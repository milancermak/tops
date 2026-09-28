use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use librespot::{
    connect::{ConnectConfig, LoadRequest, LoadRequestOptions, Spirc},
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
        player::{Player, PlayerEvent},
    },
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::mpsc,
    task::JoinHandle,
};

const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const SCOPES: &str = "streaming user-personalized user-read-private user-read-email user-library-read playlist-read playlist-read-private playlist-read-collaborative user-read-play-history user-read-recently-played user-top-read user-read-playback-state user-read-currently-playing user-modify-playback-state app-remote-control";

#[derive(Deserialize)]
struct Request {
    id: i64,
    method: String,
    #[serde(default)]
    params: Value,
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

#[derive(Serialize, Deserialize)]
struct Tokens {
    access_token: String,
    refresh_token: String,
    expires_at: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuthTokenSource {
    DesktopOAuth,
    Login5,
}

impl AuthTokenSource {
    fn for_method(method: &str) -> Option<Self> {
        match method {
            "partnerAuthContext" => Some(Self::DesktopOAuth),
            "authContext" => Some(Self::Login5),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::DesktopOAuth => "desktop_oauth",
            Self::Login5 => "login5",
        }
    }
}

struct Engine {
    data_dir: PathBuf,
    device_id: String,
    http: reqwest::Client,
    tokens: Option<Tokens>,
    session: Option<Session>,
    spirc: Option<Spirc>,
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

fn token_needs_refresh(expires_at: u64, current_time: u64, force_refresh: bool) -> bool {
    force_refresh || expires_at <= current_time.saturating_add(120)
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
fn random_string() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn token_failure(status: u16, body: &Value) -> (bool, String) {
    if body.get("error").and_then(Value::as_str) == Some("invalid_grant") {
        (
            true,
            "Spotify authorization expired. Sign in again.".to_owned(),
        )
    } else {
        (
            false,
            format!("Spotify token request failed (HTTP {status})"),
        )
    }
}

fn callback_code(target: &str, expected_state: &str) -> Result<Option<String>> {
    let Ok(callback) = url::Url::parse(&format!("http://127.0.0.1{target}")) else {
        return Ok(None);
    };
    let params: std::collections::HashMap<_, _> = callback.query_pairs().into_owned().collect();
    if callback.path() != "/login"
        || params.get("state").map(String::as_str) != Some(expected_state)
    {
        return Ok(None);
    }
    if params.contains_key("error") {
        bail!("Spotify sign-in was declined");
    }
    Ok(params.get("code").filter(|code| !code.is_empty()).cloned())
}

impl Engine {
    fn new(data_dir: PathBuf, output: mpsc::UnboundedSender<Value>) -> Result<Self> {
        private_dir(&data_dir)?;
        let device_path = data_dir.join("device-id");
        let device_id =
            fs::read_to_string(&device_path).unwrap_or_else(|_| uuid::Uuid::new_v4().to_string());
        private_write(&device_path, device_id.as_bytes())?;
        let tokens = fs::read(data_dir.join("oauth.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        Ok(Self {
            data_dir,
            device_id,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()?,
            tokens,
            session: None,
            spirc: None,
            tasks: vec![],
            state: Arc::new(Mutex::new(Playback::default())),
            output,
        })
    }

    async fn exchange(
        &mut self,
        fields: &[(&str, &str)],
        fallback_refresh: Option<String>,
    ) -> Result<()> {
        let response = self
            .http
            .post("https://accounts.spotify.com/api/token")
            .form(fields)
            .send()
            .await
            .context("Spotify token service unavailable")?;
        let status = response.status();
        let body: Value = response
            .json()
            .await
            .context("Invalid Spotify token response")?;
        if !status.is_success() {
            // Never include response bodies: they can contain credentials or reflected input.
            let (revoked, message) = token_failure(status.as_u16(), &body);
            if revoked {
                self.tokens = None;
                let _ = fs::remove_file(self.data_dir.join("oauth.json"));
            }
            bail!(message);
        }
        let access_token = body["access_token"]
            .as_str()
            .context("Missing access token")?
            .to_owned();
        let refresh_token = body["refresh_token"]
            .as_str()
            .map(str::to_owned)
            .or(fallback_refresh)
            .context("Missing refresh token")?;
        let tokens = Tokens {
            access_token,
            refresh_token,
            expires_at: now() + body["expires_in"].as_u64().unwrap_or(3600),
        };
        private_write(
            &self.data_dir.join("oauth.json"),
            &serde_json::to_vec(&tokens)?,
        )?;
        self.tokens = Some(tokens);
        Ok(())
    }

    async fn valid_token(&mut self, interactive: bool, force_refresh: bool) -> Result<String> {
        if let Some(tokens) = &self.tokens {
            if !token_needs_refresh(tokens.expires_at, now(), force_refresh) {
                return Ok(tokens.access_token.clone());
            }
            let refresh = tokens.refresh_token.clone();
            let refreshed = self
                .exchange(
                    &[
                        ("grant_type", "refresh_token"),
                        ("refresh_token", &refresh),
                        ("client_id", CLIENT_ID),
                    ],
                    Some(refresh.clone()),
                )
                .await;
            if let Err(error) = refreshed {
                if interactive && self.tokens.is_none() {
                    self.authorize().await?;
                } else {
                    return Err(error);
                }
            }
        } else if interactive {
            self.authorize().await?;
        } else {
            bail!("Sign in with Spotify first");
        }
        Ok(self
            .tokens
            .as_ref()
            .context("Authorization not available")?
            .access_token
            .clone())
    }

    async fn authorize(&mut self) -> Result<()> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .context("Cannot start local login callback")?;
        let redirect = format!("http://127.0.0.1:{}/login", listener.local_addr()?.port());
        let verifier = random_string();
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let state = random_string();
        let mut auth_url = url::Url::parse("https://accounts.spotify.com/authorize")?;
        auth_url.query_pairs_mut().extend_pairs([
            ("client_id", CLIENT_ID),
            ("response_type", "code"),
            ("redirect_uri", redirect.as_str()),
            ("scope", SCOPES),
            ("state", state.as_str()),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge.as_str()),
        ]);
        self.output
            .send(json!({"event":"authentication","data":{"state":"waiting_for_browser"}}))?;
        let opened = tokio::process::Command::new("/usr/bin/open")
            .arg(auth_url.as_str())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await?;
        if !opened.success() {
            bail!("Could not open Spotify sign-in in your browser");
        }
        let code = tokio::time::timeout(Duration::from_secs(180), async {
            loop {
                let (mut socket, _) = listener.accept().await?;
                let mut bytes = vec![0u8; 8192];
                let count = match tokio::time::timeout(Duration::from_secs(3), socket.read(&mut bytes)).await {
                    Ok(Ok(n)) => n,
                    _ => continue,
                };
                let request = String::from_utf8_lossy(&bytes[..count]);
                let target = request.lines().next().and_then(|line| line.split_whitespace().nth(1)).unwrap_or("");
                let code_result = callback_code(target, &state);
                let code = code_result.as_ref().ok().and_then(|code| code.as_ref());
                let message = if code.is_some() { "Spotify is connected. You can close this tab and return to Tops." } else { "This callback did not complete authorization. Return to the Spotify sign-in page." };
                let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", message.len(), message);
                let _ = socket.write_all(response.as_bytes()).await;
                if let Some(code) = code_result? { return Ok::<_, anyhow::Error>(code); }
            }
        }).await.context("Spotify sign-in timed out")??;
        self.exchange(
            &[
                ("grant_type", "authorization_code"),
                ("code", &code),
                ("redirect_uri", &redirect),
                ("client_id", CLIENT_ID),
                ("code_verifier", &verifier),
            ],
            None,
        )
        .await
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
        let access_token = self.valid_token(true, false).await?;
        let cache_dir = self.data_dir.join("session");
        private_dir(&cache_dir)?;
        let cache = Cache::new(Some(&cache_dir), Some(&cache_dir), None, None)?;
        let credentials = cache
            .credentials()
            .unwrap_or_else(|| Credentials::with_access_token(access_token));
        let config = SessionConfig {
            device_id: self.device_id.clone(),
            ..Default::default()
        };
        let session = Session::new(config, Some(cache));
        let mixer = mixer::find(None).context("Audio mixer missing")?(MixerConfig::default())?;
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
        let (spirc, spirc_task) = tokio::time::timeout(
            Duration::from_secs(35),
            Spirc::new(
                ConnectConfig {
                    name: "Tops".to_owned(),
                    device_type: DeviceType::Computer,
                    initial_volume: 32768,
                    ..Default::default()
                },
                session.clone(),
                credentials,
                player,
                mixer,
            ),
        )
        .await
        .context("Spotify connection timed out")??;
        let state = self.state.clone();
        let output = self.output.clone();
        self.tasks.push(tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                let mut snapshot = state.lock().unwrap();
                let became_paused = should_trim_after_event(snapshot.is_playing, &event);
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
                    PlayerEvent::Loading { track_id, position_ms, .. } => { snapshot.is_playing = false; snapshot.track_uri = Some(track_id.to_uri()); snapshot.position_ms = position_ms; snapshot.duration_ms = None; }
                    PlayerEvent::Stopped { .. } | PlayerEvent::EndOfTrack { .. } => snapshot.is_playing = false,
                    PlayerEvent::Unavailable { .. } => { snapshot.is_playing = false; let _ = output.send(json!({"event":"error","data":{"message":"Spotify could not load this track"}})); }
                    _ => continue,
                }
                let _ = output.send(json!({"event":"playback","data":*snapshot}));
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
        self.state.lock().unwrap().volume_percent = Some(50.0);
        let result =
            json!({"connected":true,"username":session.username(),"device_id":self.device_id});
        self.session = Some(session);
        self.spirc = Some(spirc);
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
        *self.state.lock().unwrap() = Playback::default();
    }

    async fn authorization_token(
        &mut self,
        source: AuthTokenSource,
        force_refresh: bool,
    ) -> Result<(String, u64)> {
        Ok(match source {
            AuthTokenSource::DesktopOAuth => {
                // Pathfinder uses the original first-party desktop grant. Keep its refresh
                // ownership here; the single request loop serializes all refreshes.
                let access_token = self.valid_token(false, force_refresh).await?;
                let expires_at = self
                    .tokens
                    .as_ref()
                    .context("Authorization not available")?
                    .expires_at;
                (access_token, expires_at)
            }
            AuthTokenSource::Login5 => {
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

#[cfg(test)]
mod tests {
    use super::*;

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
    async fn partner_auth_routes_to_original_desktop_grant_separately_from_login5() {
        let request: Request =
            serde_json::from_value(json!({"id":12,"method":"partnerAuthContext","params":{}}))
                .unwrap();
        let source = AuthTokenSource::for_method(&request.method).unwrap();
        assert_eq!(source, AuthTokenSource::DesktopOAuth);
        assert_eq!(source.label(), "desktop_oauth");
        assert_ne!(source, AuthTokenSource::for_method("authContext").unwrap());
        assert_eq!(
            AuthTokenSource::for_method("authContext"),
            Some(AuthTokenSource::Login5)
        );
        assert_eq!(AuthTokenSource::for_method("status"), None);
        let (output, _receiver) = mpsc::unbounded_channel();
        let expiry = now() + 3600;
        // Entirely in-memory fixture: a partner grant must work without a Login5 session.
        // Selecting Login5 here would fail before any network call can occur.
        let mut engine = Engine {
            data_dir: PathBuf::from("/unused-test-path"),
            device_id: "fixture-device".to_owned(),
            http: reqwest::Client::new(),
            tokens: Some(Tokens {
                access_token: "fixture-original-desktop-oauth".to_owned(),
                refresh_token: "fixture-refresh".to_owned(),
                expires_at: expiry,
            }),
            session: None,
            spirc: None,
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
                .authorization_token(AuthTokenSource::Login5, false)
                .await
                .is_err()
        );
    }

    #[test]
    fn forced_refresh_replaces_even_an_unexpired_rejected_grant() {
        assert!(!token_needs_refresh(5000, 1000, false));
        assert!(token_needs_refresh(5000, 1000, true));
        assert!(token_needs_refresh(1120, 1000, false));
        assert!(!token_needs_refresh(1121, 1000, false));
        assert!(token_needs_refresh(999, 1000, false));
    }

    #[test]
    fn callback_requires_matching_state_and_path_before_code_or_denial() {
        assert_eq!(
            callback_code("/login?code=valid&state=expected", "expected").unwrap(),
            Some("valid".to_owned())
        );
        for path in [
            "/login?code=attacker",
            "/login?code=attacker&state=wrong",
            "/other?code=attacker&state=expected",
            "/login?error=denied&state=wrong",
        ] {
            assert_eq!(callback_code(path, "expected").unwrap(), None);
        }
        assert!(callback_code("/login?error=access_denied&state=expected", "expected").is_err());
    }

    #[test]
    fn token_failures_never_echo_response_credentials_and_only_invalid_grant_revokes() {
        let secret = "fixture-access-or-refresh-token";
        for status in [400, 401, 429, 500] {
            let (revoked, message) = token_failure(
                status,
                &json!({"error":"server_error","access_token":secret,"error_description":secret}),
            );
            assert!(!revoked);
            assert!(!message.contains(secret));
            assert!(message.contains(&status.to_string()));
        }
        let (revoked, message) = token_failure(
            400,
            &json!({"error":"invalid_grant","error_description":secret}),
        );
        assert!(revoked);
        assert!(!message.contains(secret));
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
    // No logger is installed. Upstream trace logs may include authentication material.
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
