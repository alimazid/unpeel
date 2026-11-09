use super::*;
use serde_json::json;

/// A running manifest whose recorded pid is `pid`, verified by its real
/// start time when `verified` (the test process and its parent are the only
/// live pids the tests rely on).
fn manifest(id: &str, pid: Option<u32>, verified: bool) -> HostedSessionManifest {
    let started_at = pid
        .filter(|_| verified)
        .and_then(session_host::process_start_time_ms);
    serde_json::from_value(json!({
        "session": { "id": id, "project_id": "p", "label": "agent", "command": "agent" },
        "cwd": "/tmp",
        "state": "running",
        "pid": pid,
        "pid_started_at": started_at,
        "exit_code": null,
    }))
    .expect("test manifest")
}

fn this_pid() -> u32 {
    std::process::id()
}

/// A pid no live process uses, standing in for a reporter or MCP server
/// whose parents the test injects.
const CHILD: u32 = u32::MAX;
const DETACHED_PARENT: u32 = u32::MAX - 1;

/// CHILD → this test process, then nothing: the Session's verified pid sits
/// one hop up, as a hosted shell sits above its agent.
fn child_of_this_process(pid: u32) -> Option<u32> {
    (pid == CHILD).then_some(this_pid())
}

#[test]
fn an_exported_id_with_its_session_on_the_ancestry_is_verified() {
    let sessions = [manifest("a", Some(this_pid()), true)];
    let identity = identity_for(CHILD, Some("a"), child_of_this_process, &sessions);
    assert_eq!(identity, Identity::Verified("a".into()));
}

#[test]
fn an_exported_id_naming_another_session_is_refused_not_redirected() {
    // The caller descends from Session a, but exports b's id: it speaks for
    // neither, never for the ancestor it happens to have.
    let other = std::os::unix::process::parent_id();
    let sessions = [
        manifest("a", Some(this_pid()), true),
        manifest("b", Some(other), true),
    ];
    let identity = identity_for(CHILD, Some("b"), child_of_this_process, &sessions);
    assert_eq!(identity, Identity::Refused(Refusal::NotAnAncestor));
}

#[test]
fn a_detached_process_keeping_the_exported_id_is_refused() {
    // Double-forked away: its parent is no longer the Session's shell.
    let sessions = [manifest("a", Some(this_pid()), true)];
    let detached = |pid| (pid == CHILD).then_some(DETACHED_PARENT);
    let identity = identity_for(CHILD, Some("a"), detached, &sessions);
    assert_eq!(identity, Identity::Refused(Refusal::NotAnAncestor));
}

#[test]
fn without_an_exported_id_the_verified_ancestor_is_the_identity() {
    let sessions = [manifest("a", Some(this_pid()), true)];
    let identity = identity_for(CHILD, None, child_of_this_process, &sessions);
    assert_eq!(identity, Identity::Verified("a".into()));
}

#[test]
fn without_an_exported_id_or_a_session_ancestor_there_is_no_identity() {
    let sessions = [manifest("a", Some(this_pid()), true)];
    let detached = |pid| (pid == CHILD).then_some(DETACHED_PARENT);
    let identity = identity_for(CHILD, None, detached, &sessions);
    assert_eq!(identity, Identity::Refused(Refusal::NoSession));
}

#[test]
fn a_recycled_session_pid_is_refused() {
    let mut recycled = manifest("a", Some(this_pid()), true);
    // A start time far from the live process's proves the recorded child is
    // gone and this pid was reused: identity must not transfer.
    recycled.pid_started_at = recycled.pid_started_at.map(|at| at + 3_600_000);
    let identity = identity_for(CHILD, Some("a"), child_of_this_process, &[recycled.clone()]);
    assert_eq!(identity, Identity::Refused(Refusal::UnverifiedPid));
    let identity = identity_for(CHILD, None, child_of_this_process, &[recycled]);
    assert_eq!(identity, Identity::Refused(Refusal::NoSession));
}

#[test]
fn a_legacy_manifest_without_a_start_time_is_refused() {
    let legacy = [manifest("legacy-unverifiable-zz", Some(this_pid()), false)];
    let identity = identity_for(
        CHILD,
        Some("legacy-unverifiable-zz"),
        child_of_this_process,
        &legacy,
    );
    assert_eq!(identity, Identity::Refused(Refusal::UnverifiedPid));
    let identity = identity_for(CHILD, None, child_of_this_process, &legacy);
    assert_eq!(identity, Identity::Refused(Refusal::NoSession));
}

#[test]
fn an_exported_id_without_a_running_manifest_is_refused() {
    let mut exited = manifest("a", Some(this_pid()), true);
    exited.state = HostedSessionState::Exited;
    let identity = identity_for(CHILD, Some("a"), child_of_this_process, &[exited]);
    assert_eq!(identity, Identity::Refused(Refusal::NotRunning));
    let identity = identity_for(CHILD, Some("a"), child_of_this_process, &[]);
    assert_eq!(identity, Identity::Refused(Refusal::NotRunning));
}

#[test]
fn a_session_still_launching_is_undecided_not_refused() {
    // The shared PTY core publishes `pid: None` until the child spawns; its
    // own pid, verified, says the launch is still in progress.
    let mut launching = manifest("a", None, false);
    launching.host_pid = Some(this_pid());
    launching.host_pid_started_at = session_host::process_start_time_ms(this_pid());
    let identity = identity_for(
        CHILD,
        Some("a"),
        child_of_this_process,
        &[launching.clone()],
    );
    assert_eq!(identity, Identity::Undecided);

    // Once that Host is gone the record can never get a pid.
    launching.host_pid_started_at = launching.host_pid_started_at.map(|at| at + 3_600_000);
    let identity = identity_for(CHILD, Some("a"), child_of_this_process, &[launching]);
    assert_eq!(identity, Identity::Refused(Refusal::NotRunning));
}

#[test]
fn the_session_pid_may_be_the_caller_itself() {
    // An App runs as the Session's own program: its pid is the manifest pid.
    let sessions = [manifest("a", Some(this_pid()), true)];
    let identity = identity_for(this_pid(), Some("a"), |_| None, &sessions);
    assert_eq!(identity, Identity::Verified("a".into()));
}

#[test]
fn parent_pid_reads_the_kernel_parent() {
    assert_eq!(
        parent_pid(this_pid()),
        Some(std::os::unix::process::parent_id())
    );
}
