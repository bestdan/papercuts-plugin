# Privacy model

Read this before you point the pipeline at confidential work.

Client-side scrubbing here is **layered best-effort defense, explicitly not a
semantic guarantee.** Every layer below is a filter that can be wrong. None of
them understands what your work is about. The document names what each layer
covers, and then names what remains possible.

Captured records leave your machine: the flusher commits and pushes them to a
git repo you own. Nothing in this document changes that — it is about what the
records contain when they get there.

## Start here: the strict profile is a staged rollout

A machine resolves to one of two profiles, `default` or `strict`. On a strict
machine, capture is **fail-closed at the gate**: with no usable denylist, no
record is appended to the local spool and nothing is synced. That is the
intended state on day one, not a misconfiguration.

Mark a machine strict either way — the two triggers are a monotone union, and
neither can be cancelled by the other:

```sh
# (a) the operator-facing marker. No config key names this path.
mkdir -p ~/.config/papercuts
touch ~/.config/papercuts/strict

# (b) the fleet convenience: hostname globs in the config file.
#     Matched against the hostname's FIRST dot-separated label only.
cat >>~/.config/papercuts/config.toml <<'TOML'
[profile]
strict_hosts = ["work-*"]
TOML
```

`profile.strict_hosts` can only **add** strictness. The marker path is a
hardcoded literal in `scripts/papercut_append.py`; no config key relocates or
suppresses it. Profile detection also fails closed: a config file that exists
but is broken resolves to `strict` rather than silently downgrading a fleet
machine to the permissive profile.

Then, deliberately, write the denylist:

```sh
mkdir -p ~/.config/papercuts
umask 077
# One case-insensitive literal per line: internal repo names, project
# codenames, ticket prefixes, team and person names, internal hostnames and
# system names. See ../denylist.example.txt for the format.
$EDITOR ~/.config/papercuts/denylist.txt
chmod 0600 ~/.config/papercuts/denylist.txt
```

> **An incomplete denylist is worse than none.** An absent or empty denylist
> keeps a strict machine inert — nothing is stored, nothing is pushed. Writing
> three lines into it flips capture **on** for every record that does not
> happen to match those three lines. The file is the thing standing between
> your confidential vocabulary and a git push, so populate it in one
> deliberate sitting rather than growing it reactively from whatever the
> ledger turns out to contain.

The denylist is **never committed anywhere.** It names the exact things that
must not leak, so a committed copy defeats its own purpose. `denylist.txt` is
also refused if it is world-readable.

## The layers

### 1. Prompt rules

On a strict machine the extractor prompt is prefixed with a hard-rules block
(`prompts/extractor-prompt.md`, the `WORK_PROFILE_HARD_RULES` section). It
instructs the model to describe every friction point generically and never to
emit repository names, file or directory paths, code (snippets, identifiers,
function, class, or variable names), ticket IDs, person names or handles, or
internal system, service, and tool names. If a friction point cannot be
described without one of those, the prompt tells the model to drop the record
rather than redact it.

**This is a soft instruction to a model. It can fail.** It is the cheapest
layer and the least reliable one; it is listed first because it runs first, not
because it is load-bearing.

The same prompt also treats the transcript as untrusted data rather than
instructions, and the extractor runs tool-less and isolated — see
[install.md](install.md#the-extractors-isolation-flags-and-the-cli-version-they-were-checked-against)
for the flags and the CLI version they were hand-verified against.

### 2. The syntactic scrub

The gate (`scripts/papercut_append.py`) redacts the free-text fields — `title`,
`description`, `suggested_fix` — on **both** profiles, in this order:

| Pattern                                  | Replacement   | Notes                                                                                                |
| ---------------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------- |
| PEM blocks                               | `[pem-block]` | whole `-----BEGIN…-----END-----` block, so the token rule cannot shatter it                          |
| JWTs                                     | `[jwt]`       | `eyJ…`, three dot-separated base64url segments, kept as one marker                                   |
| Credentials in a URL                     | `[redacted]@` | `scheme://user:pass@host` — the credential goes, the host stays                                      |
| Prefixed API keys                        | `[key]`       | `sk-`, `ghp_`, `github_pat_`, `xox…`, `AKIA…`                                                        |
| Email addresses                          | `[email]`     |                                                                                                      |
| IPv6                                     | `[ip]`        | candidates validated with stdlib `ipaddress`, so compressed and IPv4-mapped forms cannot leak a tail |
| IPv4                                     | `[ip]`        | runs after IPv6 for the same reason                                                                  |
| Any run of ≥20 chars of `[A-Za-z0-9+_-]` | `[token]`     | last-resort catch-all for unstructured entropy                                                       |
| `/Users/<name>` and `/home/<name>`       | `~`           |                                                                                                      |

`fix_url` on a resolution record takes every pattern above **except** the
generic token rule and the home-path rule, so a 40-character commit SHA in a
URL survives while an embedded credential still does not.

**This layer is syntactic, not semantic.** It matches shapes. It has no notion
of an internal project name, a team, a customer, a person who is not written as
an email address, or a business fact. A sentence that names your unreleased
product in ordinary English passes through it untouched, because there is
nothing about that sentence for a regular expression to find.

The catch-all token rule is aggressive enough to have a false-positive problem
of its own: ordinary hyphenated vocabulary is shaped exactly like a diceware
passphrase, so it gets shredded to `[token]` too. The gate flags
vocabulary-shaped redactions on stderr and, when `PAPERCUT_REVIEW_FILE` is
set, writes the verbatim pre-redaction runs to a local-only scrub-review
sidecar so a human can reconstruct a mangled record or grow the allowlist. That
sidecar is **never flushed to the ledger** and is pruned by the sweep — see
[configuration.md](configuration.md) for the paths and the TTL.

### 3. The fail-closed denylist gate

This is the only layer with real teeth, and it only has them on a strict
machine.

**On a strict machine**, the gate requires a denylist that is present,
non-empty after stripping comments and blank lines, and not world-readable. If
any of those fail, **every record is rejected** — `ScrubRejected`, nothing
written, nothing synced. When the denylist is usable, any record whose
**pre-redaction** free text or `fix_url` contains a denylist literal is
rejected **whole**, not redacted, so a match cannot leak through the context
left around a `[redacted]` marker. Strict records also carry no `repo` and no
`session_id`; the gate strips both.

**On a default machine** the denylist is optional and advisory: if the file
exists, its literals are redacted to `[redacted]`; if it does not, only the
syntactic patterns run.

Matching is a plain case-insensitive substring test, not a regex.

Publishing from a strict machine also holds by default. A normal
`papercut-flush.sh` run logs `hold reason=strict-profile-review` and exits 0
without claiming or stamping anything. Inspect the pending set read-only with
`--review`, and publish it only after vetting, with `--force`. If review turns
up something the capture-time scrub should have caught, add the literal to the
denylist so the gate catches it next time instead of you.

## The team-shared denylist pattern

A team that wants one vocabulary list shared across machines should keep a team
list wherever the team already keeps reviewed internal documents, and have each
operator **manually merge** it into their own
`~/.config/papercuts/denylist.txt`. The per-machine file stays the only thing
the gate reads.

A ledger-committed, gate-read team denylist was considered and **refused.** Two
reasons, both structural:

- It inverts the "never committed anywhere" invariant. A denylist enumerates
  the terms that must not leak; committing it publishes exactly that list to
  the repo the pipeline pushes to.
- It fails **open.** The gate is offline and clone-less by design. A gate that
  read a team list out of a clone would silently fall back to "no team terms"
  whenever the clone was missing, unfetched, or stale — which is the failure
  mode the strict profile exists to prevent, arriving quietly instead of as a
  rejection.

Manual merge is worse ergonomics and a better failure mode: a merge you forgot
to do leaves the gate strictly stricter than the team intends, never looser.

## What remains possible

The extractor can still emit an internal name that is not on your denylist and
is not shaped like a syntactic secret. Nothing in the pipeline will stop that
record. It will be validated, appended, and pushed to your ledger.

That residual risk is **accepted and documented.** It is the reason the
denylist is mandatory on a strict machine and the reason strict capture stays
fail-closed at the gate until you populate it by hand. Concretely, all of the
following survive every layer above:

- A project codename, team name, or customer name you did not think to add.
- A description of what a system does, written in plain English, with no
  identifiers in it.
- An internal hostname or service name not on the denylist.
- A person referred to by first name.
- The shape of your work: which categories of friction your sessions produce,
  how often, and on which days.

**Passing the adversarial scrub tests proves syntactic coverage only, never
semantic confidentiality.** `tests/papercut_append.test.sh` asserts that the
patterns in the table above catch what they claim to catch. That is the whole
extent of the claim. A green suite is not evidence that a record is safe to
publish.

Locally, none of this is a boundary either. The scrub defends the **sync
boundary** — what leaves this machine for the ledger — not local disk. The
unscrubbed transcript of every session already sits under `~/.claude/projects`,
and the spool, logs, and sidecars are mode-0600 files under your home
directory, not encrypted storage.

## Related

- [install.md](install.md) — install, the denylist step in context, and the
  extractor's isolation flags.
- [configuration.md](configuration.md) — every config key and environment
  variable, with defaults.
- [../denylist.example.txt](../denylist.example.txt) — the denylist format.
- [../README.md](../README.md) — what the pipeline does and does not do.
