#!/usr/bin/env python3
"""Grouping/quarantine step for papercut-flush.sh.

Reads a claimed batch file line-by-line. A line is valid iff it parses as a
JSON object with a `ts` string matching the schema's strict
YYYY-MM-DDTHH:MM:SSZ pattern AND that string is a real calendar date/time
(datetime.strptime rejects e.g. month 13). Valid lines are grouped by
YYYY-MM and written to <group_dir>/<YYYY-MM>.jsonl; each such month is
printed to stdout (one per line) for the caller to hand to the publisher.

Invalid lines are written to <quarantine_dir>/<batch_basename> (overwritten
each run — deterministic recompute of the same batch content, not an
ever-growing append) so a bad line is never used to derive a path and never
silently dropped.

argv: <batch_path> <quarantine_dir> <group_dir>
"""

import json
import os
import re
import sys
from datetime import datetime

TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def is_valid_ts(ts) -> bool:
    if not isinstance(ts, str) or not TS_RE.match(ts):
        return False
    try:
        datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def main() -> None:
    batch_path, quarantine_dir, group_dir = sys.argv[1:4]

    os.makedirs(quarantine_dir, mode=0o700, exist_ok=True)
    os.makedirs(group_dir, mode=0o700, exist_ok=True)

    batch_name = os.path.basename(batch_path)
    quarantine_path = os.path.join(quarantine_dir, batch_name)

    groups: dict = {}
    bad_lines: list = []

    # errors="surrogateescape" so an undecodable byte becomes a lossless
    # surrogate rather than crashing the whole helper (which would strand the
    # batch — and its valid records — forever, re-crashing every run). Such a
    # line fails json.loads and lands in bad_lines -> quarantine, while valid
    # lines in the same batch still group and publish. The quarantine writer
    # below uses the same codec to re-encode the surrogate back to the original
    # byte.
    with open(batch_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            valid = False
            month = None
            try:
                rec = json.loads(line)
                if isinstance(rec, dict) and is_valid_ts(rec.get("ts")):
                    month = rec["ts"][:7]
                    valid = True
            except (json.JSONDecodeError, TypeError):
                valid = False
            if valid:
                groups.setdefault(month, []).append(line)
            else:
                bad_lines.append(line)

    if bad_lines:
        fd = os.open(quarantine_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
            os.fchmod(f.fileno(), 0o600)
            for line in bad_lines:
                f.write(line + "\n")
    elif os.path.exists(quarantine_path):
        os.remove(quarantine_path)

    for month in sorted(groups):
        group_path = os.path.join(group_dir, f"{month}.jsonl")
        fd = os.open(group_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            os.fchmod(f.fileno(), 0o600)
            for line in groups[month]:
                f.write(line + "\n")
        print(month)


if __name__ == "__main__":
    main()
