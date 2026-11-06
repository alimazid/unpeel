//! Fork-only: the Super Agent's Scheduled Task writes in the `workspace`
//! MCP tool. The user makes one Session the Super Agent to act for them, so
//! that Session (and only it) creates, edits, pauses, resumes, runs and
//! removes the workspace's tasks; every other Session still only reads.
//!
//! Each action is one request to the workspace worker's own write route
//! (`controller_schedules::write`, the routes the Mac app uses) over its
//! local socket: the worker checks the Trigger on its clock against the
//! catalog its Runs resolve against, owns Run now's overlap rule, and
//! answers with the same body and error codes. Nothing here writes
//! `app-state.json`. Like every Unpeel MCP policy this is cooperative: the
//! socket is the user's, and the check that the caller is the Router is
//! made here, before anything is sent.

use serde_json::{json, Map, Value};

use crate::schedules;

/// The write actions, in the order help lists them.
pub(super) const WRITE_ACTIONS: &[&str] = &[
    "create_schedule",
    "edit_schedule",
    "delete_schedule",
    "run_schedule",
];

const CREATE_PATH: &str = "/mobile/schedules";
const EDIT_PATH: &str = "/mobile/schedules/edit";
const DELETE_PATH: &str = "/mobile/schedules/delete";
const RUN_PATH: &str = "/mobile/schedules/run";

/// One request to the worker's write routes: `(path, body)` in, its
/// `(status, body)` out.
pub(super) type Post<'a> = &'a dyn Fn(&str, &Value) -> Result<(u16, Value), String>;

/// Answer write `action` for `caller` against the workspace's raw
/// app-state, sending the route request through `post`. Every refusal the
/// MCP server can make itself comes before anything is sent.
pub(super) fn answer(
    action: &str,
    arguments: &Value,
    caller: Option<&str>,
    state: &Value,
    post: Post<'_>,
) -> Result<Value, String> {
    if !crate::supervision::is_router_in(state, caller) {
        return Err(
            "Only the Super Agent creates, edits, runs and removes Scheduled Tasks; every other \
Session reads them (list_schedules). Ask the user: they change tasks in the app's SCHEDULED \
section or with `unpeel schedules`."
                .into(),
        );
    }
    let (path, body) = match action {
        "create_schedule" => (CREATE_PATH, create_body(arguments, state)?),
        "edit_schedule" => (EDIT_PATH, edit_body(arguments, state)?),
        "delete_schedule" => (
            DELETE_PATH,
            json!({ "scheduleID": schedule_id(arguments)? }),
        ),
        "run_schedule" => (RUN_PATH, json!({ "scheduleID": schedule_id(arguments)? })),
        _ => return Err(format!("Unknown Scheduled Tasks write action: {action}")),
    };
    let (status, answered) = post(path, &body)?;
    if status == 200 {
        return Ok(answered);
    }
    let message = answered.get("error").and_then(Value::as_str).map_or_else(
        || format!("the Host refused it (HTTP {status})"),
        str::to_owned,
    );
    Err(match answered.get("code").and_then(Value::as_str) {
        Some(code) => format!("{message} (code: {code})"),
        None => message,
    })
}

fn create_body(arguments: &Value, state: &Value) -> Result<Value, String> {
    let project_id = required(arguments, "project_id", "workspace list_projects")?;
    let preset = required(arguments, "preset", "workspace list_presets")?;
    let mut body = Map::new();
    body.insert(
        "name".into(),
        json!(optional_text(arguments, "name")?.unwrap_or_default()),
    );
    body.insert("projectID".into(), json!(project_id));
    body.insert(
        "presetID".into(),
        json!(resolve_preset(state, project_id, preset)?),
    );
    body.insert(
        "trigger".into(),
        trigger(arguments)?.ok_or("Missing required parameter: trigger (see help).")?,
    );
    if let Some(text) =
        optional_text(arguments, "instructions")?.filter(|text| !text.trim().is_empty())
    {
        body.insert("instructions".into(), json!(text));
    }
    insert_flags(arguments, &mut body)?;
    Ok(Value::Object(body))
}

/// Only the fields `arguments` names. A new `preset` resolves in the
/// Project the task will have.
fn edit_body(arguments: &Value, state: &Value) -> Result<Value, String> {
    let schedule_id = schedule_id(arguments)?;
    let mut body = Map::new();
    body.insert("scheduleID".into(), json!(schedule_id));
    if let Some(name) = optional_text(arguments, "name")? {
        body.insert("name".into(), json!(name));
    }
    let project_id = optional_id(arguments, "project_id")?;
    if let Some(preset) = optional_id(arguments, "preset")? {
        let in_project = project_id
            .clone()
            .or_else(|| stored_project(state, &schedule_id))
            .unwrap_or_default();
        body.insert(
            "presetID".into(),
            json!(resolve_preset(state, &in_project, &preset)?),
        );
    }
    if let Some(project_id) = project_id {
        body.insert("projectID".into(), json!(project_id));
    }
    if let Some(trigger) = trigger(arguments)? {
        body.insert("trigger".into(), trigger);
    }
    if let Some(text) = optional_text(arguments, "instructions")? {
        // Blank removes them, as the route reads it.
        let kept = (!text.trim().is_empty()).then_some(text);
        body.insert("instructions".into(), json!(kept));
    }
    insert_flags(arguments, &mut body)?;
    if body.len() == 1 {
        return Err(
            "edit_schedule has nothing to change: pass name, project_id, preset, \
trigger, instructions, enabled or notify_when_done."
                .into(),
        );
    }
    Ok(Value::Object(body))
}

/// `enabled` and `notify_when_done`, when given.
fn insert_flags(arguments: &Value, body: &mut Map<String, Value>) -> Result<(), String> {
    for (argument, field) in [
        ("enabled", "enabled"),
        ("notify_when_done", "notifyWhenDone"),
    ] {
        match arguments.get(argument) {
            None | Some(Value::Null) => {}
            Some(Value::Bool(value)) => {
                body.insert(field.into(), json!(value));
            }
            Some(_) => return Err(format!("{argument} must be true or false")),
        }
    }
    Ok(())
}

/// `trigger`: the stored shape (`{"kind":"daily","time":"09:30"}`), or that
/// object as JSON text. The worker checks what it says.
fn trigger(arguments: &Value) -> Result<Option<Value>, String> {
    let parsed = match arguments.get("trigger") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::String(text)) => serde_json::from_str::<Value>(text).ok(),
        Some(other) => Some(other.clone()),
    };
    match parsed {
        Some(object @ Value::Object(_)) => Ok(Some(object)),
        _ => Err(
            "trigger must be an object with a kind, e.g. {\"kind\":\"daily\",\"time\":\"09:30\"} \
(see help)."
                .into(),
        ),
    }
}

/// A preset of `project_id` (or a global one) by id, then by label, the
/// way `sessions create` resolves `preset`.
fn resolve_preset(state: &Value, project_id: &str, wanted: &str) -> Result<String, String> {
    let usable = crate::workspace_tools::usable_presets(state, project_id);
    usable
        .iter()
        .find(|preset| preset.id == wanted)
        .or_else(|| {
            usable
                .iter()
                .find(|preset| preset.label.eq_ignore_ascii_case(wanted))
        })
        .map(|preset| preset.id.clone())
        .ok_or_else(|| {
            let labels: Vec<&str> = usable.iter().map(|preset| preset.label.as_str()).collect();
            format!(
                "No enabled preset {wanted:?} in Project {project_id}. Available: {}.",
                if labels.is_empty() {
                    "none".to_string()
                } else {
                    labels.join(", ")
                }
            )
        })
}

/// The Project task `schedule_id` is saved in.
fn stored_project(state: &Value, schedule_id: &str) -> Option<String> {
    schedules::schedules_from_value(state.get("schedules"))
        .into_iter()
        .find(|schedule| schedule.id == schedule_id)
        .map(|schedule| schedule.project_id)
}

fn schedule_id(arguments: &Value) -> Result<String, String> {
    required(arguments, "schedule_id", "list_schedules").map(str::to_owned)
}

/// A trimmed, non-empty string argument; `from` says where its values come
/// from.
fn required<'a>(arguments: &'a Value, key: &str, from: &str) -> Result<&'a str, String> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Missing required parameter: {key} ({from})."))
}

/// An id an edit may change: absent is unchanged, blank is refused (an
/// edit cannot leave a task without one).
fn optional_id(arguments: &Value, key: &str) -> Result<Option<String>, String> {
    match optional_text(arguments, key)? {
        Some(id) if id.trim().is_empty() => Err(format!("{key} cannot be empty")),
        id => Ok(id.map(|id| id.trim().to_owned())),
    }
}

fn optional_text(arguments: &Value, key: &str) -> Result<Option<String>, String> {
    match arguments.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(format!("{key} must be text")),
    }
}

#[cfg(test)]
mod tests;
