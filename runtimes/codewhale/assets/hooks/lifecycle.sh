#!/bin/bash
umask 077
INPUT=$(cat)
# Global provider hooks must be inert outside a hosted Unpeel Session.
[ -n "${UNPEEL_SESSION_ID:-}" ] || exit 0
TRACE_FILE="${UNPEEL_HOOK_TRACE_FILE:-${UNPEEL_HOME:-$HOME/.unpeel}/hooks/trace.log}"
UNPEEL_PORT_REGISTRY_FILE="${UNPEEL_APP_PORT_REGISTRY_FILE:-${UNPEEL_HOME:-$HOME/.unpeel}/app-ports}"
mkdir -p "$(dirname "$TRACE_FILE")" >/dev/null 2>&1 || true

json_escape_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

runtime_generation_json_field() {
  case "${UNPEEL_RUNTIME_GENERATION:-}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf ',"unpeel_runtime_generation":%s' "$UNPEEL_RUNTIME_GENERATION"
}

# Codewhale's structured observer payloads are compact JSON objects.
json_string_value() {
  _key="$1"
  printf '%s' "$INPUT" | grep -oE "\"$_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'
}

json_is_false() {
  printf '%s' "$INPUT" | grep -qE "\"$1\"[[:space:]]*:[[:space:]]*false"
}

# Persist the last lifecycle event into the session dir so a restarted app can
# re-seed busy/attention state (hooks keep firing while no app is listening).
record_last_hook_event() {
  _record_event_name="$1"
  _record_tool_name="$2"
  # Session metadata must not erase a Stop/cancellation needed after restart.
  [ "$_record_event_name" != HookSeen ] || return 0
  _record_dir="${UNPEEL_SESSION_DIR:-${UNPEEL_HOME:-$HOME/.unpeel}/app-sessions/$UNPEEL_SESSION_ID}"
  [ -d "$_record_dir" ] || return 0
  # Idle backstops must preserve the known turn outcome and its recency.
  if [ "$_record_event_name" = Idle ] && [ -f "$_record_dir/last-hook-event.json" ]; then
    if grep -qE '"hook_event_name"[[:space:]]*:[[:space:]]*"(Stop|StopFailure|StopCancelled|Idle)"' "$_record_dir/last-hook-event.json"; then
      return 0
    fi
  fi
  _record_name_json="$(json_escape_string "$_record_event_name")"
  _record_generation="$(runtime_generation_json_field)"
  if [ -n "$_record_tool_name" ]; then
    _record_tool_json="$(json_escape_string "$_record_tool_name")"
    _record_payload=$(printf '{"hook_event_name":"%s","tool_name":"%s"%s}' "$_record_name_json" "$_record_tool_json" "$_record_generation")
  else
    _record_payload=$(printf '{"hook_event_name":"%s"%s}' "$_record_name_json" "$_record_generation")
  fi
  _record_tmp="$_record_dir/.last-hook-event.json.$$"
  if printf '%s' "$_record_payload" > "$_record_tmp" 2>/dev/null; then
    mv -f "$_record_tmp" "$_record_dir/last-hook-event.json" 2>/dev/null \
      || rm -f "$_record_tmp" 2>/dev/null || true
  fi
}

open_file_paths() {
  if [ -d "/proc/$1/fd" ]; then
    for _fd in /proc/"$1"/fd/*; do readlink "$_fd" 2>/dev/null; done
  elif command -v lsof >/dev/null 2>&1; then
    lsof -n -P -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'
  fi
}

# Codewhale's hook environment carries only a hook-correlation id (`sess_…`),
# not the saved session `codewhale --resume` accepts. The Codewhale process
# that ran this hook keeps its current saved session's
# `<sessions>/.late-usage/<id>.live` open (and switches it on /new or
# /resume), so read it from the nearest ancestor's open files. A session is
# reported only once its `<sessions>/<id>.json` exists; anything else leaves
# Resume on Codewhale's own continue-last.
codewhale_saved_session_path() {
  _uuid='[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}'
  _ancestor="$PPID"
  for _depth in 1 2 3; do
    case "$_ancestor" in ''|*[!0-9]*|0|1) return 1 ;; esac
    _live=$(open_file_paths "$_ancestor" | grep "/sessions/\.late-usage/$_uuid\.live\$" | head -1)
    if [ -n "$_live" ]; then
      _session_id=$(basename "$_live" .live)
      _sessions_dir=$(dirname "$(dirname "$_live")")
      [ -f "$_sessions_dir/$_session_id.json" ] || return 1
      printf '%s\n' "$_sessions_dir/$_session_id.json"
      return 0
    fi
    _ancestor=$(ps -o ppid= -p "$_ancestor" 2>/dev/null | tr -d ' ')
  done
  return 1
}

current_unpeel_ports() {
  [ -f "$UNPEEL_PORT_REGISTRY_FILE" ] || return 1
  awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ && $1 > 0 && $1 <= 65535 && !seen[$1 + 0]++ { print $1 + 0 }' \
    "$UNPEEL_PORT_REGISTRY_FILE" 2>/dev/null
}

# POST one hook payload synchronously and record the outcome in
# _hook_post_results ("<port>=<http-code>,..."). Loopback posts finish in
# milliseconds; the tight timeouts bound the worst case when a registry port
# is stale so a hook never burns its whole timeout budget on delivery.
post_hook_payload() {
  _hook_payload="$1"
  _hook_session_id="$2"
  _hook_port="$3"
  [ -n "$_hook_port" ] || return 1
  _hook_http_code=$(printf '%s' "$_hook_payload" | curl -s -o /dev/null -w '%{http_code}' \
    --noproxy '*' --connect-timeout 0.2 --max-time 1 -X POST -H "Content-Type: application/json" \
    -d @- "http://127.0.0.1:$_hook_port/hook/$_hook_session_id" 2>/dev/null) \
    || _hook_http_code="curl-fail"
  [ -n "$_hook_http_code" ] || _hook_http_code="curl-fail"
  if [ -z "${_hook_post_results:-}" ]; then
    _hook_post_results="$_hook_port=$_hook_http_code"
  else
    _hook_post_results="$_hook_post_results,$_hook_port=$_hook_http_code"
  fi
  printf 'hook-post session=%s port=%s status=%s\n' \
    "$_hook_session_id" "$_hook_port" "$_hook_http_code" >> "$TRACE_FILE" 2>/dev/null || true
  case "$_hook_http_code" in
    2*) return 0 ;;
    *) return 1 ;;
  esac
}

post_hook_payload_to_current_ports() {
  _hook_payload="$1"
  _hook_session_id="$2"
  _hook_skip_port="$3"
  _hook_post_pids=""
  for _hook_candidate_port in $(current_unpeel_ports); do
    [ -n "$_hook_candidate_port" ] || continue
    [ "$_hook_candidate_port" = "$_hook_skip_port" ] && continue
    ( post_hook_payload "$_hook_payload" "$_hook_session_id" "$_hook_candidate_port" || true ) &
    _hook_post_pids="$_hook_post_pids $!"
  done
  for _hook_post_pid in $_hook_post_pids; do
    wait "$_hook_post_pid" || true
  done
  return 0
}

# argv[1] names the Codewhale event family the installer registered:
#   HookSeen   session_start     metadata-only latch
#   Busy       session_busy      a turn begins or resumes after a wait
#   Attention  waiting_for_user  approval, question, or parked goal
#   TurnEnd    turn_end          outcome from the payload's `status`
#   Idle       session_idle,     backstop that never claims an outcome
#              session_end
# Codewhale's hook session id (`sess_…`) only correlates hook records; it is
# never forwarded as the provider conversation id.
EVENT_TYPE=""
TOOL_NAME=""
case "${1:-}" in
  HookSeen) EVENT_TYPE="HookSeen" ;;
  Busy) EVENT_TYPE="Start" ;;
  Attention)
    EVENT_TYPE="PermissionRequest"
    TOOL_NAME="$(json_string_value reason || true)"
    ;;
  TurnEnd)
    # Shell-only, manual-compaction, and purge completions are not agent
    # turns: settle them without a completion.
    if json_is_false model_backed; then
      EVENT_TYPE="Idle"
    else
      case "$(json_string_value status || true)" in
        completed) EVENT_TYPE="Stop" ;;
        interrupted|cancelled|canceled) EVENT_TYPE="StopCancelled" ;;
        failed|error) EVENT_TYPE="StopFailure" ;;
        *) EVENT_TYPE="Idle" ;;
      esac
    fi
    ;;
  Idle) EVENT_TYPE="Idle" ;;
  *) exit 0 ;;
esac

# Every turn end re-reads the saved session, so a /new or in-TUI /resume
# re-links the Unpeel Session to the conversation now on screen.
TRANSCRIPT_PATH=""
PROVIDER_SESSION_ID=""
if [ "${1:-}" = TurnEnd ]; then
  TRANSCRIPT_PATH="$(codewhale_saved_session_path || true)"
  [ -z "$TRANSCRIPT_PATH" ] || PROVIDER_SESSION_ID="$(basename "$TRANSCRIPT_PATH" .json)"
fi

record_last_hook_event "$EVENT_TYPE" "$TOOL_NAME"

# Codewhale runs observer hooks on two workers, so an idle backstop can land
# after the next turn's opening hook. It wakes the Host to reconcile the
# durable record instead of directly clearing that newer live turn.
DELIVERY_EVENT="$EVENT_TYPE"
[ "$EVENT_TYPE" != Idle ] || DELIVERY_EVENT=HookSeen

PAYLOAD=$(printf '{"hook_event_name":"%s"' "$(json_escape_string "$DELIVERY_EVENT")")
if [ -n "$TOOL_NAME" ]; then
  PAYLOAD="$PAYLOAD$(printf ',"tool_name":"%s"' "$(json_escape_string "$TOOL_NAME")")"
fi
if [ -n "$PROVIDER_SESSION_ID" ]; then
  PAYLOAD="$PAYLOAD$(printf ',"session_id":"%s","transcript_path":"%s"' \
    "$(json_escape_string "$PROVIDER_SESSION_ID")" "$(json_escape_string "$TRANSCRIPT_PATH")")"
fi
PAYLOAD="$PAYLOAD$(runtime_generation_json_field)}"

_hook_post_results=""
# Posts go out synchronously and in order: backgrounded fire-and-forget
# posts could be reaped when the hook process exited (silently losing the
# event), and concurrent posts could arrive out of order. Set
# UNPEEL_HOOK_POST_SYNC=0 to restore backgrounded posts.
if [ "${UNPEEL_HOOK_POST_SYNC:-1}" = "1" ]; then
  post_hook_payload "$PAYLOAD" "$UNPEEL_SESSION_ID" "${UNPEEL_APP_PORT:-}" || true
  post_hook_payload_to_current_ports "$PAYLOAD" "$UNPEEL_SESSION_ID" "${UNPEEL_APP_PORT:-}" || true
else
  (
    post_hook_payload "$PAYLOAD" "$UNPEEL_SESSION_ID" "${UNPEEL_APP_PORT:-}" || true
    post_hook_payload_to_current_ports "$PAYLOAD" "$UNPEEL_SESSION_ID" "${UNPEEL_APP_PORT:-}" || true
  ) &
fi

printf '%s codewhale-hook session=%s port=%s event=%s codewhale_session=%s provider_session=%s tool=%s post=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" \
  "$UNPEEL_SESSION_ID" \
  "${UNPEEL_APP_PORT:-}" \
  "$EVENT_TYPE" \
  "${CODEWHALE_SESSION_ID:-${DEEPSEEK_SESSION_ID:-}}" \
  "$PROVIDER_SESSION_ID" \
  "$TOOL_NAME" \
  "${_hook_post_results:-none}" >> "$TRACE_FILE" 2>/dev/null || true

exit 0
