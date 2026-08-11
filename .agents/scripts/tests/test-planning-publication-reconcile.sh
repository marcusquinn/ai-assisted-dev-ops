#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILER="${SCRIPT_DIR}/../planning-publication-reconcile.sh"
WORKFLOW="${SCRIPT_DIR}/../../../.github/workflows/issue-sync-reusable.yml"
# Literal source snippets: dollar-prefixed names must not expand in this test.
# shellcheck disable=SC2016
REMOVE_PATTERN='--remove-label "$PUBLICATION_PENDING_LABEL"'
# shellcheck disable=SC2016
WORKFLOW_PATTERN='--repo "$PUBLICATION_REPO" --sha "$PUBLICATION_SHA"'
# shellcheck disable=SC2016
VERIFY_PATTERN='_publication_issue_has_labels "$issue_json" "$projected_labels"'

# shellcheck source=../planning-publication-reconcile.sh
source "$RECONCILER"

task_line='- [ ] t9000 Reconcile publication #auto-dispatch #bug ~1h ref:GH#77 logged:2026-08-11'
desired_labels=$(_publication_desired_labels "$task_line")
[[ ",${desired_labels}," == *",auto-dispatch,"* ]]
[[ ",${desired_labels}," == *",bug,"* ]]
[[ "$(_publication_status_label "$desired_labels")" == "status:available" ]]
issue_json='{"labels":[{"name":"auto-dispatch"},{"name":"bug"},{"name":"status:available"}]}'
_publication_issue_has_labels "$issue_json" 'auto-dispatch,bug,status:available'
[[ -z "$(_publication_desired_labels '- [ ] t9001 Manual task ~1h ref:GH#78 logged:2026-08-11')" ]]
printf 'PASS production helpers project and verify intended labels\n'

grep -Fq '_publication_exact_default_snapshot' "$RECONCILER"
grep -Fq '_publication_validate_mapping' "$RECONCILER"
grep -Fq 'verify-brief-helper.sh" check-readiness' "$RECONCILER"
grep -Fq -- "$REMOVE_PATTERN" "$RECONCILER"
grep -Fq 'Reconcile pending planning publication' "$WORKFLOW"
grep -Fq -- "$WORKFLOW_PATTERN" "$WORKFLOW"

remove_line=$(grep -n -- "$REMOVE_PATTERN" "$RECONCILER" | cut -d: -f1)
verify_line=$(grep -n -m1 -- "$VERIFY_PATTERN" "$RECONCILER" | cut -d: -f1)
[[ "$remove_line" -gt "$verify_line" ]]

printf 'PASS exact-SHA mapping validation precedes blocker removal\n'
printf 'PASS default-branch workflow invokes bounded reconciliation\n'
