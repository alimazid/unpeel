use super::*;

fn applies(home: &Path, reals: &[PathBuf]) -> bool {
    switch_applies(Some("1"), Some("1"), Some(home), reals)
}

#[test]
fn the_trust_switch_needs_the_test_flag_the_switch_and_a_private_home() {
    let root = tempfile::tempdir().expect("root");
    let real = root.path().join(".unpeel");
    std::fs::create_dir_all(&real).expect("real home");
    let private = tempfile::tempdir().expect("private home");
    let reals = [real.clone()];
    assert!(applies(private.path(), &reals));
    assert!(!switch_applies(
        None,
        Some("1"),
        Some(private.path()),
        &reals
    ));
    assert!(!switch_applies(
        Some("1"),
        None,
        Some(private.path()),
        &reals
    ));
    assert!(!switch_applies(
        Some("1"),
        Some("0"),
        Some(private.path()),
        &reals
    ));
    // No explicit UNPEEL_HOME means the default, real home.
    assert!(!switch_applies(Some("1"), Some("1"), None, &reals));
    // A sibling whose name only starts like the real home is not inside it.
    let sibling = root.path().join(".unpeel-test");
    std::fs::create_dir_all(&sibling).expect("sibling");
    assert!(applies(&sibling, &reals));
}

#[test]
fn the_trust_switch_never_works_against_the_real_home() {
    let root = tempfile::tempdir().expect("root");
    let real = root.path().join(".unpeel");
    std::fs::create_dir_all(real.join("workspaces").join("w")).expect("real home");
    let reals = [real.clone()];
    assert!(!applies(&real, &reals));
    // A workspace home inside it is the user's data too.
    assert!(!applies(&real.join("workspaces").join("w"), &reals));
    // A spelling that resolves to it (trailing component, symlink) as well.
    assert!(!applies(&real.join("workspaces").join(".."), &reals));
    let link = root.path().join("link-to-real");
    std::os::unix::fs::symlink(&real, &link).expect("symlink");
    assert!(!applies(&link, &reals));
    assert!(!applies(&link.join("not-created-yet"), &reals));
}

#[cfg(target_os = "macos")]
#[test]
fn the_trust_switch_never_works_through_an_apfs_firmlink_spelling() {
    // `canonicalize` keeps `/System/Volumes/Data/...` apart from the same
    // directory's usual path, so only its directory identity gives it away.
    let root = tempfile::tempdir().expect("root");
    let real = std::fs::canonicalize(root.path())
        .expect("canonical")
        .join(".unpeel");
    std::fs::create_dir_all(&real).expect("real home");
    let firmlink =
        Path::new("/System/Volumes/Data").join(real.strip_prefix("/").expect("absolute"));
    assert!(
        firmlink.exists(),
        "{} is the data volume spelling",
        firmlink.display()
    );
    assert_ne!(std::fs::canonicalize(&firmlink).expect("firmlink"), real);
    assert!(!applies(&firmlink, std::slice::from_ref(&real)));
    assert!(!applies(&firmlink.join("workspace"), &[real]));
}

#[test]
fn a_real_home_not_created_yet_is_still_refused_however_spelled() {
    let root = tempfile::tempdir().expect("root");
    let account = root.path().join("account");
    std::fs::create_dir_all(&account).expect("account");
    let real = account.join(".unpeel");
    let link = root.path().join("link-to-account");
    std::os::unix::fs::symlink(&account, &link).expect("symlink");
    let reals = [real.clone()];
    assert!(!applies(&real, &reals));
    assert!(!applies(&link.join(".unpeel"), &reals));
    assert!(!applies(&link.join(".unpeel").join("w"), &reals));
    assert!(applies(&link.join("other"), &reals));
}

#[test]
fn a_registered_workspace_home_is_a_real_home() {
    let real = tempfile::tempdir().expect("real home");
    let workspace = tempfile::tempdir().expect("workspace");
    std::fs::write(
        crate::app_paths::workspace_registry_path(real.path()),
        serde_json::json!({"profiles": [{
            "id": "w", "name": "Work", "home": workspace.path(),
        }]})
        .to_string(),
    )
    .expect("registry");
    let reals = with_registered_workspaces(vec![real.path().to_path_buf()]);
    assert!(!applies(workspace.path(), &reals));
    assert!(!applies(&workspace.path().join("inside"), &reals));
}

#[test]
fn the_real_homes_include_the_account_home_even_when_home_is_repointed() {
    let account = account_home_dir().expect("account home");
    assert!(real_homes().contains(&account.join(".unpeel")));
}
