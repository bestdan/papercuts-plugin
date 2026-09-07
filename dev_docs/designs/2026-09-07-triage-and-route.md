# Triage and route: the plugin files each improvement with its owner

**Status:** proposed. Design only. Merging this document is the decision; the
scripts and skills in §7 are the work that follows.

**Drafted:** 2026-09-07, from a discussion with the repo owner that settled the
ownership model in §2. Counts cited from `bestdan/dotfiles` were measured on
2026-09-05 for dotfiles#709 and are not re-derived here.

---

## 1. The problem

The plugin captures papercuts and publishes them to a ledger. It does not
triage. Triage lives in `bestdan/dotfiles` as a weekly routine
(`agents/papercuts-triage.md`) with two scope decisions baked in:

- It files every issue into `bestdan/dotfiles`, whichever repo the fix belongs
  to. The fix location is written into the body as `Target repo:`. Cross-repo
  routing was declared "a human call".
- It opens up to three draft PRs per run for fix-now items in dotfiles or the
  ledger.

The first decision produced a backlog nobody routes. On 2026-09-05, 91 open
dotfiles issues sat in `status:1_needs_refinement` with the `papercut` label;
66 of them name a target other than dotfiles. dotfiles#709 designs the one-time
cleanup of that pile. This document designs the change that stops the pile from
growing: triage moves into the plugin and files each improvement with the repo
that owns it.

## 2. Ownership model

| Layer                                           | Owner                          |
| ----------------------------------------------- | ------------------------------ |
| Capture: hooks, skill, spool, flush             | this plugin                    |
| Ledger: append-only records and resolutions     | the ledger repo                |
| Triage: fold, cluster, dedupe, judge the target | this plugin                    |
| Route: file each cluster in the owner's tracker | this plugin, through a handler |
| Handle: refine, promote, fix, close             | the owner of the target repo   |

Three consequences follow, and the rest of this document works them out.

**Triage files issues and never opens PRs.** Opening a PR is handling. The
fix-now signal survives as the `papercut-fix-now` label; what an owner does
with that label is the owner's routine, not this plugin's.

**Every issue lands with an owner, or with nobody, explicitly.** An owner is a
repo named in a registry (§3). A cluster whose target is in the registry files
there. A cluster with no identified owner files into the ledger repo's issues,
where an attended skill (§6) later names an owner or records that nobody will
fix it.

**Disposition and refinement of an existing backlog are the owner's work.**
dotfiles#709's Job A and Job B stay in dotfiles. They consume two rules from
this design — the label criterion in §5 and the resolution rule in §4.3 — and
an edit to either is a cross-repo change.

## 3. The owners registry

The registry lives in the **ledger repo**, not in the machine config. Owners are
a property of the ledger — the set of people sharing it — so every machine that
runs triage must see one map, and a change to it must be a reviewed commit. The
schema already sets this precedent: its header allows a ledger repo to carry
extension files of its own.

File: `owners.toml` at the ledger repo root, read from the clone that
`ledger.dir` names. Shape:

```toml
[unowned]
repo = "you/papercuts-ledger" # default: ledger.repo from config.toml

[owners.dotfiles]
tracker = "gh-issue"
repo = "you/dotfiles"
scope = "shell config, agent instructions, the dli command runner"
labels = ["status:0_untriaged", "auto:human-review-needed"]

[owners.workflow-skills]
tracker = "gh-issue"
repo = "you/workflow-skills"
scope = "the workflow-skills plugin: task handlers, promote/do-tasks, co-review"
labels = ["status:0_untriaged", "auto:human-review-needed"]
```

| Key             | Type            | Required | What it does                                                                                                                                                                             |
| --------------- | --------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `owners.<name>` | table           | —        | `<name>` is the target vocabulary triage picks from. It is the closed set §4.1 validates against.                                                                                        |
| `.tracker`      | string          | yes      | Handler name. Only `gh-issue` is implemented. The key is named as `workflow-skills` names its handlers (`gh-issue`, `linear`, `jira`), so a later handler is an addition, not a rename.  |
| `.repo`         | string          | yes      | `owner/name` on the ledger host.                                                                                                                                                         |
| `.scope`        | string          | yes      | One sentence for the clustering prompt. It is the only thing the model reads about an owner.                                                                                             |
| `.labels`       | array of string | no       | Owner-declared labels added to every issue filed there — for example the rungs a `workflow-skills` promoter expects. The plugin does not know any owner's schema; the owner declares it. |
| `unowned.repo`  | string          | no       | Where clusters with no identified owner file. Defaults to `ledger.repo`.                                                                                                                 |

**Targets you do not own are still named.** A cluster whose fix lands in a
repo outside your control — Claude Code itself, a third-party MCP server — has
no owner in the registry, but "unowned" alone loses what it is. An
`[external.<name>]` table names such a target without giving it a tracker:

```toml
[external.claude-code]
repo = "anthropics/claude-code"
scope = "Claude Code harness behaviour: tools, sandbox, permission classifiers, transcript"
```

An external target files into `unowned.repo` like any unowned cluster, with
`Target: claude-code (external)` in the body, so `/papercuts:reroute` can
choose between `--reported-upstream` and a workaround owner without
re-deriving what the issue is about. `scope` is required for the same reason an
owner's is. Name every target — owner or external — after its repository, so
one vocabulary serves the registry, the issue body, and the upstream link.

`scripts/papercut_owners.py` is the only reader. It parses with the same
`tomllib` path `papercut_config.py` uses, validates the shape, and exits
non-zero with a message on any error — an unparseable registry never resolves
to "no owners", for the same reason a bad `strict_hosts` never resolves to "no
patterns". Every other script takes its output; none parses the file itself.

## 4. Triage, step by step

The rule throughout: **the model proposes, a script disposes.** Two steps need
judgment — clustering (§4.1) and the semantic dedupe (§4.2) — and in each the
model writes a JSON file to a schema, a script validates it against the source
data, and only scripts write to GitHub or the ledger. Everything else is a
script with a test.

### 4.0 Inputs

1. `papercut_open.py --json` — the open set, resolutions already folded. This
   exists.
2. `papercut_owners.py` — the registry, validated.
3. `papercut_tracked.py` — the **tracked index**: for every registered repo and
   the unowned repo, a map from `pc_` id prefix to the issues that carry it,
   with each issue's state, URL, and labels. It reads issue bodies over all
   states by listing, then searches comments only for the ids with no body hit,
   because consolidated ids live in comments. It searches the **8-character
   prefix**, never the full id: the full id returns zero against issues that
   demonstrably carry it, and the 56 Linear-migrated issues carry only the
   prefix. Both facts were measured in dotfiles triage and are this script's
   first test cases.

   The comment search is the expensive part. GitHub's search API allows about
   30 requests a minute, so one query per prefix per repo — 100 open ids across
   four repos is 400 calls — takes over ten minutes and risks a secondary
   limit, which would surface as a partial index. The script batches prefixes
   with `OR` (five operators a query, so six prefixes a call), reads the
   rate-limit headers, and backs off instead of failing. The manifest records
   the call count, so a run that grew expensive says so.

The index is the seam that makes routing safe. An issue routed to any registered
owner stays visible to every later run, which is what lets §4.3 drop the
resolution-on-transfer rule.

### 4.1 Cluster and judge the target (model)

Input to the model: **every** open record, each tracked one annotated with the
issue URL the index found for it, plus each owner's `name` and `scope` from the
registry. Tracked records stay in the input so the model can cluster a new
record with the one an existing issue already tracks; the script, not the
model, decides what that means (§4.2). Output: `clusters.json`:

```json
[
  {
    "improvement": "one sentence",
    "papercut_ids": ["pc_…", "pc_…"],
    "target": "workflow-skills",
    "effort": "low",
    "confidence": "high"
  }
]
```

`papercut_clusters.py --validate` then checks, and refuses the whole file on the
first failure:

- every open id appears in exactly one cluster;
- every id in the file is an open id — the model may not invent one;
- `target` is an owner name, an external name, or the literal `unowned`. A
  variant spelling is a validation error, not a new owner. The 2026-08-16 dotfiles run wrote the
  harness four ways and split one improvement into three issues; a closed set
  enforced by a script closes that class of error rather than warning about it;
- `effort` and `confidence` are each one of `low`, `medium`, `high`.

The script computes **severity** itself as the maximum across the cluster's
records. The model is not asked for it: it is derivable, so deriving it is the
deterministic choice.

The prompt carries the clustering rules dotfiles triage learned the hard way:
cluster by the friction, never by target or severity; infer the target from
where the fix would land, never from the record's `repo` field, which names
where the papercut was observed. Those rules move from
`agents/papercuts-triage.md` Step 2 into `skills/triage/SKILL.md` verbatim.

### 4.2 Dedupe (script, then model)

Two passes, in the order that keeps the model's share small.

**Id pass (script).** The script classifies each validated cluster by the
tracked index:

- all ids untracked → a candidate for filing; goes to the semantic pass;
- all ids tracked → nothing to do; the cluster is already an issue;
- mixed → a **partial match**: the script attaches the untracked ids to the
  tracked ids' issue as a `**Consolidation:**` comment — the convention dotfiles
  triage already uses — and files nothing new. Tracked ids that span more than
  one issue are a validation error the run reports; the model may not merge
  two existing issues.

"Tracked" here means tracked by an **open** issue. A reroute (§6) closes the
source and opens a successor carrying the same ids, so a span check over all
states would refuse every such cluster forever. Closed issues still populate
the index — a consolidated id on a since-closed issue is still tracked — but
only open issues pick the consolidation target.

**Semantic pass (model).** For each remaining cluster, the script lists the
open issues in the cluster's target repo (all labels — the `papercut` label only
exists from 2026-08-16 and a label-bounded scan hides the long-lived trackers
most likely to match). The model marks any cluster that restates an open issue
in `consolidations.json` as `{"cluster": i, "issue": "<url>"}`. The script
validates that the issue exists, is open, and is in the cluster's target repo,
then writes the consolidation comment instead of filing. A recurrence count on
one issue is the signal worth keeping; a second issue destroys it.

### 4.3 File (script)

`papercut_file.py` takes the validated clusters and the consolidations and does
the writes. Default is a dry run that prints the plan; `--apply` files. Per
cluster:

1. **Look up the owner.** `unowned` and every external name resolve to
   `unowned.repo`; the body keeps the target name.
2. **Label pre-flight.** The label set is the plugin's own —
   `papercut`, `priority:<severity>`, and `papercut-fix-now` when
   `effort == low` and `confidence == high` — plus the owner's declared
   `labels`. The set checked is the **union of what this run will write to that
   owner**, not the plugin's whole vocabulary: an owner with no fix-now cluster
   this run is not held back for `papercut-fix-now`. The script reads the
   target's labels once per repo and checks each name in that union. **If one
   is missing, the script files nothing into that owner** and
   reports the owner, the missing names, and the clusters held back. It never
   creates a label in someone else's repo unattended, and never files with a
   name silently dropped — `gh issue create` fails on an unknown label, so the
   failure would be loud, but the check turns a mid-run failure into a plan
   line. Held-back clusters wait in the ledger's open set; nothing is lost.
3. **Render the body** from a fixed template — the improvement, the target,
   severity/effort/confidence, one line per source papercut with its full
   `pc_` id, the merged `suggested_fix`. The ids are the dedup key every later
   run matches on, so the template is the contract and has a test.
4. **Create the issue**, one `gh issue create --repo <owner> --body-file …` per
   cluster, serially. Never a body on the command line (backticks), never a
   fan-out (a large parallel batch leaves siblings silently failed).
5. **Record** the issue URL against the cluster in the run manifest (§4.5).

**A routed issue takes no ledger resolution.** dotfiles#709 §4.6 writes
`out-of-scope` on transfer because every dotfiles search is scoped to dotfiles,
so a transferred issue leaves the search while its papercut stays open. The
tracked index searches every registered repo, so the papercut stays visible and
stays open — correctly, because it is unfixed — until the owner merges a fix
and §4.4 writes `fixed`. Writing `out-of-scope` at file time would go through
the ledger's one-way door: `papercut-resolve.sh` refuses a second resolution,
so the papercut could never become `fixed`.

`out-of-scope` keeps its ledger definition, "real and ours, tracked in a repo
this ledger doesn't track", and the registry makes "tracks" precise: it applies
to a target **outside** the registry — a re-file into a Linear project, for
instance — and `reported-upstream` applies to a third-party tracker. Those are
attended dispositions (§6); triage never writes either.

### 4.4 Resolve what merged (script)

`papercut_fixed.py` walks the tracked index for issues that are **closed**. For
each, it reads the issue's `CLOSED_EVENT` timeline item and its `closer`
(GraphQL `timelineItems(itemTypes: CLOSED_EVENT) { closer { ... on PullRequest
{ merged url } ... on Commit { url } } }`) and keeps only a closer that is a
**merged pull request**. A merged PR is the one piece of hard evidence an
unattended run may act on; a commit closer, a manual close, and `completed`
with no closer all go to the manifest as closed-without-evidence. The
2026-07-31 dotfiles run found seven papercuts still open weeks after their
fixes merged because this step was left to a human.

- Closed with a merged PR → `papercut-resolve.sh <id> fixed <pr-url>` for each
  id the issue carries. Double-resolution is refused by the script, so the step
  is safe to re-run.
- Closed **without** a merged PR closer — `not planned`, a commit closer, or
  `completed` with no closer → reported in the manifest for the attended skill.
  `completed` is a claim, not evidence.
- Closed, but every id it carries is also on an **open** issue → skipped. That
  is a rerouted source (§6), not a fix, and it must not report itself every
  week.

Then, on the default profile only, `papercut-flush.sh --force` publishes the
resolutions, and its confirmation line is the evidence the run summary quotes.
`--force` bypasses the strict-profile hold (`papercut-flush.sh` says so in its
header), so triage detects the profile first, through the same seam flush uses,
and on a strict machine skips the call: the manifest records "resolutions
spooled, not published (strict profile)" and the next default-profile flush
carries them.

### 4.5 Run manifest and summary

Every script appends to one JSON manifest for the run: filed, consolidated,
held back (and why), resolved, closed-without-evidence. `papercut_summary.py`
renders the one-line summary from it:

```
Papercuts triage 2026-09-07: 14 improvements — 9 filed (3 owners), 2 consolidated, 1 held (labels), 4 resolved, 2 unowned.
```

No report file is committed. Issues carry the dedup keys, the ledger carries the
resolutions, and the manifest is a per-run artifact at
`~/.claude/papercuts/triage/<run-date>.json`, overridable with
`PAPERCUT_TRIAGE_DIR` — the same local-state convention every other path in
`docs/configuration.md` follows.

## 5. The label criterion, restated for filing

dotfiles#709 §4.1 established that `gh issue transfer` silently drops labels the
target lacks, and that the criterion is the **source issue's labels**, not a
schema's namespaces. Filing has the mirror property: `gh issue create` fails
outright on a label the target lacks. Both lead to the same rule, and §4.3
step 2 is where this design applies it: **every label the plugin is about to
write must already exist in the target, verified before the first write.**

Provisioning is attended. `scripts/papercut-labels.sh <owner>|--all [--apply]`
lists the labels an owner is missing and creates them with `--apply`, using
`gh label create --force`, which updates rather than errors when the label
already exists. `papercut-doctor.sh` gains a read-only `owners` check that
parses the registry and names each owner's missing labels; it never creates
them, matching its existing contract.

Prompting for provisioning at setup time, and prompting in response to a
held-back owner, are follow-ups the owner named and this design does not
specify.

## 6. The attended skill: reroute

`/papercuts:reroute <issue-url>` is the route layer run attended on one issue.
It exists to drain the unowned pile and to act on what §4.4 could not.

| Argument                    | What the script does                                                                                                                                                                              |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--target <owner>`          | Re-files the issue in the owner's repo through §4.3 (same body template, same pre-flight, consolidation comments folded into the new body), then closes the source with a pointer to the new URL. |
| `--wontfix`                 | Closes the issue `not planned` and writes `wontfix` for each `pc_` id it carries. "Nobody will fix this" is what `wontfix` means; the schema gets no sixth status.                                |
| `--out-of-scope <url>`      | The target is outside the registry and the work is tracked at `<url>`. Closes with the pointer and writes `out-of-scope <url>`.                                                                   |
| `--reported-upstream <url>` | As above with `reported-upstream <url>`.                                                                                                                                                          |

Re-file, not `gh issue transfer`: transfer works only between repos under one
account, drops labels the target lacks, and needs a separate code path when it
cannot run. One path, tested once.

The skill is attended because every branch is a judgment call. Triage never
takes any of them.

## 7. What gets built

Scripts, each with a `tests/<name>.test.sh` and a `gh` seam
(`PAPERCUT_GH_CMD`, the same pattern as `PAPERCUT_APPEND_CMD`) so tests run
offline against fixtures:

| Script                         | Role                                                  |
| ------------------------------ | ----------------------------------------------------- |
| `scripts/papercut_owners.py`   | registry reader and validator                         |
| `scripts/papercut_tracked.py`  | tracked index across registered repos                 |
| `scripts/papercut_clusters.py` | validates `clusters.json`; computes severity          |
| `scripts/papercut_file.py`     | pre-flight, body render, file, consolidate; `--apply` |
| `scripts/papercut_fixed.py`    | merged-PR detection and `fixed` resolutions           |
| `scripts/papercut_summary.py`  | manifest → summary line                               |
| `scripts/papercut-labels.sh`   | attended label provisioning                           |
| `scripts/papercut-reroute.sh`  | the §6 dispositions                                   |

Skills, each a thin sequence of script calls plus the two prompts the model
must answer:

- `skills/triage/SKILL.md` → `/papercuts:triage`. Unattended-safe: it makes no
  judgment call that a script does not validate. Scheduling is the user's; a
  dotfiles routine calls the skill weekly.
- `skills/reroute/SKILL.md` → `/papercuts:reroute`. Attended.

Docs: `docs/operations.md` gains a triage section; `docs/configuration.md`
documents `owners.toml`; `README.md` replaces "It does not triage" with what it
does and does not do now — it triages and routes; it does not open PRs or
refine.

## 8. Rejected alternatives

**Route by the record's `repo` field.** It names where the papercut was
observed, is often a worktree name, and is absent on strict-profile records.
66 of dotfiles' 91 came from dotfiles sessions and belong elsewhere.

**A default owner instead of an unowned pile.** Filing unroutable clusters into
one owner's repo recreates the backlog this design exists to stop, in the repo
of whoever happens to be the default. Papercuts arrive from outside any repo —
external agents, strict machines — and "no identified owner" is the honest
state. The ledger repo's issues hold them because the ledger owner is the one
person positioned to name an owner.

**Registry in `config.toml`.** Per-machine: two machines could route one
cluster to two owners, and nobody sharing the ledger could review the map.

**Triage creates missing labels itself.** Unattended writes to another owner's
repo configuration. Holding the cluster back costs one attended command;
creating the label costs a surprise in someone else's label list.

**Move Job A and Job B into the plugin.** Considered on 2026-09-07 and rejected
on ownership: the 91 belong to dotfiles, so disposing of them is dotfiles'
handling work. Recorded in dotfiles#709 §3 as well.

**`gh issue transfer` in reroute.** See §6.

## 9. Out of scope

- The sandbox-trust-boundary check dotfiles triage runs before filing a
  loosening request. That is dotfiles policy against a dotfiles design record;
  it belongs in the owner's handling, not in the plugin's triage.
- Any handler other than `gh-issue`. The registry key leaves room; nothing
  else does the work.
- Retiring `agents/papercuts-triage.md` once this ships, and what the dotfiles
  routine becomes (a handling routine that acts on `papercut-fix-now`). That is
  a dotfiles change and the dotfiles owner's call.
- The existing 91: dotfiles#709.
