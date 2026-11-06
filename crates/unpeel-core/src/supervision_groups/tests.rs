//! Fork-only: unit tests for `supervision_groups`, against a temp home
//! (app-state, session dirs, project order), never the real one.

use super::*;

const ROUTER: &str = "router";

/// A private home: an app-state file with a Router mark and a few
/// Projects, and an `app-sessions` root. Never the real `UNPEEL_HOME`.
fn with_home<T>(body: impl FnOnce(&Home) -> T) -> T {
    let root = std::env::temp_dir().join(format!("sa-groups-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(root.join("app-sessions")).unwrap();
    let state = json!({
        "super_agent": { "session_id": ROUTER, "since": 1 },
        "projects": [
            { "id": "p", "name": "P", "path": "/work/p", "workspace_id": "ws", "sort_order": 0 },
            { "id": "sidebar-p", "name": "Sidebar", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 0, "pinned_at": 5 },
            { "id": "sa-g", "name": "Docs", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 1 },
            { "id": "wt", "name": "feature", "path": "/work/wt", "parent_project_id": "p", "worktree_branch": "feature", "sort_order": 2 },
            { "id": "q", "name": "Q", "path": "/work/q", "sort_order": 1 },
            // A group the Mac app keeps in its own records.
            { "id": "native-1", "name": "Mine", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 3 },
            // Groups other frontends and migrations made: never the Router's.
            { "id": "legacy-pinned-p", "name": "Pinned", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 4 },
            { "id": "tui-1", "name": "TUI", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 5 },
            { "id": "host-1", "name": "Host", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 6 },
        ]
    });
    std::fs::write(root.join("app-state.json"), state.to_string()).unwrap();
    let outcome = body(&Home::at(&root));
    let _ = std::fs::remove_dir_all(&root);
    outcome
}

fn project<'a>(state: &'a Value, id: &str) -> Option<&'a Value> {
    state["projects"]
        .as_array()?
        .iter()
        .find(|row| row["id"] == id)
}

#[test]
fn the_router_creates_a_group_at_the_top_of_a_project() {
    with_home(|home| {
        let created = create_group_at(
            home,
            Some(ROUTER),
            &json!({ "project_id": "p", "name": "  Research " }),
        )
        .unwrap();
        let id = created["project_id"].as_str().unwrap().to_string();
        assert!(id.starts_with("sa-"), "{id}");
        assert_eq!(created["name"], "Research");
        assert_eq!(created["parent_id"], "p");
        assert_eq!(created["path"], "/work/p");

        let state = home.state().unwrap();
        assert_eq!(
            project(&state, &id).unwrap(),
            &json!({
                "id": id, "name": "Research", "path": "/work/p", "parent_project_id": "p",
                "sort_order": 0, "is_folder": true, "workspace_id": "ws",
            })
        );
        // Its siblings move down one; other Projects keep their place.
        assert_eq!(project(&state, "sidebar-p").unwrap()["sort_order"], 1);
        assert_eq!(project(&state, "sa-g").unwrap()["sort_order"], 2);
        assert_eq!(project(&state, "wt").unwrap()["sort_order"], 3);
        assert_eq!(project(&state, "q").unwrap()["sort_order"], 1);
        // Unmodelled fields pass through.
        assert_eq!(project(&state, "sidebar-p").unwrap()["pinned_at"], 5);
    });
}

#[test]
fn a_group_is_always_created_under_its_root_project() {
    with_home(|home| {
        for inside in ["sa-g", "wt", " p "] {
            let created = create_group_at(
                home,
                Some(ROUTER),
                &json!({ "project_id": inside, "name": "Inside" }),
            )
            .unwrap();
            assert_eq!(created["parent_id"], "p", "{inside}");
            assert_eq!(created["path"], "/work/p", "{inside}");
        }
    });
}

#[test]
fn creating_needs_a_known_project_and_a_name() {
    with_home(|home| {
        let before = std::fs::read(home.state_path()).unwrap();
        for (args, wanted) in [
            (json!({ "name": "X" }), "'project_id'"),
            (
                json!({ "project_id": "nope", "name": "X" }),
                "list_projects",
            ),
            (json!({ "project_id": "p" }), "'name'"),
            (json!({ "project_id": "p", "name": " \u{7} " }), "'name'"),
        ] {
            let error = create_group_at(home, Some(ROUTER), &args).unwrap_err();
            assert!(error.contains(wanted), "{args}: {error}");
        }
        assert_eq!(std::fs::read(home.state_path()).unwrap(), before);

        let long = "n".repeat(200);
        let created = create_group_at(
            home,
            Some(ROUTER),
            &json!({ "project_id": "q", "name": format!("a\u{1b}b{long}") }),
        )
        .unwrap();
        let name = created["name"].as_str().unwrap();
        assert!(
            name.starts_with("abn") && name.chars().count() == 80,
            "{name}"
        );
    });
}

#[test]
fn the_router_renames_a_group() {
    with_home(|home| {
        let renamed = rename_group_at(
            home,
            Some(ROUTER),
            &json!({ "project_id": "sa-g", "name": " Specs " }),
        )
        .unwrap();
        assert_eq!(renamed, json!({ "project_id": "sa-g", "name": "Specs" }));
        let state = home.state().unwrap();
        assert_eq!(project(&state, "sa-g").unwrap()["name"], "Specs");
        assert_eq!(project(&state, "sa-g").unwrap()["sort_order"], 1);
    });
}

#[test]
fn only_groups_the_router_created_are_renamed() {
    with_home(|home| {
        let before = std::fs::read(home.state_path()).unwrap();
        for (project_id, wanted) in [
            ("sidebar-p", "Sidebar group"),
            ("p", "not a group"),
            ("wt", "not a group"),
            ("nope", "Unknown group"),
            ("native-1", "Mac app"),
            ("legacy-pinned-p", "only groups you created"),
            ("tui-1", "only groups you created"),
            ("host-1", "only groups you created"),
        ] {
            let error = rename_group_at(
                home,
                Some(ROUTER),
                &json!({ "project_id": project_id, "name": "X" }),
            )
            .unwrap_err();
            assert!(error.contains(wanted), "{project_id}: {error}");
        }
        assert_eq!(std::fs::read(home.state_path()).unwrap(), before);
    });
}

/// A session dir launched in `project_id`, optionally filed elsewhere.
fn session(home: &Home, id: &str, project_id: &str, filed_in: Option<&str>) -> PathBuf {
    let dir = home.sessions_root().join(id);
    std::fs::create_dir_all(&dir).unwrap();
    let manifest = json!({ "session": { "id": id, "project_id": project_id } });
    std::fs::write(dir.join("manifest.json"), manifest.to_string()).unwrap();
    if let Some(group) = filed_in {
        let marker = json!({ "project_id": group, "moved_at": 1 });
        std::fs::write(dir.join("project-override.json"), marker.to_string()).unwrap();
    }
    dir
}

fn order_path(home: &Home) -> PathBuf {
    home.root.join("project-order.json")
}

fn remove(home: &Home, project_id: &str) -> Result<Value, String> {
    remove_group_at(home, Some(ROUTER), &json!({ "project_id": project_id }))
}

#[test]
fn the_router_removes_an_empty_group() {
    with_home(|home| {
        std::fs::write(order_path(home), r#"["p","sidebar-p","sa-g","wt","q"]"#).unwrap();
        // Sessions elsewhere don't keep it.
        session(home, "s1", "p", None);
        session(home, "s2", "p", Some("sidebar-p"));

        let removed = remove(home, "sa-g").unwrap();
        assert_eq!(removed["project_id"], "sa-g");
        assert_eq!(removed["removed"], true);

        let state = home.state().unwrap();
        assert!(project(&state, "sa-g").is_none());
        // Later siblings close the gap; earlier ones and other roots stay.
        assert_eq!(project(&state, "sidebar-p").unwrap()["sort_order"], 0);
        assert_eq!(project(&state, "wt").unwrap()["sort_order"], 1);
        assert_eq!(project(&state, "native-1").unwrap()["sort_order"], 2);
        assert_eq!(project(&state, "q").unwrap()["sort_order"], 1);
        let order: Vec<String> =
            serde_json::from_slice(&std::fs::read(order_path(home)).unwrap()).unwrap();
        assert_eq!(order, ["p", "sidebar-p", "wt", "q"]);
    });
}

#[test]
fn removing_writes_no_project_order_when_there_is_none() {
    with_home(|home| {
        remove(home, "sa-g").unwrap();
        assert!(!order_path(home).exists());
    });
}

#[test]
fn a_group_with_sessions_or_children_is_not_removed() {
    with_home(|home| {
        // A stopped or running session launched in it, or one filed into it.
        let launched = session(home, "s1", "sa-g", None);
        let before = std::fs::read(home.state_path()).unwrap();
        let error = remove(home, "sa-g").unwrap_err();
        assert!(error.contains("not empty"), "{error}");
        std::fs::remove_dir_all(launched).unwrap();

        session(home, "s2", "p", Some("sa-g"));
        let error = remove(home, "sa-g").unwrap_err();
        assert!(error.contains("not empty"), "{error}");
        assert_eq!(std::fs::read(home.state_path()).unwrap(), before);
    });
}

#[test]
fn a_group_holding_other_projects_is_not_removed() {
    with_home(|home| {
        home.edit_state(|state| {
            project_rows(state)?.push(json!({
                "id": "inner", "name": "Inner", "path": "", "parent_project_id": "sa-g", "is_folder": true,
            }));
            Ok(())
        })
        .unwrap();
        let error = remove(home, "sa-g").unwrap_err();
        assert!(error.contains("holds"), "{error}");
        assert!(project(&home.state().unwrap(), "sa-g").is_some());
    });
}

#[test]
fn only_empty_groups_the_router_created_are_removed() {
    with_home(|home| {
        std::fs::write(order_path(home), r#"["p","sidebar-p","sa-g"]"#).unwrap();
        let before = std::fs::read(home.state_path()).unwrap();
        for (project_id, wanted) in [
            ("sidebar-p", "Sidebar group"),
            ("p", "not a group"),
            ("wt", "not a group"),
            ("nope", "Unknown group"),
            ("native-1", "Mac app"),
            // Empty, but made by another frontend or a migration.
            ("legacy-pinned-p", "only groups you created"),
            ("tui-1", "only groups you created"),
            ("host-1", "only groups you created"),
        ] {
            let error = remove(home, project_id).unwrap_err();
            assert!(error.contains(wanted), "{project_id}: {error}");
        }
        assert_eq!(std::fs::read(home.state_path()).unwrap(), before);
        assert_eq!(
            std::fs::read_to_string(order_path(home)).unwrap(),
            r#"["p","sidebar-p","sa-g"]"#
        );
    });
}

/// `session` with a Worker marker for `router_id`.
fn worker(home: &Home, id: &str, router_id: &str, project_id: &str) -> PathBuf {
    let dir = session(home, id, project_id, None);
    let marker = crate::supervision::WorkerMarker {
        router_id: router_id.into(),
        since: 1,
        origin: crate::supervision::WorkerOrigin::Created,
    };
    crate::supervision::write_worker_marker_in(&dir, &marker).unwrap();
    dir
}

fn move_to(home: &Home, session_id: &str, project_id: &str) -> Result<Value, String> {
    move_session_at(
        home,
        Some(ROUTER),
        &json!({ "session_id": session_id, "project_id": project_id }),
    )
}

#[test]
fn the_router_files_its_worker_into_a_group_and_back() {
    with_home(|home| {
        let dir = worker(home, "w1", ROUTER, "p");
        let moved = move_to(home, "w1", "sa-g").unwrap();
        assert_eq!(moved, json!({ "session_id": "w1", "project_id": "sa-g" }));
        assert_eq!(filed_project(&dir).as_deref(), Some("sa-g"));
        // The launch manifest is never rewritten.
        assert_eq!(manifest_project(&dir).as_deref(), Some("p"));

        // Back to the Project it was started in: the marker goes.
        move_to(home, "w1", "p").unwrap();
        assert!(!dir.join("project-override.json").exists());
        assert_eq!(sessions_in_group(&home.sessions_root(), "sa-g"), 0);
    });
}

#[test]
fn a_worker_is_filed_into_any_group_not_only_the_routers() {
    with_home(|home| {
        let dir = worker(home, "w1", ROUTER, "p");
        for group in ["tui-1", "legacy-pinned-p", "native-1"] {
            move_to(home, "w1", group).unwrap();
            assert_eq!(filed_project(&dir).as_deref(), Some(group));
        }
    });
}

#[test]
fn a_worker_started_in_a_group_moves_to_its_root_or_a_sibling() {
    with_home(|home| {
        let group = create_group_at(
            home,
            Some(ROUTER),
            &json!({ "project_id": "p", "name": "A" }),
        )
        .unwrap();
        let dir = worker(home, "w1", ROUTER, "sa-g");
        move_to(home, "w1", "p").unwrap();
        assert_eq!(filed_project(&dir).as_deref(), Some("p"));
        let sibling = group["project_id"].as_str().unwrap();
        move_to(home, "w1", sibling).unwrap();
        assert_eq!(filed_project(&dir).as_deref(), Some(sibling));
    });
}

#[test]
fn only_the_routers_own_workers_are_moved() {
    with_home(|home| {
        let users = session(home, "mine", "p", None);
        let others = worker(home, "theirs", "another-router", "p");
        session(home, ROUTER, "p", None);
        for (session_id, wanted) in [
            ("mine", "not one of your Workers"),
            ("theirs", "not one of your Workers"),
            (ROUTER, "not one of your Workers"),
            ("gone", "Unknown session"),
            ("../mine", "not a session id"),
        ] {
            let error = move_to(home, session_id, "sa-g").unwrap_err();
            assert!(error.contains(wanted), "{session_id}: {error}");
        }
        for dir in [users, others] {
            assert!(!dir.join("project-override.json").exists());
        }
    });
}

#[test]
fn a_worker_stays_inside_its_own_checkout() {
    with_home(|home| {
        let dir = worker(home, "w1", ROUTER, "p");
        let in_worktree = worker(home, "w2", ROUTER, "wt");
        for (session_id, target, wanted) in [
            ("w1", "nope", "unknown target project"),
            ("w1", "q", "outside the session's project"),
            ("w1", "wt", "outside the session's project"),
            ("w1", "sidebar-p", "Sidebar group"),
            ("w2", "sa-g", "worktree"),
        ] {
            let error = move_to(home, session_id, target).unwrap_err();
            assert!(error.contains(wanted), "{session_id} → {target}: {error}");
        }
        for dir in [dir, in_worktree] {
            assert!(!dir.join("project-override.json").exists());
        }
    });
}

#[test]
fn the_workspace_tool_advertises_and_documents_the_group_actions() {
    let base = json!({
        "name": "workspace",
        "inputSchema": { "type": "object", "properties": {
            "action": { "type": "string" },
            "project_id": { "type": "string" },
            "name": { "type": "string", "description": "create_worktree: folder name" },
        } }
    });
    let schema = crate::supervision_mcp::extend_schema("workspace", base);
    let properties = &schema["inputSchema"]["properties"];
    assert_eq!(properties["session_id"]["type"], "string");
    assert!(properties["name"]["description"]
        .as_str()
        .unwrap()
        .contains("create_group"));
    assert_eq!(properties["project_id"]["type"], "string");

    let docs = crate::supervision_mcp::help_docs("workspace");
    let actions: Vec<&str> = docs.iter().map(|(action, _)| action.as_str()).collect();
    assert_eq!(
        actions,
        [
            "list_projects",
            "create_group",
            "rename_group",
            "remove_group",
            "move_session"
        ]
    );
    for (action, doc) in &docs {
        assert!(
            doc["description"]
                .as_str()
                .is_some_and(|text| !text.is_empty()),
            "{action}"
        );
    }
    let names: Vec<&str> = crate::supervision_mcp::workspace_action_names().collect();
    assert_eq!(names, actions);
}

type Action = fn(&Home, Option<&str>, &Value) -> Result<Value, String>;

#[test]
fn only_the_router_manages_groups_and_moves_workers() {
    with_home(|home| {
        let dir = worker(home, "w1", ROUTER, "p");
        let calls: [(Action, Value); 4] = [
            (create_group_at, json!({ "project_id": "p", "name": "X" })),
            (
                rename_group_at,
                json!({ "project_id": "sa-g", "name": "X" }),
            ),
            (remove_group_at, json!({ "project_id": "sa-g" })),
            (
                move_session_at,
                json!({ "session_id": "w1", "project_id": "sa-g" }),
            ),
        ];
        let refuse_all = |callers: &[Option<&str>]| {
            let before = std::fs::read(home.state_path()).unwrap();
            for (run, args) in &calls {
                for caller in callers {
                    let error = run(home, *caller, args).unwrap_err();
                    assert!(error.contains("Super Agent"), "{caller:?} {args}: {error}");
                }
            }
            assert_eq!(std::fs::read(home.state_path()).unwrap(), before);
            assert!(!dir.join("project-override.json").exists());
        };
        refuse_all(&[None, Some("w1"), Some("someone"), Some("")]);

        // Once the user clears the mark, the former Router is refused too.
        home.edit_state(|state| Ok(crate::supervision::clear_router_mark_in(state)))
            .unwrap();
        refuse_all(&[Some(ROUTER)]);
    });
}
