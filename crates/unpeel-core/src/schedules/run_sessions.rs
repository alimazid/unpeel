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
//! retention and the next Run's stop both leave it alone. A task with no Run
//! log (deleted, or not run yet) supersedes nothing, so its Run Sessions stay
//! listed rather than vanish with the task.

use std::collections::HashMap;

use serde_json::Value;

use super::SPAWNED_BY_PREFIX;

/// Each task's latest Run Session, by task id: the Session of its current
/// Run, or `None` when that Run has none (it failed to start). A task with
/// no Run log is absent.
pub type LatestRunSessions = HashMap<String, Option<String>>;

/// One Session row, as far as Q32 needs it.
#[derive(Debug, Clone, Copy)]
pub struct RunSessionRow<'a> {
    pub session_id: &'a str,
    /// The manifest's `session.spawned_by`.
    pub spawned_by: Option<&'a str>,
    pub pinned: bool,
}

/// The task a Session is a Run of; `None` for every other Session.
pub fn schedule_id(spawned_by: Option<&str>) -> Option<&str> {
    spawned_by?
        .strip_prefix(SPAWNED_BY_PREFIX)
        .filter(|id| !id.is_empty())
}

/// Whether a Project's listings hide this Session (see the module docs).
pub fn is_superseded(row: RunSessionRow<'_>, latest: &LatestRunSessions) -> bool {
    let Some(task) = schedule_id(row.spawned_by) else {
        return false;
    };
    !row.pinned
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
        }
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
        };
        publish(&mut row, user, &latest);
        assert_eq!(row, serde_json::json!({"id": "user"}));
    }
}
