//! Fork-only: the Router's sidebar groups (§16.2). `workspace create_group`,
//! `rename_group` and `remove_group` manage plain groups in any Project of
//! this workspace; `move_session` files one of the Router's own Workers
//! into another group. Only the Router may call them.

use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use crate::state::Project;

/// `workspace create_group {project_id, name}`.
pub(crate) fn tool_create_group(args: &Value) -> Result<String, String> {
    run(create_group_at, args)
}

/// `workspace rename_group {project_id, name}`.
pub(crate) fn tool_rename_group(args: &Value) -> Result<String, String> {
    run(rename_group_at, args)
}

/// `workspace remove_group {project_id}`.
pub(crate) fn tool_remove_group(args: &Value) -> Result<String, String> {
    run(remove_group_at, args)
}

/// `workspace move_session {session_id, project_id}`.
pub(crate) fn tool_move_session(args: &Value) -> Result<String, String> {
    run(move_session_at, args)
}

/// One action against this workspace's home, for the calling Session.
fn run(
    action: fn(&Home, Option<&str>, &Value) -> Result<Value, String>,
    args: &Value,
) -> Result<String, String> {
    let caller = crate::mcp_host::self_session_id();
    render(&action(&Home::shared(), caller.as_deref(), args)?)
}

/// The `workspace` schema properties these actions add or share.
pub(crate) fn schema_properties() -> Vec<(&'static str, Value)> {
    vec![
        (
            "name",
            json!({ "type": "string", "description": "create_worktree: folder; create_group/rename_group: group; *_schedule: task name" }),
        ),
        (
            "session_id",
            json!({ "type": "string", "description": "move_session: your Worker" }),
        ),
    ]
}

/// `action: "help"` sections for these actions.
pub(crate) fn help_docs() -> Vec<(String, Value)> {
    let project = |text: &str| json!({ "type": "string", "description": text });
    let doc = |description: &str, properties: Value, required: &[&str]| {
        json!({
            "description": description,
            "inputSchema": { "type": "object", "properties": properties, "required": required },
        })
    };
    vec![
        (
            "create_group".into(),
            doc(
                "Super Agent only. Add a sidebar group at the top of a Project: {project_id, name, \
        parent_id, path}. A group or worktree id adds it under that id's root Project. Start a Worker \
        straight in it with sessions create project_id=<the new id>; it runs in the root's folder. \
        Groups only organize the sidebar.",
                json!({
                    "project_id": project("Project to add it to (workspace list_projects)"),
                    "name": project("Group name, at most 80 characters"),
                }),
                &["project_id", "name"],
            ),
        ),
        (
            "rename_group".into(),
            doc(
                "Super Agent only. Rename a sidebar group you created with create_group (id \
        sa-…): {project_id, name}. Any other group, a Project or a worktree: ask the user.",
                json!({
                    "project_id": project("The group (workspace list_projects)"),
                    "name": project("New name, at most 80 characters"),
                }),
                &["project_id", "name"],
            ),
        ),
        (
            "remove_group".into(),
            doc(
                "Super Agent only. Remove an empty sidebar group you created with create_group (id \
        sa-…): {project_id, name, removed}. Refused while any Session, stopped ones included, was \
        started in or moved into it, and while it holds other groups. Move your Workers out first \
        with move_session.",
                json!({ "project_id": project("The group (workspace list_projects)") }),
                &["project_id"],
            ),
        ),
        (
            "move_session".into(),
            doc(
                "Super Agent only. File one of your Workers, running or stopped, under another group: \
        {session_id, project_id}. The target stays inside the Worker's own checkout: its root Project \
        (or worktree) or a group directly under it, never the Sidebar group; the Project it was started \
        in puts it back. Only the sidebar changes: the Worker keeps running in its folder.",
                json!({
                    "session_id": project("Your Worker (sessions current lists them)"),
                    "project_id": project("Target group or Project (workspace list_projects)"),
                }),
                &["session_id", "project_id"],
            ),
        ),
    ]
}

fn render(value: &Value) -> Result<String, String> {
    serde_json::to_string_pretty(value).map_err(|error| format!("Failed to render: {error}"))
}

/// Where one call reads and writes: this workspace's home, whose writes
/// announce on the state bus, or a temp dir in tests.
struct Home {
    root: PathBuf,
    shared: bool,
}

impl Home {
    fn shared() -> Self {
        Self {
            root: crate::app_paths::unpeel_home(),
            shared: true,
        }
    }

    #[cfg(test)]
    fn at(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
            shared: false,
        }
    }

    fn state_path(&self) -> PathBuf {
        self.root.join("app-state.json")
    }

    fn state(&self) -> Result<Value, String> {
        crate::app_state::load_for_edit_at(&self.state_path())
    }

    fn sessions_root(&self) -> PathBuf {
        self.root.join("app-sessions")
    }

    /// Drop `project_id` from `project-order.json` under its lock, like
    /// `session_ops::set_project_order`. No file: nothing to prune.
    fn prune_project_order(&self, project_id: &str) -> Result<(), String> {
        let path = self.root.join("project-order.json");
        let _lock = crate::app_state::lock_exclusive(&path)?;
        let Ok(raw) = std::fs::read(&path) else {
            return Ok(());
        };
        let Ok(order) = serde_json::from_slice::<Vec<Value>>(&raw) else {
            // Not ours to repair; bootstrap ignores a broken order.
            return Ok(());
        };
        let kept: Vec<&Value> = order
            .iter()
            .filter(|id| id.as_str() != Some(project_id))
            .collect();
        if kept.len() == order.len() {
            return Ok(());
        }
        let body = serde_json::to_string_pretty(&kept).map_err(|error| error.to_string())?;
        crate::hook_assets::write_file_atomic(&path, &body, "project order")?;
        if self.shared {
            crate::state_bus::announce(
                crate::state_bus::Change::Order,
                crate::session_ops::own_listener_port_public(),
            );
        }
        Ok(())
    }

    /// `app_state::edit` for the shared home: same lock, save and announce.
    fn edit_state<T>(
        &self,
        mutate: impl FnOnce(&mut Map<String, Value>) -> Result<T, String>,
    ) -> Result<T, String> {
        if self.shared {
            crate::app_state::edit(mutate)
        } else {
            crate::app_state::edit_at(&self.state_path(), mutate)
        }
    }
}

/// Id prefix of the groups made here. Never `native-`: the Mac app's mirror
/// deletes `native-` projects it has no record of.
const GROUP_PREFIX: &str = "sa-";

/// Longest group name kept.
const MAX_NAME_CHARS: usize = 80;

/// Deepest nesting walked before a project tree counts as broken.
const MAX_DEPTH: usize = 16;

/// A new plain group at the top of `project_id`'s root Project, the way the
/// legacy-pin migration adds one (`session_ops::prepare_legacy_pin_groups`).
fn create_group_at(home: &Home, caller: Option<&str>, args: &Value) -> Result<Value, String> {
    require_router(home, caller)?;
    let project_id = required(args, "project_id")?;
    let name = group_name(args)?;
    let id = format!("{GROUP_PREFIX}{}", uuid::Uuid::new_v4());
    home.edit_state(|state| add_group(state, project_id, &name, &id))
}

fn add_group(
    state: &mut Map<String, Value>,
    project_id: &str,
    name: &str,
    id: &str,
) -> Result<Value, String> {
    let projects = projects_in(state);
    let root = root_of(&projects, project_id).ok_or_else(|| unknown_project(project_id))?;
    let rows = project_rows(state)?;
    let workspace_id = rows
        .iter()
        .find(|row| row_id(row) == Some(root.id.as_str()))
        .and_then(|row| row.get("workspace_id"))
        .cloned();
    for sibling in rows
        .iter_mut()
        .filter(|row| row_parent(row) == Some(root.id.as_str()))
    {
        let next = sibling
            .get("sort_order")
            .and_then(Value::as_u64)
            .unwrap_or(0)
            .saturating_add(1);
        sibling["sort_order"] = json!(next);
    }
    let mut group = json!({
        "id": id,
        "name": name,
        "path": root.path,
        "parent_project_id": root.id,
        "sort_order": 0,
        "is_folder": true,
    });
    if let Some(workspace_id) = workspace_id {
        group["workspace_id"] = workspace_id;
    }
    rows.push(group);
    Ok(json!({ "project_id": id, "name": name, "parent_id": root.id, "path": root.path }))
}

/// Rename a plain group, with `session_ops::rename_group_project`'s rules.
fn rename_group_at(home: &Home, caller: Option<&str>, args: &Value) -> Result<Value, String> {
    require_router(home, caller)?;
    let project_id = required(args, "project_id")?;
    let name = group_name(args)?;
    home.edit_state(|state| {
        managed_group(&projects_in(state), project_id, "renamed")?;
        let row = project_rows(state)?
            .iter_mut()
            .find(|row| row_id(row) == Some(project_id))
            .ok_or_else(|| unknown_group(project_id))?;
        row["name"] = json!(name);
        Ok(json!({ "project_id": project_id, "name": name }))
    })
}

/// Remove an empty group, as `session_ops::remove_unreferenced_legacy_pin_groups`
/// removes a migration group: no Session launched in or filed into it
/// (stopped ones count) and no Project inside it.
fn remove_group_at(home: &Home, caller: Option<&str>, args: &Value) -> Result<Value, String> {
    require_router(home, caller)?;
    let project_id = required(args, "project_id")?;
    let filed = sessions_in_group(&home.sessions_root(), project_id);
    let name = home.edit_state(|state| remove_group_in(state, project_id, filed))?;
    // A stale id in the order is harmless (bootstrap skips unknown ids), but
    // say so rather than hide it.
    home.prune_project_order(project_id).map_err(|error| {
        format!("Removed group '{name}', but the sidebar order kept its id: {error}")
    })?;
    Ok(json!({ "project_id": project_id, "name": name, "removed": true }))
}

fn remove_group_in(
    state: &mut Map<String, Value>,
    project_id: &str,
    filed: usize,
) -> Result<String, String> {
    let projects = projects_in(state);
    let group = managed_group(&projects, project_id, "removed")?;
    if filed > 0 {
        return Err(format!(
            "Group '{}' is not empty: {filed} Session(s), stopped ones included, are in it. \
Move your Workers out first (workspace move_session); the user's Sessions are theirs to move.",
            group.name
        ));
    }
    if projects
        .iter()
        .any(|project| parent_id(project) == Some(project_id))
    {
        return Err(format!(
            "Group '{}' holds other groups or worktrees; it can't be removed.",
            group.name
        ));
    }
    let parent = parent_id(group).map(str::to_string);
    let removed_order = u64::from(group.sort_order);
    let rows = project_rows(state)?;
    rows.retain(|row| row_id(row) != Some(project_id));
    for sibling in rows
        .iter_mut()
        .filter(|row| row_parent(row).map(str::trim) == parent.as_deref())
    {
        let order = sibling
            .get("sort_order")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if order > removed_order {
            sibling["sort_order"] = json!(order - 1);
        }
    }
    Ok(group.name.clone())
}

/// File one of the Router's own Workers (stopped ones too) under another
/// group, as the Host's `session.project.set` does (`controller_host`
/// `organization()`): its launch Project clears `project-override.json`,
/// any other target must stay inside the Worker's own checkout.
fn move_session_at(home: &Home, caller: Option<&str>, args: &Value) -> Result<Value, String> {
    let router = require_router(home, caller)?;
    let session_id = required(args, "session_id")?;
    let target = required(args, "project_id")?;
    if session_id.contains('/') || session_id.contains('\\') || session_id.contains("..") {
        return Err(format!("'{session_id}' is not a session id."));
    }
    let dir = home.sessions_root().join(session_id);
    if !dir.is_dir() {
        return Err(format!(
            "Unknown session '{session_id}'. Call sessions current for your Workers."
        ));
    }
    let owned = crate::supervision::read_worker_marker_in(&dir)
        .is_some_and(|marker| marker.router_id == router);
    if !owned {
        return Err(format!(
            "Session '{session_id}' is not one of your Workers; you can only move Sessions \
working for you."
        ));
    }
    let launched_in = manifest_project(&dir)
        .ok_or_else(|| format!("Session '{session_id}' has no launch manifest yet."))?;
    if target == launched_in {
        refile(home, session_id, None)?;
    } else {
        check_move_target(&home.state()?, &launched_in, target)
            .map_err(|error| format!("Can't move '{session_id}' to '{target}': {error}"))?;
        refile(home, session_id, Some(target))?;
    }
    Ok(json!({ "session_id": session_id, "project_id": target }))
}

/// File the Worker under `target`, or (`None`) back under its launch
/// Project. The real home uses `session_ops`' own marker writers, which
/// announce; a test home writes the same `{project_id, moved_at}` marker
/// under its own root.
fn refile(home: &Home, session_id: &str, target: Option<&str>) -> Result<(), String> {
    if home.shared {
        return match target {
            Some(target) => crate::session_ops::set_project_override(session_id, target),
            None => crate::session_ops::clear_project_override(session_id),
        };
    }
    let dir = home.sessions_root().join(session_id);
    match target {
        Some(target) => file_project(&dir, target),
        None => clear_filed_project(&dir),
    }
}

/// The Host's rule (`controller_host::validate_session_project_target`),
/// and never into a root's Sidebar group, which holds side-panel panes.
fn check_move_target(state: &Value, launched_in: &str, target: &str) -> Result<(), String> {
    let rows = state
        .get("projects")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let sidebar = rows
        .iter()
        .filter_map(|row| serde_json::from_value::<Project>(row.clone()).ok())
        .any(|project| project.id == target && is_sidebar_group(&project));
    if sidebar {
        return Err(
            "that is its Project's Sidebar group, which holds side-panel panes only.".into(),
        );
    }
    crate::controller_host::validate_session_project_target(&rows, launched_in, target)
        .map_err(|error| format!("{error}. Call workspace list_projects for the targets."))
}

/// `session_ops::set_project_override`'s marker, under a test home.
fn file_project(dir: &Path, project_id: &str) -> Result<(), String> {
    let body = json!({ "project_id": project_id, "moved_at": crate::supervision::now_ms() });
    crate::hook_assets::write_file_atomic(
        &dir.join(crate::session_ops::PROJECT_OVERRIDE_MARKER),
        &body.to_string(),
        "project override",
    )
}

/// Back to the launch Project: no marker. Absent is not an error.
fn clear_filed_project(dir: &Path) -> Result<(), String> {
    match std::fs::remove_file(dir.join(crate::session_ops::PROJECT_OVERRIDE_MARKER)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("clear the group of {}: {error}", dir.display())),
    }
}

/// How many session dirs reference `group_id`, by manifest project or by
/// `project-override.json` (`session_ops::referenced_project_ids`).
fn sessions_in_group(sessions_root: &Path, group_id: &str) -> usize {
    let Ok(entries) = std::fs::read_dir(sessions_root) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|entry| {
            let dir = entry.path();
            filed_project(&dir).as_deref() == Some(group_id)
                || manifest_project(&dir).as_deref() == Some(group_id)
        })
        .count()
}

/// The `project_id` of a session dir's `project-override.json`.
fn filed_project(dir: &Path) -> Option<String> {
    let raw = std::fs::read(dir.join(crate::session_ops::PROJECT_OVERRIDE_MARKER)).ok()?;
    let marker: Value = serde_json::from_slice(&raw).ok()?;
    marker.get("project_id")?.as_str().map(str::to_string)
}

/// The Project a session dir's manifest launched in.
fn manifest_project(dir: &Path) -> Option<String> {
    let raw = std::fs::read(dir.join("manifest.json")).ok()?;
    let manifest: Value = serde_json::from_slice(&raw).ok()?;
    manifest
        .get("session")?
        .get("project_id")?
        .as_str()
        .map(str::to_string)
}

/// `project_id` as a group the Router may rename or remove: a plain group it
/// created (`sa-` id, §16.2), never a root's Sidebar group (it holds the
/// side-panel panes) and never one the Mac app keeps in its own records —
/// its mirror would put back the old row
/// (`UnpeelStore.mirrorProjectsToSharedState`).
fn managed_group<'a>(
    projects: &'a [Project],
    project_id: &str,
    verb: &str,
) -> Result<&'a Project, String> {
    let group = find(projects, project_id).ok_or_else(|| unknown_group(project_id))?;
    if !is_plain_group(group) {
        return Err(format!(
            "'{}' is not a group: only sidebar groups can be {verb} here.",
            group.name
        ));
    }
    if is_sidebar_group(group) {
        return Err(format!(
            "'{}' is its Project's Sidebar group, which holds the side-panel panes; it can't \
be {verb}.",
            group.name
        ));
    }
    if group.id.starts_with(NATIVE_PREFIX) {
        return Err(format!(
            "Group '{}' is kept in the Mac app's own records, which would undo this change. \
Ask the user to do it in the sidebar.",
            group.name
        ));
    }
    if !group.id.starts_with(GROUP_PREFIX) {
        return Err(format!(
            "Group '{}' was not made with workspace create_group: you rename and remove only \
groups you created (id {GROUP_PREFIX}…). Ask the user to do it in the sidebar.",
            group.name
        ));
    }
    Ok(group)
}

/// Ids the Mac app mints for the groups it keeps in its own records.
const NATIVE_PREFIX: &str = "native-";

fn unknown_group(project_id: &str) -> String {
    format!(
        "Unknown group '{project_id}'. Call workspace list_projects for this workspace's \
groups."
    )
}

/// A sidebar group: a folder under a Project that is not a worktree.
fn is_plain_group(project: &Project) -> bool {
    project.is_folder && parent_id(project).is_some() && project.worktree_branch.is_none()
}

/// A root's Sidebar group (`UnpeelStore.projectSidebarGroupID(forRoot:)`),
/// the same test `workspace list_projects` flags it with.
fn is_sidebar_group(project: &Project) -> bool {
    parent_id(project).is_some_and(|parent| project.id == format!("sidebar-{parent}"))
}

/// The caller's id when it is this workspace's Router. Re-read per call, so
/// a mark the user just made or cleared applies at once.
fn require_router(home: &Home, caller: Option<&str>) -> Result<String, String> {
    let router = crate::supervision::router_id_in(&home.state()?);
    match (caller, router) {
        (Some(caller), Some(router)) if caller == router => Ok(router),
        _ => Err(
            "Only the Super Agent manages groups and moves Workers between them. The \
user makes a Claude Code Session the Super Agent with right-click ▸ Make Super Agent."
                .into(),
        ),
    }
}

/// A trimmed, non-empty string argument.
fn required<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Missing required string argument '{key}'"))
}

/// `name`, without control characters and at most `MAX_NAME_CHARS` long.
fn group_name(args: &Value) -> Result<String, String> {
    let kept: String = required(args, "name")?
        .chars()
        .filter(|ch| !ch.is_control())
        .collect();
    let name: String = kept.trim().chars().take(MAX_NAME_CHARS).collect();
    if name.is_empty() {
        return Err("Missing required string argument 'name'".into());
    }
    Ok(name)
}

fn unknown_project(project_id: &str) -> String {
    format!(
        "Unknown project '{project_id}'. Call workspace list_projects for this workspace's \
Project ids."
    )
}

/// The Projects of one app-state document, typed for lookups. Edits go to
/// the raw rows so fields nobody models pass through.
fn projects_in(state: &Map<String, Value>) -> Vec<Project> {
    state
        .get("projects")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|raw| serde_json::from_value(raw.clone()).ok())
        .collect()
}

fn project_rows(state: &mut Map<String, Value>) -> Result<&mut Vec<Value>, String> {
    state
        .get_mut("projects")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| "app-state.json has no project list.".to_string())
}

fn row_id(row: &Value) -> Option<&str> {
    row.get("id").and_then(Value::as_str)
}

fn row_parent(row: &Value) -> Option<&str> {
    row.get("parent_project_id").and_then(Value::as_str)
}

fn find<'a>(projects: &'a [Project], id: &str) -> Option<&'a Project> {
    projects.iter().find(|project| project.id == id)
}

fn parent_id(project: &Project) -> Option<&str> {
    project
        .parent_project_id
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty() && *id != project.id)
}

/// A top-level folder row of the sidebar: not a Project, and a Project
/// filed in one is a root (as `workspace_tools` and the bootstrap read it).
fn is_folder_row(project: &Project) -> bool {
    project.is_folder && parent_id(project).is_none()
}

fn parent<'a>(projects: &'a [Project], project: &Project) -> Option<&'a Project> {
    find(projects, parent_id(project)?).filter(|parent| !is_folder_row(parent))
}

/// The root Project at the top of `project_id`'s parent chain; `None` for
/// an unknown id, a folder row, or a broken (cyclic or too deep) chain.
fn root_of<'a>(projects: &'a [Project], project_id: &str) -> Option<&'a Project> {
    let mut current = find(projects, project_id)?;
    for _ in 0..MAX_DEPTH {
        match parent(projects, current) {
            Some(next) => current = next,
            None => return (!is_folder_row(current)).then_some(current),
        }
    }
    None
}

#[cfg(test)]
mod tests;
