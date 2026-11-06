//! Fork-only: the supervisor's settings — flat `supervisor_*` app-state
//! keys, parsed leniently and re-read on every sweep.

use serde_json::Value;

/// The supervisor's settings: flat `supervisor_*` app-state keys, re-read on
/// every sweep. Minute settings are held in ms; `0` turns that alarm off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SupervisorConfig {
    /// A Busy Worker with no progress this long is reported `stalled`.
    pub stall_ms: u64,
    /// A Worker waiting on a prompt this long is reported to its Router.
    pub blocked_ms: u64,
    /// A Worker prompt unanswered this long notifies the user once.
    pub escalate_ms: u64,
    /// Longest Worker turn before an alarm (`0`: no limit).
    pub max_turn_ms: u64,
    /// Running Workers one Router may have (1–32).
    pub max_children: usize,
    pub max_spawns_per_minute: u32,
    pub max_deliveries_per_hour: u32,
    /// Whether a Worker starting is worth a Router notice.
    pub notify_started: bool,
    /// Deliver to a Session with no confident idle signal on a best guess.
    pub inbox_low_confidence: bool,
}

const STALL_MINUTES: (&str, &[u64], u64) =
    ("supervisor_stall_minutes", &[0, 5, 10, 15, 20, 30, 60], 20);
const BLOCKED_MINUTES: (&str, &[u64], u64) =
    ("supervisor_blocked_minutes", &[0, 5, 10, 15, 30, 60], 10);
const ESCALATE_MINUTES: (&str, &[u64], u64) = (
    "supervisor_escalate_minutes",
    &[0, 1, 2, 5, 10, 15, 30, 60],
    5,
);
const MAX_TURN_MINUTES: (&str, &[u64], u64) =
    ("supervisor_max_turn_minutes", &[0, 30, 60, 120, 240], 0);
const MAX_CHILDREN: (&str, std::ops::RangeInclusive<u64>, usize) =
    ("supervisor_max_children", 1..=32, 8);
const MAX_SPAWNS_PER_MINUTE: (&str, u32) = ("supervisor_max_spawns_per_minute", 6);
const MAX_DELIVERIES_PER_HOUR: (&str, u32) = ("supervisor_max_deliveries_per_hour", 60);
const NOTIFY_STARTED: (&str, bool) = ("supervisor_notify_started", false);
const INBOX_LOW_CONFIDENCE: (&str, bool) = ("supervisor_inbox_low_confidence", true);

impl Default for SupervisorConfig {
    fn default() -> Self {
        config_from_state(&Value::Null, false)
    }
}

/// The settings on disk; a missing or unreadable file is all defaults.
pub fn load_config() -> SupervisorConfig {
    let state = crate::app_state::load().unwrap_or(Value::Null);
    let seconds_mode = seconds_mode_from(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var("UNPEEL_SUPERVISOR_SECONDS").ok().as_deref(),
    );
    config_from_state(&state, seconds_mode)
}

/// Lenient: junk falls back to the default, never to something shorter.
/// `seconds_mode` (tests only) counts minute settings as seconds.
pub fn config_from_state(state: &Value, seconds_mode: bool) -> SupervisorConfig {
    let unit_ms = if seconds_mode { 1_000 } else { 60_000 };
    let minutes = |(key, options, default): (&str, &[u64], u64)| {
        let value = state
            .get(key)
            .and_then(Value::as_u64)
            .filter(|minutes| options.contains(minutes))
            .unwrap_or(default);
        value * unit_ms
    };
    let rate = |(key, default): (&str, u32)| {
        state
            .get(key)
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .filter(|value| *value > 0)
            .unwrap_or(default)
    };
    let flag =
        |(key, default): (&str, bool)| state.get(key).and_then(Value::as_bool).unwrap_or(default);
    let (children_key, children_range, children_default) = MAX_CHILDREN;
    SupervisorConfig {
        stall_ms: minutes(STALL_MINUTES),
        blocked_ms: minutes(BLOCKED_MINUTES),
        escalate_ms: minutes(ESCALATE_MINUTES),
        max_turn_ms: minutes(MAX_TURN_MINUTES),
        max_children: state
            .get(children_key)
            .and_then(Value::as_u64)
            .filter(|count| children_range.contains(count))
            .map_or(children_default, |count| count as usize),
        max_spawns_per_minute: rate(MAX_SPAWNS_PER_MINUTE),
        max_deliveries_per_hour: rate(MAX_DELIVERIES_PER_HOUR),
        notify_started: flag(NOTIFY_STARTED),
        inbox_low_confidence: flag(INBOX_LOW_CONFIDENCE),
    }
}

/// `UNPEEL_TEST=1` plus `UNPEEL_SUPERVISOR_SECONDS=1`, both exactly.
pub(crate) fn seconds_mode_from(test: Option<&str>, seconds: Option<&str>) -> bool {
    test == Some("1") && seconds == Some("1")
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINUTE: u64 = 60_000;

    #[test]
    fn supervisor_config_defaults_when_nothing_is_set() {
        let config = config_from_state(&serde_json::json!({}), false);
        assert_eq!(
            config,
            SupervisorConfig {
                stall_ms: 20 * MINUTE,
                blocked_ms: 10 * MINUTE,
                escalate_ms: 5 * MINUTE,
                max_turn_ms: 0,
                max_children: 8,
                max_spawns_per_minute: 6,
                max_deliveries_per_hour: 60,
                notify_started: false,
                inbox_low_confidence: true,
            }
        );
        assert_eq!(SupervisorConfig::default(), config);
    }

    #[test]
    fn supervisor_config_reads_valid_settings() {
        let config = config_from_state(
            &serde_json::json!({
                "supervisor_stall_minutes": 60,
                "supervisor_blocked_minutes": 0,
                "supervisor_escalate_minutes": 15,
                "supervisor_max_turn_minutes": 120,
                "supervisor_max_children": 32,
                "supervisor_max_spawns_per_minute": 2,
                "supervisor_max_deliveries_per_hour": 500,
                "supervisor_notify_started": true,
                "supervisor_inbox_low_confidence": false,
            }),
            false,
        );
        assert_eq!(config.stall_ms, 60 * MINUTE);
        assert_eq!(config.blocked_ms, 0, "0 turns the blocked alarm off");
        assert_eq!(config.escalate_ms, 15 * MINUTE);
        assert_eq!(config.max_turn_ms, 120 * MINUTE);
        assert_eq!(config.max_children, 32);
        assert_eq!(config.max_spawns_per_minute, 2);
        assert_eq!(config.max_deliveries_per_hour, 500);
        assert!(config.notify_started);
        assert!(!config.inbox_low_confidence);
    }

    #[test]
    fn junk_supervisor_settings_read_as_the_defaults() {
        let config = config_from_state(
            &serde_json::json!({
                "supervisor_stall_minutes": 7,
                "supervisor_blocked_minutes": "ten",
                "supervisor_escalate_minutes": -5,
                "supervisor_max_turn_minutes": 1.5,
                "supervisor_max_children": 33,
                "supervisor_max_spawns_per_minute": 0,
                "supervisor_max_deliveries_per_hour": null,
                "supervisor_notify_started": "yes",
                "supervisor_inbox_low_confidence": 0,
            }),
            false,
        );
        assert_eq!(config, SupervisorConfig::default());
        let config = config_from_state(&serde_json::json!({ "supervisor_max_children": 0 }), false);
        assert_eq!(config.max_children, 8);
    }

    #[test]
    fn seconds_mode_counts_minute_settings_in_seconds() {
        let config = config_from_state(
            &serde_json::json!({ "supervisor_stall_minutes": 5, "supervisor_max_turn_minutes": 30 }),
            true,
        );
        assert_eq!(config.stall_ms, 5_000);
        assert_eq!(config.blocked_ms, 10_000);
        assert_eq!(config.escalate_ms, 5_000);
        assert_eq!(config.max_turn_ms, 30_000);
        // Counts and rates are not minute settings.
        assert_eq!(config.max_children, 8);
        assert_eq!(config.max_spawns_per_minute, 6);
    }

    #[test]
    fn seconds_mode_needs_both_test_switches() {
        assert!(seconds_mode_from(Some("1"), Some("1")));
        assert!(!seconds_mode_from(None, Some("1")));
        assert!(!seconds_mode_from(Some("1"), None));
        assert!(!seconds_mode_from(Some("0"), Some("1")));
        assert!(!seconds_mode_from(Some("1"), Some("true")));
    }
}
