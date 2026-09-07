---
title: "Rollout: owners.toml in the ledger, labels provisioned, first dry run"
priority: high
size: 2
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - docs/configuration.md
is_blocked_by: [triage_and_route_task_7, triage_and_route_task_9, triage_and_route_task_10]
parent: triage_and_route
tags: [triage, rollout]
---

Part of [[../triage_and_route_plan]]. Design: §3, §5.

## Context

The registry lives in `bestdan/papercuts-ledger`, so its first version is a commit there, not here. Decided 2026-09-07 with the owner:

| Name               | Kind     | Repo                             | Notes                                                                  |
| ------------------ | -------- | -------------------------------- | ---------------------------------------------------------------------- |
| `dotfiles`         | owner    | `bestdan/dotfiles`               | workflow-skills schema labels                                          |
| `papercuts-ledger` | owner    | `bestdan/papercuts-ledger`       | also `unowned.repo`                                                    |
| `papercuts-plugin` | owner    | `bestdan/papercuts-plugin`       | this repo                                                              |
| `workflow-skills`  | owner    | `bestdan/workflow-skills`        | schema labels; tracker moves from Linear to GitHub Issues — see step 1 |
| `finplan`, `opx`   | owner    | `bestdan/finplan`, `bestdan/opx` | no extra labels                                                        |
| `claude-code`      | external | `anthropics/claude-code`         | was `harness` in dotfiles triage; the first externally owned target    |
| `aiutopilot`       | external | `bestdan/aiutopilot`             | tracks in Linear; no handler yet, so unowned until one exists          |

Names follow the repository name. `harness` is retired as a target name.

## Task

1. In `bestdan/workflow-skills`: flip `dev_docs/tasks/.task-config.yml` to `handler: gh-issue`, so `/promote-tasks` and `/do-tasks` there see filed issues. Without this, the largest routing group lands where no tooling reads it.
2. In `bestdan/papercuts-ledger`: `owners.toml` per the table, each entry with a one-sentence `scope`. PR there.
3. `scripts/papercut-labels.sh --all` then `--apply`, one owner at a time.
4. `scripts/papercut-doctor.sh` → `PASS: owners`.
5. `/papercuts:triage` dry run; read the plan; record in this task's PR (or the plan overview) any rule the clusters violated and how the prompt was adjusted.
6. Comment on bestdan/dotfiles#709 that triage with routing is live, so the interim widened dedupe search in `papercuts-triage.md` can be retired, and that `harness` is now `claude-code` in the target vocabulary.

## Acceptance Criteria

- User-run: doctor passes `owners`; a dry run prints a plan with zero `held` owners.
- User-run: the first `--apply` run files issues only in registered repos or the ledger repo; spot-check three.
