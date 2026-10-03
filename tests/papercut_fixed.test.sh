#!/usr/bin/env bash
# Tests for papercut_fixed.py -- resolving papercuts whose tracking issue a
# merged pull request closed.
# Run:
#   bash tests/papercut_fixed.test.sh
#
# The gh stub answers the closer query from fixtures recorded against
# bestdan/dotfiles with the script's own QUERY (tests/fixtures/papercut_fixed/):
#   dotfiles-933.json  closed by a merged pull request
#   dotfiles-857.json  closed as not planned, no closer
# The unmerged-PR and commit-closer responses are derived from the 933
# recording below, changing only the closer, so their shape is the recorded one.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script="$(dirname "$0")/../scripts/papercut_fixed.py"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/papercut_fixed"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-fixed-test.XXXXXX")"
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

# mget <python expression over `d`> -- reads the run's manifest
mget() {
  python3 - "$manifest" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(eval(sys.argv[2]))
PY
}

run_fixed() {
  # run_fixed <args...> -- sets $out, $err, $rc. Never reads stdin.
  out="$(python3 "$script" "$@" </dev/null 2>"$workdir/stderr")"
  rc=$?
  err="$(cat "$workdir/stderr")"
}

# =====================================================================
# Fixtures.
# =====================================================================

merged_pr_url="$(python3 -c '
import json, sys
n = json.load(open(sys.argv[1]))["data"]["repository"]["issue"]["timelineItems"]["nodes"]
c = n[-1]["closer"]
assert c["__typename"] == "PullRequest" and c["merged"] is True, c
print(c["url"])
' "$fixture_dir/dotfiles-933.json")"
assert_eq "recorded fixture: 933 is closed by a merged PR" "0" "$?"

python3 - "$fixture_dir/dotfiles-933.json" "$workdir" <<'PY'
import copy, json, sys
src, out = sys.argv[1], sys.argv[2]
base = json.load(open(src))
unmerged = copy.deepcopy(base)
unmerged["data"]["repository"]["issue"]["timelineItems"]["nodes"][-1]["closer"]["merged"] = False
json.dump(unmerged, open(f"{out}/closer-unmerged.json", "w"))
commit = copy.deepcopy(base)
commit["data"]["repository"]["issue"]["timelineItems"]["nodes"][-1]["closer"] = {
    "__typename": "Commit",
    "url": "https://github.com/acme/alpha/commit/0123456789abcdef0123456789abcdef01234567",
}
json.dump(commit, open(f"{out}/closer-commit.json", "w"))
PY

id_a="pc_aaaaaaaa-0000-4000-8000-000000000001"
id_b="pc_bbbbbbbb-0000-4000-8000-000000000002"
id_c="pc_cccccccc-0000-4000-8000-000000000003"
id_d="pc_dddddddd-0000-4000-8000-000000000004"
id_e="pc_eeeeeeee-0000-4000-8000-000000000005"
id_f="pc_ffffffff-0000-4000-8000-000000000006"
id_g="pc_99999999-0000-4000-8000-000000000007"

# Issue numbers pick the stub's response:
#   1 merged PR (ids a, b)      2 unmerged PR (c)     3 commit closer (d)
#   4 not planned, no closer (e)
#   5 closed, but its only id (f) is also on open issue 6 -- a rerouted source
#   7 merged PR (g), whose id the resolve stub reports as already resolved
tracked_json="$workdir/tracked.json"
python3 - "$tracked_json" "$id_a" "$id_b" "$id_c" "$id_d" "$id_e" "$id_f" "$id_g" <<'PY'
import json, sys
path, a, b, c, d, e, f, g = sys.argv[1:]

def entry(repo, number, state, reason, full_id):
    return {"repo": repo, "number": number, "url": f"https://github.com/{repo}/issues/{number}",
            "state": state, "state_reason": reason, "labels": ["papercut"], "full_id": full_id, "source": "body"}

index = {}
for args in [("acme/alpha", 1, "CLOSED", "COMPLETED", a), ("acme/alpha", 1, "CLOSED", "COMPLETED", b),
             ("acme/alpha", 2, "CLOSED", "COMPLETED", c), ("acme/alpha", 3, "CLOSED", "COMPLETED", d),
             ("acme/alpha", 4, "CLOSED", "NOT_PLANNED", e), ("acme/alpha", 5, "CLOSED", "COMPLETED", f),
             ("acme/beta", 6, "OPEN", None, f), ("acme/alpha", 7, "CLOSED", "COMPLETED", g)]:
    index.setdefault(args[4][:11], []).append(entry(*args))
json.dump({"index": index, "calls": {"list": 2, "comments": 0}}, open(path, "w"))
PY

call_log="$workdir/calls.log"

stub_gh="$workdir/stub-gh.sh"
cat >"$stub_gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_CALL_LOG"
number=""
for arg in "$@"; do
  case "$arg" in number=*) number="${arg#number=}" ;; esac
done
case "$number" in
  1 | 7) cat "$STUB_FIXTURE_DIR/dotfiles-933.json" ;;
  2) cat "$STUB_WORKDIR/closer-unmerged.json" ;;
  3) cat "$STUB_WORKDIR/closer-commit.json" ;;
  4) cat "$STUB_FIXTURE_DIR/dotfiles-857.json" ;;
  *)
    echo "stub gh: unexpected issue number '$number'" >&2
    exit 1
    ;;
esac
STUB

stub_resolve="$workdir/stub-resolve.sh"
cat >"$stub_resolve" <<'STUB'
#!/usr/bin/env bash
echo "resolve $*" >>"$STUB_CALL_LOG"
if [ "$1" = "$STUB_ALREADY_ID" ]; then
  echo "error: '$1' already has a resolution: fixed (https://example.com/pr/1)" >&2
  echo "       pass --force to append another resolution anyway" >&2
  exit 1
fi
exit 0
STUB

stub_flush="$workdir/stub-flush.sh"
cat >"$stub_flush" <<'STUB'
#!/usr/bin/env bash
echo "flush $*" >>"$STUB_CALL_LOG"
echo "papercut-flush: published 2 record(s) to ledger/2026-10.jsonl @ abc1234 on origin/main (local clone intentionally untouched)"
exit "${STUB_FLUSH_RC:-0}"
STUB
chmod +x "$stub_gh" "$stub_resolve" "$stub_flush"

export STUB_CALL_LOG="$call_log" STUB_FIXTURE_DIR="$fixture_dir" STUB_WORKDIR="$workdir" STUB_ALREADY_ID="$id_g"
export PAPERCUT_GH_CMD="$stub_gh" PAPERCUT_RESOLVE_CMD="$stub_resolve" PAPERCUT_FLUSH_CMD="$stub_flush"
export PAPERCUT_DETECT_CMD="echo default"
export PAPERCUT_TRIAGE_DIR="$workdir/triage"
manifest="$PAPERCUT_TRIAGE_DIR/$(date +%F).json"

# =====================================================================
# Dry run: the plan, and no resolve, flush, or manifest.
# =====================================================================

: >"$call_log"
run_fixed --tracked "$tracked_json"
assert_eq "dry run: exit 0" "0" "$rc"
assert_contains "dry run: plans a resolve for each id on the merged-PR issue" "$out" "resolve      $id_a fixed $merged_pr_url  https://github.com/acme/alpha/issues/1"
assert_contains "dry run: plans the second id too" "$out" "resolve      $id_b fixed $merged_pr_url"
assert_contains "dry run: plans the flush" "$out" "flush        papercut-flush.sh --force (default profile)"
assert_not_contains "dry run: no resolve call" "$(cat "$call_log")" "resolve "
assert_not_contains "dry run: no flush call" "$(cat "$call_log")" "flush "
assert_eq "dry run: no manifest" "no" "$([ -f "$manifest" ] && echo yes || echo no)"

# =====================================================================
# --apply, default profile.
# =====================================================================

: >"$call_log"
run_fixed --tracked "$tracked_json" --apply
assert_eq "apply: exit 0" "0" "$rc"
calls="$(cat "$call_log")"

# The resolve stub receives the full pc_<uuid>, never the 8-character prefix.
assert_contains "apply: resolves id a by its full id" "$calls" "resolve $id_a fixed $merged_pr_url"
assert_contains "apply: resolves id b by its full id" "$calls" "resolve $id_b fixed $merged_pr_url"
assert_eq "apply: no resolve call carries a bare prefix" "0" "$(grep -cE '^resolve pc_[0-9a-f]{8} ' "$call_log")"
assert_eq "apply: exactly three resolve calls (a, b, and the already-resolved g)" "3" "$(grep -c '^resolve ' "$call_log")"

assert_not_contains "apply: unmerged PR closer is not resolved" "$calls" "resolve $id_c"
assert_not_contains "apply: commit closer is not resolved" "$calls" "resolve $id_d"
assert_not_contains "apply: not-planned issue is not resolved" "$calls" "resolve $id_e"

# A rerouted source: never queried, never resolved, never reported.
assert_contains "apply: rerouted source is skipped" "$out" "skip         rerouted https://github.com/acme/alpha/issues/5"
assert_not_contains "apply: rerouted source's closer is never queried" "$calls" "number=5"
assert_not_contains "apply: rerouted source's id is not resolved" "$calls" "resolve $id_f"

assert_eq "apply: flush called exactly once" "1" "$(grep -c '^flush ' "$call_log")"
assert_contains "apply: flush called with --force" "$calls" "flush --force"

assert_eq "manifest: validates against schema/manifest.v1.json" "" "$(python3 - "$manifest" "$repo_root" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("papercut_file", f"{sys.argv[2]}/scripts/papercut_file.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.validate_structure(json.load(open(sys.argv[1])), m.load_schema("manifest.v1.json")) or "")
PY
)"
assert_eq "manifest: resolved ids" "$id_a,$id_b" "$(mget "','.join(r['id'] for r in d['resolved'])")"
assert_eq "manifest: resolved carries the PR url" "$merged_pr_url" "$(mget "d['resolved'][0]['fix_url']")"
assert_eq "manifest: already-resolved refusal is skipped, not an error" "$id_g:already resolved" "$(mget "','.join(s['id'] + ':' + s['reason'] for s in d['skipped'])")"
assert_eq "manifest: closed without evidence, in issue order" "2:PullRequest,3:Commit,4:None" \
  "$(mget "','.join(c['url'].rsplit('/', 1)[1] + ':' + str(c['closer']) for c in d['closed_without_evidence'])")"
assert_eq "manifest: not-planned keeps its state_reason" "NOT_PLANNED" "$(mget "d['closed_without_evidence'][2]['state_reason']")"
assert_eq "manifest: rerouted source is not reported" "no" "$(mget "'yes' if any(c['url'].endswith('/5') for c in d['closed_without_evidence']) else 'no'")"
assert_contains "manifest: flush records the confirmation line" "$(mget "d['flush']")" "papercut-flush: published 2 record(s)"
assert_eq "manifest: sections papercut_file.py owns are written empty" "0,0,0,0" "$(mget "f\"{len(d['filed'])},{len(d['consolidated'])},{len(d['held'])},{d['noop']}\"")"

# =====================================================================
# Same-day re-run: resolved appends; the latest run's other sections win.
# papercut_file.py's sections are preserved.
# =====================================================================

python3 - "$manifest" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["filed"] = [{"papercut_ids": ["pc_00000000-0000-4000-8000-000000000000"], "target": "alpha", "repo": "acme/alpha",
               "title": "t", "labels": ["papercut"], "url": "https://github.com/acme/alpha/issues/99"}]
json.dump(d, open(sys.argv[1], "w"))
PY
: >"$call_log"
run_fixed --tracked "$tracked_json" --apply
assert_eq "re-run: exit 0" "0" "$rc"
assert_eq "re-run: resolved appends" "4" "$(mget "len(d['resolved'])")"
assert_eq "re-run: skipped is the latest run's" "1" "$(mget "len(d['skipped'])")"
assert_eq "re-run: papercut_file.py's filed entry is preserved" "1" "$(mget "len(d['filed'])")"

# =====================================================================
# Strict profile: flush is never called.
# =====================================================================

rm -rf "$PAPERCUT_TRIAGE_DIR"
: >"$call_log"
PAPERCUT_DETECT_CMD="echo strict" run_fixed --tracked "$tracked_json" --apply
assert_eq "strict: exit 0" "0" "$rc"
assert_eq "strict: the flush stub was never called" "0" "$(grep -c '^flush ' "$call_log")"
assert_eq "strict: manifest records the hold" "resolutions spooled, not published (strict profile)" "$(mget "d['flush']")"
assert_contains "strict: resolves still run" "$(cat "$call_log")" "resolve $id_a"

# Detection that fails is strict, as papercut-flush.sh treats it.
: >"$call_log"
PAPERCUT_DETECT_CMD="exit 1" run_fixed --tracked "$tracked_json" --apply
assert_eq "failed detection: the flush stub was never called" "0" "$(grep -c '^flush ' "$call_log")"

# =====================================================================
# A flush failure exits 1 and is recorded; the resolutions stay spooled.
# =====================================================================

rm -rf "$PAPERCUT_TRIAGE_DIR"
STUB_FLUSH_RC=3 run_fixed --tracked "$tracked_json" --apply
assert_eq "flush failure: exit 1" "1" "$rc"
assert_contains "flush failure: says the resolutions are spooled" "$err" "the resolutions are in the spool"
assert_contains "flush failure: manifest records it" "$(mget "d['flush']")" "failed (rc=3)"

# A resolve failure other than "already resolved" stops the run.
rm -rf "$PAPERCUT_TRIAGE_DIR"
PAPERCUT_RESOLVE_CMD="bash -c 'echo boom >&2; exit 1' --" run_fixed --tracked "$tracked_json" --apply
assert_eq "resolve failure: exit 1" "1" "$rc"
assert_contains "resolve failure: names the id" "$err" "papercut-resolve.sh $id_a failed"
assert_not_contains "resolve failure: no traceback" "$err" "Traceback"

unset PAPERCUT_GH_CMD PAPERCUT_RESOLVE_CMD PAPERCUT_FLUSH_CMD PAPERCUT_DETECT_CMD PAPERCUT_TRIAGE_DIR

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut_fixed tests passed."
  exit 0
fi
echo "Some papercut_fixed tests FAILED."
exit 1
