//! Run Sessions in a Project's listings (Scheduled Tasks, Q32).
//!
//! A Project lists only each task's latest Run Session: the Session of the
//! task's current Run ([`super::current_run`], the one rule the worker, Run
//! now, the clock and the `schedules` routes share). Every other Run Session
//! of the task is *superseded*. Hosts publish both facts on the Session's row
//! (`scheduleID`, `superseded`), and every Controller listing hides a
//! superseded row from that one field while the row stays openable by id
//! (the SCHEDULED section's Runs open it).
//!
//! A pinned Run is never superseded: the user kept it there, as Run
//! retention and the next Run's stop both leave it alone. Nor is an older
//! Run that is live and busy or waiting on the user, while it is: the next
//! Run's stop leaves it live too, and hiding it would hide the follow-up the
//! user is in (or the question it asks). A task with no Run
//! log (deleted, or not run yet) supersedes nothing, so its Run Sessions stay
//! listed rather than vanish with the task.

use std::collections::HashMap;

use serde_json::Value;

use super::SPAWNED_BY_PREFIX;

/// Each task's latest Run Session, by task id: the Session of its current
/// Run, or `None` when that Run has none (it failed to start). A task with
/// no Run log is absent.
pub type LatestRunSessions = HashMap<String, Option<String>>;

/// One Session row, as far as a Project's listing of Runs needs it.
#[derive(Debug, Clone, Copy)]
pub struct RunSessionRow<'a> {
    pub session_id: &'a str,
    /// The manifest's `session.spawned_by`.
    pub spawned_by: Option<&'a str>,
    pub pinned: bool,
    /// The manifest's `session.created_at`, which Resume keeps.
    pub created_at: u64,
    /// Live and busy, or waiting on the user ([`is_engaged`]).
    pub engaged: bool,
}

/// Whether a published Session row is live and busy or waiting on the
/// user: the user may be following up in it, so it is never hidden.
pub fn is_engaged(summary: &Value) -> bool {
    summary.get("status").and_then(Value::as_str) == Some("running")
        && matches!(
            summary.get("activity").and_then(Value::as_str),
            Some("working" | "blocked")
        )
}

/// The task a Session is a Run of; `None` for every other Session.
pub fn schedule_id(spawned_by: Option<&str>) -> Option<&str> {
    spawned_by?
        .strip_prefix(SPAWNED_BY_PREFIX)
        .filter(|id| !id.is_empty())
}

/// The Host's rows' view of `logged` (each task's latest Run Session, from
/// its Run log). Runs never overlap, so the current Run's Session is the
/// task's newest; once it no longer exists, the task's newest Run Session
/// stands in. That is the logged Session itself after Resume, which replaces
/// a Session under a new id but keeps its `spawned_by` and `created_at`.
pub fn resolve_latest(logged: LatestRunSessions, rows: &[RunSessionRow<'_>]) -> LatestRunSessions {
    logged
        .into_iter()
        .map(|(task, session)| {
            let Some(session) = session else {
                return (task, None);
            };
            let runs = || {
                rows.iter()
                    .filter(|row| schedule_id(row.spawned_by) == Some(task.as_str()))
            };
            if runs().any(|row| row.session_id == session) {
                return (task, Some(session));
            }
            let newest = runs()
                .max_by(|left, right| {
                    left.created_at
                        .cmp(&right.created_at)
                        .then_with(|| right.session_id.cmp(left.session_id))
                })
                .map(|row| row.session_id.to_string());
            (task, newest.or(Some(session)))
        })
        .collect()
}

/// Whether a Project's listings hide this Session (see the module docs).
pub fn is_superseded(row: RunSessionRow<'_>, latest: &LatestRunSessions) -> bool {
    let Some(task) = schedule_id(row.spawned_by) else {
        return false;
    };
    !row.pinned
        && !row.engaged
        && latest
            .get(task)
            .is_some_and(|current| current.as_deref() != Some(row.session_id))
}

/// Publish a Run Session's facts on its wire row: `scheduleID` (what the
/// clock badge keys off) and `superseded`. Additive: older Controllers
/// ignore both. Any other Session's row is left as it is.
pub fn publish(summary: &mut Value, row: RunSessionRow<'_>, latest: &LatestRunSessions) {
    let Some(task) = schedule_id(row.spawned_by) else {
        return;
    };
    let superseded = is_superseded(row, latest);
    if let Some(object) = summary.as_object_mut() {
        object.insert("scheduleID".into(), task.into());
        object.insert("superseded".into(), superseded.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_row<'a>(session_id: &'a str, spawned_by: &'a str) -> RunSessionRow<'a> {
        RunSessionRow {
            session_id,
            spawned_by: Some(spawned_by),
            pinned: false,
            created_at: 1,
            engaged: false,
        }
    }

    fn created<'a>(row: RunSessionRow<'a>, created_at: u64) -> RunSessionRow<'a> {
        RunSessionRow { created_at, ..row }
    }

    fn latest(entries: &[(&str, Option<&str>)]) -> LatestRunSessions {
        entries
            .iter()
            .map(|(task, session)| (task.to_string(), session.map(str::to_string)))
            .collect()
    }

    #[test]
    fn a_run_session_names_its_task() {
        assert_eq!(schedule_id(Some("schedule:sch_1")), Some("sch_1"));
        assert_eq!(schedule_id(None), None, "the user's own Session");
        assert_eq!(schedule_id(Some("cli")), None);
        assert_eq!(schedule_id(Some("4f1c-agent-session")), None);
        assert_eq!(
            schedule_id(Some("schedule:")),
            None,
            "a prefix with no task"
        );
    }

    /// Q32: only the Session of the task's current Run stays listed; the
    /// task's other Runs are superseded, and other tasks are their own.
    #[test]
    fn every_run_session_but_the_current_runs_is_superseded() {
        let latest = latest(&[("sch_a", Some("a-3")), ("sch_b", Some("b-1"))]);
        assert!(!is_superseded(run_row("a-3", "schedule:sch_a"), &latest));
        assert!(is_superseded(run_row("a-2", "schedule:sch_a"), &latest));
        assert!(is_superseded(run_row("a-1", "schedule:sch_a"), &latest));
        assert!(!is_superseded(run_row("b-1", "schedule:sch_b"), &latest));
        let user = RunSessionRow {
            session_id: "user",
            spawned_by: None,
            pinned: false,
            created_at: 1,
            engaged: false,
        };
        assert!(!is_superseded(user, &latest), "the user's own Session");
        let agent = run_row("child", "4f1c-agent-session");
        assert!(!is_superseded(agent, &latest), "an agent's child Session");
    }

    /// A current Run that failed to start has no Session, so the task lists
    /// none of its earlier ones.
    #[test]
    fn a_current_run_without_a_session_supersedes_them_all() {
        let latest = latest(&[("sch_a", None)]);
        assert!(is_superseded(run_row("a-1", "schedule:sch_a"), &latest));
    }

    /// A task with no Run log (deleted, or not run yet) supersedes nothing.
    #[test]
    fn a_task_without_a_run_log_supersedes_nothing() {
        let latest = latest(&[("sch_other", Some("o-1"))]);
        assert!(!is_superseded(
            run_row("gone-1", "schedule:sch_gone"),
            &latest
        ));
        assert!(!is_superseded(
            run_row("gone-2", "schedule:sch_gone"),
            &latest
        ));
    }

    /// The logged Session is on the Host: it is the task's latest.
    #[test]
    fn the_logged_session_stays_the_latest_while_it_exists() {
        let rows = [
            created(run_row("a-2", "schedule:sch_a"), 20),
            created(run_row("a-1", "schedule:sch_a"), 10),
        ];
        let resolved = resolve_latest(latest(&[("sch_a", Some("a-2"))]), &rows);
        assert_eq!(resolved, latest(&[("sch_a", Some("a-2"))]));
    }

    /// Resume replaced the latest Run's Session under a new id (same
    /// `spawned_by` and `created_at`): the replacement is the latest, and
    /// the task's earlier Runs stay superseded.
    #[test]
    fn a_resumed_latest_run_stays_the_latest() {
        let rows = [
            created(run_row("a-1", "schedule:sch_a"), 10),
            created(run_row("a-2-resumed", "schedule:sch_a"), 20),
            created(run_row("b-1", "schedule:sch_b"), 30),
        ];
        let resolved = resolve_latest(
            latest(&[("sch_a", Some("a-2")), ("sch_b", Some("b-1"))]),
            &rows,
        );
        assert_eq!(
            resolved,
            latest(&[("sch_a", Some("a-2-resumed")), ("sch_b", Some("b-1"))])
        );
        assert!(!is_superseded(rows[1], &resolved));
        assert!(is_superseded(rows[0], &resolved));
    }

    /// A current Run without a Session, and a task without a Run log, are
    /// what the log says.
    #[test]
    fn resolving_keeps_a_sessionless_run_and_an_unlogged_task() {
        let rows = [created(run_row("a-1", "schedule:sch_a"), 10)];
        let resolved = resolve_latest(latest(&[("sch_a", None)]), &rows);
        assert_eq!(resolved, latest(&[("sch_a", None)]));
        let rows = [created(run_row("gone-1", "schedule:sch_gone"), 10)];
        assert!(resolve_latest(LatestRunSessions::new(), &rows).is_empty());
    }

    /// An older Run the user is following up in (live and busy) or that
    /// waits on them stays listed while it is, like a pinned one.
    #[test]
    fn a_live_older_run_that_is_busy_or_waiting_is_not_superseded() {
        let latest = latest(&[("sch_a", Some("a-3"))]);
        let engaged = RunSessionRow {
            engaged: true,
            ..run_row("a-1", "schedule:sch_a")
        };
        assert!(!is_superseded(engaged, &latest));
        assert!(is_superseded(run_row("a-2", "schedule:sch_a"), &latest));
    }

    #[test]
    fn a_session_is_engaged_while_it_runs_busy_or_waiting() {
        let summary = |status: &str, activity: &str| {
            serde_json::json!({ "status": status, "activity": activity })
        };
        assert!(is_engaged(&summary("running", "working")));
        assert!(is_engaged(&summary("running", "blocked")));
        for (status, activity) in [
            ("running", "idle"),
            ("running", "done"),
            ("running", "starting"),
            ("exited", "working"),
        ] {
            assert!(!is_engaged(&summary(status, activity)), "{status} {activity}");
        }
    }

    #[test]
    fn a_pinned_run_is_never_superseded() {
        let latest = latest(&[("sch_a", Some("a-3"))]);
        let pinned = RunSessionRow {
            pinned: true,
            ..run_row("a-1", "schedule:sch_a")
        };
        assert!(!is_superseded(pinned, &latest));
    }

    #[test]
    fn a_run_sessions_row_carries_its_task_and_whether_it_is_superseded() {
        let latest = latest(&[("sch_a", Some("a-2"))]);
        let mut older = serde_json::json!({"id": "a-1"});
        publish(&mut older, run_row("a-1", "schedule:sch_a"), &latest);
        assert_eq!(
            older,
            serde_json::json!({"id": "a-1", "scheduleID": "sch_a", "superseded": true})
        );
        let mut current = serde_json::json!({"id": "a-2"});
        publish(&mut current, run_row("a-2", "schedule:sch_a"), &latest);
        assert_eq!(
            current,
            serde_json::json!({"id": "a-2", "scheduleID": "sch_a", "superseded": false})
        );
    }

    #[test]
    fn any_other_sessions_row_is_left_as_it_is() {
        let latest = latest(&[("sch_a", Some("a-2"))]);
        let mut row = serde_json::json!({"id": "user"});
        let user = RunSessionRow {
            session_id: "user",
            spawned_by: None,
            pinned: false,
            created_at: 1,
            engaged: false,
        };
        publish(&mut row, user, &latest);
        assert_eq!(row, serde_json::json!({"id": "user"}));
    }
}
