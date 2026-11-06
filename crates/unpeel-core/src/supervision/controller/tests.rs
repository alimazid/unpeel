use super::*;
use crate::supervision::{
    read_worker_marker_in, router_id_in, write_worker_marker_in, WorkerMarker, WorkerOrigin,
};
use std::collections::HashMap;
use std::path::PathBuf;

/// A private home: app-state, `app-sessions/` and an Inbox store, plus
/// the Sessions a verb can see. Never the process-global `UNPEEL_HOME`.
struct Home {
    root: PathBuf,
    inbox: Store,
    sessions: HashMap<String, SessionFacts>,
}

impl Home {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("sa-verbs-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("app-sessions")).unwrap();
        Self {
            inbox: Store::at(root.join("session-inboxes")),
            root,
            sessions: HashMap::new(),
        }
    }

    /// A Session dir plus what its manifest would say.
    fn session(mut self, id: &str, running: bool, observed: Option<&str>, command: &str) -> Self {
        std::fs::create_dir_all(self.sessions_root().join(id)).unwrap();
        self.sessions.insert(
            id.into(),
            SessionFacts {
                running,
                observed_runtime: observed.map(str::to_owned),
                command: command.into(),
                label: format!("{id} label"),
                custom_title: false,
            },
        );
        self
    }

    fn state_path(&self) -> PathBuf {
        self.root.join("app-state.json")
    }

    fn sessions_root(&self) -> PathBuf {
        self.root.join("app-sessions")
    }

    fn run<T>(&self, now_ms: u64, verb: impl FnOnce(&Ctx) -> T) -> T {
        let lookup = |id: &str| self.sessions.get(id).cloned();
        verb(&Ctx {
            state_path: &self.state_path(),
            sessions_root: &self.sessions_root(),
            inbox: &self.inbox,
            facts: &lookup,
            now_ms,
        })
    }

    fn state(&self) -> serde_json::Value {
        crate::app_state::load_for_edit_at(&self.state_path()).unwrap()
    }

    fn router(&self) -> Option<String> {
        router_id_in(&self.state())
    }

    fn marker(&self, id: &str) -> Option<WorkerMarker> {
        read_worker_marker_in(&self.sessions_root().join(id))
    }

    fn mark_worker(&self, id: &str, router: &str, origin: WorkerOrigin) {
        write_worker_marker_in(
            &self.sessions_root().join(id),
            &WorkerMarker {
                router_id: router.into(),
                since: 3,
                origin,
            },
        )
        .unwrap();
    }

    /// Pending Inbox items as (kind, priority, summary, body).
    fn pending(&self, id: &str) -> Vec<(ItemKind, Priority, String, String)> {
        self.inbox
            .list(id)
            .unwrap()
            .pending
            .iter()
            .map(|header| {
                let item = self.inbox.item(id, &header.id).unwrap().unwrap();
                assert_eq!(item.sender, Sender::Host);
                (item.kind, item.priority, item.summary, item.body)
            })
            .collect()
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

const INSTRUCTIONS: &str = "You are now the Super Agent. Read your instructions with \
                            skills read unpeel/router, then call sessions current.";

fn claude_home() -> Home {
    Home::new()
        .session("router-1", true, None, "claude")
        .session("router-2", true, Some("claude"), "zsh")
        .session("codex-1", true, None, "codex")
        .session("shell-1", true, None, "cat")
        .session("stopped-claude", false, None, "claude")
}

#[test]
fn set_marks_a_running_claude_code_session_and_queues_its_instructions() {
    let home = claude_home();
    let outcome = home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    assert!(outcome.changed);
    assert_eq!(home.router().as_deref(), Some("router-1"));
    assert_eq!(home.state()["super_agent"]["since"], 100);
    assert_eq!(
        home.pending("router-1"),
        [(
            ItemKind::Task,
            Priority::Wake,
            INSTRUCTIONS.to_owned(),
            String::new()
        )]
    );
}

#[test]
fn set_refuses_sessions_that_cannot_be_the_router_and_writes_nothing() {
    let home = claude_home();
    for (id, refusal) in [
        ("never-created", VerbError::UnknownSession),
        ("stopped-claude", VerbError::NotRunning),
        ("codex-1", VerbError::CannotBeSuperAgent),
        ("shell-1", VerbError::CannotBeSuperAgent),
    ] {
        assert_eq!(home.run(1, |ctx| set_at(ctx, id)), Err(refusal), "{id}");
        assert!(home.pending(id).is_empty(), "{id}");
    }
    assert!(!home.state_path().exists(), "no app-state write");
}

#[test]
fn set_is_idempotent_for_the_current_router() {
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    let again = home.run(200, |ctx| set_at(ctx, "router-1")).unwrap();
    assert!(!again.changed);
    assert_eq!(home.state()["super_agent"]["since"], 100, "mark untouched");
    assert_eq!(home.pending("router-1").len(), 1, "no second instructions");
}

#[test]
fn switching_the_router_moves_its_workers_and_briefs_the_new_one() {
    let home = claude_home()
        .session("worker-run", true, None, "codex")
        .session("worker-stopped", false, None, "claude")
        .session("other", true, None, "claude");
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.mark_worker("worker-run", "router-1", WorkerOrigin::Created);
    home.mark_worker("worker-stopped", "router-1", WorkerOrigin::HandedOver);
    // The new Router was one of the old one's Workers: it is one no more.
    home.mark_worker("router-2", "router-1", WorkerOrigin::Created);

    let outcome = home.run(200, |ctx| set_at(ctx, "router-2")).unwrap();
    assert!(outcome.changed);
    assert_eq!(home.router().as_deref(), Some("router-2"));
    assert_eq!(home.marker("router-2"), None, "a Router is never a Worker");
    let moved = home.marker("worker-stopped").unwrap();
    assert_eq!(moved.router_id, "router-2");
    assert_eq!(moved.origin, WorkerOrigin::HandedOver, "origin survives");
    assert_eq!(home.marker("worker-run").unwrap().router_id, "router-2");
    assert_eq!(home.marker("other"), None);

    let pending = home.pending("router-2");
    assert_eq!(pending.len(), 2, "{pending:?}");
    assert_eq!(
        (pending[0].0, pending[0].2.as_str()),
        (ItemKind::Task, INSTRUCTIONS)
    );
    let (kind, priority, summary, body) = &pending[1];
    assert_eq!((*kind, *priority), (ItemKind::Handover, Priority::Wake));
    assert!(
        summary.contains("2 Workers") && summary.contains("id:router-1"),
        "{summary}"
    );
    assert!(
        body.contains("id:worker-run") && body.contains("worker-run label"),
        "{body}"
    );
    assert!(!body.contains("id:worker-stopped"), "running only: {body}");
    assert!(body.contains("1 stopped"), "{body}");
    // The old Router is an ordinary Session now: its own instructions,
    // never delivered, no longer apply to anyone.
    assert_eq!(home.pending("router-1").len(), 0);
}

#[test]
fn switching_the_router_hands_the_old_routers_queue_to_the_new_one() {
    let home = claude_home().session("w1", true, None, "codex");
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.mark_worker("w1", "router-1", WorkerOrigin::Created);
    let report = NewItem {
        sender: Sender::Session("w1".into()),
        kind: ItemKind::Report,
        priority: Priority::Wake,
        about: None,
        status: Some("done".into()),
        label: Some("w1 label".into()),
        summary: "login fixed".into(),
        body: String::new(),
        dedupe_key: None,
    };
    home.inbox.enqueue("router-1", report, 150).unwrap();

    home.run(200, |ctx| set_at(ctx, "router-2")).unwrap();
    assert!(home.inbox.list("router-1").unwrap().pending.is_empty());
    let handed: Vec<_> = home
        .inbox
        .list("router-2")
        .unwrap()
        .pending
        .into_iter()
        .filter(|item| item.sender == Sender::Session("w1".into()))
        .collect();
    assert_eq!(handed.len(), 1, "{handed:?}");
    assert_eq!(handed[0].summary, "login fixed");
    // Still a result: it wakes the new Router, about no one else.
    assert_eq!(handed[0].priority, Priority::Wake);
    assert_eq!(handed[0].about, None);
    let instructions = home
        .inbox
        .list("router-2")
        .unwrap()
        .pending
        .iter()
        .filter(|item| item.summary == INSTRUCTIONS)
        .count();
    assert_eq!(instructions, 1, "only the new Router's own instructions");
}

#[test]
fn clear_drops_the_mark_and_frees_every_worker() {
    let home = claude_home()
        .session("w1", true, None, "codex")
        .session("w2", false, None, "claude");
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.mark_worker("w1", "router-1", WorkerOrigin::Created);
    home.mark_worker("w2", "router-1", WorkerOrigin::HandedOver);
    home.mark_worker("codex-1", "someone-else", WorkerOrigin::Created);

    let outcome = home.run(200, |ctx| clear_at(ctx, "router-1")).unwrap();
    assert!(outcome.changed);
    assert_eq!(home.router(), None);
    assert_eq!(home.marker("w1"), None, "running Workers become the user's");
    assert_eq!(home.marker("w2"), None, "stopped ones too");
    assert!(home.marker("codex-1").is_some(), "not this Router's Worker");
}

#[test]
fn clear_drops_the_undelivered_router_instructions_and_keeps_the_rest() {
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.inbox
        .enqueue(
            "router-1",
            NewItem {
                sender: Sender::Session("w1".into()),
                kind: ItemKind::Report,
                priority: Priority::Wake,
                about: None,
                status: Some("done".into()),
                label: None,
                summary: "a Worker's result".into(),
                body: String::new(),
                dedupe_key: None,
            },
            150,
        )
        .unwrap();

    home.run(200, |ctx| clear_at(ctx, "router-1")).unwrap();
    let pending: Vec<String> = home
        .inbox
        .list("router-1")
        .unwrap()
        .pending
        .into_iter()
        .map(|header| header.summary)
        .collect();
    assert_eq!(
        pending,
        ["a Worker's result"],
        "no instructions for an ordinary session"
    );

    // Made the Router again later: the instructions come back.
    home.run(300, |ctx| set_at(ctx, "router-1")).unwrap();
    assert_eq!(
        home.inbox.list("router-1").unwrap().pending.len(),
        2,
        "a new mark is a new instructions item"
    );
}

#[test]
fn clear_is_a_no_op_unless_the_session_is_the_router() {
    let home = claude_home().session("w1", true, None, "codex");
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.mark_worker("w1", "router-1", WorkerOrigin::Created);
    let before = std::fs::read(home.state_path()).unwrap();

    for id in ["router-2", "w1", "shell-1"] {
        let outcome = home.run(200, |ctx| clear_at(ctx, id)).unwrap();
        assert!(!outcome.changed, "{id}");
    }
    assert_eq!(std::fs::read(home.state_path()).unwrap(), before);
    assert_eq!(home.marker("w1").unwrap().router_id, "router-1");
    assert_eq!(
        home.run(200, |ctx| clear_at(ctx, "never-created")),
        Err(VerbError::UnknownSession)
    );
}

#[test]
fn hand_over_makes_a_worker_and_asks_it_for_a_summary() {
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();

    let outcome = home.run(300, |ctx| hand_over_at(ctx, "codex-1")).unwrap();
    assert!(outcome.changed);
    assert_eq!(
        home.marker("codex-1"),
        Some(WorkerMarker {
            router_id: "router-1".into(),
            since: 300,
            origin: WorkerOrigin::HandedOver,
        })
    );
    let pending = home.pending("codex-1");
    assert_eq!(pending.len(), 1, "{pending:?}");
    let (kind, priority, summary, body) = &pending[0];
    assert_eq!((*kind, *priority), (ItemKind::Task, Priority::Wake));
    assert!(summary.contains("Super Agent"), "{summary}");
    for expected in [
        "sessions report",
        "session_id=router-1",
        "status=done",
        "summary",
    ] {
        assert!(body.contains(expected), "{expected}: {body}");
    }
    // The Router hears nothing yet: the summary is the hand-over.
    assert_eq!(home.pending("router-1").len(), 1, "instructions only");
}

#[test]
fn hand_over_refuses_without_a_router_or_a_running_agent_and_writes_nothing() {
    let home = claude_home().session("stopped-codex", false, None, "codex");
    assert_eq!(
        home.run(1, |ctx| hand_over_at(ctx, "codex-1")),
        Err(VerbError::NoRouter)
    );
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    for (id, refusal) in [
        ("never-created", VerbError::UnknownSession),
        ("router-1", VerbError::IsTheRouter),
        ("stopped-codex", VerbError::NotRunning),
        ("shell-1", VerbError::NotAnAgent),
    ] {
        assert_eq!(
            home.run(2, |ctx| hand_over_at(ctx, id)),
            Err(refusal),
            "{id}"
        );
        assert_eq!(home.marker(id), None, "{id}");
    }
    for id in ["codex-1", "stopped-codex", "shell-1"] {
        assert!(home.pending(id).is_empty(), "{id}");
    }
}

#[test]
fn hand_over_takes_the_one_slot_past_the_worker_limit_and_no_more() {
    let home = claude_home()
        .session("busy-0", true, None, "claude")
        .session("done-0", false, None, "claude")
        .session("codex-2", true, None, "codex");
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    crate::app_state::edit_at(&home.state_path(), |state| {
        state.insert("supervisor_max_children".into(), 1.into());
        Ok(())
    })
    .unwrap();
    home.mark_worker("busy-0", "router-1", WorkerOrigin::Created);
    // A stopped Worker holds no slot.
    home.mark_worker("done-0", "router-1", WorkerOrigin::Created);

    // At the limit, a hand-over still fits: one over it (§17.6).
    assert!(home.run(2, |ctx| hand_over_at(ctx, "codex-1")).is_ok());
    assert_eq!(home.marker("codex-1").unwrap().router_id, "router-1");

    // Past that slot, a hand-over is refused before anything is written.
    let refused = home.run(3, |ctx| hand_over_at(ctx, "codex-2"));
    assert_eq!(refused, Err(VerbError::WorkerLimit(1)));
    assert_eq!(VerbError::WorkerLimit(1).status(), 409);
    let message = VerbError::WorkerLimit(1).to_string();
    assert!(
        message.contains("supervisor_max_children") && message.contains("2 running Workers"),
        "{message}"
    );
    assert!(home.marker("codex-2").is_none());
    assert!(home.pending("codex-2").is_empty());
}

#[test]
fn handing_over_an_existing_worker_is_a_no_op_and_a_stale_one_is_repointed() {
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.mark_worker("codex-1", "router-1", WorkerOrigin::Created);
    let outcome = home.run(2, |ctx| hand_over_at(ctx, "codex-1")).unwrap();
    assert!(!outcome.changed);
    assert_eq!(
        home.marker("codex-1").unwrap().origin,
        WorkerOrigin::Created
    );
    assert!(home.pending("codex-1").is_empty());

    home.mark_worker("router-2", "gone-router", WorkerOrigin::Created);
    let outcome = home.run(3, |ctx| hand_over_at(ctx, "router-2")).unwrap();
    assert!(outcome.changed);
    assert_eq!(home.marker("router-2").unwrap().router_id, "router-1");
    assert_eq!(home.pending("router-2").len(), 1);
}

#[test]
fn a_resumed_router_is_sent_its_instructions_again_once() {
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    crate::supervision::on_session_replaced_at(
        &home.state_path(),
        &home.sessions_root(),
        "router-1",
        Some("router-1b"),
    )
    .unwrap();

    for _ in 0..2 {
        let sent = router_resumed_at(&home.state_path(), &home.inbox, "router-1b", 500).unwrap();
        assert!(sent);
    }
    let pending = home.pending("router-1b");
    assert_eq!(pending.len(), 1, "a repeated call is deduped: {pending:?}");
    assert_eq!(
        (pending[0].0, pending[0].2.as_str()),
        (ItemKind::Task, INSTRUCTIONS)
    );
    // An ordinary Session's Resume sends nothing.
    assert!(!router_resumed_at(&home.state_path(), &home.inbox, "codex-1", 500).unwrap());
    assert!(home.pending("codex-1").is_empty());
}

#[test]
fn session_summaries_publish_the_router_and_each_workers_router() {
    let home = claude_home();
    home.mark_worker("codex-1", "router-1", WorkerOrigin::HandedOver);
    let summary = |id: &str, router: Option<&str>| {
        with_summary_fields_in(
            serde_json::json!({ "id": id, "title": "kept" }),
            router,
            &home.sessions_root(),
        )
    };

    let router = summary("router-1", Some("router-1"));
    assert_eq!(router["superAgent"], true);
    assert!(router.get("superAgentRouterID").is_none());
    assert_eq!(router["title"], "kept");

    let worker = summary("codex-1", Some("router-1"));
    assert_eq!(worker["superAgent"], false);
    assert_eq!(worker["superAgentRouterID"], "router-1");

    let ordinary = summary("shell-1", Some("router-1"));
    assert_eq!(ordinary["superAgent"], false);
    assert!(ordinary.get("superAgentRouterID").is_none());

    // No Router: nobody is one; a marker still names its Router.
    assert_eq!(summary("router-1", None)["superAgent"], false);
    assert_eq!(summary("codex-1", None)["superAgentRouterID"], "router-1");
}

#[test]
fn refusals_carry_the_controller_statuses() {
    for (error, status) in [
        (VerbError::InvalidId, 400),
        (VerbError::UnknownSession, 404),
        (VerbError::NotRunning, 409),
        (VerbError::NoRouter, 409),
        (VerbError::IsTheRouter, 409),
        (VerbError::WorkerLimit(8), 409),
        (VerbError::CannotBeSuperAgent, 422),
        (VerbError::NotAnAgent, 422),
        (VerbError::Failed("disk".into()), 500),
    ] {
        assert_eq!(error.status(), status, "{error}");
    }
    assert_eq!(VerbError::UnknownSession.to_string(), "unknown session");
    assert_eq!(VerbError::Failed("disk".into()).to_string(), "disk");
}

#[test]
fn the_real_home_verbs_refuse_ids_that_are_not_session_ids() {
    for verb in [set_super_agent, clear_super_agent, hand_over_to_super_agent] {
        for bad in ["", "../escape", "a/b"] {
            assert_eq!(verb(bad), Err(VerbError::InvalidId), "{bad:?}");
        }
    }
}

#[test]
fn clear_drops_a_mark_whose_session_is_gone() {
    let home = claude_home();
    crate::app_state::edit_at(&home.state_path(), |state| {
        crate::supervision::set_router_mark_in(state, "vanished", 1)
    })
    .unwrap();
    let outcome = home.run(200, |ctx| clear_at(ctx, "vanished")).unwrap();
    assert!(outcome.changed);
    assert_eq!(home.router(), None);
}

fn facts(observed: Option<&str>, command: &str) -> SessionFacts {
    SessionFacts {
        running: true,
        observed_runtime: observed.map(str::to_owned),
        command: command.into(),
        label: "a session".into(),
        custom_title: false,
    }
}

#[test]
fn only_runtimes_declaring_super_agent_may_be_the_router() {
    let catalog = crate::runtime_catalog::builtin_runtime_catalog();
    let capable: Vec<&str> = catalog
        .descriptors()
        .iter()
        .filter(|runtime| {
            runtime
                .capabilities
                .contains(&crate::runtime_catalog::RuntimeCapability::SuperAgent)
        })
        .map(|runtime| runtime.slug.as_str())
        .collect();
    // The package declares it (runtimes/claude-code/runtime.toml); the Host
    // names no provider.
    assert_eq!(capable, ["claude-code"]);
}

#[test]
fn the_router_runtime_is_recognized_by_observation_first_then_by_command() {
    // Observed Claude Code wins whatever was launched.
    assert!(facts(Some("claude"), "zsh").can_be_super_agent());
    assert!(facts(Some("claude"), "").can_be_super_agent());
    // Nothing observed: the launch command decides.
    assert!(facts(None, "claude --dangerously-skip-permissions").can_be_super_agent());
    assert!(facts(None, "claude").can_be_super_agent());
    // An observation of something else beats a `claude` launch.
    assert!(!facts(Some("codex"), "claude").can_be_super_agent());
    assert!(!facts(Some("unpeel.app.markdown"), "claude").can_be_super_agent());
    // Other agents and plain commands are not Claude Code.
    assert!(!facts(None, "codex").can_be_super_agent());
    assert!(!facts(None, "cat").can_be_super_agent());
    assert!(!facts(None, "").can_be_super_agent());
}

#[test]
fn any_catalog_runtime_is_an_agent_session() {
    assert!(facts(Some("codex"), "zsh").is_agent());
    assert!(facts(None, "codex").is_agent());
    assert!(facts(None, "claude").is_agent());
    assert!(!facts(None, "cat").is_agent());
    assert!(!facts(None, "").is_agent());
    // An App in the foreground is not an agent, whatever was launched.
    assert!(!facts(Some("unpeel.app.markdown"), "claude").is_agent());
}

impl Home {
    /// The Session's manifest says the user named it (an upstream rename).
    fn custom_titled(mut self, id: &str) -> Self {
        self.sessions.get_mut(id).unwrap().custom_title = true;
        self
    }

    fn title_json(&self, id: &str) -> Option<serde_json::Value> {
        let raw = std::fs::read(self.sessions_root().join(id).join("title.json")).ok()?;
        serde_json::from_slice(&raw).ok()
    }

    fn title_marker(&self, id: &str) -> Option<String> {
        self.title_json(id)?
            .get("title")?
            .as_str()
            .map(str::to_owned)
    }

    /// The user renames the Session through the shared override.
    fn rename(&self, id: &str, title: &str) {
        let body = serde_json::json!({ "title": title, "updated_at": 7 });
        std::fs::write(
            self.sessions_root().join(id).join("title.json"),
            body.to_string(),
        )
        .unwrap();
    }
}

#[test]
fn set_names_a_session_the_user_never_named_super_agent() {
    // Its agent-written title would otherwise follow the first prompt, now
    // the Router instructions ("Unpeel inbox notice").
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    assert_eq!(
        home.title_marker("router-1").as_deref(),
        Some("Super Agent")
    );
}

#[test]
fn set_keeps_a_name_the_user_chose() {
    let home = claude_home().custom_titled("router-2");
    home.rename("router-1", "hubspot integration");
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    assert_eq!(
        home.title_marker("router-1").as_deref(),
        Some("hubspot integration")
    );
    home.run(200, |ctx| set_at(ctx, "router-2")).unwrap();
    assert_eq!(home.title_marker("router-2"), None);
}

#[test]
fn the_super_agent_name_goes_with_the_mark_but_a_users_rename_stays() {
    let home = claude_home();
    home.run(100, |ctx| set_at(ctx, "router-1")).unwrap();
    home.run(200, |ctx| clear_at(ctx, "router-1")).unwrap();
    assert_eq!(home.title_marker("router-1"), None, "cleared with the mark");

    home.run(300, |ctx| set_at(ctx, "router-1")).unwrap();
    home.run(400, |ctx| set_at(ctx, "router-2")).unwrap();
    assert_eq!(home.title_marker("router-1"), None, "a switch takes it too");
    assert_eq!(
        home.title_marker("router-2").as_deref(),
        Some("Super Agent")
    );

    home.rename("router-2", "my coordinator");
    home.run(500, |ctx| clear_at(ctx, "router-2")).unwrap();
    assert_eq!(
        home.title_marker("router-2").as_deref(),
        Some("my coordinator")
    );
}
