#!/usr/bin/env python3
"""File each triage cluster with its owner: label pre-flight, body render,
`gh issue create`/`gh issue comment`, and the run manifest.

dev_docs/designs/2026-09-07-triage-and-route.md §4.3, §4.5 describes this
step. Default is a dry run that prints the plan; `--apply` performs the
writes.

Input:
  --clusters  The enriched clusters `papercut_clusters.py validate-clusters`
              (or `validate-consolidations`) printed: `class` (file, noop, or
              consolidate), `target`, `severity`, `effort`, `confidence`, and
              -- for a consolidate cluster -- `issue`. A cluster may also
              carry a model-set `fix_now`, which overrides the effort/
              confidence rule below either way. `class` is trusted as given;
              this script never re-derives it.
  --owners    The owners registry, `papercut_owners.py --json`.
  --open      The open-set JSONL, `papercut_open.py --json` -- read for each
              source papercut's `title` and `suggested_fix`.
  --tracked   The tracked index, `papercut_tracked.py` -- read only for its
              `calls` block, copied into the manifest verbatim. The `index`
              field is not read; tracked/untracked classification is
              `papercut_clusters.py`'s job, not this script's.

Per cluster:

  file        Label pre-flight (below), then one `<gh> issue create --repo
              <r> --title <t> --label ... --body-file <tmp>`, serially --
              never a fan-out, never a body on the command line (these
              bodies carry backticked pc_ ids, which an inline --body would
              hand to the shell as command substitution).
  consolidate `<gh> issue comment <issue-url> --body-file <tmp>` with a
              **Consolidation:** block naming the cluster's papercut ids.
  noop        Nothing.

Label pre-flight, per owner repo: the union of what THIS run will actually
write there -- papercut, priority:<severity> for each severity value present
among that repo's file clusters, papercut-fix-now only if some cluster there
qualifies, plus the owner's declared labels. Not the whole plugin
vocabulary. Read with `<gh> label list --repo <owner/name> --json name
--limit 500`. If any name is missing, this run files nothing into that
owner -- every cluster targeting it is held, and the run continues. This
check is read-only and runs in both dry-run and --apply modes.

--render <cluster-index> prints one cluster's title and body and exits --
no network, no writes.

Manifest: {run_date, filed, consolidated, held, noop, calls} is written to
$PAPERCUT_TRIAGE_DIR/<run-date>.json (default
~/.claude/papercuts/triage/), validated against schema/manifest.v1.json.
An existing file's other sections (resolved, skipped,
closed_without_evidence, flush -- written by later tasks) are preserved.
Only --apply writes the manifest; a dry run is inspection only.

GitHub access goes through $PAPERCUT_GH_CMD (default "gh"), split with
shlex.split -- the same seam pattern as $PAPERCUT_APPEND_CMD.

Structural validation (the manifest only) is the same hand-rolled, stdlib-
only subset of JSON Schema draft 2020-12 that papercut_clusters.py uses.

Requires Python 3.11+, same as papercut_clusters.py and papercut_owners.py.
"""

import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

SEVERITY_ORDER = ("high", "medium", "low")


class FilingError(Exception):
    """A gh call failure, a manifest schema violation, or an unknown target."""


# --- schema loading and the subset structural interpreter (mirrors
# papercut_clusters.py's _validate_schema) -----------------------------------


def load_schema(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schema", name)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _type_ok(value, expected):
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "array":
        return isinstance(value, list)
    if expected == "object":
        return isinstance(value, dict)
    return True


def _validate_schema(value, schema, path):
    errors = []
    expected = schema.get("type")
    if expected and not _type_ok(value, expected):
        return [f"{path or '<root>'}: expected {expected}"]

    if expected == "string":
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            errors.append(f"{path}: does not match required pattern")
        if "enum" in schema and value not in schema["enum"]:
            errors.append(f"{path}: must be one of {schema['enum']}")

    if expected == "array":
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path or '<root>'}: fewer than minItems {schema['minItems']}")
        items_schema = schema.get("items")
        if items_schema is not None:
            for i, item in enumerate(value):
                errors.extend(_validate_schema(item, items_schema, f"{path}[{i}]"))

    if expected == "object":
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected property: {key}")
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required property: {key}")
        for key, val in value.items():
            if key in props:
                errors.extend(_validate_schema(val, props[key], f"{path}.{key}" if path else key))

    return errors


def validate_structure(data, schema):
    errors = _validate_schema(data, schema, "")
    return errors[0] if errors else None


# --- loading -----------------------------------------------------------------


def _load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_open_records(path):
    """Return {full_id: record} from JSONL open-set records. A malformed
    line, or a record with no string `id`, is skipped, not fatal."""
    records = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
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
            if isinstance(rec_id, str):
                records[rec_id] = rec
    return records


# --- target resolution and rendering -----------------------------------------


def resolve_repo(target, registry):
    """An owner name resolves to its own repo; an external name or the
    literal "unowned" resolves to unowned.repo."""
    owners = registry["owners"]
    external = registry["external"]
    if target in owners:
        return owners[target]["repo"]
    if target in external or target == "unowned":
        return registry["unowned"]["repo"]
    raise FilingError(f"unknown target: {target!r}")


def target_display(target, registry):
    if target in registry["external"]:
        return f"{target} (external)"
    return target


def owner_labels_for(target, registry):
    owner = registry["owners"].get(target)
    return list(owner["labels"]) if owner else []


def compute_fix_now(cluster):
    """A model-set `fix_now` overrides the effort/confidence rule either
    way; otherwise papercut-fix-now applies when effort is low and
    confidence is high."""
    if "fix_now" in cluster:
        return bool(cluster["fix_now"])
    return cluster["effort"] == "low" and cluster["confidence"] == "high"


def render_title(cluster):
    return cluster["improvement"]


def render_body(cluster, repo, registry, open_records):
    lines = [
        cluster["improvement"],
        "",
        f"Target: {target_display(cluster['target'], registry)}",
        f"Repo: {repo}",
        f"Severity: {cluster['severity']} · Effort: {cluster['effort']} · Confidence: {cluster['confidence']}",
        "",
        "Source papercuts:",
    ]
    for pid in cluster["papercut_ids"]:
        title = open_records.get(pid, {}).get("title", "")
        lines.append(f"- {pid} — {title}" if title else f"- {pid}")

    fixes = []
    for pid in cluster["papercut_ids"]:
        rec = open_records.get(pid)
        fix = rec.get("suggested_fix") if rec else None
        if fix:
            fixes.append(fix)
    if fixes:
        lines.append("")
        lines.append(f"Suggested fix: {' '.join(fixes)}")

    return "\n".join(lines) + "\n"


def render_consolidation_comment(cluster, open_records):
    lines = ["**Consolidation:**", ""]
    for pid in cluster["papercut_ids"]:
        title = open_records.get(pid, {}).get("title", "")
        lines.append(f"- {pid} — {title}" if title else f"- {pid}")
    return "\n".join(lines) + "\n"


# --- gh seam ------------------------------------------------------------


def _gh_argv():
    gh_cmd = os.environ.get("PAPERCUT_GH_CMD", "gh")
    return shlex.split(gh_cmd)


def _stderr_tail(stderr, n=20):
    lines = stderr.splitlines()
    return "\n".join(lines[-n:])


def _run_gh(args):
    proc = subprocess.run(_gh_argv() + args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise FilingError(f"gh {' '.join(args[:2])} failed:\n{_stderr_tail(proc.stderr)}")
    return proc.stdout


def list_repo_labels(repo):
    stdout = _run_gh(["label", "list", "--repo", repo, "--json", "name", "--limit", "500"])
    return {item["name"] for item in json.loads(stdout)}


def _write_body_file(body):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(body)
        return f.name


def create_issue(repo, title, labels, body, apply):
    if not apply:
        return None
    body_path = _write_body_file(body)
    try:
        args = ["issue", "create", "--repo", repo, "--title", title]
        for label in labels:
            args += ["--label", label]
        args += ["--body-file", body_path]
        stdout = _run_gh(args)
    finally:
        os.unlink(body_path)
    return stdout.strip()


def comment_issue(issue_url, body, apply):
    if not apply:
        return
    body_path = _write_body_file(body)
    try:
        _run_gh(["issue", "comment", issue_url, "--body-file", body_path])
    finally:
        os.unlink(body_path)


# --- planning and filing -------------------------------------------------


def label_union(entries, registry):
    """entries: [(index, cluster), ...], all class == file, all resolving to
    one repo. Returns the ordered, deduped label list this run will CHECK
    for at that repo -- the union of every cluster's own write set (see
    cluster_labels). Never used as the label set an individual issue is
    filed with; that is cluster_labels' job."""
    severities_present = [s for s in SEVERITY_ORDER if any(c["severity"] == s for _, c in entries)]
    any_fix_now = any(compute_fix_now(c) for _, c in entries)

    owner_labels = []
    for _, c in entries:
        for label in owner_labels_for(c["target"], registry):
            if label not in owner_labels:
                owner_labels.append(label)

    labels = ["papercut"] + [f"priority:{s}" for s in severities_present]
    if any_fix_now:
        labels.append("papercut-fix-now")
    labels += owner_labels
    return labels


def cluster_labels(cluster, registry):
    """The label set THIS cluster's own issue is filed with: papercut,
    priority:<its severity>, papercut-fix-now only if this cluster itself
    qualifies, plus the owner's declared labels. Distinct from label_union,
    which is the wider set checked for at the repo (dev_docs/designs/
    2026-09-07-triage-and-route.md §4.3 step 2)."""
    labels = ["papercut", f"priority:{cluster['severity']}"]
    if compute_fix_now(cluster):
        labels.append("papercut-fix-now")
    for label in owner_labels_for(cluster["target"], registry):
        if label not in labels:
            labels.append(label)
    return labels


def cmd_render(index, clusters, registry, open_records):
    if index < 0 or index >= len(clusters):
        print(
            f"papercut_file.py: cluster index {index} is out of range (0..{len(clusters) - 1})",
            file=sys.stderr,
        )
        return 2
    cluster = clusters[index]
    repo = resolve_repo(cluster["target"], registry)
    print(render_title(cluster))
    print()
    print(render_body(cluster, repo, registry, open_records), end="")
    return 0


def cmd_plan(clusters, registry, open_records, tracked_data, apply):
    file_entries = [(i, c) for i, c in enumerate(clusters) if c.get("class") == "file"]
    consolidate_entries = [(i, c) for i, c in enumerate(clusters) if c.get("class") == "consolidate"]
    noop_count = sum(1 for c in clusters if c.get("class") == "noop")

    by_repo = {}
    for i, c in file_entries:
        repo = resolve_repo(c["target"], registry)
        by_repo.setdefault(repo, []).append((i, c))

    held_repos = {}
    for repo in sorted(by_repo):
        entries = by_repo[repo]
        required = label_union(entries, registry)
        existing = list_repo_labels(repo)
        missing = [label for label in required if label not in existing]
        if missing:
            held_repos[repo] = missing

    held = []
    for repo in sorted(held_repos):
        entries = by_repo[repo]
        held.append(
            {
                "repo": repo,
                "labels": held_repos[repo],
                "clusters": [
                    {"papercut_ids": c["papercut_ids"], "target": c["target"], "title": c["improvement"]}
                    for _, c in entries
                ],
            }
        )
        print(f"held    {repo}  missing={','.join(held_repos[repo])}  clusters={len(entries)}")

    filed = []
    for i, c in file_entries:
        repo = resolve_repo(c["target"], registry)
        if repo in held_repos:
            continue
        labels = cluster_labels(c, registry)
        title = render_title(c)
        body = render_body(c, repo, registry, open_records)
        url = create_issue(repo, title, labels, body, apply)
        filed.append(
            {
                "papercut_ids": c["papercut_ids"],
                "target": c["target"],
                "repo": repo,
                "title": title,
                "labels": labels,
                "url": url or "",
            }
        )
        line = f"file    {repo}  labels={','.join(labels)}  {title}"
        if url:
            line += f"  {url}"
        print(line)

    consolidated = []
    for i, c in consolidate_entries:
        repo = resolve_repo(c["target"], registry)
        body = render_consolidation_comment(c, open_records)
        comment_issue(c["issue"], body, apply)
        consolidated.append(
            {
                "papercut_ids": c["papercut_ids"],
                "target": c["target"],
                "repo": repo,
                "issue": c["issue"],
            }
        )
        print(f"consolidate  {c['issue']}  {c['improvement']}")

    print(f"noop    {noop_count}")

    if apply:
        write_manifest(filed, consolidated, held, noop_count, tracked_data.get("calls", {}))

    return 0


def write_manifest(filed, consolidated, held, noop_count, calls):
    triage_dir = os.path.expanduser(os.environ.get("PAPERCUT_TRIAGE_DIR") or "~/.claude/papercuts/triage")
    os.makedirs(triage_dir, exist_ok=True)
    run_date = datetime.date.today().isoformat()
    path = os.path.join(triage_dir, f"{run_date}.json")

    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    else:
        manifest = {}

    manifest["run_date"] = run_date
    manifest["filed"] = filed
    manifest["consolidated"] = consolidated
    manifest["held"] = held
    manifest["noop"] = noop_count
    manifest["calls"] = calls

    schema = load_schema("manifest.v1.json")
    err = validate_structure(manifest, schema)
    if err:
        raise FilingError(f"manifest failed schema validation: {err}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f)
        f.write("\n")


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(
            f"papercut_file.py: Python 3.11 or newer is required; this python3 is {found}",
            file=sys.stderr,
        )
        return 2

    parser = argparse.ArgumentParser(description="File triage clusters with their owners.")
    parser.add_argument("--clusters", required=True, metavar="FILE", help="enriched clusters JSON file")
    parser.add_argument("--owners", required=True, metavar="FILE", help="owners registry JSON file")
    parser.add_argument("--open", required=True, metavar="FILE", help="open-set JSONL file")
    parser.add_argument("--tracked", required=True, metavar="FILE", help="tracked index JSON file")
    parser.add_argument("--render", type=int, metavar="INDEX", help="print one cluster's title and body, and exit")
    parser.add_argument("--apply", action="store_true", help="file, comment, and write the manifest")
    args = parser.parse_args()

    try:
        clusters = _load_json(args.clusters)
        registry = _load_json(args.owners)
        open_records = load_open_records(args.open)
        tracked_data = _load_json(args.tracked)
    except (OSError, ValueError) as exc:
        print(f"papercut_file.py: {exc}", file=sys.stderr)
        return 2

    try:
        if args.render is not None:
            return cmd_render(args.render, clusters, registry, open_records)
        return cmd_plan(clusters, registry, open_records, tracked_data, args.apply)
    except FilingError as exc:
        print(f"papercut_file.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
