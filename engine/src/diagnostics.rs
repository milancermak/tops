//! Allowlisted connection metadata only. Never forward upstream log messages.
use librespot::core::{Error, http_client::HttpClientError};
use log::{Level, Log, Metadata, Record};
use serde::Serialize;
use std::{
    sync::{Arc, Mutex},
    time::Instant,
};

const MAX_REQUESTS: usize = 16;
const HTTP_TARGET: &str = "librespot_core::http_client";
static LOGGER: ConnectionLogger = ConnectionLogger(Mutex::new(None));

#[derive(Clone, Copy, Serialize)]
pub enum Stage {
    #[serde(rename = "client_token")]
    ClientToken,
    #[serde(rename = "playback_session")]
    PlaybackSession,
}

impl Stage {
    fn description(self) -> &'static str {
        match self {
            Self::ClientToken => "client authorization (clienttoken.spotify.com/v1/clienttoken)",
            Self::PlaybackSession => "playback session setup",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RequestMetadata {
    service: &'static str,
    elapsed_ms: u128,
}

struct Trace {
    started: Instant,
    requests: Vec<RequestMetadata>,
}

struct ConnectionLogger(Mutex<Option<Arc<Mutex<Trace>>>>);

// Return constants, never a substring of an upstream log. Even query parameters
// and unexpected URLs from this one target are discarded.
fn request_service(message: &str) -> Option<&'static str> {
    let uri = url::Url::parse(message.strip_prefix("Requesting ")?).ok()?;
    if uri.scheme() != "https" || !uri.username().is_empty() || uri.password().is_some() {
        return None;
    }
    match (uri.host_str()?, uri.path()) {
        ("clienttoken.spotify.com", "/v1/clienttoken") => {
            Some("clienttoken.spotify.com/v1/clienttoken")
        }
        ("apresolve.spotify.com", "/") => Some("apresolve.spotify.com"),
        ("login5.spotify.com", "/v3/login") => Some("login5.spotify.com/v3/login"),
        _ => None,
    }
}

impl Log for ConnectionLogger {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.target() == HTTP_TARGET && metadata.level() == Level::Debug
    }

    fn log(&self, record: &Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let active = self.0.lock().unwrap().clone();
        let Some(active) = active else { return };
        let Some(service) = request_service(&record.args().to_string()) else {
            return;
        };
        let mut trace = active.lock().unwrap();
        let elapsed_ms = trace.started.elapsed().as_millis();
        if trace.requests.len() == MAX_REQUESTS {
            trace.requests.remove(0);
        }
        trace.requests.push(RequestMetadata {
            service,
            elapsed_ms,
        });
    }

    fn flush(&self) {}
}

pub fn install() -> Result<(), log::SetLoggerError> {
    log::set_logger(&LOGGER)?;
    log::set_max_level(log::LevelFilter::Off);
    Ok(())
}

pub struct Attempt {
    trace: Arc<Mutex<Trace>>,
    started_at: u64,
    pub stage: Stage,
}

#[derive(Serialize)]
pub struct Report {
    schema_version: u8,
    started_at: u64,
    elapsed_ms: u128,
    stage: Stage,
    outcome: &'static str,
    http_status: Option<u16>,
    error_kind: Option<String>,
    // These requests were observed, not individually confirmed to have failed.
    recent_requests: Vec<RequestMetadata>,
}

impl Attempt {
    pub fn begin(started_at: u64) -> Self {
        let trace = Arc::new(Mutex::new(Trace {
            started: Instant::now(),
            requests: vec![],
        }));
        *LOGGER.0.lock().unwrap() = Some(trace.clone());
        log::set_max_level(log::LevelFilter::Debug);
        Self {
            trace,
            started_at,
            stage: Stage::ClientToken,
        }
    }

    pub fn report(&self, error: Option<&Error>, timed_out: bool) -> Report {
        let trace = self.trace.lock().unwrap();
        let http_status = error.and_then(|error| {
            error
                .error
                .downcast_ref::<HttpClientError>()
                .map(|error| match error {
                    HttpClientError::StatusCode(status) => status.as_u16(),
                })
        });
        Report {
            schema_version: 1,
            started_at: self.started_at,
            elapsed_ms: trace.started.elapsed().as_millis(),
            stage: self.stage,
            outcome: if timed_out {
                "timeout"
            } else if error.is_some() {
                "failed"
            } else {
                "connected"
            },
            http_status,
            // Only the upstream error kind is safe; its payload may include secrets.
            error_kind: error.map(|error| error.kind.to_string()),
            recent_requests: trace.requests.clone(),
        }
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        let mut active = LOGGER.0.lock().unwrap();
        if active
            .as_ref()
            .is_some_and(|trace| Arc::ptr_eq(trace, &self.trace))
        {
            *active = None;
            log::set_max_level(log::LevelFilter::Off);
        }
    }
}

impl Report {
    pub fn failure_message(&self) -> String {
        let reason = if self.outcome == "timeout" {
            "timed out".to_owned()
        } else if let Some(status) = self.http_status {
            format!("HTTP {status}")
        } else {
            self.error_kind
                .clone()
                .unwrap_or_else(|| "unknown error".to_owned())
        };
        let mut message = format!("Spotify {} failed: {reason}.", self.stage.description());
        if matches!(self.stage, Stage::PlaybackSession) && !self.recent_requests.is_empty() {
            let services: Vec<_> = self
                .recent_requests
                .iter()
                .map(|request| request.service)
                .collect();
            message.push_str(&format!(" Recent requests: {}.", services.join(", ")));
        }
        message
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local_attempt() -> Attempt {
        Attempt {
            trace: Arc::new(Mutex::new(Trace {
                started: Instant::now(),
                requests: vec![],
            })),
            started_at: 123,
            stage: Stage::ClientToken,
        }
    }

    fn emit(logger: &ConnectionLogger, target: &str, level: Level, message: &str) {
        logger.log(
            &Record::builder()
                .target(target)
                .level(level)
                .args(format_args!("{message}"))
                .build(),
        );
    }

    #[test]
    fn logger_filters_records_bounds_history_and_discards_query_secrets() {
        let attempt = local_attempt();
        let logger = ConnectionLogger(Mutex::new(Some(attempt.trace.clone())));
        for (target, level, message) in [
            (
                "librespot_core::login5",
                Level::Debug,
                "Requesting https://login5.spotify.com/v3/login",
            ),
            (
                HTTP_TARGET,
                Level::Info,
                "Requesting https://login5.spotify.com/v3/login",
            ),
            (HTTP_TARGET, Level::Debug, "Authorization: Bearer secret"),
            (
                HTTP_TARGET,
                Level::Debug,
                "Requesting https://unknown.test/secret",
            ),
        ] {
            emit(&logger, target, level, message);
        }
        assert!(attempt.report(None, false).recent_requests.is_empty());
        emit(
            &logger,
            HTTP_TARGET,
            Level::Debug,
            "Requesting https://apresolve.spotify.com/?secret",
        );
        for _ in 0..MAX_REQUESTS {
            emit(
                &logger,
                HTTP_TARGET,
                Level::Debug,
                "Requesting https://login5.spotify.com/v3/login?access_token=secret",
            );
        }
        let report = attempt.report(None, false);
        assert_eq!(report.recent_requests.len(), MAX_REQUESTS);
        assert!(
            report
                .recent_requests
                .iter()
                .all(|request| request.service == "login5.spotify.com/v3/login")
        );
        assert!(!serde_json::to_string(&report).unwrap().contains("secret"));
    }

    #[test]
    fn dropped_attempt_stops_capture_without_clearing_a_newer_attempt() {
        let first = Attempt::begin(1);
        let second = Attempt::begin(2);
        drop(first);
        emit(
            &LOGGER,
            HTTP_TARGET,
            Level::Debug,
            "Requesting https://apresolve.spotify.com/",
        );
        let trace = second.trace.clone();
        assert_eq!(trace.lock().unwrap().requests.len(), 1);
        drop(second);
        emit(
            &LOGGER,
            HTTP_TARGET,
            Level::Debug,
            "Requesting https://login5.spotify.com/v3/login",
        );
        assert_eq!(trace.lock().unwrap().requests.len(), 1);
        assert!(LOGGER.0.lock().unwrap().is_none());
    }

    #[test]
    fn only_known_services_survive_untrusted_log_content() {
        assert_eq!(
            request_service("Requesting https://login5.spotify.com/v3/login?access_token=secret"),
            Some("login5.spotify.com/v3/login")
        );
        for message in [
            "token: secret",
            "Requesting https://evil.test/?secret",
            "Requesting https://login5.spotify.com.evil.test/v3/login",
            "Requesting https://secret@login5.spotify.com/v3/login",
            "Requesting https://login5.spotify.com/v3/secret",
            "Requesting http://login5.spotify.com/v3/login",
        ] {
            assert_eq!(request_service(message), None);
        }
    }

    #[test]
    fn diagnostic_reports_503_without_serializing_error_payloads() {
        let attempt = local_attempt();
        let error: Error = HttpClientError::StatusCode(503.try_into().unwrap()).into();
        let report = attempt.report(Some(&error), false);
        assert_eq!(report.http_status, Some(503));
        assert_eq!(
            report.failure_message(),
            "Spotify client authorization (clienttoken.spotify.com/v1/clienttoken) failed: HTTP 503."
        );
        let error = Error::unavailable("access_token=secret refresh_token=secret username=private");
        let report = attempt.report(Some(&error), false);
        let serialized = serde_json::to_string(&report).unwrap();
        assert!(!serialized.contains("secret"));
        assert!(!serialized.contains("private"));
        assert!(!report.failure_message().contains("secret"));
        assert_eq!(attempt.report(None, true).outcome, "timeout");
        assert_eq!(attempt.report(None, false).outcome, "connected");
    }
}
