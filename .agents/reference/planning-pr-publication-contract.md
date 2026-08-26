<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Planning PR Publication Contract

Protected-default planning PR bodies carry one deterministic publication
marker and one machine-readable marker per validated changed task:

```text
<!-- aidevops:planning-publication:v1 id=<content-derived-id> -->
<!-- aidevops:planning-task:v1 task=t123 issue=456 -->
- For #456
```

Task candidates come from changed TODO entries and changed
`todo/tasks/t*-brief.md` paths. Every candidate must resolve to exactly one
current TODO entry with exactly one local `ref:GH#NNN`. The body emits each
unique issue as a non-closing `For` reference in deterministic order. A
single-task publication uses `plan(tNNN): ...`; multi-task publications keep
the batch title rather than selecting an arbitrary task.

The content-derived publication ID also names the planning branch. A retry
verifies and reuses a matching pushed commit or open PR. A terminal failure
reports `AIDEVOPS_PLANNING_RECOVERY_*` fields for the publication, branch,
commit, remote/PR/source states, and disposable-worktree cleanup state. Caller
planning edits and the sole durable commit are preserved; temporary worktrees
are removed on every terminal path unless cleanup itself fails visibly.
