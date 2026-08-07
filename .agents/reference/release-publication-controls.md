<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release Publication Controls

This index defines the rollout boundary for repository release settings. Code
hardening and live-setting mutation are separate checkpoints; changing
repository, environment, npm, or tag-policy settings requires explicit
maintainer operation approval.

## Contents

| Chapter | Use it for |
|---|---|
| [Controls and history](release-publication-controls/controls-and-history.md) | Signed-tag provenance, aggregation and supersession recovery, Actions permissions, approved live state, and the audited rollout sequence. |

## Non-negotiable boundary

Do not create a release, package, deployment, or test tag to validate a live
settings change. Use the chapter's read-only snapshot and verifier procedures,
then retain their captured rollback evidence.
