#!/usr/bin/env bash
# Flushes the papercuts spool: claims it into a uniquely-named batch file
# under the SAME lock that agents/papercuts/papercut_append.py holds across
# its entire append, groups the claimed (and any previously-stranded) batch
# by month, quarantines malformed lines, and hands each month-group to a
# publish hook point.
#
# Publish seam:
#   $PAPERCUT_PUBLISH_CMD <month-group-file> <YYYY-MM>
#   Exit 0 = published; non-zero = failed. Default is _papercut_publish_git
#   (below) — clones/reuses the ledger repo, then does ALL reconcile/commit/
#   push work in a disposable DETACHED WORKTREE created fresh from the
#   fetched origin/main tip, never in the clone's own checked-out worktree.
#   Reconciles ledger/<YYYY-MM>.jsonl by record `id` against that tip and
#   pushes. Tests override the env var with a stub. Called once per YYYY-MM
#   group found in a batch.
#
#   Because the user's clone's checked-out worktree/branch/HEAD is never
#   read from or written to (beyond a plain `fetch`), a dirty tree, a
#   checkout on some other branch, or a detached HEAD there can no longer be
#   damaged by publishing, nor can any of those states block a publish — the
#   only hard gate left is the origin remote-URL check below (a wrong or
#   hostile origin must still never receive a push).
#
# Real publisher env overrides (also so tests never touch the real ledger):
#   PAPERCUT_LEDGER_DIR     ledger clone path (default ~/src/papercuts)
#   PAPERCUT_LEDGER_REMOTE  git remote URL for clone + the safety check;
#                           default is unset, meaning "clone via
#                           `gh repo clone bestdan/papercuts-ledger`" and accept
#                           only an origin that is exactly git@github.com:bestdan/
#                           papercuts-ledger(.git) or https://github.com/bestdan/
#                           papercuts-ledger(.git), optionally with a trailing slash
#
# Duplicate/idempotency note (by design — see papercuts_task_4__push):
#   The fresh-spool claim is exclusive via the shared flock, but stale-batch
#   recovery is intentionally NOT mutually exclusive, and a partial publish
#   retains (and re-publishes) the whole batch. Both can re-present a record
#   whose month already published; the push slice dedups by record `id`, so a
#   re-publish is a harmless no-op. We rely on that rather than adding fragile
#   per-batch ownership locks or per-month checkpoints here.
#
# Lock/claim/recovery discipline:
#   - There is no `flock(1)` on stock macOS, so the locked claim is done by
#     a tiny embedded python3 helper using fcntl.flock — the SAME primitive
#     papercut_append.py uses, on the SAME lock file ($PAPERCUT_LOCK). Since
#     append and claim both hold this one lock across their entire critical
#     section, they can never interleave: an append either fully lands in
#     the spool before a claim's rename, or fully lands in the NEW spool
#     created after the rename. No window exists where a write is silently
#     orphaned on an inode about to be deleted.
#   - The lock is held ONLY for "check non-empty + rename to a unique
#     spool.batch.<ts>.<pid>.jsonl name" — it is released immediately after,
#     before any grouping/publishing happens outside the lock.
#   - Every run also globs existing spool.batch.* files (stale batches left
#     by a prior crash/SIGKILL) and processes them oldest-first alongside
#     whatever was just claimed. A batch is deleted ONLY after its publish
#     calls are confirmed successful; any failure retains the whole batch
#     file untouched so the next run retries it (idempotent downstream via
#     record `id`, per papercuts_task_4__push).
#
# Stamp semantics:
#   - PAPERCUT_FLUSH_OK (success stamp, ~24h): refreshed after a run where
#     every batch that existed was fully published and deleted. Suppresses
#     normal (non --force) runs for ~24h.
#   - PAPERCUT_FLUSH_FAIL (failure stamp, ~1h): set after a run where at
#     least one batch could not be published. Suppresses normal runs for
#     ~1h (a shorter backoff so transient publish failures retry sooner).
#   - Whichever stamp is fresher wins normal throttling; --force bypasses
#     BOTH stamps, but NOT the "nothing to do" fast-exit (empty spool, no
#     stray batches) — --force does not manufacture work.
#
# Work-host review-before-publish:
#   On the betterment profile, a normal (non --force) run HOLDS instead of
#   publishing — it logs "hold reason=work-host-review" and exits 0, leaving
#   the spool/stray batches untouched (no claim, no stamp write). --force
#   bypasses the hold (and the throttle) and publishes as usual. --review
#   prints pending records (spool + stray spool.batch.*) read-only, without
#   claiming/publishing/stamping, so the hold can be audited before --force.
#   The default profile is unaffected — normal runs still auto-publish there.
#
# Env overrides (all so tests never touch real ~/.claude or ~/.cache):
#   PAPERCUT_SPOOL           default ~/.claude/papercuts/spool.jsonl
#   PAPERCUT_LOCK            default <spool dir>/.spool.lock (shared with
#                             papercut_append.py — do not change independently)
#   PAPERCUT_BATCH_DIR       default <spool dir>
#   PAPERCUT_QUARANTINE_DIR  default <spool dir>/quarantine
#   PAPERCUT_FLUSH_OK        default ~/.cache/papercuts/flush-ok
#   PAPERCUT_FLUSH_FAIL      default ~/.cache/papercuts/flush-fail
#   PAPERCUT_LOG             default <spool dir>/flush.log
#   PAPERCUT_LOG_MAX_BYTES   default 1048576 (rotate to .1 past this size)
#   PAPERCUT_PUBLISH_CMD     default _papercut_publish_stub (see above)

set -uo pipefail

FORCE=0
REVIEW=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --review) REVIEW=1 ;;
  esac
done

SPOOL="${PAPERCUT_SPOOL:-$HOME/.claude/papercuts/spool.jsonl}"
SPOOL_DIR="$(dirname "$SPOOL")"
LOCK="${PAPERCUT_LOCK:-$SPOOL_DIR/.spool.lock}"
BATCH_DIR="${PAPERCUT_BATCH_DIR:-$SPOOL_DIR}"
QUARANTINE_DIR="${PAPERCUT_QUARANTINE_DIR:-$BATCH_DIR/quarantine}"
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/papercuts"
FLUSH_OK="${PAPERCUT_FLUSH_OK:-$CACHE_BASE/flush-ok}"
FLUSH_FAIL="${PAPERCUT_FLUSH_FAIL:-$CACHE_BASE/flush-fail}"
LOG="${PAPERCUT_LOG:-$SPOOL_DIR/flush.log}"
LOG_MAX_BYTES="${PAPERCUT_LOG_MAX_BYTES:-1048576}"

# Machine detection (hoisted so the work-host review-before-publish hold gate
# can see it before any spool mutation happens; also used by
# _papercut_publish_git's commit message below). Computed once, early, from
# the real `hostname` — tests inject an alternate host by putting a fake
# `hostname` shim earlier on PATH. Case-insensitive and domain-stripped (a
# lowercased or FQDN form still matches), mirroring papercut_append.py's
# _is_betterment_host — this now gates publishing itself, not just a log
# line, so it must classify a work host at least as reliably as the gate does.
host="$(hostname)"
host_short="${host%%.*}"
host_upper="$(printf '%s' "$host_short" | tr '[:lower:]' '[:upper:]')"
machine="default"
case "$host_upper" in
  NYC-BETTERMENT*) machine="betterment" ;;
esac

# shellcheck disable=SC2329 # invoked indirectly via $PAPERCUT_PUBLISH_CMD
_papercut_remote_url_trusted() {
  # $1=actual origin URL, $2=configured remote (may be empty). Anchored
  # match — no substring check — so a hostile lookalike host (e.g.
  # https://evil.example/bestdan/papercuts-ledger.git) can never pass.
  local url="$1" configured="$2"
  if [ -n "$configured" ]; then
    [ "$url" = "$configured" ]
    return
  fi
  [[ "$url" =~ ^git@github\.com:bestdan/papercuts-ledger(\.git)?/?$ ]] && return 0
  [[ "$url" =~ ^https://github\.com/bestdan/papercuts-ledger(\.git)?/?$ ]] && return 0
  return 1
}

# shellcheck disable=SC2329 # invoked indirectly via $PAPERCUT_PUBLISH_CMD
_papercut_publish_git_cleanup_worktree() {
  # $1=dir (user's clone), $2=wt (disposable worktree path, may be empty).
  # Called on EVERY exit path of _papercut_publish_git (success, failure, and
  # before each retry's fresh worktree), so a worktree can never leak.
  local dir="$1" wt="$2"
  [ -n "$wt" ] || return 0
  git -C "$dir" worktree remove --force "$wt" >>"$LOG" 2>&1
  rm -rf "$wt" 2>/dev/null
}

# shellcheck disable=SC2329 # invoked indirectly via $PAPERCUT_PUBLISH_CMD
_papercut_publish_git() {
  # Real publisher. $1=month-group file (JSONL), $2=YYYY-MM. See header for
  # the env overrides and the disposable-worktree design. The user's clone at
  # $dir is only ever read (remote URL) and fetched — every reconcile/commit/
  # push happens in a throwaway detached worktree created fresh from the
  # fetched origin/main tip, then removed before this function returns.
  # Every exit path either returns 0 with the records confirmed on the
  # remote, or returns non-zero having left $dir's own worktree untouched
  # beyond the fetch — the caller (below) retains the batch on any non-zero
  # return, and the record `id` dedup makes a retry of an already-published
  # batch a harmless no-op.
  local group_file="$1" month="$2"
  local dir="${PAPERCUT_LEDGER_DIR:-$HOME/src/papercuts}"
  local configured_remote="${PAPERCUT_LEDGER_REMOTE:-}"
  local gh_repo="bestdan/papercuts-ledger"

  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$(dirname "$dir")" 2>/dev/null
    if [ -n "$configured_remote" ]; then
      if ! git clone --quiet "$configured_remote" "$dir" >>"$LOG" 2>&1; then
        log "publish: clone of $configured_remote into $dir failed"
        return 1
      fi
    else
      if ! gh repo clone "$gh_repo" "$dir" -- --quiet >>"$LOG" 2>&1; then
        log "publish: gh repo clone $gh_repo into $dir failed (offline?)"
        return 1
      fi
    fi
  fi

  # --- safety check: the origin remote URL must be trusted. This is now the
  # ONLY hard gate — we never mutate $dir's own checked-out worktree/branch/
  # HEAD, so a dirty tree, wrong branch, or detached HEAD there can no longer
  # be damaged by publishing, nor can any of those states block one.
  local remote_url remote_rc push_url push_rc
  remote_url="$(git -C "$dir" remote get-url origin 2>>"$LOG")"
  remote_rc=$?
  if [ "$remote_rc" -ne 0 ] || [ -z "$remote_url" ]; then
    log "publish: cannot read origin remote url in $dir (rc=$remote_rc); refusing"
    return 1
  fi
  if ! _papercut_remote_url_trusted "$remote_url" "$configured_remote"; then
    log "publish: untrusted origin fetch url ($remote_url); refusing"
    return 1
  fi
  # The push resolves remote.origin.pushurl when one is set, which the fetch
  # url above does NOT reflect — so a reused clone with a hostile pushurl would
  # sail past the fetch-url check yet still receive the push. Validate the push
  # url (what `git push origin` actually targets) with the same anchored gate.
  push_url="$(git -C "$dir" remote get-url --push origin 2>>"$LOG")"
  push_rc=$?
  if [ "$push_rc" -ne 0 ] || [ -z "$push_url" ]; then
    log "publish: cannot read origin push url in $dir (rc=$push_rc); refusing"
    return 1
  fi
  if ! _papercut_remote_url_trusted "$push_url" "$configured_remote"; then
    log "publish: untrusted origin push url ($push_url); refusing"
    return 1
  fi

  # $machine is computed once, early, at top-level (see hoisted detection
  # above) and reused here for the commit message.
  local target_rel="ledger/$month.jsonl"
  local wt="" fetch_rc
  local attempt=1 max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
    git -C "$dir" fetch --quiet origin main >>"$LOG" 2>&1
    fetch_rc=$?
    if [ "$fetch_rc" -ne 0 ]; then
      log "publish: fetch failed on attempt $attempt (rc=$fetch_rc, offline?)"
      _papercut_publish_git_cleanup_worktree "$dir" "$wt"
      return 1
    fi

    # Always reconcile in a FRESH disposable worktree at the tip just
    # fetched. Drop any leftover from a prior attempt first — a non-ff push
    # rejection means origin/main moved, so the old worktree's base is stale
    # and must be rebuilt against the new tip, not reused.
    _papercut_publish_git_cleanup_worktree "$dir" "$wt"
    wt="$(mktemp -d "${TMPDIR:-/tmp}/papercut-flush-wt.XXXXXX")"
    if ! git -C "$dir" worktree add --detach --quiet "$wt" origin/main >>"$LOG" 2>&1; then
      log "publish: worktree add failed on attempt $attempt"
      # Clean up before clearing $wt so the just-created mktemp dir (and any
      # partial worktree metadata git registered before failing) can't leak —
      # the cleanup helper's stated invariant is "called on EVERY exit path".
      _papercut_publish_git_cleanup_worktree "$dir" "$wt"
      wt=""
      return 1
    fi

    local new_count py_rc
    new_count="$(python3 - "$wt/$target_rel" "$group_file" <<'PY'
import json
import os
import sys

target, group = sys.argv[1], sys.argv[2]


def load_ids(path):
    ids = set()
    if not os.path.exists(path):
        return ids
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            rid = rec.get("id") if isinstance(rec, dict) else None
            if not isinstance(rid, str) or not rid:
                raise ValueError("existing ledger record has no valid id: %r" % line)
            ids.add(rid)
    return ids


try:
    existing_ids = load_ids(target)

    new_lines = []
    with open(group, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            rid = rec.get("id") if isinstance(rec, dict) else None
            if not isinstance(rid, str) or not rid:
                raise ValueError("record has no valid id: %r" % line)
            if rid in existing_ids:
                continue
            existing_ids.add(rid)
            new_lines.append(line)
except Exception as exc:
    # Fail closed: never silently drop a line and report the group
    # published. A corrupt/unparseable/id-less line retains the WHOLE batch.
    print("ERROR: %s" % exc, file=sys.stderr)
    sys.exit(1)

if new_lines:
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    with open(target, "a", encoding="utf-8") as f:
        for line in new_lines:
            f.write(line + "\n")

print(len(new_lines))
PY
)"
    py_rc=$?

    if [ "$py_rc" -ne 0 ] || [ -z "$new_count" ]; then
      log "publish: dedup step failed for month=$month on attempt $attempt (invalid/corrupt record id?)"
      _papercut_publish_git_cleanup_worktree "$dir" "$wt"
      return 1
    fi
    if [ "$new_count" -eq 0 ]; then
      log "publish: month=$month has nothing new (already published)"
      _papercut_publish_git_cleanup_worktree "$dir" "$wt"
      return 0
    fi

    git -C "$wt" add "$target_rel" >>"$LOG" 2>&1
    if ! git -C "$wt" commit --quiet -m "chore: append $new_count papercuts from $machine" >>"$LOG" 2>&1; then
      log "publish: commit failed for month=$month on attempt $attempt"
      _papercut_publish_git_cleanup_worktree "$dir" "$wt"
      return 1
    fi

    if git -C "$wt" push --quiet origin HEAD:main >>"$LOG" 2>&1; then
      local local_head remote_head short_head
      local_head="$(git -C "$wt" rev-parse HEAD 2>>"$LOG")"
      short_head="$(git -C "$wt" rev-parse --short HEAD 2>>"$LOG")"
      remote_head="$(git -C "$dir" ls-remote origin main 2>>"$LOG" | cut -f1)"
      if [ -n "$local_head" ] && [ "$local_head" = "$remote_head" ]; then
        log "publish: month=$month pushed $new_count record(s) on attempt $attempt (confirmed)"
        # Confirm on stdout, not just in $LOG. A silent exit 0 is indistinguishable
        # from a no-op, which has cost re-runs that claimed a second batch. Name
        # origin/main explicitly: publishing deliberately never fast-forwards the
        # user's own checkout (see the worktree note above), so verifying against
        # the local clone yields a confident false negative.
        #
        # Say "intentionally untouched" rather than naming $dir as behind. The
        # clause is a signpost for whoever verifies this push, not a chore for
        # the user: nothing in the flush path reads $dir's working tree, so its
        # staleness has no consequence. Phrased as state ("$dir is not
        # fast-forwarded") it read as an outstanding task, and agents spent
        # sessions offering to pull a clone that did not need pulling.
        echo "papercut-flush: published $new_count record(s) to $target_rel @ $short_head on origin/main (local clone intentionally untouched)"
        _papercut_publish_git_cleanup_worktree "$dir" "$wt"
        return 0
      fi
      log "publish: push confirm mismatch for month=$month on attempt $attempt; retrying with a fresh worktree"
    else
      log "publish: push rejected (likely non-fast-forward) for month=$month on attempt $attempt; retrying with a fresh worktree"
    fi

    attempt=$((attempt + 1))
  done

  log "publish: gave up on month=$month after $max_attempts attempts"
  _papercut_publish_git_cleanup_worktree "$dir" "$wt"
  return 1
}
: "${PAPERCUT_PUBLISH_CMD:=_papercut_publish_git}"

log() {
  local msg="$1" log_dir size
  log_dir="$(dirname "$LOG")"
  mkdir -p "$log_dir" 2>/dev/null
  if [ -f "$LOG" ]; then
    size=$(stat -c %s "$LOG" 2>/dev/null || stat -f %z "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
      mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$LOG" 2>/dev/null
  chmod 0600 "$LOG" 2>/dev/null
}

stamp_age() {
  # Prints the age in seconds of $1, or a huge number if it doesn't exist.
  local path="$1" mtime now
  if [ ! -f "$path" ]; then
    printf '%s' 999999999
    return
  fi
  mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null)
  now=$(date +%s)
  if [ -z "$mtime" ]; then
    printf '%s' 999999999
    return
  fi
  printf '%s' $((now - mtime))
}

touch_stamp() {
  local path="$1" dir
  dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null
  : >"$path" 2>/dev/null
}

# --- review: read-only audit of pending records, never publishes -----------
# Prints the current spool plus any stray spool.batch.* files, pretty-printed,
# then exits. No claim, no publish, no stamp write — safe to run any time.
if [ "$REVIEW" -eq 1 ]; then
  shopt -s nullglob
  review_batches=("$BATCH_DIR"/spool.batch.*)
  shopt -u nullglob
  review_files=()
  [ -s "$SPOOL" ] && review_files+=("$SPOOL")
  # Guard the empty-array case: on bash 3.2 (macOS system bash) expanding
  # "${review_batches[@]}" of an empty array under `set -u` aborts with
  # "unbound variable" (see papercut-sweep.sh's anchor_files guard).
  [ "${#review_batches[@]}" -gt 0 ] && review_files+=("${review_batches[@]}")

  if [ "${#review_files[@]}" -eq 0 ]; then
    echo "papercuts: nothing pending"
    exit 0
  fi

  count=0
  for review_file in "${review_files[@]}"; do
    while IFS= read -r review_line; do
      [ -n "$review_line" ] || continue
      count=$((count + 1))
      if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$review_line" | jq .
      else
        printf '%s\n' "$review_line" | python3 -m json.tool
      fi
    done <"$review_file"
  done
  echo "papercuts: $count record(s) pending review"
  exit 0
fi

# --- hold: on the betterment profile, a non-force run never publishes ------
# Auto-flush (e.g. from SessionStart) must not push work-host records to the
# ledger unreviewed. A human runs --review to audit, then --force to publish
# the vetted set. The spool/stray batches are left untouched; no stamp write.
if [ "$machine" = "betterment" ] && [ "$FORCE" -ne 1 ]; then
  log "hold reason=work-host-review"
  exit 0
fi

# --- fast exit: nothing to do -----------------------------------------------
shopt -s nullglob
existing_batches=("$BATCH_DIR"/spool.batch.*)
shopt -u nullglob
spool_has_content=0
[ -s "$SPOOL" ] && spool_has_content=1

if [ "$spool_has_content" -eq 0 ] && [ "${#existing_batches[@]}" -eq 0 ]; then
  exit 0
fi

# --- throttle (bypassed by --force) -----------------------------------------
# A recent failure always backs off ~1h. The success stamp (~24h) throttles
# only NEW spool content — a batch already stranded on disk (prior failure or
# crash) must NOT be masked by it, so we bypass the success throttle whenever
# stale batches exist. Each outcome also clears the opposing stamp (below), so
# a success stamp can't linger past a subsequent failure and suppress retries.
if [ "$FORCE" -ne 1 ]; then
  fail_age=$(stamp_age "$FLUSH_FAIL")
  if [ "$fail_age" -lt 3600 ]; then
    echo "papercut-flush: held (recent failure ${fail_age}s ago, backing off ~1h); rerun with --force to publish now"
    exit 0
  fi
  if [ "${#existing_batches[@]}" -eq 0 ]; then
    ok_age=$(stamp_age "$FLUSH_OK")
    if [ "$ok_age" -lt 86400 ]; then
      echo "papercut-flush: held (throttled, last flush ${ok_age}s ago, <24h); rerun with --force to publish now"
      exit 0
    fi
  fi
fi

mkdir -p "$BATCH_DIR" "$QUARANTINE_DIR" 2>/dev/null
chmod 0700 "$BATCH_DIR" "$QUARANTINE_DIR" 2>/dev/null

# --- claim: rename the spool to a uniquely-named batch under the shared lock
any_failure=0
claim_helper="$(dirname "$0")/papercut_flush_claim.py"
if [ "$spool_has_content" -eq 1 ]; then
  claimed="$(python3 "$claim_helper" "$LOCK" "$SPOOL" "$BATCH_DIR" 2>>"$LOG")"
  claim_rc=$?
  if [ "$claim_rc" -ne 0 ]; then
    # Claim failed (rename error, missing helper, …) so the spool was NOT
    # processed. Mark failure so this run takes the ~1h FAIL stamp and retries
    # soon, rather than leaving the spool eligible for the ~24h SUCCESS stamp,
    # which would mask the still-unclaimed spool for a day.
    any_failure=1
    log "claim failed rc=$claim_rc for spool=$(basename "$SPOOL"); will retry after fail backoff"
  elif [ -n "$claimed" ]; then
    log "claimed batch=$(basename "$claimed")"
  fi
fi

# --- gather every batch to process: freshly claimed + any stale leftovers --
shopt -s nullglob
batch_glob=("$BATCH_DIR"/spool.batch.*)
shopt -u nullglob
# Sort oldest-first. Batch filenames embed a zero-padded UTC timestamp, so a
# lexical sort is also a chronological sort. Built with a read loop rather than
# `mapfile` (bash 4+): macOS ships bash 3.2, where mapfile is absent and would
# silently leave the list unsorted (and print an error every run).
batches=()
if [ "${#batch_glob[@]}" -gt 0 ]; then
  while IFS= read -r _b; do batches+=("$_b"); done < <(printf '%s\n' "${batch_glob[@]}" | sort)
fi

if [ "${#batches[@]}" -eq 0 ]; then
  # Claimed nothing and nothing stale. Normally this means the spool emptied
  # between the fast-exit check and the claim; but if the claim itself FAILED
  # (any_failure=1), record the failure stamp so the un-claimed spool retries
  # on the ~1h backoff instead of exiting as a silent success.
  if [ "$any_failure" -eq 1 ]; then
    rm -f "$FLUSH_OK" 2>/dev/null
    touch_stamp "$FLUSH_FAIL"
    log "claim failed and no batch to process; recorded failure stamp"
    exit 1
  fi
  exit 0
fi

group_helper="$(dirname "$0")/papercut_flush_group.py"

for batch_file in "${batches[@]}"; do
  [ -f "$batch_file" ] || continue
  group_dir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-flush-group.XXXXXX")"
  months="$(python3 "$group_helper" "$batch_file" "$QUARANTINE_DIR" "$group_dir" 2>>"$LOG")"
  group_rc=$?

  batch_ok=1
  if [ "$group_rc" -ne 0 ]; then
    # Grouping itself failed (unreadable batch, undecodable bytes, …). An empty
    # $months here is NOT "nothing to publish, success" — it means we never
    # parsed the batch. Retain it so no records are lost to a deleted batch.
    batch_ok=0
    log "grouping failed rc=$group_rc for batch=$(basename "$batch_file"); retaining"
  elif [ -n "$months" ]; then
    while IFS= read -r month; do
      [ -n "$month" ] || continue
      if ! "$PAPERCUT_PUBLISH_CMD" "$group_dir/$month.jsonl" "$month"; then
        batch_ok=0
        log "publish failed for batch=$(basename "$batch_file") month=$month"
      fi
    done <<<"$months"
  fi
  rm -rf "$group_dir"

  if [ "$batch_ok" -eq 1 ]; then
    rm -f "$batch_file"
    log "published and removed batch=$(basename "$batch_file")"
  else
    any_failure=1
    log "retaining batch=$(basename "$batch_file") after publish failure"
  fi
done

# Clear the opposing stamp on each outcome so exactly one is ever fresh: a
# success stamp left over from an earlier run must not survive a later failure
# and suppress its ~1h retry (and vice-versa).
if [ "$any_failure" -eq 1 ]; then
  rm -f "$FLUSH_OK" 2>/dev/null
  touch_stamp "$FLUSH_FAIL"
  log "flush run completed with failures"
  exit 1
fi

rm -f "$FLUSH_FAIL" 2>/dev/null
touch_stamp "$FLUSH_OK"
log "flush run completed successfully"
exit 0
