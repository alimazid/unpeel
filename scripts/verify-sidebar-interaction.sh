#!/usr/bin/env bash
# verify-sidebar-interaction.sh — drive a built Unpeel Dev bundle's PROJECTS
# list with real pointer events on a throwaway home: toggle group headers, and
# drag rows every way the sidebar allows, checking each step against the app's
# accessibility tree and the Host's session list.
#
#   scripts/verify-sidebar-interaction.sh --app clients/native/dist/Unpeel.app \
#       [--clicks 30] [--drags 20] [--only toggle-project,toggle,group-reorder,list-reorder,group-drop,out-and-back,folder-reorder,project-reorder] \
#       [--report FILE] [--quiet SECONDS] [--app-log FILE] [--dump DIR] [--scale 1|2]
#
# The default tree fits the window. To drive a list that scrolls, use a longer
# one in a shorter window, and name its scenarios (they don't run by default):
#
#   --big-rows 30 --window-height 760 --only scrolled-list-reorder,scrolled-group-drop,long-list-drop,scrolled-back-reorder,far-select
#
# Two more run only when named, on a list with no folder ranks yet:
# --only cross-project-insert,session-above-folder. After folder-reorder the script
# quits the app, relaunches it against the same Host, and runs folder-persisted
# (report: FILE.relaunch).
#
# --scale puts the window on a display of that backing scale and fails if there
# is none. A laptop screen at 2x is too short for the default tree; use a smaller
# one there: --scale 2 --big-rows 7 --window-height 900.
#
# It moves the real pointer, so it needs an unlocked screen and a quiet
# machine: it starts after 20 s without input, and any input it did not make
# pauses it until the machine is quiet again. Exits 1 on any failed step, and 2
# on a bad argument, including a scenario --only doesn't know.
# Accessibility permission is required for the process running it.
#
# The fixture is two plain-shell trees under a private HOME and UNPEEL_HOME; a
# real Host serves it, so a drop commits the way it does in the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="" CLICKS=30 DRAGS=20 ONLY="" REPORT="" QUIET=20 APP_LOG="" DUMP="" BIG_ROWS=12 WINDOW_HEIGHT=1280 SCALE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --clicks) CLICKS="$2"; shift 2 ;;
    --drags) DRAGS="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --quiet) QUIET="$2"; shift 2 ;;
    --app-log) APP_LOG="$2"; shift 2 ;;
    --dump) DUMP="$2"; shift 2 ;;
    --big-rows) BIG_ROWS="$2"; shift 2 ;;
    --window-height) WINDOW_HEIGHT="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$APP" ] || { echo "--app <Unpeel.app> is required" >&2; exit 2; }
case "$SCALE" in ""|1|2) ;; *) echo "--scale takes 1 or 2" >&2; exit 2 ;; esac
APP="$(cd "$APP" && pwd)"
case "$APP" in /Applications/*) echo "refusing: never drive the installed app" >&2; exit 2 ;; esac
MACOS="$APP/Contents/MacOS"
[ "$(plutil -extract CFBundleName raw "$APP/Contents/Info.plist")" = "Unpeel Dev" ] \
  || { echo "refusing: $APP is not a dev build" >&2; exit 2; }

H="" TOOLS="" HOME_A="" SUITE="" SUITES_BEFORE=""
ME="$(id -un)"
REAL_HOME="$(eval echo "~$ME")"
PREFS="$REAL_HOME/Library/Preferences"

# The caller's shell may export UNPEEL_* vars that point at the real home.
uenv() {
  env -i HOME="$H" CFFIXED_USER_HOME="$H" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    USER="$ME" LOGNAME="$ME" SHELL=/bin/zsh TMPDIR="$H/tmp" LANG=en_US.UTF-8 "$@"
}
ucli() { uenv UNPEEL_HOME="$HOME_A" "$MACOS/unpeel" "$@"; }

# Every pid whose environment carries this exact HOME, plus descendants.
fixture_pids() {
  local queue seen pid child
  queue="$(ps -A -E -ww -o pid=,uid=,command= 2>/dev/null \
    | awk -v me="$(id -u)" -v pat="(^| )HOME=$H( |\$)" '$2 == me && $0 ~ pat { print $1 }' | grep -vx "$$" || true)"
  seen=" "
  while [ -n "$queue" ]; do
    set -- $queue; pid="$1"; shift; queue="$*"
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "
    for child in $(pgrep -P "$pid" 2>/dev/null); do queue="$queue $child"; done
  done
  echo "$seen"
}
lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# The defaults suites on this machine that weren't there before this run and
# aren't its own. Another dev instance can make one too, so this only names them.
stray_suites() {
  ls "$PREFS" | grep '^com\.unpeel\.devhome\.' | grep -vxF "$SUITE.plist" \
    | grep -vxFf <(printf '%s\n' "$SUITES_BEFORE") || true
}

APP_PID=""
cleanup() {
  local status="${1:-$?}" round pid reg now stray
  trap - EXIT INT TERM
  set +e # A pid can be gone by the time it is read; finish the cleanup anyway.
  [ -n "$H" ] || exit "$status"
  if [ -n "$APP_LOG" ] && [ -f "$H/app.log" ]; then cp "$H/app.log" "$APP_LOG"; fi
  if [ -n "$DUMP" ]; then
    mkdir -p "$DUMP"
    cp "$HOME_A"/app-state.json "$HOME_A"/session-order.json "$HOME_A"/project-order.json "$DUMP"/ 2>/dev/null
    "$H/ls.sh" > "$DUMP/manifests.json" 2>/dev/null
    ucli ls --json > "$DUMP/ls.json" 2>/dev/null
    uenv defaults read "$SUITE" unpeel.native.expandedProjects > "$DUMP/expanded.txt" 2>/dev/null
  fi
  for round in TERM TERM KILL; do
    reg="$(for pid in $(fixture_pids); do echo "$pid|$(lstart "$pid")"; done)"
    [ -n "$reg" ] || break
    for pid in $(echo "$reg" | cut -d'|' -f1); do
      # A recycled pid is never signalled: the start time must still match.
      now="$(lstart "$pid")"
      [ -n "$now" ] && echo "$reg" | grep -qxF "$pid|$now" && kill "-$round" "$pid" 2>/dev/null || true
    done
    sleep 3
  done
  if [ -n "$SUITE" ]; then
    uenv defaults delete "$SUITE" >/dev/null 2>&1 || true
    sleep 6 # cfprefsd may write the emptied plist back.
    rm -f "$PREFS/$SUITE.plist"
  fi
  if [ -n "$SUITES_BEFORE" ]; then
    stray="$(stray_suites)"
    if [ -n "$stray" ]; then
      echo "these defaults suites appeared during the run and aren't this run's; delete any that no other dev instance owns, from $PREFS:" >&2
      echo "$stray" >&2
    fi
  fi
  rm -rf "$H" "$TOOLS"
  exit "$status"
}
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# sockaddr_un caps a socket path near 104 bytes.
H="$(mktemp -d /tmp/usi.XXXXXX)"
TOOLS="$(mktemp -d /tmp/usit.XXXXXX)"
HOME_A="$H/.unpeel"
# A copy of LaunchConfig.stableHash, checked against the running app below.
SUITE="com.unpeel.devhome.$(python3 -I -c '
import sys
x = 0xcbf29ce484222325
for b in sys.argv[1].encode(): x = ((x ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
d = "0123456789abcdefghijklmnopqrstuvwxyz"; o = ""
while x: o = d[x % 36] + o; x //= 36
print(o)' "$HOME_A")"

swiftc -O -o "$TOOLS/driver" "$ROOT/scripts/verify-sidebar-interaction.swift"
"$TOOLS/driver" check ${ONLY:+--only "$ONLY"} # Refuse a typo before the slow part.
if "$TOOLS/driver" locked; then
  echo "the screen is locked: a locked screen has no windows to drive" >&2
  exit 3
fi

# --- Fixture: projects and groups first, then the Host, then the Sessions, so
# every Session lives in the Host's PTY core and a drop can commit.
mkdir -p "$H/tmp" "$HOME_A" "$H/w"
: > "$H/.zshrc"
for name in Big Small Quiet Empty; do
  mkdir -p "$H/w/$name"
  ucli projects add "$name" "$H/w/$name" >/dev/null
done
python3 -I - "$HOME_A" <<'PY'
import fcntl, json, os, sys, tempfile
home = sys.argv[1]
path = os.path.join(home, "app-state.json")
with open(os.path.join(home, "app-state.lock"), "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = json.load(open(path))
    projects = state["projects"]
    for order, project in enumerate(projects):
        project["sort_order"] = order
    big = next(p for p in projects if p["name"] == "Big")
    for group_id, name, parent, order in (
        ("g-alpha", "Alpha", big["id"], 1),
        ("g-inner", "Inner", "g-alpha", 0),
        ("g-beta", "Beta", big["id"], 2),
    ):
        projects.append({"id": group_id, "name": name, "path": big["path"],
                         "parent_project_id": parent, "is_folder": True, "sort_order": order})
    fd, tmp = tempfile.mkstemp(dir=home, prefix=".app-state.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
PY
project_id() {
  python3 -I -c 'import json,sys; print(next(p["id"] for p in json.load(open(sys.argv[1]))["projects"] if p["name"]==sys.argv[2]))' \
    "$HOME_A/app-state.json" "$1"
}
(cd "$H" && exec env -i HOME="$H" CFFIXED_USER_HOME="$H" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  USER="$ME" LOGNAME="$ME" SHELL=/bin/zsh TMPDIR="$H/tmp" LANG=en_US.UTF-8 \
  nohup "$MACOS/unpeel-host" __serve__ > "$H/host.log" 2>&1 < /dev/null) &
for _ in $(seq 1 60); do [ -S "$HOME_A/host.sock" ] && [ -s "$HOME_A/serve.json" ] && break; sleep 0.5; done
[ -S "$HOME_A/host.sock" ] || { echo "the fixture Host did not come up" >&2; exit 1; }

new_session() { # <project> <dir name>; the row label is the abbreviated cwd.
  mkdir -p "$H/w/Big/$2"
  ucli new --project "$1" --cwd "$H/w/Big/$2" >/dev/null
}
BIG="$(project_id Big)"
for n in $(seq -w 1 "$BIG_ROWS"); do new_session "$BIG" "$(printf 'big-%02d' "$((10#$n))")"; done
for n in 1 2 3; do new_session g-alpha "alpha-$n"; new_session g-beta "beta-$n"; done
new_session g-inner inner-2
sleep 1.1 # Newest first: inner-1 is the top row, and the selection.
mkdir -p "$H/w/Big/inner-1"
SELECTED="$(ucli new --project g-inner --cwd "$H/w/Big/inner-1" --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
SMALL="$(project_id Small)"
for n in 1 2 3; do new_session "$SMALL" "small-$n"; done
QUIET_PROJECT="$(project_id Quiet)"
new_session "$QUIET_PROJECT" "quiet-1"

# Everything expanded but Quiet; only PROJECTS open, so the whole tree fits.
SUITES_BEFORE="$(ls "$PREFS" | grep '^com\.unpeel\.devhome\.' || echo none)"
uenv defaults write "$SUITE" unpeel.native.expandedProjects -array \
  "$BIG" g-alpha g-inner g-beta "$SMALL" "$(project_id Empty)"
uenv defaults write "$SUITE" unpeel.native.selectedSession -string "$SELECTED"
uenv defaults write "$SUITE" unpeel.native.notifyWhenDoneAllAgents -bool false
LAYOUT='{"version":1,"order":["projects","agents","scheduled","explorer","gitHistory"],"hidden":[],"collapsed":["agents","explorer","gitHistory","scheduled"],"weights":{"projects":0.4,"agents":0.25,"scheduled":0.2,"explorer":0.6,"gitHistory":0.4}}'
uenv defaults write "$SUITE" unpeel.sidebarSections.layout -data "$(printf '%s' "$LAYOUT" | xxd -p | tr -d '\n')"
# cleanup deletes this exact file.
[ -f "$PREFS/$SUITE.plist" ] || { echo "the seeded defaults suite is not at $PREFS/$SUITE.plist: cleanup would leave it behind" >&2; exit 1; }

# Which project each Session is in: the manifest, or the override marker the
# Host writes when a Session moves (a move never edits the manifest).
cat > "$H/ls.sh" <<LS
#!/usr/bin/python3 -I
import glob, json, os
rows = []
for path in glob.glob("$HOME_A/app-sessions/*/manifest.json"):
    try:
        manifest = json.load(open(path))
    except (OSError, ValueError):
        continue
    project = manifest["session"]["project_id"]
    try:
        project = json.load(open(os.path.join(os.path.dirname(path), "project-override.json")))["project_id"] or project
    except (OSError, ValueError, KeyError):
        pass
    rows.append({"id": manifest["session"]["id"], "cwd": manifest["cwd"], "project_id": project})
print(json.dumps(rows))
LS
chmod +x "$H/ls.sh"

# --- The app.
APP_STARTED=""
launch_app() {
  (cd "$H" && exec env -i HOME="$H" CFFIXED_USER_HOME="$H" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    USER="$ME" LOGNAME="$ME" SHELL=/bin/zsh TMPDIR="$H/tmp" LANG=en_US.UTF-8 \
    UNPEEL_HOME="$HOME_A" UNPEEL_NATIVE_SERVICE_LAUNCHER=direct \
    "$MACOS/UnpeelNative" >> "$H/app.log" 2>&1 < /dev/null) &
  APP_PID=$!
  sleep 1
  [ "$(ps -o comm= -p "$APP_PID")" = "$MACOS/UnpeelNative" ] || { echo "the app did not start" >&2; exit 1; }
  APP_STARTED="$(lstart "$APP_PID")"
  for _ in $(seq 1 40); do
    rows="$("$TOOLS/driver" prepare --pid "$APP_PID" --window-height "$WINDOW_HEIGHT" ${SCALE:+--scale "$SCALE"} 2>/dev/null || true)"
    case "$rows" in *big-*) break ;; esac
    sleep 0.5
  done
  # Only the seeded suite expands Big, so these rows also prove the app reads it.
  case "$rows" in
    *big-*) ;;
    *)
      echo "the rows never appeared: $rows" >&2
      echo "if Big is listed but collapsed, the app isn't reading the seeded defaults suite $SUITE: did stableHash in LaunchConfig.swift change?" >&2
      exit 1
      ;;
  esac
}

# A recycled pid is never signalled: the start time must still match.
stop_app() {
  local signal
  for signal in TERM TERM KILL; do
    [ "$(lstart "$APP_PID")" = "$APP_STARTED" ] || break
    kill "-$signal" "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      [ "$(lstart "$APP_PID")" = "$APP_STARTED" ] || break
      sleep 0.25
    done
  done
  if [ "$(lstart "$APP_PID")" = "$APP_STARTED" ]; then
    echo "the app did not quit" >&2
    exit 1
  fi
  wait "$APP_PID" 2>/dev/null || true # It's this shell's child: no "Terminated" line.
}

driver_run() {
  "$TOOLS/driver" run --pid "$APP_PID" --ls "$H/ls.sh" --home "$HOME_A" --clicks "$CLICKS" --drags "$DRAGS" --quiet "$QUIET" \
    ${SCALE:+--scale "$SCALE"} "$@"
}

launch_app
status=0
driver_run ${ONLY:+--only "$ONLY"} ${REPORT:+--report "$REPORT"} || status=$?
case ",$ONLY," in
  ,,|*,folder-reorder,*)
    stop_app
    launch_app
    relaunch_status=0
    driver_run --only folder-persisted ${REPORT:+--report "$REPORT.relaunch"} || relaunch_status=$?
    [ "$status" -ne 0 ] || status=$relaunch_status
    ;;
esac
exit "$status"
