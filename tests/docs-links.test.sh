#!/usr/bin/env bash
# Tests that every relative link in the repo's prose resolves to a real file.
# A dead link in the install guide is the one documentation bug that stops a
# stranger cold, so it is checked mechanically rather than by reading. Run:
#   bash tests/docs-links.test.sh
#
# Scope: README.md, CONTRIBUTING.md, and docs/*.md. http(s) links and
# anchor-only links are skipped; a link carrying a #fragment is checked on its
# file part only (fragment targets are not verified).

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

# The set of prose files under check. Missing ones are a failure, not a skip:
# this suite is also the assertion that these files exist at all.
docs=(README.md CONTRIBUTING.md)
while IFS= read -r doc; do
  [ -n "$doc" ] || continue
  docs+=("docs/$doc")
done <<<"$(cd "$repo_root/docs" 2>/dev/null && ls -1 ./*.md 2>/dev/null | sed 's|^\./||')"

if [ "${#docs[@]}" -le 2 ]; then
  fail_test "found no docs/*.md files to check"
fi

# Emit "file<TAB>target" for every markdown inline link in the given files,
# with http(s) and anchor-only targets already dropped. Reference-style
# definitions ([label]: target) are matched too.
links="$(python3 - "$repo_root" "${docs[@]}" <<'PY'
import os
import re
import sys

root = sys.argv[1]
inline = re.compile(r"\]\(\s*([^)\s]+)")
refdef = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(\S+)", re.MULTILINE)

for rel in sys.argv[2:]:
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        print("%s\t!MISSING" % rel)
        continue
    # Drop fenced code blocks: a target inside an example is not a link.
    text = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
    targets = inline.findall(text) + refdef.findall(text)
    for target in targets:
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        print("%s\t%s" % (rel, target))
PY
)"

if [ -z "$links" ]; then
  fail_test "no relative links found at all — the extractor is probably broken"
fi

checked=0
while IFS=$'\t' read -r doc target; do
  [ -n "$doc" ] || continue
  if [ "$target" = "!MISSING" ]; then
    fail_test "$doc: file does not exist"
    continue
  fi
  # Strip a #fragment; check the file part only.
  file_part="${target%%#*}"
  [ -n "$file_part" ] || continue
  checked=$((checked + 1))
  base_dir="$repo_root/$(dirname "$doc")"
  resolved="$base_dir/$file_part"
  if [ -e "$resolved" ]; then
    pass "$doc -> $target"
  else
    fail_test "$doc -> $target does not resolve (looked at $resolved)"
  fi
done <<<"$links"

if [ "$checked" -eq 0 ]; then
  fail_test "checked zero relative links"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll %s doc link(s) resolve.\n' "$checked"
else
  printf '\nSome docs-links tests FAILED.\n'
fi
exit "$fail"
