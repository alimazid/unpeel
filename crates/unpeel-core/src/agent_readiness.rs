//! Agent readiness: whether a freshly launched agent is really ready for
//! input, so text typed into it lands in its prompt instead of ahead of it.
//!
//! Readiness is the **first positive signal after launch**, from any of the
//! three activity tiers:
//!
//! - a program status (`OSC 7501`) `idle` record (`manifest.program_status`);
//! - a lifecycle hook reporting idle (the hook script's durable
//!   `last-hook-event.json` seed);
//! - the runtime's declared `[screen]` idle prompt on the parsed viewport
//!   (`manifest.screen_activity`).
//!
//! Every input is a file the PTY core or the hook script writes itself, so
//! the answer does not depend on which process owns Controllers or
//! notifications, and any thread can ask. A Running Session with none of these
//! is **not** ready: the "idle" a Controller reads for a Session with no
//! activity entry is a default, never evidence.

use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

use crate::program_status::ProgramState;
use crate::session_host::{HostedSessionManifest, HostedSessionState};

/// Bytes of `last-hook-event.json` worth reading; hook scripts write a few
/// dozen. Anything larger is not a seed this module understands.
const MAX_HOOK_SEED_BYTES: u64 = 64 * 1024;

/// Which tier said the agent is ready.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessSignal {
    Program,
    Hook,
    Screen,
}

impl ReadinessSignal {
    /// The same words the worker publishes as `activitySource`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Program => "program",
            Self::Hook => "hooks",
            Self::Screen => "screen",
        }
    }
}

/// The durable record of a Session's last lifecycle hook, as its hook script
/// wrote it (`record_last_hook_event` in each runtime's `lifecycle.sh`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookSeed {
    pub event: String,
    pub runtime_generation: Option<u64>,
    /// Wall-clock ms of the file's last write.
    pub written_at_ms: u64,
}

/// Read a Session directory's hook seed. `None` when there is none or it is
/// unreadable: a missing seed is simply no hook evidence.
pub fn read_hook_seed(session_dir: &Path) -> Option<HookSeed> {
    use std::io::Read as _;
    // Metadata and bytes from one open file: the script replaces the seed by
    // atomic rename, and a stat(path) + read(path) pair could pair a new
    // event with an old timestamp.
    let file = std::fs::File::open(session_dir.join("last-hook-event.json")).ok()?;
    let metadata = file.metadata().ok()?;
    if metadata.len() > MAX_HOOK_SEED_BYTES {
        return None;
    }
    let written_at_ms = metadata
        .modified()
        .ok()?
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()?
        .as_millis() as u64;
    let mut raw = String::new();
    file.take(MAX_HOOK_SEED_BYTES)
        .read_to_string(&mut raw)
        .ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let event = value.get("hook_event_name")?.as_str()?.to_owned();
    let runtime_generation = value
        .get("unpeel_runtime_generation")
        .or_else(|| value.get("unpeelRuntimeGeneration"))
        .and_then(serde_json::Value::as_u64);
    Some(HookSeed {
        event,
        runtime_generation,
        written_at_ms,
    })
}

/// The readiness verdict for one observation of a Running Session. `None`
/// means "not yet": no tier has positively said the agent is ready.
pub fn readiness_signal(
    manifest: &HostedSessionManifest,
    hook_seed: Option<&HookSeed>,
) -> Option<ReadinessSignal> {
    if manifest.state != HostedSessionState::Running {
        return None;
    }
    let launched_at = launched_at_ms(manifest);
    if program_reports_idle(manifest, launched_at) {
        return Some(ReadinessSignal::Program);
    }
    if hook_seed.is_some_and(|seed| hook_reports_idle(seed, manifest, launched_at)) {
        return Some(ReadinessSignal::Hook);
    }
    screen_shows_idle_prompt(manifest).then_some(ReadinessSignal::Screen)
}

/// Evidence must postdate the current runtime launch; a fresh Session's
/// launch is its creation.
fn launched_at_ms(manifest: &HostedSessionManifest) -> u64 {
    manifest
        .runtime_launched_at
        .unwrap_or(manifest.session.created_at)
}

/// Only `idle` is "accepting input" evidence at launch: `done` or `error`
/// before the first prompt says nothing about the prompt being drawn.
fn program_reports_idle(manifest: &HostedSessionManifest, launched_at: u64) -> bool {
    manifest.program_status.as_ref().is_some_and(|program| {
        program.state == ProgramState::Idle && program.changed_at >= launched_at
    })
}

/// The events that leave a hook-owned Session idle (the worker's engine maps
/// the same set to its idle state), matched case/dash/underscore-insensitively
/// like the worker's event normalization.
fn hook_reports_idle(seed: &HookSeed, manifest: &HostedSessionManifest, launched_at: u64) -> bool {
    let key: String = seed
        .event
        .trim()
        .to_lowercase()
        .chars()
        .filter(|c| !matches!(c, '-' | '_' | ' '))
        .collect();
    let idle_event = matches!(
        key.as_str(),
        "idle" | "stop" | "stopfailure" | "stopcancelled" | "stopcanceled"
    );
    // A seed tagged with another runtime generation belongs to the process
    // this launch replaced.
    let same_generation = seed.runtime_generation.is_none_or(|generation| {
        manifest.runtime_launch_generation == 0 || generation == manifest.runtime_launch_generation
    });
    idle_event && same_generation && seed.written_at_ms >= launched_at
}

/// The PTY core writes the verdict only for a recognized runtime that
/// declares `[screen]` rules; require the same of the runtime observed now,
/// exactly as the worker's screen tier does.
fn screen_shows_idle_prompt(manifest: &HostedSessionManifest) -> bool {
    crate::session_host::active_runtime_id(manifest)
        .and_then(crate::screen_activity::rules_for_runtime)
        .is_some()
        && manifest.screen_activity.as_deref() == Some("idle")
}

/// Whether `command` starts an agent whose readiness Unpeel can detect: its
/// head names a catalog runtime (on this platform) that declares at least
/// one readiness signal — lifecycle hooks, its own program status report,
/// or a `[screen]` idle prompt. Such a preset is an **Agent Preset**: only
/// it takes a Scheduled Task's instructions. Program status (`OSC 7501`) is
/// detected at run time, so a command no runtime claims never counts.
pub fn is_agent_command(command: &str) -> bool {
    let head = crate::integrations::command_head(command);
    if head.trim().is_empty() {
        return false;
    }
    crate::runtime_catalog::builtin_runtime_catalog()
        .by_command_alias_for_current_platform(head)
        .is_some_and(declares_readiness_signal)
}

fn declares_readiness_signal(runtime: &crate::runtime_catalog::RuntimeDescriptor) -> bool {
    use crate::runtime_catalog::RuntimeLifecycleSource;
    let screen_prompt = crate::screen_activity::rules_for_runtime(&runtime.legacy_slug)
        .is_some_and(|rules| !rules.idle_prompt.is_empty());
    matches!(
        runtime.lifecycle.source,
        RuntimeLifecycleSource::Hooks | RuntimeLifecycleSource::SelfReport
    ) || screen_prompt
}

/// How a readiness wait ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessWait {
    Ready(ReadinessSignal),
    /// The Session exited (or was removed) before it became ready.
    Exited,
    TimedOut,
}

/// One look at a Session for the wait loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessObservation {
    Ready(ReadinessSignal),
    NotYet,
    Ended,
}

const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Block until `session_id` is ready, exits, or `deadline` passes. Callers
/// own the thread; nothing here writes to the Session.
pub fn wait_for_agent_ready(session_id: &str, deadline: Instant) -> ReadinessWait {
    let session_dir = crate::session_host::session_dir(session_id);
    wait_with(
        || observe(crate::session_host::load_manifest(session_id), &session_dir),
        deadline,
        POLL_INTERVAL,
    )
}

/// Classify one manifest read (`None`: the Session is gone).
pub fn observe(
    manifest: Option<HostedSessionManifest>,
    session_dir: &Path,
) -> ReadinessObservation {
    let Some(manifest) = manifest else {
        return ReadinessObservation::Ended;
    };
    if manifest.state != HostedSessionState::Running {
        return ReadinessObservation::Ended;
    }
    match readiness_signal(&manifest, read_hook_seed(session_dir).as_ref()) {
        Some(signal) => ReadinessObservation::Ready(signal),
        None => ReadinessObservation::NotYet,
    }
}

/// The wait loop over an injected observer. Always observes at least once,
/// so evidence already present at the deadline still counts.
pub fn wait_with(
    mut observe: impl FnMut() -> ReadinessObservation,
    deadline: Instant,
    poll: Duration,
) -> ReadinessWait {
    loop {
        match observe() {
            ReadinessObservation::Ready(signal) => return ReadinessWait::Ready(signal),
            ReadinessObservation::Ended => return ReadinessWait::Exited,
            ReadinessObservation::NotYet => {}
        }
        let now = Instant::now();
        if now >= deadline {
            return ReadinessWait::TimedOut;
        }
        std::thread::sleep(poll.min(deadline - now));
    }
}

#[cfg(test)]
mod tests;
