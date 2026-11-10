//! The test-only switch that trusts an exported Session id (ADR 0013), and
//! the rule that keeps it away from every real Unpeel home.

use std::path::{Component, Path, PathBuf};

/// Test-only: trust an exported id without the ancestry check, for PTY cases
/// that act as a Session from the harness. Honored only with `UNPEEL_TEST=1`
/// and an explicit `UNPEEL_HOME` that is no real Unpeel home (see
/// [`switch_applies`]). The Host never passes it into a Session.
pub const TRUST_EXPORTED_ID_ENV: &str = "UNPEEL_TEST_TRUST_SESSION_ENV";

/// Whether this process may trust its exported id.
pub(super) fn exported_id_is_trusted() -> bool {
    let home = crate::app_paths::unpeel_home();
    switch_applies(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var(TRUST_EXPORTED_ID_ENV).ok().as_deref(),
        std::env::var_os("UNPEEL_HOME")
            .is_some()
            .then_some(home.as_path()),
        &real_homes(),
    )
}

/// The user's real Unpeel homes: `~/.unpeel` under both the account's
/// password-database home and `$HOME` (which a test may have repointed),
/// and every workspace either one registers.
pub(super) fn real_homes() -> Vec<PathBuf> {
    let roots = std::iter::once(crate::app_paths::real_unpeel_home())
        .chain(account_home_dir().map(|home| home.join(".unpeel")))
        .collect();
    with_registered_workspaces(roots)
}

pub(super) fn with_registered_workspaces(roots: Vec<PathBuf>) -> Vec<PathBuf> {
    let registered: Vec<PathBuf> = roots
        .iter()
        .flat_map(|root| crate::app_paths::read_workspace_registry(root))
        .map(|record| record.home)
        .collect();
    roots.into_iter().chain(registered).collect()
}

#[cfg(unix)]
pub(super) fn account_home_dir() -> Option<PathBuf> {
    use std::ffi::CStr;
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: getpwuid returns null or a pointer to a static passwd record
    // that stays valid until the next getpw* call; it is read right away.
    let entry = unsafe { libc::getpwuid(libc::geteuid()) };
    if entry.is_null() {
        return None;
    }
    // SAFETY: a non-null record's pw_dir is a NUL-terminated C string.
    let dir = unsafe { CStr::from_ptr((*entry).pw_dir) };
    let dir = std::ffi::OsStr::from_bytes(dir.to_bytes());
    (!dir.is_empty()).then(|| PathBuf::from(dir))
}

#[cfg(not(unix))]
pub(super) fn account_home_dir() -> Option<PathBuf> {
    dirs::home_dir()
}

/// Whether the switch may apply: `UNPEEL_TEST=1`, the switch set to `1`, and
/// an explicit `UNPEEL_HOME` that is neither a real Unpeel home nor inside
/// one (a workspace home there is just as real), however either is spelled.
pub(super) fn switch_applies(
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
    !real_homes.iter().any(|real| is_within(home, real))
}

/// Whether `path` is `root` or inside it. Paths compare once both are
/// resolved; directory identity also catches the spellings `canonicalize`
/// keeps apart (an APFS firmlink such as `/System/Volumes/Data/Users/…`,
/// a bind mount), also for a `root` that does not exist yet.
fn is_within(path: &Path, root: &Path) -> bool {
    let (path, root) = (resolved(path), resolved(root));
    if path.starts_with(&root) {
        return true;
    }
    let Some((anchor, tail)) = nearest_existing(&root) else {
        return false;
    };
    let Some(anchor) = directory_identity(anchor) else {
        return false;
    };
    path.ancestors().any(|ancestor| {
        directory_identity(ancestor) == Some(anchor)
            && path
                .strip_prefix(ancestor)
                .is_ok_and(|rest| rest.starts_with(tail))
    })
}

/// `path` with what exists canonicalized and the rest applied word by word,
/// so a home that is not created yet still compares by where it would be.
fn resolved(path: &Path) -> PathBuf {
    let Some((existing, rest)) = nearest_existing(path) else {
        return path.to_path_buf();
    };
    let base = std::fs::canonicalize(existing).unwrap_or_else(|_| existing.to_path_buf());
    rest.components().fold(base, |mut resolved, component| {
        match component {
            Component::ParentDir => {
                resolved.pop();
            }
            Component::Normal(name) => resolved.push(name),
            _ => {}
        }
        resolved
    })
}

/// The longest prefix of `path` that exists, and what follows it.
fn nearest_existing(path: &Path) -> Option<(&Path, &Path)> {
    path.ancestors()
        .find(|ancestor| !ancestor.as_os_str().is_empty() && ancestor.exists())
        .and_then(|existing| Some((existing, path.strip_prefix(existing).ok()?)))
}

#[cfg(unix)]
fn directory_identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path)
        .ok()
        .map(|metadata| (metadata.dev(), metadata.ino()))
}

#[cfg(not(unix))]
fn directory_identity(_path: &Path) -> Option<(u64, u64)> {
    None
}

#[cfg(test)]
mod tests;
