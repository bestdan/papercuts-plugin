---
title: "Graduate durable notes to dev_docs/triage.md and delete the plan folder"
priority: low
size: 1
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - dev_docs/designs/2026-09-07-triage-and-route.md
  - docs/architecture.md
is_blocked_by: [triage_and_route_task_11]
parent: triage_and_route
tags: [triage, cleanup]
---

Part of [[../triage_and_route_plan]].

## Context

`dev_docs/tasks/` holds live scaffolding only. The dated design stays (a dated file is a snapshot); the plan folder does not.

## Task

- Write `dev_docs/triage.md`: the as-built shape — script pipeline, manifest location, the two prompts, what triage never does — plus any gotcha the rollout surfaced (OR-batching result, label provisioning order). Link the dated design for the reasoning; do not copy it.
- Delete `dev_docs/tasks/triage_and_route_plan/`.

## Acceptance Criteria

- Code-enforced: `tests/docs-links.test.sh`, `dprint check` pass.
- User-run: `eza dev_docs/tasks` shows no `triage_and_route_plan`.
