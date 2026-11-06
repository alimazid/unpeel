//! Fork-only: the rules-based watchdog (§6). It only reports, to the
//! Worker's Router; it never stops or signals anything, so process identity
//! is not its concern. A pure function of what the Worker alerts track:
//! progress is the latest of every signal they keep, and every clock is
//! floored at the supervisor's own start, so a Host restart raises no false
//! alarm (as `auto_stop`).

use unpeel_core::supervision::SupervisorConfig;

use super::notices::duration;
use crate::sessions::Status;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Rule {
    /// Busy, with no progress for `supervisor_stall_minutes`.
    Stalled,
    /// Waiting on a prompt for `supervisor_blocked_minutes`.
    Blocked,
    /// A turn ended without finishing (interrupted, or its hook latch
    /// expired).
    WentQuiet,
    /// Exited while busy or waiting, or with a failing code. Raised from
    /// the Exited edge itself (`notices::exited`).
    ExitedUnexpectedly,
    /// One turn ran longer than `supervisor_max_turn_minutes` (off by
    /// default).
    LongTurn,
}

impl Rule {
    pub fn word(self) -> &'static str {
        match self {
            Rule::Stalled => "stalled",
            Rule::Blocked => "blocked",
            Rule::WentQuiet => "went_quiet",
            Rule::ExitedUnexpectedly => "exited_unexpectedly",
            Rule::LongTurn => "long_turn",
        }
    }
}

/// One alarm; `episode` is the start of the stretch it is about, so it
/// fires once per stretch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Alarm {
    pub rule: Rule,
    pub episode: u64,
    /// How long the condition has held, for the text.
    pub held_ms: u64,
    /// How long the whole turn has run, for the text.
    pub turn_ms: u64,
}

impl Alarm {
    /// The notice's text after the Worker's name.
    pub fn text(&self) -> String {
        match self.rule {
            Rule::Stalled => format!(
                "is stalled: busy for {}, no progress for {}.",
                duration(self.turn_ms),
                duration(self.held_ms)
            ),
            Rule::Blocked => format!("has been waiting for input for {}.", duration(self.held_ms)),
            Rule::WentQuiet => "went idle without finishing its turn (interrupted, or its \
                                status timed out)."
                .to_owned(),
            Rule::ExitedUnexpectedly => "exited unexpectedly.".to_owned(),
            Rule::LongTurn => format!("has been working for {}.", duration(self.turn_ms)),
        }
    }
}

/// What the Worker alerts know about one running Worker right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Evidence {
    pub status: Status,
    /// The current turn's start (Busy or waiting), floored.
    pub turn_started_at: Option<u64>,
    /// The current wait's start, floored.
    pub waiting_since: Option<u64>,
    /// The latest progress signal of any kind, floored.
    pub progress_at: u64,
}

/// The alarms due now, in rule order. The caller keeps which episodes
/// already fired.
pub fn due(evidence: &Evidence, config: &SupervisorConfig, now: u64) -> Vec<Alarm> {
    let turn_ms = evidence
        .turn_started_at
        .map_or(0, |start| now.saturating_sub(start));
    let mut alarms = Vec::new();
    let quiet_ms = now.saturating_sub(evidence.progress_at);
    if evidence.status == Status::Busy && config.stall_ms > 0 && quiet_ms >= config.stall_ms {
        alarms.push(Alarm {
            rule: Rule::Stalled,
            episode: evidence.progress_at,
            held_ms: quiet_ms,
            turn_ms,
        });
    }
    if let Some(since) = evidence
        .waiting_since
        .filter(|_| evidence.status == Status::Attention && config.blocked_ms > 0)
    {
        let held_ms = now.saturating_sub(since);
        if held_ms >= config.blocked_ms {
            alarms.push(Alarm {
                rule: Rule::Blocked,
                episode: since,
                held_ms,
                turn_ms,
            });
        }
    }
    if let Some(start) = evidence.turn_started_at.filter(|_| config.max_turn_ms > 0) {
        if turn_ms >= config.max_turn_ms {
            alarms.push(Alarm {
                rule: Rule::LongTurn,
                episode: start,
                held_ms: turn_ms,
                turn_ms,
            });
        }
    }
    alarms
}

/// A turn that ended without finishing.
pub fn went_quiet(turn_started_at: u64, now: u64) -> Alarm {
    Alarm {
        rule: Rule::WentQuiet,
        episode: turn_started_at,
        held_ms: 0,
        turn_ms: now.saturating_sub(turn_started_at),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 1_800_000_000_000;
    const MIN: u64 = 60_000;

    fn evidence(status: Status) -> Evidence {
        Evidence {
            status,
            turn_started_at: Some(T0),
            waiting_since: None,
            progress_at: T0,
        }
    }

    fn rules(alarms: &[Alarm]) -> Vec<Rule> {
        alarms.iter().map(|alarm| alarm.rule).collect()
    }

    #[test]
    fn a_busy_worker_with_no_progress_for_the_stall_time_is_stalled() {
        let config = SupervisorConfig::default();
        let busy = evidence(Status::Busy);
        assert!(due(&busy, &config, T0 + 20 * MIN - 1).is_empty());
        let alarms = due(&busy, &config, T0 + 20 * MIN);
        assert_eq!(rules(&alarms), [Rule::Stalled]);
        assert_eq!(alarms[0].episode, T0, "the episode is the last progress");
        assert_eq!(
            format!("\"w\" {}", alarms[0].text()),
            "\"w\" is stalled: busy for 20 min, no progress for 20 min."
        );
    }

    #[test]
    fn progress_restarts_the_stall_clock_and_names_a_new_episode() {
        let config = SupervisorConfig::default();
        let busy = Evidence {
            progress_at: T0 + 15 * MIN,
            ..evidence(Status::Busy)
        };
        assert!(due(&busy, &config, T0 + 30 * MIN).is_empty());
        let alarms = due(&busy, &config, T0 + 35 * MIN);
        assert_eq!(alarms[0].episode, T0 + 15 * MIN);
        assert_eq!(
            alarms[0].text(),
            "is stalled: busy for 35 min, no progress for 20 min."
        );
    }

    #[test]
    fn an_idle_or_waiting_worker_is_never_stalled() {
        let config = SupervisorConfig::default();
        for status in [Status::Idle, Status::Attention, Status::Starting] {
            assert!(
                !rules(&due(&evidence(status), &config, T0 + 60 * MIN)).contains(&Rule::Stalled)
            );
        }
    }

    #[test]
    fn a_worker_waiting_on_a_prompt_for_the_blocked_time_is_blocked() {
        let config = SupervisorConfig::default();
        let waiting = Evidence {
            waiting_since: Some(T0 + 2 * MIN),
            ..evidence(Status::Attention)
        };
        assert!(due(&waiting, &config, T0 + 12 * MIN - 1).is_empty());
        let alarms = due(&waiting, &config, T0 + 12 * MIN);
        assert_eq!(rules(&alarms), [Rule::Blocked]);
        assert_eq!(alarms[0].episode, T0 + 2 * MIN);
        assert_eq!(alarms[0].text(), "has been waiting for input for 10 min.");
    }

    #[test]
    fn a_zero_setting_turns_its_alarm_off() {
        let config = SupervisorConfig {
            stall_ms: 0,
            blocked_ms: 0,
            ..SupervisorConfig::default()
        };
        let waiting = Evidence {
            waiting_since: Some(T0),
            ..evidence(Status::Attention)
        };
        assert!(due(&evidence(Status::Busy), &config, T0 + 600 * MIN).is_empty());
        assert!(due(&waiting, &config, T0 + 600 * MIN).is_empty());
    }

    #[test]
    fn long_turn_is_off_by_default_and_fires_once_set() {
        let busy = Evidence {
            progress_at: T0 + 60 * MIN,
            ..evidence(Status::Busy)
        };
        assert!(due(&busy, &SupervisorConfig::default(), T0 + 61 * MIN).is_empty());
        let config = SupervisorConfig {
            max_turn_ms: 30 * MIN,
            ..SupervisorConfig::default()
        };
        let alarms = due(&busy, &config, T0 + 61 * MIN);
        assert_eq!(rules(&alarms), [Rule::LongTurn]);
        assert_eq!(alarms[0].episode, T0);
        assert_eq!(alarms[0].text(), "has been working for 1 h 1 min.");
    }

    #[test]
    fn went_quiet_is_about_the_turn_that_ended() {
        let alarm = went_quiet(T0, T0 + 3 * MIN);
        assert_eq!((alarm.rule, alarm.episode), (Rule::WentQuiet, T0));
        assert_eq!(alarm.rule.word(), "went_quiet");
    }

    #[test]
    fn durations_read_in_the_largest_whole_unit() {
        assert_eq!(duration(5_400), "5 s");
        assert_eq!(duration(5 * MIN + 30_000), "5 min");
        assert_eq!(duration(120 * MIN), "2 h");
        assert_eq!(duration(130 * MIN), "2 h 10 min");
    }
}
