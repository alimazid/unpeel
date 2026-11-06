//! The scheduler's wall clock: the current zoned time, and the civil
//! (local date-time) strings Triggers and clocks are stored as.
//!
//! Every reading of "now" goes through [`now`]. Never an `Instant`: it stops
//! while the Mac sleeps, and a Trigger missed in sleep must still fire once
//! on wake.

use jiff::civil::{DateTime, Time};
use jiff::tz::TimeZone;
use jiff::{Timestamp, Zoned};

/// The current time in the system time zone.
///
/// `TimeZone::try_system` caches the zone for about five minutes, so travel
/// takes effect within that; a failed lookup reads as UTC rather than
/// stopping every schedule. Keep this the only source of "now".
pub fn now() -> Zoned {
    Timestamp::now().to_zoned(system_zone())
}

/// The zone [`now`] reads in; also the zone CLI output is shown in.
pub fn system_zone() -> TimeZone {
    TimeZone::try_system().unwrap_or(TimeZone::UTC)
}

/// Epoch milliseconds of `zoned`, clamped at the epoch.
pub fn epoch_ms(zoned: &Zoned) -> u64 {
    u64::try_from(zoned.timestamp().as_millisecond()).unwrap_or(0)
}

/// The local date-time of an epoch-millisecond instant in `zone`.
pub fn civil_at_ms(ms: u64, zone: &TimeZone) -> Option<DateTime> {
    let ms = i64::try_from(ms).ok()?;
    Some(
        Timestamp::from_millisecond(ms)
            .ok()?
            .to_zoned(zone.clone())
            .datetime(),
    )
}

/// The instant a local date-time names in `zone`. A time a clock change
/// skips or repeats resolves the way jiff's `compatible` rule does.
pub fn ms_of(civil: DateTime, zone: &TimeZone) -> Option<u64> {
    civil
        .to_zoned(zone.clone())
        .ok()
        .map(|zoned| epoch_ms(&zoned))
}

/// `HH:MM`, or `HH:MM:SS`. Exactly those shapes: the stored form is a
/// contract with every Controller, not whatever a parser tolerates.
pub fn parse_time(raw: &str) -> Option<Time> {
    let raw = raw.trim();
    if !matches!(raw.len(), 5 | 8) {
        return None;
    }
    raw.parse().ok()
}

/// `YYYY-MM-DDTHH:MM`, or `YYYY-MM-DDTHH:MM:SS`.
pub fn parse_datetime(raw: &str) -> Option<DateTime> {
    let raw = raw.trim();
    let (day, time) = raw.split_once('T')?;
    if day.len() != 10 {
        return None;
    }
    let time = parse_time(time)?;
    let day: jiff::civil::Date = day.parse().ok()?;
    Some(day.to_datetime(time))
}

/// The stored form of a time: seconds only when they are not zero.
pub fn format_time(time: Time) -> String {
    if time.second() == 0 {
        time.strftime("%H:%M").to_string()
    } else {
        time.strftime("%H:%M:%S").to_string()
    }
}

/// The stored form of a local date-time, like [`format_time`].
pub fn format_datetime(civil: DateTime) -> String {
    format!(
        "{}T{}",
        civil.date().strftime("%Y-%m-%d"),
        format_time(civil.time())
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::{date, time};

    #[test]
    fn stored_times_take_minutes_or_whole_seconds() {
        assert_eq!(parse_time("09:43"), Some(time(9, 43, 0, 0)));
        assert_eq!(parse_time("09:43:30"), Some(time(9, 43, 30, 0)));
        assert_eq!(parse_time("9:43"), None);
        assert_eq!(parse_time("24:00"), None);
        assert_eq!(parse_time("09:43:30.5"), None);
        assert_eq!(parse_time("soon"), None);
        assert_eq!(
            parse_datetime("2026-11-06T15:00"),
            Some(date(2026, 11, 6).at(15, 0, 0, 0))
        );
        assert_eq!(
            parse_datetime("2026-11-06T15:00:05"),
            Some(date(2026, 11, 6).at(15, 0, 5, 0))
        );
        assert_eq!(parse_datetime("2026-02-30T15:00"), None);
        assert_eq!(parse_datetime("2026-11-06"), None);
    }

    #[test]
    fn stored_forms_drop_zero_seconds() {
        assert_eq!(format_time(time(9, 5, 0, 0)), "09:05");
        assert_eq!(format_time(time(9, 5, 7, 0)), "09:05:07");
        assert_eq!(
            format_datetime(date(2026, 11, 6).at(15, 0, 0, 0)),
            "2026-11-06T15:00"
        );
        assert_eq!(
            format_datetime(date(2026, 11, 6).at(15, 0, 5, 0)),
            "2026-11-06T15:00:05"
        );
    }

    #[test]
    fn instants_and_local_times_agree_in_a_fixed_zone() {
        let zone = TimeZone::fixed(jiff::tz::offset(-5));
        let civil = date(2026, 11, 6).at(9, 0, 0, 0);
        let ms = ms_of(civil, &zone).expect("in range");
        assert_eq!(ms, 1_793_973_600_000);
        assert_eq!(civil_at_ms(ms, &zone), Some(civil));
    }
}
