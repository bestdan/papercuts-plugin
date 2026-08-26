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
    PAPERCUT_SETTINGS="$dir/settings.json" \
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

# --- 6. permission-entry: absence is the normal state — advice, not a fail -
# The skill self-authorizes the append for its own turn, so no entry is a
# PASS. The doctor must still print the fallback advice, and must not crash
# on a missing PAPERCUT_SETTINGS file.
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
run_doctor "$dir"
assert_no_failing_check "no settings file" permission-entry
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

# --- 6b. permission-entry: absent entry with an EMPTY settings file --------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
printf '{}\n' >"$dir/settings.json"
run_doctor "$dir"
assert_no_failing_check "empty settings.json" permission-entry

# --- 6c. permission-entry: malformed JSON is treated as "not found", not a
# crash -----------------------------------------------------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
printf '{ not valid json' >"$dir/settings.json"
run_doctor "$dir"
assert_no_failing_check "malformed settings.json" permission-entry

# --- 6d. permission-entry passes: the resolved absolute path spelling ------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
resolved_target="$script_dir/papercut_append.py"
python3 -c '
import json, sys
path, entry = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    json.dump({"permissions": {"allow": [f"Bash(python3 {entry}:*)"]}}, f)
' "$dir/settings.json" "$resolved_target"
run_doctor "$dir"
assert_no_failing_check "resolved-path spelling" permission-entry
if printf '%s\n' "$out" | grep -qF 'If a capture ever stops'; then
  fail_test "a present entry must not print the fallback advice"
else
  pass "a present entry prints no fallback advice"
fi

# --- 6e/6f. permission-entry passes: $HOME and ~ spellings -----------------
# The doctor rewrites its own resolved path relative to $HOME. To exercise
# that rewrite (the real install's script_dir already sits under the real
# $HOME, but the test-pinned $HOME does not), point HOME at script_dir's
# grandparent for just these two cases so the prefix match fires.
fake_home="$(dirname "$(dirname "$script_dir")")"
rel_suffix="${resolved_target#"$fake_home"}"

dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
python3 -c '
import json, sys
path, entry = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    json.dump({"permissions": {"allow": [f"Bash(python3 {entry}:*)"]}}, f)
' "$dir/settings.json" "\$HOME$rel_suffix"
run_doctor "$dir" "HOME=$fake_home"
assert_no_failing_check "\$HOME spelling" permission-entry
if printf '%s\n' "$out" | grep -qF 'If a capture ever stops'; then
  fail_test "\$HOME spelling was not detected (fallback advice printed)"
else
  pass "\$HOME spelling detected (no fallback advice)"
fi

dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
python3 -c '
import json, sys
path, entry = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    json.dump({"permissions": {"allow": [f"Bash(python3 {entry}:*)"]}}, f)
' "$dir/settings.json" "~$rel_suffix"
run_doctor "$dir" "HOME=$fake_home"
assert_no_failing_check "~ spelling" permission-entry
if printf '%s\n' "$out" | grep -qF 'If a capture ever stops'; then
  fail_test "~ spelling was not detected (fallback advice printed)"
else
  pass "~ spelling detected (no fallback advice)"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll papercut-doctor tests passed.\n'
else
  printf '\nSome papercut-doctor tests FAILED.\n'
fi
exit "$fail"
