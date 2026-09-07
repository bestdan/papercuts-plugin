#!/usr/bin/env bash
# Tests for papercut_owners.py — the owners registry loader: location
# resolution ($PAPERCUT_OWNERS overriding the ledger clone), the closed name
# vocabulary, per-table required/optional fields, and the hard-error
# contract (a missing or unparseable registry is non-zero with nothing on
# stdout — triage without a registry is not a run).
# Run:
#   bash tests/papercut_owners.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

loader="$(dirname "$0")/../scripts/papercut_owners.py"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-owners-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

unset PAPERCUT_LEDGER_DIR
unset PAPERCUT_CONFIG

next_dir() {
  local d
  d="$workdir/$RANDOM$RANDOM"
  mkdir -p "$d"
  printf '%s' "$d"
}

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

run_loader() {
  # run_loader <owners.toml path> [extra args...] -> sets $out, $err, $rc
  local path="$1"
  shift
  out="$(PAPERCUT_OWNERS="$path" python3 "$loader" "$@" 2>"$workdir/stderr")"
  rc=$?
  err="$(cat "$workdir/stderr")"
}

# --- 1. valid file: exit 0, --json emits owners/external/unowned ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[unowned]
repo = "acme/papercuts-ledger"

[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config, agent instructions"
labels = ["status:0_untriaged", "auto:human-review-needed"]

[external.claude-code]
repo = "anthropics/claude-code"
scope = "Claude Code harness behaviour"
EOF
run_loader "$d/owners.toml" --json
assert_eq "valid file: exit 0" "0" "$rc"
assert_contains "valid file: owners.dotfiles present" "$out" '"dotfiles"'
assert_contains "valid file: owners.dotfiles labels" "$out" '"status:0_untriaged"'
assert_contains "valid file: external.claude-code present" "$out" '"claude-code"'
assert_contains "valid file: unowned.repo present" "$out" '"acme/papercuts-ledger"'

run_loader "$d/owners.toml"
assert_eq "valid file, human output: exit 0" "0" "$rc"
assert_contains "valid file, human output: names an owner" "$out" "dotfiles"
assert_contains "valid file, human output: names an external target" "$out" "claude-code"

# --- 2. missing file: hard error, nothing on stdout ---
d="$(next_dir)"
run_loader "$d/nope.toml"
assert_eq "missing file: exit 2 (the documented contract, not merely non-zero)" "2" "$rc"
assert_eq "missing file: stdout empty" "" "$out"
assert_contains "missing file: stderr names the path" "$err" "$d/nope.toml"

# --- 2b. the default location: PAPERCUT_OWNERS unset, registry found under
# the ledger dir -- via PAPERCUT_LEDGER_DIR, then via config.toml's ledger.dir.
# This is the path a real run takes; nothing else in this file exercises it. ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[unowned]
repo = "acme/papercuts-ledger"

[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
out="$(PAPERCUT_LEDGER_DIR="$d" python3 "$loader" --json 2>"$workdir/stderr")"
rc=$?
assert_eq "default location via PAPERCUT_LEDGER_DIR: exit 0" "0" "$rc"
assert_contains "default location via PAPERCUT_LEDGER_DIR: owner present" "$out" '"dotfiles"'

cat >"$d/config.toml" <<EOF
[ledger]
dir = "$d"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$loader" --json 2>"$workdir/stderr")"
rc=$?
assert_eq "default location via ledger.dir: exit 0" "0" "$rc"
assert_contains "default location via ledger.dir: owner present" "$out" '"dotfiles"'

d="$(next_dir)"
out="$(PAPERCUT_LEDGER_DIR="$d" python3 "$loader" --json 2>"$workdir/stderr")"
rc=$?
err="$(cat "$workdir/stderr")"
assert_eq "default location, no registry in ledger dir: exit 2" "2" "$rc"
assert_eq "default location, no registry in ledger dir: stdout empty" "" "$out"
assert_contains "default location, no registry in ledger dir: stderr names the expected path" "$err" "$d/owners.toml"

# --- 3. unknown tracker: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "linear"
repo = "acme/dotfiles"
scope = "shell config"
EOF
run_loader "$d/owners.toml"
assert_eq "unknown tracker: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "unknown tracker: stdout empty" "" "$out"
assert_contains "unknown tracker: stderr names the field" "$err" "tracker"

# --- 3b. repo not owner/name: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "dotfiles"
scope = "shell config"
EOF
run_loader "$d/owners.toml"
assert_eq "bad repo shape: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "bad repo shape: stdout empty" "" "$out"
assert_contains "bad repo shape: stderr names the expected form" "$err" "owner/name"

# --- 3c. name outside the closed vocabulary's regex: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.Dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
run_loader "$d/owners.toml"
assert_eq "bad name: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "bad name: stdout empty" "" "$out"
assert_contains "bad name: stderr says the name is invalid" "$err" "not a valid name"

# --- 3d. labels not an array of strings: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
labels = "status:0_untriaged"
EOF
run_loader "$d/owners.toml"
assert_eq "bad labels type: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "bad labels type: stdout empty" "" "$out"
assert_contains "bad labels type: stderr names the expected type" "$err" "labels must be an array"

# --- 4. missing scope: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
EOF
run_loader "$d/owners.toml"
assert_eq "missing scope: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "missing scope: stdout empty" "" "$out"
assert_contains "missing scope: stderr names the field" "$err" "scope"

# --- 5. name 'unowned' used as an owner: reserved, validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.unowned]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
run_loader "$d/owners.toml"
assert_eq "name 'unowned': non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "name 'unowned': stdout empty" "" "$out"
assert_contains "name 'unowned': stderr names it reserved" "$err" "unowned"

# --- 6. a name in both [owners] and [external]: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"

[external.dotfiles]
repo = "acme/dotfiles-mirror"
scope = "a mirror"
EOF
run_loader "$d/owners.toml"
assert_eq "duplicate name across tables: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "duplicate name across tables: stdout empty" "" "$out"
assert_contains "duplicate name across tables: stderr names it" "$err" "dotfiles"

# --- 7. an [external] entry with tracker: not allowed ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[external.claude-code]
tracker = "gh-issue"
repo = "anthropics/claude-code"
scope = "harness behaviour"
EOF
run_loader "$d/owners.toml"
assert_eq "external with tracker: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "external with tracker: stdout empty" "" "$out"
assert_contains "external with tracker: stderr names the field" "$err" "tracker"

# --- 7b. an [external] entry with labels: not allowed ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[external.claude-code]
repo = "anthropics/claude-code"
scope = "harness behaviour"
labels = ["status:0_untriaged"]
EOF
run_loader "$d/owners.toml"
assert_eq "external with labels: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "external with labels: stdout empty" "" "$out"
assert_contains "external with labels: stderr names the field" "$err" "labels"

# --- 8. unowned.repo defaulting from config.toml's ledger.repo ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
repo = "acme/papercuts-ledger"
EOF
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" PAPERCUT_OWNERS="$d/owners.toml" python3 "$loader" --json 2>"$workdir/stderr")"
rc=$?
err="$(cat "$workdir/stderr")"
assert_eq "unowned default from config: exit 0" "0" "$rc"
assert_contains "unowned default from config: ledger.repo used" "$out" '"acme/papercuts-ledger"'

# --- 8b. neither unowned.repo nor ledger.repo set: validation error ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
out="$(PAPERCUT_CONFIG="$d/nope-config.toml" PAPERCUT_OWNERS="$d/owners.toml" python3 "$loader" 2>"$workdir/stderr")"
rc=$?
err="$(cat "$workdir/stderr")"
assert_eq "unowned unresolvable: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "unowned unresolvable: stdout empty" "" "$out"
assert_contains "unowned unresolvable: stderr names unowned.repo" "$err" "unowned.repo"

# --- 8c. explicit registry with unowned.repo set: config.toml is never read,
# so a malformed one does not fail the load (the "sole location" rule) ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger
EOF
cat >"$d/owners.toml" <<'EOF'
[unowned]
repo = "acme/ledger"

[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" PAPERCUT_OWNERS="$d/owners.toml" python3 "$loader" --json 2>"$workdir/stderr")"
rc=$?
err="$(cat "$workdir/stderr")"
assert_eq "sole location, unowned set: exit 0 despite broken config" "0" "$rc"
assert_contains "sole location, unowned set: registry's repo used" "$out" '"acme/ledger"'

# --- 8d. explicit registry WITHOUT unowned.repo: the default needs config,
# and a malformed config is then a hard error that names the config file ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger
EOF
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" PAPERCUT_OWNERS="$d/owners.toml" python3 "$loader" --json 2>"$workdir/stderr")"
rc=$?
err="$(cat "$workdir/stderr")"
assert_eq "sole location, unowned absent: non-zero exit on broken config" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "sole location, unowned absent: stdout empty" "" "$out"
assert_contains "sole location, unowned absent: stderr names config.toml" "$err" "config.toml"

# --- 9. bad TOML: hard error, nothing on stdout ---
d="$(next_dir)"
cat >"$d/owners.toml" <<'EOF'
[owners.dotfiles
tracker = "gh-issue"
EOF
run_loader "$d/owners.toml"
assert_eq "bad TOML: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "bad TOML: stdout empty (explicit check)" "" "$out"
assert_contains "bad TOML: stderr names the file" "$err" "$d/owners.toml"

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut_owners tests passed."
  exit 0
fi
echo "Some papercut_owners tests FAILED."
exit 1
