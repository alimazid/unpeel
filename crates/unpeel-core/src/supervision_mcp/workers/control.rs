//! Fork-only: the Router stopping and closing its Workers (§16.4, §17.9),
//! the router-touch stamp a Router write leaves on its Worker (§17.7,
//! §18.1.11), and the Router's capped waits (§17.1). For a Router caller,
//! stop and close authority is the Worker marker alone: a Worker the user
//! restarted lost its marker and is the user's, whoever spawned it.

use serde_json::{json, Value};

use super::{at_home, Home};

/// `sessions stop {session_id}`: the Router stops one of its Workers.
pub(crate) fn stop_action(args: &Value) -> Result<String, String> {
    let caller = crate::mcp_host::self_session_id()
        .ok_or("sessions stop needs to know the calling session; run it inside a session.")?;
    let stopped = at_home(|home| stop_at(home, &caller, args, &crate::session_ops::stop_session))?;
    crate::supervision::announce_markers();
    serde_json::to_string_pretty(&stopped).map_err(|e| format!("Failed to encode stop: {e}"))
}

/// Stops (never removes) the Worker: its row stays, greyed out and
/// restartable. Whatever its Inbox still holds goes back to the Router
/// first, so nothing more is pasted into a Session being stopped.
pub(super) fn stop_at(
    home: &Home,
    caller: &str,
    args: &Value,
    stop: &dyn Fn(&str) -> Result<(), String>,
) -> Result<Value, String> {
    if !home.is_router(caller) {
        return Err(
            "sessions stop is for the Super Agent's Workers. Ask the user to stop \
that session from the sidebar."
                .into(),
        );
    }
    let target = args
        .get("session_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .ok_or("Missing required string argument 'session_id'")?;
    if target == caller {
        return Err("You cannot stop yourself.".into());
    }
    if !home.works_for(target, caller) {
        return Err(not_your_worker(target, "stop"));
    }
    let facts = (home.facts)(target)
        .ok_or_else(|| format!("Session '{target}' is no longer available."))?;
    let returned = hand_back(home, caller, target)?;
    if facts.running {
        stop(target).map_err(|error| {
            format!(
                "Stopping session {target} failed: {error}{}",
                returned_note(returned)
            )
        })?;
    }
    Ok(json!({
        "session_id": target,
        "stopped": true,
        "was_running": facts.running,
        "returned_items": returned,
        "note": format!(
            "It stays in the sidebar, greyed out, and no longer counts against your Worker \
    limit. If the user restarts it, it is theirs.{}",
            returned_note(returned)
        ),
    }))
}

/// One `sessions close` by `caller` of `target`.
pub(super) struct Closing<'a> {
    pub caller: &'a str,
    pub target: &'a str,
    /// The target's manifest `spawned_by`.
    pub spawned_by: Option<&'a str>,
    /// The target's manifest `role`.
    pub role: Option<&'a str>,
}

/// `close` from the Router, decided by the Worker marker alone (an App
/// panel the Router opened stays closable, as upstream). `None` for any
/// other caller: upstream's `spawned_by` rule.
pub(crate) fn route_close(
    caller: &crate::session_host::HostedSessionManifest,
    target: &crate::session_host::HostedSessionManifest,
) -> Option<Result<String, String>> {
    let closing = Closing {
        caller: &caller.session.id,
        target: &target.session.id,
        spawned_by: target.session.spawned_by.as_deref(),
        role: target.session.role.as_deref(),
    };
    let closed = at_home(|home| close_at(home, &closing, &crate::session_ops::remove_session))?;
    if closed.is_ok() {
        crate::supervision::announce_markers();
    }
    Some(closed)
}

pub(super) fn close_at(
    home: &Home,
    closing: &Closing,
    remove: &dyn Fn(&str) -> Result<(), String>,
) -> Option<Result<String, String>> {
    if !home.is_router(closing.caller) {
        return None;
    }
    let target = closing.target;
    if home.works_for(target, closing.caller) {
        return Some(
            hand_back(home, closing.caller, target).and_then(|returned| {
                remove(target)?;
                Ok(format!(
                    "Removed session {target}.{}",
                    returned_note(returned)
                ))
            }),
        );
    }
    let own_panel =
        closing.role == Some(super::APP_PANEL_ROLE) && closing.spawned_by == Some(closing.caller);
    Some(if own_panel {
        remove(target).map(|()| format!("Removed session {target}."))
    } else {
        Err(not_your_worker(target, "close"))
    })
}

/// Stamp the Worker as touched by its Router, then move its undelivered
/// items to the Router as ride-along. Returns how many moved.
fn hand_back(home: &Home, router: &str, worker: &str) -> Result<usize, String> {
    touch(home, worker);
    home.inbox
        .move_pending(worker, router)
        .map_err(|error| format!("The Inbox of {worker} could not be returned to you: {error}"))
}

fn returned_note(returned: usize) -> String {
    match returned {
        0 => String::new(),
        1 => " The 1 item still queued for it is back in your Inbox.".into(),
        n => format!(" The {n} items still queued for it are back in your Inbox."),
    }
}

fn not_your_worker(target: &str, verb: &str) -> String {
    format!(
        "Session '{target}' is not one of your Workers, so it stays the user's. Ask the user \
to {verb} it."
    )
}

/// The supervisor reads the stamp to tell an edge the Router caused from
/// the Worker's own; a failed stamp only costs a spurious notice. `true`
/// when the stamp was written.
fn touch(home: &Home, worker: &str) -> bool {
    match home.inbox.touch_router(worker, home.now_ms) {
        Ok(()) => true,
        Err(error) => {
            log::warn!("router-touch for {worker}: {error}");
            false
        }
    }
}

/// A write from `caller` into `target` passed the write gate: stamp it when
/// the Router wrote to one of its Workers, and announce the stamp.
pub(crate) fn note_write(caller: &str, target: &str) {
    if super::at_home_without_facts(|home| note_write_at(home, caller, target)) {
        crate::supervision::announce_markers();
    }
}

/// `true` when a router-touch stamp was written.
pub(super) fn note_write_at(home: &Home, caller: &str, target: &str) -> bool {
    home.is_router(caller) && home.works_for(target, caller) && touch(home, target)
}

/// The Router's longest wait (§17.1): a Busy turn holds its own Inbox.
pub(crate) const ROUTER_WAIT_CAP_MS: u64 = 5_000;
const ROUTER_WAIT_NOTE: &str = "You are the Super Agent, so every wait is capped at 5 s: while \
you wait, your turn is Busy and your own Inbox holds behind it. Reports, replies and alerts \
arrive in your Inbox by themselves; end your turn instead of waiting.";

/// The wait budget for `caller_id`, after upstream's clamp.
pub(crate) fn cap_wait_timeout(caller_id: Option<&str>, requested_ms: u64) -> u64 {
    capped_wait(is_router(caller_id), requested_ms)
}

pub(super) fn capped_wait(router: bool, requested_ms: u64) -> u64 {
    if router {
        requested_ms.min(ROUTER_WAIT_CAP_MS)
    } else {
        requested_ms
    }
}

fn is_router(caller_id: Option<&str>) -> bool {
    caller_id.is_some_and(|caller| crate::supervision::router_id().as_deref() == Some(caller))
}

/// One finished tool call: a Router wait the cap cut short says why.
pub(crate) fn explain_wait(
    tool: &str,
    args: &Value,
    result: Result<String, String>,
) -> Result<String, String> {
    if result.is_ok() || !is_wait(tool, args) {
        return result;
    }
    let router = is_router(crate::mcp_host::self_session_id().as_deref());
    explain_wait_for(router, tool, args, result)
}

pub(super) fn explain_wait_for(
    router: bool,
    tool: &str,
    args: &Value,
    result: Result<String, String>,
) -> Result<String, String> {
    match result {
        Err(error) if router && is_wait(tool, args) && beyond_cap(args) => {
            Err(format!("{error}\n{ROUTER_WAIT_NOTE}"))
        }
        result => result,
    }
}

/// `agents wait`, `sessions wait_for_text` / `wait_for_status`, or their
/// legacy per-tool names.
fn is_wait(tool: &str, args: &Value) -> bool {
    let action = args.get("action").and_then(Value::as_str).map(str::trim);
    match tool {
        "sessions" => matches!(action, Some("wait_for_text" | "wait_for_status")),
        "agents" => action == Some("wait"),
        legacy => matches!(legacy, "wait_for_text" | "wait_for_status"),
    }
}

/// Whether the cap lowered this wait. No `timeout_ms` means upstream's
/// 30 s default, which is past the cap.
fn beyond_cap(args: &Value) -> bool {
    args.get("timeout_ms")
        .and_then(Value::as_u64)
        .is_none_or(|ms| ms > ROUTER_WAIT_CAP_MS)
}

#[cfg(test)]
mod tests;
