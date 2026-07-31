#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-status-label-state-machine.sh — t2033 regression guard.
#
# Asserts the `set_issue_status` helper in shared-constants.sh:
#
#   1. Emits exactly one --add-label flag for the target status
#   2. Emits --remove-label flags for every sibling core status label
#   3. Passes extra arguments through verbatim (e.g., --add-assignee)
#   4. Handles the empty-status "clear only" case (7 removes, 0 adds)
#   5. Rejects invalid status strings with exit code 2
#   6. Rejects empty issue number or repo slug with exit code 2
#
# Failure history motivating this test: GH#18444, GH#18454, GH#18455 all
# accumulated both status:available and status:queued simultaneously because
# _dispatch_launch_worker at pulse-dispatch-core.sh:1062 added status:queued
# without removing status:available. The helper centralises the state-machine
# transition so no future call site can repeat the bug.
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so sourcing shared-constants.sh is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
# Exported so the gh stub subprocess can reach it at runtime — the heredoc
# below is quoted ('STUBEOF') to avoid substitution at stub-write time.
export GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"
export STATUS_LABEL_STATE_FILE="${TEST_ROOT}/status-labels-converged"
export ISSUE_STATE_FILE="${TEST_ROOT}/issue-state.json"
export ISSUE_CONCURRENT_MARKER="${TEST_ROOT}/issue-concurrent-injected"

#######################################
# Write a gh stub that records every invocation's argv to GH_CALLS_FILE,
# one call per line. Used to verify set_issue_status constructs the correct
# --add-label / --remove-label / --add-assignee flag set.
#
# The stub always exits 0 so the helper's "$?" reflects argument validation
# and label-set construction logic, not simulated gh failures.
#######################################
append_stub_gh_mutations() {
	cat >>"${STUB_DIR}/gh" <<'STUBEOF'
if [[ "${1:-}" == "api" && "${2:-}" == "-X" ]]; then
	[[ "${STUB_REST_MUTATION_FAIL:-0}" == "1" ]] && exit 1
	[[ -n "${STUB_REST_MUTATION_FAIL_METHOD:-}" && "${3:-}" == "${STUB_REST_MUTATION_FAIL_METHOD}" ]] && exit 1
	[[ -n "${STUB_REST_MUTATION_FAIL_LABEL:-}" && "${3:-}" == "DELETE" && "${4:-}" == */labels/"${STUB_REST_MUTATION_FAIL_LABEL}" ]] && exit 1
	if [[ "${STUB_STATEFUL_ISSUE:-0}" == "1" && "${3:-}" == "POST" && "${4:-}" == */labels ]]; then
		for arg in "$@"; do
			case "$arg" in
			labels\[\]=*)
				label="${arg#labels[]=}"
				jq --arg label "$label" \
					'if any(.labels[]; .name == $label) then . else .labels += [{"name": $label}] end' \
					"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
				;;
			esac
		done
	elif [[ "${STUB_STATEFUL_ISSUE:-0}" == "1" && "${3:-}" == "DELETE" && "${4:-}" == */labels/* ]]; then
		encoded_label="${4##*/}"
		label="${encoded_label//%3A/:}"
		if [[ "$encoded_label" == "${STUB_CONCURRENT_REMOVE_TRIGGER:-}" && -n "${STUB_CONCURRENT_REMOVE_BEFORE_DELETE:-}" ]]; then
			jq --arg label "${STUB_CONCURRENT_REMOVE_BEFORE_DELETE}" '.labels |= map(select(.name != $label))' \
				"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
			mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
		fi
		jq --arg label "$label" '.labels |= map(select(.name != $label))' \
			"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
		mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
	elif [[ "${STUB_STATEFUL_ISSUE:-0}" == "1" && ( "${3:-}" == "POST" || "${3:-}" == "DELETE" ) && "${4:-}" == */assignees ]]; then
		for arg in "$@"; do
			case "$arg" in
			assignees\[\]=*)
				login="${arg#assignees[]=}"
				if [[ "${3:-}" == "POST" ]]; then
					jq --arg login "$login" \
						'if any(.assignees[]; .login == $login) then . else .assignees += [{"login": $login}] end' \
						"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				else
					jq --arg login "$login" '.assignees |= map(select(.login != $login))' \
						"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				fi
				mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
				;;
			esac
		done
	fi
	exit 0
fi
STUBEOF
	return 0
}

write_stub_gh() {
	: >"$GH_CALLS_FILE"
	cat >"${STUB_DIR}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub gh for test-status-label-state-machine.sh — records all calls.
printf '%s\n' "$*" >>"${GH_CALLS_FILE}"
if [[ "${1:-}" == "api" && "${2:-}" == /repos/*/labels\?per_page=100 ]]; then
	[[ "${STUB_LABEL_LIST_FAIL:-0}" == "1" ]] && exit 1
	printf '%s\t%s\t%s\n' \
		"status:available" "0e8a16" "Task is available for claiming" \
		"status:queued" "fbca04" "Worker dispatched, not yet started" \
		"status:claimed" "f9d0c4" "Interactive session claimed this task" \
		"status:in-progress" "1d76db" "Worker actively running" \
		"status:in-review" "5319e7" "PR open, awaiting review/merge" \
		"status:done" "6f42c1" "Task is complete"
	if [[ -f "${STATUS_LABEL_STATE_FILE}" || "${STUB_LABEL_MODE:-exact}" == "exact" ]]; then
		printf '%s\t%s\t%s\n' "status:blocked" "d93f0b" "Waiting on blocker task"
	elif [[ "${STUB_LABEL_MODE:-exact}" == "drifted" ]]; then
		printf '%s\t%s\t%s\n' "status:blocked" "ffffff" "Drifted definition"
	fi
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == /repos/*/issues/[0-9]* ]]; then
	[[ "${STUB_ISSUE_GET_FAIL:-0}" == "1" ]] && exit 1
	if [[ "${STUB_STATEFUL_ISSUE:-0}" == "1" && -f "${ISSUE_STATE_FILE}" ]]; then
		cat "${ISSUE_STATE_FILE}"
		if [[ ( -n "${STUB_CONCURRENT_LABEL_AFTER_GET:-}" || -n "${STUB_CONCURRENT_ASSIGNEE_AFTER_GET:-}" ) && ! -f "${ISSUE_CONCURRENT_MARKER}" ]]; then
			if [[ -n "${STUB_CONCURRENT_LABEL_AFTER_GET:-}" ]]; then
				jq --arg label "${STUB_CONCURRENT_LABEL_AFTER_GET}" \
					'if any(.labels[]; .name == $label) then . else .labels += [{"name": $label}] end' \
					"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
			fi
			if [[ -n "${STUB_CONCURRENT_ASSIGNEE_AFTER_GET:-}" ]]; then
				jq --arg login "${STUB_CONCURRENT_ASSIGNEE_AFTER_GET}" \
					'if any(.assignees[]; .login == $login) then . else .assignees += [{"login": $login}] end' \
					"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
			fi
			: >"${ISSUE_CONCURRENT_MARKER}"
		fi
	elif [[ -n "${STUB_ISSUE_JSON:-}" ]]; then
		printf '%s\n' "$STUB_ISSUE_JSON"
	elif issue_num="${2##*/}" && edit_call=$(grep "^issue edit ${issue_num} " "${GH_CALLS_FILE}" | tail -1) && [[ -n "$edit_call" ]]; then
		status=$(printf '%s\n' "$edit_call" | sed -n 's/.*--add-label status:\([^ ]*\).*/\1/p')
		if [[ -n "$status" ]]; then
			printf '{"labels":[{"name":"status:%s"}],"assignees":[]}\n' "$status"
		else
			printf '%s\n' '{"labels":[],"assignees":[]}'
		fi
	else
		exit 1
	fi
	exit 0
fi
STUBEOF
	append_stub_gh_mutations
	cat >>"${STUB_DIR}/gh" <<'STUBEOF'
if [[ "${1:-}" == "label" ]]; then
	if [[ "${2:-}" == "create" && "${STUB_LABEL_CREATE_CONFLICT:-0}" == "1" ]]; then
		: >"${STATUS_LABEL_STATE_FILE}"
		exit 1
	fi
	[[ "${STUB_LABEL_WRITE_FAIL:-0}" == "1" ]] && exit 1
	: >"${STATUS_LABEL_STATE_FILE}"
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
	[[ "${STUB_NATIVE_EDIT_FAIL:-0}" == "1" ]] && exit 1
	if [[ "${STUB_STATEFUL_ISSUE:-0}" == "1" ]]; then
		shift 2
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--add-label)
				label="${2:-}"
				jq --arg label "$label" \
					'if any(.labels[]; .name == $label) then . else .labels += [{"name": $label}] end' \
					"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
				shift 2
				;;
			--remove-label)
				label="${2:-}"
				jq --arg label "$label" '.labels |= map(select(.name != $label))' \
					"${ISSUE_STATE_FILE}" >"${ISSUE_STATE_FILE}.next" || exit 1
				mv "${ISSUE_STATE_FILE}.next" "${ISSUE_STATE_FILE}"
				shift 2
				;;
			*) shift ;;
			esac
		done
	fi
	exit 0
fi
exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

# Source the helper. Prepending STUB_DIR to PATH ensures the stub is picked up.
export PATH="${STUB_DIR}:${PATH}"
write_stub_gh

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"

# Reset per-test caches so each case starts clean
_reset_state() {
	_STATUS_LABELS_ENSURED=""
	: >"$GH_CALLS_FILE"
	rm -f "$STATUS_LABEL_STATE_FILE" "$ISSUE_STATE_FILE" "$ISSUE_STATE_FILE.next" "$ISSUE_CONCURRENT_MARKER"
	unset STUB_ISSUE_JSON STUB_ISSUE_GET_FAIL STUB_REST_MUTATION_FAIL STUB_REST_MUTATION_FAIL_METHOD
	unset STUB_REST_MUTATION_FAIL_LABEL
	unset STUB_NATIVE_EDIT_FAIL
	unset STUB_STATEFUL_ISSUE STUB_CONCURRENT_LABEL_AFTER_GET STUB_CONCURRENT_ASSIGNEE_AFTER_GET
	unset STUB_CONCURRENT_REMOVE_TRIGGER STUB_CONCURRENT_REMOVE_BEFORE_DELETE
	unset STUB_LABEL_LIST_FAIL STUB_LABEL_MODE STUB_LABEL_CREATE_CONFLICT STUB_LABEL_WRITE_FAIL
	return 0
}

#######################################
# assert_edit_call_has_flags: verify the LAST `gh issue edit` call in
# GH_CALLS_FILE contains every required flag token (space-separated match).
#
# Args:
#   $1 — descriptive test name
#   $@ — required substrings (each must appear in the edit-call line)
#######################################
assert_last_edit_has() {
	local name="$1"
	shift
	local last_edit
	last_edit=$(grep 'issue edit' "$GH_CALLS_FILE" | tail -1 || true)
	if [[ -z "$last_edit" ]]; then
		print_result "$name" 1 "(no 'issue edit' call recorded)"
		return 0
	fi
	local missing=()
	local needle
	for needle in "$@"; do
		if ! printf '%s' "$last_edit" | grep -qF -- "$needle"; then
			missing+=("$needle")
		fi
	done
	if [[ ${#missing[@]} -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "(missing: ${missing[*]} | got: ${last_edit})"
	fi
}

#######################################
# assert_last_edit_lacks: verify the LAST `gh issue edit` call does NOT
# contain any of the forbidden substrings.
#######################################
assert_last_edit_lacks() {
	local name="$1"
	shift
	local last_edit
	last_edit=$(grep 'issue edit' "$GH_CALLS_FILE" | tail -1 || true)
	if [[ -z "$last_edit" ]]; then
		print_result "$name" 1 "(no 'issue edit' call recorded)"
		return 0
	fi
	local present=()
	local needle
	for needle in "$@"; do
		if printf '%s' "$last_edit" | grep -qF -- "$needle"; then
			present+=("$needle")
		fi
	done
	if [[ ${#present[@]} -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "(forbidden present: ${present[*]} | got: ${last_edit})"
	fi
}

#######################################
# Verify at least one native edit phase contains every required substring.
#######################################
assert_any_edit_has() {
	local name="$1"
	shift
	local edit_calls=""
	edit_calls=$(grep 'issue edit' "$GH_CALLS_FILE" || true)
	local needle=""
	local missing=()
	for needle in "$@"; do
		if ! printf '%s' "$edit_calls" | grep -qF -- "$needle"; then
			missing+=("$needle")
		fi
	done
	if [[ ${#missing[@]} -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "(missing: ${missing[*]} | got: ${edit_calls})"
	fi
	return 0
}

#######################################
# TEST 1: Transition to status:queued produces 1 add + 6 removes
#######################################
test_queued_transition() {
	_reset_state
	set_issue_status 1 "owner/repo" "queued" || {
		print_result "queued transition returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "queued transition returns 0" 0
	assert_last_edit_has "queued: adds status:queued" \
		"--add-label status:queued"
	assert_last_edit_has "queued: removes 6 siblings" \
		"--remove-label status:available" \
		"--remove-label status:claimed" \
		"--remove-label status:in-progress" \
		"--remove-label status:in-review" \
		"--remove-label status:done" \
		"--remove-label status:blocked"
	assert_last_edit_lacks "queued: does NOT remove the target" \
		"--remove-label status:queued"
}

#######################################
# TEST 2: Transition to status:available with --remove-assignee passthrough
#######################################
test_available_with_extra_flags() {
	_reset_state
	set_issue_status 42 "owner/repo" "available" \
		--remove-assignee "stale-worker" || {
		print_result "available+extra returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "available+extra returns 0" 0
	assert_last_edit_has "available+extra: adds status:available" \
		"--add-label status:available"
	assert_any_edit_has "available+extra: passes through --remove-assignee" \
		"--remove-assignee stale-worker"
	assert_last_edit_has "available+extra: removes sibling status:queued" \
		"--remove-label status:queued"
}

#######################################
# TEST 3: Empty status (clear only) with --add-label passthrough
# Used by stale-recovery escalation: clear core statuses, add needs-maintainer-review
#######################################
test_empty_status_clear_only() {
	_reset_state
	set_issue_status 99 "owner/repo" "" \
		--add-label "needs-maintainer-review" || {
		print_result "empty status returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "empty status returns 0" 0
	assert_any_edit_has "clear-only: passes through --add-label" \
		"--add-label needs-maintainer-review"
	assert_last_edit_has "clear-only: removes status:available" \
		"--remove-label status:available"
	assert_last_edit_has "clear-only: removes status:blocked" \
		"--remove-label status:blocked"
	assert_last_edit_lacks "clear-only: does NOT add any core status:*" \
		"--add-label status:available" \
		"--add-label status:queued" \
		"--add-label status:claimed" \
		"--add-label status:in-progress" \
		"--add-label status:in-review" \
		"--add-label status:done" \
		"--add-label status:blocked"
}

#######################################
# TEST 4: Transition to in-progress removes status:claimed (t1996 normalization)
#######################################
test_in_progress_removes_claimed() {
	_reset_state
	set_issue_status 7 "owner/repo" "in-progress" || {
		print_result "in-progress transition returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "in-progress transition returns 0" 0
	assert_last_edit_has "in-progress: adds status:in-progress" \
		"--add-label status:in-progress"
	assert_last_edit_has "in-progress: removes status:claimed" \
		"--remove-label status:claimed"
}

#######################################
# TEST 5: Invalid status string returns exit 2, no gh call
#######################################
test_invalid_status_rejected() {
	_reset_state
	set_issue_status 1 "owner/repo" "nonsense" 2>/dev/null
	local rc=$?
	if [[ "$rc" -eq 2 ]]; then
		print_result "invalid status returns exit 2" 0
	else
		print_result "invalid status returns exit 2" 1 "(got rc=${rc})"
	fi
	# No gh issue edit should have been recorded
	if ! grep -q 'issue edit' "$GH_CALLS_FILE" 2>/dev/null; then
		print_result "invalid status: no gh issue edit call" 0
	else
		print_result "invalid status: no gh issue edit call" 1 \
			"(unexpected: $(cat "$GH_CALLS_FILE"))"
	fi
}

#######################################
# TEST 6: Missing issue_num or repo_slug returns exit 2
#######################################
test_missing_args_rejected() {
	_reset_state
	set_issue_status "" "owner/repo" "queued" 2>/dev/null
	local rc1=$?
	if [[ "$rc1" -eq 2 ]]; then
		print_result "empty issue_num returns exit 2" 0
	else
		print_result "empty issue_num returns exit 2" 1 "(got rc=${rc1})"
	fi

	_reset_state
	set_issue_status 1 "" "queued" 2>/dev/null
	local rc2=$?
	if [[ "$rc2" -eq 2 ]]; then
		print_result "empty repo_slug returns exit 2" 0
	else
		print_result "empty repo_slug returns exit 2" 1 "(got rc=${rc2})"
	fi
}

#######################################
# TEST 7: ISSUE_STATUS_LABELS array has exactly the expected 7 elements
#######################################
test_canonical_label_list() {
	local expected=("available" "queued" "claimed" "in-progress" "in-review" "done" "blocked")
	if [[ "${#ISSUE_STATUS_LABELS[@]}" -ne "${#expected[@]}" ]]; then
		print_result "ISSUE_STATUS_LABELS has 7 elements" 1 \
			"(got ${#ISSUE_STATUS_LABELS[@]}: ${ISSUE_STATUS_LABELS[*]})"
		return 0
	fi
	local i
	for i in "${!expected[@]}"; do
		if [[ "${ISSUE_STATUS_LABELS[i]}" != "${expected[i]}" ]]; then
			print_result "ISSUE_STATUS_LABELS matches expected order" 1 \
				"(pos ${i}: expected ${expected[i]}, got ${ISSUE_STATUS_LABELS[i]})"
			return 0
		fi
	done
	print_result "ISSUE_STATUS_LABELS matches expected order" 0
}

#######################################
# TEST 8: Dispatch-realistic pattern — queued + add-assignee + add-label +
# remove-assignee (the exact shape _dispatch_launch_worker uses). This is
# the bug site from t2033: #18444 accumulated status:available + status:queued
# because the old code didn't remove siblings.
#######################################
test_dispatch_realistic_pattern() {
	_reset_state
	# Simulate the real call from pulse-dispatch-core.sh after t2033 migration
	set_issue_status 18444 "marcusquinn/aidevops" "queued" \
		--add-assignee "runner-a" \
		--add-label "origin:worker" \
		--remove-assignee "runner-b" || {
		print_result "dispatch pattern returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "dispatch pattern returns 0" 0
	assert_last_edit_has "dispatch: adds status:queued" \
		"--add-label status:queued"
	assert_last_edit_has "dispatch: removes status:available (the t2033 bug fix)" \
		"--remove-label status:available"
	assert_any_edit_has "dispatch: passes through --add-assignee" \
		"--add-assignee runner-a"
	assert_any_edit_has "dispatch: passes through --add-label origin:worker" \
		"--add-label origin:worker"
	assert_any_edit_has "dispatch: passes through --remove-assignee" \
		"--remove-assignee runner-b"
	return 0
}

#######################################
# TEST 9: A normal transition uses targeted REST delta endpoints, preserving
# unrelated labels instead of submitting a stale full-array replacement.
#######################################
test_rest_first_transition() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:available"}],"assignees":[{"login":"stale-worker"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	set_issue_status 314 "owner/repo" "queued" --remove-assignee "stale-worker"
	local rc=$?
	if [[ "$rc" -eq 0 ]] &&
		grep -q '^api -X POST /repos/owner/repo/issues/314/labels -f labels\[\]=status:queued$' "$GH_CALLS_FILE" &&
		grep -q '^api -X DELETE /repos/owner/repo/issues/314/labels/status%3Aavailable$' "$GH_CALLS_FILE" &&
		grep -q '^api -X DELETE /repos/owner/repo/issues/314/assignees -f assignees\[\]=stale-worker$' "$GH_CALLS_FILE" &&
		! grep -qE '^(api -X PATCH /repos/owner/repo/issues/314|issue edit 314)' "$GH_CALLS_FILE"; then
		print_result "REST-first transition uses targeted delta endpoints" 0
	else
		print_result "REST-first transition uses targeted delta endpoints" 1 \
			"(rc=${rc}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	if ! grep -q 'labels\[\]=bug' "$GH_CALLS_FILE"; then
		print_result "REST-first transition never replaces unrelated labels" 0
	else
		print_result "REST-first transition never replaces unrelated labels" 1 \
			"(calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 10: An unrelated label added after the snapshot survives the transition.
#######################################
test_concurrent_unrelated_label_is_preserved() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_CONCURRENT_LABEL_AFTER_GET="external-update"
	set_issue_status 315 "owner/repo" "queued"
	local rc=$?
	local final_labels=""
	final_labels=$(jq -r '.labels[].name' "$ISSUE_STATE_FILE" | sort)
	if [[ "$rc" -eq 0 && "$final_labels" == $'bug\nexternal-update\nstatus:queued' ]]; then
		print_result "concurrent unrelated label survives REST status transition" 0
	else
		print_result "concurrent unrelated label survives REST status transition" 1 \
			"(rc=${rc}; labels=${final_labels}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 11: An unrelated assignee added after the snapshot also survives.
#######################################
test_concurrent_unrelated_assignee_is_preserved() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:queued"}],"assignees":[{"login":"old-worker"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_CONCURRENT_ASSIGNEE_AFTER_GET="observer"
	set_issue_status 316 "owner/repo" "queued" \
		--add-assignee "new-worker" --remove-assignee "old-worker"
	local rc=$?
	local final_assignees=""
	final_assignees=$(jq -r '.assignees[].login' "$ISSUE_STATE_FILE" | sort)
	if [[ "$rc" -eq 0 && "$final_assignees" == $'new-worker\nobserver' ]]; then
		print_result "concurrent unrelated assignee survives REST status transition" 0
	else
		print_result "concurrent unrelated assignee survives REST status transition" 1 \
			"(rc=${rc}; assignees=${final_assignees}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 10: A converged status-label contract is one read and zero writes.
#######################################
test_converged_label_contract_is_read_only() {
	_reset_state
	ensure_status_labels_exist "owner/repo"
	local rc=$?
	local reads=0
	local writes=0
	reads=$(grep -c '^api /repos/owner/repo/labels?per_page=100 ' "$GH_CALLS_FILE" 2>/dev/null || true)
	writes=$(grep -Ec '^label (create|edit) ' "$GH_CALLS_FILE" 2>/dev/null || true)
	if [[ "$rc" -eq 0 && "$reads" -eq 1 && "$writes" -eq 0 ]]; then
		print_result "converged label contract uses one read and zero writes" 0
	else
		print_result "converged label contract uses one read and zero writes" 1 \
			"(rc=${rc}; reads=${reads}; writes=${writes}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 11: Missing and drifted definitions use create/edit respectively, then
# re-read the full contract before populating the process cache.
#######################################
test_label_contract_reconciliation() {
	_reset_state
	export STUB_LABEL_MODE="missing"
	ensure_status_labels_exist "owner/repo"
	local missing_rc=$?
	if [[ "$missing_rc" -eq 0 ]] &&
		grep -q '^label create status:blocked ' "$GH_CALLS_FILE" &&
		! grep -q -- '--force' "$GH_CALLS_FILE"; then
		print_result "missing status label is created without --force" 0
	else
		print_result "missing status label is created without --force" 1 \
			"(rc=${missing_rc}; calls=$(cat "$GH_CALLS_FILE"))"
	fi

	_reset_state
	export STUB_LABEL_MODE="drifted"
	ensure_status_labels_exist "owner/repo"
	local drifted_rc=$?
	if [[ "$drifted_rc" -eq 0 ]] &&
		grep -q '^label edit status:blocked ' "$GH_CALLS_FILE" &&
		! grep -q '^label create status:blocked ' "$GH_CALLS_FILE"; then
		print_result "drifted status label is edited without create churn" 0
	else
		print_result "drifted status label is edited without create churn" 1 \
			"(rc=${drifted_rc}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 12: A concurrent create conflict is re-read and accepted only after the
# resulting repository definition exactly matches the contract.
#######################################
test_label_create_conflict_is_verified() {
	_reset_state
	export STUB_LABEL_MODE="missing"
	export STUB_LABEL_CREATE_CONFLICT=1
	ensure_status_labels_exist "owner/repo"
	local rc=$?
	local reads=0
	reads=$(grep -c '^api /repos/owner/repo/labels?per_page=100 ' "$GH_CALLS_FILE" 2>/dev/null || true)
	if [[ "$rc" -eq 0 && "$reads" -ge 3 ]] &&
		grep -q '^label create status:blocked ' "$GH_CALLS_FILE"; then
		print_result "concurrent label create conflict is re-read and verified" 0
	else
		print_result "concurrent label create conflict is re-read and verified" 1 \
			"(rc=${rc}; reads=${reads}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 13: Unknown label state blocks every issue mutation.
#######################################
test_label_contract_read_failure_is_fail_closed() {
	_reset_state
	export STUB_LABEL_LIST_FAIL=1
	set_issue_status 2718 "owner/repo" "queued" >/dev/null 2>&1
	local rc=$?
	if [[ "$rc" -ne 0 ]] &&
		! grep -qE '^(api -X (PATCH|POST|DELETE)|issue edit|label (create|edit))' "$GH_CALLS_FILE"; then
		print_result "failed label-contract read performs no mutation" 0
	else
		print_result "failed label-contract read performs no mutation" 1 \
			"(rc=${rc}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 15: Extras that fail in both routes leave status labels untouched.
#######################################
test_failed_extra_does_not_start_status_transition() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL=1
	export STUB_NATIVE_EDIT_FAIL=1
	set_issue_status 1618 "owner/repo" "in-review" --add-assignee "invalid-worker" >/dev/null 2>&1
	local rc=$?
	local final_statuses=""
	final_statuses=$(jq -r '.labels[].name | select(startswith("status:"))' "$ISSUE_STATE_FILE")
	if [[ "$rc" -ne 0 && "$final_statuses" == "status:available" ]] &&
		! grep -qE 'labels\[\]=status:in-review|/labels/status%3Aavailable|--add-label status:in-review' "$GH_CALLS_FILE"; then
		print_result "failed passthrough extra leaves existing status untouched" 0
	else
		print_result "failed passthrough extra leaves existing status untouched" 1 \
			"(rc=${rc}; statuses=${final_statuses}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 16: A failed REST status phase falls back with status-only flags and
# converges without replaying unrelated extras.
#######################################
test_rest_status_failure_uses_status_only_native_fallback() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL=1
	set_issue_status 1619 "owner/repo" "in-review" >/dev/null 2>&1
	local rc=$?
	local final_labels=""
	final_labels=$(jq -r '.labels[].name' "$ISSUE_STATE_FILE" | sort)
	local native_call=""
	native_call=$(grep '^issue edit 1619 ' "$GH_CALLS_FILE" | tail -1 || true)
	if [[ "$rc" -eq 0 && "$final_labels" == $'bug\nstatus:in-review' &&
		"$native_call" == *"--add-label status:in-review"* && "$native_call" != *"assignee"* ]]; then
		print_result "failed REST status phase uses status-only native fallback" 0
	else
		print_result "failed REST status phase uses status-only native fallback" 1 \
			"(rc=${rc}; labels=${final_labels}; native=${native_call}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 17: If the target-label add and native fallback both fail, the REST
# phase has already removed the old status and therefore cannot strand a dual
# status-label state.
#######################################
test_failed_target_add_never_strands_dual_statuses() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL_METHOD=POST
	export STUB_NATIVE_EDIT_FAIL=1
	set_issue_status 1620 "owner/repo" "queued" >/dev/null 2>&1
	local rc=$?
	local final_statuses=""
	final_statuses=$(jq -r '.labels[].name | select(startswith("status:"))' "$ISSUE_STATE_FILE")
	local remove_line=""
	local add_line=""
	remove_line=$(grep -n '^api -X DELETE /repos/owner/repo/issues/1620/labels/status%3Aavailable$' \
		"$GH_CALLS_FILE" | cut -d: -f1 || true)
	add_line=$(grep -n '^api -X POST /repos/owner/repo/issues/1620/labels -f labels\[\]=status:queued$' \
		"$GH_CALLS_FILE" | cut -d: -f1 || true)
	if [[ "$rc" -ne 0 && -z "$final_statuses" && -n "$remove_line" && -n "$add_line" && "$remove_line" -lt "$add_line" ]]; then
		print_result "failed target add cannot strand dual statuses" 0
	else
		print_result "failed target add cannot strand dual statuses" 1 \
			"(rc=${rc}; statuses=${final_statuses}; remove=${remove_line}; add=${add_line}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 18: Passthrough assignee replacements add first. A rejected replacement
# and failed native fallback therefore leave the existing assignee intact and
# never begin the status phase.
#######################################
test_failed_extra_add_preserves_existing_assignee() {
	_reset_state
	local existing_assignee="old-worker"
	jq -n --arg login "$existing_assignee" \
		'{labels:[{name:"status:available"}],assignees:[{login:$login}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL_METHOD=POST
	export STUB_NATIVE_EDIT_FAIL=1
	set_issue_status 1621 "owner/repo" "in-review" \
		--add-assignee "invalid-worker" --remove-assignee "$existing_assignee" >/dev/null 2>&1
	local rc=$?
	local final_assignees=""
	local final_statuses=""
	final_assignees=$(jq -r '.assignees[].login' "$ISSUE_STATE_FILE")
	final_statuses=$(jq -r '.labels[].name | select(startswith("status:"))' "$ISSUE_STATE_FILE")
	if [[ "$rc" -ne 0 && "$final_assignees" == "$existing_assignee" && "$final_statuses" == "status:available" ]] &&
		! grep -q '^api -X DELETE /repos/owner/repo/issues/1621/assignees ' "$GH_CALLS_FILE"; then
		print_result "failed extra add preserves existing assignee" 0
	else
		print_result "failed extra add preserves existing assignee" 1 \
			"(rc=${rc}; assignees=${final_assignees}; statuses=${final_statuses}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 19: The same add-first protection applies to passthrough label
# replacements, including labels unrelated to the managed status state.
#######################################
test_failed_extra_add_preserves_existing_label() {
	_reset_state
	local existing_label="origin:legacy"
	jq -n --arg label "$existing_label" \
		'{labels:[{name:"status:available"},{name:$label}],assignees:[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL_METHOD=POST
	export STUB_NATIVE_EDIT_FAIL=1
	set_issue_status 1622 "owner/repo" "in-review" \
		--add-label "missing-label" --remove-label "$existing_label" >/dev/null 2>&1
	local rc=$?
	local final_statuses=""
	final_statuses=$(jq -r '.labels[].name | select(startswith("status:"))' "$ISSUE_STATE_FILE")
	if [[ "$rc" -ne 0 && "$final_statuses" == "status:available" ]] &&
		jq -e --arg label "$existing_label" 'any(.labels[]; .name == $label)' "$ISSUE_STATE_FILE" >/dev/null &&
		! grep -q '^api -X DELETE /repos/owner/repo/issues/1622/labels/' "$GH_CALLS_FILE"; then
		print_result "failed extra add preserves existing label" 0
	else
		print_result "failed extra add preserves existing label" 1 \
			"(rc=${rc}; statuses=${final_statuses}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 20: Owned worker transitions add the accepted target before removing the
# queued recovery signal, then converge to one status.
#######################################
test_owned_transition_adds_target_before_source_removal() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	transition_owned_issue_status 1623 "owner/repo" "runner-a" "queued" "in-progress"
	local rc=$?
	local final_statuses=""
	local add_line=""
	local remove_line=""
	final_statuses=$(jq -r '.labels[].name | select(startswith("status:"))' "$ISSUE_STATE_FILE")
	add_line=$(grep -n '^api -X POST /repos/owner/repo/issues/1623/labels -f labels\[\]=status:in-progress$' \
		"$GH_CALLS_FILE" | cut -d: -f1 || true)
	remove_line=$(grep -n '^api -X DELETE /repos/owner/repo/issues/1623/labels/status%3Aqueued$' \
		"$GH_CALLS_FILE" | cut -d: -f1 || true)
	if [[ "$rc" -eq 0 && "$final_statuses" == "status:in-progress" && -n "$add_line" && -n "$remove_line" && "$add_line" -lt "$remove_line" ]]; then
		print_result "owned transition adds target before removing source" 0
	else
		print_result "owned transition adds target before removing source" 1 \
			"(rc=${rc}; statuses=${final_statuses}; add=${add_line}; remove=${remove_line}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 21: A rejected target add leaves the queued recovery signal intact and
# never falls back to an ordering-unknown native mutation.
#######################################
test_owned_transition_failed_add_preserves_source() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL_METHOD=POST
	transition_owned_issue_status 1624 "owner/repo" "runner-a" "queued" "in-progress" >/dev/null 2>&1
	local rc=$?
	local final_statuses=""
	final_statuses=$(jq -r '.labels[].name | select(startswith("status:"))' "$ISSUE_STATE_FILE")
	if [[ "$rc" -ne 0 && "$final_statuses" == "status:queued" ]] &&
		! grep -q '^issue edit 1624 ' "$GH_CALLS_FILE"; then
		print_result "failed owned target add preserves queued source" 0
	else
		print_result "failed owned target add preserves queued source" 1 \
			"(rc=${rc}; statuses=${final_statuses}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 22: A failed source removal leaves an accepted overlap rather than a
# zero-status ownership gap.
#######################################
test_owned_transition_failed_remove_preserves_overlap() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_REST_MUTATION_FAIL_METHOD=DELETE
	transition_owned_issue_status 1625 "owner/repo" "runner-a" "queued" "in-progress" >/dev/null 2>&1
	local rc=$?
	local accepted_count=0
	accepted_count=$(jq '[.labels[].name | select(. == "status:queued" or . == "status:in-progress")] | length' "$ISSUE_STATE_FILE")
	if [[ "$rc" -ne 0 && "$accepted_count" -eq 2 ]] &&
		! grep -q '^issue edit 1625 ' "$GH_CALLS_FILE"; then
		print_result "failed owned source removal preserves accepted overlap" 0
	else
		print_result "failed owned source removal preserves accepted overlap" 1 \
			"(rc=${rc}; accepted=${accepted_count}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 23: The transition snapshot must still contain both the expected source
# status and expected owner before any mutation starts.
#######################################
test_owned_transition_preconditions_fail_closed() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:in-review"}],"assignees":[{"login":"runner-a"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	transition_owned_issue_status 1626 "owner/repo" "runner-a" "queued" "in-progress" >/dev/null 2>&1
	local source_rc=$?
	local source_writes=0
	source_writes=$(grep -Ec '^api -X (POST|DELETE) /repos/owner/repo/issues/1626/' "$GH_CALLS_FILE" || true)

	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-b"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	transition_owned_issue_status 1627 "owner/repo" "runner-a" "queued" "in-progress" >/dev/null 2>&1
	local owner_rc=$?
	local owner_writes=0
	owner_writes=$(grep -Ec '^api -X (POST|DELETE) /repos/owner/repo/issues/1627/' "$GH_CALLS_FILE" || true)

	if [[ "$source_rc" -ne 0 && "$owner_rc" -ne 0 && "$source_writes" -eq 0 && "$owner_writes" -eq 0 ]]; then
		print_result "owned transition preconditions fail closed" 0
	else
		print_result "owned transition preconditions fail closed" 1 \
			"(source_rc=${source_rc}; owner_rc=${owner_rc}; source_writes=${source_writes}; owner_writes=${owner_writes}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 24: A competing writer adds a different target after the first writer's
# snapshot. Post-write verification chooses the canonical precedence winner,
# removes only the loser, and preserves unrelated metadata.
#######################################
test_competing_status_writers_converge_by_precedence() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:needs-info"},{"name":"status:available"}],"assignees":[{"login":"observer"}]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_CONCURRENT_LABEL_AFTER_GET="status:done"
	set_issue_status 1628 "owner/repo" "queued" >/dev/null 2>&1
	local rc=$?
	local final_labels=""
	local reads=0
	local writes=0
	final_labels=$(jq -r '.labels[].name' "$ISSUE_STATE_FILE" | sort)
	reads=$(grep -c '^api /repos/owner/repo/issues/1628$' "$GH_CALLS_FILE" || true)
	writes=$(grep -Ec '^api -X (POST|DELETE) /repos/owner/repo/issues/1628/' "$GH_CALLS_FILE" || true)
	if [[ "$rc" -eq 0 && "$final_labels" == $'bug\nstatus:done\nstatus:needs-info' && "$reads" -eq 4 && "$writes" -eq 3 ]] &&
		jq -e '.assignees == [{"login":"observer"}]' "$ISSUE_STATE_FILE" >/dev/null; then
		print_result "competing writers converge (4 reads, 3 writes) and preserve exception labels" 0
	else
		print_result "competing writers converge (4 reads, 3 writes) and preserve exception labels" 1 \
			"(rc=${rc}; labels=${final_labels}; reads=${reads}; writes=${writes}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 25: A failed loser removal is visible and bounded: one repair attempt is
# made, no native full-array fallback runs, and unrelated metadata survives.
#######################################
test_competing_status_repair_failure_is_bounded() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"bug"},{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_CONCURRENT_LABEL_AFTER_GET="status:done"
	export STUB_REST_MUTATION_FAIL_LABEL="status%3Aqueued"
	set_issue_status 1629 "owner/repo" "queued" >/dev/null 2>&1
	local rc=$?
	local repair_attempts=0
	repair_attempts=$(grep -c '^api -X DELETE /repos/owner/repo/issues/1629/labels/status%3Aqueued$' "$GH_CALLS_FILE" || true)
	if [[ "$rc" -ne 0 && "$repair_attempts" -eq 1 ]] &&
		! grep -q '^issue edit 1629 ' "$GH_CALLS_FILE" &&
		jq -e 'any(.labels[]; .name == "bug")' "$ISSUE_STATE_FILE" >/dev/null; then
		print_result "failed competing-writer repair is bounded and visible" 0
	else
		print_result "failed competing-writer repair is bounded and visible" 1 \
			"(rc=${rc}; repairs=${repair_attempts}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 26: The canonical blocked/available safety exception keeps blocked even
# though ordinary lifecycle precedence ranks available first.
#######################################
test_blocked_available_conflict_fails_closed() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_CONCURRENT_LABEL_AFTER_GET="status:blocked"
	set_issue_status 1630 "owner/repo" "available" >/dev/null 2>&1
	local rc=$?
	local final_status=""
	final_status=$(jq -r '.labels[].name' "$ISSUE_STATE_FILE")
	if [[ "$rc" -eq 0 && "$final_status" == "status:blocked" ]]; then
		print_result "blocked/available conflict keeps blocked" 0
	else
		print_result "blocked/available conflict keeps blocked" 1 \
			"(rc=${rc}; status=${final_status}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

#######################################
# TEST 27: If a competing writer removes the selected winner after the repair
# snapshot, terminal verification observes the zero-status gap and restores the
# winner once rather than returning apparent success with no managed status.
#######################################
test_stale_loser_deletion_is_compensated() {
	_reset_state
	printf '%s\n' '{"labels":[{"name":"status:available"}],"assignees":[]}' >"$ISSUE_STATE_FILE"
	export STUB_STATEFUL_ISSUE=1
	export STUB_CONCURRENT_LABEL_AFTER_GET="status:done"
	export STUB_CONCURRENT_REMOVE_TRIGGER="status%3Aqueued"
	export STUB_CONCURRENT_REMOVE_BEFORE_DELETE="status:done"
	set_issue_status 1631 "owner/repo" "queued" >/dev/null 2>&1
	local rc=$?
	local compensation_adds=0
	compensation_adds=$(grep -c '^api -X POST /repos/owner/repo/issues/1631/labels -f labels\[\]=status:done$' "$GH_CALLS_FILE" || true)
	if [[ "$rc" -eq 0 && "$compensation_adds" -eq 1 ]] &&
		jq -e '.labels == [{"name":"status:done"}]' "$ISSUE_STATE_FILE" >/dev/null; then
		print_result "stale loser deletion receives bounded compensation" 0
	else
		print_result "stale loser deletion receives bounded compensation" 1 \
			"(rc=${rc}; compensation_adds=${compensation_adds}; calls=$(cat "$GH_CALLS_FILE"))"
	fi
	return 0
}

# =============================================================================
# Run tests
# =============================================================================
main() {
	test_queued_transition
	test_available_with_extra_flags
	test_empty_status_clear_only
	test_in_progress_removes_claimed
	test_invalid_status_rejected
	test_missing_args_rejected
	test_canonical_label_list
	test_dispatch_realistic_pattern
	test_rest_first_transition
	test_concurrent_unrelated_label_is_preserved
	test_concurrent_unrelated_assignee_is_preserved
	test_converged_label_contract_is_read_only
	test_label_contract_reconciliation
	test_label_create_conflict_is_verified
	test_label_contract_read_failure_is_fail_closed
	test_failed_extra_does_not_start_status_transition
	test_rest_status_failure_uses_status_only_native_fallback
	test_failed_target_add_never_strands_dual_statuses
	test_failed_extra_add_preserves_existing_assignee
	test_failed_extra_add_preserves_existing_label
	test_owned_transition_adds_target_before_source_removal
	test_owned_transition_failed_add_preserves_source
	test_owned_transition_failed_remove_preserves_overlap
	test_owned_transition_preconditions_fail_closed
	test_competing_status_writers_converge_by_precedence
	test_competing_status_repair_failure_is_bounded
	test_blocked_available_conflict_fails_closed
	test_stale_loser_deletion_is_compensated

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
