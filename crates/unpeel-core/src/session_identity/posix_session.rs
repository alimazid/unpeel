//! Fork-only (#74, ADR 0014): the MCP gate's POSIX-session rule.
//!
//! Ancestry alone lets a daemon speak for the Session that started it while
//! its starter lives: Codex's shared app-server daemon is spawned with
//! `setsid` and no double fork, so it stays a child of that `codex` and
//! every MCP server it starts, for any client, traces up to the Session. A
//! daemon leads a POSIX session of its own, though, and its servers inherit
//! it. So the gate also asks that every process between it and the
//! Session's pid share that pid's POSIX session. The gate itself may lead
//! its own: the Python MCP SDK (Kimi) and Node's `detached: true` (OMP on
//! Linux) start each server with `setsid`, but straight from the agent.
//!
//! Only the gate applies this. Claude Code runs every hook and Bash-tool
//! command in a new POSIX session, so the CLI and the hook reporters keep
//! the ancestry rule alone.

/// Whether the walk from `start` up to `session_pid` stays in
/// `session_pid`'s POSIX session, `start` excepted when it leads its own.
/// A sid that cannot be read fails closed, as does a walk that never
/// reaches `session_pid`.
pub(super) fn stays_in_session(
    start: u32,
    session_pid: u32,
    parent_of: impl Fn(u32) -> Option<u32>,
    sid_of: impl Fn(u32) -> Option<u32>,
) -> bool {
    let Some(session_sid) = sid_of(session_pid) else {
        return false;
    };
    for pid in super::ancestry(start, &parent_of) {
        if pid == session_pid {
            return true;
        }
        let Some(sid) = sid_of(pid) else {
            return false;
        };
        let leads_its_own = pid == start && sid == pid;
        if sid != session_sid && !leads_its_own {
            return false;
        }
    }
    false
}

/// The POSIX session `pid` belongs to, or `None` when the kernel has no such
/// process.
#[cfg(unix)]
pub(super) fn sid_of(pid: u32) -> Option<u32> {
    let pid = libc::pid_t::try_from(pid).ok()?;
    // SAFETY: getsid only reads the kernel's record for `pid`.
    let sid = unsafe { libc::getsid(pid) };
    u32::try_from(sid).ok().filter(|sid| *sid > 0)
}

#[cfg(not(unix))]
pub(super) fn sid_of(_pid: u32) -> Option<u32> {
    None
}

#[cfg(test)]
mod tests;
