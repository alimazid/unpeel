//! Fork-only: Scheduled Tasks in the `workspace` MCP tool.
//!
//! Any Session lists the workspace's tasks and reads one task's Run
//! history; reads are open in Unpeel. The answers are the Host's `GET
//! /mobile/schedules` and `GET /mobile/schedules/runs` bodies
//! (`controller_schedules`, pinned by `protocol/schedules-samples-v1.json`),
//! read from disk: the worker publishes each task's next run and Runs
//! there, so the reads work with or without it.
//!
//! Creating, editing, pausing, resuming, running and removing tasks is the
//! user's, and the Super Agent's on their behalf ([`write`]): those
//! actions go to the live worker's write routes, and every other Session
//! is refused (as `unpeel schedules` refuses its mutating verbs inside any
//! Session but the Super Agent's).

use std::collections::HashMap;
use std::path::Path;

use serde_json::{json, Value};

use crate::controller_schedules;
use crate::schedule_store;
use crate::schedules;

mod write;

/// The `workspace` actions this module answers: the reads, then the Super
/// Agent's writes.
pub const SCHEDULES_ACTIONS: &[&str] = &[
    "list_schedules",
    "list_schedule_runs",
    "create_schedule",
    "edit_schedule",
    "delete_schedule",
    "run_schedule",
];

/// Runs `list_schedule_runs` returns when the caller names no `limit`: enough
/// to see a pattern, small enough to keep an agent's context lean.
pub const RUNS_DEFAULT_LIMIT: usize = 10;

/// Answer one of [`SCHEDULES_ACTIONS`] for the calling Session, which has
/// passed the Sessions gate. Reads come from this workspace's
/// `app-state.json` and per-task files and need no role; writes are the
/// Super Agent's and go to this workspace's Host worker.
pub fn run_action(action: &str, arguments: &Value) -> Result<String, String> {
    let state = crate::app_state::load()
        .map_err(|error| format!("Could not read Scheduled Tasks: {error}"))?;
    if write::WRITE_ACTIONS.contains(&action) {
        let caller = crate::mcp_host::self_session_id();
        let answered = write::answer(action, arguments, caller.as_deref(), &state, &post_to_host)?;
        return render(&answered);
    }
    answer_at(action, arguments, &state, &schedule_store::schedules_root())
}

/// One write route request to this workspace's running Host worker.
fn post_to_host(path: &str, body: &Value) -> Result<(u16, Value), String> {
    if !crate::supervision::host_worker_running() {
        return Err(
            "Scheduled Tasks change only while this workspace's Host service runs (`unpeel \
serve`); nothing was changed."
                .into(),
        );
    }
    crate::local_host_call::post(&crate::app_paths::unpeel_home(), path, body)
}

fn render(body: &Value) -> Result<String, String> {
    serde_json::to_string_pretty(body)
        .map_err(|error| format!("Failed to encode Scheduled Tasks: {error}"))
}

/// [`run_action`] over `state` (the raw app-state) and the per-task files
/// under `root`.
fn answer_at(
    action: &str,
    arguments: &Value,
    state: &Value,
    root: &Path,
) -> Result<String, String> {
    let body = match action {
        "list_schedules" => controller_schedules::list_at(state, root),
        "list_schedule_runs" => runs_at(arguments, state, root)?,
        _ => {
            return Err(format!(
                "Unknown Scheduled Tasks action: {action}. Valid: {}.",
                SCHEDULES_ACTIONS.join(", ")
            ))
        }
    };
    render(&body)
}

fn runs_at(arguments: &Value, state: &Value, root: &Path) -> Result<Value, String> {
    let schedule_id = arguments
        .get("schedule_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .ok_or("Missing required parameter: schedule_id (a task id from list_schedules).")?;
    let unknown = || {
        format!("No Scheduled Task has id '{schedule_id}'. Use list_schedules for the task ids.")
    };
    if !schedules::is_valid_id(schedule_id) {
        return Err(unknown());
    }
    let query = HashMap::from([
        ("scheduleID".to_string(), schedule_id.to_string()),
        ("limit".to_string(), limit_word(arguments.get("limit"))?),
    ]);
    controller_schedules::runs_at(state, root, &query).map_err(|failure| {
        if failure.status == 404 {
            unknown()
        } else {
            failure.message
        }
    })
}

/// `limit` as the runs route reads it: a JSON number or a numeric string,
/// [`RUNS_DEFAULT_LIMIT`] when absent. The route refuses anything that is
/// not a positive whole number.
fn limit_word(limit: Option<&Value>) -> Result<String, String> {
    match limit {
        None | Some(Value::Null) => Ok(RUNS_DEFAULT_LIMIT.to_string()),
        Some(Value::String(word)) if word.trim().is_empty() => Ok(RUNS_DEFAULT_LIMIT.to_string()),
        Some(Value::String(word)) => Ok(word.trim().to_string()),
        Some(Value::Number(number)) => Ok(number.to_string()),
        Some(_) => Err("limit must be a positive whole number".into()),
    }
}

/// Per-action docs for `{"action":"help"}`.
pub fn action_docs() -> Vec<Value> {
    let mut docs = vec![
        json!({
            "name": "list_schedules",
            "description": "List the workspace's Scheduled Tasks, read-only: each task's id, \
        name, projectID, presetID, trigger, enabled, nextRun (null when paused or nothing is \
        due) and lastRun (the Run in progress, else the latest: its status, times, late marker \
        and snippet). Only the user and the Super Agent change tasks.",
            "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false },
        }),
        json!({
            "name": "list_schedule_runs",
            "description": format!("Read one Scheduled Task's Run history, newest first: each \
        Run's status (running, needs_you, done, failed, failed_to_start, skipped; others may \
        appear), scheduledFor (null for Run now), startedAtMs and endedAtMs, late (started over \
        2 minutes after its time), sessionID, exitCode, reason and snippet. Returns {RUNS_DEFAULT_LIMIT} Runs \
        unless limit says otherwise."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "schedule_id": { "type": "string", "description": "Task id from list_schedules" },
                    "limit": { "type": "integer", "description": format!("Most Runs to return (default {RUNS_DEFAULT_LIMIT})") },
                },
                "required": ["schedule_id"],
                "additionalProperties": false,
            },
        }),
    ];
    docs.extend(write_docs());
    docs
}

/// The `workspace` schema properties the write actions add (`name`,
/// `project_id` and `schedule_id` are shared). Detail lives in help.
pub(crate) fn schema_properties() -> Vec<(&'static str, Value)> {
    vec![
        (
            "preset",
            json!({ "type": "string", "description": "*_schedule: preset id or label" }),
        ),
        (
            "trigger",
            json!({ "type": "object", "description": "*_schedule: when it runs; see help" }),
        ),
        (
            "instructions",
            json!({ "type": "string", "description": "*_schedule: typed into the agent" }),
        ),
        (
            "enabled",
            json!({ "type": "boolean", "description": "*_schedule: false pauses" }),
        ),
        (
            "notify_when_done",
            json!({ "type": "boolean", "description": "*_schedule: notify the user" }),
        ),
    ]
}

/// Help for the Super Agent's write actions.
fn write_docs() -> Vec<Value> {
    let text = |description: &str| json!({ "type": "string", "description": description });
    let flag = |description: &str| json!({ "type": "boolean", "description": description });
    let task = || text("Task id from list_schedules");
    let doc = |name: &str, description: String, properties: Value, required: &[&str]| {
        json!({
            "name": name,
            "description": description,
            "inputSchema": {
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            },
        })
    };
    let trigger = json!({ "type": "object", "description": "One of {kind:\"hourly\",minute:0-59}, \
        {kind:\"daily\"|\"weekdays\",time:\"HH:MM\"}, {kind:\"weekly\",weekday:\"monday\"…\"sunday\",\
        time:\"HH:MM\"}, {kind:\"once\",at:\"YYYY-MM-DDTHH:MM\"}, {kind:\"cron\",expr:\"<min> <hour> \
        <day> <month> <weekday>\"}, on the Host's local wall clock" });
    let limit = schedules::save::instructions_limit();
    vec![
        doc(
            "create_schedule",
            format!(
                "Super Agent only. Add a Scheduled Task for the user: each time its trigger \
        comes due the Host starts a new Session from preset in project_id and, for an Agent Preset \
        (list_presets agent_preset: true), types instructions once the agent is ready (up to \
        {limit}). Returns {{schedule}}, the list_schedules row. Needs the Host service running. A \
        refusal ends with its code: project_missing, preset_missing, not_agent_preset, \
        instructions_too_large, invalid_trigger, trigger_in_past, host_unavailable."
            ),
            json!({
                "name": text("Task name"),
                "project_id": text("Project its Runs start in (workspace list_projects)"),
                "preset": text("Preset id or label (workspace list_presets), as sessions create"),
                "trigger": trigger.clone(),
                "instructions": text("Agent Presets only: what each Run types"),
                "enabled": flag("Default true; false saves it paused"),
                "notify_when_done": flag("Notify the user when a Run is done (default true)"),
            }),
            &["name", "project_id", "preset", "trigger"],
        ),
        doc(
            "edit_schedule",
            "Super Agent only. Change only the fields given. enabled=false pauses the task; \
        enabled=true resumes it counting from now, so times missed while paused never run (a new \
        trigger restarts its clock too). instructions=\"\" removes them. Returns {schedule}."
                .into(),
            json!({
                "schedule_id": task(),
                "name": text("New name"),
                "project_id": text("New Project"),
                "preset": text("New preset id or label, in the task's Project"),
                "trigger": trigger,
                "instructions": text("New instructions; empty removes them"),
                "enabled": flag("false pauses, true resumes"),
                "notify_when_done": flag("Notify the user when a Run is done"),
            }),
            &["schedule_id"],
        ),
        doc(
            "delete_schedule",
            "Super Agent only. Remove a task and its Run history; its Run Sessions stay. \
        Returns {scheduleID, deleted}. Remove only what the user asked to remove."
                .into(),
            json!({ "schedule_id": task() }),
            &["schedule_id"],
        ),
        doc(
            "run_schedule",
            "Super Agent only. Start a Run now: {scheduleID, runID}. Refused (run_in_progress) \
        while a Run of the task is in progress. Read its outcome later with list_schedule_runs."
                .into(),
            json!({ "schedule_id": task() }),
            &["schedule_id"],
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;

    const SAMPLES: &str = include_str!("../../../protocol/schedules-samples-v1.json");

    fn samples() -> Value {
        serde_json::from_str(SAMPLES).expect("valid schedules samples")
    }

    /// The samples' per-task files under a private root (never this
    /// machine's `UNPEEL_HOME`), plus `extra` Run logs.
    fn with_root<T>(extra: &[(&str, Vec<Value>)], body: impl FnOnce(&Value, &Path) -> T) -> T {
        let samples = samples();
        let seed = &samples["seed"];
        let root = std::env::temp_dir().join(format!("unpeel-smcp-{}", uuid::Uuid::new_v4()));
        for (id, clock) in seed["clocks"].as_object().expect("clocks") {
            fs::create_dir_all(root.join(id)).unwrap();
            fs::write(root.join(id).join("clock.json"), clock.to_string()).unwrap();
        }
        let sample_runs = seed["runs"].as_object().expect("runs");
        let logs = sample_runs
            .iter()
            .map(|(id, lines)| (id.as_str(), lines.as_array().cloned().unwrap_or_default()))
            .chain(extra.iter().map(|(id, lines)| (*id, lines.clone())));
        for (id, lines) in logs {
            fs::create_dir_all(root.join(id)).unwrap();
            let log: String = lines.iter().map(|line| format!("{line}\n")).collect();
            fs::write(root.join(id).join("runs.jsonl"), log).unwrap();
        }
        let outcome = body(&seed["appState"], &root);
        let _ = fs::remove_dir_all(&root);
        outcome
    }

    fn answer(action: &str, arguments: Value, state: &Value, root: &Path) -> Result<Value, String> {
        answer_at(action, &arguments, state, root)
            .map(|text| serde_json::from_str(&text).expect("the answer is JSON"))
    }

    #[test]
    fn the_list_is_the_hosts_list_route_body() {
        let expected = samples()["responses"]["list"]["schedules"].clone();
        with_root(&[], |state, root| {
            let listed = answer("list_schedules", json!({}), state, root).expect("listed");
            assert_eq!(listed["schedules"], expected);
            assert_eq!(listed["revision"].as_str().map(str::len), Some(16));
        });
    }

    #[test]
    fn runs_are_the_hosts_runs_route_body_newest_first() {
        let samples = samples();
        let all = samples["responses"]["runs"]["body"].clone();
        let one = samples["responses"]["limitedRuns"]["body"].clone();
        with_root(&[], |state, root| {
            let id = json!({ "schedule_id": "sch_daily" });
            assert_eq!(answer("list_schedule_runs", id, state, root), Ok(all));
            // `unpeel mcp … limit=1` passes a number; a JSON client may pass a string.
            for limit in [json!(1), json!("1")] {
                let arguments = json!({ "schedule_id": " sch_daily ", "limit": limit });
                assert_eq!(
                    answer("list_schedule_runs", arguments, state, root),
                    Ok(one.clone())
                );
            }
        });
    }

    #[test]
    fn runs_default_to_the_newest_ten() {
        let lines: Vec<Value> = (0..12)
            .map(|n| json!({ "run_id": format!("run_{n:02}"), "status": "done", "late": n == 11 }))
            .collect();
        with_root(&[("sch_cron", lines)], |state, root| {
            let answered = answer(
                "list_schedule_runs",
                json!({ "schedule_id": "sch_cron" }),
                state,
                root,
            )
            .expect("runs");
            let ids: Vec<&str> = answered["runs"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|run| run["runID"].as_str())
                .collect();
            assert_eq!(ids.len(), 10);
            assert_eq!(ids.first(), Some(&"run_11"));
            assert_eq!(ids.last(), Some(&"run_02"));
            assert_eq!(answered["runs"][0]["late"], true);
        });
    }

    #[test]
    fn a_bad_runs_request_says_what_to_pass() {
        with_root(&[], |state, root| {
            let refused = |arguments: Value| {
                answer("list_schedule_runs", arguments, state, root).expect_err("refused")
            };
            assert!(refused(json!({})).contains("schedule_id"));
            assert!(refused(json!({ "schedule_id": "sch_gone" })).contains("list_schedules"));
            assert!(refused(json!({ "schedule_id": "../etc" })).contains("list_schedules"));
            for limit in [json!(0), json!(-1), json!("many"), json!(1.5), json!(true)] {
                let message = refused(json!({ "schedule_id": "sch_daily", "limit": limit }));
                assert!(message.contains("limit"), "{message}");
            }
        });
    }
}
