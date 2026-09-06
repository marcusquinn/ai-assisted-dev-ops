#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"
TODO_FILE="${TEST_ROOT}/TODO.md"
printf '%s\n' '- [ ] t101 first repository task ref:GH#42' '- [ ] t102 second repository task ref:GH#42' '- [ ] t1873.1 dotted task ref:GH#73' '- [ ] t201 GraphQL repository task ref:GH#88' >"$TODO_FILE"

_escape_ere() {
	printf '%s' "$1"
	return 0
}
strip_code_fences() {
	command cat
	return 0
}
log_verbose() { return 0; }
print_error() { return 0; }
JQ_CALL_LOG="${TEST_ROOT}/jq-calls.log"
jq() {
	printf 'call\n' >>"$JQ_CALL_LOG"
	command jq "$@"
	return $?
}
_gh_with_timeout() {
	local _class="$1"
	shift
	"$@"
	return $?
}

REPOSITORY_TRANSPORT="rest-only"
gh() {
	local group="$1"
	shift
	if [[ "$group" == "api" ]]; then
		local endpoint="$1"
		if [[ "$endpoint" == "graphql" ]]; then
			case "$REPOSITORY_TRANSPORT" in
			graphql-only) printf '%s\n' '{"data":{"repository":{"id":"R_graphql","nameWithOwner":"owner/graphql"},"rateLimit":{"cost":1}}}' ;;
			wrong) printf '%s\n' '{"data":{"repository":{"id":"R_wrong","nameWithOwner":"other/repo"},"rateLimit":{"cost":1}}}' ;;
			missing-cost) printf '%s\n' '{"data":{"repository":{"id":"R_graphql","nameWithOwner":"owner/graphql"},"rateLimit":{}}}' ;;
			malformed) printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/graphql"},"rateLimit":{"cost":1}}}' ;;
			*) return 1 ;;
			esac
			return 0
		fi
		case "$endpoint" in
		repos/owner/one) printf '%s\n' '{"node_id":"R_one","full_name":"owner/one"}' ;;
		repos/owner/renamed-one) printf '%s\n' '{"node_id":"R_one","full_name":"owner/renamed-one"}' ;;
		repos/owner/two) printf '%s\n' '{"node_id":"R_two","full_name":"owner/two"}' ;;
		repos/owner/dotted) printf '%s\n' '{"node_id":"R_dotted","full_name":"owner/dotted"}' ;;
		repos/owner/graphql)
			case "$REPOSITORY_TRANSPORT" in
			rest-only) printf '%s\n' '{"node_id":"R_rest","full_name":"owner/graphql"}' ;;
			wrong) printf '%s\n' '{"node_id":"R_wrong","full_name":"other/repo"}' ;;
			*) return 1 ;;
			esac
			;;
		*) return 1 ;;
		esac
		return 0
	fi
	if [[ "$group" == "issue" && "$1" == "view" ]]; then
		local issue_number="$2"
		local repo=""
		while [[ $# -gt 0 ]]; do
			if [[ "$1" == "--repo" ]]; then
				repo="$2"
				shift 2
			else shift; fi
		done
		case "$repo" in
		owner/one | owner/renamed-one) [[ "$issue_number" == "42" ]] && printf '%s\n' '{"id":"I_one_42","number":42,"state":"OPEN","updatedAt":"2026-07-12T10:00:00Z"}' || return 1 ;;
		owner/two) printf '%s\n' '{"id":"I_two_42","number":42,"state":"CLOSED","updatedAt":"2026-07-12T11:00:00Z"}' ;;
		owner/dotted) printf '%s\n' '{"id":"I_dotted_73","number":73,"state":"OPEN","updatedAt":"2026-07-12T12:00:00Z"}' ;;
		owner/graphql) printf '%s\n' '{"id":"I_graphql_88","number":88,"state":"OPEN","updatedAt":"2026-07-12T13:00:00Z"}' ;;
		*) return 1 ;;
		esac
		return 0
	fi
	return 1
}

# shellcheck source=../issue-sync-lib-parse.sh
source "${SCRIPT_DIR}/issue-sync-lib-parse.sh"
# shellcheck source=../issue-sync-lib-ref.sh
source "${SCRIPT_DIR}/issue-sync-lib-ref.sh"

: >"$JQ_CALL_LOG"
[[ "$(resolve_task_gh_number t101 "$TODO_FILE" owner/one)" == "42" ]]
if [[ "$(wc -l <"$JQ_CALL_LOG" | tr -d ' ')" != "4" ]]; then
	printf 'FAIL repository identity and issue backfill did not use bounded jq parsing\n' >&2
	exit 1
fi
[[ "$(resolve_task_gh_number t102 "$TODO_FILE" owner/two)" == "42" ]]
[[ "$(resolve_task_gh_number t1873.1 "$TODO_FILE" owner/dotted)" == "73" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t101 --repository-id R_one | jq -r '.issueId')" == "I_one_42" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t102 --repository-id R_two | jq -r '.issueId')" == "I_two_42" ]]
require_task_issue_mapping t1873.1 "$TODO_FILE" owner/dotted 73

REPOSITORY_TRANSPORT="graphql-only"
[[ "$(resolve_task_gh_number t201 "$TODO_FILE" owner/graphql)" == "88" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t201 --repository-id R_graphql | jq -r '.issueId')" == "I_graphql_88" ]]
[[ "$(resolve_repository_node_id Owner/GraphQL)" == "R_graphql" ]]
REPOSITORY_TRANSPORT="rest-only"

# Existing coordinator mappings are decoded in one jq process even when
# optional project and cursor fields are empty.
: >"$JQ_CALL_LOG"
[[ "$(resolve_task_gh_number t102 "$TODO_FILE" owner/two)" == "42" ]]
if [[ "$(wc -l <"$JQ_CALL_LOG" | tr -d ' ')" != "2" ]]; then
	printf 'FAIL repository identity and coordinator mapping did not use bounded jq parsing\n' >&2
	exit 1
fi

if require_task_issue_mapping t1873.1 "$TODO_FILE" owner/dotted 74; then
	printf 'FAIL mismatched display number passed the issue write gate\n' >&2
	exit 1
fi

# A renamed remote resolves through immutable repository identity and refreshes
# only the mutable slug. A local-only/unvalidated target cannot resolve.
[[ "$(resolve_task_gh_number t101 "$TODO_FILE" owner/renamed-one)" == "42" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t101 --repository-id R_one | jq -r '.repositorySlug')" == "owner/renamed-one" ]]
if resolve_task_gh_number t101 "$TODO_FILE" local/only >/dev/null 2>&1; then
	printf 'FAIL local-only repository resolved an issue write target\n' >&2
	exit 1
fi

# Repository identity fails closed when neither transport proves the exact
# owner/name and a non-empty node ID. GraphQL cost must come from its response.
for REPOSITORY_TRANSPORT in wrong missing-cost malformed total-outage; do
	if resolve_repository_node_id owner/graphql >/dev/null 2>&1; then
		printf 'FAIL invalid repository identity was accepted (%s)\n' "$REPOSITORY_TRANSPORT" >&2
		exit 1
	fi
done
REPOSITORY_TRANSPORT="rest-only"

# A conflicting projection for the same immutable task/repository fails closed.
printf '%s\n' '- [ ] t101 conflicting task projection ref:GH#43' >"$TODO_FILE"
if AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/conflict.db" resolve_task_gh_number t101 "$TODO_FILE" owner/one >/dev/null 2>&1; then
	printf 'FAIL unresolved issue projection was accepted\n' >&2
	exit 1
fi

# A child that exits successfully without persisting anything cannot validate a
# backfill, even when GitHub returned a valid existing issue. No creation occurs.
printf '%s\n' '- [ ] t101 first repository task ref:GH#42' >"$TODO_FILE"
node() { return 0; }
if resolve_task_gh_number t101 "$TODO_FILE" owner/one >/dev/null 2>&1; then
	printf 'FAIL empty-success coordinator validated an unpersisted mapping\n' >&2
	exit 1
fi
unset -f node

printf 'PASS repository-scoped issue mapping isolation and fail-closed backfill\n'
