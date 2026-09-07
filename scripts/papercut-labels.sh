#!/usr/bin/env bash
# papercut-labels.sh — attended label provisioning for the owners registry.
#
# Usage:
#   papercut-labels.sh <owner>|unowned [--apply]
#   papercut-labels.sh --all           [--apply]
#
# Required label set for every registered [owners.*] entry, and for
# `unowned` (where filing without an identified owner, and every
# [external.*] target, lands per design §4.3): papercut, priority:high,
# priority:medium, priority:low, papercut-fix-now, plus — for a registered
# owner only — that owner's own `labels` array. `unowned` gets the five
# plugin labels and nothing more. [external.*] targets file nowhere
# themselves and are never provisioned.
#
# Without --apply, this only reports: one block per target naming the
# labels still missing in its repo, or that all are present. Nothing is
# created. A required label present under a different case is reported as
# a case mismatch and is never created by --apply — GitHub label names are
# case-insensitive for uniqueness, so creating one would just collide.
#
# With --apply, one `gh label create --force` runs per missing label
# (case mismatches excluded), serially. A failed create does not stop the
# rest; the script exits non-zero if any create failed, after attempting
# them all.
#
# Two targets can share a repo; each distinct repo's existing labels are
# read once with `gh label list --repo <repo> --json name --limit 1000`,
# before any target's block is printed. A failed list is never treated as
# "all labels missing" — it aborts the run.
#
# See dev_docs/designs/2026-09-07-triage-and-route.md §5.
#
# Env overrides:
#   PAPERCUT_GH_CMD       the `gh` seam (default: gh); tests point this at a
#                         stub script that returns fixture label lists and
#                         logs create calls instead of a real one
#   PAPERCUT_OWNERS       registry file path, passed through to
#                         papercut_owners.py
#   PAPERCUT_LEDGER_DIR   ledger clone path, passed through to
#                         papercut_owners.py
#   PAPERCUT_CONFIG       config file path, passed through to
#                         papercut_owners.py (needed only when the registry
#                         relies on [ledger].repo to resolve unowned.repo)

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gh_cmd="${PAPERCUT_GH_CMD:-gh}"

usage() {
  echo "usage: $(basename "$0") <owner>|unowned|--all [--apply]" >&2
  exit 2
}

owner_arg=""
apply=0
saw_target=0

for arg in "$@"; do
  case "$arg" in
    --apply)
      apply=1
      ;;
    --all)
      [ "$saw_target" -eq 1 ] && usage
      owner_arg="--all"
      saw_target=1
      ;;
    -*)
      usage
      ;;
    *)
      [ "$saw_target" -eq 1 ] && usage
      owner_arg="$arg"
      saw_target=1
      ;;
  esac
done

[ "$saw_target" -eq 1 ] || usage

registry_json="$(python3 "$script_dir/papercut_owners.py" --json)"
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

# One TSV line per target to process: name<TAB>repo<TAB>comma-joined required
# labels (the five required labels first, then an owner's own labels, deduped
# in that order). "unowned" is a target alongside the registered owners, with
# no extra labels; its repo may be absent from the registry JSON (no
# [ledger].repo and no unowned.repo set), in which case it is skipped with no
# error rather than treated as a target. Unknown name -> exit 2 on stderr.
targets="$(python3 - "$registry_json" "$owner_arg" <<'PY'
import json
import sys

registry = json.loads(sys.argv[1])
target = sys.argv[2]
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

if target == "--all":
    names = sorted(entries)
else:
    if target not in entries:
        known = ", ".join(sorted(entries)) or "none"
        print(f"papercut-labels.sh: unknown target {target!r} (registered: {known})", file=sys.stderr)
        sys.exit(2)
    names = [target]

for name in names:
    repo, labels = entries[name]
    print(f"{name}\t{repo}\t{','.join(labels)}")
PY
)"
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

[ -n "$targets" ] || exit 0

work="$(mktemp -d "${TMPDIR:-/tmp}/papercut-labels.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cache_file_for() {
  printf '%s/existing.%s\n' "$work" "$(printf '%s' "$1" | tr '/' '_')"
}

# fetch_existing <repo> — populate this repo's cache file with its current
# label names, one per line. Exits non-zero (after printing guidance) on a
# failed `gh label list`; the caller aborts the whole run on that.
fetch_existing() {
  local repo="$1" cache out err rc
  cache="$(cache_file_for "$repo")"
  [ -f "$cache" ] && return 0
  out="$($gh_cmd label list --repo "$repo" --json name --limit 1000 2>"$work/list-stderr")"
  rc=$?
  err="$(cat "$work/list-stderr")"
  rm -f "$work/list-stderr"
  if [ "$rc" -ne 0 ]; then
    echo "papercut-labels.sh: gh label list --repo $repo failed:" >&2
    printf '%s\n' "$err" | tail -n 5 >&2
    echo "Run this unsandboxed with gh authenticated, then retry." >&2
    return 1
  fi
  printf '%s' "$out" | python3 -c '
import json
import sys

for item in json.load(sys.stdin):
    print(item["name"])
' >"$cache"
}

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  fetch_existing "$repo" || exit 1
done < <(printf '%s\n' "$targets" | cut -f2 | sort -u)

apply_failed=0

while IFS=$'\t' read -r name repo labels_csv; do
  [ -n "$name" ] || continue
  cache="$(cache_file_for "$repo")"
  IFS=',' read -r -a label_arr <<<"$labels_csv"
  total_count=${#label_arr[@]}

  missing=""
  missing_count=0
  creatable=()
  for label in "${label_arr[@]}"; do
    if grep -Fxq -- "$label" "$cache" 2>/dev/null; then
      continue
    fi
    missing_count=$((missing_count + 1))
    have="$(grep -Fix -m1 -- "$label" "$cache" 2>/dev/null)"
    if [ -n "$have" ]; then
      item="case mismatch: $have vs $label"
    else
      item="$label"
      creatable+=("$label")
    fi
    if [ -z "$missing" ]; then
      missing="$item"
    else
      missing="$missing, $item"
    fi
  done

  if [ "$missing_count" -eq 0 ]; then
    printf '%s (%s): all %d label(s) present\n' "$name" "$repo" "$total_count"
    continue
  fi
  printf '%s (%s): missing %d label(s): %s\n' "$name" "$repo" "$missing_count" "$missing"

  [ "$apply" -eq 1 ] || continue
  for label in "${creatable[@]}"; do
    err="$($gh_cmd label create "$label" --repo "$repo" --force 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'papercut-labels.sh: failed to create %s in %s: %s\n' "$label" "$repo" "$err" >&2
      apply_failed=1
    else
      printf 'created %s: %s\n' "$repo" "$label"
    fi
  done
done <<<"$targets"

[ "$apply_failed" -eq 0 ] || exit 1
exit 0
