#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-queue-governor.sh — Adaptive queue governor — metrics collection, delta computation, mode decision, and LLM prompt guidance.
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _fetch_queue_metrics
#   - _load_queue_metrics_history
#   - _compute_queue_deltas
#   - _compute_queue_mode
#   - _emit_queue_governor_state
#   - _compute_queue_governor_guidance
#   - append_adaptive_queue_governor
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_QUEUE_GOVERNOR_LOADED:-}" ]] && return 0
_PULSE_QUEUE_GOVERNOR_LOADED=1

#######################################
# Append adaptive queue-governor guidance to pre-fetched state
#
# Uses observed queue totals and trend vs previous cycle to derive an
# adaptive PR-vs-issue dispatch focus. This avoids static per-repo
# thresholds and shifts effort toward PR burn-down when PR backlog grows.
#######################################
#######################################
# Fetch queue metrics from all pulse-enabled repos (GH#5627)
#
# Outputs 4 lines: total_prs, total_issues, ready_prs, failing_prs
#######################################
_fetch_queue_metrics() {
	local total_prs=0
	local total_issues=0
	local ready_prs=0
	local failing_prs=0

	while IFS='|' read -r slug _path; do
		[[ -n "$slug" ]] || continue

		# GH#21799: drop GraphQL statusCheckRollup; fetch headRefOid + resolve
		# PASS/FAIL/PENDING via REST check-suites (separate budget pool).
		local pr_json pr_qm_err
		pr_qm_err=$(mktemp)
		pr_json=$(pulse_pr_list_get --repo "$slug" --state open --json number,headRefOid --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>"$pr_qm_err") || pr_json="[]"
		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local _pr_qm_err_msg
			_pr_qm_err_msg=$(cat "$pr_qm_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] _fetch_queue_metrics: gh_pr_list FAILED for ${slug}: ${_pr_qm_err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
		rm -f "$pr_qm_err"
		if declare -F _pmp_enrich_prs_with_review_decisions >/dev/null 2>&1; then
			pr_json=$(_pmp_enrich_prs_with_review_decisions "$slug" "$pr_json")
		fi

		# Enrich with REST check status; aggregate counts using the resulting
		# pre-computed status string per PR.
		local pr_checks_json=""
		pr_checks_json=$(gh_pr_check_status_rest_batch "$slug" "$pr_json" 2>/dev/null) || pr_checks_json="[]"
		[[ -n "$pr_checks_json" && "$pr_checks_json" != "null" ]] || pr_checks_json="[]"

		local repo_pr_total repo_ready repo_failing
		repo_pr_total=$(echo "$pr_json" | jq 'length' 2>/dev/null) || repo_pr_total=0
		# Only policy-level APPROVED counts as ready. REST review history emits
		# OBSERVED_APPROVED instead, which is intentionally not promoted without
		# required-count/code-owner proof.
		repo_ready=$(jq -n --argjson prs "$pr_json" --argjson checks "$pr_checks_json" '
			($checks | map({(.number | tostring): .status}) | add // {}) as $check_map |
			[$prs[] | (.number | tostring) as $n | select(.reviewDecision == "APPROVED" and ($check_map[$n] // "none") == "PASS")] | length
		' 2>/dev/null) || repo_ready=0
		repo_failing=$(jq -n --argjson prs "$pr_json" --argjson checks "$pr_checks_json" '
			($checks | map({(.number | tostring): .status}) | add // {}) as $check_map |
			[$prs[] | (.number | tostring) as $n | select(.reviewDecision == "CHANGES_REQUESTED" or ($check_map[$n] // "none") == "FAIL")] | length
		' 2>/dev/null) || repo_failing=0

		local issue_json repo_issue_total issue_qm_err
		issue_qm_err=$(mktemp)
		issue_json=$(gh_issue_list --repo "$slug" --state open --json number --limit "$PULSE_RUNNABLE_ISSUE_LIMIT" 2>"$issue_qm_err") || issue_json="[]"
		if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
			local _issue_qm_err_msg
			_issue_qm_err_msg=$(cat "$issue_qm_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] _fetch_queue_metrics: gh_issue_list FAILED for ${slug}: ${_issue_qm_err_msg}" >>"$LOGFILE"
			issue_json="[]"
		fi
		rm -f "$issue_qm_err"
		repo_issue_total=$(echo "$issue_json" | jq 'length' 2>/dev/null) || repo_issue_total=0

		[[ "$repo_pr_total" =~ ^[0-9]+$ ]] || repo_pr_total=0
		[[ "$repo_ready" =~ ^[0-9]+$ ]] || repo_ready=0
		[[ "$repo_failing" =~ ^[0-9]+$ ]] || repo_failing=0
		[[ "$repo_issue_total" =~ ^[0-9]+$ ]] || repo_issue_total=0

		total_prs=$((total_prs + repo_pr_total))
		total_issues=$((total_issues + repo_issue_total))
		ready_prs=$((ready_prs + repo_ready))
		failing_prs=$((failing_prs + repo_failing))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$REPOS_JSON" 2>/dev/null)

	echo "$total_prs"
	echo "$total_issues"
	echo "$ready_prs"
	echo "$failing_prs"
	return 0
}

#######################################
# Load previous queue metrics from the metrics file (GH#14960)
#
# Reads QUEUE_METRICS_FILE and populates caller-scope variables via
# stdout in key=value format. Caller evals the output.
#
# Output: key=value lines for prev_total_prs, prev_total_issues,
#         prev_ready_prs, prev_failing_prs, prev_recorded_at
#######################################
_load_queue_metrics_history() {
	local prev_total_prs=0 prev_total_issues=0 prev_ready_prs=0 prev_failing_prs=0 prev_recorded_at=0
	if [[ -f "$QUEUE_METRICS_FILE" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			prev_total_prs) prev_total_prs="$value" ;;
			prev_total_issues) prev_total_issues="$value" ;;
			prev_ready_prs) prev_ready_prs="$value" ;;
			prev_failing_prs) prev_failing_prs="$value" ;;
			prev_recorded_at) prev_recorded_at="$value" ;;
			esac
		done <"$QUEUE_METRICS_FILE"
	fi
	[[ "$prev_total_prs" =~ ^-?[0-9]+$ ]] || prev_total_prs=0
	[[ "$prev_total_issues" =~ ^-?[0-9]+$ ]] || prev_total_issues=0
	[[ "$prev_ready_prs" =~ ^-?[0-9]+$ ]] || prev_ready_prs=0
	[[ "$prev_failing_prs" =~ ^-?[0-9]+$ ]] || prev_failing_prs=0
	[[ "$prev_recorded_at" =~ ^[0-9]+$ ]] || prev_recorded_at=0
	printf 'prev_total_prs=%s\nprev_total_issues=%s\nprev_ready_prs=%s\nprev_failing_prs=%s\nprev_recorded_at=%s\n' \
		"$prev_total_prs" "$prev_total_issues" "$prev_ready_prs" "$prev_failing_prs" "$prev_recorded_at"
	return 0
}

#######################################
# Compute queue deltas and drain/growth metrics (GH#14960)
#
# Arguments:
#   $1 - total_prs (current)
#   $2 - total_issues (current)
#   $3 - ready_prs (current)
#   $4 - failing_prs (current)
#   $5 - prev_total_prs
#   $6 - prev_total_issues
#   $7 - prev_ready_prs
#   $8 - prev_failing_prs
#   $9 - prev_recorded_at (epoch)
#
# Output: key=value lines for pr_delta, issue_delta, ready_delta,
#         failing_delta, backlog_drain_per_cycle, backlog_growth_pressure,
#         drain_rate_per_hour, elapsed_seconds, now_epoch
#######################################
_compute_queue_deltas() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"
	local prev_total_prs="$5"
	local prev_total_issues="$6"
	local prev_ready_prs="$7"
	local prev_failing_prs="$8"
	local prev_recorded_at="$9"

	local now_epoch elapsed_seconds
	now_epoch=$(date +%s)
	elapsed_seconds=$((now_epoch - prev_recorded_at))
	if [[ "$elapsed_seconds" -lt 0 ]]; then
		elapsed_seconds=0
	fi

	local pr_delta issue_delta ready_delta failing_delta
	pr_delta=$((total_prs - prev_total_prs))
	issue_delta=$((total_issues - prev_total_issues))
	ready_delta=$((ready_prs - prev_ready_prs))
	failing_delta=$((failing_prs - prev_failing_prs))

	local backlog_drain_per_cycle backlog_growth_pressure drain_rate_per_hour
	backlog_drain_per_cycle=$((prev_total_prs - total_prs))
	if [[ "$backlog_drain_per_cycle" -lt 0 ]]; then
		backlog_drain_per_cycle=0
	fi
	backlog_growth_pressure=$pr_delta
	if [[ "$backlog_growth_pressure" -lt 0 ]]; then
		backlog_growth_pressure=0
	fi
	drain_rate_per_hour="n/a"
	if [[ "$elapsed_seconds" -gt 0 && "$backlog_drain_per_cycle" -gt 0 ]]; then
		drain_rate_per_hour=$(((backlog_drain_per_cycle * 3600) / elapsed_seconds))
	fi

	printf 'pr_delta=%s\nissue_delta=%s\nready_delta=%s\nfailing_delta=%s\nbacklog_drain_per_cycle=%s\nbacklog_growth_pressure=%s\ndrain_rate_per_hour=%s\nelapsed_seconds=%s\nnow_epoch=%s\n' \
		"$pr_delta" "$issue_delta" "$ready_delta" "$failing_delta" \
		"$backlog_drain_per_cycle" "$backlog_growth_pressure" "$drain_rate_per_hour" \
		"$elapsed_seconds" "$now_epoch"
	return 0
}

#######################################
# Determine queue mode and PR focus percentages (GH#14960)
#
# Arguments:
#   $1 - total_prs
#   $2 - total_issues
#   $3 - ready_prs
#   $4 - failing_prs
#   $5 - pr_delta
#
# Output: key=value lines for queue_mode, backlog_band,
#         pr_focus_pct, new_issue_pct
#######################################
_compute_queue_mode() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"
	local pr_delta="$5"

	local denominator pr_share_pct growth_bias pr_focus_pct new_issue_pct
	denominator=$((total_prs + total_issues))
	if [[ "$denominator" -lt 1 ]]; then
		denominator=1
	fi
	pr_share_pct=$(((total_prs * 100) / denominator))
	growth_bias=0
	if [[ "$pr_delta" -gt 0 ]]; then
		growth_bias=10
	elif [[ "$pr_delta" -lt 0 ]]; then
		growth_bias=-5
	fi
	pr_focus_pct=$((35 + (pr_share_pct / 2) + growth_bias))
	if [[ "$pr_focus_pct" -lt 35 ]]; then
		pr_focus_pct=35
	elif [[ "$pr_focus_pct" -gt 85 ]]; then
		pr_focus_pct=85
	fi

	local queue_mode backlog_band
	queue_mode="balanced"
	backlog_band="normal"
	if [[ "$total_prs" -ge "$PULSE_PR_BACKLOG_CRITICAL_THRESHOLD" ]]; then
		backlog_band="critical"
	elif [[ "$total_prs" -ge "$PULSE_PR_BACKLOG_HEAVY_THRESHOLD" ]]; then
		backlog_band="heavy"
	fi

	if [[ "$backlog_band" == "critical" || ("$ready_prs" -ge "$PULSE_READY_PR_MERGE_HEAVY_THRESHOLD" && "$pr_delta" -ge 0) ]]; then
		queue_mode="merge-heavy"
		if [[ "$pr_focus_pct" -lt 90 ]]; then
			pr_focus_pct=90
		fi
	elif [[ "$backlog_band" == "heavy" || "$failing_prs" -ge "$PULSE_FAILING_PR_HEAVY_THRESHOLD" || "$pr_focus_pct" -ge 60 ]]; then
		queue_mode="pr-heavy"
		if [[ "$pr_focus_pct" -lt 75 ]]; then
			pr_focus_pct=75
		fi
	fi
	new_issue_pct=$((100 - pr_focus_pct))

	printf 'queue_mode=%s\nbacklog_band=%s\npr_focus_pct=%s\nnew_issue_pct=%s\n' \
		"$queue_mode" "$backlog_band" "$pr_focus_pct" "$new_issue_pct"
	return 0
}

#######################################
# Write metrics file and emit governor state to STATE_FILE (GH#14960)
#
# Arguments:
#   $1  - total_prs
#   $2  - total_issues
#   $3  - ready_prs
#   $4  - failing_prs
#   $5  - now_epoch
#   $6  - pr_delta
#   $7  - issue_delta
#   $8  - ready_delta
#   $9  - failing_delta
#   $10 - backlog_drain_per_cycle
#   $11 - backlog_growth_pressure
#   $12 - drain_rate_per_hour
#   $13 - backlog_band
#   $14 - queue_mode
#   $15 - pr_focus_pct
#   $16 - new_issue_pct
#   $17 - active_workers
#   $18 - max_workers
#   $19 - utilization_pct
#######################################
_emit_queue_governor_state() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"
	local now_epoch="$5"
	local pr_delta="$6"
	local issue_delta="$7"
	local ready_delta="$8"
	local failing_delta="$9"
	local backlog_drain_per_cycle="${10}"
	local backlog_growth_pressure="${11}"
	local drain_rate_per_hour="${12}"
	local backlog_band="${13}"
	local queue_mode="${14}"
	local pr_focus_pct="${15}"
	local new_issue_pct="${16}"
	local active_workers="${17}"
	local max_workers="${18}"
	local utilization_pct="${19}"

	cat >"$QUEUE_METRICS_FILE" <<EOF
prev_total_prs=${total_prs}
prev_total_issues=${total_issues}
prev_ready_prs=${ready_prs}
prev_failing_prs=${failing_prs}
prev_recorded_at=${now_epoch}
EOF

	{
		echo ""
		echo "## Adaptive Queue Governor"
		echo "- Queue totals: PRs=${total_prs} (delta ${pr_delta}), issues=${total_issues} (delta ${issue_delta})"
		echo "- Backlog thresholds: heavy>=${PULSE_PR_BACKLOG_HEAVY_THRESHOLD}, critical>=${PULSE_PR_BACKLOG_CRITICAL_THRESHOLD}; current_band=${backlog_band}"
		echo "- PR execution pressure: ready=${ready_prs} (delta ${ready_delta}), failing_or_changes_requested=${failing_prs} (delta ${failing_delta})"
		echo "- Merge-drain telemetry: open_pr_drain_per_cycle=${backlog_drain_per_cycle}, open_pr_growth_pressure=${backlog_growth_pressure}, estimated_merge_drain_per_hour=${drain_rate_per_hour}"
		echo "- Worker utilization snapshot: active=${active_workers}/${max_workers} (${utilization_pct}%)"
		echo "- Adaptive mode this cycle: ${queue_mode}"
		echo "- Recommended dispatch focus: PR remediation ${pr_focus_pct}% / new issue dispatch ${new_issue_pct}%"
		echo ""
		echo "PULSE_QUEUE_MODE=${queue_mode}"
		echo "PULSE_PR_BACKLOG_BAND=${backlog_band}"
		echo "PR_REMEDIATION_FOCUS_PCT=${pr_focus_pct}"
		echo "NEW_ISSUE_DISPATCH_PCT=${new_issue_pct}"
		echo "OPEN_PR_BACKLOG=${total_prs}"
		echo "OPEN_PR_DRAIN_PER_CYCLE=${backlog_drain_per_cycle}"
		echo "OPEN_PR_GROWTH_PRESSURE=${backlog_growth_pressure}"
		echo "ESTIMATED_MERGE_DRAIN_PER_HOUR=${drain_rate_per_hour}"
		echo "PULSE_ACTIVE_WORKERS=${active_workers}"
		echo "PULSE_MAX_WORKERS=${max_workers}"
		echo "PULSE_WORKER_UTILIZATION_PCT=${utilization_pct}"
		echo ""
		echo "When PR backlog is rising, prioritize merge-ready and failing-check PR advancement before new issue starts."
	} >>"$STATE_FILE"

	return 0
}

#######################################
# Compute queue governor guidance from metrics (GH#5627)
#
# Orchestrates focused helpers to load history, compute deltas,
# determine queue mode, and emit state. Each helper is under 50 lines.
# Refactored from a 145-line monolith (GH#14960).
#
# Arguments:
#   $1 - total_prs
#   $2 - total_issues
#   $3 - ready_prs
#   $4 - failing_prs
# Output: governor guidance appended to STATE_FILE
#######################################
_compute_queue_governor_guidance() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"

	[[ "$total_prs" =~ ^[0-9]+$ ]] || total_prs=0
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$ready_prs" =~ ^[0-9]+$ ]] || ready_prs=0
	[[ "$failing_prs" =~ ^[0-9]+$ ]] || failing_prs=0

	# Load previous cycle metrics — use while+printf -v instead of eval (security).
	local prev_total_prs prev_total_issues prev_ready_prs prev_failing_prs prev_recorded_at
	local _qg_key _qg_val
	while IFS='=' read -r _qg_key _qg_val; do
		[[ -n "$_qg_key" ]] || continue
		case "$_qg_key" in
		prev_total_prs | prev_total_issues | prev_ready_prs | prev_failing_prs | prev_recorded_at)
			printf -v "$_qg_key" '%s' "$_qg_val"
			;;
		esac
	done < <(_load_queue_metrics_history)

	# Compute deltas and drain metrics — use while+printf -v instead of eval (security).
	local pr_delta issue_delta ready_delta failing_delta
	local backlog_drain_per_cycle backlog_growth_pressure drain_rate_per_hour
	local elapsed_seconds now_epoch
	while IFS='=' read -r _qg_key _qg_val; do
		[[ -n "$_qg_key" ]] || continue
		case "$_qg_key" in
		pr_delta | issue_delta | ready_delta | failing_delta | \
			backlog_drain_per_cycle | backlog_growth_pressure | drain_rate_per_hour | \
			elapsed_seconds | now_epoch)
			printf -v "$_qg_key" '%s' "$_qg_val"
			;;
		esac
	done < <(_compute_queue_deltas \
		"$total_prs" "$total_issues" "$ready_prs" "$failing_prs" \
		"$prev_total_prs" "$prev_total_issues" "$prev_ready_prs" "$prev_failing_prs" \
		"$prev_recorded_at")

	# Determine queue mode and focus percentages — use while+printf -v instead of eval (security).
	local queue_mode backlog_band pr_focus_pct new_issue_pct
	while IFS='=' read -r _qg_key _qg_val; do
		[[ -n "$_qg_key" ]] || continue
		case "$_qg_key" in
		queue_mode | backlog_band | pr_focus_pct | new_issue_pct)
			printf -v "$_qg_key" '%s' "$_qg_val"
			;;
		esac
	done < <(_compute_queue_mode \
		"$total_prs" "$total_issues" "$ready_prs" "$failing_prs" "$pr_delta")

	# Get worker utilization
	local active_workers max_workers utilization_pct
	active_workers=$(count_active_workers)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	max_workers=$(get_max_workers_target)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	fi
	utilization_pct=$(((active_workers * 100) / max_workers))

	# Write metrics file and emit state output
	_emit_queue_governor_state \
		"$total_prs" "$total_issues" "$ready_prs" "$failing_prs" \
		"$now_epoch" \
		"$pr_delta" "$issue_delta" "$ready_delta" "$failing_delta" \
		"$backlog_drain_per_cycle" "$backlog_growth_pressure" "$drain_rate_per_hour" \
		"$backlog_band" "$queue_mode" "$pr_focus_pct" "$new_issue_pct" \
		"$active_workers" "$max_workers" "$utilization_pct"

	echo "[pulse-wrapper] Adaptive queue governor: mode=${queue_mode} prs=${total_prs} issues=${total_issues} pr_focus=${pr_focus_pct}%" >>"$LOGFILE"
	return 0
}

append_adaptive_queue_governor() {
	if [[ ! -f "$STATE_FILE" ]]; then
		return 0
	fi

	# Fetch current queue metrics from all pulse-enabled repos
	local metrics_output
	metrics_output=$(_fetch_queue_metrics)

	local total_prs total_issues ready_prs failing_prs
	total_prs=$(echo "$metrics_output" | sed -n '1p')
	total_issues=$(echo "$metrics_output" | sed -n '2p')
	ready_prs=$(echo "$metrics_output" | sed -n '3p')
	failing_prs=$(echo "$metrics_output" | sed -n '4p')

	# Compute guidance and append to state file
	_compute_queue_governor_guidance "$total_prs" "$total_issues" "$ready_prs" "$failing_prs"
	return 0
}
