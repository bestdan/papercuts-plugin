---
name: papercut
description: Capture a friction point ("papercut") from the current session as a structured record — in-the-moment logging for things that took too many prompts, a confusing tool, or a gap in instructions. Use /papercuts:papercut [description] or /papercuts:papercut --flush to also push the local queue upstream.
argument-hint: "[one-line description] | --flush"
allowed-tools:
  - AskUserQuestion
  - Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/papercut_append.py:*)
  - Bash(git rev-parse --show-toplevel)
---

# /papercuts:papercut — Manual Friction Capture

Log a papercut — friction the user noticed but that left no clean trace in the transcript (e.g. "this took three prompts when it should've taken one", "the sandbox blocked X and I had to rerun manually"). This skill only ever composes the descriptive content and hands it to the trusted gate script; it never touches the spool or ledger directly.

**Arguments:** `$ARGUMENTS`

> **Note on `${CLAUDE_PLUGIN_ROOT}` in this file.** Claude Code substitutes it at
> **skill-load time**, so every occurrence below — including the `allowed-tools`
> entry in the frontmatter — is already the absolute installed plugin path by the
> time you read it. The variable is **not** exported into the Bash tool
> environment, so do not expect `$CLAUDE_PLUGIN_ROOT` to expand in a command you
> run; use the absolute path you see here. The same substitution is why a user's
> `permissions.allow` entry — if they add the fallback rule from
> `docs/install.md` step 4 — must name the resolved absolute path rather than
> the literal `${CLAUDE_PLUGIN_ROOT}` string; `scripts/papercut-doctor.sh`
> prints the exact entry for this install.

---

## Step 0 — Parse `--flush`

Split `$ARGUMENTS` into a `--flush` flag (present anywhere) and the remaining text (the description) with `--flush` removed:

- `--flush` present **and** no remaining description → skip record composition; go straight to [Flush](#flush).
- `--flush` present **and** a remaining description → compose and log the record (Steps 1–4), **then** run [Flush](#flush).
- No `--flush` → compose and log only (Steps 1–4).

## Step 1 — Determine the Description

- If the remaining text (after removing `--flush`) is a non-empty one-line description, use it verbatim as the seed for `title`/`description`.
- Otherwise, look at the immediately preceding session context (the last few turns). If a friction point is obvious and you're confident about it, infer the description from that.
- Otherwise, ask exactly **one** short question (e.g. "What was the papercut?") via `AskUserQuestion`, then proceed with the answer. Never ask more than one question, and never block further than this.

## Step 2 — Compose the Descriptive Fields

Compose ONLY these fields, as a JSON object — nothing else. All controlled fields (`id`, `v`, `producer`, `ts`, `machine`, `source`, `session_id`, `repo`) are constructed by the gate script; do not invent or include them.

- `category` — one of, picked by best fit:
  - `harness_config` — a Claude Code / tool config gap (missing permission rule, hook misfire, sandbox denial) caused the friction.
  - `instruction_gap` — CLAUDE.md/AGENTS.md/a skill was silent, ambiguous, or contradictory, and that caused the wrong turn.
  - `model_behavior` — the model did something undesirable despite clear instructions (misread intent, ignored a rule, hallucinated).
  - `project_dx` — the repo/project itself has friction unrelated to the agent (a slow script, a missing recipe, unclear tooling).
  - `should_be_script` — the fix is a deterministic script or hook, not more prose. Use this when the papercut is "I had to explain/do this manually" and a hook or one-liner would eliminate it entirely.
- `severity` — `low` | `medium` | `high` (best judgment: how much time/trust it cost).
- `title` — short, ≤100 chars.
- `description` — 1-3 sentences of concrete context, ≤1000 chars.
- `suggested_fix` — optional, ≤500 chars; omit if you don't have a concrete one.

## Step 3 — Pipe to the Gate

Determine `<repo>` as the basename of the current repo root (e.g. via `git rev-parse --show-toplevel`, then take the last path segment). Then run, feeding the Step 2 JSON object on stdin via a **quoted heredoc** so nothing in the description is interpreted by the shell (do NOT use `echo '<json>'` — a description containing a `'` would break the quoting or allow shell injection):

```sh
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/papercut_append.py \
  --source manual \
  --producer papercut-skill/1 \
  --session-id "$CLAUDE_CODE_SESSION_ID" \
  --repo "<repo>" <<'PAPERCUT_JSON'
<json object>
PAPERCUT_JSON
```

`${CLAUDE_PLUGIN_ROOT}` above is already the absolute installed path (see the note at the top) — type it out as the literal path you see, not as a variable.

The single-quoted heredoc delimiter (`'PAPERCUT_JSON'`) disables all expansion, so the JSON is passed byte-for-byte regardless of quotes, `$`, or backslashes in the text. `$CLAUDE_CODE_SESSION_ID` is exposed by Claude Code to Bash subprocesses — never invent or hardcode a session id; pass the variable through as-is. The gate constructs every controlled field itself, validates, scrubs, and appends to the local spool; on the strict profile it drops `repo`/`session_id` from the stored record and requires the record to clear the strict-profile denylist.

If the script exits non-zero, show the stderr reason to the user (e.g. a scrub rejection) and stop — do not retry with edited text to route around a rejection.

If it fails with a **permission prompt or denial** rather than a scrub rejection, something overrode this skill's own `allowed-tools` grant for the gate — a matching `deny`/`ask` rule, a `PreToolUse` command rewriter, or the append running outside the skill's turn. Point the user at `scripts/papercut-doctor.sh`, which prints the fallback `permissions.allow` entry to paste, and `docs/install.md` step 4.

## Step 4 — Confirm Using the Script's Output

The gate prints the final **scrubbed record** as one JSON line on stdout — use its `title` and `id` fields to confirm, not your Step 2 draft (the stored record may differ from your draft after scrubbing/truncation). For example:

> Logged papercut `pc_xxxxxxxx…`: "<title from stdout>"

On the strict profile, also note that the record was genericized (no repo or session id stored).

### False-positive check (`SCRUB_REVIEW`)

The gate also emits an optional `SCRUB_REVIEW:` line on **stderr** (exit stays 0) when the generic token scrubber redacted a run that reads as technical vocabulary rather than a secret — hyphenated or snake_case words, a SCREAMING_SNAKE name, or a camelCase identifier — e.g. it shredded `dependency-readiness` to `[token]`. When you see that line, surface the named term(s) to the user in your confirmation:

> Heads-up: the scrubber redacted `<term>` as a token, but it looks like a normal phrase. If it isn't a secret, add it to `_TOKEN_ALLOWLIST` in `papercut_append.py` (and it'll survive next time).

Only relay the terms the gate names — it withholds any redaction carrying a digit, which filters out most real secrets. That is a heuristic, not a guarantee: a letter-only secret can still be named, so read the term before relaying it rather than assuming anything the gate surfaces is safe. Don't edit the allowlist yourself unless the user asks; this is an advisory check, not an automatic exemption.

## Flush

Reached when `--flush` was passed (per Step 0 — either alone, or after logging a record). Run:

```sh
${CLAUDE_PLUGIN_ROOT}/scripts/papercut-flush.sh --force
```

This is a separate, explicit step because it has **network effects** (it pushes the local queue upstream), so it is deliberately NOT in this skill's `allowed-tools` — expect the normal Bash permission prompt and let it through.

Never pass `--hook` here. That flag exists only for the plugin's `SessionStart` hook entry: it maps every exit code to 0, which would hide a real flush failure from the user.
