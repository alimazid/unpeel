#!/usr/bin/env bash
# End-to-end tests for the `unpeel` CLI and the `unpeel serve` Host service.
#
#   ./run.sh                 # every case
#   ./run.sh cli mobile      # only cases whose name contains one of these
#   ./run.sh -v mobile       # stream the case's own output too
#   ./run.sh -j 3            # up to 3 of this run's cases at once
#
# Each case gets a freshly built UNPEEL_HOME and runs in its own process, so
# one case can never leave state that changes another's result.
#
# Several runs may share one machine (one per worktree, say), so nobody needs
# an outside lock. Every case first takes one of UNPEEL_TUI_SLOTS
# machine-wide slots (default 4, at most 9). A slot is a flock held on an
# open file, so a run that dies frees its slot with no cleanup. The slot also
# names the case's home (/tmp/s<slot>-<case>), so no two live cases ever
# share a home, and every sweep below is scoped to one home. Ports are never
# fixed: the harness and the Host bind :0, or a random port outside the
# kernel's ephemeral range when a port has to be released and bound again.
# A short rerun waits for one case to free a slot, not for another whole run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
crates="$(cd "$here/../.." && pwd)"

usage() {
  echo "usage: $0 [-v] [-j N] [filter ...]" >&2
  exit 2
}

verbose=0
jobs="${UNPEEL_TUI_JOBS:-1}"
filters=()
while (( $# )); do
  case "$1" in
    -v|--verbose) verbose=1 ;;
    -j|--jobs) (( $# > 1 )) || usage; jobs="$2"; shift ;;
    -j*) jobs="${1#-j}" ;;
    -*) usage ;;
    *) filters+=("$1") ;;
  esac
  shift
done

slots="${UNPEEL_TUI_SLOTS:-4}"
slot_dir="${UNPEEL_TUI_SLOT_DIR:-/tmp/unpeel-pty-matrix.slots}"
# One digit keeps /tmp/s<slot>-<case> as short as the old /tmp/ut-<case>:
# a hosted session binds <home>/app-sessions/<uuid>/session.sock, and
# host_launch_conformance's sub-homes already sit 1 byte under the limit.
if ! [[ "$slots" =~ ^[1-9]$ ]]; then
  echo "UNPEEL_TUI_SLOTS must be 1-9, not '$slots'" >&2
  exit 2
fi
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "-j wants a positive number, not '$jobs'" >&2
  exit 2
fi
(( jobs > slots )) && jobs=$slots
if ! mkdir -p "$slot_dir"; then
  echo "cannot create the slot directory $slot_dir" >&2
  exit 1
fi

binary="${UNPEEL_TUI_BINARY:-$crates/target/debug/unpeel}"
if [[ -z "${UNPEEL_TUI_SKIP_BUILD:-}" ]]; then
  echo "building unpeel + unpeel-host…"
  # Real lifecycle cases launch the sibling host binary. Rebuilding only the
  # CLI can silently test fresh client code against a stale Host executable.
  if ! (cd "$crates" && cargo build -p unpeel-cli -p unpeel-host 2>&1 | tail -3); then
    echo "build failed" >&2
    exit 1
  fi
fi
if [[ ! -x "$binary" ]]; then
  echo "no binary at $binary" >&2
  exit 1
fi
export UNPEEL_TUI_BINARY="$binary"

# A UNIX socket path is capped near 104 bytes (sockaddr_un) and hosted
# sessions bind <home>/app-sessions/<uuid>/session.sock — about 55 bytes of
# suffix. macOS TMPDIR alone is ~49, which blows the limit and makes hosts
# fail to bind with no visible error: sessions simply never start. So homes
# live in /tmp. UNPEEL_TUI_TEST_BASE names them <base>-<case> instead of by
# slot; the caller then owns that prefix and must keep it unique and short.
base="${UNPEEL_TUI_TEST_BASE:-}"

# PTY cores holding a pty-core.lock anywhere under a directory, as
# "<pid> <lock path>" lines. lsof reports macOS temp paths through the
# /private symlink (`/private/tmp/...` for a `/tmp/...` home) and some cases
# run serve in sub-homes, so match the realpath as a prefix at any depth.
cores_under() {
  local dir="$1" real pid
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || real="$dir"
  for pid in $(pgrep -f "__pty_core__" 2>/dev/null); do
    lsof -p "$pid" 2>/dev/null | awk -v pid="$pid" -v a="$dir/" -v b="$real/" \
      '$NF ~ /pty-core\.lock$/ && (index($NF, a) == 1 || index($NF, b) == 1) { print pid, $NF }'
  done
}

sweep_cores_under() {
  local line
  while read -r line; do
    [[ -n "$line" ]] && kill -9 "${line%% *}" 2>/dev/null || true
  done <<<"$(cores_under "$1")"
}

# Kill every hosted process bound to one home. A leaked host keeps writing
# to an output.bin we are about to unlink, so the space is never reclaimed
# and the disk fills up over a long run — which is exactly how a full suite
# once ran the machine out of space.
sweep_home() {
  local home="$1" real pid
  ps -eo pid,command \
    | grep "__session_host__" \
    | grep -F "$home/" \
    | awk '{print $1}' \
    | xargs -r kill -9 2>/dev/null || true
  # `__mcp__` sidecars carry no home in argv (home is in their env), so match
  # them by an open file under the home, the same way cores are found.
  real="$(cd "$home" 2>/dev/null && pwd -P)" || real="$home"
  for pid in $(pgrep -f "__mcp__" 2>/dev/null); do
    if lsof -p "$pid" 2>/dev/null | awk -v a="$home/" -v b="$real/" \
        '(index($NF, a) == 1 || index($NF, b) == 1) { found = 1 } END { exit(found ? 0 : 1) }'; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  # A shared PTY core (`__pty_core__`) carries no home in its argv, but it
  # holds <home>/pty-core.lock open for its lifetime: sweep by that.
  sweep_cores_under "$home"
}

# Block until one of the machine's slots is free, then hold it on fd 9 of
# this shell and set `slot`. flock(2) locks the open file, which python
# shares with this shell, so the lock outlives python and lasts until fd 9
# closes. Every case runs with fd 9 closed: a daemon that inherited it would
# hold the slot for as long as the daemon lived.
take_slot() {
  local i
  while :; do
    [[ -e "$results/.stop" ]] && return 1
    for (( i = 1; i <= slots; i++ )); do
      exec 9>>"$slot_dir/$i"
      if python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; then
        if [[ -e "$results/.stop" ]]; then
          exec 9>&-
          return 1
        fi
        slot=$i
        return 0
      fi
      exec 9>&-
    done
    sleep 1
  done
}

results="$(mktemp -d "${TMPDIR:-/tmp}/unpeel-matrix.XXXXXX")" || exit 1

# One case, start to finish, in its own background job. It leaves
# <name>.out (the lines to print) and <name>.counts in $results, then
# <name>.done once both are complete.
run_case() {
  local name="$1" case_file="$here/cases/$1.py" home queued waited start output status
  local elapsed case_pass case_fail
  queued=$(date +%s)
  if ! take_slot; then
    : >"$results/$name.skipped"
    : >"$results/$name.done"
    return
  fi
  waited=$(( $(date +%s) - queued ))
  home="${base:+$base-$name}"
  home="${home:-/tmp/s$slot-$name}"
  # The slot is ours, but a run that died may have left processes here.
  sweep_home "$home"
  rm -rf "$home"
  start=$(date +%s)
  # In the background so its pid is known: on_interrupt signals the case
  # itself, which a `$(...)` would have hidden one subshell further down.
  UNPEEL_TUI_TEST_HOME="$home" python3 "$case_file" </dev/null 9>&- >"$results/$name.log" 2>&1 &
  echo "$!" >"$results/$name.pid"
  wait "$!"
  status=$?
  elapsed=$(( $(date +%s) - start ))
  output="$(cat "$results/$name.log")"

  case_pass=$(grep -c '^PASS ' <<<"$output")
  case_fail=$(grep -c '^FAIL ' <<<"$output")
  {
    printf '%-22s ' "$name"
    if (( status == 0 )); then
      printf '\033[32mok\033[0m   %2d checks  %2ds' "$case_pass" "$elapsed"
    else
      printf '\033[31mFAIL\033[0m %2d/%d failed %2ds' "$case_fail" \
        "$(( case_pass + case_fail ))" "$elapsed"
    fi
    (( waited > 0 )) && printf '  (waited %ds for a slot)' "$waited"
    printf '\n'
    (( status == 0 )) || grep '^FAIL ' <<<"$output" | sed 's/^/    /'
    if (( verbose )); then
      sed 's/^/    | /' <<<"$output"
    else
      grep '^NOTE ' <<<"$output" | sed 's/^/    /'
    fi
  } >"$results/$name.out"

  # Sweep any hosted process this case left behind BEFORE deleting its home.
  sweep_home "$home"
  # Belt and braces: a core may have come up after the sweep. A survivor
  # here is a harness bug worth seeing, so print it before killing it.
  local leaked
  if leaked="$(cores_under "$home")" && [[ -n "$leaked" ]]; then
    {
      echo "    NOTE leaked PTY cores under $home after the case:"
      sed 's/^/      /' <<<"$leaked"
    } >>"$results/$name.out"
    sweep_cores_under "$home"
  fi
  rm -rf "$home" "$home-"*
  echo "$case_pass $case_fail $status" >"$results/$name.counts"
  : >"$results/$name.done"
}

names=()
for case_file in "$here"/cases/*.py; do
  name="$(basename "$case_file" .py)"
  if (( ${#filters[@]} )); then
    keep=0
    for filter in "${filters[@]}"; do
      [[ "$name" == *"$filter"* ]] && keep=1
    done
    (( keep )) || continue
  fi
  names+=("$name")
done

# Cases run as background jobs, which a shell starts with SIGINT ignored;
# the harness restores it, so Ctrl-C still unwinds each case through its
# cleanup while the jobs themselves go on to sweep. A TERM sent to this
# script alone is handed to the running cases the same way. Either way no
# new case starts.
interrupted=0
on_interrupt() {
  interrupted=1
  : >"$results/.stop"
  local name
  for name in ${names[@]+"${names[@]}"}; do
    [[ -e "$results/$name.pid" && ! -e "$results/$name.done" ]] || continue
    kill -INT "$(cat "$results/$name.pid")" 2>/dev/null || true
  done
}
trap on_interrupt INT TERM
trap 'rm -rf "$results"' EXIT

pass=0; fail=0; failed_cases=()
start_all=$(date +%s)
total=${#names[@]}
launched=0; printed=0; finished=0

# Launch up to $jobs cases, and print finished ones in name order.
while (( printed < total )); do
  progressed=0
  while (( printed < launched )) && [[ -e "$results/${names[printed]}.done" ]]; do
    name="${names[printed]}"
    printed=$(( printed + 1 ))
    progressed=1
    [[ -e "$results/$name.skipped" ]] && continue
    cat "$results/$name.out"
    read -r case_pass case_fail status <"$results/$name.counts"
    pass=$(( pass + case_pass ))
    fail=$(( fail + case_fail ))
    (( status == 0 )) || failed_cases+=("$name")
    finished=$(( finished + 1 ))
  done
  running=0
  for (( i = printed; i < launched; i++ )); do
    [[ -e "$results/${names[i]}.done" ]] || running=$(( running + 1 ))
  done
  if (( !interrupted && launched < total && running < jobs )); then
    run_case "${names[launched]}" &
    launched=$(( launched + 1 ))
    progressed=1
  fi
  if (( interrupted && running == 0 )); then
    break
  fi
  (( progressed )) || sleep 0.2
done
wait

echo
printf 'total: %d passed, %d failed, %ds\n' "$pass" "$fail" \
  "$(( $(date +%s) - start_all ))"
if (( interrupted )); then
  echo "interrupted after $finished of $total cases"
  exit 130
fi
if (( ${#failed_cases[@]} )); then
  printf 'failing cases: %s\n' "${failed_cases[*]}"
  exit 1
fi
exit 0
