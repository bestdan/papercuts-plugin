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
#   permission-entry   whether permissions.allow carries the fallback rule
#   owners        the owners registry parses and every target's required
#                 labels exist in its repo
#
# permission-entry always passes — an absent rule is the normal state, since
# the skill authorizes its own append per turn (docs/install.md step 4). When
# no rule is found, the doctor prints the exact entry to paste, with the
# absolute path of THIS install resolved.
#
# owners is read-only: a missing registry is a PASS (capture-only install),
# and a present one with labels missing is a FAIL naming
# scripts/papercut-labels.sh to fix it. The doctor never creates a label.
#
# Env overrides (same names and meanings the rest of the pipeline uses, so a
# doctor run can be pointed at a fixture):
#   PAPERCUT_CONFIG       config file path
#   PAPERCUT_LEDGER_DIR   ledger clone path (overrides ledger.dir)
#   PAPERCUT_DENYLIST     denylist path
#   PAPERCUT_SPOOL        spool file path (its dirname is the spool dir)
#   PAPERCUT_DETECT_CMD   overrides profile detection (tests force a profile)
#   PAPERCUT_SETTINGS     the user's settings.json to check for the
#                         permissions.allow entry (default: ~/.claude/settings.json)
#   PAPERCUT_OWNERS       owners registry path, passed through to
#                         papercut_owners.py
#   PAPERCUT_GH_CMD       the `gh` seam used to list labels (default: gh);
#                         tests point this at a stub

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

# --- 7. the fallback permission entry: detected, never required ------------
# The skill authorizes its own append call for the turn it runs in
# (allowed-tools), so an absent entry is the normal state, not a failure —
# docs/install.md step 4 names the cases that need the fallback rule. The
# doctor reports whether one is present and, when it is not, prints the
# exact entry to paste if a capture ever stops on a permission prompt.
# Detection accepts three spellings of the same path — the resolved
# absolute path, the home prefix written as $HOME, or written as ~ — a
# user who wrote any of them intended coverage. The printed advice
# recommends only the resolved absolute path: whether permission rules
# expand $HOME/~ against a resolved-path command is unverified, and the
# resolved spelling is the one docs/install.md documents.
settings_path="${PAPERCUT_SETTINGS:-$HOME/.claude/settings.json}"
target_path="$SCRIPT_DIR/papercut_append.py"
home_spelling="$target_path"
tilde_spelling="$target_path"
case "$target_path" in
  "$HOME"/*)
    home_spelling="\$HOME${target_path#"$HOME"}"
    tilde_spelling="~${target_path#"$HOME"}"
    ;;
esac

entry_found=0
if [ -f "$settings_path" ]; then
  entry_found="$(python3 -c '
import json
import sys

resolved, home, tilde = sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(sys.argv[1], "rb") as f:
        data = json.load(f)
except (OSError, ValueError):
    print(0)
    sys.exit(0)

if not isinstance(data, dict) or not isinstance(data.get("permissions"), dict):
    print(0)
    sys.exit(0)

allow = data["permissions"].get("allow", [])
if not isinstance(allow, list):
    print(0)
    sys.exit(0)

# Anchor on the path followed by ":*" — the tail every real rule carries —
# so a longer path with this one as a prefix, or an unrelated string that
# merely mentions the file, does not count as coverage. Rule variants (an
# rtk-prefixed twin, python3 flags) still match.
for entry in allow:
    if not isinstance(entry, str):
        continue
    if resolved + ":*" in entry or home + ":*" in entry or tilde + ":*" in entry:
        print(1)
        sys.exit(0)
print(0)
' "$settings_path" "$target_path" "$home_spelling" "$tilde_spelling" 2>/dev/null)"
  [ "$entry_found" = "1" ] || entry_found=0
fi

if [ "$entry_found" = "1" ]; then
  pass permission-entry "$settings_path permissions.allow covers $target_path (fallback rule present)"
else
  pass permission-entry "no fallback rule in $settings_path — usually unnecessary; the skill authorizes its own turn"
  printf '\nIf a capture ever stops on a permission prompt for papercut_append.py, add\nthis to permissions.allow in your own settings.json — the path is this\ninstall, resolved:\n\n'
  printf '  "Bash(python3 %s:*)"\n\n' "$target_path"
  printf 'docs/install.md step 4 names the cases that need the fallback rule; see it\nfor the sandbox write-allowlist entries too.\n'
fi

# --- 8. owners registry + labels --------------------------------------
gh_cmd="${PAPERCUT_GH_CMD:-gh}"

if [ -z "${PAPERCUT_OWNERS:-}" ] && [ "$config_ok" -ne 1 ]; then
  fail owners "skipped — the config check failed, so the registry location cannot be resolved"
else
  owners_path_output="$(python3 -c '
import os
import sys
sys.path.insert(0, sys.argv[1])
import papercut_owners
try:
    print(papercut_owners.registry_path(os.environ))
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(2)
' "$SCRIPT_DIR" 2>&1)"
  owners_path_rc=$?
  if [ "$owners_path_rc" -ne 0 ]; then
    fail owners "could not resolve the registry path: $owners_path_output"
  elif [ ! -e "$owners_path_output" ]; then
    pass owners "no registry at $owners_path_output; triage not configured"
  else
    owners_json="$(python3 "$SCRIPT_DIR/papercut_owners.py" --json 2>&1)"
    owners_json_rc=$?
    if [ "$owners_json_rc" -ne 0 ]; then
      fail owners "$owners_json"
    else
      # Same required-label logic as papercut-labels.sh's target listing (see
      # that script for the design): the five plugin labels for every
      # registered owner plus that owner's own `labels`, and the five alone
      # for `unowned` (where unowned and external clusters file, design
      # §4.3). A deliberate copy, kept in sync by hand, the same way the
      # borrowed-trust gate above is a copy of papercut-flush.sh's.
      owners_targets="$(python3 - "$owners_json" <<'PY'
import json
import sys

registry = json.loads(sys.argv[1])
required = ["papercut", "priority:high", "priority:medium", "priority:low", "papercut-fix-now"]

entries = {}
for name, owner in registry["owners"].items():
    labels = list(required)
    for label in owner["labels"]:
        if label not in labels:
            labels.append(label)
    entries[name] = (owner["repo"], labels)

unowned_repo = (registry.get("unowned") or {}).get("repo")
if unowned_repo:
    entries["unowned"] = (unowned_repo, list(required))

for name in sorted(entries):
    repo, labels = entries[name]
    print(f"{name}\t{repo}\t{','.join(labels)}")
PY
)"
      owners_work="$(mktemp -d "${TMPDIR:-/tmp}/papercut-doctor-owners.XXXXXX")"
      trap 'rm -rf "$owners_work"' EXIT

      owners_cache_for() {
        printf '%s/existing.%s\n' "$owners_work" "$(printf '%s' "$1" | tr '/' '_')"
      }

      list_fail_parts=()
      failed_repos=""
      if [ -n "$owners_targets" ]; then
        while IFS= read -r repo; do
          [ -n "$repo" ] || continue
          cache="$(owners_cache_for "$repo")"
          out="$($gh_cmd label list --repo "$repo" --json name --limit 1000 2>"$owners_work/list-stderr")"
          rc=$?
          err="$(cat "$owners_work/list-stderr")"
          rm -f "$owners_work/list-stderr"
          if [ "$rc" -ne 0 ]; then
            err_tail="$(printf '%s\n' "$err" | tail -n 5)"
            list_fail_parts+=("$repo: gh label list failed: $err_tail")
            failed_repos="$failed_repos|$repo|"
            continue
          fi
          printf '%s' "$out" | python3 -c '
import json
import sys

for item in json.load(sys.stdin):
    print(item["name"])
' >"$cache"
        done < <(printf '%s\n' "$owners_targets" | cut -f2 | sort -u)
      fi

      missing_parts=()
      missing_names=()
      target_count=0
      while IFS=$'\t' read -r name repo labels_csv; do
        [ -n "$name" ] || continue
        target_count=$((target_count + 1))
        case "$failed_repos" in
          *"|$repo|"*) continue ;;
        esac
        cache="$(owners_cache_for "$repo")"
        IFS=',' read -r -a label_arr <<<"$labels_csv"
        missing=""
        for label in "${label_arr[@]}"; do
          if grep -Fxq -- "$label" "$cache" 2>/dev/null; then
            continue
          fi
          have="$(grep -Fix -m1 -- "$label" "$cache" 2>/dev/null)"
          if [ -n "$have" ]; then
            item="case mismatch: $have vs $label"
          else
            item="$label"
          fi
          if [ -z "$missing" ]; then
            missing="$item"
          else
            missing="$missing, $item"
          fi
        done
        if [ -n "$missing" ]; then
          missing_parts+=("$name ($repo) missing: $missing")
          missing_names+=("$name")
        fi
      done <<<"$owners_targets"

      if [ "${#missing_parts[@]}" -eq 0 ] && [ "${#list_fail_parts[@]}" -eq 0 ]; then
        pass owners "$target_count owner(s), every required label present"
      else
        msg=""
        for part in "${missing_parts[@]}" "${list_fail_parts[@]}"; do
          if [ -z "$msg" ]; then
            msg="$part"
          else
            msg="$msg; $part"
          fi
        done
        if [ "${#missing_names[@]}" -eq 1 ]; then
          msg="$msg — run scripts/papercut-labels.sh ${missing_names[0]} --apply"
        elif [ "${#missing_names[@]}" -gt 1 ]; then
          msg="$msg — run scripts/papercut-labels.sh --all --apply"
        fi
        if [ "${#list_fail_parts[@]}" -gt 0 ]; then
          msg="$msg; run the doctor unsandboxed with gh authenticated"
        fi
        fail owners "$msg"
      fi
    fi
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%s check(s) failed.\n' "$failures"
  exit 1
fi
printf '\nAll checks passed.\n'
exit 0
