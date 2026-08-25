#!/usr/bin/env bash
# Tests for papercut_open.py — the read-only open/resolved fold view over
# the ledger clone + local spool.
# Run:
#   bash tests/papercut_open.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

viewer="$(dirname "$0")/../scripts/papercut_open.py"
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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s: expected to find %q in %q)\n' "$desc" "$needle" "$haystack"
    fail=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf 'FAIL (%s: did not expect to find %q in %q)\n' "$desc" "$needle" "$haystack"
    fail=1
  else
    printf 'ok   (%s)\n' "$desc"
  fi
}

# ids, used across fixture + assertions
id_high_open="pc_00000000-0000-4000-8000-000000000001"     # open, high
id_med_resolved="pc_00000000-0000-4000-8000-000000000002"  # resolved, medium
id_low_open="pc_00000000-0000-4000-8000-000000000003"      # open, low
id_grandfathered="pc_00000000-0000-4000-8000-000000000004" # open, no `type` field (legacy row)
id_spool_open="pc_00000000-0000-4000-8000-000000000005"    # open, from spool not ledger
res_id="pc_00000000-0000-4000-8000-0000000000f1"

# --- fixture: mixed ledger (2 months) + spool with a mix of open/resolved/
# grandfathered records + a spool-only resolution ---
d="$(next_dir)"
mkdir -p "$d/ledger"
cat >"$d/ledger/2026-01.jsonl" <<EOF
{"category":"harness_config","description":"d1","id":"$id_high_open","machine":"default","producer":"p","repo":"dotfiles","severity":"high","source":"manual","title":"high open one","ts":"2026-01-01T00:00:00Z","type":"papercut","v":1}
{"category":"harness_config","description":"d2","id":"$id_med_resolved","machine":"default","producer":"p","repo":"dotfiles","severity":"medium","source":"manual","title":"medium resolved one","ts":"2026-01-02T00:00:00Z","type":"papercut","v":1}
{"category":"harness_config","description":"d3","id":"$id_low_open","machine":"default","producer":"p","repo":"dotfiles","severity":"low","source":"manual","title":"low open one","ts":"2026-01-03T00:00:00Z","type":"papercut","v":1}
EOF
cat >"$d/ledger/2026-02.jsonl" <<EOF
{"category":"harness_config","description":"d4","id":"$id_grandfathered","machine":"strict","producer":"p","severity":"low","source":"manual","title":"grandfathered legacy row","ts":"2026-02-01T00:00:00Z","v":1}
{"id":"$res_id","machine":"default","producer":"resolve-cli/1","resolves":"$id_med_resolved","source":"manual","status":"fixed","fix_url":"https://x/y/commit/abc","ts":"2026-02-02T00:00:00Z","type":"resolution","v":1}
EOF
cat >"$d/spool.jsonl" <<EOF
{"category":"model_behavior","description":"d5","id":"$id_spool_open","machine":"default","producer":"p","repo":"dotfiles","severity":"medium","source":"manual","title":"spool open one","ts":"2026-02-03T00:00:00Z","type":"papercut","v":1}
EOF

run_open() {
  PAPERCUT_LEDGER_DIR="$d" PAPERCUT_SPOOL="$d/spool.jsonl" python3 "$viewer" "$@"
}

# --- 1. default: open, grouped by severity ---
out="$(run_open)"
rc=$?
assert_eq "default view exits 0" "0" "$rc"
assert_contains "default view: high-severity open title present" "$out" "high open one"
assert_contains "default view: low-severity open title present" "$out" "low open one"
assert_contains "default view: grandfathered row is open (no type)" "$out" "grandfathered legacy row"
assert_contains "default view: spool-only open row present" "$out" "spool open one"
assert_not_contains "default view: resolved row absent" "$out" "medium resolved one"
assert_contains "default view: total count line" "$out" "4 open papercut(s)"

# ordering: severity groups appear high, then medium, then low regardless
# of ts (the spool row is severity medium) — check the group headers come
# out in that order below.
high_idx="$(printf '%s\n' "$out" | grep -n '^-- high' | head -1 | cut -d: -f1)"
medium_idx="$(printf '%s\n' "$out" | grep -n '^-- medium' | head -1 | cut -d: -f1)"
low_idx="$(printf '%s\n' "$out" | grep -n '^-- low' | head -1 | cut -d: -f1)"
if [ -n "$high_idx" ] && [ -n "$medium_idx" ] && [ -n "$low_idx" ] \
  && [ "$high_idx" -lt "$medium_idx" ] && [ "$medium_idx" -lt "$low_idx" ]; then
  printf 'ok   (default view: severity groups ordered high, medium, low)\n'
else
  printf 'FAIL (default view: severity group ordering wrong: high=%s medium=%s low=%s)\n' "$high_idx" "$medium_idx" "$low_idx"
  fail=1
fi

# --- 2. --resolved: shows resolved papercuts + resolution status/fix_url ---
out="$(run_open --resolved)"
rc=$?
assert_eq "--resolved view exits 0" "0" "$rc"
assert_contains "--resolved view: resolved title present" "$out" "medium resolved one"
assert_contains "--resolved view: status present" "$out" "fixed"
assert_contains "--resolved view: fix_url present" "$out" "https://x/y/commit/abc"
assert_not_contains "--resolved view: open row absent" "$out" "high open one"
assert_contains "--resolved view: total count line" "$out" "1 resolved papercut(s)"

# --- 3. --json: JSONL of open records only, well-formed ---
out="$(run_open --json)"
rc=$?
assert_eq "--json view exits 0" "0" "$rc"
json_lines="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "--json view: 4 open records emitted" "4" "$json_lines"
well_formed=0
open_ids=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if id="$(printf '%s' "$line" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["id"])' 2>/dev/null)"; then
    well_formed=$((well_formed + 1))
    open_ids="$open_ids $id"
  fi
done <<<"$out"
assert_eq "--json view: every line is well-formed JSON" "4" "$well_formed"
assert_contains "--json view: contains high-open id" "$open_ids" "$id_high_open"
assert_contains "--json view: contains low-open id" "$open_ids" "$id_low_open"
assert_contains "--json view: contains grandfathered id" "$open_ids" "$id_grandfathered"
assert_contains "--json view: contains spool-open id" "$open_ids" "$id_spool_open"
assert_not_contains "--json view: excludes resolved id" "$open_ids" "$id_med_resolved"

# --- 4. missing ledger clone: tolerated with a clear stderr message, spool
# records (if any) still shown ---
missing_dir="$(next_dir)/does-not-exist"
out="$(PAPERCUT_LEDGER_DIR="$missing_dir" PAPERCUT_SPOOL="$d/spool.jsonl" python3 "$viewer" 2>"$workdir"/missing_ledger_err)"
rc=$?
assert_eq "missing ledger clone: still exits 0" "0" "$rc"
assert_contains "missing ledger clone: stderr note present" "$(cat "$workdir"/missing_ledger_err)" "no ledger files found"
assert_contains "missing ledger clone: spool row still shown" "$out" "spool open one"

# --- 5. forward tolerance: unknown extra field ignored, unknown `type`
# skipped — neither errors (the reader contract in schema/v1.json) ---
tol_dir="$(next_dir)"
mkdir -p "$tol_dir/ledger"
id_extra_field="pc_00000000-0000-4000-8000-000000000006"
id_unknown_type="pc_00000000-0000-4000-8000-000000000007"
cat >"$tol_dir/ledger/2026-03.jsonl" <<EOF
{"category":"harness_config","description":"d6","future_field":{"nested":true},"id":"$id_extra_field","machine":"default","producer":"p","repo":"dotfiles","severity":"low","source":"manual","title":"extra field row","ts":"2026-03-01T00:00:00Z","type":"papercut","v":1}
{"id":"$id_unknown_type","machine":"default","producer":"p","source":"manual","title":"unknown type row","ts":"2026-03-02T00:00:00Z","type":"retraction","v":1}
EOF
out="$(PAPERCUT_LEDGER_DIR="$tol_dir" PAPERCUT_SPOOL="$tol_dir/no-spool.jsonl" python3 "$viewer" 2>"$workdir"/tolerance_err)"
rc=$?
assert_eq "forward tolerance: exits 0" "0" "$rc"
assert_eq "forward tolerance: no stderr noise" "" "$(cat "$workdir"/tolerance_err)"
assert_contains "forward tolerance: unknown-extra-field row still open" "$out" "extra field row"
assert_not_contains "forward tolerance: unknown-type row skipped" "$out" "unknown type row"
assert_contains "forward tolerance: only the papercut counted" "$out" "1 open papercut(s)"

# --json must round-trip the unknown field, not strip it
out="$(PAPERCUT_LEDGER_DIR="$tol_dir" PAPERCUT_SPOOL="$tol_dir/no-spool.jsonl" python3 "$viewer" --json 2>/dev/null)"
assert_contains "forward tolerance: --json preserves the unknown field" "$out" "future_field"

# --- 6. no sources at all: empty, deterministic output, exit 0 ---
empty_dir="$(next_dir)"
out="$(PAPERCUT_LEDGER_DIR="$empty_dir/nope" PAPERCUT_SPOOL="$empty_dir/spool.jsonl" python3 "$viewer" 2>/dev/null)"
rc=$?
assert_eq "no sources: exits 0" "0" "$rc"
assert_contains "no sources: zero-count summary line" "$out" "0 open papercut(s)"

exit $fail
