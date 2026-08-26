# papercuts

A Claude Code plugin that captures the small frictions ("papercuts") from your
sessions — automatically at session end and manually in the moment — into a
private, append-only, cross-machine git ledger, so they can be analyzed and
fixed instead of forgotten.

> **Records leave your machine.** Every captured record is pushed to a git repo
> you (or your team) own and control. Capture itself is local and offline, but
> the flusher commits and pushes the scrubbed records to that ledger repo on the
> next session start. The scrub is layered best-effort redaction — emails, IPs,
> tokens, keys, JWTs, PEM blocks, credentials in URLs, home paths — and a
> fail-closed denylist on hosts you mark strict. **It is syntactic, not
> semantic.** It cannot recognize an internal project name, a person, or a
> business fact. Make the ledger repo **private**. Before you point this at
> anything confidential, read [docs/install.md](docs/install.md) — and
> [docs/privacy.md](docs/privacy.md) for what the layered scrub does not
> cover.

## What a papercut is

A papercut is friction that cost you time or trust but is too small to file as a
bug: a task that took three prompts when it should have taken one, a tool that
failed in a confusing way, a permission prompt that stopped a routine command, a
rule in your instructions that was silent or contradictory. Individually each one
is noise. Collected across weeks, they show you exactly which parts of your setup
to fix.

Each record carries a `category` (`harness_config`, `instruction_gap`,
`model_behavior`, `project_dx`, `should_be_script`), a `severity`, a title, a
description, and an optional suggested fix, plus provenance the capture gate
constructs itself.

## Architecture

Two capture paths feed one local spool through a single trusted gate. An
opportunistic flusher syncs the spool to the ledger. A third, always-on path
records structural **anchors** the instant friction happens, so a session whose
`SessionEnd` never fires still has its acute friction rescued by a `SessionStart`
backstop sweep.

```
PostToolUseFailure ─┐
Notification       ─┴─▶ papercut-anchor.sh ──▶ anchors/<hash(session)>.jsonl
 (async, the instant     (recorder only,                    │
  friction happens)       no model)                         │ read by
                                                            ▼
SessionEnd ──▶ papercut-capture.sh ──▶ papercut_compact.py ──▶ extractor-run.sh
                (idempotency, triviality      (deterministic,    (claude -p
                 filter, concurrency cap)      budget-bound)      --model haiku)
                                                                       │
/papercuts:papercut skill ─────────────────────────────────────────────┤
 (manual, no model call)                                               ▼
                                                        papercut_append.py
                                                             THE GATE
                                                  construct → validate → scrub
                                                   → denylist → append
                                                               │
SessionStart ──▶ papercut-sweep.sh                             ▼
 (backstop for sessions whose            ~/.claude/papercuts/spool.jsonl
  SessionEnd never fired; owns                                 │
  the anchors sidecar lifecycle)                               │
                                                               ▼
SessionStart ──▶ papercut-flush.sh ──▶ claim → group by month → publish
                                                               │
                                                               ▼
                                        your ledger repo: ledger/YYYY-MM.jsonl
```

The gate is the only writer. It constructs every controlled field (`id`, `v`,
`producer`, `ts`, `machine`, `source`, `session_id`, `repo`) itself, so neither a
caller nor model output can spoof provenance. Callers pass descriptive fields
only.

## What it does

- Records a content-light anchor on every failed tool call and permission prompt,
  synchronously with the friction, independent of session end.
- Extracts papercuts from the session transcript at `SessionEnd` with a bounded,
  tool-less `claude -p --model haiku` call over a deterministically compacted
  transcript.
- Accepts manual captures through the `/papercuts:papercut` skill, which composes
  descriptive text and pipes it to the same gate. No model call, no network.
- Validates every record against a checked-in JSON Schema, scrubs free-text
  fields, and appends one JSONL line under a lock shared with the flusher.
- On hosts you mark strict: requires a populated, non-world-readable denylist,
  rejects whole any record whose pre-redaction text matches a literal, and drops
  `repo` and `session_id` from the stored record.
- Publishes month-grouped batches to your ledger repo, offline-safe, throttled,
  and non-blocking. Malformed lines are quarantined locally, never published and
  never silently dropped.

## What it does not do

- **It does not guarantee confidentiality.** The scrub is syntactic. Passing the
  adversarial scrub tests proves pattern coverage, never semantic privacy.
- **It does not triage.** The ledger holds raw records only. Deciding what to fix
  happens in whatever tracker you already use.
- **It does not host anything.** You create and own the ledger repo. There is no
  service, no account, and no third party besides your git host and the model
  call.
- **It does not grant itself permissions.** The append-gate permission rule and
  the sandbox write-allowlist paths are yours to add. See
  [docs/install.md](docs/install.md).
- **It does not block or slow a session.** Every hook is async and fail-silent. A
  broken install loses captures; it never breaks your session.
- **It does not read your ledger to capture.** Capture is offline and clone-less.
  Only the flusher touches the network.

## Five-minute quickstart

[docs/install.md](docs/install.md) is the full path, with the reasoning. The
short version:

**1. Install the plugin.**

```sh
/plugin marketplace add https://github.com/bestdan/papercuts-plugin.git
/plugin install papercuts@papercuts-plugin
```

Or clone it and load it with `--plugin-dir` instead:

```sh
git clone https://github.com/bestdan/papercuts-plugin.git ~/src/papercuts-plugin
claude --plugin-dir ~/src/papercuts-plugin
```

**2. Create a private ledger repo and clone it.**

```sh
gh repo create you/papercuts-ledger --private
git clone git@github.com:you/papercuts-ledger.git ~/src/papercuts
```

**3. Write the config.**

```sh
mkdir -p ~/.config/papercuts
cat >~/.config/papercuts/config.toml <<'TOML'
[ledger]
repo = "you/papercuts-ledger"
TOML
```

**4. Add the permission rule and the sandbox paths** to your own
`settings.json`. Both are user-scope policy a plugin must not grant itself; the
exact entries and why they are needed are in
[docs/install.md](docs/install.md).

**5. Verify.**

```sh
~/src/papercuts-plugin/scripts/papercut-doctor.sh
```

It prints one PASS/FAIL line per check and finishes by printing the permission
entry with the absolute path of your install already resolved. Paste that line
rather than guessing the path.

Then run `/papercuts:papercut` in a session to log your first record by hand.

## Documentation

- [docs/install.md](docs/install.md) — full install and verification guide.
- [docs/privacy.md](docs/privacy.md) — the layered scrub, the strict-profile
  staged rollout, and what remains possible. Read it before you point this at
  confidential work.
- [docs/configuration.md](docs/configuration.md) — every config key and
  environment variable, with defaults.
- [docs/operations.md](docs/operations.md) — the runbook: inspect the spool,
  recover a quarantined line or a stale batch, force a flush or a sweep, read
  the logs.
- [docs/architecture.md](docs/architecture.md) — what each component owns, the
  decisions with their reasons, and the sweep's residual risk.
- [docs/schema.md](docs/schema.md) — the record shape field by field, the
  resolution statuses, and the fold that computes the open set.
- [docs/schema-compat.md](docs/schema-compat.md) — the reader contract every
  consumer of the records is bound by.
- [CONTRIBUTING.md](CONTRIBUTING.md) — dev setup and the test requirement for
  changes to the gate.

## License

MIT. See [LICENSE](LICENSE).
