---
title: "papercut_fixed.py: resolve papercuts whose closing PR merged"
priority: high
size: 3
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut-resolve.sh
  - scripts/papercut-flush.sh:88
  - scripts/papercut_append.py
is_blocked_by: [triage_and_route_task_2, triage_and_route_task_4]
parent: triage_and_route
tags: [triage, scripts, ledger]
---

Part of [[../triage_and_route_plan]]. Design: §4.4.

## Context

A merged PR is the only evidence an unattended run may act on. `papercut-resolve.sh` refuses to double-resolve, so re-running is safe. `papercut-flush.sh --force` bypasses the strict-profile hold (header, lines 88–94), so the profile is checked first through the same detection seam flush uses (`PAPERCUT_DETECT_CMD` / `detect_machine()` in `papercut_append.py`).

## Task

- **First:** run the GraphQL query below once with `gh api graphql` against a dotfiles issue known to be closed by a merged PR, and save the response verbatim as the test fixture, so the fixture is a recording and not a guess about the schema.
- New `scripts/papercut_fixed.py`:
  - Input: the tracked index (task 2). Keeps issues with `state == closed`, **except** a closed issue every one of whose ids is also carried by an open issue in the index — that is a rerouted source (task 8), not a fix, and it would otherwise land in `closed_without_evidence` every week. Resolves use the entry's `full_id`; `papercut-resolve.sh` rejects a prefix.
  - Per closed issue, GraphQL through the `gh` seam: `timelineItems(itemTypes: CLOSED_EVENT) { nodes { ... on ClosedEvent { closer { __typename ... on PullRequest { merged url } ... on Commit { url } } } } }`. Evidence = a `PullRequest` closer with `merged: true`.
  - Evidence → `papercut-resolve.sh <id> fixed <pr-url>` for each id the issue carries (ids from the index); collect "already resolved" refusals as `skipped`.
  - No evidence → manifest `closed_without_evidence: [{url, state_reason, closer}]`. Every manifest write validates against `schema/manifest.v1.json` (task 4).
  - Profile gate: default profile → run `papercut-flush.sh --force`, capture its confirmation line into the manifest; strict → record `"flush": "held (strict profile)"` and do not call flush.
  - `--apply` gates the resolve and flush calls; default prints the plan.
- `tests/papercut_fixed.test.sh`: merged-PR closer resolves each id, and the resolve stub receives the full `pc_<uuid>`, never the prefix; a closed source whose ids are all on an open successor is skipped; unmerged PR closer → no evidence; commit closer → no evidence; `not planned` → no evidence; already-resolved refusal is `skipped`, not an error; strict profile skips flush (stub `PAPERCUT_DETECT_CMD`); default profile calls flush with `--force` exactly once.

## Acceptance Criteria

- Code-enforced: the strict-profile test asserts the flush stub was never called.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
