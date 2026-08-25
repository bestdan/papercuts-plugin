#!/usr/bin/env bash
# Tests that the reader-facing docs carry no identity from the checkout this
# pipeline was ported out of. These files are written for a stranger, so a
# leftover username, employer, or personal path is a defect even though it
# reads as harmless. Run:
#   bash tests/docs-identity.test.sh
#
# One occurrence is allowed and unavoidable: the plugin's own install URL. It
# names the repo, not a person's environment.
#
# Every needle -- and the allowed URL that carries one of them -- is assembled
# at runtime so this suite is not itself a hit, matching the pattern in
# tests/hooks-manifest.test.sh.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

owner="best""dan"
employer="better""ment"
host_tag="NYC-BETTER""MENT"
dotpath="src/dot""files"
allowed="github.com/$owner/papercuts"

# The files the acceptance criterion names, plus every later reader-facing
# doc — added explicitly, never as a glob: docs/plugin-surface.md is excluded on
# purpose (internal probe notes with a deliberate dotfiles reference, linked
# only from CONTRIBUTING's internal-notes section).
#
# There is no employer-name exemption for a grandfathered schema value here, and
# no file needs one: `machine` is enum ["default", "strict"] in schema/v1.json,
# so the reference docs never have to name the pre-rename value.
files=(
  README.md
  docs/install.md
  docs/schema-compat.md
  docs/privacy.md
  docs/configuration.md
  docs/operations.md
  docs/architecture.md
  docs/schema.md
  LICENSE
  CONTRIBUTING.md
)

for rel in "${files[@]}"; do
  path="$repo_root/$rel"
  if [ ! -f "$path" ]; then
    fail_test "$rel: file does not exist"
    continue
  fi
  hits="$(python3 - "$path" "$allowed" "$owner" "$employer" "$host_tag" "$dotpath" <<'PY'
import sys

path, allowed = sys.argv[1], sys.argv[2]
needles = sys.argv[3:]

with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()

for lineno, line in enumerate(lines, 1):
    # Blank out every occurrence of the one allowed string before matching, so
    # the install URL cannot satisfy a needle it happens to contain. The
    # blanking is deliberately exact — lowercase https form only: any other
    # spelling of the URL fails loudly, which pins the docs to one canonical
    # form.
    haystack = line.replace(allowed, " " * len(allowed)).lower()
    for needle in needles:
        if needle.lower() in haystack:
            print("%d: %s (matched %r)" % (lineno, line.rstrip(), needle))
            break
PY
)"
  if [ -z "$hits" ]; then
    pass "$rel carries no identity string outside the install URL"
  else
    fail_test "$rel leaks identity:
$hits"
  fi
done

# Guard the guard: if the allowed-URL exemption stopped working, the check above
# would silently pass on anything. Assert the exemption is actually exercised --
# at least one checked file must contain the install URL.
found_url=0
for rel in "${files[@]}"; do
  if grep -qF "$allowed" "$repo_root/$rel" 2>/dev/null; then
    found_url=1
    break
  fi
done
if [ "$found_url" -eq 1 ]; then
  pass "the install-URL exemption is exercised by at least one file"
else
  fail_test "no checked file names the install URL — the exemption is untested"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll docs-identity tests passed.\n'
else
  printf '\nSome docs-identity tests FAILED.\n'
fi
exit "$fail"
