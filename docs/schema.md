# Record schema

`schema/v1.json` is the authoritative shape. This document reads it field by
field, explains the two record types and how they fold together, and says who
constructs what.

If you are writing a consumer of these records rather than reading one, the
compatibility rules you are bound by are in
[schema-compat.md](schema-compat.md) — validation is a writer-side gate,
readers ignore unknown fields, and quarantine is structural only. This document
does not restate them.

The ledger is **append-only**. Nothing here is ever edited in place: a record
is corrected by writing another record, which is why resolutions exist.

## Controlled and descriptive fields

Every record is one JSON object on one line. Its fields divide by **who
constructs them**, and that division is the pipeline's provenance guarantee
rather than a convention.

**Controlled fields** are constructed by `scripts/papercut_append.py` — the
gate — from its own state, its own arguments, and the clock. A caller cannot
set them. The gate reads _only_ the descriptive keys from its stdin JSON and
silently ignores everything else, including an attempted `id`, `ts`, `machine`,
`type`, `source`, `producer`, `session_id`, or `repo`. That is what makes
provenance unforgeable when the caller is model output over an untrusted
transcript.

**Descriptive fields** are what a caller supplies: the human content of the
record.

| Field           | Who         | Type / shape                                                                                    | Notes                                                                                                                        |
| --------------- | ----------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `id`            | controlled  | `pc_` + a UUID4                                                                                 | Always present. The idempotency key the publisher reconciles by, so a re-published record is a no-op.                        |
| `v`             | controlled  | the constant `1`                                                                                | Schema version of the record itself.                                                                                         |
| `type`          | controlled  | `papercut` \| `resolution`                                                                      | From `--type`. Absent on rows written before the field existed; every consumer grandfathers those as `papercut`.             |
| `producer`      | controlled  | non-empty string                                                                                | From `--producer`, the component that made the record: `capture-hook/1`, `papercut-skill/1`, `resolve-cli/1`.                |
| `ts`            | controlled  | `YYYY-MM-DDTHH:MM:SSZ`                                                                          | UTC, second precision, at append time. Its `YYYY-MM` prefix picks the ledger file, so this pattern is load-bearing.          |
| `machine`       | controlled  | `default` \| `strict`                                                                           | The resolved profile, from the gate's own `detect_machine()`. Never taken from a caller, never from an environment variable. |
| `source`        | controlled  | `auto` \| `manual`                                                                              | From `--source`: the automatic extractor, or a hand-written capture.                                                         |
| `session_id`    | controlled  | non-empty string                                                                                | Optional. Passed by the automatic path; **dropped** from the stored record on the strict profile.                            |
| `repo`          | controlled  | non-empty string                                                                                | **Required** for a `papercut` on the default profile; **dropped** on the strict profile.                                     |
| `category`      | descriptive | `harness_config` \| `instruction_gap` \| `model_behavior` \| `project_dx` \| `should_be_script` | Papercut only, required.                                                                                                     |
| `severity`      | descriptive | `low` \| `medium` \| `high`                                                                     | Papercut only, required.                                                                                                     |
| `title`         | descriptive | string, 1–100 chars                                                                             | Papercut only, required. Free text: scrubbed.                                                                                |
| `description`   | descriptive | string, 1–1000 chars                                                                            | Papercut only, required. Free text: scrubbed.                                                                                |
| `suggested_fix` | descriptive | string, ≤ 500 chars                                                                             | Papercut only, optional. Free text: scrubbed.                                                                                |
| `resolves`      | descriptive | `pc_` + a UUID4                                                                                 | Resolution only, required. The target papercut's `id`.                                                                       |
| `status`        | descriptive | one of five values, [below](#the-five-resolution-statuses)                                      | Resolution only, required.                                                                                                   |
| `fix_url`       | descriptive | `http(s)://…`, ≤ 300 chars                                                                      | Resolution only, optional in the schema — but required by the CLI for two statuses. Scrubbed differently; see below.         |

Seven fields are required on every record: `id`, `v`, `producer`, `ts`,
`machine`, `source`, and `type`. `additionalProperties`
is `false`, which — per the reader contract — constrains the gate's own records
at append time and nothing else.

**Which fields are scrubbed.** The three free-text fields (`title`,
`description`, `suggested_fix`) go through the full syntactic redaction, plus
the denylist. `fix_url` goes through a narrower pass: every structured-secret
pattern _except_ the generic long-token rule, which would shred a commit SHA in
an otherwise perfectly good link — but the denylist still applies to it,
because a URL path can carry a codename. Enums, ids, and every other controlled
field are never rewritten. What the scrub does and does not cover is
[privacy.md](privacy.md#2-the-syntactic-scrub).

**Truncation happens after redaction.** A redaction marker changes a field's
length, so free-text fields are truncated to their schema `maxLength` before
the record is revalidated. A marker can never push a valid record over its
limit and make it invalid.

## The two record types

`type` splits the vocabulary in two, and `schema/v1.json` enforces the split in
**both** directions with conditional subschemas:

- A `papercut` must carry `category`, `severity`, `title`, `description`, and
  must **not** carry `resolves`, `status`, or `fix_url`.
- A `resolution` must carry `resolves` and `status`, and must **not** carry
  `category`, `severity`, `title`, `description`, or `suggested_fix`.

A papercut is a description of friction. A **resolution** is a later, separate
record that points at an earlier papercut's `id` and says what happened to it.
It exists because the ledger is append-only: marking a papercut done by editing
it is not available, so the fact is recorded as a new line instead.

The gate reads exactly three keys from a resolution's stdin JSON —
`RESOLUTION_KEYS`, which is `resolves`, `status`, `fix_url` — and constructs
everything else, the same way it does for a papercut. A resolution carries no
free text at all, which is why its only scrubbable field is the URL.

`scripts/papercut-resolve.sh` is the CLI:

```sh
scripts/papercut-resolve.sh <pc_id> <status> [fix_url] [--force]
```

It validates the id pattern, the status value, and the URL shape itself before
the gate ever runs, then does two lookups over the ledger clone and the local
spool:

- **Existence** — `<pc_id>` must appear as a **papercut** record somewhere.
  Matching a resolution's id does not count; resolving a resolution's id would
  create an inert orphan. This is typo protection, not authority: a papercut
  still sitting in the spool resolves fine.
- **Already-resolved** — `<pc_id>` must not already have a resolution. Without
  this, running the CLI twice quietly appends a second resolution to an
  append-only ledger.

`--force` skips **those two lookups only**. It does not waive argument
validation, including the `fix_url` requirement below.

## The five resolution statuses

The authoritative list is `schema/v1.json`'s `status` enum, and
`scripts/papercut-resolve.sh` rejects anything else before the gate is called.

| `status`            | Means                                                               | `fix_url`    |
| ------------------- | ------------------------------------------------------------------- | ------------ |
| `fixed`             | A real fix landed. The URL should point at it.                      | recommended  |
| `mitigated`         | A workaround landed — a rule, a skill, a doc — short of a real fix. | recommended  |
| `reported-upstream` | Filed somewhere findable outside your control.                      | **required** |
| `wontfix`           | Out of your control and not reported, or not worth pursuing.        | —            |
| `out-of-scope`      | Real and yours, but tracked somewhere this ledger does not cover.   | **required** |

All five are terminal, and the fold below keys only on a resolution
**existing** — never on its `status`. So the distinction is for the human
reading the ledger months later, not for tooling.

**Why two of them require a URL.** `reported-upstream` and `out-of-scope` are
both claims about a _place_: one asserts a report exists, the other asserts the
work is tracked elsewhere. Unwitnessed, each is indistinguishable from
`wontfix` — and because the ledger is append-only, a bare one is a dead end
nobody can follow up and nobody can amend. So the CLI requires the citation
rather than trusting the caller to supply it, and `--force` does not waive it.
If there is no such place, the honest status is `wontfix`.

`out-of-scope` exists because `wontfix` was doing double duty and lying about
it. Friction found in one repo is often perfectly fixable, just not from the
repo you are standing in; closing it `wontfix` writes a false claim into a file
nobody rewrites.

## The fold

`scripts/papercut_open.py` computes the open set. It is read-only — it reads
`ledger/*.jsonl` under the ledger directory plus the local spool, and never
writes anything.

```sh
scripts/papercut_open.py             # open papercuts, grouped by severity
scripts/papercut_open.py --resolved  # resolved papercuts, with their resolution
scripts/papercut_open.py --json      # open papercuts as JSONL
```

**What the fold actually does.** Records are read in one pass, in a fixed
source order: every ledger file, **sorted by filename**, then the spool. Since
ledger filenames are `YYYY-MM`, sorting by name sorts chronologically. Each
record is dispatched on `type`, defaulting to `papercut` when the field is
absent:

- a **papercut** with a string `id` goes into a map keyed by that `id`;
- a **resolution** with a string `resolves` goes into a map keyed by that
  target id;
- anything else — an unknown `type`, a non-string key, an unparseable line — is
  skipped silently rather than being an error.

A papercut is then **open** if its `id` is not a key in the resolution map, and
**resolved** if it is. That is the whole rule. It is a fold over an
append-only file, not a mutation of it, and a missing ledger clone is a note on
stderr rather than a crash.

Three consequences worth knowing:

- **Last writer wins, per key.** Both maps are plain assignments in source
  order, so if two records share an `id`, the later one in source order is the
  one the fold uses; if several resolutions target the same id, the last one
  seen wins and is the one `--resolved` prints. Nothing merges or warns.
- **`status` is not consulted.** A `wontfix` closes a papercut exactly as
  firmly as a `fixed` does.
- **An orphan resolution is inert.** A resolution whose `resolves` matches no
  papercut in the loaded set suppresses nothing and is never printed. It is not
  an error.

**Ordering of the output** is deterministic and independent of the fold:
severity rank first (`high`, `medium`, `low`, then anything else), then `ts`,
then `id`. Records whose `severity` is absent or unrecognized sort last and
print under an `unknown severity` heading rather than being dropped — the same
forward tolerance the reader contract requires.

## Related

- [schema-compat.md](schema-compat.md) — the reader contract and the rules for
  changing this schema.
- [architecture.md](architecture.md) — who constructs these fields and why.
- [operations.md](operations.md) — reading and repairing records in flight.
- [privacy.md](privacy.md) — what the scrub covers on the free-text fields.
