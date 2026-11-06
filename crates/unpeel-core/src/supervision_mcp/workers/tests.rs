use super::*;
use crate::session_inbox::{ItemKind, Priority, Sender};
use crate::supervision::{read_worker_marker_in, write_worker_marker_in, WorkerOrigin};
use serde_json::json;
use std::collections::HashMap;

/// A private home: app-state as a value, `app-sessions/`, an Inbox store and
/// the Sessions a call can see. Never the process-global `UNPEEL_HOME`.
pub(crate) struct TestHome {
    _root: tempfile::TempDir,
    pub sessions_root: PathBuf,
    pub inbox: Store,
    pub worktrees: crate::supervision_worktrees::Ledger,
    pub state: Value,
    pub sessions: HashMap<String, Facts>,
}

pub(crate) const ROUTER: &str = "router-1";
pub(crate) const NOW: u64 = 1_000_000;

impl TestHome {
    pub fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let sessions_root = root.path().join("app-sessions");
        std::fs::create_dir_all(&sessions_root).unwrap();
        Self {
            inbox: Store::at(root.path().join("session-inboxes")),
            worktrees: crate::supervision_worktrees::Ledger::at(
                root.path().join("supervision").join("worktrees.json"),
            ),
            sessions_root,
            _root: root,
            state: json!({
                "super_agent": { "session_id": ROUTER, "since": 1 },
                "projects": [
                    { "id": "p", "name": "P", "path": "/work/p" },
                    { "id": "sidebar-p", "name": "Sidebar", "path": "/work/p", "parent_project_id": "p", "is_folder": true },
                    { "id": "g", "name": "Docs", "path": "/work/p", "parent_project_id": "p", "is_folder": true },
                    { "id": "q", "name": "Q", "path": "/work/q" },
                ],
            }),
            sessions: HashMap::new(),
        }
        .session(ROUTER, true)
        .session("user-1", true)
    }

    /// A Session dir plus what its manifest would say.
    pub fn session(mut self, id: &str, running: bool) -> Self {
        std::fs::create_dir_all(self.sessions_root.join(id)).unwrap();
        self.sessions.insert(
            id.into(),
            Facts {
                running,
                label: format!("{id} label"),
                project_id: "q".into(),
                group_id: "q".into(),
                activity_status: if running { "working" } else { "exited" }.into(),
            },
        );
        self
    }

    pub fn worker(self, id: &str, running: bool, origin: WorkerOrigin, since: u64) -> Self {
        let home = self.session(id, running);
        home.mark(id, ROUTER, origin, since);
        home
    }

    pub fn mark(&self, id: &str, router: &str, origin: WorkerOrigin, since: u64) {
        write_worker_marker_in(
            &self.sessions_root.join(id),
            &WorkerMarker {
                router_id: router.into(),
                since,
                origin,
            },
        )
        .unwrap();
    }

    pub fn with_state(mut self, key: &str, value: Value) -> Self {
        self.state[key] = value;
        self
    }

    pub fn run<T>(&self, body: impl FnOnce(&Home) -> T) -> T {
        let lookup = |id: &str| self.sessions.get(id).cloned();
        body(&Home {
            state: self.state.clone(),
            sessions_root: self.sessions_root.clone(),
            inbox: self.inbox.clone(),
            worktrees: self.worktrees.clone(),
            facts: &lookup,
            now_ms: NOW,
        })
    }

    pub fn marker(&self, id: &str) -> Option<WorkerMarker> {
        read_worker_marker_in(&self.sessions_root.join(id))
    }
}

/// The record `sessions create` hands to `prepare`, in `project_id`.
fn blank_session(project_id: &str) -> crate::state::SessionInfo {
    serde_json::from_value(
        json!({ "id": "", "project_id": project_id, "label": "", "command": "" }),
    )
    .unwrap()
}

fn creator(id: &str) -> Creator {
    Creator {
        id: id.into(),
        label: format!("{id} label"),
        project_id: "p".into(),
    }
}

fn no_worktree(_args: &Value, _project_id: &str) -> Result<Value, String> {
    panic!("no worktree was asked for")
}

fn plan(home: &TestHome, caller: &str, args: Value) -> Result<Option<WorkerPlan>, String> {
    home.run(|ctx| plan_create(ctx, &args, &creator(caller), &no_worktree))
}

fn router_plan(home: &TestHome, args: Value) -> WorkerPlan {
    plan(home, ROUTER, args)
        .unwrap()
        .expect("a Router create is a Worker")
}

#[test]
fn a_plain_create_and_remove_caller_keeps_upstream_behaviour() {
    let home = TestHome::new();
    assert_eq!(
        plan(&home, "user-1", json!({ "preset": "claude" })),
        Ok(None)
    );
    // The Super Agent parameters are the Router's alone.
    for key in ["role", "task", "text", "worktree"] {
        let error = plan(&home, "user-1", json!({ key: "x" })).unwrap_err();
        assert!(error.contains("Super Agent"), "{key}: {error}");
    }
}

#[test]
fn role_and_task_are_trimmed_capped_plain_labels() {
    let home = TestHome::new();
    let long = "x".repeat(500);
    let worker = router_plan(
        &home,
        json!({ "role": "  Re\u{1b}[31mviewer\n ", "task": long, "text": "  fix it  " }),
    );
    let session = worker.prepare(blank_session("p"));
    assert_eq!(session.role.as_deref(), Some("Re[31mviewer"));
    assert_eq!(
        session.task.map(|task| task.chars().count()),
        Some(MAX_LABEL_CHARS)
    );
    // Blank labels are no labels.
    let worker = router_plan(&home, json!({ "role": " \t ", "task": "" }));
    let session = worker.prepare(blank_session("p"));
    assert_eq!((session.role, session.task), (None, None));
}

#[test]
fn a_label_can_never_make_a_worker_an_app_panel() {
    let home = TestHome::new();
    for key in ["role", "task"] {
        let error = plan(&home, ROUTER, json!({ key: " App-Panel " })).unwrap_err();
        assert!(error.contains("app-panel"), "{error}");
    }
    let error = plan(&home, ROUTER, json!({ "role": 7 })).unwrap_err();
    assert!(error.contains("'role'"), "{error}");
}

#[test]
fn the_router_never_files_a_worker_into_the_sidebar_group() {
    let home = TestHome::new();
    let error = plan(&home, ROUTER, json!({ "project_id": "sidebar-p" })).unwrap_err();
    assert!(error.contains("Sidebar"), "{error}");
    // Any other group or Project is fine.
    assert!(plan(&home, ROUTER, json!({ "project_id": "g" })).is_ok());
    assert!(plan(&home, ROUTER, json!({ "project_id": "q" })).is_ok());
}

#[test]
fn running_workers_are_capped_by_supervisor_max_children() {
    let home = TestHome::new()
        .with_state("supervisor_max_children", json!(2))
        .worker("w1", true, WorkerOrigin::Created, 1)
        .worker("w2", false, WorkerOrigin::Created, 2)
        // Someone else's Worker never counts against this Router.
        .session("other", true);
    home.mark("other", "router-2", WorkerOrigin::Created, 3);
    assert!(
        plan(&home, ROUTER, json!({})).is_ok(),
        "one running, one stopped"
    );

    let home = home.worker("w3", true, WorkerOrigin::HandedOver, 4);
    let error = plan(&home, ROUTER, json!({})).unwrap_err();
    assert!(
        error.contains("supervisor_max_children") && error.contains("sessions stop"),
        "{error}"
    );
}

#[test]
fn starting_workers_is_rate_limited_from_the_markers() {
    let minute_ago = NOW - 60_000;
    let home = TestHome::new()
        .with_state("supervisor_max_spawns_per_minute", json!(2))
        .worker("old", false, WorkerOrigin::Created, minute_ago)
        .worker("handed", false, WorkerOrigin::HandedOver, NOW - 1)
        .worker("w1", false, WorkerOrigin::Created, NOW - 30_000);
    assert!(
        plan(&home, ROUTER, json!({})).is_ok(),
        "one start this minute"
    );

    let home = home.worker("w2", false, WorkerOrigin::Created, NOW - 10);
    let error = plan(&home, ROUTER, json!({})).unwrap_err();
    assert!(
        error.contains("supervisor_max_spawns_per_minute"),
        "{error}"
    );
}

#[test]
fn a_worktree_worker_runs_in_its_new_worktree_project() {
    let home = TestHome::new();
    let asked = std::cell::RefCell::new(None);
    let make = |args: &Value, project_id: &str| {
        *asked.borrow_mut() = Some((args.clone(), project_id.to_string()));
        Ok(
            json!({ "path": "/wt/fix", "project_id": "mcp-wt-1", "branch": "fix", "adopted": false }),
        )
    };
    let worker = home
        .run(|ctx| {
            plan_create(
                ctx,
                &json!({ "project_id": "g", "worktree": " fix ", "base_ref": "main" }),
                &creator(ROUTER),
                &make,
            )
        })
        .unwrap()
        .unwrap();
    assert_eq!(
        asked.into_inner(),
        Some((
            json!({ "branch": "fix", "base_ref": "main" }),
            "g".to_string()
        ))
    );
    assert_eq!(worker.cwd().as_deref(), Some("/wt/fix"));
    let session = worker.prepare(blank_session("g"));
    assert_eq!(session.project_id, "mcp-wt-1");
    assert_eq!(session.worktree_path.as_deref(), Some("/wt/fix"));
    assert_eq!(session.worktree_branch.as_deref(), Some("fix"));
}

#[test]
fn a_worktree_cannot_be_combined_with_cwd_and_base_ref_needs_one() {
    let home = TestHome::new();
    let error = plan(&home, ROUTER, json!({ "worktree": "fix", "cwd": "/tmp" })).unwrap_err();
    assert!(error.contains("cwd"), "{error}");
    let error = plan(&home, ROUTER, json!({ "base_ref": "main" })).unwrap_err();
    assert!(error.contains("worktree"), "{error}");
}

#[test]
fn a_new_worker_is_marked_and_its_task_queued_in_its_own_inbox() {
    let home = TestHome::new().session("w-new", true);
    let worker = router_plan(
        &home,
        json!({ "task": "login bug", "text": "Fix the login." }),
    );
    let result = home.run(|ctx| {
        worker.record_at(
            ctx,
            "w-new",
            json!({ "session_id": "w-new", "project_id": "p" }),
        )
    });

    assert_eq!(
        home.marker("w-new"),
        Some(WorkerMarker {
            router_id: ROUTER.into(),
            since: NOW,
            origin: WorkerOrigin::Created,
        })
    );
    let pending = home.inbox.list("w-new").unwrap().pending;
    assert_eq!(pending.len(), 1);
    let item = home.inbox.item("w-new", &pending[0].id).unwrap().unwrap();
    // From the Router (never the Host), and it wakes the Worker.
    assert_eq!(item.sender, Sender::Session(ROUTER.into()));
    assert_eq!((item.kind, item.priority), (ItemKind::Task, Priority::Wake));
    assert_eq!(item.summary, "login bug");
    assert_eq!(item.body, "Fix the login.");
    assert_eq!(result["worker"], true);
    assert_eq!(result["task_item_id"], item.id.as_str());
    assert!(result["note"].as_str().unwrap().contains("sessions stop"));
    assert!(result.get("warning").is_none());
}

#[test]
fn a_worker_without_text_gets_nothing_queued() {
    let home = TestHome::new().session("w-new", true);
    let worker = router_plan(&home, json!({}));
    let result = home.run(|ctx| worker.record_at(ctx, "w-new", json!({ "project_id": "p" })));
    assert!(home.marker("w-new").is_some());
    assert!(home.inbox.list("w-new").unwrap().pending.is_empty());
    assert!(result.get("task_item_id").is_none());
}

#[test]
fn the_create_result_names_the_worktree_project() {
    let home = TestHome::new().session("w-new", true);
    let make = |_: &Value, _: &str| {
        Ok(json!({ "path": "/wt/fix", "project_id": "mcp-wt-1", "branch": "fix", "adopted": true }))
    };
    let worker = home
        .run(|ctx| plan_create(ctx, &json!({ "worktree": "fix" }), &creator(ROUTER), &make))
        .unwrap()
        .unwrap();
    let result = home.run(|ctx| worker.record_at(ctx, "w-new", json!({ "project_id": "p" })));
    assert_eq!(result["project_id"], "mcp-wt-1");
    assert_eq!(
        result["worktree"],
        json!({ "branch": "fix", "path": "/wt/fix", "adopted": true })
    );
}

#[test]
fn a_worktree_the_router_creates_is_recorded_for_cleanup() {
    let home = TestHome::new().session("w-new", true);
    let make = |_: &Value, _: &str| {
        Ok(json!({
            "path": "/wt/fix", "project_id": "mcp-wt-1", "branch": "fix",
            "adopted": false, "repo_path": "/work/p",
        }))
    };
    let worker = home
        .run(|ctx| {
            plan_create(
                ctx,
                &json!({ "worktree": "fix", "base_ref": "main" }),
                &creator(ROUTER),
                &make,
            )
        })
        .unwrap()
        .unwrap();
    let result = home.run(|ctx| worker.record_at(ctx, "w-new", json!({ "project_id": "p" })));

    assert!(result.get("warning").is_none(), "{result}");
    assert_eq!(
        home.worktrees.entries().unwrap(),
        vec![crate::supervision_worktrees::Entry {
            path: "/wt/fix".into(),
            branch: "fix".into(),
            base_ref: Some("main".into()),
            repo_path: "/work/p".into(),
            project_id: "mcp-wt-1".into(),
            owner_session_id: "w-new".into(),
            created_at: NOW,
        }]
    );
}

#[test]
fn a_failed_marker_write_is_reported_not_hidden() {
    let home = TestHome::new();
    let worker = router_plan(&home, json!({ "text": "go" }));
    // No session dir: the marker can't be written.
    let result = home.run(|ctx| worker.record_at(ctx, "gone", json!({})));
    assert!(
        result["warning"].as_str().unwrap().contains("Worker"),
        "{result}"
    );
    assert!(result.get("worker").is_none());
}
