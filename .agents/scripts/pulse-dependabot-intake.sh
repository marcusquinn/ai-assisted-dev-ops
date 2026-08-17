#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dependabot-intake.sh — idempotent worker intake for stalled bot PRs.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DEPENDABOT_INTAKE_LOADED:-}" ]] && return 0
_PULSE_DEPENDABOT_INTAKE_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

_pulse_dependabot_intake_marker() {
	local repo_slug="$1"
	local pr_number="$2"
	printf '<!-- aidevops:dependabot-pr-intake repo=%s pr=%s -->' "$repo_slug" "$pr_number"
	return 0
}

_pulse_dependabot_existing_intake_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local issues_json="[]"

	issues_json=$(gh_issue_list --repo "$repo_slug" --state open \
		--search "Dependabot PR #${pr_number} in:title" --limit 20 \
		--json number,body,url 2>/dev/null) || return 1
	printf '%s' "$issues_json" | jq -r --arg marker "$marker" \
		'[.[] | select((.body // "") | contains($marker))][0].url // ""' 2>/dev/null
	return $?
}

_pulse_dependabot_intake_body() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_sha="$3"
	local reason="$4"
	local marker="$5"

	cat <<-EOF
		## Dependabot PR worker intake

		Pulse verified GitHub's live Dependabot Bot identity, same-repository head ownership,
		the exact observed head, and Dependabot commit authorship. Automated merge did not
		proceed because: **${reason}**.

		Source PR: https://github.com/${repo_slug}/pull/${pr_number}
		Observed head: \`${head_sha}\`

		### Worker objective

		Inspect the dependency update and terminal checks, reproduce relevant failures, and
		deliver the smallest safe replacement or repair PR. If the source PR is safe but only
		outside the maintained trust policy, update the narrow policy with evidence. If the
		update is unsafe or intentionally deferred, apply an explicit maintainer-review hold
		with rationale. Close or supersede the source PR only after preserving this evidence.

		### Files and patterns

		Start from the source PR diff. Dependency manifests, lockfiles, workflow references,
		and exact failing test paths are intentionally unknown until inspection. Follow the
		trusted boundary in \`.agents/scripts/trusted-dependabot-lib.sh\` and the repair-routing
		pattern in \`.agents/scripts/pulse-merge-process.sh::_route_pr_to_fix_worker\`.

		### Verification

		Run the dependency ecosystem's targeted install, typecheck, tests, and security checks;
		then run repository-required checks for changed files. Verify the source PR is merged,
		closed as superseded, or explicitly held before completing this issue.

		${marker}
	EOF
	return 0
}

_pulse_route_dependabot_pr_to_worker_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local expected_head_sha="$4"
	local reason="${5:-policy-ineligible}"
	local marker=""
	local existing_url=""
	local temp_dir=""
	local body_file=""
	local issue_output=""

	case "$reason" in
	policy-ineligible | terminal-ci-failure | merge-conflict) ;;
	*) reason="policy-ineligible" ;;
	esac
	declare -F _is_authentic_dependabot_pr >/dev/null 2>&1 || return 1
	declare -F gh_create_issue >/dev/null 2>&1 || return 1
	declare -F gh_issue_list >/dev/null 2>&1 || return 1
	marker=$(_pulse_dependabot_intake_marker "$repo_slug" "$pr_number") || return 1
	existing_url=$(_pulse_dependabot_existing_intake_issue "$pr_number" "$repo_slug" "$marker") || return 1
	if [[ -n "$existing_url" ]]; then
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: existing worker issue ${existing_url}" >>"$LOGFILE"
		return 0
	fi
	_is_authentic_dependabot_pr "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha" || return 1
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-dependabot-intake] DRY-RUN: authentic PR #${pr_number} in ${repo_slug} would route ${reason} to a worker issue" >>"$LOGFILE"
		return 0
	fi

	temp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_dir" 2>/dev/null || return 1
	body_file=$(mktemp "${temp_dir}/dependabot-intake.XXXXXX") || return 1
	_pulse_dependabot_intake_body "$pr_number" "$repo_slug" "$expected_head_sha" "$reason" "$marker" >"$body_file" || {
		rm -f "$body_file"
		return 1
	}
	issue_output=$(gh_create_issue --repo "$repo_slug" \
		--title "Dependabot PR #${pr_number} requires worker resolution" \
		--body-file "$body_file" \
		--label "auto-dispatch,origin:worker,tier:standard,dependencies" 2>&1) || {
		local create_rc=$?
		rm -f "$body_file"
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: worker issue creation failed" >>"$LOGFILE"
		return "$create_rc"
	}
	rm -f "$body_file"
	echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: routed ${reason} to ${issue_output}" >>"$LOGFILE"
	return 0
}
