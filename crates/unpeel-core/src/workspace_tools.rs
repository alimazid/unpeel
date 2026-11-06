//! Fork-only: the `workspace` MCP domain served by the MCP host itself, from
//! app-state and git. The retired Swift `MCPBridge` used to answer
//! `/mcp/list-presets`, `/mcp/list-worktrees` and `/mcp/create-worktree`;
//! nothing serves those routes any more, so the three actions read and
//! write the shared files directly, and `list_projects` lists the Projects
//! a Router can start Workers in.

use std::path::Path;

use serde_json::{json, Value};

use crate::state::{Preset, Project};
use crate::worktrees::Worktree;

/// `workspace list_presets` for `project_id` (the caller's by default).
pub(crate) fn tool_list_presets(project_id: &str) -> Result<String, String> {
    render(&preset_listing(&StateFile::Shared.load()?, project_id))
}

/// `workspace list_projects`. Open to every caller: reads are open.
pub(crate) fn tool_list_projects(_args: &Value) -> Result<String, String> {
    render(&project_listing(&StateFile::Shared.load()?))
}

/// `workspace list_worktrees`. The caller checks worktree access first.
pub(crate) fn tool_list_worktrees(project_id: &str) -> Result<String, String> {
    render(&worktree_listing_at(StateFile::Shared, project_id)?)
}

/// `workspace create_worktree`. The caller checks worktree access first.
pub(crate) fn tool_create_worktree(args: &Value, project_id: &str) -> Result<String, String> {
    render(&create_and_register(args, project_id)?)
}

/// Create (or adopt) the worktree `args` names (`branch`, `name?`,
/// `base_ref?`) of `project_id`'s checkout and register its child project:
/// `{path, project_id, branch, adopted, repo_path}` (`repo_path`, the
/// checkout, goes on the Super Agent's worktree ledger).
pub(crate) fn create_and_register(args: &Value, project_id: &str) -> Result<Value, String> {
    let request = WorktreeRequest::from_args(args)?;
    create_worktree_at(
        StateFile::Shared,
        project_id,
        &request,
        crate::worktrees::create_in_folder,
    )
}

/// `action: "help"` sections for the actions this module adds.
pub(crate) fn help_docs() -> Vec<(String, Value)> {
    vec![(
        "list_projects".into(),
        json!({
            "description": "List this workspace's Projects in sidebar order, each root \
        followed by its groups and worktrees: {id, name, path, kind: root|group|worktree, parent_id?, \
        worktree_branch?, sidebar}. path is the folder a Session started there runs in (a group runs in \
        its checkout's folder). sidebar: true marks a root's Sidebar group, which holds side-panel panes \
        only; don't start Sessions there. Pass an id as project_id to sessions create or to the other \
        workspace actions.",
            "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false },
        }),
    )]
}

fn render(value: &Value) -> Result<String, String> {
    serde_json::to_string_pretty(value).map_err(|error| format!("Failed to render: {error}"))
}

/// Where app-state lives: the workspace's shared file (writes flock and
/// announce on the state bus), or an explicit path for tests.
#[derive(Clone, Copy)]
enum StateFile<'a> {
    Shared,
    #[cfg_attr(not(test), allow(dead_code))]
    At(&'a Path),
}

impl StateFile<'_> {
    fn load(self) -> Result<Value, String> {
        match self {
            Self::Shared => crate::app_state::load(),
            Self::At(path) => crate::app_state::load_for_edit_at(path),
        }
    }

    fn edit<T>(
        self,
        mutate: impl FnOnce(&mut serde_json::Map<String, Value>) -> Result<T, String>,
    ) -> Result<T, String> {
        match self {
            Self::Shared => crate::app_state::edit(mutate),
            Self::At(path) => crate::app_state::edit_at(path, mutate),
        }
    }
}

/// A `create_worktree` call's parameters, validated.
struct WorktreeRequest {
    branch: String,
    name: Option<String>,
    base_ref: Option<String>,
}

/// Longest sidebar name a worktree project gets.
const MAX_NAME_CHARS: usize = 80;

impl WorktreeRequest {
    fn from_args(args: &Value) -> Result<Self, String> {
        let text = |key: &str| {
            args.get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        };
        let branch = text("branch").ok_or("Missing required string argument 'branch'")?;
        // git would read a leading '-' as an option.
        if branch.starts_with('-') {
            return Err("A branch name cannot start with '-'.".into());
        }
        if branch.chars().any(char::is_control) {
            return Err("A branch name cannot contain control characters.".into());
        }
        let name = text("name")
            .map(|name| {
                let kept: String = name.chars().filter(|ch| !ch.is_control()).collect();
                kept.trim().chars().take(MAX_NAME_CHARS).collect::<String>()
            })
            .filter(|name| !name.is_empty());
        Ok(Self {
            branch: branch.to_string(),
            name,
            base_ref: text("base_ref").map(str::to_string),
        })
    }
}

/// Id prefix of the child projects registered here. Never `native-`: the
/// Mac app's mirror deletes `native-` projects it has no record of.
const WORKTREE_PROJECT_PREFIX: &str = "mcp-wt-";

/// Create (or adopt) a worktree of `project_id`'s checkout and register it
/// as a child project, once per (root, branch). `make` is
/// `worktrees::create_in_folder` outside tests: `(checkout, branch,
/// base_ref, folder)`. As the Mac app does, `name` picks the new worktree's
/// folder and its sidebar name; both default to the branch.
fn create_worktree_at(
    file: StateFile,
    project_id: &str,
    request: &WorktreeRequest,
    make: impl FnOnce(&str, &str, Option<&str>, &str) -> Result<Worktree, String>,
) -> Result<Value, String> {
    let state = file.load()?;
    let tree = Tree::from_state(&state);
    let root = checkout_root(&tree, project_id)?;
    let branch = request.branch.as_str();
    let name = request.name.clone().unwrap_or_else(|| branch.to_string());
    let (path, adopted) = match tree.registered_worktree(&root.id, branch) {
        Some(child) if Path::new(&child.path).is_dir() => (child.path.clone(), true),
        _ => match existing_worktree(&root.path, branch)? {
            Some(found) => (found, true),
            None => (
                make(&root.path, branch, request.base_ref.as_deref(), &name)?.path,
                false,
            ),
        },
    };
    let child_id = file.edit(|state| register_worktree(state, &root.id, branch, &path, &name))?;
    Ok(json!({
        "path": path,
        "project_id": child_id,
        "branch": branch,
        "adopted": adopted,
        "repo_path": root.path,
    }))
}

/// `workspace list_worktrees`: every git worktree of `project_id`'s
/// checkout, with the child project registered for it, plus registered
/// worktree projects git no longer knows (`missing`).
fn worktree_listing_at(file: StateFile, project_id: &str) -> Result<Value, String> {
    let state = file.load()?;
    let tree = Tree::from_state(&state);
    let root = checkout_root(&tree, project_id)?;
    let git = crate::worktrees::list(&root.path)
        .map_err(|error| format!("{} is not a git checkout: {error}", root.path))?;
    let registered = tree.worktree_children(&root.id);
    let mut rows: Vec<Value> = git
        .iter()
        .enumerate()
        .map(|(index, worktree)| git_worktree_row(index, worktree, &root, &registered))
        .collect();
    rows.extend(
        registered
            .iter()
            .filter(|child| {
                !git.iter()
                    .any(|worktree| same_path(&worktree.path, &child.path))
            })
            .map(|child| {
                json!({
                    "path": child.path,
                    "branch": worktree_branch(child),
                    "project_id": child.id,
                    "name": child.name,
                    "missing": true,
                })
            }),
    );
    Ok(json!({ "project_id": root.id, "worktrees": rows }))
}

fn git_worktree_row(
    index: usize,
    worktree: &Worktree,
    root: &Project,
    registered: &[&Project],
) -> Value {
    let mut row = json!({
        "path": worktree.path,
        "branch": worktree.branch,
        "managed": worktree.managed,
    });
    if index == 0 {
        // git lists the main checkout first: the root Project itself.
        row["main"] = json!(true);
        row["project_id"] = json!(root.id);
    } else if let Some(child) = registered
        .iter()
        .find(|child| same_path(&child.path, &worktree.path))
    {
        row["project_id"] = json!(child.id);
        row["name"] = json!(child.name);
    }
    row
}

/// Path equality through symlinks (`/tmp` is `/private/tmp` to git).
fn same_path(left: &str, right: &str) -> bool {
    let canonical = |path: &str| std::fs::canonicalize(path).unwrap_or_else(|_| path.into());
    left == right || canonical(left) == canonical(right)
}

/// The root Project whose checkout `project_id` belongs to: groups and
/// worktree children resolve to it, so every worktree of a repo hangs off
/// one parent and is created from the main checkout.
fn checkout_root(tree: &Tree, project_id: &str) -> Result<Project, String> {
    let root = tree.root_of(project_id).ok_or_else(|| {
        format!(
            "Unknown project '{project_id}'. Call workspace list_projects for this workspace's \
Project ids."
        )
    })?;
    if root.path.trim().is_empty() {
        return Err(format!("Project '{}' has no folder.", root.id));
    }
    Ok(root.clone())
}

/// A linked worktree (never the main checkout, listed first) already on
/// `branch`, made by the desktop or by hand: adopt it rather than fail.
fn existing_worktree(repo: &str, branch: &str) -> Result<Option<String>, String> {
    let worktrees = crate::worktrees::list(repo)
        .map_err(|error| format!("{repo} is not a git checkout: {error}"))?;
    Ok(worktrees
        .into_iter()
        .skip(1)
        // A deleted folder git has not pruned yet is not adoptable.
        .find(|worktree| {
            worktree.branch.as_deref() == Some(branch) && Path::new(&worktree.path).is_dir()
        })
        .map(|worktree| worktree.path))
}

/// Register the (root, branch) child project, or reuse the one another
/// frontend registered meanwhile (refreshing its path). Returns its id.
fn register_worktree(
    state: &mut serde_json::Map<String, Value>,
    root_id: &str,
    branch: &str,
    path: &str,
    name: &str,
) -> Result<String, String> {
    let rows = state
        .get_mut("projects")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| "app-state.json has no project list.".to_string())?;
    let is_child =
        |row: &Value| row.get("parent_project_id").and_then(Value::as_str) == Some(root_id);
    let registered = rows.iter_mut().find(|row| {
        is_child(row) && row.get("worktree_branch").and_then(Value::as_str) == Some(branch)
    });
    if let Some(existing) = registered {
        let id = existing
            .get("id")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| format!("The project registered for branch '{branch}' has no id."))?;
        existing["path"] = json!(path);
        return Ok(id);
    }
    let sort_order = rows
        .iter()
        .filter(|row| is_child(row))
        .filter_map(|row| row.get("sort_order").and_then(Value::as_u64))
        .max()
        .map_or(0, |last| last + 1);
    let workspace_id = rows
        .iter()
        .find(|row| row.get("id").and_then(Value::as_str) == Some(root_id))
        .and_then(|root| root.get("workspace_id"))
        .cloned();
    let id = format!("{WORKTREE_PROJECT_PREFIX}{}", uuid::Uuid::new_v4());
    let mut row = json!({
        "id": id,
        "name": name,
        "path": path,
        "parent_project_id": root_id,
        "worktree_branch": branch,
        "sort_order": sort_order,
        "is_folder": false,
    });
    if let Some(workspace_id) = workspace_id {
        row["workspace_id"] = workspace_id;
    }
    rows.push(row);
    Ok(id)
}

/// The presets a Session in `project_id` may launch: enabled, global or
/// scoped to that project, project-scoped first so an override wins over
/// its global twin. A group or worktree launches its root Project's
/// presets. `sessions create` resolves `preset` against exactly this list.
pub(crate) fn usable_presets(state: &Value, project_id: &str) -> Vec<Preset> {
    let root_id = Tree::from_state(state)
        .root_of(project_id)
        .map(|root| root.id.clone());
    let in_scope = |scope: &str| scope == project_id || root_id.as_deref() == Some(scope);
    let mut usable: Vec<Preset> = state
        .get("presets")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|raw| serde_json::from_value::<Preset>(raw.clone()).ok())
        .filter(|preset| preset.enabled && preset.project_id.as_deref().is_none_or(in_scope))
        .collect();
    // A stable sort keeps each half in the user's order.
    usable.sort_by_key(|preset| preset.project_id.is_none());
    usable
}

/// `workspace list_presets`: the presets `project_id` may launch.
pub(crate) fn preset_listing(state: &Value, project_id: &str) -> Value {
    let presets: Vec<Value> = usable_presets(state, project_id)
        .into_iter()
        .map(|preset| {
            json!({
                "id": preset.id,
                "label": preset.label,
                "command": preset.command,
                "project_id": preset.project_id,
                "quick_launch": preset.quick_launch,
            })
        })
        .collect();
    json!({ "project_id": project_id, "presets": presets })
}

/// `workspace list_projects`: every Project of this workspace in sidebar
/// tree order, each root followed by its groups and worktrees.
pub(crate) fn project_listing(state: &Value) -> Value {
    let tree = Tree::from_state(state);
    let mut rows = Vec::new();
    for root in tree.roots() {
        rows.push(project_row(&tree, root, &root.path));
        list_children(&tree, root, &root.path, 1, &mut rows);
    }
    json!({ "projects": rows })
}

/// Deepest nesting walked before a project tree counts as broken.
const MAX_DEPTH: usize = 16;

fn list_children(
    tree: &Tree,
    parent: &Project,
    parent_path: &str,
    depth: usize,
    rows: &mut Vec<Value>,
) {
    if depth > MAX_DEPTH {
        return;
    }
    for child in tree.children(&parent.id) {
        // A group has no checkout of its own: it runs in its parent's.
        let path = if child.is_folder && worktree_branch(child).is_none() {
            parent_path
        } else {
            child.path.as_str()
        };
        rows.push(project_row(tree, child, path));
        list_children(tree, child, path, depth + 1, rows);
    }
}

fn project_row(tree: &Tree, project: &Project, path: &str) -> Value {
    let parent = tree.parent(project);
    let branch = worktree_branch(project).filter(|_| parent.is_some());
    let kind = match (parent, branch) {
        (None, _) => "root",
        (Some(_), Some(_)) => "worktree",
        (Some(_), None) => "group",
    };
    // The root's "Sidebar" group, whose members show in the side panel
    // (`UnpeelStore.projectSidebarGroupID(forRoot:)`).
    let sidebar = kind == "group"
        && project.is_folder
        && parent.is_some_and(|parent| project.id == format!("sidebar-{}", parent.id));
    let mut row = json!({
        "id": project.id,
        "name": project.name,
        "path": path,
        "kind": kind,
        "sidebar": sidebar,
    });
    if let Some(parent) = parent {
        row["parent_id"] = json!(parent.id);
    }
    if let Some(branch) = branch {
        row["worktree_branch"] = json!(branch);
    }
    row
}

fn worktree_branch(project: &Project) -> Option<&str> {
    project
        .worktree_branch
        .as_deref()
        .map(str::trim)
        .filter(|branch| !branch.is_empty())
}

/// The Projects of one app-state document. A top-level folder (the
/// sidebar's folder rows) is not a Project, and a Project filed in one is
/// a root, as the Host bootstrap reads them.
struct Tree {
    projects: Vec<Project>,
}

impl Tree {
    fn from_state(state: &Value) -> Self {
        let projects = state
            .get("projects")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|raw| serde_json::from_value::<Project>(raw.clone()).ok())
            .collect();
        Self { projects }
    }

    fn get(&self, id: &str) -> Option<&Project> {
        self.projects.iter().find(|project| project.id == id)
    }

    fn is_folder_row(project: &Project) -> bool {
        project.is_folder && Self::parent_id(project).is_none()
    }

    fn parent_id(project: &Project) -> Option<&str> {
        project
            .parent_project_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty() && *id != project.id)
    }

    fn parent(&self, project: &Project) -> Option<&Project> {
        self.get(Self::parent_id(project)?)
            .filter(|parent| !Self::is_folder_row(parent))
    }

    /// Roots and children each in the user's order (`sort_order`, then
    /// file order).
    fn roots(&self) -> Vec<&Project> {
        self.sorted(|project| !Self::is_folder_row(project) && self.parent(project).is_none())
    }

    fn children(&self, parent_id: &str) -> Vec<&Project> {
        self.sorted(|project| {
            self.parent(project)
                .is_some_and(|parent| parent.id == parent_id)
        })
    }

    /// The root at the top of `project_id`'s parent chain; `None` for an
    /// unknown id or a broken (cyclic or too deep) chain.
    fn root_of(&self, project_id: &str) -> Option<&Project> {
        let mut current = self.get(project_id.trim())?;
        for _ in 0..MAX_DEPTH {
            match self.parent(current) {
                Some(parent) => current = parent,
                None => return (!Self::is_folder_row(current)).then_some(current),
            }
        }
        None
    }

    /// The worktree child project registered for (`root_id`, `branch`).
    fn registered_worktree(&self, root_id: &str, branch: &str) -> Option<&Project> {
        self.worktree_children(root_id)
            .into_iter()
            .find(|project| worktree_branch(project) == Some(branch))
    }

    fn worktree_children(&self, root_id: &str) -> Vec<&Project> {
        self.projects
            .iter()
            .filter(|project| {
                Self::parent_id(project) == Some(root_id) && worktree_branch(project).is_some()
            })
            .collect()
    }

    fn sorted(&self, keep: impl Fn(&Project) -> bool) -> Vec<&Project> {
        let mut kept: Vec<&Project> = self.projects.iter().filter(|p| keep(p)).collect();
        kept.sort_by_key(|project| project.sort_order);
        kept
    }
}

#[cfg(test)]
mod tests;
