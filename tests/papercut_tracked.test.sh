#!/usr/bin/env bash
# Tests for papercut_tracked.py — the tracked index across registered repos:
# repo dedupe from the owners registry, body-vs-comment carrier matching
# (body wins), the totalCount completeness assertion, the per-issue comment
# overflow fetch, and the no-search-API contract.
# Run:
#   bash tests/papercut_tracked.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script="$(dirname "$0")/../scripts/papercut_tracked.py"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-tracked-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

unset PAPERCUT_LEDGER_DIR

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

# jq-free field extraction: python one-liners over $out.
jget() {
  # jget <python expression over `d`> -- $out is the JSON text
  printf '%s' "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print($1)
"
}

# --- shared fixtures: a stub gh, a config, ids ---

stub_gh="$workdir/stub-gh.sh"
fixtures="$workdir/fixtures"
mkdir -p "$fixtures"
call_log="$workdir/calls.log"

cat >"$stub_gh" <<'STUB'
#!/usr/bin/env bash
{
  echo "=== CALL ==="
  printf '%s\n' "$@"
} >>"$STUB_CALL_LOG"

if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  owner=""
  name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -F)
        shift
        case "$1" in
          owner=*) owner="${1#owner=}" ;;
          name=*) name="${1#name=}" ;;
        esac
        ;;
    esac
    shift
  done
  fixture="$STUB_FIXTURES_DIR/${owner}__${name}.json"
  if [ -f "$fixture" ]; then
    cat "$fixture"
    exit 0
  fi
  echo "stub gh: no graphql fixture for $owner/$name" >&2
  exit 1
elif [ "$1" = "api" ] && [ "$2" = "--paginate" ]; then
  path="$3"
  rest="${path#repos/}"
  owner="${rest%%/*}"
  rest="${rest#*/}"
  name="${rest%%/*}"
  rest="${rest#*/}"
  number="${rest#issues/}"
  number="${number%%/*}"
  fixture="$STUB_FIXTURES_DIR/${owner}__${name}__${number}_comments.json"
  if [ -f "$fixture" ]; then
    cat "$fixture"
    exit 0
  fi
  echo "stub gh: no comments fixture for $path" >&2
  exit 1
fi
echo "stub gh: unrecognized invocation: $*" >&2
exit 1
STUB
chmod +x "$stub_gh"

export STUB_CALL_LOG="$call_log"
export STUB_FIXTURES_DIR="$fixtures"
export PAPERCUT_GH_CMD="$stub_gh"

config="$workdir/config.toml"
cat >"$config" <<'EOF'
[ledger]
repo = "you/papercuts-ledger"
EOF
export PAPERCUT_CONFIG="$config"

id_a="pc_aaaaaaaa-0000-4000-8000-000000000001"
id_b="pc_bbbbbbbb-0000-4000-8000-000000000002"
id_c="pc_cccccccc-0000-4000-8000-000000000003"
id_d="pc_dddddddd-0000-4000-8000-000000000004"
id_e="pc_eeeeeeee-0000-4000-8000-000000000005"

run_tracked() {
  # run_tracked <open-file-or-"-"> [extra args...] -- sets $out, $err, $rc
  local openfile="$1"
  shift
  if [ "$openfile" = "-" ]; then
    out="$(python3 "$script" "$@" </dev/null 2>"$workdir/stderr")"
  else
    out="$(cat "$openfile" | python3 "$script" "$@" 2>"$workdir/stderr")"
  fi
  rc=$?
  err="$(cat "$workdir/stderr")"
}

# =====================================================================
# Main scenario: two owners sharing a repo, plus a distinct unowned repo.
# Exercises: dedupe, body-source, comment-source, mixed carriers on the
# same prefix (cases 1-4, 8, 9, 10), and --open vs stdin (case 12).
# =====================================================================

owners_main="$workdir/owners-main.toml"
cat >"$owners_main" <<'EOF'
[unowned]
repo = "acme/ledger"

[owners.alpha]
tracker = "gh-issue"
repo = "acme/alpha"
scope = "alpha stuff"

[owners.beta]
tracker = "gh-issue"
repo = "acme/alpha"
scope = "beta stuff, shares alpha's repo"
EOF

cat >"$fixtures/acme__alpha.json" <<EOF
[
  {"data": {"repository": {"issues": {"totalCount": 3, "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
    {"number": 1, "state": "OPEN", "stateReason": null, "url": "https://github.com/acme/alpha/issues/1", "title": "t1", "body": "Fixes $id_a thanks", "labels": {"nodes": [{"name": "papercut"}]}, "comments": {"totalCount": 0, "nodes": []}},
    {"number": 2, "state": "OPEN", "stateReason": null, "url": "https://github.com/acme/alpha/issues/2", "title": "t2", "body": "no id here", "labels": {"nodes": []}, "comments": {"totalCount": 1, "nodes": [{"body": "consolidated: pc_bbbbbbbb"}]}},
    {"number": 4, "state": "CLOSED", "stateReason": "COMPLETED", "url": "https://github.com/acme/alpha/issues/4", "title": "t4", "body": "Fixed by $id_c", "labels": {"nodes": []}, "comments": {"totalCount": 0, "nodes": []}}
  ]}}}}
]
EOF

cat >"$fixtures/acme__ledger.json" <<EOF
[
  {"data": {"repository": {"issues": {"totalCount": 2, "pageInfo": {"hasNextPage": true, "endCursor": "c1"}, "nodes": [
    {"number": 10, "state": "OPEN", "stateReason": null, "url": "https://github.com/acme/ledger/issues/10", "title": "t10", "body": "", "labels": {"nodes": []}, "comments": {"totalCount": 1, "nodes": [{"body": "tracking pc_cccccccc here too"}]}}
  ]}}}},
  {"data": {"repository": {"issues": {"totalCount": 2, "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
    {"number": 20, "state": "OPEN", "stateReason": null, "url": "https://github.com/acme/ledger/issues/20", "title": "t20", "body": "Full id here: $id_b", "labels": {"nodes": []}, "comments": {"totalCount": 0, "nodes": []}}
  ]}}}}
]
EOF

open_main="$workdir/open-main.jsonl"
cat >"$open_main" <<EOF
{"id": "$id_a"}
{"id": "$id_b"}
{"id": "$id_c"}
{"id": "$id_d"}
EOF

export PAPERCUT_OWNERS="$owners_main"
run_tracked "$open_main"
assert_eq "main scenario: exit 0" "0" "$rc"

assert_eq "case 1: aaaaaaaa has one entry" "1" "$(jget "len(d['index']['pc_aaaaaaaa'])")"
assert_eq "case 1: aaaaaaaa source is body" "body" "$(jget "d['index']['pc_aaaaaaaa'][0]['source']")"
assert_eq "case 1: aaaaaaaa full_id" "$id_a" "$(jget "d['index']['pc_aaaaaaaa'][0]['full_id']")"
assert_eq "case 1: aaaaaaaa state" "OPEN" "$(jget "d['index']['pc_aaaaaaaa'][0]['state']")"
assert_eq "case 1: aaaaaaaa url" "https://github.com/acme/alpha/issues/1" "$(jget "d['index']['pc_aaaaaaaa'][0]['url']")"
assert_eq "case 1: aaaaaaaa labels" "papercut" "$(jget "','.join(d['index']['pc_aaaaaaaa'][0]['labels'])")"

assert_eq "case 3: bbbbbbbb has two entries (comment + body)" "2" "$(jget "len(d['index']['pc_bbbbbbbb'])")"
assert_eq "case 2/3: bbbbbbbb#1 is acme/alpha#2, source comment" "acme/alpha 2 comment" "$(jget "'%s %s %s' % (d['index']['pc_bbbbbbbb'][0]['repo'], d['index']['pc_bbbbbbbb'][0]['number'], d['index']['pc_bbbbbbbb'][0]['source'])")"
assert_eq "case 2/3: bbbbbbbb#2 is acme/ledger#20, source body" "acme/ledger 20 body" "$(jget "'%s %s %s' % (d['index']['pc_bbbbbbbb'][1]['repo'], d['index']['pc_bbbbbbbb'][1]['number'], d['index']['pc_bbbbbbbb'][1]['source'])")"
assert_eq "case 3: both bbbbbbbb entries carry full_id" "$id_b $id_b" "$(jget "'%s %s' % (d['index']['pc_bbbbbbbb'][0]['full_id'], d['index']['pc_bbbbbbbb'][1]['full_id'])")"

assert_eq "case 4: cccccccc has two entries, distinct states, ordered by (repo,number)" "acme/alpha 4 CLOSED body|acme/ledger 10 OPEN comment" "$(jget "'|'.join('%s %s %s %s' % (e['repo'], e['number'], e['state'], e['source']) for e in d['index']['pc_cccccccc'])")"

assert_eq "case 9: dddddddd has no carrier and is absent from index" "absent" "$(jget "'absent' if 'pc_dddddddd' not in d['index'] else 'present'")"
assert_eq "case 9: every entry carries full_id" "ok" "$(jget "'ok' if all(e.get('full_id') for entries in d['index'].values() for e in entries) else 'missing'")"

assert_eq "case 8: calls.list equals number of distinct repos (2)" "2" "$(jget "d['calls']['list']")"
assert_eq "main scenario: calls.comments is 0 (no overflow)" "0" "$(jget "d['calls']['comments']")"

assert_eq "case 10: two pages in acme/ledger merged into 2 issues" "2" "$(jget "sum(1 for entries in d['index'].values() for e in entries if e['repo'] == 'acme/ledger')")"

assert_not_contains "case 7: call log names no search invocation" "$(cat "$call_log")" "search"
assert_not_contains "case 7: call log names no --search flag" "$(cat "$call_log")" "--search"

# --- case 12: --open <file> gives the same result as stdin ---
out_stdin="$out"
run_tracked "$open_main" --open "$open_main"
out_open_flag="$out"
assert_eq "case 12: --open and stdin agree" "$out_stdin" "$out_open_flag"

# =====================================================================
# Case 5: totalCount mismatch -> non-zero exit naming the repo and numbers.
# =====================================================================

: >"$call_log"
owners_gamma="$workdir/owners-gamma.toml"
cat >"$owners_gamma" <<'EOF'
[unowned]
repo = "acme/gamma"
EOF
cat >"$fixtures/acme__gamma.json" <<'EOF'
[
  {"data": {"repository": {"issues": {"totalCount": 5, "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
    {"number": 1, "state": "OPEN", "stateReason": null, "url": "https://github.com/acme/gamma/issues/1", "title": "g1", "body": "", "labels": {"nodes": []}, "comments": {"totalCount": 0, "nodes": []}},
    {"number": 2, "state": "OPEN", "stateReason": null, "url": "https://github.com/acme/gamma/issues/2", "title": "g2", "body": "", "labels": {"nodes": []}, "comments": {"totalCount": 0, "nodes": []}}
  ]}}}}
]
EOF
export PAPERCUT_OWNERS="$owners_gamma"
run_tracked "-"
assert_eq "case 5: totalCount mismatch: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "case 5: stderr names the repo" "$err" "acme/gamma"
assert_contains "case 5: stderr names the collected count" "$err" "2"
assert_contains "case 5: stderr names totalCount" "$err" "5"

# =====================================================================
# Case 6: comment overflow -- totalCount 101 exceeds the 100 node cap, the
# per-issue comments call is made, and calls.comments is 1.
# =====================================================================

: >"$call_log"
owners_epsilon="$workdir/owners-epsilon.toml"
cat >"$owners_epsilon" <<'EOF'
[unowned]
repo = "acme/epsilon"
EOF
python3 - "$fixtures/acme__epsilon.json" <<'PY'
import json
import sys

nodes = [{"body": ""} for _ in range(100)]
doc = [{"data": {"repository": {"issues": {
    "totalCount": 1,
    "pageInfo": {"hasNextPage": False, "endCursor": None},
    "nodes": [{
        "number": 1,
        "state": "OPEN",
        "stateReason": None,
        "url": "https://github.com/acme/epsilon/issues/1",
        "title": "e1",
        "body": "",
        "labels": {"nodes": []},
        "comments": {"totalCount": 101, "nodes": nodes},
    }],
}}}}]
with open(sys.argv[1], "w") as f:
    json.dump(doc, f)
PY
cat >"$fixtures/acme__epsilon__1_comments.json" <<EOF
[{"body": "overflow comment: $id_e"}]
EOF
open_epsilon="$workdir/open-epsilon.jsonl"
cat >"$open_epsilon" <<EOF
{"id": "$id_e"}
EOF
export PAPERCUT_OWNERS="$owners_epsilon"
run_tracked "$open_epsilon"
assert_eq "case 6: overflow scenario exits 0" "0" "$rc"
assert_eq "case 6: overflow-only prefix is indexed" "1" "$(jget "len(d['index']['pc_eeeeeeee'])")"
assert_eq "case 6: overflow entry source is comment" "comment" "$(jget "d['index']['pc_eeeeeeee'][0]['source']")"
assert_eq "case 6: calls.comments is 1" "1" "$(jget "d['calls']['comments']")"
assert_contains "case 6: call log shows the per-issue comments call" "$(cat "$call_log")" "repos/acme/epsilon/issues/1/comments"

# =====================================================================
# Case 11: gh exits non-zero on graphql (no fixture present) -> exit 1.
# =====================================================================

: >"$call_log"
owners_delta="$workdir/owners-delta.toml"
cat >"$owners_delta" <<'EOF'
[unowned]
repo = "acme/delta"
EOF
export PAPERCUT_OWNERS="$owners_delta"
run_tracked "-"
assert_eq "case 11: gh failure on graphql: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut_tracked tests passed."
  exit 0
fi
echo "Some papercut_tracked tests FAILED."
exit 1
