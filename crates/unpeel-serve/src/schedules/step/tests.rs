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
        kind: RunKind::Script,
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
        report: None,
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
        report: None,
        session_ended: false,
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
