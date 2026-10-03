#!/usr/bin/env python3
"""Resolve papercuts whose tracking issue was closed by a merged pull request.

dev_docs/designs/2026-09-07-triage-and-route.md §4.4 describes this step.
Default is a dry run that prints the plan; `--apply` performs the resolve
and flush calls and writes the run manifest.

Input:
  --tracked   The tracked index, `papercut_tracked.py`: {prefix: [entry]},
              each entry carrying `url`, `repo`, `number`, `state`,
              `state_reason` and `full_id`. Entries are grouped by issue
              `url`; an issue's ids are the `full_id`s of its entries.
              Resolves use `full_id` -- papercut-resolve.sh rejects a prefix.

Per CLOSED issue in the index:

  rerouted    Every id it carries is also carried by an OPEN issue in the
              index: the source of a reroute (design §6), not a fix. Skipped
              with a plan line and not written to the manifest, so it does
              not report itself on every run.
  evidence    Its last CLOSED_EVENT's closer is a PullRequest with
              merged: true. Each id it carries is resolved with
              `papercut-resolve.sh <id> fixed <pr-url>`. A refusal because
              the id already has a resolution is recorded under `skipped`;
              any other resolve failure stops the run.
  no evidence Anything else -- a commit closer, an unmerged PR, no closer
              (`not planned`, or `completed` by hand). Recorded under
              `closed_without_evidence` for the attended skill. `completed`
              is a claim, not evidence.

The closer is read with one GraphQL call per closed issue:

  <gh> api graphql -F owner=<o> -F name=<n> -F number=<i> -f query=<QUERY>

Flush: on the default profile, `papercut-flush.sh --force` publishes the
resolutions and its last output line is recorded as `flush`. `--force`
bypasses flush's strict-profile hold, so the profile is detected first
through the seam flush itself uses -- $PAPERCUT_DETECT_CMD, else
papercut_append.detect_machine() -- and, failing closed as flush does,
anything but "default" is strict. On strict, flush is never called and
`flush` records that the resolutions are spooled, not published.

Manifest: resolved, skipped, closed_without_evidence and flush are written
into $PAPERCUT_TRIAGE_DIR/<run-date>.json (default
~/.claude/papercuts/triage/), the file papercut_file.py writes, validated
against schema/manifest.v1.json. A same-day re-run appends to `resolved`;
`skipped`, `closed_without_evidence` and `flush` are the latest run's. Every
other section is preserved; when no manifest exists yet, the sections the
schema requires are written empty. Only --apply writes the manifest.

Seams, each split with shlex.split:
  $PAPERCUT_GH_CMD       default "gh"
  $PAPERCUT_RESOLVE_CMD  default "bash <this dir>/papercut-resolve.sh"
  $PAPERCUT_FLUSH_CMD    default "bash <this dir>/papercut-flush.sh"
  $PAPERCUT_DETECT_CMD   run with `bash -c`, as papercut-flush.sh runs it

Requires Python 3.11+, same as papercut_file.py.
"""

import argparse
import datetime
import importlib.util
import json
import os
import shlex
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

QUERY = """\
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      timelineItems(itemTypes: [CLOSED_EVENT], last: 1) {
        nodes {
          ... on ClosedEvent {
            closer {
              __typename
              ... on PullRequest { merged url }
              ... on Commit { url }
            }
          }
        }
      }
    }
  }
}
"""

STRICT_FLUSH = "resolutions spooled, not published (strict profile)"
ALREADY_RESOLVED = "already has a resolution"


class FixedError(Exception):
    """A gh, resolve, or flush failure, or a manifest schema violation."""


def _load_sibling(name):
    path = os.path.join(SCRIPT_DIR, f"{name}.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _argv(env_name, default):
    return shlex.split(os.environ.get(env_name) or default)


def _tail(text, n=20):
    return "\n".join(text.splitlines()[-n:])


# --- index -----------------------------------------------------------------


def issues_from_index(index):
    """Group index entries by issue url: {url: {repo, number, state,
    state_reason, ids}}, ids sorted."""
    issues = {}
    for entries in index.values():
        for e in entries:
            issue = issues.setdefault(
                e["url"],
                {
                    "url": e["url"],
                    "repo": e["repo"],
                    "number": e["number"],
                    "state": e["state"],
                    "state_reason": e.get("state_reason"),
                    "ids": set(),
                },
            )
            issue["ids"].add(e["full_id"])
    for issue in issues.values():
        issue["ids"] = sorted(issue["ids"])
    return issues


# --- closer ----------------------------------------------------------------


def read_closer(repo, number):
    """Return the issue's last CLOSED_EVENT closer: None when there is no
    closer, else {"type", "merged", "url"}."""
    owner, name = repo.split("/", 1)
    args = ["api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"number={number}", "-f", f"query={QUERY}"]
    proc = subprocess.run(_argv("PAPERCUT_GH_CMD", "gh") + args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise FixedError(f"gh api graphql for {repo}#{number} failed:\n{_tail(proc.stderr)}")
    try:
        data = json.loads(proc.stdout)
        nodes = data["data"]["repository"]["issue"]["timelineItems"]["nodes"]
    except (ValueError, TypeError, KeyError) as exc:
        raise FixedError(f"gh api graphql for {repo}#{number}: unexpected output: {exc}") from exc
    closer = nodes[-1].get("closer") if nodes else None
    if not closer:
        return None
    return {"type": closer.get("__typename"), "merged": closer.get("merged") is True, "url": closer.get("url")}


# --- resolve and flush -----------------------------------------------------


def resolve(pc_id, pr_url):
    """Return "resolved" or "already"; raise on any other failure."""
    argv = _argv("PAPERCUT_RESOLVE_CMD", f"bash {shlex.quote(os.path.join(SCRIPT_DIR, 'papercut-resolve.sh'))}")
    proc = subprocess.run(argv + [pc_id, "fixed", pr_url], capture_output=True, text=True)
    if proc.returncode == 0:
        return "resolved"
    if ALREADY_RESOLVED in proc.stderr:
        return "already"
    raise FixedError(f"papercut-resolve.sh {pc_id} failed:\n{_tail(proc.stderr)}")


def detect_profile():
    """"default" or "strict", failing closed exactly as papercut-flush.sh
    does: anything other than a positive "default" is strict."""
    cmd = os.environ.get("PAPERCUT_DETECT_CMD")
    try:
        if cmd:
            proc = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
            machine = proc.stdout.strip()
        else:
            machine = _load_sibling("papercut_append").detect_machine()
    except Exception:
        machine = ""
    return "default" if machine == "default" else "strict"


def flush():
    """Run papercut-flush.sh --force. Return (ok, line): its last non-empty
    output line, or a failure description."""
    argv = _argv("PAPERCUT_FLUSH_CMD", f"bash {shlex.quote(os.path.join(SCRIPT_DIR, 'papercut-flush.sh'))}")
    proc = subprocess.run(argv + ["--force"], capture_output=True, text=True)
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    last = lines[-1].strip() if lines else ""
    if proc.returncode != 0:
        detail = last or _tail(proc.stderr, 1).strip()
        return False, f"failed (rc={proc.returncode}): {detail}"
    return True, last or "no output"


# --- manifest --------------------------------------------------------------


def write_manifest(run_date, resolved, skipped, closed_without_evidence, flush_line):
    pf = _load_sibling("papercut_file")
    directory = pf.triage_dir()
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"{run_date}.json")

    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                manifest = json.load(f)
        except (OSError, ValueError) as exc:
            raise FixedError(f"cannot read manifest {path}: {exc}") from exc
    else:
        manifest = {"run_date": run_date, "filed": [], "consolidated": [], "held": [], "noop": 0, "calls": {}}

    manifest["resolved"] = manifest.get("resolved", []) + resolved
    manifest["skipped"] = skipped
    manifest["closed_without_evidence"] = closed_without_evidence
    manifest["flush"] = flush_line

    err = pf.validate_structure(manifest, pf.load_schema("manifest.v1.json"))
    if err:
        raise FixedError(f"manifest failed schema validation: {err}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f)
        f.write("\n")


# --- plan ------------------------------------------------------------------


def cmd_plan(index, apply):
    run_date = datetime.date.today().isoformat()
    issues = issues_from_index(index)
    open_ids = {pid for issue in issues.values() if issue["state"] == "OPEN" for pid in issue["ids"]}
    closed = sorted((i for i in issues.values() if i["state"] == "CLOSED"), key=lambda i: (i["repo"], i["number"]))

    resolved = []
    skipped = []
    closed_without_evidence = []

    for issue in closed:
        url = issue["url"]
        if all(pid in open_ids for pid in issue["ids"]):
            print(f"skip         rerouted {url}  (every id is on an open issue)")
            continue

        closer = read_closer(issue["repo"], issue["number"])
        if closer and closer["type"] == "PullRequest" and closer["merged"]:
            pr = closer["url"]
            for pid in issue["ids"]:
                outcome = resolve(pid, pr) if apply else "planned"
                if outcome == "already":
                    skipped.append({"id": pid, "issue": url, "reason": "already resolved"})
                    print(f"skip         already resolved {pid}  {url}")
                    continue
                if outcome == "resolved":
                    resolved.append({"id": pid, "issue": url, "fix_url": pr})
                print(f"resolve      {pid} fixed {pr}  {url}")
        else:
            closer_type = closer["type"] if closer else None
            closed_without_evidence.append({"url": url, "state_reason": issue["state_reason"], "closer": closer_type})
            print(f"no-evidence  {url}  state_reason={issue['state_reason']} closer={closer_type}")

    profile = detect_profile()
    if profile != "default":
        flush_ok, flush_line = True, STRICT_FLUSH
        print("flush        held (strict profile)")
    elif not apply:
        flush_ok, flush_line = True, ""
        print("flush        papercut-flush.sh --force (default profile)")
    else:
        flush_ok, flush_line = flush()
        print(f"flush        {flush_line}")

    if apply:
        write_manifest(run_date, resolved, skipped, closed_without_evidence, flush_line)
    if not flush_ok:
        raise FixedError(f"papercut-flush.sh --force {flush_line}; the resolutions are in the spool, and the next flush publishes them")
    return 0


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(f"papercut_fixed.py: Python 3.11 or newer is required; this python3 is {found}", file=sys.stderr)
        return 2

    parser = argparse.ArgumentParser(description="Resolve papercuts whose tracking issue a merged PR closed.")
    parser.add_argument("--tracked", required=True, metavar="FILE", help="tracked index JSON file")
    parser.add_argument("--apply", action="store_true", help="resolve, flush, and write the manifest")
    args = parser.parse_args()

    try:
        with open(args.tracked, "r", encoding="utf-8") as f:
            index = json.load(f)["index"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"papercut_fixed.py: cannot read tracked index {args.tracked}: {exc}", file=sys.stderr)
        return 2

    try:
        return cmd_plan(index, args.apply)
    except FixedError as exc:
        print(f"papercut_fixed.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
