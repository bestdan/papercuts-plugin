---
title: "papercut-labels.sh and the doctor owners check"
priority: medium
size: 3
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut-doctor.sh
  - tests/papercut-doctor.test.sh
  - docs/operations.md
is_blocked_by: [triage_and_route_task_1]
parent: triage_and_route
tags: [triage, scripts, labels]
---

Part of [[../triage_and_route_plan]]. Design: §5.

## Context

Provisioning is attended and is the one place labels get created. `papercut-doctor.sh` prints `PASS`/`FAIL` per check, reads state only, and never publishes — the new check keeps that contract. `gh label create --force` updates rather than errors on an existing label.

## Task

- New `scripts/papercut-labels.sh <owner>|--all [--apply]`:
  - Reads the registry through `papercut_owners.py --json`.
  - Required set per owner: `papercut`, `priority:high`, `priority:medium`, `priority:low`, `papercut-fix-now`, plus the owner's `labels`. (Full plugin vocabulary here, unlike the per-run pre-flight: provisioning once is the point.)
  - Default: prints missing labels per owner. `--apply`: one `gh label create <name> --repo <r> --force` per missing label, serially, through the `PAPERCUT_GH_CMD` seam.
- `papercut-doctor.sh`: new `owners` check. Absent registry → `PASS: owners: no registry at <path>; triage not configured` (a capture-only install is valid, and task 1's exit 2 on a missing file is for triage, not the doctor). Present but invalid → `FAIL` with the validator's message. Present and valid → each owner's required set exists in the target (one `gh label list` per repo through `PAPERCUT_GH_CMD`); `FAIL` names the owner and the missing labels and points at `papercut-labels.sh`. When `gh label list` itself exits non-zero (sandboxed, offline, no auth), the `FAIL` names that cause with the stderr tail and says to run unsandboxed — it never lists labels as missing on the strength of a failed call. PASS/FAIL stays the whole vocabulary. Never creates anything. The doctor's header env list gains `PAPERCUT_GH_CMD` and `PAPERCUT_OWNERS` (`tests/docs-config-vars.test.sh` diffs that list against `docs/configuration.md`).
- Tests: `tests/papercut-labels.test.sh` (missing set computed; `--apply` calls create once per missing label; nothing without `--apply`); extend `tests/papercut-doctor.test.sh` for the new check, and set a `PAPERCUT_GH_CMD` stub in every existing `run_doctor` invocation so no case can reach the network once a fixture registry is present.
- `docs/operations.md`: "Provision an owner's labels" section.

## Acceptance Criteria

- Code-enforced: the doctor test asserts no `gh label create` call is ever made by the doctor.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
