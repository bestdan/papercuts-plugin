#!/usr/bin/env bash
# Tests for papercut_config.py — the single config resolver: file location
# precedence, shell-eval-safe output, the always-resolves contract (exit 0
# with defaults + status lines on absent/partial config), and the hard-error
# cases (unparseable config, pre-3.11 interpreter).
# Run:
#   bash tests/papercut_config.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

resolver="$(dirname "$0")/../scripts/papercut_config.py"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# The prelude already pins HOME and unsets both of these; repeated here because
# this suite's precedence tests are the ones that break if either ever leaks in
# from the developer's environment.
unset XDG_CONFIG_HOME
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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf 'FAIL (%s: did not expect to find %q in %q)\n' "$desc" "$needle" "$haystack"
    fail=1
  else
    printf 'ok   (%s)\n' "$desc"
  fi
}

# Eval the resolver's stdout in a clean subshell and print one requested
# variable — this exercises the shell-eval-safety claim for real, rather
# than grepping for a substring of the raw output.
eval_var() {
  local output="$1" var="$2"
  (
    eval "$output"
    printf '%s' "${!var}"
  )
}

# --- 1. precedence: $PAPERCUT_CONFIG wins over $XDG_CONFIG_HOME ---
d="$(next_dir)"
mkdir -p "$d/xdg/papercuts"
cat >"$d/explicit.toml" <<'EOF'
[ledger]
repo = "acme/from-explicit"
EOF
cat >"$d/xdg/papercuts/config.toml" <<'EOF'
[ledger]
repo = "acme/from-xdg"
EOF
out="$(PAPERCUT_CONFIG="$d/explicit.toml" XDG_CONFIG_HOME="$d/xdg" python3 "$resolver")"
rc=$?
assert_eq "PAPERCUT_CONFIG precedence: exit 0" "0" "$rc"
assert_eq "PAPERCUT_CONFIG wins over XDG_CONFIG_HOME" \
  "acme/from-explicit" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"

# --- 2. precedence: $XDG_CONFIG_HOME wins over ~/.config ---
mkdir -p "$HOME/.config/papercuts"
cat >"$HOME/.config/papercuts/config.toml" <<'EOF'
[ledger]
repo = "acme/from-home"
EOF
out="$(XDG_CONFIG_HOME="$d/xdg" python3 "$resolver")"
rc=$?
assert_eq "XDG fallback: exit 0" "0" "$rc"
assert_eq "XDG_CONFIG_HOME wins over ~/.config when PAPERCUT_CONFIG unset" \
  "acme/from-xdg" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"

# --- 3. precedence: ~/.config/papercuts/config.toml when XDG unset too ---
out="$(python3 "$resolver")"
rc=$?
assert_eq "~/.config fallback: exit 0" "0" "$rc"
assert_eq "~/.config/papercuts/config.toml used when both env vars unset" \
  "acme/from-home" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"
rm -rf "$HOME/.config/papercuts"

# --- 4. full config: all three keys come back as eval-safe lines ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
repo = "acme/papercuts"
host = "git.example.com"
dir = "/srv/papercuts clone"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
rc=$?
assert_eq "full config: exit 0" "0" "$rc"
assert_eq "full config: ledger.repo" \
  "acme/papercuts" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"
assert_eq "full config: ledger.host" \
  "git.example.com" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_HOST)"
assert_eq "full config: ledger.dir survives eval with an embedded space" \
  "/srv/papercuts clone" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_DIR)"
assert_eq "full config: ledger status is ok" \
  "ok" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER)"

# --- 5. defaults: host and dir fall back when absent from config ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
repo = "acme/papercuts"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
assert_eq "defaults: ledger.host defaults to github.com" \
  "github.com" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_HOST)"
assert_eq "defaults: ledger.dir defaults to ~/src/papercuts (tilde expanded)" \
  "$HOME/src/papercuts" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_DIR)"

# --- 6. hostile value: eval must not execute embedded shell syntax ---
d="$(next_dir)"
cat >"$d/config.toml" <<EOF
[ledger]
repo = "acme/papercuts"
dir = "$d/\$(touch $d/pwned)'; touch $d/pwned2 #"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
rc=$?
assert_eq "hostile value: exit 0" "0" "$rc"
got_dir="$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_DIR)"
assert_contains "hostile value: literal \$( preserved through eval" "$got_dir" '$(touch'
if [ ! -e "$d/pwned" ] && [ ! -e "$d/pwned2" ]; then
  printf 'ok   (hostile value: eval executed nothing)\n'
else
  printf 'FAIL (hostile value: eval executed embedded command)\n'
  fail=1
fi

# --- 7. parseable config with no ledger.repo: status missing, exit 0 ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
host = "github.com"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
rc=$?
assert_eq "repo absent: exit 0" "0" "$rc"
assert_eq "repo absent: ledger status is missing, not ok" \
  "missing" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER)"
assert_eq "repo absent: repo key present but empty" \
  "" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"

# --- 7b. remote_url: emitted verbatim, and it alone resolves the ledger
# identity (the flusher's publish path holds on status=missing, and the
# integration fixtures configure ONLY remote_url) ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
remote_url = "file:///srv/bare.git"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
rc=$?
assert_eq "remote_url only: exit 0" "0" "$rc"
assert_eq "remote_url only: value emitted" \
  "file:///srv/bare.git" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REMOTE_URL)"
assert_eq "remote_url only: ledger identity resolves without repo" \
  "ok" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER)"
assert_eq "remote_url only: repo key present but empty" \
  "" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"

# --- 8. no config file anywhere: exit 0 with usable defaults ---
out="$(python3 "$resolver")"
rc=$?
assert_eq "absent config: exit 0" "0" "$rc"
assert_eq "absent config: ledger status is missing" \
  "missing" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER)"
assert_eq "absent config: host default emitted" \
  "github.com" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_HOST)"
assert_eq "absent config: dir default emitted" \
  "$HOME/src/papercuts" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_DIR)"

# --- 9. PAPERCUT_CONFIG pointing at a missing file: absent, not fallback ---
d="$(next_dir)"
mkdir -p "$d/xdg/papercuts"
cat >"$d/xdg/papercuts/config.toml" <<'EOF'
[ledger]
repo = "acme/should-not-be-read"
EOF
out="$(PAPERCUT_CONFIG="$d/nope.toml" XDG_CONFIG_HOME="$d/xdg" python3 "$resolver")"
rc=$?
assert_eq "explicit-but-missing config: exit 0" "0" "$rc"
assert_eq "explicit-but-missing config: does not fall through to XDG" \
  "missing" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER)"
assert_not_contains "explicit-but-missing config: XDG repo not read" \
  "$out" "acme/should-not-be-read"

# --- 9b. tilde-valued env vars: expanded, not treated as absent ---
# A literal ~ can reach the env var unexpanded (quoted in shell, or set by
# another tool). The resolver expands it, matching how papercut_open.py
# treats PAPERCUT_LEDGER_DIR. HOME is the prelude's throwaway.
cat >"$HOME/pc-tilde-config.toml" <<'EOF'
[ledger]
repo = "acme/from-tilde"
EOF
out="$(PAPERCUT_CONFIG='~/pc-tilde-config.toml' python3 "$resolver")"
rc=$?
assert_eq "tilde PAPERCUT_CONFIG: exit 0" "0" "$rc"
assert_eq "tilde PAPERCUT_CONFIG: expanded and read" \
  "acme/from-tilde" "$(eval_var "$out" PAPERCUT_CONFIG_LEDGER_REPO)"
rm -f "$HOME/pc-tilde-config.toml"

# --- 10. unparseable config: hard error, nothing usable on stdout ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger
repo = "acme/papercuts"
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver" 2>"$d/stderr")"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'ok   (unparseable config: non-zero exit)\n'
else
  printf 'FAIL (unparseable config: expected non-zero exit, got 0)\n'
  fail=1
fi
assert_eq "unparseable config: stdout empty" "" "$out"
assert_contains "unparseable config: stderr names the file" "$(cat "$d/stderr")" "$d/config.toml"

# --- 10b. invalid UTF-8: same hard error as a syntax error, file named ---
# tomllib raises UnicodeDecodeError (not TOMLDecodeError) on invalid UTF-8;
# the resolver must fold it into the same clean ConfigError, not a traceback.
d="$(next_dir)"
printf '[ledger]\nrepo = "\xff\xfe"\n' >"$d/config.toml"
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver" 2>"$d/stderr")"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'ok   (invalid UTF-8 config: non-zero exit)\n'
else
  printf 'FAIL (invalid UTF-8 config: expected non-zero exit, got 0)\n'
  fail=1
fi
assert_eq "invalid UTF-8 config: stdout empty" "" "$out"
assert_contains "invalid UTF-8 config: stderr names the file" "$(cat "$d/stderr")" "$d/config.toml"
assert_not_contains "invalid UTF-8 config: no traceback" "$(cat "$d/stderr")" "Traceback"

# --- 10c. existing-but-unreachable config: hard error, not silent defaults ---
# An unreadable parent directory makes os.path.exists() report False, so an
# exists() pre-check would resolve a broken config to defaults. The resolver
# opens directly and treats only FileNotFoundError as absent.
d="$(next_dir)"
mkdir -p "$d/locked"
cat >"$d/locked/config.toml" <<'EOF'
[ledger]
repo = "acme/papercuts"
EOF
chmod 000 "$d/locked"
rc_locked="$(PAPERCUT_CONFIG="$d/locked/config.toml" python3 "$resolver" >/dev/null 2>&1; echo $?)"
chmod 755 "$d/locked"
if [ "$rc_locked" -ne 0 ]; then
  printf 'ok   (unreadable parent dir: non-zero exit, not silent defaults)\n'
else
  printf 'FAIL (unreadable parent dir: expected non-zero exit, got 0)\n'
  fail=1
fi

# --- 11. wrongly-typed value: also a hard error, not a silent default ---
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
repo = 123
EOF
rc_typed="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver" >/dev/null 2>&1; echo $?)"
if [ "$rc_typed" -ne 0 ]; then
  printf 'ok   (wrongly-typed ledger.repo: non-zero exit)\n'
else
  printf 'FAIL (wrongly-typed ledger.repo: expected non-zero exit, got 0)\n'
  fail=1
fi

# --- 12. pre-3.11 interpreter: clear message naming the requirement ---
# No 3.10 interpreter is guaranteed on the machine, so fake the version the
# script sees: run its source under this python3 with sys.version_info
# replaced, before any of its code (including the tomllib import) runs.
d="$(next_dir)"
err="$(
  python3 - "$resolver" 2>&1 >/dev/null <<'PYEOF'
import sys
path = sys.argv[1]
sys.version_info = (3, 10, 4)
with open(path, encoding="utf-8") as f:
    source = f.read()
try:
    exec(compile(source, path, "exec"), {"__name__": "__main__"})
except SystemExit as exc:
    sys.exit(exc.code)
PYEOF
)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'ok   (pre-3.11 interpreter: non-zero exit)\n'
else
  printf 'FAIL (pre-3.11 interpreter: expected non-zero exit, got 0)\n'
  fail=1
fi
assert_contains "pre-3.11 interpreter: message names the 3.11 requirement" "$err" "3.11"

# --- 13. [profile] strict_hosts: emitted for shell consumers, returned as a
# plain list for Python ones, and absent/empty in both views when unset. ---
strict_hosts_py() {
  # strict_hosts_py [env-assignments...] -> prints the patterns, one per line
  env "$@" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import papercut_config
for pattern in papercut_config.strict_hosts():
    print(pattern)
' "$(cd "$(dirname "$resolver")" && pwd)"
}

d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[ledger]
repo = "acme/papercuts"

[profile]
strict_hosts = ["WORK-*", "lab-??.example.com"]
EOF
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
rc=$?
assert_eq "strict_hosts: exit 0" "0" "$rc"
assert_eq "strict_hosts: emitted newline-separated and eval-safe" \
  "$(printf 'WORK-*\nlab-??.example.com')" \
  "$(eval_var "$out" PAPERCUT_CONFIG_PROFILE_STRICT_HOSTS)"
assert_eq "strict_hosts(): same patterns for Python importers" \
  "$(printf 'WORK-*\nlab-??.example.com')" \
  "$(strict_hosts_py PAPERCUT_CONFIG="$d/config.toml")"

# absent [profile] table, and no config file at all: empty, exit 0 (the
# always-resolves contract holds for this key too)
d="$(next_dir)"
printf '[ledger]\nrepo = "acme/papercuts"\n' >"$d/config.toml"
out="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver")"
assert_eq "absent [profile]: strict_hosts key present but empty" \
  "" "$(eval_var "$out" PAPERCUT_CONFIG_PROFILE_STRICT_HOSTS)"
assert_eq "absent [profile]: strict_hosts() returns nothing" \
  "" "$(strict_hosts_py PAPERCUT_CONFIG="$d/config.toml")"
assert_eq "absent config file: strict_hosts() returns nothing" \
  "" "$(strict_hosts_py PAPERCUT_CONFIG="$d/nope.toml")"

# unknown keys under [profile] are ignored — notably any key that looks like it
# names the strict marker path, which is a hardcoded literal in
# papercut_append.py precisely so no config can move it
d="$(next_dir)"
cat >"$d/config.toml" <<'EOF'
[profile]
marker = "/nonexistent"
strict_marker = "/nonexistent"
EOF
rc_unknown="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver" >/dev/null 2>&1; echo $?)"
assert_eq "marker-looking keys under [profile]: ignored, exit 0" "0" "$rc_unknown"

# --- 14. wrongly-typed strict_hosts: the same hard error as any other bad
# value. A malformed key that MEANS to add strictness must never read as "no
# patterns". ---
for bad in 'strict_hosts = "WORK-*"' 'strict_hosts = ["WORK-*", 7]' ; do
  d="$(next_dir)"
  printf '[profile]\n%s\n' "$bad" >"$d/config.toml"
  rc_bad="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver" >/dev/null 2>&1; echo $?)"
  if [ "$rc_bad" -ne 0 ]; then
    printf 'ok   (wrongly-typed %s: non-zero exit)\n' "$bad"
  else
    printf 'FAIL (wrongly-typed %s: expected non-zero exit, got 0)\n' "$bad"
    fail=1
  fi
done

d="$(next_dir)"
printf 'profile = "not-a-table"\n' >"$d/config.toml"
rc_bad="$(PAPERCUT_CONFIG="$d/config.toml" python3 "$resolver" >/dev/null 2>&1; echo $?)"
if [ "$rc_bad" -ne 0 ]; then
  printf 'ok   (non-table [profile]: non-zero exit)\n'
else
  printf 'FAIL (non-table [profile]: expected non-zero exit, got 0)\n'
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "papercut_config tests: PASS"
  exit 0
fi
echo "papercut_config tests: FAIL"
exit 1
