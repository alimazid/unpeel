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

pub mod run_sessions;
#[cfg(feature = "native-host")]
pub mod save;

/// `spawned_by` of a Run's Session is this prefix plus the task id. It names
/// no Session id, so the MCP close rule never lets an agent close one.
pub const SPAWNED_BY_PREFIX: &str = "schedule:";
/// Environment of every Run's Session: the task and the Run it belongs to.
pub const SCHEDULE_ID_ENV: &str = "UNPEEL_SCHEDULE_ID";
pub const SCHEDULE_RUN_ID_ENV: &str = "UNPEEL_SCHEDULE_RUN_ID";
/// Longest task or Run id a reader accepts as a path component.
pub const MAX_ID_LEN: usize = 128;
/// Most characters a task name keeps.
pub const MAX_NAME_CHARS: usize = 200;

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
    /// When the task's clock last restarted: on Resume, and when its
    /// Trigger changed. No occurrence at or before it fires, so a paused
    /// task never catches up and a moved Trigger never fires a time that
    /// passed before the move. Absent, the clock counts from creation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clock_reset_at_ms: Option<u64>,
}

impl Schedule {
    /// The `spawned_by` stamp of this task's Run Sessions.
    pub fn spawned_by(&self) -> String {
        format!("{SPAWNED_BY_PREFIX}{}", self.id)
    }

    /// The instant the task's clock counts from: only occurrences after it
    /// (and after the last one fired) are due.
    pub fn counts_from_ms(&self) -> u64 {
        self.clock_reset_at_ms.unwrap_or(0).max(self.created_at_ms)
    }
}

/// When a Scheduled Task comes due, on the Host's local wall clock.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ScheduleTrigger {
    /// Every hour at this minute past it, `0..=59`.
    Hourly { minute: u8 },
    /// Every day at a local time, `HH:MM[:SS]`.
    Daily { time: String },
    /// Monday to Friday at a local time.
    Weekdays { time: String },
    /// One day a week at a local time; the day's lowercase English name
    /// (`"monday"` … `"sunday"`).
    Weekly { weekday: String, time: String },
    /// Once at a local date-time, `YYYY-MM-DDTHH:MM[:SS]`.
    Once { at: String },
    /// A 5-field cron expression (minute hour day-of-month month
    /// day-of-week), read on the local wall clock. Created from the CLI only.
    Cron { expr: String },
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
            Self::Hourly { .. } => "hourly",
            Self::Daily { .. } => "daily",
            Self::Weekdays { .. } => "weekdays",
            Self::Weekly { .. } => "weekly",
            Self::Once { .. } => "once",
            Self::Cron { .. } => "cron",
            Self::Unknown => "unknown",
        }
    }
}

/// A user's change to one task; `None` leaves a field as it is. Pausing is
/// `enabled: Some(false)`, resuming `Some(true)`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScheduleEdit {
    pub name: Option<String>,
    pub project_id: Option<String>,
    pub preset_id: Option<String>,
    pub trigger: Option<ScheduleTrigger>,
    pub enabled: Option<bool>,
    pub notify_when_done: Option<bool>,
    /// `Some(Some(text))` sets the instructions, `Some(None)` removes them.
    /// The writer checks the task's preset takes them.
    pub instructions: Option<Option<String>>,
}

/// `entry`, a task as stored in `app-state.json`, with `edit` applied.
/// Every writer edits the raw entry, so fields this build does not know
/// pass through. Resuming a paused task or giving it a different Trigger
/// restarts its clock at `now_ms` ([`Schedule::clock_reset_at_ms`]): the
/// occurrences before that never fire.
pub fn apply_edit(
    entry: &serde_json::Map<String, serde_json::Value>,
    edit: &ScheduleEdit,
    now_ms: u64,
) -> serde_json::Map<String, serde_json::Value> {
    use serde_json::Value;
    let mut edited = entry.clone();
    let mut restart = false;
    for (key, value) in [
        ("name", &edit.name),
        ("project_id", &edit.project_id),
        ("preset_id", &edit.preset_id),
    ] {
        if let Some(value) = value {
            edited.insert(key.into(), Value::String(value.clone()));
        }
    }
    if let Some(trigger) = &edit.trigger {
        let trigger = serde_json::to_value(trigger).unwrap_or(Value::Null);
        restart |= entry.get("trigger") != Some(&trigger);
        edited.insert("trigger".into(), trigger);
    }
    if let Some(enabled) = edit.enabled {
        let was_enabled = entry
            .get("enabled")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        restart |= enabled && !was_enabled;
        edited.insert("enabled".into(), Value::Bool(enabled));
    }
    if let Some(notify) = edit.notify_when_done {
        edited.insert("notify_when_done".into(), Value::Bool(notify));
    }
    match &edit.instructions {
        Some(Some(text)) => {
            edited.insert("instructions".into(), Value::String(text.clone()));
        }
        Some(None) => {
            edited.remove("instructions");
        }
        None => {}
    }
    if restart {
        edited.insert("clock_reset_at_ms".into(), Value::from(now_ms));
    }
    edited
}

/// A task name as every writer saves it: trimmed, without control
/// characters, at most [`MAX_NAME_CHARS`].
pub fn task_name(raw: &str) -> Result<String, String> {
    let name = raw.trim();
    if name.is_empty() {
        return Err("a task needs a name".into());
    }
    if name.chars().any(char::is_control) {
        return Err("a task name cannot contain control characters".into());
    }
    Ok(name.chars().take(MAX_NAME_CHARS).collect())
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

impl ScheduleRun {
    /// An agent Run (a task on an Agent Preset): it follows its agent's
    /// lifecycle, which its `phase` records, instead of a command's exit.
    pub fn is_agent_run(&self) -> bool {
        self.phase.is_some()
    }

    /// An agent Run still starting: its Session launching, or its agent not
    /// ready for the instructions yet.
    pub fn is_starting_agent(&self) -> bool {
        matches!(
            self.phase,
            Some(RunPhase::Launching | RunPhase::WaitingReady)
        )
    }
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

/// The Run that speaks for a task (its "latest Run"), from its folded Runs:
/// the one in progress, if any — an occurrence skipped behind it never
/// takes its place, so the Host keeps following it, it keeps blocking the
/// next occurrence and Run now, and Controllers keep showing it — else the
/// newest outcome (when it ended, or started), the later Run on a tie. A
/// Run that says nothing of its time counts as new as the Runs before it.
pub fn current_run(runs: &[ScheduleRun]) -> Option<&ScheduleRun> {
    if let Some(live) = runs.iter().rev().find(|run| run.status.is_in_progress()) {
        return Some(live);
    }
    let mut newest: Option<(u64, &ScheduleRun)> = None;
    let mut latest_seen = 0;
    for run in runs {
        let at = run
            .ended_at_ms
            .or(run.started_at_ms)
            .unwrap_or(latest_seen);
        latest_seen = latest_seen.max(at);
        if newest.is_none_or(|(best, _)| at >= best) {
            newest = Some((at, run));
        }
    }
    newest.map(|(_, run)| run)
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
                clock_reset_at_ms: None,
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

    fn stored_entry() -> serde_json::Map<String, serde_json::Value> {
        serde_json::json!({
            "id": "sch_1",
            "name": "Morning",
            "project_id": "p",
            "preset_id": "ok",
            "trigger": {"kind": "daily", "time": "09:00"},
            "enabled": true,
            "notify_when_done": true,
            "created_at_ms": 7,
            "instructions": "from a newer build",
            "a_future_field": [1, 2]
        })
        .as_object()
        .cloned()
        .unwrap()
    }

    #[test]
    fn an_edit_changes_only_the_fields_it_names() {
        let entry = stored_entry();
        let edited = apply_edit(
            &entry,
            &ScheduleEdit {
                name: Some("Evening".into()),
                preset_id: Some("other".into()),
                notify_when_done: Some(false),
                ..ScheduleEdit::default()
            },
            1_000,
        );
        let mut expected = entry.clone();
        expected.insert("name".into(), "Evening".into());
        expected.insert("preset_id".into(), "other".into());
        expected.insert("notify_when_done".into(), false.into());
        assert_eq!(edited, expected, "unknown fields pass through");
    }

    #[test]
    fn an_edit_sets_or_removes_instructions_and_otherwise_keeps_them() {
        let set = ScheduleEdit {
            instructions: Some(Some("brief me".into())),
            ..ScheduleEdit::default()
        };
        let edited = apply_edit(&stored_entry(), &set, 1_000);
        assert_eq!(edited.get("instructions"), Some(&"brief me".into()));
        assert_eq!(edited.get("clock_reset_at_ms"), None, "the clock is kept");

        let remove = ScheduleEdit {
            instructions: Some(None),
            ..ScheduleEdit::default()
        };
        assert_eq!(
            apply_edit(&edited, &remove, 1_000).get("instructions"),
            None
        );

        let rename = ScheduleEdit {
            name: Some("Evening".into()),
            ..ScheduleEdit::default()
        };
        assert_eq!(
            apply_edit(&edited, &rename, 1_000).get("instructions"),
            Some(&"brief me".into())
        );
    }

    #[test]
    fn a_new_trigger_restarts_the_clock_and_the_same_one_does_not() {
        let hourly = ScheduleEdit {
            trigger: Some(ScheduleTrigger::Hourly { minute: 15 }),
            ..ScheduleEdit::default()
        };
        let edited = apply_edit(&stored_entry(), &hourly, 1_000);
        assert_eq!(
            edited.get("trigger"),
            Some(&serde_json::json!({"kind": "hourly", "minute": 15}))
        );
        assert_eq!(edited.get("clock_reset_at_ms"), Some(&1_000.into()));

        let same = ScheduleEdit {
            trigger: Some(ScheduleTrigger::Daily {
                time: "09:00".into(),
            }),
            ..ScheduleEdit::default()
        };
        assert_eq!(apply_edit(&stored_entry(), &same, 1_000), stored_entry());
    }

    #[test]
    fn resuming_restarts_the_clock_and_pausing_keeps_it() {
        let pause = ScheduleEdit {
            enabled: Some(false),
            ..ScheduleEdit::default()
        };
        let paused = apply_edit(&stored_entry(), &pause, 1_000);
        assert_eq!(paused.get("enabled"), Some(&false.into()));
        assert_eq!(paused.get("clock_reset_at_ms"), None);

        let resume = ScheduleEdit {
            enabled: Some(true),
            ..ScheduleEdit::default()
        };
        let resumed = apply_edit(&paused, &resume, 2_000);
        assert_eq!(resumed.get("enabled"), Some(&true.into()));
        assert_eq!(resumed.get("clock_reset_at_ms"), Some(&2_000.into()));
        assert_eq!(
            apply_edit(&resumed, &resume, 3_000),
            resumed,
            "a task already running is not resumed again"
        );

        let mut never_said = stored_entry();
        never_said.remove("enabled");
        assert_eq!(
            apply_edit(&never_said, &resume, 3_000).get("clock_reset_at_ms"),
            None,
            "a task with no enabled field is enabled"
        );
    }

    #[test]
    fn the_clock_counts_from_the_later_of_creation_and_a_restart() {
        let mut schedule = decode(serde_json::json!([stored_entry()])).remove(0);
        assert_eq!(schedule.counts_from_ms(), 7);
        schedule.clock_reset_at_ms = Some(2_000);
        assert_eq!(schedule.counts_from_ms(), 2_000);
        schedule.clock_reset_at_ms = Some(3);
        assert_eq!(schedule.counts_from_ms(), 7);
    }

    #[test]
    fn every_trigger_kind_round_trips_its_stored_form() {
        let stored = serde_json::json!([
            {"kind": "hourly", "minute": 15},
            {"kind": "daily", "time": "09:43"},
            {"kind": "weekdays", "time": "08:30"},
            {"kind": "weekly", "weekday": "friday", "time": "17:00"},
            {"kind": "once", "at": "2026-11-06T15:00"},
            {"kind": "cron", "expr": "*/15 9-17 * * 1-5"}
        ]);
        let triggers: Vec<ScheduleTrigger> = serde_json::from_value(stored.clone()).unwrap();
        let kinds: Vec<_> = triggers.iter().map(ScheduleTrigger::kind).collect();
        assert_eq!(
            kinds,
            vec!["hourly", "daily", "weekdays", "weekly", "once", "cron"]
        );
        assert_eq!(serde_json::to_value(&triggers).unwrap(), stored);
    }

    #[test]
    fn an_hourly_minute_that_is_not_a_small_number_never_names_a_time() {
        let schedules = decode(serde_json::json!([
            {"id": "sch_big", "trigger": {"kind": "hourly", "minute": 300}},
            {"id": "sch_text", "trigger": {"kind": "hourly", "minute": "15"}}
        ]));
        assert!(schedules
            .iter()
            .all(|schedule| schedule.trigger == ScheduleTrigger::Unknown));
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

    fn run_at(
        run_id: &str,
        status: RunStatus,
        started: Option<u64>,
        ended: Option<u64>,
    ) -> ScheduleRun {
        ScheduleRun {
            run_id: run_id.into(),
            scheduled_for: None,
            started_at_ms: started,
            ended_at_ms: ended,
            status,
            late: false,
            session_id: None,
            exit_code: None,
            reason: None,
            snippet: None,
            phase: None,
            prompted_at_ms: None,
        }
    }

    #[test]
    fn the_run_in_progress_speaks_for_its_task_over_a_skipped_one_behind_it() {
        let live = run_at("run_live", RunStatus::Running, Some(10), None);
        let skipped = run_at("run_skipped", RunStatus::Skipped, None, Some(20));
        let runs = vec![live.clone(), skipped.clone()];
        assert_eq!(current_run(&runs), Some(&live));

        let waiting = ScheduleRun {
            status: RunStatus::NeedsYou,
            ..live.clone()
        };
        assert_eq!(
            current_run(&[waiting.clone(), skipped.clone()]),
            Some(&waiting)
        );

        // Once it finishes, the newest outcome is the task's latest Run,
        // whatever order the log first saw them in.
        let finished = ScheduleRun {
            status: RunStatus::Done,
            ended_at_ms: Some(30),
            ..live
        };
        assert_eq!(
            current_run(&[finished.clone(), skipped.clone()]),
            Some(&finished)
        );
        let earlier = ScheduleRun {
            ended_at_ms: Some(15),
            ..finished
        };
        assert_eq!(
            current_run(&[earlier.clone(), skipped.clone()]),
            Some(&skipped)
        );
        // A line that says nothing of its time reads at its place in the log.
        let timeless = run_at("run_from_disk", RunStatus::Skipped, None, None);
        assert_eq!(
            current_run(&[earlier, timeless.clone()]),
            Some(&timeless)
        );
        assert_eq!(current_run(&[]), None);
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
