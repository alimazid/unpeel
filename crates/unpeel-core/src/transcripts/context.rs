//! Fork-only (#64): how full an agent's context is, by its transcript, for
//! the Host's Worker compaction (ADR 0012). The reading is provider code
//! (the transcript adapter's `context_usage`); the window and the command
//! that compacts come from the runtime package's `[context]` table.

use super::{
    read_head_utf8, read_jsonl_lines_before, resolve_provider_transcript, TranscriptProvider,
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
    /// Fork-only (#68): what the agent's own percent leaves out of both the
    /// tokens and the window (the runtime package's `baseline_tokens`).
    pub baseline: u64,
}

impl ContextReading {
    /// Percent of the window above the baseline, rounded as Claude Code's
    /// status line rounds it; `None` without a window larger than the
    /// baseline.
    pub fn percent(&self) -> Option<u8> {
        let window = self.window.filter(|window| *window > self.baseline)? - self.baseline;
        let (tokens, window) = (
            u128::from(self.tokens.saturating_sub(self.baseline)),
            u128::from(window),
        );
        let percent = (tokens * 100 + window / 2) / window;
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

/// The provider's `baseline_tokens`, from its runtime package (#68).
pub fn context_baseline(provider: TranscriptProvider) -> u64 {
    runtime_context(provider).map_or(0, |context| context.baseline_tokens)
}

fn runtime_context(
    provider: TranscriptProvider,
) -> Option<&'static crate::runtime_catalog::RuntimeContext> {
    crate::runtime_catalog::builtin_runtime_catalog()
        .by_legacy_slug(provider.as_str())
        .map(|descriptor| &descriptor.context)
}

/// How full the Session's context is, from the tail of its transcript (a
/// JSON document, such as a Codewhale saved session, is read whole and
/// handed to the reader as its one line). `None` without a transcript, a
/// reader, or a reply yet.
pub fn read_context(manifest: &HostedSessionManifest) -> Option<ContextReading> {
    let transcript = resolve_provider_transcript(manifest).ok()?;
    transcript.provider.adapter().context_usage?;
    let usage = if transcript.path.extension().and_then(|ext| ext.to_str()) == Some("json") {
        let document = read_head_utf8(&transcript.path, u64::MAX).ok()?;
        context_usage_in_lines(transcript.provider, &[document.as_str()])?
    } else {
        let read =
            read_jsonl_lines_before(&transcript.path, None, DEFAULT_TRANSCRIPT_TAIL_BYTES).ok()?;
        let lines: Vec<&str> = read.lines.iter().map(|(_, line)| line.as_str()).collect();
        context_usage_in_lines(transcript.provider, &lines)?
    };
    let window = usage
        .model
        .as_deref()
        .and_then(|model| context_window(transcript.provider, model));
    Some(ContextReading {
        tokens: usage.tokens,
        model: usage.model,
        window,
        compact_command: compact_command(transcript.provider),
        baseline: context_baseline(transcript.provider),
    })
}
