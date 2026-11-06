//! Fork-only: Scheduled Tasks in the `workspace` MCP tool, read-only
//! (decisions Q8, Q26).
//!
//! An agent lists the workspace's tasks and reads one task's Run history;
//! creating, editing, running and removing tasks stays the user's, so there
//! is no write action here (and `unpeel schedules` refuses its mutating
//! verbs inside a Session). The answers are the Host's `GET
//! /mobile/schedules` and `GET /mobile/schedules/runs` bodies
//! (`controller_schedules`, pinned by `protocol/schedules-samples-v1.json`),
//! read from disk: the MCP server is a core process and never reaches the
//! workspace worker, which publishes each task's next run and Runs there.

use std::collections::HashMap;
use std::path::Path;

use serde_json::{json, Value};

use crate::controller_schedules;
use crate::schedule_store;
use crate::schedules;

/// The `workspace` actions this module answers.
pub const SCHEDULES_ACTIONS: &[&str] = &["list_schedules", "list_schedule_runs"];

/// Runs `list_schedule_runs` returns when the caller names no `limit`: enough
/// to see a pattern, small enough to keep an agent's context lean.
pub const RUNS_DEFAULT_LIMIT: usize = 10;

/// Answer one of [`SCHEDULES_ACTIONS`] from this workspace's
/// `app-state.json` and per-task files. The caller has passed the Sessions
/// gate; reads need no role.
pub fn run_action(action: &str, arguments: &Value) -> Result<String, String> {
    let state = crate::app_state::load()
        .map_err(|error| format!("Could not read Scheduled Tasks: {error}"))?;
    answer_at(action, arguments, &state, &schedule_store::schedules_root())
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
    serde_json::to_string_pretty(&body)
        .map_err(|error| format!("Failed to encode Scheduled Tasks: {error}"))
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
    vec![
        json!({
            "name": "list_schedules",
            "description": "List the workspace's Scheduled Tasks, read-only: each task's id, \
        name, projectID, presetID, trigger, enabled, nextRun (null when paused or nothing is \
        due) and lastRun (the Run in progress, else the latest: its status, times, late marker \
        and snippet). Only the user creates, edits, runs or removes tasks.",
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
