#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
GH_CALLS="${TMP_DIR}/gh-calls"

print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
log_verbose() { return 0; }
ensure_labels_exist() { return 0; }
gh_create_label() { return 0; }
gh_find_issue_by_title() { return 0; }
add_gh_ref_to_todo() { return 0; }
require_task_issue_mapping() { return 0; }
session_origin_label() { printf '%s\n' 'origin:interactive'; }
_rest_should_fallback() { return 1; }

# shellcheck source=../issue-sync-helper-push.sh
source "${SCRIPTS_DIR}/issue-sync-helper-push.sh"

gh() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	if [[ "$1 $2" == "issue create" ]]; then
		printf '%s\n' 'https://github.com/owner/repo/issues/77'
		return 0
	fi
	if [[ "$1 $2" == "issue view" ]]; then
		printf '%s\n' "${PENDING_LABEL_VISIBLE:-true}"
		return 0
	fi
	return 0
}

run_create() {
	: >"$GH_CALLS"
	_PUSH_CREATED_NUM=""
	AIDEVOPS_PLANNING_PUBLICATION_STATE="$1" \
		_push_create_issue t9000 owner/repo "${TMP_DIR}/TODO.md" \
		"t9000: publication test" body "auto-dispatch,tier:standard,status:available" ""
}

run_create pending
pending_args=$(grep '^issue create' "$GH_CALLS")
[[ "$pending_args" == *'tier:standard,publication:pending,origin:interactive'* ]]
[[ "$pending_args" != *'auto-dispatch'* ]]
[[ "$pending_args" != *'status:available'* ]]
printf 'PASS pending issue creation withholds positive dispatch labels\n'

run_create canonical
canonical_args=$(grep '^issue create' "$GH_CALLS")
[[ "$canonical_args" == *'auto-dispatch,tier:standard,status:available,origin:interactive,status:available'* ]]
[[ "$canonical_args" != *'publication:pending'* ]]
printf 'PASS canonical issue creation retains dispatch projection\n'

if PENDING_LABEL_VISIBLE=false run_create pending; then
	printf 'FAIL pending creation succeeded without verified blocker\n' >&2
	exit 1
fi
printf 'PASS pending issue creation fails when blocker verification fails\n'

grep -Fq 'AIDEVOPS_PLANNING_PUBLICATION_STATE=pending' "${SCRIPTS_DIR}/new-task-helper.sh"
grep -Fq -- '--publication-state pending' "${SCRIPTS_DIR}/new-task-helper.sh"
grep -Fq '#auto-dispatch' "${SCRIPTS_DIR}/new-task-helper.sh"
printf 'PASS batch planning retains intent while creating pending issues\n'

grep -Fq "'publication:pending'" \
	"${SCRIPTS_DIR}/../../.github/workflows/apply-status-available-default.yml"
printf 'PASS platform status default excludes pending publication\n'
