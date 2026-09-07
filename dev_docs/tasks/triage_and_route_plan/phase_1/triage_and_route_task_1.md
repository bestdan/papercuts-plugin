---
title: "papercut_owners.py: read and validate the owners registry"
priority: high
size: 3
status: new
created: 2026-09-07
source_branch: bestdan/papercut-refinement-design
related_files:
  - scripts/papercut_config.py
  - docs/configuration.md
  - tests/papercut_config.test.sh
is_blocked_by: []
parent: triage_and_route
tags: [triage, scripts]
---

Part of [[../triage_and_route_plan]]. Design: §3.

## Context

`scripts/papercut_config.py` is the model: the only reader of `config.toml`, stdlib `tomllib`, shell consumers `eval` its output, Python consumers import a function, hard error on a file that exists but cannot be parsed, defaults otherwise. `tests/papercut_config.test.sh` shows the test shape (bash, `tests/test_prelude.sh`, fixtures under `tests/fixtures/`).

The registry is `owners.toml` at the ledger repo root. The ledger clone path comes from `papercut_config.py` (`ledger.dir`, default `~/src/papercuts`), overridable with `PAPERCUT_LEDGER_DIR` as every other script does.

## Task

- New `scripts/papercut_owners.py`:
  - Locate `owners.toml` under the ledger dir; `PAPERCUT_OWNERS` env var overrides the path (tests use it).
  - Validate: each `owners.<name>` has `tracker` (must be `gh-issue`), `repo` (`owner/name`), `scope` (non-empty string); optional `labels` (array of strings). Each `external.<name>` has `repo` and `scope`, no `tracker`, no `labels`. `<name>` matches `^[a-z0-9][a-z0-9._-]*$`, is never `unowned`, and is unique across `owners` and `external`. `[unowned].repo` optional, default `ledger.repo`; error if neither is set.
  - Output: `--json` prints `{ "owners": {name: {...}}, "external": {name: {...}}, "unowned": {"repo": ...} }`; default prints one line per owner and per external target for humans. Exit 2 with a message on any validation error; a missing file is an error too — triage without a registry is not a run.
  - Python consumers import `load()`.
- `tests/papercut_owners.test.sh`: valid file; missing file; unknown tracker; missing `scope`; name `unowned`; a name in both `owners` and `external`; an `external` entry with `tracker` or `labels`; `unowned.repo` defaulting from config; bad TOML exits non-zero with nothing on stdout.
- `docs/configuration.md`: new section "Owners registry (`owners.toml`)" with the key table from design §3 and the `PAPERCUT_OWNERS` override in the env table.

## Acceptance Criteria

- Code-enforced: `tests/run-tests.sh` passes with the new suite; `dprint check` passes.
- Code-enforced: the test asserts that an unparseable registry exits non-zero and prints nothing on stdout.
- User-run: `python3 scripts/papercut_owners.py` against a hand-written `owners.toml` in the real ledger clone prints the owners.
