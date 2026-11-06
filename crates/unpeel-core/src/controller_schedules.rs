//! Fork-only: Scheduled Tasks. The Controller routes and the bootstrap's
//! `schedulesRevision` and Agent Preset flags.
//!
//! - `GET /mobile/schedules`: every task with its next run and its latest
//!   Run (the Run events a Controller notices: done, needs you, failed,
//!   failed to start, skipped).
//! - `GET /mobile/schedules/runs?scheduleID=<id>[&limit=<n>]`: a task's Run
//!   history, newest first.
//! - The user's writes (create, edit / pause / resume, delete, Run now):
//!   [`write`].
//!
//! The reads use the disk only: definitions from `app-state.json`, the next
//! run and the Runs from the per-task files the workspace worker publishes
//! (`schedule_store`). No read needs the scheduler, a clock, or a time
//! zone, so every Host adapter serves them alike. `protocol/schedules-
//! samples-v1.json` pins both bodies for the Rust Host and the Swift DTOs.

use std::collections::HashMap;
use std::path::Path;

use serde_json::{json, Value};

use crate::controller_api::{ControllerPrincipal, ControllerRequest, ControllerResponse};
use crate::schedule_store::{self, TaskStore};
use crate::schedules::{self, Schedule, ScheduleClock, ScheduleRun};

mod write;

pub use write::{
    has_host, install_host, principal_can_write_schedules, RunNowRefusal, ScheduleHost,
};

/// `GET /mobile/schedules`.
pub const LIST_CAPABILITY: &str = "schedules";
/// `GET /mobile/schedules/runs`.
pub const RUNS_CAPABILITY: &str = "schedules.runs";
/// `POST /mobile/schedules`.
pub const CREATE_CAPABILITY: &str = "schedules.create";
/// `POST /mobile/schedules/edit`, pause and resume included.
pub const EDIT_CAPABILITY: &str = "schedules.edit";
/// `POST /mobile/schedules/delete`.
pub const DELETE_CAPABILITY: &str = "schedules.delete";
/// `POST /mobile/schedules/run`: Run now.
pub const RUN_CAPABILITY: &str = "schedules.run";
/// The write routes, served only where a [`ScheduleHost`] is installed.
pub const WRITE_CAPABILITIES: [&str; 4] = [
    CREATE_CAPABILITY,
    EDIT_CAPABILITY,
    DELETE_CAPABILITY,
    RUN_CAPABILITY,
];
const LIST_PATH: &str = "/mobile/schedules";
const RUNS_PATH: &str = "/mobile/schedules/runs";

/// A refused request: its HTTP status, the machine-readable reason
/// Controllers branch on (`code` in the error body; never the message),
/// and the message a person reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub status: u16,
    pub code: &'static str,
    pub message: String,
}

/// The error codes of the schedules routes beyond the save rules' own
/// (`schedules::save::SaveRefusal::code`). Additive: a Controller that does
/// not know a code shows the message.
pub mod codes {
    pub const INVALID_REQUEST: &str = "invalid_request";
    pub const FORBIDDEN: &str = "forbidden";
    pub const UNKNOWN_TASK: &str = "unknown_task";
    pub const RUN_IN_PROGRESS: &str = "run_in_progress";
    pub const RUN_NO_ANSWER: &str = "run_no_answer";
    pub const HOST_UNAVAILABLE: &str = "host_unavailable";
    pub const INTERNAL: &str = "internal";
}

impl Failure {
    pub fn new(status: u16, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }

    /// `{"error": message, "code": code}`.
    pub fn body(&self) -> Value {
        json!({ "error": self.message, "code": self.code })
    }
}

/// Every bootstrap preset row says whether it is an Agent Preset (one that
/// starts an agent Unpeel can tell is ready), so a Controller shows a
/// task's Instructions field only where the Host would accept them, and
/// whether it turns off its agent's approval prompts (`bypassesApprovals`),
/// so a Controller can warn that its Runs ask no one. A Controller never
/// classifies a command itself.
pub fn mark_agent_presets(presets: &mut [Value]) {
    for preset in presets {
        let command = preset.get("command").and_then(Value::as_str);
        let agent = command.is_some_and(crate::agent_readiness::is_agent_command);
        let bypasses = command.is_some_and(bypasses_approvals);
        if let Some(row) = preset.as_object_mut() {
            row.insert("agentPreset".into(), Value::Bool(agent));
            row.insert("bypassesApprovals".into(), Value::Bool(bypasses));
        }
    }
}

/// Whether `command` passes one of its runtime's own approval-bypass flags
/// (`[approvals]` in `runtimes/<slug>/runtime.toml`). A command no runtime
/// claims bypasses nothing Unpeel knows of.
fn bypasses_approvals(command: &str) -> bool {
    let head = crate::integrations::command_head(command);
    let Some(runtime) = crate::runtime_catalog::builtin_runtime_catalog()
        .by_command_alias_for_current_platform(head)
    else {
        return false;
    };
    let arguments: Vec<&str> = command.split_whitespace().skip(1).collect();
    runtime.approvals.bypass_flags.iter().any(|flag| {
        let words: Vec<&str> = flag.split_whitespace().collect();
        !words.is_empty() && arguments.windows(words.len()).any(|window| window == words)
    })
}

/// The routes, for `controller_api::route_uncached`. Any other method or
/// path is not this module's.
pub fn route(request: &ControllerRequest) -> Option<ControllerResponse> {
    if let Some((status, body)) = write::route(request) {
        return Some(ControllerResponse {
            id: request.id.clone(),
            status,
            body,
        });
    }
    if request.method != "GET" || !matches!(request.path.as_str(), LIST_PATH | RUNS_PATH) {
        return None;
    }
    let answer = if !principal_can_read_schedules(&request.principal) {
        Err(Failure::new(
            403,
            codes::FORBIDDEN,
            "not allowed to read Scheduled Tasks",
        ))
    } else if request.path == LIST_PATH {
        load_state().map(|state| list_at(&state, &schedule_store::schedules_root()))
    } else {
        parse_runs_query(&request.query).and_then(|query| {
            let state = load_state()?;
            runs_for(&state, &schedule_store::schedules_root(), &query)
        })
    };
    let (status, body) = match answer {
        Ok(body) => (200, body),
        Err(failure) => (failure.status, failure.body()),
    };
    Some(ControllerResponse {
        id: request.id.clone(),
        status,
        body,
    })
}

/// Who may read the workspace's Scheduled Tasks: the user's own paired
/// devices and owner transports (decision Q8). Keep this match exhaustive,
/// like `principal_can_create_session`: a scoped principal added later must
/// get an explicit decision here, never owner reads through a wildcard.
pub fn principal_can_read_schedules(principal: &ControllerPrincipal) -> bool {
    match principal {
        ControllerPrincipal::PairedDevice { .. } | ControllerPrincipal::OwnerTransport { .. } => {
            true
        }
    }
}

/// The bootstrap's `schedulesRevision` for this workspace, from the raw
/// `app-state.json` the bootstrap builder already holds.
pub fn revision(state: &Value) -> String {
    revision_at(state, &schedule_store::schedules_root())
}

/// `GET /mobile/schedules`'s body for the tasks in `state`, with per-task
/// state under `root`.
pub fn list_at(state: &Value, root: &Path) -> Value {
    let tasks = tasks_at(state, root);
    let revision = revision_of(&tasks);
    json!({
        "revision": revision,
        "schedules": tasks.iter().map(TaskOnDisk::wire).collect::<Vec<_>>(),
    })
}

/// `GET /mobile/schedules/runs`'s body for `query`.
pub fn runs_at(
    state: &Value,
    root: &Path,
    query: &HashMap<String, String>,
) -> Result<Value, Failure> {
    runs_for(state, root, &parse_runs_query(query)?)
}

/// An opaque value that changes whenever anything either route answers
/// changes: a definition, a next run, or any Run line. Controllers refetch
/// when it moves instead of polling the routes on a timer.
pub fn revision_at(state: &Value, root: &Path) -> String {
    revision_of(&tasks_at(state, root))
}

struct RunsQuery {
    schedule_id: String,
    limit: Option<usize>,
}

fn parse_runs_query(query: &HashMap<String, String>) -> Result<RunsQuery, Failure> {
    let schedule_id = query
        .get("scheduleID")
        .map(|id| id.trim())
        .filter(|id| schedules::is_valid_id(id))
        .ok_or_else(|| Failure::new(400, codes::INVALID_REQUEST, "valid scheduleID required"))?;
    let limit = match query.get("limit").map(|limit| limit.trim()) {
        None | Some("") => None,
        Some(raw) => Some(
            raw.parse::<usize>()
                .ok()
                .filter(|limit| *limit > 0)
                .ok_or_else(|| {
                    Failure::new(
                        400,
                        codes::INVALID_REQUEST,
                        "limit must be a positive whole number",
                    )
                })?,
        ),
    };
    Ok(RunsQuery {
        schedule_id: schedule_id.to_owned(),
        limit,
    })
}

fn runs_for(state: &Value, root: &Path, query: &RunsQuery) -> Result<Value, Failure> {
    let task = tasks_at(state, root)
        .into_iter()
        .find(|task| task.schedule.id == query.schedule_id)
        .ok_or_else(|| Failure::new(404, codes::UNKNOWN_TASK, "unknown Scheduled Task"))?;
    let runs: Vec<Value> = task
        .runs
        .iter()
        .rev()
        .take(query.limit.unwrap_or(usize::MAX))
        .map(run_wire)
        .collect();
    Ok(json!({ "scheduleID": task.schedule.id, "runs": runs }))
}

fn load_state() -> Result<Value, Failure> {
    crate::app_state::load()
        .map_err(|error| {
            Failure::new(
                500,
                codes::INTERNAL,
                format!("could not read Scheduled Tasks: {error}"),
            )
        })
}

/// One task as its definition and its files say.
struct TaskOnDisk {
    schedule: Schedule,
    /// `None` when the clock is missing or will not read: no next run.
    clock: Option<ScheduleClock>,
    /// Oldest first, each Run's latest line; empty (and logged) when the
    /// Run log will not read.
    runs: Vec<ScheduleRun>,
}

fn tasks_at(state: &Value, root: &Path) -> Vec<TaskOnDisk> {
    schedules::schedules_from_value(state.get("schedules"))
        .into_iter()
        .map(|schedule| TaskOnDisk::at(schedule, root))
        .collect()
}

impl TaskOnDisk {
    fn at(schedule: Schedule, root: &Path) -> Self {
        // Every listed id is valid, so the store always opens.
        let store = TaskStore::open(root, &schedule.id).ok();
        let runs = match store.as_ref().map(TaskStore::runs) {
            Some(Ok(runs)) => runs,
            Some(Err(error)) => {
                log::warn!("Scheduled Task {} lists no Runs: {error}", schedule.id);
                Vec::new()
            }
            None => Vec::new(),
        };
        Self {
            clock: store.as_ref().and_then(|store| store.clock().ok()),
            runs,
            schedule,
        }
    }

    fn wire(&self) -> Value {
        let schedule = &self.schedule;
        let mut row = json!({
            "id": schedule.id,
            "name": schedule.name,
            "projectID": schedule.project_id,
            "presetID": schedule.preset_id,
            // The Host's reading of the Trigger: a kind this build cannot
            // fire is `{"kind":"unknown"}`, which never has a next run.
            "trigger": schedule.trigger,
            "enabled": schedule.enabled,
            "notifyWhenDone": schedule.notify_when_done,
            "createdAtMs": schedule.created_at_ms,
            "nextRun": self.next_run(),
            // The Run in progress, else the newest outcome: an occurrence
            // skipped behind a live Run never hides it.
            "lastRun": schedules::current_run(&self.runs).map(run_wire),
        });
        // What a Run types into its agent, so the edit sheet can show (and
        // Duplicate can copy) them; absent for a task without any.
        if let Some(instructions) = &schedule.instructions {
            row["instructions"] = Value::String(instructions.clone());
        }
        row
    }

    /// What the worker published as the next occurrence; a disabled task
    /// has none, whatever an older clock still says.
    fn next_run(&self) -> Value {
        let clock = self.clock.as_ref().filter(|_| self.schedule.enabled);
        match clock.and_then(|clock| clock.next_occurrence.as_ref().map(|at| (at, clock))) {
            Some((at, clock)) => json!({ "at": at, "atMs": clock.next_occurrence_ms }),
            None => Value::Null,
        }
    }
}

/// One task's list row, with its per-task files under `root`.
fn row_at(schedule: Schedule, root: &Path) -> Value {
    TaskOnDisk::at(schedule, root).wire()
}

fn run_wire(run: &ScheduleRun) -> Value {
    json!({
        "runID": run.run_id,
        "scheduledFor": run.scheduled_for,
        "startedAtMs": run.started_at_ms,
        "endedAtMs": run.ended_at_ms,
        "status": run.status.word(),
        "late": run.late,
        "sessionID": run.session_id,
        "exitCode": run.exit_code,
        "reason": run.reason,
        "snippet": run.snippet,
    })
}

/// FNV-1a over every task's wire row and its whole history.
fn revision_of(tasks: &[TaskOnDisk]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    for task in tasks {
        feed(task.wire().to_string().as_bytes());
        for run in &task.runs {
            feed(run_wire(run).to_string().as_bytes());
        }
        feed(b"\n");
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests;
