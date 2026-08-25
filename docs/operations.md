# Operations runbook

One section per thing you might have to do once the pipeline is already
running. If the pipeline is not running yet, start at
[install.md](install.md); if you are deciding whether to point it at
confidential work, start at [privacy.md](privacy.md).

Commands are written as `scripts/…`, relative to your plugin checkout. Paths
are the defaults; every one of them has an environment-variable override listed
in [configuration.md](configuration.md). Nothing in this runbook needs to be
run on a schedule — the hooks do the routine work, and each section below is a
response to something specific.

Before anything else, when the install itself is in question:

```sh
scripts/papercut-doctor.sh
```

It prints one `PASS`/`FAIL` line per check (`config`, `ledger`, `denylist`,
`spool-perms`, `hooks`, `claude-path`), reads state only, and never publishes.

## Inspect the spool

The spool holds captured records that have not been published yet.

```sh
jq . <~/.claude/papercuts/spool.jsonl
```

An absent or empty file means nothing is pending. The spool is mode 0600 and
holds one JSON record per line, exactly as the gate wrote it — already
validated and already scrubbed.

For the pending set including any batch a previous flush left behind, prefer
the flusher's own read-only view, which is safe to run at any time on any
profile:

```sh
scripts/papercut-flush.sh --review
```

It pretty-prints the current spool plus every stray `spool.batch.*` file,
finishes with a count, and claims nothing, publishes nothing, and writes no
throttle stamp.

## Recover quarantined lines

A line the flusher cannot use is written to
`~/.claude/papercuts/quarantine/<batch-filename>` instead of being published.
A line is quarantined only for **structural** reasons: it does not parse as
JSON, it parses as something other than an object, or its `ts` is missing,
malformed, or not a real calendar time. An unknown field or an unknown `type`
value never quarantines anything — see
[schema-compat.md](schema-compat.md).

```sh
ls ~/.claude/papercuts/quarantine/
cat ~/.claude/papercuts/quarantine/spool.batch.*.jsonl
```

Quarantine files are named after the batch they came from and are rewritten,
not appended, each time that batch is processed — so the file is a snapshot of
one batch's bad lines, never a growing pile. Quarantined lines are never
published and never silently dropped, but they are also never retried: once
the batch's good lines publish, the batch file is deleted and the quarantine
file is all that is left.

**To recover the content, re-append it through the gate — never by editing the
spool.** Writing to `spool.jsonl` by hand bypasses validation, the syntactic
scrub, the denylist check, and the lock the flusher claims under. Instead, read
the quarantined line, recover the descriptive fields by eye, and hand them to
the gate:

```sh
python3 scripts/papercut_append.py \
  --source manual --producer requeue/1 --repo you/some-repo <<'JSON'
{"category":"harness_config","severity":"low",
 "title":"…","description":"…"}
JSON
```

Three things to know about that:

- The gate reads **only** the descriptive keys (`category`, `severity`,
  `title`, `description`, `suggested_fix`). It constructs `id`, `ts`,
  `machine`, and the rest itself, so the recovered record is a **new** record
  with a new id, timestamped now. The original timestamp cannot be preserved.
- `--repo` is required for a papercut on the default profile, and is dropped
  from the stored record on a strict one.
- On a strict profile the record passes the denylist gate like any other, so a
  recovered line whose text matches a literal is rejected whole rather than
  redacted.

If a quarantined line holds nothing worth recovering, delete it.

## Recover a stale batch

`spool.batch.<utc-timestamp>.<pid>.<token>.jsonl`, next to the spool, is a
**claimed** batch: the flusher renamed the spool to that name under the shared
lock, and has not finished publishing it. One exists when a run is in flight,
when a publish failed, or when a run was killed mid-flight.

No intervention is normally needed. Every flush globs `spool.batch.*` and
processes what it finds **oldest-first** alongside whatever it just claimed —
the filenames carry a zero-padded UTC timestamp, so sorting them lexically
sorts them chronologically. A batch is deleted only after every one of its
month-groups publishes successfully; any failure retains the whole file
untouched for the next run. Re-publishing a batch whose records already landed
is harmless: the publisher reconciles by record `id`.

Stale batches also defeat the success throttle on purpose, so a stranded batch
is never masked for a day by a `flush-ok` stamp from an earlier run.

Intervene when a batch is not draining across runs. Read why in the log:

```sh
tail -50 ~/.claude/papercuts/flush.log
scripts/papercut-flush.sh --force        # retry now, ignoring both stamps
```

A `retaining batch=…` line names the batch; the `publish:` line above it names
the reason — an untrusted origin URL, a clone that could not be made, a failed
fetch, a push that never confirmed, or a corrupt record id in the batch. Fix
that cause. The only reason to touch a batch file by hand is a batch whose
content you have decided to discard.

## Force a flush

```sh
scripts/papercut-flush.sh --force
```

`--force` bypasses exactly two things: the throttle stamps (the ~24h success
stamp and the ~1h failure stamp) and the strict-profile hold below. It does
**not** bypass the "nothing to do" fast exit — with an empty spool and no
stray batches the run still exits 0 immediately. `--force` does not manufacture
work.

It also does not bypass the ledger-identity gate. Run directly with the default
publisher and no resolvable `ledger.repo` or `ledger.remote_url`, the flusher
refuses and exits non-zero **before claiming anything**, so a broken config can
never strand a claimed batch. The `SessionStart` hook runs the same script as
`--hook`, which logs any non-zero exit and then exits 0 so a session is never
disrupted.

## Review before publish, on a strict profile

On a strict profile a normal (non-`--force`) run **holds** rather than
publishing. It logs `hold reason=strict-profile-review`, exits 0, and leaves
the spool and any stray batches untouched — no claim, no stamp write. That is
the designed state, not a failure: records that may describe confidential work
reach the ledger only after a human looks at them.

The flow is two commands:

```sh
scripts/papercut-flush.sh --review      # read-only: print every pending record
scripts/papercut-flush.sh --force       # publish the set you just vetted
```

`--review` prints the current spool plus every stray `spool.batch.*` file, one
pretty-printed record at a time (through `jq` when it is installed, otherwise
`python3 -m json.tool`), and claims, publishes, and stamps nothing. There is no
partial-approval mechanism: `--force` publishes everything pending, so discard
anything you do not want published before running it.

To discard a record, delete its whole line from `spool.jsonl` (or from the
stray `spool.batch.*` file that holds it) while no session and no flush is
running. This does not contradict the warning in
[Recover quarantined lines](#recover-quarantined-lines): that warning is about
**writing** records into the spool by hand, which bypasses the gate's
validate/scrub pipeline — deleting a whole line only removes content, and the
shared lock is held only across an append or a batch claim, so an idle-time
edit races with nothing.

If review turns up something that should never have survived capture, the fix
is not to keep reviewing more carefully — add the offending literal to the
denylist so the gate catches it next time:

```sh
umask 077
$EDITOR ~/.config/papercuts/denylist.txt   # one case-insensitive literal per line
chmod 0600 ~/.config/papercuts/denylist.txt
```

It takes effect on the next capture. On a strict profile a record whose
**pre-redaction** text matches any literal is rejected whole, not redacted, so
the literal has to be in the file before the record is captured — adding it now
does nothing for a record already sitting in the spool. Delete that record, or
accept publishing it. See
[privacy.md](privacy.md#3-the-fail-closed-denylist-gate) for what the denylist
does and does not cover, and
[install.md](install.md#the-denylist-on-a-strict-host) for the file's
requirements.

The default profile is unaffected by all of this: a normal run there publishes.

## Inspect and rotate logs

Two logs, both mode 0600, both bounded metadata only — never transcript
content, never model output.

| Path                              | Written by                                    | Cap                                      |
| --------------------------------- | --------------------------------------------- | ---------------------------------------- |
| `~/.claude/papercuts/capture.log` | `papercut-capture.sh` and `papercut-sweep.sh` | 1 MiB, then **truncated in place**       |
| `~/.claude/papercuts/flush.log`   | `papercut-flush.sh`                           | 1 MiB, then **rotated** to `flush.log.1` |

The cap is `PAPERCUT_LOG_MAX_BYTES` (1048576 by default) and is checked when a
line is about to be written, so a log can exceed the cap by one line before it
rolls. The two scripts handle the overflow differently, which matters when you
go looking for older lines: capture's history is gone, the flusher's previous
generation is in `flush.log.1` until the next roll overwrites it.

```sh
tail -50 ~/.claude/papercuts/capture.log
tail -50 ~/.claude/papercuts/flush.log
```

Both files are safe to delete at any time; nothing reads them back.

Lines worth recognizing: `skip reason=…` (a session was declined, with the
reason — capture emits `trivial`, `unchanged-transcript`, `extractor-failed`,
and others; the sweep, writing to the same log, emits `quiet-window` and its
own set),
`claimed batch=…` / `published and removed batch=…` (a normal flush),
`retaining batch=…` (a publish failed and the batch will be retried), `hold
reason=…` (nothing was claimed, with the reason), and `scrub-review runs=N`
(the scrub redacted N ordinary-vocabulary runs in that record; the verbatim
text is in the local scrub-review sidecar, never in the log).

## Inspect anchors

An anchor is a content-light structural note recorded the instant a tool call
fails or a permission prompt appears, independent of whether the session ever
ends cleanly.

```sh
ls ~/.claude/papercuts/anchors/
jq . ~/.claude/papercuts/anchors/*.jsonl
```

One sidecar per session that had friction, in a 0700 directory, mode 0600,
named `sha256(session_id).jsonl` — the raw session id is never in the
filename. The sweep still reads the id from **inside** the file rather than
reversing the name. Each line carries `v`, `session_id`, `kind`
(`tool_error` or `permission_prompt`), `tool_name`, `tool_use_id`, an
`error_class` from a fixed enum (`nonzero_exit`, `timeout`, `not_found`,
`interrupted`, `denied`, `unknown`), and optionally `exit_code` and `ts`. No
tool input, no tool output, no file paths, no transcript text.

Each file is capped at `PAPERCUT_ANCHOR_CAP` lines (50 by default); past that,
further anchors for that session are dropped rather than growing the file.

An empty or absent directory means no anchored friction is outstanding.
Sidecars are not yours to garbage-collect: the sweep deletes one once its
session is confirmed processed, and prunes one whose transcript is gone past
`PAPERCUT_ANCHOR_TTL_DAYS` (7 days by default).

## Force a sweep

The sweep is a plain `SessionStart` hook script, not a daemon, so run it
directly. It reads a session-start JSON payload on stdin:

```sh
scripts/papercut-sweep.sh </dev/null
```

An empty payload only means there is no own-session id to self-skip — which is
correct when you are running it by hand outside a session. It exits 0 no matter
what happens; read `capture.log` for what it did.

Two things bound what a forced run will do, and neither is bypassable by a
flag:

- **Quiet hours.** A session is skipped unless its anchors file _and_ its
  transcript have both been untouched for `PAPERCUT_SWEEP_QUIET_HOURS` (24 by
  default). Running the sweep right after a crash therefore does nothing —
  `skip reason=quiet-window`. Wait out the window, or lower it for one run:
  `PAPERCUT_SWEEP_QUIET_HOURS=1 scripts/papercut-sweep.sh </dev/null`. Lowering
  it raises the chance of extracting a session that is merely idle rather than
  finished, which is the duplicate risk described in
  [architecture.md](architecture.md#residual-risk-the-sweep-backstop).
- **The per-run bound.** At most `PAPERCUT_SWEEP_MAX_SESSIONS` (5 by default)
  non-self anchors files are examined per run, counted whether or not they are
  acted on. A large backlog needs several runs.

The sweep makes no model call of its own — it drives `papercut-capture.sh`,
which does.

## The `compaction failed` tripwire

`extractor: compaction failed` in `capture.log` means the compaction step
before the model call exited non-zero or produced no output, and the extractor
stopped rather than sending the raw transcript to the model. The session is not
marked processed, so it is retried on the next trigger.

**Treat a repeat of this line for the same session as a bug, not as a transient
failure to wait out.** Compaction is pure and deterministic: no model, no
network, no clock, no randomness. The same transcript bytes always produce the
same result. So a session that failed compaction once will fail forever and
never be captured until the cause is fixed. In practice the cause is one of:

- a regression in `scripts/papercut_compact.py`;
- a missing or broken `python3`;
- a non-numeric `PAPERCUT_COMPACT_BUDGET_BYTES` — the value is parsed as an
  integer with no fallback, so `200k` or an empty string fails every run on
  every session.

A malformed anchors file is **not** this failure. Anchor loading fails closed
to "no anchors", which degrades compaction (anchored neighborhoods lose their
protection from budget trimming) without failing it.

The retry behaviour is general, not specific to compaction: any non-zero
extractor exit leaves the transcript unprocessed on purpose, so a genuinely
transient failure — a timeout, a model error — is retried rather than being
recorded as done. That is also why a deterministic failure retries forever.

## Related

- [configuration.md](configuration.md) — every path and tunable named above.
- [architecture.md](architecture.md) — why the pipeline is shaped this way.
- [schema.md](schema.md) — what a record and a resolution mean.
- [privacy.md](privacy.md) — the scrub, the denylist, and what remains
  possible.
