#ifndef UNPEEL_NATIVE_TEST_HOME_H
#define UNPEEL_NATIVE_TEST_HOME_H

#include <stddef.h>

/// The private UNPEEL_HOME this test bundle's constructor created, or NULL
/// when the caller already set one (a caller's home is never removed).
const char *unpeel_native_test_home_created(void);

/// Writes the UserDefaults suite `AppDefaults.suite(forUnpeelHome:)` derives
/// for `home` into `out`. False when `out` is too small.
_Bool unpeel_native_test_home_suite_name(const char *home, char *out, size_t size);

/// Replaces whatever sits at `home` with a fresh, empty 0700 directory,
/// never walking out of the path: a symlink or file there is unlinked, and
/// only a directory this user owns is emptied. False when it can't.
_Bool unpeel_native_test_home_reset(const char *home);

#endif
