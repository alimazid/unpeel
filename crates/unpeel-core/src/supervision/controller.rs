//! Fork-only: the Controller-facing half of the Super Agent state — the
//! three Host verbs (`session.super_agent.set` / `.clear` / `.hand_over`)
//! and the two bootstrap fields every session summary carries.
//!
//! Every refusal is decided before anything is written, so a 4xx from these
//! verbs always means "not applied" (the contract the Controller backend
//! relies on). The `_at` functions take explicit roots and a facts lookup so
//! tests never touch the real home; the public wrappers plug the real home
//! in and announce on the state bus.

use std::path::Path;

use crate::runtime_catalog::RuntimeDescriptor;
use crate::session_inbox::{ItemKind, NewItem, Priority, Sender, Store};

/// The catalog id of the one runtime that may be the Router.
pub const CLAUDE_CODE_RUNTIME_ID: &str = "com.anthropic.claude-code";

/// What a verb needs to know about one Session, read from its manifest by
/// the real-home wrappers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionFacts {
    pub running: bool,
    /// The observed foreground runtime (`active_runtime_id`, a legacy slug).
    pub observed_runtime: Option<String>,
    /// The launch command, as typed.
    pub command: String,
    pub label: String,
}

impl SessionFacts {
    /// Claude Code by observation, or — when nothing is observed — by the
    /// catalog match on the launch command. The same rule the Mac menu uses.
    pub fn is_claude_code(&self) -> bool {
        self.runtime()
            .is_some_and(|runtime| runtime.id == CLAUDE_CODE_RUNTIME_ID)
    }

    /// Any catalog agent runtime, by the same observed-first rule.
    pub fn is_agent(&self) -> bool {
        self.runtime().is_some()
    }

    /// An observation always wins: a `claude` launch now running something
    /// else is that something else.
    fn runtime(&self) -> Option<&'static RuntimeDescriptor> {
        match self.observed_runtime.as_deref() {
            Some(observed) => crate::integrations::runtime_for_dispatch(observed),
            None => crate::integrations::runtime_for_command(&self.command),
        }
    }
}

/// Why a verb refused, or that it failed part-way. Every refusal (4xx) is
/// decided before anything is written; only `Failed` may follow a write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerbError {
    InvalidId,
    UnknownSession,
    NotRunning,
    NotClaudeCode,
    NotAnAgent,
    NoRouter,
    IsTheRouter,
    Failed(String),
}

impl VerbError {
    /// The Controller status, in `session.mark_unread`'s vocabulary.
    pub fn status(&self) -> u16 {
        match self {
            VerbError::InvalidId => 400,
            VerbError::UnknownSession => 404,
            VerbError::NotRunning | VerbError::NoRouter | VerbError::IsTheRouter => 409,
            VerbError::NotClaudeCode | VerbError::NotAnAgent => 422,
            VerbError::Failed(_) => 500,
        }
    }
}

impl std::fmt::Display for VerbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            VerbError::InvalidId => "invalid session id",
            VerbError::UnknownSession => "unknown session",
            VerbError::NotRunning => "the session is not running",
            VerbError::NotClaudeCode => "only a Claude Code session can be the Super Agent",
            VerbError::NotAnAgent => "only an agent session can be handed to the Super Agent",
            VerbError::NoRouter => "this workspace has no Super Agent",
            VerbError::IsTheRouter => "this session is the Super Agent",
            VerbError::Failed(message) => message,
        })
    }
}

/// What a verb did.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct VerbOutcome {
    /// `false`: already in effect, nothing was written.
    pub changed: bool,
    /// App-state (the Router mark) was written.
    pub(crate) state_written: bool,
    /// Worker markers or an Inbox were written.
    pub(crate) markers_written: bool,
}

/// Where a verb reads and writes, and how it learns about a Session.
pub(crate) struct Ctx<'a> {
    pub state_path: &'a Path,
    pub sessions_root: &'a Path,
    pub inbox: &'a Store,
    pub facts: &'a dyn Fn(&str) -> Option<SessionFacts>,
    pub now_ms: u64,
}

/// `session.super_agent.set` against the real home.
pub fn set_super_agent(session_id: &str) -> Result<VerbOutcome, VerbError> {
    at_home(session_id, set_at)
}

/// `session.super_agent.clear` against the real home.
pub fn clear_super_agent(session_id: &str) -> Result<VerbOutcome, VerbError> {
    at_home(session_id, clear_at)
}

/// `session.super_agent.hand_over` against the real home.
pub fn hand_over_to_super_agent(session_id: &str) -> Result<VerbOutcome, VerbError> {
    at_home(session_id, hand_over_at)
}

/// One bootstrap session summary with the Super Agent fields (see
/// `with_summary_fields_in`). `router_id` is read once per bootstrap.
pub fn with_summary_fields(
    summary: serde_json::Value,
    router_id: Option<&str>,
) -> serde_json::Value {
    with_summary_fields_in(summary, router_id, &crate::app_paths::app_sessions_root())
}

/// After a Resume moved the Router mark to `new_id`. Best effort: the
/// caller is the Resume itself, which must never be undone because an
/// Inbox write failed — the Router can still read `unpeel/router` by hand.
pub(crate) fn router_resumed(new_id: &str) {
    let sent = router_resumed_at(
        &crate::app_paths::app_state_path(),
        &Store::home(),
        new_id,
        super::now_ms(),
    );
    if matches!(sent, Ok(true)) {
        super::announce_markers();
    }
}

type Verb = fn(&Ctx, &str) -> Result<VerbOutcome, VerbError>;

fn at_home(session_id: &str, verb: Verb) -> Result<VerbOutcome, VerbError> {
    if !super::valid_session_id(session_id) {
        return Err(VerbError::InvalidId);
    }
    let state_path = crate::app_paths::app_state_path();
    let sessions_root = crate::app_paths::app_sessions_root();
    let inbox = Store::home();
    let outcome = verb(
        &Ctx {
            state_path: &state_path,
            sessions_root: &sessions_root,
            inbox: &inbox,
            facts: &home_facts,
            now_ms: super::now_ms(),
        },
        session_id,
    );
    announce(&outcome);
    outcome
}

/// A Session as its manifest says, with health refreshed like the Stop
/// verb's pre-check, so a dead Host never reads as running.
fn home_facts(session_id: &str) -> Option<SessionFacts> {
    let manifest = crate::session_host::refresh_manifest_health(session_id)?;
    Some(SessionFacts {
        running: manifest.state == crate::session_host::HostedSessionState::Running,
        observed_runtime: crate::session_host::active_runtime_id(&manifest).map(str::to_owned),
        label: crate::session_ops::title_marker(session_id)
            .unwrap_or_else(|| manifest.session.label.clone()),
        command: manifest.session.command,
    })
}

/// Like `on_session_replaced`: a failure part-way may still have written
/// something, so it announces both; a refusal wrote nothing.
fn announce(outcome: &Result<VerbOutcome, VerbError>) {
    let (state, markers) = match outcome {
        Ok(outcome) => (outcome.state_written, outcome.markers_written),
        Err(VerbError::Failed(_)) => (true, true),
        Err(_) => (false, false),
    };
    if state {
        crate::state_bus::announce(
            crate::state_bus::Change::AppState,
            crate::session_ops::own_listener_port_public(),
        );
    }
    if markers {
        super::announce_markers();
    }
}

/// `session.super_agent.set`: make a running Claude Code Session the Router.
/// A previous Router's Workers move with the mark, and the new Router is
/// told what it took over. Idempotent for the current Router.
pub(crate) fn set_at(ctx: &Ctx, session_id: &str) -> Result<VerbOutcome, VerbError> {
    let facts = (ctx.facts)(session_id).ok_or(VerbError::UnknownSession)?;
    if !facts.running {
        return Err(VerbError::NotRunning);
    }
    if !facts.is_claude_code() {
        return Err(VerbError::NotClaudeCode);
    }
    if current_router(ctx)?.as_deref() == Some(session_id) {
        return Ok(VerbOutcome::default());
    }
    let previous = crate::app_state::edit_at(ctx.state_path, |state| {
        let previous = super::router_id_in_map(state);
        super::set_router_mark_in(state, session_id, ctx.now_ms)?;
        Ok(previous)
    })
    .map_err(|error| VerbError::Failed(format!("Super Agent mark: {error}")))?;
    let written = VerbOutcome {
        changed: true,
        state_written: true,
        markers_written: true,
    };
    take_over(ctx, session_id, previous.as_deref()).map_err(VerbError::Failed)?;
    Ok(written)
}

/// Everything after the mark: the new Router stops being anyone's Worker,
/// takes the old Router's Workers, and gets its instructions (then, when
/// Workers moved, what it took over).
fn take_over(ctx: &Ctx, router_id: &str, previous: Option<&str>) -> Result<(), String> {
    // One level deep: a Router is never a Worker.
    super::remove_worker_marker_in(&ctx.sessions_root.join(router_id))?;
    let moved = match previous.filter(|previous| *previous != router_id) {
        Some(previous) => {
            super::rewrite_worker_markers_in(ctx.sessions_root, previous, Some(router_id))?
        }
        None => 0,
    };
    enqueue(ctx, router_id, instructions_item(router_id, ctx.now_ms))?;
    match previous {
        Some(previous) if moved > 0 => enqueue(
            ctx,
            router_id,
            take_over_item(ctx, router_id, previous, moved),
        ),
        _ => Ok(()),
    }
}

/// The instructions the Router reads on becoming one, and again after a
/// Resume. The dedupe key names the Router id and its mark's `since`, so a
/// repeated call never queues a second copy while a later `set` (new
/// `since`) or Resume (new id) always does.
fn instructions_item(router_id: &str, since: u64) -> NewItem {
    NewItem {
        sender: Sender::Host,
        kind: ItemKind::Task,
        priority: Priority::Wake,
        about: None,
        status: None,
        label: None,
        summary: format!(
            "You are now the Super Agent. Read your instructions with skills read {}, \
             then call sessions current.",
            crate::skills_mcp::ROUTER_SKILL_ID
        ),
        body: String::new(),
        dedupe_key: Some(format!("router-instructions:{router_id}:{since}")),
    }
}

/// What a new Router took over from the previous one: its running Workers
/// by id and label, and how many stopped ones came along.
fn take_over_item(ctx: &Ctx, router_id: &str, previous: &str, moved: usize) -> NewItem {
    let workers: Vec<(String, Option<SessionFacts>)> =
        super::workers_of_in(ctx.sessions_root, router_id)
            .into_iter()
            .map(|id| {
                let facts = (ctx.facts)(&id);
                (id, facts)
            })
            .collect();
    let running: Vec<String> = workers
        .iter()
        .filter_map(|(id, facts)| {
            let facts = facts.as_ref().filter(|facts| facts.running)?;
            Some(format!("- id:{id} \"{}\"", facts.label))
        })
        .collect();
    let stopped = workers.len() - running.len();
    let mut body = if running.is_empty() {
        "None of them is running.".to_owned()
    } else {
        format!(
            "Running Workers now reporting to you:\n{}",
            running.join("\n")
        )
    };
    if stopped > 0 {
        body.push_str(&format!(
            "\n{stopped} stopped Worker{} also moved to you.",
            if stopped == 1 { "" } else { "s" }
        ));
    }
    body.push_str("\nCall sessions current for their cards.");
    NewItem {
        sender: Sender::Host,
        kind: ItemKind::Handover,
        priority: Priority::Wake,
        about: None,
        status: None,
        label: None,
        summary: format!(
            "You took over {moved} Worker{} from the previous Super Agent id:{previous}.",
            if moved == 1 { "" } else { "s" }
        ),
        body,
        dedupe_key: None,
    }
}

/// `session.super_agent.clear`: stop being the Router. Its Workers, running
/// or stopped, become the user's ordinary Sessions. A no-op for any other
/// Session; a mark naming a Session that is gone is still cleared.
pub(crate) fn clear_at(ctx: &Ctx, session_id: &str) -> Result<VerbOutcome, VerbError> {
    if current_router(ctx)?.as_deref() != Some(session_id) {
        return match (ctx.facts)(session_id) {
            Some(_) => Ok(VerbOutcome::default()),
            None => Err(VerbError::UnknownSession),
        };
    }
    let cleared = crate::app_state::edit_at(ctx.state_path, |state| {
        // Re-checked under the lock: another frontend may have moved it.
        Ok(
            super::router_id_in_map(state).as_deref() == Some(session_id)
                && super::clear_router_mark_in(state),
        )
    })
    .map_err(|error| VerbError::Failed(format!("Super Agent mark: {error}")))?;
    if !cleared {
        return Ok(VerbOutcome::default());
    }
    super::rewrite_worker_markers_in(ctx.sessions_root, session_id, None)
        .map_err(VerbError::Failed)?;
    Ok(VerbOutcome {
        changed: true,
        state_written: true,
        markers_written: true,
    })
}

/// `session.super_agent.hand_over`: make a running agent Session the
/// Router's Worker and ask it to summarise itself into the Router's Inbox.
/// No Worker limit applies: a hand-over is the user's free slot (§17.6).
/// Idempotent for a Session already working for this Router.
pub(crate) fn hand_over_at(ctx: &Ctx, session_id: &str) -> Result<VerbOutcome, VerbError> {
    let facts = (ctx.facts)(session_id).ok_or(VerbError::UnknownSession)?;
    let router_id = current_router(ctx)?.ok_or(VerbError::NoRouter)?;
    if router_id == session_id {
        return Err(VerbError::IsTheRouter);
    }
    if !facts.running {
        return Err(VerbError::NotRunning);
    }
    if !facts.is_agent() {
        return Err(VerbError::NotAnAgent);
    }
    let dir = ctx.sessions_root.join(session_id);
    if super::read_worker_marker_in(&dir).is_some_and(|marker| marker.router_id == router_id) {
        return Ok(VerbOutcome::default());
    }
    let marker = super::WorkerMarker {
        router_id: router_id.clone(),
        since: ctx.now_ms,
        origin: super::WorkerOrigin::HandedOver,
    };
    super::write_worker_marker_in(&dir, &marker).map_err(VerbError::Failed)?;
    enqueue(ctx, session_id, summary_request_item(&router_id)).map_err(VerbError::Failed)?;
    Ok(VerbOutcome {
        changed: true,
        state_written: false,
        markers_written: true,
    })
}

/// Asks a handed-over Session to brief its new Router, which carries on
/// from that summary.
fn summary_request_item(router_id: &str) -> NewItem {
    NewItem {
        sender: Sender::Host,
        kind: ItemKind::Task,
        priority: Priority::Wake,
        about: None,
        status: None,
        label: None,
        summary: "The user handed you to the Super Agent: summarise this conversation for it."
            .into(),
        body: format!(
            "You now work for the Super Agent, Session id:{router_id}, and it carries on from \
             your summary. Send it one hand-over report with sessions report: \
             session_id={router_id}, status=done, a one-line summary of what you were asked to \
             do, and details covering what you have done, where things stand now, and any open \
             questions. Then end your turn."
        ),
        dedupe_key: None,
    }
}

/// A Resume gave `new_id` the Router mark: its new process gets the
/// instructions again. `false` when `new_id` is not the Router.
pub(crate) fn router_resumed_at(
    state_path: &Path,
    inbox: &Store,
    new_id: &str,
    now_ms: u64,
) -> Result<bool, String> {
    let state = crate::app_state::load_for_edit_at(state_path)
        .map_err(|error| format!("Super Agent mark: {error}"))?;
    if super::router_id_in(&state).as_deref() != Some(new_id) {
        return Ok(false);
    }
    // `since` survives the Resume, so the new id alone makes the key new.
    let since = state[super::ROUTER_MARK_KEY]["since"]
        .as_u64()
        .unwrap_or_default();
    inbox
        .enqueue(new_id, instructions_item(new_id, since), now_ms)
        .map_err(|error| format!("Inbox of {new_id}: {error}"))?;
    Ok(true)
}

/// One bootstrap session summary with the Super Agent fields: `superAgent`
/// always, `superAgentRouterID` from a Worker marker. Additive; older
/// Controllers ignore both.
pub(crate) fn with_summary_fields_in(
    summary: serde_json::Value,
    router_id: Option<&str>,
    sessions_root: &Path,
) -> serde_json::Value {
    let mut summary = summary;
    let Some(object) = summary.as_object_mut() else {
        return summary;
    };
    let id = object
        .get("id")
        .and_then(serde_json::Value::as_str)
        .filter(|id| super::valid_session_id(id))
        .map(str::to_owned);
    let is_router = id.is_some() && id.as_deref() == router_id;
    object.insert("superAgent".into(), is_router.into());
    if let Some(marker) = id.and_then(|id| super::read_worker_marker_in(&sessions_root.join(id))) {
        object.insert("superAgentRouterID".into(), marker.router_id.into());
    }
    summary
}

fn enqueue(ctx: &Ctx, target: &str, item: NewItem) -> Result<(), String> {
    ctx.inbox
        .enqueue(target, item, ctx.now_ms)
        .map(|_| ())
        .map_err(|error| format!("Inbox of {target}: {error}"))
}

fn current_router(ctx: &Ctx) -> Result<Option<String>, VerbError> {
    crate::app_state::load_for_edit_at(ctx.state_path)
        .map(|state| super::router_id_in(&state))
        .map_err(|error| VerbError::Failed(format!("Super Agent mark: {error}")))
}

#[cfg(test)]
mod tests;
