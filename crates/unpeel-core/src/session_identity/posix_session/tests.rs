use super::*;

/// The Session's hosted shell: the PTY child leads its own POSIX session.
const SHELL: u32 = 100;
const AGENT: u32 = 101;
const GATE: u32 = 102;
/// A helper the agent started with `setsid` and no double fork: Codex's
/// shared app-server daemon while the `codex` that started it lives.
const DAEMON: u32 = 103;
const OUTSIDE: u32 = 999;

/// GATE → (DAEMON →) AGENT → SHELL.
fn parents(through_daemon: bool) -> impl Fn(u32) -> Option<u32> {
    move |pid| match pid {
        GATE if through_daemon => Some(DAEMON),
        GATE | DAEMON => Some(AGENT),
        AGENT => Some(SHELL),
        _ => None,
    }
}

/// Every process in the shell's POSIX session, except those `overrides`
/// names (pid, sid); a pid mapped to `None` has no readable sid.
fn sids(overrides: &'static [(u32, Option<u32>)]) -> impl Fn(u32) -> Option<u32> {
    move |pid| {
        overrides
            .iter()
            .find(|(of, _)| *of == pid)
            .map_or(Some(SHELL), |(_, sid)| *sid)
    }
}

#[test]
fn a_gate_in_the_shells_session_stays_in_it() {
    // Claude Code, Codex `--no-daemon`, Codewhale: a new process group at
    // most, never a new POSIX session.
    assert!(stays_in_session(GATE, SHELL, parents(false), sids(&[])));
}

#[test]
fn a_gate_leading_its_own_session_under_the_agent_stays_in_it() {
    // The Python MCP SDK (Kimi) and Node's `detached: true` (OMP on Linux)
    // start the server itself with `setsid`.
    let gate_leads = sids(&[(GATE, Some(GATE))]);
    assert!(stays_in_session(GATE, SHELL, parents(false), gate_leads));
}

#[test]
fn a_gate_under_a_setsid_helper_leaves_the_session() {
    // The daemon leads its own POSIX session and its servers inherit it.
    let daemon = sids(&[(DAEMON, Some(DAEMON)), (GATE, Some(DAEMON))]);
    assert!(!stays_in_session(GATE, SHELL, parents(true), daemon));
}

#[test]
fn a_leading_gate_under_a_setsid_helper_leaves_the_session() {
    // A daemon that also starts each server with `setsid`: the gate's own
    // exemption does not carry the helper.
    let daemon = sids(&[(DAEMON, Some(DAEMON)), (GATE, Some(GATE))]);
    assert!(!stays_in_session(GATE, SHELL, parents(true), daemon));
}

#[test]
fn a_gate_in_some_other_session_leaves_it() {
    let elsewhere = sids(&[(GATE, Some(OUTSIDE))]);
    assert!(!stays_in_session(GATE, SHELL, parents(false), elsewhere));
}

#[test]
fn an_unreadable_sid_on_the_chain_fails_closed() {
    const UNREADABLE: [&[(u32, Option<u32>)]; 3] =
        [&[(GATE, None)], &[(AGENT, None)], &[(SHELL, None)]];
    for overrides in UNREADABLE {
        assert!(
            !stays_in_session(GATE, SHELL, parents(false), sids(overrides)),
            "an unreadable sid at {overrides:?} must refuse"
        );
    }
}

#[test]
fn a_chain_that_never_reaches_the_session_pid_leaves_it() {
    assert!(!stays_in_session(GATE, OUTSIDE, parents(false), sids(&[])));
}

#[test]
fn the_session_pid_itself_stays_in_its_session() {
    // An App is the Session's own program.
    assert!(stays_in_session(SHELL, SHELL, parents(false), sids(&[])));
}

#[test]
fn sid_of_reads_the_kernel_session() {
    let this = std::process::id();
    // SAFETY: getsid(0) only reads this process's own session id.
    let own = unsafe { libc::getsid(0) } as u32;
    assert_eq!(sid_of(this), Some(own));
    assert_eq!(sid_of(u32::MAX >> 1), None);
}
