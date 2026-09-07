#!/usr/bin/env python3
"""Build the tracked index: which GitHub issues carry which open papercuts.

For every repo in the owners registry, plus the unowned repo, this lists
every issue in every state with its body and comments, through paged
GraphQL, and greps the text locally for each open papercut's 8-character
`pc_` id prefix. The result maps a prefix to every issue that carries it, in
any state -- consumers filter on `state` themselves (see
dev_docs/designs/2026-09-07-triage-and-route.md §4.4).

There is no search pass. A full listing already carries every prefix a
consolidated id lives under (in a body or a comment), so there is nothing a
search call would find that the listing does not, and no rate limit to
manage.

Inputs:
  Open set  -- JSONL records from `papercut_open.py --json`, read from stdin
               by default, or from --open <file>. Each record's `id` (e.g.
               "pc_1234abcd...") supplies the 8-character prefix (the first 8
               hex characters after "pc_"). A record with no well-formed id
               is ignored.
  Registry  -- scripts/papercut_owners.py's load(), imported by path the same
               way papercut_owners.py imports papercut_config.py. The repos
               listed are every [owners.*].repo plus unowned.repo, deduped.

GitHub access goes through one seam, $PAPERCUT_GH_CMD (default "gh"), split
with shlex.split -- the same seam pattern as $PAPERCUT_APPEND_CMD. One
GraphQL listing call per distinct repo:

  <gh_cmd> api graphql --paginate --slurp \
      -F owner=<owner> -F name=<name> -f query=<QUERY>

`--slurp` makes gh print one JSON array holding every page's response. The
query is paged on `pageInfo { hasNextPage endCursor }` through the
$endCursor variable, which gh's own --paginate follows automatically. The
collected node count is checked against `totalCount`: a mismatch is a hard
error naming the repo and both numbers, because a partial index is worse
than a failed one.

An issue's `comments.totalCount` can exceed the 100 comment nodes GraphQL
returns per issue; when it does, this fetches every comment for that issue
with a second, per-issue call through the same seam:

  <gh_cmd> api --paginate repos/<owner>/<name>/issues/<number>/comments

and uses those bodies instead of the truncated node list.

Requires Python 3.11+, same as papercut_owners.py and papercut_config.py
(though nothing here uses tomllib directly -- the registry loader does).

Usage:
  papercut_open.py --json | python3 papercut_tracked.py
  python3 papercut_tracked.py --open open.jsonl
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys

PREFIX_RE = re.compile(r"pc_([0-9a-f]{8})")
OPEN_ID_RE = re.compile(r"^pc_([0-9a-f]{8})")

QUERY = """\
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $endCursor, states: [OPEN, CLOSED]) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        state
        stateReason
        url
        title
        body
        labels(first: 100) { nodes { name } }
        comments(first: 100) { totalCount nodes { body } }
      }
    }
  }
}
"""

_OWNERS_MODULE = None


def _owners_module():
    """Import papercut_owners.py from THIS file's directory, by path -- the
    same pattern papercut_owners.py itself uses for papercut_config.py."""
    global _OWNERS_MODULE
    if _OWNERS_MODULE is None:
        import importlib.util

        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "papercut_owners.py")
        spec = importlib.util.spec_from_file_location("papercut_owners", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _OWNERS_MODULE = module
    return _OWNERS_MODULE


def registered_repos(registry):
    """Every [owners.*].repo plus unowned.repo, deduped, order not
    significant (the caller sorts repos before use)."""
    repos = {owner["repo"] for owner in registry["owners"].values()}
    unowned_repo = registry.get("unowned", {}).get("repo")
    if unowned_repo:
        repos.add(unowned_repo)
    return repos


def load_open_prefixes(lines):
    """Return {8-char prefix: full_id} from JSONL open-set records. A record
    whose id does not start with "pc_" followed by 8 hex characters is
    ignored."""
    prefixes = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(rec, dict):
            continue
        rec_id = rec.get("id")
        if not isinstance(rec_id, str):
            continue
        match = OPEN_ID_RE.match(rec_id)
        if not match:
            continue
        prefixes[f"pc_{match.group(1)}"] = rec_id
    return prefixes


def _gh_argv():
    gh_cmd = os.environ.get("PAPERCUT_GH_CMD", "gh")
    return shlex.split(gh_cmd)


def _stderr_tail(stderr, n=20):
    lines = stderr.splitlines()
    return "\n".join(lines[-n:])


class TrackedError(Exception):
    """A gh call failed, or a repo's listing was incomplete."""


def _run_gh(args):
    """Run a gh_argv + args subprocess. Returns stdout. Raises TrackedError
    (message already formatted for stderr) on a non-zero exit."""
    proc = subprocess.run(_gh_argv() + args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise TrackedError(f"gh {' '.join(args[:2])} failed:\n{_stderr_tail(proc.stderr)}")
    return proc.stdout


def _parse_concatenated_json(text):
    """Parse one or more whitespace-separated top-level JSON values from
    text, flattening any that are lists into a single list. Handles both a
    single JSON array (one page) and several arrays back to back (gh
    --paginate on a REST list endpoint, without --slurp)."""
    text = text.strip()
    if not text:
        return []
    decoder = json.JSONDecoder()
    idx = 0
    values = []
    while idx < len(text):
        while idx < len(text) and text[idx].isspace():
            idx += 1
        if idx >= len(text):
            break
        obj, end = decoder.raw_decode(text, idx)
        values.append(obj)
        idx = end
    flat = []
    for value in values:
        if isinstance(value, list):
            flat.extend(value)
        else:
            flat.append(value)
    return flat


def list_repo_issues(owner, name):
    """Run the paged GraphQL listing for one repo. Returns the list of issue
    nodes. Raises TrackedError on a gh failure or a totalCount mismatch."""
    stdout = _run_gh(["api", "graphql", "--paginate", "--slurp", "-F", f"owner={owner}", "-F", f"name={name}", "-f", f"query={QUERY}"])
    pages = json.loads(stdout)

    nodes = []
    total_count = None
    for page in pages:
        issues = page["data"]["repository"]["issues"]
        if total_count is None:
            total_count = issues["totalCount"]
        nodes.extend(issues["nodes"])

    if total_count is not None and len(nodes) != total_count:
        raise TrackedError(f"{owner}/{name}: collected {len(nodes)} issue(s) but totalCount is {total_count}")

    return nodes


def fetch_all_comments(owner, name, number):
    """Fetch every comment body for one issue via the REST endpoint, for an
    issue whose comments.totalCount exceeds the GraphQL node cap."""
    stdout = _run_gh(["api", "--paginate", f"repos/{owner}/{name}/issues/{number}/comments"])
    comments = _parse_concatenated_json(stdout)
    return [c.get("body") or "" for c in comments if isinstance(c, dict)]


def _extract_prefixes(text, open_prefixes):
    return {f"pc_{m}" for m in PREFIX_RE.findall(text or "")} & open_prefixes.keys()


def build_index(repos, open_prefixes):
    """Returns (index, calls) where index is {prefix: [entry, ...]} and calls
    is {"list": n, "comments": n}."""
    raw_index = {}
    calls_list = 0
    calls_comments = 0

    for repo in sorted(repos):
        owner, name = repo.split("/", 1)
        nodes = list_repo_issues(owner, name)
        calls_list += 1

        for issue in nodes:
            body_hits = _extract_prefixes(issue.get("body"), open_prefixes)

            comments = issue.get("comments") or {}
            comment_nodes = comments.get("nodes") or []
            comments_total = comments.get("totalCount") or 0
            if comments_total > len(comment_nodes):
                comment_bodies = fetch_all_comments(owner, name, issue["number"])
                calls_comments += 1
            else:
                comment_bodies = [c.get("body") for c in comment_nodes]

            comment_hits = set()
            for body in comment_bodies:
                comment_hits |= _extract_prefixes(body, open_prefixes)
            comment_hits -= body_hits

            labels = [n["name"] for n in (issue.get("labels") or {}).get("nodes") or []]

            for prefix, source in [(p, "body") for p in body_hits] + [(p, "comment") for p in comment_hits]:
                entry = {
                    "repo": repo,
                    "number": issue["number"],
                    "url": issue["url"],
                    "state": issue["state"],
                    "state_reason": issue.get("stateReason"),
                    "labels": labels,
                    "full_id": open_prefixes[prefix],
                    "source": source,
                }
                raw_index.setdefault(prefix, []).append(entry)

    for entries in raw_index.values():
        entries.sort(key=lambda e: (e["repo"], e["number"]))

    index = {prefix: raw_index[prefix] for prefix in sorted(raw_index)}
    return index, {"list": calls_list, "comments": calls_comments}


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(
            f"papercut_tracked.py: Python 3.11 or newer is required; this python3 is {found}",
            file=sys.stderr,
        )
        return 2

    parser = argparse.ArgumentParser(description="Build the tracked index across registered repos.")
    parser.add_argument("--open", metavar="FILE", help="open-set JSONL file (default: stdin)")
    parser.add_argument("--json", action="store_true", help="print the index as JSON (the default and only output)")
    args = parser.parse_args()

    if args.open:
        with open(args.open, "r", encoding="utf-8") as f:
            open_prefixes = load_open_prefixes(f)
    else:
        open_prefixes = load_open_prefixes(sys.stdin)

    owners = _owners_module()
    try:
        registry = owners.load()
    except owners.OwnersError as exc:
        print(f"papercut_tracked.py: {exc}", file=sys.stderr)
        return 2

    repos = registered_repos(registry)

    try:
        index, calls = build_index(repos, open_prefixes)
    except TrackedError as exc:
        print(f"papercut_tracked.py: {exc}", file=sys.stderr)
        return 1

    print(json.dumps({"index": index, "calls": calls}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
