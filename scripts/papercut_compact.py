#!/usr/bin/env python3
"""Deterministic, no-model compaction of a Claude Code session transcript.

Reads transcript JSONL from stdin, writes a compacted JSONL transcript to
stdout — same entry/block shapes, trimmed content — so the extractor
prompt's "raw transcript" framing still holds, but the total byte size
stays under PAPERCUT_COMPACT_BUDGET_BYTES (default 200000).

Three stages, applied only as needed:

1. Per-entry lossless-shape trimming (always): strip envelope metadata,
   drop thinking blocks, cap/stub tool_result and tool_use payloads.
2. Anchor-preserving reduction (if stage 1 still exceeds budget): keep
   every user text turn, denial, and error-tool_result neighborhood;
   collapse the rest into elision-marker note entries.
3. Absolute-budget truncation (if the must-keep set alone still exceeds
   budget): bound every content field, including must-keeps, to a
   head/tail excerpt with a truncation marker. The budget always wins.

Pure stdlib, deterministic — no wall-clock or randomness.
"""

import json
import os
import sys

DEFAULT_BUDGET = 200000
ERROR_CAP = 4000
TOOL_USE_FIELD_CAP = 200
NONERROR_STUB_HEAD = 200
NEIGHBOR_RADIUS = 2
TRUNC_MARKER = "...[truncated]..."
MALFORMED_STUB_CAP = 500


def _utf8_len(s):
    """Byte length of s, tolerant of lone surrogates from escaped \\uD800-\\uDFFF
    sequences that valid JSON can carry but plain UTF-8 cannot encode."""
    return len(s.encode("utf-8", errors="replace"))


def _content_blocks(content):
    """Return content as a list of blocks, or None if it's a plain string."""
    if isinstance(content, str):
        return None
    if isinstance(content, list):
        return content
    return []


def _is_user_text_turn(entry):
    """Mirror papercut-capture.sh:177's human-turn definition."""
    if entry.get("type") != "user" or entry.get("isMeta", False):
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "text" for b in content)
    return False


def _has_error_tool_result(entry):
    content = entry.get("message", {}).get("content")
    blocks = _content_blocks(content)
    if not blocks:
        return False
    return any(
        isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error") is True
        for b in blocks
    )


def _is_denial(entry):
    return entry.get("toolDenialKind") is not None


def _elide_str(s, cap, label):
    """Stub a string field down to a head excerpt with a byte-count marker."""
    n = _utf8_len(s)
    head = s[:cap]
    return f"{head}[{label}: {n} bytes elided]"


def _compact_tool_use_block(block):
    out = {"type": "tool_use"}
    if "id" in block:
        out["id"] = block["id"]
    if "name" in block:
        out["name"] = block["name"]
    inp = block.get("input")
    if isinstance(inp, dict):
        compact_input = {}
        for key, val in inp.items():
            if isinstance(val, str) and len(val) > TOOL_USE_FIELD_CAP:
                compact_input[key] = _elide_str(val, TOOL_USE_FIELD_CAP, key)
            else:
                compact_input[key] = val
        out["input"] = compact_input
    return out


def _compact_tool_result_block(block):
    is_error = block.get("is_error") is True
    content = block.get("content")
    out = {"type": "tool_result", "is_error": is_error}
    if "tool_use_id" in block:
        out["tool_use_id"] = block["tool_use_id"]
    if is_error:
        if isinstance(content, str) and len(content) > ERROR_CAP:
            out["content"] = _elide_str(content, ERROR_CAP, "error content")
        else:
            out["content"] = content
    else:
        if isinstance(content, str):
            n = _utf8_len(content)
            head = content[:NONERROR_STUB_HEAD]
            out["content"] = f"[tool_result: {n} bytes elided] {head}"
        else:
            out["content"] = "[tool_result: non-string payload elided]"
    return out


def _compact_content(content):
    blocks = _content_blocks(content)
    if blocks is None:
        return content
    out = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype in ("thinking", "redacted_thinking"):
            continue
        if btype == "text":
            out.append({"type": "text", "text": block.get("text", "")})
        elif btype == "tool_result":
            out.append(_compact_tool_result_block(block))
        elif btype == "tool_use":
            out.append(_compact_tool_use_block(block))
        else:
            out.append(block)
    return out


def _compact_entry(entry):
    """Stage 1: strip envelope metadata, trim block payloads."""
    out = {"type": entry.get("type")}
    if "isMeta" in entry:
        out["isMeta"] = entry["isMeta"]
    message = entry.get("message")
    if isinstance(message, dict):
        out_message = {}
        if "role" in message:
            out_message["role"] = message["role"]
        out_message["content"] = _compact_content(message.get("content"))
        out["message"] = out_message
    if entry.get("toolDenialKind") is not None:
        out["toolDenialKind"] = entry["toolDenialKind"]
    return out


def _malformed_stub(raw_line, index):
    excerpt = raw_line[:MALFORMED_STUB_CAP]
    return {
        "type": "note",
        "message": {
            "role": "system",
            "content": f"[malformed transcript line {index} skipped: {excerpt!r}]",
        },
    }


def _note(text):
    return {"type": "note", "message": {"role": "system", "content": text}}


def _serialize(entries):
    return [json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in entries]


def _total_bytes(lines):
    return sum(_utf8_len(line) + 1 for line in lines)


def _valid_anchor(obj):
    """An anchor record is usable only if the fields _anchor_indices reads
    (tool_use_id, tool_name, kind) are the expected str-or-absent shape.
    kind in particular becomes part of a dict key (see _anchor_indices), so
    an unhashable kind (e.g. a JSON list) must be rejected here, not crash
    downstream."""
    if not isinstance(obj, dict):
        return False
    for field in ("tool_use_id", "tool_name", "kind"):
        if field in obj and obj[field] is not None and not isinstance(obj[field], str):
            return False
    return True


def _load_anchors(path):
    """Load anchor records (task 3's papercut-anchor.sh output) from `path`.
    Fails closed to "no anchors" on any problem -- missing file, unreadable
    file, empty file, or any line that isn't a valid, well-shaped anchor
    object -- so a broken anchors file degrades to task 1 behavior rather
    than crashing or partially applying. Validation is transactional: one
    malformed/malshaped line discards the whole file's anchors, since a
    partially-trusted anchor set has no well-defined "no regression"
    baseline to fall back to."""
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            raw = f.read()
    except OSError:
        return []
    anchors = []
    for line in raw.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return []
        if not _valid_anchor(obj):
            return []
        anchors.append(obj)
    return anchors


def _tool_result_index(entries):
    """Map tool_use_id -> set of entry indices, scanning tool_result blocks."""
    idx = {}
    for i, entry in enumerate(entries):
        for block in _content_blocks(entry.get("message", {}).get("content")) or []:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                tid = block.get("tool_use_id")
                if isinstance(tid, str) and tid:
                    idx.setdefault(tid, set()).add(i)
    return idx


def _tool_use_candidate_indices(entries, tool_name):
    """Entry indices containing a tool_use block, in transcript order,
    restricted to `tool_name` when given. This is the fallback's structural
    anchor point: the invocation itself, rather than its (possibly
    inconsistently flagged) tool_result -- keeping it also protects the
    paired tool_result via NEIGHBOR_RADIUS, without assuming the anchor's
    view of "error"/"denied" agrees with how the transcript flagged it."""
    out = []
    for i, entry in enumerate(entries):
        for block in _content_blocks(entry.get("message", {}).get("content")) or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                if not tool_name or block.get("name") == tool_name:
                    out.append(i)
                    break
    return out


def _anchor_indices(entries, anchors):
    """Resolve anchor records to transcript entry indices. Primary: exact
    tool_use_id match against tool_result blocks (order-immune). Fallback
    (only for anchors missing tool_use_id, e.g. permission_prompt): best-
    effort tool_name + kind + order -- the Nth tool_use invocation matching
    tool_name, where N counts prior fallback anchors sharing that same
    (tool_name, kind) so repeated anchors walk forward through repeated
    invocations. Clamped to the last candidate when order runs past what's
    available, so a resolvable anchor always keeps *a* plausible candidate
    rather than none; kind alone (no tool_name) matches any tool_use, in
    order."""
    if not anchors:
        return set()
    tool_result_idx = _tool_result_index(entries)
    fallback_order = {}
    result = set()
    for anchor in anchors:
        tid = anchor.get("tool_use_id")
        if isinstance(tid, str) and tid:
            result.update(tool_result_idx.get(tid, ()))
            continue
        kind = anchor.get("kind")
        tool_name = anchor.get("tool_name")
        tool_name = tool_name if isinstance(tool_name, str) and tool_name else None
        candidates = _tool_use_candidate_indices(entries, tool_name)
        if not candidates:
            continue
        key = (kind, tool_name)
        order = fallback_order.get(key, 0)
        fallback_order[key] = order + 1
        result.add(candidates[min(order, len(candidates) - 1)])
    return result


def _must_keep_indices(entries, extra_anchor_indices=None):
    """Single overridable must-keep index set: user turns, denials, error
    tool_result neighborhoods, plus any externally supplied anchor indices
    (task 5 extends this via extra_anchor_indices)."""
    keep = set()
    for i, entry in enumerate(entries):
        if _is_user_text_turn(entry) or _is_denial(entry) or _has_error_tool_result(entry):
            for j in range(max(0, i - NEIGHBOR_RADIUS), min(len(entries), i + NEIGHBOR_RADIUS + 1)):
                keep.add(j)
    if extra_anchor_indices:
        for i in extra_anchor_indices:
            if 0 <= i < len(entries):
                for j in range(max(0, i - NEIGHBOR_RADIUS), min(len(entries), i + NEIGHBOR_RADIUS + 1)):
                    keep.add(j)
    return keep


def _reduce_to_anchors(entries, keep_indices):
    """Stage 2: collapse consecutive non-must-keep runs into note markers."""
    out = []
    i = 0
    n = len(entries)
    while i < n:
        if i in keep_indices:
            out.append(entries[i])
            i += 1
            continue
        run_start = i
        while i < n and i not in keep_indices:
            i += 1
        out.append(_note(f"[{i - run_start} entries elided by budget]"))
    return out


def _string_fields_in_entry(entry):
    """Yield (container, key) pairs for every truncatable string field in an
    entry: message.content itself (if a plain string), and content/text/input
    string fields inside each content block."""
    fields = []
    message = entry.get("message")
    if not isinstance(message, dict):
        return fields
    content = message.get("content")
    if isinstance(content, str):
        fields.append((message, "content"))
    elif isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            if isinstance(block.get("text"), str):
                fields.append((block, "text"))
            if isinstance(block.get("content"), str):
                fields.append((block, "content"))
            inp = block.get("input")
            if isinstance(inp, dict):
                for k, v in inp.items():
                    if isinstance(v, str):
                        fields.append((inp, k))
    return fields


def _truncate_field(s, cap):
    """Head/tail excerpt of s bounded to ~cap chars, with a truncation
    marker, deterministic given s and cap."""
    if cap <= 0:
        return ""
    if len(s) <= cap:
        return s
    if cap <= len(TRUNC_MARKER):
        return TRUNC_MARKER[:cap]
    remaining = cap - len(TRUNC_MARKER)
    head_len = (remaining + 1) // 2
    tail_len = remaining - head_len
    if tail_len:
        return s[:head_len] + TRUNC_MARKER + s[-tail_len:]
    return s[:head_len] + TRUNC_MARKER


def _apply_cap(entries, cap):
    """Return a deep-ish copy of entries with every truncatable string
    field bounded to `cap` chars. cap=None means no truncation."""
    out = []
    for entry in entries:
        entry_copy = json.loads(json.dumps(entry))
        if cap is not None:
            for container, key in _string_fields_in_entry(entry_copy):
                container[key] = _truncate_field(container[key], cap)
        out.append(entry_copy)
    return out


def _max_field_len(entries):
    m = 0
    for entry in entries:
        for container, key in _string_fields_in_entry(entry):
            m = max(m, len(container[key]))
    return m


def _truncate_to_budget(entries, budget):
    """Stage 3: binary-search a per-field character cap such that
    serializing every must-keep entry with that cap fits under budget.
    Every candidate is measured directly (never assumed), so the returned
    lines are guaranteed <= budget bytes even though size(cap) need not be
    strictly monotonic (a field that stops needing truncation drops its
    marker, which can shrink output at a larger cap).
    """
    lo, hi = 0, _max_field_len(entries)
    best_lines = _serialize(_apply_cap(entries, 0))
    if _total_bytes(best_lines) > budget:
        return _hard_byte_cutoff(best_lines, budget)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        candidate = _serialize(_apply_cap(entries, mid))
        if _total_bytes(candidate) <= budget:
            lo = mid
            best_lines = candidate
        else:
            hi = mid - 1
    return best_lines


def _hard_byte_cutoff(lines, budget):
    """Last-resort deterministic fallback: keep whole lines, in order, up to
    budget bytes, skipping (not stopping at) any single line too big to fit
    so later, smaller must-keeps still get a chance. Only reached when even
    maximally truncated must-keeps (cap=0) exceed budget on fixed JSON
    overhead alone."""
    out = []
    total = 0
    for line in lines:
        size = _utf8_len(line) + 1
        if total + size > budget:
            continue
        out.append(line)
        total += size
    return out


def compact(lines, budget=None, anchors=None):
    if budget is None:
        budget = DEFAULT_BUDGET

    entries = []
    for idx, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n")
        if not line:
            continue
        try:
            parsed = json.loads(line)
            if not isinstance(parsed, dict):
                raise ValueError("not an object")
        except (json.JSONDecodeError, ValueError):
            entries.append(_malformed_stub(line, idx))
            continue
        entries.append(_compact_entry(parsed))

    stage1_lines = _serialize(entries)
    if _total_bytes(stage1_lines) <= budget:
        return stage1_lines

    keep_indices = _must_keep_indices(entries, _anchor_indices(entries, anchors))
    reduced_entries = _reduce_to_anchors(entries, keep_indices)
    stage2_lines = _serialize(reduced_entries)
    if _total_bytes(stage2_lines) <= budget:
        return stage2_lines

    return _truncate_to_budget(reduced_entries, budget)


def _anchors_path_from_argv(argv):
    if "--anchors" in argv:
        i = argv.index("--anchors")
        if i + 1 < len(argv):
            return argv[i + 1]
    return os.environ.get("PAPERCUT_ANCHORS")


def main():
    budget = int(os.environ.get("PAPERCUT_COMPACT_BUDGET_BYTES", DEFAULT_BUDGET))
    anchors = _load_anchors(_anchors_path_from_argv(sys.argv[1:]))
    raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    lines = raw.split("\n")
    out = sys.stdout.buffer
    for line in compact(lines, budget, anchors):
        out.write(line.encode("utf-8", errors="replace"))
        out.write(b"\n")


if __name__ == "__main__":
    main()
