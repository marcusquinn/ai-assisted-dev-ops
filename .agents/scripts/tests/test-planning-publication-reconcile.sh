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
VERIFY_PATTERN='_publication_issue_has_labels "$issue_json" "$desired_labels"'
# shellcheck disable=SC2016
SAFE_EDIT_PATTERN='gh_issue_edit_safe "$issue_num" --repo "$repo"'

# shellcheck source=../planning-publication-reconcile.sh
source "$RECONCILER"

task_line='- [ ] t9000 Reconcile publication #auto-dispatch #bug ~1h ref:GH#77 logged:2026-08-11'
desired_labels=$(_publication_desired_labels "$task_line")
[[ ",${desired_labels}," == *",auto-dispatch,"* ]]
[[ ",${desired_labels}," == *",bug,"* ]]
issue_json='{"labels":[{"name":"publication:pending"}]}'
[[ "$(_publication_status_label "$desired_labels" 0 "$issue_json")" == "status:available" ]]
issue_json='{"labels":[{"name":"auto-dispatch"},{"name":"bug"},{"name":"status:available"}]}'
_publication_issue_has_labels "$issue_json" 'auto-dispatch,bug,status:available'
[[ -z "$(_publication_desired_labels '- [ ] t9001 Manual task ~1h ref:GH#78 logged:2026-08-11')" ]]
blocked_task_line='- [ ] t9002 Blocked publication #auto-dispatch #bug ~1h blocked-by:t9000 ref:GH#79 logged:2026-08-11'
_publication_task_has_dependency "$blocked_task_line"
[[ "$(_publication_status_label "$desired_labels" 1 '{"labels":[{"name":"publication:pending"}]}')" == "status:blocked" ]]
[[ -z "$(_publication_status_label "$desired_labels" 1 '{"labels":[{"name":"status:in-progress"}]}')" ]]
printf 'PASS production helpers project and verify intended labels\n'

grep -Fq '_publication_exact_default_snapshot' "$RECONCILER"
grep -Fq '_publication_validate_mapping' "$RECONCILER"
grep -Fq 'verify-brief-helper.sh" check-readiness' "$RECONCILER"
grep -Fq -- "$REMOVE_PATTERN" "$RECONCILER"
grep -Fq -- "$SAFE_EDIT_PATTERN" "$RECONCILER"
if grep -Fq 'gh-write-helper.sh" issue edit' "$RECONCILER"; then
	exit 1
fi
grep -Fq 'Reconcile pending planning publication' "$WORKFLOW"
grep -Fq -- "$WORKFLOW_PATTERN" "$WORKFLOW"

remove_line=$(grep -n -- "$REMOVE_PATTERN" "$RECONCILER" | cut -d: -f1)
verify_line=$(grep -n -m1 -- "$VERIFY_PATTERN" "$RECONCILER" | cut -d: -f1)
[[ "$remove_line" -gt "$verify_line" ]]

awk '
	/name: Reconcile pending planning publication/ { publication_line = NR }
	/name: Reconcile issue relationships/ { relationship_line = NR }
	/name: Enrich plan-linked issues/ { enrichment_line = NR }
	END {
		exit !(publication_line > 0 && publication_line < relationship_line && publication_line < enrichment_line)
	}
' "$WORKFLOW"

grep -Fq 'continue-on-error: true' "$WORKFLOW"
grep -Fq "if: always() && steps.check-author.outputs.skip != 'true'" "$WORKFLOW"
awk '
	/name: Reconcile pending planning publication/ { publication_line = NR }
	/name: Reconcile issue relationships/ { relationship_line = NR }
	/name: Report planning publication failure/ { failure_line = NR }
	END { exit !(publication_line < relationship_line && relationship_line < failure_line) }
' "$WORKFLOW"

mutation_log=$(mktemp)
cleanup() {
	rm -f "$mutation_log"
	return 0
}
trap cleanup EXIT

_publication_validate_mapping() {
	local task_id="$1"
	local issue_num="$2"
	printf -- '- [ ] %s Partial batch #auto-dispatch #bug blocked-by:t9000 ref:GH#%s\n' "$task_id" "$issue_num"
	return 0
}

gh_issue_edit_safe() {
	local issue_num="$1"
	shift
	printf '%s %s\n' "$issue_num" "$*" >>"$mutation_log"
	if [[ "$issue_num" == "78" && "$*" == *"--add-label"* ]]; then
		return 1
	fi
	if [[ "$issue_num" == "80" && "$*" == *"--remove-label status:available,status:blocked"* ]] && \
		grep -q '^80 .*--remove-label publication:pending' "$mutation_log"; then
		return 1
	fi
	return 0
}

gh() {
	local command="$1"
	local subcommand="$2"
	local issue_num="$3"
	local labels='[{"name":"publication:pending"}]'
	: "$command" "$subcommand"
	if grep -q "^${issue_num} .*--add-label" "$mutation_log"; then
		labels='[{"name":"publication:pending"},{"name":"auto-dispatch"},{"name":"bug"},{"name":"status:blocked"}]'
	fi
	if [[ "$issue_num" == "79" && "$labels" == *"status:blocked"* ]]; then
		labels='[{"name":"publication:pending"},{"name":"auto-dispatch"},{"name":"bug"},{"name":"status:blocked"},{"name":"status:in-progress"}]'
	fi
	if [[ "$issue_num" == "80" ]] && grep -q '^80 .*--remove-label publication:pending' "$mutation_log"; then
		labels='[{"name":"auto-dispatch"},{"name":"bug"},{"name":"status:blocked"},{"name":"status:in-progress"}]'
	fi
	if grep -q "^${issue_num} .*--remove-label status:available,status:blocked" "$mutation_log"; then
		labels='[{"name":"publication:pending"},{"name":"auto-dispatch"},{"name":"bug"},{"name":"status:in-progress"}]'
	fi
	if grep -q "^${issue_num} .*--remove-label publication:pending" "$mutation_log"; then
		labels="${labels//\{\"name\":\"publication:pending\"\},/}"
	fi
	printf '{"number":%s,"title":"t%s: Partial batch","state":"OPEN","labels":%s}\n' \
		"$issue_num" "$((8923 + issue_num))" "$labels"
	return 0
}

failed=0
_publication_reconcile_one example/repo t9000 77 || failed=$((failed + 1))
_publication_reconcile_one example/repo t9002 79 || failed=$((failed + 1))
_publication_reconcile_one example/repo t9003 80 || failed=$((failed + 1))
_publication_reconcile_one example/repo t9001 78 || failed=$((failed + 1))
[[ "$failed" -eq 2 ]]
grep -q '^77 .*--add-label auto-dispatch,bug,status:blocked' "$mutation_log"
grep -q '^77 .*--remove-label status:available' "$mutation_log"
grep -q '^77 .*--remove-label publication:pending' "$mutation_log"
grep -q '^79 .*--remove-label status:available,status:blocked' "$mutation_log"
grep -q '^79 .*--remove-label publication:pending' "$mutation_log"
grep -q '^80 .*--add-label publication:pending' "$mutation_log"
grep -q '^80 .*--remove-label status:available,status:blocked' "$mutation_log"
if grep -q '^78 .*--remove-label publication:pending' "$mutation_log"; then
	exit 1
fi

printf 'PASS exact-SHA mapping validation precedes blocker removal\n'
printf 'PASS default-branch workflow reconciles publication before maintenance\n'
printf 'PASS partial batches leave earlier dependencies blocked and later failures pending\n'
