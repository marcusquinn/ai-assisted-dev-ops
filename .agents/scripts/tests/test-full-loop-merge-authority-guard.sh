#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#28622: every full-loop merge mode must apply the
# same live external/fork authority gate before invoking GitHub's merge API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_SCRIPT="${SCRIPT_DIR}/../full-loop-helper-merge.sh"
COMMIT_SCRIPT="${SCRIPT_DIR}/../full-loop-helper-commit.sh"
TEST_ROOT="$(mktemp -d -t full-loop-merge-authority.XXXXXX)"
EXTRACTED="${TEST_ROOT}/functions.sh"
CRYPTO_CALLS="${TEST_ROOT}/crypto-calls.log"
MERGE_CALLS="${TEST_ROOT}/merge-calls.log"
GUARD_CALLS="${TEST_ROOT}/guard-calls.log"
TRUSTED_CALLS="${TEST_ROOT}/trusted-calls.log"
ISSUE_SYNC_TRUST_CALLS="${TEST_ROOT}/issue-sync-trust-calls.log"
ISSUE_SYNC_HELPER="${TEST_ROOT}/review-bot-gate-helper.sh"
export ISSUE_SYNC_TRUST_CALLS
cat >"$ISSUE_SYNC_HELPER" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" ]]; then
	printf 'PASS\n'
	exit 0
fi
printf '%s\n' "$*" >>"${ISSUE_SYNC_TRUST_CALLS}"
[[ "${1:-}" == "is-trusted-issue-sync-pr" && -n "${4:-}" && "${FIXTURE_TRUSTED_ISSUE_SYNC:-0}" == "1" ]]
EOF
chmod +x "$ISSUE_SYNC_HELPER"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s' "$name"
	[[ -n "$detail" ]] && printf ': %s' "$detail"
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

extract_function() {
	local function_name="$1"
	awk -v fn="$function_name" '
      index($0, fn "() {") == 1 { capture = 1 }
      capture { print }
      capture && $0 == "}" { exit }
    ' "$MERGE_SCRIPT" >>"$EXTRACTED"
	return 0
}

extract_commit_function() {
	local function_name="$1"
	awk -v fn="$function_name" '
      index($0, fn "() {") == 1 { capture = 1 }
      capture { print }
      capture && $0 == "}" { exit }
    ' "$COMMIT_SCRIPT" >>"$EXTRACTED"
	return 0
}

load_functions() {
	: >"$EXTRACTED"
	extract_function _merge_linked_issue_numbers
	extract_function _merge_issue_requires_maintainer_review
	extract_function _merge_author_has_write_authority
	extract_function _merge_is_trusted_issue_sync_pr
	extract_function _merge_collect_linked_issue_authority_gaps
	extract_function _merge_collect_external_authority_gaps
	extract_function _merge_linked_issue_authority_clear
	extract_function _merge_guard_admin_merge_maintainer_review
	extract_function _merge_resolve_conventional_type_from_commits
	extract_function _merge_resolve_squash_subject
	extract_function _merge_resolve_subject_for_method
	extract_function _merge_describe_flags
	extract_function _merge_rest_fallback
	extract_function _merge_revalidate_transport_authority
	extract_function _merge_execute
	extract_commit_function cmd_pre_merge_gate
	# shellcheck source=/dev/null
	source "$EXTRACTED"
	return 0
}

FIXTURE_PR_JSON=""
FIXTURE_PERMISSION="write"
FIXTURE_PERMISSION_FAIL=0
FIXTURE_PR_LOOKUP_FAIL=0
FIXTURE_ISSUE_LABELS=""
FIXTURE_ISSUE_LOOKUP_FAIL=0
FIXTURE_ISSUE_APPROVED=0
FIXTURE_PR_APPROVED=0
FIXTURE_GH_MODE="guard"
FIXTURE_TRUSTED_DEPENDABOT=0
FIXTURE_TRUSTED_ISSUE_SYNC=0
export FIXTURE_TRUSTED_ISSUE_SYNC
AUTHORITY_GUARD_PASS=1
AUTHORITY_GUARD_FAIL_ON_CALL=0
FULL_LOOP_MERGE_SUBJECT_FLAG="--subject"

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >&2
	return 0
}

print_success() {
	local message="$1"
	printf 'OK %s\n' "$message" >&2
	return 0
}

_flm_gh_write() {
	"$@"
	return $?
}

_merge_run_bounded_write() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local write_rc=0
	: "$pr_number" "$repo" "$expected_head_sha"
	shift 3
	_MERGE_WRITE_OUTPUT=""
	_MERGE_WRITE_OUTPUT=$(_flm_gh_write "$@" 2>&1) || write_rc=$?
	return "$write_rc"
}

gh() {
	local command="${1:-}"
	local subcommand="${2:-}"
	if [[ "$FIXTURE_GH_MODE" == "merge" && "$command" == "pr" && "$subcommand" == "merge" ]]; then
		printf '%s\n' "$*" >>"$MERGE_CALLS"
		printf 'merged\n'
		return 0
	fi
	if [[ "$command" == "pr" && "$subcommand" == "view" ]]; then
		[[ "$FIXTURE_PR_LOOKUP_FAIL" -eq 0 ]] || return 1
		if [[ "$*" == *"--json title"* ]]; then
			printf '%s\n' '{"title":"GH#28622: preserve exact-head merge authority","commits":[{"messageHeadline":"fix: preserve exact-head merge authority"}]}'
			return 0
		fi
		printf '%s\n' "$FIXTURE_PR_JSON"
		return 0
	fi
	if [[ "$command" == "issue" && "$subcommand" == "view" ]]; then
		[[ "$FIXTURE_ISSUE_LOOKUP_FAIL" -eq 0 ]] || return 1
		printf '%s\n' "$FIXTURE_ISSUE_LABELS"
		return 0
	fi
	if [[ "$command" == "api" && "$subcommand" == *"/collaborators/"*"/permission" ]]; then
		[[ "$FIXTURE_PERMISSION_FAIL" -eq 0 ]] || return 1
		printf '%s\n' "$FIXTURE_PERMISSION"
		return 0
	fi
	return 1
}

# Production full-loop loads the shared App-aware permission helper. Model its
# contract here, including the `none` verdict used for a confirmed 404.
_gh_collaborator_permission_lookup() {
	local repo="$1"
	local author="$2"
	local out_var="${3:-}"
	[[ -n "$repo" && -n "$author" ]] || return 2
	[[ "$FIXTURE_PERMISSION_FAIL" -eq 0 ]] || return 2
	if [[ -n "$out_var" ]]; then
		printf -v "$out_var" '%s' "$FIXTURE_PERMISSION"
	else
		printf '%s\n' "$FIXTURE_PERMISSION"
	fi
	return 0
}

_merge_target_crypto_approved() {
	local target_type="$1"
	local target_number="$2"
	local repo="$3"
	local expected_head_sha="${4:-}"
	printf '%s %s %s %s\n' "$target_type" "$target_number" "$repo" "$expected_head_sha" >>"$CRYPTO_CALLS"
	if [[ "$target_type" == "issue" ]]; then
		[[ "$FIXTURE_ISSUE_APPROVED" -eq 1 ]]
		return $?
	fi
	[[ "$FIXTURE_PR_APPROVED" -eq 1 && -n "$expected_head_sha" ]]
	return $?
}

_is_trusted_dependabot_update_pr() {
	local pr_number="$1"
	local repo="$2"
	local author="${3:-}"
	local expected_head_sha="${4:-}"
	printf '%s %s %s %s\n' "$pr_number" "$repo" "$author" "$expected_head_sha" >>"$TRUSTED_CALLS"
	[[ "$FIXTURE_TRUSTED_DEPENDABOT" -eq 1 && "$author" == "dependabot[bot]" && -n "$expected_head_sha" ]]
	return $?
}

_full_loop_review_bot_gate_helper_path() {
	printf '%s\n' "$ISSUE_SYNC_HELPER"
	return 0
}

_full_loop_verify_pr_readiness() {
	return 0
}

set_pr_fixture() {
	local author="$1"
	local labels_json="$2"
	local is_fork="$3"
	local issues_json="$4"
	local body="$5"
	local head_sha="${6:-head-current}"
	FIXTURE_PR_JSON=$(jq -nc \
		--arg author "$author" \
		--arg head "$head_sha" \
		--arg body "$body" \
		--argjson labels "$labels_json" \
		--argjson fork "$is_fork" \
		--argjson issues "$issues_json" \
		'{author:{login:$author},labels:$labels,isCrossRepository:$fork,headRefOid:$head,closingIssuesReferences:$issues,body:$body}')
	return 0
}

reset_fixture() {
	FIXTURE_PERMISSION="write"
	FIXTURE_PERMISSION_FAIL=0
	FIXTURE_PR_LOOKUP_FAIL=0
	FIXTURE_ISSUE_LABELS=""
	FIXTURE_ISSUE_LOOKUP_FAIL=0
	FIXTURE_ISSUE_APPROVED=0
	FIXTURE_PR_APPROVED=0
	FIXTURE_GH_MODE="guard"
	FIXTURE_TRUSTED_DEPENDABOT=0
	FIXTURE_TRUSTED_ISSUE_SYNC=0
	export FIXTURE_TRUSTED_ISSUE_SYNC
	AUTHORITY_GUARD_PASS=1
	AUTHORITY_GUARD_FAIL_ON_CALL=0
	: >"$CRYPTO_CALLS"
	: >"$MERGE_CALLS"
	: >"$GUARD_CALLS"
	: >"$TRUSTED_CALLS"
	: >"$ISSUE_SYNC_TRUST_CALLS"
	set_pr_fixture maintainer '[]' false '[]' ''
	return 0
}

test_trusted_issue_sync_authority() {
	reset_fixture
	set_pr_fixture 'app/github-actions' '[]' false '[]' '<!-- aidevops:issue-sync-todo-pr -->'
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_ISSUE_SYNC=1
	export FIXTURE_TRUSTED_ISSUE_SYNC
	expect_guard_result "exact-head repository-generated Issue Sync PR passes without linked issue or crypto" 0
	if grep -q '^is-trusted-issue-sync-pr 900 owner/repo head-current$' "$ISSUE_SYNC_TRUST_CALLS" && [[ ! -s "$CRYPTO_CALLS" ]]; then
		print_result "trusted Issue Sync authority is bound to the exact PR head" 0
	else
		print_result "trusted Issue Sync authority is bound to the exact PR head" 1 \
			"trust=$(<"$ISSUE_SYNC_TRUST_CALLS") crypto=$(<"$CRYPTO_CALLS")"
	fi

	reset_fixture
	set_pr_fixture 'app/github-actions' '[{"name":"needs-maintainer-review"}]' false '[]' '<!-- aidevops:issue-sync-todo-pr -->'
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_ISSUE_SYNC=1
	export FIXTURE_TRUSTED_ISSUE_SYNC
	expect_guard_result "live PR NMR still blocks trusted Issue Sync automation" 1
	if [[ ! -s "$ISSUE_SYNC_TRUST_CALLS" ]]; then
		print_result "NMR hold is evaluated before the Issue Sync exception" 0
	else
		print_result "NMR hold is evaluated before the Issue Sync exception" 1 "unexpected trust call"
	fi

	reset_fixture
	set_pr_fixture 'app/github-actions' '[]' false '[]' '<!-- aidevops:issue-sync-todo-pr -->'
	FIXTURE_PERMISSION="none"
	expect_guard_result "unverified Actions automation remains on fail-closed external path" 1

	reset_fixture
	set_pr_fixture 'app/github-actions' '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_ISSUE_SYNC=1
	export FIXTURE_TRUSTED_ISSUE_SYNC
	FIXTURE_ISSUE_LABELS="needs-maintainer-review"
	expect_guard_result "linked issue NMR still blocks trusted Issue Sync automation" 1

	reset_fixture
	set_pr_fixture 'app/github-actions' '[]' false '[]' '<!-- aidevops:issue-sync-todo-pr -->'
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_ISSUE_SYNC=1
	export FIXTURE_TRUSTED_ISSUE_SYNC
	expect_guard_result "head drift blocks before Issue Sync trust reuse" 1 head-stale
	return 0
}

expect_guard_result() {
	local name="$1"
	local expected_rc="$2"
	local expected_head="${3:-head-current}"
	local actual_rc=0
	_merge_guard_admin_merge_maintainer_review 900 owner/repo "$expected_head" >/dev/null 2>&1 || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected rc=$expected_rc, got rc=$actual_rc"
	fi
	return 0
}

test_trusted_dependabot_authority() {
	reset_fixture
	set_pr_fixture 'dependabot[bot]' '[]' false '[]' 'Dependabot dependency update'
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_DEPENDABOT=1
	expect_guard_result "exact-head trusted Dependabot passes without linked issue or crypto" 0
	if grep -q '^900 owner/repo dependabot\[bot\] head-current$' "$TRUSTED_CALLS" && [[ ! -s "$CRYPTO_CALLS" ]]; then
		print_result "trusted Dependabot authority is bound to the exact PR head" 0
	else
		print_result "trusted Dependabot authority is bound to the exact PR head" 1 "trusted=$(<"$TRUSTED_CALLS") crypto=$(<"$CRYPTO_CALLS")"
	fi

	reset_fixture
	set_pr_fixture 'dependabot[bot]' '[{"name":"needs-maintainer-review"}]' false '[]' ''
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_DEPENDABOT=1
	expect_guard_result "live PR NMR still blocks trusted Dependabot" 1
	if [[ ! -s "$TRUSTED_CALLS" ]]; then
		print_result "NMR hold is evaluated before the Dependabot exception" 0
	else
		print_result "NMR hold is evaluated before the Dependabot exception" 1 "unexpected trust call"
	fi

	reset_fixture
	set_pr_fixture 'dependabot[bot]' '[]' false '[]' ''
	FIXTURE_PERMISSION="none"
	expect_guard_result "unverified Dependabot remains on fail-closed external path" 1

	reset_fixture
	set_pr_fixture 'dependabot[bot]' '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	FIXTURE_TRUSTED_DEPENDABOT=1
	FIXTURE_ISSUE_LABELS="needs-maintainer-review"
	expect_guard_result "linked issue NMR still blocks trusted Dependabot" 1
	if [[ ! -s "$CRYPTO_CALLS" ]]; then
		print_result "trusted Dependabot linked-issue NMR blocks before crypto" 0
	else
		print_result "trusted Dependabot linked-issue NMR blocks before crypto" 1 "unexpected crypto verification"
	fi
	return 0
}

test_authority_guard() {
	reset_fixture
	expect_guard_result "internal maintainer PR passes without crypto" 0

	reset_fixture
	set_pr_fixture external '[{"name":"needs-maintainer-review"}]' false '[]' ''
	FIXTURE_PERMISSION="none"
	expect_guard_result "live PR NMR blocks before external authority" 1

	reset_fixture
	FIXTURE_PERMISSION_FAIL=1
	expect_guard_result "author permission lookup failure blocks" 1

	reset_fixture
	set_pr_fixture external '[]' false '[]' ''
	FIXTURE_PERMISSION="none"
	expect_guard_result "unlabeled external PR without linked issue blocks" 1

	reset_fixture
	set_pr_fixture maintainer '[{"name":"external-contributor"}]' false '[]' ''
	expect_guard_result "external label overrides live write permission" 1

	reset_fixture
	set_pr_fixture maintainer '[]' true '[]' ''
	expect_guard_result "fork metadata requires external authority" 1

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	FIXTURE_ISSUE_LABELS="needs-maintainer-review"
	expect_guard_result "linked issue live NMR blocks" 1

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	expect_guard_result "external linked issue without crypto blocks" 1

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	FIXTURE_ISSUE_APPROVED=1
	expect_guard_result "external PR without exact-head V2 authority blocks" 1

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	FIXTURE_ISSUE_APPROVED=1
	FIXTURE_PR_APPROVED=1
	expect_guard_result "external PR with issue and exact-head authority passes" 0
	if grep -q '^issue 42 owner/repo ' "$CRYPTO_CALLS" &&
		grep -q '^pr 900 owner/repo head-current$' "$CRYPTO_CALLS"; then
		print_result "external success verifies issue and exact PR head" 0
	else
		print_result "external success verifies issue and exact PR head" 1 "crypto calls did not bind both authorities"
	fi

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION="none"
	FIXTURE_ISSUE_APPROVED=1
	FIXTURE_PR_APPROVED=1
	expect_guard_result "head drift blocks before crypto reuse" 1 head-stale

	reset_fixture
	FIXTURE_ISSUE_LOOKUP_FAIL=1
	set_pr_fixture maintainer '[]' false '[{"number":42}]' 'Resolves #42'
	expect_guard_result "linked issue metadata failure blocks" 1

	reset_fixture
	FIXTURE_PR_JSON='{"author":null}'
	expect_guard_result "malformed PR authority metadata blocks" 1

	reset_fixture
	set_pr_fixture maintainer '[]' false '[{"number":42}]' 'Resolves #42'
	expect_guard_result "internal linked issue without hold passes without crypto" 0
	if [[ ! -s "$CRYPTO_CALLS" ]]; then
		print_result "internal PR does not require external crypto" 0
	else
		print_result "internal PR does not require external crypto" 1 "unexpected crypto verification"
	fi
	return 0
}

test_pre_merge_authority_preflight() {
	local output=""
	local actual_rc=0

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42},{"number":43}]' 'Resolves #42\nResolves #43'
	FIXTURE_PERMISSION="none"
	output=$(cmd_pre_merge_gate 900 owner/repo 2>&1) || actual_rc=$?
	if [[ "$actual_rc" -eq 1 ]] &&
		grep -qF 'sudo aidevops approve batch issue:42 issue:43 pr:900 owner/repo' <<<"$output"; then
		print_result "preflight reports all missing issue and exact-head PR authorities in one command" 0
	else
		print_result "preflight reports all missing issue and exact-head PR authorities in one command" 1 \
			"rc=$actual_rc output=$output"
	fi

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42},{"number":43}]' 'Resolves #42\nResolves #43'
	FIXTURE_PERMISSION="none"
	FIXTURE_ISSUE_APPROVED=1
	FIXTURE_PR_APPROVED=1
	actual_rc=0
	output=$(cmd_pre_merge_gate 900 owner/repo 2>&1) || actual_rc=$?
	if [[ "$actual_rc" -eq 0 ]] && ! grep -qF 'aidevops approve batch' <<<"$output"; then
		print_result "preflight passes without an approval prompt when all authority is current" 0
	else
		print_result "preflight passes without an approval prompt when all authority is current" 1 \
			"rc=$actual_rc output=$output"
	fi

	reset_fixture
	set_pr_fixture external '[]' false '[{"number":42}]' 'Resolves #42'
	FIXTURE_PERMISSION_FAIL=1
	actual_rc=0
	output=$(cmd_pre_merge_gate 900 owner/repo 2>&1) || actual_rc=$?
	if [[ "$actual_rc" -eq 1 ]] && ! grep -qF 'aidevops approve batch' <<<"$output"; then
		print_result "API uncertainty emits no incomplete final approval command" 0
	else
		print_result "API uncertainty emits no incomplete final approval command" 1 \
			"rc=$actual_rc output=$output"
	fi
	return 0
}

_merge_guard_admin_merge_maintainer_review_for_mode_test() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="${3:-}"
	local guard_call_count=0
	printf '%s %s %s\n' "$pr_number" "$repo" "$expected_head_sha" >>"$GUARD_CALLS"
	guard_call_count=$(wc -l <"$GUARD_CALLS")
	guard_call_count="${guard_call_count//[[:space:]]/}"
	if [[ "$AUTHORITY_GUARD_FAIL_ON_CALL" -gt 0 &&
		"$guard_call_count" -eq "$AUTHORITY_GUARD_FAIL_ON_CALL" ]]; then
		return 1
	fi
	[[ "$AUTHORITY_GUARD_PASS" -eq 1 ]]
	return $?
}

test_merge_mode() {
	local name="$1"
	local has_admin="$2"
	local has_auto="$3"
	local actual_rc=0
	: >"$GUARD_CALLS"
	: >"$MERGE_CALLS"
	FIXTURE_GH_MODE="merge"
	AUTHORITY_GUARD_PASS=1
	_merge_execute 900 owner/repo --squash "$has_admin" "$has_auto" >/dev/null 2>&1 || actual_rc=$?
	if [[ "$actual_rc" -eq 0 ]] && grep -q '^900 owner/repo head-current$' "$GUARD_CALLS" && [[ -s "$MERGE_CALLS" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "rc=$actual_rc guard=$(<"$GUARD_CALLS") merge=$(<"$MERGE_CALLS")"
	fi
	return 0
}

test_secondary_merge_transports_refresh_authority() {
	local transport_mode=""
	local actual_rc=0

	gh() {
		local command="${1:-}"
		local subcommand="${2:-}"
		local merge_call_count=0
		if [[ "$command" == "pr" && "$subcommand" == "view" && "$*" == *"--json title"* ]]; then
			printf '%s\n' '{"title":"GH#28622: preserve exact-head merge authority","commits":[{"messageHeadline":"fix: preserve exact-head merge authority"}]}'
			return 0
		fi
		if [[ "$command" == "pr" && "$subcommand" == "merge" ]]; then
			printf '%s\n' "$*" >>"$MERGE_CALLS"
			merge_call_count=$(wc -l <"$MERGE_CALLS")
			if [[ "$transport_mode" == "cache" && "$merge_call_count" -eq 1 ]]; then
				printf 'HTTP 401: Bad credentials\n'
				return 1
			fi
			if [[ "$transport_mode" == "rest" ]]; then
				printf 'GraphQL: API rate limit exceeded\n'
				return 1
			fi
			printf 'merged\n'
			return 0
		fi
		if [[ "$command" == "api" && "$*" == *"/pulls/900/merge"* ]]; then
			printf 'REST %s\n' "$*" >>"$MERGE_CALLS"
			printf '{"merged":true}\n'
			return 0
		fi
		return 1
	}
	gh_merge_remediate_stale_auth_cache() {
		[[ "$transport_mode" == "cache" ]]
		return $?
	}
	_merge_output_is_graphql_rate_limit() {
		[[ "$transport_mode" == "rest" ]]
		return $?
	}

	: >"$GUARD_CALLS"
	: >"$MERGE_CALLS"
	transport_mode="cache"
	AUTHORITY_GUARD_PASS=1
	AUTHORITY_GUARD_FAIL_ON_CALL=2
	actual_rc=0
	_merge_execute 900 owner/repo --squash 0 0 >/dev/null 2>&1 || actual_rc=$?
	if [[ "$actual_rc" -eq 1 && "$(wc -l <"$GUARD_CALLS")" -eq 2 &&
	"$(wc -l <"$MERGE_CALLS")" -eq 1 ]]; then
		print_result "stale-cache retry refreshes and honors revoked authority" 0
	else
		print_result "stale-cache retry refreshes and honors revoked authority" 1 \
			"rc=$actual_rc guard=$(<"$GUARD_CALLS") merge=$(<"$MERGE_CALLS")"
	fi

	: >"$GUARD_CALLS"
	: >"$MERGE_CALLS"
	transport_mode="rest"
	AUTHORITY_GUARD_PASS=1
	AUTHORITY_GUARD_FAIL_ON_CALL=2
	actual_rc=0
	_merge_execute 900 owner/repo --squash 0 0 >/dev/null 2>&1 || actual_rc=$?
	if [[ "$actual_rc" -eq 1 && "$(wc -l <"$GUARD_CALLS")" -eq 2 &&
	"$(wc -l <"$MERGE_CALLS")" -eq 1 ]] &&
		! grep -q '^REST ' "$MERGE_CALLS"; then
		print_result "REST fallback refreshes and honors revoked authority" 0
	else
		print_result "REST fallback refreshes and honors revoked authority" 1 \
			"rc=$actual_rc guard=$(<"$GUARD_CALLS") merge=$(<"$MERGE_CALLS")"
	fi
	return 0
}

test_all_merge_modes_use_guard() {
	_merge_guard_admin_merge_maintainer_review() {
		_merge_guard_admin_merge_maintainer_review_for_mode_test "$@"
		return $?
	}
	_merge_resolve_match_head() {
		local pr_number="$1"
		local repo="$2"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		printf 'head-current\n'
		return 0
	}
	_merge_review_state_still_clear() {
		return 0
	}
	_merge_guard_prospective_todo() {
		return 0
	}
	gh_merge_remediate_stale_auth_cache() {
		return 1
	}

	test_merge_mode "normal merge applies exact-head authority guard" 0 0
	test_merge_mode "admin merge applies exact-head authority guard" 1 0
	test_merge_mode "auto-merge applies exact-head authority guard" 0 1

	: >"$GUARD_CALLS"
	: >"$MERGE_CALLS"
	FIXTURE_GH_MODE="merge"
	AUTHORITY_GUARD_PASS=0
	local blocked_rc=0
	_merge_execute 900 owner/repo --squash 0 0 >/dev/null 2>&1 || blocked_rc=$?
	if [[ "$blocked_rc" -eq 1 && ! -s "$MERGE_CALLS" ]]; then
		print_result "failed authority guard prevents merge API invocation" 0
	else
		print_result "failed authority guard prevents merge API invocation" 1 "rc=$blocked_rc"
	fi
	return 0
}

main() {
	load_functions
	test_trusted_issue_sync_authority
	test_trusted_dependabot_authority
	test_authority_guard
	test_pre_merge_authority_preflight
	test_all_merge_modes_use_guard
	test_secondary_merge_transports_refresh_authority
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
