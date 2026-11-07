//! This test binary never resolves the real `~/.unpeel` (#40).

// SAFETY: runs once before `main`, while the process is single-threaded, and
// only touches the environment and the filesystem.
#[ctor::ctor(unsafe)]
fn isolate_unpeel_home() {
    unpeel_core::app_paths::use_private_test_home()
        .expect("create a private UNPEEL_HOME for the unpeel-native-bridge tests");
}

#[test]
fn this_test_binary_never_resolves_the_real_unpeel_home() {
    let home = unpeel_core::app_paths::unpeel_home();
    let real = unpeel_core::app_paths::real_unpeel_home();
    assert!(
        !home.starts_with(&real),
        "this test binary resolved its Unpeel home to {}, inside the real {}",
        home.display(),
        real.display()
    );
}
