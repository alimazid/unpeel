use super::*;
use jiff::civil::date;

fn at(year: i16, month: i8, day: i8, hour: i8, minute: i8) -> DateTime {
    date(year, month, day).at(hour, minute, 0, 0)
}

fn nov(day: i8, hour: i8, minute: i8) -> DateTime {
    at(2026, 11, day, hour, minute)
}

fn cron(expr: &str) -> CronSpec {
    CronSpec::parse(expr).unwrap_or_else(|error| panic!("{expr}: {error}"))
}

fn refused(expr: &str) -> String {
    CronSpec::parse(expr).expect_err(expr)
}

#[test]
fn an_expression_has_exactly_five_fields() {
    assert!(refused("* * * *").contains("5 fields"));
    assert!(refused("0 * * * * *").contains("5 fields"));
    assert!(refused("").contains("5 fields"));
    assert!(refused("@daily").contains("5 fields"));
}

#[test]
fn a_value_outside_its_field_is_refused_naming_the_field() {
    let error = refused("61 * * * *");
    assert!(
        error.contains("minute") && error.contains("0-59"),
        "{error}"
    );
    let error = refused("0 24 * * *");
    assert!(error.contains("hour") && error.contains("0-23"), "{error}");
    assert!(refused("0 0 0 * *").contains("day of month"));
    assert!(refused("0 0 * 13 *").contains("month"));
    assert!(refused("0 0 * * 8").contains("day of week"));
}

#[test]
fn malformed_lists_ranges_and_steps_are_refused() {
    for expr in [
        "1,,2 * * * *",
        "5-2 * * * *",
        "*/0 * * * *",
        "*/x * * * *",
        "1- * * * *",
        "? * * * *",
        "L * * * *",
        "0 0 * * 5#2",
        "0 0 * FOO *",
        "-1 * * * *",
    ] {
        assert!(CronSpec::parse(expr).is_err(), "{expr} parsed");
    }
}

#[test]
fn steps_ranges_lists_and_names_select_their_times() {
    let office = cron("*/15 9-17 * * 1-5");
    // 2026-11-06 is a Friday.
    assert_eq!(office.next_after(nov(6, 9, 7)), Some(nov(6, 9, 15)));
    assert_eq!(office.next_after(nov(6, 17, 45)), Some(nov(9, 9, 0)));

    let named = cron("30 8 * jan,DEC Mon-Fri");
    assert_eq!(
        named.next_after(nov(6, 12, 0)),
        Some(at(2026, 12, 1, 8, 30))
    );

    let from_five = cron("5/20 * * * *");
    assert_eq!(from_five.next_after(nov(6, 9, 6)), Some(nov(6, 9, 25)));
    assert_eq!(from_five.next_after(nov(6, 9, 45)), Some(nov(6, 10, 5)));
}

#[test]
fn seven_is_sunday_too() {
    assert_eq!(
        cron("0 12 * * 7").next_after(nov(6, 0, 0)),
        Some(nov(8, 12, 0))
    );
    assert_eq!(
        cron("0 12 * * 0").next_after(nov(6, 0, 0)),
        Some(nov(8, 12, 0))
    );
}

#[test]
fn a_day_of_month_and_a_day_of_week_both_restricted_match_either() {
    // The 1st, or any Monday.
    let either = cron("0 0 1 * 1");
    assert_eq!(either.next_after(nov(6, 0, 0)), Some(nov(9, 0, 0)));
    assert_eq!(
        either.next_after(nov(30, 0, 0)),
        Some(at(2026, 12, 1, 0, 0))
    );

    // A day field starting with `*` restricts with AND: odd days that are
    // Mondays (Mondays in November 2026: 2, 9, 16, 23, 30).
    let both = cron("0 0 */2 * 1");
    assert_eq!(both.next_after(nov(6, 0, 0)), Some(nov(9, 0, 0)));
    assert_eq!(both.next_after(nov(9, 0, 0)), Some(nov(23, 0, 0)));
}

#[test]
fn a_rare_date_is_found_and_an_impossible_one_never_is() {
    assert_eq!(
        cron("0 0 29 2 *").next_after(nov(6, 0, 0)),
        Some(at(2028, 2, 29, 0, 0))
    );
    assert_eq!(cron("0 0 30 2 *").next_after(nov(6, 0, 0)), None);
    assert_eq!(cron("0 0 31 4,6,9,11 *").next_after(nov(6, 0, 0)), None);
}

#[test]
fn the_latest_occurrence_is_the_one_due() {
    let quarter = cron("*/15 * * * *");
    assert_eq!(
        quarter.latest_due(nov(6, 8, 0), nov(6, 9, 7)),
        Some(nov(6, 9, 0))
    );
    assert_eq!(quarter.latest_due(nov(6, 9, 0), nov(6, 9, 7)), None);
    assert_eq!(
        quarter.latest_due(nov(6, 9, 0), nov(6, 9, 15)),
        Some(nov(6, 9, 15)),
        "due from the start of its minute"
    );

    let monthly = cron("0 6 1 * *");
    assert_eq!(
        monthly.latest_due(at(2026, 9, 15, 0, 0), nov(6, 12, 0)),
        Some(nov(1, 6, 0)),
        "a gap of months is one occurrence, the latest"
    );
    assert_eq!(monthly.latest_due(nov(1, 6, 0), nov(30, 23, 59)), None);
    assert_eq!(
        cron("0 0 30 2 *").latest_due(nov(1, 0, 0), nov(6, 0, 0)),
        None
    );
}

#[test]
fn an_occurrence_counts_in_whole_minutes() {
    let every_minute = cron("* * * * *");
    let half_past = date(2026, 11, 6).at(9, 0, 30, 0);
    assert_eq!(every_minute.next_after(half_past), Some(nov(6, 9, 1)));
    assert_eq!(
        every_minute.latest_due(nov(6, 8, 59), half_past),
        Some(nov(6, 9, 0))
    );
}
