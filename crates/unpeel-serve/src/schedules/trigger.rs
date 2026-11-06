//! When a Trigger's occurrences fall, in local (civil) time.
//!
//! Occurrences are compared as local date-times, not instants: a Trigger is
//! read on the local wall clock, so a time that a clock change skips is due
//! as soon as the clock is past it (02:30 on a spring-forward night fires
//! at 03:00), a repeated time is one occurrence (it fires on its first pass
//! only, for every kind, Hourly and cron included), and a time zone change
//! moves every later occurrence with the clock.

use jiff::civil::{DateTime, Time, Weekday};
use jiff::tz::TimeZone;
use jiff::{ToSpan, Zoned};
use unpeel_core::schedules::save::TriggerRefusal;
use unpeel_core::schedules::{Schedule, ScheduleClock, ScheduleTrigger};

use super::clock;
use super::cron::CronSpec;

/// A Trigger this build can evaluate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    /// At this many minutes past every hour.
    Hourly(i8),
    Daily(Time),
    /// Monday to Friday.
    Weekdays(Time),
    Weekly(Weekday, Time),
    Once(DateTime),
    Cron(CronSpec),
}

/// Days of the week a time-of-day Trigger fires on, Monday as bit 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Days(u8);

impl Days {
    const EVERY: Self = Self(0b111_1111);
    const WEEKDAYS: Self = Self(0b001_1111);

    fn only(day: Weekday) -> Self {
        Self(1 << day.to_monday_zero_offset())
    }

    fn contains(self, day: Weekday) -> bool {
        self.0 & (1 << day.to_monday_zero_offset()) != 0
    }
}

impl Trigger {
    /// `None` for an unknown kind or a stored value out of its range: such
    /// a task never fires.
    pub fn parse(trigger: &ScheduleTrigger) -> Option<Self> {
        match trigger {
            ScheduleTrigger::Hourly { minute } => {
                let minute = i8::try_from(*minute).ok().filter(|minute| *minute < 60)?;
                Some(Self::Hourly(minute))
            }
            ScheduleTrigger::Daily { time } => clock::parse_time(time).map(Self::Daily),
            ScheduleTrigger::Weekdays { time } => clock::parse_time(time).map(Self::Weekdays),
            ScheduleTrigger::Weekly { weekday, time } => Some(Self::Weekly(
                clock::parse_weekday(weekday)?,
                clock::parse_time(time)?,
            )),
            ScheduleTrigger::Once { at } => clock::parse_datetime(at).map(Self::Once),
            ScheduleTrigger::Cron { expr } => CronSpec::parse(expr).ok().map(Self::Cron),
            ScheduleTrigger::Unknown => None,
        }
    }

    /// The save-time check every writer runs: the Trigger, or a message
    /// saying what is wrong with it. A Trigger that can never come due
    /// again (a past Once, a cron date that does not exist) is refused too.
    pub fn check(trigger: &ScheduleTrigger, now: DateTime) -> Result<Self, String> {
        let time = |time: &str| {
            clock::parse_time(time)
                .ok_or_else(|| format!("{time:?} is not a local time HH:MM or HH:MM:SS"))
        };
        let checked = match trigger {
            ScheduleTrigger::Hourly { minute } => Self::parse(trigger)
                .ok_or_else(|| format!("an hourly minute is 0-59, not {minute}"))?,
            ScheduleTrigger::Daily { time: at } => Self::Daily(time(at)?),
            ScheduleTrigger::Weekdays { time: at } => Self::Weekdays(time(at)?),
            ScheduleTrigger::Weekly { weekday, time: at } => Self::Weekly(
                clock::parse_weekday(weekday)
                    .ok_or_else(|| format!("{weekday:?} is not a day of the week"))?,
                time(at)?,
            ),
            ScheduleTrigger::Once { at } => {
                let once = clock::parse_datetime(at).ok_or_else(|| {
                    format!("{at:?} is not a local date-time YYYY-MM-DDTHH:MM[:SS]")
                })?;
                if once <= now {
                    return Err(format!("{} is in the past", clock::format_datetime(once)));
                }
                Self::Once(once)
            }
            ScheduleTrigger::Cron { expr } => Self::Cron(CronSpec::parse(expr)?),
            ScheduleTrigger::Unknown => return Err("unknown Trigger kind".into()),
        };
        if checked.next_after(now).is_none() {
            return Err(format!("{} never comes due", describe(trigger)));
        }
        Ok(checked)
    }

    /// The latest occurrence strictly after `after` and at or before `now`.
    pub fn latest_due(self, after: DateTime, now: DateTime) -> Option<DateTime> {
        let latest = match self {
            Self::Once(at) => Some(at).filter(|at| *at <= now)?,
            Self::Cron(spec) => return spec.latest_due(after, now),
            Self::Hourly(minute) => {
                let this_hour = now.date().at(now.hour(), minute, 0, 0);
                if this_hour <= now {
                    this_hour
                } else {
                    this_hour.checked_sub(1.hour()).ok()?
                }
            }
            Self::Daily(time) | Self::Weekdays(time) | Self::Weekly(_, time) => {
                latest_on(self.days()?, time, now)?
            }
        };
        (latest > after).then_some(latest)
    }

    /// The first occurrence strictly after `after`.
    pub fn next_after(self, after: DateTime) -> Option<DateTime> {
        match self {
            Self::Once(at) => (at > after).then_some(at),
            Self::Cron(spec) => spec.next_after(after),
            Self::Hourly(minute) => {
                let this_hour = after.date().at(after.hour(), minute, 0, 0);
                if this_hour > after {
                    Some(this_hour)
                } else {
                    this_hour.checked_add(1.hour()).ok()
                }
            }
            Self::Daily(time) | Self::Weekdays(time) | Self::Weekly(_, time) => {
                next_on(self.days()?, time, after)
            }
        }
    }

    pub fn is_once(self) -> bool {
        matches!(self, Self::Once(_))
    }

    fn days(self) -> Option<Days> {
        match self {
            Self::Daily(_) => Some(Days::EVERY),
            Self::Weekdays(_) => Some(Days::WEEKDAYS),
            Self::Weekly(day, _) => Some(Days::only(day)),
            Self::Hourly(_) | Self::Once(_) | Self::Cron(_) => None,
        }
    }
}

/// The save-time check of every writer (`unpeel_core::schedules::save`):
/// the Trigger in its stored form, or what is wrong with it. A task saved
/// enabled must still come due ([`Trigger::check`]); one saved paused only
/// needs a Trigger that reads, since resuming checks it again.
pub fn for_save(
    trigger: &ScheduleTrigger,
    comes_due: bool,
    now: DateTime,
) -> Result<ScheduleTrigger, TriggerRefusal> {
    let parsed = match Trigger::parse(trigger) {
        Some(parsed) if !comes_due => parsed,
        Some(Trigger::Once(at)) if at <= now => {
            return Err(TriggerRefusal::InPast(format!(
                "{} is in the past",
                clock::format_datetime(at)
            )))
        }
        // `check` reads at least as strictly as `parse`, so it says what is
        // wrong with a Trigger that does not parse.
        _ => Trigger::check(trigger, now).map_err(TriggerRefusal::Invalid)?,
    };
    Ok(match (parsed, trigger) {
        (Trigger::Hourly(_), _) => trigger.clone(),
        (Trigger::Daily(time), _) => ScheduleTrigger::Daily {
            time: clock::format_time(time),
        },
        (Trigger::Weekdays(time), _) => ScheduleTrigger::Weekdays {
            time: clock::format_time(time),
        },
        (Trigger::Weekly(day, time), _) => ScheduleTrigger::Weekly {
            weekday: clock::weekday_name(day).to_owned(),
            time: clock::format_time(time),
        },
        (Trigger::Once(at), _) => ScheduleTrigger::Once {
            at: clock::format_datetime(at),
        },
        (Trigger::Cron(_), ScheduleTrigger::Cron { expr }) => ScheduleTrigger::Cron {
            expr: expr.split_whitespace().collect::<Vec<_>>().join(" "),
        },
        (Trigger::Cron(_), _) => trigger.clone(),
    })
}

/// A Trigger as a person reads it (`hourly at :15`, `weekly friday 17:00`,
/// `cron 0 9 * * 1-5`).
pub fn describe(trigger: &ScheduleTrigger) -> String {
    match trigger {
        ScheduleTrigger::Hourly { minute } => format!("hourly at :{minute:02}"),
        ScheduleTrigger::Daily { time } => format!("daily {time}"),
        ScheduleTrigger::Weekdays { time } => format!("weekdays {time}"),
        ScheduleTrigger::Weekly { weekday, time } => format!("weekly {weekday} {time}"),
        ScheduleTrigger::Once { at } => format!("once {at}"),
        ScheduleTrigger::Cron { expr } => format!("cron {expr}"),
        ScheduleTrigger::Unknown => "unknown (never fires)".into(),
    }
}

/// The local date-time a task's due rule counts from: the later of the
/// last occurrence it fired and its creation or last clock restart (Resume,
/// a new Trigger), read on the wall clock of `zone`.
pub fn counts_from(
    schedule: &Schedule,
    clock_state: &ScheduleClock,
    zone: &TimeZone,
) -> Option<DateTime> {
    let restarted = clock::civil_at_ms(schedule.counts_from_ms(), zone);
    let fired = clock_state
        .last_occurrence
        .as_deref()
        .and_then(clock::parse_datetime);
    fired.max(restarted)
}

/// When a task will next fire, from its stored state, as a zoned time on
/// the wall clock it fires by; `None` while it is paused or for a Trigger
/// that never fires. The scheduler publishes the same instant.
pub fn next_run(
    schedule: &Schedule,
    clock_state: &ScheduleClock,
    zone: &TimeZone,
) -> Option<Zoned> {
    let trigger = Trigger::parse(&schedule.trigger).filter(|_| schedule.enabled)?;
    let next = trigger.next_after(counts_from(schedule, clock_state, zone)?)?;
    let due_ms = i64::try_from(clock::due_ms(next, zone)?).ok()?;
    Some(
        jiff::Timestamp::from_millisecond(due_ms)
            .ok()?
            .to_zoned(zone.clone()),
    )
}

/// The next occurrence exactly as the scheduler publishes it in the task's
/// clock (`next_occurrence`, `next_occurrence_ms`): its local date-time and
/// its instant on `zone`. `None` while it is paused or never fires.
pub fn published_next_run(
    schedule: &Schedule,
    clock_state: &ScheduleClock,
    zone: &TimeZone,
) -> Option<(String, u64)> {
    let trigger = Trigger::parse(&schedule.trigger).filter(|_| schedule.enabled)?;
    let next = trigger.next_after(counts_from(schedule, clock_state, zone)?)?;
    Some((clock::format_datetime(next), clock::due_ms(next, zone)?))
}

/// The latest `time` on one of `days` at or before `now`; a week back is
/// always far enough.
fn latest_on(days: Days, time: Time, now: DateTime) -> Option<DateTime> {
    let mut day = now.date();
    for _ in 0..=7 {
        let candidate = day.to_datetime(time);
        if days.contains(day.weekday()) && candidate <= now {
            return Some(candidate);
        }
        day = day.yesterday().ok()?;
    }
    None
}

/// The first `time` on one of `days` strictly after `after`.
fn next_on(days: Days, time: Time, after: DateTime) -> Option<DateTime> {
    let mut day = after.date();
    for _ in 0..=7 {
        let candidate = day.to_datetime(time);
        if days.contains(day.weekday()) && candidate > after {
            return Some(candidate);
        }
        day = day.tomorrow().ok()?;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::{date, time};

    fn at(day: i8, hour: i8, minute: i8) -> DateTime {
        date(2026, 11, day).at(hour, minute, 0, 0)
    }

    #[test]
    fn once_is_due_from_its_time_and_only_after_the_last_fired() {
        let once = Trigger::Once(at(6, 15, 0));
        assert_eq!(once.latest_due(at(6, 9, 0), at(6, 14, 59)), None);
        assert_eq!(
            once.latest_due(at(6, 9, 0), at(6, 15, 0)),
            Some(at(6, 15, 0))
        );
        assert_eq!(
            once.latest_due(at(6, 9, 0), at(9, 8, 0)),
            Some(at(6, 15, 0))
        );
        assert_eq!(once.latest_due(at(6, 15, 0), at(9, 8, 0)), None);
        assert_eq!(once.next_after(at(6, 9, 0)), Some(at(6, 15, 0)));
        assert_eq!(once.next_after(at(6, 15, 0)), None);
    }

    #[test]
    fn daily_is_due_at_its_time_each_day() {
        let daily = Trigger::Daily(time(9, 0, 0, 0));
        assert_eq!(daily.latest_due(at(6, 8, 0), at(6, 8, 59)), None);
        assert_eq!(
            daily.latest_due(at(6, 8, 0), at(6, 9, 0)),
            Some(at(6, 9, 0))
        );
        assert_eq!(daily.latest_due(at(6, 9, 0), at(6, 23, 0)), None);
        assert_eq!(daily.latest_due(at(6, 9, 0), at(7, 8, 0)), None);
        assert_eq!(
            daily.latest_due(at(6, 9, 0), at(7, 9, 1)),
            Some(at(7, 9, 0))
        );
        assert_eq!(daily.next_after(at(6, 8, 0)), Some(at(6, 9, 0)));
        assert_eq!(daily.next_after(at(6, 9, 0)), Some(at(7, 9, 0)));
    }

    #[test]
    fn a_gap_of_days_is_one_occurrence_the_latest() {
        let daily = Trigger::Daily(time(9, 0, 0, 0));
        assert_eq!(
            daily.latest_due(at(2, 9, 0), at(6, 12, 0)),
            Some(at(6, 9, 0))
        );
        assert_eq!(
            daily.latest_due(at(2, 9, 0), at(6, 8, 0)),
            Some(at(5, 9, 0))
        );
    }

    #[test]
    fn only_known_kinds_with_readable_times_fire() {
        assert_eq!(
            Trigger::parse(&ScheduleTrigger::Daily {
                time: "09:43".into()
            }),
            Some(Trigger::Daily(time(9, 43, 0, 0)))
        );
        assert_eq!(
            Trigger::parse(&ScheduleTrigger::Once {
                at: "2026-11-06T15:00:05".into()
            }),
            Some(Trigger::Once(date(2026, 11, 6).at(15, 0, 5, 0)))
        );
        assert_eq!(
            Trigger::parse(&ScheduleTrigger::Daily {
                time: "quarter past".into()
            }),
            None
        );
        assert_eq!(Trigger::parse(&ScheduleTrigger::Unknown), None);
    }

    #[test]
    fn hourly_is_due_at_its_minute_every_hour() {
        let hourly = Trigger::parse(&ScheduleTrigger::Hourly { minute: 15 }).unwrap();
        assert_eq!(hourly.latest_due(at(6, 8, 15), at(6, 9, 14)), None);
        assert_eq!(
            hourly.latest_due(at(6, 8, 15), at(6, 9, 15)),
            Some(at(6, 9, 15))
        );
        assert_eq!(hourly.latest_due(at(6, 9, 15), at(6, 10, 0)), None);
        assert_eq!(
            hourly.latest_due(at(5, 22, 15), at(6, 0, 20)),
            Some(at(6, 0, 15)),
            "a gap of hours across midnight is one occurrence, the latest"
        );
        assert_eq!(hourly.next_after(at(6, 9, 14)), Some(at(6, 9, 15)));
        assert_eq!(hourly.next_after(at(6, 9, 15)), Some(at(6, 10, 15)));
        assert_eq!(hourly.next_after(at(6, 23, 30)), Some(at(7, 0, 15)));
    }

    #[test]
    fn weekdays_skip_the_weekend() {
        // 2026-11-06 is a Friday.
        let weekdays = Trigger::parse(&ScheduleTrigger::Weekdays {
            time: "09:00".into(),
        })
        .unwrap();
        assert_eq!(weekdays.next_after(at(6, 9, 0)), Some(at(9, 9, 0)));
        assert_eq!(weekdays.next_after(at(6, 8, 0)), Some(at(6, 9, 0)));
        assert_eq!(
            weekdays.latest_due(at(5, 9, 0), at(8, 23, 0)),
            Some(at(6, 9, 0)),
            "Saturday and Sunday have no occurrence"
        );
        assert_eq!(weekdays.latest_due(at(6, 9, 0), at(9, 8, 59)), None);
        assert_eq!(
            weekdays.latest_due(at(6, 9, 0), at(9, 9, 0)),
            Some(at(9, 9, 0))
        );
    }

    #[test]
    fn weekly_is_due_on_its_day_only() {
        let weekly = Trigger::parse(&ScheduleTrigger::Weekly {
            weekday: "monday".into(),
            time: "07:30".into(),
        })
        .unwrap();
        assert_eq!(weekly.next_after(at(6, 12, 0)), Some(at(9, 7, 30)));
        assert_eq!(weekly.next_after(at(9, 7, 30)), Some(at(16, 7, 30)));
        assert_eq!(weekly.latest_due(at(2, 7, 30), at(8, 23, 0)), None);
        assert_eq!(
            weekly.latest_due(at(2, 7, 30), at(20, 0, 0)),
            Some(at(16, 7, 30))
        );
    }

    #[test]
    fn cron_is_due_at_each_matching_minute() {
        let cron = Trigger::parse(&ScheduleTrigger::Cron {
            expr: "0 9 * * 1-5".into(),
        })
        .unwrap();
        assert_eq!(cron.next_after(at(6, 9, 0)), Some(at(9, 9, 0)));
        assert_eq!(
            cron.latest_due(at(5, 9, 0), at(8, 12, 0)),
            Some(at(6, 9, 0))
        );
        assert_eq!(cron.latest_due(at(6, 9, 0), at(8, 12, 0)), None);
        assert!(!cron.is_once());
    }

    #[test]
    fn the_next_run_is_when_it_comes_due_on_the_wall_clock() {
        let new_york = TimeZone::posix("EST5EDT,M3.2.0,M11.1.0").unwrap();
        let mut schedule = Schedule {
            id: "sch_1".into(),
            name: "Night".into(),
            project_id: "p".into(),
            preset_id: "ok".into(),
            instructions: None,
            trigger: ScheduleTrigger::Daily {
                time: "02:30".into(),
            },
            enabled: true,
            notify_when_done: true,
            created_at_ms: 0,
            clock_reset_at_ms: None,
        };
        let fired = ScheduleClock {
            last_occurrence: Some("2026-03-07T02:30".into()),
            ..ScheduleClock::default()
        };
        let next = next_run(&schedule, &fired, &new_york).expect("a next run");
        assert_eq!(
            next.datetime(),
            date(2026, 3, 8).at(3, 0, 0, 0),
            "02:30 is skipped that night: it runs at 03:00"
        );
        assert_eq!(next.offset(), jiff::tz::offset(-4));

        schedule.enabled = false;
        assert_eq!(next_run(&schedule, &fired, &new_york), None);
    }

    fn refused(trigger: ScheduleTrigger) -> String {
        Trigger::check(&trigger, at(6, 12, 0)).expect_err("refused")
    }

    #[test]
    fn a_trigger_that_can_come_due_is_accepted() {
        for trigger in [
            ScheduleTrigger::Hourly { minute: 0 },
            ScheduleTrigger::Daily {
                time: "23:59:59".into(),
            },
            ScheduleTrigger::Weekdays {
                time: "09:00".into(),
            },
            ScheduleTrigger::Weekly {
                weekday: "sunday".into(),
                time: "07:00".into(),
            },
            ScheduleTrigger::Once {
                at: "2026-11-06T12:01".into(),
            },
            ScheduleTrigger::Cron {
                expr: "0 0 29 2 *".into(),
            },
        ] {
            assert!(
                Trigger::check(&trigger, at(6, 12, 0)).is_ok(),
                "{trigger:?}"
            );
        }
    }

    #[test]
    fn an_impossible_or_unreadable_trigger_is_refused_saying_why() {
        assert!(refused(ScheduleTrigger::Hourly { minute: 60 }).contains("0-59"));
        assert!(refused(ScheduleTrigger::Daily {
            time: "24:00".into()
        })
        .contains("HH:MM"));
        assert!(refused(ScheduleTrigger::Weekdays {
            time: "9:00".into()
        })
        .contains("HH:MM"));
        assert!(refused(ScheduleTrigger::Weekly {
            weekday: "funday".into(),
            time: "09:00".into()
        })
        .contains("day of the week"));
        assert!(refused(ScheduleTrigger::Once {
            at: "2026-02-30T09:00".into()
        })
        .contains("YYYY-MM-DD"));
        assert!(refused(ScheduleTrigger::Once {
            at: "2026-11-06T12:00".into()
        })
        .contains("past"));
        assert!(refused(ScheduleTrigger::Cron {
            expr: "0 9 * *".into()
        })
        .contains("5 fields"));
        let never = refused(ScheduleTrigger::Cron {
            expr: "0 0 30 2 *".into(),
        });
        assert!(never.contains("never"), "{never}");
        assert!(refused(ScheduleTrigger::Unknown).contains("kind"));
    }

    #[test]
    fn a_stored_value_out_of_range_never_fires() {
        for trigger in [
            ScheduleTrigger::Hourly { minute: 60 },
            ScheduleTrigger::Weekdays {
                time: "25:00".into(),
            },
            ScheduleTrigger::Weekly {
                weekday: "mon".into(),
                time: "09:00".into(),
            },
            ScheduleTrigger::Weekly {
                weekday: "funday".into(),
                time: "09:00".into(),
            },
            ScheduleTrigger::Cron {
                expr: "0 9 * *".into(),
            },
        ] {
            assert_eq!(Trigger::parse(&trigger), None, "{trigger:?}");
        }
    }

    #[test]
    fn a_controller_trigger_is_saved_in_its_stored_form() {
        let now = at(6, 12, 0);
        let saved = |trigger: ScheduleTrigger| for_save(&trigger, true, now);
        assert_eq!(
            saved(ScheduleTrigger::Daily {
                time: "09:43:00".into()
            }),
            Ok(ScheduleTrigger::Daily {
                time: "09:43".into()
            })
        );
        assert_eq!(
            saved(ScheduleTrigger::Weekly {
                weekday: "friday".into(),
                time: "17:00:30".into()
            }),
            Ok(ScheduleTrigger::Weekly {
                weekday: "friday".into(),
                time: "17:00:30".into()
            })
        );
        assert_eq!(
            saved(ScheduleTrigger::Once {
                at: "2026-11-07T08:00:00".into()
            }),
            Ok(ScheduleTrigger::Once {
                at: "2026-11-07T08:00".into()
            })
        );
        assert_eq!(
            saved(ScheduleTrigger::Cron {
                expr: " 0  9 * * 1-5 ".into()
            }),
            Ok(ScheduleTrigger::Cron {
                expr: "0 9 * * 1-5".into()
            })
        );
        assert_eq!(
            saved(ScheduleTrigger::Hourly { minute: 5 }),
            Ok(ScheduleTrigger::Hourly { minute: 5 })
        );
    }

    #[test]
    fn a_paused_task_may_keep_a_time_that_passed_but_never_a_malformed_one() {
        let now = at(6, 12, 0);
        let past = ScheduleTrigger::Once {
            at: "2026-11-06T08:00".into(),
        };
        assert_eq!(
            for_save(&past, true, now),
            Err(TriggerRefusal::InPast(
                "2026-11-06T08:00 is in the past".into()
            ))
        );
        assert_eq!(for_save(&past, false, now), Ok(past));
        let malformed = ScheduleTrigger::Daily {
            time: "25:00".into(),
        };
        let refused = for_save(&malformed, false, now);
        assert!(
            matches!(&refused, Err(TriggerRefusal::Invalid(detail)) if detail.contains("not a local time")),
            "{refused:?}"
        );
        assert!(matches!(
            for_save(&ScheduleTrigger::Unknown, false, now),
            Err(TriggerRefusal::Invalid(_))
        ));
    }
}
