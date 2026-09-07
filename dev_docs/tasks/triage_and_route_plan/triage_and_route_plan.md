---
type: epic
title: Triage and route — implement the owners-registry design
status: active
owner: bestdan
created: 2026-09-07
---

# Triage and route

Implements [`dev_docs/designs/2026-09-07-triage-and-route.md`](../../designs/2026-09-07-triage-and-route.md). Read the design first; task cards cite its sections and do not restate them.

## Goal

Move papercut triage into the plugin and file each improvement in the repo that owns it, so the cross-repo backlog in `bestdan/dotfiles` stops growing. Deterministic, tested scripts do every write; the model answers two prompts whose output a script validates.

## Scope / non-goals

- No handler other than `gh-issue` (design §9).
- No PRs opened by triage (design §2).
- Job A / Job B for the existing 91 dotfiles issues: dotfiles#709, not here.
- Retiring `agents/papercuts-triage.md` in dotfiles: a dotfiles change, after this plan ships.
- Setup-time prompting for label provisioning: follow-up, named in design §5.

## Approach

Model proposes, script disposes (design §4). Eight scripts, each with a `tests/<name>.test.sh` and a `PAPERCUT_GH_CMD` seam so tests run offline against fixtures. Two thin skills sequence the scripts. Tradeoff: more scripts than a single prompt would need, bought for the property that every GitHub and ledger write is reproducible from a JSON file a test can check.

## Tasks

Phase 1 — scripts (each independently mergeable; the order is the data flow):

1. [phase_1/triage_and_route_task_1.md](phase_1/triage_and_route_task_1.md) — `papercut_owners.py`: registry reader and validator, plus `owners.toml` docs.
2. [phase_1/triage_and_route_task_2.md](phase_1/triage_and_route_task_2.md) — `papercut_tracked.py`: the tracked index across registered repos.
3. [phase_1/triage_and_route_task_3.md](phase_1/triage_and_route_task_3.md) — `papercut_clusters.py`: validate `clusters.json` and `consolidations.json`, compute severity, classify by the index.
4. [phase_1/triage_and_route_task_4.md](phase_1/triage_and_route_task_4.md) — `papercut_file.py`: label pre-flight, body template, filing, consolidation comments, the manifest and its schema.
5. [phase_1/triage_and_route_task_5.md](phase_1/triage_and_route_task_5.md) — `papercut_fixed.py`: merged-PR closer detection, `fixed` resolutions, profile-gated flush.
6. [phase_1/triage_and_route_task_6.md](phase_1/triage_and_route_task_6.md) — `papercut_summary.py`: the one-line summary from the manifest.
7. [phase_1/triage_and_route_task_7.md](phase_1/triage_and_route_task_7.md) — `papercut-labels.sh` and the doctor `owners` check.
8. [phase_1/triage_and_route_task_8.md](phase_1/triage_and_route_task_8.md) — `papercut-reroute.sh`: the four attended dispositions.

Phase 2 — skills and docs:

9. [phase_2/triage_and_route_task_9.md](phase_2/triage_and_route_task_9.md) — `/papercuts:triage` skill, operations doc, README.
10. [phase_2/triage_and_route_task_10.md](phase_2/triage_and_route_task_10.md) — `/papercuts:reroute` skill.

Phase 3 — rollout:

11. [phase_3/triage_and_route_task_11.md](phase_3/triage_and_route_task_11.md) — `owners.toml` in `bestdan/papercuts-ledger`, label provisioning, first dry run.
12. [phase_3/triage_and_route_task_12.md](phase_3/triage_and_route_task_12.md) — graduate durable notes into `dev_docs/triage.md` and delete this plan folder.

## Open questions

- Task 2: whether one paged `gh issue list --json body,comments` covers consolidation comments, which would remove the search API from the index entirely, is unmeasured; so is OR-batching of `pc_` prefixes in search. The task's first step is a two-part probe that settles both, and the design gets a one-line correction either way.
- Task 4: the issue body template is a contract with every later run. Should the body also carry a machine-readable footer (an HTML comment with the JSON of ids), or is the human-readable `pc_` list enough? Recommendation: the visible list only — an HTML comment is one more thing the search index may not tokenize.
- Task 11: `owners.toml` lives in another repo, and the workflow-skills handler flip in a third. Both are tracked here because the design is here; the commits land there.
