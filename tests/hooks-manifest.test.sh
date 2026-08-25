#!/usr/bin/env bash
# Tests for the plugin's hooks manifest (hooks/hooks.json) — every hook command
# must be plugin-relative, and the repo must carry no leftover reference to the
# dotfiles checkout the pipeline was ported out of. Run:
#   bash tests/hooks-manifest.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hooks_json="$repo_root/hooks/hooks.json"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

# --- 1. the manifest parses -------------------------------------------------
if [ -f "$hooks_json" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$hooks_json" 2>/dev/null; then
  pass "hooks/hooks.json exists and is valid JSON"
else
  fail_test "hooks/hooks.json exists and is valid JSON"
  printf '\nManifest unusable; skipping the rest.\n'
  exit 1
fi

# --- 2. every command path is plugin-relative and points at a real, executable
# script in this repo. -------------------------------------------------------
commands="$(python3 -c '
import json
import sys

with open(sys.argv[1], "rb") as f:
    data = json.load(f)

for event, entries in data.get("hooks", {}).items():
    for entry in entries:
        for hook in entry.get("hooks", []):
            print("%s\t%s" % (event, hook.get("command", "")))
' "$hooks_json")"

prefix='${CLAUDE_PLUGIN_ROOT}/'
count=0
while IFS=$'\t' read -r event command; do
  [ -n "$command" ] || continue
  count=$((count + 1))
  token="${command%% *}"
  case "$token" in
    "$prefix"*) ;;
    *)
      fail_test "$event: command is not plugin-relative: $token"
      continue
      ;;
  esac
  resolved="$repo_root/${token#"$prefix"}"
  if [ ! -f "$resolved" ]; then
    fail_test "$event: $token resolves to a missing file ($resolved)"
  elif [ ! -x "$resolved" ]; then
    fail_test "$event: $token resolves to a non-executable file ($resolved)"
  else
    pass "$event: $token resolves to an executable script"
  fi
done <<<"$commands"

if [ "$count" -eq 0 ]; then
  fail_test "the manifest declares at least one hook command"
fi

# --- 3. the five production hook entries are all present -------------------
# Mirrors agents/settings.json: Notification and PostToolUseFailure -> anchor,
# SessionStart -> flush --hook and sweep, SessionEnd -> capture.
expect_entry() {
  # expect_entry <event> <substring>
  if printf '%s\n' "$commands" | grep -qF "$1	$2"; then
    pass "$1 declares $2"
  else
    fail_test "$1 declares $2"
  fi
}
expect_entry Notification "$prefix"scripts/papercut-anchor.sh
expect_entry PostToolUseFailure "$prefix"scripts/papercut-anchor.sh
expect_entry SessionStart "$prefix"scripts/papercut-flush.sh
expect_entry SessionStart "$prefix"scripts/papercut-sweep.sh
expect_entry SessionEnd "$prefix"scripts/papercut-capture.sh

# The SessionStart flush entry must go through the fail-silent wrapper.
if printf '%s\n' "$commands" | grep -qF "papercut-flush.sh --hook"; then
  pass "SessionStart invokes papercut-flush.sh through --hook"
else
  fail_test "SessionStart invokes papercut-flush.sh through --hook"
fi

# --- 4. async/timeout mirror production ------------------------------------
# Verified as accepted by a plugin manifest — see docs/plugin-surface.md's
# 2026-08-25 probe section.
attrs="$(python3 -c '
import json
import sys

with open(sys.argv[1], "rb") as f:
    data = json.load(f)

for event, entries in data.get("hooks", {}).items():
    for entry in entries:
        for hook in entry.get("hooks", []):
            print("%s|%s|%s|%s" % (
                event,
                hook.get("command", "").split()[0].rsplit("/", 1)[-1],
                hook.get("async", False),
                hook.get("timeout", ""),
            ))
' "$hooks_json")"

expect_attrs() {
  # expect_attrs <event|script|async|timeout>
  if printf '%s\n' "$attrs" | grep -qxF "$1"; then
    pass "attrs $1"
  else
    fail_test "attrs $1 (got: $(printf '%s\n' "$attrs" | tr '\n' ' '))"
  fi
}
expect_attrs 'Notification|papercut-anchor.sh|True|5'
expect_attrs 'PostToolUseFailure|papercut-anchor.sh|True|5'
expect_attrs 'SessionStart|papercut-flush.sh|True|'
expect_attrs 'SessionStart|papercut-sweep.sh|True|'
expect_attrs 'SessionEnd|papercut-capture.sh|True|180'

# --- 5. no leftover dotfiles-checkout path anywhere in the tracked tree ----
# The needle is assembled at runtime so this suite is not itself a hit.
needle="src/dot""files"
hits="$(git -C "$repo_root" grep -nF "$needle" -- . 2>/dev/null)"
if [ -z "$hits" ]; then
  pass "no '\$HOME/$needle' reference in any tracked file"
else
  fail_test "tracked files still reference '$needle':
$hits"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll hooks-manifest tests passed.\n'
else
  printf '\nSome hooks-manifest tests FAILED.\n'
fi
exit "$fail"
