//! Fork-only (#84): what the health check reads from the real home — task
//! definitions, clocks and Run logs, the Router mark, its Inbox — and
//! how its reports reach the Router's Inbox.

use jiff::Zoned;
use unpeel_core::schedule_store::TaskStore;
use unpeel_core::session_inbox::Store;

use super::check::{Facts, RouterFacts, TaskFacts};
use super::Alert;
use crate::schedules::trigger;
use crate::sessions::{SessionRow, Status};

/// The Host as a check sees it: `rows` are the worker's latest rescan.
pub fn facts(rows: &[SessionRow], now: &Zoned) -> Facts {
    Facts {
        tasks: tasks(now),
        router: unpeel_core::supervision::router_id().map(|id| router(rows, id)),
        asking: rows
            .iter()
            .filter(|row| row.running && row.status == Status::Attention)
            .map(|row| row.id.clone())
            .collect(),
    }
}

/// Every task with its next run and Runs. Definitions that will not read
/// check no task (the sweep warns about them).
fn tasks(now: &Zoned) -> Vec<TaskFacts> {
    let schedules = unpeel_core::schedule_store::load_schedules().unwrap_or_else(|error| {
        crate::tracelog::trace("health", &format!("no tasks checked: {error}"));
        Vec::new()
    });
    schedules
        .into_iter()
        .filter_map(|schedule| {
            let store = TaskStore::for_schedule(&schedule.id).ok()?;
            // A clock that will not read has no next run to miss: the
            // scheduler restarts it from now.
            let next_run = store.clock().ok().and_then(|clock| {
                let (at, ms) = trigger::published_next_run(&schedule, &clock, now.time_zone())?;
                Some((at, ms?))
            });
            Some(TaskFacts {
                runs: store.runs().ok(),
                next_run,
                schedule,
            })
        })
        .collect()
}

fn router(rows: &[SessionRow], session_id: String) -> RouterFacts {
    let store = Store::home();
    RouterFacts {
        running: rows.iter().any(|row| row.id == session_id && row.running),
        inbox: store.pending_stats(&session_id),
        hold: store.hold(&session_id).map(|hold| hold.reason),
        session_id,
    }
}

/// Queue `alert` in the Router's Inbox and announce it, as the
/// supervisor's own notices are.
pub fn queue_report(router: &str, alert: &Alert, now_ms: u64) -> Result<(), String> {
    Store::home().enqueue(router, alert.report(), now_ms)?;
    unpeel_core::supervision::announce_markers();
    Ok(())
}
