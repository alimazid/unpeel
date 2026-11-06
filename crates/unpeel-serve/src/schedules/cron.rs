//! The cron Trigger: a 5-field expression (minute hour day-of-month month
//! day-of-week) matched against local (civil) date-times, so it follows
//! the same wall-clock rules as every other Trigger kind.
//!
//! The syntax is the classic one: `*`, a value, `a-b`, a `/step` on any of
//! those (`5/20` runs 5, 25, 45), comma lists, and English month and day
//! names. Day of week runs 0-7 with both 0 and 7 Sunday. When day of month
//! and day of week are both restricted, a day matching either fires; a day
//! field starting with `*` restricts with AND (Vixie cron's rule). Seconds,
//! years, `?`, `L`, `W`, `#` and `@` macros are refused.
//!
//! A hand-written parser rather than `croner`: croner's syntax is a
//! superset this would have to fence off field by field, and it brings two
//! proc-macro dependency trees (`derive_builder`, `strum`) into every
//! binary for what is a few bitmasks.

use jiff::civil::{Date, DateTime};
use jiff::ToSpan;

/// How far a search looks for an occurrence before calling it never: past
/// the longest gap a real expression has (a weekday-and-date pair can
/// recur 12 years apart), and short enough to stay cheap every sweep.
const HORIZON_YEARS: i16 = 50;

const MONTH_NAMES: [&str; 12] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];
const DAY_NAMES: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/// One field of the expression: what it is called, its range, and the
/// names it accepts (the first name standing for `min`).
struct Field {
    name: &'static str,
    min: u8,
    max: u8,
    names: &'static [&'static str],
}

const MINUTE: Field = Field {
    name: "minute",
    min: 0,
    max: 59,
    names: &[],
};
const HOUR: Field = Field {
    name: "hour",
    min: 0,
    max: 23,
    names: &[],
};
const DAY_OF_MONTH: Field = Field {
    name: "day of month",
    min: 1,
    max: 31,
    names: &[],
};
const MONTH: Field = Field {
    name: "month",
    min: 1,
    max: 12,
    names: &MONTH_NAMES,
};
const DAY_OF_WEEK: Field = Field {
    name: "day of week",
    min: 0,
    max: 7,
    names: &DAY_NAMES,
};

/// A parsed expression: one bit per allowed value of each field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CronSpec {
    minutes: u64,
    hours: u64,
    days_of_month: u64,
    months: u64,
    /// Sunday as bit 0.
    days_of_week: u64,
    /// Both day fields are restricted, so either one matching is enough.
    either_day: bool,
}

impl CronSpec {
    /// The expression, or why it is not one: the message names the field
    /// and the part that is wrong.
    pub fn parse(expr: &str) -> Result<Self, String> {
        let fields: Vec<&str> = expr.split_whitespace().collect();
        let [minute, hour, day_of_month, month, day_of_week] = fields[..] else {
            return Err(format!(
                "a cron expression has 5 fields (minute hour day-of-month month day-of-week); {expr:?} has {}",
                fields.len()
            ));
        };
        let days_of_week = parse_field(day_of_week, &DAY_OF_WEEK)?;
        Ok(Self {
            minutes: parse_field(minute, &MINUTE)?,
            hours: parse_field(hour, &HOUR)?,
            days_of_month: parse_field(day_of_month, &DAY_OF_MONTH)?,
            months: parse_field(month, &MONTH)?,
            // 7 is Sunday as well as 0.
            days_of_week: (days_of_week | (days_of_week >> 7)) & 0x7f,
            either_day: !day_of_month.starts_with('*') && !day_of_week.starts_with('*'),
        })
    }

    /// The first occurrence strictly after `after`.
    pub fn next_after(&self, after: DateTime) -> Option<DateTime> {
        let start = whole_minute(after).checked_add(1.minute()).ok()?;
        let last_day = start.date().checked_add(HORIZON_YEARS.years()).ok()?;
        let mut day = start.date();
        let mut from = (start.hour(), start.minute());
        while day <= last_day {
            if !self.month_matches(day) {
                day = day.first_of_month().checked_add(1.month()).ok()?;
                from = (0, 0);
                continue;
            }
            if self.day_matches(day) {
                if let Some((hour, minute)) = self.first_from(from) {
                    return Some(day.at(hour, minute, 0, 0));
                }
            }
            day = day.tomorrow().ok()?;
            from = (0, 0);
        }
        None
    }

    /// The latest occurrence at or before `now`, if it is strictly after
    /// `after`.
    pub fn latest_due(&self, after: DateTime, now: DateTime) -> Option<DateTime> {
        let floor = after
            .date()
            .max(now.date().checked_sub(HORIZON_YEARS.years()).ok()?);
        let mut day = now.date();
        let mut until = (now.hour(), now.minute());
        while day >= floor {
            if !self.month_matches(day) {
                day = day.first_of_month().yesterday().ok()?;
                until = (23, 59);
                continue;
            }
            if self.day_matches(day) {
                if let Some((hour, minute)) = self.last_until(until) {
                    let latest = day.at(hour, minute, 0, 0);
                    return (latest > after).then_some(latest);
                }
            }
            day = day.yesterday().ok()?;
            until = (23, 59);
        }
        None
    }

    fn month_matches(&self, day: Date) -> bool {
        has(self.months, day.month())
    }

    fn day_matches(&self, day: Date) -> bool {
        let by_date = has(self.days_of_month, day.day());
        let by_weekday = has(self.days_of_week, day.weekday().to_sunday_zero_offset());
        if self.either_day {
            by_date || by_weekday
        } else {
            by_date && by_weekday
        }
    }

    /// The first allowed hour and minute at or after `from` in one day.
    fn first_from(&self, (hour, minute): (i8, i8)) -> Option<(i8, i8)> {
        for candidate in hour..24 {
            if !has(self.hours, candidate) {
                continue;
            }
            let start = if candidate == hour { minute } else { 0 };
            if let Some(found) = (start..60).find(|m| has(self.minutes, *m)) {
                return Some((candidate, found));
            }
        }
        None
    }

    /// The last allowed hour and minute at or before `until` in one day.
    fn last_until(&self, (hour, minute): (i8, i8)) -> Option<(i8, i8)> {
        for candidate in (0..=hour).rev() {
            if !has(self.hours, candidate) {
                continue;
            }
            let end = if candidate == hour { minute } else { 59 };
            if let Some(found) = (0..=end).rev().find(|m| has(self.minutes, *m)) {
                return Some((candidate, found));
            }
        }
        None
    }
}

fn has(bits: u64, value: i8) -> bool {
    u32::try_from(value).is_ok_and(|value| value < 64 && bits & (1 << value) != 0)
}

fn whole_minute(at: DateTime) -> DateTime {
    at.date().at(at.hour(), at.minute(), 0, 0)
}

/// One field's bits; the error names the field and its range.
fn parse_field(text: &str, field: &Field) -> Result<u64, String> {
    let complain = |problem: String| {
        format!(
            "cron {} field {text:?}: {problem} (allowed {}-{})",
            field.name, field.min, field.max
        )
    };
    let mut bits = 0u64;
    for item in text.split(',') {
        bits |= parse_item(item, field).map_err(complain)?;
    }
    Ok(bits)
}

/// `*`, `a`, `a-b`, each with an optional `/step`.
fn parse_item(item: &str, field: &Field) -> Result<u64, String> {
    let (base, step) = match item.split_once('/') {
        Some((base, step)) => (base, Some(step)),
        None => (item, None),
    };
    let step = match step {
        None => 1,
        Some(step) => match step.parse::<u8>() {
            Ok(0) | Err(_) => return Err(format!("{step:?} is not a step of 1 or more")),
            Ok(step) => step,
        },
    };
    let (low, high) = if base == "*" {
        (field.min, field.max)
    } else if let Some((low, high)) = base.split_once('-') {
        let (low, high) = (value(low, field)?, value(high, field)?);
        if low > high {
            return Err(format!("the range {base} runs backwards"));
        }
        (low, high)
    } else {
        let low = value(base, field)?;
        // `5/20` steps from 5 to the end of the field.
        (low, if item.contains('/') { field.max } else { low })
    };
    Ok((low..=high)
        .step_by(usize::from(step))
        .fold(0u64, |bits, value| bits | (1 << value)))
}

/// A number or a name in the field's range.
fn value(text: &str, field: &Field) -> Result<u8, String> {
    let lower = text.to_ascii_lowercase();
    let named = field
        .names
        .iter()
        .position(|name| *name == lower)
        .and_then(|index| u8::try_from(index).ok())
        .map(|index| index + field.min);
    let value = match named {
        Some(value) => value,
        None => text
            .parse::<u8>()
            .map_err(|_| format!("{text:?} is not a number"))?,
    };
    if value < field.min || value > field.max {
        return Err(format!("{value} is out of range"));
    }
    Ok(value)
}

#[cfg(test)]
mod tests;
