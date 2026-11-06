//! Fork-only: the Host side of the Super Agent. The workspace worker owns
//! one [`Supervisor`] and calls it from a few one-line `// Fork-only` hunks in
//! `driver.rs`: every accepted hook event, every lifecycle edge before it
//! becomes a user notification, once per rescan, and before the auto-stop
//! sweep. Until a Router exists every method leaves the worker's behavior
//! exactly as it was.

use std::borrow::Cow;
use std::time::{SystemTime, UNIX_EPOCH};

use unpeel_core::activity_log::ActivityLogKind;

use crate::sessions::{SessionRow, SidebarModel};

mod inbox_drain;
mod inbox_rules;
mod notices;
mod watchdog;
mod worker_alerts;
mod worker_host;

pub use inbox_drain::{Notice, NoticeKind};

#[derive(Debug, Default)]
pub struct Supervisor {
    /// Pastes queued Inbox items into idle targets (`inbox_drain.rs`).
    inbox: inbox_drain::Drain,
    /// Worker edges and the watchdog, for the Router (`worker_alerts.rs`).
    workers: worker_alerts::WorkerAlerts,
}

impl Supervisor {
    /// One accepted hook event for `session_id` (canonical name, as
    /// `activity::normalize_event_name` returns it), received at `at_ms`.
    pub fn observe_hook(&mut self, session_id: &str, canonical_event: &str, at_ms: u64) {
        self.inbox.observe_hook(session_id, canonical_event, at_ms);
        self.workers
            .observe_hook(session_id, canonical_event, at_ms);
    }

    /// Where a lifecycle edge of `row` about to notify the user goes. A
    /// Worker's is taken for its Router ([`EdgeRoute::Router`]). `body` is
    /// the finished snippet, already taken.
    pub fn route_edge(
        &mut self,
        row: &SessionRow,
        kind: ActivityLogKind,
        body: Option<&str>,
        now_ms: u64,
    ) -> EdgeRoute {
        let diverted = self.workers.divert(row, kind, body, now_ms, &self.inbox);
        edge_route(diverted, row)
    }

    /// Once per rescan, after the keep-limit sweep: Worker notices and the
    /// watchdog, then the Inbox drain. Returns notifications for the user
    /// (an unanswered Worker prompt, a draft holding queued items).
    pub fn step(&mut self, model: &SidebarModel, now_ms: u64) -> Vec<Notice> {
        // Removed Workers' merged, clean worktrees (throttled, off-thread).
        unpeel_core::supervision_worktrees::sweep_in_background(now_ms);
        let mut notices = self.workers.step(&model.rows, now_ms);
        notices.extend(self.inbox.step(&model.rows, now_ms));
        notices
    }

    /// The rows the auto-stop sweep may consider: never the Router, its
    /// running Workers, or a Session with queued Inbox items.
    pub fn auto_stop_rows<'a>(&self, rows: &'a [SessionRow]) -> Cow<'a, [SessionRow]> {
        self.workers.auto_stop_rows(rows, &self.inbox)
    }
}

/// Where the worker delivers one lifecycle edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeRoute {
    /// Taken for the Router: the worker sends no notification and marks the
    /// row read, so an unread Worker never pins itself in the sidebar.
    Router,
    /// The user's, as upstream. The Router's own turns notify even when
    /// "notify when done" is off (§16.3).
    User { requires_notify_when_done: bool },
}

fn edge_route(diverted: bool, row: &SessionRow) -> EdgeRoute {
    if diverted {
        return EdgeRoute::Router;
    }
    EdgeRoute::User {
        requires_notify_when_done: !row.is_router,
    }
}

/// `rows` with `is_router` set from this workspace's Router mark (read
/// once), for row builders that cannot carry it themselves.
pub fn with_router_marked(rows: Vec<SessionRow>) -> Vec<SessionRow> {
    let router_id = unpeel_core::supervision::router_id();
    rows.into_iter()
        .map(|row| SessionRow {
            is_router: router_id.as_deref() == Some(row.id.as_str()),
            ..row
        })
        .collect()
}

/// Whether each row in `stopped` (indices into `rows`, display order) is
/// inside a keep window of `window` rows. The user's stopped rows rank
/// first, then Workers, each in display order, so Workers expire first. The
/// Router is exempt, like a pinned row: it is always kept and takes no slot,
/// since removing it would silently free its Workers (§8d).
pub fn stopped_in_keep_window(rows: &[SessionRow], stopped: &[usize], window: usize) -> Vec<bool> {
    let ranked = |index: &&usize| !rows[**index].is_router;
    let users = stopped
        .iter()
        .filter(ranked)
        .filter(|&&index| !rows[index].is_worker)
        .count();
    stopped
        .iter()
        .scan((0, users), |(next_user, next_worker), &index| {
            let row = &rows[index];
            if row.is_router {
                return Some(true);
            }
            let next = if row.is_worker {
                next_worker
            } else {
                next_user
            };
            let rank = *next;
            *next += 1;
            Some(rank < window)
        })
        .collect()
}

/// A hook receipt in unix ms.
pub fn unix_ms(at: SystemTime) -> u64 {
    at.duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, is_router: bool) -> SessionRow {
        SessionRow {
            host_started_at: None,
            id: id.into(),
            project_id: "p".into(),
            label: id.into(),
            command: "claude".into(),
            active_runtime_id: None,
            active_app: None,
            resume_available: false,
            resumable: true,
            resume_agent_available: false,
            running: true,
            status: crate::sessions::Status::Idle,
            status_source: crate::sessions::StatusSource::None,
            program_status: None,
            created_at: 1,
            pinned: false,
            unread: false,
            latest_alert_body: None,
            cwd: "/tmp".into(),
            activity_at: 1,
            group_id: "p".into(),
            detected_local_urls: Vec::new(),
            spawned_by: None,
            is_worker: false,
            is_router,
        }
    }

    #[test]
    fn the_routers_own_turn_always_notifies_the_user() {
        // §16.3: not gated on notify-when-done.
        assert_eq!(
            edge_route(false, &row("router", true)),
            EdgeRoute::User {
                requires_notify_when_done: false
            }
        );
        // Everyone else keeps upstream's rule.
        assert_eq!(
            edge_route(false, &row("user", false)),
            EdgeRoute::User {
                requires_notify_when_done: true
            }
        );
        // A Worker's edge taken for its Router never reaches the user.
        assert_eq!(edge_route(true, &row("worker", false)), EdgeRoute::Router);
    }
}
