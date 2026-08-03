<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Identity Parser Inventory

Updated for issue #27149. The shared lexical contract is
`.agents/scripts/task-identity-lib.sh`. This inventory prevents broad regex
replacement. Critical lifecycle consumers migrated in #27149 are marked below;
remaining numeric-only production parsers retain explicit owners.

| Consumer group | Representative production files | Migration concern |
|---|---|---|
| Allocation and counters | `claim-task-id.sh`, `claim-task-id-counter.sh`, `claim-task-id-issue.sh` | Emit canonical unpadded legacy IDs until the coordinator gate enables namespaced IDs |
| TODO parsing and issue sync | Migrated: `issue-sync-lib-parse.sh`, `issue-sync-lib-ref.sh`, `issue-sync-helper-commands.sh`. Remaining owner (issue-sync): `issue-sync-helper-enrich.sh`, `issue-sync-helper-close.sh` | Parse tokens through the codec and require explicit repository context for legacy resolution |
| Dependency resolution | Migrated: `pulse-dep-graph.sh`. Remaining owner (lifecycle): `issue-sync-relationships.sh`, `parent-status-helper.sh` | Do not strip the `t` prefix or assume the identity body is numeric |
| Brief and plan lookup | Migrated: `task-brief-helper.sh`. Remaining owner (planning): `verify-brief.sh`, `list-todo-helper.sh`, `todo-ready.sh`, `show-plan-helper.sh` | Use canonical tokens as opaque filename and lookup keys after validation |
| Worktree and session routing | Migrated: `worktree-helper-add.sh`, `pre-edit-check.sh`. Remaining owner (worktree): `interactive-session-helper.sh` | Avoid partial numeric extraction from namespaced branch tokens |
| PR and dispatch identity | `full-loop-helper-commit.sh`, `dispatch-dedup-helper.sh`, `pulse-dispatch-core.sh`, `pulse-merge-conflict.sh`, `shared-gh-wrappers-create.sh`, `gh` | Preserve complete tokens in titles, markers, dedup keys, and provenance checks |
| Release and completion | Migrated: `version-manager-git.sh`. Remaining owner (release): `task-complete-helper.sh`, `pre-commit-hook.sh` | Extract complete validated tokens and retain legacy behavior |
| Collision guards and CI | Migrated: `.agents/hooks/task-id-collision-guard.sh`. Remaining owner (CI): `install-task-id-guard.sh`, `.github/workflows/task-id-collision-check.yml` | Scope legacy collisions by verified home repository and namespaced collisions globally |
| Secondary integrations | `beads-sync-helper.sh`, `email-triage-helper.sh`, `self-evolution-helper-todo.sh`, `memory-graduate-helper.sh`, `session_time_common.py` | Replace display-oriented numeric matching only when the integration accepts both forms |

The migration must inventory tests with each production consumer, retain
numeric-only fixtures, and add namespaced and malformed fixtures. Matches in
examples, generated patches, vendored content, or unrelated words such as
`timeout` are not production parsers and must not be mechanically rewritten.

Historical zero-padded IDs remain migration input for counter seeding and
collision detection, but they are not canonical aliases. Migrations must reject
an ambiguous rewrite when both a padded token and its unpadded form exist.

The dependency cache currently validates at most 500 fetched issues through the
shared shell codec. The pulse-performance owner should restore batched cache
construction only when the batch transports broad candidates back through this
codec; a second task-ID grammar in `jq` is not an acceptable optimisation.
