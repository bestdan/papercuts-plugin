# Configuration reference

Two mechanisms, with different jobs.

The **config file** carries the pipeline's identity and policy: which ledger to
publish to, and which machines are strict. It is the operator's reviewable trust
root, so it is the only place a value that widens trust may come from.

**Environment variables** override paths, tunables, and the seams the test
suite substitutes commands into. They are per-invocation and no environment
variable can make a machine less strict or add a trusted remote.

A minimal working config is three lines; see
[install.md](install.md#3-config-file). Read [privacy.md](privacy.md) before
you make a machine strict.

## Config file

Location, most specific first. When `PAPERCUT_CONFIG` is set and non-empty it
is the **sole** location — it never falls through to the others.

1. `$PAPERCUT_CONFIG`
2. `$XDG_CONFIG_HOME/papercuts/config.toml`
3. `~/.config/papercuts/config.toml`

`scripts/papercut_config.py` is the only reader. Shell consumers `eval` its
output; Python consumers import `resolve()` or `strict_hosts()`.

```toml
[ledger]
repo = "you/papercuts-ledger"
host = "github.com"
dir = "~/src/papercuts"
remote_url = "git@github.com:you/papercuts-ledger.git"

[profile]
strict_hosts = ["work-*"]
```

| Key                    | Type            | Default           | What it does                                                                                                                                                                                                                                                                     |
| ---------------------- | --------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ledger.repo`          | string          | none              | `owner/name`. Names the ledger for cloning, and with `ledger.host` builds the anchored origin allowlist: only `git@<host>:<repo>` and `https://<host>/<repo>` are accepted, both components regex-escaped.                                                                       |
| `ledger.host`          | string          | `github.com`      | Allowlist and clone host.                                                                                                                                                                                                                                                        |
| `ledger.dir`           | string          | `~/src/papercuts` | Local clone path. Tilde is expanded.                                                                                                                                                                                                                                             |
| `ledger.remote_url`    | string          | none              | A full remote URL, any scheme. Joins the origin allowlist as an **exact-match** trust anchor, for a remote the host/repo forms cannot express.                                                                                                                                   |
| `profile.strict_hosts` | array of string | `[]`              | Hostname glob patterns. A machine whose hostname matches any pattern resolves to the strict profile. Matched against the hostname's **first dot-separated label** only, case-insensitively — write `work-*`, not `work-*.example.com`, which contains a dot and can never match. |

Notes that bite:

- **The resolver always resolves.** A missing or partly-filled config exits 0
  with defaults. The one hard error, non-zero with nothing on stdout, is a
  config file that **exists** but cannot be parsed or holds a wrongly-typed
  value. That includes a `profile.strict_hosts` that is not an array of
  strings: a config meaning to add strictness must not read as "no patterns".
- **`profile.strict_hosts` can only add strictness.** The strict marker file's
  path (`~/.config/papercuts/strict`) is a hardcoded literal in
  `scripts/papercut_append.py`, and no config key names it. A key that looks
  like it does is ignored, like any other unknown key.
- **Publishing refuses without a ledger identity.** Invoked directly with the
  default publisher and neither `repo` nor `remote_url` resolvable,
  `papercut-flush.sh` exits non-zero before claiming anything. The
  `SessionStart` hook invokes it as `--hook`, which logs and exits 0 instead.
- Python 3.11 or newer is required, for stdlib `tomllib`.

## Environment variables

Every variable below is read by at least one script under `scripts/`. Defaults
in a `<spool dir>` form mean the directory holding the resolved spool file.

### Config resolver — `papercut_config.py`

| Variable          | Default                                                      | What it does                                                            |
| ----------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `PAPERCUT_CONFIG` | `~/.config/papercuts/config.toml` (after `$XDG_CONFIG_HOME`) | Config file path. When set and non-empty it is the only location tried. |

The resolver **emits** the six variables below on stdout for shell consumers to
`eval`. They are not meant to be set by hand — a value you export is simply
overwritten by the next `eval`. They are documented because the flusher and the
doctor read them by name.

| Variable                               | Value                                                  | Source                 |
| -------------------------------------- | ------------------------------------------------------ | ---------------------- |
| `PAPERCUT_CONFIG_LEDGER_REPO`          | `owner/name`, or empty                                 | `ledger.repo`          |
| `PAPERCUT_CONFIG_LEDGER_HOST`          | host, default `github.com`                             | `ledger.host`          |
| `PAPERCUT_CONFIG_LEDGER_DIR`           | clone path, default `~/src/papercuts`, tilde expanded  | `ledger.dir`           |
| `PAPERCUT_CONFIG_LEDGER_REMOTE_URL`    | exact-match trusted remote URL, or empty               | `ledger.remote_url`    |
| `PAPERCUT_CONFIG_LEDGER`               | `ok` when the ledger identity resolved, else `missing` | status line            |
| `PAPERCUT_CONFIG_PROFILE_STRICT_HOSTS` | the glob patterns, one per line                        | `profile.strict_hosts` |

Python consumers call `strict_hosts()` rather than splitting that last value:
command substitution strips trailing newlines, so the shell view of a list
whose last pattern is the empty string loses that entry.

### The gate — `papercut_append.py`

| Variable               | Default                             | What it does                                                                                                                                                      |
| ---------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PAPERCUT_SPOOL`       | `~/.claude/papercuts/spool.jsonl`   | The local spool. Created mode 0600 in a 0700 directory; an existing spool is tightened to 0600 on every append.                                                   |
| `PAPERCUT_LOCK`        | `<spool dir>/.spool.lock`           | The `fcntl.flock` file, separate from the spool and **shared with the flusher**. Do not change it for one side only.                                              |
| `PAPERCUT_SCHEMA`      | `schema/v1.json` next to the script | The JSON Schema every record is validated against, before and after the scrub.                                                                                    |
| `PAPERCUT_DENYLIST`    | `~/.config/papercuts/denylist.txt`  | Per-machine denylist. Required, non-empty, and not world-readable on a strict machine — see [privacy.md](privacy.md).                                             |
| `PAPERCUT_REVIEW_FILE` | unset, meaning no sidecar           | Scrub-review sidecar path. When set, the gate records the verbatim pre-redaction text of vocabulary-shaped `[token]` redactions there. Local-only, never flushed. |

### Auto capture — `papercut-capture.sh`

| Variable                   | Default                                                   | What it does                                                                                                                                                                                    |
| -------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PAPERCUT_EXTRACTOR_RUN`   | unset                                                     | Recursion guard. Set to `1` around the extractor call, so the `claude -p` subprocess's own `SessionEnd` cannot re-enter capture.                                                                |
| `PAPERCUT_PROCESSED_DIR`   | `~/.claude/papercuts/processed`                           | Idempotency markers and per-session locks. The sweep reads the same directory.                                                                                                                  |
| `PAPERCUT_MIN_TURNS`       | `6`                                                       | Triviality threshold on structurally-counted human turns. A session below it is skipped unless it had a tool error or a denial.                                                                 |
| `PAPERCUT_CAPTURE_LOCKDIR` | `~/.claude/papercuts/locks`                               | Holds the two concurrency-cap lock files. A third concurrent session skips.                                                                                                                     |
| `PAPERCUT_LOG`             | `~/.claude/papercuts/capture.log`                         | Metadata log, mode 0600. Never transcript content or model output.                                                                                                                              |
| `PAPERCUT_LOG_MAX_BYTES`   | `1048576`                                                 | Size cap. Capture truncates its log in place past this.                                                                                                                                         |
| `PAPERCUT_EXTRACTOR_CMD`   | `scripts/extractor-run.sh`                                | The extractor seam. Tests substitute a stub here.                                                                                                                                               |
| `PAPERCUT_APPEND_CMD`      | `python3 scripts/papercut_append.py`                      | The gate command.                                                                                                                                                                               |
| `PAPERCUT_ANCHORS_DIR`     | `~/.claude/papercuts/anchors`                             | Anchors sidecar directory. The same directory the anchor recorder and the sweep use.                                                                                                            |
| `PAPERCUT_ANCHORS`         | exported when this session has a sidecar, otherwise unset | Path to **this session's** anchors sidecar, so compaction can force-preserve anchored neighborhoods. Capture always exports or explicitly unsets it, so a stale inherited value cannot leak in. |
| `PAPERCUT_REVIEW_FILE`     | `~/.claude/papercuts/scrub-review.jsonl`                  | Capture exports this unconditionally, so an auto-captured over-redaction is recoverable. The manual path leaves it unset.                                                                       |

The gate's own overrides (`PAPERCUT_SPOOL`, `PAPERCUT_LOCK`,
`PAPERCUT_SCHEMA`, `PAPERCUT_DENYLIST`) are inherited from capture's
environment rather than re-declared.

### The extractor — `extractor-run.sh`

| Variable                     | Default                                    | What it does                                                                                                                                                                       |
| ---------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PAPERCUT_EXTRACTOR_PROMPT`  | `prompts/extractor-prompt.md`              | The system prompt file. It **replaces** the default Claude Code system prompt, never appends to it.                                                                                |
| `PAPERCUT_EXTRACTOR_SCHEMA`  | `scripts/extractor-schema.json`            | The structured-output schema for the model call.                                                                                                                                   |
| `PAPERCUT_EXTRACTOR_TIMEOUT` | `120`                                      | Process-group watchdog, in seconds.                                                                                                                                                |
| `PAPERCUT_CLAUDE_BIN`        | `claude`                                   | The CLI to invoke. Tests point it at a stub.                                                                                                                                       |
| `PAPERCUT_COMPACT_CMD`       | unset, runs `papercut_compact.py` directly | Override seam for the compaction step. Tests use it to stub or force-fail compaction.                                                                                              |
| `PAPERCUT_DETECT_CMD`        | unset, uses `detect_machine()`             | Overrides profile detection. Tests use it to force a profile; it cannot make a real machine less strict, because the marker and hostname checks are what it stands in for locally. |

### Compaction — `papercut_compact.py`

| Variable                        | Default  | What it does                                                                                                                                                                                                            |
| ------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PAPERCUT_COMPACT_BUDGET_BYTES` | `200000` | Maximum compacted-transcript size, in bytes, before the model call. The budget always wins; stage 3 never returns over-budget output. A non-numeric value is a `compaction failed` bug tripwire, not a transient error. |
| `PAPERCUT_ANCHORS`              | unset    | This session's anchors sidecar, read to force-keep anchored neighborhoods under budget pressure. A malformed file fails closed to "no anchors" rather than failing compaction.                                          |

### Anchor recorder — `papercut-anchor.sh`

| Variable               | Default                       | What it does                                                                         |
| ---------------------- | ----------------------------- | ------------------------------------------------------------------------------------ |
| `PAPERCUT_ANCHORS_DIR` | `~/.claude/papercuts/anchors` | Per-session anchor sidecars, `sha256(session_id).jsonl`, 0700 directory, 0600 files. |
| `PAPERCUT_ANCHOR_CAP`  | `50`                          | Maximum anchor lines per session file.                                               |

### Backstop sweep — `papercut-sweep.sh`

| Variable                      | Default                                  | What it does                                                                                                                                              |
| ----------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PAPERCUT_ANCHORS_DIR`        | `~/.claude/papercuts/anchors`            | The sidecars the sweep examines, deletes once processed, and prunes.                                                                                      |
| `PAPERCUT_PROCESSED_DIR`      | `~/.claude/papercuts/processed`          | Idempotency markers. The same directory capture uses.                                                                                                     |
| `PAPERCUT_PROJECTS_DIR`       | `~/.claude/projects`                     | Transcript search root.                                                                                                                                   |
| `PAPERCUT_SWEEP_QUIET_HOURS`  | `24`                                     | How long an anchors file **and** its transcript must be untouched before the sweep acts on that session.                                                  |
| `PAPERCUT_ANCHOR_TTL_DAYS`    | `7`                                      | How long a transcript-less anchors file survives before the sweep prunes it.                                                                              |
| `PAPERCUT_SWEEP_MAX_SESSIONS` | `5`                                      | Bound on non-self anchors files examined per run.                                                                                                         |
| `PAPERCUT_CAPTURE_CMD`        | `scripts/papercut-capture.sh`            | The capture seam the sweep drives.                                                                                                                        |
| `PAPERCUT_REVIEW_FILE`        | `~/.claude/papercuts/scrub-review.jsonl` | The scrub-review sidecar the sweep prunes. Pruned on every run, not only when an anchors file exists.                                                     |
| `PAPERCUT_REVIEW_TTL_DAYS`    | `30`                                     | How long an individual scrub-review entry survives. Longer than the anchor TTL on purpose: the point is reconstructing a record **after** it was flushed. |
| `PAPERCUT_LOG`                | `~/.claude/papercuts/capture.log`        | The same metadata log capture writes.                                                                                                                     |
| `PAPERCUT_LOG_MAX_BYTES`      | `1048576`                                | Size cap for that log.                                                                                                                                    |

The sweep is at-least-once, not duplicate-free. It cannot prove a resumable
transcript is final, only that it looks quiet — a session swept as done and
later resumed is re-extracted by capture's own content-hash idempotency. It
also only ever fires for sessions that left an anchor, so purely
conversational friction in a crashed session is never rescued. Both are
accepted scope boundaries.

### The flusher — `papercut-flush.sh`

| Variable                  | Default                                            | What it does                                                                                                                                                                                                                   |
| ------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `PAPERCUT_SPOOL`          | `~/.claude/papercuts/spool.jsonl`                  | The spool to claim.                                                                                                                                                                                                            |
| `PAPERCUT_LOCK`           | `<spool dir>/.spool.lock`                          | The lock shared with the gate. Held only across "check non-empty + rename to a unique batch name".                                                                                                                             |
| `PAPERCUT_BATCH_DIR`      | `<spool dir>`                                      | Where claimed `spool.batch.*` files live. Stale batches from a crash are recovered oldest-first.                                                                                                                               |
| `PAPERCUT_QUARANTINE_DIR` | `<batch dir>/quarantine`                           | Lines the flusher cannot use — non-JSON, non-object, missing or invalid `ts`, invalid UTF-8. Never published, never silently dropped.                                                                                          |
| `PAPERCUT_FLUSH_OK`       | `${XDG_CACHE_HOME:-~/.cache}/papercuts/flush-ok`   | Success stamp. Suppresses normal runs for about 24 hours.                                                                                                                                                                      |
| `PAPERCUT_FLUSH_FAIL`     | `${XDG_CACHE_HOME:-~/.cache}/papercuts/flush-fail` | Failure stamp. Suppresses normal runs for about 1 hour — a shorter backoff so transient publish failures retry sooner.                                                                                                         |
| `PAPERCUT_LOG`            | `<spool dir>/flush.log`                            | Metadata log, mode 0600.                                                                                                                                                                                                       |
| `PAPERCUT_LOG_MAX_BYTES`  | `1048576`                                          | Size cap. The flusher rotates to `.1` past this.                                                                                                                                                                               |
| `PAPERCUT_PUBLISH_CMD`    | `_papercut_publish_git`                            | The publish seam, called once per `YYYY-MM` group as `<cmd> <group-file> <YYYY-MM>`. A custom command replaces the git publisher entirely, so the ledger-identity refusal does not apply to it.                                |
| `PAPERCUT_LEDGER_DIR`     | `ledger.dir`, else `~/src/papercuts`               | Ledger clone path. Overrides `ledger.dir`.                                                                                                                                                                                     |
| `PAPERCUT_LEDGER_REMOTE`  | `ledger.remote_url`, else unset                    | Remote URL used when the clone is absent. Overrides `ledger.remote_url` as a **value only** — the resolved origin is still judged by the config-derived allowlist, so nothing env-settable can exempt a target from the check. |
| `PAPERCUT_DETECT_CMD`     | unset                                              | Overrides profile detection, as in the extractor.                                                                                                                                                                              |

`--force` bypasses both stamps and the strict-profile hold, but not the
"nothing to do" fast exit. `--review` prints the pending set read-only.
`--hook` maps every exit code to 0 after logging it.

### Doctor — `papercut-doctor.sh`

Read-only; it never publishes.

| Variable              | Default                              | What it does                                              |
| --------------------- | ------------------------------------ | --------------------------------------------------------- |
| `PAPERCUT_CONFIG`     | as above                             | Config file to check.                                     |
| `PAPERCUT_LEDGER_DIR` | `ledger.dir`, else `~/src/papercuts` | Clone whose origin URL is checked against the allowlist.  |
| `PAPERCUT_DENYLIST`   | `~/.config/papercuts/denylist.txt`   | Denylist whose state is checked against the profile.      |
| `PAPERCUT_SPOOL`      | `~/.claude/papercuts/spool.jsonl`    | Its dirname is the spool directory whose mode is checked. |
| `PAPERCUT_DETECT_CMD` | unset                                | Overrides profile detection.                              |

### Resolutions — `papercut-resolve.sh`, `papercut_open.py`

| Variable              | Default                              | What it does                                                               |
| --------------------- | ------------------------------------ | -------------------------------------------------------------------------- |
| `PAPERCUT_LEDGER_DIR` | `~/src/papercuts`                    | Ledger clone read for the `<pc_id>` existence check, and by the open fold. |
| `PAPERCUT_SPOOL`      | `~/.claude/papercuts/spool.jsonl`    | Local spool, read alongside the ledger.                                    |
| `PAPERCUT_APPEND_CMD` | `python3 scripts/papercut_append.py` | The gate command a resolution record is appended through.                  |

`papercut_open.py` is read-only: it reads `ledger/*.jsonl` and the spool and
never writes.

## Related

- [install.md](install.md) — install and verification.
- [privacy.md](privacy.md) — what the scrub covers and what it does not.
- [schema-compat.md](schema-compat.md) — the reader contract.
