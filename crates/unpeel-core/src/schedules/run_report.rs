//! Fork-only (#81): a Run Session's `sessions report`, kept for its Run.
//!
//! Whoever sends the report (the `unpeel` MCP server or CLI inside the Run
//! Session) writes it to that Session's own directory once the report was
//! accepted, each one replacing the last. The workspace worker, the only
//! writer of a task's Run log, reads it every sweep and records it on the
//! Run it belongs to (`unpeel_serve::schedules`): the Session is the Run's
//! own, so its directory names the Run without trusting the environment.

use std::path::Path;

use serde_json::Value;

use super::RunReport;
use crate::session_host::HostedSessionManifest;

const FILE: &str = "run-report.json";
/// Most characters of a report's summary a Run keeps.
const MAX_SUMMARY_CHARS: usize = 1000;

/// Keep the report in `args` when `caller` is a Scheduled Task's Run
/// Session; anyone else's report is not a Run's. Best-effort: the report
/// itself already went out, so a failed write only costs the Run record it.
pub fn record(caller: Option<HostedSessionManifest>, args: &Value) {
    let Some(caller) = caller.filter(|caller| {
        super::run_sessions::schedule_id(caller.session.spawned_by.as_deref()).is_some()
    }) else {
        return;
    };
    let report = report_from(args, crate::state::current_timestamp_ms());
    let dir = crate::session_host::session_dir(&caller.session.id);
    match write_in(&dir, &report) {
        Ok(()) => crate::state_bus::announce(crate::state_bus::Change::SessionMarkers, None),
        Err(error) => log::warn!(
            "Run Session {} report not kept for its Run: {error}",
            caller.session.id
        ),
    }
}

/// The last report the Run Session `session_id` sent, if any.
pub fn read(session_id: &str) -> Option<RunReport> {
    let bytes = std::fs::read(crate::session_host::session_dir(session_id).join(FILE)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// A report as the Run keeps it: its status (`update` when it gave none,
/// as the report itself reads it) and its trimmed summary.
fn report_from(args: &Value, at_ms: u64) -> RunReport {
    let text = |key: &str| {
        args.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
    };
    RunReport {
        status: text("status").unwrap_or("update").to_owned(),
        summary: text("summary")
            .unwrap_or_default()
            .chars()
            .take(MAX_SUMMARY_CHARS)
            .collect(),
        at_ms,
    }
}

/// Atomically replace the report in an existing Session directory.
fn write_in(session_dir: &Path, report: &RunReport) -> Result<(), String> {
    if !session_dir.is_dir() {
        return Err(format!("no session dir {}", session_dir.display()));
    }
    let bytes = serde_json::to_vec(report).map_err(|error| error.to_string())?;
    let tmp = session_dir.join(format!(".{FILE}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, bytes).map_err(|error| error.to_string())?;
    std::fs::rename(&tmp, session_dir.join(FILE)).map_err(|error| error.to_string())
}
