//! Fork-only: the Super Agent seams in the unified MCP server. Each is called
//! by a one-line `// Fork-only` hunk in `mcp_host.rs` and, by default,
//! leaves upstream behavior untouched, so later Super Agent work lands here
//! instead of in `mcp_host.rs`.

use serde_json::Value;

use crate::session_host::HostedSessionManifest;
use crate::state::SessionInfo;

/// An extra domain action: arguments in, the tool's text result out.
pub(crate) type Handler = fn(&Value) -> Result<String, String>;

/// Extra `sessions` actions (name, handler). Their names join the advertised
/// action enum; each runs behind the same gate as upstream's actions.
const SESSIONS_ACTIONS: &[(&str, Handler)] = &[];

/// Extra `workspace` actions, as `SESSIONS_ACTIONS`.
const WORKSPACE_ACTIONS: &[(&str, Handler)] =
    &[("list_projects", crate::workspace_tools::tool_list_projects)];

pub(crate) fn sessions_action_names() -> impl Iterator<Item = &'static str> {
    SESSIONS_ACTIONS.iter().map(|(name, _)| *name)
}

pub(crate) fn workspace_action_names() -> impl Iterator<Item = &'static str> {
    WORKSPACE_ACTIONS.iter().map(|(name, _)| *name)
}

/// `Some` when `action` is an extra `sessions` action; `None` leaves the
/// call to upstream's table.
pub(crate) fn sessions_action(
    action: &str,
    args: &Value,
    gate: fn() -> Result<(), String>,
) -> Option<Result<String, String>> {
    dispatch(SESSIONS_ACTIONS, action, args, gate)
}

/// As `sessions_action`, for the `workspace` domain.
pub(crate) fn workspace_action(
    action: &str,
    args: &Value,
    gate: fn() -> Result<(), String>,
) -> Option<Result<String, String>> {
    dispatch(WORKSPACE_ACTIONS, action, args, gate)
}

fn dispatch(
    table: &[(&str, Handler)],
    action: &str,
    args: &Value,
    gate: fn() -> Result<(), String>,
) -> Option<Result<String, String>> {
    let (_, run) = table.iter().find(|(name, _)| *name == action)?;
    Some(gate().and_then(|()| run(args)))
}

/// The advertised definition of `tool` with the Super Agent parameters
/// merged into its input schema. Detail belongs in `help_docs`: the whole
/// surface must stay inside `advertised_schema_stays_within_the_context_budget`.
pub(crate) fn extend_schema(tool: &str, definition: Value) -> Value {
    merge_properties(definition, extra_properties(tool))
}

/// Extra schema properties per tool (none yet).
fn extra_properties(tool: &str) -> Vec<(&'static str, Value)> {
    let _ = tool;
    Vec::new()
}

fn merge_properties(definition: Value, properties: Vec<(&'static str, Value)>) -> Value {
    let mut definition = definition;
    if let Some(advertised) = definition
        .pointer_mut("/inputSchema/properties")
        .and_then(Value::as_object_mut)
    {
        advertised.extend(
            properties
                .into_iter()
                .map(|(name, schema)| (name.to_string(), schema)),
        );
    }
    definition
}

/// `action: "help"` sections for the extra actions of `tool`, shaped like
/// `legacy_sessions_tool_definitions` entries: `(action, {description,
/// inputSchema})`.
pub(crate) fn help_docs(tool: &str) -> Vec<(String, Value)> {
    if tool == "workspace" {
        return crate::workspace_tools::help_docs();
    }
    Vec::new()
}

/// `report` from `caller` to `target`, taken over before the write gate (a
/// Worker's report to its Router is queued in the Router's Inbox and needs
/// no approval). `None`: upstream's paste path.
pub(crate) fn route_report(
    args: &Value,
    caller: &HostedSessionManifest,
    target: &HostedSessionManifest,
) -> Option<Result<String, String>> {
    let _ = (args, caller, target);
    None
}

/// `send_text` to `target_id`, taken over before the write gate, as
/// `route_report`. `None`: upstream's paste path.
pub(crate) fn route_send_text(
    args: &Value,
    caller: Option<&HostedSessionManifest>,
    target_id: &str,
) -> Option<Result<String, String>> {
    let _ = (args, caller, target_id);
    None
}

/// Close authority beyond upstream's `spawned_by == caller` (a Router closes
/// its Workers by marker). `false` keeps upstream's rule alone.
pub(crate) fn may_close(caller: &HostedSessionManifest, target: &HostedSessionManifest) -> bool {
    let _ = (caller, target);
    false
}

/// The Super Agent half of one `sessions create`: extra parameters read
/// before the spawn, and the after-spawn step.
#[derive(Debug, Default)]
pub(crate) struct CreateHooks {
    default_cwd: Option<String>,
}

/// Read the extra create parameters. An `Err` refuses the create before
/// anything is spawned.
pub(crate) fn create_hooks(
    args: &Value,
    caller: &HostedSessionManifest,
) -> Result<CreateHooks, String> {
    let _ = caller;
    let default_cwd = if args.get("project_id").is_some() {
        default_create_cwd(&crate::app_state::load().unwrap_or(Value::Null), args)
    } else {
        None
    };
    Ok(CreateHooks { default_cwd })
}

impl CreateHooks {
    /// The folder to run in when the caller passed no `cwd`; `None` keeps
    /// the caller's own.
    pub(crate) fn default_cwd(&self) -> Option<String> {
        self.default_cwd.clone()
    }

    /// The session record about to be spawned, with any extra fields set.
    pub(crate) fn prepare(&self, session: SessionInfo) -> SessionInfo {
        session
    }

    /// After a successful spawn: record what the new Session is and add any
    /// fields to the create result.
    pub(crate) fn after_spawn(&self, session_id: &str, result: Value) -> Value {
        let _ = session_id;
        result
    }
}

/// Extra fields for `sessions current` (`None`: nothing to add).
pub(crate) fn current_extras(caller: &HostedSessionManifest) -> Option<Value> {
    let _ = caller;
    None
}

/// `result` with the fields of `extras` (an object) added.
pub(crate) fn merge_extras(result: Value, extras: Option<Value>) -> Value {
    match (result, extras) {
        (Value::Object(mut fields), Some(Value::Object(extra))) => {
            fields.extend(extra);
            Value::Object(fields)
        }
        (result, _) => result,
    }
}

/// The wait budget for `caller_id`, after upstream's clamp: a Router never
/// waits long, since its own Inbox holds behind a Busy turn.
pub(crate) fn cap_wait_timeout(caller_id: Option<&str>, requested_ms: u64) -> u64 {
    let _ = caller_id;
    requested_ms
}

/// Deepest group nesting walked before a project tree counts as broken.
const MAX_GROUP_DEPTH: usize = 16;

/// The folder a `sessions create` with a `project_id` and no `cwd` runs in
/// (§16.2): that Project's path, and for a sidebar group, the path of the
/// checkout it sits in (its root, or the worktree it groups). `None` keeps
/// upstream's default, the caller's own folder — for an absent or unknown
/// id (desktop-owned projects may be missing from app-state) or a project
/// without a path.
pub(crate) fn default_create_cwd(state: &Value, args: &Value) -> Option<String> {
    let project_id = args
        .get("project_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())?;
    let projects: Vec<crate::state::Project> = state
        .get("projects")?
        .as_array()?
        .iter()
        .filter_map(|raw| serde_json::from_value(raw.clone()).ok())
        .collect();
    let mut current = projects.iter().find(|project| project.id == project_id)?;
    for _ in 0..MAX_GROUP_DEPTH {
        let parent = current
            .parent_project_id
            .as_deref()
            .filter(|_| is_plain_group(current));
        match parent {
            Some(parent) => current = projects.iter().find(|project| project.id == parent)?,
            None => return Some(current.path.clone()).filter(|path| !path.trim().is_empty()),
        }
    }
    None
}

/// A sidebar group: a folder under a project that is not a worktree (the
/// same test `session_ops` applies before renaming or pinning one).
fn is_plain_group(project: &crate::state::Project) -> bool {
    project.is_folder
        && project
            .parent_project_id
            .as_deref()
            .is_some_and(|parent| !parent.trim().is_empty())
        && project.worktree_branch.is_none()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn workspace() -> Value {
        json!({
            "projects": [
                { "id": "root", "name": "Root", "path": "/work/root" },
                // A plain group: its own path is whatever a frontend wrote.
                { "id": "group", "name": "Group", "path": "/stale", "parent_project_id": "root", "is_folder": true },
                { "id": "nested", "name": "Nested", "path": "", "parent_project_id": "group", "is_folder": true },
                { "id": "wt", "name": "wt", "path": "/work/wt", "parent_project_id": "root", "worktree_branch": "feature" },
                { "id": "wt-group", "name": "In wt", "path": "/work/root", "parent_project_id": "wt", "is_folder": true },
                { "id": "folder", "name": "Folder", "path": "", "is_folder": true },
                { "id": "loop-a", "name": "A", "path": "", "parent_project_id": "loop-b", "is_folder": true },
                { "id": "loop-b", "name": "B", "path": "", "parent_project_id": "loop-a", "is_folder": true },
                "junk",
            ]
        })
    }

    fn cwd_for(project_id: Option<&str>) -> Option<String> {
        let args = match project_id {
            Some(id) => json!({ "action": "create", "project_id": id }),
            None => json!({ "action": "create" }),
        };
        default_create_cwd(&workspace(), &args)
    }

    fn gate_open() -> Result<(), String> {
        Ok(())
    }

    fn gate_closed() -> Result<(), String> {
        Err("gated".into())
    }

    fn pong(_args: &Value) -> Result<String, String> {
        Ok("pong".into())
    }

    #[test]
    fn extra_actions_run_behind_the_domain_gate() {
        let table: &[(&str, Handler)] = &[("ping", pong)];
        assert_eq!(
            dispatch(table, "ping", &json!({}), gate_open),
            Some(Ok("pong".into()))
        );
        assert_eq!(
            dispatch(table, "ping", &json!({}), gate_closed),
            Some(Err("gated".into()))
        );
        // Anything else stays upstream's, gate or not.
        assert_eq!(dispatch(table, "list", &json!({}), gate_closed), None);
    }

    #[test]
    fn no_extra_actions_ship_yet() {
        assert_eq!(sessions_action("list", &json!({}), gate_open), None);
        assert_eq!(
            workspace_action("list_presets", &json!({}), gate_open),
            None
        );
        assert_eq!(sessions_action_names().count(), 0);
        assert_eq!(
            workspace_action_names().collect::<Vec<_>>(),
            ["list_projects"]
        );
    }

    #[test]
    fn extra_schema_properties_join_the_advertised_ones() {
        let definition = json!({
            "name": "sessions",
            "inputSchema": { "type": "object", "properties": { "action": { "type": "string" } } }
        });
        let merged = merge_properties(
            definition,
            vec![(
                "role",
                json!({ "type": "string", "description": "create: label" }),
            )],
        );
        let properties = &merged["inputSchema"]["properties"];
        assert_eq!(properties["action"]["type"], "string");
        assert_eq!(properties["role"]["description"], "create: label");
        assert_eq!(merged["name"], "sessions");
    }

    #[test]
    fn current_extras_merge_into_the_current_result() {
        let base = json!({ "current_session": { "id": "s" } });
        assert_eq!(merge_extras(base.clone(), None), base);
        let merged = merge_extras(base, Some(json!({ "inbox": { "pending": 2 } })));
        assert_eq!(merged["current_session"]["id"], "s");
        assert_eq!(merged["inbox"]["pending"], 2);
    }

    #[test]
    fn create_runs_in_the_named_projects_folder() {
        assert_eq!(cwd_for(Some("root")).as_deref(), Some("/work/root"));
        assert_eq!(cwd_for(Some("  root  ")).as_deref(), Some("/work/root"));
        // A worktree child project is its own checkout.
        assert_eq!(cwd_for(Some("wt")).as_deref(), Some("/work/wt"));
    }

    #[test]
    fn a_group_runs_in_its_roots_folder() {
        assert_eq!(cwd_for(Some("group")).as_deref(), Some("/work/root"));
        assert_eq!(cwd_for(Some("nested")).as_deref(), Some("/work/root"));
        // A group inside a worktree belongs to that checkout.
        assert_eq!(cwd_for(Some("wt-group")).as_deref(), Some("/work/wt"));
    }

    #[test]
    fn create_keeps_the_callers_folder_without_a_known_project() {
        assert_eq!(cwd_for(None), None);
        assert_eq!(cwd_for(Some("")), None);
        // Desktop-owned or unknown ids, folders without a path, broken trees.
        assert_eq!(cwd_for(Some("unknown")), None);
        assert_eq!(cwd_for(Some("folder")), None);
        assert_eq!(cwd_for(Some("loop-a")), None);
        assert_eq!(
            default_create_cwd(&Value::Null, &json!({ "project_id": "root" })),
            None
        );
    }
}
