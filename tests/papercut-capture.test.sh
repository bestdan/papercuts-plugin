#!/usr/bin/env bash
# Tests for papercut-capture.sh — the SessionEnd hook that pre-filters
# transcripts and pipes non-trivial ones through the extractor seam and the
# papercut_append.py gate. Run:
#   bash tests/papercut-capture.test.sh
#
# All state (log, processed-hash dir, lock dir, spool, lock) lives under a
# per-run temp dir so this suite never touches real ~/.claude. The gate derives
# its profile from the real hostname and the strict marker (the gate-core
# change dropped the PAPERCUT_HOSTNAME/PAPERCUT_TEST_MODE override), so this
# suite forces the default profile by routing every gate call through a wrapper
# that monkeypatches socket.gethostname (see $append_default_host below) —
# otherwise on a machine matching a configured strict_hosts pattern the gate
# would require a hand-populated denylist this suite has no business depending
# on. The prelude's throwaway HOME keeps the marker out of reach.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
hook="$script_dir/papercut-capture.sh"
fixtures="$(cd "$(dirname "$0")" && pwd)/fixtures"

fail=0
counter=0

# Fresh, isolated state dir for one test case. Sets the global $env_dir.
# NOT run via command substitution — `dir=$(new_env)` would increment
# $counter inside a subshell, silently discarding the increment and handing
# every test case the same directory.
new_env() {
  counter=$((counter + 1))
  env_dir="$workdir/case-$counter"
  mkdir -p "$env_dir"
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# The gate derives its profile from the REAL hostname (the gate-core change
# removed the PAPERCUT_HOSTNAME/PAPERCUT_TEST_MODE env override), so on a host
# matching a configured strict_hosts pattern it would resolve to the strict
# profile and reject records for lack of a denylist. Because the hook invokes the gate as a SUBPROCESS, tests can't
# use papercut_append.test.sh's in-process monkeypatch directly — so route the
# gate through this wrapper, which forces socket.gethostname to a non-work host
# before runpy-executing the gate. Every gate call in this suite goes through
# it (via PAPERCUT_APPEND_CMD), making the default profile deterministic on any
# machine rather than relying on the caller's real hostname.
append_default_host="$workdir/append_default_host.sh"
cat >"$append_default_host" <<EOF
#!/usr/bin/env bash
exec python3 -c '
import runpy, socket, sys
socket.gethostname = lambda: "some-laptop"
sys.argv = ["papercut_append.py"] + sys.argv[1:]
runpy.run_path("$script_dir/papercut_append.py", run_name="__main__")
' "\$@"
EOF
chmod +x "$append_default_host"

# run_hook <case_dir> <transcript_fixture> [extra env assignments...]
# Emits a synthetic SessionEnd stdin payload pointing at a copy of the given
# fixture (so the hook's own temp-copy step never mutates our fixture), runs
# the hook with fully isolated state, and leaves stdout/log for inspection.
run_hook() {
  local dir="$1" fixture="$2"
  shift 2

  local transcript="$dir/transcript.jsonl"
  cp "$fixtures/$fixture" "$transcript"

  local session_id="sess-$counter"
  local payload
  payload=$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' \
    "$transcript" "$session_id" "$dir")

  env \
    PAPERCUT_PROCESSED_DIR="$dir/processed" \
    PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
    PAPERCUT_LOG="$dir/capture.log" \
    PAPERCUT_EXTRACTOR_CMD="${PAPERCUT_EXTRACTOR_CMD:-echo []}" \
    PAPERCUT_APPEND_CMD="$append_default_host" \
    PAPERCUT_SPOOL="$dir/spool.jsonl" \
    PAPERCUT_LOCK="$dir/.spool.lock" \
    "$@" \
    bash "$hook" <<<"$payload"
}

assert_log_contains() {
  local desc="$1" dir="$2" needle="$3"
  if [ -f "$dir/capture.log" ] && grep -qF "$needle" "$dir/capture.log"; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s: expected log line containing %q, got: %s)\n' \
      "$desc" "$needle" "$(cat "$dir/capture.log" 2>/dev/null)"
    fail=1
  fi
}

assert_log_absent() {
  local desc="$1" dir="$2" needle="$3"
  if [ -f "$dir/capture.log" ] && grep -qF "$needle" "$dir/capture.log"; then
    printf 'FAIL (%s: log unexpectedly contains %q)\n' "$desc" "$needle"
    fail=1
  else
    printf 'ok   (%s)\n' "$desc"
  fi
}

# --- Pre-filter: accepts a non-trivial transcript (>= 6 human turns) -------
new_env; dir="$env_dir"
run_hook "$dir" nontrivial_turns.jsonl
assert_log_contains "accepts >=6 human turns" "$dir" "accept reason=non-trivial"

# --- Pre-filter: skips a trivial transcript ---------------------------------
new_env; dir="$env_dir"
run_hook "$dir" trivial.jsonl
assert_log_contains "skips trivial transcript" "$dir" "skip reason=trivial"

# --- permissionMode false-positive case -------------------------------------
# Trivial transcript whose entries carry a `permissionMode` field (and even
# the word "permission" in prompt text) must still be SKIPPED — proves the
# filter counts structure (message.content type), not a grep for
# "permission".
new_env; dir="$env_dir"
run_hook "$dir" permission_mode_trivial.jsonl
assert_log_contains "permissionMode false-positive still skipped" "$dir" "skip reason=trivial"

# --- Pre-filter: a single tool error makes a <6-turn transcript non-trivial -
new_env; dir="$env_dir"
run_hook "$dir" tool_error.jsonl
assert_log_contains "tool error forces non-trivial" "$dir" "accept reason=non-trivial"

# --- Pre-filter: a single denial makes a <6-turn transcript non-trivial ----
new_env; dir="$env_dir"
run_hook "$dir" denial.jsonl
assert_log_contains "denial forces non-trivial" "$dir" "accept reason=non-trivial"

# --- Recursion guard: exits immediately, nothing else happens --------------
new_env; dir="$env_dir"
transcript="$dir/transcript.jsonl"
cp "$fixtures/nontrivial_turns.jsonl" "$transcript"
payload=$(printf '{"transcript_path":"%s","session_id":"sess-guard","cwd":"%s"}' "$transcript" "$dir")
out=$(PAPERCUT_EXTRACTOR_RUN=1 \
  PAPERCUT_PROCESSED_DIR="$dir/processed" \
  PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
  PAPERCUT_LOG="$dir/capture.log" \
  bash "$hook" <<<"$payload")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$dir/capture.log" ]; then
  printf 'ok   (recursion guard: exits 0, no log, no state)\n'
else
  printf 'FAIL (recursion guard: rc=%s out=%q log_exists=%s)\n' "$rc" "$out" "$([ -e "$dir/capture.log" ] && echo yes || echo no)"
  fail=1
fi

# --- Idempotency: same transcript fed twice -> second run skipped ----------
new_env; dir="$env_dir"
run_hook "$dir" nontrivial_turns.jsonl
# Re-run against the identical bytes and session id the first run used.
transcript="$dir/transcript.jsonl"
session_id="sess-$counter"
payload=$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$transcript" "$session_id" "$dir")
env \
  PAPERCUT_PROCESSED_DIR="$dir/processed" \
  PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
  PAPERCUT_LOG="$dir/capture.log" \
  PAPERCUT_EXTRACTOR_CMD="echo []" \
  PAPERCUT_APPEND_CMD="$append_default_host" \
  PAPERCUT_SPOOL="$dir/spool.jsonl" \
  PAPERCUT_LOCK="$dir/.spool.lock" \
  bash "$hook" <<<"$payload"
assert_log_contains "idempotency skips unchanged re-fire" "$dir" "skip reason=unchanged-transcript"

# --- Both slots busy -> skip -------------------------------------------------
for attempt in 1 2 3; do
  new_env;   dir="$env_dir"
  lockdir="$dir/locks"
  mkdir -p "$lockdir"

  # Hold both slot locks from a separate process for the duration of the
  # hook invocation, exactly like a real concurrent capture would.
  python3 -c "
import fcntl, os, sys, time
fd1 = os.open('$lockdir/capture-slot-1.lock', os.O_CREAT | os.O_RDWR, 0o600)
fd2 = os.open('$lockdir/capture-slot-2.lock', os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd1, fcntl.LOCK_EX)
fcntl.flock(fd2, fcntl.LOCK_EX)
sys.stdout.write('locked\n')
sys.stdout.flush()
time.sleep(10)
" >"$dir/holder.out" 2>/dev/null &
  holder_pid=$!

  # Wait deterministically for the holder to actually acquire both locks,
  # rather than a fixed sleep, so this isn't flaky under load.
  waited=0
  while [ ! -s "$dir/holder.out" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  run_hook "$dir" nontrivial_turns.jsonl

  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null

  if grep -qF "skip reason=capture-slots-busy" "$dir/capture.log" 2>/dev/null; then
    printf 'ok   (both slots busy -> skip) [attempt %d]\n' "$attempt"
    break
  elif [ "$attempt" -eq 3 ]; then
    printf 'FAIL (both slots busy -> skip, log: %s)\n' "$(cat "$dir/capture.log" 2>/dev/null)"
    fail=1
  fi
done

# --- Temp transcript copy is removed on exit --------------------------------
new_env; dir="$env_dir"
tmp_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'papercut-capture.*' 2>/dev/null | wc -l | tr -d ' ')
run_hook "$dir" nontrivial_turns.jsonl
tmp_after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'papercut-capture.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$tmp_before" = "$tmp_after" ]; then
  printf 'ok   (temp transcript copy cleaned up)\n'
else
  printf 'FAIL (temp transcript copy leaked: before=%s after=%s)\n' "$tmp_before" "$tmp_after"
  fail=1
fi

# --- Malformed extractor output: metadata logged, nothing appended ---------
new_env; dir="$env_dir"
PAPERCUT_EXTRACTOR_CMD="echo not-json-at-all" run_hook "$dir" nontrivial_turns.jsonl
assert_log_contains "malformed extractor output logged" "$dir" "skip reason=gate-rejected"
if [ -f "$dir/spool.jsonl" ] && [ -s "$dir/spool.jsonl" ]; then
  printf 'FAIL (malformed extractor output: spool should be empty, got: %s)\n' "$(cat "$dir/spool.jsonl")"
  fail=1
else
  printf 'ok   (malformed extractor output appends nothing)\n'
fi

# --- Happy path: a valid NON-EMPTY extractor result is forwarded to the gate
# and persisted with the correct metadata (the hook's whole purpose). Every
# other test drives the extractor with an empty array, malformed output, or a
# failing exit, so without this the extractor->gate forwarding contract and the
# --source/--producer/--session-id/--repo annotation are never exercised. The
# shared default-host gate wrapper (see setup) keeps this deterministic on any
# machine. -------------------------------------------------------------------
new_env; dir="$env_dir"
happy_record='[{"category":"harness_config","severity":"low","title":"real papercut","description":"a genuine friction point forwarded end to end"}]'
PAPERCUT_EXTRACTOR_CMD="printf '%s' '$happy_record'" run_hook "$dir" nontrivial_turns.jsonl
assert_log_contains "happy path: record appended" "$dir" "accept reason=appended"
happy_lines=$(wc -l <"$dir/spool.jsonl" 2>/dev/null | tr -d ' ')
if [ "${happy_lines:-0}" = "1" ]; then
  printf 'ok   (happy path: exactly one spool entry)\n'
else
  printf 'FAIL (happy path: expected 1 spool entry, got %s)\n' "${happy_lines:-0}"
  fail=1
fi
if [ -s "$dir/spool.jsonl" ] && python3 -c '
import json, sys
rec = json.loads(open(sys.argv[1]).readline())
assert rec["source"] == "auto", rec.get("source")
assert rec["producer"] == "capture-hook/1", rec.get("producer")
assert rec["repo"] == sys.argv[2], rec.get("repo")
assert rec["session_id"] == sys.argv[3], rec.get("session_id")
assert rec["title"] == "real papercut", rec.get("title")
' "$dir/spool.jsonl" "case-$counter" "sess-$counter" 2>/dev/null; then
  printf 'ok   (happy path: spool entry carries source=auto, producer=capture-hook/1, repo, session_id)\n'
else
  printf 'FAIL (happy path: spool entry metadata wrong: %s)\n' "$(cat "$dir/spool.jsonl" 2>/dev/null)"
  fail=1
fi

# --- Scrub-review sidecar wiring: a vocab-shaped redaction in the extracted
# record reaches PAPERCUT_REVIEW_FILE (exported by the hook, defaulted here to
# a per-case path), and the hook logs ONLY a count -- never the plaintext run
# itself -- per the "metadata only, never transcript/model content" invariant
# this log already documents. ------------------------------------------------
new_env; dir="$env_dir"
review_record='[{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}]'
review_file="$dir/scrub-review.jsonl"
PAPERCUT_EXTRACTOR_CMD="printf '%s' '$review_record'" run_hook "$dir" nontrivial_turns.jsonl \
  PAPERCUT_REVIEW_FILE="$review_file"
assert_log_contains "scrub-review wiring: count logged" "$dir" "scrub-review runs=1"
assert_log_absent "scrub-review wiring: plaintext run never logged" "$dir" "backward-compatibility-shim"
if [ -s "$review_file" ] && grep -qF "backward-compatibility-shim" "$review_file" 2>/dev/null; then
  printf 'ok   (scrub-review wiring: verbatim run landed in the sidecar file)\n'
else
  printf 'FAIL (scrub-review wiring: sidecar missing the verbatim run: %s)\n' "$(cat "$review_file" 2>/dev/null)"
  fail=1
fi

# --- A non-zero extractor exit is TRANSIENT: it must NOT be marked processed,
# so the next SessionEnd on the same bytes retries (otherwise a one-off crash
# permanently suppresses the papercut). Assert no .hash marker was written. ----
new_env; dir="$env_dir"
PAPERCUT_EXTRACTOR_CMD="bash -c 'exit 3'" run_hook "$dir" nontrivial_turns.jsonl
assert_log_contains "transient extractor failure logged" "$dir" "skip reason=extractor-failed"
if [ -z "$(find "$dir/processed" -name '*.hash' 2>/dev/null | head -1)" ]; then
  printf 'ok   (transient extractor failure leaves no marker → retryable)\n'
else
  printf 'FAIL (transient extractor failure wrote a marker → would never retry)\n'
  fail=1
fi

# --- Log contains NONE of the fixture's text --------------------------------
new_env; dir="$env_dir"
run_hook "$dir" nontrivial_turns.jsonl
assert_log_absent "log never contains fixture sentinel text" "$dir" "SENTINEL_FIXTURE_TEXT_ALPHA"

# --- Fix 1: session_id log injection via embedded newline -------------------
# A session_id carrying a newline must not forge a second log line. The hook
# must sanitize it into session_safe before it ever reaches log().
new_env; dir="$env_dir"
transcript="$dir/transcript.jsonl"
cp "$fixtures/trivial.jsonl" "$transcript"
injected_session_id=$'sess-inject\nFAKE_INJECTED_LOG_LINE'
payload=$(jq -n --arg tp "$transcript" --arg sid "$injected_session_id" --arg cwd "$dir" \
  '{transcript_path:$tp, session_id:$sid, cwd:$cwd}')
env \
  PAPERCUT_PROCESSED_DIR="$dir/processed" \
  PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
  PAPERCUT_LOG="$dir/capture.log" \
  PAPERCUT_EXTRACTOR_CMD="echo []" \
  PAPERCUT_APPEND_CMD="$append_default_host" \
  PAPERCUT_SPOOL="$dir/spool.jsonl" \
  PAPERCUT_LOCK="$dir/.spool.lock" \
  bash "$hook" <<<"$payload"
log_lines=$(wc -l <"$dir/capture.log" 2>/dev/null | tr -d ' ')
if [ "$log_lines" = "1" ]; then
  printf 'ok   (session_id newline does not forge a second log line)\n'
else
  printf 'FAIL (session_id newline: expected 1 log line, got %s: %s)\n' \
    "$log_lines" "$(cat "$dir/capture.log" 2>/dev/null)"
  fail=1
fi

# --- Fix 2: extractor invocation carries the recursion guard ----------------
# The extractor must see PAPERCUT_EXTRACTOR_RUN=1 so that, once the real
# extractor shells out to `claude -p ...`, its nested SessionEnd fire is a
# guaranteed no-op instead of forking back into this hook.
new_env; dir="$env_dir"
guard_seen_file="$dir/guard_seen.txt"
PAPERCUT_EXTRACTOR_CMD="cat >/dev/null; printf '%s' \"\${PAPERCUT_EXTRACTOR_RUN:-unset}\" > $guard_seen_file; echo []" \
  run_hook "$dir" nontrivial_turns.jsonl
if [ -f "$guard_seen_file" ] && [ "$(cat "$guard_seen_file")" = "1" ]; then
  printf 'ok   (extractor invocation sets PAPERCUT_EXTRACTOR_RUN=1)\n'
else
  printf 'FAIL (extractor recursion guard: guard_seen=%s)\n' "$(cat "$guard_seen_file" 2>/dev/null)"
  fail=1
fi

# --- Fix 3: transcript is copied BEFORE it is read again (TOCTOU) -----------
# A `cp` wrapper deletes ONLY the hook's own transcript source (never a
# fixture) the instant that copy completes — simulating the live transcript
# disappearing/mutating right after the temp copy is made. If any later step
# (hash, triviality filter, extractor) fell back to reading $transcript_path
# instead of the temp copy, it would fail outright since the source is now
# gone. A clean "accept reason=appended" proves every read after the copy
# went through the temp file. The test's own fixture->transcript.jsonl copy
# (done via the real /bin/cp, before PATH is touched) is left untouched.
new_env; dir="$env_dir"
transcript="$dir/transcript.jsonl"
/bin/cp "$fixtures/nontrivial_turns.jsonl" "$transcript"
mkdir -p "$dir/bin"
cat >"$dir/bin/cp" <<CPWRAP
#!/usr/bin/env bash
/bin/cp "\$@"
rc=\$?
if [ "\$1" = "$transcript" ]; then
  rm -f "\$1"
fi
exit \$rc
CPWRAP
chmod +x "$dir/bin/cp"
session_id="sess-$counter"
payload=$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$transcript" "$session_id" "$dir")
env \
  PATH="$dir/bin:$PATH" \
  PAPERCUT_PROCESSED_DIR="$dir/processed" \
  PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
  PAPERCUT_LOG="$dir/capture.log" \
  PAPERCUT_EXTRACTOR_CMD="echo []" \
  PAPERCUT_APPEND_CMD="$append_default_host" \
  PAPERCUT_SPOOL="$dir/spool.jsonl" \
  PAPERCUT_LOCK="$dir/.spool.lock" \
  bash "$hook" <<<"$payload"
assert_log_contains "reads happen from the temp copy, not the (now-gone) original" "$dir" "accept reason=appended"

# --- Fix 4: session_id used as a pathname cannot traverse out of processed_dir
new_env; dir="$env_dir"
transcript="$dir/transcript.jsonl"
cp "$fixtures/trivial.jsonl" "$transcript"
payload=$(jq -n --arg tp "$transcript" --arg sid "../evil" --arg cwd "$dir" \
  '{transcript_path:$tp, session_id:$sid, cwd:$cwd}')
env \
  PAPERCUT_PROCESSED_DIR="$dir/processed" \
  PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
  PAPERCUT_LOG="$dir/capture.log" \
  PAPERCUT_EXTRACTOR_CMD="echo []" \
  PAPERCUT_APPEND_CMD="$append_default_host" \
  PAPERCUT_SPOOL="$dir/spool.jsonl" \
  PAPERCUT_LOCK="$dir/.spool.lock" \
  bash "$hook" <<<"$payload"
# The marker/lock filenames are a SHA-256 of the raw session id (hex, no
# slashes), so a "../evil" id cannot escape processed_dir by construction. The
# trivial transcript writes a marker; assert a .hash landed inside processed_dir
# and that nothing named evil.hash appeared in a parent dir.
if [ -n "$(find "$dir/processed" -name '*.hash' 2>/dev/null | head -1)" ] \
  && [ ! -e "$workdir/evil.hash" ] \
  && [ ! -e "$(dirname "$dir")/evil.hash" ]; then
  printf 'ok   (traversal-shaped session_id stays inside processed_dir)\n'
else
  printf 'FAIL (traversal-shaped session_id: %s)\n' "$(find "$dir/processed" -type f 2>/dev/null | tr '\n' ' ')"
  fail=1
fi

# --- Fix 5: per-session lock prevents a concurrent double-emit -------------
new_env; dir="$env_dir"
mkdir -p "$dir/processed"
# The hook keys its per-session lock on SHA-256(session_id); run_hook uses
# "sess-$counter", so lock the matching SHA-named file.
session_lock_key=$(printf '%s' "sess-$counter" | shasum -a 256 | awk '{print $1}')
session_lock="$dir/processed/$session_lock_key.lock"
python3 -c "
import fcntl, os, sys, time
fd = os.open('$session_lock', os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write('locked\n')
sys.stdout.flush()
time.sleep(10)
" >"$dir/session_holder.out" 2>/dev/null &
session_holder_pid=$!
waited=0
while [ ! -s "$dir/session_holder.out" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
run_hook "$dir" nontrivial_turns.jsonl
kill "$session_holder_pid" 2>/dev/null
wait "$session_holder_pid" 2>/dev/null
assert_log_contains "per-session lock busy -> skip" "$dir" "skip reason=session-lock-busy"
if [ -f "$dir/spool.jsonl" ] && [ -s "$dir/spool.jsonl" ]; then
  printf 'FAIL (per-session lock busy: spool should be empty, got: %s)\n' "$(cat "$dir/spool.jsonl")"
  fail=1
else
  printf 'ok   (per-session lock busy appends nothing)\n'
fi

# --- Fix 6a: human prompts as a text-block array count as non-trivial ------
new_env; dir="$env_dir"
run_hook "$dir" text_block_array_nontrivial.jsonl
assert_log_contains "text-block-array prompts count as human turns" "$dir" "accept reason=non-trivial"

# --- Fix 6b: isMeta:true string entries are NOT counted as human turns -----
new_env; dir="$env_dir"
run_hook "$dir" ismeta_string_trivial.jsonl
assert_log_contains "isMeta:true string entries are skipped as trivial" "$dir" "skip reason=trivial"

# --- Real extractor (extractor-run.sh): guard env + stdin reach the model --
# Routes PAPERCUT_EXTRACTOR_CMD through the real extractor-run.sh (instead of
# a plain "echo []" stub) but swaps PAPERCUT_CLAUDE_BIN for a fake `claude`
# so no real model call is ever made. Confirms extractor-run.sh itself sets
# up the PAPERCUT_EXTRACTOR_RUN guard and pipes the COMPACTED transcript (not
# raw, not argv, not a mutated copy) to the model's stdin -- extractor-run.sh
# now compacts unconditionally, so what reaches the model is the fixture as
# transformed by papercut_compact.py, not the fixture's raw bytes.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
guard_file="$dir/fake_claude_guard.txt"
stdin_file="$dir/fake_claude_stdin.txt"
cat >"$dir/bin/fake-claude" <<FAKECLAUDE
#!/usr/bin/env bash
printf '%s' "\${PAPERCUT_EXTRACTOR_RUN:-unset}" > "$guard_file"
cat > "$stdin_file"
echo '{"structured_output":{"records":[]}}'
FAKECLAUDE
chmod +x "$dir/bin/fake-claude"
PAPERCUT_EXTRACTOR_CMD="$script_dir/extractor-run.sh" run_hook "$dir" nontrivial_turns.jsonl \
  PAPERCUT_CLAUDE_BIN="$dir/bin/fake-claude"
if [ "$(cat "$guard_file" 2>/dev/null)" = "1" ]; then
  printf 'ok   (extractor-run.sh forwards PAPERCUT_EXTRACTOR_RUN=1 to the model call)\n'
else
  printf 'FAIL (extractor-run.sh guard: got %q)\n' "$(cat "$guard_file" 2>/dev/null)"
  fail=1
fi
expected_compacted="$dir/expected_compacted.jsonl"
python3 "$script_dir/papercut_compact.py" <"$dir/transcript.jsonl" >"$expected_compacted"
if diff -q "$expected_compacted" "$stdin_file" >/dev/null 2>&1; then
  printf 'ok   (extractor-run.sh pipes the compacted transcript to the model on stdin)\n'
else
  printf 'FAIL (extractor-run.sh stdin: compacted transcript and what the model saw differ)\n'
  fail=1
fi
assert_log_contains "extractor-run.sh empty-records model output appends nothing" "$dir" "accept reason=appended"
if [ -f "$dir/spool.jsonl" ] && [ -s "$dir/spool.jsonl" ]; then
  printf 'FAIL (extractor-run.sh empty records: spool should be empty, got: %s)\n' "$(cat "$dir/spool.jsonl")"
  fail=1
else
  printf 'ok   (extractor-run.sh empty records: spool stays empty)\n'
fi

# --- Real extractor: python watchdog kills a hung call AND its descendants --
# (FIX 2/3) A fake `claude` that ignores SIGTERM, forks a grandchild sleep,
# then sleeps well past the bound must be killed by the python3 watchdog,
# which SIGKILLs claude's WHOLE process group -- so both the fake claude and
# its grandchild die, no stray process is left, extractor-run.sh exits
# non-zero, and the hook logs it as a transient extractor failure (no
# processed marker, so a later SessionEnd retries). A short
# PAPERCUT_EXTRACTOR_TIMEOUT keeps the test fast.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
grandchild_pid_file="$dir/grandchild.pid"
cat >"$dir/bin/fake-claude-hung" <<FAKEHUNG
#!/usr/bin/env bash
trap '' TERM
cat >/dev/null
sleep 30 &
echo \$! > "$grandchild_pid_file"
sleep 30
FAKEHUNG
chmod +x "$dir/bin/fake-claude-hung"
start_ts=$(date +%s)
PAPERCUT_EXTRACTOR_CMD="$script_dir/extractor-run.sh" run_hook "$dir" nontrivial_turns.jsonl \
  PAPERCUT_CLAUDE_BIN="$dir/bin/fake-claude-hung" \
  PAPERCUT_EXTRACTOR_TIMEOUT=1
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
assert_log_contains "watchdog-killed hung model call logged as extractor-failed" "$dir" "skip reason=extractor-failed"
assert_log_contains "hung-call failure records the timeout error class" "$dir" "err=extractor: timeout"
if [ -z "$(find "$dir/processed" -name '*.hash' 2>/dev/null | head -1)" ]; then
  printf 'ok   (watchdog kill leaves no processed marker -> retryable)\n'
else
  printf 'FAIL (watchdog kill wrote a processed marker -> would never retry)\n'
  fail=1
fi
if [ "$elapsed" -lt 15 ]; then
  printf 'ok   (watchdog bounds the hung call instead of waiting out the full sleep) [%ss]\n' "$elapsed"
else
  printf 'FAIL (watchdog did not bound the hung call: took %ss)\n' "$elapsed"
  fail=1
fi
# Probes whether this environment can do the thing the assertion below is
# actually testing for: SIGKILL to a process GROUP taking a grandchild with
# it. Some sandboxes (the nightly review's Linux container among them) leave
# the grandchild alive no matter what the code under test does, which reads as
# a product bug that isn't there.
#
# Only consulted when the assertion is about to fail, so a working environment
# can never be silently skipped — and a real regression is still a FAIL
# everywhere the primitive works.
pgroup_kill_reaps_descendants() {
  local pidfile probe_pid gpid
  pidfile="$(mktemp "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
  set -m # own process group for the subshell, so kill -PGID is meaningful
  ( sleep 30 & echo $! >"$pidfile"; sleep 30 ) &
  probe_pid=$!
  set +m
  for _ in $(seq 1 40); do
    [ -s "$pidfile" ] && break
    sleep 0.05
  done
  kill -9 -"$probe_pid" 2>/dev/null
  sleep 0.3
  gpid="$(cat "$pidfile" 2>/dev/null)"
  rm -f "$pidfile"
  if [ -n "$gpid" ] && kill -0 "$gpid" 2>/dev/null; then
    kill -9 "$gpid" 2>/dev/null
    return 1
  fi
  return 0
}

# Give the SIGKILL a beat to be reaped, then prove the grandchild is gone:
# a parent-only kill would leave it orphaned and sleeping.
sleep 1
grandchild_pid=$(cat "$grandchild_pid_file" 2>/dev/null)
if [ -n "$grandchild_pid" ] && kill -0 "$grandchild_pid" 2>/dev/null; then
  if pgroup_kill_reaps_descendants; then
    printf 'FAIL (watchdog left a stray grandchild process %s alive)\n' "$grandchild_pid"
    fail=1
  else
    printf 'SKIP (watchdog descendant reaping: this environment does not reap process groups at all, so the assertion cannot distinguish a real regression)\n'
  fi
  kill -9 "$grandchild_pid" 2>/dev/null
else
  printf 'ok   (watchdog process-group kill reaps claude descendants too)\n'
fi

# --- Direct extractor-run.sh drivers (FIX 1, 4, 5). --------------------------
# These call extractor-run.sh directly (not through the hook) so they can
# inspect its stdout, stderr class, exit code, and the composed system-prompt
# file. PAPERCUT_CLAUDE_BIN points at a fake `claude`; PAPERCUT_DETECT_CMD
# overrides profile detection so no real profile logic or real model runs.
extractor="$script_dir/extractor-run.sh"

# run_extractor <case_dir> <fake_claude_path> <transcript_bytes> [extra env...]
# Runs the extractor on a one-line transcript, capturing stdout/stderr/rc into
# $ext_out / $ext_err / $ext_rc globals.
run_extractor() {
  local d="$1" claude_bin="$2" transcript="$3"
  shift 3
  printf '%s\n' "$transcript" >"$d/tr.jsonl"
  ext_out=$(env \
    PAPERCUT_CLAUDE_BIN="$claude_bin" \
    "$@" \
    bash "$extractor" <"$d/tr.jsonl" 2>"$d/ext.err")
  ext_rc=$?
  ext_err=$(cat "$d/ext.err" 2>/dev/null)
}

# A fake claude that copies its --system-prompt-file argument out to
# $1 so a test can inspect the composed system prompt, then emits valid empty
# structured output.
write_sysprompt_capture_stub() {
  local path="$1" out="$2"
  cat >"$path" <<STUB
#!/usr/bin/env bash
cat >/dev/null
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--system-prompt-file" ]; then cp "\$a" "$out"; fi
  prev="\$a"
done
echo '{"structured_output":{"records":[]}}'
STUB
  chmod +x "$path"
}

# --- FIX 1: profile detection FAILS CLOSED -> work rules still prepended ----
# If detection errors (broken command, crashed python), extractor-run.sh must
# NOT drop the strict-profile hard-rules preamble -- omitting it on a strict host
# would let the model emit internal identifiers. Only a positive "default"
# result strips the rules.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
sp_out="$dir/sysprompt.md"
write_sysprompt_capture_stub "$dir/bin/capture" "$sp_out"

run_extractor "$dir" "$dir/bin/capture" '{"t":1}' PAPERCUT_DETECT_CMD="exit 1"
if grep -qF "Work-profile hard rules" "$sp_out" 2>/dev/null; then
  printf 'ok   (detection failure fails closed: work rules prepended)\n'
else
  printf 'FAIL (detection failure dropped the work rules: %s)\n' "$(cat "$sp_out" 2>/dev/null | head -1)"
  fail=1
fi

run_extractor "$dir" "$dir/bin/capture" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
if grep -qF "Work-profile hard rules" "$sp_out" 2>/dev/null; then
  printf 'FAIL (default profile still got the work rules)\n'
  fail=1
else
  printf 'ok   (default profile: work rules omitted)\n'
fi

run_extractor "$dir" "$dir/bin/capture" '{"t":1}' PAPERCUT_DETECT_CMD="echo strict"
if grep -qF "Work-profile hard rules" "$sp_out" 2>/dev/null; then
  printf 'ok   (strict profile: work rules prepended)\n'
else
  printf 'FAIL (strict profile dropped the work rules)\n'
  fail=1
fi

# --- FIX (co-review): detection failing closed isn't enough — the work-rules
# preamble must actually LAND in the composed prompt. If the
# WORK_PROFILE_HARD_RULES markers are absent (a plausible future prompt edit)
# the awk emits a main-only prompt even on a work host, so the extractor must
# FAIL CLOSED (non-zero, bounded class) BEFORE the model call rather than run
# the model with the privacy rules silently missing.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
sp_out="$dir/sysprompt.md"
write_sysprompt_capture_stub "$dir/bin/capture" "$sp_out"
markerless_prompt="$dir/markerless-prompt.md"
printf '# Extractor prompt\n\nExtract papercuts. No markers in this file.\n' >"$markerless_prompt"
run_extractor "$dir" "$dir/bin/capture" '{"t":1}' \
  PAPERCUT_DETECT_CMD="echo strict" \
  PAPERCUT_EXTRACTOR_PROMPT="$markerless_prompt"
if [ "$ext_rc" -ne 0 ] && printf '%s' "$ext_err" | grep -qF "work-profile rules missing"; then
  printf 'ok   (markerless prompt on work host: fails closed with a bounded error class)\n'
else
  printf 'FAIL (markerless prompt: expected non-zero + "work-profile rules missing", rc=%s err=%q)\n' "$ext_rc" "$ext_err"
  fail=1
fi
if [ -f "$sp_out" ]; then
  printf 'FAIL (markerless prompt: model was invoked despite the missing work rules)\n'
  fail=1
else
  printf 'ok   (markerless prompt: model never invoked — failed before the claude call)\n'
fi

# --- FIX 4: valid empty result vs broken result are distinguished -----------
new_env; dir="$env_dir"
mkdir -p "$dir/bin"

cat >"$dir/bin/ok-empty" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"structured_output":{"records":[]}}'
STUB
cat >"$dir/bin/ok-records" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"structured_output":{"records":[{"category":"model_behavior","severity":"low","title":"t","description":"d"}]}}'
STUB
cat >"$dir/bin/no-so" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"result":"blah"}'
STUB
cat >"$dir/bin/junk" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo 'not json at all'
STUB
chmod +x "$dir/bin/ok-empty" "$dir/bin/ok-records" "$dir/bin/no-so" "$dir/bin/junk"

run_extractor "$dir" "$dir/bin/ok-empty" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
if [ "$ext_rc" -eq 0 ] && [ "$ext_out" = "[]" ]; then
  printf 'ok   (valid {"records":[]} -> emits [] and succeeds)\n'
else
  printf 'FAIL (valid empty records: rc=%s out=%q)\n' "$ext_rc" "$ext_out"
  fail=1
fi

run_extractor "$dir" "$dir/bin/ok-records" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
if [ "$ext_rc" -eq 0 ] && printf '%s' "$ext_out" | jq -e '.[0].title == "t"' >/dev/null 2>&1; then
  printf 'ok   (valid non-empty records -> emitted verbatim, succeeds)\n'
else
  printf 'FAIL (valid records: rc=%s out=%q)\n' "$ext_rc" "$ext_out"
  fail=1
fi

run_extractor "$dir" "$dir/bin/no-so" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
if [ "$ext_rc" -ne 0 ] && [ -z "$ext_out" ]; then
  printf 'ok   (absent structured_output -> non-zero, no stdout)\n'
else
  printf 'FAIL (absent structured_output: rc=%s out=%q)\n' "$ext_rc" "$ext_out"
  fail=1
fi

run_extractor "$dir" "$dir/bin/junk" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
if [ "$ext_rc" -ne 0 ] && [ -z "$ext_out" ]; then
  printf 'ok   (malformed (non-JSON) output -> non-zero, no stdout)\n'
else
  printf 'FAIL (malformed output: rc=%s out=%q)\n' "$ext_rc" "$ext_out"
  fail=1
fi

# --- FIX 5: failures emit a short, bounded error CLASS to stderr ------------
# The class names WHY it failed (never transcript/model content) so the hook
# can log diagnosable metadata instead of retrying a permanent failure blind.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"

cat >"$dir/bin/crash7" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 7
STUB
cat >"$dir/bin/no-so" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"result":"blah"}'
STUB
chmod +x "$dir/bin/crash7" "$dir/bin/no-so"

run_extractor "$dir" "$dir/bin/crash7" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
case "$ext_err" in
  "extractor: claude exit 7")
    printf 'ok   (claude non-zero exit -> "extractor: claude exit N" on stderr)\n' ;;
  *)
    printf 'FAIL (claude exit class: rc=%s err=%q)\n' "$ext_rc" "$ext_err"; fail=1 ;;
esac

run_extractor "$dir" "$dir/bin/no-so" '{"t":1}' PAPERCUT_DETECT_CMD="echo default"
case "$ext_err" in
  "extractor: no structured output")
    printf 'ok   (broken output -> "extractor: no structured output" on stderr)\n' ;;
  *)
    printf 'FAIL (no-structured-output class: err=%q)\n' "$ext_err"; fail=1 ;;
esac

# Missing prompt/schema file is also a diagnosable failure, not a silent []
# (so a broken deploy doesn't mark every transcript processed forever).
run_extractor "$dir" "$dir/bin/no-so" '{"t":1}' \
  PAPERCUT_DETECT_CMD="echo default" \
  PAPERCUT_EXTRACTOR_PROMPT="$dir/does-not-exist.md"
case "$ext_err" in
  "extractor: missing prompt/schema")
    printf 'ok   (missing prompt file -> "extractor: missing prompt/schema", non-zero)\n' ;;
  *)
    printf 'FAIL (missing-prompt class: rc=%s err=%q)\n' "$ext_rc" "$ext_err"; fail=1 ;;
esac

# The hook surfaces the extractor's stderr class as sanitized log metadata
# (bounded, newline-free) on failure -- proven end-to-end through the hook.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
cat >"$dir/bin/stderr-noise" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'extractor: no structured output\n' >&2
echo 'not json'
STUB
chmod +x "$dir/bin/stderr-noise"
PAPERCUT_EXTRACTOR_CMD="$script_dir/extractor-run.sh" run_hook "$dir" nontrivial_turns.jsonl \
  PAPERCUT_CLAUDE_BIN="$dir/bin/stderr-noise" \
  PAPERCUT_DETECT_CMD="echo default"
assert_log_contains "hook logs the extractor error class as metadata" "$dir" "err=extractor: no structured output"

# --- Compaction runs before the model call: an over-budget transcript is
# compacted UNDER budget before it reaches the fake claude, and the extractor
# still succeeds end to end. Uses the real large_payload.jsonl fixture (raw
# bytes > the default 200000-byte compaction budget, per papercut_compact.test.sh).
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
compact_stdin_file="$dir/compact_fake_claude_stdin.txt"
cat >"$dir/bin/fake-claude-record-stdin" <<FAKECLAUDE
#!/usr/bin/env bash
cat > "$compact_stdin_file"
echo '{"structured_output":{"records":[]}}'
FAKECLAUDE
chmod +x "$dir/bin/fake-claude-record-stdin"
raw_bytes=$(wc -c <"$fixtures/large_payload.jsonl" | tr -d ' ')
ext_out=$(env \
  PAPERCUT_CLAUDE_BIN="$dir/bin/fake-claude-record-stdin" \
  PAPERCUT_DETECT_CMD="echo default" \
  bash "$extractor" <"$fixtures/large_payload.jsonl" 2>"$dir/ext.err")
ext_rc=$?
compacted_bytes=$(wc -c <"$compact_stdin_file" 2>/dev/null | tr -d ' ')
if [ "$raw_bytes" -gt 200000 ]; then
  printf 'ok   (large_payload fixture exceeds the default compaction budget: %s bytes)\n' "$raw_bytes"
else
  printf 'FAIL (large_payload fixture does not exceed the default compaction budget: %s bytes)\n' "$raw_bytes"
  fail=1
fi
if [ "${compacted_bytes:-999999999}" -lt 200000 ]; then
  printf 'ok   (fake claude received compacted input under budget: %s bytes)\n' "$compacted_bytes"
else
  printf 'FAIL (fake claude did NOT receive input under budget: %s bytes)\n' "${compacted_bytes:-unset}"
  fail=1
fi
if [ "$ext_rc" -eq 0 ] && [ "$ext_out" = "[]" ]; then
  printf 'ok   (extractor-run.sh compacts an over-budget transcript and still succeeds, emitting [])\n'
else
  printf 'FAIL (compaction-before-model: rc=%s out=%q err=%s)\n' "$ext_rc" "$ext_out" "$(cat "$dir/ext.err" 2>/dev/null)"
  fail=1
fi

# --- Compaction failure is fail-CLOSED: PAPERCUT_COMPACT_CMD=false must stop
# extractor-run.sh with class "compaction failed" BEFORE the model is ever
# invoked -- never falls back to feeding the raw (possibly over-budget)
# transcript to claude.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
compact_fail_guard="$dir/compact_fail_claude_invoked.txt"
cat >"$dir/bin/fake-claude-should-not-run" <<FAKECLAUDE
#!/usr/bin/env bash
cat >/dev/null
touch "$compact_fail_guard"
echo '{"structured_output":{"records":[]}}'
FAKECLAUDE
chmod +x "$dir/bin/fake-claude-should-not-run"
ext_out=$(env \
  PAPERCUT_CLAUDE_BIN="$dir/bin/fake-claude-should-not-run" \
  PAPERCUT_COMPACT_CMD="false" \
  PAPERCUT_DETECT_CMD="echo default" \
  bash "$extractor" <"$fixtures/nontrivial_turns.jsonl" 2>"$dir/ext.err")
ext_rc=$?
ext_err=$(cat "$dir/ext.err" 2>/dev/null)
if [ "$ext_rc" -ne 0 ] && [ "$ext_err" = "extractor: compaction failed" ]; then
  printf 'ok   (PAPERCUT_COMPACT_CMD=false -> non-zero, "extractor: compaction failed" on stderr)\n'
else
  printf 'FAIL (compaction-failed class: rc=%s err=%q)\n' "$ext_rc" "$ext_err"
  fail=1
fi
if [ -f "$compact_fail_guard" ]; then
  printf 'FAIL (compaction failure: the model was invoked despite fail-closed compaction)\n'
  fail=1
else
  printf 'ok   (compaction failure: model never invoked)\n'
fi

# --- Compaction failure is fail-CLOSED even on a ZERO exit: a compactor that
# exits 0 but emits nothing (PAPERCUT_COMPACT_CMD=true) is just as much a
# failure as a non-zero exit -- the "[ -s ]" empty check must catch it, and
# the model must still never be invoked.
new_env; dir="$env_dir"
mkdir -p "$dir/bin"
compact_empty_guard="$dir/compact_empty_claude_invoked.txt"
cat >"$dir/bin/fake-claude-should-not-run-2" <<FAKECLAUDE
#!/usr/bin/env bash
cat >/dev/null
touch "$compact_empty_guard"
echo '{"structured_output":{"records":[]}}'
FAKECLAUDE
chmod +x "$dir/bin/fake-claude-should-not-run-2"
ext_out=$(env \
  PAPERCUT_CLAUDE_BIN="$dir/bin/fake-claude-should-not-run-2" \
  PAPERCUT_COMPACT_CMD="true" \
  PAPERCUT_DETECT_CMD="echo default" \
  bash "$extractor" <"$fixtures/nontrivial_turns.jsonl" 2>"$dir/ext.err")
ext_rc=$?
ext_err=$(cat "$dir/ext.err" 2>/dev/null)
if [ "$ext_rc" -ne 0 ] && [ "$ext_err" = "extractor: compaction failed" ]; then
  printf 'ok   (PAPERCUT_COMPACT_CMD=true, empty output -> non-zero, "extractor: compaction failed" on stderr)\n'
else
  printf 'FAIL (compaction-empty-output class: rc=%s err=%q)\n' "$ext_rc" "$ext_err"
  fail=1
fi
if [ -f "$compact_empty_guard" ]; then
  printf 'FAIL (compaction empty output: the model was invoked despite fail-closed compaction)\n'
  fail=1
else
  printf 'ok   (compaction empty output: model never invoked)\n'
fi

exit $fail
