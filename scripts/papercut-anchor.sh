#!/usr/bin/env bash
# PostToolUseFailure/Notification hook: records acute friction (tool errors,
# permission prompts) the instant it happens, so it survives even if
# compaction's budget trimming would drop it and even if SessionEnd never
# fires. This is a recorder ONLY — no model call, no extraction; task 5
# consumes these anchors alongside the transcript.
#
# Anchor shape is content-light and structural ONLY:
#   {v, session_id, kind:"tool_error"|"permission_prompt", tool_name,
#    tool_use_id, error_class(enum), exit_code?, ts?}
# error_class is a small normalized ENUM (nonzero_exit|timeout|not_found|
# interrupted|denied|unknown) — never a scrubbed excerpt. tool_input,
# tool_output, file paths, and transcript content are NEVER copied in.
#
# Fail-silent: any error anywhere in this script must exit 0 without
# disrupting the session (best-effort recorder, non-blocking async hook).
#
# Env overrides:
#   PAPERCUT_ANCHORS_DIR   anchor jsonl dir (default ~/.claude/papercuts/anchors)
#   PAPERCUT_ANCHOR_CAP    max anchor lines per session file (default 50)

set -uo pipefail

input_json="$(cat 2>/dev/null)"

# ${HOME:-} avoids a set -u "unbound variable" abort when PAPERCUT_ANCHORS_DIR
# is unset AND HOME is unset (default expansion never evaluates $HOME once
# PAPERCUT_ANCHORS_DIR is set, so this only matters on the fallback path).
if [ -z "${PAPERCUT_ANCHORS_DIR:-}" ] && [ -z "${HOME:-}" ]; then
  exit 0
fi
anchors_dir="${PAPERCUT_ANCHORS_DIR:-$HOME/.claude/papercuts/anchors}"
anchor_cap="${PAPERCUT_ANCHOR_CAP:-50}"

mkdir -p "$anchors_dir" 2>/dev/null
chmod 700 "$anchors_dir" 2>/dev/null

# shellcheck disable=SC2016
py_code='
import fcntl
import hashlib
import json
import os
import re
import sys

ENUM = {"nonzero_exit", "timeout", "not_found", "interrupted", "denied", "unknown"}


def get(d, *path):
    for key in path:
        if not isinstance(d, dict):
            return None
        d = d.get(key)
    return d


def truthy(v):
    return v is True


def as_text(v):
    return v.lower() if isinstance(v, str) else ""


def classify_error(p):
    flags = {
        "timeout": [get(p, "timeout"), get(p, "timed_out"), get(p, "error", "timeout")],
        "interrupted": [
            get(p, "interrupted"),
            get(p, "is_interrupt"),
            get(p, "cancelled"),
            get(p, "error", "interrupted"),
        ],
        "denied": [get(p, "denied"), get(p, "permission_denied"), get(p, "error", "denied")],
    }
    for cls in ("timeout", "interrupted", "denied"):
        if any(truthy(v) for v in flags[cls]):
            return cls

    code = get(p, "exit_code")
    if code is None:
        code = get(p, "error", "exit_code")
    if isinstance(code, int) and not isinstance(code, bool) and code != 0:
        return "nonzero_exit"

    # A top-level string `error` field (older/alternate payload shapes carry
    # the message directly rather than nested under error.type/error.code) is
    # classified the same tolerant, enum-only way as the other text fields —
    # never stored verbatim, only matched against fixed keywords.
    texts = " ".join(
        as_text(v)
        for v in (
            get(p, "error_type"),
            get(p, "error", "type"),
            get(p, "error", "code"),
            get(p, "error_message"),
            get(p, "error") if isinstance(get(p, "error"), str) else None,
        )
    )[:1000]
    if "enoent" in texts or "command not found" in texts or "not_found" in texts:
        return "not_found"
    if "timeout" in texts or "timed out" in texts:
        return "timeout"
    if "interrupt" in texts or "cancel" in texts:
        return "interrupted"
    if "denied" in texts or "permission" in texts:
        return "denied"

    # The installed CLI sends the top-level error field for PostToolUseFailure
    # as a plain string (Exit code 1, then a message) rather than the
    # documented {type, exit_code, stderr} object, so the structured
    # exit_code checks above never fire for it. Parse the exit-code phrase
    # out of the same lowercased text instead of adding a new field.
    match = re.search(r"exit\s+(?:code|status)\s*:?\s*(\d+)", texts)
    if match and int(match.group(1)) != 0:
        return "nonzero_exit"
    return "unknown"


def str_or_none(v):
    return v if isinstance(v, str) else None


def main():
    anchors_dir = sys.argv[1]
    anchor_cap = int(sys.argv[2])

    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(payload, dict):
        return

    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return

    event = payload.get("hook_event_name")
    anchor = None

    if event == "PostToolUseFailure":
        anchor = {
            "kind": "tool_error",
            "tool_name": str_or_none(payload.get("tool_name")),
            "tool_use_id": str_or_none(payload.get("tool_use_id")),
            "error_class": classify_error(payload),
        }
    elif event == "PostToolUse":
        tool_response = payload.get("tool_response")
        is_error = payload.get("tool_output_type") == "error" or (
            isinstance(tool_response, dict) and tool_response.get("is_error") is True
        )
        if is_error:
            anchor = {
                "kind": "tool_error",
                "tool_name": str_or_none(payload.get("tool_name")),
                "tool_use_id": str_or_none(payload.get("tool_use_id")),
                "error_class": classify_error(payload),
            }
    elif event == "Notification":
        if payload.get("notification_type") == "permission_prompt":
            anchor = {
                "kind": "permission_prompt",
                "tool_name": str_or_none(payload.get("tool_name")),
                "tool_use_id": str_or_none(payload.get("tool_use_id")),
            }

    if anchor is None:
        return

    if "error_class" in anchor and anchor["error_class"] not in ENUM:
        anchor["error_class"] = "unknown"

    record = {"v": 1, "session_id": session_id}
    record.update(anchor)

    exit_code = payload.get("exit_code")
    if exit_code is None:
        exit_code = get(payload, "error", "exit_code")
    if isinstance(exit_code, int) and not isinstance(exit_code, bool):
        record["exit_code"] = exit_code

    ts = payload.get("ts")
    if ts is None:
        ts = payload.get("timestamp")
    if isinstance(ts, (str, int, float)) and not isinstance(ts, bool):
        record["ts"] = ts

    session_key = hashlib.sha256(session_id.encode("utf-8", "surrogateescape")).hexdigest()
    anchor_path = os.path.join(anchors_dir, session_key + ".jsonl")

    lock_fd = os.open(anchor_path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)

        existing = b""
        line_count = 0
        if os.path.exists(anchor_path):
            with open(anchor_path, "rb") as f:
                existing = f.read()
            line_count = existing.count(b"\n")

        if line_count >= anchor_cap:
            return

        # Write the whole file (existing lines + the new one) to a private
        # temp file and rename it over the anchor path, rather than
        # appending in place: a crash mid os.write to an append-mode fd can
        # leave a truncated/partial JSON line on disk, and os.rename is
        # atomic on the same filesystem, so a reader never observes a
        # half-written line.
        new_line = (json.dumps(record, sort_keys=True) + "\n").encode("utf-8")
        tmp_path = anchor_path + ".tmp"
        tmp_fd = os.open(tmp_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        try:
            os.fchmod(tmp_fd, 0o600)
            # Buffered write rather than a raw os.write(): os.write() may write
            # fewer bytes than given and report that count instead of raising,
            # so on ENOSPC the tail is silently dropped and the os.replace()
            # below installs a truncated anchors file. BufferedWriter.write()
            # loops to completion or raises. Same fix as write_review_sidecar()
            # in papercut_append.py, which was modelled on this function.
            with os.fdopen(tmp_fd, "wb", closefd=False) as out:
                out.write(existing + new_line)
                out.flush()
                os.fsync(tmp_fd)
        finally:
            os.close(tmp_fd)
        os.replace(tmp_path, anchor_path)
        os.chmod(anchor_path, 0o600)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


try:
    main()
except Exception:
    pass
'

printf '%s' "$input_json" | python3 -c "$py_code" "$anchors_dir" "$anchor_cap" 2>/dev/null || true

exit 0
