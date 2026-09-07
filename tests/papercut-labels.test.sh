#!/usr/bin/env bash
# Tests for scripts/papercut-labels.sh — attended label provisioning. Each
# case builds a fixture owners.toml/config.toml and a `gh` stub, then asserts
# on the printed report, the exit code, and (for --apply) the stub's
# create-call log. Run:
#   bash tests/papercut-labels.test.sh
#
# No real `gh` is ever invoked: every case sets PAPERCUT_GH_CMD to a stub.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
labels_sh="$script_dir/papercut-labels.sh"

fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-labels-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

new_dir() { mktemp -d "$workdir/case.XXXXXX"; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$desc"
  else
    fail_test "$desc: expected to find $(printf '%q' "$needle") in $(printf '%q' "$haystack")"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail_test "$desc: did not expect to find $(printf '%q' "$needle") in $(printf '%q' "$haystack")"
  else
    pass "$desc"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail_test "$desc: expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
  fi
}

# write_fixture <dir> — two owners sharing a repo, one external target (never
# provisioned), and unowned (also a target, per design §4.3).
write_fixture() {
  local dir="$1"
  cat >"$dir/config.toml" <<'EOF'
[ledger]
repo = "acme/papercuts-ledger"
EOF
  cat >"$dir/owners.toml" <<'EOF'
[unowned]
repo = "acme/papercuts-ledger"

[owners.dotfiles]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "shell config"
labels = ["status:0_untriaged", "auto:human-review-needed"]

[owners.workflow]
tracker = "gh-issue"
repo = "acme/dotfiles"
scope = "workflow skills"
labels = ["status:0_untriaged"]

[external.claude-code]
repo = "anthropics/claude-code"
scope = "harness"
EOF
}

# write_stub <dir> <dotfiles-json> <ledger-json> — `label list --repo <r>
# --json name --limit <n>` returns the fixture JSON for that repo, asserting
# --limit is present in argv; `label create ...` appends its full argv to
# create.log.
write_stub() {
  local dir="$1" dotfiles_json="$2" ledger_json="$3"
  cat >"$dir/gh-stub.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
log="$dir/create.log"
if [ "\$1" = "label" ] && [ "\$2" = "list" ]; then
  repo=""
  limit=""
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "--repo" ]; then repo="\$a"; fi
    if [ "\$prev" = "--limit" ]; then limit="\$a"; fi
    prev="\$a"
  done
  if [ -z "\$limit" ]; then
    echo "stub: label list called without --limit" >&2
    exit 1
  fi
  case "\$repo" in
    acme/dotfiles) echo '$dotfiles_json' ;;
    acme/papercuts-ledger) echo '$ledger_json' ;;
    *) echo '[]' ;;
  esac
  exit 0
elif [ "\$1" = "label" ] && [ "\$2" = "create" ]; then
  echo "\$@" >>"\$log"
  exit 0
fi
echo "stub: unexpected gh call: \$*" >&2
exit 1
STUB
  chmod +x "$dir/gh-stub.sh"
  : >"$dir/create.log"
}

# write_failing_stub <dir> — `label list` always fails; `label create`
# should never be reached in these cases.
write_failing_stub() {
  local dir="$1"
  cat >"$dir/gh-stub-fail.sh" <<STUB
#!/usr/bin/env bash
log="$dir/create.log"
if [ "\$1" = "label" ] && [ "\$2" = "create" ]; then
  echo "\$@" >>"\$log"
  exit 0
fi
echo "stub: gh label list failed (simulated)" >&2
exit 1
STUB
  chmod +x "$dir/gh-stub-fail.sh"
  : >"$dir/create.log"
}

run_labels() {
  # run_labels <dir> <gh-stub-name> <args...> — sets $out, $err, $rc
  local dir="$1" stub="$2"
  shift 2
  out="$(PAPERCUT_OWNERS="$dir/owners.toml" PAPERCUT_CONFIG="$dir/config.toml" PAPERCUT_GH_CMD="$dir/$stub" \
    bash "$labels_sh" "$@" 2>"$workdir/stderr")"
  rc=$?
  err="$(cat "$workdir/stderr")"
}

# --- 1. missing set computed correctly -------------------------------------
dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[{"name":"papercut"},{"name":"priority:high"}]' '[]'
run_labels "$dir" gh-stub.sh dotfiles
assert_eq "missing set: exit 0" "0" "$rc"
assert_contains "missing set: names the block" "$out" "dotfiles (acme/dotfiles): missing 5 label(s):"
assert_contains "missing set: required label missing" "$out" "priority:medium"
assert_contains "missing set: owner label missing" "$out" "status:0_untriaged"
assert_contains "missing set: owner label missing" "$out" "auto:human-review-needed"
assert_not_contains "missing set: present label not listed as missing" "$out" ", papercut,"

# --- 2. without --apply, nothing is created --------------------------------
assert_eq "no --apply: create log stays empty" "" "$(cat "$dir/create.log")"

# --- 3. with --apply: one create per missing label, --force and the right
# --repo, none for present labels -------------------------------------------
dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[{"name":"papercut"},{"name":"priority:high"}]' '[]'
run_labels "$dir" gh-stub.sh dotfiles --apply
assert_eq "--apply: exit 0" "0" "$rc"
create_log="$(cat "$dir/create.log")"
create_count="$(printf '%s\n' "$create_log" | grep -c .)"
assert_eq "--apply: exactly 5 creates" "5" "$create_count"
assert_contains "--apply: each create carries --force" "$create_log" "--force"
assert_contains "--apply: each create carries --repo acme/dotfiles" "$create_log" "--repo acme/dotfiles"
assert_not_contains "--apply: present label 'papercut' not created" "$create_log" "label create papercut --repo"
assert_not_contains "--apply: present label 'priority:high' not created" "$create_log" "label create priority:high --repo"

# --- 4. --all covers every owner (and unowned); a single <owner> covers
# only that one ---------------------------------------------------------
dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[]' '[]'
run_labels "$dir" gh-stub.sh --all
assert_eq "--all: exit 0" "0" "$rc"
assert_contains "--all: covers dotfiles" "$out" "dotfiles (acme/dotfiles):"
assert_contains "--all: covers workflow" "$out" "workflow (acme/dotfiles):"
assert_contains "--all: covers unowned" "$out" "unowned (acme/papercuts-ledger):"

dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[]' '[]'
run_labels "$dir" gh-stub.sh workflow
assert_eq "single owner: exit 0" "0" "$rc"
assert_contains "single owner: covers workflow" "$out" "workflow (acme/dotfiles):"
assert_not_contains "single owner: does not cover dotfiles" "$out" "dotfiles (acme/dotfiles):"
assert_not_contains "single owner: does not cover unowned" "$out" "unowned"

# --- 4b. unowned addressed alone --------------------------------------------
dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[]' '[]'
run_labels "$dir" gh-stub.sh unowned
assert_eq "unowned alone: exit 0" "0" "$rc"
assert_contains "unowned alone: covers unowned" "$out" "unowned (acme/papercuts-ledger): missing 5 label(s):"
assert_not_contains "unowned alone: does not cover dotfiles" "$out" "dotfiles (acme/dotfiles):"

# --- 5. unknown owner: non-zero, stderr message -----------------------------
dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[]' '[]'
run_labels "$dir" gh-stub.sh bogus
assert_eq "unknown owner: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "unknown owner: stderr names it" "$err" "unknown target"

# --- 6. label list failing: non-zero, no create attempted even with --apply
dir="$(new_dir)"
write_fixture "$dir"
write_failing_stub "$dir"
run_labels "$dir" gh-stub-fail.sh --all --apply
assert_eq "list failing: non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "list failing: stderr mentions the failure" "$err" "gh label list"
assert_eq "list failing: no create attempted" "" "$(cat "$dir/create.log")"

# --- 7. case mismatch: reported distinctly, never created by --apply -------
dir="$(new_dir)"
write_fixture "$dir"
write_stub "$dir" '[{"name":"papercut"},{"name":"priority:High"}]' '[]'
run_labels "$dir" gh-stub.sh dotfiles
assert_eq "case mismatch: exit 0" "0" "$rc"
assert_contains "case mismatch: reported distinctly" "$out" "case mismatch: priority:High vs priority:high"

run_labels "$dir" gh-stub.sh dotfiles --apply
assert_eq "case mismatch --apply: exit 0" "0" "$rc"
assert_not_contains "case mismatch --apply: never created" "$(cat "$dir/create.log")" "priority:high --repo"
assert_not_contains "case mismatch --apply: original case never created" "$(cat "$dir/create.log")" "priority:High"

echo
if [ "$fail" -eq 0 ]; then
  echo "All papercut-labels tests passed."
  exit 0
fi
echo "Some papercut-labels tests FAILED."
exit 1
