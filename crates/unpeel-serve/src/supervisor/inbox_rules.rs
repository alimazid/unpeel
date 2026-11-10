//! Fork-only: when an Inbox may be pasted (spec §4.2) — a pure truth table
//! over one target's state plus the timing gates, so the drain only feeds
//! facts in and acts on the answer.

use unpeel_core::program_status::ProgramState;

use crate::sessions::{Status, StatusSource};

/// Why an Inbox is not pasted right now. The word is what `sessions inbox`
/// and `report` results show.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HoldReason {
    /// Kept for Resume.
    Exited,
    /// App-wide "Writing to other sessions: Deny", re-read every sweep.
    PolicyDeny,
    Busy,
    Starting,
    /// A prompt or select menu is up.
    Attention,
    /// Nothing confidently says an agent is at its prompt; the session can
    /// still pull its items (`sessions inbox`).
    NoAgentAuthority,
    /// Only the screen tier (or nothing) says idle, and best-guess delivery
    /// is off or no runtime is in the foreground.
    LowConfidence,
    /// The terminal has not enabled bracketed paste (mode 2004).
    NoBracketedPaste,
    /// Only ride-along items, none waiting long enough to be promoted:
    /// they go out with the next wake batch.
    RideAlong,
    /// The screen changed too recently.
    Quiet,
    /// Items are still arriving.
    Debounce,
    /// `supervisor_max_deliveries_per_hour` reached.
    Budget,
    /// The input line changed since the idle baseline: maybe a draft.
    Draft,
    /// The idle baseline snapshot could not be taken yet.
    Snapshot,
    /// The last paste failed; retrying shortly.
    Retry,
    /// A paste is running.
    InFlight,
    /// Pasted; waiting for the target to take it.
    Unconfirmed,
}

impl HoldReason {
    pub fn word(self) -> &'static str {
        match self {
            Self::Exited => "exited",
            Self::PolicyDeny => "policy_deny",
            Self::Busy => "busy",
            Self::Starting => "starting",
            Self::Attention => "attention",
            Self::NoAgentAuthority => "no_agent_authority",
            Self::LowConfidence => "low_confidence",
            Self::NoBracketedPaste => "no_bracketed_paste",
            Self::RideAlong => "ride_along",
            Self::Quiet => "quiet",
            Self::Debounce => "debounce",
            Self::Budget => "budget",
            Self::Draft => "draft",
            Self::Snapshot => "snapshot",
            Self::Retry => "retry",
            Self::InFlight => "in_flight",
            Self::Unconfirmed => "unconfirmed",
        }
    }

    /// The target left its idle period (a Busy → Idle cycle starts over):
    /// the draft baseline and any draft hold are dropped.
    pub fn ends_idle_episode(self) -> bool {
        matches!(
            self,
            Self::Exited | Self::Busy | Self::Starting | Self::Attention
        )
    }
}

/// Everything the §4.2 table reads about one target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Facts {
    pub running: bool,
    pub policy_deny: bool,
    pub status: Status,
    pub source: StatusSource,
    /// The program's own OSC 7501 record, when it holds one.
    pub program_state: Option<ProgramState>,
    /// A runtime or App is in the foreground (`active_runtime_id` /
    /// `active_app`): an agent, not a bare shell, owns the prompt.
    pub foreground: bool,
    /// Manifest `menu_prompt_active`, whatever the menu-attention setting.
    pub menu_prompt: bool,
    /// Mode 2004 is set (`manifest.terminal_modes.set`).
    pub bracketed_paste: bool,
    /// `supervisor_inbox_low_confidence`: deliver on a best guess.
    pub low_confidence: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Readiness {
    /// The timing gates and the draft guard decide. `confident: false` is a
    /// best guess: it needs a longer quiet window, and nothing will confirm
    /// it, so it counts as delivered once pasted.
    Deliver {
        confident: bool,
    },
    Hold(HoldReason),
}

/// The §4.2 truth table, in its row order.
pub fn readiness(facts: &Facts) -> Readiness {
    if !facts.running {
        return Readiness::Hold(HoldReason::Exited);
    }
    if facts.policy_deny {
        return Readiness::Hold(HoldReason::PolicyDeny);
    }
    if let Some(reason) = activity_hold(facts) {
        return Readiness::Hold(reason);
    }
    match source_readiness(facts) {
        Readiness::Deliver { .. } if !facts.bracketed_paste => {
            Readiness::Hold(HoldReason::NoBracketedPaste)
        }
        decision => decision,
    }
}

fn activity_hold(facts: &Facts) -> Option<HoldReason> {
    match facts.status {
        Status::Exited => Some(HoldReason::Exited),
        Status::Busy => Some(HoldReason::Busy),
        Status::Starting => Some(HoldReason::Starting),
        Status::Attention => Some(HoldReason::Attention),
        Status::Idle if facts.menu_prompt => Some(HoldReason::Attention),
        Status::Idle => None,
    }
}

/// Who says the idle session is at an agent's prompt, and how surely.
fn source_readiness(facts: &Facts) -> Readiness {
    let confident = Readiness::Deliver { confident: true };
    let in_front = |decision| {
        if facts.foreground {
            decision
        } else {
            Readiness::Hold(HoldReason::NoAgentAuthority)
        }
    };
    match (facts.source, facts.program_state) {
        (StatusSource::Program, Some(ProgramState::Idle)) => confident,
        // A finished record outlives its program: trust it only while an
        // agent is still in the foreground. Hook latches outlive theirs too.
        (StatusSource::Program, Some(ProgramState::Done | ProgramState::Error)) => {
            in_front(confident)
        }
        (StatusSource::Hooks, _) => in_front(confident),
        (StatusSource::Program, _) => Readiness::Hold(HoldReason::Busy),
        (StatusSource::Screen, _) => best_guess(facts),
        (StatusSource::None, _) => in_front(best_guess(facts)),
    }
}

/// The screen must have been still this long before a paste.
pub const QUIET_MS: u64 = 3_000;
/// A best guess waits longer: nothing else says the agent is done.
pub const BEST_GUESS_QUIET_MS: u64 = 10_000;
/// Debounce: the newest item must be this old…
pub const DEBOUNCE_NEWEST_MS: u64 = 2_000;
/// …unless the oldest has already waited this long.
pub const DEBOUNCE_OLDEST_MS: u64 = 30_000;
/// Ride-along items whose oldest has waited this long start a delivery as
/// if they were a wake item (#83).
pub const RIDE_ALONG_PROMOTE_MS: u64 = 15 * 60_000;

/// The quiet window (§4.2): `screen_changed_at` (manifest) old enough.
pub fn quiet_hold(confident: bool, now: u64, screen_changed_at: Option<u64>) -> Option<HoldReason> {
    let window = if confident {
        QUIET_MS
    } else {
        BEST_GUESS_QUIET_MS
    };
    let quiet = screen_changed_at.is_none_or(|changed| changed <= now && now - changed >= window);
    (!quiet).then_some(HoldReason::Quiet)
}

/// Whether ride-along items have waited `promote_ms` since the oldest was
/// queued. The stored queue time is the clock, so a Host restart does not
/// start it over.
pub fn promoted(oldest_at: Option<u64>, now: u64, promote_ms: u64) -> bool {
    oldest_at.is_some_and(|at| at <= now && now - at >= promote_ms)
}

/// What the send gates read once the screen is quiet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timing {
    pub now: u64,
    pub oldest_at: Option<u64>,
    pub newest_at: Option<u64>,
    /// Pastes into this target in the last hour.
    pub deliveries_last_hour: usize,
    pub max_deliveries_per_hour: u32,
}

/// Debounce, then the hourly budget (§4.2).
pub fn send_hold(timing: &Timing) -> Option<HoldReason> {
    let age = |at: Option<u64>| at.map_or(u64::MAX, |at| timing.now.saturating_sub(at));
    let settled =
        age(timing.newest_at) >= DEBOUNCE_NEWEST_MS || age(timing.oldest_at) >= DEBOUNCE_OLDEST_MS;
    if !settled {
        return Some(HoldReason::Debounce);
    }
    let budget = usize::try_from(timing.max_deliveries_per_hour).unwrap_or(usize::MAX);
    (timing.deliveries_last_hour >= budget).then_some(HoldReason::Budget)
}

/// What the draft guard reads about the user's typing (#38).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DraftFacts {
    pub now: u64,
    /// When the target's current turn began: its latest prompt submit, or
    /// the step that saw it turn busy.
    pub turn_began_at: u64,
    /// Manifest `last_input_at`: when the user last typed. `None` from a
    /// session host that does not stamp it, or before anyone typed.
    pub last_input_at: Option<u64>,
}

/// The line a paste may land on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DraftGuard {
    /// Nobody typed since the turn began: the line is the agent's own
    /// prompt, so it is the baseline and the target's known-empty prompt.
    Baseline,
    /// The user typed since (at `typed_at`): only the known-empty prompt is
    /// not a draft.
    KnownEmpty { typed_at: u64 },
}

/// The draft guard's first gate. Typing within the quiet window always
/// holds; the drain then compares the line for [`DraftGuard::KnownEmpty`].
pub fn draft_guard(facts: &DraftFacts) -> Result<DraftGuard, HoldReason> {
    let Some(typed_at) = facts.last_input_at else {
        return Ok(DraftGuard::Baseline);
    };
    if typed_at < facts.turn_began_at {
        return Ok(DraftGuard::Baseline);
    }
    if typed_at <= facts.now && facts.now - typed_at >= QUIET_MS {
        Ok(DraftGuard::KnownEmpty { typed_at })
    } else {
        Err(HoldReason::Draft)
    }
}

/// Best-guess delivery (Q2): only with the setting on and a runtime in the
/// foreground.
fn best_guess(facts: &Facts) -> Readiness {
    if facts.low_confidence && facts.foreground {
        Readiness::Deliver { confident: false }
    } else {
        Readiness::Hold(HoldReason::LowConfidence)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::{Status, StatusSource};
    use unpeel_core::program_status::ProgramState;

    /// A Claude-like agent at its prompt, reported idle by its hooks.
    fn idle_agent() -> Facts {
        Facts {
            running: true,
            policy_deny: false,
            status: Status::Idle,
            source: StatusSource::Hooks,
            program_state: None,
            foreground: true,
            menu_prompt: false,
            bracketed_paste: true,
            low_confidence: true,
        }
    }

    fn deliver() -> Readiness {
        Readiness::Deliver { confident: true }
    }

    fn best_guess() -> Readiness {
        Readiness::Deliver { confident: false }
    }

    fn hold(reason: HoldReason) -> Readiness {
        Readiness::Hold(reason)
    }

    #[test]
    fn the_delivery_truth_table() {
        let program = |state| Facts {
            source: StatusSource::Program,
            program_state: Some(state),
            ..idle_agent()
        };
        let rows: Vec<(&str, Facts, Readiness)> = vec![
            ("idle agent from hooks", idle_agent(), deliver()),
            (
                "not running",
                Facts {
                    running: false,
                    status: Status::Exited,
                    source: StatusSource::None,
                    ..idle_agent()
                },
                hold(HoldReason::Exited),
            ),
            (
                "app-wide Deny",
                Facts {
                    policy_deny: true,
                    ..idle_agent()
                },
                hold(HoldReason::PolicyDeny),
            ),
            (
                "busy",
                Facts {
                    status: Status::Busy,
                    ..idle_agent()
                },
                hold(HoldReason::Busy),
            ),
            (
                "starting",
                Facts {
                    status: Status::Starting,
                    ..idle_agent()
                },
                hold(HoldReason::Starting),
            ),
            (
                "attention",
                Facts {
                    status: Status::Attention,
                    ..idle_agent()
                },
                hold(HoldReason::Attention),
            ),
            (
                "a select menu on screen",
                Facts {
                    menu_prompt: true,
                    ..idle_agent()
                },
                hold(HoldReason::Attention),
            ),
            (
                "program idle, no runtime in front",
                Facts {
                    foreground: false,
                    ..program(ProgramState::Idle)
                },
                deliver(),
            ),
            (
                "program done with a runtime in front",
                program(ProgramState::Done),
                deliver(),
            ),
            (
                "program done on a bare shell",
                Facts {
                    foreground: false,
                    ..program(ProgramState::Done)
                },
                hold(HoldReason::NoAgentAuthority),
            ),
            (
                "program error on a bare shell",
                Facts {
                    foreground: false,
                    ..program(ProgramState::Error)
                },
                hold(HoldReason::NoAgentAuthority),
            ),
            (
                "hooks idle after the agent left",
                Facts {
                    foreground: false,
                    ..idle_agent()
                },
                hold(HoldReason::NoAgentAuthority),
            ),
            (
                "screen tier, runtime in front",
                Facts {
                    source: StatusSource::Screen,
                    ..idle_agent()
                },
                best_guess(),
            ),
            (
                "screen tier, best guess off",
                Facts {
                    source: StatusSource::Screen,
                    low_confidence: false,
                    ..idle_agent()
                },
                hold(HoldReason::LowConfidence),
            ),
            (
                "screen tier, nothing in front",
                Facts {
                    source: StatusSource::Screen,
                    foreground: false,
                    ..idle_agent()
                },
                hold(HoldReason::LowConfidence),
            ),
            (
                "hookless runtime in front",
                Facts {
                    source: StatusSource::None,
                    ..idle_agent()
                },
                best_guess(),
            ),
            (
                "hookless runtime, best guess off",
                Facts {
                    source: StatusSource::None,
                    low_confidence: false,
                    ..idle_agent()
                },
                hold(HoldReason::LowConfidence),
            ),
            (
                "a plain shell or cat",
                Facts {
                    source: StatusSource::None,
                    foreground: false,
                    bracketed_paste: false,
                    ..idle_agent()
                },
                hold(HoldReason::NoAgentAuthority),
            ),
            (
                "no bracketed paste",
                Facts {
                    bracketed_paste: false,
                    ..idle_agent()
                },
                hold(HoldReason::NoBracketedPaste),
            ),
            (
                "no bracketed paste on a program",
                Facts {
                    bracketed_paste: false,
                    ..program(ProgramState::Idle)
                },
                hold(HoldReason::NoBracketedPaste),
            ),
        ];
        for (name, facts, expected) in rows {
            assert_eq!(readiness(&facts), expected, "{name}");
        }
    }

    #[test]
    fn deny_and_exit_outrank_activity() {
        let exited_and_denied = Facts {
            running: false,
            policy_deny: true,
            status: Status::Exited,
            ..idle_agent()
        };
        assert_eq!(readiness(&exited_and_denied), hold(HoldReason::Exited));
        let busy_and_denied = Facts {
            policy_deny: true,
            status: Status::Busy,
            ..idle_agent()
        };
        assert_eq!(readiness(&busy_and_denied), hold(HoldReason::PolicyDeny));
    }

    #[test]
    fn only_activity_holds_end_an_idle_episode() {
        for reason in [
            HoldReason::Exited,
            HoldReason::Busy,
            HoldReason::Starting,
            HoldReason::Attention,
        ] {
            assert!(reason.ends_idle_episode(), "{reason:?}");
        }
        for reason in [
            HoldReason::PolicyDeny,
            HoldReason::NoAgentAuthority,
            HoldReason::LowConfidence,
            HoldReason::NoBracketedPaste,
            HoldReason::Quiet,
            HoldReason::Draft,
        ] {
            assert!(!reason.ends_idle_episode(), "{reason:?}");
        }
    }

    const NOW: u64 = 1_000_000;

    #[test]
    fn the_screen_must_be_quiet_for_three_seconds_or_ten_on_a_best_guess() {
        assert_eq!(quiet_hold(true, NOW, None), None, "never changed");
        assert_eq!(quiet_hold(true, NOW, Some(NOW - 3_000)), None);
        assert_eq!(
            quiet_hold(true, NOW, Some(NOW - 2_999)),
            Some(HoldReason::Quiet)
        );
        assert_eq!(
            quiet_hold(false, NOW, Some(NOW - 9_999)),
            Some(HoldReason::Quiet)
        );
        assert_eq!(quiet_hold(false, NOW, Some(NOW - 10_000)), None);
        // A clock step back reads as just changed, not as quiet forever.
        assert_eq!(
            quiet_hold(true, NOW, Some(NOW + 5_000)),
            Some(HoldReason::Quiet)
        );
    }

    fn timing(oldest_age: u64, newest_age: u64, deliveries: usize) -> Timing {
        Timing {
            now: NOW,
            oldest_at: Some(NOW - oldest_age),
            newest_at: Some(NOW - newest_age),
            deliveries_last_hour: deliveries,
            max_deliveries_per_hour: 60,
        }
    }

    #[test]
    fn debounce_waits_for_items_to_stop_arriving_but_not_forever() {
        assert_eq!(send_hold(&timing(5_000, 2_000, 0)), None);
        assert_eq!(
            send_hold(&timing(5_000, 1_999, 0)),
            Some(HoldReason::Debounce)
        );
        // A steady trickle still goes out once the oldest has waited 30 s.
        assert_eq!(send_hold(&timing(30_000, 100, 0)), None);
        assert_eq!(
            send_hold(&timing(29_999, 100, 0)),
            Some(HoldReason::Debounce)
        );
    }

    #[test]
    fn ride_along_items_are_promoted_once_the_oldest_has_waited() {
        let promote = RIDE_ALONG_PROMOTE_MS;
        assert!(promoted(Some(NOW - promote), NOW, promote));
        assert!(!promoted(Some(NOW - promote + 1), NOW, promote));
        assert!(!promoted(None, NOW, promote));
        // A queue time from a clock ahead of this one is not old.
        assert!(!promoted(Some(NOW + 1), NOW, promote));
    }

    #[test]
    fn the_hourly_budget_caps_deliveries() {
        assert_eq!(send_hold(&timing(5_000, 5_000, 59)), None);
        assert_eq!(
            send_hold(&timing(5_000, 5_000, 60)),
            Some(HoldReason::Budget)
        );
        let tight = Timing {
            max_deliveries_per_hour: 1,
            ..timing(5_000, 5_000, 1)
        };
        assert_eq!(send_hold(&tight), Some(HoldReason::Budget));
    }

    fn facts(turn_began_at: u64, last_input_at: Option<u64>) -> DraftFacts {
        DraftFacts {
            now: NOW,
            turn_began_at,
            last_input_at,
        }
    }

    #[test]
    fn typing_since_the_turn_began_needs_the_known_empty_prompt() {
        let began = NOW - 60_000;
        let known_empty = |typed_at| Ok(DraftGuard::KnownEmpty { typed_at });
        let rows = [
            (
                "a host that does not stamp input",
                None,
                Ok(DraftGuard::Baseline),
            ),
            (
                "typed before the turn began",
                Some(began - 1),
                Ok(DraftGuard::Baseline),
            ),
            ("typed as the turn began", Some(began), known_empty(began)),
            (
                "typed and quiet for 3 s",
                Some(NOW - 3_000),
                known_empty(NOW - 3_000),
            ),
            ("typing just now", Some(NOW - 2_999), Err(HoldReason::Draft)),
            // A clock step back reads as just typed, not as quiet forever.
            (
                "typed in the future",
                Some(NOW + 5_000),
                Err(HoldReason::Draft),
            ),
        ];
        for (name, last_input_at, expected) in rows {
            assert_eq!(
                draft_guard(&facts(began, last_input_at)),
                expected,
                "{name}"
            );
        }
    }

    #[test]
    fn hold_reasons_read_as_snake_case_words() {
        assert_eq!(HoldReason::NoAgentAuthority.word(), "no_agent_authority");
        assert_eq!(HoldReason::PolicyDeny.word(), "policy_deny");
        assert_eq!(HoldReason::NoBracketedPaste.word(), "no_bracketed_paste");
        assert_eq!(HoldReason::RideAlong.word(), "ride_along");
    }
}
