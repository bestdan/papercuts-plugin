---
title: "papercut_clusters.py: validate the model's clusters and consolidations"
priority: high
size: 5
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut_open.py
  - schema/v1.json
is_blocked_by: [triage_and_route_task_2]
parent: triage_and_route
tags: [triage, scripts]
---

Part of [[../triage_and_route_plan]]. Design: §4.1, §4.2.

## Context

The model writes two JSON files; this script is the gate between them and any write. It refuses the whole file on the first failure so a half-valid file never files half a run. The closed target set is enforced here — the 2026-08-16 dotfiles run wrote one target four ways and split one improvement into three issues.

## Task

- New `scripts/papercut_clusters.py` with two subcommands:
  - `validate-clusters --open <open.json> --tracked <index.json> --owners <owners.json> clusters.json`:
    - every open id appears in exactly one cluster; no id outside the open set;
    - `target` ∈ owner names ∪ external names ∪ `{unowned}`; an external target resolves to `unowned.repo` at filing (task 4) but the name is kept on the cluster; `effort`, `confidence` ∈ `{low, medium, high}`; `improvement` non-empty, ≤ 120 chars;
    - computes `severity` = max over the cluster's records (`high > medium > low`);
    - classifies each cluster by the index, **counting only open issues**: `file` (no id tracked by an open issue), `noop` (every id tracked by an open issue), `consolidate` (mixed; sets `issue` to the open issue's URL; error if the open tracked issues span more than one). An id tracked only by closed issues counts as untracked here — after a `papercut-reroute.sh --target` the closed source and the open successor carry the same ids, and a span check over all states would refuse every such cluster forever. Closed issues still matter to the index (a consolidated id on a since-closed issue is still tracked); they just do not pick the consolidation target (design §4.2, last paragraph).
    - output: the enriched clusters as JSON on stdout; exit 2 with the first failure on stderr.
  - `candidates --owners <owners.json> --clusters <enriched.json>`: for each target repo that has at least one `file` cluster, lists open issues (`number, title, body, url`) through the seam and writes `candidates.json`. Bodies, not just titles — dotfiles triage records that the list endpoint truncates titles at ~80 chars. This keeps the listing in a tested script and the skill's `allowed-tools` script-only.
  - `validate-consolidations --clusters <enriched.json> --candidates <candidates.json> consolidations.json`: each entry names an existing cluster of class `file` and an issue present in `candidates.json` for the cluster's target repo; on success rewrites those clusters to class `consolidate`.
- Ship `schema/clusters.v1.json` and `schema/consolidations.v1.json` (JSON Schema) so the prompt can cite the shape and the validator checks structure before semantics.
- `tests/papercut_clusters.test.sh`: each rule above fails on a fixture that breaks only it; a valid fixture round-trips; severity max; mixed cluster → `consolidate` with the right issue; mixed across two open issues → error; ids on a closed source plus an open successor → `noop`, no error; `candidates` lists only repos with a `file` cluster (assert on the stub's call log).

## Acceptance Criteria

- Code-enforced: one failing fixture per validation rule, each asserting the rule's own message.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
