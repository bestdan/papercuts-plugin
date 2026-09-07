---
title: "papercut_summary.py: manifest schema and the one-line run summary"
priority: medium
size: 2
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - schema/v1.json
is_blocked_by: [triage_and_route_task_4, triage_and_route_task_5]
parent: triage_and_route
tags: [triage, scripts]
---

Part of [[../triage_and_route_plan]]. Design: §4.5.

## Context

Tasks 4 and 5 each merge their section into one manifest file per run, validated against `schema/manifest.v1.json` (task 4). This task only renders the summary line the skill ends with, which a scheduled run's notification carries.

## Task

- New `scripts/papercut_summary.py <manifest>`: validates against the schema, then prints exactly one line:
  `Papercuts triage <date>: <N> improvements — <F> filed (<O> owners), <C> consolidated, <H> held (labels), <R> resolved, <U> unowned.`
  `--verbose` adds one line per held owner with its missing labels and one per closed-without-evidence issue — the material for `/papercuts:reroute`.
- `tests/papercut_summary.test.sh`: golden line from a fixture manifest; invalid manifest exits non-zero; `--verbose` lists held owners.

## Acceptance Criteria

- Code-enforced: golden-line test; an invalid manifest exits non-zero.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
