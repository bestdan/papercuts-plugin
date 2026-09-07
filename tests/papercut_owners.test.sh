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
assert_eq "missing file: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "missing file: stdout empty" "" "$out"
assert_contains "missing file: stderr names the path" "$err" "$d/nope.toml"

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
