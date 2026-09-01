#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-current-state-helper.sh — current pulse productivity snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

_usage() {
	cat <<'EOF'
Usage: pulse-current-state-helper.sh [--window 15m] [--repo-path PATH] [--log-dir DIR] [--json]

Summarizes current-state pulse evidence from recent dispatch stages, worker
metrics, pulse counters, pulse wrapper log activity, and worker worktrees.
EOF
	return 0
}

_seconds() {
	local value="$1"
	case "$value" in
		*m) printf '%s\n' "$((${value%m} * 60))" ;;
		*h) printf '%s\n' "$((${value%h} * 3600))" ;;
		*) printf '%s\n' "$value" ;;
	esac
	return 0
}

_state_file_json() {
	local path="$1"
	if [[ -f "$path" ]]; then
		local content=""
		content=$(cat "$path" 2>/dev/null) || content="{}"
		if printf '%s' "$content" | jq empty >/dev/null 2>&1; then
			printf '%s\n' "$content"
			return 0
		fi
	fi
	printf '{}\n'
	return 0
}

_observability_overlay_json() {
	local nmr_state_file="${AIDEVOPS_NMR_REVALIDATION_STATE_FILE:-${HOME}/.aidevops/cache/nmr-revalidation-state.json}"
	local family_state_file="${PULSE_CHECK_FAILURE_FAMILY_STATE_FILE:-${HOME}/.aidevops/cache/failure-family-remediation.json}"
	local nmr_state="{}"
	local family_state="{}"
	nmr_state=$(_state_file_json "$nmr_state_file")
	family_state=$(_state_file_json "$family_state_file")
	jq -n --argjson nmr "$nmr_state" --argjson families "$family_state" '
		($nmr.entries // {} | [.[]]) as $entries
		| {
			nmr_revalidation: {
				total: ($entries | length),
				reason_counts: (reduce $entries[] as $entry ({}; .[$entry.code // "authority"] += 1)),
				status_counts: (reduce $entries[] as $entry ({}; .[$entry.status // "unknown"] += 1)),
				temporary_count: ([$entries[] | select(.class == "temporary")] | length),
				genuine_authority_count: ([$entries[] | select(.class == "genuine-authority")] | length),
				oldest_age_seconds: ([$entries[] | try (now - (.label_at | fromdateiso8601) | floor) catch empty] | if length > 0 then max else 0 end)
			},
			failure_family_remediation: {
				updated_at: ($families.updated_at // null),
				families: [($families.families // [])[] | {fingerprint, family, count, recent_count, confidence, recovery_outcome}],
				recurrent_count: ([($families.families // [])[] | select((.count // 0) >= 3)] | length),
				recovery_candidate_count: ([($families.families // [])[] | select((.count // 0) == 0 and (.recent_count // 0) == 0)] | length)
			}
		}'
	return 0
}

_active_claim_state_json() {
	local log_dir="$1"
	local active_workers="$2"
	local pulse_log="${log_dir}/pulse-wrapper.log"
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	if [[ ! -f "$pulse_log" ]]; then
		jq -n --argjson active "$active_workers" '{active_workers:$active, classification_counts:{}, zero_worker_actionable:false}'
		return 0
	fi

	local counts="{}"
	counts=$(awk '
		/Instance lock acquired/ {
			delete count
			next
		}
		/ACTIVE_CLAIM_STATE classification=/ || /DISPATCH_BLOCK_REASON reason=dedup_active_claim_/ {
			line = $0
			if (match(line, /classification=[a-z_]+/)) {
				key = substr(line, RSTART + 15, RLENGTH - 15)
			} else if (match(line, /reason=dedup_active_claim_[a-z_]+/)) {
				key = substr(line, RSTART + 26, RLENGTH - 26)
			} else {
				next
			}
			count[key]++
		}
		END {
			printf "{"
			separator = ""
			for (key in count) {
				printf "%s\"%s\":%d", separator, key, count[key]
				separator = ","
			}
			printf "}"
		}
	' "$pulse_log" 2>/dev/null) || counts="{}"
	printf '%s' "$counts" | jq --argjson active "$active_workers" '
		. as $counts
		| (["stale_owner", "zero_attempt", "current_cycle", "current_cycle_duplicate", "zero_worker_infrastructure_hold", "unverified"]
			| map($counts[.] // 0) | add) as $actionable
		| {
			active_workers: $active,
			classification_counts: $counts,
			zero_worker_actionable: ($active == 0 and $actionable > 0),
			live_owner_count: ($counts.live_owner // 0),
			durable_launch_count: ($counts.durable_launch // 0)
		}'
	return 0
}

main() {
	local window="15m"
	local repo_path="${AIDEVOPS_REPO_PATH:-$HOME/Git/aidevops}"
	local log_dir="${AIDEVOPS_LOG_DIR:-$HOME/.aidevops/logs}"
	local review_thread_state_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR:-$HOME/.aidevops/.agent-workspace/pr-review-thread-response}"
	local active_worker_processes=""
	local worker_worktree_count="0"
	local graphql_budget_status=""
	local runtime_state_file=""
	local objective_state_file="${AIDEVOPS_OBJECTIVE_STATE_FILE:-$HOME/.aidevops/state/objective-reconciliation.json}"
	local as_json=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--window) [[ $# -gt 0 ]] || { printf 'ERROR: --window requires a value\n' >&2; return 2; }; local value="$1"; window="$value"; shift ;;
			--repo-path) [[ $# -gt 0 ]] || { printf 'ERROR: --repo-path requires a value\n' >&2; return 2; }; local value="$1"; repo_path="$value"; shift ;;
			--log-dir) [[ $# -gt 0 ]] || { printf 'ERROR: --log-dir requires a value\n' >&2; return 2; }; local value="$1"; log_dir="$value"; shift ;;
			--json) as_json=1 ;;
			--help|-h) _usage; return 0 ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	local window_s
	window_s="$(_seconds "$window")"
	if [[ -f "${SCRIPT_DIR}/worker-lifecycle-common.sh" ]]; then
		# Keep worker process discovery in the shell lifecycle helper so Python
		# static-analysis checks do not flag a subprocess bridge for this metric.
		# shellcheck source=.agents/scripts/worker-lifecycle-common.sh
		source "${SCRIPT_DIR}/worker-lifecycle-common.sh" >/dev/null 2>&1 || true
		if declare -F count_active_workers >/dev/null 2>&1; then
			active_worker_processes="$(count_active_workers 2>/dev/null || true)"
		fi
	fi
	if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		worker_worktree_count="$(git -C "$repo_path" worktree list 2>/dev/null \
			| grep -Ec 'feature/(auto-|gh-)' || true)"
	fi
	if [[ -x "${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh" ]]; then
		graphql_budget_status="$("${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh" \
			status --cached 2>/dev/null || true)"
	fi
	runtime_state_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-pulse-runtime-state.XXXXXX") || runtime_state_file=""
	local projection_status=0
	local projection_output=""
	projection_output=$(
		AIDEVOPS_ACTIVE_WORKER_PROCESSES="$active_worker_processes" \
			AIDEVOPS_WORKER_WORKTREE_COUNT="$worker_worktree_count" \
			AIDEVOPS_GRAPHQL_BUDGET_STATUS="$graphql_budget_status" \
			AIDEVOPS_OBJECTIVE_STATE_FILE="$objective_state_file" \
			AIDEVOPS_RUNTIME_STATE_OUTPUT="$runtime_state_file" \
			python3 "${SCRIPT_DIR}/pulse-current-state.py" \
				"$log_dir" "$repo_path" "$window_s" "$as_json" "$SCRIPT_DIR" \
				"$review_thread_state_dir"
	) || projection_status=$?
	local overlay_json="{}"
	overlay_json=$(_observability_overlay_json)
	local active_claim_json="{}"
	active_claim_json=$(_active_claim_state_json "$log_dir" "$active_worker_processes")
	if [[ "$projection_status" -eq 0 && "$as_json" -eq 1 ]] && printf '%s' "$projection_output" | jq empty >/dev/null 2>&1; then
		projection_output=$(jq -n --argjson base "$projection_output" --argjson overlay "$overlay_json" --argjson claims "$active_claim_json" '
			($base.pre_launch_blockers.dedup_active_claim // 0) as $legacy_claims
			| ($claims.classification_counts.unverified // 0) as $classified_unverified
			| ($claims
				| .classification_counts.unverified = ([$legacy_claims, $classified_unverified] | max)
				| .zero_worker_actionable = (.zero_worker_actionable or (.active_workers == 0 and $legacy_claims > 0))) as $enriched_claims
			| $base + $overlay + {active_claim_state:$enriched_claims}')
	elif [[ "$projection_status" -eq 0 ]]; then
		projection_output+=$'\n'
		projection_output+="NMR revalidation: $(printf '%s' "$overlay_json" | jq -c '.nmr_revalidation')"
		projection_output+=$'\n'
		projection_output+="Failure-family remediation: $(printf '%s' "$overlay_json" | jq -c '.failure_family_remediation')"
		projection_output+=$'\n'
		projection_output+="Active claim state: $(printf '%s' "$active_claim_json" | jq -c '.')"
	fi
	printf '%s\n' "$projection_output"
	if [[ "$projection_status" -eq 0 && -s "$runtime_state_file" ]] && command -v node >/dev/null 2>&1; then
		local runtime_tmp=""
		runtime_tmp=$(mktemp "${TMPDIR:-/tmp}/aidevops-pulse-runtime-overlay.XXXXXX") || runtime_tmp=""
		if [[ -n "$runtime_tmp" ]] && jq --argjson overlay "$overlay_json" '. + {
			nmr_revalidation: $overlay.nmr_revalidation,
			failure_family_remediation: {
				recurrent_count: $overlay.failure_family_remediation.recurrent_count,
				recovery_candidate_count: $overlay.failure_family_remediation.recovery_candidate_count
			}
		}' "$runtime_state_file" >"$runtime_tmp" 2>/dev/null; then
			mv "$runtime_tmp" "$runtime_state_file"
		else
			rm -f "$runtime_tmp" 2>/dev/null || true
		fi
		node "${SCRIPT_DIR}/runtime-events.mjs" state auto "pulse:current" - <"$runtime_state_file" \
			>/dev/null 2>&1 || true
	fi
	rm -f "$runtime_state_file" 2>/dev/null || true
	return "$projection_status"
}

main "$@"
