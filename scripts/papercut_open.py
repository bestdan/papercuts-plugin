#!/usr/bin/env python3
"""Read-only fold view over the papercuts ledger + local spool: shows which
papercuts are still open (no resolution record points at them) vs resolved.

Sources: every ledger/*.jsonl file under $PAPERCUT_LEDGER_DIR (default
~/src/papercuts) plus the local spool ($PAPERCUT_SPOOL, default
~/.claude/papercuts/spool.jsonl) if present. A missing ledger clone is
tolerated with a clear stderr note, not a crash -- the spool alone (or an
empty view) is still useful.

Fold semantics: a papercut record (type=="papercut", OR type absent --
ledger rows written before the type field existed are grandfathered as
papercuts) is OPEN unless some resolution record's `resolves` field equals
its `id`. If multiple resolutions target the same id, the last one seen
(source order: ledger files sorted by name, then the spool) wins. Malformed
lines are skipped, not fatal.

Usage:
  papercut_open.py             # open papercuts, grouped by severity
  papercut_open.py --resolved  # resolved papercuts + their resolution
  papercut_open.py --json      # open papercuts as JSONL, one record per line

Pure stdlib, deterministic ordering (severity rank high>medium>low, then ts).
"""

import argparse
import glob
import json
import os
import sys

SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}
SEVERITY_ORDER = ("high", "medium", "low")


def _iter_lines(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except (ValueError, TypeError):
                    continue
    except OSError:
        return


def load_records(ledger_dir, spool_path):
    records = []
    ledger_glob = os.path.join(ledger_dir, "ledger", "*.jsonl")
    ledger_files = sorted(glob.glob(ledger_glob))
    if not ledger_files:
        print(
            f"note: no ledger files found under {ledger_glob} (missing clone?)",
            file=sys.stderr,
        )
    for path in ledger_files:
        for rec in _iter_lines(path):
            if isinstance(rec, dict):
                records.append(rec)
    if os.path.isfile(spool_path):
        for rec in _iter_lines(spool_path):
            if isinstance(rec, dict):
                records.append(rec)
    return records


def fold(records):
    """Return (open_papercuts, resolved) where open_papercuts is a list of
    papercut records with no matching resolution, and resolved is a list of
    (papercut_record, resolution_record) pairs."""
    papercuts = {}
    resolutions = {}
    for rec in records:
        rtype = rec.get("type", "papercut")
        if rtype == "resolution":
            resolves = rec.get("resolves")
            if isinstance(resolves, str):
                resolutions[resolves] = rec
        elif rtype == "papercut":
            rec_id = rec.get("id")
            if isinstance(rec_id, str):
                papercuts[rec_id] = rec
    open_papercuts = [rec for rid, rec in papercuts.items() if rid not in resolutions]
    resolved = [(rec, resolutions[rid]) for rid, rec in papercuts.items() if rid in resolutions]
    return open_papercuts, resolved


def _sort_key(rec):
    severity = rec.get("severity", "low")
    return (SEVERITY_RANK.get(severity, len(SEVERITY_ORDER)), rec.get("ts", ""), rec.get("id", ""))


def id_short(rec_id):
    if isinstance(rec_id, str) and rec_id.startswith("pc_"):
        return rec_id[3:11]
    return (rec_id or "?")[:8]


def date_of(ts):
    if isinstance(ts, str) and "T" in ts:
        return ts.split("T", 1)[0]
    return ts or "?"


def machine_repo(rec):
    machine = rec.get("machine") or "?"
    repo = rec.get("repo")
    return f"{machine}/{repo}" if repo else machine


def print_open(open_papercuts):
    by_severity = {sev: [] for sev in SEVERITY_ORDER}
    overflow = []
    for rec in sorted(open_papercuts, key=_sort_key):
        severity = rec.get("severity")
        if severity in by_severity:
            by_severity[severity].append(rec)
        else:
            overflow.append(rec)

    total = 0
    for severity in SEVERITY_ORDER:
        recs = by_severity[severity]
        if not recs:
            continue
        print(f"-- {severity} ({len(recs)}) --")
        for rec in recs:
            print(
                f"{id_short(rec.get('id')):<8}  {date_of(rec.get('ts')):<10}  "
                f"{machine_repo(rec):<20}  {rec.get('title', '')}"
            )
        total += len(recs)

    if overflow:
        print(f"-- unknown severity ({len(overflow)}) --")
        for rec in overflow:
            print(
                f"{id_short(rec.get('id')):<8}  {date_of(rec.get('ts')):<10}  "
                f"{machine_repo(rec):<20}  {rec.get('title', '')}"
            )
        total += len(overflow)

    print(f"\n{total} open papercut(s)")


def print_resolved(resolved):
    for rec, resolution in sorted(resolved, key=lambda pair: _sort_key(pair[0])):
        fix_url = resolution.get("fix_url", "")
        line = (
            f"{id_short(rec.get('id')):<8}  {date_of(rec.get('ts')):<10}  "
            f"{machine_repo(rec):<20}  {resolution.get('status', ''):<18}  "
            f"{rec.get('title', '')}"
        )
        if fix_url:
            line += f"  {fix_url}"
        print(line)
    print(f"\n{len(resolved)} resolved papercut(s)")


def print_json(open_papercuts):
    for rec in sorted(open_papercuts, key=_sort_key):
        print(json.dumps(rec, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--resolved", action="store_true", help="list resolved papercuts instead")
    parser.add_argument("--json", action="store_true", help="emit open papercuts as JSONL")
    args = parser.parse_args()

    ledger_dir = os.path.expanduser(os.environ.get("PAPERCUT_LEDGER_DIR", "~/src/papercuts"))
    spool_path = os.path.expanduser(
        os.environ.get("PAPERCUT_SPOOL", "~/.claude/papercuts/spool.jsonl")
    )

    records = load_records(ledger_dir, spool_path)
    open_papercuts, resolved = fold(records)

    if args.json:
        print_json(open_papercuts)
    elif args.resolved:
        print_resolved(resolved)
    else:
        print_open(open_papercuts)


if __name__ == "__main__":
    main()
