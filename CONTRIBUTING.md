# Contributing

Small personal project. Issues and pull requests are welcome; keep them focused.

## Dev setup

No build step and no dependencies. The Python is pure stdlib and needs 3.11 or
newer. The shell is **bash 3.2 compatible** — macOS ships `/bin/bash` 3.2, so no
associative arrays, no `declare -A`, no `${var^^}`.

Run the suite:

```sh
bash tests/run-tests.sh
```

It discovers every `*.test.sh` in the repo and runs it. Every suite sources
`tests/test_prelude.sh` first, which pins `HOME`, the git config, and every
`PAPERCUT_*` variable, so a test result never depends on the machine it runs on.
New suites must source it too.

Format markdown and JSON before committing:

```sh
dprint fmt
dprint check
```

## Testing the gate, the scrub, and the denylist

**Required:** any change to the capture gate (`scripts/papercut_append.py`), the
scrub, or the denylist path must come with a test in the adversarial suite,
`tests/papercut_append.test.sh`. That suite is the only thing standing between a
regression and records leaving the machine with content that should have been
rejected or redacted. Its `adversarial:` assertions are the corpus that fires
many patterns at once and pins which cases the syntactic scrub deliberately does
_not_ catch.

Two adjacent suites cover the same surface from the outside and are worth
extending alongside it: `tests/papercut-capture.test.sh` for the auto-capture
path that runs the gate with stderr discarded, and
`tests/papercut-doctor.test.sh` for the denylist and profile checks the doctor
reports on.

A change that loosens the scrub or the denylist needs a test showing the new
behavior is intended, not just one showing the old test still passes.

## PR conventions

- Branch off `main`; never commit to it directly.
- [Conventional Commits](https://www.conventionalcommits.org/) for commit
  subjects and PR titles — `feat`, `fix`, `docs`, `refactor`, `test`, `chore`,
  with an optional scope: `fix(gate): ...`.
- Explain _why_ in the message, not _what_ — the diff already says what.
- The suite must pass, and `dprint check` must be clean.

## Internal notes

- [docs/plugin-surface.md](docs/plugin-surface.md) — the plugin-surface probe
  notes: which hook events actually reach a plugin, which path variables resolve,
  and what is still untested. Every answer there came from installing a throwaway
  probe plugin and observing the result, not from documentation. Read it before
  changing `hooks/hooks.json` or anything that depends on
  `${CLAUDE_PLUGIN_ROOT}`.
- [docs/schema-compat.md](docs/schema-compat.md) — the reader contract. Adding an
  optional field is safe; removing or renaming one is breaking and needs
  coordination across every install reading the ledger.
