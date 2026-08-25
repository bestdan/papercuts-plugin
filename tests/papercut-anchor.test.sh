#!/usr/bin/env bash
# Tests for papercut-anchor.sh — the PostToolUseFailure/Notification hook
# that records content-light "anchor" lines for acute friction (tool errors,
# permission prompts) so they survive even if compaction trims them and even
# if SessionEnd never fires. Run:
#   bash tests/papercut-anchor.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
hook="$script_dir/papercut-anchor.sh"

fail=0
counter=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

# Fresh per-case anchors dir. Sets the global $anchors_dir.
new_env() {
  counter=$((counter + 1))
  anchors_dir="$workdir/anchors-$counter"
}

run_hook() {
  local payload="$1"
  shift
  printf '%s' "$payload" | env PAPERCUT_ANCHORS_DIR="$anchors_dir" "$@" bash "$hook"
}

session_key() {
  python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8','surrogateescape')).hexdigest())" "$1"
}

anchor_file_for() {
  printf '%s/%s.jsonl' "$anchors_dir" "$(session_key "$1")"
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail_test "$desc (expected [$expected], got [$actual])"
  fi
}

assert_exists() {
  local path="$1" desc="$2"
  if [ -e "$path" ]; then
    pass "$desc"
  else
    fail_test "$desc (missing: $path)"
  fi
}

assert_not_exists() {
  local path="$1" desc="$2"
  if [ -e "$path" ]; then
    fail_test "$desc (unexpectedly present: $path)"
  else
    pass "$desc"
  fi
}

# --- 1. PostToolUseFailure -> one tool_error anchor, raw session_id, tool
# name, tool_use_id, enum error_class, no tool_input/tool_output content.
new_env
session_id="session-one-1111"
payload=$(cat <<EOF
{"hook_event_name":"PostToolUseFailure","session_id":"$session_id","tool_name":"Bash","tool_use_id":"tu_abc123","exit_code":127,"tool_input":{"command":"cat /Users/dan/secret/ticket-ENG-4242.txt"},"tool_output":{"stderr":"cat: /Users/dan/secret/ticket-ENG-4242.txt: No such file or directory"}}
EOF
)
run_hook "$payload"
rc=$?
anchor_path=$(anchor_file_for "$session_id")
assert_eq "$rc" "0" "PostToolUseFailure: hook exits 0"
assert_exists "$anchor_path" "PostToolUseFailure: anchor file created"
if [ -f "$anchor_path" ]; then
  line_count=$(wc -l <"$anchor_path" | tr -d ' ')
  assert_eq "$line_count" "1" "PostToolUseFailure: exactly one anchor line"
  record=$(cat "$anchor_path")
  kind=$(printf '%s' "$record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')
  sid=$(printf '%s' "$record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_id"])')
  tool_name=$(printf '%s' "$record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tool_name"])')
  tool_use_id=$(printf '%s' "$record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tool_use_id"])')
  error_class=$(printf '%s' "$record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$kind" "tool_error" "PostToolUseFailure: kind is tool_error"
  assert_eq "$sid" "$session_id" "PostToolUseFailure: raw session_id preserved"
  assert_eq "$tool_name" "Bash" "PostToolUseFailure: tool_name present"
  assert_eq "$tool_use_id" "tu_abc123" "PostToolUseFailure: tool_use_id present"
  assert_eq "$error_class" "nonzero_exit" "PostToolUseFailure: error_class is enum value"
  if printf '%s' "$record" | grep -qi 'ENG-4242\|secret\|tool_input\|tool_output\|No such file'; then
    fail_test "PostToolUseFailure: no tool_input/tool_output content leaked"
  else
    pass "PostToolUseFailure: no tool_input/tool_output content leaked"
  fi
  perm=$(stat -c '%a' "$anchor_path" 2>/dev/null || stat -f '%Lp' "$anchor_path" 2>/dev/null)
  assert_eq "$perm" "600" "PostToolUseFailure: anchor file mode 600"
  dir_perm=$(stat -c '%a' "$anchors_dir" 2>/dev/null || stat -f '%Lp' "$anchors_dir" 2>/dev/null)
  assert_eq "$dir_perm" "700" "PostToolUseFailure: anchors dir mode 700"
fi

# --- 2. Filename == sha256(raw session_id).jsonl, including a filename-hostile id.
new_env
hostile_id='sess/../weird?id: with spaces\backslash'
payload=$(python3 -c '
import json, sys
print(json.dumps({
    "hook_event_name": "PostToolUseFailure",
    "session_id": sys.argv[1],
    "tool_name": "Bash",
    "tool_use_id": "tu_x",
    "exit_code": 1,
}))
' "$hostile_id")
run_hook "$payload"
expected_path=$(anchor_file_for "$hostile_id")
assert_exists "$expected_path" "filename-hostile session_id: anchor lands at sha256(raw id).jsonl"
if [ -f "$expected_path" ]; then
  sid=$(head -n1 "$expected_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_id"])')
  assert_eq "$sid" "$hostile_id" "filename-hostile session_id: raw id stored verbatim in record"
fi

# --- 3. PostToolUse success -> no anchor written (no-op).
new_env
session_id="session-success-2222"
payload='{"hook_event_name":"PostToolUse","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_ok","tool_output_type":"success"}'
run_hook "$payload"
rc=$?
assert_eq "$rc" "0" "PostToolUse success: hook exits 0"
assert_not_exists "$(anchor_file_for "$session_id")" "PostToolUse success: no anchor written"

# --- 4. Notification permission_prompt -> one permission_prompt anchor.
new_env
session_id="session-prompt-3333"
payload='{"hook_event_name":"Notification","session_id":"'"$session_id"'","notification_type":"permission_prompt","tool_name":"Bash","tool_use_id":"tu_prompt"}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
assert_exists "$anchor_path" "Notification permission_prompt: anchor created"
if [ -f "$anchor_path" ]; then
  kind=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')
  assert_eq "$kind" "permission_prompt" "Notification permission_prompt: kind is permission_prompt"
fi

# --- 4b. Notification of a non-permission_prompt type -> no anchor.
new_env
session_id="session-other-notif-3334"
payload='{"hook_event_name":"Notification","session_id":"'"$session_id"'","notification_type":"idle_timeout"}'
run_hook "$payload"
assert_not_exists "$(anchor_file_for "$session_id")" "Notification non-permission_prompt: no anchor written"

# --- 5. Older tool_response.is_error fallback shape still detected.
new_env
session_id="session-fallback-4444"
payload='{"hook_event_name":"PostToolUse","session_id":"'"$session_id"'","tool_name":"Read","tool_use_id":"tu_fallback","tool_response":{"is_error":true}}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
assert_exists "$anchor_path" "tool_response.is_error fallback: anchor created"
if [ -f "$anchor_path" ]; then
  kind=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$kind" "tool_error" "tool_response.is_error fallback: kind is tool_error"
  assert_eq "$error_class" "unknown" "tool_response.is_error fallback: error_class falls back to unknown enum value"
fi

# --- 6. error_class is always one of the enum values, never free text.
new_env
session_id="session-enum-5555"
payload='{"hook_event_name":"PostToolUseFailure","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_enum","error":{"message":"some completely unexpected weird shape"}}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  case "$error_class" in
    nonzero_exit | timeout | not_found | interrupted | denied | unknown)
      pass "unrecognized error shape: error_class is a known enum value ($error_class)"
      ;;
    *)
      fail_test "unrecognized error shape: error_class is a known enum value (got: $error_class)"
      ;;
  esac
else
  fail_test "unrecognized error shape: anchor file was created"
fi

# --- 6b. Installed-CLI shape: top-level string `error` ("Exit code N\n...")
# must classify as nonzero_exit, not unknown (the regression this fix covers).
new_env
session_id="session-string-error-5556"
payload=$(python3 -c '
import json, sys
print(json.dumps({
    "hook_event_name": "PostToolUseFailure",
    "session_id": sys.argv[1],
    "tool_name": "Bash",
    "tool_use_id": "tu_strerr",
    "error": "Exit code 1\nls: /nope-does-not-exist: No such file or directory",
}))
' "$session_id")
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$error_class" "nonzero_exit" "string error 'Exit code 1\\n...': error_class is nonzero_exit"
else
  fail_test "string error 'Exit code 1\\n...': anchor file was created"
fi

# --- 6c. Bare string error with no trailing detail still parses.
new_env
session_id="session-string-error-bare-5557"
payload='{"hook_event_name":"PostToolUseFailure","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_bare","error":"Exit code 1"}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$error_class" "nonzero_exit" "string error 'Exit code 1': error_class is nonzero_exit"
else
  fail_test "string error 'Exit code 1': anchor file was created"
fi

# --- 6d. String error "Exit code 0" must not be misclassified as nonzero_exit.
new_env
session_id="session-string-error-zero-5558"
payload='{"hook_event_name":"PostToolUseFailure","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_zero","error":"Exit code 0"}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$error_class" "unknown" "string error 'Exit code 0': error_class stays unknown"
else
  fail_test "string error 'Exit code 0': anchor file was created"
fi

# --- 6e. No-regression: structured error.exit_code object shape still works.
new_env
session_id="session-object-error-5559"
payload='{"hook_event_name":"PostToolUseFailure","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_obj","error":{"exit_code":1}}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$error_class" "nonzero_exit" "object error.exit_code=1: error_class is nonzero_exit (no regression)"
else
  fail_test "object error.exit_code=1: anchor file was created"
fi

# --- 6f. No-regression: unrecognized text with no keyword and no exit-code
# phrase still falls back to unknown.
new_env
session_id="session-no-match-5560"
payload='{"hook_event_name":"PostToolUseFailure","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_none","error":"something went sideways"}'
run_hook "$payload"
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  error_class=$(head -n1 "$anchor_path" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_class"])')
  assert_eq "$error_class" "unknown" "no keyword / no exit-code phrase: error_class stays unknown"
else
  fail_test "no keyword / no exit-code phrase: anchor file was created"
fi

# --- 7. Malformed / empty stdin -> exit 0, no crash, nothing written.
new_env
run_hook ""
rc=$?
assert_eq "$rc" "0" "empty stdin: hook exits 0"
jsonl_count=$(find "$anchors_dir" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$jsonl_count" "0" "empty stdin: no anchor jsonl files written"

new_env
run_hook "{not valid json at all"
rc=$?
assert_eq "$rc" "0" "malformed stdin: hook exits 0"

new_env
run_hook '{"hook_event_name":"SomeOtherEvent","session_id":"whatever"}'
rc=$?
assert_eq "$rc" "0" "unrelated event: hook exits 0"
assert_not_exists "$(anchor_file_for "whatever")" "unrelated event: no anchor written"

# --- 8. Per-session cap halts appends past the limit.
new_env
session_id="session-cap-6666"
for i in $(seq 1 55); do
  run_hook '{"hook_event_name":"PostToolUseFailure","session_id":"'"$session_id"'","tool_name":"Bash","tool_use_id":"tu_'"$i"'","exit_code":1}' PAPERCUT_ANCHOR_CAP=50
done
anchor_path=$(anchor_file_for "$session_id")
if [ -f "$anchor_path" ]; then
  line_count=$(wc -l <"$anchor_path" | tr -d ' ')
  assert_eq "$line_count" "50" "per-session cap: appends halt at the cap (50)"
else
  fail_test "per-session cap: anchor file exists"
fi

if [ "$fail" -eq 0 ]; then
  echo "All papercut-anchor tests passed."
else
  echo "Some papercut-anchor tests FAILED."
fi
exit "$fail"
