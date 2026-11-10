//! Fork-only (#84): what the health check remembers across checks and Host
//! restarts, in `<UNPEEL_HOME>/health/state.json`: when it last ran, every
//! problem it saw then (so a problem alerts once, and again only after it
//! cleared and came back), when it first saw the Router running, and
//! the Mac notifications no app was connected to show. Only this
//! workspace's worker writes it (one per home, by its lease), so a temp
//! file and a rename are the whole write.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const STATE_VERSION: u32 = 1;
/// Kept Mac notifications past this drop the oldest.
pub const MAX_KEPT_NOTICES: usize = 20;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthState {
    #[serde(default)]
    pub v: u32,
    /// When the last check ran (wall-clock ms): a Run recorded after it is
    /// news to the next one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_check_ms: Option<u64>,
    /// Every problem the last check saw, by key, alerted or still under its
    /// limit.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub problems: BTreeMap<String, Tracked>,
    /// When a check first saw the Router running, since it last saw it
    /// down: its Inbox is not late before then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub router_running: Option<RunningSince>,
    /// Mac notifications no app was connected to show, oldest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kept: Vec<KeptNotice>,
}

/// One problem a check saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tracked {
    /// When its clock started: when the problem began, or when a check
    /// first saw it.
    pub since: u64,
    /// Its alert went out; it does not go out again while the problem lasts.
    #[serde(default)]
    pub alerted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunningSince {
    pub session_id: String,
    pub since: u64,
}

/// A Mac notification kept until an app connects.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeptNotice {
    /// The health problem it reports; dropped once that clears. `None` for a
    /// Run's own failure notice, which is shown whenever an app connects.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
    /// Empty for a notice about a task with no Session.
    #[serde(default)]
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schedule_id: Option<String>,
    pub title: String,
    pub body: String,
    pub at: u64,
}

impl HealthState {
    /// The state at `path`. Missing is a first check; a file that will not
    /// read starts over too (traced), which can repeat a lasting problem's
    /// alert once but never hides one.
    pub fn load(path: &Path) -> Self {
        let raw = match std::fs::read(path) {
            Ok(raw) => raw,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Self::default(),
            Err(error) => return Self::starting_over(path, &error),
        };
        serde_json::from_slice(&raw).unwrap_or_else(|error| Self::starting_over(path, &error))
    }

    fn starting_over(path: &Path, error: &dyn std::fmt::Display) -> Self {
        crate::tracelog::trace(
            "health",
            &format!("{} unreadable, starting over: {error}", path.display()),
        );
        Self::default()
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        let state = Self {
            v: STATE_VERSION,
            ..self.clone()
        };
        let bytes = serde_json::to_vec_pretty(&state).map_err(|error| error.to_string())?;
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("{}: {error}", parent.display()))?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, bytes).map_err(|error| format!("{}: {error}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|error| format!("{}: {error}", path.display()))
    }

    /// The state with `notice` kept, the oldest dropped past
    /// [`MAX_KEPT_NOTICES`].
    pub fn keeping(self, notice: KeptNotice) -> Self {
        let mut kept = self.kept;
        kept.push(notice);
        let excess = kept.len().saturating_sub(MAX_KEPT_NOTICES);
        Self {
            kept: kept.into_iter().skip(excess).collect(),
            ..self
        }
    }

    /// The state without the kept notices whose problem has cleared.
    pub fn without_cleared_notices(self) -> Self {
        let problems = &self.problems;
        let kept = self
            .kept
            .iter()
            .filter(|notice| {
                notice
                    .problem
                    .as_ref()
                    .is_none_or(|key| problems.contains_key(key))
            })
            .cloned()
            .collect();
        Self { kept, ..self }
    }
}

/// `<UNPEEL_HOME>/health/state.json`.
pub fn state_path() -> PathBuf {
    unpeel_core::app_paths::unpeel_home()
        .join("health")
        .join("state.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notice(problem: Option<&str>, at: u64) -> KeptNotice {
        KeptNotice {
            problem: problem.map(str::to_owned),
            session_id: String::new(),
            schedule_id: Some("sch_1".into()),
            title: "Morning report".into(),
            body: "Health check: …".into(),
            at,
        }
    }

    #[test]
    fn the_state_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("health").join("state.json");
        assert_eq!(HealthState::load(&path), HealthState::default());
        let state = HealthState {
            last_check_ms: Some(10),
            problems: BTreeMap::from([(
                "router_down:r".into(),
                Tracked {
                    since: 5,
                    alerted: true,
                },
            )]),
            router_running: None,
            kept: vec![notice(Some("router_down:r"), 5)],
            ..HealthState::default()
        };
        state.save(&path).unwrap();
        let loaded = HealthState::load(&path);
        assert_eq!(loaded.v, STATE_VERSION);
        assert_eq!(HealthState { v: 0, ..loaded }, state);
    }

    #[test]
    fn an_unreadable_state_starts_over() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        std::fs::write(&path, b"{not json").unwrap();
        assert_eq!(HealthState::load(&path), HealthState::default());
    }

    #[test]
    fn kept_notices_keep_the_newest_twenty() {
        let state = (0..25).fold(HealthState::default(), |state, at| {
            state.keeping(notice(None, at))
        });
        assert_eq!(state.kept.len(), MAX_KEPT_NOTICES);
        assert_eq!(state.kept.first().map(|notice| notice.at), Some(5));
        assert_eq!(state.kept.last().map(|notice| notice.at), Some(24));
    }

    #[test]
    fn a_kept_notice_goes_once_its_problem_clears() {
        let state = HealthState {
            problems: BTreeMap::from([(
                "missed:sch_1".into(),
                Tracked {
                    since: 1,
                    alerted: true,
                },
            )]),
            kept: vec![
                notice(Some("missed:sch_1"), 1),
                notice(Some("router_down:r"), 2),
                notice(None, 3),
            ],
            ..HealthState::default()
        }
        .without_cleared_notices();
        let left: Vec<_> = state.kept.iter().map(|notice| notice.at).collect();
        // A Run's own failure notice has no problem to clear.
        assert_eq!(left, vec![1, 3]);
    }
}
