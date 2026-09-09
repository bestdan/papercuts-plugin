#!/usr/bin/env bash
# Tests for papercut_clusters.py -- validate-clusters (structural + semantic
# checks, severity/class enrichment), candidates (per-target-repo issue
# listing through the gh seam), and validate-consolidations (structural +
# semantic checks, class rewrite).
# Run:
#   bash tests/papercut_clusters.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script="$(dirname "$0")/../scripts/papercut_clusters.py"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-clusters-test.XXXXXX")"
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

run_clusters() {
  # run_clusters <args...> -- sets $out, $err, $rc. Never reads stdin.
  out="$(python3 "$script" "$@" </dev/null 2>"$workdir/stderr")"
  rc=$?
  err="$(cat "$workdir/stderr")"
}

id_a="pc_aaaaaaaa-0000-4000-8000-000000000001"
id_b="pc_bbbbbbbb-0000-4000-8000-000000000002"
id_c="pc_cccccccc-0000-4000-8000-000000000003"
id_d="pc_dddddddd-0000-4000-8000-000000000004"
id_e="pc_eeeeeeee-0000-4000-8000-000000000005"

registry_main="$workdir/registry-main.json"
cat >"$registry_main" <<EOF
{
  "owners": {
    "alpha": {"tracker": "gh-issue", "repo": "acme/alpha", "scope": "alpha stuff", "labels": []},
    "beta": {"tracker": "gh-issue", "repo": "acme/beta", "scope": "beta stuff", "labels": []}
  },
  "external": {},
  "unowned": {"repo": "acme/ledger"}
}
EOF

open_main="$workdir/open-main.jsonl"
cat >"$open_main" <<EOF
{"id": "$id_a", "severity": "high"}
{"id": "$id_b", "severity": "medium"}
{"id": "$id_c", "severity": "low"}
{"id": "$id_d", "severity": "medium"}
{"id": "$id_e", "severity": "low"}
EOF

tracked_main="$workdir/tracked-main.json"
cat >"$tracked_main" <<EOF
{
  "index": {
    "pc_bbbbbbbb": [
      {"repo": "acme/beta", "number": 5, "url": "https://github.com/acme/beta/issues/5", "state": "OPEN", "state_reason": null, "labels": [], "full_id": "$id_b", "source": "body"}
    ],
    "pc_dddddddd": [
      {"repo": "acme/ledger", "number": 1, "url": "https://github.com/acme/ledger/issues/1", "state": "CLOSED", "state_reason": "COMPLETED", "labels": [], "full_id": "$id_d", "source": "body"},
      {"repo": "acme/ledger", "number": 2, "url": "https://github.com/acme/ledger/issues/2", "state": "OPEN", "state_reason": null, "labels": [], "full_id": "$id_d", "source": "body"}
    ]
  },
  "calls": {"list": 2, "comments": 0}
}
EOF

clusters_main="$workdir/clusters-main.json"
cat >"$clusters_main" <<EOF
[
  {"improvement": "improve a and e", "papercut_ids": ["$id_a", "$id_e"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "improve b and c", "papercut_ids": ["$id_b", "$id_c"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "improve d", "papercut_ids": ["$id_d"], "target": "unowned", "effort": "high", "confidence": "low"}
]
EOF

# =====================================================================
# Main scenario: valid fixture round-trips, severity max, mixed ->
# consolidate with the right issue, closed-source + open-successor -> noop.
# =====================================================================

run_clusters validate-clusters --open "$open_main" --tracked "$tracked_main" --owners "$registry_main" "$clusters_main"
assert_eq "valid fixture: exit 0" "0" "$rc"
assert_eq "valid fixture: 3 clusters in output" "3" "$(jget "len(d)")"

assert_eq "cluster 0: severity is max(high, low) = high" "high" "$(jget "d[0]['severity']")"
assert_eq "cluster 0: untracked ids -> class file" "file" "$(jget "d[0]['class']")"
assert_eq "cluster 0: no issue key on file class" "no" "$(jget "'yes' if 'issue' in d[0] else 'no'")"

assert_eq "cluster 1: severity is max(medium, low) = medium" "medium" "$(jget "d[1]['severity']")"
assert_eq "cluster 1: mixed carriers -> class consolidate" "consolidate" "$(jget "d[1]['class']")"
assert_eq "cluster 1: issue is the open carrier's url" "https://github.com/acme/beta/issues/5" "$(jget "d[1]['issue']")"

assert_eq "cluster 2: reroute (closed source + open successor) -> class noop" "noop" "$(jget "d[2]['class']")"
assert_eq "cluster 2: noop carries no issue key" "no" "$(jget "'yes' if 'issue' in d[2] else 'no'")"

assert_eq "output key order: issue is last when present" "improvement,papercut_ids,target,effort,confidence,severity,class,issue" "$(jget "','.join(d[1].keys())")"

enriched_main="$workdir/enriched-main.json"
printf '%s' "$out" >"$enriched_main"

# =====================================================================
# Severity vocabulary: a record severity outside low/medium/high is
# ignored rather than ranked, and a cluster with no valid severity at all
# falls back to "low". The open set is the model's input, but the
# severity comes from the ledger, which grandfathers rows written before
# the field existed -- so both cases are reachable from real data.
# =====================================================================

id_f="pc_ffffffff-0000-4000-8000-000000000006"
id_g="pc_99999999-0000-4000-8000-000000000007"
id_h="pc_88888888-0000-4000-8000-000000000008"
id_i="pc_77777777-0000-4000-8000-000000000009"
id_j="pc_66666666-0000-4000-8000-000000000010"

open_sev="$workdir/open-sev.jsonl"
cat >"$open_sev" <<EOF
{"id": "$id_f", "severity": "critical"}
{"id": "$id_g", "severity": "low"}
{"id": "$id_h"}
{"id": "$id_i", "severity": "high"}
{"id": "$id_j", "severity": null}
EOF

tracked_sev="$workdir/tracked-sev.json"
cat >"$tracked_sev" <<'EOF'
{"index": {}, "calls": {"list": 0, "comments": 0}}
EOF

clusters_sev="$workdir/clusters-sev.json"
cat >"$clusters_sev" <<EOF
[
  {"improvement": "out-of-vocabulary severity beside a valid one", "papercut_ids": ["$id_f", "$id_i"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "missing severity beside a valid one", "papercut_ids": ["$id_h", "$id_g"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "no valid severity anywhere in the cluster", "papercut_ids": ["$id_j"], "target": "alpha", "effort": "low", "confidence": "high"}
]
EOF

run_clusters validate-clusters --open "$open_sev" --tracked "$tracked_sev" --owners "$registry_main" "$clusters_sev"
assert_eq "severity vocabulary: exit 0" "0" "$rc"
assert_eq "cluster 0: 'critical' is ignored, not ranked above high" "high" "$(jget "d[0]['severity']")"
assert_eq "cluster 1: a record with no severity field is ignored" "low" "$(jget "d[1]['severity']")"
assert_eq "cluster 2: no valid severity in the cluster falls back to low" "low" "$(jget "d[2]['severity']")"

# =====================================================================
# validate-clusters: one failing fixture per rule, each on its own message.
# =====================================================================

run_bad_clusters() {
  # run_bad_clusters <clusters-json-content-var-name>
  local content="$1"
  local f="$workdir/bad-clusters.json"
  printf '%s' "$content" >"$f"
  run_clusters validate-clusters --open "$open_main" --tracked "$tracked_main" --owners "$registry_main" "$f"
}

# 1. structural: missing required property
run_bad_clusters '[
  {"improvement": "x", "papercut_ids": ["'"$id_a"'"], "effort": "low", "confidence": "high"}
]'
assert_eq "rule 1 (structural): exit 2" "2" "$rc"
assert_contains "rule 1 (structural): message names the missing property" "$err" "missing required property: target"

# 2. improvement too long
long_improvement="$(python3 -c 'print("x" * 121)')"
run_bad_clusters '[
  {"improvement": "'"$long_improvement"'", "papercut_ids": ["'"$id_a"'", "'"$id_e"'"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "b and c", "papercut_ids": ["'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "low"}
]'
assert_eq "rule 2 (improvement length): exit 2" "2" "$rc"
assert_contains "rule 2 (improvement length): message names the rule" "$err" "improvement must be non-empty and at most 120 characters"

# 3a. effort not in vocabulary
run_bad_clusters '[
  {"improvement": "a and e", "papercut_ids": ["'"$id_a"'", "'"$id_e"'"], "target": "alpha", "effort": "urgent", "confidence": "high"},
  {"improvement": "b and c", "papercut_ids": ["'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "low"}
]'
assert_eq "rule 3a (effort vocabulary): exit 2" "2" "$rc"
assert_contains "rule 3a (effort vocabulary): message names the rule" "$err" "effort must be one of low, medium, high"

# 3b. confidence not in vocabulary
run_bad_clusters '[
  {"improvement": "a and e", "papercut_ids": ["'"$id_a"'", "'"$id_e"'"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "b and c", "papercut_ids": ["'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "maybe"}
]'
assert_eq "rule 3b (confidence vocabulary): exit 2" "2" "$rc"
assert_contains "rule 3b (confidence vocabulary): message names the rule" "$err" "confidence must be one of low, medium, high"

# 4. target is a variant spelling, not a registered name
run_bad_clusters '[
  {"improvement": "a and e", "papercut_ids": ["'"$id_a"'", "'"$id_e"'"], "target": "Alpha", "effort": "low", "confidence": "high"},
  {"improvement": "b and c", "papercut_ids": ["'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "low"}
]'
assert_eq "rule 4 (target vocabulary): exit 2" "2" "$rc"
assert_contains "rule 4 (target vocabulary): message names the target" "$err" "target 'Alpha' is not a known owner"

# 5. an invented id, not in the open set
run_bad_clusters '[
  {"improvement": "a, e, and invented", "papercut_ids": ["'"$id_a"'", "'"$id_e"'", "pc_ffffffff-0000-4000-8000-000000000006"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "b and c", "papercut_ids": ["'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "low"}
]'
assert_eq "rule 5 (id membership): exit 2" "2" "$rc"
assert_contains "rule 5 (id membership): message names the invented id" "$err" "is not in the open set"

# 6a. an id appears in two clusters
run_bad_clusters '[
  {"improvement": "a and e", "papercut_ids": ["'"$id_a"'", "'"$id_e"'"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "a again, and b and c", "papercut_ids": ["'"$id_a"'", "'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "low"}
]'
assert_eq "rule 6a (id span, duplicate): exit 2" "2" "$rc"
assert_contains "rule 6a (id span, duplicate): message names the duplicate" "$err" "appears in more than one cluster"

# 6b. an open id is missing from every cluster
run_bad_clusters '[
  {"improvement": "a only", "papercut_ids": ["'"$id_a"'"], "target": "alpha", "effort": "low", "confidence": "high"},
  {"improvement": "b and c", "papercut_ids": ["'"$id_b"'", "'"$id_c"'"], "target": "beta", "effort": "medium", "confidence": "medium"},
  {"improvement": "d", "papercut_ids": ["'"$id_d"'"], "target": "unowned", "effort": "high", "confidence": "low"}
]'
assert_eq "rule 6b (id span, missing): exit 2" "2" "$rc"
assert_contains "rule 6b (id span, missing): message names the unassigned id" "$err" "is not assigned to any cluster"

# =====================================================================
# 6c. A mixed cluster whose tracked ids span two open issues is an error
# (checked on the consolidate branch only).
# =====================================================================

open_span="$workdir/open-span.jsonl"
cat >"$open_span" <<EOF
{"id": "$id_b", "severity": "medium"}
{"id": "$id_c", "severity": "low"}
EOF

tracked_span="$workdir/tracked-span.json"
cat >"$tracked_span" <<EOF
{
  "index": {
    "pc_bbbbbbbb": [
      {"repo": "acme/beta", "number": 5, "url": "https://github.com/acme/beta/issues/5", "state": "OPEN", "state_reason": null, "labels": [], "full_id": "$id_b", "source": "body"},
      {"repo": "acme/beta", "number": 6, "url": "https://github.com/acme/beta/issues/6", "state": "OPEN", "state_reason": null, "labels": [], "full_id": "$id_b", "source": "body"}
    ]
  },
  "calls": {"list": 1, "comments": 0}
}
EOF

clusters_span="$workdir/clusters-span.json"
cat >"$clusters_span" <<EOF
[
  {"improvement": "b and c", "papercut_ids": ["$id_b", "$id_c"], "target": "beta", "effort": "medium", "confidence": "medium"}
]
EOF

run_clusters validate-clusters --open "$open_span" --tracked "$tracked_span" --owners "$registry_main" "$clusters_span"
assert_eq "rule (span across two open issues): exit 2" "2" "$rc"
assert_contains "rule (span): message names both urls" "$err" "acme/beta/issues/5"
assert_contains "rule (span): message names both urls" "$err" "acme/beta/issues/6"
assert_contains "rule (span): message says span" "$err" "span more than one open issue"

# =====================================================================
# candidates: only repos with a `file` cluster get listed.
# =====================================================================

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

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        repo="$1"
        ;;
    esac
    shift
  done
  safe="${repo//\//__}"
  fixture="$STUB_FIXTURES_DIR/issuelist__${safe}.json"
  if [ -f "$fixture" ]; then
    cat "$fixture"
    exit 0
  fi
  echo "stub gh: no issue-list fixture for $repo" >&2
  exit 1
fi
echo "stub gh: unrecognized invocation: $*" >&2
exit 1
STUB
chmod +x "$stub_gh"

cat >"$fixtures/issuelist__acme__alpha.json" <<'EOF'
[
  {"number": 9, "title": "t9", "body": "b9", "url": "https://github.com/acme/alpha/issues/9"}
]
EOF

export STUB_CALL_LOG="$call_log"
export STUB_FIXTURES_DIR="$fixtures"
export PAPERCUT_GH_CMD="$stub_gh"

run_clusters candidates --owners "$registry_main" --clusters "$enriched_main"
assert_eq "candidates: exit 0" "0" "$rc"
assert_eq "candidates: only acme/alpha is a key" "acme/alpha" "$(jget "','.join(sorted(d.keys()))")"
assert_eq "candidates: acme/alpha issue 9 present" "9" "$(jget "d['acme/alpha'][0]['number']")"
assert_contains "candidates: call log names acme/alpha" "$(cat "$call_log")" "acme/alpha"
assert_not_contains "candidates: call log does not name acme/beta (class consolidate)" "$(cat "$call_log")" "acme/beta"
assert_not_contains "candidates: call log does not name acme/ledger (class noop)" "$(cat "$call_log")" "acme/ledger"

candidates_main="$workdir/candidates-main.json"
printf '%s' "$out" >"$candidates_main"

: >"$call_log"
out_file="$workdir/candidates-out.json"
run_clusters candidates --owners "$registry_main" --clusters "$enriched_main" --out "$out_file"
assert_eq "candidates --out: exit 0" "0" "$rc"
assert_eq "candidates --out: nothing on stdout" "" "$out"
assert_eq "candidates --out: file holds the same result" "$(cat "$candidates_main")" "$(cat "$out_file")"

unset PAPERCUT_GH_CMD

# =====================================================================
# validate-consolidations
# =====================================================================

run_bad_consolidations() {
  local content="$1"
  local f="$workdir/bad-consolidations.json"
  printf '%s' "$content" >"$f"
  run_clusters validate-consolidations --clusters "$enriched_main" --candidates "$candidates_main" --owners "$registry_main" "$f"
}

# success: consolidate the file-class cluster (index 0) against a candidate.
run_bad_consolidations '[{"cluster": 0, "issue": "https://github.com/acme/alpha/issues/9"}]'
assert_eq "consolidations success: exit 0" "0" "$rc"
assert_eq "consolidations success: cluster 0 is now class consolidate" "consolidate" "$(jget "d[0]['class']")"
assert_eq "consolidations success: cluster 0 issue is the candidate url" "https://github.com/acme/alpha/issues/9" "$(jget "d[0]['issue']")"
assert_eq "consolidations success: cluster 1 (already consolidate) is untouched" "https://github.com/acme/beta/issues/5" "$(jget "d[1]['issue']")"
assert_eq "consolidations success: cluster 2 (noop) is untouched" "noop" "$(jget "d[2]['class']")"

# structural: missing required property "issue"
run_bad_consolidations '[{"cluster": 0}]'
assert_eq "consolidations rule (structural): exit 2" "2" "$rc"
assert_contains "consolidations rule (structural): message names the missing property" "$err" "missing required property: issue"

# cluster index out of range
run_bad_consolidations '[{"cluster": 99, "issue": "https://github.com/acme/alpha/issues/9"}]'
assert_eq "consolidations rule (index range): exit 2" "2" "$rc"
assert_contains "consolidations rule (index range): message says out of range" "$err" "out of range"

# same cluster named twice
run_bad_consolidations '[
  {"cluster": 0, "issue": "https://github.com/acme/alpha/issues/9"},
  {"cluster": 0, "issue": "https://github.com/acme/alpha/issues/9"}
]'
assert_eq "consolidations rule (duplicate cluster): exit 2" "2" "$rc"
assert_contains "consolidations rule (duplicate cluster): message says named more than once" "$err" "is named more than once"

# cluster's class is not "file"
run_bad_consolidations '[{"cluster": 1, "issue": "https://github.com/acme/beta/issues/5"}]'
assert_eq "consolidations rule (class not file): exit 2" "2" "$rc"
assert_contains "consolidations rule (class not file): message names the actual class" "$err" "is class 'consolidate', not 'file'"

# issue not among the candidates for the cluster's target repo
run_bad_consolidations '[{"cluster": 0, "issue": "https://github.com/acme/alpha/issues/999"}]'
assert_eq "consolidations rule (issue not a candidate): exit 2" "2" "$rc"
assert_contains "consolidations rule (issue not a candidate): message names the repo" "$err" "is not among the candidates for acme/alpha"

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut_clusters tests passed."
  exit 0
fi
echo "Some papercut_clusters tests FAILED."
exit 1
