#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for pulse cleanup permanent removal guards:
# - current-cwd worktrees are skipped before deletion
# - eligible orphan worktrees are removed permanently and unregistered

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/pulse.log"
export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup_worktrees.log"
UNREGISTER_LOG="${TEST_ROOT}/unregister.log"

# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

is_worktree_owned_by_others() { return 1; }
unregister_worktree() {
	local wt_path="$1"
	printf '%s\n' "$wt_path" >>"$UNREGISTER_LOG"
	return 0
}

# shellcheck source=../pulse-cleanup.sh
source "${SCRIPT_DIR}/pulse-cleanup.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

make_repo_with_worktree() {
	local repo_path="$1"
	local wt_path="$2"
	local branch="$3"

	mkdir -p "$repo_path"
	git -C "$repo_path" init -q -b main
	printf 'base\n' >"${repo_path}/README.md"
	git -C "$repo_path" add README.md
	git -C "$repo_path" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
	git -C "$repo_path" worktree add -q -b "$branch" "$wt_path" main
	touch -t 202001010000 "${wt_path}/.git"
	return 0
}

test_current_cwd_skip() {
	local repo_path="${TEST_ROOT}/repo-cwd"
	local wt_path="${TEST_ROOT}/wt-cwd"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/cwd"

	(
		cd "$wt_path"
		if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/cwd" "$(date +%s)" "" "main"; then
			exit 1
		fi
	)

	[[ -d "$wt_path" ]] || fail "current cwd worktree was removed"
	grep -q 'current-worktree.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" || fail "current-cwd skip was not audited"
	pass "pulse cleanup skips current cwd worktree"
	return 0
}

test_orphan_removal_unregisters() {
	local repo_path="${TEST_ROOT}/repo-remove"
	local wt_path="${TEST_ROOT}/wt-remove"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/remove"

	_cleanup_single_worktree "$repo_path" "$wt_path" "feature/remove" "$(date +%s)" "" "main" \
		|| fail "eligible orphan worktree was not removed"

	[[ ! -e "$wt_path" ]] || fail "eligible orphan worktree still exists"
	grep -Fxq "$wt_path" "$UNREGISTER_LOG" || fail "worktree unregister was not called"
	grep -q 'age-eligible.*mode=permanent' "$AIDEVOPS_CLEANUP_LOG" || fail "permanent removal was not audited"
	pass "pulse cleanup permanently removes and unregisters eligible orphan"
	return 0
}

test_degraded_orphan_removal_is_recoverable() {
	local repo_path="${TEST_ROOT}/repo-degraded"
	local wt_path="${TEST_ROOT}/wt-degraded"
	local trash_root="${TEST_ROOT}/recoverable-trash"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/degraded"
	mkdir -p "$trash_root"

	worktree_removal_guard() {
		local candidate_path="$1"
		local caller="$2"
		local reason="$3"
		: "$candidate_path" "$caller" "$reason"
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		return 2
	}
	gh_pr_list() {
		return 0
	}
	claim_worktree_ownership() {
		return 0
	}
	unregister_worktree_if_owner_pid() {
		return 0
	}
	is_worktree_owned_by_others_for_pid() {
		return 1
	}
	_branch_has_active_interactive_claim() {
		return 1
	}

	AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root" \
		_cleanup_single_worktree "$repo_path" "$wt_path" "feature/degraded" \
		"$(date +%s)" "owner/repo" "main" ||
		fail "degraded eligible orphan was not removed recoverably"

	[[ ! -e "$wt_path" ]] || fail "degraded orphan source path still exists"
	if /usr/bin/git -C "$repo_path" worktree list --porcelain | grep -Fqx "worktree $wt_path"; then
		fail "degraded orphan metadata remains registered"
	fi
	grep -Fxq "$wt_path" "$UNREGISTER_LOG" || fail "degraded orphan unregister was not called"
	grep -q 'degraded-cwd-orphan-recoverable.*mode=recoverable-trash' "$AIDEVOPS_CLEANUP_LOG" ||
		fail "recoverable degraded removal was not audited"
	pass "pulse cleanup recoverably removes a degraded clean zero-ahead no-PR orphan"
	return 0
}

write_kill_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/kill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${KILL_LOG:?}"
exit 0
STUB
	chmod +x "${bin_dir}/kill"
	return 0
}

write_ledger_stub() {
	local scripts_dir="$1"
	local mode="$2"
	mkdir -p "$scripts_dir"
	if [[ "$mode" == "missing" ]]; then
		cat >"${scripts_dir}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
	else
		cat >"${scripts_dir}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "check" ]]; then
	jq -cn --arg worktree "${LEDGER_WORKTREE:?}" --arg lease "${LEDGER_LEASE_TOKEN:?}" \
		'{session_key:"issue-3964",issue_number:"3964",repo_slug:"exampleorg/examplerepo",pid:123,status:"in-flight",lease_phase:"ready",worktree_path:$worktree,lease_token:$lease}'
	exit 0
fi
printf '%s\n' "$*" >>"${LEDGER_LOG:?}"
if [[ "$cmd" == "complete" && "${LEDGER_COMPLETE_FAIL:-0}" == "1" ]]; then
	exit 1
fi
exit 0
STUB
	fi
	chmod +x "${scripts_dir}/dispatch-ledger-helper.sh"
	return 0
}

ps() {
	local subcommand="${1:-}"
	if [[ "$subcommand" == "aux" ]]; then
		printf '%s\n' 'runner 123 0.0 0.0 ?? ?? S 0:00 headless-runtime-helper.sh run --role worker --session-key issue-3964 --dir /tmp/wt'
	fi
	return 0
}

kill() {
	local pid="$1"
	printf '%s\n' "$pid" >>"${KILL_LOG:?}"
	return 0
}

gh() {
	local subcommand="${1:-}"
	local action="${2:-}"
	printf '%s\n' "$*" >>"${GH_LOG:?}"
	if [[ "$subcommand" == "issue" && "$action" == "view" ]]; then
		printf '%s\n' "${GH_ISSUE_STATE:-OPEN}"
		return 0
	fi
	if [[ "$subcommand" == "pr" && "$action" == "list" ]]; then
		[[ "${GH_API_FAIL:-0}" == "0" ]] || return 1
		jq -cn --argjson number "${GH_MERGED_PR:-3964}" --argjson issue "${GH_CLOSING_ISSUE:-3964}" \
			--arg branch "${GH_PR_BRANCH:?}" --arg head "${GH_PR_HEAD:?}" \
			'[{number:$number,state:"MERGED",mergedAt:"2026-07-15T12:00:00Z",headRefName:$branch,headRefOid:$head,closingIssuesReferences:[{number:$issue}]}]'
		return 0
	fi
	return 1
}

gh_issue_comment() {
	printf 'gh_issue_comment %s\n' "$*" >>"${GH_LOG:?}"
	return 0
}

recover_failed_launch_state() {
	printf 'recover_failed_launch_state %s\n' "$*" >>"${GH_LOG:?}"
	return 0
}

test_orphan_crash_skips_closed_issue_comment() {
	local gh_log="${TEST_ROOT}/gh-closed-orphan.log"
	local old_state="${GH_ISSUE_STATE:-}"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-closed-orphan.log"
	GH_LOG="$gh_log"
	GH_ISSUE_STATE="CLOSED"
	export GH_LOG GH_ISSUE_STATE

	_record_orphan_crash_classification "feature/auto-20260515-123456-gh23379" 0 "owner/repo"

	grep -q 'issue view 23379 --repo owner/repo' "$gh_log" || fail "closed orphan did not check issue state"
	if grep -Eq 'gh_issue_comment|recover_failed_launch_state|issues/23379/comments' "$gh_log"; then
		fail "closed orphan posted or recovered issue state"
	fi
	grep -q 'Orphan cleanup skipped for #23379 (owner/repo): issue state=CLOSED' "$LOGFILE" || fail "closed orphan skip was not audited"
	if [[ -n "$old_state" ]]; then
		GH_ISSUE_STATE="$old_state"
	else
		unset GH_ISSUE_STATE
	fi
	pass "orphan cleanup skips recovery comments on closed issues"
	return 0
}

test_orphan_crash_keeps_open_issue_recovery() {
	local gh_log="${TEST_ROOT}/gh-open-orphan.log"
	local old_state="${GH_ISSUE_STATE:-}"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-open-orphan.log"
	GH_LOG="$gh_log"
	GH_ISSUE_STATE="OPEN"
	export GH_LOG GH_ISSUE_STATE

	_record_orphan_crash_classification "feature/auto-20260515-123456-gh23380" 0 "owner/repo"

	grep -q 'issue view 23380 --repo owner/repo' "$gh_log" || fail "open orphan did not check issue state"
	grep -q 'recover_failed_launch_state 23380 owner/repo premature_exit no_work' "$gh_log" || fail "open orphan did not recover launch state"
	grep -q 'gh_issue_comment 23380 --repo owner/repo --body' "$gh_log" || fail "open orphan did not post recovery comment"
	if [[ -n "$old_state" ]]; then
		GH_ISSUE_STATE="$old_state"
	else
		unset GH_ISSUE_STATE
	fi
	pass "orphan cleanup preserves recovery comments on open issues"
	return 0
}

test_zombie_reaper_requires_ledger_repo() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-no-ledger"
	local bin_dir="${TEST_ROOT}/bin-no-ledger"
	local kill_log="${TEST_ROOT}/kill-no-ledger.log"
	local gh_log="${TEST_ROOT}/gh-no-ledger.log"
	local old_path="$PATH"

	: >"$kill_log"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-no-ledger.log"
	printf '%s\n' '{"initialized_repos":[{"slug":"marcusquinn/aidevops","pulse":true}]}' >"${TEST_ROOT}/repos.json"
	REPOS_JSON="${TEST_ROOT}/repos.json"
	write_ledger_stub "$scripts_dir" "missing"
	write_kill_stub "$bin_dir"

	SCRIPT_DIR="$scripts_dir"
	PATH="${bin_dir}:${PATH}"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR="3964"
	reap_zombie_workers
	PATH="$old_path"
	SCRIPT_DIR="$original_script_dir"

	[[ ! -s "$kill_log" ]] || fail "zombie reaper killed a worker without a ledger repo"
	[[ ! -s "$gh_log" ]] || fail "zombie reaper queried merged PRs without a ledger repo"
	grep -q 'no live ledger repo' "$LOGFILE" || fail "missing no-ledger skip audit log"
	pass "zombie reaper refuses repo-less merged-PR lookup"
	return 0
}

test_zombie_reaper_uses_ledger_repo_and_pid() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-with-ledger"
	local bin_dir="${TEST_ROOT}/bin-with-ledger"
	local kill_log="${TEST_ROOT}/kill-with-ledger.log"
	local gh_log="${TEST_ROOT}/gh-with-ledger.log"
	local ledger_log="${TEST_ROOT}/ledger-with-ledger.log"
	local repo_path="${TEST_ROOT}/repo-with-ledger"
	local worker_worktree="${TEST_ROOT}/wt-with-ledger"
	local old_path="$PATH"

	: >"$kill_log"
	: >"$gh_log"
	: >"$ledger_log"
	LOGFILE="${TEST_ROOT}/pulse-with-ledger.log"
	make_repo_with_worktree "$repo_path" "$worker_worktree" "feature/worker-3964"
	write_ledger_stub "$scripts_dir" "present"
	write_kill_stub "$bin_dir"

	SCRIPT_DIR="$scripts_dir"
	PATH="${bin_dir}:${PATH}"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR="5000" GH_API_FAIL=0 GH_CLOSING_ISSUE=3964
	export GH_PR_BRANCH="feature/worker-3964" GH_PR_HEAD LEDGER_WORKTREE="$worker_worktree" LEDGER_LEASE_TOKEN="lease-3964" LEDGER_LOG="$ledger_log"
	GH_PR_HEAD=$(git -C "$worker_worktree" rev-parse HEAD)
	reap_zombie_workers
	PATH="$old_path"
	SCRIPT_DIR="$original_script_dir"

	grep -Fxq '123' "$kill_log" || fail "zombie reaper did not kill the ledger PID"
	grep -q -- '--repo exampleorg/examplerepo' "$gh_log" || fail "zombie reaper did not query the ledger repo"
	grep -q -- '--head feature/worker-3964' "$gh_log" || fail "zombie reaper did not bind merged PR lookup to worker branch"
	grep -q 'closingIssuesReferences' "$gh_log" || fail "zombie reaper did not verify structured closing references"
	grep -q 'record-outcome.*--reason merged_pr_reap' "$ledger_log" || fail "zombie reaper did not record typed terminal telemetry"
	grep -q 'complete.*--lease-token lease-3964.*--reason merged_pr_reap' "$ledger_log" || fail "zombie reaper did not complete the exact lease"
	grep -q 'PR #5000 already merged in exampleorg/examplerepo' "$LOGFILE" || fail "missing ledger-repo reap audit log"
	grep -q 'kill_reason=merged_pr_reap' "$LOGFILE" || fail "missing typed reap lifecycle log"
	pass "zombie reaper uses ledger repo and PID"
	return 0
}

test_zombie_reaper_rejects_unverified_completion() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-unverified"
	local repo_path="${TEST_ROOT}/repo-unverified"
	local worker_worktree="${TEST_ROOT}/wt-unverified"
	local kill_log="${TEST_ROOT}/kill-unverified.log"
	local gh_log="${TEST_ROOT}/gh-unverified.log"
	local ledger_log="${TEST_ROOT}/ledger-unverified.log"

	: >"$kill_log"
	: >"$gh_log"
	: >"$ledger_log"
	LOGFILE="${TEST_ROOT}/pulse-unverified.log"
	make_repo_with_worktree "$repo_path" "$worker_worktree" "feature/worker-3964-unverified"
	write_ledger_stub "$scripts_dir" "present"
	SCRIPT_DIR="$scripts_dir"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR=5001 GH_API_FAIL=0 GH_CLOSING_ISSUE=9999
	export GH_PR_BRANCH="feature/worker-3964-unverified" GH_PR_HEAD LEDGER_WORKTREE="$worker_worktree" LEDGER_LEASE_TOKEN="lease-3964-unverified" LEDGER_LOG="$ledger_log"
	GH_PR_HEAD=$(git -C "$worker_worktree" rev-parse HEAD)
	reap_zombie_workers
	SCRIPT_DIR="$original_script_dir"

	[[ ! -s "$kill_log" ]] || fail "planning PR without structured closure reaped the worker"
	[[ ! -s "$ledger_log" ]] || fail "unverified completion emitted terminal ledger state"
	pass "zombie reaper rejects planning PRs without structured closure"
	return 0
}

test_zombie_reaper_fails_closed_on_stale_or_indeterminate_evidence() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-indeterminate"
	local repo_path="${TEST_ROOT}/repo-indeterminate"
	local worker_worktree="${TEST_ROOT}/wt-indeterminate"
	local kill_log="${TEST_ROOT}/kill-indeterminate.log"
	local gh_log="${TEST_ROOT}/gh-indeterminate.log"
	local ledger_log="${TEST_ROOT}/ledger-indeterminate.log"

	: >"$kill_log"
	: >"$gh_log"
	: >"$ledger_log"
	LOGFILE="${TEST_ROOT}/pulse-indeterminate.log"
	make_repo_with_worktree "$repo_path" "$worker_worktree" "feature/worker-3964-indeterminate"
	write_ledger_stub "$scripts_dir" "present"
	SCRIPT_DIR="$scripts_dir"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR=5002 GH_API_FAIL=0 GH_CLOSING_ISSUE=3964
	export GH_PR_BRANCH="feature/worker-3964-indeterminate" GH_PR_HEAD="0000000000000000000000000000000000000000"
	export LEDGER_WORKTREE="$worker_worktree" LEDGER_LEASE_TOKEN="lease-3964-indeterminate" LEDGER_LOG="$ledger_log"
	reap_zombie_workers
	GH_API_FAIL=1
	GH_PR_HEAD=$(git -C "$worker_worktree" rev-parse HEAD)
	reap_zombie_workers
	GH_API_FAIL=0
	export LEDGER_COMPLETE_FAIL=1
	reap_zombie_workers
	unset LEDGER_COMPLETE_FAIL
	SCRIPT_DIR="$original_script_dir"

	[[ ! -s "$kill_log" ]] || fail "stale or API-indeterminate evidence reaped the worker"
	if grep -q 'record-outcome' "$ledger_log"; then
		fail "stale or API-indeterminate evidence emitted terminal telemetry"
	fi
	grep -q 'ambiguous or API-indeterminate' "$LOGFILE" || fail "API-indeterminate skip was not diagnosed"
	grep -q 'active dispatch generation changed' "$LOGFILE" || fail "stale lease transition was not diagnosed"
	pass "zombie reaper fails closed on stale dispatch and API-indeterminate evidence"
	return 0
}

test_current_cwd_skip
test_orphan_removal_unregisters
test_orphan_crash_skips_closed_issue_comment
test_orphan_crash_keeps_open_issue_recovery
test_zombie_reaper_requires_ledger_repo
test_zombie_reaper_uses_ledger_repo_and_pid
test_zombie_reaper_rejects_unverified_completion
test_zombie_reaper_fails_closed_on_stale_or_indeterminate_evidence
test_degraded_orphan_removal_is_recoverable

exit 0
