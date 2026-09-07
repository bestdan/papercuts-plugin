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

# The gh stub every run_doctor call uses, so no case can reach the network.
# `label list` returns $gh_stub_response's content (default "[]") unless
# $gh_stub_fail_marker exists, in which case it fails; `label list` without
# --limit in argv is itself treated as a stub failure. `label create` appends
# its full argv to $gh_stub_create_log — the doctor must never call it.
gh_stub="$workdir/gh-stub.sh"
gh_stub_create_log="$workdir/create.log"
gh_stub_response="$workdir/label-response.json"
gh_stub_fail_marker="$workdir/label-list-fail"
cat >"$gh_stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
log="$gh_stub_create_log"
response="$gh_stub_response"
fail_marker="$gh_stub_fail_marker"
if [ "\$1" = "label" ] && [ "\$2" = "list" ]; then
  limit=""
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "--limit" ]; then limit="\$a"; fi
    prev="\$a"
  done
  if [ -z "\$limit" ]; then
    echo "stub: label list called without --limit" >&2
    exit 1
  fi
  if [ -f "\$fail_marker" ]; then
    echo "boom: simulated gh failure" >&2
    exit 1
  fi
  if [ -f "\$response" ]; then
    cat "\$response"
  else
    echo '[]'
  fi
  exit 0
elif [ "\$1" = "label" ] && [ "\$2" = "create" ]; then
  echo "\$@" >>"\$log"
  exit 0
fi
echo "stub: unexpected gh call: \$*" >&2
exit 1
STUB
chmod +x "$gh_stub"
: >"$gh_stub_create_log"

# Positive control: prove the stub itself logs a create call correctly,
# before relying on an empty log to mean "the doctor never created a label."
"$gh_stub" label create x --repo a/b --force
control_count="$(grep -c . "$gh_stub_create_log")"
if [ "$control_count" -eq 1 ] && grep -qF -- "label create x --repo a/b --force" "$gh_stub_create_log"; then
  pass "gh stub positive control: one create call logged"
else
  fail_test "gh stub positive control: expected one logged create call, got:
$(cat "$gh_stub_create_log")"
fi
: >"$gh_stub_create_log"

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
    PAPERCUT_GH_CMD="$gh_stub" \
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
# owners has no PAPERCUT_OWNERS here either, so it cannot resolve a registry
# location without the (broken) config — it must fail closed, not crash.
assert_failing_check "missing config" owners
if printf '%s\n' "$out" | grep -q "^FAIL: owners: skipped"; then
  pass "missing config: owners check reports 'skipped', not a crash"
else
  fail_test "missing config: expected owners to report 'skipped', got:
$out"
fi

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

# --- 7. owners: registry checks --------------------------------------------
write_owners_fixture() {
  local dir="$1"
  cat >"$dir/owners.toml" <<'EOF'
[unowned]
repo = "acme/papercuts-ledger"

[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
labels = ["status:0_untriaged"]
EOF
}

# --- 7a. absent registry: PASS, not a fail (capture-only install is valid) -
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
run_doctor "$dir"
assert_no_failing_check "no owners.toml in ledger dir" owners

# --- 7b. PAPERCUT_OWNERS pointing at a directory: not "absent" (-e is true),
# falls through to the loader and fails on its own message, not a crash -----
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
mkdir -p "$dir/owners-is-a-dir"
run_doctor "$dir" "PAPERCUT_OWNERS=$dir/owners-is-a-dir"
assert_failing_check "PAPERCUT_OWNERS is a directory" owners

# --- 7c. invalid registry: FAIL naming the parse problem --------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
cat >"$dir/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "linear"
repo = "acme/dotfiles"
scope = "shell config"
EOF
run_doctor "$dir" "PAPERCUT_OWNERS=$dir/owners.toml"
assert_failing_check "invalid registry" owners

# --- 7d. valid registry, labels missing: FAIL naming the owner and the
# fix-it command, and covering the unowned target too -----------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
write_owners_fixture "$dir"
printf '[]' >"$gh_stub_response"
run_doctor "$dir" "PAPERCUT_OWNERS=$dir/owners.toml"
assert_failing_check "missing labels" owners
if printf '%s\n' "$out" | grep -q "^FAIL: owners:.*dotfiles.*papercut-labels\.sh"; then
  pass "missing labels: names the owner and papercut-labels.sh"
else
  fail_test "missing labels: expected owner + papercut-labels.sh in the FAIL line, got:
$out"
fi
if printf '%s\n' "$out" | grep -q "^FAIL: owners:.*unowned"; then
  pass "missing labels: covers the unowned target too"
else
  fail_test "missing labels: expected 'unowned' named in the FAIL line, got:
$out"
fi
rm -f "$gh_stub_response"

# --- 7e. valid registry, all labels present: no fail ------------------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
write_owners_fixture "$dir"
printf '[{"name":"papercut"},{"name":"priority:high"},{"name":"priority:medium"},{"name":"priority:low"},{"name":"papercut-fix-now"},{"name":"status:0_untriaged"}]' >"$gh_stub_response"
run_doctor "$dir" "PAPERCUT_OWNERS=$dir/owners.toml"
assert_no_failing_check "all labels present" owners
rm -f "$gh_stub_response"

# --- 7f. gh label list fails: FAIL mentioning the failed call, and NEVER
# reporting labels as missing on the strength of that failure ---------------
dir="$(new_dir)"
printf '[ledger]\nrepo = "you/papercuts-ledger"\n' >"$dir/config.toml"
bare_ledger "$dir/ledger" "git@github.com:you/papercuts-ledger.git"
write_owners_fixture "$dir"
: >"$gh_stub_fail_marker"
run_doctor "$dir" "PAPERCUT_OWNERS=$dir/owners.toml"
assert_failing_check "gh label list fails" owners
if printf '%s\n' "$out" | grep -q "^FAIL: owners:.*gh label list failed.*unsandboxed with gh authenticated"; then
  pass "gh label list fails: names the failed call and the fix"
else
  fail_test "gh label list fails: expected the failed-list message, got:
$out"
fi
if printf '%s\n' "$out" | grep -q "^FAIL: owners:.*missing:"; then
  fail_test "gh label list fails: must NOT report labels as missing"
else
  pass "gh label list fails: does not report labels as missing"
fi
rm -f "$gh_stub_fail_marker"

# --- 7g. the doctor never calls gh label create, across this whole suite ---
if [ -s "$gh_stub_create_log" ]; then
  fail_test "doctor called gh label create at some point in this suite:
$(cat "$gh_stub_create_log")"
else
  pass "gh label create was never called by the doctor, across the whole suite"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll papercut-doctor tests passed.\n'
else
  printf '\nSome papercut-doctor tests FAILED.\n'
fi
exit "$fail"
