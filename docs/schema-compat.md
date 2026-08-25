# Schema compatibility — the reader contract

This contract binds every consumer of papercut records — the shipped readers
and any reader anyone writes later. It is also stated in `schema/v1.json`'s
`$comment` and pinned by tests (the `forward tolerance:` assertions in
`tests/papercut_open.test.sh` and `tests/papercut-flush.test.sh`).
[schema.md](schema.md) documents the record shape itself and defers to this
file for the contract.

## Why a contract, not just tolerant code

The shipped readers are already forward-tolerant: `scripts/papercut_open.py`
folds without schema validation, ignores unknown fields, and skips unknown
`type` values; `scripts/papercut_flush_group.py` gates only on "JSON object
with a valid `ts`"; the publisher's dedup reads only `id`. Without a written
promise, the next reader anyone writes is free to validate strictly — and
becomes the one upgraded install that rejects everyone else's records. With
the contract, every later schema addition is a cheap additive change, not a
coordination event across installs.

## The reader contract

- **Validation is a writer-side gate.** The schema's
  `additionalProperties: false` applies to the capture gate's own records at
  append time, and to nothing else.
- **Readers ignore unknown fields.** A record carrying a field the reader does
  not know is a normal record.
- **A consumer that dispatches on `type` skips unknown values** rather than
  erroring (`papercut_open.py` does this). A structural consumer passes them
  through (`papercut_flush_group.py` groups any JSON object with a valid
  `ts`).
- **Quarantine is structural, never vocabulary-based.** Unparseable lines,
  parseable non-objects, and invalid `ts` values quarantine; unknown fields
  and unknown `type` values never do.
- **A whole-ledger validator must be a separate audit command**, never a gate
  on any read path.

## The compatibility contract for schema changes

- **Adding an optional field is safe.** Readers must tolerate it; per the
  contract above, they already do.
- **Removing or renaming an existing base field is breaking** and requires
  coordination across every install reading the ledger.
- **Changing the structure of an existing field is a new field plus a
  deprecation** of the old one, never an in-place edit.

## Extension point

A ledger repo may carry its own schema copy that extends the shipped schema
with team-specific optional fields. The shipped gate keeps validating against
the shipped schema only — capture stays offline and clone-less. Team-extended
records read fine everywhere by the contract above; only the team's own audit
tooling validates the extended shape.
