#!/usr/bin/env bash
# SessionStart hook (async): backstop for sessions whose SessionEnd never
# fired (crash, kill -9, machine sleep) but which recorded friction anchors
# (task 3, papercut-anchor.sh). Also owns the anchors sidecar lifecycle:
# deletes a sidecar once its session is confirmed processed, and prunes stale
# sidecars whose transcript is gone.
#
# The live-session race: an anchors file with no processed marker describes
# every CURRENTLY RUNNING session with friction, not just dead ones. Naively
# driving papercut-capture.sh
# for a live session would extract a partial transcript, mark that partial
# hash processed, and duplicate the same early friction once the session
# really ends (different hash -> full re-extraction). Two guards keep this
# rare without claiming to eliminate it (the sweep is explicitly
# at-least-once, not duplicate-free):
#   1. Self-skip: never touch the sweep's own session's anchors file,
#      regardless of mtime -- checked first, unconditionally, before any
#      other guard.
#   2. Quiet window: skip any anchors file (or its transcript) touched within
#      the last PAPERCUT_SWEEP_QUIET_HOURS (default 24) -- an idle-but-open
#      session routinely outlives short windows.
# Only once both guards pass does a processed-marker check or transcript-
# driven capture happen. This does not make resume-re-extraction materially
# more common than the status quo: a resumed session already re-extracts on
# its own SessionEnd fire via papercut-capture.sh's hash-based idempotency.
#
# "Marker exists" is a reasonable, not airtight, proxy for "consumed": once
# quiet, the sweep trusts a present marker and deletes the anchors file
# without re-checking it against the transcript's current content hash. A
# post-window resume re-fires SessionEnd anyway, which re-extracts with or
# without anchors, so this is the same at-least-once tradeoff as above.
#
# Env overrides (all state paths overridable so tests never touch real
# ~/.claude):
#   PAPERCUT_ANCHORS_DIR        anchors jsonl dir
#                               (default ~/.claude/papercuts/anchors)
#   PAPERCUT_PROCESSED_DIR      idempotency hash dir, SAME dir as
#                               papercut-capture.sh
#                               (default ~/.claude/papercuts/processed)
#   PAPERCUT_PROJECTS_DIR       transcript search root
#                               (default ~/.claude/projects)
#   PAPERCUT_SWEEP_QUIET_HOURS  quiet window, hours (default 24)
#   PAPERCUT_ANCHOR_TTL_DAYS    prune threshold for a transcript-less
#                               anchors file, days (default 7)
#   PAPERCUT_SWEEP_MAX_SESSIONS bound on non-self anchors files EXAMINED per
#                               run (default 5) -- counted whether or not
#                               they end up skipped, so a large backlog of
#                               live (quiet-window-skipped) sessions can't
#                               make every SessionStart pay for an unbounded
#                               number of python3/os.walk lookups (this hook
#                               is async, but still shouldn't be O(backlog))
#   PAPERCUT_CAPTURE_CMD        capture seam (default: this dir's
#                               papercut-capture.sh). Tests override with a
#                               stub that records the synthesized stdin JSON
#                               it received.
#   PAPERCUT_LOG                metadata log path, SAME file as
#                               papercut-capture.sh
#                               (default ~/.claude/papercuts/capture.log)
#   PAPERCUT_LOG_MAX_BYTES      size cap (default 1048576)
#   PAPERCUT_REVIEW_FILE        scrub-review sidecar path, SAME file
#                               papercut-capture.sh exports to
#                               papercut_append.py
#                               (default ~/.claude/papercuts/scrub-review.jsonl)
#   PAPERCUT_REVIEW_TTL_DAYS    prune threshold for individual sidecar
#                               entries, days (default 30 -- longer than
#                               PAPERCUT_ANCHOR_TTL_DAYS since this sidecar
#                               reconstructs a record's plaintext after a
#                               flush, not just bridges a crash)
#
# Fail-silent: any error anywhere must not disrupt SessionStart. No model
# call of its own -- capture invokes the extractor.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_file="${PAPERCUT_LOG:-$HOME/.claude/papercuts/capture.log}"
log_max_bytes="${PAPERCUT_LOG_MAX_BYTES:-1048576}"

log() {
  mkdir -p "$(dirname "$log_file")" 2>/dev/null
  touch "$log_file" 2>/dev/null
  chmod 600 "$log_file" 2>/dev/null

  if [ -f "$log_file" ]; then
    local size
    size=$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')
    if [ -n "$size" ] && [ "$size" -gt "$log_max_bytes" ] 2>/dev/null; then
      : >"$log_file"
    fi
  fi

  printf '%s [papercut-sweep] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$log_file"
}

input_json="$(cat 2>/dev/null)"
own_session_id=$(printf '%s' "$input_json" | jq -r '.session_id // empty' 2>/dev/null)
own_key=""
if [ -n "$own_session_id" ]; then
  own_key=$(printf '%s' "$own_session_id" | shasum -a 256 2>/dev/null | awk '{print $1}')
fi

anchors_dir="${PAPERCUT_ANCHORS_DIR:-$HOME/.claude/papercuts/anchors}"
processed_dir="${PAPERCUT_PROCESSED_DIR:-$HOME/.claude/papercuts/processed}"
projects_dir="${PAPERCUT_PROJECTS_DIR:-$HOME/.claude/projects}"
quiet_hours="${PAPERCUT_SWEEP_QUIET_HOURS:-24}"
ttl_days="${PAPERCUT_ANCHOR_TTL_DAYS:-7}"
max_sessions="${PAPERCUT_SWEEP_MAX_SESSIONS:-5}"
capture_cmd="${PAPERCUT_CAPTURE_CMD:-$script_dir/papercut-capture.sh}"
# Same default path papercut-capture.sh exports PAPERCUT_REVIEW_FILE to --
# must match so both scripts agree on where the sidecar lives.
review_file="${PAPERCUT_REVIEW_FILE:-$HOME/.claude/papercuts/scrub-review.jsonl}"
review_ttl_days="${PAPERCUT_REVIEW_TTL_DAYS:-30}"

# Sanitize the numeric overrides: a non-integer value would make the arithmetic
# below abort under `set -u` (bash treats the token as an unset variable name),
# breaking this hook's fail-silent contract. Fall back to the default instead.
[[ $quiet_hours =~ ^[0-9]+$ ]] || quiet_hours=24
[[ $ttl_days =~ ^[0-9]+$ ]] || ttl_days=7
[[ $max_sessions =~ ^[0-9]+$ ]] || max_sessions=5
[[ $review_ttl_days =~ ^[0-9]+$ ]] || review_ttl_days=30

# prune_review_sidecar rewrites the scrub-review sidecar in place, dropping
# entries older than PAPERCUT_REVIEW_TTL_DAYS (default 30 -- longer than the
# anchors TTL above, since the sidecar's whole point is reconstructing a
# record's plaintext runs after its transcript is long gone, not just
# bridging a crash). Unlike the anchors prune below, the sidecar is ONE file
# holding many sessions' entries, so pruning means filtering lines by their
# own `ts`, not deleting a whole per-session file. Runs unconditionally, not
# gated on anchors_dir existing, and BEFORE the early exit below.
#
# Locking: papercut_append.py's write_review_sidecar() (the gate) takes an
# exclusive fcntl.flock on "<review_file>.lock" across its own read-modify-
# write of this same file, and this function takes the SAME lock, across the
# SAME read-modify-write shape (read whole file, write a private *.tmp,
# os.replace() it over the target) -- otherwise a concurrent gate append (real:
# papercut-capture.sh runs with up to 2 concurrent capture slots) and this
# prune could interleave, and a torn write here isn't just cosmetic -- it's
# fed right back into this same JSON-line parser next run, silently dropping
# whatever came after the tear.
prune_review_sidecar() {
  local file="$1" ttl_days_arg="$2"
  [ -f "$file" ] || return 0
  python3 -c '
import fcntl, json, os, sys, time
from datetime import datetime, timezone

path, ttl_days = sys.argv[1], float(sys.argv[2])
cutoff = time.time() - ttl_days * 86400


def read_and_filter():
    kept = []
    pruned = 0
    # surrogateescape, not "ignore": the malformed-line branch below promises to
    # KEEP an unreadable entry, but "ignore" drops undecodable bytes at the
    # DECODER, before that branch ever runs -- so the mangled version is what
    # gets written back on the next rewrite, permanently. surrogateescape lets
    # the exact original bytes round-trip (paired with the same errors= setting
    # on the write side) so that promise is actually kept. The only writer emits
    # ASCII-only json.dumps output, so this defends external corruption rather
    # than our own path -- but this file is the ONLY copy of the runs it holds,
    # which makes "corruption defense that itself corrupts" the worst property
    # it could have.
    with open(path, "r", errors="surrogateescape") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            keep = True
            try:
                obj = json.loads(line)
                ts = obj.get("ts") if isinstance(obj, dict) else None
                dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                if dt.timestamp() < cutoff:
                    keep = False
            except Exception:
                # Malformed line: KEEP it rather than risk silently losing an
                # unreadable-but-possibly-recoverable review entry -- pruning
                # is about age, not about being a strict parser.
                pass
            if keep:
                kept.append(line)
            else:
                pruned += 1
    return kept, pruned


def write_atomically(kept):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        # errors= mirrors the surrogateescape in read_and_filter() so a
        # preserved malformed line round-trips byte-for-byte, not blow up here.
        # fsync before the rename: a rename can be journaled ahead of the data
        # blocks, so without this a power loss mid-prune leaves a truncated or
        # zero-length file installed AT THE REAL PATH. This writer rewrites the
        # whole file every time anything ages out, so it has a wider blast
        # radius than the gate writer, which only rewrites on a redaction.
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as out:
            for line in kept:
                out.write(line + "\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        # fsync the PARENT DIRECTORY too: the rename is a directory metadata
        # operation, so fsyncing tmp alone leaves the rename itself losable on
        # a power loss, reverting the sidecar to its pre-prune state. Same
        # reasoning as write_review_sidecar() in papercut_append.py.
        # Best-effort -- never fail a prune over an unopenable directory.
        try:
            dir_fd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


lock_fd = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        kept, pruned = read_and_filter()
    except Exception:
        print(0)
        sys.exit(0)
    if pruned == 0:
        print(0)
        sys.exit(0)
    try:
        write_atomically(kept)
        print(pruned)
    except Exception:
        print(0)
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
' "$file" "$ttl_days_arg" 2>/dev/null
}

review_pruned="$(prune_review_sidecar "$review_file" "$review_ttl_days")"
[[ $review_pruned =~ ^[0-9]+$ ]] || review_pruned=0
if [ "$review_pruned" -gt 0 ]; then
  log "prune reason=review-sidecar-ttl count=$review_pruned"
fi

[ -d "$anchors_dir" ] || exit 0

quiet_seconds=$((quiet_hours * 3600))
ttl_seconds=$((ttl_days * 86400))
now=$(date +%s)

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Reads the RAW session_id from the anchor file's own lines (never
# reconstructed from the sha256 filename). Tolerates a malformed or
# partially-written trailing line (the anchor writer can be mid-append).
read_raw_session_id() {
  python3 -c '
import json, sys

path = sys.argv[1]
try:
    with open(path, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            sid = obj.get("session_id") if isinstance(obj, dict) else None
            if isinstance(sid, str) and sid:
                print(sid)
                break
except Exception:
    pass
' "$1" 2>/dev/null
}

# Newest ~/.claude/projects/**/<raw session_id>.jsonl match, via os.walk (not
# shell globstar).
find_transcript() {
  python3 -c '
import os, sys

root, sid = sys.argv[1], sys.argv[2]
target = sid + ".jsonl"
best, best_mtime = None, -1
try:
    for dirpath, _dirnames, filenames in os.walk(root):
        if target in filenames:
            p = os.path.join(dirpath, target)
            try:
                m = os.path.getmtime(p)
            except OSError:
                continue
            if m > best_mtime:
                best_mtime, best = m, p
except Exception:
    pass
if best:
    print(best)
' "$1" "$2" 2>/dev/null
}

read_transcript_cwd() {
  python3 -c '
import json, sys

path = sys.argv[1]
try:
    with open(path, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            cwd = obj.get("cwd") if isinstance(obj, dict) else None
            if isinstance(cwd, str) and cwd:
                print(cwd)
                break
except Exception:
    pass
' "$1" 2>/dev/null
}

processed_count=0

shopt -s nullglob
anchor_files=("$anchors_dir"/*.jsonl)
shopt -u nullglob

# Guard the empty-array case: on bash 3.2 (macOS system bash) expanding
# "${anchor_files[@]}" of an empty array under `set -u` aborts with "unbound
# variable", which would break this hook's fail-silent contract whenever the
# anchors dir exists but is empty (the common steady state).
[ "${#anchor_files[@]}" -gt 0 ] || exit 0

for anchors_file in "${anchor_files[@]}"; do
  [ "$processed_count" -lt "$max_sessions" ] || break

  base="$(basename "$anchors_file" .jsonl)"

  # --- Self-skip: unconditional, before any other guard, and before it
  # counts against the per-run bound below (it isn't a session that needs
  # handling at all). ---
  if [ -n "$own_key" ] && [ "$base" = "$own_key" ]; then
    continue
  fi

  # Every OTHER anchors file counts against the per-run bound as soon as we
  # start examining it, whether or not it ends up skipped: counting only
  # acted-upon sessions would leave the bound toothless against a backlog of
  # live (quiet-window-skipped) sessions, which could still cost a python3 +
  # os.walk per file every SessionStart.
  processed_count=$((processed_count + 1))

  # --- Quiet-window guard FIRST: the cheapest half (anchors mtime alone),
  # before any transcript lookup -- the session may still be live/resumable.
  anchors_mtime="$(file_mtime "$anchors_file")"
  if [ -z "$anchors_mtime" ] || [ $((now - anchors_mtime)) -lt "$quiet_seconds" ]; then
    log "skip reason=quiet-window session=$base"
    continue
  fi

  raw_session_id="$(read_raw_session_id "$anchors_file")"
  if [ -z "$raw_session_id" ]; then
    log "skip reason=anchors-unreadable session=$base"
    continue
  fi

  transcript_path="$(find_transcript "$projects_dir" "$raw_session_id")"

  # --- Quiet-window guard, second half: the transcript too, once located. --
  if [ -n "$transcript_path" ]; then
    transcript_mtime="$(file_mtime "$transcript_path")"
    if [ -z "$transcript_mtime" ] || [ $((now - transcript_mtime)) -lt "$quiet_seconds" ]; then
      log "skip reason=quiet-window session=$base"
      continue
    fi
  fi

  session_key="$(printf '%s' "$raw_session_id" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  hash_file="$processed_dir/${session_key}.hash"

  if [ -f "$hash_file" ]; then
    rm -f "$anchors_file" "$anchors_file.lock" 2>/dev/null
    log "cleanup reason=already-processed session=$base"
    continue
  fi

  if [ -z "$transcript_path" ]; then
    anchors_age=$((now - anchors_mtime))
    if [ "$anchors_age" -ge "$ttl_seconds" ]; then
      rm -f "$anchors_file" "$anchors_file.lock" 2>/dev/null
      log "prune reason=transcript-gone-past-ttl session=$base"
    else
      log "skip reason=transcript-gone-within-ttl session=$base"
    fi
    continue
  fi

  cwd="$(read_transcript_cwd "$transcript_path")"
  synth_json=$(jq -n -c --arg sid "$raw_session_id" --arg tp "$transcript_path" --arg cwd "$cwd" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd}' 2>/dev/null)
  if [ -z "$synth_json" ]; then
    log "skip reason=synth-json-failed session=$base"
    continue
  fi

  log "sweep reason=driving-capture session=$base"
  # shellcheck disable=SC2086
  printf '%s' "$synth_json" | bash -c "$capture_cmd" >/dev/null 2>&1
done

exit 0
