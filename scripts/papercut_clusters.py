#!/usr/bin/env python3
"""Validate the model's triage clustering output and file-candidate lookup.

dev_docs/designs/2026-09-07-triage-and-route.md §4.1-§4.2 describes three
steps, each its own subcommand:

  validate-clusters        Checks the model-written clusters.json against
                            schema/clusters.v1.json (structure) and then
                            against the open set, the tracked index, and the
                            owners registry (semantics), refusing the whole
                            file on the first failure. On success it prints
                            the clusters enriched with a script-computed
                            `severity` and `class` (and `issue` when
                            `class == "consolidate"`).

  candidates                For every target repo carrying at least one
                            `class: file` cluster, lists that repo's open
                            issues (number, title, body, url) through the
                            $PAPERCUT_GH_CMD seam, so the model's semantic
                            dedupe pass (§4.2) has something to compare
                            against.

  validate-consolidations   Checks the model-written consolidations.json
                            against schema/consolidations.v1.json and then
                            against the enriched clusters and the candidate
                            listing, refusing the whole file on the first
                            failure. On success it rewrites the named
                            clusters to `class: consolidate` and prints the
                            full, updated cluster array.

Structural validation is a hand-rolled, stdlib-only subset of JSON Schema
draft 2020-12 -- the same approach papercut_append.py uses for schema/v1.json,
generalized here to walk nested arrays and objects (both shipped schemas
describe a top-level array of objects).

GitHub access (candidates only) goes through $PAPERCUT_GH_CMD (default "gh"),
split with shlex.split -- the same seam papercut_tracked.py uses.

Requires Python 3.11+, same as papercut_tracked.py and papercut_owners.py.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys

SEVERITY_ORDER = ("high", "medium", "low")
ID_PREFIX_RE = re.compile(r"^pc_([0-9a-f]{8})")


class ClustersError(Exception):
    """A structural or semantic validation failure, or a gh call failure."""


# --- schema loading and the subset structural interpreter ------------------


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
    """Return a list of error strings, or [] on success. Each error names
    `path` (e.g. "[0].papercut_ids[1]"). Stops descending into a value whose
    type is already wrong."""
    errors = []
    expected = schema.get("type")
    if expected and not _type_ok(value, expected):
        return [f"{path or '<root>'}: expected {expected}"]

    if expected == "string":
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            errors.append(f"{path}: does not match required pattern")
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: longer than maxLength {schema['maxLength']}")
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
    """Return the first structural error string, or None."""
    errors = _validate_schema(data, schema, "")
    return errors[0] if errors else None


# --- shared loading helpers --------------------------------------------------


def _load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_open_records(lines):
    """Return {full_id: severity} from JSONL open-set records, mirroring
    papercut_tracked.load_open_prefixes -- a record with no well-formed
    "pc_" + 8-hex-char id is skipped, not fatal."""
    records = {}
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
        if not isinstance(rec_id, str) or not ID_PREFIX_RE.match(rec_id):
            continue
        records[rec_id] = rec.get("severity")
    return records


def resolve_repo(target, registry):
    """Map a cluster's target name to the repo it files into: an owner name
    resolves to its own repo; an external name or the literal "unowned"
    resolves to unowned.repo."""
    owners = registry["owners"]
    external = registry["external"]
    if target in owners:
        return owners[target]["repo"]
    if target in external or target == "unowned":
        return registry["unowned"]["repo"]
    raise ClustersError(f"unknown target: {target!r}")


# --- validate-clusters -------------------------------------------------------


def validate_clusters_semantics(clusters, open_severity, index, registry):
    """Return the first semantic error string, or None. Order matches
    dev_docs/designs/2026-09-07-triage-and-route.md §4.1: improvement length,
    effort/confidence vocabulary, target vocabulary, id membership, id span."""
    valid_targets = set(registry["owners"]) | set(registry["external"]) | {"unowned"}

    for i, cluster in enumerate(clusters):
        improvement = cluster["improvement"]
        if not improvement or len(improvement) > 120:
            return f"cluster {i}: improvement must be non-empty and at most 120 characters"

    for i, cluster in enumerate(clusters):
        if cluster["effort"] not in ("low", "medium", "high"):
            return f"cluster {i}: effort must be one of low, medium, high, got {cluster['effort']!r}"
        if cluster["confidence"] not in ("low", "medium", "high"):
            return f"cluster {i}: confidence must be one of low, medium, high, got {cluster['confidence']!r}"

    for i, cluster in enumerate(clusters):
        if cluster["target"] not in valid_targets:
            return f"cluster {i}: target {cluster['target']!r} is not a known owner, external target, or 'unowned'"

    for i, cluster in enumerate(clusters):
        for pid in cluster["papercut_ids"]:
            if pid not in open_severity:
                return f"cluster {i}: papercut id {pid!r} is not in the open set"

    assigned = {}
    for i, cluster in enumerate(clusters):
        for pid in cluster["papercut_ids"]:
            if pid in assigned:
                return f"papercut id {pid!r} appears in more than one cluster (cluster {assigned[pid]} and cluster {i})"
            assigned[pid] = i

    for pid in open_severity:
        if pid not in assigned:
            return f"open papercut id {pid!r} is not assigned to any cluster"

    return None


def enrich_cluster(cluster, open_severity, index):
    ranked = [open_severity.get(pid) for pid in cluster["papercut_ids"]]
    ranked = [s for s in ranked if s in SEVERITY_ORDER]
    severity = min(ranked, key=SEVERITY_ORDER.index) if ranked else "low"

    tracked = {}
    for pid in cluster["papercut_ids"]:
        prefix = f"pc_{pid[3:11]}"
        entries = index.get(prefix, [])
        tracked[pid] = [e for e in entries if e.get("state") == "OPEN"]

    tracked_ids = [pid for pid, entries in tracked.items() if entries]
    untracked_ids = [pid for pid, entries in tracked.items() if not entries]

    out = {
        "improvement": cluster["improvement"],
        "papercut_ids": cluster["papercut_ids"],
        "target": cluster["target"],
        "effort": cluster["effort"],
        "confidence": cluster["confidence"],
        "severity": severity,
    }

    if not tracked_ids:
        out["class"] = "file"
        return out, None
    if not untracked_ids:
        out["class"] = "noop"
        return out, None

    urls = sorted({e["url"] for pid in tracked_ids for e in tracked[pid]})
    if len(urls) > 1:
        return None, f"tracked ids span more than one open issue: {', '.join(urls)}"
    out["class"] = "consolidate"
    out["issue"] = urls[0]
    return out, None


def cmd_validate_clusters(args):
    try:
        data = _load_json(args.clusters_file)
    except (OSError, ValueError) as exc:
        print(f"papercut_clusters.py: {args.clusters_file}: {exc}", file=sys.stderr)
        return 2

    schema = load_schema("clusters.v1.json")
    struct_err = validate_structure(data, schema)
    if struct_err:
        print(f"papercut_clusters.py: {args.clusters_file}: {struct_err}", file=sys.stderr)
        return 2
    clusters = data

    with open(args.open, "r", encoding="utf-8") as f:
        open_severity = load_open_records(f)

    try:
        tracked_data = _load_json(args.tracked)
        registry = _load_json(args.owners)
    except (OSError, ValueError) as exc:
        print(f"papercut_clusters.py: {exc}", file=sys.stderr)
        return 2
    index = tracked_data["index"]

    sem_err = validate_clusters_semantics(clusters, open_severity, index, registry)
    if sem_err:
        print(f"papercut_clusters.py: {sem_err}", file=sys.stderr)
        return 2

    enriched = []
    for i, cluster in enumerate(clusters):
        out, err = enrich_cluster(cluster, open_severity, index)
        if err:
            print(f"papercut_clusters.py: cluster {i}: {err}", file=sys.stderr)
            return 2
        enriched.append(out)

    print(json.dumps(enriched))
    return 0


# --- candidates ---------------------------------------------------------


def _gh_argv():
    gh_cmd = os.environ.get("PAPERCUT_GH_CMD", "gh")
    return shlex.split(gh_cmd)


def _stderr_tail(stderr, n=20):
    lines = stderr.splitlines()
    return "\n".join(lines[-n:])


def list_open_issues(repo):
    proc = subprocess.run(
        _gh_argv() + ["issue", "list", "--repo", repo, "--state", "open", "--json", "number,title,body,url", "--limit", "1000"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise ClustersError(f"gh issue list --repo {repo} failed:\n{_stderr_tail(proc.stderr)}")
    issues = json.loads(proc.stdout)
    return sorted(issues, key=lambda issue: issue["number"])


def cmd_candidates(args):
    try:
        registry = _load_json(args.owners)
        clusters = _load_json(args.clusters)
    except (OSError, ValueError) as exc:
        print(f"papercut_clusters.py: {exc}", file=sys.stderr)
        return 1

    repos = set()
    for cluster in clusters:
        if cluster.get("class") == "file":
            try:
                repos.add(resolve_repo(cluster["target"], registry))
            except ClustersError as exc:
                print(f"papercut_clusters.py: {exc}", file=sys.stderr)
                return 1

    result = {}
    try:
        for repo in sorted(repos):
            result[repo] = list_open_issues(repo)
    except ClustersError as exc:
        print(f"papercut_clusters.py: {exc}", file=sys.stderr)
        return 1

    output = json.dumps(result)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(output)
    else:
        print(output)
    return 0


# --- validate-consolidations ----------------------------------------------


def validate_consolidations_semantics(consolidations, clusters, candidates, registry):
    """Return the first semantic error string, or None."""
    seen = set()
    for entry in consolidations:
        ci = entry["cluster"]
        if not isinstance(ci, int) or ci < 0 or ci >= len(clusters):
            return f"cluster index {ci!r} is out of range (0..{len(clusters) - 1})"
        if ci in seen:
            return f"cluster {ci} is named more than once"
        seen.add(ci)

        cluster = clusters[ci]
        if cluster.get("class") != "file":
            return f"cluster {ci} is class {cluster.get('class')!r}, not 'file'"

        repo = resolve_repo(cluster["target"], registry)
        issue = entry["issue"]
        repo_candidates = candidates.get(repo, [])
        if not any(c["url"] == issue for c in repo_candidates):
            return f"cluster {ci}: issue {issue!r} is not among the candidates for {repo}"

    return None


def cmd_validate_consolidations(args):
    try:
        data = _load_json(args.consolidations_file)
    except (OSError, ValueError) as exc:
        print(f"papercut_clusters.py: {args.consolidations_file}: {exc}", file=sys.stderr)
        return 2

    schema = load_schema("consolidations.v1.json")
    struct_err = validate_structure(data, schema)
    if struct_err:
        print(f"papercut_clusters.py: {args.consolidations_file}: {struct_err}", file=sys.stderr)
        return 2
    consolidations = data

    try:
        clusters = _load_json(args.clusters)
        candidates = _load_json(args.candidates)
        registry = _load_json(args.owners)
    except (OSError, ValueError) as exc:
        print(f"papercut_clusters.py: {exc}", file=sys.stderr)
        return 2

    try:
        sem_err = validate_consolidations_semantics(consolidations, clusters, candidates, registry)
    except ClustersError as exc:
        print(f"papercut_clusters.py: {exc}", file=sys.stderr)
        return 2
    if sem_err:
        print(f"papercut_clusters.py: {sem_err}", file=sys.stderr)
        return 2

    updated = list(clusters)
    for entry in consolidations:
        ci = entry["cluster"]
        cluster = dict(updated[ci])
        cluster["class"] = "consolidate"
        cluster["issue"] = entry["issue"]
        updated[ci] = cluster

    print(json.dumps(updated))
    return 0


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(
            f"papercut_clusters.py: Python 3.11 or newer is required; this python3 is {found}",
            file=sys.stderr,
        )
        return 2

    parser = argparse.ArgumentParser(description="Validate triage clustering and consolidation output.")
    sub = parser.add_subparsers(dest="command", required=True)

    p_validate = sub.add_parser("validate-clusters", help="validate and enrich clusters.json")
    p_validate.add_argument("--open", required=True, metavar="FILE", help="open-set JSONL file")
    p_validate.add_argument("--tracked", required=True, metavar="FILE", help="tracked index JSON file")
    p_validate.add_argument("--owners", required=True, metavar="FILE", help="owners registry JSON file")
    p_validate.add_argument("clusters_file", metavar="clusters.json")
    p_validate.set_defaults(func=cmd_validate_clusters)

    p_candidates = sub.add_parser("candidates", help="list file-candidate issues per target repo")
    p_candidates.add_argument("--owners", required=True, metavar="FILE", help="owners registry JSON file")
    p_candidates.add_argument("--clusters", required=True, metavar="FILE", help="enriched clusters JSON file")
    p_candidates.add_argument("--out", metavar="FILE", help="write output here instead of stdout")
    p_candidates.set_defaults(func=cmd_candidates)

    p_consolidations = sub.add_parser("validate-consolidations", help="validate and apply consolidations.json")
    p_consolidations.add_argument("--clusters", required=True, metavar="FILE", help="enriched clusters JSON file")
    p_consolidations.add_argument("--candidates", required=True, metavar="FILE", help="candidates JSON file")
    p_consolidations.add_argument("--owners", required=True, metavar="FILE", help="owners registry JSON file")
    p_consolidations.add_argument("consolidations_file", metavar="consolidations.json")
    p_consolidations.set_defaults(func=cmd_validate_consolidations)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
