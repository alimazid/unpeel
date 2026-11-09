//! Which Session a process speaks for (#70, #71).
//!
//! An exported `UNPEEL_SESSION_ID` is a claim, not an identity. A long-lived
//! process that inherited a Session's environment keeps the id after it has
//! stopped being that Session's process, and passes it on to everything it
//! starts: Codex's shared app-server daemon keeps the environment of
//! whichever Session started it and runs other clients' hooks and MCP
//! servers with it. Process ancestry is the authority instead: a process
//! speaks for Session S only when S's recorded pid, verified against its
//! kernel start time (`PidIdentity::Matches`), is the process itself or one
//! of its ancestors. An exported id must pass that check for its own
//! Session; a mismatch is refused, never redirected to another ancestor.
//! Without an exported id, the nearest verified ancestor wins, for launchers
//! that strip their MCP children's environment (cursor-agent, Codex).
//!
//! The MCP gate and every `unpeel` CLI verb (`mcp_host::self_session_id`)
//! and the hook reporters' guard (`unpeel-host __session_identity__`) all
//! ask this module, so the rule holds whichever path an agent uses.
//!
//! Known gap: a daemon started with `setsid` but no double fork stays the
//! child of the process that started it, so while that process lives the
//! daemon's ancestry still reaches its Session. A same-POSIX-session rule
//! would close it, but Claude Code runs every hook and Bash-tool command in
//! a new POSIX session (#74).

use crate::session_host::{self, HostedSessionManifest, HostedSessionState, PidIdentity};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// `unpeel-host` argument the hook reporters run before they write a marker
/// or post: exit 0 when the process speaks for its exported Session,
/// [`REFUSED_EXIT_CODE`] when it provably does not, anything else when it
/// cannot tell (a reporter then keeps its old behavior).
pub const CHECK_ARG: &str = "__session_identity__";
pub const REFUSED_EXIT_CODE: i32 = 3;
pub const UNDECIDED_EXIT_CODE: i32 = 4;

/// Test-only: trust an exported id without the ancestry check, for PTY cases
/// that act as a Session from the harness. Honored only with `UNPEEL_TEST=1`
/// and an `UNPEEL_HOME` that is not the user's real Unpeel home.
pub const TRUST_EXPORTED_ID_ENV: &str = "UNPEEL_TEST_TRUST_SESSION_ENV";

/// How far up the parent chain a match may sit: agent → wrapper shells →
/// hook runner → reporter stays well inside it.
const MAX_ANCESTOR_HOPS: u32 = 12;

/// How long a fresh answer is reused. The unified MCP server asks once per
/// listed Session, so a short memo keeps a list from re-walking the chain
/// per row while a process that loses its ancestry still loses its identity
/// within a second.
const MEMO_TTL: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Identity {
    /// The process descends from this Session's verified pid.
    Verified(String),
    /// The process provably does not speak for the claimed Session (or for
    /// any Session, without a claim).
    Refused(Refusal),
    /// The claimed Session is still launching: its manifest has no pid yet
    /// while its Host is alive. Ask again shortly.
    Undecided,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// No claim, and no verified Session pid on the ancestry.
    NoSession,
    /// The claimed Session has no running manifest.
    NotRunning,
    /// The claimed Session's pid cannot be verified (recycled, or a legacy
    /// manifest without a start time).
    UnverifiedPid,
    /// The claimed Session's pid is not this process or an ancestor.
    NotAnAncestor,
}

impl Refusal {
    pub fn reason(self) -> &'static str {
        match self {
            Refusal::NoSession => "no-session",
            Refusal::NotRunning => "not-running",
            Refusal::UnverifiedPid => "unverified-pid",
            Refusal::NotAnAncestor => "not-an-ancestor",
        }
    }
}

impl Identity {
    pub fn session_id(&self) -> Option<&str> {
        match self {
            Identity::Verified(id) => Some(id),
            _ => None,
        }
    }
}

/// `unpeel-host __session_identity__`: print the verdict for this process
/// (whose ancestry includes the reporter that started it) and return the
/// exit code a hook reporter acts on. Only a live Session that provably is
/// not this process's refuses: a missing manifest may just mean the checker
/// looked in another home, and the Host turns those posts away anyway.
pub fn run_check() -> i32 {
    match current() {
        Identity::Verified(id) => {
            println!("{id}");
            0
        }
        Identity::Refused(refusal @ (Refusal::NotAnAncestor | Refusal::UnverifiedPid)) => {
            println!("{}", refusal.reason());
            REFUSED_EXIT_CODE
        }
        Identity::Refused(refusal @ (Refusal::NotRunning | Refusal::NoSession)) => {
            println!("{}", refusal.reason());
            UNDECIDED_EXIT_CODE
        }
        Identity::Undecided => {
            println!("launching");
            UNDECIDED_EXIT_CODE
        }
    }
}

/// The Session this process speaks for, if it provably speaks for one.
pub fn current_session_id() -> Option<String> {
    static MEMO: Mutex<Option<(Instant, Option<String>)>> = Mutex::new(None);
    if let Ok(memo) = MEMO.lock() {
        if let Some((at, id)) = memo.as_ref() {
            if at.elapsed() < MEMO_TTL {
                return id.clone();
            }
        }
    }
    let id = current().session_id().map(str::to_owned);
    if let Ok(mut memo) = MEMO.lock() {
        *memo = Some((Instant::now(), id.clone()));
    }
    id
}

/// [`current`], asked again while the claimed Session is still launching,
/// for at most `budget`. The MCP gate decides once at startup whether to
/// serve tools, so a gate that starts in the launch window must not settle
/// on "unknown".
pub fn current_waiting(budget: Duration) -> Identity {
    let started = Instant::now();
    loop {
        let identity = current();
        if identity != Identity::Undecided || started.elapsed() >= budget {
            return identity;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// This process's identity, uncached.
pub fn current() -> Identity {
    let pid = std::process::id();
    if let Some(claim) = exported_session_id() {
        if exported_id_is_trusted() {
            return Identity::Verified(claim);
        }
        let manifests: Vec<_> = claimed_manifest(&claim).into_iter().collect();
        return identity_for(pid, Some(&claim), parent_pid, &manifests);
    }
    // Without a claim every running manifest is a candidate. Remember which
    // Session the scan found and re-verify only that one afterwards.
    static FOUND: Mutex<Option<String>> = Mutex::new(None);
    let remembered = FOUND.lock().ok().and_then(|found| found.clone());
    if let Some(id) = remembered {
        let manifests: Vec<_> = session_host::load_manifest(&id).into_iter().collect();
        return identity_for(pid, Some(&id), parent_pid, &manifests);
    }
    let identity = identity_for(pid, None, parent_pid, &running_manifests_unrefreshed());
    if let (Identity::Verified(id), Ok(mut found)) = (&identity, FOUND.lock()) {
        *found = Some(id.clone());
        crate::mcp_host::trace(&format!(
            "recovered caller identity from process ancestry self={id} pid={pid}"
        ));
    }
    identity
}

/// The claimed Session's manifest: from the exported `UNPEEL_SESSION_DIR`
/// when that names the same Session (a reporter whose launcher scrubbed
/// `UNPEEL_HOME` recovers only the Session variables), else from this home.
fn claimed_manifest(claim: &str) -> Option<HostedSessionManifest> {
    std::env::var_os("UNPEEL_SESSION_DIR")
        .filter(|dir| !dir.is_empty())
        .and_then(|dir| std::fs::read(Path::new(&dir).join("manifest.json")).ok())
        .and_then(|raw| serde_json::from_slice::<HostedSessionManifest>(&raw).ok())
        .filter(|manifest| manifest.session.id == claim)
        .or_else(|| session_host::load_manifest(claim))
}

/// The exported `UNPEEL_SESSION_ID`, unless it is empty or a launcher left
/// an unexpanded `${UNPEEL_SESSION_ID}` literal.
pub fn exported_session_id() -> Option<String> {
    let value = std::env::var("UNPEEL_SESSION_ID").ok()?;
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.starts_with("${") {
        return None;
    }
    Some(trimmed.to_string())
}

fn exported_id_is_trusted() -> bool {
    let home = crate::app_paths::unpeel_home();
    trust_switch_applies(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var(TRUST_EXPORTED_ID_ENV).ok().as_deref(),
        std::env::var_os("UNPEEL_HOME")
            .is_some()
            .then_some(home.as_path()),
        &real_homes(),
    )
}

/// The user's real Unpeel homes: `~/.unpeel` under both the account's
/// password-database home and `$HOME`, which a test may have repointed.
fn real_homes() -> Vec<PathBuf> {
    let mut homes = vec![crate::app_paths::real_unpeel_home()];
    if let Some(account_home) = account_home_dir() {
        homes.push(account_home.join(".unpeel"));
    }
    homes
}

#[cfg(unix)]
fn account_home_dir() -> Option<PathBuf> {
    use std::ffi::CStr;
    use std::os::unix::ffi::OsStrExt;
    let entry = unsafe { libc::getpwuid(libc::geteuid()) };
    if entry.is_null() {
        return None;
    }
    let dir = unsafe { CStr::from_ptr((*entry).pw_dir) };
    let dir = std::ffi::OsStr::from_bytes(dir.to_bytes());
    (!dir.is_empty()).then(|| PathBuf::from(dir))
}

#[cfg(not(unix))]
fn account_home_dir() -> Option<PathBuf> {
    dirs::home_dir()
}

/// Whether the test-only trust switch may apply: `UNPEEL_TEST=1`, the switch
/// set to `1`, and an explicit `UNPEEL_HOME` that is neither a real Unpeel
/// home nor inside one (a workspace home there is just as real).
fn trust_switch_applies(
    test_host: Option<&str>,
    switch: Option<&str>,
    explicit_home: Option<&Path>,
    real_homes: &[PathBuf],
) -> bool {
    if test_host != Some("1") || switch != Some("1") {
        return false;
    }
    let Some(home) = explicit_home else {
        return false;
    };
    let home = normalized(home);
    !real_homes
        .iter()
        .map(|real| normalized(real))
        .any(|real| home.starts_with(&real))
}

fn normalized(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Raw manifest scan without the health-refresh pass `list_manifests` runs:
/// identity resolution must not rewrite manifests as a side effect.
fn running_manifests_unrefreshed() -> Vec<HostedSessionManifest> {
    let Ok(entries) = std::fs::read_dir(crate::app_paths::app_sessions_root()) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| std::fs::read(entry.path().join("manifest.json")).ok())
        .filter_map(|raw| serde_json::from_slice::<HostedSessionManifest>(&raw).ok())
        .filter(|manifest| manifest.state == HostedSessionState::Running)
        .collect()
}

/// The identity rule over an injected parent lookup: the seam the unit
/// tests drive.
fn identity_for(
    start: u32,
    claim: Option<&str>,
    parent_of: impl Fn(u32) -> Option<u32>,
    manifests: &[HostedSessionManifest],
) -> Identity {
    let running = manifests
        .iter()
        .filter(|manifest| manifest.state == HostedSessionState::Running);
    let Some(claim) = claim else {
        let candidates: Vec<_> = running.collect();
        return ancestry(start, &parent_of)
            .find_map(|pid| {
                candidates.iter().find(|manifest| {
                    manifest.pid == Some(pid)
                        && session_host::manifest_pid_identity(manifest) == PidIdentity::Matches
                })
            })
            .map(|manifest| Identity::Verified(manifest.session.id.clone()))
            .unwrap_or(Identity::Refused(Refusal::NoSession));
    };
    let Some(manifest) = running
        .into_iter()
        .find(|manifest| manifest.session.id == claim)
    else {
        return Identity::Refused(Refusal::NotRunning);
    };
    let Some(session_pid) = manifest.pid else {
        return if session_host::manifest_launching_host_is_alive(manifest) {
            Identity::Undecided
        } else {
            Identity::Refused(Refusal::NotRunning)
        };
    };
    if session_host::manifest_pid_identity(manifest) != PidIdentity::Matches {
        return Identity::Refused(Refusal::UnverifiedPid);
    }
    if ancestry(start, &parent_of).any(|pid| pid == session_pid) {
        Identity::Verified(claim.to_string())
    } else {
        Identity::Refused(Refusal::NotAnAncestor)
    }
}

/// `start` and its parents, nearest first, stopping before launchd/init and
/// after [`MAX_ANCESTOR_HOPS`].
fn ancestry<'a>(
    start: u32,
    parent_of: &'a impl Fn(u32) -> Option<u32>,
) -> impl Iterator<Item = u32> + 'a {
    std::iter::successors(Some(start), move |pid| parent_of(*pid))
        .take_while(|pid| *pid > 1)
        .take(MAX_ANCESTOR_HOPS as usize)
}

#[cfg(target_os = "macos")]
fn parent_pid(pid: u32) -> Option<u32> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let returned = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr() as *mut libc::c_void,
            size,
        )
    };
    (returned == size).then(|| unsafe { info.assume_init() }.pbi_ppid)
}

#[cfg(target_os = "linux")]
fn parent_pid(pid: u32) -> Option<u32> {
    // /proc/<pid>/stat: the comm field can contain spaces and parens, so the
    // state letter and ppid are the first fields after the last ')'.
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit(')')
        .next()?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn parent_pid(_pid: u32) -> Option<u32> {
    None
}

#[cfg(test)]
mod tests;
