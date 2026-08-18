#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for trusted Dependabot dependency-update allowances.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
GATES_SCRIPT="${SCRIPT_DIR}/../pulse-merge-gates.sh"
AUTHOR_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-author-checks.sh"
TRUSTED_DEPENDABOT_LIB="${SCRIPT_DIR}/../trusted-dependabot-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

write_pr_fixture() {
	local author_login="$1"
	local commit_login="$2"
	local changed_path="$3"
	local security_conclusion="$4"
	local framework_conclusion="${5:-SUCCESS}"
	local package_manager="${6:-pip}"
	local dependency_name="${7:-pyarrow}"
	cat >"${TEST_ROOT}/pr.json" <<EOF
{
  "author": {"__typename": "Bot", "login": "${author_login}"},
  "headRefOid": "head-current",
  "headRepositoryOwner": {"login": "owner"},
  "headRepository": {"nameWithOwner": "owner/repo"},
  "body": "Bumps the ${package_manager} group with 1 update in the / directory: [${dependency_name}](source).\n\n---\nupdated-dependencies:\n- dependency-name: ${dependency_name}\n  dependency-version: 23.0.1\n  dependency-type: direct:production\n  dependency-group: ${package_manager}\n...",
  "commits": [
    {"authors": [{"login": "${commit_login}"}]}
  ],
  "files": [
    {"path": "${changed_path}"}
  ],
	"statusCheckRollup": [
		{"name": "Socket Security: Pull Request Alerts", "conclusion": "${security_conclusion}", "status": "COMPLETED"},
		{"name": "Framework Validation", "conclusion": "${framework_conclusion}", "status": "COMPLETED"},
		{"name": "review status", "workflowName": "Review Bot Gate", "conclusion": "FAILURE", "status": "COMPLETED"}
	]
}
EOF
	jq '{data:{
		repository:{pullRequest:{
			author:.author,
			body:.body,
			headRefOid:.headRefOid,
			headRepository:.headRepository,
			headRepositoryOwner:.headRepositoryOwner,
			commits:{
				nodes:[.commits[] | {commit:{authors:{
					nodes:[.authors[] | {user:{login:.login}}],
					pageInfo:{hasNextPage:false}
				}}}],
				pageInfo:{hasNextPage:false}
			},
			files:{nodes:.files,pageInfo:{hasNextPage:false}},
			statusCheckRollup:{contexts:{
				nodes:[.statusCheckRollup[] | {
					__typename:"CheckRun",
					name,
					conclusion,
					status,
					checkSuite:{workflowRun:{workflow:{name:(.workflowName // null)}}}
				}],
				pageInfo:{hasNextPage:false}
			}}
		}},
		rateLimit:{cost:2}
	}}' "${TEST_ROOT}/pr.json" >"${TEST_ROOT}/graphql.json"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="${TEST_ROOT}/trusted-dependabot-updates.conf"
	printf 'pip:pyarrow\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	printf 'pulse-runner\n' >"${TEST_ROOT}/collaborators.txt"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s|%s|gh %s\n' \
	"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
	"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"${GH_LOG:-/dev/null}"

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	cat "${TEST_ROOT}/graphql.json"
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	cat "${TEST_ROOT}/pr.json"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	printf 'pulse-runner\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "-i" && "$*" == *"/collaborators/"*"/permission" ]]; then
	_user="${3#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'HTTP/2.0 200 OK\n\n{"permission":"admin"}\n'
	else
		printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "$*" == *"/collaborators/"*"/permission"* && "$*" == *"--jq"* ]]; then
	_user="${2#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'admin\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "-X" && "${3:-}" == "POST" &&
	"${4:-}" == repos/*/pulls/*/reviews ]]; then
	_commit_id=""
	for _arg in "$@"; do
		case "$_arg" in
		commit_id=*) _commit_id="${_arg#commit_id=}" ;;
		esac
	done
	printf '{"state":"APPROVED","commit_id":"%s"}\n' "$_commit_id"
	exit 0
fi

if [[ "${1:-}" == "api" && "$*" == *"/pulls/"*"/reviews"* ]]; then
	printf '[]\n'
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "review" ]]; then
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_helpers_under_test() {
	local approve_src=""
	local runner_src=""
	local trusted_approval_src=""
	local exact_head_approval_src=""
	approve_src=$(awk '/^approve_collaborator_pr\(\) \{/,/^}$/ { print }' "$GATES_SCRIPT")
	runner_src=$(awk '/^_approve_collaborator_runner_has_write\(\) \{/,/^}$/ { print }' "$GATES_SCRIPT")
	trusted_approval_src=$(awk '/^_trusted_existing_approver\(\) \{/,/^}$/ { print }' "$GATES_SCRIPT")
	exact_head_approval_src=$(awk '/^_pulse_approve_pr_at_head\(\) \{/,/^}$/ { print }' "$GATES_SCRIPT")
	[[ -n "$approve_src" && -n "$runner_src" && -n "$trusted_approval_src" &&
		-n "$exact_head_approval_src" ]] || return 1

	_has_maintainer_crypto_approval() { return 1; }
	# shellcheck source=../pulse-merge-author-checks.sh
	source "$AUTHOR_CHECKS_SCRIPT"
	# shellcheck source=../trusted-dependabot-lib.sh
	source "$TRUSTED_DEPENDABOT_LIB"
	# shellcheck disable=SC1090
	eval "$runner_src"
	# shellcheck disable=SC1090
	eval "$trusted_approval_src"
	# shellcheck disable=SC1090
	eval "$exact_head_approval_src"
	# shellcheck disable=SC1090
	eval "$approve_src"
	return 0
}

test_trusted_dependabot_uses_response_metered_graphql() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	: >"$GH_LOG"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current" \
		&& grep -qF '1|trusted-dependabot-exact-cost|gh api graphql' "$GH_LOG" \
		&& ! grep -qF '|gh pr view 24473' "$GH_LOG"; then
		print_result "trusted Dependabot snapshot reports operation-owned GraphQL cost" 0
		return 0
	fi
	print_result "trusted Dependabot snapshot reports operation-owned GraphQL cost" 1 "gh log: $(<"$GH_LOG")"
	return 0
}

test_worker_intake_reuses_trusted_snapshot() {
	local graphql_calls=""
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	: >"$GH_LOG"
	_is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current" || true
	if _is_authentic_dependabot_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		graphql_calls=$(grep -cF 'gh api graphql' "$GH_LOG" 2>/dev/null) || graphql_calls=0
		if [[ "$graphql_calls" -eq 1 ]]; then
			print_result "worker intake reuses the exact-head trust snapshot" 0
			return 0
		fi
	fi
	print_result "worker intake reuses the exact-head trust snapshot" 1 "gh log: $(<"$GH_LOG")"
	return 0
}

test_typescript_is_maintainer_allowlisted() {
	local fixture_conf="$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"

	unset AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF
	if _trusted_dependabot_dependency_allowed "" "typescript"; then
		export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_conf"
		print_result "TypeScript is allowlisted for trusted Dependabot updates" 0
		return 0
	fi
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_conf"
	print_result "TypeScript is allowlisted for trusted Dependabot updates" 1
	return 0
}

test_worker_intake_authenticates_paginated_checks() {
	local graphql_calls=""
	local fixture_tmp="${TEST_ROOT}/graphql-paginated.json"

	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	jq '.data.repository.pullRequest.statusCheckRollup.contexts.pageInfo.hasNextPage = true' \
		"${TEST_ROOT}/graphql.json" >"$fixture_tmp"
	mv "$fixture_tmp" "${TEST_ROOT}/graphql.json"
	_TRUSTED_DEPENDABOT_LAST_PR_JSON=""
	_TRUSTED_DEPENDABOT_LAST_REPO=""
	_TRUSTED_DEPENDABOT_LAST_PR=""
	_TRUSTED_DEPENDABOT_LAST_HEAD=""
	: >"$GH_LOG"
	if ! _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current" \
		&& _is_authentic_dependabot_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		graphql_calls=$(grep -cF 'gh api graphql' "$GH_LOG" 2>/dev/null) || graphql_calls=0
		if [[ "$graphql_calls" -eq 2 ]] \
			&& grep -qF '1|trusted-dependabot-auth-exact-cost|gh api graphql' "$GH_LOG"; then
			print_result "worker intake authenticates independently of paginated checks" 0
			return 0
		fi
	fi
	print_result "worker intake authenticates independently of paginated checks" 1 "gh log: $(<"$GH_LOG")"
	return 0
}

test_trusted_dependabot_binds_expected_head() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current" \
		&& ! _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-stale"; then
		print_result "trusted Dependabot snapshot binds the expected head" 0
		return 0
	fi
	print_result "trusted Dependabot snapshot binds the expected head" 1
	return 0
}

test_standard_dependabot_body_parser() {
	local dependencies=""
	dependencies=$(_trusted_dependabot_dependencies_from_body 'Bumps [vite](source) from 7 to 8') || dependencies=""
	if [[ "$dependencies" == "vite" ]]; then
		print_result "standard Dependabot first line yields the dependency name" 0
		return 0
	fi
	print_result "standard Dependabot first line yields the dependency name" 1 "parsed: ${dependencies:-empty}"
	return 0
}

test_quoted_dependabot_dependency_names() {
	local body=""
	local dependencies=""

	body=$(printf '%s\n' \
		'Bumps [react](source) and [@types/react](source).' \
		'---' \
		'updated-dependencies:' \
		'- dependency-name: "@types/react"' \
		"- dependency-name: 'react'")
	dependencies=$(_trusted_dependabot_dependencies_from_body "$body") || dependencies=""
	if [[ "$dependencies" == $'@types/react\nreact' ]]; then
		print_result "quoted Dependabot YAML dependency names are normalized" 0
		return 0
	fi
	print_result "quoted Dependabot YAML dependency names are normalized" 1 "parsed: ${dependencies:-empty}"
	return 0
}

test_malformed_quoted_dependency_name_fails_closed() {
	local body=""

	body=$(printf '%s\n' \
		'Bumps [@types/react](source) from 19.2.6 to 19.2.18.' \
		'---' \
		'updated-dependencies:' \
		'- dependency-name: "@types/react' \
		'- dependency-name: react')
	if _trusted_dependabot_dependencies_from_body "$body" >/dev/null; then
		print_result "malformed quoted Dependabot dependency name fails closed" 1
		return 0
	fi
	print_result "malformed quoted Dependabot dependency name fails closed" 0
	return 0
}

test_trusted_dependabot_rejects_paginated_snapshot() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	jq '.data.repository.pullRequest.files.pageInfo.hasNextPage = true' \
		"${TEST_ROOT}/graphql.json" >"${TEST_ROOT}/graphql-paginated.json"
	mv "${TEST_ROOT}/graphql-paginated.json" "${TEST_ROOT}/graphql.json"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		print_result "paginated trusted Dependabot snapshot fails closed" 1
		return 0
	fi
	print_result "paginated trusted Dependabot snapshot fails closed" 0
	return 0
}

test_trusted_dependabot_rejects_incomplete_snapshot() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	jq '.data.repository.pullRequest.commits.nodes = []' \
		"${TEST_ROOT}/graphql.json" >"${TEST_ROOT}/graphql-incomplete.json"
	mv "${TEST_ROOT}/graphql-incomplete.json" "${TEST_ROOT}/graphql.json"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		print_result "incomplete trusted Dependabot snapshot fails closed" 1
		return 0
	fi
	print_result "incomplete trusted Dependabot snapshot fails closed" 0
	return 0
}

test_trusted_dependabot_passes() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		print_result "trusted Dependabot update passes narrow gate" 0
		return 0
	fi
	print_result "trusted Dependabot update passes narrow gate" 1 "Expected helper to trust fixture. Log: $(<"$LOGFILE")"
	return 0
}

test_spoofed_author_fails() {
	write_pr_fixture "attacker" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		print_result "spoofed Dependabot author fails" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "spoofed Dependabot author fails" 0
	return 0
}

test_dependabot_login_with_user_type_fails() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	jq '.data.repository.pullRequest.author.__typename = "User"' \
		"${TEST_ROOT}/graphql.json" >"${TEST_ROOT}/graphql-user.json"
	mv "${TEST_ROOT}/graphql-user.json" "${TEST_ROOT}/graphql.json"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "app/dependabot" "head-current"; then
		print_result "ordinary User with Dependabot login text fails" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "ordinary User with Dependabot login text fails" 0
	return 0
}

test_security_failure_fails() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "FAILURE"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		print_result "security-scan failure blocks Dependabot trust" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "security-scan failure blocks Dependabot trust" 0
	return 0
}

test_non_dependency_file_fails() {
	write_pr_fixture "dependabot" "dependabot[bot]" ".github/workflows/pwn.yml" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		print_result "non-dependency file blocks Dependabot trust" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "non-dependency file blocks Dependabot trust" 0
	return 0
}

test_trusted_actions_dependabot_passes() {
	write_pr_fixture "dependabot" "dependabot[bot]" ".github/workflows/test.yml" "SUCCESS" "SUCCESS" "actions" "actions/checkout"
	printf 'pip:pyarrow\nactions:actions/checkout\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		printf 'pip:pyarrow\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
		print_result "allowlisted Actions Dependabot workflow update passes narrow gate" 0
		return 0
	fi
	printf 'pip:pyarrow\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	print_result "allowlisted Actions Dependabot workflow update passes narrow gate" 1 "Expected helper to trust fixture. Log: $(<"$LOGFILE")"
	return 0
}

test_unallowlisted_dependency_fails() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	printf 'other-package\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]" "head-current"; then
		printf 'pip:pyarrow\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
		print_result "unallowlisted dependency blocks Dependabot trust" 1 "Unexpected trusted result"
		return 0
	fi
	printf 'pip:pyarrow\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	print_result "unallowlisted dependency blocks Dependabot trust" 0
	return 0
}

test_repository_allows_types_bun() {
	local fixture_allowlist="$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"

	unset AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF
	if _trusted_dependabot_dependency_allowed "" "@types/bun"; then
		export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
		print_result "repository allowlist permits @types/bun updates" 0
		return 0
	fi
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
	print_result "repository allowlist permits @types/bun updates" 1
	return 0
}

test_repository_allows_hono() {
	local fixture_allowlist="$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"

	unset AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF
	if _trusted_dependabot_dependency_allowed "" "hono"; then
		export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
		print_result "repository allowlist permits hono updates" 0
		return 0
	fi
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
	print_result "repository allowlist permits hono updates" 1
	return 0
}

test_repository_allows_elysia() {
	local fixture_allowlist="$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"

	unset AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF
	if _trusted_dependabot_dependency_allowed "" "elysia"; then
		export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
		print_result "repository allowlist permits Elysia updates" 0
		return 0
	fi
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
	print_result "repository allowlist permits Elysia updates" 1
	return 0
}

test_repository_allows_fontsource_ubuntu() {
	local fixture_allowlist="$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"

	unset AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF
	if _trusted_dependabot_dependency_allowed "bun" "@fontsource/ubuntu"; then
		export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
		print_result "repository allowlist permits @fontsource/ubuntu Bun updates" 0
		return 0
	fi
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
	print_result "repository allowlist permits @fontsource/ubuntu Bun updates" 1
	return 0
}

test_repository_allows_trusted_actions() {
	local fixture_allowlist="$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	local dependency_name=""

	unset AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF
	for dependency_name in \
		actions/checkout \
		actions/github-script \
		qltysh/qlty-action/install \
		actions/setup-node \
		actions/upload-artifact \
		github/codeql-action/upload-sarif \
		anomalyco/opencode/github \
		actions/download-artifact; do
		if ! _trusted_dependabot_dependency_allowed "actions" "$dependency_name"; then
			export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
			print_result "repository allowlist permits trusted Actions updates" 1 "Missing actions:${dependency_name}"
			return 0
		fi
	done
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="$fixture_allowlist"
	print_result "repository allowlist permits trusted Actions updates" 0
	return 0
}

test_trusted_dependabot_can_be_approved() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	: >"$GH_LOG"
	approve_collaborator_pr "24473" "owner/repo" "dependabot[bot]" "head-current" >/dev/null || true
	if grep -qF 'api -X POST repos/owner/repo/pulls/24473/reviews' "$GH_LOG" &&
		grep -qF 'event=APPROVE' "$GH_LOG" &&
		grep -qF 'commit_id=head-current' "$GH_LOG" &&
		grep -qF 'trusted Dependabot dependency update verified' "$GH_LOG"; then
		print_result "trusted Dependabot PR receives accurate head-bound auto-approval" 0
		return 0
	fi
	print_result "trusted Dependabot PR receives accurate auto-approval" 1 "Expected approval call. gh log: $(<"$GH_LOG")"
	return 0
}

test_review_bot_failure_is_ignored_when_other_checks_green() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS" "SUCCESS"
	if _trusted_dependabot_non_review_checks_green "24473" "owner/repo"; then
		print_result "review-bot failure ignored when non-review checks green" 0
		return 0
	fi
	print_result "review-bot failure ignored when non-review checks green" 1 "Expected non-review check helper to pass. Log: $(<"$LOGFILE")"
	return 0
}

test_precomputed_status_rollup_skips_graphql() {
	local pr_json=""

	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS" "SUCCESS"
	pr_json=$(<"${TEST_ROOT}/pr.json")
	: >"$GH_LOG"
	if _trusted_dependabot_non_review_checks_green "24473" "owner/repo" "$pr_json" \
		&& ! grep -qF 'gh api graphql' "$GH_LOG"; then
		print_result "precomputed status rollup skips GraphQL fetch" 0
		return 0
	fi
	print_result "precomputed status rollup skips GraphQL fetch" 1 "Expected no GraphQL call. gh log: $(<"$GH_LOG")"
	return 0
}

test_non_review_failure_blocks_required_check_bypass() {
	write_pr_fixture "dependabot" "dependabot[bot]" "requirements-lock.txt" "SUCCESS" "FAILURE"
	if _trusted_dependabot_non_review_checks_green "24473" "owner/repo"; then
		print_result "non-review failure blocks Dependabot required-check bypass" 1 "Unexpected bypass"
		return 0
	fi
	print_result "non-review failure blocks Dependabot required-check bypass" 0
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	define_helpers_under_test
	test_trusted_dependabot_passes
	test_trusted_dependabot_uses_response_metered_graphql
	test_worker_intake_reuses_trusted_snapshot
	test_typescript_is_maintainer_allowlisted
	test_worker_intake_authenticates_paginated_checks
	test_trusted_dependabot_binds_expected_head
	test_standard_dependabot_body_parser
	test_quoted_dependabot_dependency_names
	test_malformed_quoted_dependency_name_fails_closed
	test_trusted_dependabot_rejects_paginated_snapshot
	test_trusted_dependabot_rejects_incomplete_snapshot
	test_spoofed_author_fails
	test_dependabot_login_with_user_type_fails
	test_security_failure_fails
	test_non_dependency_file_fails
	test_trusted_actions_dependabot_passes
	test_unallowlisted_dependency_fails
	test_repository_allows_types_bun
	test_repository_allows_hono
	test_repository_allows_elysia
	test_repository_allows_fontsource_ubuntu
	test_repository_allows_trusted_actions
	test_trusted_dependabot_can_be_approved
	test_review_bot_failure_is_ignored_when_other_checks_green
	test_precomputed_status_rollup_skips_graphql
	test_non_review_failure_blocks_required_check_bypass

	printf '\nTests run: %s\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf 'Tests failed: %s\n' "$TESTS_FAILED"
		exit 1
	fi
	printf 'All tests passed.\n'
	return 0
}

main "$@"
