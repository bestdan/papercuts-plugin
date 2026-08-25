#!/usr/bin/env bash
# Bidirectional cross-check between the configuration reference and the code.
#
# A configuration reference drifts silently: a new env var lands in a script and
# nobody documents it, or a documented var is renamed out of existence and the
# doc keeps promising it. Neither shows up as a test failure anywhere else, and
# both cost a reader more than a missing doc would -- one hides a knob, the
# other sends them chasing a variable no script reads. So the two sets are
# diffed mechanically, in both directions. Run:
#   bash tests/docs-config-vars.test.sh
#
# Code side:  every papercut-prefixed env-var name appearing anywhere under
#             scripts/ -- shell ${VAR:-default} forms, python os.environ reads,
#             and the header comments that document them alike. The union is
#             deliberate: a name a script mentions is a name a reader can find.
# Doc side:   every such name appearing in docs/configuration.md.
#
# The prefix needle is assembled at runtime so this file is not itself a hit for
# a grep over tracked files.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
doc_rel="docs/configuration.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

prefix="PAPER""CUT_"

if [ ! -f "$repo_root/$doc_rel" ]; then
  fail_test "$doc_rel: file does not exist"
  printf '\nSome docs-config-vars tests FAILED.\n'
  exit 1
fi

# Emit three tab-separated sections: COUNT, ONLY_CODE, ONLY_DOC. Names are
# normalized by stripping trailing underscores, so a prose wildcard like the
# bare prefix followed by "*" cannot masquerade as a variable name.
report="$(python3 - "$repo_root" "$doc_rel" "$prefix" <<'PY'
import os
import re
import sys

root, doc_rel, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
pattern = re.compile(re.escape(prefix) + r"[A-Z0-9_]+")


def names(text):
    found = set()
    for raw in pattern.findall(text):
        name = raw.rstrip("_")
        if name.startswith(prefix):
            found.add(name)
    return found


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


code = set()
scripts = os.path.join(root, "scripts")
for entry in sorted(os.listdir(scripts)):
    path = os.path.join(scripts, entry)
    if os.path.isfile(path):
        code |= names(read(path))

doc = names(read(os.path.join(root, doc_rel)))

print("COUNT\t%d\t%d" % (len(code), len(doc)))
for name in sorted(code - doc):
    print("ONLY_CODE\t%s" % name)
for name in sorted(doc - code):
    print("ONLY_DOC\t%s" % name)
PY
)"

if [ -z "$report" ]; then
  fail_test "the extractor produced nothing — it is probably broken"
  printf '\nSome docs-config-vars tests FAILED.\n'
  exit 1
fi

code_count=0
doc_count=0
only_code=""
only_doc=""
while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    COUNT)
      code_count="$a"
      doc_count="$b"
      ;;
    ONLY_CODE) only_code="$only_code  $a"$'\n' ;;
    ONLY_DOC) only_doc="$only_doc  $a"$'\n' ;;
  esac
done <<<"$report"

# Guard the guard: an extractor that found nothing would make both diffs empty
# and pass vacuously. The pipeline has dozens of these variables, so a low
# count means the regex or the file walk broke, not that the code got simpler.
if [ "$code_count" -ge 30 ]; then
  pass "found $code_count env var(s) read under scripts/"
else
  fail_test "only $code_count env var(s) found under scripts/ — the extractor is probably broken"
fi

if [ -z "$only_code" ]; then
  pass "every env var under scripts/ appears in $doc_rel"
else
  fail_test "read by a script but undocumented in $doc_rel:
$only_code"
fi

if [ -z "$only_doc" ]; then
  pass "every env var named in $doc_rel is read by a script"
else
  fail_test "documented in $doc_rel but read by no script:
$only_doc"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll docs-config-vars tests passed (%s documented, %s in code).\n' \
    "$doc_count" "$code_count"
else
  printf '\nSome docs-config-vars tests FAILED.\n'
fi
exit "$fail"
