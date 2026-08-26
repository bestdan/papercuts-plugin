# Plugin surface — verified, not assumed

Evidence for `papercuts_oss_task_1`. Every answer here was produced by installing
a throwaway probe plugin and observing what happened. Nothing in this file comes
from documentation or memory.

**Why this file exists.** The published documentation was checked first and was
**wrong by omission** on the question that decides the whole packaging approach:
it does not list `Notification` as a hook event at all. `Notification` is real,
it is in production use in `bestdan/dotfiles`, and — as recorded below — it does
reach a plugin. A plan built on the documented list would have concluded the
pipeline could not be packaged as a plugin, and would have been wrong.

Probe run: 2026-08-25, `claude` CLI, macOS. Two sessions.

## Method

A minimal plugin with one hook per event. Each hook ran the same script, which
appended the event name, the three path variables, `PWD`, and the raw stdin
payload to a log at a **fixed absolute path** — deliberately not a
plugin-relative one, so that "the variable did not resolve" and "the hook never
fired" stay distinguishable.

```
papercut-probe/
  .claude-plugin/plugin.json
  hooks/hooks.json
  hooks/probe.sh
  skills/probe/SKILL.md
```

Installed with:

```
claude --plugin-dir /path/to/papercut-probe
```

## 1. Manifest

`.claude-plugin/plugin.json`, at the plugin root. The probe's manifest carried
`name`, `description`, and `version`, and loaded.

## 2. Hooks declaration

`hooks/hooks.json`, at the plugin root — **not** inside `.claude-plugin/`. Same
shape as `settings.json` hooks:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/probe.sh SessionStart"
          }
        ]
      }
    ]
  }
}
```

A hook command takes arguments. The probe passed the event name as `$1` and read
it back correctly.

## 3. Hook event availability — the load-bearing answer

All four events the pipeline needs **do** reach a plugin. Verified by observing
one log entry per event.

| Event                | Reaches a plugin | How it was triggered                       |
| -------------------- | ---------------- | ------------------------------------------ |
| `SessionStart`       | Yes              | Starting the probe session                 |
| `SessionEnd`         | Yes              | Exiting the session                        |
| `PostToolUseFailure` | Yes              | Asking the agent to run `cat /nonexistent` |
| `Notification`       | Yes              | A permission prompt                        |

**`Notification` is the one that mattered.** It is absent from the published hook
event list, so it had to be tested rather than assumed. `CwdChanged` is likewise
absent from the docs and likewise in production use in `agents/settings.json`,
which is corroborating evidence that the documented list is a subset.

A note on how `PostToolUseFailure` was triggered, because the first attempt
produced a false negative: a `!`-prefixed shell command typed by the user is not
an agent tool call and does not fire it. The agent must actually invoke the tool.

## 4. Path variables

All three resolve inside a hook command:

| Variable                | Value observed                                 |
| ----------------------- | ---------------------------------------------- |
| `${CLAUDE_PLUGIN_ROOT}` | the installed plugin's own directory           |
| `${CLAUDE_PLUGIN_DATA}` | `~/.claude/plugins/data/papercut-probe-inline` |
| `${CLAUDE_PROJECT_DIR}` | the project root                               |

`CLAUDE_PLUGIN_ROOT` resolved to the plugin directory while `PWD` was the user's
project directory, which is the property that replaces the hardcoded absolute
`$HOME/...` script paths the dotfiles checkout used.

**Carry this forward:** `CLAUDE_PLUGIN_DATA` ended in `-inline`. The probe was
installed with `--plugin-dir`. Whether a marketplace install produces a different
data path is **not tested**, and task 5 must not assume the two agree.

## 5. Skill invocation

Plugin skills are **always namespaced**: `/papercut-probe:probe` resolved.

Consequence for the port: the skill becomes `/papercuts:papercut`, not
`/papercut`. This changes `dev_docs/papercuts.md` and the "papercut is a term of
art" routing bullet at `agents/AGENTS.md:81`, which currently routes to
`/papercut`.

## 6. Payload shapes

Common to every event: `session_id`, `transcript_path`, `cwd`,
`hook_event_name`. Most also carry `prompt_id`.

Per event, as observed:

- **`SessionStart`** — `source` (`"startup"`), `model`.
- **`SessionEnd`** — `reason` (`"prompt_input_exit"`).
- **`Notification`** — `message` (`"Claude needs your permission"`),
  `notification_type` (`"permission_prompt"`). The type field means a consumer
  can distinguish a permission prompt from other attention requests without
  parsing prose.
- **`PostToolUseFailure`** — `tool_name`, `tool_input`, `tool_use_id`, `error`
  (the full text, including exit code), `is_interrupt`, `duration_ms`,
  `permission_mode`, `effort`.

Two of these are worth more than they look for the extractor: `is_interrupt`
separates a user-cancelled call from a genuine failure, and `permission_mode`
records whether the failure happened under auto mode.

`tool_input` holds the command **after** any `PreToolUse` rewriting. The probe
recorded `rtk read /nonexistent` where the agent had written `cat /nonexistent`.
A consumer reading `tool_input` is reading what ran, not what the model wrote.

## Second probe — 2026-08-25 (task 5)

Two of the open questions below were closed by a second round of headless
probes, run the same way (a throwaway plugin, a fixed-absolute-path log).

### `"async": true` and per-command `"timeout"` are accepted

A plugin's `hooks/hooks.json` takes both keys per hook command. The manifest
loaded, the hooks fired, and `${CLAUDE_PLUGIN_ROOT}` still resolved to the
installed plugin directory with them present. So the production wiring in
`agents/settings.json` ports across verbatim — `async: true` on all five entries,
`timeout: 5` on the two anchor entries, `timeout: 180` on `SessionEnd`.

### `${CLAUDE_PLUGIN_ROOT}` in a SKILL.md is substituted at skill-load time

Inside a plugin's `SKILL.md` the variable is replaced with the **absolute
installed path** before the agent reads the file. The agent therefore never sees
the literal `${CLAUDE_PLUGIN_ROOT}` string — it sees a real path — and the env
var `CLAUDE_PLUGIN_ROOT` is **not** set in the Bash tool environment, so a
command that tries to expand it at runtime gets an empty string.

**Consequence:** if a user adds the fallback `permissions.allow` entry
(install.md step 4 — usually unnecessary, since the skill's own `allowed-tools`
grant covers the append for its turn), the entry must name the resolved
absolute path on their machine.
A rule holding a literal `${CLAUDE_PLUGIN_ROOT}` can never match what runs.
`scripts/papercut-doctor.sh` prints the exact entry for the install it ships
inside, which is why the doctor resolves paths from its own location rather than
from `PWD`.

## Open — not settled by this probe

- **Marketplace vs `--plugin-dir` install.** Only `--plugin-dir` was tested. The
  `-inline` suffix on `CLAUDE_PLUGIN_DATA` is a hint that the two differ.
- **Hook stdout semantics.** The probe always exited 0 and wrote nothing to
  stdout, so what a plugin hook can return to influence the session is untested.
  The pipeline's hooks are all fail-silent and need nothing here, but a future
  gate that wants to block would.
