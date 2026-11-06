//! The scheduler's step: definitions, clocks, Run states and the current
//! zoned time in, actions out. Pure, so every due and Run rule is tested
//! with injected time; the worker (`super::Scheduler`) reads the inputs and
//! performs the actions, in order.
//!
//! Due rule: a task fires one Run for the latest occurrence after the last
//! one it fired (a new task: after its creation) and at or before now, so a
//! gap of days catches up exactly once. The clock that records the
//! occurrence is always saved before the Run starts, so a crash can never
//! fire it twice. A Run that starts more than 2 minutes after its
//! occurrence is late. An occurrence that falls while the latest Run is
//! still in progress is recorded as skipped.

use jiff::Zoned;
use unpeel_core::schedules::{RunPhase, RunStatus, Schedule, ScheduleClock, ScheduleRun};

use super::agent_run::{self, AgentObservation};
use super::clock;
use super::trigger::Trigger;

/// A Run that starts later than this after its occurrence is late.
pub const LATE_AFTER_MS: u64 = 2 * 60_000;

/// Where a Run of a task starts: the preset's command as typed, in the
/// Project's directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub project_id: String,
    pub preset_id: String,
    pub command: String,
    pub cwd: String,
    pub worktree_path: Option<String>,
    pub worktree_branch: Option<String>,
    /// The preset is an Agent Preset: the Run follows the agent lifecycle
    /// (`agent_run`) instead of its command's exit.
    pub agent: bool,
    /// Typed into the agent once it is ready; `Some` only when `agent`.
    /// Without them the Run is done once the agent is ready.
    pub instructions: Option<String>,
}

/// What the Host sees of a running Run's Session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunObservation {
    /// No running Run to observe.
    Idle,
    /// Its Session is still being started.
    Launching,
    /// Its Session is up and the command has not exited.
    Live,
    /// The command exited with this status (`startup-exit`).
    Exited(i32),
    /// The Session stopped without recording its command's exit status.
    Ended,
    /// The Session no longer exists.
    Missing,
    /// The Session could not be started.
    SpawnFailed(String),
    /// An agent Run's Session is up and its command has not exited.
    Agent(AgentObservation),
}

/// One task as the step sees it.
#[derive(Debug, Clone)]
pub struct TaskState {
    pub schedule: Schedule,
    pub clock: ScheduleClock,
    pub latest_run: Option<ScheduleRun>,
    pub observation: RunObservation,
    /// An accepted Run now request: its Run id.
    pub run_now: Option<String>,
    /// Where a Run would start, or why it cannot.
    pub launch: Result<LaunchPlan, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Persist the task's clock. Always ahead of any Run it starts.
    SaveClock {
        schedule_id: String,
        clock: ScheduleClock,
    },
    /// Record the Run as running and start its Session.
    Start {
        schedule_id: String,
        run: ScheduleRun,
        plan: LaunchPlan,
    },
    /// Append a Run line (finished, failed before launch, or skipped).
    Record {
        schedule_id: String,
        run: ScheduleRun,
    },
    /// A Once task has had its Run.
    Disable { schedule_id: String },
}

/// One step over every task. A task's actions are in the order they must
/// be performed: its clock first, then its Run lines and Starts.
pub fn step(
    tasks: &[TaskState],
    now: &Zoned,
    new_run_id: &mut dyn FnMut() -> String,
) -> Vec<Action> {
    let mut actions = Vec::new();
    for task in tasks {
        step_task(task, now, new_run_id, &mut actions);
    }
    actions
}

/// The latest Run as this step leaves it: what the clock publishes, and
/// whether it still blocks the next one.
struct LatestRun {
    id: Option<String>,
    status: Option<RunStatus>,
}

impl LatestRun {
    fn in_progress(&self) -> bool {
        self.status.is_some_and(RunStatus::is_in_progress)
    }

    /// A Run in progress stays the latest until its own next line: a Run
    /// skipped behind it never takes its place (`schedules::current_run`).
    fn update(&mut self, run: &ScheduleRun) {
        let behind = self.in_progress() && self.id.as_deref() != Some(run.run_id.as_str());
        if behind && run.status == RunStatus::Skipped {
            return;
        }
        self.id = Some(run.run_id.clone());
        self.status = Some(run.status);
    }

    fn observe(&mut self, action: &Action) {
        if let Action::Start { run, .. } | Action::Record { run, .. } = action {
            self.update(run);
        }
    }
}

fn step_task(
    task: &TaskState,
    now: &Zoned,
    new_run_id: &mut dyn FnMut() -> String,
    actions: &mut Vec<Action>,
) {
    let now_ms = clock::epoch_ms(now);
    let schedule_id = &task.schedule.id;
    let mut runs = Vec::new();
    let mut latest = LatestRun {
        id: task.latest_run.as_ref().map(|run| run.run_id.clone()),
        status: task.latest_run.as_ref().map(|run| run.status),
    };

    runs.extend(finish_latest(task, &mut latest, now_ms));

    if let Some(run_id) = &task.run_now {
        let start = RunStart {
            run_id: run_id.clone(),
            scheduled_for: None,
            late: false,
            skip_reason: "a Run was already in progress",
        };
        runs.push(skip_or_launch(task, &mut latest, start, now_ms));
    }

    let trigger = Trigger::parse(&task.schedule.trigger).filter(|_| task.schedule.enabled);
    let mut after = super::trigger::counts_from(&task.schedule, &task.clock, now.time_zone());
    let mut last_occurrence = task.clock.last_occurrence.clone();
    let due = trigger.zip(after).and_then(|(trigger, after)| {
        trigger
            .latest_due(after, now.datetime())
            .map(|occurrence| (trigger, occurrence))
    });
    if let Some((trigger, occurrence)) = due {
        after = Some(occurrence);
        last_occurrence = Some(clock::format_datetime(occurrence));
        runs.extend(fire(task, &mut latest, trigger, occurrence, now, new_run_id));
    }

    let clock = clock_after(trigger, after, last_occurrence, latest, now.time_zone());
    if clock != task.clock {
        actions.push(Action::SaveClock {
            schedule_id: schedule_id.clone(),
            clock,
        });
    }
    actions.extend(runs);
}

/// The latest Run's next line, once its Session (or agent) says how it
/// ended or where it is; it becomes the latest as the clock publishes it.
fn finish_latest(task: &TaskState, latest: &mut LatestRun, now_ms: u64) -> Option<Action> {
    let finished = finish(task.latest_run.as_ref()?, &task.observation, now_ms)?;
    latest.update(&finished);
    Some(record(&task.schedule.id, finished))
}

/// The clock a step leaves: the last occurrence it fired, the next one
/// after it, and the latest Run as it stands.
fn clock_after(
    trigger: Option<Trigger>,
    after: Option<jiff::civil::DateTime>,
    last_occurrence: Option<String>,
    latest: LatestRun,
    zone: &jiff::tz::TimeZone,
) -> ScheduleClock {
    let next = trigger
        .zip(after)
        .and_then(|(trigger, after)| trigger.next_after(after));
    ScheduleClock {
        last_occurrence,
        next_occurrence: next.map(clock::format_datetime),
        next_occurrence_ms: next.and_then(|next| clock::due_ms(next, zone)),
        last_run_id: latest.id,
        last_run_status: latest.status,
    }
}

/// A Run about to begin, for Run now or an occurrence.
struct RunStart {
    run_id: String,
    scheduled_for: Option<String>,
    late: bool,
    /// Why it is skipped when the latest Run is still in progress.
    skip_reason: &'static str,
}

/// The Run's line: skipped while the latest Run is still in progress, else
/// started. Either becomes the latest as the clock publishes it.
fn skip_or_launch(task: &TaskState, latest: &mut LatestRun, start: RunStart, now_ms: u64) -> Action {
    let action = if latest.in_progress() {
        record(
            &task.schedule.id,
            skipped(start.run_id, start.scheduled_for, now_ms, start.skip_reason),
        )
    } else {
        launch(task, start.run_id, start.scheduled_for, start.late, now_ms)
    };
    latest.observe(&action);
    action
}

/// A due occurrence's Run (late when it starts more than
/// [`LATE_AFTER_MS`] after it), and a Once task's switching off.
fn fire(
    task: &TaskState,
    latest: &mut LatestRun,
    trigger: Trigger,
    occurrence: jiff::civil::DateTime,
    now: &Zoned,
    new_run_id: &mut dyn FnMut() -> String,
) -> Vec<Action> {
    let now_ms = clock::epoch_ms(now);
    let late = clock::due_ms(occurrence, now.time_zone())
        .is_some_and(|due_ms| now_ms.saturating_sub(due_ms) > LATE_AFTER_MS);
    let start = RunStart {
        run_id: new_run_id(),
        scheduled_for: Some(clock::format_datetime(occurrence)),
        late,
        skip_reason: "the previous Run was still in progress",
    };
    let mut runs = vec![skip_or_launch(task, latest, start, now_ms)];
    if trigger.is_once() {
        runs.push(Action::Disable {
            schedule_id: task.schedule.id.clone(),
        });
    }
    runs
}

/// The Run's next line, once its Session says how it ended (a script Run)
/// or where its agent is (an agent Run, `agent_run`).
fn finish(run: &ScheduleRun, observation: &RunObservation, now_ms: u64) -> Option<ScheduleRun> {
    if run.phase.is_some() && run.status.is_in_progress() {
        return agent_run::advance(run, observation, now_ms);
    }
    if run.status != RunStatus::Running {
        return None;
    }
    let (status, exit_code, reason) = match observation {
        RunObservation::Exited(0) => (RunStatus::Done, Some(0), None),
        RunObservation::Exited(code) => (
            RunStatus::Failed,
            Some(*code),
            Some(format!("the command exited with status {code}")),
        ),
        RunObservation::Idle
        | RunObservation::Launching
        | RunObservation::Live
        | RunObservation::Agent(_) => return None,
        lost => (RunStatus::Failed, None, session_lost(lost)),
    };
    Some(ScheduleRun {
        status,
        exit_code,
        reason,
        ended_at_ms: Some(now_ms),
        ..run.clone()
    })
}

/// Why a Run whose Session went away failed; `None` while it is still there.
pub(super) fn session_lost(observation: &RunObservation) -> Option<String> {
    match observation {
        RunObservation::Ended => {
            Some("the Session ended before its command reported an exit status".to_string())
        }
        RunObservation::Missing => Some("the Run's Session no longer exists".to_string()),
        RunObservation::SpawnFailed(error) => Some(format!("the Session could not start: {error}")),
        RunObservation::Idle
        | RunObservation::Launching
        | RunObservation::Live
        | RunObservation::Exited(_)
        | RunObservation::Agent(_) => None,
    }
}

/// Start the Run, or record it failed when it cannot start (the Project or
/// preset is gone): the task itself stays as it is.
fn launch(
    task: &TaskState,
    run_id: String,
    scheduled_for: Option<String>,
    late: bool,
    now_ms: u64,
) -> Action {
    let run = ScheduleRun {
        run_id,
        scheduled_for,
        started_at_ms: Some(now_ms),
        ended_at_ms: None,
        status: RunStatus::Running,
        late,
        session_id: None,
        exit_code: None,
        reason: None,
        snippet: None,
        phase: None,
        prompted_at_ms: None,
    };
    match &task.launch {
        Ok(plan) => Action::Start {
            schedule_id: task.schedule.id.clone(),
            run: ScheduleRun {
                phase: plan.agent.then_some(RunPhase::Launching),
                ..run
            },
            plan: plan.clone(),
        },
        Err(reason) => record(
            &task.schedule.id,
            ScheduleRun {
                status: RunStatus::Failed,
                ended_at_ms: Some(now_ms),
                reason: Some(reason.clone()),
                ..run
            },
        ),
    }
}

fn skipped(
    run_id: String,
    scheduled_for: Option<String>,
    now_ms: u64,
    reason: &str,
) -> ScheduleRun {
    ScheduleRun {
        run_id,
        scheduled_for,
        started_at_ms: None,
        ended_at_ms: Some(now_ms),
        status: RunStatus::Skipped,
        late: false,
        session_id: None,
        exit_code: None,
        reason: Some(reason.to_string()),
        snippet: None,
        phase: None,
        prompted_at_ms: None,
    }
}

fn record(schedule_id: &str, run: ScheduleRun) -> Action {
    Action::Record {
        schedule_id: schedule_id.to_string(),
        run,
    }
}

#[cfg(test)]
mod tests;
