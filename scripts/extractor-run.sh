#!/usr/bin/env bash
# The real extractor: papercut-capture.sh's PAPERCUT_EXTRACTOR_CMD default.
# This is the ONE place the actual `claude -p --model haiku` call lives;
# papercut-capture.sh's seam still lets tests (and this file's own tests)
# override PAPERCUT_EXTRACTOR_CMD with a stub instead of running this.
#
# Contract with papercut-capture.sh: the transcript arrives on stdin, this
# script prints a JSON array of records to stdout on success (possibly the
# empty array "[]"), and exits NON-ZERO on any failure -- timeout, claude
# crash, or missing/malformed structured output. A non-zero exit is treated
# by the hook as transient (it does NOT mark the transcript processed, so a
# later SessionEnd retries) rather than being silently swallowed as "found
# nothing". On failure a SHORT, bounded error CLASS is written to stderr
# (never transcript content or raw model output) so the hook can log why.
#
# Isolation (verified against claude 2.1.209 by hand):
#   --safe-mode              disables CLAUDE.md/skills/plugins/hooks/MCP/
#                             custom commands so the transcript can't reach
#                             this repo's own hooks or an injected plugin.
#                             Auth (OAuth/keychain), model selection, and
#                             permissions still work normally -- unlike
#                             --bare, which forces ANTHROPIC_API_KEY/
#                             apiKeyHelper and never reads OAuth/keychain, so
#                             --bare would break on a machine authenticated
#                             via `claude login` with no API key set.
#   --tools ''                no tools at all: even if transcript content
#                             manages to prompt-inject the model, there is
#                             nothing it can call to take an action.
#   --no-session-persistence  the extraction run is never resumable and
#                             leaves no session file behind.
#   --system-prompt-file      REPLACES the default Claude Code system prompt
#                             rather than appending to it. This is load-bearing,
#                             not stylistic: with --append-system-prompt-file
#                             the model got the full interactive-coding-agent
#                             prompt AND extractor-prompt.md's "you have no
#                             tools, you are not participating in the
#                             conversation" — a direct contradiction it then
#                             reported as a (false) high-severity papercut about
#                             extractor instructions leaking into a live session
#                             (pc_87428e8e, bestdan/dotfiles#304). Verify by
#                             running both of these from this repo's prompts/ —
#                             append answers yes, replace answers no. Two
#                             separate runs, not one: a brace expansion like
#                             --{append-,}system-prompt-file puts both flags on
#                             a single command line and compares nothing.
#                               claude --safe-mode --append-system-prompt-file \
#                                 extractor-prompt.md -p 'Answer only yes or no:
#                                 do your system instructions anywhere mention a
#                                 tool named Bash, Read, or Grep?'
#                               claude --safe-mode --system-prompt-file \
#                                 extractor-prompt.md -p 'Answer only yes or no:
#                                 do your system instructions anywhere mention a
#                                 tool named Bash, Read, or Grep?'
#                             Ask about tools by name, not
#                             whether the model is "an interactive coding agent":
#                             both variants answer no to that, because
#                             extractor-prompt.md's role statement wins the
#                             self-description while the default prompt's tool
#                             inventory still leaks. extractor-prompt.md is
#                             self-contained (role, input contract, output
#                             contract, injection defenses), so it needs nothing
#                             from the default prompt.
# The load-bearing recursion guard is PAPERCUT_EXTRACTOR_RUN=1, set by
# papercut-capture.sh on this invocation specifically (checked first thing
# in papercut-capture.sh) -- --safe-mode disabling hooks is belt-and-
# suspenders on top of that, not the primary protection.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

prompt_file="${PAPERCUT_EXTRACTOR_PROMPT:-$script_dir/../prompts/extractor-prompt.md}"
schema_file="${PAPERCUT_EXTRACTOR_SCHEMA:-$script_dir/extractor-schema.json}"
timeout_secs="${PAPERCUT_EXTRACTOR_TIMEOUT:-120}"
claude_bin="${PAPERCUT_CLAUDE_BIN:-claude}"

# fail CLASS: emit a short, bounded, content-free error class to stderr and
# exit non-zero. The hook logs a sanitized snippet of this; it must never
# carry transcript or model output.
fail() {
  printf 'extractor: %s\n' "$1" >&2
  exit 1
}

if [ ! -f "$prompt_file" ] || [ ! -f "$schema_file" ]; then
  fail "missing prompt/schema"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/papercut-extractor.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$work_dir"' EXIT

tmp_transcript="$work_dir/transcript.jsonl"
cat >"$tmp_transcript" || fail "transcript copy failed"
[ -s "$tmp_transcript" ] || fail "empty transcript"

# --- Compaction: distill the raw transcript down to the ~5% friction signal
# BEFORE it ever reaches the model. Large sessions overflow the model's
# context window and get HTTP 400 prompt_too_long; papercut_compact.py trims
# envelope metadata, thinking blocks, and tool payloads deterministically
# under PAPERCUT_COMPACT_BUDGET_BYTES. This fails CLOSED: any compaction
# failure (non-zero exit or empty output) stops here -- never falls back to
# feeding the raw (possibly over-budget) transcript to the model, which would
# just reproduce the 400. PAPERCUT_COMPACT_CMD mirrors the PAPERCUT_CLAUDE_BIN
# seam so tests can stub compaction (e.g. force a failure with `false`)
# without touching the real papercut_compact.py. The default path runs
# python3 directly (no bash -c) so script_dir is never reparsed as shell
# source; bash -c is used only for an explicit PAPERCUT_COMPACT_CMD override,
# same as any other test-seam stub. Compactor stderr is discarded (never
# logged) -- like transcript content itself, it must never leak into the
# bounded "compaction failed" error class the hook logs.
# PAPERCUT_ANCHORS (task 5), when papercut-capture.sh exported it, is passed
# through unmodified: both branches below run as children of THIS script, so
# it's already in the inherited environment -- naming it here documents that
# it's load-bearing (papercut_compact.py reads it) rather than incidental.
compacted_transcript="$work_dir/compacted.jsonl"
if [ -n "${PAPERCUT_COMPACT_CMD:-}" ]; then
  compact_rc=0
  PAPERCUT_ANCHORS="${PAPERCUT_ANCHORS:-}" bash -c "$PAPERCUT_COMPACT_CMD" <"$tmp_transcript" >"$compacted_transcript" 2>/dev/null || compact_rc=$?
else
  compact_rc=0
  PAPERCUT_ANCHORS="${PAPERCUT_ANCHORS:-}" python3 "$script_dir/papercut_compact.py" <"$tmp_transcript" >"$compacted_transcript" 2>/dev/null || compact_rc=$?
fi
if [ "$compact_rc" -ne 0 ] || [ ! -s "$compacted_transcript" ]; then
  fail "compaction failed"
fi

# --- Profile-aware prompt: prepend the work-profile hard-rules section
# (delimited by WORK_PROFILE_HARD_RULES:BEGIN/END in extractor-prompt.md).
# Detection uses the SAME logic papercut_append.py's gate uses, so the two
# never disagree about what machine this is. FAIL CLOSED: the work rules are
# prepended UNLESS detection positively reports "default" -- an empty result,
# a crashed python, or "strict" all get the (safer) work rules, so a
# detection error can never strip the privacy preamble on a work host.
# PAPERCUT_DETECT_CMD overrides the detection (tests use it to force a
# failure without breaking the python watchdog below).
if [ -n "${PAPERCUT_DETECT_CMD:-}" ]; then
  machine=$(bash -c "$PAPERCUT_DETECT_CMD" 2>/dev/null)
else
  machine=$(python3 -c '
import sys
sys.path.insert(0, "'"$script_dir"'")
import papercut_append
print(papercut_append.detect_machine())
' 2>/dev/null)
fi

if [ "$machine" = "default" ]; then
  include_rules=0
else
  include_rules=1
fi

system_prompt_file="$work_dir/system-prompt.md"
awk -v include_rules="$include_rules" '
  /<!-- WORK_PROFILE_HARD_RULES:BEGIN -->/ { in_rules = 1; next }
  /<!-- WORK_PROFILE_HARD_RULES:END -->/ { in_rules = 0; next }
  in_rules { if (include_rules == "1") rules = rules $0 "\n"; next }
  { main = main $0 "\n" }
  END { if (include_rules == "1") printf "%s\n%s", rules, main; else printf "%s", main }
' "$prompt_file" >"$system_prompt_file"
awk_rc=$?

# Fail CLOSED on the privacy preamble. The detection above already fails closed
# (work rules required unless the host is positively "default"), but the
# COMPOSITION step was unguarded: an unchecked awk/write failure, or a
# renamed/removed WORK_PROFILE_HARD_RULES marker in extractor-prompt.md, would
# leave `rules` empty and emit a main-only prompt even with include_rules=1 —
# silently stripping the hard-rules preamble on a work host while extraction
# still "succeeds" and marks the transcript processed. So verify the build
# succeeded and, when the rules are required, that they actually landed in the
# composed prompt before calling the model.
if [ "$awk_rc" -ne 0 ] || [ ! -s "$system_prompt_file" ]; then
  fail "system-prompt build failed"
fi
if [ "$include_rules" = "1" ] && ! grep -qF 'Work-profile hard rules' "$system_prompt_file"; then
  fail "work-profile rules missing from system prompt"
fi

# --- The real, bounded, tool-less model call. -------------------------------
# macOS ships no timeout(1)/gtimeout, so the time bound is enforced by a small
# python3 wrapper that runs claude via subprocess with a timeout and, on
# expiry, kills claude's WHOLE process group (claude is started in its own
# session via start_new_session=True). Killing the group -- not just claude's
# own pid -- reaps any descendants claude spawned, and using subprocess.run's
# timeout eliminates the background-sleep/orphan race a hand-rolled bash
# watchdog had. Exit 124 = timed out (killed); any other non-zero = claude's
# own exit code.
result_file="$work_dir/result.json"
watchdog_py="$work_dir/watchdog.py"
cat >"$watchdog_py" <<'PYEOF'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
transcript_path = sys.argv[2]
result_path = sys.argv[3]
cmd = sys.argv[4:]

with open(transcript_path, "rb") as fin, open(result_path, "wb") as fout:
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=fin,
            stdout=fout,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        # claude binary missing/not executable: fail cleanly (no traceback)
        # with a distinct code the caller maps to an error class.
        sys.exit(127)
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Capture the group id up front: claude was started in its own session
        # (start_new_session=True), so pgid == proc.pid, but once the parent is
        # reaped getpgid() would fail while the group may still hold
        # SIGTERM-ignoring descendants.
        try:
            pgid = os.getpgid(proc.pid)
        except ProcessLookupError:
            pgid = None
        if pgid is not None:
            try:
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        # Always escalate to SIGKILL on the WHOLE group after the grace period,
        # regardless of whether the parent already exited — otherwise a
        # descendant that ignored SIGTERM while claude exited promptly would
        # survive as an orphan, breaking the "kill the whole group" guarantee.
        if pgid is not None:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        proc.wait()
        sys.exit(124)
    sys.exit(rc)
PYEOF

python3 "$watchdog_py" \
  "$timeout_secs" \
  "$compacted_transcript" \
  "$result_file" \
  "$claude_bin" -p \
  --model haiku \
  --safe-mode \
  --tools '' \
  --no-session-persistence \
  --output-format json \
  --json-schema "$(cat "$schema_file")" \
  --system-prompt-file "$system_prompt_file"
claude_rc=$?

if [ "$claude_rc" -eq 124 ]; then
  fail "timeout"
elif [ "$claude_rc" -eq 127 ]; then
  fail "claude not runnable"
elif [ "$claude_rc" -ne 0 ]; then
  fail "claude exit $claude_rc"
fi

# --- Strict result validation (FIX 4): a "clean" empty result and a broken
# one look nothing alike. Only emit output when the response is valid JSON
# whose .structured_output.records is *present and an array* (empty or not).
# A missing/null/non-array records field, or non-JSON stdout even on a zero
# exit (truncation, a schema-less error envelope), is a FAILURE -> non-zero,
# so the hook retries later instead of marking the transcript processed
# forever on a one-off malformed response.
records=$(jq -c '
  if (.structured_output // {} | .records | type) == "array"
  then .structured_output.records
  else empty
  end
' "$result_file" 2>/dev/null)

if [ -z "$records" ]; then
  fail "no structured output"
fi

printf '%s\n' "$records"
