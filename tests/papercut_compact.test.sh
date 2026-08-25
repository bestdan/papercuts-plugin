#!/usr/bin/env bash
# Tests for papercut_compact.py — deterministic transcript compaction that
# keeps the extractor's input under the byte budget.
# Run:
#   bash tests/papercut_compact.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
module="$script_dir/papercut_compact.py"
fixtures="$(cd "$(dirname "$0")" && pwd)/fixtures"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

assert_lt() {
  local actual="$1" bound="$2" desc="$3"
  if [ "$actual" -lt "$bound" ]; then
    pass "$desc ($actual < $bound)"
  else
    fail_test "$desc ($actual >= $bound)"
  fi
}

assert_gt() {
  local actual="$1" bound="$2" desc="$3"
  if [ "$actual" -gt "$bound" ]; then
    pass "$desc ($actual > $bound)"
  else
    fail_test "$desc ($actual <= $bound)"
  fi
}

assert_contains() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -- "$needle" "$file"; then
    pass "$desc"
  else
    fail_test "$desc (missing: $needle)"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -- "$needle" "$file"; then
    fail_test "$desc (found: $needle)"
  else
    pass "$desc"
  fi
}

assert_valid_jsonl() {
  local file="$1" desc="$2"
  if python3 -c "
import json, sys
with open('$file') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        json.loads(line)
" 2>"$workdir/jsonl_err"; then
    pass "$desc"
  else
    fail_test "$desc ($(cat "$workdir/jsonl_err"))"
  fi
}

run_compact() {
  local input="$1" budget="${2:-}"
  if [ -n "$budget" ]; then
    PAPERCUT_COMPACT_BUDGET_BYTES="$budget" python3 "$module" <"$input"
  else
    python3 "$module" <"$input"
  fi
}

# --- large_payload fixture: raw > default budget, compacted < default budget
large_out="$workdir/large_out.jsonl"
run_compact "$fixtures/large_payload.jsonl" >"$large_out"
large_exit=$?
raw_bytes=$(wc -c <"$fixtures/large_payload.jsonl" | tr -d ' ')
compacted_bytes=$(wc -c <"$large_out" | tr -d ' ')
if [ "$large_exit" -eq 0 ]; then
  pass "large_payload: compact exits 0"
else
  fail_test "large_payload: compact exits 0 (got $large_exit)"
fi
assert_gt "$raw_bytes" 200000 "large_payload: raw fixture exceeds default budget"
assert_lt "$compacted_bytes" 200000 "large_payload: compacted output under default budget"
assert_valid_jsonl "$large_out" "large_payload: compacted output is valid JSONL"

# large non-error tool_result payload elided: stub present, raw payload absent
assert_contains "$large_out" "bytes elided" "large_payload: non-error tool_result stub present"
assert_not_contains "$large_out" "$(printf 'x%.0s' $(seq 1 5000))" "large_payload: raw non-error payload body absent"

# error tool_result + denial survive inside the same fixture
assert_contains "$large_out" "permission denied writing to /opt/app/release" "large_payload: error tool_result content survives"
assert_contains "$large_out" '"toolDenialKind":"user-rejected"' "large_payload: denial entry survives"

# --- determinism: same input -> byte-identical output across two runs
large_out2="$workdir/large_out2.jsonl"
run_compact "$fixtures/large_payload.jsonl" >"$large_out2"
if diff -q "$large_out" "$large_out2" >/dev/null; then
  pass "large_payload: determinism (byte-identical across two runs)"
else
  fail_test "large_payload: determinism (byte-identical across two runs)"
fi

# --- user text turns survive verbatim on a fixture whose must-keeps fit budget
turns_out="$workdir/turns_out.jsonl"
run_compact "$fixtures/nontrivial_turns.jsonl" >"$turns_out"
assert_contains "$turns_out" "Please add a helper function to parse config files." "nontrivial_turns: first user turn verbatim"
assert_contains "$turns_out" "Now add validation for missing keys." "nontrivial_turns: mid-session user turn verbatim"
assert_contains "$turns_out" "Perfect, that's exactly what I needed. Thanks!" "nontrivial_turns: final user turn verbatim"
assert_valid_jsonl "$turns_out" "nontrivial_turns: compacted output is valid JSONL"

# --- dedicated error/denial fixtures survive verbatim
error_out="$workdir/error_out.jsonl"
run_compact "$fixtures/tool_error.jsonl" >"$error_out"
assert_contains "$error_out" "Exit code 1: build failed, missing dependency 'widget'" "tool_error: error content survives verbatim"

denial_out="$workdir/denial_out.jsonl"
run_compact "$fixtures/denial.jsonl" >"$denial_out"
assert_contains "$denial_out" '"toolDenialKind":"user-rejected"' "denial: denial entry survives"

# --- thinking blocks dropped entirely
thinking_in="$workdir/thinking.jsonl"
cat >"$thinking_in" <<'EOF'
{"type":"user","message":{"role":"user","content":"Investigate the flaky test."}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"SENTINEL_THINKING_SHOULD_BE_DROPPED"},{"type":"text","text":"SENTINEL_TEXT_SHOULD_SURVIVE"}]}}
EOF
thinking_out="$workdir/thinking_out.jsonl"
run_compact "$thinking_in" >"$thinking_out"
assert_not_contains "$thinking_out" "SENTINEL_THINKING_SHOULD_BE_DROPPED" "thinking blocks dropped"
assert_not_contains "$thinking_out" '"type":"thinking"' "no thinking block type in output"
assert_contains "$thinking_out" "SENTINEL_TEXT_SHOULD_SURVIVE" "sibling text block still present"

# --- pathological: must-keep set alone exceeds budget -> truncated, still under budget
path_in="$workdir/pathological.jsonl"
python3 - "$path_in" <<'PYEOF'
import json, sys
path = sys.argv[1]
lines = []
for i in range(3):
    lines.append(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": f"USERTEXT_{i}_" + ("a" * 1500)},
    }))
lines.append(json.dumps({
    "type": "user",
    "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "ERRTEXT_" + ("b" * 3000), "is_error": True}
    ]},
}))
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
path_out="$workdir/pathological_out.jsonl"
run_compact "$path_in" 1500 >"$path_out"
path_exit=$?
path_bytes=$(wc -c <"$path_out" | tr -d ' ')
if [ "$path_exit" -eq 0 ]; then
  pass "pathological: compact exits 0"
else
  fail_test "pathological: compact exits 0 (got $path_exit)"
fi
assert_lt "$path_bytes" 1500 "pathological: output under absolute budget despite must-keeps exceeding it"
assert_contains "$path_out" "...[truncated]..." "pathological: truncation marker present"
assert_contains "$path_out" "USERTEXT_0_" "pathological: user turn 0 present in truncated form"
assert_contains "$path_out" "USERTEXT_1_" "pathological: user turn 1 present in truncated form"
assert_contains "$path_out" "USERTEXT_2_" "pathological: user turn 2 present in truncated form"
assert_contains "$path_out" "ERRTEXT_" "pathological: error payload present in truncated form"
assert_valid_jsonl "$path_out" "pathological: output is valid JSONL"

# --- malformed line does not crash the run
malformed_in="$workdir/malformed.jsonl"
cat >"$malformed_in" <<'EOF'
{"type":"user","message":{"role":"user","content":"This line is fine."}}
{not valid json at all
{"type":"user","message":{"role":"user","content":"This line is also fine."}}
EOF
malformed_out="$workdir/malformed_out.jsonl"
run_compact "$malformed_in" >"$malformed_out"
malformed_exit=$?
if [ "$malformed_exit" -eq 0 ]; then
  pass "malformed line: compact exits 0"
else
  fail_test "malformed line: compact exits 0 (got $malformed_exit)"
fi
assert_contains "$malformed_out" "This line is fine." "malformed line: preceding valid line intact"
assert_contains "$malformed_out" "This line is also fine." "malformed line: following valid line intact"
assert_valid_jsonl "$malformed_out" "malformed line: output is still valid JSONL"

# --- Task 5: anchor-informed compaction -------------------------------------
# Build an over-budget transcript of "smooth" filler tool calls (no user
# turns, errors, or denials -- nothing task 1's structural rules would keep)
# plus one target tool_use/tool_result pair, and an anchors file naming it.
# Without anchors, the target is indistinguishable from filler and gets
# elided. With anchors, its neighborhood must survive.
anchor_fixture="$workdir/anchor_fixture.jsonl"
python3 - "$anchor_fixture" <<'PYEOF'
import json, sys

path = sys.argv[1]
lines = []


def filler(i):
    lines.append(json.dumps({
        "type": "assistant",
        "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": f"toolu_filler_{i}", "name": "Bash", "input": {"command": f"echo filler {i}"}}
        ]},
    }))
    lines.append(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": f"toolu_filler_{i}", "content": "filler result " + "x" * 300, "is_error": False}
        ]},
    }))


for i in range(15):
    filler(i)

# Target: an ordinary (non-error) tool_result the anchor names by tool_use_id.
lines.append(json.dumps({
    "type": "assistant",
    "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_ANCHOR1", "name": "Bash", "input": {"command": "do the important thing"}}
    ]},
}))
lines.append(json.dumps({
    "type": "user",
    "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_ANCHOR1", "content": "SENTINEL_ANCHOR_SURVIVES important result", "is_error": False}
    ]},
}))

for i in range(15, 30):
    filler(i)

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

anchor_file="$workdir/anchors_id.jsonl"
printf '{"v":1,"session_id":"s","kind":"tool_error","tool_name":"Bash","tool_use_id":"toolu_ANCHOR1","error_class":"unknown"}\n' >"$anchor_file"

anchor_budget=2000
noanchor_out="$workdir/anchor_noanchor_out.jsonl"
PAPERCUT_COMPACT_BUDGET_BYTES="$anchor_budget" python3 "$module" <"$anchor_fixture" >"$noanchor_out"
anchor_out="$workdir/anchor_out.jsonl"
PAPERCUT_COMPACT_BUDGET_BYTES="$anchor_budget" python3 "$module" --anchors "$anchor_file" <"$anchor_fixture" >"$anchor_out"

assert_not_contains "$noanchor_out" "SENTINEL_ANCHOR_SURVIVES" \
  "anchors: without anchors file, target neighborhood is elided under budget"
assert_contains "$anchor_out" "SENTINEL_ANCHOR_SURVIVES" \
  "anchors: tool_use_id-matched anchor keeps target neighborhood even under budget"
assert_valid_jsonl "$anchor_out" "anchors: tool_use_id-matched output is valid JSONL"

# --- Fallback: anchor lacking tool_use_id, matched by tool_name+kind+order --
fallback_fixture="$workdir/fallback_fixture.jsonl"
python3 - "$fallback_fixture" <<'PYEOF'
import json, sys

path = sys.argv[1]
lines = []


def filler(i):
    lines.append(json.dumps({
        "type": "assistant",
        "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": f"toolu_filler_{i}", "name": "Bash", "input": {"command": f"echo filler {i}"}}
        ]},
    }))
    lines.append(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": f"toolu_filler_{i}", "content": "filler result " + "x" * 300, "is_error": False}
        ]},
    }))


for i in range(15):
    filler(i)

# Target: an ordinary Write invocation -- the anchor names it by tool_name
# only (no tool_use_id), simulating a permission_prompt anchor whose payload
# never surfaced a matchable id.
lines.append(json.dumps({
    "type": "assistant",
    "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_TARGET1", "name": "Write", "input": {"file_path": "SENTINEL_FALLBACK_SURVIVES.txt"}}
    ]},
}))
lines.append(json.dumps({
    "type": "user",
    "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_TARGET1", "content": "file written", "is_error": False}
    ]},
}))

for i in range(15, 30):
    filler(i)

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

fallback_anchor_file="$workdir/anchors_fallback.jsonl"
printf '{"v":1,"session_id":"s","kind":"permission_prompt","tool_name":"Write"}\n' >"$fallback_anchor_file"

fallback_noanchor_out="$workdir/fallback_noanchor_out.jsonl"
PAPERCUT_COMPACT_BUDGET_BYTES="$anchor_budget" python3 "$module" <"$fallback_fixture" >"$fallback_noanchor_out"
fallback_out="$workdir/fallback_out.jsonl"
fallback_exit=0
PAPERCUT_COMPACT_BUDGET_BYTES="$anchor_budget" python3 "$module" --anchors "$fallback_anchor_file" <"$fallback_fixture" >"$fallback_out" || fallback_exit=$?

if [ "$fallback_exit" -eq 0 ]; then
  pass "anchors fallback: missing tool_use_id does not crash"
else
  fail_test "anchors fallback: missing tool_use_id does not crash (got $fallback_exit)"
fi
assert_not_contains "$fallback_noanchor_out" "SENTINEL_FALLBACK_SURVIVES" \
  "anchors fallback: without anchors file, target neighborhood is elided under budget"
assert_contains "$fallback_out" "SENTINEL_FALLBACK_SURVIVES" \
  "anchors fallback: tool_name+kind+order fallback keeps a plausible candidate"
assert_valid_jsonl "$fallback_out" "anchors fallback: output is valid JSONL"

# --- No anchors file -> byte-identical to task-1 behavior (no regression) ---
# Exercise every "absent" path against the SAME over-budget input (the
# existing large_payload fixture, which already forces stage 2 + 3): env
# unset, env pointing at a nonexistent path, and an explicit --anchors flag
# with no counterpart file.
baseline_out="$workdir/baseline_noanchors.jsonl"
run_compact "$fixtures/large_payload.jsonl" >"$baseline_out"

env_missing_out="$workdir/env_missing_out.jsonl"
PAPERCUT_ANCHORS="$workdir/does-not-exist.jsonl" python3 "$module" <"$fixtures/large_payload.jsonl" >"$env_missing_out"
if diff -q "$baseline_out" "$env_missing_out" >/dev/null; then
  pass "anchors: PAPERCUT_ANCHORS pointing at a missing file is byte-identical to no anchors"
else
  fail_test "anchors: PAPERCUT_ANCHORS pointing at a missing file is byte-identical to no anchors"
fi

flag_missing_out="$workdir/flag_missing_out.jsonl"
python3 "$module" --anchors "$workdir/also-does-not-exist.jsonl" <"$fixtures/large_payload.jsonl" >"$flag_missing_out"
if diff -q "$baseline_out" "$flag_missing_out" >/dev/null; then
  pass "anchors: --anchors pointing at a missing file is byte-identical to no anchors"
else
  fail_test "anchors: --anchors pointing at a missing file is byte-identical to no anchors"
fi

# --- Malformed / empty anchors file -> treated as no anchors, no crash -----
empty_anchors="$workdir/empty_anchors.jsonl"
: >"$empty_anchors"
empty_out="$workdir/empty_anchors_out.jsonl"
empty_exit=0
python3 "$module" --anchors "$empty_anchors" <"$fixtures/large_payload.jsonl" >"$empty_out" || empty_exit=$?
if [ "$empty_exit" -eq 0 ] && diff -q "$baseline_out" "$empty_out" >/dev/null; then
  pass "anchors: empty anchors file behaves exactly as no anchors"
else
  fail_test "anchors: empty anchors file behaves exactly as no anchors (exit=$empty_exit)"
fi

malformed_anchors="$workdir/malformed_anchors.jsonl"
printf 'not valid json at all\n{"also": "not an anchor" \n\n' >"$malformed_anchors"
malformed_anchors_out="$workdir/malformed_anchors_out.jsonl"
malformed_anchors_exit=0
python3 "$module" --anchors "$malformed_anchors" <"$fixtures/large_payload.jsonl" >"$malformed_anchors_out" || malformed_anchors_exit=$?
if [ "$malformed_anchors_exit" -eq 0 ] && diff -q "$baseline_out" "$malformed_anchors_out" >/dev/null; then
  pass "anchors: malformed anchors file behaves exactly as no anchors, no crash"
else
  fail_test "anchors: malformed anchors file behaves exactly as no anchors, no crash (exit=$malformed_anchors_exit)"
fi

# --- papercut-capture.sh exports PAPERCUT_ANCHORS only when the file exists -
# Route the extractor seam through a stub that dumps its own environment,
# so we can assert PAPERCUT_ANCHORS's presence/absence without depending on
# the real extractor-run.sh or claude binary.
capture_hook="$script_dir/papercut-capture.sh"
env_capture_dump() {
  local case_dir="$1" anchors_dir="$2" anchor_file_exists="$3"
  mkdir -p "$case_dir" "$anchors_dir"
  local session_id="anchor-export-case-$4"
  local session_key
  session_key=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8','surrogateescape')).hexdigest())" "$session_id")
  if [ "$anchor_file_exists" = "yes" ]; then
    printf '{"v":1,"session_id":"%s","kind":"tool_error","tool_name":"Bash","tool_use_id":"toolu_1","error_class":"unknown"}\n' "$session_id" \
      >"$anchors_dir/${session_key}.jsonl"
  fi
  local transcript="$case_dir/transcript.jsonl"
  cp "$fixtures/nontrivial_turns.jsonl" "$transcript"
  local payload
  payload=$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$transcript" "$session_id" "$case_dir")
  local env_capture="$case_dir/captured_env.txt"
  env \
    PAPERCUT_PROCESSED_DIR="$case_dir/processed" \
    PAPERCUT_CAPTURE_LOCKDIR="$case_dir/locks" \
    PAPERCUT_LOG="$case_dir/capture.log" \
    PAPERCUT_ANCHORS_DIR="$anchors_dir" \
    PAPERCUT_EXTRACTOR_CMD="env >\"$env_capture\"; echo []" \
    PAPERCUT_APPEND_CMD="true" \
    PAPERCUT_SPOOL="$case_dir/spool.jsonl" \
    PAPERCUT_LOCK="$case_dir/.spool.lock" \
    bash "$capture_hook" <<<"$payload" >/dev/null 2>&1 || true
  cat "$env_capture" 2>/dev/null
}

case_present_dir="$workdir/anchor_export_present"
case_absent_dir="$workdir/anchor_export_absent"
present_env=$(env_capture_dump "$case_present_dir" "$case_present_dir/anchors" "yes" "present")
absent_env=$(env_capture_dump "$case_absent_dir" "$case_absent_dir/anchors" "no" "absent")

if printf '%s' "$present_env" | grep -q '^PAPERCUT_ANCHORS='; then
  pass "capture.sh: exports PAPERCUT_ANCHORS when the anchors sidecar file exists"
else
  fail_test "capture.sh: exports PAPERCUT_ANCHORS when the anchors sidecar file exists"
fi

if printf '%s' "$absent_env" | grep -q '^PAPERCUT_ANCHORS='; then
  fail_test "capture.sh: does not export PAPERCUT_ANCHORS when the anchors sidecar file is absent"
else
  pass "capture.sh: does not export PAPERCUT_ANCHORS when the anchors sidecar file is absent"
fi

if [ "$fail" -eq 0 ]; then
  echo "All papercut_compact tests passed."
else
  echo "Some papercut_compact tests FAILED."
fi
exit "$fail"
