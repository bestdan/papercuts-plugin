---
title: "papercut-reroute.sh: the four attended dispositions"
priority: medium
size: 5
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut-resolve.sh
  - scripts/papercut_file.py
is_blocked_by: [triage_and_route_task_4]
parent: triage_and_route
tags: [triage, scripts, github, ledger]
---

Part of [[../triage_and_route_plan]]. Design: §6.

## Context

Reroute is the route layer run attended on one issue. `--target` re-files through `papercut_file.py`'s template and pre-flight — never `gh issue transfer`. The three other flags close and resolve. `papercut-resolve.sh` requires a URL for `out-of-scope` and `reported-upstream` and rejects a bare one; `--force` does not waive it.

## Task

- New `scripts/papercut-reroute.sh <issue-url> (--target <owner> | --wontfix | --out-of-scope <url> | --reported-upstream <url>) [--apply]`:
  - Reads the issue (`gh issue view --json`) and extracts every `pc_` id from body and comments.
  - `--target`: builds one **already-enriched** cluster (`class: file`, `papercut_ids` with full ids, `improvement` = title, `target` = owner, `severity` from the source's `priority:*` label — a source with none is a usage error naming the label, or takes an explicit `--severity`; `fix_now` true iff the source carries `papercut-fix-now`) and passes it straight to `papercut_file.py` — never through `validate-clusters`, which would see every id as tracked on the source and classify the cluster `noop`. Folds `**Consolidation:**` comments into the new body, runs pre-flight + create, then closes the source `not planned` with a comment `Re-filed as <url>`. No ledger write.
  - `--wontfix`: `gh issue close --reason "not planned"` + `papercut-resolve.sh <id> wontfix` per id.
  - `--out-of-scope <url>` / `--reported-upstream <url>`: close with a pointer comment + `papercut-resolve.sh <id> <status> <url>` per id.
  - Dry run by default; `--apply` writes. Prints what it will do per id.
- `tests/papercut-reroute.test.sh`: ids extracted from body and a consolidation comment; `--target` hands `papercut_file.py` (stub) a cluster with `class: file` and closes with the new URL; `--wontfix` resolves each id and closes; `--out-of-scope` without a URL is a usage error; a source with no `priority:*` label and no `--severity` is a usage error; `papercut-fix-now` on the source sets `fix_now`; no writes without `--apply`.

## Acceptance Criteria

- Code-enforced: per-flag tests as above; a test that `--target` writes no ledger resolution.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
