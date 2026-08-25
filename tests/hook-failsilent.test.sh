#!/usr/bin/env bash
# Tests that every script wired as a plugin hook is fail-silent: handed an
# empty stdin payload, or garbage bytes where JSON was expected, it must still
# exit 0 so a session is never disrupted. Also covers the divergence the
# fail-closed config gate requires — `papercut-flush.sh --hook` exits 0 on a
# missing config where a direct invocation of the same script exits non-zero.
# Run:
#   bash tests/hook-failsilent.test.sh
#
# Every state path is redirected into a per-case temp dir, so this suite never
# touches real ~/.claude.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"

fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

# Each case gets its own directory. mktemp rather than an incrementing counter:
# this is called in a command substitution, so a counter would be incremented in
# a subshell and every case would silently share one directory.
new_dir() {
  mktemp -d "$workdir/case.XXXXXX"
}

# Garbage bytes: invalid UTF-8, unbalanced braces, NULs stripped by the shell.
garbage() {
  printf '\xff\xfe{"session_id: not json at all \x01\x02 }}}\n'
}

# run_hook <label> <script-name> <payload-kind> — payload-kind is empty|garbage
run_hook() {
  local label="$1" script="$2" kind="$3" dir rc
  dir="$(new_dir)"
  local env_args=(
    PAPERCUT_ANCHORS_DIR="$dir/anchors"
    PAPERCUT_PROCESSED_DIR="$dir/processed"
    PAPERCUT_PROJECTS_DIR="$dir/projects"
    PAPERCUT_CAPTURE_LOCKDIR="$dir/locks"
    PAPERCUT_SPOOL="$dir/spool.jsonl"
    PAPERCUT_LOCK="$dir/.spool.lock"
    PAPERCUT_BATCH_DIR="$dir"
    PAPERCUT_QUARANTINE_DIR="$dir/quarantine"
    PAPERCUT_FLUSH_OK="$dir/flush-ok"
    PAPERCUT_FLUSH_FAIL="$dir/flush-fail"
    PAPERCUT_REVIEW_FILE="$dir/scrub-review.jsonl"
    PAPERCUT_LOG="$dir/hook.log"
    PAPERCUT_DETECT_CMD='echo default'
    PAPERCUT_CAPTURE_CMD='cat >/dev/null'
    PAPERCUT_EXTRACTOR_CMD='echo []'
    PAPERCUT_CONFIG="$dir/no-such-config.toml"
  )
  if [ "$kind" = "garbage" ]; then
    garbage | env "${env_args[@]}" bash "$script_dir/$script" >/dev/null 2>&1
  else
    env "${env_args[@]}" bash "$script_dir/$script" </dev/null >/dev/null 2>&1
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$label ($kind stdin) exits 0"
  else
    fail_test "$label ($kind stdin) exits 0 (rc=$rc)"
  fi
}

# --- 1. every hook script, both malformed payload shapes -------------------
for kind in empty garbage; do
  run_hook "papercut-anchor.sh" papercut-anchor.sh "$kind"
  run_hook "papercut-sweep.sh" papercut-sweep.sh "$kind"
  run_hook "papercut-capture.sh" papercut-capture.sh "$kind"
done

# papercut-flush.sh reads no stdin, but the hook entry still feeds it a payload
# and it must survive both shapes. Passed through the --hook wrapper, which is
# how the manifest invokes it.
run_flush_hook() {
  local kind="$1" dir rc
  dir="$(new_dir)"
  local env_args=(
    PAPERCUT_SPOOL="$dir/spool.jsonl"
    PAPERCUT_LOCK="$dir/.spool.lock"
    PAPERCUT_BATCH_DIR="$dir"
    PAPERCUT_QUARANTINE_DIR="$dir/quarantine"
    PAPERCUT_FLUSH_OK="$dir/flush-ok"
    PAPERCUT_FLUSH_FAIL="$dir/flush-fail"
    PAPERCUT_LOG="$dir/flush.log"
    PAPERCUT_DETECT_CMD='echo default'
    PAPERCUT_CONFIG="$dir/no-such-config.toml"
  )
  if [ "$kind" = "garbage" ]; then
    garbage | env "${env_args[@]}" bash "$script_dir/papercut-flush.sh" --hook >/dev/null 2>&1
  else
    env "${env_args[@]}" bash "$script_dir/papercut-flush.sh" --hook </dev/null >/dev/null 2>&1
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "papercut-flush.sh --hook ($kind stdin) exits 0"
  else
    fail_test "papercut-flush.sh --hook ($kind stdin) exits 0 (rc=$rc)"
  fi
}
run_flush_hook empty
run_flush_hook garbage

# --- 2. --hook vs direct on a MISSING config -------------------------------
# The fail-closed gate is reached only with the default git publisher, on the
# default profile (the strict-profile hold exits 0 earlier), and only once the
# spool has content (the "nothing to do" fast-exit comes first). Build exactly
# that fixture, then run the same script twice — once bare, once with --hook.
rec() {
  printf '{"id":"%s","v":1,"producer":"test/1","ts":"2026-08-01T00:00:00Z","machine":"default","source":"manual","category":"harness_config","severity":"low","title":"t","description":"d","repo":"papercuts-plugin"}\n' "$1"
}

# 2a. Direct invocation: must exit non-zero and claim nothing.
direct_dir="$(new_dir)"
rec pc_direct1 >"$direct_dir/spool.jsonl"
env \
  PAPERCUT_SPOOL="$direct_dir/spool.jsonl" \
  PAPERCUT_LOCK="$direct_dir/.spool.lock" \
  PAPERCUT_BATCH_DIR="$direct_dir" \
  PAPERCUT_QUARANTINE_DIR="$direct_dir/quarantine" \
  PAPERCUT_FLUSH_OK="$direct_dir/flush-ok" \
  PAPERCUT_FLUSH_FAIL="$direct_dir/flush-fail" \
  PAPERCUT_LOG="$direct_dir/flush.log" \
  PAPERCUT_DETECT_CMD='echo default' \
  PAPERCUT_CONFIG="$direct_dir/absent-config.toml" \
  bash "$script_dir/papercut-flush.sh" >/dev/null 2>&1
direct_rc=$?
if [ "$direct_rc" -ne 0 ]; then
  pass "direct papercut-flush.sh with a missing config exits non-zero (rc=$direct_rc)"
else
  fail_test "direct papercut-flush.sh with a missing config exits non-zero (got rc=0)"
fi
if grep -qF "hold reason=ledger-identity-unresolved" "$direct_dir/flush.log" 2>/dev/null; then
  pass "direct invocation reached the ledger-identity gate (not an earlier exit)"
else
  fail_test "direct invocation reached the ledger-identity gate (log: $(cat "$direct_dir/flush.log" 2>/dev/null))"
fi
if [ -s "$direct_dir/spool.jsonl" ]; then
  pass "direct invocation refused before claiming the spool"
else
  fail_test "direct invocation refused before claiming the spool"
fi

# 2b. Same fixture through --hook: must exit 0 and log the swallowed rc.
hook_dir="$(new_dir)"
rec pc_hook1 >"$hook_dir/spool.jsonl"
env \
  PAPERCUT_SPOOL="$hook_dir/spool.jsonl" \
  PAPERCUT_LOCK="$hook_dir/.spool.lock" \
  PAPERCUT_BATCH_DIR="$hook_dir" \
  PAPERCUT_QUARANTINE_DIR="$hook_dir/quarantine" \
  PAPERCUT_FLUSH_OK="$hook_dir/flush-ok" \
  PAPERCUT_FLUSH_FAIL="$hook_dir/flush-fail" \
  PAPERCUT_LOG="$hook_dir/flush.log" \
  PAPERCUT_DETECT_CMD='echo default' \
  PAPERCUT_CONFIG="$hook_dir/absent-config.toml" \
  bash "$script_dir/papercut-flush.sh" --hook >/dev/null 2>&1
hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "papercut-flush.sh --hook with the same missing config exits 0"
else
  fail_test "papercut-flush.sh --hook with the same missing config exits 0 (rc=$hook_rc)"
fi
if grep -qF "hook mode: run exited rc=" "$hook_dir/flush.log" 2>/dev/null; then
  pass "--hook logged the non-zero rc it swallowed"
else
  fail_test "--hook logged the non-zero rc it swallowed (log: $(cat "$hook_dir/flush.log" 2>/dev/null))"
fi

# 2c. --hook must not swallow the exit code of a run that SUCCEEDS silently,
# and must still pass other flags through to the real run. A stub publisher
# needs no config, so the gate is skipped and the batch publishes.
combo_dir="$(new_dir)"
rec pc_combo1 >"$combo_dir/spool.jsonl"
env \
  PAPERCUT_SPOOL="$combo_dir/spool.jsonl" \
  PAPERCUT_LOCK="$combo_dir/.spool.lock" \
  PAPERCUT_BATCH_DIR="$combo_dir" \
  PAPERCUT_QUARANTINE_DIR="$combo_dir/quarantine" \
  PAPERCUT_FLUSH_OK="$combo_dir/flush-ok" \
  PAPERCUT_FLUSH_FAIL="$combo_dir/flush-fail" \
  PAPERCUT_LOG="$combo_dir/flush.log" \
  PAPERCUT_DETECT_CMD='echo strict' \
  PAPERCUT_PUBLISH_CMD="true" \
  bash "$script_dir/papercut-flush.sh" --hook --force >/dev/null 2>&1
combo_rc=$?
if [ "$combo_rc" -eq 0 ] && [ ! -s "$combo_dir/spool.jsonl" ]; then
  pass "--hook passes --force through (strict profile still published)"
else
  fail_test "--hook passes --force through (rc=$combo_rc, spool_left=$([ -s "$combo_dir/spool.jsonl" ] && echo yes || echo no))"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll hook fail-silent tests passed.\n'
else
  printf '\nSome hook fail-silent tests FAILED.\n'
fi
exit "$fail"
