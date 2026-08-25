#!/usr/bin/env bash
# Tests for papercut-resolve.sh — the manual CLI that marks a papercut
# resolved by appending a resolution record via papercut_append.py.
# Run:
#   bash tests/papercut-resolve.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
resolver="$script_dir/papercut-resolve.sh"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# The gate derives its profile from the REAL hostname, so on an NYC-BETTERMENT*
# work host it would require a hand-populated denylist this suite has no
# business depending on. Route every gate call through a wrapper that forces
# socket.gethostname to a non-work host (same pattern as
# papercut-capture.test.sh / papercut-sweep.test.sh).
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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s: expected to find %q in %q)\n' "$desc" "$needle" "$haystack"
    fail=1
  fi
}

get_field() {
  local json="$1" field="$2"
  printf '%s' "$json" | python3 -c "import json, sys; print(json.loads(sys.stdin.read()).get('$field', ''))"
}

known_id="pc_00000000-0000-4000-8000-000000000001"
unknown_id="pc_00000000-0000-4000-8000-0000000000ff"

# Seed a temp ledger clone with one papercut and an empty spool.
seed_ledger() {
  local d="$1"
  mkdir -p "$d/ledger"
  cat >"$d/ledger/2026-01.jsonl" <<EOF
{"category":"harness_config","description":"d","id":"$known_id","machine":"default","producer":"p","repo":"dotfiles","severity":"low","source":"manual","title":"t","ts":"2026-01-01T00:00:00Z","type":"papercut","v":1}
EOF
}

run_resolver() {
  local ledger_dir="$1" spool_dir="$2"
  shift 2
  PAPERCUT_LEDGER_DIR="$ledger_dir" PAPERCUT_SPOOL="$spool_dir/spool.jsonl" PAPERCUT_LOCK="$spool_dir/.spool.lock" \
    PAPERCUT_APPEND_CMD="$append_default_host" \
    "$resolver" "$@"
}

# --- 1. happy path: known id (in ledger), no fix_url ---
d="$(next_dir)"
ledger_d="$(next_dir)"
seed_ledger "$ledger_d"
out="$(run_resolver "$ledger_d" "$d" "$known_id" fixed)"
rc=$?
assert_eq "happy path exits 0" "0" "$rc"
rtype="$(get_field "$out" type)"
resolves="$(get_field "$out" resolves)"
status="$(get_field "$out" status)"
producer="$(get_field "$out" producer)"
assert_eq "happy path: type=resolution" "resolution" "$rtype"
assert_eq "happy path: resolves matches target id" "$known_id" "$resolves"
assert_eq "happy path: status set" "fixed" "$status"
assert_eq "happy path: producer=resolve-cli/1" "resolve-cli/1" "$producer"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "happy path: spool has exactly one line" "1" "$lines"

# --- 2. happy path with fix_url ---
d="$(next_dir)"
out="$(run_resolver "$ledger_d" "$d" "$known_id" mitigated "https://github.com/x/y/commit/abc123")"
rc=$?
assert_eq "happy path with fix_url exits 0" "0" "$rc"
fix_url="$(get_field "$out" fix_url)"
assert_eq "happy path: fix_url set" "https://github.com/x/y/commit/abc123" "$fix_url"

# --- 2b. out-of-scope status is accepted, with a tracker link as fix_url ---
d="$(next_dir)"
out="$(run_resolver "$ledger_d" "$d" "$known_id" out-of-scope "https://linear.app/prethinkio/issue/PRE-647")"
rc=$?
assert_eq "out-of-scope exits 0" "0" "$rc"
status="$(get_field "$out" status)"
assert_eq "out-of-scope: status set" "out-of-scope" "$status"
fix_url="$(get_field "$out" fix_url)"
assert_eq "out-of-scope: tracker link kept as fix_url" "https://linear.app/prethinkio/issue/PRE-647" "$fix_url"

# --- 3. known id found via the local spool instead of the ledger ---
d="$(next_dir)"
empty_ledger="$(next_dir)"
cat >"$d/spool.jsonl" <<EOF
{"category":"harness_config","description":"d","id":"$known_id","machine":"default","producer":"p","repo":"dotfiles","severity":"low","source":"manual","title":"t","ts":"2026-01-01T00:00:00Z","type":"papercut","v":1}
EOF
out="$(run_resolver "$empty_ledger" "$d" "$known_id" fixed)"
rc=$?
assert_eq "id found via spool: exits 0" "0" "$rc"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "id found via spool: spool gains the resolution line (now 2)" "2" "$lines"

# --- 4. unknown id fails without --force ---
d="$(next_dir)"
run_resolver "$ledger_d" "$d" "$unknown_id" fixed >"$workdir"/unknown_out 2>"$workdir"/unknown_err
rc=$?
assert_eq "unknown id without --force exits 1" "1" "$rc"
assert_contains "unknown id error message mentions --force" "$(cat "$workdir"/unknown_err)" "--force"
assert_true "unknown id without --force appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 5. unknown id succeeds with --force ---
d="$(next_dir)"
out="$(run_resolver "$ledger_d" "$d" "$unknown_id" fixed --force)"
rc=$?
assert_eq "unknown id with --force exits 0" "0" "$rc"
resolves="$(get_field "$out" resolves)"
assert_eq "unknown id with --force: resolves matches target id" "$unknown_id" "$resolves"

# --- 5b. a resolution record's id does NOT satisfy the existence check
#     (only a papercut id counts; resolving a resolution id would orphan) ---
d="$(next_dir)"
resolution_ledger="$(next_dir)"
mkdir -p "$resolution_ledger/ledger"
resolution_id="pc_00000000-0000-4000-8000-0000000000aa"
cat >"$resolution_ledger/ledger/2026-01.jsonl" <<EOF
{"fix_url":"https://github.com/x/y/commit/abc123","id":"$resolution_id","machine":"default","producer":"resolve-cli/1","resolves":"$known_id","source":"manual","status":"fixed","type":"resolution","v":1}
EOF
run_resolver "$resolution_ledger" "$d" "$resolution_id" fixed >"$workdir"/reso_out 2>"$workdir"/reso_err
rc=$?
assert_eq "resolution id fails existence check (not a papercut) without --force" "1" "$rc"
assert_contains "resolution id error mentions --force" "$(cat "$workdir"/reso_err)" "--force"
assert_true "resolution id appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 5c. already-resolved id fails without --force (dedup) ---
d="$(next_dir)"
resolved_ledger="$(next_dir)"
mkdir -p "$resolved_ledger/ledger"
prior_resolution_id="pc_00000000-0000-4000-8000-0000000000bb"
cat >"$resolved_ledger/ledger/2026-01.jsonl" <<EOF
{"category":"harness_config","description":"d","id":"$known_id","machine":"default","producer":"p","repo":"dotfiles","severity":"low","source":"manual","title":"t","ts":"2026-01-01T00:00:00Z","type":"papercut","v":1}
{"fix_url":"https://github.com/x/y/commit/abc123","id":"$prior_resolution_id","machine":"default","producer":"resolve-cli/1","resolves":"$known_id","source":"manual","status":"mitigated","type":"resolution","v":1}
EOF
run_resolver "$resolved_ledger" "$d" "$known_id" fixed >"$workdir"/dup_out 2>"$workdir"/dup_err
rc=$?
assert_eq "already-resolved id without --force exits 1" "1" "$rc"
assert_contains "already-resolved error mentions prior status" "$(cat "$workdir"/dup_err)" "mitigated"
assert_contains "already-resolved error mentions --force" "$(cat "$workdir"/dup_err)" "--force"
assert_true "already-resolved id without --force appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 5d. already-resolved id succeeds with --force (intentional re-resolve) ---
d="$(next_dir)"
out="$(run_resolver "$resolved_ledger" "$d" "$known_id" fixed --force)"
rc=$?
assert_eq "already-resolved id with --force exits 0" "0" "$rc"
resolves="$(get_field "$out" resolves)"
assert_eq "already-resolved id with --force: resolves matches target id" "$known_id" "$resolves"

# --- 6. bad status fails ---
d="$(next_dir)"
run_resolver "$ledger_d" "$d" "$known_id" not-a-status >"$workdir"/badstatus_out 2>"$workdir"/badstatus_err
rc=$?
assert_eq "bad status exits 1 (usage error, before append)" "1" "$rc"
assert_true "bad status appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 6b. reported-upstream / out-of-scope require a fix_url ---
for bare_status in reported-upstream out-of-scope; do
  d="$(next_dir)"
  run_resolver "$ledger_d" "$d" "$known_id" "$bare_status" >"$workdir"/bare_out 2>"$workdir"/bare_err
  rc=$?
  assert_eq "$bare_status without fix_url exits 1" "1" "$rc"
  assert_contains "$bare_status error explains the requirement" "$(cat "$workdir"/bare_err)" "requires a fix_url"
  assert_true "$bare_status without fix_url appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"
done

# --- 6c. --force does not waive the citation requirement (it skips lookups, not validation) ---
d="$(next_dir)"
run_resolver "$ledger_d" "$d" "$known_id" out-of-scope --force >"$workdir"/bf_out 2>"$workdir"/bf_err
rc=$?
assert_eq "out-of-scope --force without fix_url still exits 1" "1" "$rc"
assert_true "out-of-scope --force without fix_url appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 6d. statuses that make no claim about elsewhere still work bare ---
for bare_ok in fixed mitigated wontfix; do
  d="$(next_dir)"
  out="$(run_resolver "$ledger_d" "$d" "$known_id" "$bare_ok")"
  rc=$?
  assert_eq "$bare_ok without fix_url exits 0" "0" "$rc"
done

# --- 7. bad pc_id format fails ---
d="$(next_dir)"
run_resolver "$ledger_d" "$d" "not-a-pc-id" fixed >"$workdir"/badid_out 2>"$workdir"/badid_err
rc=$?
assert_eq "bad pc_id format exits 1" "1" "$rc"
assert_true "bad pc_id format appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 8. bad fix_url fails ---
d="$(next_dir)"
run_resolver "$ledger_d" "$d" "$known_id" fixed "not-a-url" >"$workdir"/badurl_out 2>"$workdir"/badurl_err
rc=$?
assert_eq "bad fix_url exits 1" "1" "$rc"
assert_true "bad fix_url appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- 9. wrong number of args fails ---
d="$(next_dir)"
run_resolver "$ledger_d" "$d" "$known_id" >"$workdir"/noargs_out 2>"$workdir"/noargs_err
rc=$?
assert_eq "missing status arg exits 1" "1" "$rc"

exit $fail
