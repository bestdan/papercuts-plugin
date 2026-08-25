#!/usr/bin/env bash
# SessionEnd hook: captures "papercut" records from a session transcript by
# handing it to an extractor (stubbed here; papercuts_task_3__extractor swaps
# in the real model call) and piping the result through the trusted gate
# (papercut_append.py). This slice owns everything AROUND the model call:
# recursion safety, idempotency, a triviality pre-filter, an atomic
# concurrency cap, a safe temp copy of the transcript, and metadata-only
# logging. It never writes transcript content or raw extractor output to
# disk outside the transcript's own temp copy.
#
# Env overrides (all state paths are overridable so tests never touch real
# ~/.claude):
#   PAPERCUT_EXTRACTOR_RUN     recursion guard. Set by the (future) extractor
#                              invocation before it spawns a nested `claude`,
#                              whose own SessionEnd would otherwise fork-loop
#                              back into this script. MUST be checked first.
#   PAPERCUT_PROCESSED_DIR     idempotency hash dir
#                              (default ~/.claude/papercuts/processed)
#   PAPERCUT_MIN_TURNS         triviality threshold on human turns (default 6)
#   PAPERCUT_CAPTURE_LOCKDIR   dir holding the 2 concurrency-cap lock files
#                              (default ~/.claude/papercuts/locks)
#   PAPERCUT_LOG               metadata log path
#                              (default ~/.claude/papercuts/capture.log)
#   PAPERCUT_LOG_MAX_BYTES     size cap; the log is TRUNCATED in place past this
#                              size (not rotated to .1) (default 1048576)
#   PAPERCUT_EXTRACTOR_CMD     the extractor seam (see below). Default runs
#                              extractor-run.sh, which shells out to `claude
#                              -p --model haiku ...` (tool-less, safe-mode,
#                              watchdog-bounded). Tests override this with
#                              their own stub so no real `claude` ever runs.
#   PAPERCUT_APPEND_CMD        the gate command (default: `python3
#                              <this dir>/papercut_append.py`)
#   PAPERCUT_ANCHORS_DIR       anchors jsonl dir, SAME dir as
#                              papercut-anchor.sh (default
#                              ~/.claude/papercuts/anchors). On the success
#                              path, this session's anchors sidecar is deleted
#                              once the processed marker is confirmed written.
#   PAPERCUT_REVIEW_FILE       scrub-review sidecar path (default
#                              ~/.claude/papercuts/scrub-review.jsonl). Unlike
#                              the gate's other overrides below, this one is
#                              EXPORTED here (not merely inherited) so the auto
#                              path always gets a sidecar: the gate's advisory
#                              for a vocab-shaped redaction normally goes to
#                              stderr, which step 6 below discards, so without
#                              this a false-positive scrub on an auto-captured
#                              record is unrecoverable. See
#                              papercut_append.py's own doc comment for what
#                              gets written.
#
# papercut_append.py's own overrides (PAPERCUT_SPOOL, PAPERCUT_LOCK,
# PAPERCUT_SCHEMA, PAPERCUT_DENYLIST) are simply inherited from this script's
# environment. (The gate derives its profile from the real hostname; there is
# no env override for it.)

set -uo pipefail

# --- 1. Recursion guard: FIRST, before anything else touches disk. ---------
if [ -n "${PAPERCUT_EXTRACTOR_RUN:-}" ]; then
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_file="${PAPERCUT_LOG:-$HOME/.claude/papercuts/capture.log}"
log_max_bytes="${PAPERCUT_LOG_MAX_BYTES:-1048576}"

# log() writes ONE bounded metadata line: timestamp, decision, counts, error
# classes. NEVER transcript content or raw extractor/model output — that
# would be a second, unscrubbed retention path.
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

  printf '%s [papercut-capture] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$log_file"
}

# --- 2. Parse stdin JSON. ----------------------------------------------------
input_json="$(cat)"

transcript_path=$(printf '%s' "$input_json" | jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input_json" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input_json" | jq -r '.cwd // empty' 2>/dev/null)

if [ -z "$transcript_path" ] || [ -z "$session_id" ]; then
  log "skip reason=bad-hook-input (missing transcript_path or session_id)"
  exit 0
fi

# session_safe is used EVERYWHERE this script logs or builds a pathname from
# the session id: session_id comes from hook stdin (untrusted-ish), and
# logging it verbatim would let an embedded newline forge extra log lines,
# while using it as-is in a filename would allow path traversal (e.g.
# "../evil"). The raw $session_id is only ever passed to the gate via
# --session-id, which JSON-escapes it.
# session_safe is a readable, injection-proof form for LOG lines only. Pathnames
# (marker + lock) instead use session_key — a full SHA-256 of the raw id — so
# two distinct session ids can never collide onto one marker/lock (sanitizing
# is not injective: "a/b" and "a?b" both sanitize to "a_b", and a >64-char id
# would be truncated), which would otherwise make one session's success wrongly
# skip another.
session_safe=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)
session_key=$(printf '%s' "$session_id" | shasum -a 256 2>/dev/null | awk '{print $1}')

if [ ! -f "$transcript_path" ]; then
  log "skip reason=transcript-missing session=$session_safe"
  exit 0
fi

# --- 3. Idempotency: content-hash the transcript. ---------------------------
processed_dir="${PAPERCUT_PROCESSED_DIR:-$HOME/.claude/papercuts/processed}"
mkdir -p "$processed_dir" 2>/dev/null
hash_file="$processed_dir/${session_key}.hash"

# write_marker persists the idempotency hash and returns success/failure so
# callers can gate follow-on cleanup (e.g. deleting the anchors sidecar) on
# an ACTUAL write, not merely on having reached this point. A failed write
# must be logged rather than silently swallowed: silently continuing past a
# write failure would leave no record that this transcript was handled, so
# the next SessionEnd fire on the same bytes would re-run the extractor and
# could double-emit the same papercut.
write_marker() {
  if printf '%s' "$current_hash" >"$hash_file" 2>/dev/null; then
    return 0
  fi
  log "marker-write-failed session=$session_safe"
  return 1
}

# --- 3a. Per-session lock: prevents two concurrent SessionEnd fires for the
# SAME session from both seeing no hash and both emitting. Fixed fd 7 (bash
# 3.2 on macOS has no `exec {fd}>` dynamic allocation), separate from the two
# capacity-slot fds (8, 9) below. Acquired BEFORE the idempotency check and
# held through the marker write, and BEFORE the capacity slots are taken so a
# session that's already busy doesn't consume a global slot.
session_lock_file="$processed_dir/${session_key}.lock"
exec 7>"$session_lock_file" 2>/dev/null
if ! python3 -c '
import fcntl, sys
try:
    fcntl.flock(7, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
' 2>/dev/null; then
  log "skip reason=session-lock-busy session=$session_safe"
  exit 0
fi

# --- 3b. Copy the transcript to a private temp file BEFORE hashing, and
# always clean it up. Hashing (and every later read) is done against this
# immutable copy so a concurrent write to the live transcript between "hash
# it" and "read it" can't record the wrong hash for what was actually
# processed (a TOCTOU that would otherwise re-emit the new content next run).
tmp_transcript=$(mktemp "${TMPDIR:-/tmp}/papercut-capture.XXXXXX") || {
  log "skip reason=tmpfile-failed session=$session_safe"
  exit 0
}
chmod 600 "$tmp_transcript" 2>/dev/null
# The two stderr sidecars ($tmp_transcript.err for the extractor,
# $tmp_transcript.append.err for the gate) are derived paths, not mktemp
# results, so they are NOT covered by tmp_transcript's own cleanup and are
# created by shell redirection at whatever the ambient umask allows. Both
# carry tool stderr, so both get the same 0600-and-remove treatment as the
# transcript copy: pre-create them here to own the mode before anything
# writes, and trap all three so an abnormal exit can't strand one on disk.
: >"$tmp_transcript.err" 2>/dev/null
: >"$tmp_transcript.append.err" 2>/dev/null
chmod 600 "$tmp_transcript.err" "$tmp_transcript.append.err" 2>/dev/null
trap 'rm -f "$tmp_transcript" "$tmp_transcript.err" "$tmp_transcript.append.err"' EXIT

if ! cp "$transcript_path" "$tmp_transcript" 2>/dev/null; then
  log "skip reason=transcript-copy-failed session=$session_safe"
  exit 0
fi

current_hash=$(shasum -a 256 "$tmp_transcript" 2>/dev/null | awk '{print $1}')
if [ -z "$current_hash" ]; then
  log "skip reason=hash-failed session=$session_safe"
  exit 0
fi

if [ -f "$hash_file" ]; then
  prev_hash=$(cat "$hash_file" 2>/dev/null)
  if [ -n "$prev_hash" ] && [ "$prev_hash" = "$current_hash" ]; then
    log "skip reason=unchanged-transcript session=$session_safe"
    exit 0
  fi
fi

# --- 4. Triviality pre-filter: PARSE with jq, never grep. -------------------
# A "human turn" is a type=="user" entry that is NOT isMeta==true and whose
# message content is EITHER a plain string OR an array containing at least
# one {"type":"text"} block. Genuine user prompts can arrive as either shape;
# tool-result arrays contain tool_result blocks (never text blocks), so
# they're still excluded, and isMeta:true injected context (which can itself
# be a bare string) is explicitly excluded rather than relying on shape alone.
min_turns="${PAPERCUT_MIN_TURNS:-6}"

counts=$(jq -c -s '{
  human_turns: ([.[]
    | select(.type == "user" and (.isMeta // false) != true)
    | .message.content
    | select(
        (type == "string")
        or (type == "array" and (any(.[]; .type == "text")))
      )
  ] | length),
  tool_errors: ([.[]
    | select(.type == "user")
    | (.message.content // []) as $c
    | (if ($c | type) == "array" then $c else [] end)[]
    | select(.type == "tool_result" and .is_error == true)
  ] | length),
  denials: ([.[] | select(.toolDenialKind != null)] | length)
}' "$tmp_transcript" 2>/dev/null)

if [ -z "$counts" ]; then
  log "skip reason=transcript-parse-failed session=$session_safe"
  exit 0
fi

human_turns=$(printf '%s' "$counts" | jq -r '.human_turns')
tool_errors=$(printf '%s' "$counts" | jq -r '.tool_errors')
denials=$(printf '%s' "$counts" | jq -r '.denials')

is_nontrivial=0
if [ "${human_turns:-0}" -ge "$min_turns" ] 2>/dev/null || [ "${tool_errors:-0}" -gt 0 ] 2>/dev/null || [ "${denials:-0}" -gt 0 ] 2>/dev/null; then
  is_nontrivial=1
fi

if [ "$is_nontrivial" -eq 0 ]; then
  log "skip reason=trivial session=$session_safe human_turns=$human_turns tool_errors=$tool_errors denials=$denials min_turns=$min_turns"
  # Nothing changed about this transcript's decision-worthy content; record
  # the hash so a repeat SessionEnd fire (e.g. a second /clear) on the exact
  # same bytes doesn't redo this work.
  write_marker
  exit 0
fi
log "accept reason=non-trivial session=$session_safe human_turns=$human_turns tool_errors=$tool_errors denials=$denials min_turns=$min_turns"

# --- 5. Atomic concurrency cap: 2 flock slots, non-blocking. ----------------
# macOS ships no `flock(1)` (util-linux) and this repo's mise.toml doesn't
# vend one either, so the slot lock uses python3's fcntl.flock(LOCK_NB) on a
# file descriptor opened by THIS shell. Bash keeps that fd open for the rest
# of the process (bash on macOS is 3.2, which lacks `exec {fd}>file` dynamic
# allocation, hence the two fixed fd numbers below), so the underlying open
# file description — and therefore the lock — is held for the whole hook
# invocation and is released automatically when the process exits. This is
# the same acquire-or-fail atomicity flock(1) would give, just invoked via
# libc through python instead of a missing binary.
lockdir="${PAPERCUT_CAPTURE_LOCKDIR:-$HOME/.claude/papercuts/locks}"
mkdir -p "$lockdir" 2>/dev/null

slot=""

exec 8>"$lockdir/capture-slot-1.lock" 2>/dev/null
if python3 -c '
import fcntl, sys
try:
    fcntl.flock(8, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
' 2>/dev/null; then
  slot=1
else
  exec 8>&- 2>/dev/null

  exec 9>"$lockdir/capture-slot-2.lock" 2>/dev/null
  if python3 -c '
import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
' 2>/dev/null; then
    slot=2
  else
    exec 9>&- 2>/dev/null
  fi
fi

if [ -z "$slot" ]; then
  log "skip reason=capture-slots-busy session=$session_safe"
  exit 0
fi

# --- 6. Invoke the extractor through a single seam, then the gate. ---------
# The transcript was already copied to $tmp_transcript in step 3b, before it
# was hashed, so the extractor reads exactly the bytes that were hashed.
extractor_cmd="${PAPERCUT_EXTRACTOR_CMD:-$script_dir/extractor-run.sh}"
append_cmd="${PAPERCUT_APPEND_CMD:-python3 $script_dir/papercut_append.py}"
repo_name=$(basename "${cwd:-unknown}")

# Scrub-review sidecar (see the env-override doc comment above): exported
# unconditionally, on every invocation, unlike PAPERCUT_ANCHORS above (which
# is conditional on a per-session anchors file existing). There's no such
# per-invocation condition here -- the gate itself decides whether anything
# gets written, based on whether the scrub actually produced a vocab-shaped
# redaction.
review_file="${PAPERCUT_REVIEW_FILE:-$HOME/.claude/papercuts/scrub-review.jsonl}"
export PAPERCUT_REVIEW_FILE="$review_file"
review_lines_before=0
if [ -f "$review_file" ]; then
  review_lines_before=$(wc -l <"$review_file" 2>/dev/null | tr -d ' ')
fi

# PAPERCUT_EXTRACTOR_RUN=1 is the recursion guard (see step 1): the real
# extractor shells out to `claude -p ...`, whose own SessionEnd hook would
# otherwise fire this same script again. Setting it here, on the extractor
# invocation specifically, is what makes that nested fire a no-op.
# The extractor's stderr is captured (not discarded) so a bounded, sanitized
# error CLASS (e.g. "extractor: timeout", "extractor: claude exit N") can be
# logged as metadata explaining a failure. It is aggressively scrubbed before
# it reaches the log: bounded to 200 bytes and reduced to a safe char set, so
# even if the extractor were tricked into writing something unexpected it can
# neither forge a log line (newlines stripped) nor bloat the log.
# --- 6a. Anchor-informed compaction (task 5): if task 3's anchor recorder
# left a sidecar file for this session, point the extractor's compaction
# stage at it so anchored friction (tool errors, permission prompts) is
# force-kept even if budget trimming would otherwise elide it. Only exported
# when the file exists -- an unset PAPERCUT_ANCHORS is exactly task 1's
# no-anchors behavior, so a session with no anchors never changes compaction.
anchors_dir="${PAPERCUT_ANCHORS_DIR:-$HOME/.claude/papercuts/anchors}"
anchors_file="$anchors_dir/${session_key}.jsonl"
if [ -f "$anchors_file" ]; then
  export PAPERCUT_ANCHORS="$anchors_file"
else
  # Explicitly clear rather than merely not setting: this hook's own process
  # (and thus the extractor it execs) could otherwise inherit a PAPERCUT_ANCHORS
  # already exported by a caller/prior session, wrongly applying a stale or
  # unrelated session's anchors to this one.
  unset PAPERCUT_ANCHORS
fi

extractor_err_file="$tmp_transcript.err"
extractor_output=$(PAPERCUT_EXTRACTOR_RUN=1 bash -c "$extractor_cmd" <"$tmp_transcript" 2>"$extractor_err_file")
extractor_rc=$?
extractor_err=$(head -c 200 "$extractor_err_file" 2>/dev/null | tr -c 'A-Za-z0-9 :._/-' '_' | tr -s '_')
rm -f "$extractor_err_file" 2>/dev/null

if [ "$extractor_rc" -ne 0 ]; then
  # A non-zero extractor exit is TRANSIENT (crash, timeout, transient model
  # error). Do NOT write the processed marker — otherwise the transcript hash
  # is recorded and every retry skips as unchanged, so the papercut is never
  # emitted. Leaving the marker unwritten lets the next SessionEnd re-run it.
  log "skip reason=extractor-failed session=$session_safe rc=$extractor_rc err=$extractor_err"
  exit 0
fi

# append_err_file captures the gate's stderr instead of discarding it
# outright: normally nothing but the sidecar's SCRUB_REVIEW_WRITE_FAILED
# marker (see papercut_append.py) lands there on the auto path, but a
# discarded stderr would bury that marker exactly like it buries everything
# else on this path.
append_err_file="$tmp_transcript.append.err"

# shellcheck disable=SC2086
if printf '%s' "$extractor_output" | $append_cmd \
  --source auto \
  --producer capture-hook/1 \
  --session-id "$session_id" \
  --repo "$repo_name" >/dev/null 2>"$append_err_file"; then
  # Success (records appended, or an empty extractor array = "nothing found").
  # Only here do we mark the transcript processed so an identical re-fire skips.
  log "accept reason=appended session=$session_safe"

  # Scrub-review sidecar write failure: the gate never fails the append over
  # this (the record already landed in the spool), so the only trace is its
  # bounded stderr marker. Pull just the error-class token out of it and
  # sanitize with the same technique as the extractor error class above
  # (bounded length, safe charset, repeats squeezed) before it ever reaches
  # log() -- log()'s own invariant is metadata only, never anything that
  # traces back toward the scrubbed runs.
  scrub_write_failed_class=$(grep -o 'SCRUB_REVIEW_WRITE_FAILED error_class=[^[:space:]]*' "$append_err_file" 2>/dev/null |
    head -1 | sed 's/.*error_class=//' | head -c 200 | tr -c 'A-Za-z0-9_' '_' | tr -s '_')
  rm -f "$append_err_file" 2>/dev/null
  if [ -n "$scrub_write_failed_class" ]; then
    log "scrub-review-write-failed error_class=$scrub_write_failed_class"
  fi

  # Scrub-review sidecar: log ONLY a count of new entries the gate just wrote
  # (never the plaintext runs themselves, per the invariant above) -- a
  # pointer telling us to go look at the sidecar, not a substitute for it.
  review_lines_after=0
  if [ -f "$review_file" ]; then
    review_lines_after=$(wc -l <"$review_file" 2>/dev/null | tr -d ' ')
  fi
  if [[ $review_lines_before =~ ^[0-9]+$ ]] && [[ $review_lines_after =~ ^[0-9]+$ ]]; then
    review_new=$((review_lines_after - review_lines_before))
    if [ "$review_new" -gt 0 ]; then
      log "scrub-review runs=$review_new"
    fi
  fi

  if write_marker; then
    # Delete the anchors sidecar ONLY after the marker write actually
    # succeeded: deleting it after a failed marker write would destroy the
    # only evidence that this session still needs processing (the next
    # SessionEnd fire would re-extract, but with no anchors to help it).
    rm -f "$anchors_dir/${session_key}.jsonl" "$anchors_dir/${session_key}.jsonl.lock" 2>/dev/null
  fi
else
  # Gate rejection can be transient too (e.g. flaky model output that a retry
  # would fix), so do NOT mark — a later fire on the same bytes retries.
  rm -f "$append_err_file" 2>/dev/null
  log "skip reason=gate-rejected session=$session_safe"
fi
exit 0
