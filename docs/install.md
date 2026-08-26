# Install

Read this before you install: **captured records leave your machine.** The
flusher commits and pushes them to a git repo you own. Make that repo private,
and read [what the scrub does and does not cover](../README.md#what-it-does-not-do)
before you point the pipeline at confidential work.

Steps 1-3 get the pipeline installed and identified. Steps 4 and 5 are the two
things the plugin deliberately does **not** ship: the permission rule for the
append gate, and the sandbox write-allowlist paths. Both are user-scope policy —
a plugin must not grant itself the right to run a script or to write outside the
sandbox. Add them yourself. Step 6 verifies the whole thing.

## Prerequisites

- `python3` 3.11 or newer. The gate, the compactor, and the config resolver are
  pure stdlib; 3.11 is the floor for `tomllib`.
- `git`, and push access to the ledger repo you will create in step 2.
- A logged-in `claude` CLI on `PATH`, **for auto-capture only.** Manual captures
  through `/papercuts:papercut` never call a model. Auto-capture does:
  `scripts/extractor-run.sh` shells out to `claude -p --model haiku` with a JSON
  schema over the compacted transcript. Without a `claude` on `PATH` that can
  authenticate, `SessionEnd` capture fails (transiently, and silently — the
  session is unaffected) and only manual captures land.
- **Each extraction is a metered model call.** One Haiku call per non-trivial
  session that reaches `SessionEnd`, plus one per session the `SessionStart`
  backstop sweep rescues. It bills against whatever account your `claude` CLI is
  logged in to. A triviality pre-filter drops sessions with no friction signal
  before the call, so quiet sessions cost nothing.

### The extractor's isolation flags, and the CLI version they were checked against

`extractor-run.sh` runs the model with four isolation flags: `--safe-mode`,
`--tools ''`, `--no-session-persistence`, and `--system-prompt-file`. Its header
comment records the verification, verbatim:

> `Isolation (verified against claude 2.1.209 by hand)`

That is the whole basis for the claim: **hand-verified against `claude` CLI
2.1.209 specifically.** Nothing here is inferred from documentation. The flags do,
per that verification:

- `--safe-mode` — disables CLAUDE.md, skills, plugins, hooks, MCP, and custom
  commands, so transcript content cannot reach your own hooks or an injected
  plugin. Auth, model selection, and permissions still work normally, which is
  why `--bare` is not used: `--bare` forces `ANTHROPIC_API_KEY`/`apiKeyHelper`
  and never reads OAuth or the keychain, so it breaks on a machine authenticated
  with `claude login` and no API key.
- `--tools ''` — no tools at all, so a successful prompt injection from
  transcript content has nothing to call.
- `--no-session-persistence` — the extraction run is not resumable and leaves no
  session file behind.
- `--system-prompt-file` — **replaces** the default Claude Code system prompt
  rather than appending to it. Load-bearing, not stylistic: with
  `--append-system-prompt-file` the model receives both the interactive-coding-agent
  prompt and the extractor prompt's "you have no tools, you are not participating
  in the conversation", a direct contradiction it then reported as a false
  high-severity papercut.

**Re-verify if you run a later CLI.** These are flag names and flag semantics on
one tested version. A later `claude` that renames, removes, or changes the
behavior of any of the four silently weakens the isolation — nothing in this
repo detects that. `extractor-run.sh`'s header carries the two commands that
reproduce the `--system-prompt-file` check (run them separately, not as one brace
expansion, which compares nothing).

## 1. Install the plugin

Install it from the marketplace this repo publishes:

```sh
claude
/plugin marketplace add https://github.com/bestdan/papercuts-plugin.git
/plugin install papercuts@papercuts-plugin
```

Or clone it and load it with `--plugin-dir` instead:

```sh
git clone https://github.com/bestdan/papercuts-plugin.git ~/src/papercuts-plugin
claude --plugin-dir ~/src/papercuts-plugin
```

The two are equivalent for the hooks and the skill. One caveat:
`CLAUDE_PLUGIN_DATA` was observed with an `-inline` suffix under a `--plugin-dir`
install, and whether a marketplace install produces a different data path is
untested. Nothing in the pipeline depends on `CLAUDE_PLUGIN_DATA`, but the
resolved plugin root does differ between install methods, which matters if you
ever add the fallback permission rule in step 4 — run the doctor and paste what
it prints rather than reusing a path from another machine.

A marketplace install resolves under
`~/.claude/plugins/cache/papercuts-plugin/papercuts/<version>/`. **That path
carries the version**, so every release moves it. Capture does not depend on it
staying put — the skill re-resolves its own grant at load time (step 4) — but a
path-pinned permission rule does: if you added one, re-run the doctor and paste
the new line after an upgrade. A `--plugin-dir` install has no version segment
and never moves.

The skill is namespaced by the plugin, so it is invoked as
`/papercuts:papercut`, not `/papercut`.

## 2. Create the ledger repo

The ledger is a plain git repo holding one JSONL file per month under `ledger/`.
Nothing else. **Make it private** — it holds friction records from your real
sessions.

```sh
gh repo create you/papercuts-ledger --private
git clone git@github.com:you/papercuts-ledger.git ~/src/papercuts
```

`~/src/papercuts` is the default clone location. Change it with `ledger.dir` in
the config file, or `PAPERCUT_LEDGER_DIR`.

The flusher only ever pushes to an origin URL the config trusts: it must match
the configured `host`/`repo` pair, or an exact `ledger.remote_url`. A clone whose
origin points anywhere else is refused, not published to.

## 3. Config file

Publishing needs a ledger identity. Write `~/.config/papercuts/config.toml`:

```toml
[ledger]
repo = "you/papercuts-ledger"
```

Invoked directly with no resolvable ledger identity, `papercut-flush.sh` refuses
and exits non-zero. The `SessionStart` hook invokes it as
`papercut-flush.sh --hook`, which logs that failure and exits 0 instead, so a
missing config never disrupts a session.

Other keys, all optional: `ledger.host` (default `github.com`), `ledger.dir`
(default `~/src/papercuts`), `ledger.remote_url` (an exact-match escape hatch for
a remote the host/repo forms cannot express), and `profile.strict_hosts`, an
array of hostname glob patterns. A machine whose hostname matches any pattern
resolves to the **strict profile**, which requires a populated denylist and
stores no `repo` or `session_id`. See `scripts/papercut_config.py` for every key
and every config-file location.

### The denylist, on a strict host

On a strict host, capture is **fail-closed at the gate**: a present, non-empty,
non-world-readable denylist is required, and any record whose _pre-redaction_
text matches a literal is rejected whole rather than redacted. A missing or empty
denylist rejects every record — nothing is persisted locally and nothing is
synced. That is the intended staged rollout, not a misconfiguration.

```sh
mkdir -p ~/.config/papercuts
umask 077
# One case-insensitive literal per line: internal repo names, project codenames,
# ticket prefixes, team and person names, internal hostnames and system names.
# See denylist.example.txt for the format.
$EDITOR ~/.config/papercuts/denylist.txt
chmod 0600 ~/.config/papercuts/denylist.txt
```

Never commit the denylist anywhere — it names the exact things that must not
leak. An _incomplete_ denylist is worse than none: it turns capture on while
still missing terms. Populate it deliberately.

On a default host no denylist is required. If one exists, its literals are
redacted rather than rejected.

## 4. Permission rule for the append gate (usually unnecessary)

The `/papercuts:papercut` skill pipes a record to `papercut_append.py`, and the
skill authorizes that call itself: its frontmatter declares an `allowed-tools`
grant for the gate, Claude Code resolves `${CLAUDE_PLUGIN_ROOT}` in it to this
install's absolute path at skill-load time, and the grant holds for the turn
that invokes the skill. Verified empirically: in a headless session — where an
unapproved call is denied outright rather than prompted — with no papercuts
entry anywhere in `permissions.allow`, the skill appended a record cleanly.

So skip this step on a first install. Add the rule below only if a capture
actually stops on a permission prompt for `papercut_append.py`, which means
something in your setup overrode the skill's own grant:

- a matching `deny` or `ask` rule — those win over `allowed-tools`;
- a `PreToolUse` command rewriter — the matcher runs against the **rewritten**
  command, so the skill's grant no longer matches and your allow rule must
  name the rewritten form;
- an append invoked outside the skill's own turn — the grant does not outlive
  the turn that loaded the skill.

The fallback rule, in `permissions.allow` in your `settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(python3 /Users/you/.claude/plugins/papercuts/scripts/papercut_append.py:*)"
    ]
  }
}
```

**The path must be the resolved absolute path on your machine.** A literal
`${CLAUDE_PLUGIN_ROOT}` in a permission rule never matches: Claude Code
substitutes that variable when it loads the skill, so the command that actually
runs — and that the permission matcher sees — already carries the absolute path.
Run `scripts/papercut-doctor.sh` and paste the line it prints rather than
guessing the install directory. On a marketplace install that path moves with
every release, so the rule needs re-pasting after each upgrade — one more
reason to lean on the skill's own grant and add this rule only when you have
seen it needed.

## 5. Sandbox write-allowlist

The pipeline writes the spool under `~/.claude/papercuts` and clones the ledger
into `~/src/papercuts`. Both are outside a default sandbox.

Add to `sandbox.filesystem.allowWrite` in your `settings.json`:

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.claude/papercuts",
        "~/src/papercuts"
      ]
    }
  }
}
```

Change these paths if you moved the spool (`PAPERCUT_SPOOL`) or the ledger clone
(`ledger.dir` in the config file, or `PAPERCUT_LEDGER_DIR`).

## 6. Verify with the doctor

```sh
~/src/papercuts-plugin/scripts/papercut-doctor.sh
```

It is read-only and never publishes. It prints one `PASS`/`FAIL` line per check
and exits non-zero if any failed. The checks, by name:

| Check         | What it means                                                            |
| ------------- | ------------------------------------------------------------------------ |
| `config`      | the config file exists, parses, and names a ledger                       |
| `ledger`      | the clone exists and its origin URL is one the config trusts             |
| `denylist`    | the denylist state matches the resolved profile                          |
| `spool-perms` | the spool directory is `0700` (absent is fine — first append creates it) |
| `hooks`       | `hooks/hooks.json` is present and its scripts are executable             |
| `claude-path` | `claude` is on `PATH` (auto-capture only; manual capture works without)  |

It finishes by printing the exact `permissions.allow` entry to paste, with the
absolute path of _this_ install resolved — it reads its own location, not `PWD`,
so run the copy inside the install you actually loaded.

Then log a record by hand with `/papercuts:papercut` to confirm the gate and the
permission rule agree, and check that it landed:

```sh
cat ~/.claude/papercuts/spool.jsonl
```

It is flushed to the ledger on the next `SessionStart`, or immediately with
`/papercuts:papercut --flush`.
