#!/usr/bin/env bash
# Tests for papercut_summary.py -- the one-line run summary rendered from a
# triage run manifest.
# Run:
#   bash tests/papercut_summary.test.sh
#
# tests/fixtures/papercut_summary/manifest.json is built so its counts match
# the example line in dev_docs/designs/2026-09-07-triage-and-route.md §4.5;
# summary.golden is that line.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script="$(dirname "$0")/../scripts/papercut_summary.py"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$repo_root/tests/fixtures/papercut_summary/manifest.json"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-summary-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

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

run_summary() {
  # run_summary <args...> -- sets $out, $err, $rc. Never reads stdin.
  out="$(python3 "$script" "$@" </dev/null 2>"$workdir/stderr")"
  rc=$?
  err="$(cat "$workdir/stderr")"
}

# variant <out-file> <python statements over `d`> -- the fixture, edited.
variant() {
  python3 - "$fixture" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
}

# =====================================================================
# The golden line.
# =====================================================================

run_summary "$fixture"
assert_eq "golden: exit 0" "0" "$rc"
assert_eq "golden: exactly the design's example line" "$(cat "$repo_root/tests/fixtures/papercut_summary/summary.golden")" "$out"
assert_eq "golden: exactly one line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

# Owners count distinct owner targets, never unowned or external ones: two
# more filings to an existing owner change F but not O.
variant "$workdir/more-alpha.json" 'd["filed"] += [dict(d["filed"][0], url="https://github.com/acme/alpha/issues/200"), dict(d["filed"][0], url="https://github.com/acme/alpha/issues/201")]'
run_summary "$workdir/more-alpha.json"
assert_contains "owners: distinct owner targets, not filings" "$out" "11 filed (3 owners)"

# =====================================================================
# An invalid or unreadable manifest exits non-zero and prints no summary.
# =====================================================================

variant "$workdir/no-noop.json" 'del d["noop"]'
run_summary "$workdir/no-noop.json"
assert_eq "invalid (missing required section): exit 1" "1" "$rc"
assert_eq "invalid: nothing on stdout" "" "$out"
assert_contains "invalid: names the problem" "$err" "missing required property: noop"

variant "$workdir/bad-unowned.json" 'd["filed"][0]["unowned"] = "no"'
run_summary "$workdir/bad-unowned.json"
assert_eq "invalid (unowned not a boolean): exit 1" "1" "$rc"

printf '{not json' >"$workdir/garbage.json"
run_summary "$workdir/garbage.json"
assert_eq "unparseable: exit 1" "1" "$rc"
assert_eq "unparseable: nothing on stdout" "" "$out"

run_summary "$workdir/does-not-exist.json"
assert_eq "missing file: exit 1" "1" "$rc"

# =====================================================================
# --verbose: the summary line, then held repos and unevidenced closes.
# =====================================================================

run_summary "$fixture" --verbose
assert_eq "verbose: exit 0" "0" "$rc"
assert_eq "verbose: first line is the summary" "$(cat "$repo_root/tests/fixtures/papercut_summary/summary.golden")" "$(printf '%s\n' "$out" | head -1)"
assert_contains "verbose: lists the held repo with its missing labels" "$out" "held         acme/delta  missing=priority:high,papercut-fix-now  clusters=1"
assert_contains "verbose: lists the closed-without-evidence issue" "$out" "no-evidence  https://github.com/acme/beta/issues/30  state_reason=NOT_PLANNED closer=None"

# =====================================================================
# A run with failed steps (issue #35) says INCOMPLETE, and still exits 0.
# =====================================================================

variant "$workdir/failed-one.json" 'd["failed"] = [{"step": "file", "repo": "acme/beta", "papercut_ids": ["pc_00000001-0000-4000-8000-000000000001"], "target": "beta", "title": "beta thing", "error": "gh issue create failed:\nboom"}]'
run_summary "$workdir/failed-one.json"
assert_eq "one failure: exit 0" "0" "$rc"
assert_eq "one failure: the line ends INCOMPLETE, naming the step and repo" \
  "$(sed 's/unowned\.$/unowned; INCOMPLETE — 1 failed (file acme\/beta)./' "$repo_root/tests/fixtures/papercut_summary/summary.golden")" "$out"

variant "$workdir/failed-many.json" 'd["failed"] = [{"step": "flush", "error": "failed (rc=2): x"}, {"step": "resolve", "id": "pc_1", "error": "e"}, {"step": "file", "repo": "acme/beta", "error": "e"}, {"step": "resolve", "id": "pc_2", "error": "e"}]'
run_summary "$workdir/failed-many.json"
assert_contains "several failures: in step order, resolves counted, flush named" "$out" "INCOMPLETE — 4 failed (file acme/beta, resolve ×2, flush)."

run_summary "$workdir/failed-one.json" --verbose
assert_contains "verbose: lists a failed step with its first error line" "$out" "failed       file  acme/beta  beta thing  gh issue create failed:"

variant "$workdir/failed-empty.json" 'd["failed"] = []'
run_summary "$workdir/failed-empty.json"
assert_eq "empty failed: the ordinary line" "$(cat "$repo_root/tests/fixtures/papercut_summary/summary.golden")" "$out"

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut_summary tests passed."
  exit 0
fi
echo "Some papercut_summary tests FAILED."
exit 1
