# Install

The plugin ships the hooks and the skill. Two things it deliberately does **not**
ship: the permission rule for the append gate, and the sandbox write-allowlist
paths. Both are user-scope policy — a plugin must not grant itself the right to
run a script or to write outside the sandbox. Add them yourself.

Run `scripts/papercut-doctor.sh` after installing. It checks every piece and
prints the permission entry below with the path already resolved for your
machine.

## 1. Permission rule for the append gate

The `/papercuts:papercut` skill pipes a record to `papercut_append.py`. Without
this rule every capture stops on a permission prompt.

Add to `permissions.allow` in your `settings.json`:

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
guessing the install directory.

If you use `rtk` (or any other `PreToolUse` command rewriter), the matcher runs
against the **rewritten** command, so add the rewritten twin as well.

## 2. Sandbox write-allowlist

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

See `scripts/papercut_config.py` for every key and every config-file location.
