//! Fork-only: the real Host behind the Inbox drain: manifests, viewport
//! snapshots, the guarded paste recipe.

use std::collections::HashSet;
use std::time::Duration;

use unpeel_core::session_input::GuardedPaste;

use super::inbox_rules::RIDE_ALONG_PROMOTE_MS;
use super::{CursorLine, HostIo, Settings, TerminalFacts};

const SNAPSHOT_TIMEOUT: Duration = Duration::from_millis(100);
const PASTE_TIMEOUT: Duration = Duration::from_secs(5);
/// Test Hosts (`UNPEEL_TEST=1`) may shorten [`RIDE_ALONG_PROMOTE_MS`].
const RIDE_ALONG_PROMOTE_OVERRIDE_ENV: &str = "UNPEEL_INBOX_RIDE_ALONG_PROMOTE_MS";

/// How long ride-along items wait before they start a delivery on this Host.
fn ride_along_promote_ms() -> u64 {
    ride_along_promote_from(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var(RIDE_ALONG_PROMOTE_OVERRIDE_ENV)
            .ok()
            .as_deref(),
    )
}

pub(super) fn ride_along_promote_from(test_host: Option<&str>, override_ms: Option<&str>) -> u64 {
    override_ms
        .filter(|_| test_host == Some("1"))
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(RIDE_ALONG_PROMOTE_MS)
}

/// The draft guard's view of `snapshot`'s input line. Suggested input (a
/// reply the program proposes, drawn faint at the cursor) is left out: it
/// comes and goes on its own and is never the user's draft.
pub(super) fn cursor_line(
    snapshot: &unpeel_core::terminal_viewport::TerminalViewportSnapshot,
) -> CursorLine {
    CursorLine {
        text: snapshot
            .cursor_row_text_without_suggestion()
            .unwrap_or_default(),
        col: snapshot.cursor_col,
    }
}

/// The real Host: manifests, viewport snapshots, the guarded paste.
#[derive(Debug, Clone, Copy, Default)]
pub struct HostTerminal;

impl HostIo for HostTerminal {
    fn terminal(&self, session_id: &str) -> Option<TerminalFacts> {
        let manifest = unpeel_core::session_host::load_manifest(session_id)?;
        Some(TerminalFacts {
            bracketed_paste: manifest
                .terminal_modes
                .as_ref()
                .is_some_and(|modes| modes.set.contains(&2004)),
            screen_changed_at: manifest.screen_changed_at,
            menu_prompt: manifest.menu_prompt_active,
            last_input_at: manifest.last_input_at,
            draft_guard: manifest.draft_guard,
        })
    }

    fn cursor(&self, session_id: &str) -> Option<CursorLine> {
        let snapshot = unpeel_core::session_host::request_current_viewport_snapshot_with_timeout(
            session_id,
            0,
            None,
            SNAPSHOT_TIMEOUT,
        )
        .ok()?;
        Some(cursor_line(&snapshot))
    }

    fn paste(
        &self,
        session_id: &str,
        text: &str,
        since: u64,
        unless_draft: bool,
    ) -> Result<GuardedPaste, String> {
        if unless_draft {
            unpeel_core::session_input::paste_unless_user_is_typing_within(
                session_id,
                text,
                true,
                since,
                PASTE_TIMEOUT,
            )
        } else {
            unpeel_core::session_input::paste_unless_typed(session_id, text, since, PASTE_TIMEOUT)
        }
    }

    fn live_session_ids(&self) -> HashSet<String> {
        let Ok(entries) = std::fs::read_dir(unpeel_core::app_paths::app_sessions_root()) else {
            return HashSet::new();
        };
        entries
            .flatten()
            .filter(|entry| entry.path().join("manifest.json").is_file())
            .filter_map(|entry| entry.file_name().into_string().ok())
            .collect()
    }

    fn settings(&self) -> Settings {
        let (config, policy_deny) = unpeel_core::supervision::config_and_write_deny();
        Settings {
            config,
            policy_deny,
            ride_along_promote_ms: ride_along_promote_ms(),
        }
    }

    fn announce(&self) {
        unpeel_core::supervision::announce_markers();
    }
}
