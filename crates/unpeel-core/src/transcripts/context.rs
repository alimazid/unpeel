//! Fork-only (#64): how full an agent's context is, by its transcript, for
//! the Host's Worker compaction (ADR 0012). The reading is provider code
//! (the transcript adapter's `context_usage`); the window and the command
//! that compacts come from the runtime package's `[context]` table.

use super::{
    read_jsonl_lines_before, resolve_provider_transcript, TranscriptProvider,
    DEFAULT_TRANSCRIPT_TAIL_BYTES,
};
use crate::session_host::HostedSessionManifest;

/// How full an agent's context is, by its transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextUsage {
    /// What the latest request sent (for Claude: input, cache writes and
    /// cache reads), or what a compaction since then left.
    pub tokens: u64,
    /// The latest reply's model.
    pub model: Option<String>,
}

/// A Session's context against its runtime package's `[context]` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextReading {
    pub tokens: u64,
    pub model: Option<String>,
    /// `None` when the runtime package names no window for the model.
    pub window: Option<u64>,
    /// What to type, then Enter, to compact it; `None` when the runtime
    /// package names none.
    pub compact_command: Option<String>,
}

impl ContextReading {
    /// Percent of the window, rounded as Claude Code's status line rounds
    /// it; `None` without a window.
    pub fn percent(&self) -> Option<u8> {
        let window = u128::from(self.window.filter(|window| *window > 0)?);
        let percent = (u128::from(self.tokens) * 100 + window / 2) / window;
        Some(u8::try_from(percent.min(100)).unwrap_or(100))
    }
}

/// The provider's context reader over JSONL `lines`, oldest first; `None`
/// for a provider without one.
pub fn context_usage_in_lines(
    provider: TranscriptProvider,
    lines: &[&str],
) -> Option<ContextUsage> {
    (provider.adapter().context_usage?)(lines)
}

/// `model`'s context window, from the provider's runtime package.
pub fn context_window(provider: TranscriptProvider, model: &str) -> Option<u64> {
    runtime_context(provider)?.window_for(model)
}

/// The provider's compact command, from its runtime package.
pub fn compact_command(provider: TranscriptProvider) -> Option<String> {
    runtime_context(provider)?.compact_command.clone()
}

fn runtime_context(
    provider: TranscriptProvider,
) -> Option<&'static crate::runtime_catalog::RuntimeContext> {
    crate::runtime_catalog::builtin_runtime_catalog()
        .by_legacy_slug(provider.as_str())
        .map(|descriptor| &descriptor.context)
}

/// How full the Session's context is, from the tail of its transcript.
/// `None` without a transcript, a reader, or a reply yet.
pub fn read_context(manifest: &HostedSessionManifest) -> Option<ContextReading> {
    let transcript = resolve_provider_transcript(manifest).ok()?;
    transcript.provider.adapter().context_usage?;
    let read =
        read_jsonl_lines_before(&transcript.path, None, DEFAULT_TRANSCRIPT_TAIL_BYTES).ok()?;
    let lines: Vec<&str> = read.lines.iter().map(|(_, line)| line.as_str()).collect();
    let usage = context_usage_in_lines(transcript.provider, &lines)?;
    let window = usage
        .model
        .as_deref()
        .and_then(|model| context_window(transcript.provider, model));
    Some(ContextReading {
        tokens: usage.tokens,
        model: usage.model,
        window,
        compact_command: compact_command(transcript.provider),
    })
}
