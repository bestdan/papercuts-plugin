#!/usr/bin/env bash
# Tests for papercut-sweep.sh — the SessionStart backstop that re-drives
# papercut-capture.sh for sessions whose SessionEnd never fired, and owns the
# anchors sidecar lifecycle (delete on confirmed-processed, prune past TTL).
# Also covers the anchor-cleanup change to papercut-capture.sh's success path
# (task 4). Run:
#   bash tests/papercut-sweep.test.sh
#
# All state (anchors, processed dir, projects dir, log) lives under a
# per-case temp dir so this suite never touches real ~/.claude.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
sweep="$script_dir/papercut-sweep.sh"
capture="$script_dir/papercut-capture.sh"
fixtures="$(cd "$(dirname "$0")" && pwd)/fixtures"

fail=0
counter=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

new_env() {
  counter=$((counter + 1))
  env_dir="$workdir/case-$counter"
  mkdir -p "$env_dir/anchors" "$env_dir/processed" "$env_dir/projects" "$env_dir/captured"
}

# The gate derives its profile from the REAL hostname; on a work host it
# would resolve to the betterment profile and reject records for lack of a
# denylist. Route the gate through this wrapper (same trick as
# papercut-capture.test.sh) so it's deterministic on any machine.
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

session_key() {
  python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8','surrogateescape')).hexdigest())" "$1"
}

set_mtime() {
  # $1=path $2=seconds-ago
  python3 -c '
import os, sys, time
path, ago = sys.argv[1], int(sys.argv[2])
t = time.time() - ago
os.utime(path, (t, t))
' "$1" "$2"
}

# write_anchor <dir> <session_id> -> path to the anchors file
write_anchor() {
  local dir="$1" sid="$2" key path
  key="$(session_key "$sid")"
  path="$dir/anchors/$key.jsonl"
  printf '{"v":1,"session_id":"%s","kind":"tool_error","tool_name":"Bash","error_class":"nonzero_exit"}\n' "$sid" >"$path"
  printf '%s' "$path"
}

# write_transcript <dir> <session_id> <cwd> -> path to the transcript file
write_transcript() {
  local dir="$1" sid="$2" cwd="$3" sub path
  sub="$dir/projects/proj-$counter"
  mkdir -p "$sub"
  path="$sub/$sid.jsonl"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hi"}}\n' "$cwd" >"$path"
  printf '%s' "$path"
}

# run_sweep <dir> <own_session_id> [extra env assignments...]
run_sweep() {
  local dir="$1" own="$2"
  shift 2
  local payload
  payload=$(printf '{"session_id":"%s"}' "$own")
  env \
    PAPERCUT_ANCHORS_DIR="$dir/anchors" \
    PAPERCUT_PROCESSED_DIR="$dir/processed" \
    PAPERCUT_PROJECTS_DIR="$dir/projects" \
    PAPERCUT_LOG="$dir/sweep.log" \
    PAPERCUT_CAPTURE_CMD="{ cat; printf '\\n'; } >>'$dir/captured/calls.jsonl'" \
    "$@" \
    bash "$sweep" <<<"$payload"
}

# run_capture <dir> <fixture> <session_id> -> drives papercut-capture.sh
# directly (used for the two acceptance criteria about capture.sh's own
# anchor-cleanup change, independent of the sweep script).
run_capture() {
  local dir="$1" fixture="$2" sid="$3"
  shift 3
  local transcript="$dir/transcript.jsonl"
  cp "$fixtures/$fixture" "$transcript"
  local payload
  payload=$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$transcript" "$sid" "$dir")
  env \
    PAPERCUT_PROCESSED_DIR="$dir/processed" \
    PAPERCUT_CAPTURE_LOCKDIR="$dir/locks" \
    PAPERCUT_LOG="$dir/capture.log" \
    PAPERCUT_EXTRACTOR_CMD="echo []" \
    PAPERCUT_APPEND_CMD="$append_default_host" \
    PAPERCUT_SPOOL="$dir/spool.jsonl" \
    PAPERCUT_LOCK="$dir/.spool.lock" \
    PAPERCUT_ANCHORS_DIR="$dir/anchors" \
    "$@" \
    bash "$capture" <<<"$payload"
}

# --- 1a. Quiet window: fresh anchors mtime -> skipped, even with no marker --
new_env; dir="$env_dir"
sid="live-session-1"
anchors_path="$(write_anchor "$dir" "$sid")"
write_transcript "$dir" "$sid" "$dir/repo" >/dev/null
# anchors mtime left fresh (just written = now).
run_sweep "$dir" "own-session-x"
if [ -f "$anchors_path" ] && [ ! -s "$dir/captured/calls.jsonl" ]; then
  pass "quiet window: fresh anchors mtime skipped entirely"
else
  fail_test "quiet window: fresh anchors mtime skipped entirely (anchors_present=$([ -f "$anchors_path" ] && echo yes || echo no))"
fi

# --- 1b. Quiet window: old anchors but fresh transcript -> still skipped ----
new_env; dir="$env_dir"
sid="live-session-2"
anchors_path="$(write_anchor "$dir" "$sid")"
set_mtime "$anchors_path" $((30 * 3600))
transcript_path="$(write_transcript "$dir" "$sid" "$dir/repo")"
# transcript mtime left fresh (just written = now).
run_sweep "$dir" "own-session-x"
if [ -f "$anchors_path" ] && [ ! -s "$dir/captured/calls.jsonl" ]; then
  pass "quiet window: fresh transcript mtime skipped entirely"
else
  fail_test "quiet window: fresh transcript mtime skipped entirely"
fi
[ -f "$transcript_path" ] # silence unused-var lint concerns

# --- 2. Self-skip: own session's anchors file never processed, regardless
# of mtimes (backdated well past quiet window AND a marker present). --------
new_env; dir="$env_dir"
own_sid="own-session-2"
anchors_path="$(write_anchor "$dir" "$own_sid")"
set_mtime "$anchors_path" $((30 * 3600))
own_key="$(session_key "$own_sid")"
: >"$dir/processed/$own_key.hash"
run_sweep "$dir" "$own_sid"
if [ -f "$anchors_path" ] && [ ! -s "$dir/captured/calls.jsonl" ]; then
  pass "self-skip: own session's anchors file untouched despite quiet mtime + marker"
else
  fail_test "self-skip: own session's anchors file untouched despite quiet mtime + marker"
fi

# --- 3. Quiet + marker exists -> anchors deleted, no capture invoked -------
new_env; dir="$env_dir"
sid="done-session-1"
anchors_path="$(write_anchor "$dir" "$sid")"
set_mtime "$anchors_path" $((30 * 3600))
key="$(session_key "$sid")"
: >"$dir/processed/$key.hash"
run_sweep "$dir" "own-session-x"
if [ ! -f "$anchors_path" ] && [ ! -s "$dir/captured/calls.jsonl" ]; then
  pass "quiet + marker exists: anchors deleted, capture not invoked"
else
  fail_test "quiet + marker exists: anchors deleted, capture not invoked (anchors_present=$([ -f "$anchors_path" ] && echo yes || echo no), captured=$(cat "$dir/captured/calls.jsonl" 2>/dev/null))"
fi

# --- 4. Quiet + no marker + transcript present -> capture invoked with the
# RAW session id and transcript-derived cwd. --------------------------------
new_env; dir="$env_dir"
sid="stuck-session-1"
anchors_path="$(write_anchor "$dir" "$sid")"
set_mtime "$anchors_path" $((30 * 3600))
transcript_path="$(write_transcript "$dir" "$sid" "/repo/checkout")"
set_mtime "$transcript_path" $((30 * 3600))
run_sweep "$dir" "own-session-x"
calls="$dir/captured/calls.jsonl"
if [ -f "$calls" ]; then
  got_sid="$(jq -r '.session_id' "$calls")"
  got_cwd="$(jq -r '.cwd' "$calls")"
  got_tp="$(jq -r '.transcript_path' "$calls")"
  if [ "$got_sid" = "$sid" ] && [ "$got_cwd" = "/repo/checkout" ] && [ "$got_tp" = "$transcript_path" ]; then
    pass "quiet + no marker + transcript: capture invoked with raw session_id + cwd"
  else
    fail_test "quiet + no marker + transcript: wrong synthesized JSON (sid=$got_sid cwd=$got_cwd tp=$got_tp)"
  fi
else
  fail_test "quiet + no marker + transcript: capture was not invoked"
fi

# --- 5a. No transcript, anchors age > TTL -> pruned ------------------------
new_env; dir="$env_dir"
sid="gone-session-old"
anchors_path="$(write_anchor "$dir" "$sid")"
set_mtime "$anchors_path" $((10 * 86400))
run_sweep "$dir" "own-session-x" PAPERCUT_ANCHOR_TTL_DAYS=7
if [ ! -f "$anchors_path" ]; then
  pass "no transcript + age>TTL: anchors pruned"
else
  fail_test "no transcript + age>TTL: anchors pruned"
fi

# --- 5b. No transcript, anchors age < TTL -> kept --------------------------
new_env; dir="$env_dir"
sid="gone-session-new"
anchors_path="$(write_anchor "$dir" "$sid")"
set_mtime "$anchors_path" $((2 * 86400))
run_sweep "$dir" "own-session-x" PAPERCUT_ANCHOR_TTL_DAYS=7
if [ -f "$anchors_path" ] && [ ! -s "$dir/captured/calls.jsonl" ]; then
  pass "no transcript + age<TTL: anchors kept, no capture"
else
  fail_test "no transcript + age<TTL: anchors kept, no capture"
fi

# --- 6. Capture success path deletes the anchors sidecar (capture.sh direct,
# stubbed extractor returning [] / empty-array success). -------------------
new_env; dir="$env_dir"
sid="capture-success-1"
anchors_path="$(write_anchor "$dir" "$sid")"
run_capture "$dir" nontrivial_turns.jsonl "$sid"
if [ ! -f "$anchors_path" ]; then
  pass "capture success path deletes the anchors sidecar"
else
  fail_test "capture success path deletes the anchors sidecar"
fi

# --- 7. Capture with marker write forced to fail -> anchors sidecar kept.
# Making the whole processed dir read-only also blocks the per-session LOCK
# file (a different path in the same dir) from being opened, which trips an
# earlier "session-lock-busy" skip and never reaches write_marker at all --
# so instead pre-create the hash file's path AS A DIRECTORY: the lock file
# still opens fine, capture proceeds all the way to `printf ... >"$hash_file"`,
# and that write fails (EISDIR) exactly like a real permission failure would.
new_env; dir="$env_dir"
sid="marker-fail-1"
anchors_path="$(write_anchor "$dir" "$sid")"
key="$(session_key "$sid")"
mkdir -p "$dir/processed/$key.hash"
run_capture "$dir" nontrivial_turns.jsonl "$sid"
if [ -f "$anchors_path" ] && grep -qF "marker-write-failed" "$dir/capture.log" 2>/dev/null; then
  pass "capture with marker write failure keeps the anchors sidecar"
else
  fail_test "capture with marker write failure keeps the anchors sidecar (log: $(cat "$dir/capture.log" 2>/dev/null))"
fi

# --- 9. Fail-silent regressions on bash 3.2 (macOS system bash): the hook
# must exit 0 rather than aborting under `set -u` for (a) an empty anchors dir
# (empty-array expansion) and (b) a non-integer numeric override (arithmetic
# treats the token as an unset variable). --------------------------------------
new_env; dir="$env_dir"
run_sweep "$dir" "own-session-x" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
  pass "fail-silent: empty anchors dir exits 0"
else
  fail_test "fail-silent: empty anchors dir exits 0 (rc=$rc)"
fi

new_env; dir="$env_dir"
write_anchor "$dir" "badcfg-1" >/dev/null
run_sweep "$dir" "own-session-x" PAPERCUT_SWEEP_QUIET_HOURS=abc PAPERCUT_ANCHOR_TTL_DAYS=12x >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
  pass "fail-silent: non-integer numeric overrides exit 0"
else
  fail_test "fail-silent: non-integer numeric overrides exit 0 (rc=$rc)"
fi

# --- 10. Scrub-review sidecar TTL prune: entries older than
# PAPERCUT_REVIEW_TTL_DAYS are dropped, entries within it survive, and the
# prune runs even when the anchors dir is otherwise empty (this sidecar is a
# single shared file, unrelated to any one session's anchors). ---
new_env; dir="$env_dir"
review_file="$dir/scrub-review.jsonl"
old_ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
new_ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
python3 -c '
import json, sys
old_ts, new_ts, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    f.write(json.dumps({"ts": old_ts, "record_id": "pc_old", "runs": ["stale-vocab-run"]}) + "\n")
    f.write(json.dumps({"ts": new_ts, "record_id": "pc_new", "runs": ["fresh-vocab-run"]}) + "\n")
' "$old_ts" "$new_ts" "$review_file"
chmod 0600 "$review_file"
run_sweep "$dir" "own-session-x" PAPERCUT_REVIEW_FILE="$review_file" PAPERCUT_REVIEW_TTL_DAYS=30
remaining_ids="$(python3 -c '
import json
with open("'"$review_file"'") as f:
    print(",".join(json.loads(l)["record_id"] for l in f if l.strip()))
' 2>/dev/null)"
if [ "$remaining_ids" = "pc_new" ]; then
  pass "scrub-review sidecar TTL prune: stale entry dropped, fresh entry kept"
else
  fail_test "scrub-review sidecar TTL prune: stale entry dropped, fresh entry kept (remaining=$remaining_ids)"
fi
review_file_perm="$(stat -c '%a' "$review_file" 2>/dev/null || stat -f '%Lp' "$review_file")"
if [ "$review_file_perm" = "600" ]; then
  pass "scrub-review sidecar TTL prune: file stays 0600 after rewrite"
else
  fail_test "scrub-review sidecar TTL prune: file stays 0600 after rewrite (got $review_file_perm)"
fi

# --- 11. Scrub-review sidecar TTL prune: nothing stale -> file untouched,
# no rewrite. ---
new_env; dir="$env_dir"
review_file="$dir/scrub-review.jsonl"
new_ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
python3 -c '
import json, sys
new_ts, path = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    f.write(json.dumps({"ts": new_ts, "record_id": "pc_new", "runs": ["fresh-vocab-run"]}) + "\n")
' "$new_ts" "$review_file"
chmod 0600 "$review_file"
run_sweep "$dir" "own-session-x" PAPERCUT_REVIEW_FILE="$review_file" PAPERCUT_REVIEW_TTL_DAYS=30
if grep -qF "pc_new" "$review_file" 2>/dev/null && ! grep -qF "prune reason=review-sidecar-ttl" "$dir/sweep.log" 2>/dev/null; then
  pass "scrub-review sidecar TTL prune: nothing stale, no prune logged"
else
  fail_test "scrub-review sidecar TTL prune: nothing stale, no prune logged (log: $(cat "$dir/sweep.log" 2>/dev/null))"
fi

# --- 12. Concurrency: a swarm of gate appends racing several sweep prunes
# must never corrupt the sidecar. Both sides serialize on the SAME
# "<review_file>.lock" fcntl lock (gate: papercut_append.py's
# write_review_sidecar(); sweep: prune_review_sidecar() above), each doing a
# read-whole / write-tmp / atomic-rename cycle rather than an in-place
# append, so a crash or interleave mid-write can't leave a torn line.
#
# The sidecar is pre-seeded with one entry whose `ts` is already older than
# the TTL used below, so at least one of the concurrent prune passes
# genuinely reaches write_atomically() instead of hitting
# prune_review_sidecar's `if pruned == 0` early return before ever writing --
# which is what this test's previous far-future TTL guaranteed on EVERY
# pass, so it only ever exercised lock ACQUISITION, never a write racing
# another write. TTL is a real, small number (not 9999) so the age filter
# stays live for the whole race, and every gate append lands with a fresh
# `ts` that must survive it regardless of which prune pass wins the race to
# write. Runs real concurrent processes (not a mock) against one shared
# file: 15 gate appends and 5 sweep prune passes. Asserts every surviving
# line is valid JSON with the right shape, the stale seed entry is gone, and
# none of the fresh entries were lost.
#
# Be honest about what this does and does not prove. It is a SMOKE test: it
# starts real concurrent writers against one file and asserts the result is
# never corrupt. It does NOT prove that a prune rewrite actually overlapped a
# gate append -- there is no barrier or instrumentation, so the scheduler is
# free to run the whole prune before any append reaches the sidecar and the
# test still passes. Proving overlap would need a test-only synchronization
# hook wired into the locked read/write phases of production code, which is
# more machinery than a personal dotfiles repo warrants for a race the shared
# fcntl lock already forecloses by construction (one writer holds it at a
# time, so two write_atomically calls cannot interleave regardless).
#
# Also not covered: forcing >1 prune pass to independently observe stale rows.
# Once the first prune wins, the sidecar is clean and the rest legitimately
# take the early return. -----------------------------------------------------
new_env; dir="$env_dir"
review_file="$dir/scrub-review.jsonl"
review_ttl_days=7
stale_ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
python3 -c '
import json, sys
stale_ts, path = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    f.write(json.dumps({"ts": stale_ts, "record_id": "pc_stale_seed", "runs": ["stale-vocab-run"]}) + "\n")
' "$stale_ts" "$review_file"
chmod 0600 "$review_file"

n_appends=15
n_prunes=5
pids=()
for i in $(seq 1 "$n_appends"); do
  (
    printf '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
      | PAPERCUT_SPOOL="$dir/spool.jsonl" PAPERCUT_LOCK="$dir/spool.lock" PAPERCUT_REVIEW_FILE="$review_file" \
        "$append_default_host" --source manual --producer test/concurrency --repo dotfiles >/dev/null 2>/dev/null
  ) &
  pids+=($!)
done
for _ in $(seq 1 "$n_prunes"); do
  (
    run_sweep "$dir" "own-session-x" PAPERCUT_REVIEW_FILE="$review_file" PAPERCUT_REVIEW_TTL_DAYS="$review_ttl_days" >/dev/null 2>&1
  ) &
  pids+=($!)
done
race_failed=0
for p in "${pids[@]}"; do
  wait "$p" || race_failed=1
done
if [ "$race_failed" -ne 0 ]; then
  fail_test "concurrent sidecar race: a background gate/sweep process exited non-zero"
fi

if [ -f "$review_file" ]; then
  line_count=$(wc -l <"$review_file" | tr -d ' ')
  stale_seed_present=$(grep -cF "pc_stale_seed" "$review_file" 2>/dev/null || true)
  well_formed=$(python3 -c '
import json, sys
path = sys.argv[1]
n = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        assert set(obj.keys()) == {"ts", "record_id", "runs"}, obj
        n += 1
print(n)
' "$review_file" 2>/dev/null)
  if [ "$line_count" = "$n_appends" ] && [ "$well_formed" = "$n_appends" ] && [ "${stale_seed_present:-1}" = "0" ]; then
    pass "concurrent gate appends + sweep prunes: $n_appends fresh well-formed lines, stale seed pruned, none lost/corrupted"
  else
    fail_test "concurrent gate appends + sweep prunes: expected $n_appends fresh well-formed lines and stale seed pruned, got $line_count total / ${well_formed:-parse-error} well-formed / stale_seed_present=${stale_seed_present:-?}"
  fi
else
  fail_test "concurrent gate appends + sweep prunes: sidecar file missing entirely"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll papercut-sweep tests passed.\n'
else
  printf '\nSome papercut-sweep tests FAILED.\n'
fi
exit "$fail"
