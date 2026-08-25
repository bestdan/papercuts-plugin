#!/usr/bin/env bash
# Tests for papercut-flush.sh — the local half of the flusher (stamps,
# locked claim, stale-batch recovery, quarantine). Publishing is a stub
# (scripts/papercut_flush_group.py / papercut_flush_claim.py do the
# real work; the publish seam is $PAPERCUT_PUBLISH_CMD).
# Run:
#   bash tests/papercut-flush.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

here="$(cd "$(dirname "$0")/../scripts" && pwd)"
flush="$here/papercut-flush.sh"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

next_dir() {
  local d
  d="$workdir/$RANDOM$RANDOM"
  mkdir -p "$d"
  printf '%s' "$d"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s: expected %q, got %q)\n' "$desc" "$expected" "$actual"
    fail=1
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s)\n' "$desc"
    fail=1
  fi
}

# Sets up a fresh, isolated env for one flusher invocation. Prints the dir.
new_env_dir() {
  local d
  d="$(next_dir)"
  mkdir -p "$d/cache"
  printf '%s' "$d"
}

env_vars_for() {
  local d="$1"
  printf 'export PAPERCUT_SPOOL=%q PAPERCUT_LOCK=%q PAPERCUT_BATCH_DIR=%q PAPERCUT_QUARANTINE_DIR=%q PAPERCUT_FLUSH_OK=%q PAPERCUT_FLUSH_FAIL=%q PAPERCUT_LOG=%q' \
    "$d/spool.jsonl" "$d/.spool.lock" "$d" "$d/quarantine" "$d/cache/ok" "$d/cache/fail" "$d/flush.log"
}

rec() {
  # rec <id> <ts> -> one JSONL papercut record line
  printf '{"id":"%s","v":1,"producer":"test/1","ts":"%s","machine":"default","source":"manual","category":"harness_config","severity":"low","title":"t","description":"d","repo":"dotfiles"}\n' "$1" "$2"
}

# A stub publisher that records every id it's handed into $PAPERCUT_TEST_LEDGER
# and exits 0, unless $PAPERCUT_TEST_FAIL_MONTHS lists the month it's called
# with (space-separated), in which case it exits 1 without recording anything.
# Fake `hostname` shim: put a dir on PATH ahead of the real `hostname` so the
# flusher's early machine detection sees whatever host we want, without
# touching the real machine's hostname. Mirrors the git-shim technique used
# below for the divergent-remote test.
hostname_shim_dir() {
  # hostname_shim_dir <fake-hostname> -> prints a dir to prepend to PATH
  local fake_host="$1" d
  d="$(next_dir)"
  cat >"$d/hostname" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$fake_host"
EOF
  chmod +x "$d/hostname"
  printf '%s' "$d"
}

# The rest of this suite assumes the DEFAULT profile unless a test explicitly
# overrides it (sections 21/22 below) — pin PATH to a non-betterment hostname
# shim so every existing assertion is deterministic regardless of the real
# machine running the suite (which may itself be a Betterment host).
default_host_shim="$(hostname_shim_dir "some-laptop")"
export PATH="$default_host_shim:$PATH"

# Ledger-identity config fixtures. The publisher's origin allowlist is built
# from the config file (task 3b), so every fixture that drives the REAL
# publisher writes a temp config: remote_url is the exact-match trust anchor
# that lets a file:// bare repo pass the allowlist legitimately (an env-only
# PAPERCUT_LEDGER_REMOTE no longer can — that bypass is deleted).
ledger_config() {
  # ledger_config <remote-url> -> temp config trusting exactly that URL
  local url="$1" cfg
  cfg="$(next_dir)/config.toml"
  printf '[ledger]\nremote_url = "%s"\n' "$url" >"$cfg"
  printf '%s' "$cfg"
}

ledger_config_repo() {
  # ledger_config_repo <owner/name> [host] -> temp config naming the ledger
  # repo, exercising the anchored host/repo-derived allowlist regexes
  local repo="$1" host="${2:-}" cfg
  cfg="$(next_dir)/config.toml"
  {
    printf '[ledger]\nrepo = "%s"\n' "$repo"
    [ -n "$host" ] && printf 'host = "%s"\n' "$host"
  } >"$cfg"
  printf '%s' "$cfg"
}

stub_publish="$workdir/stub_publish.sh"
cat >"$stub_publish" <<'EOF'
#!/usr/bin/env bash
file="$1"
month="$2"
if [ -n "${PAPERCUT_TEST_FAIL_MONTHS:-}" ]; then
  for m in $PAPERCUT_TEST_FAIL_MONTHS; do
    [ "$m" = "$month" ] && exit 1
  done
fi
python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            print(json.loads(line)["id"])
' "$file" >>"$PAPERCUT_TEST_LEDGER"
exit 0
EOF
chmod +x "$stub_publish"

# =============================================================================
# 1. throttle: empty spool + no batches -> fast exit 0, no stamps written
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
bash "$flush"
rc=$?
assert_eq "empty spool, no batches: exits 0" "0" "$rc"
assert_true "empty spool: no success stamp written" "$([ ! -f "$PAPERCUT_FLUSH_OK" ] && echo 1 || echo 0)"

# =============================================================================
# 2. happy path: populated spool, --force, publishes and cleans up
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
{ rec pc_1 "2026-01-15T00:00:00Z"; rec pc_2 "2026-01-16T00:00:00Z"; } >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "happy path exits 0" "0" "$rc"
assert_true "happy path: spool consumed" "$([ ! -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
shopt -s nullglob
leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*)
shopt -u nullglob
assert_eq "happy path: no batch files left" "0" "${#leftover[@]}"
assert_true "happy path: success stamp set" "$([ -f "$PAPERCUT_FLUSH_OK" ] && echo 1 || echo 0)"
ledger_count="$(wc -l <"$PAPERCUT_TEST_LEDGER" | tr -d ' ')"
assert_eq "happy path: both records published" "2" "$ledger_count"

# =============================================================================
# 3. append-during-claim race: no record lost, flusher waits for the lock
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
rec pc_race_1 "2026-02-01T00:00:00Z" >"$PAPERCUT_SPOOL"

# Simulated in-flight appender: acquire the SAME lock file, hold it for 1s,
# append a second record while still holding it, then release. Mirrors
# papercut_append.py's append_records: lock held across the whole write.
holder_started="$d/holder_started"
python3 - "$PAPERCUT_LOCK" "$PAPERCUT_SPOOL" "$holder_started" <<'PY' &
import fcntl, os, sys, time

lock_path, spool_path, started_marker = sys.argv[1:4]
os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(started_marker, "w") as m:
    m.write("1")
time.sleep(1)
with open(spool_path, "a") as f:
    f.write('{"id":"pc_race_2","v":1,"producer":"test/1","ts":"2026-02-01T00:00:01Z","machine":"default","source":"manual","category":"harness_config","severity":"low","title":"t","description":"d","repo":"dotfiles"}\n')
    f.flush()
    os.fsync(f.fileno())
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
holder_pid=$!

# Wait for the holder to actually acquire the lock before launching the
# flusher, so the flusher deterministically has to wait on it.
for _ in $(seq 1 50); do
  [ -f "$holder_started" ] && break
  sleep 0.05
done

bash "$flush" --force
wait "$holder_pid"

# Losslessness: every id appended must end up published exactly once (the
# flusher may have claimed before or after the concurrent append landed —
# either ordering is fine, but nothing may be lost or duplicated). Run a
# second flush to sweep up anything left in the spool by an ordering where
# the append happened after this run's claim.
bash "$flush" --force

total_race_ids="$(sort -u "$PAPERCUT_TEST_LEDGER" | wc -l | tr -d ' ')"
assert_eq "race: both concurrent ids published exactly once" "2" "$total_race_ids"
dup_check="$(sort "$PAPERCUT_TEST_LEDGER" | uniq -d | wc -l | tr -d ' ')"
assert_eq "race: no duplicate ids in ledger" "0" "$dup_check"

# =============================================================================
# 4. two flushers running simultaneously: unique batches, both survive
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"

# Slow stub for flusher A so it's still "in flight" when B claims separate
# content appended after A already renamed the spool away.
slow_stub="$d/slow_stub.sh"
cat >"$slow_stub" <<EOF
#!/usr/bin/env bash
sleep 0.5
exec "$stub_publish" "\$@"
EOF
chmod +x "$slow_stub"

rec pc_two_a "2026-03-01T00:00:00Z" >"$PAPERCUT_SPOOL"
PAPERCUT_PUBLISH_CMD="$slow_stub" bash "$flush" --force &
flusher_a=$!
sleep 0.1
rec pc_two_b "2026-03-01T00:00:01Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
flusher_b_rc=$?
wait "$flusher_a"
flusher_a_rc=$?

assert_eq "two flushers: A exits 0" "0" "$flusher_a_rc"
assert_eq "two flushers: B exits 0" "0" "$flusher_b_rc"
two_ledger_count="$(sort -u "$PAPERCUT_TEST_LEDGER" | wc -l | tr -d ' ')"
assert_eq "two flushers: both ids published, none duplicated" "2" "$two_ledger_count"

# =============================================================================
# 5. kill -9 after claim: a stray spool.batch.* with no completion is
# recovered and published on the next run
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$PAPERCUT_BATCH_DIR"
rec pc_stale_1 "2026-04-01T00:00:00Z" >"$PAPERCUT_BATCH_DIR/spool.batch.20260101T000000Z.99999.jsonl"
bash "$flush" --force
rc=$?
assert_eq "stale batch recovery: exits 0" "0" "$rc"
shopt -s nullglob
leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*)
shopt -u nullglob
assert_eq "stale batch recovery: batch consumed" "0" "${#leftover[@]}"
assert_true "stale batch recovery: id published" "$(grep -qx pc_stale_1 "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 5b. multiple stale batches are published OLDEST-FIRST. Guards the sort: an
# earlier version used `mapfile` (bash 4+, absent on macOS 3.2), which silently
# left the batch list unsorted. The publish stub records ids in call order, so
# the older batch's id must appear before the newer batch's id in the ledger.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$PAPERCUT_BATCH_DIR"
# Create the NEWER batch file first so directory/glob order can't accidentally
# yield oldest-first; only a real sort produces the correct order.
rec pc_newer "2026-06-01T00:00:00Z" >"$PAPERCUT_BATCH_DIR/spool.batch.20260201T000000Z.222.jsonl"
rec pc_older "2026-05-01T00:00:00Z" >"$PAPERCUT_BATCH_DIR/spool.batch.20260101T000000Z.111.jsonl"
bash "$flush" --force
older_line="$(grep -nxq pc_older "$PAPERCUT_TEST_LEDGER"; grep -nx pc_older "$PAPERCUT_TEST_LEDGER" | cut -d: -f1)"
newer_line="$(grep -nx pc_newer "$PAPERCUT_TEST_LEDGER" | cut -d: -f1)"
assert_true "multi-batch: oldest published before newest" \
  "$([ -n "$older_line" ] && [ -n "$newer_line" ] && [ "$older_line" -lt "$newer_line" ] && echo 1 || echo 0)"

# =============================================================================
# 6. publish failure -> batch retained + failure stamp; success -> deleted
#    + success stamp
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
rec pc_fail_1 "2026-05-01T00:00:00Z" >"$PAPERCUT_SPOOL"
PAPERCUT_TEST_FAIL_MONTHS="2026-05" bash "$flush" --force
rc=$?
assert_eq "publish failure: flush exits non-zero" "1" "$rc"
shopt -s nullglob
leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*)
shopt -u nullglob
assert_eq "publish failure: batch retained" "1" "${#leftover[@]}"
assert_true "publish failure: failure stamp set" "$([ -f "$PAPERCUT_FLUSH_FAIL" ] && echo 1 || echo 0)"
assert_true "publish failure: nothing published" "$([ ! -s "$PAPERCUT_TEST_LEDGER" ] && echo 1 || echo 0)"

# now retry without the forced failure: should publish and clean up, and set
# the success stamp (failure stamp is left stale, which is fine — the next
# normal run reads the FRESHER stamp's semantics, exercised in section 8).
bash "$flush" --force
rc=$?
assert_eq "publish retry succeeds: exits 0" "0" "$rc"
shopt -s nullglob
leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*)
shopt -u nullglob
assert_eq "publish retry: batch cleaned up" "0" "${#leftover[@]}"
assert_true "publish retry: id published" "$(grep -qx pc_fail_1 "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 7. malformed ts -> quarantined; valid lines still grouped/published
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
{
  rec pc_good_1 "2026-06-01T00:00:00Z"
  printf '{"id":"pc_bad_1","v":1,"ts":"not-a-timestamp"}\n'
  printf '{"id":"pc_bad_2","v":1,"ts":"2026-13-40T99:99:99Z"}\n'
} >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "malformed ts: exits 0 (good record still published)" "0" "$rc"
assert_true "malformed ts: good id published" "$(grep -qx pc_good_1 "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"
quarantine_file="$(find "$PAPERCUT_QUARANTINE_DIR" -type f 2>/dev/null | head -1)"
assert_true "malformed ts: quarantine file created" "$([ -n "$quarantine_file" ] && echo 1 || echo 0)"
if [ -n "$quarantine_file" ]; then
  assert_true "malformed ts: bad_1 quarantined" "$(grep -q pc_bad_1 "$quarantine_file" && echo 1 || echo 0)"
  assert_true "malformed ts: bad_2 quarantined" "$(grep -q pc_bad_2 "$quarantine_file" && echo 1 || echo 0)"
  assert_true "malformed ts: good_1 NOT in quarantine" "$(grep -q pc_good_1 "$quarantine_file" && echo 0 || echo 1)"
fi

# =============================================================================
# 8. a batch spanning two months groups correctly
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
month_calls="$d/month_calls.txt"
: >"$month_calls"
month_stub="$d/month_stub.sh"
cat >"$month_stub" <<EOF
#!/usr/bin/env bash
echo "\$2" >>"$month_calls"
exec "$stub_publish" "\$@"
EOF
chmod +x "$month_stub"
{
  rec pc_july "2026-07-10T00:00:00Z"
  rec pc_august "2026-08-10T00:00:00Z"
} >"$PAPERCUT_SPOOL"
PAPERCUT_PUBLISH_CMD="$month_stub" bash "$flush" --force
rc=$?
assert_eq "two-month batch: exits 0" "0" "$rc"
months_seen="$(sort -u "$month_calls" | tr '\n' ',' )"
assert_eq "two-month batch: grouped into 2026-07 and 2026-08" "2026-07,2026-08," "$months_seen"
assert_true "two-month batch: july id published" "$(grep -qx pc_july "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"
assert_true "two-month batch: august id published" "$(grep -qx pc_august "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 9. stamp semantics: success stamp throttles, failure stamp throttles
#    (shorter), --force bypasses both
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$(dirname "$PAPERCUT_FLUSH_OK")"
: >"$PAPERCUT_FLUSH_OK" # fresh success stamp
rec pc_throttled_1 "2026-09-01T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush"
rc=$?
assert_eq "fresh success stamp: throttled run exits 0" "0" "$rc"
assert_true "fresh success stamp: spool untouched (not processed)" "$([ -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
bash "$flush" --force
assert_true "fresh success stamp: --force processes anyway" "$(grep -qx pc_throttled_1 "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$(dirname "$PAPERCUT_FLUSH_FAIL")"
: >"$PAPERCUT_FLUSH_FAIL" # fresh failure stamp
rec pc_throttled_2 "2026-09-02T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush"
rc=$?
assert_eq "fresh failure stamp: throttled run exits 0" "0" "$rc"
assert_true "fresh failure stamp: spool untouched (not processed)" "$([ -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
bash "$flush" --force
assert_true "fresh failure stamp: --force processes anyway" "$(grep -qx pc_throttled_2 "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 10. the DEFAULT publisher (no PAPERCUT_PUBLISH_CMD) is the real git
#     publisher (_papercut_publish_git). Pointed at a ledger clone/remote
#     that can never succeed (no such repo, no network involved — a bogus
#     local file:// path), it must fail closed: NOT delete the batch.
#     Isolated to a temp PAPERCUT_LEDGER_DIR/REMOTE so this never touches the
#     real ~/src/papercuts clone or GitHub.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD # fall back to the built-in default: _papercut_publish_git
export PAPERCUT_LEDGER_DIR="$d/no-such-ledger-clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$d/no-such-remote.git")"
rec pc_default_stub "2026-09-03T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "default publisher: run reports failure (non-zero)" "1" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "default publisher: batch RETAINED (no data loss)" "1" "${#leftover[@]}"
assert_true "default publisher: failure stamp set" "$([ -f "$PAPERCUT_FLUSH_FAIL" ] && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# =============================================================================
# 11. an invalid-UTF-8 line is QUARANTINED (surrogateescape), not left to crash
#     the grouping helper and strand the whole batch (and its valid records)
#     forever. Valid records in the same batch still publish; the batch is then
#     consumed; the bad bytes are preserved losslessly in quarantine —
#     fail-closed WITHOUT stranding.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"; : >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$PAPERCUT_BATCH_DIR"
batch11="$PAPERCUT_BATCH_DIR/spool.batch.20260101T000000Z.7.abcd.jsonl"
rec pc_utf8_good "2026-01-05T00:00:00Z" >"$batch11"
printf 'valid-looking but bad bytes \377\376\n' >>"$batch11"
bash "$flush" --force
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "invalid UTF-8: batch consumed (no infinite stranding)" "0" "${#leftover[@]}"
assert_true "invalid UTF-8: valid record still published" "$(grep -qx pc_utf8_good "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"
qfile11="$(find "$PAPERCUT_QUARANTINE_DIR" -type f 2>/dev/null | head -1)"
assert_true "invalid UTF-8: bad bytes quarantined losslessly" "$([ -n "$qfile11" ] && grep -qa 'bad bytes' "$qfile11" && echo 1 || echo 0)"

# =============================================================================
# 11b. a batch the grouping helper genuinely cannot read (unreadable file, so
#      grouping rc != 0) is still RETAINED — the rc-checked retain path must
#      never delete a batch it never parsed. (Skipped as root, which can read a
#      0000-mode file.)
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
  d="$(new_env_dir)"
  eval "$(env_vars_for "$d")"
  export PAPERCUT_PUBLISH_CMD="$stub_publish"
  export PAPERCUT_TEST_LEDGER="$d/ledger.txt"; : >"$PAPERCUT_TEST_LEDGER"
  mkdir -p "$PAPERCUT_BATCH_DIR"
  unreadable="$PAPERCUT_BATCH_DIR/spool.batch.20260101T000000Z.8.efgh.jsonl"
  rec pc_unreadable "2026-01-06T00:00:00Z" >"$unreadable"
  chmod 000 "$unreadable"
  bash "$flush" --force
  chmod 600 "$unreadable" 2>/dev/null
  shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
  assert_eq "grouping rc!=0 (unreadable): batch RETAINED (no data loss)" "1" "${#leftover[@]}"
fi

# =============================================================================
# 12. a failure CLEARS a stale success stamp, so it can't mask the ~1h retry.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"; : >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$(dirname "$PAPERCUT_FLUSH_OK")"; : >"$PAPERCUT_FLUSH_OK" # stale success stamp
PAPERCUT_TEST_FAIL_MONTHS="2026-10" rec pc_fail_clears "2026-10-01T00:00:00Z" >"$PAPERCUT_SPOOL"
PAPERCUT_TEST_FAIL_MONTHS="2026-10" bash "$flush" --force
assert_true "failure clears the stale success stamp" "$([ -f "$PAPERCUT_FLUSH_OK" ] && echo 0 || echo 1)"
assert_true "failure sets the failure stamp" "$([ -f "$PAPERCUT_FLUSH_FAIL" ] && echo 1 || echo 0)"

# =============================================================================
# 13. a stale batch BYPASSES the success throttle (no --force): a batch stranded
#     on disk must be retried even while the ~24h success stamp is fresh.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"; : >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$(dirname "$PAPERCUT_FLUSH_OK")"; : >"$PAPERCUT_FLUSH_OK" # fresh success stamp
mkdir -p "$PAPERCUT_BATCH_DIR"
rec pc_stale_bypass "2026-11-01T00:00:00Z" >"$PAPERCUT_BATCH_DIR/spool.batch.20261001T000000Z.5.beef.jsonl"
bash "$flush" # NO --force
assert_true "stale batch bypasses success throttle: published" "$(grep -qx pc_stale_bypass "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "stale batch bypasses success throttle: batch consumed" "0" "${#leftover[@]}"

# =============================================================================
# Publisher (_papercut_publish_git, the real default publisher) tests against
# a file:// bare remote fixture. Never touches real ~/src/papercuts or GitHub
# — PAPERCUT_LEDGER_DIR and each fixture's PAPERCUT_CONFIG point at temp
# dirs. Two machines are modeled as two independent clones of the same bare
# repo: whichever one pushes second sees the other's commit on its next
# fetch (which _papercut_publish_git always does before building its own
# commit), so the id-dedup step is what keeps both records intact.
# =============================================================================

make_bare_ledger() {
  # Creates a bare repo fixture with an empty ledger/ + one commit on main.
  # Prints the bare repo path.
  local base bare seed
  base="$(next_dir)"
  bare="$base/remote.git"
  git init --quiet --bare --initial-branch=main "$bare" >/dev/null
  seed="$base/seed"
  git clone --quiet "file://$bare" "$seed" >/dev/null 2>&1
  git -C "$seed" config user.email "test@example.com"
  git -C "$seed" config user.name "Test Machine"
  mkdir -p "$seed/ledger"
  : >"$seed/ledger/.gitkeep"
  git -C "$seed" add ledger/.gitkeep >/dev/null
  git -C "$seed" commit --quiet -m "chore: seed ledger" >/dev/null
  git -C "$seed" push --quiet origin HEAD:main >/dev/null 2>&1
  printf '%s' "$bare"
}

clone_ledger() {
  # clone_ledger <bare> <dest> — clones $bare into $dest and sets a local
  # committer identity so commits work without relying on global git config.
  local bare="$1" dest="$2"
  git clone --quiet "file://$bare" "$dest" >/dev/null 2>&1
  git -C "$dest" config user.email "test@example.com"
  git -C "$dest" config user.name "Test Machine"
}

ledger_file_on_remote() {
  # ledger_file_on_remote <bare> <YYYY-MM> — clones fresh into a throwaway
  # dir and prints the monthly ledger file's contents (or nothing).
  local bare="$1" month="$2" tmp
  tmp="$(next_dir)/verify"
  git clone --quiet "file://$bare" "$tmp" >/dev/null 2>&1
  cat "$tmp/ledger/$month.jsonl" 2>/dev/null
}

# --- 14. happy path: batch lands in the correct monthly file on the remote -
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD # use the real default publisher
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_remote_1 "2026-01-05T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "remote happy path: exits 0" "0" "$rc"
remote_content="$(ledger_file_on_remote "$bare" "2026-01")"
assert_true "remote happy path: record landed on remote" \
  "$(printf '%s\n' "$remote_content" | grep -q pc_remote_1 && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 14b. a confirmed publish reports on stdout, and says so only when it
# actually published. A silent exit 0 is indistinguishable from a no-op, which
# has cost re-runs that claimed a second batch.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_stdout_1 "2026-03-05T00:00:00Z" >"$PAPERCUT_SPOOL"
rec pc_stdout_2 "2026-03-06T00:00:00Z" >>"$PAPERCUT_SPOOL"
publish_out="$(bash "$flush" --force)"
rc=$?
assert_eq "publish reporting: exits 0" "0" "$rc"
assert_true "publish reporting: reports the record count" \
  "$(printf '%s' "$publish_out" | grep -q 'published 2 record(s)' && echo 1 || echo 0)"
assert_true "publish reporting: names the monthly ledger file" \
  "$(printf '%s' "$publish_out" | grep -q 'ledger/2026-03.jsonl' && echo 1 || echo 0)"
assert_true "publish reporting: points the reader at origin/main, not the clone" \
  "$(printf '%s' "$publish_out" | grep -q 'origin/main' && echo 1 || echo 0)"
assert_true "publish reporting: includes the pushed sha" \
  "$(printf '%s' "$publish_out" | grep -qE '@ [0-9a-f]{7,}' && echo 1 || echo 0)"
# The clone clause is a signpost for whoever verifies the push, not a chore. Any
# phrasing that describes the clone as behind reads as an outstanding task, and
# agents have burned sessions offering to pull a clone nothing in the flush path
# reads. Both halves are needed: the positive alone would still pass if someone
# appended the old wording back. Safe to assert "fast-forward" is absent — the
# only other use ("push rejected (likely non-fast-forward)") goes through log()
# to $LOG, never to stdout.
assert_true "publish reporting: says the clone is intentionally untouched" \
  "$(printf '%s' "$publish_out" | grep -q 'intentionally untouched' && echo 1 || echo 0)"
assert_true "publish reporting: never describes the clone as needing a pull" \
  "$(printf '%s' "$publish_out" | grep -q 'fast-forward' && echo 0 || echo 1)"
# Re-flushing the same ids publishes nothing new, so it must stay silent —
# otherwise "flushed" would print on a run that changed nothing.
rec pc_stdout_1 "2026-03-05T00:00:00Z" >"$PAPERCUT_SPOOL"
noop_out="$(bash "$flush" --force)"
assert_eq "publish reporting: silent when nothing new is published" "" "$noop_out"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 15. push succeeds but reported as failure -> retry does not duplicate -
# Simulated by re-presenting the SAME record for publish a second time (the
# flusher itself does exactly this on any uncertain outcome — it retains and
# retries the whole batch). Id-dedup must make the second run a no-op.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_retry_1 "2026-02-05T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc1=$?
rec pc_retry_1 "2026-02-05T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc2=$?
assert_eq "duplicate publish: first run exits 0" "0" "$rc1"
assert_eq "duplicate publish: retry run exits 0" "0" "$rc2"
remote_content="$(ledger_file_on_remote "$bare" "2026-02")"
dup_count="$(printf '%s\n' "$remote_content" | grep -c pc_retry_1)"
assert_eq "duplicate publish: id appears exactly once on remote" "1" "$dup_count"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 16. divergent remote: a "second machine" push lands strictly BETWEEN
#     this run's fetch and its first push attempt, forcing a genuine
#     non-fast-forward rejection and a full retry (re-fetch, remove the
#     stale worktree, rebuild a fresh one at the new tip, re-dedup, re-commit,
#     re-push). Made deterministic (not timing-dependent, per "git ops must
#     be deterministic" in the verification bar) via a `git` shim on PATH
#     that injects machine B's push exactly once, the first time this run's
#     `git push ... HEAD:main` (the disposable-worktree push) is invoked —
#     i.e. exactly the window the real retry logic must handle.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_machine_a "2026-03-06T00:00:00Z" >"$PAPERCUT_SPOOL"

machine_b="$d/machine-b"
clone_ledger "$bare" "$machine_b"
machine_b_line="$(rec pc_machine_b "2026-03-05T00:00:00Z")"

real_git="$(command -v git)"
shim_dir="$d/git-shim"
mkdir -p "$shim_dir"
race_marker="$d/race_done"
cat >"$shim_dir/git" <<EOF
#!/usr/bin/env bash
has_push=0
has_target=0
for a in "\$@"; do
  [ "\$a" = "push" ] && has_push=1
  [ "\$a" = "HEAD:main" ] && has_target=1
done
if [ "\$has_push" = "1" ] && [ "\$has_target" = "1" ] && [ ! -f "$race_marker" ]; then
  : >"$race_marker"
  mkdir -p "$machine_b/ledger"
  printf '%s\n' '$machine_b_line' >"$machine_b/ledger/2026-03.jsonl"
  "$real_git" -C "$machine_b" add ledger/2026-03.jsonl >/dev/null
  "$real_git" -C "$machine_b" commit --quiet -m "chore: append 1 papercuts from machine-b" >/dev/null
  "$real_git" -C "$machine_b" push --quiet origin main >/dev/null 2>&1
fi
exec "$real_git" "\$@"
EOF
chmod +x "$shim_dir/git"

PATH="$shim_dir:$PATH" bash "$flush" --force
rc=$?
assert_eq "divergent remote: publish exits 0" "0" "$rc"
assert_true "divergent remote: the race actually fired" "$([ -f "$race_marker" ] && echo 1 || echo 0)"
remote_content="$(ledger_file_on_remote "$bare" "2026-03")"
count_a="$(printf '%s\n' "$remote_content" | grep -c pc_machine_a)"
count_b="$(printf '%s\n' "$remote_content" | grep -c pc_machine_b)"
assert_eq "divergent remote: machine A's record exactly once" "1" "$count_a"
assert_eq "divergent remote: machine B's record exactly once" "1" "$count_b"
only_main_wt="$(git -C "$clone" worktree list | wc -l | tr -d ' ')"
assert_eq "divergent remote: non-ff retry leaves no leftover worktree" "1" "$only_main_wt"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 17. dirty clone -> publish STILL succeeds via the disposable worktree,
#     and the clone's own worktree/HEAD/branch/dirt are left byte-for-byte
#     untouched (Fix A: we never mutate the user's checked-out worktree, so a
#     dirty tree can no longer be damaged by, or block, publishing).
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
echo "uncommitted local work" >"$clone/ledger/scratch.txt"
head_before="$(git -C "$clone" rev-parse HEAD)"
branch_before="$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
porcelain_before="$(git -C "$clone" status --porcelain)"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_dirty_1 "2026-04-05T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "dirty clone: publish succeeds via disposable worktree" "0" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "dirty clone: batch consumed" "0" "${#leftover[@]}"
assert_true "dirty clone: unrelated local work untouched" "$([ -f "$clone/ledger/scratch.txt" ] && echo 1 || echo 0)"
assert_eq "dirty clone: HEAD unchanged" "$head_before" "$(git -C "$clone" rev-parse HEAD)"
assert_eq "dirty clone: branch unchanged" "$branch_before" "$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
assert_eq "dirty clone: porcelain status unchanged" "$porcelain_before" "$(git -C "$clone" status --porcelain)"
remote_content="$(ledger_file_on_remote "$bare" "2026-04")"
assert_true "dirty clone: record published to remote" "$(printf '%s\n' "$remote_content" | grep -q pc_dirty_1 && echo 1 || echo 0)"
only_main_wt="$(git -C "$clone" worktree list | wc -l | tr -d ' ')"
assert_eq "dirty clone: no leftover worktrees" "1" "$only_main_wt"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 18. wrong branch / local unpushed commit -> publish STILL succeeds via
#     the disposable worktree; the clone is left on the same branch/commit.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
git -C "$clone" checkout --quiet -b some-other-branch
echo "local work" >"$clone/ledger/unpushed.txt"
git -C "$clone" add ledger/unpushed.txt
git -C "$clone" commit --quiet -m "local unpushed commit"
head_before="$(git -C "$clone" rev-parse HEAD)"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_branch_1 "2026-04-06T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "wrong branch: publish succeeds via disposable worktree" "0" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "wrong branch: batch consumed" "0" "${#leftover[@]}"
current_branch="$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
assert_eq "wrong branch: clone left on the same branch (untouched)" "some-other-branch" "$current_branch"
assert_eq "wrong branch: clone HEAD/local commit unchanged" "$head_before" "$(git -C "$clone" rev-parse HEAD)"
remote_content="$(ledger_file_on_remote "$bare" "2026-04")"
assert_true "wrong branch: record published to remote" "$(printf '%s\n' "$remote_content" | grep -q pc_branch_1 && echo 1 || echo 0)"
only_main_wt="$(git -C "$clone" worktree list | wc -l | tr -d ' ')"
assert_eq "wrong branch: no leftover worktrees" "1" "$only_main_wt"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 19. wrong remote -> untouched, publish returns non-zero, batch retained
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
other_bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$other_bare" "$clone" # clone's real origin is a DIFFERENT repo
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")" # trusted remote != clone's origin
rec pc_remote_mismatch_1 "2026-04-07T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "wrong remote: publish returns non-zero" "1" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "wrong remote: batch retained" "1" "${#leftover[@]}"
remote_content="$(ledger_file_on_remote "$bare" "2026-04")"
assert_true "wrong remote: expected remote untouched" "$([ -z "$remote_content" ] && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 19b. hostile lookalike origin, config names the repo, no remote_url ->
#     the anchored regex BUILT FROM ledger.host/ledger.repo must reject it
#     (Fix C: no substring bypass). A URL merely CONTAINING the configured
#     repo on a different host must not pass.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD PAPERCUT_LEDGER_REMOTE
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
git -C "$clone" remote set-url origin "https://evil.example/bestdan/papercuts-ledger.git"
export PAPERCUT_CONFIG="$(ledger_config_repo "bestdan/papercuts-ledger")"
export PAPERCUT_LEDGER_DIR="$clone"
rec pc_hostile_1 "2026-04-08T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "hostile lookalike origin: publish returns non-zero" "1" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "hostile lookalike origin: batch retained" "1" "${#leftover[@]}"
remote_content="$(ledger_file_on_remote "$bare" "2026-04")"
assert_true "hostile lookalike origin: real remote untouched" "$([ -z "$remote_content" ] && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 19d. TRUSTED fetch origin but a HOSTILE remote.origin.pushurl. `git push
#     origin` targets the pushurl, so a gate that validated only the fetch url
#     would let the push reach the hostile remote. The push-url check must
#     reject it: non-zero, batch retained, and NEITHER remote receives anything.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"          # trusted remote == the fetch origin
hostile_bare="$(make_bare_ledger)"  # where the hostile pushurl points
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
git -C "$clone" remote set-url --push origin "file://$hostile_bare"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")" # trusted, and == the fetch origin
rec pc_pushurl_1 "2026-04-10T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "hostile pushurl: publish returns non-zero" "1" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "hostile pushurl: batch retained" "1" "${#leftover[@]}"
assert_true "hostile pushurl: trusted remote untouched" "$([ -z "$(ledger_file_on_remote "$bare" "2026-04")" ] && echo 1 || echo 0)"
assert_true "hostile pushurl: hostile remote untouched" "$([ -z "$(ledger_file_on_remote "$hostile_bare" "2026-04")" ] && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 19c. a record with a missing/empty/non-string id in the group file ->
#     publish returns non-zero, the whole batch is retained (Fix B: fail
#     closed, never silently drop a line and report success).
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
{
  rec pc_id_ok "2026-04-09T00:00:00Z"
  printf '{"id":"","v":1,"producer":"test/1","ts":"2026-04-09T00:00:01Z","machine":"default","source":"manual","category":"harness_config","severity":"low","title":"t","description":"d","repo":"dotfiles"}\n'
} >"$PAPERCUT_SPOOL"
bash "$flush" --force
rc=$?
assert_eq "bad id in batch: publish returns non-zero" "1" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "bad id in batch: batch retained" "1" "${#leftover[@]}"
remote_content="$(ledger_file_on_remote "$bare" "2026-04")"
assert_true "bad id in batch: nothing published (fail-closed, not partial)" "$([ -z "$remote_content" ] && echo 1 || echo 0)"
only_main_wt="$(git -C "$clone" worktree list | wc -l | tr -d ' ')"
assert_eq "bad id in batch: no leftover worktree after a failed publish" "1" "$only_main_wt"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# =============================================================================
# 3b security: the origin allowlist is BUILT FROM config, and nothing
# env-settable can exempt a target from it. These are the assertions that
# prove the control survived the refactor — a happy-path test alone would not.
# =============================================================================

# --- 19e. attack-URL matrix: for a configured repo acme/papercuts, the
#     anchored allowlist must reject a lookalike host, a path-prefix attack,
#     a suffix attack, and an embedded-credentials URL. Each rejection must
#     come from the allowlist itself (the "untrusted" log line), retain the
#     batch, and touch no remote.
for attack_url in \
  "https://evil.example/acme/papercuts.git" \
  "https://github.com/acme/papercuts-evil.git" \
  "https://github.com/notacme/papercuts.git" \
  "https://user:token@github.com/acme/papercuts.git"; do
  d="$(new_env_dir)"
  eval "$(env_vars_for "$d")"
  unset PAPERCUT_PUBLISH_CMD
  bare="$(make_bare_ledger)"
  clone="$d/ledger-clone"
  clone_ledger "$bare" "$clone"
  git -C "$clone" remote set-url origin "$attack_url"
  export PAPERCUT_CONFIG="$(ledger_config_repo "acme/papercuts")"
  export PAPERCUT_LEDGER_DIR="$clone"
  rec pc_attack "2026-05-01T00:00:00Z" >"$PAPERCUT_SPOOL"
  bash "$flush" --force >/dev/null 2>&1
  rc=$?
  assert_eq "allowlist rejects $attack_url" "1" "$rc"
  shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
  assert_eq "allowlist reject retains the batch ($attack_url)" "1" "${#leftover[@]}"
  assert_true "reject came from the allowlist, not a later step ($attack_url)" \
    "$(grep -q 'untrusted origin fetch url' "$PAPERCUT_LOG" && echo 1 || echo 0)"
  unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG
done

# --- 19f. positive control for the regex forms: an origin that matches the
#     config-derived https://<host>/<repo>(.git) form must PASS the allowlist
#     (the run then fails later, at fetch — host "ledger.invalid" is an
#     RFC 2606 reserved TLD that never resolves, so no real host is touched).
#     Without this, every 19e rejection would also pass with an allowlist
#     that rejects everything.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
git -C "$clone" remote set-url origin "https://ledger.invalid/acme/papercuts.git"
export PAPERCUT_CONFIG="$(ledger_config_repo "acme/papercuts" "ledger.invalid")"
export PAPERCUT_LEDGER_DIR="$clone"
rec pc_regex_pass "2026-05-02T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force >/dev/null 2>&1
assert_true "config-derived regex form: origin passes the allowlist" \
  "$(grep -q 'untrusted origin' "$PAPERCUT_LOG" && echo 0 || echo 1)"
assert_true "config-derived regex form: run proceeded to the fetch" \
  "$(grep -q 'publish: fetch failed' "$PAPERCUT_LOG" && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 19g. regex metacharacters in ledger.repo are escaped, not interpreted:
#     with repo "acme/papercuts.x", an origin "acme/papercutsZx" must be
#     REJECTED by the allowlist — an unescaped "." would match it (and the
#     run would then show up at the fetch step instead, which the assertion
#     on the "untrusted" line distinguishes deterministically).
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
git -C "$clone" remote set-url origin "https://ledger.invalid/acme/papercutsZx.git"
export PAPERCUT_CONFIG="$(ledger_config_repo "acme/papercuts.x" "ledger.invalid")"
export PAPERCUT_LEDGER_DIR="$clone"
rec pc_regex_meta "2026-05-03T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force >/dev/null 2>&1
rc=$?
assert_eq "regex metachars in ledger.repo: lookalike rejected" "1" "$rc"
assert_true "regex metachars in ledger.repo: rejected BY the allowlist (escaped, not interpreted)" \
  "$(grep -q 'untrusted origin fetch url' "$PAPERCUT_LOG" && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# --- 19h. the exact-equality bypass is GONE: PAPERCUT_LEDGER_REMOTE set to a
#     URL that fails the config-derived allowlist is rejected even though the
#     origin equals it exactly — the equality that used to grant trust.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
git -C "$clone" remote set-url origin "https://evil.example/acme/papercuts.git"
export PAPERCUT_CONFIG="$(ledger_config_repo "acme/papercuts")"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_LEDGER_REMOTE="https://evil.example/acme/papercuts.git"
rec pc_bypass_gone "2026-05-04T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force >/dev/null 2>&1
rc=$?
assert_eq "env override matching a hostile origin exactly: still rejected" "1" "$rc"
assert_true "env override grants no trust: allowlist logged the refusal" \
  "$(grep -q 'untrusted origin fetch url' "$PAPERCUT_LOG" && echo 1 || echo 0)"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "env override grants no trust: batch retained" "1" "${#leftover[@]}"
unset PAPERCUT_LEDGER_DIR PAPERCUT_LEDGER_REMOTE PAPERCUT_CONFIG

# --- 19i. a LEGITIMATE PAPERCUT_LEDGER_REMOTE override — one the config's
#     allowlist accepts — still works as a value override: with no clone on
#     disk it selects what to clone, and the resulting origin passes the
#     config's remote_url trust anchor, so the publish completes end-to-end.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
export PAPERCUT_LEDGER_DIR="$d/fresh-clone"
export PAPERCUT_LEDGER_REMOTE="file://$bare"
rec pc_env_legit "2026-05-05T00:00:00Z" >"$PAPERCUT_SPOOL"
# The clone is created by the flusher itself here, so unlike the
# clone_ledger fixtures nothing set a local committer identity, and the
# prelude pins global git config to /dev/null — supply the ident via env.
GIT_AUTHOR_NAME="Test Machine" GIT_AUTHOR_EMAIL="test@example.com" \
  GIT_COMMITTER_NAME="Test Machine" GIT_COMMITTER_EMAIL="test@example.com" \
  bash "$flush" --force >/dev/null 2>&1
rc=$?
assert_eq "legitimate env override (matches allowlist): publishes, exits 0" "0" "$rc"
remote_content="$(ledger_file_on_remote "$bare" "2026-05")"
assert_true "legitimate env override: record landed on remote" \
  "$(printf '%s\n' "$remote_content" | grep -q pc_env_legit && echo 1 || echo 0)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_LEDGER_REMOTE PAPERCUT_CONFIG

# --- 19j. the config-vs-env distinction is real: the SAME file:// URL is
#     accepted when config's ledger.remote_url names it, and rejected when it
#     arrives through PAPERCUT_LEDGER_REMOTE alone (config resolves identity
#     via ledger.repo but trusts nothing matching a file:// URL).
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
rec pc_cfg_vs_env_a "2026-05-06T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force >/dev/null 2>&1
rc=$?
assert_eq "config remote_url trusts the URL: publishes" "0" "$rc"
export PAPERCUT_CONFIG="$(ledger_config_repo "acme/papercuts")"
export PAPERCUT_LEDGER_REMOTE="file://$bare"
rec pc_cfg_vs_env_b "2026-05-07T00:00:00Z" >"$PAPERCUT_SPOOL"
bash "$flush" --force >/dev/null 2>&1
rc=$?
assert_eq "same URL via env alone: rejected" "1" "$rc"
remote_content="$(ledger_file_on_remote "$bare" "2026-05")"
assert_true "same URL via env alone: nothing published" \
  "$(printf '%s\n' "$remote_content" | grep -q pc_cfg_vs_env_b && echo 0 || echo 1)"
unset PAPERCUT_LEDGER_DIR PAPERCUT_LEDGER_REMOTE PAPERCUT_CONFIG

# --- 19k. missing config + default publisher, invoked directly: exits
#     non-zero WITHOUT claiming the spool and without publishing — keyed on
#     the resolver's ledger-missing status line (the resolver itself exits 0
#     on an absent config), never a publish to a guessed default.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD PAPERCUT_CONFIG
rec pc_no_config "2026-05-08T00:00:00Z" >"$PAPERCUT_SPOOL"
err_out="$(bash "$flush" --force 2>&1 >/dev/null)"
rc=$?
assert_true "missing config: exits non-zero" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_true "missing config: spool NOT claimed" "$([ -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "missing config: no batch created" "0" "${#leftover[@]}"
assert_true "missing config: message names the unresolved ledger identity" \
  "$(printf '%s' "$err_out" | grep -q 'ledger identity unresolved' && echo 1 || echo 0)"
assert_true "missing config: hold reason logged" \
  "$(grep -q 'hold reason=ledger-identity-unresolved' "$PAPERCUT_LOG" && echo 1 || echo 0)"

# --- 19l. unparseable config + default publisher: the resolver's hard error
#     is a hard error here too — non-zero, nothing claimed.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
broken_cfg="$(next_dir)/config.toml"
printf '[ledger\nrepo = "acme/papercuts"\n' >"$broken_cfg"
export PAPERCUT_CONFIG="$broken_cfg"
rec pc_broken_config "2026-05-09T00:00:00Z" >"$PAPERCUT_SPOOL"
err_out="$(bash "$flush" --force 2>&1 >/dev/null)"
rc=$?
assert_true "unparseable config: exits non-zero" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_true "unparseable config: spool NOT claimed" "$([ -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
assert_true "unparseable config: message says config resolution failed" \
  "$(printf '%s' "$err_out" | grep -q 'config resolution failed' && echo 1 || echo 0)"
unset PAPERCUT_CONFIG

# --- 19m. the GATE still appends with no config present — a team may want
#     local-only capture before they set up a ledger. Same runpy hostname
#     patch as test 20 (the gate derives its profile from the real hostname).
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_CONFIG
gate="$here/papercut_append.py"
printf '%s' '{"category":"harness_config","severity":"low","title":"no-config append","description":"d"}' \
  | PAPERCUT_SPOOL="$PAPERCUT_SPOOL" PAPERCUT_LOCK="$PAPERCUT_LOCK" python3 -c '
import runpy, socket, sys
socket.gethostname = lambda: "some-laptop"
gate = sys.argv[1]
sys.argv = ["papercut_append.py"] + sys.argv[2:]
runpy.run_path(gate, run_name="__main__")
' "$gate" --source manual --producer test/no-config --repo dotfiles
gate_rc=$?
assert_eq "gate with no config: append accepted" "0" "$gate_rc"
assert_true "gate with no config: record landed in the spool" \
  "$(grep -q 'no-config append' "$PAPERCUT_SPOOL" && echo 1 || echo 0)"

# --- 20. end-to-end: papercut_append.py -> spool -> flush -> bare remote, --
#     byte-identical to what the gate appended.
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
unset PAPERCUT_PUBLISH_CMD
bare="$(make_bare_ledger)"
clone="$d/ledger-clone"
clone_ledger "$bare" "$clone"
export PAPERCUT_LEDGER_DIR="$clone"
export PAPERCUT_CONFIG="$(ledger_config "file://$bare")"
gate="$here/papercut_append.py"
# The gate derives its profile ONLY from the real hostname (no env override, by
# design — see papercut_append.py's detect_machine). To drive the default
# profile on any host (incl. a real NYC-BETTERMENT* laptop), invoke it via
# runpy with socket.gethostname monkeypatched in-process — the same mechanism
# papercut_append.test.sh uses. Production calls the gate directly with no patch.
printf '%s' '{"category":"harness_config","severity":"low","title":"e2e title","description":"e2e description"}' \
  | PAPERCUT_SPOOL="$PAPERCUT_SPOOL" PAPERCUT_LOCK="$PAPERCUT_LOCK" python3 -c '
import runpy, socket, sys
socket.gethostname = lambda: "some-laptop"
gate = sys.argv[1]
sys.argv = ["papercut_append.py"] + sys.argv[2:]
runpy.run_path(gate, run_name="__main__")
' "$gate" --source manual --producer test/e2e --repo dotfiles
gate_rc=$?
assert_eq "e2e append->flush: gate accepted the record" "0" "$gate_rc"
appended_line="$(tail -n1 "$PAPERCUT_SPOOL")"
assert_true "e2e append->flush: a record was actually appended" "$([ -n "$appended_line" ] && echo 1 || echo 0)"
bash "$flush" --force
rc=$?
assert_eq "e2e append->flush: exits 0" "0" "$rc"
rec_id="$(printf '%s' "$appended_line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
rec_month="$(printf '%s' "$appended_line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ts"][:7])')"
remote_content="$(ledger_file_on_remote "$bare" "$rec_month")"
assert_true "e2e: record landed on remote" "$(printf '%s\n' "$remote_content" | grep -qF "$rec_id" && echo 1 || echo 0)"
remote_line="$(printf '%s\n' "$remote_content" | grep -F "$rec_id")"
assert_eq "e2e: record byte-identical to what the gate appended" "$appended_line" "$remote_line"
unset PAPERCUT_LEDGER_DIR PAPERCUT_CONFIG

# =============================================================================
# 21. betterment profile + normal run (no --force), non-empty spool -> HOLDS:
#     nothing published, spool untouched, exit 0, a hold line in the log.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
rec pc_hold_1 "2026-12-01T00:00:00Z" >"$PAPERCUT_SPOOL"
work_shim="$(hostname_shim_dir "NYC-BETTERMENT01487")"
PATH="$work_shim:$PATH" bash "$flush"
rc=$?
assert_eq "betterment no-force: holds, exits 0" "0" "$rc"
assert_true "betterment no-force: spool untouched" "$([ -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
assert_true "betterment no-force: nothing published" "$([ ! -s "$PAPERCUT_TEST_LEDGER" ] && echo 1 || echo 0)"
assert_true "betterment no-force: no success stamp written" "$([ ! -f "$PAPERCUT_FLUSH_OK" ] && echo 1 || echo 0)"
assert_true "betterment no-force: hold line logged" "$(grep -q 'hold reason=work-host-review' "$PAPERCUT_LOG" && echo 1 || echo 0)"

# =============================================================================
# 22. betterment profile + --force, non-empty spool -> publishes (bypasses
#     the hold), spool consumed.
# =============================================================================
PATH="$work_shim:$PATH" bash "$flush" --force
rc=$?
assert_eq "betterment --force: publishes, exits 0" "0" "$rc"
assert_true "betterment --force: spool consumed" "$([ ! -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
assert_true "betterment --force: record published" "$(grep -qx pc_hold_1 "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 23. default profile + normal run -> UNCHANGED: still publishes/consumes
#     (no regression from the hold gate).
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
rec pc_default_normal "2026-12-02T00:00:00Z" >"$PAPERCUT_SPOOL"
default_shim="$(hostname_shim_dir "some-laptop")"
PATH="$default_shim:$PATH" bash "$flush"
rc=$?
assert_eq "default profile no-force: unchanged, exits 0" "0" "$rc"
assert_true "default profile no-force: spool consumed" "$([ ! -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
assert_true "default profile no-force: record published" "$(grep -qx pc_default_normal "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 24. --review with a non-empty spool: prints the record(s), does NOT
#     publish, does NOT consume the spool, does NOT write stamps.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
rec pc_review_1 "2026-12-03T00:00:00Z" >"$PAPERCUT_SPOOL"
review_out="$(PATH="$work_shim:$PATH" bash "$flush" --review)"
rc=$?
assert_eq "--review: exits 0" "0" "$rc"
assert_true "--review: prints the pending record" "$(printf '%s' "$review_out" | grep -q pc_review_1 && echo 1 || echo 0)"
assert_true "--review: spool untouched" "$([ -s "$PAPERCUT_SPOOL" ] && echo 1 || echo 0)"
assert_true "--review: nothing published" "$([ ! -s "$PAPERCUT_TEST_LEDGER" ] && echo 1 || echo 0)"
assert_true "--review: no success stamp written" "$([ ! -f "$PAPERCUT_FLUSH_OK" ] && echo 1 || echo 0)"
assert_true "--review: no failure stamp written" "$([ ! -f "$PAPERCUT_FLUSH_FAIL" ] && echo 1 || echo 0)"

# =============================================================================
# 25. --review with an empty spool: "nothing pending" message, exit 0.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
review_empty_out="$(bash "$flush" --review)"
rc=$?
assert_eq "--review empty: exits 0" "0" "$rc"
assert_true "--review empty: reports nothing pending" "$(printf '%s' "$review_empty_out" | grep -qi 'nothing pending' && echo 1 || echo 0)"

# =============================================================================
# 26. betterment profile + normal run (no --force), a STRAY spool.batch.* with
#     no live spool content -> still HOLDS (the hold gate must block stray-
#     batch publishing too, not just a fresh spool). --force then publishes it.
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$PAPERCUT_BATCH_DIR"
rec pc_stray_hold "2026-12-04T00:00:00Z" >"$PAPERCUT_BATCH_DIR/spool.batch.20261201T000000Z.1.deadbeef.jsonl"
work_shim2="$(hostname_shim_dir "NYC-BETTERMENT01487")"
PATH="$work_shim2:$PATH" bash "$flush"
rc=$?
assert_eq "betterment no-force, stray batch only: holds, exits 0" "0" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "betterment no-force, stray batch: batch untouched" "1" "${#leftover[@]}"
assert_true "betterment no-force, stray batch: nothing published" "$([ ! -s "$PAPERCUT_TEST_LEDGER" ] && echo 1 || echo 0)"
assert_true "betterment no-force, stray batch: hold line logged" "$(grep -q 'hold reason=work-host-review' "$PAPERCUT_LOG" && echo 1 || echo 0)"
PATH="$work_shim2:$PATH" bash "$flush" --force
rc=$?
assert_eq "betterment --force, stray batch: publishes, exits 0" "0" "$rc"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "betterment --force, stray batch: batch consumed" "0" "${#leftover[@]}"
assert_true "betterment --force, stray batch: record published" "$(grep -qx pc_stray_hold "$PAPERCUT_TEST_LEDGER" && echo 1 || echo 0)"

# =============================================================================
# 27. --review is a true no-op on the FULL artifact set: a live spool, a stray
#     batch, and pre-existing stamp files must all be byte-identical after
#     --review runs (no claim, no publish, no stamp write, no batch mutation).
# =============================================================================
d="$(new_env_dir)"
eval "$(env_vars_for "$d")"
export PAPERCUT_PUBLISH_CMD="$stub_publish"
export PAPERCUT_TEST_LEDGER="$d/ledger.txt"
: >"$PAPERCUT_TEST_LEDGER"
mkdir -p "$PAPERCUT_BATCH_DIR" "$(dirname "$PAPERCUT_FLUSH_OK")"
rec pc_review_live "2026-12-05T00:00:00Z" >"$PAPERCUT_SPOOL"
rec pc_review_stray "2026-12-05T00:00:01Z" >"$PAPERCUT_BATCH_DIR/spool.batch.20261202T000000Z.2.cafef00d.jsonl"
: >"$PAPERCUT_FLUSH_OK" # pre-existing stamp, must survive untouched
spool_before="$(cat "$PAPERCUT_SPOOL")"
stray_before="$(cat "$PAPERCUT_BATCH_DIR/spool.batch.20261202T000000Z.2.cafef00d.jsonl")"
ok_mtime_before=$(stat -c %Y "$PAPERCUT_FLUSH_OK" 2>/dev/null || stat -f %m "$PAPERCUT_FLUSH_OK" 2>/dev/null)
review_full_out="$(PATH="$work_shim2:$PATH" bash "$flush" --review)"
rc=$?
assert_eq "--review full set: exits 0" "0" "$rc"
assert_true "--review full set: prints the live-spool record" "$(printf '%s' "$review_full_out" | grep -q pc_review_live && echo 1 || echo 0)"
assert_true "--review full set: prints the stray-batch record" "$(printf '%s' "$review_full_out" | grep -q pc_review_stray && echo 1 || echo 0)"
assert_eq "--review full set: spool byte-identical" "$spool_before" "$(cat "$PAPERCUT_SPOOL")"
assert_eq "--review full set: stray batch byte-identical" "$stray_before" "$(cat "$PAPERCUT_BATCH_DIR/spool.batch.20261202T000000Z.2.cafef00d.jsonl")"
shopt -s nullglob; leftover=("$PAPERCUT_BATCH_DIR"/spool.batch.*); shopt -u nullglob
assert_eq "--review full set: stray batch still present (not consumed)" "1" "${#leftover[@]}"
ok_mtime_after=$(stat -c %Y "$PAPERCUT_FLUSH_OK" 2>/dev/null || stat -f %m "$PAPERCUT_FLUSH_OK" 2>/dev/null)
assert_eq "--review full set: pre-existing success stamp mtime untouched" "$ok_mtime_before" "$ok_mtime_after"
assert_true "--review full set: no failure stamp written" "$([ ! -f "$PAPERCUT_FLUSH_FAIL" ] && echo 1 || echo 0)"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME TESTS FAILED"
fi
exit "$fail"
