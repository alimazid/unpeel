//! The step against the wall clock: every Trigger kind through a clock
//! change in a zone with real DST rules, a time zone change between steps,
//! and pause / resume. Zones come from POSIX rules, so no test depends on
//! the machine's tz database.

use jiff::civil::{date, DateTime};
use jiff::tz::{self, TimeZone};
use jiff::Zoned;
use unpeel_core::schedules::{RunStatus, Schedule, ScheduleClock, ScheduleRun, ScheduleTrigger};

use super::clock;
use super::step::{step, Action, LaunchPlan, RunObservation, TaskState};

/// New York's rules: 2026-03-08 02:00 EST jumps to 03:00 EDT, 2026-11-01
/// 02:00 EDT falls back to 01:00 EST.
fn new_york() -> TimeZone {
    TimeZone::posix("EST5EDT,M3.2.0,M11.1.0").expect("a valid rule")
}

/// The same offsets, with both clock changes on a Wednesday so every
/// Trigger kind (Weekdays included) has an occurrence in them: 2026-03-11
/// 02:00 jumps to 03:00, 2026-11-04 02:00 falls back to 01:00.
fn wednesday_rules() -> TimeZone {
    TimeZone::posix("EST5EDT,M3.2.3,M11.1.3").expect("a valid rule")
}

fn civil(month: i8, day: i8, hour: i8, minute: i8, second: i8) -> DateTime {
    date(2026, month, day).at(hour, minute, second, 0)
}

/// The instant `offset_hours` from UTC reads `civil`: unambiguous even
/// inside a clock change.
fn instant(civil: DateTime, offset_hours: i8, zone: &TimeZone) -> Zoned {
    tz::offset(offset_hours)
        .to_timestamp(civil)
        .expect("in range")
        .to_zoned(zone.clone())
}

fn ms_at(civil: DateTime, offset_hours: i8) -> u64 {
    clock::epoch_ms(&instant(civil, offset_hours, &TimeZone::UTC))
}

fn task(trigger: ScheduleTrigger, created: u64) -> TaskState {
    TaskState {
        schedule: Schedule {
            id: "sch_1".into(),
            name: "Night".into(),
            project_id: "p".into(),
            preset_id: "ok".into(),
            trigger,
            enabled: true,
            notify_when_done: true,
            created_at_ms: created,
            clock_reset_at_ms: None,
        },
        clock: ScheduleClock::default(),
        latest_run: None,
        observation: RunObservation::Idle,
        run_now: None,
        launch: Ok(LaunchPlan {
            project_id: "p".into(),
            preset_id: "ok".into(),
            command: "true".into(),
            cwd: "/tmp".into(),
            worktree_path: None,
            worktree_branch: None,
        }),
    }
}

fn fired_at(mut task: TaskState, occurrence: &str) -> TaskState {
    task.clock.last_occurrence = Some(occurrence.into());
    task
}

fn run_step(task: &TaskState, now: &Zoned) -> Vec<Action> {
    let mut next = 0;
    step(std::slice::from_ref(task), now, &mut || {
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

fn saved(actions: &[Action]) -> Option<&ScheduleClock> {
    actions.iter().find_map(|action| match action {
        Action::SaveClock { clock, .. } => Some(clock),
        _ => None,
    })
}

/// Apply a step's saved clock, as the worker does before its next step.
fn after_step(mut task: TaskState, actions: &[Action]) -> TaskState {
    if let Some(clock) = saved(actions) {
        task.clock = clock.clone();
    }
    if let Some(run) = started(actions).first() {
        task.latest_run = Some(ScheduleRun {
            status: RunStatus::Done,
            ..(*run).clone()
        });
    }
    task
}

#[test]
fn a_time_the_clock_skips_is_published_and_fires_at_the_end_of_the_gap() {
    let zone = new_york();
    let daily = fired_at(
        task(
            ScheduleTrigger::Daily {
                time: "02:30".into(),
            },
            ms_at(civil(3, 1, 0, 0, 0), -5),
        ),
        "2026-03-07T02:30",
    );

    let before = run_step(&daily, &instant(civil(3, 8, 1, 59, 59), -5, &zone));
    assert!(started(&before).is_empty());
    let published = saved(&before).expect("the next run is published");
    assert_eq!(
        published.next_occurrence.as_deref(),
        Some("2026-03-08T02:30")
    );
    assert_eq!(
        published.next_occurrence_ms,
        Some(ms_at(civil(3, 8, 3, 0, 0), -4)),
        "02:30 does not exist that day: it fires when the clock reads 03:00"
    );

    let daily = after_step(daily, &before);
    let at_three = run_step(&daily, &instant(civil(3, 8, 3, 0, 0), -4, &zone));
    let runs = started(&at_three);
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].scheduled_for.as_deref(), Some("2026-03-08T02:30"));
    assert!(!runs[0].late, "it fired at its instant, not an hour early");
}

/// One task of every kind whose next occurrence is `due` (a local
/// date-time), each having fired its previous occurrence.
fn every_kind_due_at(due: DateTime, created: u64) -> Vec<(&'static str, TaskState)> {
    let time = clock::format_time(due.time());
    let previous =
        |span: jiff::Span| clock::format_datetime(due.checked_sub(span).expect("in range"));
    let weekday = clock::weekday_name(due.weekday()).to_string();
    vec![
        (
            "hourly",
            fired_at(
                task(
                    ScheduleTrigger::Hourly {
                        minute: u8::try_from(due.minute()).expect("a minute"),
                    },
                    created,
                ),
                &previous(jiff::Span::new().hours(1)),
            ),
        ),
        (
            "daily",
            fired_at(
                task(ScheduleTrigger::Daily { time: time.clone() }, created),
                &previous(jiff::Span::new().days(1)),
            ),
        ),
        (
            "weekdays",
            fired_at(
                task(ScheduleTrigger::Weekdays { time: time.clone() }, created),
                &previous(jiff::Span::new().days(1)),
            ),
        ),
        (
            "weekly",
            fired_at(
                task(
                    ScheduleTrigger::Weekly {
                        weekday,
                        time: time.clone(),
                    },
                    created,
                ),
                &previous(jiff::Span::new().weeks(1)),
            ),
        ),
        (
            "once",
            task(
                ScheduleTrigger::Once {
                    at: clock::format_datetime(due),
                },
                created,
            ),
        ),
        (
            "cron",
            fired_at(
                task(
                    ScheduleTrigger::Cron {
                        expr: format!("{} {} * * *", due.minute(), due.hour()),
                    },
                    created,
                ),
                &previous(jiff::Span::new().days(1)),
            ),
        ),
    ]
}

#[test]
fn every_kind_fires_a_skipped_time_once_when_the_clock_change_ends() {
    let zone = wednesday_rules();
    let skipped = civil(3, 11, 2, 30, 0);
    let created = ms_at(civil(3, 1, 0, 0, 0), -5);
    for (kind, task) in every_kind_due_at(skipped, created) {
        let before = run_step(&task, &instant(civil(3, 11, 1, 59, 59), -5, &zone));
        assert!(started(&before).is_empty(), "{kind}");
        let published = saved(&before).expect(kind);
        assert_eq!(
            published.next_occurrence.as_deref(),
            Some("2026-03-11T02:30"),
            "{kind}"
        );
        assert_eq!(
            published.next_occurrence_ms,
            Some(ms_at(civil(3, 11, 3, 0, 0), -4)),
            "{kind}: due when the clock reads 03:00"
        );

        let task = after_step(task, &before);
        let at_three = run_step(&task, &instant(civil(3, 11, 3, 0, 0), -4, &zone));
        let runs = started(&at_three);
        assert_eq!(runs.len(), 1, "{kind}: {at_three:?}");
        assert_eq!(
            runs[0].scheduled_for.as_deref(),
            Some("2026-03-11T02:30"),
            "{kind}"
        );
        assert!(!runs[0].late, "{kind}");

        let task = after_step(task, &at_three);
        let again = run_step(&task, &instant(civil(3, 11, 3, 0, 1), -4, &zone));
        assert!(started(&again).is_empty(), "{kind}: fires once");
    }
}

#[test]
fn every_kind_fires_a_repeated_time_once_on_its_first_pass() {
    let zone = wednesday_rules();
    let repeated = civil(11, 4, 1, 30, 0);
    let created = ms_at(civil(10, 20, 0, 0, 0), -4);
    for (kind, task) in every_kind_due_at(repeated, created) {
        let before = run_step(&task, &instant(civil(11, 4, 1, 29, 59), -4, &zone));
        assert!(started(&before).is_empty(), "{kind}");
        assert_eq!(
            saved(&before).and_then(|clock| clock.next_occurrence_ms),
            Some(ms_at(repeated, -4)),
            "{kind}: due on the first pass"
        );

        let task = after_step(task, &before);
        let first_pass = run_step(&task, &instant(repeated, -4, &zone));
        assert_eq!(started(&first_pass).len(), 1, "{kind}: {first_pass:?}");

        let mut task = after_step(task, &first_pass);
        for second_pass in [repeated, civil(11, 4, 1, 59, 59)] {
            let actions = run_step(&task, &instant(second_pass, -5, &zone));
            assert!(
                started(&actions).is_empty(),
                "{kind}: the repeated hour does not fire it again: {actions:?}"
            );
            task = after_step(task, &actions);
        }
    }
}

#[test]
fn every_kind_follows_the_zone_in_effect_at_each_step() {
    // The Mac is in UTC-5, then travels west to UTC-8 before 09:00.
    let east = TimeZone::fixed(tz::offset(-5));
    let west = TimeZone::fixed(tz::offset(-8));
    let due = civil(11, 6, 9, 0, 0);
    let created = ms_at(civil(10, 20, 0, 0, 0), -5);
    for (kind, task) in every_kind_due_at(due, created) {
        let in_east = run_step(&task, &instant(civil(11, 6, 8, 30, 0), -5, &east));
        assert_eq!(
            saved(&in_east).and_then(|clock| clock.next_occurrence_ms),
            Some(ms_at(due, -5)),
            "{kind}"
        );

        let task = after_step(task, &in_east);
        // 05:31 in the west is one minute after the last step.
        let landed = run_step(&task, &instant(civil(11, 6, 5, 31, 0), -8, &west));
        assert!(started(&landed).is_empty(), "{kind}");
        assert_eq!(
            saved(&landed).and_then(|clock| clock.next_occurrence_ms),
            Some(ms_at(due, -8)),
            "{kind}: the next run moves with the clock"
        );

        let task = after_step(task, &landed);
        let east_nine = run_step(&task, &instant(civil(11, 6, 6, 0, 0), -8, &west));
        assert!(
            started(&east_nine).is_empty(),
            "{kind}: 09:00 back east is 06:00 here"
        );

        let task = after_step(task, &east_nine);
        let nine = run_step(&task, &instant(due, -8, &west));
        let runs = started(&nine);
        assert_eq!(runs.len(), 1, "{kind}: {nine:?}");
        assert_eq!(
            runs[0].scheduled_for.as_deref(),
            Some("2026-11-06T09:00"),
            "{kind}"
        );
        assert!(!runs[0].late, "{kind}");
    }
}

#[test]
fn every_kind_resumed_counts_from_the_resume_and_never_catches_up() {
    let zone = TimeZone::fixed(tz::offset(-5));
    let due = civil(11, 6, 9, 0, 0);
    let created = ms_at(civil(10, 20, 0, 0, 0), -5);
    let resumed_at = civil(11, 6, 9, 10, 0);
    let next_after_resume = [
        ("hourly", Some(civil(11, 6, 10, 0, 0))),
        ("daily", Some(civil(11, 7, 9, 0, 0))),
        ("weekdays", Some(civil(11, 9, 9, 0, 0))),
        ("weekly", Some(civil(11, 13, 9, 0, 0))),
        ("once", None),
        ("cron", Some(civil(11, 7, 9, 0, 0))),
    ];
    for ((kind, mut task), (expected_kind, next)) in every_kind_due_at(due, created)
        .into_iter()
        .zip(next_after_resume)
    {
        assert_eq!(kind, expected_kind);
        task.schedule.enabled = false;
        for paused_at in [due, civil(11, 6, 9, 5, 0)] {
            let actions = run_step(&task, &instant(paused_at, -5, &zone));
            assert!(started(&actions).is_empty(), "{kind}: paused");
            task = after_step(task, &actions);
            assert_eq!(
                task.clock.next_occurrence, None,
                "{kind}: no next run while paused"
            );
        }

        task.schedule.enabled = true;
        task.schedule.clock_reset_at_ms = Some(ms_at(resumed_at, -5));
        let resumed = run_step(&task, &instant(civil(11, 6, 9, 10, 1), -5, &zone));
        assert!(
            started(&resumed).is_empty(),
            "{kind}: 09:00 fell while paused and is not caught up: {resumed:?}"
        );
        let task = after_step(task, &resumed);
        assert_eq!(
            task.clock.next_occurrence,
            next.map(clock::format_datetime),
            "{kind}"
        );
        if let Some(next) = next {
            let fired = run_step(&task, &instant(next, -5, &zone));
            assert_eq!(
                started(&fired).len(),
                1,
                "{kind}: fires again from its next time"
            );
        }
    }
}

#[test]
fn a_new_trigger_counts_from_when_it_was_set() {
    let zone = TimeZone::fixed(tz::offset(-5));
    let mut edited = fired_at(
        task(
            ScheduleTrigger::Daily {
                time: "08:00".into(),
            },
            ms_at(civil(10, 20, 0, 0, 0), -5),
        ),
        "2026-11-05T09:00",
    );
    // At 10:00 the 09:00 task was moved to 08:00: this morning's 08:00 is
    // not a missed run.
    edited.schedule.clock_reset_at_ms = Some(ms_at(civil(11, 6, 10, 0, 0), -5));
    let actions = run_step(&edited, &instant(civil(11, 6, 10, 0, 1), -5, &zone));
    assert!(started(&actions).is_empty(), "{actions:?}");
    assert_eq!(
        saved(&actions).and_then(|clock| clock.next_occurrence.clone()),
        Some("2026-11-07T08:00".into())
    );
}
