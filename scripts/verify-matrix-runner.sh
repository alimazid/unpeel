#!/usr/bin/env bash
#
# Checks the PTY matrix runner itself (crates/unpeel-cli/tests/run.sh), not
# the cases: it copies run.sh and harness.py next to a few fake cases that
# only sleep and log, then drives the copy the way several Workers would.
#
# Verifies:
#   0. isolation — a run on a private slot directory keeps its homes inside
#                  it, and a live home in the machine's /tmp/s<slot>-*
#                  survives the whole self-test; checked first, since a
#                  failure means the sections below would remove a real
#                  run's homes
#   1. serial    — the default runs one case at a time, in name order
#   2. jobs      — -j N runs a run's cases at once, still printed in order
#   3. slots     — two runs at once never hold more cases than there are
#                  slots, yet do overlap; no two live cases share a home,
#                  every case runs with the slot's fd 9 closed, and homes
#                  are removed afterwards
#   4. failure   — a failing case fails the run and is named
#   5. interrupt — TERM to run.sh unwinds the running cases through their
#                  cleanup, starts no new case, and exits 143
#   6. crash     — a slot whose holder was killed -9 is free again at once
#   7. queue     — a run that arrives while another holds the only slot
#                  gets it after that run's current case, not its last
#
# Usage: scripts/verify-matrix-runner.sh   (about 50 s; touches no real case,
#        so it may run beside a real matrix)
# Exit:  0 = all checks pass; non-zero with FAIL lines otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$REPO_ROOT/crates/unpeel-cli/tests"

# In /tmp, not $TMPDIR: a private slot directory holds its runs' homes, and
# the harness refuses a home too long for a hosted session's socket.
sandbox="$(mktemp -d /tmp/mr.XXXXXX)"
# Every run in here shares one private slot directory: a stand-in for the
# machine's, so these checks take no slot a real matrix uses at the default
# 4 (section 0 holds the machine's slot 9 for the whole self-test).
export UNPEEL_TUI_SLOT_DIR="$sandbox/slots"
export UNPEEL_TUI_SKIP_BUILD=1
export UNPEEL_TUI_BINARY=/usr/bin/true
# Section 0's machine slot 9 holder and the live home it owns on that slot.
slot9_holder=""
private_holder=""
decoy=""
owns_decoy=0
holder=""
stop() { [[ -n "$1" ]] && { kill -9 "$1"; wait "$1"; } 2>/dev/null; }
cleanup() {
  stop "$holder"
  stop "$private_holder"
  # Only while the machine's slot 9 is still held: once it is free, a home
  # there belongs to whoever holds the slot next.
  (( owns_decoy )) && rm -rf "$decoy"
  stop "$slot9_holder"
  rm -rf "$sandbox"
}
trap cleanup EXIT

failures=0
# 1 if the command succeeds, else 0: the shape `check` takes.
holds() { "$@" && echo 1 || echo 0; }
check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == 1 ]]; then
    echo "PASS $name"
  else
    echo "FAIL $name${detail:+  [$detail]}"
    failures=$(( failures + 1 ))
  fi
}

# A runner copy with these case names. Each fake case logs
# "start <case> <t> <home> <fd9-open>" and "end <case> <t>" to $log.
make_runner() {
  local dir="$1"; shift
  mkdir -p "$dir/cases"
  cp "$TESTS/run.sh" "$TESTS/harness.py" "$dir/"
  local name
  for name in "$@"; do
    cat >"$dir/cases/$name.py" <<'PY'
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run

NAME = os.path.splitext(os.path.basename(__file__))[0]


def log(line):
    with open(os.environ["RUNNER_LOG"], "a") as handle:
        handle.write(line + "\n")


def body(case):
    try:
        os.fstat(9)
        fd9 = 1
    except OSError:
        fd9 = 0
    log(f"start {NAME} {time.time():.3f} {case.home.root} {fd9}")
    try:
        time.sleep(float(os.environ.get("RUNNER_SLEEP", "1")))
    finally:
        log(f"end {NAME} {time.time():.3f}")
    case.check("the case ran with the slot's fd closed", not fd9)
    if NAME.startswith("bad"):
        case.check("this case fails on purpose", False)


run(NAME, body)
PY
  done
}

# Flock the slot files $2... from a background python (its pid is $!) that
# creates $1 once it holds them all, and lets go once this script is gone,
# even after a kill -9.
hold_slots() {
  python3 -c 'import fcntl, os, sys, time
parent, ready = int(sys.argv[1]), sys.argv[2]
held = [open(path, "a") for path in sys.argv[3:]]
for handle in held:
    fcntl.flock(handle, fcntl.LOCK_EX)
open(ready, "w").close()
while os.getppid() == parent:
    time.sleep(0.5)' "$$" "$@" &
}

# Wait up to $3 half-seconds for file $1 while pid $2 lives.
await_file() {
  local tries="$3"
  while (( tries-- > 0 )); do
    [[ -e "$1" ]] && return 0
    kill -0 "$2" 2>/dev/null || break
    sleep 0.5
  done
  [[ -e "$1" ]]
}

# The case names a run printed, in the order it printed them.
case_order() { grep -oE '^rt_[a-z]+' <<<"$1" | tr '\n' ' '; }

# Most cases ever running at once, from start/end lines in a log.
max_overlap() {
  awk '$1 == "start" { print $3, 1 } $1 == "end" { print $3, -1 }' "$@" \
    | sort -k1,1n -k2,2n \
    | awk '{ now += $2; if (now > top) top = now } END { print top + 0 }'
}

# 0. isolation: a run holding slot N clears every home named for slot N, so a
# run on the private slots must never name its homes like the machine's. This
# holds the machine's slot 9 (no run polls it at the default 4 slots), which
# makes its homes this script's to touch, keeps a live home there until the
# end, and has a run take its private slot 9 (1-8 held). The machine's slots
# and homes are read from run.sh, so moving them can't leave this guarding a
# path no run uses.
machine_slots="$(sed -n 's|^machine_slot_dir=\(/.*\)$|\1|p' "$TESTS/run.sh" | head -1)"
machine_prefix="$(sed -n 's|^  home_prefix=\(/[^"]*\)$|\1|p' "$TESTS/run.sh" | head -1)"
if [[ -z "$machine_slots" || -z "$machine_prefix" ]]; then
  check "isolation: run.sh names the machine's slots and homes" 0 \
    "slots '$machine_slots', home prefix '$machine_prefix'"
  exit 1
fi
make_runner "$sandbox/iso" rt_iso
mkdir -p "$machine_slots" "$UNPEEL_TUI_SLOT_DIR"
hold_slots "$sandbox/slot9.ready" "$machine_slots/9"
slot9_holder=$!
# A real run with 9 slots may hold slot 9 for one case: wait that out.
if ! await_file "$sandbox/slot9.ready" "$slot9_holder" 600; then
  check "isolation: hold the machine's slot 9" 0 "its holder exited (see above), or 300s passed"
  exit 1
fi
decoy="${machine_prefix}9-runner_selftest"
owns_decoy=1
rm -rf "$decoy"
mkdir -p "$decoy"
echo '{}' >"$decoy/app-state.json"
hold_slots "$sandbox/private.ready" "$UNPEEL_TUI_SLOT_DIR"/{1..8}
private_holder=$!
if ! await_file "$sandbox/private.ready" "$private_holder" 20; then
  check "isolation: hold private slots 1-8" 0 "its holder exited (see above), or 10s passed"
  exit 1
fi
log="$sandbox/iso.log"
out="$(RUNNER_LOG="$log" RUNNER_SLEEP=0.2 UNPEEL_TUI_SLOTS=9 "$sandbox/iso/run.sh" 2>&1)"
status=$?
stop "$private_holder"; private_holder=""
check "isolation: the run passes" "$(( status == 0 ))" "exit $status: $out"
iso_home="$(awk '$1 == "start" { print $4 }' "$log" 2>/dev/null)"
check "isolation: the run's home is inside its slot directory" \
  "$(holds test "$iso_home" = "$UNPEEL_TUI_SLOT_DIR/s9-rt_iso")" "$iso_home"
check "isolation: a live home outside the sandbox survives a run" \
  "$(holds test -e "$decoy/app-state.json")" "$decoy was removed"
if (( failures )); then
  echo "isolation failed: the sections below would remove a real run's homes"
  exit 1
fi

# 1. serial
make_runner "$sandbox/one" rt_a rt_b rt_c
log="$sandbox/serial.log"
out="$(RUNNER_LOG="$log" UNPEEL_TUI_SLOTS=3 "$sandbox/one/run.sh" 2>&1)"
status=$?
check "serial: the run passes" "$(( status == 0 ))" "exit $status: $out"
check "serial: one case at a time" "$(( $(max_overlap "$log") == 1 ))" "$(cat "$log")"
order="$(case_order "$out")"
check "serial: cases print in name order" "$(holds test "$order" = "rt_a rt_b rt_c ")" "$order"
check "serial: the total counts every check" \
  "$(holds grep -q '^total: 6 passed, 0 failed' <<<"$out")" "$out"

# 2. jobs
log="$sandbox/jobs.log"
began=$(date +%s)
out="$(RUNNER_LOG="$log" RUNNER_SLEEP=3 UNPEEL_TUI_SLOTS=3 "$sandbox/one/run.sh" -j 3 2>&1)"
status=$?
took=$(( $(date +%s) - began ))
check "jobs: the run passes" "$(( status == 0 ))" "exit $status: $out"
check "jobs: -j 3 runs all three at once" "$(( $(max_overlap "$log") == 3 ))" "$(cat "$log")"
check "jobs: in less than two cases' time" "$(( took < 6 ))" "${took}s"
order="$(case_order "$out")"
check "jobs: cases still print in name order" "$(holds test "$order" = "rt_a rt_b rt_c ")" "$order"

# 3. slots: two runs, two slots, each run asking for two at once
make_runner "$sandbox/two" rt_d rt_e rt_f
first="$sandbox/slots-first.log"; second="$sandbox/slots-second.log"
RUNNER_LOG="$first" RUNNER_SLEEP=2 UNPEEL_TUI_SLOTS=2 \
  "$sandbox/one/run.sh" -j 2 >"$sandbox/first.out" 2>&1 &
first_pid=$!
RUNNER_LOG="$second" RUNNER_SLEEP=2 UNPEEL_TUI_SLOTS=2 \
  "$sandbox/two/run.sh" -j 2 >"$sandbox/second.out" 2>&1 &
second_pid=$!
wait "$first_pid"; first_status=$?
wait "$second_pid"; second_status=$?
check "slots: both runs pass" "$(( first_status == 0 && second_status == 0 ))" \
  "$(cat "$sandbox/first.out" "$sandbox/second.out")"
check "slots: never more cases than slots, across both runs" \
  "$(( $(max_overlap "$first" "$second") == 2 ))" "$(cat "$first" "$second")"
crossed="$(awk 'FNR == 1 { run++ } $1 == "start" { from[run, $2] = $3; names[run] = names[run] " " $2 }
  $1 == "end" { to[run, $2] = $3 }
  END {
    split(names[1], a, " "); split(names[2], b, " ")
    for (i in a) for (j in b)
      if (from[1, a[i]] < to[2, b[j]] && from[2, b[j]] < to[1, a[i]]) { print 1; exit }
    print 0
  }' "$first" "$second")"
check "slots: the two runs' cases overlap in time" "$crossed" "$(cat "$first" "$second")"
overlapping_homes="$(awk '$1=="start"{home[$2]=$4; from[$2]=$3} $1=="end"{to[$2]=$3}
  END { for (a in home) for (b in home) if (a < b && home[a] == home[b] && from[a] < to[b] && from[b] < to[a]) print a, b }' \
  "$first" "$second")"
check "slots: no two live cases share a home" "$(holds test -z "$overlapping_homes")" "$overlapping_homes"
homes="$(awk '$1=="start"{print $4}' "$first" "$second" | sort -u)"
bad_homes="$(for home in $homes; do
  [[ "$home" == "$UNPEEL_TUI_SLOT_DIR/s"[12]-rt_[a-f] ]] || echo "$home"
done)"
check "slots: homes are <slot dir>/s<slot>-<case>" "$(holds test -z "$bad_homes")" "$bad_homes"
left="$(for home in $homes; do [[ -e "$home" ]] && echo "$home"; done)"
check "slots: homes are removed after the run" "$(holds test -z "$left")" "$left"
check "slots: fd 9 is closed in every case" \
  "$(awk '$1=="start" && $5 != 0 { bad = 1 } END { print bad ? 0 : 1 }' "$first" "$second")" ""

# 4. failure
make_runner "$sandbox/bad" bad_one rt_g
out="$(RUNNER_LOG="$sandbox/bad.log" "$sandbox/bad/run.sh" 2>&1)"
status=$?
check "failure: a failing case fails the run" "$(( status == 1 ))" "exit $status"
check "failure: and is named" "$(holds grep -q '^failing cases: bad_one$' <<<"$out")" "$out"

# 5. interrupt
make_runner "$sandbox/stop" rt_h rt_i rt_j rt_k
log="$sandbox/stop.log"
RUNNER_LOG="$log" RUNNER_SLEEP=30 UNPEEL_TUI_SLOTS=2 \
  "$sandbox/stop/run.sh" -j 2 >"$sandbox/stop.out" 2>&1 &
runner=$!
for _ in $(seq 50); do
  started="$(grep -c '^start' "$log" 2>/dev/null)"
  (( ${started:-0} == 2 )) && break
  sleep 0.2
done
kill -TERM "$runner"
began=$(date +%s)
wait "$runner"; status=$?
took=$(( $(date +%s) - began ))
check "interrupt: run.sh exits 143" "$(( status == 143 ))" "exit $status: $(cat "$sandbox/stop.out")"
check "interrupt: well before the cases would have finished" "$(( took < 20 ))" "${took}s"
check "interrupt: both running cases unwound through cleanup" \
  "$(( $(grep -c '^end' "$log") == 2 ))" "$(cat "$log")"
check "interrupt: no new case started" "$(( $(grep -c '^start' "$log") == 2 ))" "$(cat "$log")"

# 6. crash: a holder killed -9 frees its slot
make_runner "$sandbox/crash" rt_l
hold_slots "$sandbox/crash.ready" "$UNPEEL_TUI_SLOT_DIR/1"
holder=$!
await_file "$sandbox/crash.ready" "$holder" 20
log="$sandbox/crash.log"
RUNNER_LOG="$log" RUNNER_SLEEP=0.2 UNPEEL_TUI_SLOTS=1 \
  "$sandbox/crash/run.sh" >"$sandbox/crash.out" 2>&1 &
runner=$!
sleep 2
check "crash: a held slot keeps the case waiting" "$(holds test ! -s "$log")" "$(cat "$log" 2>/dev/null)"
stop "$holder"; holder=""
for _ in $(seq 50); do kill -0 "$runner" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$runner" 2>/dev/null; then
  kill -TERM "$runner"
  check "crash: the slot is free once its holder is killed -9" 0 "still waiting after 10s"
else
  wait "$runner"; status=$?
  check "crash: the slot is free once its holder is killed -9" "$(( status == 0 ))" \
    "exit $status: $(cat "$sandbox/crash.out")"
  check "crash: the run says how long the case waited" \
    "$(holds grep -q 'waited [0-9]*s for a slot' "$sandbox/crash.out")" \
    "$(cat "$sandbox/crash.out")"
fi

# 7. queue: one slot, a four-case run, then a one-case run arriving later
make_runner "$sandbox/long" rt_m rt_n rt_o rt_p
make_runner "$sandbox/short" rt_q
long_log="$sandbox/long.log"; short_log="$sandbox/short.log"
RUNNER_LOG="$long_log" RUNNER_SLEEP=2 UNPEEL_TUI_SLOTS=1 \
  "$sandbox/long/run.sh" >"$sandbox/long.out" 2>&1 &
long_pid=$!
for _ in $(seq 50); do [[ -s "$long_log" ]] && break; sleep 0.2; done
RUNNER_LOG="$short_log" RUNNER_SLEEP=0.2 UNPEEL_TUI_SLOTS=1 \
  "$sandbox/short/run.sh" >"$sandbox/short.out" 2>&1 &
short_pid=$!
wait "$short_pid"; short_status=$?
wait "$long_pid"; long_status=$?
check "queue: both runs pass" "$(( short_status == 0 && long_status == 0 ))" \
  "$(cat "$sandbox/long.out" "$sandbox/short.out")"
long_starts="$(awk '$1 == "start" { n++ } END { print n + 0 }' "$long_log")"
before="$(awk -v t="$(awk '$1 == "start" { print $3 }' "$short_log")" \
  '$1 == "start" && $3 < t { n++ } END { print n + 0 }' "$long_log")"
check "queue: the later run's case goes next, after the first run's current case" \
  "$(( long_starts == 4 && before == 1 ))" "$(sort -k3,3n "$long_log" "$short_log")"

check "isolation: the live home outside the sandbox survives the self-test" \
  "$(holds test -e "$decoy/app-state.json")" "$decoy was removed"

echo
if (( failures )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all runner checks passed"
