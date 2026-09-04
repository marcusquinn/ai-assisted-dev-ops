<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feedback Plane: CLI, Routines, and Implementation Boundary

Detailed contract chapter for `.agents/aidevops/feedback.md`.

## CLI Design

The public surface is `aidevops feedback <command>`. Phase 5 defines the
contract only; command wiring belongs in a follow-up implementation task after
the capture, retention, mining, and promotion contracts are stable.

```bash
# Capture one feedback item into _feedback/captures/
aidevops feedback capture --source <uri-or-label> --channel <channel> --text <text>
aidevops feedback capture --file path/to/note.md --source <uri-or-label> --channel <channel>

# List retained captures and mined themes
aidevops feedback list
aidevops feedback list --state captured|mined|promoted|retired --sensitivity public|internal|client-scoped|privileged|personal|delete-after-review --since 2026-05-01

# Mine captures into candidate themes with evidence thresholds
aidevops feedback mine
aidevops feedback mine --since 30d --segment <segment> --min-evidence 3 --dry-run

# Promote a reviewed capture or theme into another plane
aidevops feedback promote <feedback-id|theme-id> --to knowledge|campaign|project|case|performance|task --reason <why>

# Retire sensitive, obsolete, duplicate, or consent-expired feedback
aidevops feedback retire <feedback-id|theme-id> --reason <why> [--delete-raw]
```

### `capture`

Creates a normalized capture record under `_feedback/captures/`.

Inputs:

- `--source`: source URI, local label, issue/PR reference, meeting note, survey,
  social thread, support ticket, or operator-provided label.
- `--channel`: `client`, `support`, `survey`, `social`, `sales`, `product`,
  `retrospective`, or repo-local extension value.
- `--text` or `--file`: the raw feedback body. File mode preserves formatting
  and avoids shell-history exposure for sensitive text.
- Optional metadata: `--actor`, `--segment`, `--context`, `--sentiment`,
  `--sensitivity`, `--consent`, `--retain-until`, `--case`, `--project`,
  `--campaign`, `--tags`.

Output:

- Prints the capture ID, path, sensitivity tier, retention state, and next
  recommended action (`review`, `mine`, or `retire`).
- Appends an audit entry to `_feedback/index/audit.log` when an index exists.

### `list`

Shows retained captures and mined themes without exposing raw sensitive text by
default.

Inputs:

- Filters: `--state`, `--channel`, `--sensitivity`, `--segment`, `--tag`,
  `--since`, `--until`, `--promoted-to`, `--retired`, `--json`.
- Raw body display requires an explicit `--show-body` flag and must still redact
  secrets and privileged snippets.

Output:

- Human table: ID, date, channel, segment, sensitivity, state, evidence count,
  promotion target, and age/retention warning.
- JSON mode: stable machine-readable records for routine reports.

### `mine`

Clusters captures into candidate themes and records the evidence behind each
theme. One-off comments remain captures; repeated or high-severity patterns
become mined themes.

Inputs:

- Scope: `--since`, `--until`, `--channel`, `--segment`, `--case`, `--project`,
  `--campaign`, `--tag`.
- Thresholds: `--min-evidence`, `--min-segments`, `--require-review`,
  `--include-sensitive`, `--dry-run`.

Output:

- Creates or updates `_feedback/themes/<theme-id>.md` with summary, evidence
  IDs, confidence, sensitivity roll-up, suggested promotion target, and reviewer
  decision fields.
- Prints counts for captures scanned, new themes, updated themes, rejected
  singletons, and sensitivity holds.
- Dry-run prints the same report without writing theme files.

### `promote`

Moves reviewed feedback or mined themes into the destination plane while keeping
the source evidence traceable.

Inputs:

- `<feedback-id|theme-id>` plus `--to knowledge|campaign|project|case|performance|task`.
- Destination selectors as needed: `--campaign <id>`, `--project <id>`,
  `--case <id>`, `--metric <name>`, `--title <task-title>`.
- `--reason` is required and must explain why the evidence is promotion-worthy.

Output:

- Writes the destination artifact or task draft using the promotion-path contract.
- Updates source state to `promoted`, records destination path or issue number,
  and appends an audit entry.
- Never auto-promotes privileged/client feedback without a review marker or
  cryptographic maintainer approval path defined by the retention policy.

### `retire`

Marks feedback as no longer available for mining or promotion.

Inputs:

- `<feedback-id|theme-id>` plus required `--reason`.
- Reasons: `duplicate`, `obsolete`, `consent-expired`, `sensitive`,
  `client-delete`, `merged`, `low-signal`, or repo-local extension value.
- `--delete-raw` removes or redacts raw body content only when retention policy
  allows deletion; otherwise the command writes a tombstone.

Output:

- Updates state to `retired`, records reason, actor, timestamp, and replacement
  ID when applicable.
- Excludes the item from future `mine` runs unless `--include-retired` is used.

## Routine Design

Recurring jobs live in `TODO.md` under `## Routines`; deterministic scripts are
preferred over agent dispatch when no judgment is needed.

```markdown
- [x] r-feedback-mine Feedback mining report — cluster new captures and surface candidate themes repeat:weekly(mon@09:00) ~5m run:scripts/feedback-helper.sh mine --since 7d --min-evidence 3 --report
- [x] r-feedback-retention Feedback retention audit — flag expired consent, privileged holds, and stale raw captures repeat:weekly(mon@09:30) ~3m run:scripts/feedback-helper.sh retention-audit
- [ ] r-feedback-promotion Feedback promotion review — summarize approved themes awaiting destination decisions repeat:weekly(mon@10:00) ~10m agent:Build+
```

Routine evidence:

- Mining report records captures scanned, themes created/updated, evidence count
  per theme, sensitivity holds, and recommended promotion targets.
- Retention audit records expired retention windows, consent gaps, raw captures
  older than policy, and retirement actions taken.
- Promotion review records themes ready for `_knowledge/`, `_campaigns/`,
  `_projects/`, `_cases/`, `_performance/`, or TODO/GitHub task creation.
- Each tick appends JSONL audit rows to `_feedback/index/audit.log` and prints a
  concise markdown summary suitable for a pulse or routine comment.

## Implementation Boundary

This document is design-only. Do not wire `aidevops feedback` into
`.agents/scripts/aidevops.sh` until the earlier phase contracts are stable:

1. Capture schema and required metadata.
2. Retention and sensitivity policy.
3. Mining workflow and evidence thresholds.
4. Promotion path formats and review gates.

The first implementation task should create a dedicated
`.agents/scripts/feedback-helper.sh` and have `aidevops.sh` delegate to it,
mirroring other plane helpers rather than growing the main CLI file.
