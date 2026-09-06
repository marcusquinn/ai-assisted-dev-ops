---
description: Captured-state forge-loss recovery, acknowledgement and adapter limits
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Forge portability

## Ownership and bounded guarantee

The repository owns task identity, plans, material decisions, progress and necessary
evidence. A forge owns its execution conversation, not the only copy of that
knowledge. Recover **captured records**, not unobserved remote history. This is not
a universal backup/import engine or a claim of four-provider parity.

Keep `TODO.md`, complete `todo/tasks/` briefs, referenced plans and evidence in a
reachable commit and a verified independent repository backup. A forge-hosted Git
remote alone is not independent of losing that forge/account. Preserve the task
counter branch and all required refs in the backup before allocating new IDs.
Uncommitted files and dangling Git objects are not the durable acknowledgement
point. Runtime/session databases and generated Beads caches are not required for
the bounded recovery below, nor substitutes for missing source records.

## Write paths and coverage matrix

Paths below are relative to `.agents/scripts/` unless otherwise stated.

| Path/direction | What is retained or generated | Recovery boundary |
| --- | --- | --- |
| `claim-task-id.sh`, `claim-task-id-counter.sh`: Git CAS allocation → tracker mapping | Stable `tNNN` identity; counter state; separate GH/GL issue reference | ID reservation is not a complete task brief. Preserve counter refs; offline offset allocation does not prove fleet-wide uniqueness. |
| `planning-publisher.sh`: local `TODO.md`/`todo/` → Git snapshot/publication | File blobs, commit, publication/handoff digest; conflict detection | Content is recoverable from a reachable backed-up commit. Local receipt files alone are not portable authority; no whole-forge export. |
| `issue-sync-lib-compose.sh`: TODO/brief → issue body | Task metadata, dependencies, brief content, generated worker guidance | Generated views are not a lossless archive of their inputs (frontmatter/promotion formatting can change). Back up source files, not only the composed body. |
| `issue-sync-lib-ref.sh`: foreign-ref updates → TODO | Existing task identity plus mapping updates | Retain original provider/host/repository identity when migrating; never reinterpret GH numbers as IDs on another host. |
| `issue-sync-helper-commands.sh` `cmd_pull`: GitHub → TODO | Refs, missing assignees, orphan task stubs | Not a body/comment/evidence importer; bounded issue listing is not a complete event cursor or archive. |
| `issue-sync-helper-close.sh`: completion observations ↔ TODO/issue state | Selected completion evidence interpreted into local state/remote close | Source comment bodies and all revisions are not automatically retained. A checked box is not a full evidence archive. |
| `issue-sync-relationships.sh`: TODO dependencies → GitHub edges; backfill from GitHub | Declared task relationships and provider edge views | GitHub-specific; native-only edges need explicit local capture before they are recoverable. Resume caches are not canonical plans. |
| `brief-readiness-helper.sh stub`: GitHub body → full local brief | Entire observed body, opaque body fields, title, URL, node ID, remote revision time, capture time and coverage marker | Repaired here. Create-only; no overwrite, comments, attachments, PR reviews or later-event ingestion. |
| `beads-sync-helper.sh`: markdown ↔ Beads export | Derived task graph; pull requires reconciliation | Ignored SQLite/JSONL is not a durable backup. Beads-only fields require capture before rebuilding. No Beads restore proof is claimed here. |

### Adapter status

| Adapter | Supported surface inspected | Not implemented/proven by this exercise |
| --- | --- | --- |
| GitHub | Issue composition/ref sync, relationships, new body capture through `gh issue view` | Continuous acknowledged event ingestion, comments/reviews/attachments archive, full re-publication after account loss |
| GitLab | Allocation code has GL mapping/issue creation | Equivalent recovery/export, incoming event cursor, dependencies and evidence round-trip |
| Gitea | Allocation detects Gitea; generic Git snapshot remains usable | Lossless issue/event adapter and recovery proof |
| Forgejo | Generic Git snapshot remains usable | Distinct detection and full issue/event recovery adapter; do not infer support from Gitea similarity |

No third-party API mapping was changed. The repair uses existing `gh_issue_view`
and supported `gh issue view --json body,title,url,updatedAt,id` fields; validation
used gh 2.98.0, Bash 5.2 and the existing jq/ShellCheck toolchain. The offline
fixture deliberately has no live account dependency.

## Persistence and acknowledgement

1. **Outgoing:** write generated plans, dependencies, decisions, progress and
   necessary evidence into the repo record first. Commit and verify those paths
   before publishing the forge view. Existing publication helpers cover planning
   snapshots, not every worker comment; this contract must not be mistaken for
   universal automated enforcement.
2. **Incoming:** observe remote content as untrusted data. Capture its source
   identity, remote revision/time, observation time, scope and required evidence.
   Review/redact sensitive data before committing it to the appropriate repository
   or approved protected knowledge store. A successful fetch or `stub` file write
   is not yet a durable acknowledgement: commit and verify the retained record.
3. **Lag:** `captured_at` records observation time; `updatedAt` is the observed body
   revision time, not a comments cursor. Coverage is explicitly `issue-body-only`.
   Everything after that observation and every excluded surface is unknown. There
   is no event-stream watermark, bounded-lag guarantee or “fully synced” claim.
4. **Authority:** capturing an approval, assignee or historical command does not
   authorize execution. Revalidate current ownership, policy, dependency state,
   permissions and any cryptographic approval before resuming external actions.

### Conflicts, retry and rollback

`stub` keeps its old arguments but now captures content instead of writing a link.
It validates a non-empty observation, writes a temporary file and publishes via a
create-only hard link. Failed capture/write returns failure; its task-brief caller
must not substitute a success claim. A retry on an existing brief preserves it
byte-for-byte and explicitly reports that it was not refreshed or backfilled.

The assigned task owner reconciles simultaneous local/remote changes using the
last captured revision and both versions. Never last-writer-wins a material
decision. Keep the original evidence and unknown fields; commit a reviewed
resolution. Existing pointer stubs are **not** silently upgraded: back up TODO and
todo records, capture the remote version separately while still available, compare,
then integrate without deleting local/session-specific context. If the forge is
already lost, label the missing material unrecoverable rather than invent it.

No schema migration or destructive conversion is required. Older markdown readers
still read the brief. Rollback can revert the writer while retaining all captured
files; do not replace full captures with pointers. Restoring the same backup must
not allocate tasks, publish issues, clear holds or replay historical actions.

## Offline exercise

```bash
bash .agents/scripts/tests/test-forge-portability.sh
bash .agents/scripts/tests/test-brief-readiness.sh
bash .agents/scripts/test-issue-sync-lib.sh
.agents/scripts/linters-local.sh --changed
git diff --check
```

The focused fixture creates a complete task body with dependencies, progress,
evidence and an opaque future field, captures it through the real legacy command,
and checks exact body/provenance retention. It commits TODO, a plan, the brief and
evidence to an isolated repository and exports a Git bundle. It then deletes the
remote observation, disables forge access in the CLI fixture and restores twice
with an empty HOME (no session DB). Identical Git trees prove **all** captured
files survive, not just issue counts. Repeated capture leaves the restored files
unchanged and makes no additional forge calls. Unavailable/incomplete observations
fail without creating a brief; existing pointer stubs remain unchanged.

For operational recovery, use an independent verified backup, restore into an
isolated worktree, inventory missing referenced artifacts, and keep execution
paused until authority is revalidated. Inspect raw source records before rebuilding
derived views. Attach replacement-host mappings alongside original provenance;
there is no tested automatic provider migration command in this change.

## Individually actionable remaining work

These are separate bounded work packages, not completion claims. The assigned
issue/PR carries this backlog for the brief owner; this worker does not mutate
unassigned sibling issues.

| Gap | Target and reference pattern | Acceptance/verification |
| --- | --- | --- |
| GitHub incoming events | `issue-sync-helper-commands.sh` and close readers; use create-only capture as preservation precedent | Paginated comments/reviews and revisions with explicit cursor/partial-failure state; offline export retains edits, deletions, opaque fields and evidence without replaying authority. |
| Outgoing progress durability | Worker completion/comment writers (exact owners require call-site discovery); planning publisher snapshot precedent | Fault injection between local commit and remote write proves every generated material update is retained and retries do not duplicate actions. |
| Existing pointer backfill | `brief-readiness-helper.sh` and task-brief caller | Backup-first, reviewed three-way reconciliation; old local fields survive, unavailable sources remain explicitly incomplete. |
| GitLab adapter | `claim-task-id.sh` GL branch plus provider adapter paths to discover | Verify installed glab API first; body/comments/dependencies/evidence round-trip and offline idempotency fixture. |
| Gitea adapter | Allocation detection plus provider adapter paths to discover | Preserve host-qualified refs, paginated events and opaque fields; offline restore twice with no identity churn. |
| Forgejo adapter | Detection/allocation and provider adapter paths to discover | Explicit support instead of inferred parity; same loss fixture plus cross-host numeric-ID collision case. |
| Beads-only records | `beads-sync-helper.sh`, `tools/task-management/beads.md` | Verify installed bd export schema; preserve unmapped fields before rebuilding and prove round-trip without force-overwrite. |

All adapter follow-ups require collision discovery and their own write-surface and
verification contract. Do not broaden this repair into a general state engine.
