//! When a Trigger's occurrences fall, in local (civil) time.
//!
//! Occurrences are compared as local date-times, not instants: a Trigger is
//! read on the local wall clock, so a time that a clock change skips is due
//! as soon as the clock is past it, a repeated time is one occurrence, and a
//! time zone change moves every later occurrence with the clock.

use jiff::civil::{DateTime, Time};
use unpeel_core::schedules::ScheduleTrigger;

use super::clock;

/// A Trigger this build can evaluate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    Once(DateTime),
    Daily(Time),
}

impl Trigger {
    /// `None` for an unknown kind or a time that does not parse: such a task
    /// never fires.
    pub fn parse(trigger: &ScheduleTrigger) -> Option<Self> {
        match trigger {
            ScheduleTrigger::Once { at } => clock::parse_datetime(at).map(Self::Once),
            ScheduleTrigger::Daily { time } => clock::parse_time(time).map(Self::Daily),
            ScheduleTrigger::Unknown => None,
        }
    }

    /// The latest occurrence strictly after `after` and at or before `now`.
    pub fn latest_due(self, after: DateTime, now: DateTime) -> Option<DateTime> {
        let latest = match self {
            Self::Once(at) => Some(at).filter(|at| *at <= now)?,
            Self::Daily(time) => {
                let today = now.date().to_datetime(time);
                if today <= now {
                    today
                } else {
                    now.date().yesterday().ok()?.to_datetime(time)
                }
            }
        };
        (latest > after).then_some(latest)
    }

    /// The first occurrence strictly after `after`.
    pub fn next_after(self, after: DateTime) -> Option<DateTime> {
        match self {
            Self::Once(at) => (at > after).then_some(at),
            Self::Daily(time) => {
                let same_day = after.date().to_datetime(time);
                if same_day > after {
                    Some(same_day)
                } else {
                    Some(after.date().tomorrow().ok()?.to_datetime(time))
                }
            }
        }
    }

    pub fn is_once(self) -> bool {
        matches!(self, Self::Once(_))
    }
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
}
