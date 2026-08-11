#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
#
# pulse-check-helper.sh — bounded pulse/worker utilisation diagnostics.
#
# This helper combines the canonical current-state and worker outcome ledgers
# with a privacy-preserving scan of repos.json auto-dispatch issues. It is safe
# for interactive diagnosis and for a daily self-improvement routine because
# --apply files only deduplicated, aggregate framework issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

CURRENT_STATE_HELPER="${PULSE_CHECK_CURRENT_STATE_HELPER:-${SCRIPT_DIR}/pulse-current-state-helper.sh}"
WORKER_ACTIVITY_HELPER="${PULSE_CHECK_WORKER_ACTIVITY_HELPER:-${SCRIPT_DIR}/worker-activity-helper.sh}"
RUNNER_HEALTH_HELPER="${PULSE_CHECK_RUNNER_HEALTH_HELPER:-${SCRIPT_DIR}/pulse-runner-health-helper.sh}"
PULSE_DIAGNOSE_HELPER="${PULSE_CHECK_PULSE_DIAGNOSE_HELPER:-${SCRIPT_DIR}/pulse-diagnose-helper.sh}"
GH_WRAPPERS="${PULSE_CHECK_GH_WRAPPERS:-${SCRIPT_DIR}/shared-gh-wrappers.sh}"
REPORT_FILTER="${PULSE_CHECK_REPORT_FILTER:-${SCRIPT_DIR}/pulse-check-report.jq}"
QUEUE_SCANNER="${PULSE_CHECK_QUEUE_SCANNER:-${SCRIPT_DIR}/pulse-check-queue-scan.py}"
REPOS_JSON="${PULSE_CHECK_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
PULSE_HEALTH_FILE="${PULSE_CHECK_PULSE_HEALTH_FILE:-${HOME}/.aidevops/logs/pulse-health.json}"

COMMAND="report"
WINDOW="15m"
SINCE="24h"
RECENT_SINCE="1h"
APPLY_REPO="${PULSE_CHECK_APPLY_REPO:-}"
JSON_OUTPUT=0
APPLY_MODE=0
MAX_ISSUES_PER_REPO="${PULSE_CHECK_MAX_ISSUES_PER_REPO:-100}"
AVAILABLE_THRESHOLD="${PULSE_CHECK_AVAILABLE_THRESHOLD:-3}"
OLD_AVAILABLE_MINUTES="${PULSE_CHECK_OLD_AVAILABLE_MINUTES:-30}"
NMR_INACTIVE_MINUTES="${PULSE_CHECK_NMR_INACTIVE_MINUTES:-10080}"
FAILURE_FAMILY_THRESHOLD="${PULSE_CHECK_FAILURE_FAMILY_THRESHOLD:-3}"
FAILURE_FAMILY_RECOVERY_SECONDS="${PULSE_CHECK_FAILURE_FAMILY_RECOVERY_SECONDS:-86400}"
FAILURE_FAMILY_STATE_FILE="${PULSE_CHECK_FAILURE_FAMILY_STATE_FILE:-${HOME}/.aidevops/cache/failure-family-remediation.json}"
FAILURE_FAMILY_STATUS_RECURRING="recurring"
PULSE_CHECK_LABELS_ENSURED=""

_usage() {
	cat <<EOF
Usage: $(basename "$0") [report|json|apply|help] [options]

Options:
  --window <15m|30m|1h>       Current-state window (default: ${WINDOW})
  --since <1h|6h|24h|48h|7d> Historical worker summary window (default: ${SINCE})
  --recent <1h|6h|24h>       Recent worker outcome window (default: ${RECENT_SINCE})
  --repo <owner/repo>        Repo for --apply self-improvement issues
  --max-issues <N>           Per-repo auto-dispatch issue scan limit (default: ${MAX_ISSUES_PER_REPO})
  --available-threshold <N>  Queue depth threshold for underfill findings (default: ${AVAILABLE_THRESHOLD})
  --old-available-minutes <N> Age threshold for stale available queue counts (default: ${OLD_AVAILABLE_MINUTES})
  --nmr-inactive-minutes <N> Issue inactivity threshold for aggregate NMR advisories (default: ${NMR_INACTIVE_MINUTES})
  --failure-family-threshold <N> Distinct recurrent family threshold (default: ${FAILURE_FAMILY_THRESHOLD})
  --json                     Emit JSON report
  --apply                    File deduplicated self-improvement issues for autofile findings
  --help                     Show this help

Subcommands:
  report  Human-readable diagnostics (default)
  json    Machine-readable diagnostics
  apply   Human-readable diagnostics plus deduplicated issue creation
EOF
	return 0
}

_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local next="${2:-}"
		case "$arg" in
		report) COMMAND="report"; shift ;;
		json) COMMAND="json"; JSON_OUTPUT=1; shift ;;
		apply) COMMAND="apply"; APPLY_MODE=1; shift ;;
		--window) WINDOW="$next"; shift 2 ;;
		--since) SINCE="$next"; shift 2 ;;
		--recent) RECENT_SINCE="$next"; shift 2 ;;
		--repo) APPLY_REPO="$next"; shift 2 ;;
		--max-issues) MAX_ISSUES_PER_REPO="$next"; shift 2 ;;
		--available-threshold) AVAILABLE_THRESHOLD="$next"; shift 2 ;;
		--old-available-minutes) OLD_AVAILABLE_MINUTES="$next"; shift 2 ;;
		--nmr-inactive-minutes) NMR_INACTIVE_MINUTES="$next"; shift 2 ;;
		--failure-family-threshold) FAILURE_FAMILY_THRESHOLD="$next"; shift 2 ;;
		--json) JSON_OUTPUT=1; shift ;;
		--apply) APPLY_MODE=1; shift ;;
		help|--help|-h) _usage; exit 0 ;;
		*) print_warning "pulse-check: unknown argument: ${arg}"; _usage; exit 1 ;;
		esac
	done
	return 0
}

_validate_numeric_options() {
	[[ "$MAX_ISSUES_PER_REPO" =~ ^[0-9]+$ ]] || MAX_ISSUES_PER_REPO=100
	[[ "$AVAILABLE_THRESHOLD" =~ ^[0-9]+$ ]] || AVAILABLE_THRESHOLD=3
	[[ "$OLD_AVAILABLE_MINUTES" =~ ^[0-9]+$ ]] || OLD_AVAILABLE_MINUTES=30
	[[ "$NMR_INACTIVE_MINUTES" =~ ^[0-9]+$ ]] || NMR_INACTIVE_MINUTES=10080
	[[ "$FAILURE_FAMILY_THRESHOLD" =~ ^[0-9]+$ ]] || FAILURE_FAMILY_THRESHOLD=3
	[[ "$FAILURE_FAMILY_RECOVERY_SECONDS" =~ ^[0-9]+$ ]] || FAILURE_FAMILY_RECOVERY_SECONDS=86400
	return 0
}

_run_json_helper() {
	local fallback_json="$1"
	shift

	local output=""
	local rc=0
	output=$("$@" 2>/dev/null) || rc=$?
	if [[ "$rc" -ne 0 || -z "$output" ]] || ! printf '%s' "$output" | jq empty >/dev/null 2>&1; then
		printf '%s\n' "$fallback_json"
		return 0
	fi
	printf '%s\n' "$output"
	return 0
}

_scan_auto_dispatch_queue() {
	if [[ ! -f "$QUEUE_SCANNER" ]]; then
		print_error "pulse-check: queue scanner not found: ${QUEUE_SCANNER}"
		printf '{"aggregate":{"repos":0,"auto_dispatch_open":0,"available_unassigned":0,"eligible_available_unassigned":0,"available_old":0,"oldest_available_age_min":0,"repos_with_available":0,"queued":0,"assigned":0,"assigned_in_flight":0,"blocked_labels":0,"blocked_explicit_hold":0,"dependency_inconsistent_available":0,"needs_tier":0,"needs_status":0,"malformed_metadata":0,"parent_task":0,"nmr":0,"nmr_inactive":0,"oldest_nmr_inactivity_age_min":0,"nmr_inactivity_threshold_min":0,"no_auto_dispatch":0,"gh_errors":0},"error":"queue_scanner_missing"}\n'
		return 0
	fi

	PULSE_CHECK_REPOS_JSON="$REPOS_JSON" \
		PULSE_CHECK_MAX_ISSUES_PER_REPO="$MAX_ISSUES_PER_REPO" \
		PULSE_CHECK_OLD_AVAILABLE_MINUTES="$OLD_AVAILABLE_MINUTES" \
		PULSE_CHECK_NMR_INACTIVE_MINUTES="$NMR_INACTIVE_MINUTES" \
		python3 "$QUEUE_SCANNER"
	return 0
}

_collect_report_json() {
	local current_state="{}"
	local worker_summary="{}"
	local worker_recent="{}"
	local providers="{}"
	local runner_health="{}"
	local api_budget="{}"
	local queue="{}"
	local pulse_health="{}"

	current_state=$(_run_json_helper '{}' "$CURRENT_STATE_HELPER" --window "$WINDOW" --json)
	if [[ -f "$PULSE_HEALTH_FILE" ]]; then
		pulse_health=$(jq -c . "$PULSE_HEALTH_FILE" 2>/dev/null || printf '{}')
		current_state=$(printf '%s' "$current_state" | jq -c --argjson health "$pulse_health" '. + {pulse_health: $health}' 2>/dev/null || printf '%s' "$current_state")
	fi
	worker_summary=$(_run_json_helper '{}' "$WORKER_ACTIVITY_HELPER" summary --since "$SINCE" --json --no-pr-check)
	worker_recent=$(_run_json_helper '{}' "$WORKER_ACTIVITY_HELPER" summary --since "$RECENT_SINCE" --json --no-pr-check)
	providers=$(_run_json_helper '{}' "$WORKER_ACTIVITY_HELPER" providers --since "$RECENT_SINCE" --json)
	runner_health=$(_run_json_helper '{}' "$RUNNER_HEALTH_HELPER" diagnose --json)
	api_budget=$(_run_json_helper '{}' "$PULSE_DIAGNOSE_HELPER" api-budget --json)
	local skip_queue_scan="0"
	if printf '%s' "$api_budget" | jq -e '((.secondary_cooldown_state // "") | contains("active=yes"))' >/dev/null 2>&1; then
		skip_queue_scan="1"
	fi
	if [[ "$skip_queue_scan" == "1" ]]; then
		queue=$(PULSE_CHECK_SKIP_GH=1 _scan_auto_dispatch_queue)
	else
		queue=$(_scan_auto_dispatch_queue)
	fi

	if [[ ! -f "$REPORT_FILTER" ]]; then
		print_error "pulse-check: report filter not found: ${REPORT_FILTER}"
		return 1
	fi

	jq -n \
		--arg window "$WINDOW" \
		--arg since "$SINCE" \
		--arg recent "$RECENT_SINCE" \
		--argjson threshold "$AVAILABLE_THRESHOLD" \
		--argjson failure_threshold "$FAILURE_FAMILY_THRESHOLD" \
		--argjson current "$current_state" \
		--argjson summary "$worker_summary" \
		--argjson recent_summary "$worker_recent" \
		--argjson providers "$providers" \
		--argjson runner "$runner_health" \
		--argjson api "$api_budget" \
		--argjson queue "$queue" \
		-f "$REPORT_FILTER"
	return 0
}

_render_text_report() {
	local report_json="$1"
	printf '%s' "$report_json" | jq -r '
		def percent_text: if . == null then "n/a" else (. | tostring) + "%" end;
		"Pulse Check — " + .generated_at,
		"",
		"## Current utilisation",
		"- Active workers: " + (.summary.active_workers | tostring) + " / " + (.summary.max_workers | tostring) + " (available slots: " + (.summary.available_slots | tostring) + ")",
		"- Auto-dispatch queue: " + (.summary.auto_dispatch_available_unassigned | tostring) + " available (" + (.summary.auto_dispatch_eligible_available_unassigned | tostring) + " eligible) / " + (.summary.auto_dispatch_open | tostring) + " open across " + (.queue.repos | tostring) + " pulse repos",
		"- Queue scan state: " + (.summary.auto_dispatch_scan_state // "scanned"),
		"- Current window launches: " + (.summary.worker_launches_in_window | tostring) + "; terminal worker events: " + (.summary.worker_terminal_events_in_window | tostring),
		"- Recent worker metric events: " + (.summary.recent_worker_events | tostring) + "; " + .inputs.historical_window + " runtime handoff rate: " + (.summary.historical_runtime_handoff_rate | percent_text) + "; delivered success rate: " + (.summary.historical_delivery_success_rate | percent_text),
		"- GraphQL/API: " + (.summary.graphql_budget_status // "unknown"),
		"- Runner health: " + (.summary.runner_health // "unknown"),
		"",
		"## Findings",
		(if (.findings | length) == 0 then "- None above thresholds" else (.findings[] | "- [" + .severity + "] " + .title + " (`" + .id + "`) — " + .recommendation) end),
		"",
		"## Evidence commands",
		"- pulse-current-state-helper.sh --window " + .inputs.current_window + " --json",
		"- worker-activity-helper.sh summary --since " + .inputs.recent_window + " --json --no-pr-check",
		"- worker-activity-helper.sh summary --since " + .inputs.historical_window + " --json --no-pr-check",
		"- pulse-diagnose-helper.sh cycle-health --window 1h",
		"",
		"Privacy: report aggregates repos.json queue state and omits repo slugs, local paths, and issue titles."
	'
	return 0
}

_resolve_apply_repo() {
	if [[ -n "$APPLY_REPO" ]]; then
		printf '%s\n' "$APPLY_REPO"
		return 0
	fi
	gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
	return 0
}

_existing_open_issue_for_finding() {
	local slug="$1"
	local finding_id="$2"
	local marker="aidevops:generator=pulse-check finding=${finding_id}"
	gh issue list --repo "$slug" --state open --search "in:body \"${marker}\"" \
		--limit 1 --json number,url 2>/dev/null \
		| jq -r '.[0] // empty | "\(.number)\t\(.url)"' 2>/dev/null
	return 0
}

_finding_issue_body() {
	local finding_id="$1"
	local title="$2"
	local severity="$3"
	local evidence_markdown="$4"
	local recommendation="$5"
	local family_fingerprint="${6:-}"
	local family_count="${7:-0}"
	local family_recent_count="${8:-0}"

	cat <<EOF
<!-- aidevops:generator=pulse-check finding=${finding_id} -->

## Finding

${title}

Severity: ${severity}

## Evidence

${evidence_markdown}

Source commands:

- \`.agents/scripts/pulse-check-helper.sh --json\`
- \`.agents/scripts/pulse-current-state-helper.sh --window 15m --json\`
- \`.agents/scripts/worker-activity-helper.sh summary --since 1h --json --no-pr-check\`
- \`.agents/scripts/pulse-diagnose-helper.sh cycle-health --window 1h\`

## Recommendation

${recommendation}

## Implementation context

- Primary files: \`.agents/scripts/pulse-check-queue-scan.py\`, \`.agents/scripts/pulse-check-report.jq\`, \`.agents/scripts/pulse-check-helper.sh\`, and \`.agents/scripts/tests/test-pulse-check-helper.sh\`; follow related diagnostics into current-state or worker helpers only when evidence requires it.
- Reference patterns: \`.agents/reference/diagnostics-discipline.md\` and \`.agents/reference/worker-diagnostics.md\`.
- If the exact broken path differs, keep the fix in the pulse/worker diagnostics layer and update this issue with the verified file path before implementation.

## Verification

- \`.agents/scripts/tests/test-pulse-check-helper.sh\`
- \`.agents/scripts/pulse-check-helper.sh --json\` shows the finding cleared or downgraded with current evidence.
- Relevant focused tests for any touched pulse/worker helper.

Privacy note: this issue intentionally uses aggregate counts only; do not add private repo names, private basenames, local paths, or issue titles.
EOF
	if [[ -n "$family_fingerprint" ]]; then
		_failure_family_state_section "$family_fingerprint" "$family_count" "$family_recent_count" "$FAILURE_FAMILY_STATUS_RECURRING"
	fi
	return 0
}

_failure_family_state_section() {
	local fingerprint="$1"
	local count="$2"
	local recent_count="$3"
	local status="$4"
	local observed_at=""
	observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	cat <<EOF

<!-- failure-family-state:start -->
<!-- failure-family-state fingerprint=${fingerprint} count=${count} recent_count=${recent_count} status=${status} observed_at=${observed_at} -->
## Remediation outcome

- Stable fingerprint: ${fingerprint}
- Historical-window failures: ${count}
- Recent-window failures: ${recent_count}
- Outcome: ${status}

This bounded aggregate is refreshed in place; pulse does not post recurrence comments.
<!-- failure-family-state:end -->
EOF
	return 0
}

_load_gh_wrappers() {
	if [[ ! -f "$GH_WRAPPERS" ]]; then
		print_error "pulse-check: gh wrappers not found: ${GH_WRAPPERS}"
		return 1
	fi
	if [[ "${PULSE_CHECK_GH_WRAPPERS_LOADED:-}" != "$GH_WRAPPERS" ]]; then
		# shellcheck source=./shared-gh-wrappers.sh
		source "$GH_WRAPPERS"
		PULSE_CHECK_GH_WRAPPERS_LOADED="$GH_WRAPPERS"
	fi
	declare -F gh_create_issue >/dev/null 2>&1 || return 1
	declare -F gh_issue_edit_safe >/dev/null 2>&1 || return 1
	declare -F gh_issue_close_safe >/dev/null 2>&1 || return 1
	return 0
}

_refresh_failure_family_issue() {
	local slug="$1"
	local issue_number="$2"
	local finding_json="$3"
	local outcome_status="${4:-$FAILURE_FAMILY_STATUS_RECURRING}"
	local fingerprint=""
	local count="0"
	local recent_count="0"
	fingerprint=$(printf '%s' "$finding_json" | jq -r '.family_fingerprint // ""')
	count=$(printf '%s' "$finding_json" | jq -r '.family_count // 0')
	recent_count=$(printf '%s' "$finding_json" | jq -r '.family_recent_count // 0')
	[[ -n "$fingerprint" ]] || return 0

	local body=""
	body=$(gh api "repos/${slug}/issues/${issue_number}" --jq '.body // ""' 2>/dev/null) || return 0
	local current_marker="fingerprint=${fingerprint} count=${count} recent_count=${recent_count} status=${outcome_status}"
	if [[ "$body" == *"${current_marker}"* ]]; then
		return 0
	fi

	local section=""
	section=$(_failure_family_state_section "$fingerprint" "$count" "$recent_count" "$outcome_status")
	local start_marker='<!-- failure-family-state:start -->'
	local end_marker='<!-- failure-family-state:end -->'
	local updated_body=""
	updated_body=$(jq -nr \
		--arg body "$body" --arg section "$section" --arg start "$start_marker" --arg end "$end_marker" '
		if (($body | contains($start)) and ($body | contains($end))) then
			($body | split($start) | .[0]) + $section + ($body | split($end) | .[1])
		else $body + "\n\n" + $section end') || return 0

	local body_file=""
	body_file=$(mktemp "${TMPDIR:-/tmp}/pulse-check-refresh.XXXXXX") || return 0
	printf '%s\n' "$updated_body" >"$body_file"
	if _load_gh_wrappers; then
		gh_issue_edit_safe "$issue_number" --repo "$slug" --body-file "$body_file" >/dev/null 2>&1 || true
	fi
	rm -f "$body_file"
	return 0
}

_record_failure_family_state() {
	local report_json="$1"
	local state_dir="${FAILURE_FAMILY_STATE_FILE%/*}"
	[[ "$state_dir" != "$FAILURE_FAMILY_STATE_FILE" ]] || return 0
	mkdir -p "$state_dir" 2>/dev/null || return 0
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.failure-family-remediation.XXXXXX") || return 0
	printf '%s' "$report_json" | jq '{
		updated_at: now,
		families: [.failure_family_remediation[]? | {fingerprint, family, count, recent_count, confidence, recovery_outcome}]
	}' >"$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 0; }
	mv "$tmp_file" "$FAILURE_FAMILY_STATE_FILE" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

_pulse_check_label_contract() {
	printf '%s\n' \
		'auto-dispatch|0E8A16|Eligible for autonomous worker dispatch' \
		'tier:standard|1D76DB|Standard-tier implementation requiring contextual judgment' \
		'bug|D73A4A|Something is not working' \
		'framework|5319E7|AI DevOps framework maintenance' \
		'pulse|0052CC|Pulse dispatch and worker automation' \
		'self-improvement|7057FF|Automated framework self-improvement' \
		'source:pulse-check|C2E0C6|Auto-created by the Pulse check routine'
	return 0
}

_pulse_check_label_present() {
	local labels_json="$1"
	local label_name="$2"
	if printf '%s' "$labels_json" | jq -e --arg label "$label_name" \
		'any(.[]?; .name == $label)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_list_pulse_check_labels() {
	local repo_slug="$1"
	local labels_json=""
	if ! labels_json=$(gh api --paginate "repos/${repo_slug}/labels?per_page=100" 2>/dev/null |
		jq -s '[.[][]? | {name: .name}]'); then
		return 1
	fi
	printf '%s\n' "$labels_json"
	return 0
}

_ensure_pulse_check_labels() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	case ",${PULSE_CHECK_LABELS_ENSURED}," in
	*",${repo_slug},"*) return 0 ;;
	esac

	local existing_labels_json=""
	if ! existing_labels_json=$(_list_pulse_check_labels "$repo_slug") ||
		! printf '%s' "$existing_labels_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
		print_error "pulse-check: failed to list labels for ${repo_slug}"
		return 1
	fi

	while IFS='|' read -r label_name color description; do
		[[ -n "$label_name" ]] || continue
		if _pulse_check_label_present "$existing_labels_json" "$label_name"; then
			continue
		fi

		local create_output=""
		if create_output=$(gh label create "$label_name" --repo "$repo_slug" \
			--color "$color" --description "$description" 2>&1); then
			continue
		fi

		# Treat a concurrent creator as success, but fail closed when the
		# required label still cannot be verified after the write attempt.
		local refreshed_labels_json=""
		refreshed_labels_json=$(_list_pulse_check_labels "$repo_slug") || refreshed_labels_json="[]"
		if _pulse_check_label_present "$refreshed_labels_json" "$label_name"; then
			continue
		fi
		print_error "pulse-check: failed to ensure label ${label_name} on ${repo_slug}: ${create_output}"
		return 1
	done < <(_pulse_check_label_contract)

	PULSE_CHECK_LABELS_ENSURED="${PULSE_CHECK_LABELS_ENSURED:+${PULSE_CHECK_LABELS_ENSURED},}${repo_slug}"
	return 0
}

_apply_finding() {
	local slug="$1"
	local finding_json="$2"
	local finding_id=""
	local title=""
	local severity=""
	local recommendation=""
	local evidence_markdown=""

	finding_id=$(printf '%s' "$finding_json" | jq -r '.id')
	title=$(printf '%s' "$finding_json" | jq -r '.title')
	severity=$(printf '%s' "$finding_json" | jq -r '.severity')
	recommendation=$(printf '%s' "$finding_json" | jq -r '.recommendation')
	evidence_markdown=$(printf '%s' "$finding_json" | jq -r '.evidence | map("- " + .) | join("\n")')

	local existing=""
	existing=$(_existing_open_issue_for_finding "$slug" "$finding_id")
	if [[ -n "$existing" ]]; then
		local existing_number=""
		local existing_url=""
		IFS=$'\t' read -r existing_number existing_url <<<"$existing"
		_refresh_failure_family_issue "$slug" "$existing_number" "$finding_json" "$FAILURE_FAMILY_STATUS_RECURRING"
		print_info "pulse-check: finding=${finding_id} already tracked by #${existing_number} (${existing_url})"
		return 0
	fi

	_load_gh_wrappers || return 1
	_ensure_pulse_check_labels "$slug" || return 1

	local body_file=""
	body_file=$(mktemp "${TMPDIR:-/tmp}/pulse-check-issue.XXXXXX") || return 1
	local family_fingerprint=""
	local family_count="0"
	local family_recent_count="0"
	family_fingerprint=$(printf '%s' "$finding_json" | jq -r '.family_fingerprint // ""')
	family_count=$(printf '%s' "$finding_json" | jq -r '.family_count // 0')
	family_recent_count=$(printf '%s' "$finding_json" | jq -r '.family_recent_count // 0')
	_finding_issue_body "$finding_id" "$title" "$severity" "$evidence_markdown" "$recommendation" \
		"$family_fingerprint" "$family_count" "$family_recent_count" >"$body_file"

	local labels="auto-dispatch,tier:standard,bug,framework,pulse,self-improvement,source:pulse-check"
	local issue_output=""
	issue_output=$(gh_create_issue --repo "$slug" --title "$title" --body-file "$body_file" --label "$labels" 2>&1) || {
		local issue_rc=$?
		rm -f "$body_file"
		print_error "pulse-check: failed to create issue for ${finding_id}: ${issue_output}"
		return "$issue_rc"
	}
	rm -f "$body_file"
	print_success "pulse-check: filed ${issue_output} for finding=${finding_id}"
	return 0
}

_failure_family_writes_allowed() {
	local report_json="$1"
	if printf '%s' "$report_json" | jq -e '
		(.current_state.dispatch_api_blocked // false) == true
		or ((.api_budget.secondary_cooldown_state // "") | contains("active=yes"))
	' >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

_reconcile_failure_family_remediations() {
	local slug="$1"
	local report_json="$2"
	_load_gh_wrappers || return 0
	local tracked_json="[]"
	tracked_json=$(gh issue list --repo "$slug" --state open \
		--search 'in:body "failure-family-state:start"' --limit 100 \
		--json number,body,createdAt,url 2>/dev/null) || tracked_json="[]"
	printf '%s' "$tracked_json" | jq empty >/dev/null 2>&1 || tracked_json="[]"

	while IFS= read -r issue_json; do
		[[ -n "$issue_json" ]] || continue
		local issue_number=""
		local body=""
		local created_at=""
		local fingerprint=""
		local baseline_count="0"
		issue_number=$(printf '%s' "$issue_json" | jq -r '.number // ""')
		body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
		created_at=$(printf '%s' "$issue_json" | jq -r '.createdAt // ""')
		fingerprint=$(jq -nr --arg body "$body" '$body | try capture("failure-family-state fingerprint=(?<value>[^ ]+)").value catch ""')
		baseline_count=$(jq -nr --arg body "$body" '$body | try (capture("failure-family-state fingerprint=[^ ]+ count=(?<value>[0-9]+)").value | tonumber) catch 0')
		[[ "$issue_number" =~ ^[0-9]+$ && -n "$fingerprint" ]] || continue

		local family_json=""
		family_json=$(printf '%s' "$report_json" | jq -c --arg fingerprint "$fingerprint" '
			([.failure_family_remediation[]? | select(.fingerprint == $fingerprint)] | first)
			// {fingerprint:$fingerprint, family:($fingerprint | sub("^ff-v1:"; "")), count:0, recent_count:0, confidence:"none", recovery_outcome:"not-observed"}
			| {family_fingerprint:.fingerprint, family:.family, family_count:(.count // 0), family_recent_count:(.recent_count // 0), family_confidence:(.confidence // "none")}')
		local current_count="0"
		local recent_count="0"
		current_count=$(printf '%s' "$family_json" | jq -r '.family_count // 0')
		recent_count=$(printf '%s' "$family_json" | jq -r '.family_recent_count // 0')
		local outcome_status="$FAILURE_FAMILY_STATUS_RECURRING"
		# Historical windows intentionally retain failures after the failure has
		# stopped recurring. Use the recent observation window as the recovery
		# signal; otherwise remediations remain open until old samples age out and
		# can be dispatched to fix a failure that is no longer occurring.
		if [[ "$recent_count" -eq 0 ]]; then
			outcome_status="recovery-candidate"
		elif [[ "$current_count" -lt "$baseline_count" ]]; then
			outcome_status="improving"
		fi

		local created_epoch="0"
		local age_seconds="0"
		created_epoch=$(jq -nr --arg value "$created_at" 'try ($value | fromdateiso8601) catch 0')
		[[ "$created_epoch" =~ ^[0-9]+$ ]] || created_epoch=0
		if [[ "$created_epoch" -gt 0 ]]; then
			age_seconds=$(( $(date +%s) - created_epoch ))
		fi
		if [[ "$outcome_status" == "recovery-candidate" && "$age_seconds" -ge "$FAILURE_FAMILY_RECOVERY_SECONDS" ]]; then
			outcome_status="eliminated"
		fi
		_refresh_failure_family_issue "$slug" "$issue_number" "$family_json" "$outcome_status"

		if [[ "$outcome_status" == "eliminated" ]]; then
			gh_issue_close_safe "$issue_number" --repo "$slug" \
				--comment "<!-- failure-family-recovery --> Stable aggregate ${fingerprint} recorded zero failures in the ${RECENT_SINCE} recent window after a ${age_seconds}s observation period; the ${SINCE} historical count is ${current_count} and will decay as retained samples age out. Closing with measured recovery evidence." \
				>/dev/null 2>&1 || true
		fi
	done < <(printf '%s' "$tracked_json" | jq -c '.[]')
	return 0
}

_apply_findings() {
	local report_json="$1"
	local slug=""
	slug=$(_resolve_apply_repo)
	if [[ -z "$slug" ]]; then
		print_error "pulse-check: --apply requires --repo <owner/repo> or a gh repo context"
		return 1
	fi
	if ! _failure_family_writes_allowed "$report_json"; then
		print_warning "pulse-check: skipping issue writes while GitHub API cooldown or dispatch API block is active"
		return 0
	fi

	local applied_count=0
	while IFS= read -r finding_json; do
		[[ -n "$finding_json" ]] || continue
		_apply_finding "$slug" "$finding_json" || true
		applied_count=$((applied_count + 1))
	done < <(printf '%s' "$report_json" | jq -c '.findings[] | select(.autofile == true)')

	if [[ "$applied_count" -eq 0 ]]; then
		print_info "pulse-check: no autofile findings above thresholds"
	fi
	_reconcile_failure_family_remediations "$slug" "$report_json"
	return 0
}

_main() {
	_parse_args "$@"
	_validate_numeric_options
	if [[ "$COMMAND" == "json" ]]; then
		JSON_OUTPUT=1
	elif [[ "$COMMAND" == "apply" ]]; then
		APPLY_MODE=1
	fi

	local report_json=""
	report_json=$(_collect_report_json)
	_record_failure_family_state "$report_json"

	if [[ "$APPLY_MODE" -eq 1 ]]; then
		_apply_findings "$report_json"
	fi

	if [[ "$JSON_OUTPUT" -eq 1 ]]; then
		printf '%s\n' "$report_json"
	else
		_render_text_report "$report_json"
	fi
	return 0
}

if [[ "${PULSE_CHECK_SOURCE_ONLY:-0}" != "1" ]]; then
	_main "$@"
fi
