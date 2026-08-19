#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-output-classification-head-vs-search.sh — Regression tests for
# t3195 / GH#21889. Pin the contract that `_pr_exists_for_branch_or_issue`
# (and the upstream classifier paths that use it) preferentially probe via
# `gh pr list --head <branch> --state all` so workers are not misclassified
# during the GitHub Search index lag window (5-30 min after PR creation).
#
# Background (canonical incident, t3195):
#
#   - Worker dispatched at 05:43:12Z (issue #21870, repo a/b).
#   - Worker pushed feature/auto-... and opened PR #21885 at 05:47:48Z.
#   - The pulse ran `_worker_produced_output` at 05:52:38Z (5 min later).
#   - Signal 3 was `gh pr list --search 21870 --json number --jq length`.
#   - GitHub Search index had not yet indexed PR #21885 → returned 0.
#   - Classifier emitted `branch_orphan`.
#   - `_attempt_orphan_recovery_pr` then tried `gh pr create --head <same>`
#     which fails because the PR ALREADY exists for that head.
#   - The worker's real output was discarded as orphan recovery noise.
#
# Fix (t3195): probe via `--head <branch> --state all` first (live pulls API,
# no search-index lag); fall back to `--search <issue>` only when --head
# missed (or branch unknown). Pre-check the same in `_attempt_orphan_recovery_pr`
# so the recovery path no-ops cleanly when a PR already exists.
#
# Test cases:
#
#   Case A (search-lag survival): branch=feature/foo, head-probe returns 1,
#     search-probe returns 0 → helper "found", classifier "pr_exists".
#     This is THE regression case from t3195. Pre-fix: `branch_orphan`.
#
#   Case B (definitive absence): branch=feature/foo, head-probe returns 0,
#     search-probe returns 0 → helper "absent", classifier "branch_orphan".
#     Legitimate orphan path stays intact.
#
#   Case C (search fallback for empty branch): branch="", head-probe never
#     fires, search-probe returns 1 → helper "found".
#     Confirms the fallback chain works when branch_name is empty.
#
#   Case D (no inputs / unknown): branch="", issue="", repo="" → "unknown".
#     Caller fail-opens via the `*` arm of the case statement.
#
#   Case E (orphan recovery pre-check): _attempt_orphan_recovery_pr is given
#     a branch whose head-probe returns 1 → returns 0 (PR exists, no
#     duplicate creation attempt). Pre-fix: tried `gh pr create` → failed.

set -uo pipefail

# Bypass the aidevops git policy shim for disposable repositories created under
# this test's isolated temporary HOME.
git() {
	command -p git "$@"
	return $?
}

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
LIB_SCRIPT="${TEST_SCRIPTS_DIR}/shared-claim-lifecycle.sh"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s%s\n' "$TEST_RED" "$TEST_RESET" "$name" "${extra:+ — $extra}"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Sandbox
# -----------------------------------------------------------------------------

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

ORIGINAL_HOME="$HOME"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# `gh` stub: lifecycle probes return real gh JSON shapes from STUB_HEAD_JSON and
# STUB_SEARCH_JSON. Any other gh invocation prints empty JSON {} and exits 0
# so source-time `gh api user` calls in dependent helpers don't crash.
GH_STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$GH_STUB_DIR"
cat >"${GH_STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: emit counts based on which probe flag is in argv.
# Recognised:
#   `gh pr list ... --head <branch> ...` → ${STUB_HEAD_COUNT:-0}
#   `gh pr list ... --search <query> ...` → ${STUB_SEARCH_COUNT:-0}
#   `gh pr create ...`                   → record to STUB_PR_CREATE_LOG, exit 0
#   `gh issue view ...`                  → emit OPEN state JSON
#   `gh repo view ...`                   → emit defaultBranchRef.name=main JSON
#   anything else                        → empty JSON `{}`
mode=""
json_fields=""
previous=""
for a in "$@"; do
	if [[ "$previous" == "--json" ]]; then
		json_fields="$a"
	fi
	case "$a" in
		--head) mode="head" ;;
		--search) mode="search" ;;
	esac
	previous="$a"
done
case "${1:-}" in
	pr)
		case "${2:-}" in
			list)
				if [[ "${AIDEVOPS_GH_REST_FIRST_READS:-0}" != "1" ]]; then
					printf 'lifecycle PR probe did not request REST-first routing\n' >&2
					exit 1
				fi
				if [[ "$mode" == "head" && "${STUB_HEAD_FAIL:-0}" == "1" ]]; then
					exit 1
				fi
				if [[ "$json_fields" == "number,state,isDraft,mergedAt,headRefOid,labels" ]]; then
					if [[ "$mode" == "head" ]]; then
						printf '%s\n' "${STUB_HEAD_JSON:-[]}"
					else
						printf '%s\n' "${STUB_SEARCH_JSON:-[]}"
					fi
					exit 0
				fi
				if [[ "$json_fields" == "number" && "$mode" == "search" ]]; then
					printf '%s\n' "${STUB_SEARCH_JSON:-[]}"
					exit 0
				fi
				if [[ "$mode" == "head" ]]; then
					printf '%s\n' "${STUB_HEAD_COUNT:-0}"
				elif [[ "$mode" == "search" ]]; then
					printf '%s\n' "${STUB_SEARCH_COUNT:-0}"
				else
					printf '0\n'
				fi
				;;
			create)
				if [[ -n "${STUB_PR_CREATE_LOG:-}" ]]; then
					printf 'gh pr create %s\n' "$*" >> "$STUB_PR_CREATE_LOG"
				fi
				exit 0
				;;
			*) ;;
		esac
		;;
	issue)
		case "${2:-}" in
			view) printf '"OPEN"\n' ;;
			*) ;;
		esac
		;;
	repo)
		case "${2:-}" in
			view) printf '"main"\n' ;;
			*) ;;
		esac
		;;
	api)
		if [[ "$*" == *"/comments"* ]]; then
			if [[ "${STUB_SUMMARY_COUNT:-0}" -gt 0 ]]; then
				printf '%s\n' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			else
				printf '%s\n' '[[]]'
			fi
		elif [[ "$*" == *"/pulls/"* ]]; then
			printf '%s\n' "${STUB_LINKED_BODY:-}"
		else
			printf '{}\n'
		fi
		;;
	*) ;;
esac
exit 0
STUB
chmod +x "${GH_STUB_DIR}/gh"
export PATH="${GH_STUB_DIR}:${PATH}"

# Source the lib. set -e off so transient sourcing failures don't abort.
set +e
# shellcheck source=/dev/null
source "$LIB_SCRIPT" >/dev/null 2>&1
SOURCE_RC=$?
set -e
if [[ "$SOURCE_RC" -ne 0 ]] && ! declare -F _pr_exists_for_branch_or_issue >/dev/null 2>&1; then
	printf '%sFAIL%s sourcing %s — _pr_exists_for_branch_or_issue not defined\n' \
		"$TEST_RED" "$TEST_RESET" "$LIB_SCRIPT"
	exit 1
fi
if ! declare -F _pr_exists_for_branch_or_issue >/dev/null 2>&1; then
	printf '%sFAIL%s _pr_exists_for_branch_or_issue not defined after source\n' \
		"$TEST_RED" "$TEST_RESET"
	exit 1
fi
if ! declare -F _attempt_orphan_recovery_pr >/dev/null 2>&1; then
	printf '%sFAIL%s _attempt_orphan_recovery_pr not defined after source\n' \
		"$TEST_RED" "$TEST_RESET"
	exit 1
fi

# Keep these unit tests independent of live GraphQL/REST routing state.
gh_pr_list() {
	gh pr list "$@"
	return $?
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case A: search-lag survival. --head returns 1, --search returns 0.
# This is the regression case from t3195 / GH#21889.
test_case_a_head_wins_over_search_lag() {
	export STUB_HEAD_JSON='[{"number":21885,"state":"OPEN","isDraft":false,"mergedAt":null,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]'
	export STUB_SEARCH_JSON='[]'
	local got
	got=$(_pr_exists_for_branch_or_issue "feature/auto-foo" "21870" "owner/repo")
	if [[ "$got" == "found" ]]; then
		print_result "case A: --head=1 + --search=0 → found (search-lag survival, t3195)" 0
	else
		print_result "case A: --head=1 + --search=0 → found (search-lag survival, t3195)" 1 \
			"got: '$got' (expected 'found' — search-index lag must NOT mask a real PR)"
	fi
	return 0
}

# Case B: definitive absence. Both probes return 0.
test_case_b_definitive_absence() {
	export STUB_HEAD_JSON='[]'
	export STUB_SEARCH_JSON='[]'
	local got
	got=$(_pr_exists_for_branch_or_issue "feature/real-orphan" "99999" "owner/repo")
	if [[ "$got" == "absent" ]]; then
		print_result "case B: --head=0 + --search=0 → absent (legitimate orphan)" 0
	else
		print_result "case B: --head=0 + --search=0 → absent (legitimate orphan)" 1 \
			"got: '$got' (expected 'absent')"
	fi
	return 0
}

# Case C: search fallback when branch_name empty.
test_case_c_search_fallback_empty_branch() {
	export STUB_HEAD_JSON='[]'  # never queried — branch is empty
	export STUB_SEARCH_JSON='[{"number":21885}]'
	local got
	got=$(_pr_exists_for_branch_or_issue "" "21870" "owner/repo")
	if [[ "$got" == "found" ]]; then
		print_result "case C: branch='' + --search=1 → found (fallback path)" 0
	else
		print_result "case C: branch='' + --search=1 → found (fallback path)" 1 \
			"got: '$got' (expected 'found')"
	fi
	return 0
}

# Case D: no usable inputs → unknown.
test_case_d_no_inputs_unknown() {
	export STUB_HEAD_JSON='[]'
	export STUB_SEARCH_JSON='[]'
	local got
	got=$(_pr_exists_for_branch_or_issue "" "" "owner/repo")
	if [[ "$got" == "unknown" ]]; then
		print_result "case D: branch='' + issue='' → unknown (fail-open)" 0
	else
		print_result "case D: branch='' + issue='' → unknown (fail-open)" 1 \
			"got: '$got' (expected 'unknown')"
	fi
	return 0
}

# Case D2: empty repo_slug → unknown regardless of probes.
test_case_d2_empty_repo_unknown() {
	export STUB_HEAD_JSON='[{"number":1}]'
	export STUB_SEARCH_JSON='[{"number":1}]'
	local got
	got=$(_pr_exists_for_branch_or_issue "feature/foo" "21870" "")
	if [[ "$got" == "unknown" ]]; then
		print_result "case D2: repo_slug='' → unknown (no API target)" 0
	else
		print_result "case D2: repo_slug='' → unknown (no API target)" 1 \
			"got: '$got' (expected 'unknown')"
	fi
	return 0
}

test_case_d3_failed_head_probe_is_unknown() {
	export STUB_HEAD_FAIL=1
	export STUB_HEAD_JSON='[]'
	export STUB_SEARCH_JSON='[]'
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/api-failure" "21870" "owner/repo")
	unset STUB_HEAD_FAIL
	if [[ "$got" == "unknown|" ]]; then
		print_result "failed exact-head probe plus empty search remains unknown" 0
	else
		print_result "failed exact-head probe plus empty search remains unknown" 1 "got: '$got'"
	fi
	return 0
}

test_case_draft_state_is_preserved() {
	export STUB_HEAD_JSON='[{"number":321,"state":"OPEN","isDraft":true,"mergedAt":null,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]'
	export STUB_SEARCH_JSON='[]'
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/checkpoint" "27501" "owner/repo")
	if [[ "$got" == "draft_checkpoint|321" ]]; then
		print_result "draft PR is classified as durable checkpoint, not completed handoff" 0
	else
		print_result "draft PR is classified as durable checkpoint, not completed handoff" 1 "got: '$got'"
	fi
	return 0
}

test_case_ready_and_terminal_states_are_preserved() {
	local fixture expected got
	for fixture in \
		'[{"number":322,"state":"OPEN","isDraft":false,"mergedAt":null,"labels":[],"statusCheckRollup":[]}]' \
		'[{"number":323,"state":"MERGED","isDraft":false,"mergedAt":"2026-07-13T00:00:00Z","labels":[],"statusCheckRollup":[]}]' \
		'[{"number":324,"state":"CLOSED","isDraft":false,"mergedAt":null,"labels":[],"statusCheckRollup":[]}]'; do
		case "$fixture" in
			*322*) expected="ready|322" ;;
			*323*) expected="merged|323" ;;
			*) expected="closed_unmerged|324" ;;
		esac
		export STUB_HEAD_JSON="$fixture"
		got=$(_pr_handoff_state_for_branch_or_issue "feature/checkpoint" "27501" "owner/repo")
		if [[ "$got" == "$expected" ]]; then
			print_result "PR lifecycle state ${expected%%|*} is preserved" 0
		else
			print_result "PR lifecycle state ${expected%%|*} is preserved" 1 "got: '$got'"
		fi
	done
	return 0
}

test_case_ready_requires_exact_head_and_merge_summary() {
	export STUB_HEAD_JSON='[{"number":331,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"remote-head","labels":[],"statusCheckRollup":[]}]'
	export STUB_SEARCH_JSON='[]'
	export STUB_LINKED_BODY='Resolves #27501'
	export STUB_SUMMARY_COUNT=1
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/exact" "27501" "owner/repo" \
		"head-only" "local-head" 1)
	if [[ "$got" == "head_mismatch|331" ]]; then
		print_result "ready handoff rejects local HEAD that differs from PR head" 0
	else
		print_result "ready handoff rejects local HEAD that differs from PR head" 1 "got: '$got'"
	fi

	export STUB_SUMMARY_COUNT=0
	got=$(_pr_handoff_state_for_branch_or_issue "feature/exact" "27501" "owner/repo" \
		"head-only" "remote-head" 1)
	if [[ "$got" == "ready_missing_summary|331" ]]; then
		print_result "ready handoff requires canonical MERGE_SUMMARY" 0
	else
		print_result "ready handoff requires canonical MERGE_SUMMARY" 1 "got: '$got'"
	fi

	export STUB_SUMMARY_COUNT=1
	got=$(_pr_handoff_state_for_branch_or_issue "feature/exact" "27501" "owner/repo" \
		"head-only" "remote-head" 1)
	if [[ "$got" == "ready|331" ]]; then
		print_result "ready handoff accepts exact head with MERGE_SUMMARY" 0
	else
		print_result "ready handoff accepts exact head with MERGE_SUMMARY" 1 "got: '$got'"
	fi
	unset STUB_SUMMARY_COUNT
	unset STUB_LINKED_BODY
	return 0
}

test_case_ready_requires_same_repo_linkage() {
	export STUB_HEAD_JSON='[{"number":333,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"remote-head","labels":[],"statusCheckRollup":[]}]'
	export STUB_SEARCH_JSON='[]'
	export STUB_SUMMARY_COUNT=1
	export STUB_LINKED_BODY='## Summary\n\nNo closing reference survived creation.'
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/exact" "27501" "owner/repo" \
		"head-only" "remote-head" 1)
	if [[ "$got" == "ready_missing_linkage|333" ]]; then
		print_result "ready handoff requires a same-repository closing reference" 0
	else
		print_result "ready handoff requires a same-repository closing reference" 1 "got: '$got'"
	fi
	unset STUB_SUMMARY_COUNT STUB_LINKED_BODY
	return 0
}

test_case_merged_requires_exact_head_and_merge_summary() {
	export STUB_HEAD_JSON='[{"number":332,"state":"MERGED","isDraft":false,"mergedAt":"2026-07-13T00:00:00Z","headRefOid":"merged-head","labels":[],"statusCheckRollup":[]}]'
	export STUB_SEARCH_JSON='[]'
	export STUB_LINKED_BODY='Resolves #27501'
	export STUB_SUMMARY_COUNT=1
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/merged" "27501" "owner/repo" \
		"head-only" "newer-local-head" 1)
	if [[ "$got" == "head_mismatch|332" ]]; then
		print_result "merged handoff rejects unpushed local commits" 0
	else
		print_result "merged handoff rejects unpushed local commits" 1 "got: '$got'"
	fi

	export STUB_SUMMARY_COUNT=0
	got=$(_pr_handoff_state_for_branch_or_issue "feature/merged" "27501" "owner/repo" \
		"head-only" "merged-head" 1)
	if [[ "$got" == "merged_missing_summary|332" ]]; then
		print_result "merged handoff requires canonical MERGE_SUMMARY" 0
	else
		print_result "merged handoff requires canonical MERGE_SUMMARY" 1 "got: '$got'"
	fi
	unset STUB_SUMMARY_COUNT
	unset STUB_LINKED_BODY
	return 0
}

test_case_head_only_does_not_capture_unrelated_issue_draft() {
	export STUB_HEAD_JSON='[]'
	export STUB_SEARCH_JSON='[{"number":325,"state":"OPEN","isDraft":true}]'
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/worker" "27501" "owner/repo")
	if [[ "$got" == "unverified_open_pr|325" ]]; then
		print_result "issue-search fallback remains inconclusive, not complete" 0
	else
		print_result "issue-search fallback remains inconclusive, not complete" 1 "got: '$got'"
	fi
	return 0
}

test_case_active_pr_wins_over_historical_pr() {
	export STUB_HEAD_JSON='[{"number":326,"state":"CLOSED","isDraft":false,"mergedAt":null,"labels":[],"statusCheckRollup":[]},{"number":327,"state":"OPEN","isDraft":true,"mergedAt":null,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]'
	local got
	got=$(_pr_handoff_state_for_branch_or_issue "feature/reopened" "27501" "owner/repo")
	if [[ "$got" == "draft_checkpoint|327" ]]; then
		print_result "active draft wins over historical closed PR on same head" 0
	else
		print_result "active draft wins over historical closed PR on same head" 1 "got: '$got'"
	fi
	return 0
}

test_case_ci_failures_remain_ready_handoffs() {
	local fixture expected got
	for fixture in \
		'[{"number":328,"state":"OPEN","isDraft":false,"mergedAt":null,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"tests","status":"COMPLETED","conclusion":"FAILURE"}]}]' \
		'[{"number":329,"state":"OPEN","isDraft":false,"mergedAt":null,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"__typename":"StatusContext","context":"ci/test","state":"ERROR"}]}]'; do
		case "$fixture" in
			*328*) expected="ready|328" ;;
			*) expected="ready|329" ;;
		esac
		export STUB_HEAD_JSON="$fixture"
		export STUB_SEARCH_JSON='[]'
		got=$(_pr_handoff_state_for_branch_or_issue "feature/failed-checks" "27517" "owner/repo")
		if [[ "$got" == "$expected" ]]; then
			print_result "real CheckRun/StatusContext failure remains durable ${expected}" 0
		else
			print_result "real CheckRun/StatusContext failure remains durable ${expected}" 1 "got: '$got'"
		fi
	done
	return 0
}

test_case_protected_draft_labels_are_preserved() {
	local label got
	for label in origin:interactive hold-for-review no-auto-dispatch needs-maintainer-review; do
		export STUB_HEAD_JSON="[{\"number\":330,\"state\":\"OPEN\",\"isDraft\":true,\"mergedAt\":null,\"labels\":[{\"name\":\"origin:worker\"},{\"name\":\"${label}\"}],\"statusCheckRollup\":[]}]"
		export STUB_SEARCH_JSON='[]'
		got=$(_pr_handoff_state_for_branch_or_issue "feature/protected" "27517" "owner/repo")
		if [[ "$got" == "protected_draft|330" ]]; then
			print_result "draft carrying ${label} is protected" 0
		else
			print_result "draft carrying ${label} is protected" 1 "got: '$got'"
		fi
	done
	return 0
}

# Case E: orphan recovery pre-check. When a PR exists for the branch
# (--head=1), recovery returns 0 with NO `gh pr create` attempt.
test_case_e_orphan_recovery_skips_when_pr_exists() {
	export STUB_HEAD_JSON='[{"number":21885,"state":"OPEN","isDraft":false,"mergedAt":null,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]'
	export STUB_SEARCH_JSON='[]'
	local pr_log="${TEST_ROOT}/pr-create.log"
	: >"$pr_log"
	export STUB_PR_CREATE_LOG="$pr_log"

	# Call recovery; should return 0 immediately (PR exists) and NOT log
	# any `gh pr create` invocation.
	if _attempt_orphan_recovery_pr "issue-21870" "/tmp/unused-workdir" \
		"feature/auto-foo" "owner/repo"; then
		if [[ -s "$pr_log" ]]; then
			print_result "case E: orphan recovery short-circuits when --head=1" 1 \
				"recovery returned 0 but ALSO called gh pr create — pre-check ineffective"
		else
			print_result "case E: orphan recovery short-circuits when --head=1" 0
		fi
	else
		print_result "case E: orphan recovery short-circuits when --head=1" 1 \
			"recovery returned non-zero (expected 0 — PR exists, treat as success)"
	fi
	unset STUB_PR_CREATE_LOG
	return 0
}

# Case F: orphan recovery proceeds when no PR exists. Confirms the pre-check
# does NOT block legitimate recovery when the absence is real. We allow the
# stub `gh pr create` to "succeed" so we can observe it being called.
test_case_f_orphan_recovery_proceeds_when_no_pr() {
	export STUB_HEAD_JSON='[]'
	export STUB_SEARCH_JSON='[]'
	local pr_log="${TEST_ROOT}/pr-create-2.log"
	: >"$pr_log"
	export STUB_PR_CREATE_LOG="$pr_log"
	local origin_dir="${TEST_ROOT}/case-f-origin.git"
	local work_dir="${TEST_ROOT}/case-f-work"
	git init --bare "$origin_dir" >/dev/null 2>&1 || return 1
	git init "$work_dir" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.email test@example.invalid || return 1
	git -C "$work_dir" config user.name "Test User" || return 1
	printf 'base\n' >"${work_dir}/README.md"
	git -C "$work_dir" add README.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m base >/dev/null 2>&1 || return 1
	git -C "$work_dir" branch -M main >/dev/null 2>&1 || return 1
	git -C "$work_dir" remote add origin "$origin_dir" || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1
	git -C "$work_dir" checkout -b feature/real-orphan >/dev/null 2>&1 || return 1
	printf 'change\n' >>"${work_dir}/README.md"
	git -C "$work_dir" add README.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m change >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin feature/real-orphan >/dev/null 2>&1 || return 1

	_attempt_orphan_recovery_pr "issue-99999" "$work_dir" \
		"feature/real-orphan" "owner/repo" || true
	# Whether create succeeded matters less than: did we ATTEMPT it?
	if [[ -s "$pr_log" ]]; then
		print_result "case F: orphan recovery proceeds to gh pr create when --head=0" 0
	else
		print_result "case F: orphan recovery proceeds to gh pr create when --head=0" 1 \
			"pre-check incorrectly blocked recovery despite definitive absence"
	fi
	unset STUB_PR_CREATE_LOG
	return 0
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

test_case_a_head_wins_over_search_lag
test_case_b_definitive_absence
test_case_c_search_fallback_empty_branch
test_case_d_no_inputs_unknown
test_case_d2_empty_repo_unknown
test_case_d3_failed_head_probe_is_unknown
test_case_draft_state_is_preserved
test_case_ready_and_terminal_states_are_preserved
test_case_ready_requires_exact_head_and_merge_summary
test_case_ready_requires_same_repo_linkage
test_case_merged_requires_exact_head_and_merge_summary
test_case_head_only_does_not_capture_unrelated_issue_draft
test_case_active_pr_wins_over_historical_pr
test_case_ci_failures_remain_ready_handoffs
test_case_protected_draft_labels_are_preserved
test_case_e_orphan_recovery_skips_when_pr_exists
test_case_f_orphan_recovery_proceeds_when_no_pr

printf '\nRan %d test(s), %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

export HOME="$ORIGINAL_HOME"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
