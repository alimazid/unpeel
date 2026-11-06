//! Fork-only: what the Worker alerts and the watchdog read outside the
//! sidebar rows — the Router mark, Worker markers, exit facts, durable
//! progress stamps and the supervisor's heartbeat. [`HostWorkers`] reads
//! the real home; tests use a fake.

use std::path::PathBuf;

use unpeel_core::supervision::SupervisorConfig;

use crate::sessions::{SessionRow, StatusSource};

/// How a stopped Session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exit {
    /// The manifest's `exit_code` (`None` when the Host never learned it).
    pub code: Option<i32>,
    /// When it exited: the exited manifest's `updated_at`, which nothing
    /// rewrites while it stays stopped.
    pub at: u64,
}

pub trait WorkerHost: Send + Sync {
    /// The Router mark and the supervisor's settings, read together.
    fn router_and_config(&self) -> (Option<String>, SupervisorConfig);
    /// The Router a Session's Worker marker names.
    fn worker_router(&self, session_id: &str) -> Option<String>;
    /// Whether the manifest says the Session runs (before a step has seen
    /// its row).
    fn running(&self, session_id: &str) -> bool;
    /// How a stopped Session ended; `None` while it runs.
    fn exit(&self, session_id: &str) -> Option<Exit>;
    /// Durable progress the row does not carry: hook stamps for a
    /// hook-capable launch, the screen only when nothing better speaks (a
    /// spinner would otherwise hide a stall).
    fn durable_progress(&self, row: &SessionRow) -> Option<u64>;
    /// The last heartbeat any supervisor of this home wrote.
    fn heartbeat(&self) -> Option<u64>;
    fn write_heartbeat(&self, at_ms: u64);
}

/// The real home.
#[derive(Debug, Clone, Copy, Default)]
pub struct HostWorkers;

impl HostWorkers {
    fn heartbeat_path() -> PathBuf {
        unpeel_core::app_paths::unpeel_home()
            .join("supervision")
            .join("heartbeat")
    }
}

impl WorkerHost for HostWorkers {
    fn router_and_config(&self) -> (Option<String>, SupervisorConfig) {
        unpeel_core::supervision::router_and_config()
    }

    fn worker_router(&self, session_id: &str) -> Option<String> {
        unpeel_core::supervision::read_worker_marker(session_id).map(|marker| marker.router_id)
    }

    fn running(&self, session_id: &str) -> bool {
        unpeel_core::session_host::load_manifest(session_id).is_some_and(|manifest| {
            manifest.state == unpeel_core::session_host::HostedSessionState::Running
        })
    }

    fn exit(&self, session_id: &str) -> Option<Exit> {
        let manifest = unpeel_core::session_host::load_manifest(session_id)?;
        (manifest.state == unpeel_core::session_host::HostedSessionState::Exited).then_some(Exit {
            code: manifest.exit_code,
            at: manifest.updated_at,
        })
    }

    fn durable_progress(&self, row: &SessionRow) -> Option<u64> {
        let hooks = unpeel_core::integrations::uses_hook_port(
            unpeel_core::integrations::command_head(&row.command),
        );
        let screen_only = matches!(row.status_source, StatusSource::Screen | StatusSource::None);
        (hooks || screen_only)
            .then(|| unpeel_core::session_ops::last_activity_ms(&row.id, &row.command))
            .flatten()
    }

    fn heartbeat(&self) -> Option<u64> {
        std::fs::read_to_string(Self::heartbeat_path())
            .ok()?
            .trim()
            .parse()
            .ok()
    }

    fn write_heartbeat(&self, at_ms: u64) {
        let path = Self::heartbeat_path();
        let written = path
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| {
                let tmp = path.with_extension("tmp");
                std::fs::write(&tmp, at_ms.to_string())?;
                std::fs::rename(&tmp, &path)
            });
        if let Err(error) = written {
            crate::tracelog::trace("supervisor", &format!("heartbeat write failed: {error}"));
        }
    }
}
