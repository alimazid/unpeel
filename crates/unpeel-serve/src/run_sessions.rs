//! Run Sessions after a Run (Scheduled Tasks). A Session whose
//! `spawned_by` is `schedule:<task id>` is one Run of that task.
//!
//! Run Sessions never count toward a Project's stopped-Session window
//! (`sessions::group_listing`), so a busy task cannot push the user's own
//! stopped Sessions out. Each task keeps its newest
//! [`RUN_SESSIONS_KEPT_PER_TASK`] stopped Runs instead; older ones join the
//! sidebar's `expired` list and the same retention sweep removes them
//! (`retention.rs`). Pinned Runs and the task's latest Run are never
//! expired, and a Session holding artifacts or managed storage is kept by
//! the removal itself; unread is no exemption for a Run, since every
//! finished Run is unread until someone looks. The rule keys off
//! `spawned_by` alone, so a deleted task's Runs keep it.

use std::collections::HashMap;

use crate::sessions::{SessionRow, Status};

/// Stopped Run Sessions a task keeps. The task's live latest Run
/// takes no slot.
pub const RUN_SESSIONS_KEPT_PER_TASK: usize = 5;

/// The task a Run Session belongs to; `None` for every other Session.
pub fn schedule_id(row: &SessionRow) -> Option<&str> {
    unpeel_core::schedules::run_sessions::schedule_id(row.spawned_by.as_deref())
}

/// The facts the superseded flag reads off a row (`unpeel_core::schedules::run_sessions`).
pub fn wire_row(row: &SessionRow) -> unpeel_core::schedules::run_sessions::RunSessionRow<'_> {
    unpeel_core::schedules::run_sessions::RunSessionRow {
        session_id: &row.id,
        spawned_by: row.spawned_by.as_deref(),
        pinned: row.pinned,
        created_at: row.created_at,
        engaged: row.running && matches!(row.status, Status::Busy | Status::Attention),
    }
}

pub fn is_run_session(row: &SessionRow) -> bool {
    schedule_id(row).is_some()
}

/// Stopped Run Sessions past their task's keep limit, bound for removal.
/// Pinned Runs take no slot and are never returned, and neither is the
/// task's latest Run (its newest Session; Runs never overlap). Unread does
/// not exempt a Run as it does the user's own stopped rows: every finished
/// Run is unread until someone looks, so it would defeat the limit.
pub fn expired_run_sessions(rows: &[SessionRow]) -> Vec<String> {
    let mut by_task: HashMap<&str, Vec<&SessionRow>> = HashMap::new();
    for row in rows {
        if let Some(task) = schedule_id(row) {
            by_task.entry(task).or_default().push(row);
        }
    }
    by_task
        .values()
        .flat_map(|runs| expired_runs_of_task(runs))
        .collect()
}

/// One task's Run Sessions past the keep limit.
fn expired_runs_of_task(runs: &[&SessionRow]) -> Vec<String> {
    let latest = runs
        .iter()
        .max_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| lifecycle(left).cmp(&lifecycle(right)))
                .then_with(|| left.id.cmp(&right.id))
        })
        .map(|row| row.id.as_str());
    let mut stopped: Vec<&SessionRow> = runs
        .iter()
        .copied()
        .filter(|row| !row.running && !row.pinned)
        .collect();
    // Newest first by the stopped window's own stamp.
    stopped.sort_by(|left, right| {
        lifecycle(right)
            .cmp(&lifecycle(left))
            .then_with(|| left.id.cmp(&right.id))
    });
    stopped
        .into_iter()
        .skip(RUN_SESSIONS_KEPT_PER_TASK)
        .filter(|row| Some(row.id.as_str()) != latest)
        .map(|row| row.id.clone())
        .collect()
}

/// A task's latest Run Session stays live so the user can follow up; once
/// the Session `new_session_id` of the next Run has started (never before:
/// a failed start leaves the previous Run as it is), the task's earlier Run
/// Sessions that sit idle are stopped (they stay as stopped rows). One
/// that is busy with a follow-up, waits on the user, is still starting, or
/// is pinned stays live; auto-stop still applies to it.
pub fn superseded_run_sessions(
    rows: &[SessionRow],
    task: &str,
    new_session_id: &str,
) -> Vec<String> {
    rows.iter()
        .filter(|row| schedule_id(row) == Some(task) && row.id != new_session_id)
        .filter(|row| row.running && row.status == Status::Idle && !row.pinned)
        .map(|row| row.id.clone())
        .collect()
}

/// Stop `rows`' Run Sessions that the Run in `new_session_id` supersedes,
/// each through the pid-verified stop path on its own helper thread (a stop
/// waits for the exited manifest). The outcome goes to the trace log, the
/// app-launched service's only output.
pub fn stop_superseded(rows: &[SessionRow], task: &str, new_session_id: &str) {
    for session_id in superseded_run_sessions(rows, task, new_session_id) {
        let owner = task.to_string();
        let spawned = std::thread::Builder::new()
            .name("unpeel-schedules-stop".into())
            .spawn(move || {
                let message = match unpeel_core::session_ops::stop_session(&session_id) {
                    Ok(()) => format!("schedule {owner}: stopped earlier Run session {session_id}"),
                    Err(error) => format!(
                        "schedule {owner}: stopping earlier Run session {session_id} failed: {error}"
                    ),
                };
                crate::tracelog::trace("host-worker", &message);
            });
        if let Err(error) = spawned {
            crate::tracelog::trace(
                "host-worker",
                &format!("schedule {task}: no thread to stop an earlier Run session: {error}"),
            );
        }
    }
}

fn lifecycle(row: &SessionRow) -> u64 {
    row.created_at.max(row.activity_at)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::StatusSource;

    /// A Session started at `stamp`: a Run of `task`, or the user's own.
    fn row(id: &str, task: Option<&str>, running: bool, stamp: u64) -> SessionRow {
        SessionRow {
            id: id.into(),
            host_started_at: None,
            project_id: "p".into(),
            label: id.into(),
            command: "true".into(),
            active_runtime_id: None,
            active_app: None,
            resume_available: !running,
            resumable: false,
            resume_agent_available: false,
            running,
            status: if running {
                Status::Idle
            } else {
                Status::Exited
            },
            status_source: StatusSource::None,
            program_status: None,
            created_at: stamp,
            pinned: false,
            unread: false,
            latest_alert_body: None,
            cwd: "/tmp".into(),
            activity_at: stamp,
            group_id: "p".into(),
            detected_local_urls: Vec::new(),
            spawned_by: task.map(|task| format!("schedule:{task}")),
            is_worker: false,
            is_router: false,
        }
    }

    fn sorted(mut ids: Vec<String>) -> Vec<String> {
        ids.sort();
        ids
    }

    #[test]
    fn a_run_session_names_its_task() {
        assert_eq!(
            schedule_id(&row("r", Some("sch_1"), false, 1)),
            Some("sch_1")
        );
        assert_eq!(schedule_id(&row("u", None, false, 1)), None);
        let mut agent = row("a", None, false, 1);
        agent.spawned_by = Some("4f1c-session".into());
        assert!(!is_run_session(&agent));
        agent.spawned_by = Some("schedule:".into());
        assert!(!is_run_session(&agent), "a prefix with no task is no Run");
    }

    /// Each task keeps its newest five stopped Run Sessions; its live
    /// latest Run takes no slot, and the user's own Sessions are not Runs.
    #[test]
    fn each_task_keeps_its_newest_five_stopped_runs() {
        let mut rows: Vec<SessionRow> = (1..=7)
            .map(|n| row(&format!("a-{n}"), Some("sch_a"), false, n))
            .collect();
        rows.push(row("a-live", Some("sch_a"), true, 8));
        rows.extend((1..=3).map(|n| row(&format!("b-{n}"), Some("sch_b"), false, n)));
        rows.extend((1..=9).map(|n| row(&format!("user-{n}"), None, false, n)));

        assert_eq!(sorted(expired_run_sessions(&rows)), ["a-1", "a-2"]);
    }

    /// A pinned Run is never removed and takes no slot. Unread does not
    /// exempt a Run: every finished Run is unread until someone looks, so
    /// it would defeat the limit.
    #[test]
    fn pinned_runs_are_never_expired_and_unread_ones_are() {
        let mut rows: Vec<SessionRow> = (1..=8)
            .map(|n| row(&format!("a-{n}"), Some("sch_a"), false, n))
            .collect();
        rows[7].pinned = true; // a-8
        rows[0].pinned = true; // a-1
        for row in &mut rows {
            row.unread = true;
        }

        // Unpinned: a-2..a-7; the newest five are a-3..a-7.
        assert_eq!(expired_run_sessions(&rows), ["a-2"]);

        rows[0].pinned = false;
        assert_eq!(
            sorted(expired_run_sessions(&rows)),
            ["a-1", "a-2"],
            "unpinned, a-1 is past five too"
        );
    }

    /// The task's latest Run (its newest Session) is never removed, even
    /// when five older Runs were used after it.
    #[test]
    fn a_tasks_latest_run_is_never_expired() {
        let mut rows: Vec<SessionRow> = (1..=6)
            .map(|n| row(&format!("a-{n}"), Some("sch_a"), false, n))
            .collect();
        for (offset, row) in rows.iter_mut().take(5).enumerate() {
            row.activity_at = 100 + offset as u64;
        }
        assert!(
            expired_run_sessions(&rows).is_empty(),
            "a-6 is the latest Run"
        );
    }

    /// The newest is what the user touched last: a resumed-then-stopped
    /// older Run counts by its latest lifecycle, as the stopped window does.
    #[test]
    fn a_runs_age_is_its_latest_lifecycle() {
        let mut rows: Vec<SessionRow> = (1..=6)
            .map(|n| row(&format!("a-{n}"), Some("sch_a"), false, n))
            .collect();
        rows[0].activity_at = 100; // a-1 was used again after a-6
        assert_eq!(expired_run_sessions(&rows), ["a-2"]);
    }

    /// The next Run stops the task's earlier Run Sessions that sit
    /// idle, and nothing else.
    #[test]
    fn a_new_run_stops_its_tasks_idle_earlier_runs() {
        let rows = vec![
            row("a-previous", Some("sch_a"), true, 2),
            row("a-older-stopped", Some("sch_a"), false, 1),
            row("a-new", Some("sch_a"), true, 3),
            row("b-live", Some("sch_b"), true, 2),
            row("user-live", None, true, 2),
        ];
        assert_eq!(
            superseded_run_sessions(&rows, "sch_a", "a-new"),
            ["a-previous"]
        );
        assert!(superseded_run_sessions(&rows, "sch_c", "c-new").is_empty());
    }

    /// A previous Run the user is following up in (busy), that waits on
    /// them, that is still starting, or that they pinned stays live.
    #[test]
    fn a_new_run_leaves_a_previous_run_that_is_not_idle_or_is_pinned() {
        for status in [Status::Busy, Status::Attention, Status::Starting] {
            let mut previous = row("a-previous", Some("sch_a"), true, 2);
            previous.status = status;
            assert!(
                superseded_run_sessions(&[previous], "sch_a", "a-new").is_empty(),
                "{status:?}"
            );
        }
        let mut pinned = row("a-previous", Some("sch_a"), true, 2);
        pinned.pinned = true;
        assert!(superseded_run_sessions(&[pinned], "sch_a", "a-new").is_empty());
    }

    /// What keeps an older Run listed: live and busy, or waiting on the user.
    #[test]
    fn a_live_run_is_engaged_while_busy_or_waiting() {
        for (status, engaged) in [
            (Status::Busy, true),
            (Status::Attention, true),
            (Status::Idle, false),
            (Status::Starting, false),
        ] {
            let mut live = row("a", Some("sch_a"), true, 1);
            live.status = status;
            assert_eq!(wire_row(&live).engaged, engaged, "{status:?}");
        }
        let mut stopped = row("a", Some("sch_a"), false, 1);
        stopped.status = Status::Busy;
        assert!(!wire_row(&stopped).engaged);
    }

    /// Keyed by `spawned_by` alone: a deleted task's Runs keep the rule.
    #[test]
    fn runs_of_a_deleted_task_keep_the_same_rule() {
        let rows: Vec<SessionRow> = (1..=6)
            .map(|n| row(&format!("gone-{n}"), Some("sch_deleted"), false, n))
            .collect();
        assert_eq!(expired_run_sessions(&rows), ["gone-1"]);
    }
}
