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

use crate::runtime_catalog::{RuntimeCapability, RuntimeDescriptor};
use crate::session_inbox::{ItemKind, NewItem, Priority, Sender, Store};

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
    /// The user named it through an upstream rename (manifest
    /// `custom_title`); a `title.json` rename is read from the file.
    pub custom_title: bool,
}

impl SessionFacts {
    /// Its runtime declares the `super_agent` capability in its package, by
    /// observation or — when nothing is observed — by the catalog match on
    /// the launch command. The same rule the Mac menu uses.
    pub fn can_be_super_agent(&self) -> bool {
        self.runtime().is_some_and(|runtime| {
            runtime
                .capabilities
                .contains(&RuntimeCapability::SuperAgent)
        })
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
    CannotBeSuperAgent,
    NotAnAgent,
    NoRouter,
    IsTheRouter,
    /// The Router already runs `supervisor_max_children` (the value held)
    /// Workers plus the one hand-over slot.
    WorkerLimit(usize),
    Failed(String),
}

impl VerbError {
    /// The Controller status, in `session.mark_unread`'s vocabulary.
    pub fn status(&self) -> u16 {
        match self {
            VerbError::InvalidId => 400,
            VerbError::UnknownSession => 404,
            VerbError::NotRunning
            | VerbError::NoRouter
            | VerbError::IsTheRouter
            | VerbError::WorkerLimit(_) => 409,
            VerbError::CannotBeSuperAgent | VerbError::NotAnAgent => 422,
            VerbError::Failed(_) => 500,
        }
    }
}

impl std::fmt::Display for VerbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let text = match self {
            VerbError::InvalidId => "invalid session id",
            VerbError::UnknownSession => "unknown session",
            VerbError::NotRunning => "the session is not running",
            VerbError::CannotBeSuperAgent => "this session's agent cannot be the Super Agent",
            VerbError::NotAnAgent => "only an agent session can be handed to the Super Agent",
            VerbError::NoRouter => "this workspace has no Super Agent",
            VerbError::IsTheRouter => "this session is the Super Agent",
            VerbError::WorkerLimit(limit) => {
                return write!(
                    f,
                    "the Super Agent already has {} running Workers: its limit \
                     (supervisor_max_children = {limit}) plus the one hand-over slot. Stop one \
                     of its Workers first",
                    limit + 1
                );
            }
            VerbError::Failed(message) => message,
        };
        f.write_str(text)
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
        custom_title: manifest.session.custom_title,
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

/// `session.super_agent.set`: make a running Session whose runtime declares
/// `super_agent` (Claude Code today) the Router.
/// A previous Router's Workers move with the mark, and the new Router is
/// told what it took over. Idempotent for the current Router.
pub(crate) fn set_at(ctx: &Ctx, session_id: &str) -> Result<VerbOutcome, VerbError> {
    let facts = (ctx.facts)(session_id).ok_or(VerbError::UnknownSession)?;
    if !facts.running {
        return Err(VerbError::NotRunning);
    }
    if !facts.can_be_super_agent() {
        return Err(VerbError::CannotBeSuperAgent);
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
    name_router(ctx, session_id, &facts).map_err(VerbError::Failed)?;
    Ok(written)
}

/// The title a Router gets while it is the Router, unless the user named it.
const ROUTER_TITLE: &str = "Super Agent";
/// `title.json` `by`: this title came from becoming the Router.
const ROUTER_TITLE_BY: &str = "super_agent";

/// An agent-titled Session follows its conversation's title, which would
/// now come from the Router instructions ("Unpeel inbox notice"). Name it
/// through the shared `title.json` override a rename writes, marked as
/// ours so it goes with the mark; a name the user chose always stays.
fn name_router(ctx: &Ctx, session_id: &str, facts: &SessionFacts) -> Result<(), String> {
    let path = ctx.sessions_root.join(session_id).join("title.json");
    if facts.custom_title || path.exists() {
        return Ok(());
    }
    let body = serde_json::json!({
        "title": ROUTER_TITLE,
        "updated_at": ctx.now_ms,
        "by": ROUTER_TITLE_BY,
    })
    .to_string();
    crate::hook_assets::write_file_atomic(&path, &body, "Router title")
}

/// Drop the title [`name_router`] gave, so the Session's own title shows
/// again; a later rename by the user is theirs and stays.
fn unname_router(ctx: &Ctx, session_id: &str) -> Result<(), String> {
    let path = ctx.sessions_root.join(session_id).join("title.json");
    let ours = std::fs::read(&path)
        .ok()
        .and_then(|raw| serde_json::from_slice::<serde_json::Value>(&raw).ok())
        .is_some_and(|title| {
            title.get("by").and_then(serde_json::Value::as_str) == Some(ROUTER_TITLE_BY)
        });
    if !ours {
        return Ok(());
    }
    match std::fs::remove_file(&path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            Err(format!("Router title: {error}"))
        }
        _ => Ok(()),
    }
}

/// Everything after the mark: the new Router stops being anyone's Worker,
/// takes the old Router's Workers, and gets its instructions (then, when
/// Workers moved, what it took over).
fn take_over(ctx: &Ctx, router_id: &str, previous: Option<&str>) -> Result<(), String> {
    // One level deep: a Router is never a Worker.
    super::remove_worker_marker_in(&ctx.sessions_root.join(router_id))?;
    let moved = match previous.filter(|previous| *previous != router_id) {
        Some(previous) => {
            unname_router(ctx, previous)?;
            // What waits for the old Router is the new one's: Worker results
            // still wake it. The old Router's own instructions apply to no one.
            ctx.inbox
                .hand_over_pending(previous, router_id, is_router_instructions)
                .map_err(|error| format!("Inbox of {previous}: {error}"))?;
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

/// Dedupe-key prefix of the Router instructions item.
const INSTRUCTIONS_KEY_PREFIX: &str = "router-instructions:";

fn is_router_instructions(item: &crate::session_inbox::InboxItem) -> bool {
    item.sender == Sender::Host
        && item
            .dedupe_key
            .as_deref()
            .is_some_and(|key| key.starts_with(INSTRUCTIONS_KEY_PREFIX))
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
            crate::skills_builtin::ROUTER_SKILL_ID
        ),
        body: String::new(),
        dedupe_key: Some(format!("{INSTRUCTIONS_KEY_PREFIX}{router_id}:{since}")),
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
    unname_router(ctx, session_id).map_err(VerbError::Failed)?;
    // Instructions it never read are no longer for it.
    ctx.inbox
        .drop_pending(session_id, is_router_instructions)
        .map_err(|error| VerbError::Failed(format!("Inbox of {session_id}: {error}")))?;
    Ok(VerbOutcome {
        changed: true,
        state_written: true,
        markers_written: true,
    })
}

/// `session.super_agent.hand_over`: make a running agent Session the
/// Router's Worker and ask it to summarise itself into the Router's Inbox.
/// A hand-over is the user's free slot (§17.6): accepted at
/// `supervisor_max_children` running Workers, one over the limit, and
/// refused past that. Idempotent for a Session already working for this
/// Router.
pub(crate) fn hand_over_at(ctx: &Ctx, session_id: &str) -> Result<VerbOutcome, VerbError> {
    let facts = (ctx.facts)(session_id).ok_or(VerbError::UnknownSession)?;
    let state = load_state(ctx)?;
    let router_id = super::router_id_in(&state).ok_or(VerbError::NoRouter)?;
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
    let limit = super::config_from_state(&state, false).max_children;
    if running_workers(ctx, &router_id) > limit {
        return Err(VerbError::WorkerLimit(limit));
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
    load_state(ctx).map(|state| super::router_id_in(&state))
}

fn load_state(ctx: &Ctx) -> Result<serde_json::Value, VerbError> {
    crate::app_state::load_for_edit_at(ctx.state_path)
        .map_err(|error| VerbError::Failed(format!("Super Agent mark: {error}")))
}

/// `router_id`'s Workers that are running now.
fn running_workers(ctx: &Ctx, router_id: &str) -> usize {
    super::workers_of_in(ctx.sessions_root, router_id)
        .iter()
        .filter(|id| (ctx.facts)(id).is_some_and(|facts| facts.running))
        .count()
}

#[cfg(test)]
mod tests;
