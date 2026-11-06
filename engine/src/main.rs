mod diagnostics;
mod oauth;

use oauth::{CLIENT_ID, OAuthStore, PlaybackTokenProvider, SharedOAuth};

use anyhow::{Context, Result, bail};
use librespot::{
    connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc},
    core::{
        SpotifyUri,
        authentication::Credentials,
        cache::Cache,
        config::{DeviceType, SessionConfig},
        session::Session,
    },
    metadata::audio::UniqueFields,
    playback::{
        audio_backend,
        config::{AudioFormat, Bitrate, PlayerConfig},
        mixer::{self, MixerConfig},
        player::{Player, PlayerEvent, PlayerEventChannel},
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
    task::JoinHandle,
};

#[derive(Deserialize)]
struct Request {
    id: i64,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
struct RestorePlayback {
    track_uri: String,
    context_uri: Option<String>,
    position_ms: u32,
    start_playing: bool,
}

#[derive(Clone, Default, Serialize)]
struct Playback {
    connected: bool,
    is_playing: bool,
    position_ms: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    track_uri: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_ms: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    image_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    volume_percent: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuthTokenSource {
    DesktopOAuth,
    Playback,
}

impl AuthTokenSource {
    fn for_method(method: &str) -> Option<Self> {
        match method {
            "partnerAuthContext" => Some(Self::DesktopOAuth),
            "authContext" => Some(Self::Playback),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::DesktopOAuth => "desktop_oauth",
            Self::Playback => "desktop_oauth",
        }
    }
}

struct Engine {
    data_dir: PathBuf,
    device_id: String,
    oauth: SharedOAuth,
    session: Option<Session>,
    spirc: Option<Spirc>,
    player: Option<Arc<Player>>,
    tasks: Vec<JoinHandle<()>>,
    state: Arc<Mutex<Playback>>,
    output: mpsc::UnboundedSender<Value>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn connect_config() -> ConnectConfig {
    ConnectConfig {
        name: "Tops".to_owned(),
        device_type: DeviceType::Computer,
        // Tops controls the macOS output volume. Start the software mixer at
        // unity: Connect ignores volume commands until the device is active.
        initial_volume: u16::MAX,
        ..Default::default()
    }
}

fn playback_mixer() -> Result<Arc<dyn mixer::Mixer>> {
    Ok(mixer::find(None).context("Audio mixer missing")?(
        MixerConfig::default(),
    )?)
}

fn trim_memory() -> usize {
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
        }
        // Apple's malloc/malloc.h documents NULL as all zones and zero as maximal
        // release of unused pages. This does not free live allocations. Call from
        // the control task while idle/paused, never from the audio callback.
        unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) }
    }
    #[cfg(not(target_os = "macos"))]
    {
        0
    }
}

fn should_trim_after_event(was_playing: bool, event: &PlayerEvent) -> bool {
    was_playing && matches!(event, PlayerEvent::Paused { .. })
}

fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        bail!("Data directory must not be a symlink");
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
fn private_write(path: &Path, contents: &[u8]) -> Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(contents)?;
        file.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

impl Engine {
    fn new(data_dir: PathBuf, output: mpsc::UnboundedSender<Value>) -> Result<Self> {
        private_dir(&data_dir)?;
        let device_path = data_dir.join("device-id");
        let device_id =
            fs::read_to_string(&device_path).unwrap_or_else(|_| uuid::Uuid::new_v4().to_string());
        private_write(&device_path, device_id.as_bytes())?;
        let oauth = Arc::new(tokio::sync::Mutex::new(OAuthStore::new(
            data_dir.clone(),
            output.clone(),
        )?));
        Ok(Self {
            data_dir,
            device_id,
            oauth,
            session: None,
            spirc: None,
            player: None,
            tasks: vec![],
            state: Arc::new(Mutex::new(Playback::default())),
            output,
        })
    }

    async fn authenticate(&mut self) -> Result<Value> {
        if self.session.as_ref().is_some_and(|s| !s.is_invalid())
            && self.spirc.is_some()
            && self.state.lock().unwrap().connected
        {
            return Ok(
                json!({"connected":true,"username":self.session.as_ref().unwrap().username(),"device_id":self.device_id}),
            );
        }
        self.disconnect();
        // Release the grant lock before Spirc calls the same store through its provider.
        let grant = { self.oauth.lock().await.valid_token(true, false).await? };
        let cache_dir = self.data_dir.join("session");
        private_dir(&cache_dir)?;
        let cache = Cache::new(Some(&cache_dir), Some(&cache_dir), None, None)?;
        // AP and HTTP authorization must refer to the same account, even after
        // the browser grant changes. Never prefer a possibly different cached user.
        let credentials = Credentials::with_access_token(grant.access_token);
        let config = SessionConfig {
            device_id: self.device_id.clone(),
            ..Default::default()
        };
        let session = Session::new(config, Some(cache));
        session
            .login5()
            .set_token_provider(Arc::new(PlaybackTokenProvider(self.oauth.clone())));
        let mixer = playback_mixer()?;
        let sink =
            audio_backend::find(Some("rodio".to_owned())).context("CoreAudio output missing")?;
        let player = Player::new(
            PlayerConfig {
                bitrate: Bitrate::Bitrate320,
                position_update_interval: Some(Duration::from_secs(1)),
                normalisation: true,
                ..Default::default()
            },
            session.clone(),
            mixer.get_soft_volume(),
            move || sink(None, AudioFormat::default()),
        );
        let mut events = player.get_player_event_channel();
        let connect_config = connect_config();
        let initial_volume_percent = connect_config.initial_volume as f64 / u16::MAX as f64 * 100.0;
        let mut attempt = diagnostics::Attempt::begin(now());
        let connection = tokio::time::timeout(Duration::from_secs(35), async {
            // Spirc normally does this first. Acquire it here to identify this
            // failure exactly; Spirc reuses the same session's cached token.
            session.spclient().client_token().await?;
            attempt.stage = diagnostics::Stage::PlaybackSession;
            Spirc::new(
                connect_config,
                session.clone(),
                credentials,
                player.clone(),
                mixer,
            )
            .await
        })
        .await;
        let report = match &connection {
            Ok(Ok(_)) => attempt.report(None, false),
            Ok(Err(error)) => attempt.report(Some(error), false),
            Err(_) => attempt.report(None, true),
        };
        drop(attempt);
        // A bounded, private latest-attempt report; never write raw errors or
        // protocol replies. Failure to save diagnostics must not prevent login.
        if let Ok(bytes) = serde_json::to_vec_pretty(&report) {
            let _ = private_write(&self.data_dir.join("connection-diagnostic.json"), &bytes);
        }
        let _ = self
            .output
            .send(json!({"event":"connection_diagnostic","data":report}));
        let (spirc, spirc_task) = match connection {
            Ok(Ok(connected)) => connected,
            _ => {
                // Spirc may have opened a session before a later service failed.
                session.shutdown();
                bail!(report.failure_message());
            }
        };
        let state = self.state.clone();
        let output = self.output.clone();
        self.tasks.push(tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                let mut snapshot = state.lock().unwrap();
                let became_paused = should_trim_after_event(snapshot.is_playing, &event);
                let position_confirmed = matches!(&event,
                    PlayerEvent::Playing { .. } | PlayerEvent::Paused { .. } | PlayerEvent::PositionChanged { .. }
                    | PlayerEvent::PositionCorrection { .. } | PlayerEvent::Seeked { .. });
                match event {
                    PlayerEvent::Playing { track_id, position_ms, .. } => { snapshot.is_playing = true; snapshot.track_uri = Some(track_id.to_uri()); snapshot.position_ms = position_ms; }
                    PlayerEvent::Paused { track_id, position_ms, .. } => { snapshot.is_playing = false; snapshot.track_uri = Some(track_id.to_uri()); snapshot.position_ms = position_ms; }
                    PlayerEvent::PositionChanged { position_ms, .. } | PlayerEvent::PositionCorrection { position_ms, .. } | PlayerEvent::Seeked { position_ms, .. } => snapshot.position_ms = position_ms,
                    PlayerEvent::TrackChanged { audio_item } => {
                        snapshot.track_uri = Some(audio_item.uri);
                        snapshot.duration_ms = Some(audio_item.duration_ms);
                        snapshot.title = Some(audio_item.name);
                        snapshot.image_url = audio_item.covers.iter().max_by_key(|cover| cover.width).map(|cover| cover.url.clone());
                        snapshot.artist = match audio_item.unique_fields {
                            UniqueFields::Track { artists, .. } => Some(artists.iter().map(|artist| artist.name.as_str()).collect::<Vec<_>>().join(", ")),
                            UniqueFields::Episode { show_name, .. } => Some(show_name),
                            UniqueFields::Local { artists, .. } => artists,
                        };
                    }
                    PlayerEvent::VolumeChanged { volume } => snapshot.volume_percent = Some(volume as f64 / u16::MAX as f64 * 100.0),
                    PlayerEvent::Loading { track_id, position_ms, .. } => {
                        let uri = track_id.to_uri();
                        if snapshot.track_uri.as_deref() != Some(&uri) {
                            snapshot.title = None;
                            snapshot.artist = None;
                            snapshot.image_url = None;
                        }
                        snapshot.is_playing = false;
                        snapshot.track_uri = Some(uri);
                        snapshot.position_ms = position_ms;
                        snapshot.duration_ms = None;
                    }
                    PlayerEvent::Stopped { .. } | PlayerEvent::EndOfTrack { .. } => snapshot.is_playing = false,
                    PlayerEvent::Unavailable { .. } => { snapshot.is_playing = false; let _ = output.send(json!({"event":"error","data":{"message":"Spotify could not load this track"}})); }
                    _ => continue,
                }
                let mut data = json!(*snapshot);
                data["position_confirmed"] = json!(position_confirmed);
                let _ = output.send(json!({"event":"playback","data":data}));
                drop(snapshot);
                if became_paused {
                    let state = state.clone();
                    // Allocator maintenance belongs off the audio and async event paths.
                    // Recheck because playback may resume before this worker starts.
                    tokio::task::spawn_blocking(move || {
                        let is_playing = state.lock().unwrap().is_playing;
                        if !is_playing {
                            trim_memory();
                        }
                    });
                }
            }
        }));
        let state = self.state.clone();
        let output = self.output.clone();
        self.tasks.push(tokio::spawn(async move {
            spirc_task.await;
            state.lock().unwrap().connected = false;
            let _ = output.send(json!({"event":"connection","data":{"connected":false}}));
        }));
        self.state.lock().unwrap().connected = true;
        self.state.lock().unwrap().volume_percent = Some(initial_volume_percent);
        let result =
            json!({"connected":true,"username":session.username(),"device_id":self.device_id});
        self.session = Some(session);
        self.spirc = Some(spirc);
        self.player = Some(player);
        Ok(result)
    }

    fn disconnect(&mut self) {
        if let Some(spirc) = self.spirc.take() {
            let _ = spirc.shutdown();
        }
        if let Some(session) = self.session.take() {
            session.shutdown();
        }
        for task in self.tasks.drain(..) {
            task.abort();
        }
        self.player = None;
        *self.state.lock().unwrap() = Playback::default();
    }

    async fn restore_playback(&self, saved: RestorePlayback) -> Result<Value> {
        let spirc = self.spirc.as_ref().context("Sign in with Spotify first")?;
        let player = self.player.as_ref().context("Sign in with Spotify first")?;
        let track = SpotifyUri::from_uri(&saved.track_uri).context("Invalid saved track URI")?;
        if !matches!(track, SpotifyUri::Track { .. } | SpotifyUri::Episode { .. }) {
            bail!("Unsupported saved track URI");
        }
        let options = LoadRequestOptions {
            seek_to: saved.position_ms,
            ..Default::default()
        };
        let context_load = if let Some(uri) = saved.context_uri {
            let parsed = SpotifyUri::from_uri(&uri).context("Invalid saved collection URI")?;
            if !matches!(
                parsed,
                SpotifyUri::Playlist { .. } | SpotifyUri::Album { .. } | SpotifyUri::Artist { .. }
            ) {
                bail!("Unsupported saved collection URI");
            }
            Some(LoadRequest::from_context_uri(
                uri,
                LoadRequestOptions {
                    playing_track: Some(PlayingTrack::Uri(saved.track_uri.clone())),
                    ..options.clone()
                },
            ))
        } else {
            None
        };

        spirc.activate()?;
        let mut context_restored = false;
        if let Some(load) = context_load {
            context_restored = load_saved_track(spirc, player, load, &track).await?;
        }
        // A changed collection can resolve to its first song. Confirm the saved
        // URI while paused before letting audio start.
        if !context_restored
            && !load_saved_track(
                spirc,
                player,
                LoadRequest::from_tracks(vec![saved.track_uri], options),
                &track,
            )
            .await?
        {
            bail!("Spotify could not restore the saved track");
        }
        if saved.start_playing {
            spirc.play()?;
        }
        Ok(json!({"context_restored":context_restored}))
    }

    async fn authorization_token(
        &mut self,
        source: AuthTokenSource,
        force_refresh: bool,
    ) -> Result<(String, u64)> {
        Ok(match source {
            AuthTokenSource::DesktopOAuth => {
                let grant = self
                    .oauth
                    .lock()
                    .await
                    .valid_token(false, force_refresh)
                    .await?;
                (grant.access_token, grant.expires_at)
            }
            AuthTokenSource::Playback => {
                // Refresh under the shared lock, then release it before the provider
                // re-enters the store through auth_token().
                if force_refresh {
                    self.oauth.lock().await.valid_token(false, true).await?;
                }
                let session = self
                    .session
                    .as_ref()
                    .context("Connect playback before requesting API authorization")?;
                let token =
                    tokio::time::timeout(Duration::from_secs(15), session.login5().auth_token())
                        .await
                        .context("Spotify API authorization timed out")??;
                let expires_at = (token.timestamp + token.expires_in)
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                (token.access_token, expires_at)
            }
        })
    }

    async fn handle(&mut self, request: &Request) -> Result<Value> {
        if let Some(source) = AuthTokenSource::for_method(&request.method) {
            let force_refresh = request
                .params
                .get("force_refresh")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let (access_token, expires_at) =
                self.authorization_token(source, force_refresh).await?;
            let session = self
                .session
                .as_ref()
                .context("Connect playback before requesting API authorization")?;
            let client_token =
                tokio::time::timeout(Duration::from_secs(15), session.spclient().client_token())
                    .await
                    .context("Client token request timed out")??;
            return Ok(json!({
                "access_token":access_token,
                "client_token":client_token,
                "client_id":CLIENT_ID,
                "device_id":self.device_id,
                "expires_at":expires_at,
                "token_kind":source.label()
            }));
        }
        match request.method.as_str() {
            "authenticate" => return self.authenticate().await,
            "status" => return Ok(serde_json::to_value(&*self.state.lock().unwrap())?),
            "restore" => {
                return self
                    .restore_playback(
                        serde_json::from_value(request.params.clone())
                            .context("Invalid playback checkpoint parameters")?,
                    )
                    .await;
            }
            "trimMemory" => {
                if self.state.lock().unwrap().is_playing {
                    bail!("Pause playback before releasing unused memory");
                }
                return Ok(json!({"released_bytes":trim_memory()}));
            }
            "shutdown" => {
                self.disconnect();
                return Ok(json!({"stopped":true}));
            }
            _ => {}
        }
        let spirc = self.spirc.as_ref().context("Sign in with Spotify first")?;
        match request.method.as_str() {
            "play" => {
                let uri = request.params["uri"]
                    .as_str()
                    .context("play requires uri")?;
                let parsed = SpotifyUri::from_uri(uri).context("Invalid Spotify URI")?;
                let options = LoadRequestOptions {
                    start_playing: true,
                    ..Default::default()
                };
                let load = match parsed {
                    SpotifyUri::Track { .. } | SpotifyUri::Episode { .. } => {
                        LoadRequest::from_tracks(vec![uri.to_owned()], options)
                    }
                    SpotifyUri::Album { .. }
                    | SpotifyUri::Playlist { .. }
                    | SpotifyUri::Artist { .. } => {
                        LoadRequest::from_context_uri(uri.to_owned(), options)
                    }
                    _ => bail!("Unsupported Spotify playback URI"),
                };
                spirc.activate()?;
                spirc.load(load)?;
            }
            "pause" => spirc.pause()?,
            "resume" => spirc.play()?,
            "next" => spirc.next()?,
            "previous" => spirc.prev()?,
            "seek" => {
                let position = request.params["position_ms"]
                    .as_u64()
                    .context("seek requires position_ms")?;
                spirc.set_position_ms(
                    u32::try_from(position).context("Seek position out of range")?,
                )?;
            }
            "volume" => {
                let percent = request.params["percent"]
                    .as_f64()
                    .context("volume requires percent")?;
                if !(0.0..=100.0).contains(&percent) {
                    bail!("Volume must be between 0 and 100");
                }
                spirc.set_volume((percent / 100.0 * u16::MAX as f64).round() as u16)?;
            }
            _ => bail!("Unknown engine method"),
        }
        Ok(json!({"accepted":true}))
    }
}

async fn load_saved_track(
    spirc: &Spirc,
    player: &Player,
    load: LoadRequest,
    track: &SpotifyUri,
) -> Result<bool> {
    let events = player.get_player_event_channel();
    spirc.load(load)?;
    Ok(
        tokio::time::timeout(Duration::from_secs(15), confirm_saved_track(events, track))
            .await
            .unwrap_or(false),
    )
}

async fn confirm_saved_track(mut events: PlayerEventChannel, track: &SpotifyUri) -> bool {
    let mut active_request = None;
    while let Some(event) = events.recv().await {
        match event {
            PlayerEvent::PlayRequestIdChanged { play_request_id } => {
                active_request = Some(play_request_id)
            }
            _ if active_request.is_none() || event.get_play_request_id() != active_request => {
                continue;
            }
            PlayerEvent::Paused { track_id, .. } => return &track_id == track,
            PlayerEvent::Loading { track_id, .. } if &track_id != track => return false,
            PlayerEvent::Unavailable { .. } => return false,
            _ => {}
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn restore_requires_the_saved_track_in_the_current_paused_request() {
        let saved = SpotifyUri::from_uri("spotify:track:0123456789abcdefghijkl").unwrap();
        let other = SpotifyUri::from_uri("spotify:track:1123456789abcdefghijkl").unwrap();
        let (sender, events) = mpsc::unbounded_channel();
        for event in [
            PlayerEvent::PlayRequestIdChanged { play_request_id: 2 },
            PlayerEvent::Paused {
                track_id: other.clone(),
                play_request_id: 1,
                position_ms: 0,
            },
            PlayerEvent::Paused {
                track_id: saved.clone(),
                play_request_id: 2,
                position_ms: 15_000,
            },
        ] {
            sender.send(event).unwrap();
        }
        assert!(confirm_saved_track(events, &saved).await);

        let (sender, events) = mpsc::unbounded_channel();
        sender
            .send(PlayerEvent::PlayRequestIdChanged { play_request_id: 3 })
            .unwrap();
        sender
            .send(PlayerEvent::Loading {
                track_id: other,
                play_request_id: 3,
                position_ms: 15_000,
            })
            .unwrap();
        assert!(!confirm_saved_track(events, &saved).await);
    }

    #[test]
    fn initial_connect_volume_leaves_audio_unattenuated_before_playback() {
        let mixer = playback_mixer().unwrap();
        // Spirc applies this configuration directly during construction, before
        // it accepts volume commands. Exercise the actual mixer gain, since its
        // logarithmic 50% setting attenuates audio by about 30 dB.
        mixer.set_volume(connect_config().initial_volume);
        assert_eq!(mixer.get_soft_volume().attenuation_factor(), 1.0);
    }

    #[test]
    fn allocator_relief_requires_a_confirmed_playing_to_paused_transition() {
        let track_id = SpotifyUri::from_uri("spotify:track:0123456789abcdefghijkl").unwrap();
        let paused = PlayerEvent::Paused {
            track_id: track_id.clone(),
            play_request_id: 1,
            position_ms: 15000,
        };
        assert!(should_trim_after_event(true, &paused));
        assert!(!should_trim_after_event(false, &paused));
        for event in [
            PlayerEvent::Playing {
                track_id: track_id.clone(),
                play_request_id: 1,
                position_ms: 0,
            },
            PlayerEvent::Loading {
                track_id: track_id.clone(),
                play_request_id: 1,
                position_ms: 0,
            },
            PlayerEvent::Seeked {
                track_id: track_id.clone(),
                play_request_id: 1,
                position_ms: 1000,
            },
            PlayerEvent::Stopped {
                track_id,
                play_request_id: 1,
            },
            PlayerEvent::VolumeChanged { volume: 32768 },
        ] {
            assert!(!should_trim_after_event(true, &event));
        }
    }

    #[tokio::test]
    async fn browsing_and_playback_share_the_desktop_grant_without_reentrant_locking() {
        let request: Request =
            serde_json::from_value(json!({"id":12,"method":"partnerAuthContext","params":{}}))
                .unwrap();
        let source = AuthTokenSource::for_method(&request.method).unwrap();
        assert_eq!(source, AuthTokenSource::DesktopOAuth);
        assert_eq!(source.label(), "desktop_oauth");
        assert_ne!(source, AuthTokenSource::for_method("authContext").unwrap());
        assert_eq!(
            AuthTokenSource::for_method("authContext"),
            Some(AuthTokenSource::Playback)
        );
        assert_eq!(AuthTokenSource::for_method("status"), None);
        let (output, _receiver) = mpsc::unbounded_channel();
        let expiry = now() + 3600;
        // Entirely in-memory fixture: browsing works without a playback session;
        // playback goes through the injected provider without calling Spotify.
        let mut engine = Engine {
            data_dir: PathBuf::from("/unused-test-path"),
            device_id: "fixture-device".to_owned(),
            oauth: Arc::new(tokio::sync::Mutex::new(OAuthStore::fixture(
                output.clone(),
                expiry,
            ))),
            session: None,
            spirc: None,
            player: None,
            tasks: vec![],
            state: Arc::new(Mutex::new(Playback::default())),
            output,
        };
        assert_eq!(
            engine.authorization_token(source, false).await.unwrap(),
            ("fixture-original-desktop-oauth".to_owned(), expiry)
        );
        assert!(
            engine
                .authorization_token(AuthTokenSource::Playback, false)
                .await
                .is_err()
        );
        let session = Session::new(SessionConfig::default(), None);
        session
            .login5()
            .set_token_provider(Arc::new(PlaybackTokenProvider(engine.oauth.clone())));
        engine.session = Some(session);
        let (token, token_expiry) = tokio::time::timeout(
            Duration::from_secs(1),
            engine.authorization_token(AuthTokenSource::Playback, false),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(token, "fixture-original-desktop-oauth");
        assert_eq!(token_expiry, expiry);
        assert_eq!(AuthTokenSource::Playback.label(), "desktop_oauth");
        engine.disconnect();
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 || args[1] != "--data-dir" {
        bail!("Usage: tops-engine --data-dir /absolute/private/path");
    }
    let path = PathBuf::from(&args[2]);
    if !path.is_absolute() {
        bail!("--data-dir must be absolute");
    }
    // Only allowlisted service names are retained; no upstream log is forwarded.
    diagnostics::install()
        .map_err(|_| anyhow::anyhow!("Cannot initialize connection diagnostics"))?;
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(value) = rx.recv().await {
            let mut bytes = serde_json::to_vec(&value)?;
            bytes.push(b'\n');
            stdout.write_all(&bytes).await?;
            stdout.flush().await?;
        }
        Ok::<(), anyhow::Error>(())
    });
    let mut engine = Engine::new(path, tx.clone())?;
    tx.send(json!({"event":"ready","data":{"version":env!("CARGO_PKG_VERSION")}}))?;
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        if line.len() > 64 * 1024 {
            tx.send(json!({"id":null,"error":"Request too large"}))?;
            continue;
        }
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                tx.send(json!({"id":null,"error":"Invalid JSON request"}))?;
                continue;
            }
        };
        let response = match engine.handle(&request).await {
            Ok(result) => json!({"id":request.id,"result":result}),
            Err(error) => json!({"id":request.id,"error":error.to_string()}),
        };
        tx.send(response)?;
        if request.method == "shutdown" {
            break;
        }
    }
    engine.disconnect();
    drop(engine);
    drop(tx);
    writer.await??;
    Ok(())
}
