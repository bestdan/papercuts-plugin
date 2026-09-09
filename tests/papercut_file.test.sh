#!/usr/bin/env bash
# Tests for papercut_file.py -- the filing step: target/label pre-flight,
# body render, gh issue create/comment, and the run manifest.
# Run:
#   bash tests/papercut_file.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script="$(dirname "$0")/../scripts/papercut_file.py"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-file-test.XXXXXX")"
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

run_file() {
  # run_file <args...> -- sets $out, $err, $rc. Never reads stdin.
  out="$(python3 "$script" "$@" </dev/null 2>"$workdir/stderr")"
  rc=$?
  err="$(cat "$workdir/stderr")"
}

# =====================================================================
# Fixtures shared by every scenario below.
# =====================================================================

id_a="pc_aaaaaaaa-0000-4000-8000-000000000001"
id_b="pc_bbbbbbbb-0000-4000-8000-000000000002"
id_c="pc_cccccccc-0000-4000-8000-000000000003"
id_d="pc_dddddddd-0000-4000-8000-000000000004"
id_e="pc_eeeeeeee-0000-4000-8000-000000000005"
id_f="pc_ffffffff-0000-4000-8000-000000000006"
id_g="pc_99999999-0000-4000-8000-000000000007"
id_h="pc_88888888-0000-4000-8000-000000000008"
id_i="pc_77777777-0000-4000-8000-000000000009"

owners_json="$workdir/owners.json"
cat >"$owners_json" <<'EOF'
{
  "owners": {
    "alpha": {"tracker": "gh-issue", "repo": "acme/alpha", "scope": "a", "labels": ["status:0_untriaged"]},
    "beta": {"tracker": "gh-issue", "repo": "acme/beta", "scope": "b", "labels": []},
    "gamma": {"tracker": "gh-issue", "repo": "acme/gamma", "scope": "g", "labels": []},
    "delta": {"tracker": "gh-issue", "repo": "acme/delta", "scope": "d", "labels": []},
    "theta": {"tracker": "gh-issue", "repo": "acme/theta", "scope": "t", "labels": []},
    "epsilon": {"tracker": "gh-issue", "repo": "acme/epsilon", "scope": "e", "labels": []}
  },
  "external": {"claude-code": {"repo": "anthropics/claude-code", "scope": "harness"}},
  "unowned": {"repo": "acme/ledger"}
}
EOF

open_jsonl="$workdir/open.jsonl"
cat >"$open_jsonl" <<EOF
{"id": "$id_a", "title": "The alpha widget breaks on save", "suggested_fix": "Guard against null before save."}
{"id": "$id_b", "title": "Beta button misaligned", "suggested_fix": ""}
{"id": "$id_c", "title": "Gamma race condition", "suggested_fix": "Add a mutex around the write."}
{"id": "$id_g", "title": "Gamma race condition, second report"}
{"id": "$id_d", "title": "Delta typo in docs"}
{"id": "$id_e", "title": "Theta thing one"}
{"id": "$id_f", "title": "Theta thing two"}
{"id": "$id_h", "title": "Epsilon high severity thing"}
{"id": "$id_i", "title": "Epsilon low severity thing"}
EOF

clusters_json="$workdir/clusters.json"
cat >"$clusters_json" <<EOF
[
  {"improvement": "Fix the alpha thing", "papercut_ids": ["$id_a"], "target": "alpha", "effort": "low", "confidence": "high", "severity": "high", "class": "file"},
  {"improvement": "Beta friction cleanup", "papercut_ids": ["$id_b"], "target": "beta", "effort": "low", "confidence": "high", "severity": "medium", "class": "file", "fix_now": false},
  {"improvement": "Gamma consolidation candidate", "papercut_ids": ["$id_c", "$id_g"], "target": "gamma", "effort": "medium", "confidence": "medium", "severity": "medium", "class": "file", "fix_now": true},
  {"improvement": "Delta minor thing", "papercut_ids": ["$id_d"], "target": "delta", "effort": "medium", "confidence": "medium", "severity": "low", "class": "file"},
  {"improvement": "Theta consolidation", "papercut_ids": ["$id_e", "$id_f"], "target": "theta", "effort": "low", "confidence": "low", "severity": "low", "class": "consolidate", "issue": "https://github.com/acme/theta/issues/9"},
  {"improvement": "External claude-code thing", "papercut_ids": ["$id_a"], "target": "claude-code", "effort": "low", "confidence": "low", "severity": "low", "class": "file"},
  {"improvement": "Unowned thing", "papercut_ids": ["$id_a"], "target": "unowned", "effort": "low", "confidence": "low", "severity": "low", "class": "file"},
  {"improvement": "Epsilon high severity thing", "papercut_ids": ["$id_h"], "target": "epsilon", "effort": "high", "confidence": "low", "severity": "high", "class": "file"},
  {"improvement": "Epsilon low severity thing", "papercut_ids": ["$id_i"], "target": "epsilon", "effort": "low", "confidence": "high", "severity": "low", "class": "file"},
  {"improvement": "A noop cluster", "papercut_ids": ["$id_a"], "target": "alpha", "effort": "low", "confidence": "low", "severity": "low", "class": "noop"},
  {"improvement": "Another noop cluster", "papercut_ids": ["$id_b"], "target": "beta", "effort": "low", "confidence": "low", "severity": "low", "class": "noop"}
]
EOF

# A separate, single-cluster fixture for the unknown-target render test below
# -- kept out of clusters.json so it does not also break the dry-run/apply
# scenarios, which resolve every file cluster's target while planning.
unknown_target_clusters_json="$workdir/clusters-unknown-target.json"
cat >"$unknown_target_clusters_json" <<EOF
[
  {"improvement": "Unknown target thing", "papercut_ids": ["$id_a"], "target": "no-such-owner", "effort": "low", "confidence": "low", "severity": "low", "class": "file"}
]
EOF

# A titleless id -- present in no open record at all -- for the dangling
# em-dash guard below. Kept out of clusters.json/open.jsonl so it does not
# perturb the dry-run/apply/noop-count scenarios.
id_k="pc_55555555-0000-4000-8000-000000000011"
dangling_clusters_json="$workdir/clusters-dangling.json"
cat >"$dangling_clusters_json" <<EOF
[
  {"improvement": "Dangling title thing", "papercut_ids": ["$id_k"], "target": "alpha", "effort": "low", "confidence": "low", "severity": "low", "class": "noop"}
]
EOF

tracked_json="$workdir/tracked.json"
cat >"$tracked_json" <<'EOF'
{"index": {}, "calls": {"list": 5, "comments": 1}}
EOF

# =====================================================================
# --render: golden files for title and body, checked SEPARATELY (calling
# render_title/render_body directly, not by splitting --render's combined
# stdout) so a bug that drops the title or duplicates the improvement into
# the body cannot hide behind an ambiguous combined fixture.
# =====================================================================

render_piece() {
  # render_piece <title|body> <cluster-index> [clusters-file] -- prints
  # exactly that piece, nothing else, no trailing blank line. Defaults to
  # $clusters_json when no clusters-file is given.
  python3 - "$repo_root" "${3:-$clusters_json}" "$owners_json" "$open_jsonl" "$1" "$2" <<'PY'
import importlib.util
import json
import sys

repo_root, clusters_path, owners_path, open_path, what, index = sys.argv[1:7]
index = int(index)

spec = importlib.util.spec_from_file_location("papercut_file", f"{repo_root}/scripts/papercut_file.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

clusters = json.load(open(clusters_path, encoding="utf-8"))
registry = json.load(open(owners_path, encoding="utf-8"))
open_records = module.load_open_records(open_path)

cluster = clusters[index]
if what == "title":
    sys.stdout.write(module.render_title(cluster))
else:
    repo = module.resolve_repo(cluster["target"], registry)
    sys.stdout.write(module.render_body(cluster, repo, registry, open_records))
PY
}

run_file --render 0 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_eq "render cluster 0: exit 0" "0" "$rc"

title_out="$(render_piece title 0)"
body_out="$(render_piece body 0)"
title_golden="$(cat "$repo_root/tests/fixtures/papercut_file/cluster0-title.golden")"
body_golden="$(cat "$repo_root/tests/fixtures/papercut_file/cluster0-body.golden")"
assert_eq "render cluster 0: title matches its own golden (not the body's)" "$title_golden" "$title_out"
assert_eq "render cluster 0: body matches its own golden (not the title's)" "$body_golden" "$body_out"
assert_contains "render cluster 0: --render's combined output includes the title" "$out" "$title_out"
assert_contains "render cluster 0: --render's combined output includes the body" "$out" "$body_out"

run_file --render 1 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_contains "render cluster 1 (external suggested_fix skipped): no 'Suggested fix' line" "$out" ""
assert_not_contains "render cluster 1: no Suggested fix line (empty suggested_fix skipped)" "$out" "Suggested fix:"

run_file --render 2 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_contains "render cluster 2: merged suggested_fix from one of two records" "$out" "Suggested fix: Add a mutex around the write."
assert_contains "render cluster 2: both source papercut ids listed in order" "$out" "- $id_c — Gamma race condition"
assert_contains "render cluster 2: both source papercut ids listed in order" "$out" "- $id_g — Gamma race condition, second report"

run_file --render 3 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_not_contains "render cluster 3 (no suggested_fix anywhere): line omitted entirely" "$out" "Suggested fix"

run_file --render 5 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_contains "render cluster 5 (external target): body keeps the name, suffixed" "$out" "Target: claude-code (external)"
assert_contains "render cluster 5 (external target): resolves to unowned.repo" "$out" "Repo: acme/ledger"

run_file --render 6 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_contains "render cluster 6 (literal unowned): body keeps the name, no suffix" "$out" "Target: unowned"
assert_not_contains "render cluster 6: no (external) suffix on unowned" "$out" "unowned (external)"
assert_contains "render cluster 6 (literal unowned): resolves to unowned.repo" "$out" "Repo: acme/ledger"

run_file --render 99 --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_eq "render out-of-range index: exit 2" "2" "$rc"
assert_contains "render out-of-range index: message says out of range" "$err" "out of range"

# render on a cluster whose target is not in the registry: resolve_repo raises
# FilingError, which must be caught by main() (the same handler cmd_plan uses),
# not left to propagate as an uncaught traceback.
run_file --render 0 --clusters "$unknown_target_clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_eq "render unknown target: exit 1, not a traceback" "1" "$rc"
assert_contains "render unknown target: clean error message" "$err" "unknown target"
assert_not_contains "render unknown target: no Python traceback" "$err" "Traceback"

# Dangling em-dash guard: a papercut id with no title anywhere (no open
# record at all) must render as a bare "- {pid}" line, never "- {pid} —"
# with nothing after it, in both render_body and render_consolidation_comment.
dangling_body="$(render_piece body 0 "$dangling_clusters_json")"
assert_contains "render_body: titleless id renders as a bare line" "$dangling_body" "- $id_k"
assert_not_contains "render_body: no dangling em-dash after a titleless id" "$dangling_body" "$id_k —"

dangling_comment="$(python3 - "$repo_root" "$dangling_clusters_json" "$open_jsonl" <<'PY'
import importlib.util
import json
import sys

repo_root, clusters_path, open_path = sys.argv[1:4]

spec = importlib.util.spec_from_file_location("papercut_file", f"{repo_root}/scripts/papercut_file.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

clusters = json.load(open(clusters_path, encoding="utf-8"))
open_records = module.load_open_records(open_path)
sys.stdout.write(module.render_consolidation_comment(clusters[0], open_records))
PY
)"
assert_contains "render_consolidation_comment: titleless id renders as a bare line" "$dangling_comment" "- $id_k"
assert_not_contains "render_consolidation_comment: no dangling em-dash after a titleless id" "$dangling_comment" "$id_k —"

# =====================================================================
# gh stub for the plan/apply scenarios below.
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

if [ "$1" = "label" ] && [ "$2" = "list" ]; then
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
  fixture="$STUB_FIXTURES_DIR/labels__${safe}.json"
  if [ -f "$fixture" ]; then
    cat "$fixture"
    exit 0
  fi
  echo "[]"
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        repo="$1"
        ;;
      --body)
        echo "stub gh: --body used on the command line" >&2
        exit 1
        ;;
    esac
    shift
  done
  echo "https://github.com/$repo/issues/999"
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  for arg in "$@"; do
    if [ "$arg" = "--body" ]; then
      echo "stub gh: --body used on the command line" >&2
      exit 1
    fi
  done
  exit 0
fi

echo "stub gh: unrecognized invocation: $*" >&2
exit 1
STUB
chmod +x "$stub_gh"

cat >"$fixtures/labels__acme__alpha.json" <<'EOF'
[{"name": "papercut"}, {"name": "priority:high"}, {"name": "status:0_untriaged"}]
EOF
cat >"$fixtures/labels__acme__beta.json" <<'EOF'
[{"name": "papercut"}, {"name": "priority:medium"}]
EOF
cat >"$fixtures/labels__acme__gamma.json" <<'EOF'
[{"name": "papercut"}, {"name": "priority:medium"}, {"name": "papercut-fix-now"}]
EOF
cat >"$fixtures/labels__acme__delta.json" <<'EOF'
[{"name": "papercut"}, {"name": "priority:low"}]
EOF
cat >"$fixtures/labels__acme__epsilon.json" <<'EOF'
[{"name": "papercut"}, {"name": "priority:high"}, {"name": "priority:low"}, {"name": "papercut-fix-now"}]
EOF

export STUB_CALL_LOG="$call_log"
export STUB_FIXTURES_DIR="$fixtures"
export PAPERCUT_GH_CMD="$stub_gh"
triage_dir="$workdir/triage"
export PAPERCUT_TRIAGE_DIR="$triage_dir"

# =====================================================================
# Dry run: alpha (default fix-now, label missing) is held; acme/ledger is
# held too (no fixture -> empty existing labels), reached by two DIFFERENT
# target names (claude-code, an external; unowned, the literal) that both
# resolve to it -- nothing is written to gh or the manifest.
# =====================================================================

: >"$call_log"
run_file --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json"
assert_eq "dry run: exit 0" "0" "$rc"
assert_contains "dry run: alpha reported held" "$out" "held    acme/alpha  missing=papercut-fix-now"
assert_contains "dry run: acme/ledger (two colliding targets) reported held" "$out" "held    acme/ledger  missing=papercut,priority:low  clusters=2"
assert_not_contains "dry run: no gh write call at all (label list is read-only)" "$(cat "$call_log")" "create"
assert_not_contains "dry run: no gh write call at all (label list is read-only)" "$(cat "$call_log")" "comment"
assert_eq "dry run: no manifest file written" "no" "$([ -f "$triage_dir"/*.json ] 2>/dev/null && echo yes || echo no)"

# =====================================================================
# --apply: the full scenario.
# =====================================================================

: >"$call_log"
run_file --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json" --apply
assert_eq "apply: exit 0" "0" "$rc"

# held: alpha's default fix-now cluster is held, files nothing into acme/alpha.
held_alpha_create="$(python3 - "$call_log" <<'PY'
import sys

calls = []
current = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line == "=== CALL ===":
        if current:
            calls.append(current)
        current = []
    else:
        current.append(line)
if current:
    calls.append(current)

for call in calls:
    if call[:2] == ["issue", "create"] and "acme/alpha" in call:
        print("found")
        break
else:
    print("none")
PY
)"
assert_eq "apply: held owner (acme/alpha) gets no issue create" "none" "$held_alpha_create"

# fix_now override: beta's cluster has fix_now:false despite low/high, so its
# required label set excludes papercut-fix-now -- it is not held even though
# the acme/beta fixture never carries that label.
assert_contains "apply: beta (fix_now:false override) filed, not held" "$out" "file    acme/beta"
assert_not_contains "apply: beta not held" "$out" "held    acme/beta"

# --apply prints the created issue URL on the file line (it exists only in
# the manifest otherwise); the dry-run line above stays exactly as it was.
assert_contains "apply: file line includes the created issue URL" "$out" "file    acme/beta  labels=papercut,priority:medium  Beta friction cleanup  https://github.com/acme/beta/issues/999"

# fix_now override: gamma's cluster has fix_now:true despite medium/medium,
# so papercut-fix-now IS required -- and present in its fixture, so it files.
assert_contains "apply: gamma (fix_now:true override) filed" "$out" "file    acme/gamma"

# delta: no fix-now cluster at all -- required set excludes papercut-fix-now,
# so its fixture's missing papercut-fix-now does not hold it back.
assert_contains "apply: delta (no fix-now cluster) filed despite missing papercut-fix-now label" "$out" "file    acme/delta"
assert_not_contains "apply: delta not held" "$out" "held    acme/delta"

# consolidation: a comment on the existing issue, not a new issue.
assert_contains "apply: theta consolidated onto the existing issue" "$out" "consolidate  https://github.com/acme/theta/issues/9"

# --body-file always used, --body never (the stub itself refuses a bare
# --body and would have failed the run above; this also checks the log
# directly rather than relying on that alone).
assert_contains "apply: call log uses --body-file" "$(cat "$call_log")" "--body-file"
bare_body_lines="$(grep -cx -- '--body' "$call_log" || true)"
assert_eq "apply: call log never uses bare --body" "0" "$bare_body_lines"

# issue create calls happen in cluster order: beta (index 1) before gamma (2)
# before delta (3) -- never grouped by repo.
create_repo_order="$(python3 - "$call_log" <<'PY'
import sys

calls = []
current = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line == "=== CALL ===":
        if current:
            calls.append(current)
        current = []
    else:
        current.append(line)
if current:
    calls.append(current)

repos = []
for call in calls:
    if call[:2] == ["issue", "create"]:
        i = call.index("--repo")
        repos.append(call[i + 1])
print(",".join(repos))
PY
)"
assert_eq "apply: issue create calls happen in cluster order, not grouped by repo" "acme/beta,acme/gamma,acme/delta,acme/epsilon,acme/epsilon" "$create_repo_order"

# =====================================================================
# Per-cluster labels vs the pre-flight union: two clusters targeting one
# repo (epsilon) with different severity and different fix-now
# eligibility must each be filed with THEIR OWN label set, not the union
# checked for at that repo. The plan text and the --label args in the gh
# call log are both asserted, since the bug this pins produced identical
# labels in the plan output for both clusters.
# =====================================================================

assert_contains "apply: epsilon high-severity cluster plan shows its own labels (no fix-now)" "$out" "file    acme/epsilon  labels=papercut,priority:high  Epsilon high severity thing"
assert_contains "apply: epsilon low-severity cluster plan shows its own labels (fix-now, no priority:high)" "$out" "file    acme/epsilon  labels=papercut,priority:low,papercut-fix-now  Epsilon low severity thing"

epsilon_create_labels="$(python3 - "$call_log" <<'PY'
import sys

calls = []
current = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line == "=== CALL ===":
        if current:
            calls.append(current)
        current = []
    else:
        current.append(line)
if current:
    calls.append(current)

for call in calls:
    if call[:2] != ["issue", "create"] or "--repo" not in call or call[call.index("--repo") + 1] != "acme/epsilon":
        continue
    labels = [call[i + 1] for i, tok in enumerate(call) if tok == "--label"]
    title_i = call.index("--title")
    print(f"{call[title_i + 1]}: {','.join(labels)}")
PY
)"
assert_contains "apply: epsilon high-severity issue create --label args exclude papercut-fix-now" "$epsilon_create_labels" "Epsilon high severity thing: papercut,priority:high"
assert_contains "apply: epsilon low-severity issue create --label args exclude priority:high" "$epsilon_create_labels" "Epsilon low severity thing: papercut,priority:low,papercut-fix-now"

# manifest: written, and validates against schema/manifest.v1.json.
manifest_file="$(find "$triage_dir" -maxdepth 1 -name '*.json' -type f)"
assert_eq "apply: exactly one manifest file written" "1" "$(printf '%s\n' "$manifest_file" | grep -c .)"

manifest_json="$(cat "$manifest_file")"
schema_err="$(python3 - "$manifest_file" "$repo_root" <<'PY'
import sys, json, importlib.util

manifest_path, repo_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "papercut_file", f"{repo_root}/scripts/papercut_file.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

data = json.load(open(manifest_path, encoding="utf-8"))
schema = module.load_schema("manifest.v1.json")
err = module.validate_structure(data, schema)
print(err or "")
PY
)"
assert_eq "apply: manifest validates against schema/manifest.v1.json" "" "$schema_err"

out="$manifest_json"
assert_eq "manifest: 5 filed" "5" "$(jget "len(d['filed'])")"
assert_eq "manifest: 1 consolidated" "1" "$(jget "len(d['consolidated'])")"
assert_eq "manifest: 2 held" "2" "$(jget "len(d['held'])")"
assert_eq "manifest: held[0] names acme/alpha (repo, not owner)" "acme/alpha" "$(jget "d['held'][0]['repo']")"
assert_eq "manifest: held[0] names the missing label" "papercut-fix-now" "$(jget "d['held'][0]['labels'][0]")"

# The acme/ledger held entry is reached by two DIFFERENT target names
# (claude-code, an external target; unowned, the literal) that both resolve
# to it -- each cluster record must keep its own target, or this collapses
# into an entry nothing can attribute back to either target.
assert_eq "manifest: acme/ledger held entry has 2 clusters" "2" "$(jget "len(next(h for h in d['held'] if h['repo']=='acme/ledger')['clusters'])")"
assert_eq "manifest: acme/ledger held clusters carry both distinct target names" "claude-code,unowned" "$(jget "','.join(c['target'] for c in next(h for h in d['held'] if h['repo']=='acme/ledger')['clusters'])")"
assert_eq "manifest: noop count is 2" "2" "$(jget "d['noop']")"
assert_eq "manifest: calls copied verbatim from --tracked" "5" "$(jget "d['calls']['list']")"
assert_eq "manifest: calls copied verbatim from --tracked" "1" "$(jget "d['calls']['comments']")"
assert_eq "manifest: beta's labels exclude papercut-fix-now" "no" "$(jget "'yes' if 'papercut-fix-now' in next(f for f in d['filed'] if f['target']=='beta')['labels'] else 'no'")"
assert_eq "manifest: gamma's labels include papercut-fix-now" "yes" "$(jget "'yes' if 'papercut-fix-now' in next(f for f in d['filed'] if f['target']=='gamma')['labels'] else 'no'")"

# The two epsilon entries must carry DIFFERENT label lists (this is what the
# repo-wide-union bug broke: both got the same, wrong, combined set).
epsilon_high_labels="$(jget "','.join(next(f for f in d['filed'] if f['title']=='Epsilon high severity thing')['labels'])")"
epsilon_low_labels="$(jget "','.join(next(f for f in d['filed'] if f['title']=='Epsilon low severity thing')['labels'])")"
assert_eq "manifest: epsilon high-severity cluster's own labels" "papercut,priority:high" "$epsilon_high_labels"
assert_eq "manifest: epsilon low-severity cluster's own labels" "papercut,priority:low,papercut-fix-now" "$epsilon_low_labels"

# =====================================================================
# Manifest merge: a pre-existing manifest's sections owned by a later task
# are preserved across a re-run.
# =====================================================================

python3 - "$manifest_file" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["resolved"] = [{"id": "pc_zzzzzzzz-0000-4000-8000-000000000099", "url": "https://example.com/pr/1"}]
data["flush"] = "resolutions spooled, not published (strict profile)"
json.dump(data, open(path, "w", encoding="utf-8"))
PY

: >"$call_log"
run_file --clusters "$clusters_json" --owners "$owners_json" --open "$open_jsonl" --tracked "$tracked_json" --apply
assert_eq "merge re-run: exit 0" "0" "$rc"

merged="$(cat "$manifest_file")"
resolved_len="$(printf '%s' "$merged" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('resolved', [])))")"
flush_val="$(printf '%s' "$merged" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('flush', ''))")"
assert_eq "merge re-run: preserves the resolved section this script does not own" "1" "$resolved_len"
assert_eq "merge re-run: preserves the flush section this script does not own" "resolutions spooled, not published (strict profile)" "$flush_val"

unset PAPERCUT_GH_CMD PAPERCUT_TRIAGE_DIR

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut_file tests passed."
  exit 0
fi
echo "Some papercut_file tests FAILED."
exit 1
