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
    /// A Worker whose context is this full (percent of its model's window)
    /// when a turn ends is compacted by the Host (#64); `0`: never.
    pub compact_percent: u8,
}

/// One `supervisor_*` app-state key: the values it accepts and its default.
/// The supervisor reads it through this, and `unpeel settings` sets it
/// through this, so both agree on every value.
#[derive(Debug, PartialEq, Eq)]
pub struct SupervisorSetting {
    pub key: &'static str,
    values: Values,
    /// A number, or `1`/`0` for a flag.
    default: u64,
    /// The accepted values, for an error message.
    pub allowed: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Values {
    /// Minutes from a fixed menu; `0` turns that alarm off.
    Minutes(&'static [u64]),
    /// A percent from a fixed menu; `0` turns it off.
    Percent(&'static [u64]),
    /// A whole number in `low..=high`.
    Range(u64, u64),
    /// A whole number from 1 to `u32::MAX`.
    Positive,
    Flag,
}

const STALL_MINUTES: SupervisorSetting = SupervisorSetting {
    key: "supervisor_stall_minutes",
    values: Values::Minutes(&[0, 5, 10, 15, 20, 30, 60]),
    default: 20,
    allowed: "0, 5, 10, 15, 20, 30, or 60 (0 = off)",
};
const BLOCKED_MINUTES: SupervisorSetting = SupervisorSetting {
    key: "supervisor_blocked_minutes",
    values: Values::Minutes(&[0, 5, 10, 15, 30, 60]),
    default: 10,
    allowed: "0, 5, 10, 15, 30, or 60 (0 = off)",
};
const ESCALATE_MINUTES: SupervisorSetting = SupervisorSetting {
    key: "supervisor_escalate_minutes",
    values: Values::Minutes(&[0, 1, 2, 5, 10, 15, 30, 60]),
    default: 5,
    allowed: "0, 1, 2, 5, 10, 15, 30, or 60 (0 = off)",
};
const MAX_TURN_MINUTES: SupervisorSetting = SupervisorSetting {
    key: "supervisor_max_turn_minutes",
    values: Values::Minutes(&[0, 30, 60, 120, 240]),
    default: 0,
    allowed: "0, 30, 60, 120, or 240 (0 = no limit)",
};
const MAX_CHILDREN: SupervisorSetting = SupervisorSetting {
    key: "supervisor_max_children",
    values: Values::Range(1, 32),
    default: 8,
    allowed: "a whole number from 1 to 32",
};
const MAX_SPAWNS_PER_MINUTE: SupervisorSetting = SupervisorSetting {
    key: "supervisor_max_spawns_per_minute",
    values: Values::Positive,
    default: 6,
    allowed: "a whole number of at least 1",
};
const MAX_DELIVERIES_PER_HOUR: SupervisorSetting = SupervisorSetting {
    key: "supervisor_max_deliveries_per_hour",
    values: Values::Positive,
    default: 60,
    allowed: "a whole number of at least 1",
};
const NOTIFY_STARTED: SupervisorSetting = SupervisorSetting {
    key: "supervisor_notify_started",
    values: Values::Flag,
    default: 0,
    allowed: "true or false",
};
const INBOX_LOW_CONFIDENCE: SupervisorSetting = SupervisorSetting {
    key: "supervisor_inbox_low_confidence",
    values: Values::Flag,
    default: 1,
    allowed: "true or false",
};

/// Nothing below 25: the startup context comes back after a compaction
/// (7–10% of a 1M window), so a lower value would compact every turn.
const COMPACT_PERCENT: SupervisorSetting = SupervisorSetting {
    key: "supervisor_compact_percent",
    values: Values::Percent(&[0, 25, 30, 40, 50, 60, 70]),
    default: 40,
    allowed: "0, 25, 30, 40, 50, 60, or 70 (0 = off)",
};

/// Every `supervisor_*` key, in `unpeel settings list` order.
pub const SUPERVISOR_SETTINGS: [&SupervisorSetting; 10] = [
    &STALL_MINUTES,
    &BLOCKED_MINUTES,
    &ESCALATE_MINUTES,
    &MAX_TURN_MINUTES,
    &MAX_CHILDREN,
    &MAX_SPAWNS_PER_MINUTE,
    &MAX_DELIVERIES_PER_HOUR,
    &NOTIFY_STARTED,
    &INBOX_LOW_CONFIDENCE,
    &COMPACT_PERCENT,
];

impl SupervisorSetting {
    pub fn named(key: &str) -> Option<&'static SupervisorSetting> {
        SUPERVISOR_SETTINGS
            .iter()
            .copied()
            .find(|setting| setting.key == key)
    }

    /// `raw` (as typed, e.g. on the command line) as the value to store;
    /// `Err` carries [`Self::allowed`].
    pub fn parse(&self, raw: &str) -> Result<Value, String> {
        let normalized = raw.trim().to_ascii_lowercase();
        let parsed = match self.values {
            Values::Flag => match normalized.as_str() {
                "true" => Some(Value::Bool(true)),
                "false" => Some(Value::Bool(false)),
                _ => None,
            },
            _ => normalized
                .parse::<u64>()
                .ok()
                .filter(|number| self.accepts(*number))
                .map(Value::from),
        };
        parsed.ok_or_else(|| self.allowed.to_owned())
    }

    /// The stored value as the supervisor reads it: valid, else the
    /// default — never something shorter (§10).
    pub fn effective(&self, stored: Option<&Value>) -> Value {
        match self.values {
            Values::Flag => Value::Bool(self.flag(stored)),
            _ => Value::from(self.number(stored)),
        }
    }

    fn accepts(&self, number: u64) -> bool {
        match self.values {
            Values::Minutes(options) | Values::Percent(options) => options.contains(&number),
            Values::Range(low, high) => (low..=high).contains(&number),
            Values::Positive => number > 0 && u32::try_from(number).is_ok(),
            Values::Flag => false,
        }
    }

    fn number(&self, stored: Option<&Value>) -> u64 {
        stored
            .and_then(Value::as_u64)
            .filter(|number| self.accepts(*number))
            .unwrap_or(self.default)
    }

    fn flag(&self, stored: Option<&Value>) -> bool {
        stored.and_then(Value::as_bool).unwrap_or(self.default != 0)
    }
}

impl Default for SupervisorConfig {
    fn default() -> Self {
        config_from_state(&Value::Null, false)
    }
}

/// The settings on disk; a missing or unreadable file is all defaults.
pub fn load_config() -> SupervisorConfig {
    let state = crate::app_state::load().unwrap_or(Value::Null);
    config_from_state(&state, seconds_mode())
}

/// Whether this process counts minute settings in seconds (tests only).
pub(crate) fn seconds_mode() -> bool {
    seconds_mode_from(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var("UNPEEL_SUPERVISOR_SECONDS").ok().as_deref(),
    )
}

/// Lenient: junk falls back to the default, never to something shorter.
/// `seconds_mode` (tests only) counts minute settings as seconds.
pub fn config_from_state(state: &Value, seconds_mode: bool) -> SupervisorConfig {
    let unit_ms = if seconds_mode { 1_000 } else { 60_000 };
    let number = |setting: &SupervisorSetting| setting.number(state.get(setting.key));
    // `Positive` and `Range` values were checked to fit.
    let rate = |setting: &SupervisorSetting| u32::try_from(number(setting)).unwrap_or(u32::MAX);
    let flag = |setting: &SupervisorSetting| setting.flag(state.get(setting.key));
    SupervisorConfig {
        stall_ms: number(&STALL_MINUTES) * unit_ms,
        blocked_ms: number(&BLOCKED_MINUTES) * unit_ms,
        escalate_ms: number(&ESCALATE_MINUTES) * unit_ms,
        max_turn_ms: number(&MAX_TURN_MINUTES) * unit_ms,
        max_children: usize::try_from(number(&MAX_CHILDREN)).unwrap_or(usize::MAX),
        max_spawns_per_minute: rate(&MAX_SPAWNS_PER_MINUTE),
        max_deliveries_per_hour: rate(&MAX_DELIVERIES_PER_HOUR),
        notify_started: flag(&NOTIFY_STARTED),
        inbox_low_confidence: flag(&INBOX_LOW_CONFIDENCE),
        // The menu tops out at 70.
        compact_percent: u8::try_from(number(&COMPACT_PERCENT)).unwrap_or(0),
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
                compact_percent: 40,
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
                "supervisor_compact_percent": 60,
            }),
            false,
        );
        assert_eq!(config.compact_percent, 60);
        let off = config_from_state(
            &serde_json::json!({ "supervisor_compact_percent": 0 }),
            false,
        );
        assert_eq!(off.compact_percent, 0, "0 turns compaction off");
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
                "supervisor_compact_percent": 10,
            }),
            false,
        );
        assert_eq!(config, SupervisorConfig::default());
        // Below 25 would compact every turn: the startup context comes back
        // after a compaction.
        for junk in [
            serde_json::json!(5),
            serde_json::json!(24),
            serde_json::json!(45),
            serde_json::json!("40"),
        ] {
            let config = config_from_state(
                &serde_json::json!({ "supervisor_compact_percent": junk }),
                false,
            );
            assert_eq!(config.compact_percent, 40, "{junk}");
        }
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

    fn setting(key: &str) -> &'static SupervisorSetting {
        SupervisorSetting::named(key).expect("a supervisor setting")
    }

    #[test]
    fn every_supervisor_key_is_a_named_setting() {
        let keys: Vec<&str> = SUPERVISOR_SETTINGS.iter().map(|s| s.key).collect();
        assert_eq!(
            keys,
            [
                "supervisor_stall_minutes",
                "supervisor_blocked_minutes",
                "supervisor_escalate_minutes",
                "supervisor_max_turn_minutes",
                "supervisor_max_children",
                "supervisor_max_spawns_per_minute",
                "supervisor_max_deliveries_per_hour",
                "supervisor_notify_started",
                "supervisor_inbox_low_confidence",
                "supervisor_compact_percent",
            ]
        );
        assert!(SupervisorSetting::named("supervisor_bogus").is_none());
        assert!(SupervisorSetting::named("theme").is_none());
    }

    #[test]
    fn a_setting_accepts_exactly_the_values_the_supervisor_reads() {
        use serde_json::json;
        for (key, good, bad) in [
            (
                "supervisor_stall_minutes",
                vec![("20", json!(20)), ("0", json!(0))],
                vec!["7", "ten", "-5"],
            ),
            (
                "supervisor_escalate_minutes",
                vec![("1", json!(1))],
                vec!["3"],
            ),
            (
                "supervisor_max_children",
                vec![("1", json!(1)), (" 32 ", json!(32))],
                vec!["0", "33"],
            ),
            (
                "supervisor_max_spawns_per_minute",
                vec![("1", json!(1)), ("100", json!(100))],
                vec!["0", "1.5", "99999999999"],
            ),
            (
                "supervisor_notify_started",
                vec![("TRUE", json!(true)), ("false", json!(false))],
                vec!["yes", "1"],
            ),
            (
                "supervisor_compact_percent",
                vec![
                    ("40", json!(40)),
                    ("0", json!(0)),
                    ("25", json!(25)),
                    ("70", json!(70)),
                ],
                vec!["10", "24", "45", "80", "forty"],
            ),
        ] {
            let setting = setting(key);
            for (raw, value) in good {
                assert_eq!(setting.parse(raw), Ok(value.clone()), "{key}={raw}");
                // What is accepted is what the supervisor reads back.
                assert_eq!(setting.effective(Some(&value)), value, "{key}={raw}");
            }
            for raw in bad {
                let error = setting.parse(raw).unwrap_err();
                assert_eq!(error, setting.allowed, "{key}={raw}");
            }
        }
    }

    #[test]
    fn a_settings_effective_value_is_the_default_for_junk() {
        use serde_json::json;
        assert_eq!(
            setting("supervisor_stall_minutes").effective(None),
            json!(20)
        );
        assert_eq!(
            setting("supervisor_stall_minutes").effective(Some(&json!(7))),
            json!(20)
        );
        assert_eq!(
            setting("supervisor_max_children").effective(Some(&json!(0))),
            json!(8)
        );
        assert_eq!(
            setting("supervisor_inbox_low_confidence").effective(Some(&json!("x"))),
            json!(true)
        );
        assert_eq!(
            setting("supervisor_max_deliveries_per_hour").effective(None),
            json!(60)
        );
        assert_eq!(
            setting("supervisor_compact_percent").effective(Some(&json!(10))),
            json!(40)
        );
    }

    #[test]
    fn each_settings_allowed_text_names_its_menu() {
        for setting in SUPERVISOR_SETTINGS {
            if let Values::Minutes(options) | Values::Percent(options) = setting.values {
                for option in options {
                    assert!(
                        setting.allowed.contains(&option.to_string()),
                        "{}: {option}",
                        setting.key
                    );
                }
            }
        }
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
