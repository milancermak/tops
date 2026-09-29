//! Shared owner of the desktop OAuth grant used by browsing and native playback.
use crate::{now, private_write};
use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use librespot::core::{Error as PlaybackError, login5::TokenProvider, token::Token};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    future::Future,
    path::PathBuf,
    pin::Pin,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::{Mutex, mpsc},
};

pub const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const SCOPES: &str = "streaming user-personalized user-read-private user-read-email user-library-read playlist-read playlist-read-private playlist-read-collaborative user-read-play-history user-read-recently-played user-top-read user-read-playback-state user-read-currently-playing user-modify-playback-state app-remote-control";
const TOKEN_ENDPOINT: &str = "https://accounts.spotify.com/api/token";

#[derive(Serialize, Deserialize)]
struct Tokens {
    access_token: String,
    refresh_token: String,
    expires_at: u64,
}

impl Tokens {
    fn grant(&self) -> Grant {
        Grant {
            access_token: self.access_token.clone(),
            expires_at: self.expires_at,
        }
    }
}

// Never derive Debug: grants contain credentials.
pub struct Grant {
    pub access_token: String,
    pub expires_at: u64,
}

impl Grant {
    fn playback_token(self, timestamp: SystemTime) -> Result<Token, PlaybackError> {
        let expires_at = UNIX_EPOCH
            .checked_add(Duration::from_secs(self.expires_at))
            .ok_or_else(|| PlaybackError::invalid_argument("Invalid desktop token expiry"))?;
        let expires_in = expires_at.duration_since(timestamp).unwrap_or_default();
        if expires_in <= Duration::from_secs(10) {
            return Err(PlaybackError::unauthenticated(
                "Spotify desktop authorization expired",
            ));
        }
        Ok(Token {
            access_token: self.access_token,
            expires_in,
            token_type: "Bearer".to_owned(),
            scopes: SCOPES.split_whitespace().map(str::to_owned).collect(),
            timestamp,
        })
    }
}

pub type SharedOAuth = Arc<Mutex<OAuthStore>>;

pub struct OAuthStore {
    data_dir: PathBuf,
    http: reqwest::Client,
    tokens: Option<Tokens>,
    // A background playback session may briefly outlive Engine during shutdown.
    // It must not keep the IPC writer open through this provider-owned store.
    output: mpsc::WeakUnboundedSender<Value>,
    #[cfg(test)]
    test_token_endpoint: Option<String>,
}

// This provider owns only the shared grant store, never the Session that owns it.
pub struct PlaybackTokenProvider(pub SharedOAuth);

impl TokenProvider for PlaybackTokenProvider {
    fn token(&self) -> Pin<Box<dyn Future<Output = Result<Token, PlaybackError>> + Send + '_>> {
        Box::pin(async move {
            let grant = {
                let mut store = self.0.lock().await;
                match store.valid_token(false, false).await {
                    Ok(grant) => grant,
                    Err(_) if store.tokens.is_none() => {
                        return Err(PlaybackError::unauthenticated(
                            "Spotify authorization expired. Reconnect to sign in again.",
                        ));
                    }
                    Err(_) => {
                        return Err(PlaybackError::unavailable(
                            "Spotify desktop authorization refresh failed",
                        ));
                    }
                }
            };
            grant.playback_token(SystemTime::now())
        })
    }
}

fn token_needs_refresh(expires_at: u64, current_time: u64, force_refresh: bool) -> bool {
    force_refresh || expires_at <= current_time.saturating_add(120)
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
            format!(
                "Spotify sign-in token request failed (accounts.spotify.com/api/token, HTTP {status})"
            ),
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

impl OAuthStore {
    pub fn new(data_dir: PathBuf, output: mpsc::UnboundedSender<Value>) -> Result<Self> {
        let tokens = fs::read(data_dir.join("oauth.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        Ok(Self {
            data_dir,
            output: output.downgrade(),
            tokens,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()?,
            #[cfg(test)]
            test_token_endpoint: None,
        })
    }

    fn token_endpoint(&self) -> &str {
        #[cfg(test)]
        if let Some(endpoint) = &self.test_token_endpoint {
            return endpoint;
        }
        TOKEN_ENDPOINT
    }

    #[cfg(test)]
    pub fn fixture(output: mpsc::UnboundedSender<Value>, expires_at: u64) -> Self {
        Self {
            data_dir: PathBuf::from("/unused-test-path"),
            http: reqwest::Client::new(),
            tokens: Some(Tokens {
                access_token: "fixture-original-desktop-oauth".to_owned(),
                refresh_token: "fixture-refresh".to_owned(),
                expires_at,
            }),
            output: output.downgrade(),
            test_token_endpoint: None,
        }
    }

    async fn exchange(
        &mut self,
        fields: &[(&str, &str)],
        fallback_refresh: Option<String>,
    ) -> Result<()> {
        let response = self
            .http
            .post(self.token_endpoint())
            .form(fields)
            .send()
            .await
            .context("Spotify token service unavailable")?;
        let status = response.status();
        let body = response.json::<Value>().await;
        if !status.is_success() {
            // Never include response bodies: they can contain credentials or reflected input.
            // A service failure may return HTML or an empty body; preserve its status.
            let (revoked, message) = token_failure(status.as_u16(), &body.unwrap_or(Value::Null));
            if revoked {
                self.tokens = None;
                let _ = fs::remove_file(self.data_dir.join("oauth.json"));
            }
            bail!(message);
        }
        let body =
            body.context("Invalid Spotify token response (accounts.spotify.com/api/token)")?;
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
            expires_at: now().saturating_add(body["expires_in"].as_u64().unwrap_or(3600)),
        };
        private_write(
            &self.data_dir.join("oauth.json"),
            &serde_json::to_vec(&tokens)?,
        )?;
        self.tokens = Some(tokens);
        Ok(())
    }

    pub async fn valid_token(&mut self, interactive: bool, force_refresh: bool) -> Result<Grant> {
        if let Some(tokens) = &self.tokens {
            if !token_needs_refresh(tokens.expires_at, now(), force_refresh) {
                return Ok(tokens.grant());
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
            .grant())
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
            .upgrade()
            .context("Playback engine has stopped")?
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn playback_provider_does_not_keep_the_ipc_writer_alive() {
        let (output, mut events) = mpsc::unbounded_channel();
        let store = Arc::new(Mutex::new(OAuthStore::fixture(output.clone(), now() + 500)));
        let provider = PlaybackTokenProvider(store);
        drop(output);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), events.recv())
                .await
                .unwrap()
                .is_none()
        );
        assert!(provider.token().await.is_ok());
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
        for status in [400, 401, 429, 500, 503] {
            let (revoked, message) = token_failure(
                status,
                &json!({"error":"server_error","access_token":secret,"error_description":secret}),
            );
            assert!(!revoked);
            assert!(!message.contains(secret));
            assert!(message.contains(&status.to_string()));
        }
        let (revoked, message) = token_failure(503, &Value::Null);
        assert!(!revoked);
        assert!(message.contains("accounts.spotify.com/api/token, HTTP 503"));
        let (revoked, message) = token_failure(
            400,
            &json!({"error":"invalid_grant","error_description":secret}),
        );
        assert!(revoked);
        assert!(!message.contains(secret));
    }

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("tops-oauth-test-{}", uuid::Uuid::new_v4()));
            crate::private_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    async fn mock_token_service(
        responses: Vec<(u16, String)>,
    ) -> (String, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}/token", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let mut bodies = Vec::new();
            for (status, body) in responses {
                let (mut socket, _) =
                    tokio::time::timeout(Duration::from_secs(5), listener.accept())
                        .await
                        .unwrap()
                        .unwrap();
                let mut request = Vec::new();
                let (header_end, length) = loop {
                    let mut buffer = [0; 1024];
                    let read = socket.read(&mut buffer).await.unwrap();
                    assert_ne!(read, 0);
                    request.extend_from_slice(&buffer[..read]);
                    assert!(request.len() < 16_384);
                    if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&request[..end]);
                        let length = headers
                            .lines()
                            .find_map(|line| {
                                let (name, value) = line.split_once(':')?;
                                name.eq_ignore_ascii_case("content-length")
                                    .then(|| value.trim().parse::<usize>().unwrap())
                            })
                            .unwrap();
                        break (end + 4, length);
                    }
                };
                while request.len() < header_end + length {
                    let mut buffer = [0; 1024];
                    let read = socket.read(&mut buffer).await.unwrap();
                    assert_ne!(read, 0);
                    request.extend_from_slice(&buffer[..read]);
                }
                bodies.push(
                    String::from_utf8(request[header_end..header_end + length].to_vec()).unwrap(),
                );
                // Give a concurrent caller time to queue behind the shared store.
                tokio::time::sleep(Duration::from_millis(20)).await;
                let response = format!(
                    "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            }
            bodies
        });
        (endpoint, server)
    }

    fn test_store(
        directory: &TestDirectory,
        output: mpsc::UnboundedSender<Value>,
        endpoint: String,
    ) -> SharedOAuth {
        let mut store = OAuthStore::fixture(output, now().saturating_sub(1));
        store.data_dir = directory.0.clone();
        store.test_token_endpoint = Some(endpoint);
        private_write(
            &directory.0.join("oauth.json"),
            &serde_json::to_vec(store.tokens.as_ref().unwrap()).unwrap(),
        )
        .unwrap();
        Arc::new(Mutex::new(store))
    }

    #[tokio::test]
    async fn concurrent_browsing_and_playback_refresh_once_and_preserve_rotated_refresh_token() {
        let directory = TestDirectory::new();
        let (output, _events) = mpsc::unbounded_channel();
        let (endpoint, server) = mock_token_service(vec![
            (200, json!({"access_token":"fixture-access-one", "refresh_token":"fixture-rotated-refresh", "expires_in":3600}).to_string()),
            // A later response may omit refresh_token: preserve the rotated one.
            (200, json!({"access_token":"fixture-access-two", "expires_in":3600}).to_string()),
        ]).await;
        let store = test_store(&directory, output, endpoint);
        let provider = PlaybackTokenProvider(store.clone());
        let (playback, browsing) = tokio::join!(provider.token(), async {
            store.lock().await.valid_token(false, false).await
        });
        let playback = playback.unwrap();
        let browsing = browsing.unwrap();
        assert_eq!(playback.access_token, "fixture-access-one");
        assert_eq!(browsing.access_token, playback.access_token);
        assert_eq!(
            (playback.timestamp + playback.expires_in)
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            browsing.expires_at
        );
        let forced = store.lock().await.valid_token(false, true).await.unwrap();
        assert_eq!(forced.access_token, "fixture-access-two");
        let requests = server.await.unwrap();
        assert_eq!(requests.len(), 2);
        let refresh = |body: &str| -> String {
            url::form_urlencoded::parse(body.as_bytes())
                .find(|(name, _)| name == "refresh_token")
                .unwrap()
                .1
                .into_owned()
        };
        assert_eq!(refresh(&requests[0]), "fixture-refresh");
        assert_eq!(refresh(&requests[1]), "fixture-rotated-refresh");
        let saved: Tokens =
            serde_json::from_slice(&fs::read(directory.0.join("oauth.json")).unwrap()).unwrap();
        assert_eq!(saved.access_token, "fixture-access-two");
        assert_eq!(saved.refresh_token, "fixture-rotated-refresh");
    }

    #[tokio::test]
    async fn failed_refresh_preserves_grant_but_revocation_clears_it_without_browser() {
        let directory = TestDirectory::new();
        let (output, mut events) = mpsc::unbounded_channel();
        let (endpoint, server) = mock_token_service(vec![
            (503, "<html>fixture-secret-reflected</html>".to_owned()),
            (
                400,
                json!({"error":"invalid_grant", "error_description":"fixture-secret-reflected"})
                    .to_string(),
            ),
        ])
        .await;
        let store = test_store(&directory, output, endpoint);
        let initial = fs::read(directory.0.join("oauth.json")).unwrap();
        let provider = PlaybackTokenProvider(store.clone());
        let transient = provider.token().await.unwrap_err();
        assert_eq!(
            transient.kind,
            librespot::core::error::ErrorKind::Unavailable
        );
        assert!(!transient.to_string().contains("fixture-secret"));
        assert_eq!(fs::read(directory.0.join("oauth.json")).unwrap(), initial);
        assert!(store.lock().await.tokens.is_some());
        let revoked = provider.token().await.unwrap_err();
        assert_eq!(
            revoked.kind,
            librespot::core::error::ErrorKind::Unauthenticated
        );
        assert!(!revoked.to_string().contains("fixture-secret"));
        assert!(store.lock().await.tokens.is_none());
        assert!(!directory.0.join("oauth.json").exists());
        assert!(events.try_recv().is_err());
        assert_eq!(server.await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn valid_grant_uses_no_network_and_provider_preserves_absolute_expiry() {
        let (output, _events) = mpsc::unbounded_channel();
        let expires_at = now() + 500;
        let mut store = OAuthStore::fixture(output, expires_at);
        // Any accidental refresh fails locally; this fixture never contacts Spotify.
        store.test_token_endpoint = Some("http://127.0.0.1:0/token".to_owned());
        let grant = store.valid_token(false, false).await.unwrap();
        let timestamp =
            UNIX_EPOCH + Duration::from_secs(expires_at - 45) + Duration::from_millis(250);
        let token = grant.playback_token(timestamp).unwrap();
        assert_eq!(token.expires_in, Duration::from_millis(44_750));
        assert_eq!(
            token.timestamp + token.expires_in,
            UNIX_EPOCH + Duration::from_secs(expires_at)
        );
        let expired = Grant {
            access_token: "fixture-expired".to_owned(),
            expires_at,
        };
        assert!(
            expired
                .playback_token(UNIX_EPOCH + Duration::from_secs(expires_at))
                .is_err()
        );
    }
}
