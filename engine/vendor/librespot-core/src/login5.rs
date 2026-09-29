use crate::config::OS;
use crate::spclient::CLIENT_TOKEN;
use crate::token::Token;
use crate::{Error, SessionConfig, util};
use bytes::Bytes;
use http::{HeaderValue, Method, Request, header::ACCEPT};
use librespot_protocol::login5::login_response::Response;
use librespot_protocol::{
    client_info::ClientInfo,
    credentials::{Password, StoredCredential},
    hashcash::HashcashSolution,
    login5::{
        ChallengeSolution, LoginError, LoginOk, LoginRequest, LoginResponse,
        login_request::Login_method,
    },
};
use protobuf::well_known_types::duration::Duration as ProtoDuration;
use protobuf::{Message, MessageField};
use std::time::{Duration, SystemTime};
use std::{future::Future, pin::Pin, sync::Arc};
use thiserror::Error;
use tokio::time::sleep;

const MAX_LOGIN_TRIES: u8 = 3;
const LOGIN_TIMEOUT: Duration = Duration::from_secs(3);

/// Supplies a caller-owned bearer for native Spotify HTTP and dealer requests.
///
/// The caller owns expiry and refresh. Errors propagate without falling back to
/// Login5, so revoked external grants cannot silently switch account identity.
pub trait TokenProvider: Send + Sync {
    fn token(&self) -> Pin<Box<dyn Future<Output = Result<Token, Error>> + Send + '_>>;
}

component! {
    Login5Manager : Login5ManagerInner {
        auth_token: Option<Token> = None,
        token_provider: Option<Arc<dyn TokenProvider>> = None,
    }
}

#[derive(Debug, Error)]
enum Login5Error {
    #[error("Login request was denied: {0:?}")]
    FaultyRequest(LoginError),
    #[error("Code challenge is not supported")]
    CodeChallenge,
    #[error("Tried to acquire token without stored credentials")]
    NoStoredCredentials,
    #[error("Couldn't successfully authenticate after {0} times")]
    RetriesFailed(u8),
    #[error("Login via login5 is only allowed for android or ios")]
    OnlyForMobile,
}

impl From<Login5Error> for Error {
    fn from(err: Login5Error) -> Self {
        match err {
            Login5Error::NoStoredCredentials | Login5Error::OnlyForMobile => {
                Error::unavailable(err)
            }
            Login5Error::RetriesFailed(_) | Login5Error::FaultyRequest(_) => {
                Error::failed_precondition(err)
            }
            Login5Error::CodeChallenge => Error::unimplemented(err),
        }
    }
}

impl Login5Manager {
    /// Use a provider shared with the application's original OAuth grant.
    /// Do not capture a strong Session reference in the provider.
    pub fn set_token_provider(&self, provider: Arc<dyn TokenProvider>) {
        self.lock(|inner| {
            inner.auth_token = None;
            inner.token_provider = Some(provider);
        });
    }

    async fn request(&self, message: &LoginRequest) -> Result<Bytes, Error> {
        let client_token = self.session().spclient().client_token().await?;
        let body = message.write_to_bytes()?;

        let request = Request::builder()
            .method(&Method::POST)
            .uri("https://login5.spotify.com/v3/login")
            .header(ACCEPT, HeaderValue::from_static("application/x-protobuf"))
            .header(CLIENT_TOKEN, HeaderValue::from_str(&client_token)?)
            .body(body.into())?;

        self.session().http_client().request_body(request).await
    }

    async fn login5_request(&self, login: Login_method) -> Result<LoginOk, Error> {
        let client_id = match OS {
            "macos" | "windows" => self.session().client_id(),
            // StoredCredential is used to get an access_token from Session credentials.
            // Using the session client_id allows user to use Keymaster on Android/IOS
            // if their Credentials::with_access_token was obtained there, assuming
            // they have overriden the SessionConfig::client_id with the Keymaster's.
            _ if matches!(login, Login_method::StoredCredential(_)) => self.session().client_id(),
            _ => SessionConfig::default().client_id,
        };

        let mut login_request = LoginRequest {
            client_info: MessageField::some(ClientInfo {
                client_id,
                device_id: self.session().device_id().to_string(),
                special_fields: Default::default(),
            }),
            login_method: Some(login),
            ..Default::default()
        };

        let mut response = self.request(&login_request).await?;
        let mut count = 0;

        loop {
            count += 1;

            let message = LoginResponse::parse_from_bytes(&response)?;
            if let Some(Response::Ok(ok)) = message.response {
                break Ok(ok);
            }

            if message.has_error() {
                match message.error() {
                    LoginError::TIMEOUT | LoginError::TOO_MANY_ATTEMPTS => {
                        sleep(LOGIN_TIMEOUT).await
                    }
                    others => return Err(Login5Error::FaultyRequest(others).into()),
                }
            }

            if message.has_challenges() {
                // handles the challenges, and updates the login context with the response
                Self::handle_challenges(&mut login_request, message)?;
            }

            if count < MAX_LOGIN_TRIES {
                response = self.request(&login_request).await?;
            } else {
                return Err(Login5Error::RetriesFailed(MAX_LOGIN_TRIES).into());
            }
        }
    }

    /// Login for android and ios
    ///
    /// This request doesn't require a connected session as it is the entrypoint for android or ios
    ///
    /// This request will only work when:
    /// - client_id => android or ios | can be easily adjusted in [SessionConfig::default_for_os]
    /// - user-agent => android or ios | has to be adjusted in [HttpClient::new](crate::http_client::HttpClient::new)
    pub async fn login(
        &self,
        id: impl Into<String>,
        password: impl Into<String>,
    ) -> Result<(Token, Vec<u8>), Error> {
        if !matches!(OS, "android" | "ios") {
            // by manipulating the user-agent and client-id it can be also used/tested on desktop
            return Err(Login5Error::OnlyForMobile.into());
        }

        let method = Login_method::Password(Password {
            id: id.into(),
            password: password.into(),
            ..Default::default()
        });

        let token_response = self.login5_request(method).await?;
        let auth_token = Self::token_from_login(
            token_response.access_token,
            token_response.access_token_expires_in,
        );

        Ok((auth_token, token_response.stored_credential))
    }

    /// Retrieve the access_token via login5
    ///
    /// This request will only work when the store credentials match the client-id. Meaning that
    /// stored credentials generated with the keymaster client-id will not work, for example, with
    /// the android client-id.
    pub async fn auth_token(&self) -> Result<Token, Error> {
        let provider = self.lock(|inner| inner.token_provider.clone());
        if let Some(provider) = provider {
            // Never hold the component mutex over an asynchronous refresh.
            return provider.token().await;
        }
        let auth_data = self.session().auth_data();
        if auth_data.is_empty() {
            return Err(Login5Error::NoStoredCredentials.into());
        }

        let auth_token = self.lock(|inner| {
            if let Some(token) = &inner.auth_token {
                if token.is_expired() {
                    inner.auth_token = None;
                }
            }
            inner.auth_token.clone()
        });

        if let Some(auth_token) = auth_token {
            return Ok(auth_token);
        }

        let method = Login_method::StoredCredential(StoredCredential {
            username: self.session().username().to_string(),
            data: auth_data,
            ..Default::default()
        });

        let token_response = self.login5_request(method).await?;
        let auth_token = Self::token_from_login(
            token_response.access_token,
            token_response.access_token_expires_in,
        );

        let token = self.lock(|inner| {
            inner.auth_token = Some(auth_token.clone());
            inner.auth_token.clone()
        });

        trace!("Got auth token: {auth_token:?}");

        token.ok_or(Login5Error::NoStoredCredentials.into())
    }

    fn handle_challenges(
        login_request: &mut LoginRequest,
        message: LoginResponse,
    ) -> Result<(), Error> {
        let challenges = message.challenges();
        debug!(
            "Received {} challenges, solving...",
            challenges.challenges.len()
        );

        for challenge in &challenges.challenges {
            if challenge.has_code() {
                return Err(Login5Error::CodeChallenge.into());
            } else if !challenge.has_hashcash() {
                debug!("Challenge was empty, skipping...");
                continue;
            }

            let hash_cash_challenge = challenge.hashcash();

            let mut suffix = [0u8; 0x10];
            let duration = util::solve_hash_cash(
                &message.login_context,
                &hash_cash_challenge.prefix,
                hash_cash_challenge.length,
                &mut suffix,
            )?;

            let (seconds, nanos) = (duration.as_secs() as i64, duration.subsec_nanos() as i32);
            debug!("Solving hashcash took {seconds}s {nanos}ns");

            let mut solution = ChallengeSolution::new();
            solution.set_hashcash(HashcashSolution {
                suffix: Vec::from(suffix),
                duration: MessageField::some(ProtoDuration {
                    seconds,
                    nanos,
                    ..Default::default()
                }),
                ..Default::default()
            });

            login_request
                .challenge_solutions
                .mut_or_insert_default()
                .solutions
                .push(solution);
        }

        login_request.login_context = message.login_context;

        Ok(())
    }

    fn token_from_login(token: String, expires_in: i32) -> Token {
        Token {
            access_token: token,
            expires_in: Duration::from_secs(expires_in.try_into().unwrap_or(3600)),
            token_type: "Bearer".to_string(),
            scopes: vec![],
            timestamp: SystemTime::now(),
        }
    }
}

#[cfg(test)]
mod external_token_provider_tests {
    use super::*;
    use crate::{Session, error::ErrorKind};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::{Notify, oneshot};

    struct RotatingProvider {
        calls: AtomicUsize,
    }

    impl RotatingProvider {
        fn new() -> Self {
            Self {
                calls: AtomicUsize::new(0),
            }
        }
    }

    impl TokenProvider for RotatingProvider {
        fn token(&self) -> Pin<Box<dyn Future<Output = Result<Token, Error>> + Send + '_>> {
            Box::pin(async move {
                let revision = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
                Ok(Login5Manager::token_from_login(
                    format!("external-grant-{revision}"),
                    3600,
                ))
            })
        }
    }

    #[tokio::test]
    async fn external_token_works_without_access_point_credentials() {
        let session = Session::new(SessionConfig::default(), None);
        assert!(session.auth_data().is_empty());
        let provider = Arc::new(RotatingProvider::new());
        session.login5().set_token_provider(provider.clone());

        let token = tokio::time::timeout(Duration::from_secs(1), session.login5().auth_token())
            .await
            .expect("an external token must not wait for Spotify")
            .expect("external token should not require AP credentials");

        assert_eq!(token.access_token, "external-grant-1");
        assert_eq!(token.token_type, "Bearer");
        assert_eq!(provider.calls.load(Ordering::SeqCst), 1);
        assert!(session.auth_data().is_empty());
    }

    #[tokio::test]
    async fn external_provider_is_consulted_for_each_grant() {
        let session = Session::new(SessionConfig::default(), None);
        let manager = session.login5();
        manager.lock(|inner| {
            inner.auth_token = Some(Login5Manager::token_from_login(
                "previous-login5-token".to_owned(),
                3600,
            ));
        });
        let provider = Arc::new(RotatingProvider::new());
        manager.set_token_provider(provider.clone());
        assert!(manager.lock(|inner| inner.auth_token.is_none()));

        let first = manager.auth_token().await.unwrap();
        let refreshed = manager.auth_token().await.unwrap();

        assert_eq!(first.access_token, "external-grant-1");
        assert_eq!(refreshed.access_token, "external-grant-2");
        assert_eq!(provider.calls.load(Ordering::SeqCst), 2);
    }

    struct RejectedProvider;

    impl TokenProvider for RejectedProvider {
        fn token(&self) -> Pin<Box<dyn Future<Output = Result<Token, Error>> + Send + '_>> {
            Box::pin(async { Err(Error::unauthenticated("external grant revoked")) })
        }
    }

    #[tokio::test]
    async fn external_provider_errors_propagate_without_login5_fallback() {
        let session = Session::new(SessionConfig::default(), None);
        session
            .login5()
            .set_token_provider(Arc::new(RejectedProvider));

        let error = tokio::time::timeout(Duration::from_secs(1), session.login5().auth_token())
            .await
            .expect("a rejected external grant must not trigger a Login5 request")
            .unwrap_err();

        // Falling back would instead return NoStoredCredentials (Unavailable).
        assert_eq!(error.kind, ErrorKind::Unauthenticated);
        assert_eq!(error.error.to_string(), "external grant revoked");
    }

    struct PendingProvider {
        started: Notify,
        release: tokio::sync::Mutex<Option<oneshot::Receiver<()>>>,
    }

    impl TokenProvider for PendingProvider {
        fn token(&self) -> Pin<Box<dyn Future<Output = Result<Token, Error>> + Send + '_>> {
            Box::pin(async move {
                let release = self.release.lock().await.take().unwrap();
                self.started.notify_one();
                release.await.unwrap();
                Ok(Login5Manager::token_from_login(
                    "pending-external-grant".to_owned(),
                    3600,
                ))
            })
        }
    }

    #[tokio::test]
    async fn external_refresh_does_not_hold_the_component_mutex() {
        let session = Session::new(SessionConfig::default(), None);
        let manager = session.login5().clone();
        let (release, receiver) = oneshot::channel();
        let provider = Arc::new(PendingProvider {
            started: Notify::new(),
            release: tokio::sync::Mutex::new(Some(receiver)),
        });
        manager.set_token_provider(provider.clone());
        let task_manager = manager.clone();
        let pending = tokio::spawn(async move { task_manager.auth_token().await });
        tokio::time::timeout(Duration::from_secs(1), provider.started.notified())
            .await
            .expect("provider must start without blocking the component");

        // try_lock fails promptly if a regression retains the synchronous mutex.
        // Calling the setter directly in that case could prevent a timeout firing.
        drop(
            (manager.0)
                .1
                .try_lock()
                .expect("component mutex held across provider await"),
        );
        manager.set_token_provider(Arc::new(RotatingProvider::new()));
        release.send(()).unwrap();

        let token = tokio::time::timeout(Duration::from_secs(1), pending)
            .await
            .expect("refresh must finish after provider replacement")
            .unwrap()
            .unwrap();
        assert_eq!(token.access_token, "pending-external-grant");
        assert_eq!(
            manager.auth_token().await.unwrap().access_token,
            "external-grant-1"
        );
    }
}
