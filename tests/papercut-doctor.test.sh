#!/usr/bin/env bash
# Tests for scripts/papercut-doctor.sh — the install checker. Each case builds a
# deliberately broken install and asserts the doctor exits non-zero AND names
# the specific failing check on its own line. Run:
#   bash tests/papercut-doctor.test.sh
#
# Every path the doctor reads is redirected into a per-case temp dir, so this
# suite never touches a real install.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
doctor="$script_dir/papercut-doctor.sh"

fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

# Each case gets its own directory. mktemp rather than an incrementing counter:
# this is called in a command substitution, so a counter would be incremented in
# a subshell and every case would silently share one directory.
new_dir() {
  mktemp -d "$workdir/case.XXXXXX"
}

# bare_ledger <dir> <origin-url> — a clone whose origin points at <origin-url>.
# The URL is never fetched from; the doctor only reads it.
bare_ledger() {
  local dir="$1" url="$2"
  git init --quiet "$dir" >/dev/null 2>&1
  git -C "$dir" config user.name "papercut test" >/dev/null 2>&1
  git -C "$dir" config user.email "papercut@example.invalid" >/dev/null 2>&1
  git -C "$dir" remote add origin "$url" >/dev/null 2>&1
}

# run_doctor <dir> [extra env assignments...] — prints stdout, sets $rc.
run_doctor() {
  local dir="$1"
  shift
  out="$(env \
    PAPERCUT_CONFIG="$dir/config.toml" \
    PAPERCUT_LEDGER_DIR="$dir/ledger" \
    PAPERCUT_DENYLIST="$dir/denylist.txt" \
    PAPERCUT_SPOOL="$dir/spool/spool.jsonl" \
    PAPERCUT_DETECT_CMD='echo default' \
    "$@" \
    bash "$doctor" 2>&1)"
  rc=$?
}

# assert_failing_check <label> <check-name>
assert_failing_check() {
  local label="$1" name="$2"
  if [ "$rc" -eq 0 ]; then
    fail_test "$label: doctor exited 0, expected non-zero
$out"
    return
  fi
  if printf '%s\n' "$out" | grep -q "^FAIL: $name: "; then
    pass "$label: non-zero exit and a FAIL line naming '$name'"
  else
    fail_test "$label: expected a 'FAIL: $name:' line, got:
$out"
  fi
}

# assert_no_failing_check <label> <check-name>
assert_no_failing_check() {
  local label="$1" name="$2"
  if printf '%s\n' "$out" | grep -q "^FAIL: $name: "; then
    fail_test "$label: '$name' failed unexpectedly:
$out"
  else
    pass "$label: '$name' did not fail"
  fi
}

# --- 1. missing config -----------------------------------------------------
dir="$(new_dir)"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
run_doctor "$dir"
assert_failing_check "missing config" config
# The ledger check has no trust anchor without a config, so it must also fail
# rather than silently accepting an unvetted origin.
assert_failing_check "missing config" ledger

# --- 2. wrong ledger origin ------------------------------------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "https://evil.example/you/papercuts-ledger.git"
run_doctor "$dir"
assert_failing_check "wrong ledger origin" ledger
assert_no_failing_check "wrong ledger origin" config

# --- 2b. control: the SAME config with the matching origin passes ----------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
run_doctor "$dir"
assert_no_failing_check "matching ledger origin" ledger

# --- 3. world-readable denylist under the strict profile -------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
printf 'acme-internal-codename\n' >"$dir/denylist.txt"
chmod 0644 "$dir/denylist.txt"
run_doctor "$dir" PAPERCUT_DETECT_CMD='echo strict'
assert_failing_check "world-readable denylist (strict)" denylist
assert_no_failing_check "world-readable denylist (strict)" ledger

# --- 3b. control: same denylist at 0600 under the strict profile passes -----
chmod 0600 "$dir/denylist.txt"
run_doctor "$dir" PAPERCUT_DETECT_CMD='echo strict'
assert_no_failing_check "0600 denylist (strict)" denylist

# --- 3c. strict profile with NO denylist fails -----------------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
run_doctor "$dir" PAPERCUT_DETECT_CMD='echo strict'
assert_failing_check "no denylist (strict)" denylist

# --- 4. spool directory permissions ---------------------------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
mkdir -p "$dir/spool"
chmod 0755 "$dir/spool"
run_doctor "$dir"
assert_failing_check "world-readable spool dir" spool-perms
chmod 0700 "$dir/spool"
run_doctor "$dir"
assert_no_failing_check "0700 spool dir" spool-perms

# --- 5. the hooks check reads the manifest next to the doctor --------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
run_doctor "$dir"
assert_no_failing_check "shipped manifest" hooks

# --- 6. the printed permissions.allow entry names the resolved abs path ----
if printf '%s\n' "$out" | grep -qF "\"Bash(python3 $script_dir/papercut_append.py:*)\""; then
  pass "prints the permissions.allow entry with the resolved absolute path"
else
  fail_test "prints the permissions.allow entry with the resolved absolute path:
$out"
fi
if printf '%s\n' "$out" | grep -qF 'CLAUDE_PLUGIN_ROOT'; then
  fail_test "the printed permission entry must not carry an unresolved variable"
else
  pass "the printed permission entry carries no unresolved variable"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll papercut-doctor tests passed.\n'
else
  printf '\nSome papercut-doctor tests FAILED.\n'
fi
exit "$fail"
