#!/usr/bin/env bash
# papercut-doctor.sh — check a papercuts plugin install.
#
# Prints one PASS/FAIL line per check and exits non-zero if any check failed.
# Purely advisory: it reads state, never writes it, and never publishes.
#
# Checks (the leading word on each line is the check NAME, which the test
# suite asserts on — keep the names stable):
#   config        the papercuts config file exists and parses
#   ledger        the ledger clone exists and its origin is trusted
#   denylist      the denylist state matches the resolved profile
#   spool-perms   the spool directory is 0700
#   hooks         hooks/hooks.json is present and its scripts are executable
#   claude-path   `claude` is on PATH
#
# It finishes by printing the exact permissions.allow entry to paste, with the
# absolute path of THIS install resolved — see docs/install.md for why a
# plugin cannot grant that itself.
#
# Env overrides (same names and meanings the rest of the pipeline uses, so a
# doctor run can be pointed at a fixture):
#   PAPERCUT_CONFIG       config file path
#   PAPERCUT_LEDGER_DIR   ledger clone path (overrides ledger.dir)
#   PAPERCUT_DENYLIST     denylist path
#   PAPERCUT_SPOOL        spool file path (its dirname is the spool dir)
#   PAPERCUT_DETECT_CMD   overrides profile detection (tests force a profile)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0

pass() { printf 'PASS: %s: %s\n' "$1" "$2"; }
fail() {
  printf 'FAIL: %s: %s\n' "$1" "$2"
  failures=$((failures + 1))
}

# --- borrowed trust gate ----------------------------------------------------
# These two functions are a deliberate copy of papercut-flush.sh's origin
# allowlist (see its `_papercut_regex_escape` / `_papercut_remote_url_trusted`
# and the "safety check" block in `_papercut_publish_git`). The flusher's copy
# is the one that actually gates a push and stays authoritative; this one only
# reports, so drift here misreports an install, it cannot let a push through.
# Keep them in sync anyway — they answer the same question.
_papercut_regex_escape() {
  printf '%s' "$1" | sed -e 's/[][\.|$(){}?+*^]/\\&/g'
}

_papercut_remote_url_trusted() {
  local url="$1"
  if [ -n "${PAPERCUT_CONFIG_LEDGER_REMOTE_URL:-}" ] \
    && [ "$url" = "$PAPERCUT_CONFIG_LEDGER_REMOTE_URL" ]; then
    return 0
  fi
  [ -n "${PAPERCUT_CONFIG_LEDGER_REPO:-}" ] || return 1
  local host_re repo_re
  host_re="$(_papercut_regex_escape "${PAPERCUT_CONFIG_LEDGER_HOST:-github.com}")"
  repo_re="$(_papercut_regex_escape "$PAPERCUT_CONFIG_LEDGER_REPO")"
  [[ "$url" =~ ^git@${host_re}:${repo_re}(\.git)?/?$ ]] && return 0
  [[ "$url" =~ ^https://${host_re}/${repo_re}(\.git)?/?$ ]] && return 0
  return 1
}

# --- 1. config --------------------------------------------------------------
# The resolver deliberately exits 0 on an ABSENT config (its always-resolves
# contract), so "present" has to be checked separately from "parses".
config_ok=0
config_path="$(python3 -c '
import os
import sys
sys.path.insert(0, sys.argv[1])
import papercut_config
print(papercut_config.config_path(os.environ))
' "$SCRIPT_DIR" 2>/dev/null)"

if [ -z "$config_path" ]; then
  fail config "could not resolve a config path (is python3 3.11+ available?)"
elif [ ! -f "$config_path" ]; then
  fail config "no config file at $config_path — see docs/install.md"
else
  # stdout only: this lands in an eval, so a future rc-0 stderr warning from
  # the resolver must never ride along (papercut-flush.sh captures the same
  # way). The failure branch re-runs for the error text — read-only and cheap.
  config_kv="$(python3 "$SCRIPT_DIR/papercut_config.py" 2>/dev/null)"
  if [ $? -ne 0 ]; then
    config_err="$(python3 "$SCRIPT_DIR/papercut_config.py" 2>&1 >/dev/null)"
    fail config "$config_path is present but unparseable: $config_err"
  else
    eval "$config_kv"
    if [ "${PAPERCUT_CONFIG_LEDGER:-missing}" != "ok" ]; then
      fail config "$config_path parses but names no ledger — set ledger.repo or ledger.remote_url"
    else
      pass config "$config_path parses; ledger identity resolved"
      config_ok=1
    fi
  fi
fi

# --- 2. ledger clone + trusted origin ---------------------------------------
ledger_dir="${PAPERCUT_LEDGER_DIR:-${PAPERCUT_CONFIG_LEDGER_DIR:-$HOME/src/papercuts}}"
if [ "$config_ok" -ne 1 ]; then
  fail ledger "skipped — the config check failed, so there is no trust anchor to judge an origin against"
elif [ ! -d "$ledger_dir/.git" ]; then
  fail ledger "no clone at $ledger_dir — clone the ledger repo there"
else
  fetch_url="$(git -C "$ledger_dir" remote get-url origin 2>/dev/null)"
  push_url="$(git -C "$ledger_dir" remote get-url --push origin 2>/dev/null)"
  if [ -z "$fetch_url" ] || [ -z "$push_url" ]; then
    fail ledger "$ledger_dir has no origin remote"
  elif ! _papercut_remote_url_trusted "$fetch_url"; then
    fail ledger "$ledger_dir origin fetch url is not trusted by the config: $fetch_url"
  elif ! _papercut_remote_url_trusted "$push_url"; then
    fail ledger "$ledger_dir origin push url is not trusted by the config: $push_url"
  else
    pass ledger "$ledger_dir origin accepted: $fetch_url"
  fi
fi

# --- 3. denylist vs resolved profile ----------------------------------------
# Same resolver and same fail-closed polarity papercut-flush.sh uses: anything
# other than a positive "default" is treated as strict.
if [ -n "${PAPERCUT_DETECT_CMD:-}" ]; then
  profile=$(bash -c "$PAPERCUT_DETECT_CMD" 2>/dev/null)
else
  profile=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import papercut_append
print(papercut_append.detect_machine())
' "$SCRIPT_DIR" 2>/dev/null)
fi
[ "$profile" = "default" ] || profile="strict"

denylist_path="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import papercut_append
print(papercut_append.DENYLIST_PATH)
' "$SCRIPT_DIR" 2>/dev/null)"

if [ -z "$denylist_path" ]; then
  fail denylist "could not resolve the denylist path from papercut_append.py"
elif [ "$profile" != "strict" ]; then
  if [ -f "$denylist_path" ]; then
    pass denylist "default profile; optional denylist present at $denylist_path"
  else
    pass denylist "default profile; no denylist required"
  fi
elif [ ! -f "$denylist_path" ]; then
  fail denylist "strict profile requires a denylist at $denylist_path, none found"
else
  denylist_mode="$(stat -c '%a' "$denylist_path" 2>/dev/null || stat -f '%Lp' "$denylist_path" 2>/dev/null)"
  if python3 -c 'import os, sys; sys.exit(0 if os.stat(sys.argv[1]).st_mode & 0o004 else 1)' "$denylist_path" 2>/dev/null; then
    fail denylist "$denylist_path is world-readable (mode $denylist_mode); chmod 0600 it"
  else
    literal_count="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$denylist_path" 2>/dev/null | grep -c '.')"
    if [ "${literal_count:-0}" -eq 0 ]; then
      fail denylist "$denylist_path holds no literals after stripping comments; strict capture stays inert"
    else
      pass denylist "strict profile; $denylist_path has $literal_count literal(s), mode $denylist_mode"
    fi
  fi
fi

# --- 4. spool directory permissions ----------------------------------------
spool="${PAPERCUT_SPOOL:-$HOME/.claude/papercuts/spool.jsonl}"
spool_dir="$(dirname "$spool")"
if [ ! -d "$spool_dir" ]; then
  # A fresh install has no spool dir until the first append, which creates it
  # 0700 itself. Absent is therefore not a misconfiguration.
  pass spool-perms "$spool_dir does not exist yet; it is created 0700 on first append"
else
  spool_mode="$(stat -c '%a' "$spool_dir" 2>/dev/null || stat -f '%Lp' "$spool_dir" 2>/dev/null)"
  if [ "$spool_mode" = "700" ]; then
    pass spool-perms "$spool_dir is 0700"
  else
    fail spool-perms "$spool_dir is mode $spool_mode, expected 700; run chmod 0700 '$spool_dir'"
  fi
fi

# --- 5. hooks registered ----------------------------------------------------
# Resolved relative to this script's own location, so the doctor checks the
# install it ships inside rather than whatever happens to be in PWD.
hooks_json="$PLUGIN_ROOT/hooks/hooks.json"
if [ ! -f "$hooks_json" ]; then
  fail hooks "no manifest at $hooks_json"
else
  hook_scripts="$(python3 -c '
import json
import sys

with open(sys.argv[1], "rb") as f:
    data = json.load(f)

seen = []
for entries in data.get("hooks", {}).values():
    for entry in entries:
        for hook in entry.get("hooks", []):
            command = hook.get("command", "")
            if not command:
                continue
            token = command.split()[0]
            if token not in seen:
                seen.append(token)
for token in seen:
    print(token)
' "$hooks_json" 2>&1)"
  if [ $? -ne 0 ]; then
    fail hooks "$hooks_json is unparseable: $hook_scripts"
  elif [ -z "$hook_scripts" ]; then
    fail hooks "$hooks_json declares no hook commands"
  else
    hooks_bad=""
    hooks_count=0
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      hooks_count=$((hooks_count + 1))
      case "$token" in
        '${CLAUDE_PLUGIN_ROOT}/'*) ;;
        *)
          hooks_bad="$hooks_bad $token(not-plugin-relative)"
          continue
          ;;
      esac
      resolved="$PLUGIN_ROOT/${token#'${CLAUDE_PLUGIN_ROOT}/'}"
      if [ ! -f "$resolved" ]; then
        hooks_bad="$hooks_bad $resolved(missing)"
      elif [ ! -x "$resolved" ]; then
        hooks_bad="$hooks_bad $resolved(not-executable)"
      fi
    done <<<"$hook_scripts"
    if [ -n "$hooks_bad" ]; then
      fail hooks "$hooks_json references unusable scripts:$hooks_bad"
    else
      pass hooks "$hooks_count hook script(s) present and executable under $PLUGIN_ROOT"
    fi
  fi
fi

# --- 6. claude on PATH ------------------------------------------------------
claude_bin="$(command -v claude 2>/dev/null)"
if [ -n "$claude_bin" ]; then
  pass claude-path "$claude_bin"
else
  fail claude-path "claude is not on PATH"
fi

# --- the fallback permission entry, printed resolved ------------------------
printf '\nThe /papercuts:papercut skill authorizes its own append call for the turn\nit runs in (allowed-tools), so a permission rule is usually unnecessary. If\na capture still stops on a permission prompt, add this to permissions.allow\nin your own settings.json — the path is this install, resolved:\n\n'
printf '  "Bash(python3 %s/papercut_append.py:*)"\n\n' "$SCRIPT_DIR"
printf 'See docs/install.md for the sandbox write-allowlist entries too.\n'

if [ "$failures" -ne 0 ]; then
  printf '\n%s check(s) failed.\n' "$failures"
  exit 1
fi
printf '\nAll checks passed.\n'
exit 0
