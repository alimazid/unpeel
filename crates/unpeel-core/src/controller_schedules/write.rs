//! Fork-only: Scheduled Tasks. The Controller write routes, the user's only
//! (decision Q8: PairedDevice / OwnerTransport principals):
//!
//! - `POST /mobile/schedules` (`schedules.create`): a new task.
//! - `POST /mobile/schedules/edit` (`schedules.edit`): change any field;
//!   pausing and resuming are `enabled`.
//! - `POST /mobile/schedules/delete` (`schedules.delete`): the task and its
//!   history; its Run Sessions stay where they are.
//! - `POST /mobile/schedules/run` (`schedules.run`): Run now, refused (409)
//!   while a Run of the task is in progress.
//!
//! Bodies are camelCase (`scheduleID`, `projectID`, `presetID`,
//! `notifyWhenDone`, `instructions`); `trigger` is the stored shape the
//! list route answers with. Definitions are edited raw under the
//! `app-state.json` flock and announced, so fields this build does not
//! model pass through, like `unpeel schedules`. What only the running Host
//! service can do (check a Trigger on its wall clock, resolve the catalog
//! its Runs use, start a Run now) comes from the [`ScheduleHost`] the
//! workspace worker installs; a process without one answers 503 and writes
//! nothing.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{json, Map, Value};

use super::Failure;
use crate::controller_api::{ControllerPrincipal, ControllerRequest};
use crate::schedule_store::TaskStore;
use crate::schedules::save::{self, SaveHost, SaveRefusal};
use crate::schedules::{self, Schedule, ScheduleEdit, ScheduleTrigger};

pub(super) const CREATE_PATH: &str = "/mobile/schedules";
pub(super) const EDIT_PATH: &str = "/mobile/schedules/edit";
pub(super) const DELETE_PATH: &str = "/mobile/schedules/delete";
pub(super) const RUN_PATH: &str = "/mobile/schedules/run";

/// Why the worker did not start a Run now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunNowRefusal {
    /// A Run of the task is still in progress (D5): 409.
    InProgress(String),
    /// The request never reached the worker: 503 (not applied).
    Unavailable(String),
    /// The worker did not answer in time; the Run may still start: 504
    /// (outcome unknown, so a Controller refreshes rather than retries).
    NoAnswer(String),
}

/// What only the workspace worker can do for the write routes: the save
/// rules' Host half (its clock and catalog, [`SaveHost`]) and Run now.
pub trait ScheduleHost: SaveHost + Send + Sync {
    /// Start a Run of the task now; its Run id.
    fn run_now(&self, schedule_id: &str) -> Result<String, RunNowRefusal>;
}

static HOST: Mutex<Option<Arc<dyn ScheduleHost>>> = Mutex::new(None);

/// The workspace worker installs itself when it starts; a later start
/// replaces it.
pub fn install_host(host: Arc<dyn ScheduleHost>) {
    let mut slot = HOST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    *slot = Some(host);
}

/// Whether this process can serve the write routes, so the disk-backed
/// runtime advertises them only where they work.
pub fn has_host() -> bool {
    current_host().is_some()
}

fn current_host() -> Option<Arc<dyn ScheduleHost>> {
    HOST.lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// The write routes, for `controller_schedules::route`. Every other request
/// passes through the router here, so it leaves before anything is read.
pub(super) fn route(request: &ControllerRequest) -> Option<(u16, Value)> {
    let is_write = request.method == "POST"
        && matches!(
            request.path.as_str(),
            CREATE_PATH | EDIT_PATH | DELETE_PATH | RUN_PATH
        );
    if !is_write {
        return None;
    }
    let host = current_host();
    answer(request, host.as_deref(), &Workspace::current(), now_ms())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

type Write =
    fn(&Map<String, Value>, Option<&dyn ScheduleHost>, &Workspace, u64) -> Result<Value, Failure>;

/// One write request against `workspace` at `now_ms`; `None` when it is not
/// a write route. Every refusal that needs no Host comes first, so a
/// process without one answers a malformed or unknown request the same way.
pub(super) fn answer(
    request: &ControllerRequest,
    host: Option<&dyn ScheduleHost>,
    workspace: &Workspace,
    now_ms: u64,
) -> Option<(u16, Value)> {
    if request.method != "POST" {
        return None;
    }
    let write: Write = match request.path.as_str() {
        CREATE_PATH => create,
        EDIT_PATH => edit,
        DELETE_PATH => delete,
        RUN_PATH => run_now,
        _ => return None,
    };
    let answer = if !principal_can_write_schedules(&request.principal) {
        Err(Failure(403, "only the user changes Scheduled Tasks".into()))
    } else {
        request
            .body
            .as_object()
            .ok_or_else(|| invalid("a JSON object body is required"))
            .and_then(|body| write(body, host, workspace, now_ms))
    };
    Some(match answer {
        Ok(body) => (200, body),
        Err(Failure(status, message)) => (status, json!({ "error": message })),
    })
}

/// Who may change Scheduled Tasks: the user's paired devices and owner
/// transports, never an agent (Q8). Exhaustive on purpose, like
/// `principal_can_read_schedules`.
pub fn principal_can_write_schedules(principal: &ControllerPrincipal) -> bool {
    match principal {
        ControllerPrincipal::PairedDevice { .. } | ControllerPrincipal::OwnerTransport { .. } => {
            true
        }
    }
}

fn require(host: Option<&dyn ScheduleHost>) -> Result<&dyn ScheduleHost, Failure> {
    host.ok_or_else(|| {
        Failure(
            503,
            "Scheduled Tasks change only while the Host service runs".into(),
        )
    })
}

// ── create ──

fn create(
    body: &Map<String, Value>,
    host: Option<&dyn ScheduleHost>,
    workspace: &Workspace,
    now_ms: u64,
) -> Result<Value, Failure> {
    let enabled = optional_bool(body, "enabled")?.unwrap_or(true);
    let notify = optional_bool(body, "notifyWhenDone")?.unwrap_or(true);
    let name = schedules::task_name(&optional_string(body, "name")?.unwrap_or_default())
        .map_err(invalid)?;
    let raw_trigger = match body.get("trigger") {
        None | Some(Value::Null) => return Err(invalid("a Scheduled Task needs a Trigger")),
        Some(raw) => raw,
    };
    let project_id = optional_string(body, "projectID")?.unwrap_or_default();
    let preset_id = optional_string(body, "presetID")?.unwrap_or_default();
    let instructions = instructions_field(body)?.flatten();
    let host = require(host)?;
    let trigger = save::check_trigger(host, &decode_trigger(raw_trigger)?, enabled)
        .map_err(refused)?;
    save::check_task_runs(host, &project_id, &preset_id, instructions.as_deref())
        .map_err(refused)?;

    let entry = save::new_entry(
        &save::NewTask {
            name: &name,
            project_id: &project_id,
            preset_id: &preset_id,
            trigger: &trigger,
            instructions: instructions.as_deref(),
            enabled,
            notify_when_done: notify,
        },
        now_ms,
    );
    workspace.edit(|list| {
        list.push(entry.clone());
        Ok(())
    })?;
    saved_row(workspace, &entry)
}

// ── edit, pause, resume ──

/// Change the fields the body names. A new Trigger is checked (and must
/// come due while the task is enabled); resuming checks the Trigger the
/// task keeps; a new Project, preset or instructions must still make a
/// task the Host would run. Resuming or a new Trigger restarts the clock
/// (`schedules::apply_edit`).
fn edit(
    body: &Map<String, Value>,
    host: Option<&dyn ScheduleHost>,
    workspace: &Workspace,
    now_ms: u64,
) -> Result<Value, Failure> {
    let schedule_id = schedule_id(body)?;
    let stored = workspace.stored_entry(&schedule_id)?;
    let current = decode(&stored)?;
    let mut change = ScheduleEdit {
        name: optional_string(body, "name")?
            .map(|name| schedules::task_name(&name).map_err(invalid))
            .transpose()?,
        project_id: optional_string(body, "projectID")?,
        preset_id: optional_string(body, "presetID")?,
        trigger: None,
        enabled: optional_bool(body, "enabled")?,
        notify_when_done: optional_bool(body, "notifyWhenDone")?,
        instructions: instructions_field(body)?,
    };
    let host = require(host)?;
    change.trigger = edited_trigger(host, body, &stored, &current, change.enabled)?;
    if change.project_id.is_some()
        || change.preset_id.is_some()
        || matches!(change.instructions, Some(Some(_)))
    {
        let edited = decode(&schedules::apply_edit(&stored, &change, now_ms))?;
        save::check_task_runs(
            host,
            &edited.project_id,
            &edited.preset_id,
            edited.instructions.as_deref(),
        )
        .map_err(refused)?;
    }
    let saved = workspace.edit(|list| {
        let entry = save::entry_mut(list, &schedule_id).ok_or_else(|| gone(&schedule_id))?;
        *entry = schedules::apply_edit(entry, &change, now_ms);
        Ok(Value::Object(entry.clone()))
    })?;
    saved_row(workspace, &saved)
}

/// An edit's new Trigger, checked (it must come due while the task stays
/// enabled); without one, resuming checks the Trigger the task keeps.
fn edited_trigger(
    host: &dyn ScheduleHost,
    body: &Map<String, Value>,
    stored: &Map<String, Value>,
    current: &Schedule,
    enabled: Option<bool>,
) -> Result<Option<ScheduleTrigger>, Failure> {
    let enabled = enabled.unwrap_or(current.enabled);
    let new_trigger = body
        .get("trigger")
        .filter(|raw| !raw.is_null() && Some(*raw) != stored.get("trigger"));
    if let Some(raw) = new_trigger {
        return save::check_trigger(host, &decode_trigger(raw)?, enabled)
            .map(Some)
            .map_err(refused);
    }
    if enabled && !current.enabled {
        save::check_trigger(host, &current.trigger, true).map_err(|refusal| {
            let failure = refused(refusal);
            Failure(failure.0, format!("cannot resume: {}", failure.1))
        })?;
    }
    Ok(None)
}

// ── delete ──

/// Remove the task and its history. Its Run Sessions stay where they are.
fn delete(
    body: &Map<String, Value>,
    _host: Option<&dyn ScheduleHost>,
    workspace: &Workspace,
    _now_ms: u64,
) -> Result<Value, Failure> {
    let schedule_id = schedule_id(body)?;
    workspace.stored_entry(&schedule_id)?;
    workspace.edit(|list| {
        let before = list.len();
        list.retain(|entry| entry_id(entry) != Some(schedule_id.as_str()));
        if list.len() == before {
            return Err(gone(&schedule_id));
        }
        Ok(())
    })?;
    TaskStore::open(&workspace.root, &schedule_id)
        .and_then(|store| store.remove())
        .map_err(|error| {
            Failure(
                500,
                format!("deleted the task but not its history: {error}"),
            )
        })?;
    Ok(json!({ "scheduleID": schedule_id, "deleted": true }))
}

// ── Run now ──

fn run_now(
    body: &Map<String, Value>,
    host: Option<&dyn ScheduleHost>,
    workspace: &Workspace,
    _now_ms: u64,
) -> Result<Value, Failure> {
    let schedule_id = schedule_id(body)?;
    workspace.stored_entry(&schedule_id)?;
    match require(host)?.run_now(&schedule_id) {
        Ok(run_id) => Ok(json!({ "scheduleID": schedule_id, "runID": run_id })),
        Err(RunNowRefusal::InProgress(message)) => Err(Failure(409, message)),
        Err(RunNowRefusal::Unavailable(message)) => Err(Failure(503, message)),
        Err(RunNowRefusal::NoAnswer(message)) => Err(Failure(504, message)),
    }
}

// ── shared rules ──

/// A save rule's refusal (`schedules::save`): 400, except a catalog the
/// Host has not published yet (503, try again).
fn refused(refusal: SaveRefusal) -> Failure {
    let status = match refusal {
        SaveRefusal::CatalogUnavailable => 503,
        _ => 400,
    };
    Failure(status, refusal.to_string())
}

/// A Trigger from a body. A shape that does not decode reads as `Unknown`,
/// which no Host accepts: the save check says so.
fn decode_trigger(raw: &Value) -> Result<ScheduleTrigger, Failure> {
    if !raw.is_object() {
        return Err(invalid("a Trigger is an object with a kind"));
    }
    Ok(serde_json::from_value(raw.clone()).unwrap_or_default())
}

/// `instructions`: absent → `None` (unchanged); `null` or blank →
/// `Some(None)` (none); text → `Some(Some(text))`.
fn instructions_field(body: &Map<String, Value>) -> Result<Option<Option<String>>, Failure> {
    match body.get("instructions") {
        None => Ok(None),
        Some(Value::Null) => Ok(Some(None)),
        Some(Value::String(text)) if text.trim().is_empty() => Ok(Some(None)),
        Some(Value::String(text)) => Ok(Some(Some(text.clone()))),
        Some(_) => Err(invalid("instructions must be text")),
    }
}

fn optional_string(body: &Map<String, Value>, key: &str) -> Result<Option<String>, Failure> {
    match body.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(invalid(format!("{key} must be text"))),
    }
}

fn optional_bool(body: &Map<String, Value>, key: &str) -> Result<Option<bool>, Failure> {
    match body.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{key} must be true or false"))),
    }
}

/// `scheduleID`, a valid task id.
fn schedule_id(body: &Map<String, Value>) -> Result<String, Failure> {
    body.get("scheduleID")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| schedules::is_valid_id(id))
        .map(str::to_owned)
        .ok_or_else(|| invalid("valid scheduleID required"))
}

fn invalid(message: impl Into<String>) -> Failure {
    Failure(400, message.into())
}

fn gone(schedule_id: &str) -> Failure {
    Failure(
        404,
        format!("no Scheduled Task {schedule_id}; it may have been deleted"),
    )
}

fn entry_id(entry: &Value) -> Option<&str> {
    entry.get("id").and_then(Value::as_str)
}

/// A stored entry as every reader decodes it.
fn decode(entry: &Map<String, Value>) -> Result<Schedule, Failure> {
    schedules::schedules_from_value(Some(&Value::Array(vec![Value::Object(entry.clone())])))
        .pop()
        .ok_or_else(|| Failure(500, "the Scheduled Task does not read".into()))
}

/// `{"schedule": <row>}` for an entry as saved, as the list route lists it.
fn saved_row(workspace: &Workspace, entry: &Value) -> Result<Value, Failure> {
    let entry = entry
        .as_object()
        .ok_or_else(|| Failure(500, "the saved Scheduled Task is not an object".into()))?;
    Ok(json!({ "schedule": super::row_at(decode(entry)?, &workspace.root) }))
}

/// Where the routes read and write: this workspace (`app-state.json`,
/// announced on the state bus) or a private pair of paths.
pub(super) struct Workspace {
    /// `None`: the workspace's own `app-state.json`.
    state: Option<PathBuf>,
    root: PathBuf,
}

impl Workspace {
    fn current() -> Self {
        Self {
            state: None,
            root: crate::schedule_store::schedules_root(),
        }
    }

    #[cfg(test)]
    pub(super) fn at(state: &std::path::Path, root: &std::path::Path) -> Self {
        Self {
            state: Some(state.to_path_buf()),
            root: root.to_path_buf(),
        }
    }

    fn load(&self) -> Result<Value, Failure> {
        match &self.state {
            None => crate::app_state::load(),
            Some(path) => crate::app_state::load_for_edit_at(path),
        }
        .map_err(|error| Failure(500, format!("could not read Scheduled Tasks: {error}")))
    }

    /// The task's raw entry, read without the flock: a write route refuses
    /// an unknown task before it takes the lock or needs the Host.
    fn stored_entry(&self, schedule_id: &str) -> Result<Map<String, Value>, Failure> {
        self.load()?
            .get("schedules")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|entry| entry_id(entry) == Some(schedule_id))
            .and_then(Value::as_object)
            .cloned()
            .ok_or_else(|| gone(schedule_id))
    }

    /// Load → change the `schedules` list → save, under the flock (and
    /// announced, for the workspace's own file). A refusal saves nothing.
    fn edit<T>(
        &self,
        change: impl FnOnce(&mut Vec<Value>) -> Result<T, Failure>,
    ) -> Result<T, Failure> {
        let mut refused = None;
        let mutate = |state: &mut Map<String, Value>| {
            let list = save::schedules_list_mut(state)?;
            change(list).map_err(|failure| {
                let message = failure.1.clone();
                refused = Some(failure);
                message
            })
        };
        let saved = match &self.state {
            None => crate::app_state::edit(mutate),
            Some(path) => crate::app_state::edit_at(path, mutate),
        };
        saved.map_err(|error| refused.take().unwrap_or(Failure(500, error)))
    }
}

#[cfg(test)]
mod tests;
