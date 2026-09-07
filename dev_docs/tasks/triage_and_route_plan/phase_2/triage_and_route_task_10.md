---
title: "/papercuts:reroute skill"
priority: medium
size: 2
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - skills/papercut/SKILL.md
  - docs/operations.md
is_blocked_by: [triage_and_route_task_8]
parent: triage_and_route
tags: [triage, skills, docs]
---

Part of [[../triage_and_route_plan]]. Design: §6.

## Context

Attended. Every branch is a judgment call the user makes; the skill's job is to show the issue, the ids, the registry's owners, and the dry-run plan, then run `papercut-reroute.sh --apply` on confirmation.

## Task

- New `skills/reroute/SKILL.md` → `/papercuts:reroute <issue-url> [--target <owner> | --wontfix | --out-of-scope <url> | --reported-upstream <url>]`:
  - No flag given: show the issue summary, the `pc_` ids, the owner list with `scope`, and ask which disposition (one `AskUserQuestion`).
  - Run the script dry; show the plan; confirm; run with `--apply`.
  - After a `--wontfix`/`--out-of-scope`/`--reported-upstream`, remind that resolutions are on the spool until `papercut-flush.sh` publishes them, and offer to run it (respecting the strict hold).
- `docs/operations.md`: "Reroute an issue" section, including draining the unowned pile after a triage run. Whichever of task 9 and this task lands second adds the cross-link between the two sections.

## Acceptance Criteria

- Code-enforced: `tests/docs-links.test.sh`, `dprint check` pass.
- User-run: reroute one real unowned issue to an owner with `--target` and confirm the source closes with a pointer and the new issue carries the ids.
