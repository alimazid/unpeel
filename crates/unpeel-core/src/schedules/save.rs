//! The save rules of a Scheduled Task, in one place: every writer (the
//! `unpeel schedules` CLI, the Controller write routes) checks a task with
//! them before saving it, and a Run checks them again when it starts, so
//! a task the Host would refuse to run is never saved and the writers never
//! drift apart. What only a Host knows (its wall clock for a Trigger, the
//! catalog of Projects and presets its Runs resolve against) comes from the
//! [`SaveHost`] each caller passes in.
//!
//! Definitions live raw in `app-state.json` (`schedules`), so fields this
//! build does not model pass through every edit: [`new_entry`] builds the
//! one stored shape of a new task and [`schedules_list_mut`] /
//! [`entry_mut`] are the one way into the list.

use std::fmt;

use serde_json::{json, Map, Value};

use super::ScheduleTrigger;
use crate::controller_api::{find_host_preset, HostCreatePreset, HostCreateProject};

/// The most text a task's instructions may hold: what one create may type.
pub const MAX_INSTRUCTIONS_BYTES: usize = crate::initial_text::MAX_INITIAL_TEXT_BYTES;

/// [`MAX_INSTRUCTIONS_BYTES`] as people read it ("256 KiB").
pub fn instructions_limit() -> String {
    format!("{} KiB", MAX_INSTRUCTIONS_BYTES / 1024)
}

/// Why a Trigger cannot be saved, as the Host's clock sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TriggerRefusal {
    /// A Once time that has already passed.
    InPast(String),
    /// A Trigger that does not read, or can never come due.
    Invalid(String),
}

/// Why a task cannot be saved (or its Run started) as asked. Each has a
/// stable [`code`](Self::code) Controllers branch on, and a sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveRefusal {
    NoProject,
    ProjectMissing(String),
    ProjectHasNoFolder(String),
    NoPreset,
    PresetMissing(String),
    NotAgentPreset(String),
    InstructionsTooLarge,
    InvalidTrigger(String),
    TriggerInPast(String),
    /// The Host has not published the catalog its Runs resolve against.
    CatalogUnavailable,
}

impl SaveRefusal {
    /// The machine-readable reason (`code` in a write route's error body).
    pub fn code(&self) -> &'static str {
        match self {
            Self::NoProject | Self::ProjectMissing(_) | Self::ProjectHasNoFolder(_) => {
                "project_missing"
            }
            Self::NoPreset | Self::PresetMissing(_) => "preset_missing",
            Self::NotAgentPreset(_) => "not_agent_preset",
            Self::InstructionsTooLarge => "instructions_too_large",
            Self::InvalidTrigger(_) => "invalid_trigger",
            Self::TriggerInPast(_) => "trigger_in_past",
            Self::CatalogUnavailable => "host_unavailable",
        }
    }
}

impl fmt::Display for SaveRefusal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoProject => write!(formatter, "a Scheduled Task needs a Project"),
            Self::ProjectMissing(id) => {
                write!(formatter, "the Project {id} does not exist on this Host")
            }
            Self::ProjectHasNoFolder(id) => {
                write!(formatter, "the Project {id} has no folder for a Run to start in")
            }
            Self::NoPreset => write!(formatter, "a Scheduled Task needs a preset"),
            Self::PresetMissing(id) => write!(
                formatter,
                "the preset {id} does not exist in that Project or is turned off"
            ),
            Self::NotAgentPreset(id) => write!(
                formatter,
                "the preset {id} is not an Agent Preset: it does not start an agent Unpeel \
                 can tell is ready, so it cannot take instructions"
            ),
            Self::InstructionsTooLarge => write!(
                formatter,
                "the instructions are longer than {}",
                instructions_limit()
            ),
            Self::InvalidTrigger(detail) => write!(formatter, "invalid Trigger: {detail}"),
            Self::TriggerInPast(detail) => write!(formatter, "invalid Trigger: {detail}"),
            Self::CatalogUnavailable => write!(
                formatter,
                "the Host has not published its Projects yet; try again"
            ),
        }
    }
}

impl From<TriggerRefusal> for SaveRefusal {
    fn from(refusal: TriggerRefusal) -> Self {
        match refusal {
            TriggerRefusal::InPast(detail) => Self::TriggerInPast(detail),
            TriggerRefusal::Invalid(detail) => Self::InvalidTrigger(detail),
        }
    }
}

/// What a writer needs a Host for.
pub trait SaveHost {
    /// The Trigger in its stored form, on the Host's wall clock. With
    /// `comes_due` it must still come due (a past Once is refused); a task
    /// saved paused only needs a Trigger that reads, and is checked again
    /// when it resumes.
    fn check_trigger(
        &self,
        trigger: &ScheduleTrigger,
        comes_due: bool,
    ) -> Result<ScheduleTrigger, TriggerRefusal>;
    /// The Projects and presets a Run resolves against; `None` while the
    /// Host has not published one.
    fn catalog(&self) -> Option<(Vec<HostCreateProject>, Vec<HostCreatePreset>)>;
}

/// Where a task's Run starts.
#[derive(Debug, Clone, Copy)]
pub struct RunTarget<'a> {
    pub project: &'a HostCreateProject,
    pub preset: &'a HostCreatePreset,
    /// The Project's folder (its worktree's, for a worktree Project).
    pub cwd: &'a str,
    /// The instructions to type, when there are any.
    pub instructions: Option<&'a str>,
}

/// The launch rules, against a catalog: a Project with a folder, an enabled
/// preset of it or a global one, and instructions (blank ones are none)
/// only for an Agent Preset, at most [`MAX_INSTRUCTIONS_BYTES`]. A preset
/// edited into a plain command since the task was saved fails here too,
/// rather than typing the instructions into a shell.
pub fn check_runnable<'a>(
    project_id: &str,
    preset_id: &str,
    instructions: Option<&'a str>,
    projects: &'a [HostCreateProject],
    presets: &'a [HostCreatePreset],
) -> Result<RunTarget<'a>, SaveRefusal> {
    if project_id.trim().is_empty() {
        return Err(SaveRefusal::NoProject);
    }
    let project = projects
        .iter()
        .find(|project| project.id == project_id)
        .ok_or_else(|| SaveRefusal::ProjectMissing(project_id.to_owned()))?;
    let cwd = project.worktree_path.as_deref().unwrap_or(&project.path);
    if cwd.trim().is_empty() {
        return Err(SaveRefusal::ProjectHasNoFolder(project_id.to_owned()));
    }
    if preset_id.trim().is_empty() {
        return Err(SaveRefusal::NoPreset);
    }
    let preset = find_host_preset(presets, preset_id, project_id)
        .ok_or_else(|| SaveRefusal::PresetMissing(preset_id.to_owned()))?;
    let instructions = instructions.filter(|text| !text.trim().is_empty());
    if let Some(text) = instructions {
        if !crate::agent_readiness::is_agent_command(&preset.command) {
            return Err(SaveRefusal::NotAgentPreset(preset.id.clone()));
        }
        if text.len() > MAX_INSTRUCTIONS_BYTES {
            return Err(SaveRefusal::InstructionsTooLarge);
        }
    }
    Ok(RunTarget {
        project,
        preset,
        cwd,
        instructions,
    })
}

/// [`check_runnable`] against the Host's catalog.
pub fn check_task_runs(
    host: &dyn SaveHost,
    project_id: &str,
    preset_id: &str,
    instructions: Option<&str>,
) -> Result<(), SaveRefusal> {
    let (projects, presets) = host.catalog().ok_or(SaveRefusal::CatalogUnavailable)?;
    check_runnable(project_id, preset_id, instructions, &projects, &presets).map(|_| ())
}

/// A new task's Trigger, checked by the Host ([`SaveHost::check_trigger`]).
pub fn check_trigger(
    host: &dyn SaveHost,
    trigger: &ScheduleTrigger,
    comes_due: bool,
) -> Result<ScheduleTrigger, SaveRefusal> {
    host.check_trigger(trigger, comes_due)
        .map_err(SaveRefusal::from)
}

/// A new task as a writer gives it, every field already checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewTask<'a> {
    pub name: &'a str,
    pub project_id: &'a str,
    pub preset_id: &'a str,
    pub trigger: &'a ScheduleTrigger,
    pub instructions: Option<&'a str>,
    pub enabled: bool,
    pub notify_when_done: bool,
}

/// A fresh task id.
pub fn new_schedule_id() -> String {
    format!("sch_{}", uuid::Uuid::new_v4())
}

/// The stored entry of a new task, under a fresh id.
pub fn new_entry(task: &NewTask<'_>, now_ms: u64) -> Value {
    let mut entry = json!({
        "id": new_schedule_id(),
        "name": task.name,
        "project_id": task.project_id,
        "preset_id": task.preset_id,
        "trigger": task.trigger,
        "enabled": task.enabled,
        "notify_when_done": task.notify_when_done,
        "created_at_ms": now_ms,
    });
    if let Some(instructions) = task.instructions.filter(|text| !text.trim().is_empty()) {
        entry["instructions"] = Value::String(instructions.to_owned());
    }
    entry
}

/// The `schedules` list of an `app-state.json` being edited (made when it
/// is missing). One that is not a list is never overwritten.
pub fn schedules_list_mut(state: &mut Map<String, Value>) -> Result<&mut Vec<Value>, String> {
    state
        .entry("schedules")
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| "app-state.json schedules is not a list; not changing it".to_owned())
}

/// The raw entry of task `schedule_id` in that list.
pub fn entry_mut<'a>(list: &'a mut [Value], schedule_id: &str) -> Option<&'a mut Map<String, Value>> {
    list.iter_mut()
        .find(|entry| entry.get("id").and_then(Value::as_str) == Some(schedule_id))
        .and_then(Value::as_object_mut)
}

#[cfg(test)]
mod tests;
