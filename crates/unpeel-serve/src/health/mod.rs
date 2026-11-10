//! Fork-only (#84): the Host's health check. No LLM: every
//! [`CHECK_INTERVAL_MS`] the workspace worker looks, after the sweep that
//! fires Scheduled Tasks, for
//!
//! 1. a task whose Run was recorded `failed`, `failed_to_start` or
//!    `skipped` since the last check;
//! 2. a task whose Run in progress has waited on a prompt, or whose Run
//!    reported `blocked` (#81), for [`RUN_WAITING_MS`];
//! 3. an enabled task whose next run passed [`MISSED_FIRE_MS`] ago without
//!    a Run starting;
//! 4. the workspace's Router Session not running (only when one is
//!    marked);
//! 5. a delivery due in the Router's Inbox for [`INBOX_UNDELIVERED_MS`].
//!
//! A new problem goes to the Router's Inbox as one Host report
//! (status `blocked`) and to the Mac as a notification (`Check::to_router`,
//! `Check::to_mac` say which); a notification no app is connected to show
//! is kept and shown when one connects. A problem alerts once, and again only
//! after it cleared and came back; the state is on disk (`state.rs`), so a
//! restart repeats nothing. The rules are `check.rs`; `host.rs` reads the
//! real home and queues the reports; the worker's delivery is
//! `driver/health.rs`.

pub mod check;
pub mod host;
pub mod state;

use std::path::PathBuf;

use unpeel_core::session_inbox::{ItemKind, NewItem, Priority, Sender};

pub use check::{Alert, Check, Facts};
use state::{HealthState, KeptNotice};

const MINUTE_MS: u64 = 60_000;
/// How often the check runs.
pub const CHECK_INTERVAL_MS: u64 = 5 * MINUTE_MS;
/// How long a Run may wait on a prompt, or stay blocked, before it alerts.
pub const RUN_WAITING_MS: u64 = 30 * MINUTE_MS;
/// How long after its next run a task alerts when no Run started.
pub const MISSED_FIRE_MS: u64 = 10 * MINUTE_MS;
/// How long a delivery may be due in the Router's Inbox.
pub const INBOX_UNDELIVERED_MS: u64 = 15 * MINUTE_MS;
/// Test Hosts (`UNPEEL_TEST=1`) with this set to `1` read every minute
/// above as a second, like `UNPEEL_SUPERVISOR_SECONDS`.
const SECONDS_ENV: &str = "UNPEEL_HEALTH_SECONDS";
/// The status of every health report, so it wakes the Router.
pub const REPORT_STATUS: &str = "blocked";

/// The check's interval and limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub interval_ms: u64,
    pub run_waiting_ms: u64,
    pub missed_fire_ms: u64,
    pub inbox_undelivered_ms: u64,
    /// When the Inbox drain promotes ride-along items (#83).
    pub ride_along_promote_ms: u64,
}

impl Limits {
    /// This Host's: the constants, or seconds for minutes on a test Host.
    pub fn for_host() -> Self {
        Self::new(
            unpeel_core::supervision::seconds_mode_from(
                std::env::var("UNPEEL_TEST").ok().as_deref(),
                std::env::var(SECONDS_ENV).ok().as_deref(),
            ),
            crate::supervisor::ride_along_promote_ms(),
        )
    }

    pub fn new(seconds_mode: bool, ride_along_promote_ms: u64) -> Self {
        let scale = |ms: u64| if seconds_mode { ms / 60 } else { ms };
        Self {
            interval_ms: scale(CHECK_INTERVAL_MS),
            run_waiting_ms: scale(RUN_WAITING_MS),
            missed_fire_ms: scale(MISSED_FIRE_MS),
            inbox_undelivered_ms: scale(INBOX_UNDELIVERED_MS),
            ride_along_promote_ms,
        }
    }
}

/// The worker's health check: its limits and its state, saved on every
/// change.
pub struct HealthCheck {
    path: PathBuf,
    limits: Limits,
    state: HealthState,
}

impl Default for HealthCheck {
    fn default() -> Self {
        Self::at(state::state_path(), Limits::for_host())
    }
}

impl HealthCheck {
    pub fn at(path: PathBuf, limits: Limits) -> Self {
        let state = HealthState::load(&path);
        Self {
            path,
            limits,
            state,
        }
    }

    /// Whether a check is due at `now`: the first one, an interval after
    /// the last (on the wall clock, so a restart or a sleep keeps the
    /// pace), or after the clock went back.
    pub fn due(&self, now: u64) -> bool {
        self.state
            .last_check_ms
            .is_none_or(|at| now < at || now - at >= self.limits.interval_ms)
    }

    /// One check: the problems to alert about now.
    pub fn run(&mut self, facts: &Facts, now: u64) -> Vec<Alert> {
        let (state, alerts) = check::check(facts, &self.state, &self.limits, now);
        self.replace(state);
        alerts
    }

    /// Keep a Mac notification until an app connects.
    pub fn keep(&mut self, notice: KeptNotice) {
        let state = self.state.clone().keeping(notice);
        self.replace(state);
    }

    pub fn has_kept(&self) -> bool {
        !self.state.kept.is_empty()
    }

    /// The kept notifications, oldest first, no longer kept.
    pub fn take_kept(&mut self) -> Vec<KeptNotice> {
        let kept = self.state.kept.clone();
        self.replace(HealthState {
            kept: Vec::new(),
            ..self.state.clone()
        });
        kept
    }

    fn replace(&mut self, state: HealthState) {
        if state == self.state {
            return;
        }
        if let Err(error) = state.save(&self.path) {
            crate::tracelog::trace("health", &format!("state not saved: {error}"));
        }
        self.state = state;
    }
}

impl Alert {
    /// The alert as a Mac notification, kept or shown now.
    pub fn notice(&self, at: u64) -> KeptNotice {
        KeptNotice {
            problem: Some(self.key.clone()),
            session_id: self.session_id.clone().unwrap_or_default(),
            schedule_id: self.schedule_id.clone(),
            title: self.title.clone(),
            body: self.text.clone(),
            at,
        }
    }

    /// The alert as a Host report in the Router's Inbox: one item per
    /// episode of the problem, `about` its task or Session.
    pub fn report(&self) -> NewItem {
        NewItem {
            sender: Sender::Host,
            kind: ItemKind::Report,
            priority: Priority::Wake,
            about: self.schedule_id.clone().or_else(|| self.session_id.clone()),
            status: Some(REPORT_STATUS.to_owned()),
            label: Some(self.title.clone()),
            summary: self.text.clone(),
            body: String::new(),
            dedupe_key: Some(format!("health:{}:{}", self.key, self.since)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> Limits {
        Limits::new(false, 15 * MINUTE_MS)
    }

    #[test]
    fn seconds_mode_counts_minute_limits_as_seconds() {
        let seconds = Limits::new(true, 6_000);
        assert_eq!(
            (
                seconds.interval_ms,
                seconds.run_waiting_ms,
                seconds.missed_fire_ms,
                seconds.inbox_undelivered_ms,
                seconds.ride_along_promote_ms,
            ),
            (5_000, 30_000, 10_000, 15_000, 6_000)
        );
        assert_eq!(limits().interval_ms, 300_000);
    }

    #[test]
    fn a_check_is_due_first_then_every_interval_on_the_wall_clock() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let mut health = HealthCheck::at(path.clone(), limits());
        assert!(health.due(1_000_000));
        health.run(&Facts::default(), 1_000_000);
        assert!(!health.due(1_000_000 + CHECK_INTERVAL_MS - 1));
        assert!(health.due(1_000_000 + CHECK_INTERVAL_MS));
        // A clock that went back runs it again rather than waiting.
        assert!(health.due(999_999));
        // The pace survives a restart.
        let restarted = HealthCheck::at(path, limits());
        assert!(!restarted.due(1_000_000 + 1));
    }

    #[test]
    fn kept_notices_are_saved_and_taken_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let mut health = HealthCheck::at(path.clone(), limits());
        let alert = Alert {
            key: "missed:sch_1:5".into(),
            check: Check::MissedFire,
            since: 5,
            schedule_id: Some("sch_1".into()),
            session_id: None,
            title: "Morning report".into(),
            text: "Health check: …".into(),
        };
        health.keep(Alert::notice(&alert, 9));
        assert!(HealthCheck::at(path.clone(), limits()).has_kept());
        let taken = health.take_kept();
        assert_eq!(taken.len(), 1);
        assert_eq!(taken[0].schedule_id.as_deref(), Some("sch_1"));
        assert_eq!(taken[0].session_id, "");
        assert!(!health.has_kept());
        assert!(!HealthCheck::at(path, limits()).has_kept());
    }

    #[test]
    fn a_report_wakes_the_router_once_per_episode() {
        let alert = Alert {
            key: "waiting:run_1".into(),
            check: Check::RunWaiting,
            since: 42,
            schedule_id: Some("sch_1".into()),
            session_id: Some("s-1".into()),
            title: "Morning report".into(),
            text: "Health check: Run run_1 …".into(),
        };
        let item = alert.report();
        assert_eq!(item.sender, Sender::Host);
        assert_eq!(item.kind, ItemKind::Report);
        assert_eq!(item.priority, Priority::Wake);
        assert_eq!(item.status.as_deref(), Some("blocked"));
        assert_eq!(item.about.as_deref(), Some("sch_1"));
        assert_eq!(item.dedupe_key.as_deref(), Some("health:waiting:run_1:42"));
        let down = Alert {
            key: "router_down:r".into(),
            schedule_id: None,
            session_id: Some("r".into()),
            ..alert
        };
        assert_eq!(down.report().about.as_deref(), Some("r"));
    }
}
