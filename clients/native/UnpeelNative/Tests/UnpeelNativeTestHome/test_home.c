// Fork-only: this test bundle never resolves the real ~/.unpeel (#44).
//
// `LaunchConfig.unpeelDir` and `AppDefaults.shared` are `static let`s, fixed
// on first touch, so a per-test `setenv` depends on test order. This
// constructor runs when the bundle loads, before any test, and gives the
// process a private UNPEEL_HOME unless the caller set one. A caller's home
// and its defaults suite are never touched.
//
// The home is one of a fixed set of slots, `/tmp/unt-<n>`, held through an
// flock on `/tmp/unt-<n>.lock` for the life of the process, so concurrent
// runs never share one. The defaults suite is named after the home, and
// cfprefsd writes an emptied suite's plist back a few seconds after anything
// deletes it, so fresh paths would leave one plist per run behind. Reused
// slots bound that to one per slot. Each run replaces its slot's home with a
// fresh directory and empties the slot's suite on the way in (a crashed
// run's leftovers), and removes both on the way out. Nothing outside the
// slot path is ever removed, even when the path is a symlink.
// The Swift side's guard is `TestHomeIsolationTests`.

#include "unpeel_native_test_home.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

enum { slot_count = 32 };
static const char slot_home_format[] = "/tmp/unt-%d";

/// Empty unless the constructor created the home.
static char created_home[PATH_MAX];
static char created_suite[128];

const char *unpeel_native_test_home_created(void) {
    return created_home[0] ? created_home : NULL;
}

/// `AppDefaults.suite(forUnpeelHome:)`: FNV-1a over the raw path's UTF-8
/// bytes, in base 36 (`String(_:radix: 36)`, lowercase).
_Bool unpeel_native_test_home_suite_name(const char *home, char *out, size_t size) {
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (const unsigned char *byte = (const unsigned char *)home; *byte; byte++) {
        hash = (hash ^ *byte) * 0x100000001b3ULL;
    }
    static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    char reversed[16];
    size_t count = 0;
    do {
        reversed[count++] = digits[hash % 36];
        hash /= 36;
    } while (hash != 0);
    char base36[16];
    for (size_t index = 0; index < count; index++) {
        base36[index] = reversed[count - 1 - index];
    }
    base36[count] = '\0';
    int written = snprintf(out, size, "com.unpeel.devhome.%s", base36);
    return written > 0 && (size_t)written < size;
}

static int remove_entry(const char *path, const struct stat *info, int flag, struct FTW *ftw) {
    (void)info;
    (void)flag;
    (void)ftw;
    if (remove(path) != 0) perror(path);
    return 0;
}

/// Removes every key of the slot's suite. The plist file itself stays.
static void empty_created_suite(void) {
    CFStringRef suite = CFStringCreateWithCString(NULL, created_suite, kCFStringEncodingUTF8);
    if (suite == NULL) return;
    CFArrayRef keys = CFPreferencesCopyKeyList(
        suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
    );
    if (keys != NULL) {
        CFPreferencesSetMultiple(
            NULL, keys, suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        );
        CFRelease(keys);
    }
    if (!CFPreferencesSynchronize(suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
        fprintf(stderr, "unpeel-native tests: could not empty defaults suite %s\n", created_suite);
    }
    CFRelease(suite);
}

/// Removes whatever sits at `home` without ever walking out of it. `nftw`
/// with FTW_PHYS skips symlinks inside the tree but still walks a symlinked
/// root's target, so a link or file at the path is unlinked, and only a
/// real directory this user owns is walked. False when the path is left in
/// place (someone else's directory, or a removal failed).
static _Bool remove_home(const char *home) {
    struct stat info;
    if (lstat(home, &info) != 0) {
        if (errno == ENOENT) return 1;
        perror(home);
        return 0;
    }
    if (!S_ISDIR(info.st_mode)) {
        if (unlink(home) == 0) return 1;
        perror(home);
        return 0;
    }
    if (info.st_uid != getuid()) {
        fprintf(stderr, "unpeel-native tests: %s belongs to another user\n", home);
        return 0;
    }
    nftw(home, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
    return lstat(home, &info) != 0 && errno == ENOENT;
}

_Bool unpeel_native_test_home_reset(const char *home) {
    if (!remove_home(home)) return 0;
    // A fresh directory or nothing: an EEXIST here means something raced in.
    if (mkdir(home, 0700) == 0) return 1;
    perror(home);
    return 0;
}

static void release_created_home(void) {
    if (!created_home[0]) return;
    remove_home(created_home);
    if (created_suite[0]) empty_created_suite();
}

/// Locks the first free slot whose home resets cleanly, and empties that
/// slot's suite. The lock fd stays open (and close-on-exec, so spawned
/// children never hold the slot) until the process exits.
static _Bool claim_slot(char *home, size_t size) {
    for (int slot = 0; slot < slot_count; slot++) {
        snprintf(home, size, slot_home_format, slot);
        char lock[PATH_MAX];
        snprintf(lock, sizeof lock, "%s.lock", home);
        int fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) continue;
        if (flock(fd, LOCK_EX | LOCK_NB) == 0 && unpeel_native_test_home_reset(home)) {
            return 1;
        }
        close(fd);
    }
    home[0] = '\0';
    return 0;
}

__attribute__((constructor))
static void isolate_unpeel_home(void) {
    // Marks the process as a test harness: HostServiceManager never starts
    // the Host service from one.
    setenv("UNPEEL_TEST_NATIVE_SUITE", "1", 1);
    // A store under test that scopes to another workspace opens a gateway,
    // which spawns `LaunchConfig.hostBinary`. Point it at a program that
    // exits at once, so no test ever starts a real Host.
    setenv("UNPEEL_HOST_CMD", "/usr/bin/false", 0);
    const char *existing = getenv("UNPEEL_HOME");
    if (existing != NULL && existing[0] != '\0') return;
    if (!claim_slot(created_home, sizeof created_home)) {
        fprintf(stderr, "unpeel-native tests: no free /tmp/unt-<n> home among %d slots\n", slot_count);
        abort();
    }
    if (!unpeel_native_test_home_suite_name(created_home, created_suite, sizeof created_suite)) {
        created_suite[0] = '\0';
    }
    // A crashed run's leftovers.
    if (created_suite[0]) empty_created_suite();
    setenv("UNPEEL_HOME", created_home, 1);
    atexit(release_created_home);
}
