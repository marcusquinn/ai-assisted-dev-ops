#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pr-drain-helper.sh — rank open PRs for maintainer-directed backlog drains.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REVIEW_GATE_HELPER="${REVIEW_GATE_HELPER:-${SCRIPT_DIR}/review-bot-gate-helper.sh}"
BASELINE_CHECK_REGEX="${PR_DRAIN_BASELINE_CHECK_REGEX:-}"
readonly CATEGORY_BLOCKED="blocked"
readonly CATEGORY_MERGEABLE="mergeable"
readonly CATEGORY_CONFLICT_ONLY="conflict-only"
readonly STATE_ERROR="err""or"

usage() {
	cat <<'EOF'
Usage: pr-drain-helper.sh [REPO] [--limit N] [--json]

Lists open PRs and ranks each as mergeable, conflict-only, superseded/stale, or blocked.
Default mode is read-only and prints next commands; it never pushes or merges.

Environment:
  PR_DRAIN_BASELINE_CHECK_REGEX  Regex for known baseline-red check names.
EOF
	return 0
}

json_escape() {
	local value="$1"
	if command -v jq >/dev/null 2>&1; then
		jq -Rn --arg value "$value" '$value'
		return 0
	fi
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	printf '"%s"' "$value"
	return 0
}

resolve_repo() {
	local repo="$1"
	if [[ -n "$repo" ]]; then
		printf '%s\n' "$repo"
		return 0
	fi
	gh repo view --json nameWithOwner -q '.nameWithOwner'
	return 0
}

label_names() {
	local pr_json="$1"
	jq -r '[.labels[]?.name] | join(" ")' <<<"$pr_json"
	return 0
}

failed_checks() {
	local pr_json="$1"
	jq -r '
    [.statusCheckRollup[]? |
      . as $check |
      ($check.name // $check.context // "unknown") as $name |
      ($check.conclusion // $check.state // $check.status // "") as $state |
      select(($state | ascii_downcase) as $s | ($s == "failure" or $s == "failed" or $s == "error" or $s == "timed_out" or $s == "action_required" or $s == "cancelled")) |
      $name] | join("|")
  ' <<<"$pr_json"
	return 0
}

pending_checks() {
	local pr_json="$1"
	jq -r '
    [.statusCheckRollup[]? |
      . as $check |
      ($check.name // $check.context // "unknown") as $name |
      ($check.conclusion // $check.state // $check.status // "") as $state |
      select(($state | ascii_downcase) as $s | ($s == "pending" or $s == "queued" or $s == "in_progress" or $s == "requested" or $s == "waiting" or $s == "expected")) |
      $name] | join("|")
  ' <<<"$pr_json"
	return 0
}

all_failures_are_baseline() {
	local failures="$1"
	local regex="$2"
	local check=""

	[[ -n "$failures" && -n "$regex" ]] || return 1
	while IFS= read -r check; do
		[[ -z "$check" ]] && continue
		if ! [[ "$check" =~ $regex ]]; then
			return 1
		fi
	done < <(tr '|' '\n' <<<"$failures")
	return 0
}

review_gate_status() {
	local pr_number="$1"
	local repo="$2"
	if [[ -x "$REVIEW_GATE_HELPER" ]]; then
		"$REVIEW_GATE_HELPER" status-json "$pr_number" "$repo" 2>/dev/null || true
		return 0
	fi
	jq -nc --arg status "ERROR" --arg state "$STATE_ERROR" --arg merge_gate "$CATEGORY_BLOCKED" \
		'{status:$status,state:$state,merge_gate:$merge_gate,exit_code:2}'
	return 0
}

classify_pr() {
	local pr_json="$1"
	local repo="$2"
	local number title cross_repo draft merge_state mergeable review_decision labels failures pending gate_json gate_state category reason rank

	number=$(jq -r '.number' <<<"$pr_json")
	title=$(jq -r '.title // ""' <<<"$pr_json")
	cross_repo=$(jq -r '.isCrossRepository // false' <<<"$pr_json")
	draft=$(jq -r '.isDraft // false' <<<"$pr_json")
	merge_state=$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$pr_json")
	mergeable=$(jq -r '.mergeable // "UNKNOWN"' <<<"$pr_json")
	review_decision=$(jq -r '.reviewDecision // ""' <<<"$pr_json")
	labels=$(label_names "$pr_json")
	failures=$(failed_checks "$pr_json")
	pending=$(pending_checks "$pr_json")
	gate_json=$(review_gate_status "$number" "$repo")
	gate_state=$(jq -r --arg fallback "$STATE_ERROR" '.state // $fallback' <<<"$gate_json")

	category="$CATEGORY_BLOCKED"
	reason="unclassified"
	rank=90

	if [[ "$labels" =~ (^|[[:space:]])(superseded|stale)([[:space:]]|$) ]]; then
		category="superseded/stale"
		reason="label indicates superseded or stale"
		rank=70
	elif [[ "$cross_repo" == "true" ]]; then
		category="$CATEGORY_BLOCKED"
		reason="fork PR; do not use admin drain flow"
		rank=80
	elif [[ "$draft" == "true" ]]; then
		category="$CATEGORY_BLOCKED"
		reason="draft PR"
		rank=81
	elif [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
		category="$CATEGORY_BLOCKED"
		reason="human changes requested"
		rank=82
	elif [[ "$gate_state" != "pass" ]]; then
		category="$CATEGORY_BLOCKED"
		reason="review-bot gate ${gate_state}"
		rank=83
	elif [[ "$mergeable" == "CONFLICTING" || "$merge_state" == "DIRTY" ]]; then
		category="$CATEGORY_CONFLICT_ONLY"
		reason="merge conflict; resolve only concrete conflicts"
		rank=20
	elif [[ -n "$pending" ]]; then
		category="$CATEGORY_BLOCKED"
		reason="checks pending: ${pending}"
		rank=84
	elif [[ -n "$failures" ]]; then
		if all_failures_are_baseline "$failures" "$BASELINE_CHECK_REGEX"; then
			category="$CATEGORY_MERGEABLE"
			reason="only configured baseline-red checks failing: ${failures}"
			rank=10
		else
			category="$CATEGORY_BLOCKED"
			reason="PR-specific or unknown failing checks: ${failures}"
			rank=85
		fi
	elif [[ "$merge_state" == "CLEAN" || "$merge_state" == "HAS_HOOKS" || "$mergeable" == "MERGEABLE" ]]; then
		category="$CATEGORY_MERGEABLE"
		reason="same-repo, non-draft, bot gate clear, no failing checks"
		rank=1
	else
		category="$CATEGORY_BLOCKED"
		reason="merge state ${merge_state}/${mergeable} needs inspection"
		rank=86
	fi

	jq -nc \
		--argjson rank "$rank" \
		--argjson number "$number" \
		--arg title "$title" \
		--arg category "$category" \
		--arg reason "$reason" \
		--argjson review_gate "$gate_json" \
		'{rank:$rank,number:$number,title:$title,category:$category,reason:$reason,review_gate:$review_gate}'
	return 0
}

print_next_commands() {
	local repo="$1"
	local number="$2"
	local category="$3"

	printf '    bot gate: review-bot-gate-helper.sh check %s %s\n' "$number" "$repo"
	case "$category" in
	"$CATEGORY_MERGEABLE")
		printf '    merge:    full-loop-helper.sh merge %s %s --admin --squash\n' "$number" "$repo"
		;;
	"$CATEGORY_CONFLICT_ONLY")
		printf '    worktree: worktree-helper.sh add feature/pr-drain-%s-%s --base origin/main\n' "$number" "$(basename "$repo")"
		printf '    checkout: gh pr checkout %s --repo %s\n' "$number" "$repo"
		printf '    push:     git push\n'
		printf '    merge:    full-loop-helper.sh merge %s %s --admin --squash\n' "$number" "$repo"
		;;
	*)
		printf '    inspect:  gh pr view %s --repo %s --json isCrossRepository,isDraft,mergeStateStatus,files,statusCheckRollup\n' "$number" "$repo"
		;;
	esac
	return 0
}

print_human() {
	local repo="$1"
	local classified="$2"
	local line number title category reason

	printf 'PR drain candidates for %s (read-only)\n\n' "$repo"
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		number=$(jq -r '.number' <<<"$line")
		title=$(jq -r '.title' <<<"$line")
		category=$(jq -r '.category' <<<"$line")
		reason=$(jq -r '.reason' <<<"$line")
		printf '#%s [%s] %s\n' "$number" "$category" "$title"
		printf '    reason:   %s\n' "$reason"
		print_next_commands "$repo" "$number" "$category"
		printf '\n'
	done <<<"$classified"
	return 0
}

main() {
	local repo_arg=""
	local limit="30"
	local json_mode="0"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--limit)
			limit="${2:-}"
			shift 2
			;;
		--json)
			json_mode="1"
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			repo_arg="$arg"
			shift
			;;
		esac
	done

	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		printf 'ERROR: --limit must be numeric\n' >&2
		return 2
	fi

	local repo pr_numbers classified pr_number pr_json row
	repo=$(resolve_repo "$repo_arg")
	pr_numbers=$(gh pr list --repo "$repo" --state open --limit "$limit" --json number --jq '.[].number')
	classified=""
	while IFS= read -r pr_number; do
		[[ -z "$pr_number" ]] && continue
		pr_json=$(gh pr view "$pr_number" --repo "$repo" --json number,title,isCrossRepository,isDraft,mergeStateStatus,mergeable,reviewDecision,headRefName,baseRefName,author,statusCheckRollup,labels,updatedAt)
		row=$(classify_pr "$pr_json" "$repo")
		classified="${classified}${row}"$'\n'
	done <<<"$pr_numbers"

	classified=$(printf '%s' "$classified" | jq -s -c 'sort_by(.rank, .number)[]')
	if [[ "$json_mode" == "1" ]]; then
		printf '%s\n' "$classified" | jq -s '{prs: .}'
		return 0
	fi
	print_human "$repo" "$classified"
	return 0
}

main "$@"
