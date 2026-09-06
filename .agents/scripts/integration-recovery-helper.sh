#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Runtime-owned recovery intake; queue records confer no execution authority.
[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail
_IR_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

integration_recovery_capture() {
	local output_file="$1" worktree="$2"
	local issue="${WORKER_ISSUE_NUMBER:-}" repo="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local request="" brief="" prs="" branch="" head="" pr=0 pr_head="" payload=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	request=$(python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" extract --output "$output_file") || return 1
	#aidevops:trust-boundary — capture is called by the runtime after final output,
	# not by parsing issue prose. Fresh dispatch fencing precedes any queue write.
	declare -F _hrw_verify_dispatch_ownership >/dev/null 2>&1 || return 1
	_hrw_verify_dispatch_ownership || return 1
	[[ -n "${AIDEVOPS_ATTEMPT_ID:-}" && -n "${WORKER_SESSION_KEY:-}" ]] || return 1
	brief=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null) || return 1
	jq -e --argjson issue "$issue" '
		.number == $issue and .state == "open" and
		(.author_association as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a))
	' <<<"$brief" >/dev/null || return 1
	branch=$(git -C "$worktree" symbolic-ref --short HEAD) || return 1
	head=$(git -C "$worktree" rev-parse HEAD) || return 1
	prs=$(gh pr list --repo "$repo" --head "$branch" --state open \
		--json number,headRefOid,isCrossRepository,closingIssuesReferences 2>/dev/null) || return 1
	pr=$(jq -er --argjson issue "$issue" '
		if length == 0 then 0 else select(length == 1) | .[0] |
		select(.isCrossRepository == false and ([.closingIssuesReferences[].number] == [$issue])) | .number end
	' <<<"$prs") || return 1
	if [[ "$pr" != 0 ]]; then
		pr_head=$(jq -er '.[0].headRefOid' <<<"$prs") || return 1
		[[ "$pr_head" =~ ^[a-f0-9]{40,64}$ ]] || return 1
	fi
	payload=$(jq -nc --argjson request "$request" --argjson brief "$brief" \
		--arg repo "$repo" --argjson issue "$issue" --argjson pr "$pr" \
		--arg attempt "$AIDEVOPS_ATTEMPT_ID" --arg session "$WORKER_SESSION_KEY" \
		--arg branch "$branch" --arg head "$head" --arg pr_head "$pr_head" \
		'{request:$request,envelope:{repo:$repo,issue:$issue,pr:$pr,attempt:$attempt,session:$session,branch:$branch,head:$head,pr_head:$pr_head,brief:$brief}}') || return 1
	_IR_CAPTURE_RESULT=$(python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" capture <<<"$payload") || return 1
	return 0
}

integration_recovery_observe() {
	local id="$1" record="" repo="" issue="" brief="" comments="" dependencies=""
	record=$(python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" show --id "$id") || return 1
	repo=$(jq -er '.repo' <<<"$record") || return 1
	issue=$(jq -er '.issue' <<<"$record") || return 1
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	brief=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null) || return 1
	# Reuse the circuit's authenticated comment filtering and dependency API.
	# shellcheck source=terminal-blocker-circuit.sh
	source "${_IR_SCRIPT_DIR}/terminal-blocker-circuit.sh"
	comments=$(terminal_blocker_fetch_trusted_comments "$issue" "$repo") || return 1
	dependencies=$(_terminal_blocker_dependency_signature "$repo" "$issue") || return 1
	jq -nc --argjson issue "$brief" --argjson comments "$comments" --argjson dependencies "$dependencies" \
		'{issue:$issue,comments:$comments,dependencies:$dependencies}' |
		python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" observe --id "$id"
	return $?
}

integration_recovery_pending() {
	local records="" id="" observed=""
	records=$(python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" pending) || return 1
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		if observed=$(integration_recovery_observe "$id"); then
			[[ "$observed" == null ]] || printf '%s\n' "$observed"
		else
			printf 'Recovery request %s remains owned by Pulse; live observation unavailable\n' "$id" >&2
		fi
	done < <(jq -r '.[].id' <<<"$records")
	return 0
}

integration_recovery_decision() {
	local id="${1:-}" record="" repo="" actor="" input=""
	[[ -z "${WORKER_ISSUE_NUMBER:-}" && "$id" =~ ^[a-f0-9]{24}$ ]] || return 1
	input=$(jq -ec 'select(keys == ["evidence","next_action","wake"])') || return 1
	record=$(python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" show --id "$id") || return 1
	repo=$(jq -er '.repo' <<<"$record") || return 1
	actor=$(gh api user --jq .login) || return 1
	#aidevops:trust-boundary — immutable decision authorship comes from GitHub,
	# never a worker's event or an actor field supplied through stdin.
	gh api "repos/${repo}/collaborators/${actor}/permission" --jq '.permission' |
		grep -Eq '^(admin|maintain|write)$' || return 1
	integration_recovery_observe "$id" >/dev/null || return 1
	jq --arg actor "$actor" '. + {actor:$actor}' <<<"$input" |
		python3 "${_IR_SCRIPT_DIR}/integration_recovery.py" decision --id "$id"
	return $?
}

integration_recovery_main() {
	local action="${1:-pending}"
	shift || true
	case "$action" in
	pending) integration_recovery_pending ;;
	decision) integration_recovery_decision "$@" ;;
	*) return 2 ;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	integration_recovery_main "$@"
fi
