---
title: "papercut_file.py: pre-flight labels, render bodies, file issues, write the manifest"
priority: high
size: 5
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut-resolve.sh
  - docs/configuration.md
is_blocked_by: [triage_and_route_task_3]
parent: triage_and_route
tags: [triage, scripts, github]
---

Part of [[../triage_and_route_plan]]. Design: §4.3, §4.5, §5.

## Context

This is the only script in triage that creates GitHub issues. Its body template is the contract every later run's tracked index matches on, so the template has its own test. The issue body format in `agents/papercuts-triage.md` Step 6 (dotfiles) is the starting point: improvement, `Target repo:`, severity/effort/confidence, `Source papercuts:` one line per full `pc_` id, `Suggested fix:`.

`gh issue create` fails on an unknown label; the pre-flight turns that into a plan line before any write. Bodies go through `--body-file`, never `--body`.

## Task

- New `scripts/papercut_file.py`:
  - Input: enriched clusters (task 3), owners JSON, `--tracked <index.json>` (for its `calls` block only), manifest path (`PAPERCUT_TRIAGE_DIR`, default `~/.claude/papercuts/triage/`, file `<run-date>.json`). The enriched cluster's `class` is trusted as given: `papercut-reroute.sh` (task 8) hands in a cluster it classified itself.
  - Label pre-flight per owner: union of labels this run writes there (`papercut`, `priority:<severity>` values present, `papercut-fix-now` only if some cluster qualifies) ∪ the owner's `labels`. `gh label list --repo <r> --json name --limit 500` once per repo. Missing → mark every cluster for that owner `held` with the missing names; file nothing there.
  - `unowned` and every external name resolve to `unowned.repo`; the body's `Target:` line keeps the name, suffixed `(external)` for an external target.
  - Title: the `improvement` sentence (task 3 caps it at 120 chars). Render: fixed body template in the script; `--render <cluster-index>` prints one title and body for inspection.
  - Dry run by default: prints the plan (per cluster: action, owner repo, labels, title). `--apply`: `consolidate` → `gh issue comment` with the `**Consolidation:**` block; `file` → `gh issue create --repo <r> --title … --label … --body-file <tmp>` serially, recording the URL.
  - Manifest: this task ships `schema/manifest.v1.json` (JSON Schema for the whole run manifest — `run_date`, `filed[]`, `consolidated[]`, `held[]`, `noop`, `resolved[]`, `skipped[]`, `closed_without_evidence[]`, `flush`, `calls`) and validates against it on every write. Appends `{filed, consolidated, held: [{owner, labels, clusters}], noop, calls}` merged into the run file, `calls` copied from the tracked index; creates the file if absent. Task 5 writes its sections against the same schema; task 6 only renders.
  - An enriched cluster may carry `fix_now: bool` directly; when present it wins over the effort/confidence rule, so reroute (task 8) need not invent effort or confidence.
- `tests/papercut_file.test.sh` with the `PAPERCUT_GH_CMD` stub: title and body golden file; manifest validates against the schema; a held owner files nothing and records the names; `--apply` issues one `gh issue create` per `file` cluster in order; consolidation comment content; `--body-file` used (assert no `--body` in the stub's log); manifest shape.
- `docs/configuration.md`: `PAPERCUT_TRIAGE_DIR`.

## Acceptance Criteria

- Code-enforced: golden-file test for the body; a test that a missing label holds the whole owner and writes nothing.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
- User-run: dry run against real clusters prints a plan you agree with before `--apply` is ever passed.
