#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_TASK="${SCRIPT_DIR}/../new-task-helper.sh"
PLANNING_COMMIT="${SCRIPT_DIR}/../planning-commit-helper.sh"
PULSE_RECONCILE="${SCRIPT_DIR}/../pulse-issue-reconcile.sh"
PUBLICATION_RECONCILE="${SCRIPT_DIR}/../planning-publication-reconcile.sh"
WORKFLOW_DOC="${SCRIPT_DIR}/../../workflows/new-task.md"

grep -Fq 'AIDEVOPS_PLANNING_COMMIT_RESULT=' "$PLANNING_COMMIT"
grep -Fq '_BATCH_PUBLICATION_RESULT="failed"' "$NEW_TASK"
grep -Fq 'all created issues remain publication:pending' "$NEW_TASK"
grep -Fq '_repair_pending_planning_publications' "$PULSE_RECONCILE"
grep -Fq 'AIDEVOPS_PUBLICATION_RECONCILE_LIMIT=10' "$PULSE_RECONCILE"
grep -Fq 'PUBLICATION_BLOCKED_LABEL="status:blocked"' "$PUBLICATION_RECONCILE"
grep -Fq '_publication_task_has_dependency' "$PUBLICATION_RECONCILE"
# Matching the literal variable reference in source.
# shellcheck disable=SC2016
grep -Fq -- '--remove-label "$PUBLICATION_AVAILABLE_LABEL"' "$PUBLICATION_RECONCILE"
grep -Fq 'closed-unmerged' "$WORKFLOW_DOC"
grep -Fq 'reported as queued' "$WORKFLOW_DOC"

printf 'PASS batch publication outcomes remain pending on failure\n'
printf 'PASS pulse recovery is bounded and documentation is fail-closed\n'
printf 'PASS dependency-bearing publication projects a blocked lifecycle state\n'
