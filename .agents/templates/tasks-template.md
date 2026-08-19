---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Tasks: {Feature Name}

Based on [ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) task format, with time tracking.

**PRD:** [prd-{slug}.md](prd-{slug}.md)
**Created:** {YYYY-MM-DD}
**Status:** Not Started | In Progress | Blocked | Complete
**Estimate:** ~{total} (ai:{ai_time} test:{test_time} read:{read_time})

<!--TOON:tasks_meta{id,feature,prd,status,est,est_ai,est_test,est_read,logged,started,completed}:
tasks-{slug},{Feature Name},prd-{slug},not_started,{est},{est_ai},{est_test},{est_read},{YYYY-MM-DDTHH:MMZ},,
-->

## Relevant Files

- `path/to/file1.ts` - {Brief description of why this file is relevant}
- `path/to/file1.test.ts` - {Existing test relevant to the change; omit when none applies}
- `path/to/file2.ts` - {Brief description}

## Notes

- Prioritise time-to-functional and verify through the existing production-facing path, standard logs, and framework systems
- Run applicable existing required tests with the project-specific command; do not add tests by default or create test infrastructure without approval
- Check off tasks as you complete them by changing `- [ ]` to `- [x]`
- Time estimates use format: `~Xh (ai:Xh test:Xh)`

## Instructions

**IMPORTANT:** As you complete each task, check it off by changing `- [ ]` to `- [x]`.

Update after completing each sub-task, not just parent tasks.

## Tasks

- [ ] 0.0 Create safe linked worktree for {Feature Name} ~5m (ai:5m)
  - [ ] 0.1 Fetch latest main for worktree base: `git fetch origin main`
  - [ ] 0.2 Create safe linked worktree: `aidevops worktree add feature/{slug}`
  - [ ] 0.3 `cd` into the printed linked worktree path; this keeps edits off canonical `main`/`master` and preserves an auditable branch/worktree boundary.

- [ ] 1.0 {First Parent Task} ~{Xh} (ai:{Xh} test:{Xh})
  - [ ] 1.1 {Sub-task description} ~{Xm}
  - [ ] 1.2 {Sub-task description} ~{Xm}
  - [ ] 1.3 {Sub-task description} ~{Xm}

- [ ] 2.0 {Second Parent Task} ~{Xh} (ai:{Xh} test:{Xh})
  - [ ] 2.1 {Sub-task description} ~{Xm}
  - [ ] 2.2 {Sub-task description} ~{Xm}

- [ ] 3.0 {Third Parent Task} ~{Xh} (ai:{Xh} test:{Xh})
  - [ ] 3.1 {Sub-task description} ~{Xm}
  - [ ] 3.2 {Sub-task description} ~{Xm}

- [ ] 4.0 Functional verification ~{Xh} (ai:{Xm} test:{Xh})
  - [ ] 4.1 Exercise the requested behaviour through the existing user/API/CLI path ~{Xm}
  - [ ] 4.2 Inspect standard logs, observability, or framework diagnostics ~{Xm}
  - [ ] 4.3 Run applicable existing targeted and affected-package checks; broaden only when change evidence requires it ~{Xm}

- [ ] 5.0 Documentation ~{Xm} (ai:{Xm} read:{Xm})
  - [ ] 5.1 Update relevant documentation ~{Xm}
  - [ ] 5.2 Add code comments where needed ~{Xm}
  - [ ] 5.3 Update CHANGELOG.md ~{Xm}

- [ ] 6.0 Quality & Review ~{Xm} (ai:{Xm} test:{Xm})
  - [ ] 6.1 Run changed-file/affected lint: `.agents/scripts/linters-local.sh --changed` ~{Xm}
  - [ ] 6.2 Self-review code changes ~{Xm}
  - [ ] 6.3 Commit with descriptive message ~{Xm}
  - [ ] 6.4 Push worktree ref and create PR ~{Xm}

<!--TOON:tasks[7]{id,parent,desc,est,est_ai,est_test,status,actual,completed}:
0.0,,Create safe linked worktree,5m,5m,,pending,,
1.0,,{First Parent Task},{Xh},{Xh},{Xh},pending,,
2.0,,{Second Parent Task},{Xh},{Xh},{Xh},pending,,
3.0,,{Third Parent Task},{Xh},{Xh},{Xh},pending,,
4.0,,Functional verification,{Xh},{Xm},{Xh},pending,,
5.0,,Documentation,{Xm},{Xm},,pending,,
6.0,,Quality & Review,{Xm},{Xm},{Xm},pending,,
-->

## Time Tracking

| Task | Estimated | Actual | Variance |
|------|-----------|--------|----------|
| 0.0 Create safe linked worktree | 5m | - | - |
| 1.0 {Task 1} | {Xh} | - | - |
| 2.0 {Task 2} | {Xh} | - | - |
| 3.0 {Task 3} | {Xh} | - | - |
| 4.0 Functional verification | {Xh} | - | - |
| 5.0 Documentation | {Xm} | - | - |
| 6.0 Quality | {Xm} | - | - |
| **Total** | **{Xh}** | **-** | **-** |

<!--TOON:time_summary{total_est,total_actual,variance_pct}:
{Xh},,
-->

## Completion Checklist

Before marking this task list complete:

- [ ] All tasks checked off
- [ ] Requested behaviour verified through the real path; applicable existing required checks pass
- [ ] Linters passing
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] PR created and ready for review
- [ ] Time actuals recorded
