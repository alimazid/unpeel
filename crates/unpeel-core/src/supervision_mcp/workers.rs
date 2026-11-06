//! Fork-only: the Router's Workers over MCP (§8b, §16.2, §17). A
//! `sessions create` from the Router starts a Worker: labels, a first task
//! queued in the Worker's own Inbox, an optional worktree, and the
//! `supervisor_max_children` / `supervisor_max_spawns_per_minute` limits.
//! `control.rs` stops and closes Workers, `cards.rs` describes them in
//! `sessions current`. Plain Create & remove callers keep upstream's
//! behavior: only the marked Router gets any of this.

use std::collections::HashSet;
use std::path::PathBuf;

use serde_json::{json, Value};

use crate::session_inbox::{ItemKind, NewItem, Priority, Sender, Store};
use crate::supervision::{WorkerMarker, WorkerOrigin};

pub(super) mod cards;
pub(super) mod control;

/// Where the Worker actions read and write, and how they learn about a
/// Session: the real home (`at_home`), or temp roots in tests.
pub(super) struct Home<'a> {
    pub state: Value,
    pub sessions_root: PathBuf,
    pub inbox: Store,
    /// The worktrees made for Workers (`supervision_worktrees`).
    pub worktrees: crate::supervision_worktrees::Ledger,
    pub facts: &'a dyn Fn(&str) -> Option<Facts>,
    pub now_ms: u64,
}

/// One Session as its manifest (and the published activity) says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Facts {
    pub running: bool,
    pub label: String,
    pub project_id: String,
    /// The group it renders in: a valid move marker, else `project_id`.
    pub group_id: String,
    pub activity_status: String,
}

impl Home<'_> {
    pub fn is_router(&self, session_id: &str) -> bool {
        crate::supervision::router_id_in(&self.state).as_deref() == Some(session_id)
    }

    pub fn marker(&self, session_id: &str) -> Option<WorkerMarker> {
        crate::supervision::valid_session_id(session_id).then_some(())?;
        crate::supervision::read_worker_marker_in(&self.sessions_root.join(session_id))
    }

    /// Whether `session_id` is `router_id`'s Worker by its marker.
    pub fn works_for(&self, session_id: &str, router_id: &str) -> bool {
        self.marker(session_id)
            .is_some_and(|marker| marker.router_id == router_id)
    }

    /// `router_id`'s Workers (stopped ones included), oldest first.
    pub fn workers(&self, router_id: &str) -> Vec<(String, WorkerMarker)> {
        let mut workers: Vec<(String, WorkerMarker)> =
            crate::supervision::workers_of_in(&self.sessions_root, router_id)
                .into_iter()
                .filter_map(|id| {
                    let marker = self.marker(&id)?;
                    Some((id, marker))
                })
                .collect();
        workers.sort_by(|(a, left), (b, right)| (left.since, a).cmp(&(right.since, b)));
        workers
    }
}

/// Run `body` against this workspace's home. Activity is read once.
pub(super) fn at_home<T>(body: impl FnOnce(&Home) -> T) -> T {
    let state = crate::app_state::load().unwrap_or(Value::Null);
    let activity = crate::mcp_host::load_activity_state();
    let known = project_ids(&state);
    let facts = |id: &str| home_facts(id, &activity, &known);
    body(&Home {
        state,
        sessions_root: crate::app_paths::app_sessions_root(),
        inbox: Store::home(),
        worktrees: crate::supervision_worktrees::Ledger::home(),
        facts: &facts,
        now_ms: now_ms(),
    })
}

/// As `at_home`, for calls that only read the Router mark, Worker markers
/// and Inboxes: no manifest or activity is read.
pub(super) fn at_home_without_facts<T>(body: impl FnOnce(&Home) -> T) -> T {
    let no_facts = |_: &str| None;
    body(&Home {
        state: crate::app_state::load().unwrap_or(Value::Null),
        sessions_root: crate::app_paths::app_sessions_root(),
        inbox: Store::home(),
        worktrees: crate::supervision_worktrees::Ledger::home(),
        facts: &no_facts,
        now_ms: now_ms(),
    })
}

fn home_facts(
    session_id: &str,
    activity: &std::collections::HashMap<String, crate::mcp_host::ActivityStateEntry>,
    known_projects: &HashSet<String>,
) -> Option<Facts> {
    crate::supervision::valid_session_id(session_id).then_some(())?;
    let manifest = crate::session_host::load_manifest(session_id)?;
    let group_id = crate::session_ops::project_override_marker(session_id)
        .filter(|project_id| known_projects.contains(project_id))
        .unwrap_or_else(|| manifest.session.project_id.clone());
    Some(Facts {
        running: manifest.state == crate::session_host::HostedSessionState::Running,
        label: crate::session_ops::title_marker(session_id)
            .unwrap_or_else(|| manifest.session.label.clone()),
        project_id: manifest.session.project_id.clone(),
        group_id,
        activity_status: crate::mcp_host::activity_status_for_manifest(activity, &manifest),
    })
}

fn project_ids(state: &Value) -> HashSet<String> {
    state
        .get("projects")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|project| project.get("id")?.as_str().map(str::to_string))
        .collect()
}

pub(super) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

/// Longest `role` or `task` label kept.
pub(super) const MAX_LABEL_CHARS: usize = 120;
/// The `role` App panels carry (`app_open.rs`); a Worker never does.
const APP_PANEL_ROLE: &str = "app-panel";
/// The rate limit's window.
const SPAWN_WINDOW_MS: u64 = 60_000;

/// The Session asking `sessions create`.
pub(super) struct Creator {
    pub id: String,
    pub label: String,
    pub project_id: String,
}

/// Creates (or adopts) a worktree: `workspace_tools::create_and_register`
/// outside tests. Arguments `{branch, base_ref}` and the Project id.
pub(super) type MakeWorktree<'a> = &'a dyn Fn(&Value, &str) -> Result<Value, String>;

/// The worktree a Worker runs in.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PlannedWorktree {
    path: String,
    project_id: String,
    branch: String,
    adopted: bool,
    /// For the cleanup ledger: the base the Router named, and the checkout.
    base_ref: Option<String>,
    repo_path: Option<String>,
}

/// The Super Agent half of one `sessions create` by the Router, decided
/// before anything spawns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkerPlan {
    router_id: String,
    router_label: String,
    role: Option<String>,
    task: Option<String>,
    text: Option<String>,
    worktree: Option<PlannedWorktree>,
}

/// The extra create parameters, validated.
struct WorkerParams {
    role: Option<String>,
    task: Option<String>,
    text: Option<String>,
    worktree: Option<String>,
    base_ref: Option<String>,
}

impl WorkerParams {
    fn from_args(args: &Value) -> Result<Self, String> {
        let params = Self {
            role: label(args, "role")?,
            task: label(args, "task")?,
            text: text(args, "text")?,
            worktree: text(args, "worktree")?,
            base_ref: text(args, "base_ref")?,
        };
        if params.base_ref.is_some() && params.worktree.is_none() {
            return Err("base_ref only goes with worktree=<branch>.".into());
        }
        if params.worktree.is_some() && text(args, "cwd")?.is_some() {
            return Err(
                "Pass either worktree or cwd, not both: a worktree Worker runs in its worktree."
                    .into(),
            );
        }
        Ok(params)
    }

    /// The first Super Agent parameter given, if any.
    fn named(&self) -> Option<&'static str> {
        [
            ("role", self.role.is_some()),
            ("task", self.task.is_some()),
            ("text", self.text.is_some()),
            ("worktree", self.worktree.is_some()),
        ]
        .into_iter()
        .find_map(|(name, given)| given.then_some(name))
    }
}

/// A trimmed, non-empty string parameter.
fn text(args: &Value, key: &str) -> Result<Option<String>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(raw)) => Ok(Some(raw.trim().to_owned()).filter(|raw| !raw.is_empty())),
        Some(_) => Err(format!("'{key}' must be a string")),
    }
}

/// A `role`/`task` label: plain text only (control characters stripped),
/// trimmed and capped, and never the App-panel role.
fn label(args: &Value, key: &str) -> Result<Option<String>, String> {
    let Some(raw) = text(args, key)? else {
        return Ok(None);
    };
    let plain: String = raw.chars().filter(|ch| !ch.is_control()).collect();
    let capped: String = plain.trim().chars().take(MAX_LABEL_CHARS).collect();
    let capped = capped.trim_end().to_owned();
    if capped.eq_ignore_ascii_case(APP_PANEL_ROLE) {
        return Err(format!(
            "'{key}' cannot be \"{APP_PANEL_ROLE}\": role and task are labels for a Worker."
        ));
    }
    Ok(Some(capped).filter(|label| !label.is_empty()))
}

/// The plan for one create, or `None` when the caller is not the Router
/// (upstream's create, unchanged). An `Err` refuses before anything spawns.
pub(super) fn plan_create(
    home: &Home,
    args: &Value,
    caller: &Creator,
    make_worktree: MakeWorktree,
) -> Result<Option<WorkerPlan>, String> {
    let params = WorkerParams::from_args(args)?;
    if !home.is_router(&caller.id) {
        return match params.named() {
            Some(name) => Err(format!(
                "'{name}' is a Super Agent parameter; only the Super Agent starts Workers. \
Create the session without it."
            )),
            None => Ok(None),
        };
    }
    let project_id = text(args, "project_id")?.unwrap_or_else(|| caller.project_id.clone());
    refuse_sidebar_group(&home.state, &project_id)?;
    check_limits(home, &caller.id)?;
    let worktree = match &params.worktree {
        Some(branch) => Some(planned_worktree(
            make_worktree(
                &json!({ "branch": branch, "base_ref": params.base_ref }),
                &project_id,
            )?,
            params.base_ref.clone(),
        )?),
        None => None,
    };
    Ok(Some(WorkerPlan {
        router_id: caller.id.clone(),
        router_label: caller.label.clone(),
        role: params.role,
        task: params.task,
        text: params.text,
        worktree,
    }))
}

/// A root's Sidebar group holds side-panel panes only (§16.2).
fn refuse_sidebar_group(state: &Value, project_id: &str) -> Result<(), String> {
    let is_sidebar = state
        .get("projects")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|project| {
            project.get("id").and_then(Value::as_str) == Some(project_id)
                && project
                    .get("parent_project_id")
                    .and_then(Value::as_str)
                    .is_some_and(|parent| project_id == format!("sidebar-{parent}"))
        });
    if is_sidebar {
        return Err(format!(
            "'{project_id}' is a Project's Sidebar group, which holds side-panel panes only. \
Start the Worker in the Project itself or another group (workspace list_projects)."
        ));
    }
    Ok(())
}

/// `supervisor_max_children` running Workers, and at most
/// `supervisor_max_spawns_per_minute` started by `sessions create` in the
/// last minute — counted from the markers alone, no extra state.
fn check_limits(home: &Home, router_id: &str) -> Result<(), String> {
    let config = crate::supervision::config_from_state(&home.state, false);
    let workers = home.workers(router_id);
    let running = workers
        .iter()
        .filter(|(id, _)| (home.facts)(id).is_some_and(|facts| facts.running))
        .count();
    if running >= config.max_children {
        return Err(format!(
            "You already run {running} Workers, the most the user allows \
(supervisor_max_children = {}). Stop a finished Worker with sessions stop, or keep this task \
queued and tell the user it waits for a free Worker.",
            config.max_children
        ));
    }
    let recent = workers
        .iter()
        .filter(|(_, marker)| {
            marker.origin == WorkerOrigin::Created
                && home.now_ms.saturating_sub(marker.since) < SPAWN_WINDOW_MS
        })
        .count();
    if recent >= config.max_spawns_per_minute as usize {
        return Err(format!(
            "You started {recent} Workers in the last minute, the most allowed \
(supervisor_max_spawns_per_minute = {}). Start this one in a minute.",
            config.max_spawns_per_minute
        ));
    }
    Ok(())
}

/// `create_and_register`'s answer, `{path, project_id, branch, adopted,
/// repo_path}`.
fn planned_worktree(created: Value, base_ref: Option<String>) -> Result<PlannedWorktree, String> {
    let field = |key: &str| {
        created
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| format!("The worktree was created without a {key}."))
    };
    Ok(PlannedWorktree {
        path: field("path")?,
        project_id: field("project_id")?,
        branch: field("branch")?,
        adopted: created
            .get("adopted")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        base_ref,
        repo_path: field("repo_path").ok(),
    })
}

impl PlannedWorktree {
    /// Put it on the cleanup ledger as `owner`'s, so it goes when that
    /// Worker is removed, if merged and clean (§16.4).
    fn record(
        &self,
        ledger: &crate::supervision_worktrees::Ledger,
        owner: &str,
        now_ms: u64,
    ) -> Result<(), String> {
        let repo_path = self.repo_path.clone().ok_or("its checkout is unknown")?;
        let entry = crate::supervision_worktrees::Entry {
            path: self.path.clone(),
            branch: self.branch.clone(),
            base_ref: self.base_ref.clone(),
            repo_path,
            project_id: self.project_id.clone(),
            owner_session_id: owner.to_owned(),
            created_at: now_ms,
        };
        ledger.record(entry, self.adopted)
    }
}

/// The real-home plan for `sessions create` by `caller`.
pub(crate) fn plan_create_at_home(
    args: &Value,
    caller: &crate::session_host::HostedSessionManifest,
) -> Result<Option<WorkerPlan>, String> {
    let creator = Creator {
        id: caller.session.id.clone(),
        label: caller.session.label.clone(),
        project_id: caller.session.project_id.clone(),
    };
    at_home(|home| {
        plan_create(
            home,
            args,
            &creator,
            &crate::workspace_tools::create_and_register,
        )
    })
}

impl WorkerPlan {
    /// The folder the Worker runs in when it has a worktree.
    pub(crate) fn cwd(&self) -> Option<String> {
        self.worktree.as_ref().map(|worktree| worktree.path.clone())
    }

    /// The session record about to be spawned: its labels, and its
    /// worktree project.
    pub(crate) fn prepare(&self, session: crate::state::SessionInfo) -> crate::state::SessionInfo {
        let session = crate::state::SessionInfo {
            role: self.role.clone(),
            task: self.task.clone(),
            ..session
        };
        match &self.worktree {
            Some(worktree) => crate::state::SessionInfo {
                project_id: worktree.project_id.clone(),
                worktree_path: Some(worktree.path.clone()),
                worktree_branch: Some(worktree.branch.clone()),
                ..session
            },
            None => session,
        }
    }

    /// After the spawn, against the real home: record the Worker and
    /// announce it.
    pub(crate) fn after_spawn(&self, session_id: &str, result: Value) -> Value {
        let result = at_home(|home| self.record_at(home, session_id, result));
        crate::state_bus::announce(crate::state_bus::Change::SessionMarkers, None);
        result
    }

    /// Mark `session_id` as the Router's Worker and queue its first task in
    /// its own Inbox; the create result gains what happened. A failure here
    /// can't undo the spawn, so it becomes a `warning`.
    pub(super) fn record_at(&self, home: &Home, session_id: &str, result: Value) -> Value {
        let mut result = result;
        let mut warnings = Vec::new();
        let marker = WorkerMarker {
            router_id: self.router_id.clone(),
            since: home.now_ms,
            origin: WorkerOrigin::Created,
        };
        match crate::supervision::write_worker_marker_in(
            &home.sessions_root.join(session_id),
            &marker,
        ) {
            Ok(()) => result["worker"] = Value::Bool(true),
            Err(error) => warnings.push(format!(
                "It could not be marked as your Worker ({error}), so it reports to no one."
            )),
        }
        if let Some(text) = &self.text {
            match home
                .inbox
                .enqueue(session_id, self.task_item(text), home.now_ms)
            {
                Ok(queued) => result["task_item_id"] = Value::String(queued.item_id),
                Err(error) => warnings.push(format!(
                    "Its task could not be queued ({error}); send it with send_text."
                )),
            }
        }
        if let Some(worktree) = &self.worktree {
            result["project_id"] = Value::String(worktree.project_id.clone());
            result["worktree"] = json!({
                "branch": worktree.branch,
                "path": worktree.path,
                "adopted": worktree.adopted,
            });
            if let Err(error) = worktree.record(&home.worktrees, session_id, home.now_ms) {
                warnings.push(format!(
                    "Its worktree is not on the cleanup ledger ({error}), so removing the \
Worker leaves it in place."
                ));
            }
        }
        result["note"] = Value::String(self.note());
        if !warnings.is_empty() {
            result["warning"] = Value::String(warnings.join(" "));
        }
        result
    }

    fn note(&self) -> String {
        let task = if self.text.is_some() {
            "Its task waits in its Inbox and is pasted the first time it is idle. "
        } else {
            "Give it its task with send_text once its prompt is up. "
        };
        format!(
            "{task}Its reports and replies reach your Inbox by themselves; stop it with sessions \
stop when its work is done."
        )
    }

    /// The first task, from the Router (an MCP call never speaks as the
    /// Host): it wakes the Worker, with the task label leading the paste.
    fn task_item(&self, text: &str) -> NewItem {
        NewItem {
            sender: Sender::Session(self.router_id.clone()),
            kind: ItemKind::Task,
            priority: Priority::Wake,
            about: None,
            status: None,
            label: Some(self.router_label.clone()),
            summary: self.task.clone().unwrap_or_default(),
            body: text.to_owned(),
            dedupe_key: None,
        }
    }
}

/// The advertised `sessions` properties `create` gains: names only (`text`
/// is shared with send_text), every byte counts
/// (`advertised_schema_stays_within_the_context_budget`); `help_docs`
/// explains them.
pub(super) fn schema_properties() -> Vec<(&'static str, Value)> {
    vec![
        (
            "role",
            json!({ "type": "string", "description": "create: label, never access" }),
        ),
        ("task", json!({ "type": "string" })),
        ("worktree", json!({ "type": "string" })),
        ("base_ref", json!({ "type": "string" })),
    ]
}

/// `sessions help` for what the Super Agent adds to `create`, `stop`,
/// `close` and `current`.
pub(super) fn help_docs() -> Vec<(String, Value)> {
    let text = |description: &str| json!({ "type": "string", "description": description });
    let section = |description: &str, properties: Value| {
        json!({
            "description": description,
            "inputSchema": { "type": "object", "properties": properties },
        })
    };
    vec![
        (
            "create".into(),
            section(
                "Super Agent only: starting a Worker. Without cwd it runs in project_id's folder \
        (a group runs in its Project's; never the Sidebar group). It is marked as your Worker: its \
        reports and replies reach your Inbox by themselves. At most supervisor_max_children (8) of \
        your Workers run at once, and supervisor_max_spawns_per_minute (6) start per minute; past \
        either the create is refused, so keep the task queued and tell the user.",
                json!({
                    "role": text("A label for the Worker, trimmed, at most 120 characters. It is never the Agent access role and grants nothing."),
                    "task": text("A label for the Worker's task, carried in its reports. Never the Agent access role."),
                    "text": text("The Worker's first task, queued in its own Inbox and pasted the first time it is idle (no wait_for_text then send_text)."),
                    "worktree": text("Run it in a git worktree on this branch (created, or adopted if it exists) of the Project's checkout, registered as a child project. Not with cwd."),
                    "base_ref": text("With worktree: the ref a new branch starts from (default: the mainline)."),
                }),
            ),
        ),
        (
            "stop".into(),
            section(
                "Super Agent only: stop one of your Workers when its work is done. It is stopped, \
        not removed: it stays in the sidebar, greyed out and restartable, and no longer counts \
        against your Worker limit. Anything still queued in its Inbox comes back to yours. If the \
        user restarts it, it is theirs. Returns {session_id, stopped, was_running, returned_items}.",
                json!({ "session_id": text("Your Worker (sessions current lists them).") }),
            ),
        ),
        (
            "close".into(),
            section(
                "For the Super Agent, close removes only your Workers (and App panels you opened), \
        whoever created them; a Worker the user restarted is theirs. Prefer stop.",
                json!({ "session_id": text("Your Worker.") }),
            ),
        ),
        (
            "current".into(),
            section(
                "For the Super Agent: super_agent: true and workers[], one card per Worker \
        {id, label, project_id, group_id, activity_status, last_report_status, preview (its last \
        report or reply, at most 160 characters)}. Call it after a compaction or Resume before \
        starting anything. For a Worker: router_id, the Super Agent it reports to.",
                json!({}),
            ),
        ),
    ]
}

#[cfg(test)]
pub(super) mod tests;
