//! Fork-only: the shared Super Agent state — which Session is the Router,
//! which Sessions are its Workers, and the supervisor's settings.
//!
//! The Router mark is one app-state key, `super_agent: {session_id, since}`;
//! a Worker carries a marker in its own session dir,
//! `app-sessions/<id>/supervision.json` `{router_id, since, origin}`. A
//! marker (not the manifest's `spawned_by`) is the Worker identity: a
//! handed-over Worker was never spawned by its Router, and rewriting a
//! stopped Worker's manifest would bump the `updated_at` its keep-limit
//! rank reads. Tearing a session dir down on Resume or Reload drops the
//! marker with it, which is exactly "a user restart makes it the user's".

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

mod config;
pub use config::{config_from_state, load_config, SupervisorConfig};
mod controller;
pub use controller::{
    clear_super_agent, hand_over_to_super_agent, set_super_agent, with_summary_fields,
    SessionFacts, VerbError, VerbOutcome, CLAUDE_CODE_RUNTIME_ID,
};

/// App-state key holding the Router mark.
pub const ROUTER_MARK_KEY: &str = "super_agent";

/// The Router's session id, if one is marked. Re-read per call, like every
/// other app-state policy, so a mark made by any frontend applies at once.
pub fn router_id() -> Option<String> {
    router_id_in(&crate::app_state::load().ok()?)
}

/// The Router id in a raw app-state document. A malformed mark is no mark.
pub fn router_id_in(state: &Value) -> Option<String> {
    router_id_in_map(state.as_object()?)
}

fn router_id_in_map(state: &Map<String, Value>) -> Option<String> {
    state
        .get(ROUTER_MARK_KEY)?
        .get("session_id")?
        .as_str()
        .filter(|id| valid_session_id(id))
        .map(str::to_string)
}

/// Make `session_id` the Router (one per workspace: it replaces any other).
pub fn set_router_mark(session_id: &str) -> Result<(), String> {
    crate::app_state::edit(|state| set_router_mark_in(state, session_id, now_ms()))
}

/// Drop the Router mark, whoever holds it.
pub fn clear_router_mark() -> Result<(), String> {
    crate::app_state::edit(|state| Ok(clear_router_mark_in(state))).map(|_| ())
}

pub(crate) fn set_router_mark_in(
    state: &mut Map<String, Value>,
    session_id: &str,
    since: u64,
) -> Result<(), String> {
    if !valid_session_id(session_id) {
        return Err(format!("'{session_id}' is not a session id"));
    }
    state.insert(
        ROUTER_MARK_KEY.into(),
        serde_json::json!({ "session_id": session_id, "since": since }),
    );
    Ok(())
}

/// Clear the mark in place. The key is nulled, never removed: app-state
/// refuses a write that drops a top-level key. `false` when nothing was set.
pub(crate) fn clear_router_mark_in(state: &mut Map<String, Value>) -> bool {
    match state.get_mut(ROUTER_MARK_KEY) {
        Some(mark) if !mark.is_null() => {
            *mark = Value::Null;
            true
        }
        _ => false,
    }
}

/// The MCP grants with the marked Router holding Create & remove: the user
/// made it the Router, which implies lifecycle rights. Its reach is kept;
/// every other Session's grant is the user's, untouched.
pub(crate) fn grant_override(
    state: &Value,
    grants: std::collections::HashMap<String, crate::state::McpGrant>,
) -> std::collections::HashMap<String, crate::state::McpGrant> {
    let Some(router) = router_id_in(state) else {
        return grants;
    };
    let reach = grants
        .get(&router)
        .map_or(crate::state::McpScope::Project, |grant| grant.reach);
    let mut overridden = grants;
    overridden.insert(
        router,
        crate::state::McpGrant {
            role: crate::state::McpRole::Manage,
            reach,
        },
    );
    overridden
}

/// Being the Router implies `mcp_worktree_access` for that one Session.
pub(crate) fn router_has_worktree_access(state: &Value, caller_id: Option<&str>) -> bool {
    caller_id.is_some_and(|caller| router_id_in(state).as_deref() == Some(caller))
}

/// The MCP activity status of a running Session the Host has not published
/// yet (§8e). While a Host worker runs, a missing entry means "not known
/// yet", never "idle" — otherwise every wait for idle returns at once
/// against a Session that just started. Without a Host nothing publishes
/// activity, and the old answer stays.
pub fn running_status_without_activity(host_running: bool) -> &'static str {
    if host_running {
        "unknown"
    } else {
        "idle"
    }
}

/// Whether this workspace's Host worker holds its serve lease.
pub fn host_worker_running() -> bool {
    host_worker_running_at(&crate::app_paths::unpeel_home())
}

/// The lease is the worker's flock on `<home>/serve.lock` (see
/// `unpeel-serve` `driver::is_running_at`); stale files never count. The
/// probe takes a *shared* lock, so concurrent probes never see each other
/// as a Host, and releases it at once.
pub(crate) fn host_worker_running_at(home: &std::path::Path) -> bool {
    use std::os::fd::AsRawFd;
    let Ok(file) = std::fs::File::open(home.join("serve.lock")) else {
        return false;
    };
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0 {
        let _ = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        false
    } else {
        std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock
    }
}

/// What one id replacement changed.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Replaced {
    pub mark_moved: bool,
    pub markers_changed: usize,
}

/// A Session id was replaced (`Some(new)`: Resume) or removed (`None`).
/// The Router mark follows the id or is dropped; Workers of the old id are
/// re-pointed at the new one, or freed when their Router is gone. Called
/// once from `session_ops::rewrite_shared_session_references`, which runs
/// on Resume, removal, and failed-restart cleanup.
pub fn on_session_replaced(old_id: &str, replacement_id: Option<&str>) -> Result<(), String> {
    let outcome = on_session_replaced_at(
        &crate::app_paths::app_state_path(),
        &crate::app_paths::app_sessions_root(),
        old_id,
        replacement_id,
    );
    // A partial failure may still have changed something: announce both.
    let (mark_moved, markers_changed) = match &outcome {
        Ok(changed) => (changed.mark_moved, changed.markers_changed > 0),
        Err(_) => (true, true),
    };
    if mark_moved {
        crate::state_bus::announce(
            crate::state_bus::Change::AppState,
            crate::session_ops::own_listener_port_public(),
        );
    }
    if markers_changed {
        announce_markers();
    }
    // A resumed Router is a new process: it is sent its instructions again.
    let router_resumed = outcome.as_ref().is_ok_and(|changed| changed.mark_moved);
    if let Some(new_id) = replacement_id.filter(|_| router_resumed) {
        controller::router_resumed(new_id);
    }
    outcome.map(|_| ())
}

pub(crate) fn on_session_replaced_at(
    state_path: &std::path::Path,
    sessions_root: &std::path::Path,
    old_id: &str,
    replacement_id: Option<&str>,
) -> Result<Replaced, String> {
    // A same-id Reload keeps every reference as it is.
    if replacement_id == Some(old_id) {
        return Ok(Replaced::default());
    }
    let mark = move_router_mark_at(state_path, old_id, replacement_id);
    let markers = rewrite_worker_markers_in(sessions_root, old_id, replacement_id);
    let inbox = transfer_inbox(old_id, replacement_id);
    match (mark, markers, inbox) {
        (Ok(mark_moved), Ok(markers_changed), Ok(())) => Ok(Replaced {
            mark_moved,
            markers_changed,
        }),
        (mark, markers, inbox) => Err([mark.err(), markers.err(), inbox.err()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join("; ")),
    }
}

/// The Inbox follows its Session (ticket 02): `session_inbox::transfer(old,
/// new)` on Resume and `session_inbox::remove(old)` on removal go here.
fn transfer_inbox(_old_id: &str, _replacement_id: Option<&str>) -> Result<(), String> {
    Ok(())
}

/// Move or drop the mark when `old_id` holds it. Reads first so the common
/// case (an ordinary Session) never rewrites app-state.
fn move_router_mark_at(
    state_path: &std::path::Path,
    old_id: &str,
    replacement_id: Option<&str>,
) -> Result<bool, String> {
    let state = crate::app_state::load_for_edit_at(state_path)
        .map_err(|error| format!("Super Agent mark: {error}"))?;
    if router_id_in(&state).as_deref() != Some(old_id) {
        return Ok(false);
    }
    crate::app_state::edit_at(state_path, |state| {
        Ok(replace_router_mark_in(state, old_id, replacement_id))
    })
    .map_err(|error| format!("Super Agent mark: {error}"))
}

/// Re-checked under the app-state lock; `since` survives a Resume.
fn replace_router_mark_in(
    state: &mut Map<String, Value>,
    old_id: &str,
    replacement_id: Option<&str>,
) -> bool {
    if router_id_in_map(state).as_deref() != Some(old_id) {
        return false;
    }
    match replacement_id {
        Some(new_id) => {
            if let Some(mark) = state
                .get_mut(ROUTER_MARK_KEY)
                .and_then(Value::as_object_mut)
            {
                mark.insert("session_id".into(), Value::String(new_id.to_owned()));
            }
            true
        }
        None => clear_router_mark_in(state),
    }
}

/// Re-point (or, with `None`, remove) every marker naming `old_id` as its
/// Router. Returns how many changed; one bad dir never stops the rest.
fn rewrite_worker_markers_in(
    sessions_root: &std::path::Path,
    old_id: &str,
    replacement_id: Option<&str>,
) -> Result<usize, String> {
    let mut changed = 0;
    let mut errors = Vec::new();
    for worker_id in workers_of_in(sessions_root, old_id) {
        let dir = sessions_root.join(&worker_id);
        let result = match (replacement_id, read_worker_marker_in(&dir)) {
            (Some(new_id), Some(marker)) => write_worker_marker_in(
                &dir,
                &WorkerMarker {
                    router_id: new_id.to_owned(),
                    ..marker
                },
            )
            .map(|()| true),
            (None, Some(_)) => remove_worker_marker_in(&dir),
            // Removed between the scan and this read.
            (_, None) => Ok(false),
        };
        match result {
            Ok(true) => changed += 1,
            Ok(false) => {}
            Err(error) => errors.push(format!("Worker {worker_id}: {error}")),
        }
    }
    if errors.is_empty() {
        Ok(changed)
    } else {
        Err(errors.join("; "))
    }
}

/// The Worker marker's file name inside a session dir.
const WORKER_MARKER_FILE: &str = "supervision.json";

/// How a Session became a Worker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerOrigin {
    /// The Router created it with `sessions create`.
    Created,
    /// The user handed it over (right-click ▸ Hand to Super Agent).
    HandedOver,
}

/// `app-sessions/<id>/supervision.json`: this Session works for `router_id`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WorkerMarker {
    pub router_id: String,
    /// Unix ms the Session became a Worker.
    pub since: u64,
    pub origin: WorkerOrigin,
}

/// The Worker marker of `session_id`, if it is one.
pub fn read_worker_marker(session_id: &str) -> Option<WorkerMarker> {
    read_worker_marker_in(&session_dir(session_id)?)
}

/// Whether `session_id` is some Router's Worker (stopped Workers included).
pub fn is_worker(session_id: &str) -> bool {
    read_worker_marker(session_id).is_some()
}

/// Mark `session_id` as a Worker, replacing any earlier marker.
pub fn write_worker_marker(session_id: &str, marker: &WorkerMarker) -> Result<(), String> {
    let dir =
        session_dir(session_id).ok_or_else(|| format!("'{session_id}' is not a session id"))?;
    write_worker_marker_in(&dir, marker)?;
    announce_markers();
    Ok(())
}

/// Make `session_id` an ordinary Session again. Absent is not an error.
pub fn remove_worker_marker(session_id: &str) -> Result<(), String> {
    let dir =
        session_dir(session_id).ok_or_else(|| format!("'{session_id}' is not a session id"))?;
    if remove_worker_marker_in(&dir)? {
        announce_markers();
    }
    Ok(())
}

/// Every Session marked as `router_id`'s Worker, by id.
pub fn workers_of(router_id: &str) -> Vec<String> {
    workers_of_in(&crate::app_paths::app_sessions_root(), router_id)
}

pub(crate) fn read_worker_marker_in(dir: &std::path::Path) -> Option<WorkerMarker> {
    let raw = std::fs::read(dir.join(WORKER_MARKER_FILE)).ok()?;
    serde_json::from_slice(&raw).ok()
}

/// Same-dir temp + rename, like `unread.json`: readers see the old marker or
/// the new one, never a torn file.
pub(crate) fn write_worker_marker_in(
    dir: &std::path::Path,
    marker: &WorkerMarker,
) -> Result<(), String> {
    if !dir.is_dir() {
        return Err(format!("no session dir {}", dir.display()));
    }
    let tmp = dir.join(".supervision.json.tmp");
    let body = serde_json::to_vec(marker).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, dir.join(WORKER_MARKER_FILE))
        .map_err(|e| format!("rename {}: {e}", tmp.display()))
}

/// `Ok(true)` when a marker was removed.
pub(crate) fn remove_worker_marker_in(dir: &std::path::Path) -> Result<bool, String> {
    match std::fs::remove_file(dir.join(WORKER_MARKER_FILE)) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "remove Worker marker in {}: {error}",
            dir.display()
        )),
    }
}

/// Scans session dirs directly — not `list_manifests`, which refreshes
/// health (and rewrites manifests) as a side effect. Sorted by id.
pub(crate) fn workers_of_in(sessions_root: &std::path::Path, router_id: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(sessions_root) else {
        return Vec::new();
    };
    let mut workers: Vec<String> = entries
        .flatten()
        .filter(|entry| {
            read_worker_marker_in(&entry.path()).is_some_and(|marker| marker.router_id == router_id)
        })
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    workers.sort();
    workers
}

/// No in-process channel follows a marker write, so the announce includes
/// this process (port `None`), as `session_ops::mark_unread` does.
fn announce_markers() {
    crate::state_bus::announce(crate::state_bus::Change::SessionMarkers, None);
}

fn session_dir(session_id: &str) -> Option<std::path::PathBuf> {
    valid_session_id(session_id).then(|| crate::app_paths::app_sessions_root().join(session_id))
}

/// Session ids name directories under `app-sessions/`.
fn valid_session_id(id: &str) -> bool {
    !id.trim().is_empty() && !id.contains('/') && !id.contains('\\') && !id.contains("..")
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private app-state file; never the process-global `UNPEEL_HOME`.
    fn with_state<T>(body: impl FnOnce(&std::path::Path) -> T) -> T {
        let dir = std::env::temp_dir().join(format!("sa-state-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let outcome = body(&dir.join("app-state.json"));
        let _ = std::fs::remove_dir_all(&dir);
        outcome
    }

    fn state_at(path: &std::path::Path) -> Value {
        crate::app_state::load_for_edit_at(path).unwrap()
    }

    #[test]
    fn router_mark_is_set_read_and_cleared_through_app_state() {
        with_state(|path| {
            assert_eq!(router_id_in(&state_at(path)), None);

            crate::app_state::edit_at(path, |state| set_router_mark_in(state, "router-1", 42))
                .unwrap();
            let state = state_at(path);
            assert_eq!(router_id_in(&state).as_deref(), Some("router-1"));
            assert_eq!(state["super_agent"]["since"], 42);

            let cleared =
                crate::app_state::edit_at(path, |state| Ok(clear_router_mark_in(state))).unwrap();
            assert!(cleared);
            // The key stays (app-state never drops a top-level key), empty.
            let state = state_at(path);
            assert_eq!(router_id_in(&state), None);
            assert!(state.get("super_agent").is_some_and(Value::is_null));
        });
    }

    #[test]
    fn clearing_without_a_mark_adds_no_key() {
        with_state(|path| {
            let cleared =
                crate::app_state::edit_at(path, |state| Ok(clear_router_mark_in(state))).unwrap();
            assert!(!cleared);
            assert!(state_at(path).get("super_agent").is_none());
        });
    }

    #[test]
    fn setting_a_mark_rejects_ids_that_are_not_session_ids() {
        let mut state = Map::new();
        for bad in ["", "  ", "../escape", "a/b", "a\\b"] {
            assert!(set_router_mark_in(&mut state, bad, 1).is_err(), "{bad:?}");
        }
        assert!(state.is_empty());
    }

    /// A private `app-sessions` root with one dir per given session id.
    fn with_sessions<T>(ids: &[&str], body: impl FnOnce(&std::path::Path) -> T) -> T {
        let root = std::env::temp_dir().join(format!("sa-sessions-{}", uuid::Uuid::new_v4()));
        for id in ids {
            std::fs::create_dir_all(root.join(id)).unwrap();
        }
        let outcome = body(&root);
        let _ = std::fs::remove_dir_all(&root);
        outcome
    }

    fn marker(router_id: &str, origin: WorkerOrigin) -> WorkerMarker {
        WorkerMarker {
            router_id: router_id.into(),
            since: 7,
            origin,
        }
    }

    #[test]
    fn worker_marker_round_trips_and_is_removed() {
        with_sessions(&["w1"], |root| {
            let dir = root.join("w1");
            assert_eq!(read_worker_marker_in(&dir), None);

            write_worker_marker_in(&dir, &marker("r", WorkerOrigin::HandedOver)).unwrap();
            assert_eq!(
                read_worker_marker_in(&dir),
                Some(marker("r", WorkerOrigin::HandedOver))
            );
            let raw: Value =
                serde_json::from_slice(&std::fs::read(dir.join("supervision.json")).unwrap())
                    .unwrap();
            assert_eq!(raw["origin"], "handed_over");
            assert_eq!(raw["router_id"], "r");

            assert!(remove_worker_marker_in(&dir).unwrap());
            assert_eq!(read_worker_marker_in(&dir), None);
            // Removing an absent marker is not an error.
            assert!(!remove_worker_marker_in(&dir).unwrap());
            // Atomic write: no temp file left behind.
            let leftovers: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().collect();
            assert!(leftovers.is_empty(), "{leftovers:?}");
        });
    }

    #[test]
    fn a_worker_marker_needs_an_existing_session_dir() {
        with_sessions(&[], |root| {
            let error =
                write_worker_marker_in(&root.join("gone"), &marker("r", WorkerOrigin::Created))
                    .unwrap_err();
            assert!(error.contains("no session dir"), "{error}");
        });
    }

    #[test]
    fn workers_of_lists_only_that_routers_workers() {
        with_sessions(&["a", "b", "c", "d", "junk"], |root| {
            write_worker_marker_in(&root.join("a"), &marker("r1", WorkerOrigin::Created)).unwrap();
            write_worker_marker_in(&root.join("c"), &marker("r1", WorkerOrigin::HandedOver))
                .unwrap();
            write_worker_marker_in(&root.join("d"), &marker("r2", WorkerOrigin::Created)).unwrap();
            std::fs::write(root.join("junk").join("supervision.json"), b"{not json").unwrap();

            assert_eq!(workers_of_in(root, "r1"), ["a", "c"]);
            assert_eq!(workers_of_in(root, "r2"), ["d"]);
            assert!(workers_of_in(root, "nobody").is_empty());
            assert!(workers_of_in(&root.join("missing-root"), "r1").is_empty());
        });
    }

    /// A Router `old` with Workers `a` and `c`, and `d` working for someone else.
    fn router_with_workers(path: &std::path::Path, root: &std::path::Path) {
        crate::app_state::edit_at(path, |state| set_router_mark_in(state, "old", 5)).unwrap();
        write_worker_marker_in(&root.join("a"), &marker("old", WorkerOrigin::Created)).unwrap();
        write_worker_marker_in(&root.join("c"), &marker("old", WorkerOrigin::HandedOver)).unwrap();
        write_worker_marker_in(&root.join("d"), &marker("other", WorkerOrigin::Created)).unwrap();
    }

    #[test]
    fn a_resumed_router_keeps_its_mark_and_its_workers() {
        with_state(|path| {
            with_sessions(&["a", "c", "d"], |root| {
                router_with_workers(path, root);

                let outcome = on_session_replaced_at(path, root, "old", Some("new")).unwrap();
                assert!(outcome.mark_moved);
                assert_eq!(outcome.markers_changed, 2);

                let state = state_at(path);
                assert_eq!(router_id_in(&state).as_deref(), Some("new"));
                assert_eq!(
                    state["super_agent"]["since"], 5,
                    "the Router keeps its since"
                );
                assert_eq!(workers_of_in(root, "new"), ["a", "c"]);
                assert!(workers_of_in(root, "old").is_empty());
                // Origin and since survive the move; others' Workers are untouched.
                assert_eq!(
                    read_worker_marker_in(&root.join("c")),
                    Some(marker("new", WorkerOrigin::HandedOver))
                );
                assert_eq!(workers_of_in(root, "other"), ["d"]);
            });
        });
    }

    #[test]
    fn a_removed_router_leaves_no_mark_and_frees_its_workers() {
        with_state(|path| {
            with_sessions(&["a", "c", "d"], |root| {
                router_with_workers(path, root);

                let outcome = on_session_replaced_at(path, root, "old", None).unwrap();
                assert!(outcome.mark_moved);
                assert_eq!(outcome.markers_changed, 2);

                assert_eq!(router_id_in(&state_at(path)), None);
                assert_eq!(read_worker_marker_in(&root.join("a")), None);
                assert_eq!(read_worker_marker_in(&root.join("c")), None);
                assert_eq!(workers_of_in(root, "other"), ["d"]);
            });
        });
    }

    #[test]
    fn replacing_an_ordinary_session_changes_nothing() {
        with_state(|path| {
            with_sessions(&["a", "c", "d"], |root| {
                router_with_workers(path, root);
                let before = std::fs::read(path).unwrap();

                for replacement in [Some("fresh"), None] {
                    let outcome = on_session_replaced_at(path, root, "a", replacement).unwrap();
                    assert!(!outcome.mark_moved);
                    assert_eq!(outcome.markers_changed, 0);
                }
                // Not even rewritten: no mark to move means no app-state write.
                assert_eq!(std::fs::read(path).unwrap(), before);
                assert_eq!(workers_of_in(root, "old"), ["a", "c"]);
            });
        });
    }

    #[test]
    fn a_same_id_reload_is_a_no_op() {
        with_state(|path| {
            with_sessions(&["a", "c", "d"], |root| {
                router_with_workers(path, root);
                let outcome = on_session_replaced_at(path, root, "old", Some("old")).unwrap();
                assert!(!outcome.mark_moved);
                assert_eq!(outcome.markers_changed, 0);
                assert_eq!(router_id_in(&state_at(path)).as_deref(), Some("old"));
                assert_eq!(workers_of_in(root, "old"), ["a", "c"]);
            });
        });
    }

    #[test]
    fn only_the_marked_router_is_treated_as_create_and_remove() {
        use crate::state::{McpGrant, McpRole, McpScope};
        let read = McpGrant {
            role: McpRole::Read,
            reach: McpScope::Project,
        };
        let write = McpGrant {
            role: McpRole::Write,
            reach: McpScope::Project,
        };
        let grants = std::collections::HashMap::from([
            ("router".to_string(), read),
            ("writer".to_string(), write),
        ]);
        let marked = serde_json::json!({ "super_agent": { "session_id": "router", "since": 1 } });

        let overridden = grant_override(&marked, grants.clone());
        assert_eq!(overridden["router"].role, McpRole::Manage);
        assert_eq!(overridden["writer"], write);
        assert_eq!(overridden.len(), 2);

        // A Router without an explicit grant gets one.
        let fresh = grant_override(&marked, std::collections::HashMap::new());
        assert_eq!(fresh["router"].role, McpRole::Manage);
        assert_eq!(fresh["router"].reach, McpScope::Project);

        // No mark (or a cleared one): the user's grants, untouched.
        for unmarked in [
            serde_json::json!({}),
            serde_json::json!({ "super_agent": null }),
        ] {
            assert_eq!(grant_override(&unmarked, grants.clone()), grants);
        }
    }

    #[test]
    fn being_the_router_implies_worktree_access() {
        let marked = serde_json::json!({ "super_agent": { "session_id": "router", "since": 1 } });
        assert!(router_has_worktree_access(&marked, Some("router")));
        assert!(!router_has_worktree_access(&marked, Some("worker")));
        assert!(!router_has_worktree_access(&marked, None));
        assert!(!router_has_worktree_access(
            &serde_json::json!({}),
            Some("router")
        ));
    }

    #[test]
    fn a_running_session_without_activity_reads_unknown_while_a_host_runs() {
        assert_eq!(running_status_without_activity(true), "unknown");
        // No Host publishes activity at all: today's answer.
        assert_eq!(running_status_without_activity(false), "idle");
    }

    #[test]
    fn the_host_worker_counts_as_running_only_while_its_lease_is_held() {
        use std::os::fd::AsRawFd;
        let home = std::env::temp_dir().join(format!("sa-home-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        assert!(!host_worker_running_at(&home), "no lease file");

        let lease = std::fs::File::create(home.join("serve.lock")).unwrap();
        assert!(!host_worker_running_at(&home), "a stale lease file");

        assert_eq!(
            unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        assert!(host_worker_running_at(&home), "a held lease");
        // Probing never takes the lease from its holder.
        assert!(host_worker_running_at(&home));

        drop(lease);
        assert!(!host_worker_running_at(&home), "released");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_malformed_mark_reads_as_no_router() {
        for junk in [
            serde_json::json!({ "super_agent": "router-1" }),
            serde_json::json!({ "super_agent": { "session_id": 7 } }),
            serde_json::json!({ "super_agent": { "session_id": "" } }),
            serde_json::json!({ "super_agent": { "session_id": "../x" } }),
        ] {
            assert_eq!(router_id_in(&junk), None, "{junk}");
        }
    }
}
