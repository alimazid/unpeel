//! The scheduler's wall clock: the current zoned time, and the civil
//! (local date-time) strings Triggers and clocks are stored as.
//!
//! Every reading of "now" goes through [`now`]. Never an `Instant`: it stops
//! while the Mac sleeps, and a Trigger missed in sleep must still fire once
//! on wake.

use jiff::civil::{DateTime, Time, Weekday};
use jiff::tz::{AmbiguousOffset, TimeZone};
use jiff::{Timestamp, Zoned};
use std::path::Path;
use std::sync::{Mutex, PoisonError};

/// The system's local zone: where the OS points it when the Mac travels.
const LOCALTIME: &str = "/etc/localtime";

/// The current time in the system time zone. Keep this the only source of
/// "now".
pub fn now() -> Zoned {
    Timestamp::now().to_zoned(system_zone())
}

/// The zone [`now`] reads in; also the zone CLI output is shown in.
///
/// Looked up afresh on every call (the worker asks once a sweep), so travel
/// takes effect on the next sweep: `TimeZone::try_system` would keep a
/// stale zone for up to five minutes. `TZ`, when set, wins, as it does for
/// every other program. A lookup that fails (the OS replacing the link
/// mid-change) keeps the last zone read rather than jumping to UTC, which
/// would fire every task at the wrong hour.
pub fn system_zone() -> TimeZone {
    static LAST_READ: Mutex<Option<TimeZone>> = Mutex::new(None);
    let read = if std::env::var_os("TZ").is_some() {
        TimeZone::try_system().ok()
    } else {
        zone_from_localtime(Path::new(LOCALTIME))
    };
    let mut last = LAST_READ.lock().unwrap_or_else(PoisonError::into_inner);
    match read {
        Some(zone) => {
            *last = Some(zone.clone());
            zone
        }
        None => last
            .clone()
            .or_else(|| TimeZone::try_system().ok())
            .unwrap_or(TimeZone::UTC),
    }
}

/// The zone a `localtime` file names: by the tz database name its link
/// points at (`…/zoneinfo/America/New_York`), else the rules it holds.
pub fn zone_from_localtime(localtime: &Path) -> Option<TimeZone> {
    let named = std::fs::read_link(localtime).ok().and_then(|target| {
        let target = target.to_str()?.to_string();
        let (_, name) = target.rsplit_once("zoneinfo/")?;
        jiff::tz::db().get(name).ok()
    });
    named.or_else(|| {
        let rules = std::fs::read(localtime).ok()?;
        TimeZone::tzif("Local", &rules).ok()
    })
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

/// The instant a task due at local `civil` comes due in `zone`: the first
/// instant the wall clock reads `civil` or later, which is when the due
/// rule fires it. A time the clock skips comes due when the clock change
/// ends it (02:30 on a spring-forward night is due at 03:00); a time the
/// clock repeats comes due on its first pass.
pub fn due_ms(civil: DateTime, zone: &TimeZone) -> Option<u64> {
    let ambiguous = zone.to_ambiguous_timestamp(civil);
    let due = match ambiguous.offset() {
        AmbiguousOffset::Unambiguous { offset } => offset.to_timestamp(civil).ok()?,
        AmbiguousOffset::Fold { before, .. } => before.to_timestamp(civil).ok()?,
        AmbiguousOffset::Gap { after, .. } => {
            // Read with the later offset, the time falls just before the
            // clock change; the change itself is the first instant after.
            let ahead_of_gap = after.to_timestamp(civil).ok()?;
            zone.following(ahead_of_gap).next()?.timestamp()
        }
    };
    u64::try_from(due.as_millisecond()).ok()
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

/// Days as stored, Monday first.
const WEEKDAY_NAMES: [(&str, Weekday); 7] = [
    ("monday", Weekday::Monday),
    ("tuesday", Weekday::Tuesday),
    ("wednesday", Weekday::Wednesday),
    ("thursday", Weekday::Thursday),
    ("friday", Weekday::Friday),
    ("saturday", Weekday::Saturday),
    ("sunday", Weekday::Sunday),
];

/// A stored weekday: its lowercase English name, exactly.
pub fn parse_weekday(raw: &str) -> Option<Weekday> {
    WEEKDAY_NAMES
        .iter()
        .find(|(name, _)| *name == raw)
        .map(|(_, day)| *day)
}

/// A weekday as a person types it: the name or its first three letters,
/// any case (`Fri`, `friday`).
pub fn weekday_from_input(raw: &str) -> Option<Weekday> {
    let raw = raw.trim().to_ascii_lowercase();
    WEEKDAY_NAMES
        .iter()
        .find(|(name, _)| *name == raw || (raw.len() == 3 && name.starts_with(&raw)))
        .map(|(_, day)| *day)
}

/// The stored form of a weekday.
pub fn weekday_name(day: Weekday) -> &'static str {
    WEEKDAY_NAMES
        .iter()
        .find(|(_, named)| *named == day)
        .map(|(name, _)| *name)
        .unwrap_or("monday")
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
        let ms = due_ms(civil, &zone).expect("in range");
        assert_eq!(ms, 1_793_973_600_000);
        assert_eq!(civil_at_ms(ms, &zone), Some(civil));
    }

    #[test]
    fn a_repeated_time_is_due_on_its_first_pass() {
        let new_york = TimeZone::posix("EST5EDT,M3.2.0,M11.1.0").unwrap();
        let repeated = date(2026, 11, 1).at(1, 30, 0, 0);
        let first_pass = jiff::tz::offset(-4).to_timestamp(repeated).unwrap();
        assert_eq!(
            due_ms(repeated, &new_york),
            Some(first_pass.as_millisecond() as u64)
        );
    }

    /// The system zone's file, as a test's own `/etc/localtime`.
    fn zoneinfo(name: &str) -> Option<std::path::PathBuf> {
        let path = std::path::Path::new("/usr/share/zoneinfo").join(name);
        path.exists().then_some(path)
    }

    #[test]
    fn the_local_zone_follows_its_link_each_time_it_is_read() {
        let (Some(tokyo), Some(paris)) = (zoneinfo("Asia/Tokyo"), zoneinfo("Europe/Paris")) else {
            eprintln!("no tz database at /usr/share/zoneinfo; nothing to resolve");
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        let localtime = dir.path().join("localtime");
        std::os::unix::fs::symlink(&tokyo, &localtime).unwrap();
        let zone = zone_from_localtime(&localtime).expect("a zone");
        assert_eq!(zone.iana_name(), Some("Asia/Tokyo"));

        // Travel: the system re-points the link.
        std::fs::remove_file(&localtime).unwrap();
        std::os::unix::fs::symlink(&paris, &localtime).unwrap();
        let zone = zone_from_localtime(&localtime).expect("a zone");
        assert_eq!(zone.iana_name(), Some("Europe/Paris"));
    }

    #[test]
    fn a_local_zone_that_is_a_copy_reads_its_rules() {
        let Some(tokyo) = zoneinfo("Asia/Tokyo") else {
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        let localtime = dir.path().join("localtime");
        std::fs::copy(tokyo, &localtime).unwrap();
        let zone = zone_from_localtime(&localtime).expect("a zone");
        let noon_utc = Timestamp::from_second(1_793_966_400).unwrap();
        assert_eq!(zone.to_offset(noon_utc), jiff::tz::offset(9));

        assert!(zone_from_localtime(&dir.path().join("missing")).is_none());
    }
}
