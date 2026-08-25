# Architecture

The diagram is in the [README](../README.md#architecture) and is not repeated
here. This document goes one level deeper: what each component owns, the
invariants that hold the design together, the decisions that were load-bearing
enough to write down with their reasons, and the residual risk the backstop
sweep accepts on purpose.

## The three invariants

Everything else is detail around these.

**1. The gate is the only writer.** `scripts/papercut_append.py` is the sole
process that appends to the spool. Every path in — the automatic extractor, the
manual skill, the resolve CLI — funnels through it, and the record content on
**stdin carries descriptive fields only**. The controlled fields never come
from record content: the gate constructs `id`, `v`, `ts`, and `machine`
entirely itself, and takes the provenance context (`--type`, `--producer`,
`--source`, `--session-id`, `--repo`) as arguments from the trusted CLI
wrappers — so model output cannot spoof any of them; see
[schema.md](schema.md#controlled-and-descriptive-fields). Its pipeline is fixed:
**construct → validate → scrub → revalidate → append.** Revalidation is not
ceremony — a redaction marker changes a field's length, so the record that
lands on disk is a different record from the one that was validated.

**2. One lock, shared by the writer and the reader that steals the file.** The
gate holds an `fcntl.flock` on a lock file — separate from the spool — across
its _entire_ append. The flusher claims the spool by renaming it to a batch
file under that _same_ lock. So an append either fully lands in the spool
before the rename, or fully lands in the fresh spool created after it. There is
no window in which a write is orphaned on an inode about to disappear. The lock
is held only across "check non-empty, then rename" — grouping and publishing
happen outside it, so a slow network push never blocks a capture.

**3. Capture is offline and clone-less; only the flusher touches the network.**
Nothing on the capture path reads the ledger, and nothing needs a ledger clone
to exist. That is why the gate validates against the schema shipped in this
repo rather than one fetched from the ledger, and why capture keeps working
with no config file at all. It is also the reason the extractor's model call is
the single outbound dependency of capture, and the flusher's push the single
outbound dependency of publishing.

## What each component owns

**`scripts/papercut_append.py` — the gate.** Construct, validate, scrub,
revalidate, append. Validation is a hand-rolled, stdlib-only subset of JSON
Schema draft 2020-12, sufficient for `schema/v1.json` and not a general
validator. Also resolves the machine profile (`detect_machine()`), which is the
one profile resolver in the pipeline: the extractor and the flusher both call
_this_ function rather than deciding for themselves, so the three can never
disagree about what machine they are on.

**`scripts/papercut-capture.sh` — automatic capture.** Everything around the
model call and nothing of the call itself: the recursion guard, a structural
triviality pre-filter, per-session and content-hash idempotency, an atomic
two-slot concurrency cap, a private immutable copy of the transcript (hashed
and read as the same bytes), and metadata-only logging. Exports this session's
anchors path and the scrub-review sidecar path to the steps below it. Writes
the processed marker only on success or on a definitive "nothing found" — never
after a failure, so a failure retries.

**`scripts/extractor-run.sh` — the model call, bounded.** Runs the compactor,
then a tool-less `claude -p --model haiku` with a JSON schema, under a process-
group watchdog, and pipes the result to the gate. Emits short content-free
error _classes_ on failure (`compaction failed`, `empty transcript`, and
similar), never transcript text, because the caller logs them.

**`scripts/papercut_compact.py` — compaction.** Deterministic, pure stdlib, no
model, no network, no clock. Three stages, applied only as far as needed to fit
the byte budget: lossless-shape trimming (envelope metadata, thinking blocks,
tool payloads); then collapsing everything except must-keep entries (user
turns, denials, error neighborhoods, anchor-resolved neighborhoods) into
elision markers; then bounding every field, must-keeps included, to a head/tail
excerpt. The budget always wins.

**`scripts/papercut-anchor.sh` — the anchor recorder.** A recorder, not an
extractor: no model, no network, no transcript content. Writes one structural
line per failed tool call or permission prompt to a per-session sidecar, the
instant it happens.

**`scripts/papercut-sweep.sh` — the backstop.** Rescues sessions that left
anchors but never fired a clean session end, by driving capture for them
directly. Also owns the anchors sidecar lifecycle and prunes the scrub-review
sidecar. See [the residual-risk section](#residual-risk-the-sweep-backstop).

**`scripts/papercut-flush.sh` — the flusher.** Claim, group by month,
quarantine, publish, stamp. The only component with write access to the ledger,
and the only one that needs a ledger identity — which it resolves through
`scripts/papercut_config.py`, the single config reader.

**`scripts/papercut-resolve.sh` and `scripts/papercut_open.py` — the
resolution pair.** One appends a resolution record through the gate; the other
folds resolutions over papercuts, read-only. Neither mutates the append-only
ledger. See [schema.md](schema.md#the-fold).

**`scripts/papercut-doctor.sh` — the install check.** Read-only, advisory,
never publishes. It exists because the two things a plugin must not grant
itself (a permission rule and sandbox write paths) are exactly the two things a
stranger gets wrong.

## Load-bearing decisions

**Controlled fields are constructed by the gate, not accepted from callers.**
The automatic path's input is model output over an untrusted transcript. If a
caller could supply `machine`, a crafted transcript could talk the extractor
into emitting a record that claims to come from a different profile — and the
strict profile is exactly what decides whether `repo` and `session_id` are
stored. Constructing those fields in the gate makes provenance unforgeable by
construction rather than by validation.

**The strict profile fails closed, twice, and strictness is monotone.** A
strict machine requires a denylist that exists, is non-empty after stripping
comments, and is not world-readable; without one, _every_ record is rejected
and nothing is stored or pushed. And any record whose **pre-redaction** text
matches a literal is rejected _whole_ rather than redacted, because redacting
the match still leaves the context around it. The two strictness triggers — a
hostname glob from config, and a marker file — form a union that config can
only add to. The deciding argument is polarity: a wrong denylist path fails
closed (records rejected), while a wrong _marker_ path would fail open (records
published), so the marker path is a hardcoded literal that no config key and no
environment variable can move.

**Profile detection fails closed everywhere it is consulted.** The flusher and
the extractor both treat "not positively `default`" as strict — empty output, a
crashed interpreter, a missing script. A detection error can therefore never
let a strict host auto-publish unreviewed, and never strip the extractor's
privacy preamble.

**Anchors are a crash backstop, not an extraction path.** The alternative
considered was incremental per-turn extraction on a stop hook, which is
size-independent by construction — and a structural duplicate-record machine,
because overlapping windows re-describe the same friction under a fresh `id`
every turn. Anchors buy the same property that mattered (acute friction
survives budget trimming, and survives a session that never ends cleanly)
while extraction stays single-pass. That trades a guaranteed duplicate every
turn for a rare, bounded one.

**Denylist matching happens before redaction, and on `fix_url` too.** Matching
the post-redaction text would let a literal that the built-in patterns
partially mangled slip through as a non-match. `fix_url` is checked against the
denylist but deliberately skips the generic long-token redaction rule, which
would shred the commit SHA in a perfectly good link; a URL path can still carry
a codename, so the denylist still applies to it.

**Compact before the model call, rather than feed the raw transcript.** A large
transcript overflows the model's context and the call fails; because a failed
call is never marked processed, the same doomed session retries forever and is
never captured. In a measured real case the actual friction signal was about 5%
of the transcript bytes — the rest was tool payloads, thinking blocks, and
per-line envelope metadata the extractor does not need. Compaction distills to
that signal deterministically, upstream of the model, so the fix costs no extra
call and no round trip. It fails closed: a compaction failure stops the run
rather than falling back to the raw transcript, which would just reproduce the
original failure.

**The claim is a rename under the shared lock, not a copy-and-truncate.**
Renaming is atomic, so the claim cannot lose a record to a partial copy, and
the batch name carries a UTC timestamp, the pid, and a random token. The token
is not decoration: a repeated clock second plus a reused pid would otherwise
let a rename silently overwrite a stale batch. Unique names also mean several
batches can be outstanding at once, which is what makes crash recovery a plain
oldest-first glob.

**Publishing reconciles by record `id`, in a disposable worktree.** Two
machines appending at end-of-file cannot be merged textually, and an uncertain
push outcome must not double-append. So the record `id` — a UUID4 — is the
idempotency key: the publisher fetches, creates a throwaway worktree detached
at the fetched tip, appends only records whose id is not already present,
commits, pushes, and confirms the pushed SHA actually landed on the remote,
retrying against a fresh tip on a non-fast-forward rejection. Your own ledger
clone is only ever fetched. Its checked-out branch is never reset or committed
to, so a dirty or ahead clone can neither be damaged by a publish nor block
one — and it is left deliberately un-fast-forwarded, which is why the success
line says so rather than reading as a chore.

**Only the origin URL gates a push, and both URLs are checked.** Since the
publish never touches your clone's working tree, the states that used to be
hard gates (dirty tree, wrong branch, detached HEAD) no longer need to be. What
remains is the one thing that must never be wrong: where the push goes. The
fetch URL and the _push_ URL are both validated against an anchored allowlist
built from the config file, regex-escaped, with no substring matching — so a
lookalike host cannot pass, and a clone with a hostile `pushurl` cannot sail
past a check of the fetch URL alone. There is deliberately no environment
variable that can add a trusted remote; one can change what the flusher aims
at, never exempt the target from the check.

**The ledger is grouped by month.** One file per `YYYY-MM` under `ledger/`,
which is the coarsest grouping that still keeps files small enough to read and
diff, and keeps two machines publishing in the same month reconciling against
one file rather than fighting over one enormous one. It also makes the common
analysis question — this month, last month — a filename rather than a filter.

**Two stamps, with different half-lives.** A success stamp throttles normal
runs for about 24 hours; a failure stamp backs off for about one hour, because
a transient publish failure should retry sooner than a satisfied success should
expire. Each outcome clears the opposing stamp, so exactly one is ever fresh.
The success stamp is bypassed whenever a stale batch exists, so a stranded
batch cannot be masked for a day by a stamp from a run that succeeded before
it.

**Every hook is fail-silent, and the flusher's is fail-silent by re-exec.** A
capture that fails loses a record; a hook that fails would disrupt a session,
which is far more expensive. The flusher gets there with `--hook`, which
re-executes the script without the flag and maps every exit code to 0 after
logging it — chosen over a trap or per-branch exits because the failures that
must be swallowed are not confined to one branch: the identity gate, a publish
error, and an interpreter error anywhere in the file all have to be covered.
Invoked directly, the same script keeps its fail-closed exit codes so a human
sees them.

## Residual risk: the sweep backstop

The sweep is **at-least-once, not duplicate-free** — by design, not by
oversight. [configuration.md](configuration.md#backstop-sweep--papercut-sweepsh)
states this in brief; here is the full reasoning.

**The problem it cannot solve.** An anchors file with no processed marker
describes every _currently running_ session that has had friction, not only the
dead ones. Nothing in a transcript distinguishes "finished" from "idle and
resumable" — a session can be resumed hours or days later. So the sweep cannot
wait for proof that a transcript is final. It can only wait for **quiet**.

**What it does instead.** Two guards, in order:

1. **Self-skip**, unconditionally and before anything else: the sweep never
   touches its own session's anchors file, whatever its mtime.
2. **A quiet window** on _both_ the anchors file and the transcript — neither
   may have been touched within `PAPERCUT_SWEEP_QUIET_HOURS` (24 by default).
   An idle-but-open session routinely outlives a shorter window.

Only after both pass does it check for a processed marker or drive a capture.
The window is on the cheap half first (the anchors mtime) so a live session
costs no transcript lookup at all.

**Why duplicates remain possible.** A session the sweep swept as done can later
be resumed. Resuming appends turns, which changes the transcript's content
hash, and capture's hash-based idempotency then sees a new transcript and
re-extracts it — reproducing a superset of what the sweep already captured.
Importantly, this is **not a new failure mode**: a resumed session already
re-extracts on its own next clean session end, with or without a sweep. The
sweep adds a second trigger for a risk the pipeline already accepted, and the
same content-hash idempotency is what keeps re-extraction of an _unchanged_
transcript a no-op.

There is a second, smaller version of the same tradeoff: once a session is
quiet, the sweep trusts a present processed marker and deletes the anchors file
without re-checking the marker against the transcript's current hash. A
post-window resume re-fires capture anyway, so the outcome is the same
at-least-once behaviour.

**The accepted scope boundary.** The sweep only ever _fires_ for a session that
left an anchor — a failed tool call or a permission prompt. Once it fires it
runs an ordinary capture, so it finds everything a clean session end would have
found. But a crashed session whose only friction was conversational — a
contradictory instruction, work that should have been a script, with no tool
error and no permission prompt anywhere — leaves no anchor, is never
discovered, and is never captured if its session end did not fire either. That
is a boundary, not a bug: anchors exist to catch acute friction cheaply, not to
make the sweep a general crash-recovery mechanism for every category.

**Why the per-run bound exists.** At most `PAPERCUT_SWEEP_MAX_SESSIONS`
non-self anchors files are _examined_ per run, counted whether or not they are
acted on. Counting only acted-upon sessions would leave the bound toothless
against a backlog of live sessions that the quiet window skips — each of which
would still cost an interpreter start and a directory walk on every session
start. The hook is asynchronous, but it should still not be linear in the size
of the backlog.

## Related

- [README](../README.md#architecture) — the diagram, and the does / does-not
  lists.
- [operations.md](operations.md) — running each of these components by hand.
- [schema.md](schema.md) — the record shape the gate constructs.
- [configuration.md](configuration.md) — every knob named above.
- [privacy.md](privacy.md) — the scrub layers and their limits.
