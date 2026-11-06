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

    if let Some(finished) = task
        .latest_run
        .as_ref()
        .and_then(|run| finish(run, &task.observation, now_ms))
    {
        latest.update(&finished);
        runs.push(record(schedule_id, finished));
    }

    if let Some(run_id) = &task.run_now {
        let action = if latest.in_progress() {
            record(
                schedule_id,
                skipped(
                    run_id.clone(),
                    None,
                    now_ms,
                    "a Run was already in progress",
                ),
            )
        } else {
            launch(task, run_id.clone(), None, false, now_ms)
        };
        latest.observe(&action);
        runs.push(action);
    }

    let trigger = Trigger::parse(&task.schedule.trigger).filter(|_| task.schedule.enabled);
    let zone = now.time_zone();
    let mut after = super::trigger::counts_from(&task.schedule, &task.clock, zone);
    let mut last_occurrence = task.clock.last_occurrence.clone();
    if let Some((trigger, occurrence)) = trigger.zip(after).and_then(|(trigger, after)| {
        trigger
            .latest_due(after, now.datetime())
            .map(|occurrence| (trigger, occurrence))
    }) {
        after = Some(occurrence);
        let scheduled_for = clock::format_datetime(occurrence);
        last_occurrence = Some(scheduled_for.clone());
        let action = if latest.in_progress() {
            record(
                schedule_id,
                skipped(
                    new_run_id(),
                    Some(scheduled_for),
                    now_ms,
                    "the previous Run was still in progress",
                ),
            )
        } else {
            let late = clock::due_ms(occurrence, zone)
                .is_some_and(|due_ms| now_ms.saturating_sub(due_ms) > LATE_AFTER_MS);
            launch(task, new_run_id(), Some(scheduled_for), late, now_ms)
        };
        latest.observe(&action);
        runs.push(action);
        if trigger.is_once() {
            runs.push(Action::Disable {
                schedule_id: schedule_id.clone(),
            });
        }
    }

    let next = trigger
        .zip(after)
        .and_then(|(trigger, after)| trigger.next_after(after));
    let clock = ScheduleClock {
        last_occurrence,
        next_occurrence: next.map(clock::format_datetime),
        next_occurrence_ms: next.and_then(|next| clock::due_ms(next, zone)),
        last_run_id: latest.id,
        last_run_status: latest.status,
    };
    if clock != task.clock {
        actions.push(Action::SaveClock {
            schedule_id: schedule_id.clone(),
            clock,
        });
    }
    actions.extend(runs);
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
mod tests {
    use super::*;
    use jiff::civil::{date, DateTime};
    use jiff::tz::{self, TimeZone};
    use unpeel_core::schedules::ScheduleTrigger;

    fn zone() -> TimeZone {
        TimeZone::fixed(tz::offset(-5))
    }

    fn local(day: i8, hour: i8, minute: i8, second: i8) -> DateTime {
        date(2026, 11, day).at(hour, minute, second, 0)
    }

    fn now(day: i8, hour: i8, minute: i8, second: i8) -> Zoned {
        local(day, hour, minute, second).to_zoned(zone()).unwrap()
    }

    fn ms(day: i8, hour: i8, minute: i8, second: i8) -> u64 {
        clock::epoch_ms(&now(day, hour, minute, second))
    }

    fn plan() -> LaunchPlan {
        LaunchPlan {
            project_id: "p".into(),
            preset_id: "ok".into(),
            command: "true".into(),
            cwd: "/tmp".into(),
            worktree_path: None,
            worktree_branch: None,
            agent: false,
            instructions: None,
        }
    }

    fn task(trigger: ScheduleTrigger) -> TaskState {
        TaskState {
            schedule: Schedule {
                id: "sch_1".into(),
                name: "Morning".into(),
                project_id: "p".into(),
                preset_id: "ok".into(),
                instructions: None,
                trigger,
                enabled: true,
                notify_when_done: true,
                created_at_ms: ms(1, 8, 0, 0),
                clock_reset_at_ms: None,
            },
            clock: ScheduleClock::default(),
            latest_run: None,
            observation: RunObservation::Idle,
            run_now: None,
            launch: Ok(plan()),
        }
    }

    fn daily(time: &str) -> TaskState {
        task(ScheduleTrigger::Daily { time: time.into() })
    }

    fn once(at: &str) -> TaskState {
        task(ScheduleTrigger::Once { at: at.into() })
    }

    fn fired_at(mut task: TaskState, occurrence: &str) -> TaskState {
        task.clock.last_occurrence = Some(occurrence.into());
        task
    }

    fn running(mut task: TaskState, observation: RunObservation) -> TaskState {
        task.latest_run = Some(ScheduleRun {
            run_id: "run_prev".into(),
            scheduled_for: Some("2026-11-06T09:00".into()),
            started_at_ms: Some(ms(6, 9, 0, 0)),
            ended_at_ms: None,
            status: RunStatus::Running,
            late: false,
            session_id: Some("session-prev".into()),
            exit_code: None,
            reason: None,
            snippet: None,
            phase: None,
            prompted_at_ms: None,
        });
        task.observation = observation;
        task
    }

    fn run_step(tasks: &[TaskState], now: &Zoned) -> Vec<Action> {
        let mut next = 0;
        step(tasks, now, &mut || {
            next += 1;
            format!("run_{next}")
        })
    }

    fn started(actions: &[Action]) -> Vec<&ScheduleRun> {
        actions
            .iter()
            .filter_map(|action| match action {
                Action::Start { run, .. } => Some(run),
                _ => None,
            })
            .collect()
    }

    fn recorded(actions: &[Action]) -> Vec<&ScheduleRun> {
        actions
            .iter()
            .filter_map(|action| match action {
                Action::Record { run, .. } => Some(run),
                _ => None,
            })
            .collect()
    }

    fn saved(actions: &[Action]) -> Vec<&ScheduleClock> {
        actions
            .iter()
            .filter_map(|action| match action {
                Action::SaveClock { clock, .. } => Some(clock),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn daily_fires_once_at_its_time() {
        let before = run_step(
            &[fired_at(daily("09:00"), "2026-11-05T09:00")],
            &now(6, 8, 59, 59),
        );
        assert!(started(&before).is_empty());

        let actions = run_step(
            &[fired_at(daily("09:00"), "2026-11-05T09:00")],
            &now(6, 9, 0, 0),
        );
        let runs = started(&actions);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].scheduled_for.as_deref(), Some("2026-11-06T09:00"));
        assert_eq!(runs[0].status, RunStatus::Running);
        assert_eq!(runs[0].started_at_ms, Some(ms(6, 9, 0, 0)));
        assert!(!runs[0].late);
        assert_eq!(
            saved(&actions)[0].last_occurrence.as_deref(),
            Some("2026-11-06T09:00")
        );

        let again = run_step(
            &[fired_at(daily("09:00"), "2026-11-06T09:00")],
            &now(6, 9, 0, 1),
        );
        assert!(started(&again).is_empty());
    }

    #[test]
    fn a_new_task_counts_from_its_creation() {
        let mut created_after_nine = daily("09:00");
        created_after_nine.schedule.created_at_ms = ms(6, 9, 30, 0);
        assert!(started(&run_step(&[created_after_nine.clone()], &now(6, 10, 0, 0))).is_empty());
        let next_day = run_step(&[created_after_nine], &now(7, 9, 0, 0));
        assert_eq!(
            started(&next_day)[0].scheduled_for.as_deref(),
            Some("2026-11-07T09:00")
        );

        let mut created_before_nine = daily("09:00");
        created_before_nine.schedule.created_at_ms = ms(6, 8, 59, 0);
        assert_eq!(
            started(&run_step(&[created_before_nine], &now(6, 9, 0, 0))).len(),
            1
        );
    }

    #[test]
    fn a_gap_of_days_catches_up_exactly_once_and_late() {
        let actions = run_step(
            &[fired_at(daily("09:00"), "2026-11-02T09:00")],
            &now(6, 12, 0, 0),
        );
        let runs = started(&actions);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].scheduled_for.as_deref(), Some("2026-11-06T09:00"));
        assert!(runs[0].late);
        assert!(
            recorded(&actions).is_empty(),
            "missed days are not recorded"
        );

        let caught_up = run_step(
            &[fired_at(daily("09:00"), "2026-11-06T09:00")],
            &now(6, 12, 0, 1),
        );
        assert!(started(&caught_up).is_empty());
    }

    #[test]
    fn late_means_more_than_two_minutes_after_the_occurrence() {
        let on_time = run_step(
            &[fired_at(daily("09:00"), "2026-11-05T09:00")],
            &now(6, 9, 2, 0),
        );
        assert!(!started(&on_time)[0].late);
        let late = run_step(
            &[fired_at(daily("09:00"), "2026-11-05T09:00")],
            &now(6, 9, 2, 1),
        );
        assert!(started(&late)[0].late);
    }

    #[test]
    fn the_occurrence_is_saved_before_its_run_starts() {
        let actions = run_step(
            &[fired_at(daily("09:00"), "2026-11-05T09:00")],
            &now(6, 9, 0, 0),
        );
        let save = actions
            .iter()
            .position(|action| {
                matches!(action, Action::SaveClock { clock, .. }
                    if clock.last_occurrence.as_deref() == Some("2026-11-06T09:00"))
            })
            .expect("the occurrence is saved");
        let start = actions
            .iter()
            .position(|action| matches!(action, Action::Start { .. }))
            .expect("the Run starts");
        assert!(save < start, "{actions:?}");
    }

    #[test]
    fn an_occurrence_during_a_run_in_progress_is_skipped() {
        let busy = running(
            fired_at(daily("09:00"), "2026-11-05T09:00"),
            RunObservation::Live,
        );
        let actions = run_step(&[busy], &now(6, 9, 0, 0));
        assert!(started(&actions).is_empty());
        let skipped = recorded(&actions);
        assert_eq!(skipped.len(), 1);
        assert_eq!(skipped[0].status, RunStatus::Skipped);
        assert_eq!(
            skipped[0].scheduled_for.as_deref(),
            Some("2026-11-06T09:00")
        );
        assert_eq!(skipped[0].started_at_ms, None);
        assert_eq!(skipped[0].session_id, None);
        assert!(skipped[0]
            .reason
            .as_deref()
            .unwrap_or_default()
            .contains("in progress"));
        assert_eq!(
            saved(&actions)[0].last_occurrence.as_deref(),
            Some("2026-11-06T09:00"),
            "a skipped occurrence is spent"
        );
    }

    /// The live Run stays the task's latest Run behind a skip: it is what
    /// the clock publishes, and what blocks a Run now in the same step.
    #[test]
    fn a_skip_never_replaces_the_run_in_progress() {
        let mut busy = running(
            fired_at(daily("09:00"), "2026-11-05T09:00"),
            RunObservation::Live,
        );
        busy.run_now = Some("run_asked".into());
        let actions = run_step(&[busy], &now(6, 9, 0, 0));
        assert!(started(&actions).is_empty(), "{actions:?}");
        let skipped: Vec<_> = recorded(&actions).iter().map(|run| run.status).collect();
        assert_eq!(skipped, vec![RunStatus::Skipped, RunStatus::Skipped]);
        let clock = saved(&actions)[0];
        assert_eq!(clock.last_run_id.as_deref(), Some("run_prev"));
        assert_eq!(clock.last_run_status, Some(RunStatus::Running));
    }

    #[test]
    fn a_script_run_is_done_on_exit_zero_and_failed_with_its_code_otherwise() {
        let done = run_step(
            &[running(daily("09:00"), RunObservation::Exited(0))],
            &now(6, 9, 1, 0),
        );
        let finished = recorded(&done);
        assert_eq!(finished.len(), 1);
        assert_eq!(finished[0].run_id, "run_prev");
        assert_eq!(finished[0].status, RunStatus::Done);
        assert_eq!(finished[0].exit_code, Some(0));
        assert_eq!(finished[0].ended_at_ms, Some(ms(6, 9, 1, 0)));
        assert_eq!(finished[0].session_id.as_deref(), Some("session-prev"));
        assert_eq!(finished[0].started_at_ms, Some(ms(6, 9, 0, 0)));

        let failed = run_step(
            &[running(daily("09:00"), RunObservation::Exited(3))],
            &now(6, 9, 1, 0),
        );
        let finished = recorded(&failed);
        assert_eq!(finished[0].status, RunStatus::Failed);
        assert_eq!(finished[0].exit_code, Some(3));
        assert!(finished[0]
            .reason
            .as_deref()
            .unwrap_or_default()
            .contains('3'));
    }

    #[test]
    fn a_session_that_ends_without_an_exit_record_fails_with_a_reason() {
        for observation in [
            RunObservation::Ended,
            RunObservation::Missing,
            RunObservation::SpawnFailed("unpeel-host exited with 1".into()),
        ] {
            let actions = run_step(
                &[running(daily("09:00"), observation.clone())],
                &now(6, 9, 1, 0),
            );
            let finished = recorded(&actions);
            assert_eq!(finished.len(), 1, "{observation:?}");
            assert_eq!(finished[0].status, RunStatus::Failed, "{observation:?}");
            assert_eq!(finished[0].exit_code, None, "{observation:?}");
            assert!(finished[0].reason.is_some(), "{observation:?}");
        }
        let spawn = run_step(
            &[running(
                daily("09:00"),
                RunObservation::SpawnFailed("no host".into()),
            )],
            &now(6, 9, 1, 0),
        );
        assert!(recorded(&spawn)[0]
            .reason
            .as_deref()
            .unwrap()
            .contains("no host"));
    }

    #[test]
    fn a_live_or_launching_run_is_left_running() {
        for observation in [RunObservation::Live, RunObservation::Launching] {
            let busy = running(fired_at(daily("09:00"), "2026-11-06T09:00"), observation);
            let actions = run_step(&[busy], &now(6, 9, 1, 0));
            assert!(recorded(&actions).is_empty());
            assert!(started(&actions).is_empty());
        }
    }

    #[test]
    fn a_run_that_cannot_start_fails_with_the_reason_and_the_task_stays_enabled() {
        let mut gone = fired_at(daily("09:00"), "2026-11-05T09:00");
        gone.launch = Err("the preset ok no longer exists".into());
        let actions = run_step(&[gone], &now(6, 9, 0, 0));
        assert!(started(&actions).is_empty());
        let failed = recorded(&actions);
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].status, RunStatus::Failed);
        assert_eq!(failed[0].scheduled_for.as_deref(), Some("2026-11-06T09:00"));
        assert_eq!(
            failed[0].reason.as_deref(),
            Some("the preset ok no longer exists")
        );
        assert_eq!(failed[0].ended_at_ms, Some(ms(6, 9, 0, 0)));
        assert!(!actions
            .iter()
            .any(|action| matches!(action, Action::Disable { .. })));
        assert_eq!(
            saved(&actions)[0].last_occurrence.as_deref(),
            Some("2026-11-06T09:00")
        );
    }

    #[test]
    fn a_once_task_runs_at_its_time_then_disables_itself() {
        assert!(started(&run_step(&[once("2026-11-06T15:00:05")], &now(6, 15, 0, 4))).is_empty());
        let actions = run_step(&[once("2026-11-06T15:00:05")], &now(6, 15, 0, 5));
        assert_eq!(
            started(&actions)[0].scheduled_for.as_deref(),
            Some("2026-11-06T15:00:05")
        );
        assert!(actions.contains(&Action::Disable {
            schedule_id: "sch_1".into()
        }));
        let spent = fired_at(once("2026-11-06T15:00:05"), "2026-11-06T15:00:05");
        assert!(started(&run_step(&[spent], &now(7, 9, 0, 0))).is_empty());
    }

    #[test]
    fn a_once_time_before_the_task_existed_never_fires() {
        let past = once("2026-11-01T07:00");
        assert!(run_step(&[past], &now(6, 9, 0, 0))
            .iter()
            .all(|action| matches!(action, Action::SaveClock { .. })));
    }

    #[test]
    fn disabled_and_unknown_tasks_never_fire() {
        let mut disabled = daily("09:00");
        disabled.schedule.enabled = false;
        let unknown = task(ScheduleTrigger::Unknown);
        let unreadable = daily("nine o'clock");
        let actions = run_step(&[disabled, unknown, unreadable], &now(6, 9, 0, 0));
        assert!(started(&actions).is_empty());
        assert!(recorded(&actions).is_empty());
    }

    #[test]
    fn run_now_starts_a_run_with_no_occurrence() {
        let mut asked = daily("09:00");
        asked.run_now = Some("run_asked".into());
        let actions = run_step(&[asked], &now(6, 7, 0, 0));
        let runs = started(&actions);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].run_id, "run_asked");
        assert_eq!(runs[0].scheduled_for, None);
        assert!(!runs[0].late);
        assert!(!actions
            .iter()
            .any(|action| matches!(action, Action::Disable { .. })));
    }

    #[test]
    fn an_occurrence_due_with_run_now_is_skipped_behind_it() {
        let mut asked = fired_at(daily("09:00"), "2026-11-05T09:00");
        asked.run_now = Some("run_asked".into());
        let actions = run_step(&[asked], &now(6, 9, 0, 0));
        assert_eq!(started(&actions).len(), 1);
        assert_eq!(recorded(&actions)[0].status, RunStatus::Skipped);
    }

    #[test]
    fn a_run_that_just_finished_does_not_block_the_next_occurrence() {
        let finishing = running(
            fired_at(daily("09:00"), "2026-11-05T09:00"),
            RunObservation::Exited(0),
        );
        let actions = run_step(&[finishing], &now(6, 9, 0, 0));
        assert_eq!(recorded(&actions)[0].status, RunStatus::Done);
        assert_eq!(started(&actions).len(), 1);
    }

    #[test]
    fn the_clock_publishes_the_next_run_and_the_last_result() {
        let actions = run_step(
            &[fired_at(daily("09:00"), "2026-11-05T09:00")],
            &now(6, 9, 0, 0),
        );
        let clock = saved(&actions)[0];
        assert_eq!(clock.next_occurrence.as_deref(), Some("2026-11-07T09:00"));
        assert_eq!(clock.next_occurrence_ms, Some(ms(7, 9, 0, 0)));
        assert_eq!(clock.last_run_id.as_deref(), Some("run_1"));
        assert_eq!(clock.last_run_status, Some(RunStatus::Running));

        let mut settled = fired_at(daily("09:00"), "2026-11-06T09:00");
        settled.clock = clock.clone();
        settled.latest_run = Some(started(&actions)[0].clone());
        settled.observation = RunObservation::Live;
        assert!(
            saved(&run_step(&[settled], &now(6, 9, 0, 1))).is_empty(),
            "unchanged clocks are not rewritten"
        );

        let mut disabled = daily("09:00");
        disabled.schedule.enabled = false;
        disabled.clock.next_occurrence = Some("2026-11-06T09:00".into());
        disabled.clock.next_occurrence_ms = Some(ms(6, 9, 0, 0));
        let clock = run_step(&[disabled], &now(6, 7, 0, 0));
        assert_eq!(saved(&clock)[0].next_occurrence, None);
    }
}
