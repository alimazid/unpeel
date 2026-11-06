//! Scheduled Tasks: the shapes every reader shares.
//!
//! A Scheduled Task (code and CLI: *schedule*) lives in `app-state.json`
//! under `schedules`; its per-task clock and Run log live under
//! `<UNPEEL_HOME>/schedules/<id>/` (`schedule_store`). Only serde types and
//! pure folding live here, so the portable Controller core can decode them:
//! time zones, the clock, and the due rule belong to the Host service
//! (`unpeel_serve::schedules`), never to this crate.
//!
//! Trigger times stay the strings the user typed (`"09:43"`,
//! `"2026-11-06T15:00"`). A reader that cannot interpret one treats the task
//! as never firing; it never fails the document.

use serde::{Deserialize, Deserializer, Serialize};

/// `spawned_by` of a Run's Session is this prefix plus the task id. It names
/// no Session id, so the MCP close rule never lets an agent close one.
pub const SPAWNED_BY_PREFIX: &str = "schedule:";
/// Environment of every Run's Session: the task and the Run it belongs to.
pub const SCHEDULE_ID_ENV: &str = "UNPEEL_SCHEDULE_ID";
pub const SCHEDULE_RUN_ID_ENV: &str = "UNPEEL_SCHEDULE_RUN_ID";
/// Longest task or Run id a reader accepts as a path component.
pub const MAX_ID_LEN: usize = 128;

fn default_true() -> bool {
    true
}

/// One Scheduled Task. Every field but `id` defaults, and a Trigger this
/// build cannot read decodes as [`ScheduleTrigger::Unknown`], so a newer
/// writer costs an older reader the task's firing, never the task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Schedule {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub project_id: String,
    #[serde(default)]
    pub preset_id: String,
    /// What a Run types into the agent once it is ready (ADR 0005). Only a
    /// task on an Agent Preset has them, at most
    /// `initial_text::MAX_INITIAL_TEXT_BYTES`; a task without them runs its
    /// preset like a script, finished by its command's exit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    #[serde(default, deserialize_with = "deserialize_trigger")]
    pub trigger: ScheduleTrigger,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub notify_when_done: bool,
    #[serde(default)]
    pub created_at_ms: u64,
}

impl Schedule {
    /// The `spawned_by` stamp of this task's Run Sessions.
    pub fn spawned_by(&self) -> String {
        format!("{SPAWNED_BY_PREFIX}{}", self.id)
    }
}

/// When a Scheduled Task comes due, on the Host's local wall clock.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ScheduleTrigger {
    /// Once at a local date-time, `YYYY-MM-DDTHH:MM[:SS]`.
    Once { at: String },
    /// Every day at a local time, `HH:MM[:SS]`.
    Daily { time: String },
    /// A kind this build does not know (a newer writer), or a known kind
    /// whose fields do not decode. It never fires.
    #[default]
    #[serde(other)]
    Unknown,
}

impl ScheduleTrigger {
    /// The `kind` tag as stored.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Once { .. } => "once",
            Self::Daily { .. } => "daily",
            Self::Unknown => "unknown",
        }
    }
}

fn deserialize_trigger<'de, D>(deserializer: D) -> Result<ScheduleTrigger, D::Error>
where
    D: Deserializer<'de>,
{
    let raw = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(raw
        .and_then(|value| serde_json::from_value(value).ok())
        .unwrap_or_default())
}

/// `AppState.schedules`: every entry decodes on its own. One that cannot
/// (no string id, a field of the wrong type) is dropped, a repeated id keeps
/// its first entry, and a value that is not a list reads as no tasks, so a
/// damaged task never costs the reader the rest of `app-state.json`.
pub fn deserialize_schedules<'de, D>(deserializer: D) -> Result<Vec<Schedule>, D::Error>
where
    D: Deserializer<'de>,
{
    let raw = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(schedules_from_value(raw.as_ref()))
}

/// The lenient list decode behind [`deserialize_schedules`], for readers of
/// the raw document.
pub fn schedules_from_value(value: Option<&serde_json::Value>) -> Vec<Schedule> {
    let Some(entries) = value.and_then(serde_json::Value::as_array) else {
        return Vec::new();
    };
    let mut schedules: Vec<Schedule> = Vec::new();
    for entry in entries {
        let Ok(schedule) = serde_json::from_value::<Schedule>(entry.clone()) else {
            continue;
        };
        if !is_valid_id(&schedule.id) || schedules.iter().any(|kept| kept.id == schedule.id) {
            continue;
        }
        schedules.push(schedule);
    }
    schedules
}

/// Ids name directories, so only a short run of `[A-Za-z0-9_-]` is one.
pub fn is_valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// What came of a Run.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Running,
    Done,
    NeedsYou,
    FailedToStart,
    Failed,
    Skipped,
    /// A status this build does not know.
    #[default]
    #[serde(other)]
    Unknown,
}

impl RunStatus {
    /// A Run in progress blocks the next occurrence (skipped) and Run now.
    pub fn is_in_progress(self) -> bool {
        matches!(self, Self::Running | Self::NeedsYou)
    }

    pub fn word(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Done => "done",
            Self::NeedsYou => "needs_you",
            Self::FailedToStart => "failed_to_start",
            Self::Failed => "failed",
            Self::Skipped => "skipped",
            Self::Unknown => "unknown",
        }
    }
}

/// One line of a task's `runs.jsonl`. The log is append-only: a Run's later
/// line supersedes its earlier ones ([`fold_runs`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScheduleRun {
    pub run_id: String,
    /// The occurrence it ran for (local date-time); `None` for Run now.
    #[serde(default)]
    pub scheduled_for: Option<String>,
    /// When the Host started it; `None` for a skipped Run.
    #[serde(default)]
    pub started_at_ms: Option<u64>,
    #[serde(default)]
    pub ended_at_ms: Option<u64>,
    #[serde(default)]
    pub status: RunStatus,
    /// Started more than 2 minutes after its occurrence.
    #[serde(default)]
    pub late: bool,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub snippet: Option<String>,
    /// Where an agent Run (a task with instructions) is in its lifecycle;
    /// `None` for a script Run. Kept on its finished line too, so a
    /// `needs_you` Run says whether the agent ever started working.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<RunPhase>,
    /// When an agent Run's instructions were typed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompted_at_ms: Option<u64>,
}

/// An agent Run's lifecycle: `launching` (its Session starting),
/// `waiting_ready` (for the agent's first readiness signal), `prompted`
/// (instructions typed, no working signal yet), `working`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunPhase {
    Launching,
    WaitingReady,
    Prompted,
    Working,
    /// A phase this build does not know.
    #[serde(other)]
    Unknown,
}

impl RunPhase {
    pub fn word(self) -> &'static str {
        match self {
            Self::Launching => "launching",
            Self::WaitingReady => "waiting_ready",
            Self::Prompted => "prompted",
            Self::Working => "working",
            Self::Unknown => "unknown",
        }
    }
}

/// Each Run's latest line, in the order the Runs first appeared (oldest
/// first). Lines without a Run id are ignored.
pub fn fold_runs(lines: impl IntoIterator<Item = ScheduleRun>) -> Vec<ScheduleRun> {
    let mut runs: Vec<ScheduleRun> = Vec::new();
    for run in lines {
        if run.run_id.is_empty() {
            continue;
        }
        match runs.iter_mut().find(|kept| kept.run_id == run.run_id) {
            Some(kept) => *kept = run,
            None => runs.push(run),
        }
    }
    runs
}

/// A task's `clock.json`: the last occurrence the Host fired (the due rule's
/// whole memory), plus facts it publishes so readers without a clock (MCP,
/// Controllers) can show the next run and the last result.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScheduleClock {
    /// Local date-time of the last occurrence fired or skipped.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_occurrence: Option<String>,
    /// The next occurrence the Host will fire, as a local date-time and as
    /// an instant in the zone it was computed in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_occurrence: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_occurrence_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_status: Option<RunStatus>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(value: serde_json::Value) -> Vec<Schedule> {
        schedules_from_value(Some(&value))
    }

    #[test]
    fn a_task_decodes_with_its_defaults() {
        let schedules = decode(serde_json::json!([{
            "id": "sch_1",
            "name": "Morning",
            "project_id": "p",
            "preset_id": "ok",
            "trigger": {"kind": "daily", "time": "09:43"},
            "created_at_ms": 7
        }]));
        assert_eq!(
            schedules,
            vec![Schedule {
                id: "sch_1".into(),
                name: "Morning".into(),
                project_id: "p".into(),
                preset_id: "ok".into(),
                instructions: None,
                trigger: ScheduleTrigger::Daily {
                    time: "09:43".into()
                },
                enabled: true,
                notify_when_done: true,
                created_at_ms: 7,
            }]
        );
    }

    #[test]
    fn an_unknown_trigger_kind_keeps_the_task_and_never_names_a_time() {
        let schedules = decode(serde_json::json!([
            {"id": "sch_future", "trigger": {"kind": "fortnightly", "weekday": "mon"}},
            {"id": "sch_bad_daily", "trigger": {"kind": "daily"}},
            {"id": "sch_no_trigger"}
        ]));
        let triggers: Vec<_> = schedules
            .iter()
            .map(|s| (s.id.as_str(), &s.trigger))
            .collect();
        assert_eq!(
            triggers,
            vec![
                ("sch_future", &ScheduleTrigger::Unknown),
                ("sch_bad_daily", &ScheduleTrigger::Unknown),
                ("sch_no_trigger", &ScheduleTrigger::Unknown),
            ]
        );
    }

    #[test]
    fn an_entry_that_cannot_decode_is_dropped_alone() {
        let schedules = decode(serde_json::json!([
            "not an object",
            {"name": "no id"},
            {"id": 5},
            {"id": "../escape"},
            {"id": "sch_ok", "enabled": false},
            {"id": "sch_ok", "name": "a second entry with the same id"},
            {"id": "sch_wrong_type", "enabled": "yes"}
        ]));
        let ids: Vec<_> = schedules.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, vec!["sch_ok"]);
        assert!(!schedules[0].enabled);
        assert_eq!(schedules[0].name, "");
    }

    #[test]
    fn schedules_that_are_not_a_list_read_as_none() {
        assert!(decode(serde_json::json!({"sch_1": {}})).is_empty());
        assert!(schedules_from_value(None).is_empty());
    }

    #[test]
    fn a_later_line_supersedes_its_run_in_first_seen_order() {
        let line = |run_id: &str, status: RunStatus| ScheduleRun {
            run_id: run_id.into(),
            scheduled_for: None,
            started_at_ms: Some(1),
            ended_at_ms: None,
            status,
            late: false,
            session_id: None,
            exit_code: None,
            reason: None,
            snippet: None,
            phase: None,
            prompted_at_ms: None,
        };
        let folded = fold_runs([
            line("run_a", RunStatus::Running),
            line("run_b", RunStatus::Skipped),
            line("", RunStatus::Done),
            line("run_a", RunStatus::Done),
        ]);
        let statuses: Vec<_> = folded
            .iter()
            .map(|r| (r.run_id.as_str(), r.status))
            .collect();
        assert_eq!(
            statuses,
            vec![("run_a", RunStatus::Done), ("run_b", RunStatus::Skipped)]
        );
    }

    #[test]
    fn a_task_on_an_agent_preset_carries_its_instructions() {
        let schedules = decode(serde_json::json!([
            {"id": "sch_agent", "preset_id": "claude", "instructions": "run the briefing"},
            {"id": "sch_script", "preset_id": "ok"}
        ]));
        assert_eq!(
            schedules[0].instructions.as_deref(),
            Some("run the briefing")
        );
        assert_eq!(schedules[1].instructions, None);
        let written = serde_json::to_value(&schedules[1]).unwrap();
        assert!(
            written.get("instructions").is_none(),
            "a script task writes no instructions key: {written}"
        );
    }

    #[test]
    fn an_agent_runs_phase_round_trips_and_a_newer_one_keeps_the_line() {
        let line: ScheduleRun = serde_json::from_value(serde_json::json!({
            "run_id": "run_a", "status": "running", "phase": "prompted",
            "prompted_at_ms": 42
        }))
        .unwrap();
        assert_eq!(line.phase, Some(RunPhase::Prompted));
        assert_eq!(line.prompted_at_ms, Some(42));
        let script: ScheduleRun =
            serde_json::from_value(serde_json::json!({"run_id": "run_b", "status": "done"}))
                .unwrap();
        assert_eq!((script.phase, script.prompted_at_ms), (None, None));
        let written = serde_json::to_value(&script).unwrap();
        assert!(written.get("phase").is_none(), "{written}");
        let newer: ScheduleRun = serde_json::from_value(
            serde_json::json!({"run_id": "run_c", "status": "running", "phase": "thinking"}),
        )
        .unwrap();
        assert_eq!(newer.phase, Some(RunPhase::Unknown));
    }

    #[test]
    fn an_unknown_run_status_is_not_in_progress() {
        let status: RunStatus = serde_json::from_str("\"paused_forever\"").unwrap();
        assert_eq!(status, RunStatus::Unknown);
        assert!(!status.is_in_progress());
        assert!(RunStatus::Running.is_in_progress());
        assert!(RunStatus::NeedsYou.is_in_progress());
    }
}
