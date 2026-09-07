---
title: "papercut_tracked.py: the tracked index across registered repos"
priority: high
size: 5
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut_open.py
  - scripts/papercut-resolve.sh:38
  - docs/configuration.md
is_blocked_by: [triage_and_route_task_1]
parent: triage_and_route
tags: [triage, scripts, github]
---

Part of [[../triage_and_route_plan]]. Design: §4.0 item 3.

## Context

The index maps each open papercut's 8-character `pc_` prefix to the issues that carry it, across every registered repo plus the unowned repo. It is the seam that lets a routed issue take no ledger resolution (design §4.3), so a partial index is worse than a failed one.

Measured facts from dotfiles triage that are test cases here: the full UUID returns zero from issue search against issues that carry it; the 8-char prefix matches both full and truncated forms; consolidated ids live in `**Consolidation:**` comments, invisible to `in:body`.

`gh` is reached through a `PAPERCUT_GH_CMD` seam (default `gh`), the same pattern as `PAPERCUT_APPEND_CMD` in `scripts/papercut-resolve.sh:38`. Tests substitute a stub that replays fixture JSON.

## Task

- **First, a one-off probe** (not committed), against `bestdan/dotfiles`, in two parts. Record both results in the PR body.
  1. List with `gh issue list --state all --json number,body,comments` and check whether every known consolidated prefix appears in the returned comment bodies, and whether any issue's comment list is truncated. If the listing covers them, **drop the comment-search pass, the rate-limit handling and `PAPERCUT_SLEEP_CMD` from this card** and correct design §4.0: one paged listing is the whole index.
  2. Only if the listing falls short: compare `pc_aaaaaaaa OR pc_bbbbbbbb ... in:comments` for six known prefixes with six single-prefix queries. If OR-batching loses hits, use single queries and correct design §4.0 in the same PR.
- New `scripts/papercut_tracked.py`:
  - Input: open ids from `papercut_open.py --json` on stdin or `--open <file>`; registry from `papercut_owners.py --json`.
  - Body pass: `gh issue list --repo <r> --state all --limit <n> --json number,title,body,state,url,labels` per repo, paged; grep bodies for every prefix.
  - Comment pass: only for prefixes with no body hit. `gh search issues` exposes no response headers, so the pass goes through `gh api --include "search/issues?q=<prefixes>+repo:<r>+in:comments"` via the seam, batched as the probe decided; the script parses the header block before the JSON body, reads `X-RateLimit-Remaining`/`Retry-After`, and sleeps rather than fails.
  - Output `--json`: `{ "index": { "<prefix>": [ {repo, number, url, state, state_reason, labels, full_id, source: "body"|"comment"} ] }, "calls": {search: n, list: n} }`. `full_id` is the full `pc_<uuid>` from the open set, so downstream scripts never have to map a prefix back. `calls` feeds the manifest (task 4 copies it).
  - Deterministic ordering (repo, number).
- `tests/papercut_tracked.test.sh` with a stub `gh` that serves fixtures: prefix found in body; found only in comment; full-UUID query never issued (assert on the stub's call log); an issue in two states; the call count reported; a fixture response whose header block carries `Retry-After` triggers a sleep (stub the sleep via `PAPERCUT_SLEEP_CMD`); every index entry carries its `full_id`.
- `docs/configuration.md`: `PAPERCUT_GH_CMD`, `PAPERCUT_SLEEP_CMD` in the env table.

## Acceptance Criteria

- Code-enforced: the test asserts no query contains a full `pc_<uuid>`; the test asserts the comment search runs only for prefixes with no body hit.
- Code-enforced: `tests/run-tests.sh` and `dprint check` pass.
- User-run: `papercut_tracked.py` against the real registry finishes and prints `_calls`; compare a handful of prefixes to a manual `gh issue list` grep.
