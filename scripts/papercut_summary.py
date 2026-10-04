#!/usr/bin/env python3
"""Render a triage run manifest as the one-line summary the triage skill ends
with, and that a scheduled run's notification carries.

dev_docs/designs/2026-09-07-triage-and-route.md §4.5 describes this step.

Usage:
  papercut_summary.py <manifest> [--verbose]

The manifest is validated against schema/manifest.v1.json first; an invalid
or unreadable one exits 1 and prints nothing to stdout. Then exactly one line:

  Papercuts triage <date>: <N> improvements — <F> filed (<O> owners),
  <C> consolidated, <H> held (labels), <R> resolved, <U> unowned.

  N  every cluster the run saw: filed + consolidated + held clusters + noop
  F  `filed` entries; O is how many distinct owners they went to, counting
     only entries whose `unowned` is false
  C  `consolidated` entries
  H  clusters across every `held` entry (one entry is one repo)
  R  `resolved` entries
  U  `filed` entries whose `unowned` is true: filed into unowned.repo, the
     pile /papercuts:reroute drains

A run with `failed` entries (issue #35) is incomplete, and the line says so
instead of ending at the full stop:

  ... <U> unowned; INCOMPLETE — <k> failed (<what>).

where <what> lists each failed `file` or `consolidate` step by repo, counts
`resolve` failures as `resolve ×<n>`, and names `flush`. The exit code is 0
either way: this script reports a run, it does not judge it.

--verbose adds one line per held repo (its missing labels), per
closed-without-evidence issue, and per failed step -- the material
/papercuts:reroute and the attended skill act on.

Structural validation reuses papercut_file.py's stdlib-only subset of JSON
Schema, loaded by path. Requires Python 3.11+, same as papercut_file.py.
"""

import argparse
import importlib.util
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FAILED_STEP_ORDER = ("file", "consolidate", "resolve", "flush")


def _papercut_file():
    path = os.path.join(SCRIPT_DIR, "papercut_file.py")
    spec = importlib.util.spec_from_file_location("papercut_file", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def describe_failed(failed):
    """`file acme/beta, resolve ×2, flush` -- in step order."""
    parts = []
    for step in FAILED_STEP_ORDER:
        entries = [f for f in failed if f["step"] == step]
        if not entries:
            continue
        if step in ("file", "consolidate"):
            parts.extend(f"{step} {f.get('repo') or f.get('issue') or '?'}" for f in entries)
        elif step == "resolve":
            parts.append(f"resolve ×{len(entries)}")
        else:
            parts.append(step)
    return ", ".join(parts)


def summary_line(m):
    filed = m["filed"]
    owned = [f for f in filed if not f["unowned"]]
    held_clusters = sum(len(h["clusters"]) for h in m["held"])
    improvements = len(filed) + len(m["consolidated"]) + held_clusters + m["noop"]

    line = (
        f"Papercuts triage {m['run_date']}: {improvements} improvements — "
        f"{len(filed)} filed ({len({f['target'] for f in owned})} owners), "
        f"{len(m['consolidated'])} consolidated, "
        f"{held_clusters} held (labels), "
        f"{len(m.get('resolved', []))} resolved, "
        f"{len(filed) - len(owned)} unowned"
    )
    failed = m.get("failed", [])
    if failed:
        return f"{line}; INCOMPLETE — {len(failed)} failed ({describe_failed(failed)})."
    return f"{line}."


def verbose_lines(m):
    lines = []
    for h in m["held"]:
        lines.append(f"held         {h['repo']}  missing={','.join(h['labels'])}  clusters={len(h['clusters'])}")
    for c in m.get("closed_without_evidence", []):
        lines.append(f"no-evidence  {c['url']}  state_reason={c['state_reason']} closer={c['closer']}")
    for f in m.get("failed", []):
        where = f.get("repo") or f.get("issue") or f.get("id") or ""
        first = f["error"].splitlines()[0] if f["error"] else ""
        lines.append(f"failed       {f['step']}  {where}  {f.get('title', '')}  {first}".rstrip())
    return lines


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(f"papercut_summary.py: Python 3.11 or newer is required; this python3 is {found}", file=sys.stderr)
        return 2

    parser = argparse.ArgumentParser(description="Print a triage run manifest's one-line summary.")
    parser.add_argument("manifest", help="run manifest JSON file")
    parser.add_argument("--verbose", action="store_true", help="also list held repos, unevidenced closes, and failures")
    args = parser.parse_args()

    try:
        with open(args.manifest, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"papercut_summary.py: cannot read {args.manifest}: {exc}", file=sys.stderr)
        return 1

    pf = _papercut_file()
    err = pf.validate_structure(manifest, pf.load_schema("manifest.v1.json"))
    if err:
        print(f"papercut_summary.py: {args.manifest} is not a valid manifest: {err}", file=sys.stderr)
        return 1

    print(summary_line(manifest))
    if args.verbose:
        for line in verbose_lines(manifest):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
