---
created: 2026-09-07
aim: "move the papercut backlog disposition/refinement design into this plugin and build the two jobs it specifies"
branch: bestdan/papercut-refinement-design
pr: https://github.com/bestdan/dotfiles/pull/709
expires: "when the design lands here and dotfiles#709 is closed"
---

# Papercut backlog disposition and refinement

## Why you are reading this

`bestdan/dotfiles` has 91 open issues labelled `status:1_needs_refinement` +
`papercut` that no automation will ever touch again. A design for clearing them
was written **in dotfiles** and reviewed there — dotfiles#709. The repo owner
then decided the work belongs in **this plugin** instead, because it is
papercut-pipeline machinery rather than dotfiles configuration.

Your job is that move, and then the build. The design is done and reviewed; do
not re-derive it.

## Read this first

**The design document is dotfiles#709**, branch
`bestdan/papercut-refinement-design-2`, file
`dev_docs/designs/2026-09-05-papercut-refinement-job.md` (492 lines). Read the
whole thing before writing anything. Two commits: the original, then a second
correcting four things co-review found.

Its companion is `agents/papercuts-triage.md` in dotfiles — the weekly
unattended triage routine that **produces** this backlog. The new jobs are
deliberately not part of it.

## What the design says, in one paragraph

Two prompt files, not one. **Job A** is a batch disposition sweep: attended,
mechanical, works the whole set, and routes / dedupes / expires / promotes.
**Job B** is per-issue refinement: on demand, deep research, writes acceptance
criteria. A runs first because 66 of the 91 name a repo `bestdan/dotfiles`
cannot fix, so most of the backlog is a routing problem, and running B first
means paying research cost on issues that should have been transferred.

## Findings that are load-bearing — do not re-litigate these

Each was verified against installed source, not inferred. If you change the
design, change it knowing these:

1. **`status:1_needs_refinement` is terminal.** `gh-issue-promote.md` scores
   only un-scored issues and no handler writes one back out of that rung. So
   refining a body accomplishes nothing without a deliberate state write.
   dotfiles#331 has full acceptance criteria and has sat in that rung since
   2026-08-09 for exactly this reason.
2. **A state write needs both rungs.** `gh-issue-state.py` validates the label
   set locally and raises `expected exactly one 'auto:' label, got 0`. The reset
   is `status:0_untriaged,auto:human-review-needed` plus the issue's existing
   `prio:`/`est:` labels, which the helper deletes if you omit them.
3. **A transfer needs a ledger resolution.** The ledger defines `out-of-scope`
   as "real and ours, tracked in a repo this ledger doesn't track" — a transfer
   exactly. Every triage dedupe query is scoped to `bestdan/dotfiles`, so a
   transferred issue leaves the search while its papercut stays open, and next
   week's triage re-files it.
4. **Absence from `papercut_open.py` proves nothing about a fix.** The fold keys
   on a resolution record existing, never on its status.
5. **The transfer label criterion is the source issue's labels, not the
   schema's.** Not one of the 91 carries a `prio:` label; all 91 carry
   `priority:high|medium|low`, which `gh-label-sync.py` does not provision. The
   design carries the full census.

## What is NOT settled

- **Where the design document itself lands here.** This repo has no `dev_docs/`
  at all — you are creating it. Decide whether the design belongs at
  `dev_docs/designs/`, or whether it should be folded into the two prompt files
  and not kept as a separate document.
- **Where the two prompt files live.** In dotfiles they were specified as
  `agents/papercuts-disposition.md` and `agents/papercuts-refinement.md`,
  siblings of `papercuts-triage.md`. In this plugin the natural homes are
  `prompts/` or `skills/` — this repo already has both, and the choice decides
  whether they are invoked as skills or read as routines.
- **Whether `papercuts-triage.md` moves too.** The design deliberately kept the
  new jobs out of triage, but the argument for moving this work into the plugin
  applies to triage at least as strongly, and triage still lives in dotfiles.
  The design does not address this; it is a genuine open question.

## Prerequisites the design names, neither of which is done

1. **`bestdan/workflow-skills` needs labels provisioned** before the 28
   `workflow-skills`-targeted issues transfer: the three `priority:*` names, the
   legacy `auto-eligible` / `human-approval-requested` pair, `papercut-fix-now`,
   and `task-add`. `gh-label-sync.py` provisions none of them.
2. **That repo's `dev_docs/tasks/.task-config.yml` still says
   `handler: linear`.** The owner settled on 2026-09-05 that its tracker of
   record is GitHub Issues, and its issues carry the schema labels — but while
   the config says otherwise, `/promote-tasks` and `/do-tasks` there run against
   Linear and will not see transferred issues at all.

## The next concrete step

Read dotfiles#709 in full, then decide the two placement questions above and put
the answers to the repo owner before building. The design is worth its length —
several of its rules exist because the obvious version of the rule was tried on
paper and shown to fail.

## Loose ends elsewhere

- dotfiles#709 stays open until this lands. Closing it is the owner's call, not
  yours.
- `dev_docs/.handoff.md` in the dotfiles main checkout is the **older** handoff
  that started this work. It is superseded by #709 and should be deleted when
  that PR resolves.
- `bestdan/workflow-skills#496` is unrelated to the design but was filed from
  the same session: `/local-review` is unreachable over SSH.
- This worktree adds `dev_docs/.handoffs/` to `.gitignore` and to `dprint.json`'s
  excludes, matching the dotfiles convention. Without the dprint entry a handoff
  file fails `dprint check` — its `**/*.md` include matches dot-prefixed paths.

---

**When the work described above is done, delete this file.** It is a handoff,
not a record. If what it says is worth keeping, it belongs in a commit message,
a PR body, a design doc, or the tracker — move it there first, then delete this
file.
