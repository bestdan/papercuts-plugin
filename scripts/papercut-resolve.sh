#!/usr/bin/env bash
# Manual CLI to mark a papercut resolved: builds a resolution record
# ({resolves, status, fix_url?}) and pipes it through papercut_append.py
# (--type resolution), the same trusted gate every other record type funnels
# through (construct -> validate -> scrub -> revalidate -> append).
#
# Usage:
#   papercut-resolve.sh <pc_id> <status> [fix_url] [--force]
#
#   <pc_id>    the target papercut's id (pc_<uuid> form)
#   <status>   one of: fixed, mitigated, reported-upstream, wontfix,
#              out-of-scope
#   [fix_url]  http(s) URL (e.g. a commit/PR link); omit if none. REQUIRED for
#              reported-upstream and out-of-scope, which are claims about a
#              place and are unfollowable without it
#   --force    skip the existence and already-resolved checks (see below);
#              may appear anywhere
#
# Existence check (typo protection): unless --force is given, <pc_id> must
# appear as a record id somewhere in the ledger clone (ledger/*.jsonl under
# $PAPERCUT_LEDGER_DIR) or the local spool ($PAPERCUT_SPOOL). This is a
# best-effort sanity check, not authoritative — a papercut that hasn't
# flushed yet still resolves fine as long as it's in the spool, and --force
# lets you resolve an id this script can't see (e.g. no ledger clone here).
#
# Already-resolved check: unless --force is given, <pc_id> must not already
# have a resolution record in the ledger clone or spool. Without this, running
# the resolve CLI twice for the same id (e.g. because an earlier resolution
# was forgotten) silently appends a second resolution to the append-only
# ledger; --force skips this check too, for intentional re-resolution.
#
# Env overrides (so tests never touch the real ledger clone or spool):
#   PAPERCUT_LEDGER_DIR  ledger clone path (default ~/src/papercuts), same
#                        as papercut-flush.sh
#   PAPERCUT_SPOOL       local spool JSONL path (default
#                        ~/.claude/papercuts/spool.jsonl), same as
#                        papercut_append.py
#   PAPERCUT_APPEND_CMD  the gate command (default: `python3
#                        <this dir>/papercut_append.py`), same seam as
#                        papercut-capture.sh — tests use it to force the
#                        non-work profile via a gethostname wrapper, since
#                        the gate derives its profile from the real hostname

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $(basename "$0") <pc_id> <status> [fix_url] [--force]" >&2
  echo "  status must be one of: fixed, mitigated, reported-upstream, wontfix, out-of-scope" >&2
  exit 1
}

pc_id=""
status=""
fix_url=""
force=0
positional=()

for arg in "$@"; do
  if [ "$arg" = "--force" ]; then
    force=1
  else
    positional+=("$arg")
  fi
done

if [ "${#positional[@]}" -lt 2 ] || [ "${#positional[@]}" -gt 3 ]; then
  usage
fi
pc_id="${positional[0]}"
status="${positional[1]}"
if [ "${#positional[@]}" -eq 3 ]; then
  fix_url="${positional[2]}"
fi

if ! [[ "$pc_id" =~ ^pc_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
  echo "error: '$pc_id' is not a valid papercut id (expected pc_<uuid>)" >&2
  exit 1
fi

case "$status" in
  fixed | mitigated | reported-upstream | wontfix | out-of-scope) ;;
  *)
    echo "error: '$status' is not a valid status (expected one of: fixed, mitigated, reported-upstream, wontfix, out-of-scope)" >&2
    exit 1
    ;;
esac

if [ -n "$fix_url" ] && ! [[ "$fix_url" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "error: '$fix_url' is not a valid fix_url (expected http(s)://... with no whitespace)" >&2
  exit 1
fi

# Two statuses are claims about somewhere else, and are worthless without the
# pointer: `reported-upstream` asserts a report exists, `out-of-scope` asserts
# the work is tracked in another repo. Unwitnessed, both are indistinguishable
# from `wontfix` -- and because the ledger is append-only, a bare one is a dead
# end nobody can follow up. Require the citation rather than trusting the caller
# to supply it. Note --force does not waive this: it skips the existence and
# already-resolved *lookups*, not argument validation.
case "$status" in
  reported-upstream | out-of-scope)
    if [ -z "$fix_url" ]; then
      echo "error: status '$status' requires a fix_url naming where it is reported or tracked" >&2
      echo "       (a GitHub issue/PR or tracker URL); use 'wontfix' if there is no such place" >&2
      exit 1
    fi
    ;;
esac

ledger_dir="${PAPERCUT_LEDGER_DIR:-$HOME/src/papercuts}"
spool_path="${PAPERCUT_SPOOL:-$HOME/.claude/papercuts/spool.jsonl}"

if [ "$force" -ne 1 ]; then
  found=0
  shopt -s nullglob
  ledger_files=("$ledger_dir"/ledger/*.jsonl)
  shopt -u nullglob
  # Guard the empty-array case: on bash 3.2 (macOS system bash) expanding
  # "${ledger_files[@]}" of an empty array under `set -u` aborts with
  # "unbound variable" whenever no ledger clone/files exist yet.
  candidates=("$spool_path")
  if [ "${#ledger_files[@]}" -gt 0 ]; then
    candidates=("${ledger_files[@]}" "$spool_path")
  fi
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    # Parse each line as JSON rather than grep-matching the raw bytes: id/key
    # placement and whitespace in a JSONL line isn't guaranteed byte-for-byte
    # (e.g. hand-written test fixtures vs. papercut_append.py's own
    # sort_keys=True, ": "-separated output).
    if python3 -c '
import json, sys
target, path = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            # Match only a papercut (type absent == grandfathered papercut,
            # per papercut_open.py); a resolution sharing the id must not
            # satisfy the check, or resolving a resolution id creates an inert
            # orphan resolution.
            if (
                isinstance(obj, dict)
                and obj.get("id") == target
                and obj.get("type", "papercut") == "papercut"
            ):
                sys.exit(0)
except OSError:
    pass
sys.exit(1)
' "$pc_id" "$f"; then
      found=1
      break
    fi
  done
  if [ "$found" -ne 1 ]; then
    echo "error: '$pc_id' not found in the ledger clone ($ledger_dir/ledger/*.jsonl) or spool ($spool_path)" >&2
    echo "       pass --force to resolve it anyway (typo protection)" >&2
    exit 1
  fi

  # Scan the same candidate files for a resolution record that already
  # resolves this id; print a one-line summary of it if found, nothing
  # otherwise. Kept separate from the existence check above: that one matches
  # type=="papercut", this one matches type=="resolution" + resolves==target.
  existing_resolution="$(python3 -c '
import json, sys
target = sys.argv[1]
for path in sys.argv[2:]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if (
                    isinstance(obj, dict)
                    and obj.get("type") == "resolution"
                    and obj.get("resolves") == target
                ):
                    fix_url = obj.get("fix_url")
                    suffix = " (" + fix_url + ")" if fix_url else ""
                    print(obj.get("status", "?") + suffix)
                    sys.exit(0)
    except OSError:
        pass
' "$pc_id" "${candidates[@]}")"
  if [ -n "$existing_resolution" ]; then
    echo "error: '$pc_id' already has a resolution: $existing_resolution" >&2
    echo "       pass --force to append another resolution anyway" >&2
    exit 1
  fi
fi

payload="$(python3 -c '
import json, sys
resolves, status, fix_url = sys.argv[1], sys.argv[2], sys.argv[3]
rec = {"resolves": resolves, "status": status}
if fix_url:
    rec["fix_url"] = fix_url
print(json.dumps(rec))
' "$pc_id" "$status" "$fix_url")"

append_cmd="${PAPERCUT_APPEND_CMD:-python3 $script_dir/papercut_append.py}"
printf '%s' "$payload" | $append_cmd \
  --type resolution --source manual --producer resolve-cli/1
