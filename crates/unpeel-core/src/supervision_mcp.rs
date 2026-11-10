//! Fork-only: the Super Agent seams in the unified MCP server. Each is called
//! by a one-line `// Fork-only` hunk in `mcp_host.rs` and, by default,
//! leaves upstream behavior untouched, so later Super Agent work lands here
//! instead of in `mcp_host.rs`.

use serde_json::Value;

use crate::session_host::HostedSessionManifest;
use crate::state::SessionInfo;

mod inbox;
mod workers;

/// An extra domain action: arguments in, the tool's text result out.
pub(crate) type Handler = fn(&Value) -> Result<String, String>;

/// Extra `sessions` actions (name, handler). Their names join the advertised
/// action enum; each runs behind the same gate as upstream's actions.
const SESSIONS_ACTIONS: &[(&str, Handler)] = &[
    ("inbox", inbox::inbox_action),
    ("stop", workers::control::stop_action),
];

/// Extra `workspace` actions, as `SESSIONS_ACTIONS`.
const WORKSPACE_ACTIONS: &[(&str, Handler)] = &[
    ("list_projects", crate::workspace_tools::tool_list_projects),
    ("create_group", crate::supervision_groups::tool_create_group),
    ("rename_group", crate::supervision_groups::tool_rename_group),
    ("remove_group", crate::supervision_groups::tool_remove_group),
    ("move_session", crate::supervision_groups::tool_move_session),
];

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

/// Extra schema properties per tool.
fn extra_properties(tool: &str) -> Vec<(&'static str, Value)> {
    match tool {
        "sessions" => [inbox::schema_properties(), workers::schema_properties()].concat(),
        "workspace" => [
            crate::supervision_groups::schema_properties(),
            crate::schedules_mcp::schema_properties(),
        ]
        .concat(),
        _ => Vec::new(),
    }
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

/// The unified server's `initialize` result with the Super Agent's
/// after-compaction rule after upstream's `instructions`.
pub(crate) fn extend_instructions(result: Value) -> Value {
    let mut result = result;
    if let Some(upstream) = result.get("instructions").and_then(Value::as_str) {
        let extended = format!("{upstream} {}", compaction_rule());
        result["instructions"] = Value::String(extended);
    }
    result
}

/// MCP server instructions stay in Claude Code's system prompt, which a
/// compaction does not summarize, so this rule outlasts a summary that drops
/// the Router skill. Every Session receives it, so it says whom it is for.
fn compaction_rule() -> String {
    format!(
        "If you are this workspace's Super Agent, your instructions are skills read {}. \
         After a compaction, call sessions current before starting anything: super_agent: \
         true there means you are the Super Agent, and its Worker cards show what is \
         already running.",
        crate::skills_builtin::ROUTER_SKILL_ID
    )
}

/// `action: "help"` sections for the extra actions of `tool`, shaped like
/// `legacy_sessions_tool_definitions` entries: `(action, {description,
/// inputSchema})`.
pub(crate) fn help_docs(tool: &str) -> Vec<(String, Value)> {
    if tool == "workspace" {
        let mut docs = crate::workspace_tools::help_docs();
        docs.extend(crate::supervision_groups::help_docs());
        return docs;
    }
    if tool == "sessions" {
        return [inbox::help_doc(), workers::help_docs()].concat();
    }
    Vec::new()
}

/// `report` from `caller` to `target`, taken over before upstream's write
/// gate; `gate` is that gate. While a Host worker runs the report passes
/// it and is queued in the target's Inbox (`inbox.rs`). `None`: upstream's
/// paste path.
pub(crate) fn route_report(
    args: &Value,
    caller: &HostedSessionManifest,
    target: &HostedSessionManifest,
    gate: &dyn Fn() -> Result<(), String>,
) -> Option<Result<String, String>> {
    inbox::route_report(args, caller, target, gate)
}

/// Upstream's immediate-paste `report` result, marked as such.
pub(crate) fn immediate_report_result(message: String) -> String {
    inbox::immediate_report_result(message)
}

/// The `report` address of this workspace's Router, the Super Agent (#82).
/// Its id changes on every Resume, and a Run is told nothing about it.
const ROUTER_ADDRESS: &str = "super_agent";

/// The Session a `report` to `session_id` goes to: the `super_agent`
/// address is the Router marked now, read at send time; anything else is
/// the id as given. With no Super Agent the report fails here, before any
/// write gate, so it never waits on an approval prompt.
pub(crate) fn resolve_report_target(session_id: &str) -> Result<String, String> {
    report_target(session_id, crate::supervision::router_id)
}

fn report_target(
    session_id: &str,
    router_id: impl FnOnce() -> Option<String>,
) -> Result<String, String> {
    if session_id.trim() != ROUTER_ADDRESS {
        return Ok(session_id.to_owned());
    }
    router_id().ok_or_else(|| {
        format!(
            "No Super Agent in this workspace, so nothing was sent: session_id \
{ROUTER_ADDRESS:?} reaches the Session the user made Super Agent. Report to a session id \
from list instead."
        )
    })
}

/// `sessions list` rows with the Router's marked `super_agent: true`
/// (#82), the mark read once per list; every other row is left as it was.
pub(crate) fn mark_router_rows(rows: Vec<Value>) -> Vec<Value> {
    mark_rows(rows, crate::supervision::router_id().as_deref())
}

fn mark_rows(rows: Vec<Value>, router_id: Option<&str>) -> Vec<Value> {
    rows.into_iter()
        .map(|row| {
            let is_router =
                router_id.is_some() && row.get("id").and_then(Value::as_str) == router_id;
            merge_extras(
                row,
                is_router.then(|| serde_json::json!({ "super_agent": true })),
            )
        })
        .collect()
}

/// `send_text` to `target_id`, taken over before the write gate, as
/// `route_report`: a Worker's message to its Router goes through the Inbox.
/// `None`: upstream's paste path.
pub(crate) fn route_send_text(
    args: &Value,
    caller: Option<&HostedSessionManifest>,
    target_id: &str,
) -> Option<Result<String, String>> {
    inbox::route_send_text(args, caller, target_id)
}

/// A write from `caller_id` into `target_id` passed the write gate: a
/// Router's write to its Worker leaves the router-touch stamp.
pub(crate) fn note_write(caller_id: &str, target_id: &str) {
    workers::control::note_write(caller_id, target_id)
}

/// `close` of `target` by `caller`, decided here for the Router (its
/// Workers, by marker alone). `None` keeps upstream's `spawned_by` rule.
pub(crate) fn route_close(
    caller: &HostedSessionManifest,
    target: &HostedSessionManifest,
) -> Option<Result<String, String>> {
    workers::control::route_close(caller, target)
}

/// The Super Agent half of one `sessions create`: extra parameters read
/// before the spawn, and the after-spawn step.
#[derive(Debug, Default)]
pub(crate) struct CreateHooks {
    default_cwd: Option<String>,
    /// Set when the Router is starting a Worker.
    worker: Option<workers::WorkerPlan>,
}

/// Read the extra create parameters. An `Err` refuses the create before
/// anything is spawned.
pub(crate) fn create_hooks(
    args: &Value,
    caller: &HostedSessionManifest,
) -> Result<CreateHooks, String> {
    let worker = workers::plan_create_at_home(args, caller)?;
    let default_cwd = worker
        .as_ref()
        .and_then(workers::WorkerPlan::cwd)
        .or_else(|| {
            args.get("project_id")
                .and_then(|_| default_create_cwd(&crate::app_state::load().ok()?, args))
        });
    Ok(CreateHooks {
        default_cwd,
        worker,
    })
}

impl CreateHooks {
    /// The folder to run in when the caller passed no `cwd`; `None` keeps
    /// the caller's own.
    pub(crate) fn default_cwd(&self) -> Option<String> {
        self.default_cwd.clone()
    }

    /// `(command, source preset id)` for a Worker the Router started with
    /// neither `preset` nor `command`: the Router's own agent. `None` keeps
    /// upstream's `resolve_create_command`.
    pub(crate) fn default_command(&self) -> Option<(String, Option<String>)> {
        self.worker
            .as_ref()
            .and_then(workers::WorkerPlan::default_command)
    }

    /// The session record about to be spawned, with any extra fields set.
    pub(crate) fn prepare(&self, session: SessionInfo) -> SessionInfo {
        match &self.worker {
            Some(worker) => worker.prepare(session),
            None => session,
        }
    }

    /// After a successful spawn: record what the new Session is and add any
    /// fields to the create result.
    pub(crate) fn after_spawn(&self, session_id: &str, result: Value) -> Value {
        match &self.worker {
            Some(worker) => worker.after_spawn(session_id, result),
            None => result,
        }
    }
}

/// Extra fields for `sessions current` (`None`: nothing to add): Worker
/// cards for the Router, `router_id` for a Worker.
pub(crate) fn current_extras(caller: &HostedSessionManifest) -> Option<Value> {
    workers::cards::current_extras(&caller.session.id)
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
    workers::control::cap_wait_timeout(caller_id, requested_ms)
}

/// One finished `tool` call: a Router wait the cap cut short says why.
pub(crate) fn explain_wait(
    tool: &str,
    args: &Value,
    result: Result<String, String>,
) -> Result<String, String> {
    workers::control::explain_wait(tool, args, result)
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
        assert_eq!(
            sessions_action_names().collect::<Vec<_>>(),
            ["inbox", "stop"]
        );
        assert_eq!(
            workspace_action_names().collect::<Vec<_>>(),
            [
                "list_projects",
                "create_group",
                "rename_group",
                "remove_group",
                "move_session"
            ]
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
    fn the_super_agent_address_is_the_router_marked_now() {
        let marked = || Some("router-2".to_string());
        assert_eq!(
            report_target("super_agent", marked).as_deref(),
            Ok("router-2")
        );
        assert_eq!(
            report_target(" super_agent ", marked).as_deref(),
            Ok("router-2")
        );
        // Any other target is the id as given, without reading the mark.
        let unread = || -> Option<String> { panic!("the mark is read only for the address") };
        assert_eq!(report_target("4f0c", unread).as_deref(), Ok("4f0c"));
        assert_eq!(
            report_target("Super_Agent", unread).as_deref(),
            Ok("Super_Agent")
        );
    }

    #[test]
    fn the_super_agent_address_fails_clearly_without_a_super_agent() {
        let refused = report_target("super_agent", || None).unwrap_err();
        assert!(refused.contains("No Super Agent"), "{refused}");
        assert!(refused.contains("nothing was sent"), "{refused}");
    }

    #[test]
    fn only_the_routers_row_wears_the_mark() {
        let row = |id: &str| json!({ "id": id, "label": "x" });
        let rows = || vec![row("other"), row("router"), json!({})];
        let marked = mark_rows(rows(), Some("router"));
        assert_eq!(marked[1]["super_agent"], true);
        assert_eq!(marked[1]["id"], "router");
        // Every other row, and every row with no Router, is left as it was.
        assert_eq!([&marked[0], &marked[2]], [&row("other"), &json!({})]);
        assert_eq!(mark_rows(rows(), None), rows());
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
