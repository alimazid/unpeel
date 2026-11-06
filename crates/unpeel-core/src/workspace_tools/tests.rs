//! Fork-only: unit tests for `workspace_tools`, against a temp app-state
//! file and a temp git repo, never the real home.

use super::*;

fn workspace() -> Value {
    json!({
        "projects": [
            { "id": "q", "name": "Q", "path": "/work/q", "parent_project_id": "folder", "sort_order": 1 },
            { "id": "wt", "name": "feature", "path": "/work/wt", "parent_project_id": "p", "worktree_branch": "feature", "sort_order": 2 },
            { "id": "folder", "name": "Clients", "path": "", "is_folder": true, "sort_order": 2 },
            { "id": "g", "name": "Docs", "path": "/stale", "parent_project_id": "p", "is_folder": true, "sort_order": 1 },
            { "id": "p", "name": "P", "path": "/work/p", "sort_order": 0 },
            { "id": "sidebar-p", "name": "Sidebar", "path": "/work/p", "parent_project_id": "p", "is_folder": true, "sort_order": 0 },
            { "id": "wt-g", "name": "In wt", "path": "", "parent_project_id": "wt", "is_folder": true },
            { "id": "loop-a", "name": "A", "path": "", "parent_project_id": "loop-b", "is_folder": true },
            { "id": "loop-b", "name": "B", "path": "", "parent_project_id": "loop-a", "is_folder": true },
            "junk",
        ]
    })
}

fn preset_ids(state: &Value, project_id: &str) -> Vec<String> {
    usable_presets(state, project_id)
        .into_iter()
        .map(|preset| preset.id)
        .collect()
}

#[test]
fn usable_presets_are_enabled_global_or_this_projects_scoped_first() {
    let state = json!({
        "presets": [
            { "id": "claude", "label": "Claude", "command": "claude", "project_id": null },
            { "id": "off", "label": "Off", "command": "x", "project_id": null, "enabled": false },
            { "id": "other", "label": "Other", "command": "y", "project_id": "q" },
            { "id": "mine", "label": "Claude", "command": "claude --mine", "project_id": "p" },
            { "id": "codex", "label": "Codex", "command": "codex", "project_id": null },
        ]
    });
    assert_eq!(preset_ids(&state, "p"), ["mine", "claude", "codex"]);
    assert_eq!(preset_ids(&state, "q"), ["other", "claude", "codex"]);
    assert_eq!(preset_ids(&json!({}), "p"), Vec::<String>::new());
    assert_eq!(
        preset_ids(&json!({ "presets": "junk" }), "p"),
        Vec::<String>::new()
    );
}

#[test]
fn a_group_or_worktree_uses_its_root_projects_presets() {
    let mut state = workspace();
    state["presets"] = json!([
        { "id": "global", "label": "Claude", "command": "claude", "project_id": null },
        { "id": "root", "label": "Tests", "command": "cargo test", "project_id": "p" },
        { "id": "other", "label": "Other", "command": "y", "project_id": "q" },
    ]);
    assert_eq!(preset_ids(&state, "g"), ["root", "global"]);
    assert_eq!(preset_ids(&state, "wt"), ["root", "global"]);
    assert_eq!(preset_ids(&state, "wt-g"), ["root", "global"]);
    // A root is its own root; an unknown id keeps the exact match only.
    assert_eq!(preset_ids(&state, "p"), ["root", "global"]);
    assert_eq!(preset_ids(&state, "desktop-owned"), ["global"]);
}

#[test]
fn the_preset_listing_names_each_presets_launch_fields() {
    let state = json!({
        "presets": [
            { "id": "claude", "label": "Claude", "command": "claude", "project_id": null, "quick_launch": true },
            { "id": "mine", "label": "Tests", "command": "cargo test", "project_id": "p" },
        ]
    });
    assert_eq!(
        preset_listing(&state, "p"),
        json!({
            "project_id": "p",
            "presets": [
                { "id": "mine", "label": "Tests", "command": "cargo test", "project_id": "p", "quick_launch": false, "agent_preset": false },
                { "id": "claude", "label": "Claude", "command": "claude", "project_id": null, "quick_launch": true, "agent_preset": true },
            ]
        })
    );
}

#[test]
fn list_projects_returns_roots_with_their_groups_and_worktrees() {
    assert_eq!(
        project_listing(&workspace()),
        json!({
            "projects": [
                { "id": "p", "name": "P", "path": "/work/p", "kind": "root", "sidebar": false },
                { "id": "sidebar-p", "name": "Sidebar", "path": "/work/p", "kind": "group", "parent_id": "p", "sidebar": true },
                // A group runs in its checkout's folder, whatever path it stores.
                { "id": "g", "name": "Docs", "path": "/work/p", "kind": "group", "parent_id": "p", "sidebar": false },
                { "id": "wt", "name": "feature", "path": "/work/wt", "kind": "worktree", "parent_id": "p", "worktree_branch": "feature", "sidebar": false },
                { "id": "wt-g", "name": "In wt", "path": "/work/wt", "kind": "group", "parent_id": "wt", "sidebar": false },
                // A root filed in a sidebar folder is still a root; the
                // folder is not a Project, and a cyclic pair has no root.
                { "id": "q", "name": "Q", "path": "/work/q", "kind": "root", "sidebar": false },
            ]
        })
    );
    assert_eq!(project_listing(&json!({})), json!({ "projects": [] }));
}

fn git(dir: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .expect("git runs");
    assert!(
        status.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&status.stderr)
    );
}

/// A temp workspace: a git repo with one commit as root Project `p`,
/// a group `g` under it, and the app-state file naming them.
struct Fixture {
    dir: tempfile::TempDir,
    repo: std::path::PathBuf,
    state: std::path::PathBuf,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().expect("tempdir");
    let repo = dir.path().join("repo");
    std::fs::create_dir_all(&repo).expect("repo dir");
    git(&repo, &["init", "--quiet", "-b", "main"]);
    git(&repo, &["commit", "--quiet", "--allow-empty", "-m", "init"]);
    let state = dir.path().join("app-state.json");
    let document = json!({
        "projects": [
            { "id": "p", "name": "P", "path": repo, "workspace_id": "w1" },
            { "id": "g", "name": "G", "path": "", "parent_project_id": "p", "is_folder": true, "sort_order": 4 },
        ],
        "presets": [],
        "desktop_only_key": { "kept": true },
    });
    std::fs::write(&state, document.to_string()).expect("state");
    Fixture { dir, repo, state }
}

impl Fixture {
    /// `git worktree add` into this fixture's own folder, named like
    /// `worktrees::create_in_folder` names it (which writes under the real
    /// home).
    fn make(&self) -> impl FnOnce(&str, &str, Option<&str>, &str) -> Result<Worktree, String> + '_ {
        move |repo, branch, _base, folder| {
            let path = self
                .dir
                .path()
                .join("wts")
                .join(crate::worktrees::slug(folder));
            let path_str = path.to_string_lossy().to_string();
            git(
                Path::new(repo),
                &["worktree", "add", "--quiet", "-b", branch, &path_str],
            );
            Ok(Worktree {
                path: path_str,
                branch: Some(branch.into()),
                managed: false,
            })
        }
    }

    fn state(&self) -> Value {
        serde_json::from_slice(&std::fs::read(&self.state).expect("read")).expect("json")
    }

    fn worktree_children(&self) -> Vec<Value> {
        self.state()["projects"]
            .as_array()
            .expect("projects")
            .iter()
            .filter(|row| row.get("worktree_branch").is_some())
            .cloned()
            .collect()
    }
}

fn request(branch: &str) -> WorktreeRequest {
    WorktreeRequest {
        branch: branch.into(),
        name: None,
        base_ref: None,
    }
}

#[test]
fn create_worktree_registers_a_child_project_once_and_then_adopts_it() {
    let fx = fixture();
    // A group resolves to the checkout it sits in.
    let first = create_worktree_at(
        StateFile::At(&fx.state),
        "g",
        &request("feature"),
        fx.make(),
    )
    .expect("created");
    assert_eq!(first["adopted"], false);
    assert_eq!(first["branch"], "feature");
    // The checkout it belongs to, for the Super Agent's cleanup ledger.
    assert_eq!(first["repo_path"], json!(fx.repo));
    let path = first["path"].as_str().expect("path").to_string();
    assert!(
        Path::new(&path).join(".git").exists(),
        "{path} is a checkout"
    );
    let child_id = first["project_id"].as_str().expect("id").to_string();
    assert!(child_id.starts_with("mcp-wt-"), "{child_id}");

    let children = fx.worktree_children();
    assert_eq!(children.len(), 1);
    let child = &children[0];
    assert_eq!(child["id"], child_id.as_str());
    assert_eq!(child["name"], "feature");
    assert_eq!(child["path"], path.as_str());
    assert_eq!(child["parent_project_id"], "p");
    assert_eq!(child["worktree_branch"], "feature");
    assert_eq!(child["workspace_id"], "w1");
    assert_eq!(child["sort_order"], 5, "after its last sibling");
    assert_eq!(fx.state()["desktop_only_key"]["kept"], true);

    let never = |_: &str, _: &str, _: Option<&str>, _: &str| -> Result<Worktree, String> {
        panic!("an adopted worktree runs no git")
    };
    let again = create_worktree_at(StateFile::At(&fx.state), "p", &request("feature"), never)
        .expect("adopted");
    assert_eq!(again["adopted"], true);
    assert_eq!(again["project_id"], child_id.as_str());
    assert_eq!(again["path"], path.as_str());
    assert_eq!(fx.worktree_children().len(), 1, "registered once");
}

#[test]
fn the_name_picks_the_worktree_folder_and_both_default_to_the_branch() {
    let fx = fixture();
    // Upstream's meaning: `name` is the worktree's folder (as the Mac app
    // names it, also its sidebar row); without it both follow the branch.
    let named = WorktreeRequest {
        name: Some("Login Fix".into()),
        ..request("feature/login")
    };
    let created =
        create_worktree_at(StateFile::At(&fx.state), "p", &named, fx.make()).expect("created");
    let path = created["path"].as_str().expect("path");
    assert!(path.ends_with("/wts/login-fix"), "{path}");
    let plain = create_worktree_at(
        StateFile::At(&fx.state),
        "p",
        &request("feature/docs"),
        fx.make(),
    )
    .expect("created");
    let path = plain["path"].as_str().expect("path");
    assert!(path.ends_with("/wts/feature-docs"), "{path}");
    let names: Vec<(String, String)> = fx
        .worktree_children()
        .iter()
        .map(|child| {
            (
                child["worktree_branch"].as_str().unwrap_or_default().into(),
                child["name"].as_str().unwrap_or_default().into(),
            )
        })
        .collect();
    assert_eq!(
        names,
        [
            ("feature/login".to_owned(), "Login Fix".to_owned()),
            ("feature/docs".to_owned(), "feature/docs".to_owned()),
        ]
    );
}

#[test]
fn create_worktree_adopts_an_unregistered_worktree_already_on_the_branch() {
    let fx = fixture();
    let by_hand = fx.dir.path().join("by-hand");
    let by_hand_str = by_hand.to_string_lossy().to_string();
    git(
        &fx.repo,
        &["worktree", "add", "--quiet", "-b", "manual", &by_hand_str],
    );
    let never = |_: &str, _: &str, _: Option<&str>, _: &str| -> Result<Worktree, String> {
        panic!("an existing worktree is adopted, not re-added")
    };
    let adopted = create_worktree_at(StateFile::At(&fx.state), "p", &request("manual"), never)
        .expect("adopted");
    assert_eq!(adopted["adopted"], true);
    let path = adopted["path"].as_str().unwrap_or_default();
    assert!(same_path(path, &by_hand_str), "{path}");
    assert_eq!(fx.worktree_children().len(), 1);
}

fn by_branch<'a>(listing: &'a Value, branch: &str) -> Option<&'a Value> {
    listing["worktrees"]
        .as_array()?
        .iter()
        .find(|row| row["branch"] == branch)
}

#[test]
fn list_worktrees_merges_git_with_the_registered_child_projects() {
    let fx = fixture();
    let created = create_worktree_at(
        StateFile::At(&fx.state),
        "p",
        &request("feature"),
        fx.make(),
    )
    .expect("created");
    // A registration whose folder is gone stays listed, marked missing.
    let stale = fx.dir.path().join("gone");
    crate::app_state::edit_at(&fx.state, |state| {
        register_worktree(state, "p", "old", &stale.to_string_lossy(), "Old")
    })
    .expect("registered");

    let listing = worktree_listing_at(StateFile::At(&fx.state), "g").expect("listed");
    assert_eq!(listing["project_id"], "p");
    let main = by_branch(&listing, "main").expect("main checkout");
    assert_eq!(main["project_id"], "p");
    assert_eq!(main["main"], true);
    let feature = by_branch(&listing, "feature").expect("the new worktree");
    assert_eq!(feature["project_id"], created["project_id"]);
    assert_eq!(feature["name"], "feature");
    assert!(feature.get("missing").is_none());
    let old = by_branch(&listing, "old").expect("the stale registration");
    assert_eq!(old["missing"], true);
    assert_eq!(old["name"], "Old");
    assert_eq!(listing["worktrees"].as_array().map(Vec::len), Some(3));
}

#[test]
fn create_worktree_refuses_an_unknown_project_or_a_flag_shaped_branch() {
    let fx = fixture();
    let never = |_: &str, _: &str, _: Option<&str>, _: &str| -> Result<Worktree, String> {
        panic!("refused before git")
    };
    let unknown = create_worktree_at(StateFile::At(&fx.state), "nope", &request("x"), never)
        .expect_err("unknown project");
    assert!(unknown.contains("list_projects"), "{unknown}");

    for (args, wanted) in [
        (json!({}), "branch"),
        (json!({ "branch": "   " }), "branch"),
        (json!({ "branch": "-D" }), "'-'"),
        (json!({ "branch": "a\u{1b}b" }), "control"),
    ] {
        let error = WorktreeRequest::from_args(&args).err().unwrap_or_default();
        assert!(error.contains(wanted), "{args}: {error}");
    }
    let parsed = WorktreeRequest::from_args(&json!({
        "branch": " feature/x ",
        "name": "  My\u{7} tree  ",
        "base_ref": "  ",
    }))
    .expect("valid");
    assert_eq!(parsed.branch, "feature/x");
    assert_eq!(parsed.name.as_deref(), Some("My tree"));
    assert_eq!(parsed.base_ref, None);
    let long = WorktreeRequest::from_args(&json!({ "branch": "b", "name": "n".repeat(500) }))
        .expect("valid");
    assert_eq!(
        long.name.map(|name| name.chars().count()),
        Some(MAX_NAME_CHARS)
    );
}
