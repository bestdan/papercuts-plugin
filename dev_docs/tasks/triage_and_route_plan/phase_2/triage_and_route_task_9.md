---
title: "/papercuts:triage skill, operations doc, README"
priority: high
size: 3
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - skills/papercut/SKILL.md
  - docs/operations.md
  - README.md:97
  - tests/docs-links.test.sh
is_blocked_by: [triage_and_route_task_6]
parent: triage_and_route
tags: [triage, skills, docs]
---

Part of [[../triage_and_route_plan]]. Design: §4, §7.

## Context

`skills/papercut/SKILL.md` is the pattern: frontmatter with `allowed-tools` naming the scripts, `${CLAUDE_PLUGIN_ROOT}` substituted at skill-load time, the skill composes and the scripts gate. The clustering rules move verbatim from `agents/papercuts-triage.md` Step 2 in dotfiles (cluster by friction, never by target or severity; target from the fix location, never from `repo`). `tests/docs-links.test.sh` checks links in docs.

## Task

- New `skills/triage/SKILL.md` → `/papercuts:triage [--apply]`. Steps, each a script call except two prompts:
  1. `papercut_open.py --json`, `papercut_owners.py --json`, `papercut_tracked.py` → files under `PAPERCUT_TRIAGE_DIR`. If the open set is empty, print the zero summary line and stop; neither prompt runs.
  2. **Prompt 1** (the model): cluster every open record into `clusters.json` per `schema/clusters.v1.json`; carries the rules above and the owner `scope` lines.
  3. `papercut_clusters.py validate-clusters`; on failure, fix the JSON and re-validate — never edit the validator's verdict.
  4. `papercut_clusters.py candidates` → `candidates.json`; **Prompt 2**: `consolidations.json`; `validate-consolidations`.
  5. `papercut_file.py` (dry run; `--apply` only when the skill was invoked with it).
  6. `papercut_fixed.py` (same gate).
  7. `papercut_summary.py`; end with its line.
  - `allowed-tools` lists the scripts; network calls need the sandbox escape, say so.
- `tests/triage-pipeline.test.sh`: the end-to-end dry run. Fixture ledger, fixture `owners.toml`, `gh` stub, a hand-written `clusters.json` and an empty `consolidations.json` standing in for the two prompts; runs open → owners → tracked → validate → candidates → validate → file (dry) → fixed (dry) → summary and asserts the summary line and zero write calls in the stub's log. This is the test that catches a JSON-shape mismatch between two scripts before a real run does.
- `docs/operations.md`: "Run triage" section — what it writes, what it never does (no PRs, no label creation, no resolutions except `fixed`), where the manifest is, what to do with `held` and `closed_without_evidence` (→ `/papercuts:reroute`, task 10).
- `README.md`: replace "It does not triage" with what it does and does not do: triages and routes to registered owners; never opens PRs; never refines.
- `docs/architecture.md`: one paragraph and a line in any component list for triage and the registry.

## Acceptance Criteria

- Code-enforced: `tests/triage-pipeline.test.sh` passes and asserts zero write calls; `tests/docs-links.test.sh`, `tests/docs-identity.test.sh`, `tests/run-tests.sh`, `dprint check` pass.
- User-run: `/papercuts:triage` without `--apply` on a real ledger clone prints a plan and a summary line, and writes nothing to GitHub or the ledger.
