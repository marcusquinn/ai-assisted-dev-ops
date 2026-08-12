#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for CI repair routing from the deterministic merge pass.
# A red/pending trusted PR must pass the normal merge gates first, then route
# exactly one repair action for the same PR/head SHA instead of silently
# accumulating in the open PR backlog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
FEEDBACK_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback.sh"
FINALIZER_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback-finalizer.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
TEST_PR_HEAD_SHA=""

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
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	export TEST_CHECK_SCENARIO="terminal_failure"
	export TEST_WORKER_SLEEP_SECONDS="2"
	unset TEST_INITIAL_PR_HEAD_SHA
	unset TEST_INITIAL_PR_HEAD_EMPTY
	unset TEST_WORKTREE_ADD_FAIL
	export AIDEVOPS_CI_REPAIR_STATE_DIR="${TEST_ROOT}/repair-state"
	export AIDEVOPS_CI_REPAIR_WORKTREE_BASE_DIR="${TEST_ROOT}/worktrees"
	export AIDEVOPS_HEADLESS_RUNTIME_DIR="${TEST_ROOT}/headless-runtime"
	export AIDEVOPS_CI_REPAIR_SESSION_LOCK_WAIT_STEPS="0"
	export AIDEVOPS_PULSE_RUNNER_LOGIN="expected-runner"
	mkdir -p "${TEST_ROOT}/repo"
	TEST_PR_HEAD_SHA="abcdef0123456789abcdef0123456789abcdef01"
	export TEST_PR_HEAD_SHA
	printf 'OPEN\n' >"${TEST_ROOT}/pr-state.txt"
	printf 'origin:worker\n' >"${TEST_ROOT}/pr-labels.txt"
	printf 'status:in-review,origin:interactive\n' >"${TEST_ROOT}/issue-labels.txt"
	printf 'stale-owner\n' >"${TEST_ROOT}/issue-assignees.txt"
	cat >"${TEST_ROOT}/bin/headless-runtime-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "${AIDEVOPS_PR_REPAIR_NUMBER:-}" "${AIDEVOPS_PR_REPAIR_HEAD_SHA:-}" "${AIDEVOPS_PR_REPAIR_HEAD_REF:-}" "${AIDEVOPS_PR_REPAIR_FINGERPRINT:-}" "${AIDEVOPS_PR_REPAIR_OWNERSHIP_MODE:-}" "${WORKER_WORKTREE_PATH:-}" "${WORKER_NO_EXIT_PUSH:-}" "${WORKER_GITHUB_LOGIN:-}" "$*" >>"${GH_LOG}"
if [[ "$*" == *"--detach"* ]]; then
	sleep "${TEST_WORKER_SLEEP_SECONDS:-2}" >/dev/null 2>&1 &
	printf 'Dispatched PID: %s\n' "$!"
	exit 0
fi
sleep "${TEST_WORKER_SLEEP_SECONDS:-2}"
EOF
	chmod +x "${TEST_ROOT}/bin/headless-runtime-helper.sh"
	export AIDEVOPS_HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/bin/headless-runtime-helper.sh"
	cat >"${TEST_ROOT}/bin/worktree-helper.sh" <<'EOF'
#!/usr/bin/env bash
action="${1:-}"
shift || true
case "$action" in
add)
	branch="${1:-}"
	path="${2:-}"
	if [[ "${TEST_WORKTREE_ADD_FAIL:-0}" == "1" ]]; then
		printf 'worktree add failed %s %s\n' "$branch" "$path" >>"${GH_LOG}"
		exit 1
	fi
	shift 2
	base=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base)
			base="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	printf 'worktree add %s %s %s %s\n' "$branch" "$path" "$base" "${AIDEVOPS_WORKTREE_BASE_DIR:-}" >>"${GH_LOG}"
	mkdir -p "$path"
	;;
remove)
	path="${1:-}"
	printf 'worktree remove %s\n' "$path" >>"${GH_LOG}"
	rm -rf "$path"
	;;
*) exit 1 ;;
esac
EOF
	chmod +x "${TEST_ROOT}/bin/worktree-helper.sh"
	export AIDEVOPS_WORKTREE_HELPER="${TEST_ROOT}/bin/worktree-helper.sh"
	printf 'Original issue body.\n' >"${TEST_ROOT}/issue-body.txt"
	write_gh_mock
	return 0
}


write_gh_mock() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

if [[ "${1:-} ${2:-}" == "pr view" ]]; then
	if [[ "$*" == *"headRefOid,headRefName,isCrossRepository,maintainerCanModify"* ]]; then
		printf '%s\tfeature/repair\tfalse\ttrue\n' "${TEST_PR_HEAD_SHA}"
		exit 0
	fi
	if [[ "$*" == *"--json labels"* ]]; then
		cat "${TEST_ROOT}/pr-labels.txt"
		exit 0
	fi
	if [[ "$*" == *"--json headRefOid"* ]]; then
		if [[ "${TEST_INITIAL_PR_HEAD_EMPTY:-0}" == "1" ]]; then
			printf '\n'
		else
			printf '%s\n' "${TEST_INITIAL_PR_HEAD_SHA:-${TEST_PR_HEAD_SHA}}"
		fi
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr close" ]]; then
	printf 'CLOSED\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr reopen" ]]; then
	printf 'OPEN\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr edit" ]]; then
	_labels=$(<"${TEST_ROOT}/pr-labels.txt")
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--add-label)
			shift
			_value="${1:-}"
			[[ ",${_labels}," == *",${_value},"* ]] || _labels="${_labels:+${_labels},}${_value}"
			;;
		--remove-label)
			shift
			_value="${1:-}"
			_next=""
			IFS=',' read -r -a _parts <<<"$_labels"
			for _part in "${_parts[@]}"; do
				[[ "$_part" == "$_value" ]] && continue
				_next="${_next:+${_next},}${_part}"
			done
			_labels="$_next"
			;;
		esac
		shift || true
	done
	printf '%s\n' "$_labels" >"${TEST_ROOT}/pr-labels.txt"
	exit 0
fi

if [[ "${1:-} ${2:-}" == "run view" ]]; then
	case "${TEST_CHECK_SCENARIO:-terminal_failure}" in
	infra_timeout)
		printf '%s\n' 'Lint Run timed out after 10m'
		;;
	infra_registry_rate_limit)
		printf '%s\n' 'Error response from daemon: toomanyrequests: Rate exceeded while pulling public.ecr.aws/docker/library/postgres:18'
		;;
	infra_dockerhub_rate_limit)
		printf '%s\n' 'toomanyrequests: You have reached your unauthenticated pull rate limit.'
		;;
	infra_github_api_rate_limit)
		printf '%s\n' 'gh: API rate limit exceeded for installation. (HTTP 403)'
		;;
	log_exit_143)
		printf '%s\n' 'Lint Run ##[error]Process completed with exit code 143.'
		;;
	*)
		printf '%s\n' 'Lint Run actual lint error in source file'
		;;
	esac
	exit 0
fi
GHEOF
	_append_gh_mock_routes
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

_append_gh_mock_routes() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
	if [[ "${1:-} ${2:-}" == "pr checks" ]]; then
		_is_required=0
		[[ "$*" == *" --required "* || "$*" == *" --required"* ]] && _is_required=1
		if [[ "$*" == *"conclusion"* ]]; then
			printf '%s\n' 'Unknown JSON field: "conclusion"' >&2
			exit 1
		fi
		if [[ "$*" == *"name,bucket,state,link"* ]]; then
			case "${TEST_CHECK_SCENARIO:-terminal_failure}:${_is_required}" in
				terminal_failure:1 | log_exit_143:1 | required_and_advisory:1 | infra_registry_rate_limit:1 | infra_dockerhub_rate_limit:1 | infra_github_api_rate_limit:1)
					printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
					;;
				required_and_advisory:0)
					printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"},{"name":"Qlty","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/124/job/790"}]'
					;;
				pending_only:*|mixed_pending_pass:*)
					printf '[]\n'
					;;
				infra_timeout:1)
					printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
					;;
				advisory_failure:0)
					printf '%s\n' '[{"name":"Docs","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/789"}]'
					;;
				advisory_failure:1)
					printf '[]\n'
					;;
			esac
			exit 0
		fi
		exit 0
	fi

if [[ "${1:-} ${2:-}" == "issue view" ]]; then
	if [[ "$*" == *"--json assignees"* ]]; then
		cat "${TEST_ROOT}/issue-assignees.txt"
		exit 0
	fi
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "issue edit" ]]; then
	_labels=$(<"${TEST_ROOT}/issue-labels.txt")
	_assignees=$(<"${TEST_ROOT}/issue-assignees.txt")
	while [[ $# -gt 0 ]]; do
		_action="$1"
		if [[ "$_action" == "--body" ]]; then
			shift
			printf '%s' "$1" >"${TEST_ROOT}/issue-body.txt"
		elif [[ "$_action" == "--add-label" ]]; then
			shift
			_value="${1:-}"
			[[ ",${_labels}," == *",${_value},"* ]] || _labels="${_labels:+${_labels},}${_value}"
		elif [[ "$_action" == "--remove-label" ]]; then
			shift
			_value="${1:-}"
			_next=""
			IFS=',' read -r -a _parts <<<"$_labels"
			for _part in "${_parts[@]}"; do
				[[ "$_part" == "$_value" ]] && continue
				_next="${_next:+${_next},}${_part}"
			done
			_labels="$_next"
		elif [[ "$_action" == "--remove-assignee" ]]; then
			shift
			_value="${1:-}"
			[[ "$_assignees" == "$_value" ]] && _assignees=""
		fi
		shift || true
	done
	printf '%s\n' "$_labels" >"${TEST_ROOT}/issue-labels.txt"
	printf '%s' "$_assignees" >"${TEST_ROOT}/issue-assignees.txt"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/pulls/100" ]]; then
	printf '%s\t%s\t%s\n' "$(<"${TEST_ROOT}/pr-state.txt")" "$TEST_PR_HEAD_SHA" \
		"$(<"${TEST_ROOT}/pr-labels.txt")"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/42" ]]; then
	if [[ "$*" == *".body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
	else
		printf '%s\t%s\n' "$(<"${TEST_ROOT}/issue-labels.txt")" \
			"$(<"${TEST_ROOT}/issue-assignees.txt")"
	fi
	exit 0
fi

exit 0
GHEOF
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		local state_file="" worker_pid="" worker_start="" worker_status=""
		while IFS= read -r state_file; do
			worker_pid=$(jq -r '.pid // empty' "$state_file" 2>/dev/null) || worker_pid=""
			worker_start=$(jq -r '.pid_start // empty' "$state_file" 2>/dev/null) || worker_start=""
			worker_status=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || worker_status=""
			if [[ "$worker_status" == "dispatched" && "$worker_pid" =~ ^[0-9]+$ && "$worker_pid" != "$$" ]] \
				&& declare -F _ci_repair_pid_is_live >/dev/null 2>&1 \
				&& _ci_repair_pid_is_live "$worker_pid" "$worker_start"; then
				kill "$worker_pid" 2>/dev/null || true
				wait "$worker_pid" 2>/dev/null || true
			fi
		done < <(find "${AIDEVOPS_CI_REPAIR_STATE_DIR:-$TEST_ROOT}" -name state.json -type f 2>/dev/null)
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

extract_function() {
	local fn_name="$1"
	local source_file="$2"
	awk -v name="$fn_name" '
		$0 ~ "^" name "\\(\\) \\{" { capture = 1 }
		capture { print }
		capture && /^}$/ { capture = 0; exit }
	' "$source_file"
	return 0
}

define_process_helper() {
	local fn_src="" review_gate_src=""
	review_gate_src=$(extract_function _handle_changes_requested_review_gate "$MERGE_SCRIPT")
	fn_src=$(extract_function _process_single_ready_pr "$MERGE_SCRIPT")
	[[ -n "$review_gate_src" && -n "$fn_src" ]] || return 1

	_OW_LABEL_PAT=",origin:worker,"
	PULSE_UNKNOWN_STATE="UNKNOWN"
	PULSE_MERGE_CLOSE_CONFLICTING=false
	DRY_RUN=0
	GATE_CALLS=0
	GATE_REVIEW_ARG=""
	GATE_REVIEW_MODE=""
	RESOLVE_CALLS=0
	ROUTE_CALLS=0
	ROUTE_ARGS=""
	ROUTE_LABELS=""
	ROUTE_EVIDENCE=""
	DISMISS_CALLS=0
	PR_REQUIRED_CHECKS_RC=1
	REBASE_RETRY_RC=1
	REBASE_RETRY_CALLS=0
	REBASE_RETRY_POLICY=""
	DUPLICATE_CLOSE_RC=1
	DUPLICATE_CLOSE_CALLS=0
	PREFLIGHT_RC=0
	PREFLIGHT_EVIDENCE="[]"
	REFRESHED_MERGEABLE="UNKNOWN"
	REFRESHED_REVIEW_DECISION="NONE"
	REVIEW_REFRESH_CALLS=0

	_resolve_pr_mergeable_status() { local pr_number="$1" repo_slug="$2" mergeable="$3"; [[ -n "$pr_number$repo_slug$mergeable" ]]; RESOLVE_CALLS=$((RESOLVE_CALLS + 1)); return 0; }
	_pmp_refresh_unknown_mergeable_state_into() { local dest_var="$1" pr_number="$2" repo_slug="$3" mergeable="$4"; [[ -n "$pr_number$repo_slug$mergeable" ]]; printf -v "$dest_var" '%s' "$REFRESHED_MERGEABLE"; return 0; }
	_pmp_normalize_pr_lifecycle_state_into() { local dest_var="$1"; local raw_state="$2"; local normalized_state=""; case "$raw_state" in [Oo][Pp][Ee][Nn]) normalized_state="OPEN" ;; [Cc][Ll][Oo][Ss][Ee][Dd]) normalized_state="CLOSED" ;; [Mm][Ee][Rr][Gg][Ee][Dd]) normalized_state="MERGED" ;; *) normalized_state="$raw_state" ;; esac; printf -v "$dest_var" '%s' "$normalized_state"; return 0; }
	_pmp_normalize_review_decision_into() { local dest_var="$1" raw_decision="$2" normalized_decision=""; case "$raw_decision" in CHANGES_REQUESTED|APPROVED|REVIEW_REQUIRED|NONE) normalized_decision="$raw_decision" ;; ''|null|NULL|UNKNOWN|unknown) normalized_decision="UNKNOWN" ;; *) normalized_decision="$raw_decision" ;; esac; printf -v "$dest_var" '%s' "$normalized_decision"; return 0; }
	_pmp_review_decision_is_unknown() { local raw_decision="$1" _test_normalized_decision=""; _pmp_normalize_review_decision_into _test_normalized_decision "$raw_decision"; [[ "$_test_normalized_decision" == "UNKNOWN" ]]; return $?; }
	_pmp_refresh_unknown_review_decision_into() { local dest_var="$1" pr_number="$2" repo_slug="$3" review_decision="$4"; [[ -n "$pr_number$repo_slug$review_decision" ]]; REVIEW_REFRESH_CALLS=$((REVIEW_REFRESH_CALLS + 1)); printf -v "$dest_var" '%s' "$REFRESHED_REVIEW_DECISION"; return 0; }
	_extract_linked_issue() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; printf '42\n'; return 0; }
	_check_pr_merge_gates() { local pr_number="$1" repo_slug="$2" pr_author="$3" pr_review="$4" linked_issue="$5" review_mode="${8:-merge}"; [[ -n "$pr_number$repo_slug$pr_author$pr_review$linked_issue" ]]; GATE_CALLS=$((GATE_CALLS + 1)); GATE_REVIEW_ARG="$pr_review"; GATE_REVIEW_MODE="$review_mode"; return 0; }
	_pr_required_checks_pass() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; if [[ "$PR_REQUIRED_CHECKS_RC" -eq 0 ]]; then return 0; fi; return 1; }
	_check_required_checks_passing() { local repo_slug="$1" pr_number="$2"; [[ -n "$repo_slug$pr_number" ]]; return 1; }
	_is_trusted_dependabot_update_pr() { local pr_number="$1" repo_slug="$2" pr_author="$3"; [[ -n "$pr_number$repo_slug$pr_author" ]]; return 1; }
	_trusted_dependabot_non_review_checks_green() { local pr_number="$1" repo_slug="$2" pr_obj="$3"; [[ -n "$pr_number$repo_slug$pr_obj" ]]; return 1; }
	_attempt_pr_ci_rebase_retry() { local pr_number="$1" repo_slug="$2" rebase_policy="${5:-standard}"; [[ -n "$pr_number$repo_slug" ]]; REBASE_RETRY_CALLS=$((REBASE_RETRY_CALLS + 1)); REBASE_RETRY_POLICY="$rebase_policy"; return "$REBASE_RETRY_RC"; }
	_pm_close_superseded_duplicate_pr_if_issue_solved() { local pr_number="$1" repo_slug="$2" linked_issue="$3" pr_labels="$4"; [[ -n "$pr_number$repo_slug$linked_issue$pr_labels" ]]; DUPLICATE_CLOSE_CALLS=$((DUPLICATE_CLOSE_CALLS + 1)); return "$DUPLICATE_CLOSE_RC"; }
	_route_pr_to_fix_worker() { local pr_number="$1" repo_slug="$2" linked_issue="$3" mode="$4" pr_labels="${5:-}" checks_json="${9:-}"; ROUTE_CALLS=$((ROUTE_CALLS + 1)); ROUTE_ARGS="${pr_number}|${repo_slug}|${linked_issue}|${mode}"; ROUTE_LABELS="$pr_labels"; ROUTE_EVIDENCE="$checks_json"; return 0; }
	_pulse_merge_dismiss_coderabbit_nits() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; DISMISS_CALLS=$((DISMISS_CALLS + 1)); if [[ "${DISMISS_NITS_RC:-0}" -eq 0 ]]; then return 0; fi; return 1; }
	_attempt_pr_update_branch() { return 1; }
	_attempt_existing_auto_merge_behind_update_branch() { return 1; }
	_attempt_green_behind_update_branch() { return 1; }
	approve_collaborator_pr() { return 0; }
	_check_ruleset_required_reviews_passing() { return 0; }
	_extract_merge_summary() { printf 'test summary'; return 0; }
	_retarget_stacked_children() { return 0; }
	_pulse_merge_admin_safety_check() { return 0; }
	_set_native_auto_merge_or_skip() { return 0; }
	_pulse_merge_changes_requested_thread_remediation_first_enabled() { return 1; }
	_pulse_merge_preflight_snapshot_gate() { _PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON="$PREFLIGHT_EVIDENCE"; return "$PREFLIGHT_RC"; }
	_pulse_merge_final_trust_gate() { _PULSE_FINAL_REQUIRES_SYNCHRONOUS_MERGE=0; _PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON="$PREFLIGHT_EVIDENCE"; return "$PREFLIGHT_RC"; }
	_pulse_merge_maybe_dispatch_preflight_remediation() { return 0; }
	_close_conflicting_pr() { return 0; }
	_pmp_is_protected_release_pr() { return 1; }
	_pmp_normalize_mergeable_state_into() { return 0; }
	gh_pr_view() { gh pr view "$@"; return $?; }
	printf -v PR_OBJECT '%s' '{"number":100,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"","author":{"login":"worker-bot"},"title":"t1: fix"}'

	# shellcheck disable=SC1090
	eval "$review_gate_src"
	# shellcheck disable=SC1090
	eval "$fn_src"
	return 0
}

define_feedback_helpers() {
	local fns=(
		_build_ci_feedback_section
		_ci_check_url_has_infra_failure_log
		_ci_actionable_failed_checks_markdown
		_ci_terminal_failed_check_results
		_ci_merge_check_sets
		_ci_repair_required_checks_json
		_append_feedback_to_issue
		_transition_issue_for_redispatch
		_ci_repair_write_state
		_ci_repair_process_start
		_ci_repair_pid_is_live
		_ci_repair_publish_lock_owner
		_ci_repair_lock_is_stale
		_ci_repair_claim_dir_is_active
		_ci_repair_status_preparing
		_ci_repair_status_dispatched
		_ci_repair_result_active
		_ci_repair_result_exhausted
		_ci_repair_result_retryable
		_ci_repair_claim_next_attempt
		_ci_repair_latest_archive
		_ci_repair_prepare_attempt
		_ci_repair_adopt_live_session
		_ci_repair_claim_lease
		_ci_repair_create_worktree
		_ci_repair_session_identity
		_ci_repair_launch_worker
		_ci_repair_write_prompt
		_ci_repair_legacy_lease_is_active
		_ci_repair_hash_text
		_ci_repair_session_key
		_dispatch_ci_repair_session
		_route_ci_repair_fallback
		_dispatch_ci_fix_worker
	)
	local fn fn_src
	cat >"${TEST_ROOT}/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"cat-file -e"* ]]; then
	exit 0
fi
if [[ "$*" == *"rev-parse HEAD"* ]]; then
	printf '%s\n' "${TEST_PR_HEAD_SHA}"
	exit 0
fi
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/git"
	gh_issue_edit_safe() { gh issue edit "$@"; return $?; }
	_pmrc_rerun_infrastructure_check() { local repo_slug="$1"; local pr_number="$2"; local check_name="$3"; local check_url="$4"; printf '%s|%s|%s|%s\n' "$repo_slug" "$pr_number" "$check_name" "$check_url" >>"${TEST_ROOT}/infra-rerun-calls.log"; return 0; }
	_emit_ci_failure_guidance_blocks() { return 0; }
	_classify_ci_failures_by_pattern() { local failing_names="$1"; printf '%s' "$failing_names" >"${TEST_ROOT}/classified-names.txt"; return 0; }
	_pulse_merge_repo_path_for_slug() { local repo_slug="$1"; [[ -n "$repo_slug" ]]; printf '%s\n' "${TEST_ROOT}/repo"; return 0; }
	_is_process_alive_and_matches() { local process_pid="$1"; local process_pattern="$2"; local stored_hash="$3"; [[ -n "$process_pattern" || -n "$stored_hash" ]]; kill -0 "$process_pid" 2>/dev/null; return $?; }
	_file_mtime_epoch() { local file_path="$1"; [[ -e "$file_path" ]] || return 1; date +%s; return 0; }
	gh_pr_checks_exact_json() {
		local repo_slug="$1"
		local pr_number="$2"
		local selection_mode="$3"
		printf 'exact-checks %s %s %s\n' "$repo_slug" "$pr_number" "$selection_mode" >>"$GH_LOG"
		case "${TEST_CHECK_SCENARIO:-terminal_failure}" in
		pending_only)
			printf '%s\n' '[{"name":"Lint","bucket":"pending","state":"IN_PROGRESS","link":""}]'
			return 8
			;;
		mixed_pending_pass)
			printf '%s\n' '[{"name":"Lint","bucket":"pending","state":"QUEUED","link":""},{"name":"Unit","bucket":"pass","state":"SUCCESS","link":""}]'
			return 8
			;;
		advisory_failure)
			printf "%s\n" "no required checks reported on the 'feature/repair' branch" >&2
			return 1
			;;
		*)
			printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
			return 1
			;;
		esac
	}
	for fn in "${fns[@]}"; do
		fn_src=$(extract_function "$fn" "$FEEDBACK_SCRIPT")
		[[ -n "$fn_src" ]] || return 1
		# shellcheck disable=SC1090
		eval "$fn_src"
	done
	unset _PULSE_MERGE_FEEDBACK_FINALIZER_LOADED
	# shellcheck disable=SC1090
	source "$FINALIZER_SCRIPT"
	return 0
}

test_red_pr_passes_gates_before_repair_route() {
	setup_test_env
	define_process_helper || { print_result "defines process helper" 1 "could not extract _process_single_ready_pr"; teardown_test_env; return 0; }

	_process_single_ready_pr "owner/repo" "$PR_OBJECT" || true

	if [[ "$GATE_CALLS" -ne 1 ]]; then
		print_result "red PR runs merge gates before CI repair routing" 1 "Expected 1 gate call, got ${GATE_CALLS}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "100|owner/repo|42|ci" ]]; then
		print_result "red PR routes one CI repair after gates pass" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "red PR passes gates then routes exactly one CI repair" 0
	fi
	teardown_test_env
	return 0
}

test_rebase_success_defers_ci_repair_route() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for rebase deferral" 1 "could not extract _process_single_ready_pr"; teardown_test_env; return 0; }

	local rc=0
	REBASE_RETRY_RC=0
	_process_single_ready_pr "owner/repo" "$PR_OBJECT" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "successful CI-drift rebase defers CI repair routing" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$GATE_CALLS" -ne 1 ]]; then
		print_result "successful CI-drift rebase defers CI repair routing" 1 "gate_calls=${GATE_CALLS}"
	elif [[ "$ROUTE_CALLS" -ne 0 ]]; then
		print_result "successful CI-drift rebase defers CI repair routing" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "successful CI-drift rebase defers CI repair routing" 0
	fi
	teardown_test_env
	return 0
}

test_converged_changes_requested_runs_strict_rebase_only() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for review-repair rebase" 1 "could not extract _process_single_ready_pr or review gate"; teardown_test_env; return 0; }
	_pulse_merge_changes_requested_thread_remediation_first_enabled() { return 0; }
	_pulse_merge_dispatch_review_thread_remediation() { _PULSE_MERGE_REMEDIATION_OUTCOME="converged"; return 0; }

	local pr_object rc=0
	REBASE_RETRY_RC=0
	DUPLICATE_CLOSE_RC=0
	printf -v pr_object '%s' '{"number":558,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","author":{"login":"worker-bot"},"title":"GH#503: repair drift","updatedAt":"2026-08-03T00:00:00Z","headRefOid":"sha558","headRefName":"fix/review-repair","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "converged CHANGES_REQUESTED runs strict rebase only" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$GATE_CALLS" -ne 1 || "$GATE_REVIEW_ARG" != "CHANGES_REQUESTED" || "$GATE_REVIEW_MODE" != "ci-rebase-only" ]]; then
		print_result "converged CHANGES_REQUESTED runs strict rebase only" 1 "gate_calls=${GATE_CALLS}, gate_review=${GATE_REVIEW_ARG}, gate_mode=${GATE_REVIEW_MODE}"
	elif [[ "$REBASE_RETRY_CALLS" -ne 1 || "$REBASE_RETRY_POLICY" != "review-repair" ]]; then
		print_result "converged CHANGES_REQUESTED runs strict rebase only" 1 "rebase_calls=${REBASE_RETRY_CALLS}, policy=${REBASE_RETRY_POLICY}"
	elif [[ "$DUPLICATE_CLOSE_CALLS" -ne 0 ]]; then
		print_result "converged CHANGES_REQUESTED runs strict rebase only" 1 "duplicate_close_calls=${DUPLICATE_CLOSE_CALLS}"
	elif [[ "$ROUTE_CALLS" -ne 0 ]]; then
		print_result "converged CHANGES_REQUESTED runs strict rebase only" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "converged CHANGES_REQUESTED runs trust-gated strict rebase only" 0
	fi
	teardown_test_env
	return 0
}

test_converged_changes_requested_never_falls_through_to_merge() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for review-repair merge block" 1 "could not extract _process_single_ready_pr or review gate"; teardown_test_env; return 0; }
	_pulse_merge_changes_requested_thread_remediation_first_enabled() { return 0; }
	_pulse_merge_dispatch_review_thread_remediation() { _PULSE_MERGE_REMEDIATION_OUTCOME="converged"; return 0; }

	local pr_object rc=0
	PR_REQUIRED_CHECKS_RC=0
	REBASE_RETRY_RC=1
	printf -v pr_object '%s' '{"number":559,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","author":{"login":"worker-bot"},"title":"GH#504: preserve review block","updatedAt":"2026-08-03T00:00:00Z","headRefOid":"sha559","headRefName":"fix/review-block","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 1 || "$REBASE_RETRY_CALLS" -ne 1 || "$ROUTE_CALLS" -ne 0 ]]; then
		print_result "converged CHANGES_REQUESTED never reaches merge" 1 "rc=${rc}, rebase_calls=${REBASE_RETRY_CALLS}, route_calls=${ROUTE_CALLS}"
	else
		print_result "converged CHANGES_REQUESTED remains blocking after repair-only no-op" 0
	fi
	teardown_test_env
	return 0
}

test_repair_only_gate_stops_before_review_bot_boundary() {
	setup_test_env
	define_process_helper || { print_result "defines repair-only gate helper" 1 "could not extract review gate"; teardown_test_env; return 0; }
	local gate_src="" gate_rc=0 review_bot_calls=0
	local old_agents_dir="${AGENTS_DIR:-}"
	gate_src=$(extract_function _check_pr_merge_gates "$MERGE_SCRIPT")
	if [[ -z "$gate_src" ]]; then
		print_result "repair-only gate stops before review-bot boundary" 1 "could not extract _check_pr_merge_gates"
		teardown_test_env
		return 0
	fi
	AGENTS_DIR="${TEST_ROOT}/agents"
	mkdir -p "${AGENTS_DIR}/scripts"
	: >"${AGENTS_DIR}/scripts/review-bot-gate-helper.sh"
	_is_collaborator_author() { _PULSE_AUTHOR_PERMISSION_VALUE="write"; return 0; }
	check_pr_modifies_workflows() { return 1; }
	_pm_issue_api() { local repo_slug="$1" issue_number="$2"; printf 'repos/%s/issues/%s\n' "$repo_slug" "$issue_number"; return 0; }
	gh() { return 0; }
	gh_pr_view() {
		if [[ "$*" == *"labels,isDraft"* ]]; then
			printf '%s\n' '{"labels":[{"name":"origin:worker"}],"isDraft":false}'
		else
			printf 'origin:worker\n'
		fi
		return 0
	}
	_attempt_worker_briefed_auto_merge() { return 0; }
	bash() { review_bot_calls=$((review_bot_calls + 1)); return 1; }
	# shellcheck disable=SC1090
	eval "$gate_src"

	_check_pr_merge_gates "560" "owner/repo" "worker-bot" "CHANGES_REQUESTED" "42" "origin:worker" "sha560" "ci-rebase-only" || gate_rc=$?
	unset -f bash gh gh_pr_view _is_collaborator_author check_pr_modifies_workflows \
		_pm_issue_api _attempt_worker_briefed_auto_merge _check_pr_merge_gates
	if [[ -n "$old_agents_dir" ]]; then
		AGENTS_DIR="$old_agents_dir"
	else
		unset AGENTS_DIR
	fi

	if [[ "$gate_rc" -ne 0 || "$review_bot_calls" -ne 0 ]]; then
		print_result "repair-only gate stops before review-bot boundary" 1 "gate_rc=${gate_rc}, review_bot_calls=${review_bot_calls}"
	else
		print_result "repair-only mode applies non-review trust gates without treating review as cleared" 0
	fi
	teardown_test_env
	return 0
}

test_preflight_terminal_blocker_routes_supplied_evidence() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for preflight blocker routing" 1 "could not extract _process_single_ready_pr"; teardown_test_env; return 0; }

	local rc=0
	local expected_evidence='[{"name":"CodeFactor","bucket":"fail","state":"FAILURE","conclusion":"failure","link":"https://github.com/owner/repo/runs/99"}]'
	PR_REQUIRED_CHECKS_RC=0
	PREFLIGHT_RC=1
	PREFLIGHT_EVIDENCE="$expected_evidence"
	_process_single_ready_pr "owner/repo" "$PR_OBJECT" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "preflight terminal blocker routes supplied evidence" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "100|owner/repo|42|ci" ]]; then
		print_result "preflight terminal blocker routes supplied evidence" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	elif [[ "$ROUTE_EVIDENCE" != "$expected_evidence" ]]; then
		print_result "preflight terminal blocker routes supplied evidence" 1 "route_evidence=${ROUTE_EVIDENCE}"
	else
		print_result "head-bound preflight blocker reaches trusted CI repair route" 0
	fi
	teardown_test_env
	return 0
}

test_changes_requested_unknown_routes_before_mergeable_skip() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for review routing" 1 "could not extract _process_single_ready_pr or review gate"; teardown_test_env; return 0; }

	local pr_object rc=0
	printf -v pr_object '%s' '{"number":554,"state":"OPEN","mergeable":"UNKNOWN","reviewDecision":"CHANGES_REQUESTED","author":{"login":"worker-bot"},"title":"GH#500: fix","updatedAt":"2026-06-21T00:00:00Z","headRefOid":"sha554","headRefName":"fix/review","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "554|owner/repo|42|review" ]]; then
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	elif [[ "$RESOLVE_CALLS" -ne 0 || "$GATE_CALLS" -ne 0 ]]; then
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 1 "resolve_calls=${RESOLVE_CALLS}, gate_calls=${GATE_CALLS}"
	else
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 0
	fi
	teardown_test_env
	return 0
}

test_rest_missing_review_decision_refreshes_before_ci_route() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for REST review refresh" 1 "could not extract _process_single_ready_pr"; teardown_test_env; return 0; }

	local pr_object rc=0
	REFRESHED_REVIEW_DECISION="CHANGES_REQUESTED"
	printf -v pr_object '%s' '{"number":557,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":null,"author":{"login":"worker-bot"},"title":"GH#502: fix","updatedAt":"2026-06-21T00:00:00Z","headRefOid":"sha557","headRefName":"fix/rest-review","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "REST-missing reviewDecision refreshes before CI route" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$REVIEW_REFRESH_CALLS" -ne 1 ]]; then
		print_result "REST-missing reviewDecision refreshes before CI route" 1 "review_refresh_calls=${REVIEW_REFRESH_CALLS}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "557|owner/repo|42|review" ]]; then
		print_result "REST-missing reviewDecision refreshes before CI route" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	elif [[ "$GATE_CALLS" -ne 0 ]]; then
		print_result "REST-missing reviewDecision refreshes before CI route" 1 "gate_calls=${GATE_CALLS}"
	else
		print_result "REST-missing reviewDecision refreshes before CI route" 0
	fi
	teardown_test_env
	return 0
}

test_coderabbit_nits_ok_dismissed_once_before_late_gate() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for coderabbit review routing" 1 "could not extract _process_single_ready_pr or review gate"; teardown_test_env; return 0; }

	local pr_object rc=0
	DRY_RUN=0
	PR_REQUIRED_CHECKS_RC=0
	printf -v pr_object '%s' '{"number":555,"state":"OPEN","mergeable":"UNKNOWN","reviewDecision":"CHANGES_REQUESTED","author":{"login":"worker-bot"},"title":"GH#501: fix","updatedAt":"2026-06-21T00:00:00Z","headRefOid":"sha555","headRefName":"fix/nits","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"},{"name":"coderabbit-nits-ok"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 4 ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "Expected native-auto defer return 4, got ${rc}"
	elif [[ "$DISMISS_CALLS" -ne 1 ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "dismiss_calls=${DISMISS_CALLS}"
	elif [[ "$GATE_CALLS" -ne 1 || "$GATE_REVIEW_ARG" != "NONE" ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "gate_calls=${GATE_CALLS}, gate_review=${GATE_REVIEW_ARG}"
	elif [[ "$ROUTE_CALLS" -ne 0 ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "route_calls=${ROUTE_CALLS}"
	else
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 0
	fi
	teardown_test_env
	return 0
}

test_changes_requested_empty_labels_refresh_current_metadata() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for explicit empty labels" 1 "could not extract review gate"; teardown_test_env; return 0; }

	: >"$GH_LOG"
	_handle_changes_requested_review_gate "556" "owner/repo" "CHANGES_REQUESTED" "42" "" || true

	local label_fetch_count=0
	label_fetch_count=$(grep -c -- '--json labels' "$GH_LOG" || true)
	[[ "$label_fetch_count" =~ ^[0-9]+$ ]] || label_fetch_count=0
	if [[ "$label_fetch_count" -ne 1 ]]; then
		print_result "empty PR labels refresh current metadata once" 1 "label_fetch_count=${label_fetch_count}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "556|owner/repo|42|review" ]]; then
		print_result "refreshed empty PR labels preserve review routing" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "empty PR labels refresh current metadata before review routing" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_dedupes_identical_evidence_for_same_head() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	local edit_count state_count worktree_count dispatch_count active_count ownership_mode_count
	edit_count=$(grep -c 'gh issue edit .*--body' "$GH_LOG" || true)
	[[ "$edit_count" =~ ^[0-9]+$ ]] || edit_count=0
	state_count=$(find "$AIDEVOPS_CI_REPAIR_STATE_DIR" -name state.json -type f | wc -l | tr -d ' ')
	worktree_count=$(grep -c '^worktree add ' "$GH_LOG" || true)
	dispatch_count=$(grep -c 'dispatched in-place CI repair' "$LOGFILE" || true)
	active_count=$(grep -c 'in-place CI repair already active' "$LOGFILE" || true)
	ownership_mode_count=$(grep -c '|linked-issue|' "$GH_LOG" || true)

	if [[ "$edit_count" -ne 0 || "$state_count" -ne 1 || "$worktree_count" -ne 1 ]]; then
		print_result "CI repair dedupes identical evidence by repo/PR/head" 1 "issue_edits=${edit_count}, states=${state_count}, worktrees=${worktree_count}"
	elif [[ "$dispatch_count" -ne 1 || "$active_count" -ne 1 || "$ownership_mode_count" -ne 1 ]]; then
		print_result "CI repair distinguishes dispatch from a live lease" 1 "dispatches=${dispatch_count}, active=${active_count}, ownership_modes=${ownership_mode_count}"
	else
		print_result "CI repair dedupes and reports a live lease without false dispatch" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_dedupes_changed_evidence_for_same_head() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers for changed evidence" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_repair_session "100" "owner/repo" "42" "$TEST_PR_HEAD_SHA" "feature/repair" \
		"fingerprint-one" "- **Lint**: failure — [check URL](https://github.com/owner/repo/actions/runs/123/job/456)"
	_dispatch_ci_repair_session "100" "owner/repo" "42" "$TEST_PR_HEAD_SHA" "feature/repair" \
		"fingerprint-two" "- **Unit**: failure — [check URL](https://github.com/owner/repo/actions/runs/124/job/789)"

	local state_count=0 worktree_count=0
	state_count=$(find "$AIDEVOPS_CI_REPAIR_STATE_DIR" -name state.json -type f | wc -l | tr -d ' ')
	worktree_count=$(grep -c '^worktree add ' "$GH_LOG" || true)
	if [[ "$state_count" -ne 1 || "$worktree_count" -ne 1 ]]; then
		print_result "changed CI evidence shares one PR/head lease" 1 "states=${state_count}, worktrees=${worktree_count}"
	else
		print_result "changed CI evidence cannot overlap repair workers for one head" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_respects_live_legacy_lease() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers for legacy lease" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local legacy_key="owner_repo-100-${TEST_PR_HEAD_SHA}-legacyfingerprint"
	local legacy_dir="${AIDEVOPS_CI_REPAIR_STATE_DIR}/${legacy_key}"
	local legacy_pid=""
	sleep 30 &
	legacy_pid=$!
	mkdir -p "$legacy_dir"
	printf '{"repo":"owner/repo","pr":100,"head":"%s","fingerprint":"legacyfingerprint","pid":%s,"status":"dispatched"}\n' \
		"$TEST_PR_HEAD_SHA" "$legacy_pid" >"${legacy_dir}/state.json"
	mkdir -p "${AIDEVOPS_HEADLESS_RUNTIME_DIR}/locks"
	printf '%s|\n' "$legacy_pid" >"${AIDEVOPS_HEADLESS_RUNTIME_DIR}/locks/ci-repair-100-${TEST_PR_HEAD_SHA:0:12}-legacyfinger.pid"
	_dispatch_ci_repair_session "100" "owner/repo" "42" "$TEST_PR_HEAD_SHA" "feature/repair" \
		"new-fingerprint" "- **Lint**: failure — [check URL](https://github.com/owner/repo/actions/runs/123/job/456)"
	kill "$legacy_pid" 2>/dev/null || true
	wait "$legacy_pid" 2>/dev/null || true

	local worktree_count=0
	worktree_count=$(grep -c '^worktree add ' "$GH_LOG" || true)
	if [[ "$worktree_count" -ne 0 || "${_CI_REPAIR_DISPATCH_RESULT:-}" != "active" ]]; then
		print_result "live legacy CI lease blocks migrated overlap" 1 "worktrees=${worktree_count}, result=${_CI_REPAIR_DISPATCH_RESULT:-unset}"
	else
		print_result "live legacy fingerprint lease remains exclusive during migration" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_session_keys_are_repository_scoped() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers for repository session keys" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local first_key="" second_key=""
	first_key=$(_ci_repair_session_key "acme/foo_bar" "100" "$TEST_PR_HEAD_SHA")
	second_key=$(_ci_repair_session_key "acme_foo/bar" "100" "$TEST_PR_HEAD_SHA")
	if [[ "$first_key" == "$second_key" ]]; then
		print_result "CI repair session keys include repository identity" 1 "first=${first_key}, second=${second_key}"
	else
		print_result "flattening-collision repository slugs have isolated session keys" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_worktree_paths_are_repository_scoped() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers for repository worktrees" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local first_path="" second_path=""
	first_path=$(_ci_repair_create_worktree "${TEST_ROOT}/repo" "first/repo" "42" "100" "$TEST_PR_HEAD_SHA" \
		"feature/repair" "fingerprint" "1")
	second_path=$(_ci_repair_create_worktree "${TEST_ROOT}/repo" "second/repo" "42" "100" "$TEST_PR_HEAD_SHA" \
		"feature/repair" "fingerprint" "1")
	if [[ "$first_path" == "$second_path" || -z "$first_path" || -z "$second_path" ]]; then
		print_result "CI repair worktree paths include repository identity" 1 "first=${first_path}, second=${second_path}"
	elif ! grep -q " ${AIDEVOPS_CI_REPAIR_WORKTREE_BASE_DIR}$" "$GH_LOG"; then
		print_result "CI-specific worktree base reaches worktree helper validation" 1 "Log: $(cat "$GH_LOG")"
	else
		print_result "same-basename repositories have isolated repair worktrees" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_pending_only_checks() {
	setup_test_env
	TEST_CHECK_SCENARIO="pending_only"
	define_feedback_helpers || { print_result "defines feedback helpers for pending-only" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "pending-only checks do not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	elif ! grep -qF 'no actionable failed checks with URLs' "$LOGFILE"; then
		print_result "pending-only checks log terminal-failure skip" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "pending-only checks do not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_mixed_pending_pass_checks() {
	setup_test_env
	TEST_CHECK_SCENARIO="mixed_pending_pass"
	define_feedback_helpers || { print_result "defines feedback helpers for mixed pending/pass" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "mixed pending/pass checks do not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "mixed pending/pass checks do not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_emits_terminal_failure_with_conclusion_and_url() {
	setup_test_env
	TEST_CHECK_SCENARIO="terminal_failure"
	define_feedback_helpers || { print_result "defines feedback helpers for terminal failure" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	sleep 1

	local prompt_file=""
	prompt_file=$(find "$AIDEVOPS_CI_REPAIR_STATE_DIR" -name prompt.md -type f -print -quit)
	if [[ -z "$prompt_file" ]] || ! grep -qF '**Lint**: failure — [check URL](https://github.com/owner/repo/actions/runs/123/job/456)' "$prompt_file"; then
		print_result "terminal failure dispatch includes conclusion and check URL" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif ! grep -q "${TEST_ROOT}/worktrees/.*|1|expected-runner|run --role worker.*--dir ${TEST_ROOT}/worktrees/" "$GH_LOG"; then
		print_result "terminal failure dispatch uses matching worker worktree env and directory" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "terminal failure preserves existing PR" 1 "Unexpected close: $(cat "$GH_LOG")"
	else
		print_result "terminal failure dispatches against and preserves existing PR" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_uses_supplied_non_required_blocker_evidence() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers for supplied preflight evidence" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local supplied='[{"name":"CodeFactor","bucket":"fail","state":"FAILURE","conclusion":"failure","link":"https://github.com/owner/repo/actions/runs/125/job/791"}]'
	_dispatch_ci_fix_worker "100" "owner/repo" "42" "$supplied"
	sleep 1

	local prompt_file=""
	prompt_file=$(find "$AIDEVOPS_CI_REPAIR_STATE_DIR" -name prompt.md -type f -print -quit)
	if [[ -z "$prompt_file" ]] || ! grep -qF '**CodeFactor**: failure — [check URL](https://github.com/owner/repo/actions/runs/125/job/791)' "$prompt_file"; then
		print_result "supplied non-required blocker launches CI repair" 1 "Dispatch log: $(cat "$GH_LOG")"
	else
		print_result "supplied non-required preflight blocker launches bounded CI repair" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_defers_when_head_changes_during_collection() {
	setup_test_env
	export TEST_INITIAL_PR_HEAD_SHA="1111111111111111111111111111111111111111"
	define_feedback_helpers || { print_result "defines feedback helpers for moving head" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	if grep -q '^worktree add ' "$GH_LOG"; then
		print_result "moving PR head defers stale CI evidence" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif ! grep -qF 'head changed while collecting CI evidence' "$LOGFILE"; then
		print_result "moving PR head records repair deferral" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "CI evidence is not bound to a concurrently changed head" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_defers_without_initial_head_snapshot() {
	setup_test_env
	export TEST_INITIAL_PR_HEAD_EMPTY="1"
	define_feedback_helpers || { print_result "defines feedback helpers for missing head snapshot" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	if grep -q '^worktree add ' "$GH_LOG"; then
		print_result "missing PR head snapshot defers CI repair" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif ! grep -qF 'head snapshot unavailable' "$LOGFILE"; then
		print_result "missing PR head snapshot records repair deferral" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "CI repair fails closed without an initial head snapshot" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_infra_timeout_checks() {
	setup_test_env
	TEST_CHECK_SCENARIO="infra_timeout"
	define_feedback_helpers || { print_result "defines feedback helpers for infra timeout" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "infra timeout checks do not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "infra timeout checks do not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_failed_check_with_exit_143_log() {
	setup_test_env
	TEST_CHECK_SCENARIO="log_exit_143"
	define_feedback_helpers || { print_result "defines feedback helpers for log exit 143" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "failed check with exit 143 log does not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	elif ! grep -qF 'classified as infrastructure failure' "$LOGFILE"; then
		print_result "failed check with exit 143 log records infrastructure classification" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "failed check with exit 143 log does not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_registry_rate_limit_failure() {
	setup_test_env
	TEST_CHECK_SCENARIO="infra_registry_rate_limit"
	define_feedback_helpers || { print_result "defines feedback helpers for registry rate limit" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'PR #100: CI repair' "$GH_LOG"; then
		print_result "registry rate limit does not dispatch a code repair" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif ! grep -qF 'classified as infrastructure failure' "$LOGFILE"; then
		print_result "registry rate limit records infrastructure classification" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "registry rate limit is classified as infrastructure" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_dockerhub_pull_rate_limit_failure() {
	setup_test_env
	TEST_CHECK_SCENARIO="infra_dockerhub_rate_limit"
	define_feedback_helpers || { print_result "defines feedback helpers for Docker Hub rate limit" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	if grep -qF 'PR #100: CI repair' "$GH_LOG"; then
		print_result "Docker Hub pull rate limit does not dispatch code repair" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif ! grep -qF 'classified as infrastructure failure' "$LOGFILE"; then
		print_result "Docker Hub pull rate limit records infrastructure classification" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "Docker Hub unauthenticated pull limit is classified as infrastructure" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_github_api_rate_limit_failure() {
	setup_test_env
	TEST_CHECK_SCENARIO="infra_github_api_rate_limit"
	define_feedback_helpers || { print_result "defines feedback helpers for GitHub API rate limit" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	if grep -qF 'PR #100: CI repair' "$GH_LOG"; then
		print_result "GitHub API rate limit does not dispatch code repair" 1 "Dispatch log: $(cat "$GH_LOG")"
	elif ! grep -qF 'classified as infrastructure failure' "$LOGFILE"; then
		print_result "GitHub API rate limit records infrastructure classification" 1 "Log: $(cat "$LOGFILE")"
	elif ! grep -qF 'owner/repo|100|Lint|https://github.com/owner/repo/actions/runs/123/job/456' "${TEST_ROOT}/infra-rerun-calls.log" 2>/dev/null; then
		print_result "GitHub API rate limit requests bounded infrastructure rerun" 1 "Rerun calls missing or incorrect"
	else
		print_result "GitHub API installation limit requests bounded infrastructure rerun" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_preserves_pr_until_launch_retries_exhausted() {
	setup_test_env
	export TEST_WORKTREE_ADD_FAIL="1"
	define_feedback_helpers || { print_result "defines feedback helpers for retryable launch failures" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local first_close_count=0 second_close_count=0 final_close_count=0
	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	first_close_count=$(grep -cF 'gh pr close 100' "$GH_LOG" || true)
	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	second_close_count=$(grep -cF 'gh pr close 100' "$GH_LOG" || true)
	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	final_close_count=$(grep -cF 'gh pr close 100' "$GH_LOG" || true)

	if [[ "$first_close_count" -ne 0 || "$second_close_count" -ne 0 ]]; then
		print_result "retryable CI repair failures preserve the PR" 1 "close counts before exhaustion: first=${first_close_count}, second=${second_close_count}"
	elif [[ "$final_close_count" -ne 1 ]]; then
		print_result "exhausted CI repair failures take one durable fallback" 1 "final close count=${final_close_count}; GH log: $(cat "$GH_LOG")"
	else
		print_result "CI repair preserves the PR until bounded launch retries exhaust" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_recovers_one_stale_lease_then_exhausts() {
	setup_test_env
	export TEST_WORKER_SLEEP_SECONDS="0.2"
	define_feedback_helpers || { print_result "defines feedback helpers for stale repair lease" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	sleep 1
	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	sleep 1
	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	local worktree_count=0 current_attempt=""
	worktree_count=$(grep -c '^worktree add ' "$GH_LOG" || true)
	current_attempt=$(find "$AIDEVOPS_CI_REPAIR_STATE_DIR" -name state.json -type f -exec jq -r '.attempt // empty' {} \;)
	if [[ "$worktree_count" -ne 1 || "$current_attempt" != "2" ]]; then
		print_result "stale CI repair lease resumes one worktree for a bounded retry" 1 "worktrees=${worktree_count}, attempt=${current_attempt}"
	elif ! grep -qF 'recovering stale repair' "$LOGFILE"; then
		print_result "stale CI repair retry is observable" 1 "Log: $(cat "$LOGFILE")"
	elif ! grep -qF 'resuming stale repair worktree' "$LOGFILE"; then
		print_result "stale CI repair preserves prior worktree evidence" 1 "Log: $(cat "$LOGFILE")"
	elif ! grep -qF 'exhausted 2 attempts' "$LOGFILE"; then
		print_result "exhausted CI repair lease is observable" 1 "Log: $(cat "$LOGFILE")"
	elif ! grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "exhausted CI repair lease takes durable fallback" 1 "GH log: $(cat "$GH_LOG")"
	else
		print_result "stale CI repair lease retries once then takes durable fallback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_consumes_abandoned_append_only_claim() {
	setup_test_env
	export AIDEVOPS_CI_REPAIR_LOCK_GRACE_SECONDS="0"
	define_feedback_helpers || { print_result "defines feedback helpers for incomplete lease" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local lease_dir="${AIDEVOPS_CI_REPAIR_STATE_DIR}/incomplete"
	local action=""
	mkdir -p "${lease_dir}/attempt-1.claim"
	printf '{"pid":999999,"pid_start":"stale"}\n' >"${lease_dir}/attempt-1.claim/owner.json"
	action=$(_ci_repair_claim_lease "$lease_dir" "owner/repo" "100" "$TEST_PR_HEAD_SHA" \
		"fingerprint" "2" "feature/repair" "ci-repair-test")

	if [[ "$action" != "launch|2|" ]]; then
		print_result "abandoned CI repair attempt advances safely" 1 "action=${action}"
	elif ! jq -e '.status == "preparing" and .attempt == 2 and .session == "ci-repair-test"' "${lease_dir}/state.json" >/dev/null; then
		print_result "reclaimed CI repair state is complete JSON" 1 "State: $(cat "${lease_dir}/state.json")"
	else
		print_result "abandoned append-only claim is consumed without lock replacement" 0
	fi
	teardown_test_env
	return 0
}

test_ci_repair_waits_for_prelock_startup_before_retry() {
	setup_test_env
	export AIDEVOPS_CI_REPAIR_LOCK_GRACE_SECONDS="0"
	export AIDEVOPS_CI_REPAIR_LAUNCH_GRACE_SECONDS="240"
	define_feedback_helpers || { print_result "defines feedback helpers for startup grace" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	local lease_dir="${AIDEVOPS_CI_REPAIR_STATE_DIR}/startup-grace"
	local state_file="${lease_dir}/state.json"
	local action="" expired_action=""
	mkdir -p "${lease_dir}/attempt-1.claim"
	printf '{"pid":999999,"pid_start":"stale"}\n' >"${lease_dir}/attempt-1.claim/owner.json"
	_ci_repair_write_state "$state_file" "owner/repo" "100" "$TEST_PR_HEAD_SHA" "feature/repair" \
		"fingerprint" "${TEST_ROOT}/worktrees/preserved" "999999" "stale" "1" "preparing" "ci-repair-test"
	action=$(_ci_repair_claim_lease "$lease_dir" "owner/repo" "100" "$TEST_PR_HEAD_SHA" \
		"fingerprint" "2" "feature/repair" "ci-repair-test")
	jq '.updated_at = 0' "$state_file" >"${state_file}.tmp"
	mv "${state_file}.tmp" "$state_file"
	expired_action=$(_ci_repair_claim_lease "$lease_dir" "owner/repo" "100" "$TEST_PR_HEAD_SHA" \
		"fingerprint" "2" "feature/repair" "ci-repair-test")

	if [[ "$action" != "active" ]]; then
		print_result "pre-lock startup grace suppresses duplicate launch" 1 "action=${action}"
	elif [[ "$expired_action" != "launch|2|${TEST_ROOT}/worktrees/preserved" ]]; then
		print_result "expired startup grace permits bounded retry" 1 "expired_action=${expired_action}"
	else
		print_result "pre-lock startup grace blocks overlap then permits bounded retry" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_advisory_failure_when_required_clean() {
	setup_test_env
	TEST_CHECK_SCENARIO="advisory_failure"
	define_feedback_helpers || { print_result "defines feedback helpers for advisory failure" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	if grep -qF 'PR #100: CI repair' "$GH_LOG"; then
		print_result "advisory-only failure does not dispatch CI repair" 1 "Dispatch log: $(cat "$GH_LOG")"
	else
		print_result "advisory-only failure does not dispatch CI repair" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_includes_required_and_advisory_failures_together() {
	setup_test_env
	TEST_CHECK_SCENARIO="required_and_advisory"
	define_feedback_helpers || { print_result "defines feedback helpers for combined failures" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if ! grep -qF '**Lint**: failure' "${TEST_ROOT}/issue-body.txt"; then
		print_result "combined CI feedback retains required failure" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	elif ! grep -qF '**Qlty**: failure' "${TEST_ROOT}/issue-body.txt"; then
		print_result "combined CI feedback includes advisory failure" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "combined CI feedback includes every terminal failure in one pass" 0
	fi
	teardown_test_env
	return 0
}

main() {
	test_red_pr_passes_gates_before_repair_route
	test_rebase_success_defers_ci_repair_route
	test_converged_changes_requested_runs_strict_rebase_only
	test_converged_changes_requested_never_falls_through_to_merge
	test_repair_only_gate_stops_before_review_bot_boundary
	test_preflight_terminal_blocker_routes_supplied_evidence
	test_changes_requested_unknown_routes_before_mergeable_skip
	test_rest_missing_review_decision_refreshes_before_ci_route
	test_coderabbit_nits_ok_dismissed_once_before_late_gate
	test_changes_requested_empty_labels_refresh_current_metadata
	test_ci_repair_dedupes_identical_evidence_for_same_head
	test_ci_repair_dedupes_changed_evidence_for_same_head
	test_ci_repair_respects_live_legacy_lease
	test_ci_repair_session_keys_are_repository_scoped
	test_ci_repair_worktree_paths_are_repository_scoped
	test_ci_feedback_skips_pending_only_checks
	test_ci_feedback_skips_mixed_pending_pass_checks
	test_ci_feedback_emits_terminal_failure_with_conclusion_and_url
	test_ci_feedback_uses_supplied_non_required_blocker_evidence
	test_ci_feedback_defers_when_head_changes_during_collection
	test_ci_feedback_defers_without_initial_head_snapshot
	test_ci_feedback_skips_infra_timeout_checks
	test_ci_feedback_skips_failed_check_with_exit_143_log
	test_ci_feedback_skips_registry_rate_limit_failure
	test_ci_feedback_skips_dockerhub_pull_rate_limit_failure
	test_ci_feedback_skips_github_api_rate_limit_failure
	test_ci_repair_preserves_pr_until_launch_retries_exhausted
	test_ci_repair_recovers_one_stale_lease_then_exhausts
	test_ci_repair_consumes_abandoned_append_only_claim
	test_ci_repair_waits_for_prelock_startup_before_retry
	test_ci_feedback_skips_advisory_failure_when_required_clean

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
