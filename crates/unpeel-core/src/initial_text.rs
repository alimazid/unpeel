//! Typing a new Session's initial text: the Host-side half of
//! `session.create`'s `initialText`, and the helper a Host-internal caller
//! (the scheduler) uses directly, with no Controller principal.

use std::path::Path;
use std::time::{Duration, Instant};

use crate::agent_readiness::{ReadinessSignal, ReadinessWait};
use crate::session_ops::InitialTextSubmitMode;

/// The most text one create may type (`session.create` refuses more).
pub const MAX_INITIAL_TEXT_BYTES: usize = 256 * 1024;
/// How long the Session's control socket may take to appear.
const HOST_ATTACH_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a launched agent may take to show its first readiness signal.
const AGENT_READY_TIMEOUT: Duration = Duration::from_secs(120);
/// Test Hosts (`UNPEEL_TEST=1`) may shorten the readiness wait so a never-
/// ready agent can be exercised without a two-minute case.
const AGENT_READY_TIMEOUT_OVERRIDE_ENV: &str = "UNPEEL_AGENT_READY_TIMEOUT_MS";
/// Per-Session record of the last initial-text delivery.
const OUTCOME_MARKER: &str = "initial-text.json";

/// When to type the text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitialTextWhen {
    /// As soon as the Session's control socket exists (the shipped behavior).
    Attached,
    /// After the agent's first readiness signal (`crate::agent_readiness`).
    AgentReady,
}

impl InitialTextWhen {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Attached => "attached",
            Self::AgentReady => "agent_ready",
        }
    }
}

/// What happened to the text. Only `Delivered` typed anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InitialTextOutcome {
    /// Typed; `signal` names the readiness tier that released an
    /// `AgentReady` wait.
    Delivered {
        signal: Option<ReadinessSignal>,
    },
    /// The Session's control socket never appeared.
    HostNotReady(String),
    /// No readiness signal arrived in time; nothing was typed.
    ReadinessTimeout,
    /// The Session exited before it became ready; nothing was typed.
    Exited,
    DeliveryFailed(String),
}

impl InitialTextOutcome {
    pub fn typed(&self) -> bool {
        matches!(self, Self::Delivered { .. })
    }

    fn state(&self) -> &'static str {
        match self {
            Self::Delivered { .. } => "delivered",
            Self::HostNotReady(_) => "host_not_ready",
            Self::ReadinessTimeout => "readiness_timeout",
            Self::Exited => "exited",
            Self::DeliveryFailed(_) => "delivery_failed",
        }
    }

    fn error(&self) -> Option<&str> {
        match self {
            Self::HostNotReady(error) | Self::DeliveryFailed(error) => Some(error),
            _ => None,
        }
    }
}

/// Type `text` into a freshly created Session once `when` allows, blocking
/// the calling thread (up to the readiness timeout), and record the outcome
/// in the Session's `initial-text.json` for whoever started it. Empty text
/// types nothing and records nothing, as it always has.
pub fn deliver(
    session_id: &str,
    text: &str,
    mode: InitialTextSubmitMode,
    when: InitialTextWhen,
) -> InitialTextOutcome {
    if text.is_empty() {
        return InitialTextOutcome::Delivered { signal: None };
    }
    deliver_with(session_id, when, text.len(), || {
        crate::session_ops::deliver_initial_text(session_id, text, mode)
    })
}

/// Type `prompt` into a freshly launched agent once it is ready, the way
/// Unpeel types every prompt into an agent (`session_input::deliver_prompt`:
/// one bracketed paste, a settle, then Enter), so several lines arrive as
/// one submission. Same budget and `initial-text.json` record as
/// [`deliver`] with [`InitialTextWhen::AgentReady`]; also returns the
/// wall-clock ms typing began, the moment the agent's turn can start.
pub fn prompt_when_ready(session_id: &str, prompt: &str) -> (InitialTextOutcome, Option<u64>) {
    let mut typed_at = None;
    let outcome = deliver_with(
        session_id,
        InitialTextWhen::AgentReady,
        prompt.len(),
        || {
            typed_at = Some(crate::state::current_timestamp_ms());
            crate::session_input::deliver_prompt(session_id, prompt)
        },
    );
    let typed_at = typed_at.filter(|_| outcome.typed());
    (outcome, typed_at)
}

/// Wait for a freshly launched agent's first readiness signal within the
/// same budget, typing nothing and recording nothing.
pub fn wait_for_agent(session_id: &str) -> ReadinessWait {
    crate::agent_readiness::wait_for_agent_ready(session_id, Instant::now() + agent_ready_timeout())
}

/// The cap, the one readiness budget, the wait `when` asks for, `type_text`,
/// and the recorded outcome.
fn deliver_with(
    session_id: &str,
    when: InitialTextWhen,
    len: usize,
    type_text: impl FnOnce() -> Result<(), String>,
) -> InitialTextOutcome {
    if len > MAX_INITIAL_TEXT_BYTES {
        return InitialTextOutcome::DeliveryFailed("initial text too large".into());
    }
    // One readiness budget from launch, covering the socket wait too.
    let ready_deadline = Instant::now() + agent_ready_timeout();
    let outcome = attach_then_type(session_id, when, ready_deadline, type_text);
    record(session_id, when, Some(&outcome));
    outcome
}

fn attach_then_type(
    session_id: &str,
    when: InitialTextWhen,
    ready_deadline: Instant,
    type_text: impl FnOnce() -> Result<(), String>,
) -> InitialTextOutcome {
    if let Err(error) = crate::session_host::wait_until_ready(session_id, HOST_ATTACH_TIMEOUT) {
        return InitialTextOutcome::HostNotReady(error);
    }
    let signal = match when {
        InitialTextWhen::Attached => None,
        InitialTextWhen::AgentReady => {
            record(session_id, when, None);
            match crate::agent_readiness::wait_for_agent_ready(session_id, ready_deadline) {
                ReadinessWait::Ready(signal) => Some(signal),
                ReadinessWait::TimedOut => return InitialTextOutcome::ReadinessTimeout,
                ReadinessWait::Exited => return InitialTextOutcome::Exited,
            }
        }
    };
    match type_text() {
        Ok(()) => InitialTextOutcome::Delivered { signal },
        Err(error) => InitialTextOutcome::DeliveryFailed(error),
    }
}

fn agent_ready_timeout() -> Duration {
    agent_ready_timeout_from(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var(AGENT_READY_TIMEOUT_OVERRIDE_ENV)
            .ok()
            .as_deref(),
    )
}

fn agent_ready_timeout_from(test_host: Option<&str>, override_ms: Option<&str>) -> Duration {
    override_ms
        .filter(|_| test_host == Some("1"))
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(AGENT_READY_TIMEOUT)
}

/// Best-effort: a Session removed mid-wait has no directory to record into,
/// and a failed write must not change what was (or wasn't) typed.
fn record(session_id: &str, when: InitialTextWhen, outcome: Option<&InitialTextOutcome>) {
    let dir = crate::session_host::session_dir(session_id);
    match record_in(&dir, when, outcome, crate::state::current_timestamp_ms()) {
        Ok(()) => crate::state_bus::announce(crate::state_bus::Change::SessionMarkers, None),
        Err(error) => {
            log::warn!("session {session_id} initial-text outcome not recorded: {error}")
        }
    }
}

/// Atomically replace `initial-text.json` in an existing Session directory.
/// `outcome: None` records a wait in progress.
fn record_in(
    session_dir: &Path,
    when: InitialTextWhen,
    outcome: Option<&InitialTextOutcome>,
    at_ms: u64,
) -> Result<(), String> {
    if !session_dir.is_dir() {
        return Err(format!("no session dir {}", session_dir.display()));
    }
    let mut body = serde_json::json!({
        "when": when.as_str(),
        "state": outcome.map_or("waiting", InitialTextOutcome::state),
        "at": at_ms,
    });
    if let Some(InitialTextOutcome::Delivered {
        signal: Some(signal),
    }) = outcome
    {
        body["signal"] = signal.as_str().into();
    }
    if let Some(error) = outcome.and_then(InitialTextOutcome::error) {
        body["error"] = error.into();
    }
    let bytes = serde_json::to_vec(&body).map_err(|error| error.to_string())?;
    let tmp = session_dir.join(format!(".{OUTCOME_MARKER}.tmp"));
    std::fs::write(&tmp, bytes).map_err(|error| error.to_string())?;
    std::fs::rename(&tmp, session_dir.join(OUTCOME_MARKER)).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests;
