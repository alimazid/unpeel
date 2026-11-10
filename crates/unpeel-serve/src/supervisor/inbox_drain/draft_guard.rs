//! Fork-only: the Inbox drain's draft guard: the input line a paste must
//! find, and when only the PTY core can tell a draft (#38, #69).

use super::inbox_rules::{self, DraftFacts, DraftGuard, HoldReason};
use super::{CursorLine, Episode, HostIo, Target};

/// Whether the input line was empty after the typing stamped at
/// `typed_at`: the known-empty prompt, or no draft to the PTY core.
#[derive(Debug, Clone, Copy)]
pub(super) struct EmptyCheck {
    pub(super) typed_at: u64,
    pub(super) empty: bool,
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
    /// A paste held for a draft. What the core found is kept until the user
    /// types again; without it, the next step looks at the line again.
    pub(super) fn held_for_draft(&mut self, checked: Option<EmptyCheck>, now: u64) {
        self.checked = checked;
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
/// with the draft guard (`core_guard`) decides (#69).
pub(super) fn guarded_line(
    target: &mut Target,
    io: &dyn HostIo,
    id: &str,
    facts: &DraftFacts,
    core_guard: bool,
) -> Result<Guarded, HoldReason> {
    let episode = target.episode.get_or_insert_with(Episode::default);
    match inbox_rules::draft_guard(facts)? {
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
        DraftGuard::KnownEmpty { typed_at } => typed_line(target, io, id, typed_at, core_guard),
    }
}

/// After the user typed at `typed_at`: the known-empty prompt, read once
/// per typing. With none known yet, as when a person answers a Worker's
/// startup menu, only the PTY core can tell a draft (#69). Once it refuses
/// one, it is asked again only after the user types again. An older core
/// cannot tell, so that holds.
fn typed_line(
    target: &mut Target,
    io: &dyn HostIo,
    id: &str,
    typed_at: u64,
    core_guard: bool,
) -> Result<Guarded, HoldReason> {
    let checked = target
        .checked
        .filter(|check| check.typed_at == typed_at)
        .map(|check| check.empty);
    let Some(known_empty) = target.known_empty.clone() else {
        if !core_guard || checked == Some(false) {
            return Err(HoldReason::Draft);
        }
        let line = io.cursor(id).ok_or(HoldReason::Snapshot)?;
        return Ok(Guarded {
            line,
            ask_core: Some(typed_at),
        });
    };
    let empty = match checked {
        Some(empty) => empty,
        None => {
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
