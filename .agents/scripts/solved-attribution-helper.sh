#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Report and safely backfill solved:* completion attribution from merged PRs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

SAH_REPO=""
SAH_SINCE=""
SAH_LIMIT=100
SAH_APPLY=0
SAH_JSON=0
SAH_MIN_COVERAGE=""

_sah_usage() {
	printf '%s\n' \
		'Usage: solved-attribution-helper.sh report|backfill [options]' \
		'' \
		'Options:' \
		'  --repo OWNER/REPO       Repository (defaults to current repository)' \
		'  --since YYYY-MM-DD      Closed-at lower bound (default: 30 days ago)' \
		'  --limit N               Backfill candidate limit (default: 100)' \
		'  --apply                 Apply labels; backfill is dry-run by default' \
		'  --json                  Emit report as JSON' \
		'  --min-coverage PERCENT  Fail report when coverage is below threshold'
	return 0
}

_sah_default_since() {
	if date -u -v-30d +%Y-%m-%d >/dev/null 2>&1; then
		date -u -v-30d +%Y-%m-%d
	else
		date -u -d '30 days ago' +%Y-%m-%d
	fi
	return 0
}

_sah_resolve_repo() {
	if [[ -n "$SAH_REPO" ]]; then
		return 0
	fi
	SAH_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || SAH_REPO=""
	[[ -n "$SAH_REPO" ]] || return 1
	return 0
}

_sah_parse_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			SAH_REPO="${2:-}"
			shift 2
			;;
		--since)
			SAH_SINCE="${2:-}"
			shift 2
			;;
		--limit)
			SAH_LIMIT="${2:-}"
			shift 2
			;;
		--apply)
			SAH_APPLY=1
			shift
			;;
		--json)
			SAH_JSON=1
			shift
			;;
		--min-coverage)
			SAH_MIN_COVERAGE="${2:-}"
			shift 2
			;;
		-h | --help)
			_sah_usage
			exit 0
			;;
		*)
			printf 'Unknown option: %s\n' "$1" >&2
			return 1
			;;
		esac
	done
	[[ "$SAH_LIMIT" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ -z "$SAH_SINCE" || "$SAH_SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
	[[ -z "$SAH_MIN_COVERAGE" || "$SAH_MIN_COVERAGE" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
	return 0
}

_sah_completion_search() {
	local since="$1"
	printf 'closed:>=%s -label:duplicate -label:not-planned -label:already-fixed -label:wontfix' "$since"
	return 0
}

_sah_count_issues() {
	local search_query="$1"
	local payload=""
	payload=$(gh issue list --repo "$SAH_REPO" --state closed --search "$search_query" \
		--limit 1000 --json number 2>/dev/null) || return 1
	printf '%s' "$payload" | jq -er 'if type == "array" then length else error("invalid issue list") end'
	return $?
}

_sah_report() {
	local base_search="$1"
	local worker_count=0 interactive_count=0 conflict_count=0 missing_count=0 attributed_count=0 population=0
	worker_count=$(_sah_count_issues "${base_search} label:solved:worker -label:solved:interactive") || return 1
	interactive_count=$(_sah_count_issues "${base_search} label:solved:interactive -label:solved:worker") || return 1
	conflict_count=$(_sah_count_issues "${base_search} label:solved:worker label:solved:interactive") || return 1
	missing_count=$(_sah_count_issues "${base_search} -label:solved:worker -label:solved:interactive") || return 1
	attributed_count=$((worker_count + interactive_count))
	population=$((attributed_count + conflict_count + missing_count))

	local coverage="0.00"
	if [[ "$population" -gt 0 ]]; then
		coverage=$(awk -v attributed="$attributed_count" -v population="$population" \
			'BEGIN { printf "%.2f", (attributed * 100) / population }')
	fi
	local capped=false
	if [[ "$worker_count" -ge 1000 || "$interactive_count" -ge 1000 || "$conflict_count" -ge 1000 || "$missing_count" -ge 1000 ]]; then
		capped=true
	fi

	if [[ "$SAH_JSON" -eq 1 ]]; then
		jq -n --arg repo "$SAH_REPO" --arg since "$SAH_SINCE" --argjson worker "$worker_count" \
			--argjson interactive "$interactive_count" --argjson conflicting "$conflict_count" --argjson missing "$missing_count" \
			--argjson coverage "$coverage" --argjson capped "$capped" \
			'{repo:$repo,since:$since,solved_worker:$worker,solved_interactive:$interactive,conflicting:$conflicting,unattributed:$missing,coverage_percent:$coverage,capped:$capped}'
	else
		printf 'Solved attribution coverage for %s since %s\n' "$SAH_REPO" "$SAH_SINCE"
		printf '  solved:worker      %d\n' "$worker_count"
		printf '  solved:interactive %d\n' "$interactive_count"
		printf '  conflicting        %d\n' "$conflict_count"
		printf '  unattributed       %d\n' "$missing_count"
		printf '  coverage           %s%%\n' "$coverage"
		[[ "$capped" == true ]] && printf '  warning            one or more counts reached the 1000-result GitHub cap\n'
	fi

	if [[ -n "$SAH_MIN_COVERAGE" ]] && awk -v actual="$coverage" -v minimum="$SAH_MIN_COVERAGE" \
		'BEGIN { exit !(actual < minimum) }'; then
		printf 'Coverage %s%% is below required %s%%\n' "$coverage" "$SAH_MIN_COVERAGE" >&2
		return 1
	fi
	return 0
}

_sah_backfill_one() {
	local issue_json="$1"
	local issue_num="" state_reason="" pr_count=0 pr_num=""
	issue_num=$(printf '%s' "$issue_json" | jq -r '.number // empty')
	state_reason=$(printf '%s' "$issue_json" | jq -r '.stateReason // empty')
	pr_count=$(printf '%s' "$issue_json" | jq -r '[.closedByPullRequestsReferences[]?] | length')
	[[ "$issue_num" =~ ^[0-9]+$ && "$state_reason" == "COMPLETED" && "$pr_count" -eq 1 ]] || return 1
	pr_num=$(printf '%s' "$issue_json" | jq -r '.closedByPullRequestsReferences[0].number // empty')
	[[ "$pr_num" =~ ^[0-9]+$ ]] || return 1

	local pr_evidence="" merged_at="" pr_labels="" solved_actor=""
	pr_evidence=$(gh pr view "$pr_num" --repo "$SAH_REPO" --json mergedAt,labels \
		--jq '[.mergedAt // "", ([.labels[].name] | join(","))] | @tsv' 2>/dev/null) || return 1
	merged_at="${pr_evidence%%$'\t'*}"
	pr_labels="${pr_evidence#*$'\t'}"
	[[ -n "$merged_at" && "$pr_evidence" == *$'\t'* ]] || return 1
	solved_actor=$(solved_actor_from_pr_labels "$pr_labels") || return 1

	if [[ "$SAH_APPLY" -eq 1 ]]; then
		set_solved_label "$issue_num" "$SAH_REPO" "$solved_actor" || return 1
		printf 'Applied solved:%s to issue #%s from merged PR #%s\n' "$solved_actor" "$issue_num" "$pr_num"
	else
		printf '[DRY-RUN] issue #%s <- solved:%s from merged PR #%s\n' "$issue_num" "$solved_actor" "$pr_num"
	fi
	return 0
}

_sah_backfill() {
	local base_search="$1"
	local candidates=""
	candidates=$(gh issue list --repo "$SAH_REPO" --state closed \
		--search "${base_search} -label:solved:worker -label:solved:interactive" \
		--limit "$SAH_LIMIT" --json number,stateReason,closedByPullRequestsReferences 2>/dev/null) || return 1

	local applied=0 skipped=0 issue_json=""
	while IFS= read -r issue_json; do
		[[ -n "$issue_json" ]] || continue
		if _sah_backfill_one "$issue_json"; then
			applied=$((applied + 1))
		else
			skipped=$((skipped + 1))
		fi
	done < <(printf '%s' "$candidates" | jq -c '.[]')
	printf 'Backfill %s: attributable=%d skipped_or_ambiguous=%d\n' \
		"$([[ "$SAH_APPLY" -eq 1 ]] && printf 'applied' || printf 'dry-run')" "$applied" "$skipped"
	return 0
}

main() {
	local command="${1:-}"
	[[ -n "$command" ]] && shift || true
	case "$command" in
	report | backfill) ;;
	help | -h | --help | "")
		_sah_usage
		return 0
		;;
	*)
		printf 'Unknown command: %s\n' "$command" >&2
		return 1
		;;
	esac

	_sah_parse_options "$@" || return 1
	_sah_resolve_repo || return 1
	[[ -n "$SAH_SINCE" ]] || SAH_SINCE=$(_sah_default_since)
	local base_search=""
	base_search=$(_sah_completion_search "$SAH_SINCE")
	case "$command" in
	report) _sah_report "$base_search" ;;
	backfill) _sah_backfill "$base_search" ;;
	esac
	return $?
}

main "$@"
