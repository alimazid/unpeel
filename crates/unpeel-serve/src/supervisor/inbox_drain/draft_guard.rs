//! Fork-only: the Inbox drain's draft guard: the input line a paste must
//! find, and when only the PTY core can tell a draft (#38, #69).

use super::inbox_rules::{self, DraftFacts, DraftGuard, HoldReason};
use super::{CursorLine, Episode, HostIo, Target};

/// Whether the input line was the known-empty prompt after the typing
/// stamped at `typed_at`.
#[derive(Debug, Clone, Copy)]
pub(super) struct EmptyCheck {
    pub(super) typed_at: u64,
    pub(super) empty: bool,
}

/// The PTY core refused a paste asked at `asked_at` over a draft of the
/// typing stamped at `typed_at` (#69).
#[derive(Debug, Clone, Copy)]
pub(super) struct CoreRefusal {
    pub(super) typed_at: u64,
    pub(super) asked_at: u64,
}

impl CoreRefusal {
    /// It still holds the paste: the user has not typed since, and the
    /// Router has not written to the target since it was asked. A Router
    /// write (`send_text`, `send_keys`) asks the core once more, so a
    /// refusal the core would no longer give cannot strand a Worker nobody
    /// types into.
    fn holds(self, typed_at: u64, router_touched_at: Option<u64>) -> bool {
        self.typed_at == typed_at && router_touched_at.is_none_or(|at| at < self.asked_at)
    }
}

/// What the draft guard reads about one target this step.
pub(super) struct GuardFacts {
    pub(super) typing: DraftFacts,
    /// The target's PTY core refuses `unless_draft` writes (manifest
    /// `draft_guard`).
    pub(super) core_guard: bool,
    /// When the Router last wrote to the target (`Store::router_touched_at`);
    /// read only while a [`CoreRefusal`] is kept.
    pub(super) router_touched_at: Option<u64>,
}

/// How a paste is kept off the user's draft.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Guarded {
    /// The input line the paste must still find.
    pub(super) line: CursorLine,
    /// The PTY core decides whether the line holds a draft of the typing
    /// stamped then (#69): the paste carries `unless_draft`.
    pub(super) ask_core: Option<u64>,
}

impl Target {
    /// A paste held for a draft: the next step reads the line again, unless
    /// the core's refusal is kept (`core_refusal`).
    pub(super) fn held_for_draft(&mut self, now: u64) {
        self.checked = None;
        if let Some(episode) = self.episode.as_mut() {
            episode.line_changed = true;
            episode.draft_since.get_or_insert(now);
        }
    }
}

/// The line a paste must find (`Ok`), or why the line may be a draft.
/// With nobody typing since the turn began, the episode's baseline is the
/// agent's own prompt and becomes the known-empty one; after typing, only
/// the known-empty prompt is not a draft. With none known yet, a PTY core
/// with the draft guard decides (#69).
pub(super) fn guarded_line(
    target: &mut Target,
    io: &dyn HostIo,
    id: &str,
    facts: &GuardFacts,
) -> Result<Guarded, HoldReason> {
    let episode = target.episode.get_or_insert_with(Episode::default);
    match inbox_rules::draft_guard(&facts.typing)? {
        DraftGuard::Baseline => {
            if episode.line_changed {
                return Err(HoldReason::Draft);
            }
            if episode.baseline.is_none() {
                episode.baseline = io.cursor(id);
            }
            let baseline = episode.baseline.clone().ok_or(HoldReason::Snapshot)?;
            target.known_empty = Some(baseline.clone());
            Ok(Guarded {
                line: baseline,
                ask_core: None,
            })
        }
        DraftGuard::KnownEmpty { typed_at } => typed_line(target, io, id, typed_at, facts),
    }
}

/// After the user typed at `typed_at`: the known-empty prompt, read once
/// per typing. With none known yet, as when a person answers a Worker's
/// startup menu, only the PTY core can tell a draft (#69). Once it refuses
/// one, it is asked again only after the user types or the Router writes.
/// An older core cannot tell, so that holds.
fn typed_line(
    target: &mut Target,
    io: &dyn HostIo,
    id: &str,
    typed_at: u64,
    facts: &GuardFacts,
) -> Result<Guarded, HoldReason> {
    let Some(known_empty) = target.known_empty.clone() else {
        let refused = target
            .core_refusal
            .is_some_and(|refusal| refusal.holds(typed_at, facts.router_touched_at));
        if !facts.core_guard || refused {
            return Err(HoldReason::Draft);
        }
        let line = io.cursor(id).ok_or(HoldReason::Snapshot)?;
        return Ok(Guarded {
            line,
            ask_core: Some(typed_at),
        });
    };
    let empty = match target.checked {
        Some(check) if check.typed_at == typed_at => check.empty,
        _ => {
            let empty = io.cursor(id).ok_or(HoldReason::Snapshot)? == known_empty;
            target.checked = Some(EmptyCheck { typed_at, empty });
            empty
        }
    };
    let guarded = Guarded {
        line: known_empty,
        ask_core: None,
    };
    empty.then_some(guarded).ok_or(HoldReason::Draft)
}
