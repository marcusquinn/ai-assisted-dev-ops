#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Quality Sweep Tools -- Individual sweep tool integrations
# =============================================================================
# Contains the per-tool sweep functions for ShellCheck, SonarCloud issues/
# diagnostics, Codacy, CodeRabbit, merged-PR review scanner, and the sweep
# comment builder. Extracted from stats-quality-sweep.sh to reduce file size
# below the 1500-line gate.
#
# Usage: source "${SCRIPT_DIR}/stats-quality-sweep-tools.sh"
# Read-only Codacy report: bash stats-quality-sweep-tools.sh codacy OWNER/REPO REPO_PATH
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, _sanitize_markdown, etc.)
#   - stats-quality-sweep-issues.sh (_load_sweep_state, _save_sweep_state)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_STATS_QUALITY_SWEEP_TOOLS_LIB_LOADED:-}" ]] && return 0
_STATS_QUALITY_SWEEP_TOOLS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Discover tracked .sh files in a repo.
#
# Arguments:
#   $1 - repo path
# Output: newline-separated file paths to stdout (max 100)
#######################################
_sweep_shellcheck_get_files() {
	local repo_path="$1"

	# GH#5663: Use git ls-files to discover only tracked shell scripts.
	# find can return deleted files still on disk, stale worktree paths, or
	# build artifacts — causing false ShellCheck findings on non-existent files.
	if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" ls-files '*.sh' 2>/dev/null | head -100
	else
		# Fallback for non-git directories (should not occur for pulse repos)
		find "$repo_path" -name "*.sh" -not -path "*/node_modules/*" \
			-not -path "*/.git/*" -type f 2>/dev/null | head -100
	fi
	return 0
}

#######################################
# Format ShellCheck results into a markdown section.
#
# Arguments:
#   $1 - file count scanned
#   $2 - error count
#   $3 - warning count
#   $4 - note count
#   $5 - top findings details (may be empty)
# Output: markdown section to stdout
#######################################
_sweep_shellcheck_format_section() {
	local file_count="$1"
	local sc_errors="$2"
	local sc_warnings="$3"
	local sc_notes="$4"
	local sc_details="$5"

	local shellcheck_section="### ShellCheck ($file_count files scanned)

- **Errors**: ${sc_errors}
- **Warnings**: ${sc_warnings}
- **Notes**: ${sc_notes}
"
	if [[ -n "$sc_details" ]]; then
		shellcheck_section="${shellcheck_section}
**Top findings:**
${sc_details}"
	fi
	if [[ "$sc_errors" -eq 0 && "$sc_warnings" -eq 0 && "$sc_notes" -eq 0 ]]; then
		shellcheck_section="${shellcheck_section}
_All clear — no issues found._
"
	fi

	printf '%s' "$shellcheck_section"
	return 0
}

#######################################
# Run ShellCheck on all tracked .sh files in a repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output: shellcheck_section markdown to stdout
#######################################
_sweep_shellcheck() {
	local repo_slug="$1"
	local repo_path="$2"

	command -v shellcheck &>/dev/null || return 0

	local sh_files
	sh_files=$(_sweep_shellcheck_get_files "$repo_path")

	[[ -z "$sh_files" ]] && return 0

	local sc_errors=0
	local sc_warnings=0
	local sc_notes=0
	local sc_details=""

	# timeout_sec (from shared-constants.sh) handles macOS + Linux portably,
	# providing a background + kill fallback on bare macOS so we no longer
	# need to skip ShellCheck when no timeout utility is installed.
	# GH#5663: git ls-files returns relative paths — resolve to absolute
	# before running ShellCheck, and guard against tracked-but-deleted files
	# (index vs working tree mismatch) by skipping missing paths with a log
	# entry rather than passing a non-existent path to ShellCheck.

	while IFS= read -r shfile; do
		[[ -z "$shfile" ]] && continue
		if [[ ! "$shfile" =~ ^/ ]]; then
			shfile="${repo_path}/${shfile}"
		fi
		if [[ ! -f "$shfile" ]]; then
			printf '%s [stats] ShellCheck: skipping missing file: %s\n' \
				"$(date '+%Y-%m-%d %H:%M:%S')" "${shfile}" >>"$LOGFILE"
			continue
		fi
		local result
		# t1398.2: hardened invocation — no -x, --norc, per-file timeout,
		# ulimit -v in subshell to cap RSS per shellcheck process.
		# t1402: stderr merged into stdout (2>&1) so diagnostic messages
		# (parse errors, timeouts, permission failures) are captured in
		# $result and appear in the sweep summary.
		result=$(
			ulimit -v 1048576 2>/dev/null || true
			timeout_sec 30 shellcheck --norc -f gcc "$shfile" 2>&1 || true
		)
		if [[ -n "$result" ]]; then
			# t1992: shellcheck -f gcc emits three severities: error, warning,
			# note. Pin the regex to the gcc location prefix `<file>:<line>:<col>:`
			# so we don't accidentally match content inside a finding message.
			local file_errors file_warnings file_notes
			file_errors=$(grep -cE ':[0-9]+:[0-9]+: error:' <<<"$result") || file_errors=0
			file_warnings=$(grep -cE ':[0-9]+:[0-9]+: warning:' <<<"$result") || file_warnings=0
			file_notes=$(grep -cE ':[0-9]+:[0-9]+: note:' <<<"$result") || file_notes=0
			sc_errors=$((sc_errors + file_errors))
			sc_warnings=$((sc_warnings + file_warnings))
			sc_notes=$((sc_notes + file_notes))

			# Capture first 3 findings per file for the summary
			local rel_path="${shfile#"$repo_path"/}"
			local top_findings
			top_findings=$(head -3 <<<"$result" | while IFS= read -r line; do
				echo "  - \`${rel_path}\`: ${line##*: }"
			done)
			if [[ -n "$top_findings" ]]; then
				sc_details="${sc_details}${top_findings}
"
			fi
		fi
	done <<<"$sh_files"

	local file_count
	file_count=$(echo "$sh_files" | wc -l | tr -d ' ')
	_sweep_shellcheck_format_section "$file_count" "$sc_errors" "$sc_warnings" "$sc_notes" "$sc_details"
	return 0
}

#######################################
# Fetch SonarCloud open issues summary with rule-level breakdown.
#
# Arguments:
#   $1 - encoded_project_key
# Output: "total_issues|high_critical_count|sev_inline|issues_md"
#
# t2717: sev_inline is a single-line per-severity string for the dashboard
# (e.g., "0 BLOCKER · 0 CRITICAL · 98 MAJOR · 196 MINOR · 0 INFO"). Replaces
# the misleading '(N high/critical)' aggregate label, which counted MAJOR
# (a CODE_SMELL severity in SonarCloud's taxonomy) alongside BLOCKER and
# CRITICAL. high_critical_count is retained on the wire for back-compat
# with the state-file schema and downstream test fixtures.
#######################################
_sweep_sonarcloud_issues() {
	local encoded_project_key="$1"

	local sonar_issues=""
	sonar_issues=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/issues/search?componentKeys=${encoded_project_key}&statuses=OPEN,CONFIRMED,REOPENED&ps=1&facets=severities,types,rules" || echo "")

	if [[ -z "$sonar_issues" ]] || ! echo "$sonar_issues" | jq -e '.total' &>/dev/null; then
		printf '%s|%s|%s|%s' "0" "0" "0 BLOCKER · 0 CRITICAL · 0 MAJOR · 0 MINOR · 0 INFO" ""
		return 0
	fi

	# Single jq pass: extract total, high/critical count, per-severity inline
	# summary (t2717), severity breakdown, and type breakdown.
	local issues_data
	# Bind $sev_values once (t2717) so the "severities" facet selector is not
	# repeated — avoids tripping the repeated-string-literal ratchet in the
	# pre-commit hook and makes the per-severity derivations explicit.
	issues_data=$(echo "$sonar_issues" | jq -r '
		(.total // 0) as $total |
		([.facets[]? | select(.property == "severities") | .values[]?]) as $sev_values |
		([$sev_values[] | select(.val == "MAJOR" or .val == "CRITICAL" or .val == "BLOCKER") | .count] | add // 0) as $hc |
		($sev_values | map({key: .val, value: .count}) | from_entries) as $sev_map |
		"\(($sev_map.BLOCKER // 0)) BLOCKER · \(($sev_map.CRITICAL // 0)) CRITICAL · \(($sev_map.MAJOR // 0)) MAJOR · \(($sev_map.MINOR // 0)) MINOR · \(($sev_map.INFO // 0)) INFO" as $sev_inline |
		([$sev_values[] | "  - \(.val): \(.count)"] | join("\n")) as $sev |
		([.facets[]? | select(.property == "types") | .values[]? | "  - \(.val): \(.count)"] | join("\n")) as $typ |
		"\($total)|\($hc)|\($sev_inline)|\($sev)|\($typ)"
	') || issues_data="0|0|0 BLOCKER · 0 CRITICAL · 0 MAJOR · 0 MINOR · 0 INFO||"
	local total_issues="${issues_data%%|*}"
	local remainder="${issues_data#*|}"
	local high_critical_count="${remainder%%|*}"
	remainder="${remainder#*|}"
	local sev_inline="${remainder%%|*}"
	remainder="${remainder#*|}"
	local severity_breakdown="${remainder%%|*}"
	local type_breakdown="${remainder#*|}"
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	# t2717: sev_inline is a presentation string — sanitize it the same way
	# the breakdown strings are sanitized so stray markdown tokens in the
	# SonarCloud facet values can't break the dashboard table.
	sev_inline=$(_sanitize_markdown "$sev_inline")
	severity_breakdown=$(_sanitize_markdown "$severity_breakdown")
	type_breakdown=$(_sanitize_markdown "$type_breakdown")

	local issues_md="
- **Open issues**: ${total_issues}
- **By severity**:
${severity_breakdown}
- **By type**:
${type_breakdown}
"
	# Rule-level breakdown: shows which rules produce the most issues,
	# enabling targeted batch fixes (e.g., S1192 string constants, S7688
	# bracket style). This is the key data the supervisor needs to create
	# actionable quality-debt issues grouped by rule rather than by file.
	local rules_breakdown
	rules_breakdown=$(echo "$sonar_issues" | jq -r '
		[.facets[]? | select(.property == "rules") | .values[:10][]? |
		"  - \(.val): \(.count) issues"] | join("\n")
	') || rules_breakdown=""
	if [[ -n "$rules_breakdown" ]]; then
		rules_breakdown=$(_sanitize_markdown "$rules_breakdown")
		issues_md="${issues_md}
- **Top rules (fix these for maximum badge improvement)**:
${rules_breakdown}
"
	fi

	printf '%s|%s|%s|%s' "$total_issues" "$high_critical_count" "$sev_inline" "$issues_md"
	return 0
}

#######################################
# Build SonarCloud failing-condition diagnostics markdown.
#
# Called only when gate_status is ERROR or WARN.
#
# Arguments:
#   $1 - sonar_status JSON
#   $2 - encoded_project_key
# Output: diagnostics markdown to stdout
#######################################
_sweep_sonarcloud_diagnostics() {
	local sonar_status="$1"
	local encoded_project_key="$2"

	local failing_diagnostics
	failing_diagnostics=$(echo "$sonar_status" | jq -r '
		[.projectStatus.conditions[]? | select(.status == "ERROR" or .status == "WARN") |
		"- **\(.metricKey)**: actual=\(.actualValue), required \(.comparator) \(.errorThreshold) -- " +
		(if .metricKey == "new_security_hotspots_reviewed" then
			"Review unreviewed security hotspots in SonarCloud UI (mark Safe/Fixed) or fix the flagged code"
		elif .metricKey == "new_reliability_rating" then
			"Fix new bugs introduced in the analysis period"
		elif .metricKey == "new_security_rating" then
			"Fix new vulnerabilities introduced in the analysis period"
		elif .metricKey == "new_maintainability_rating" then
			"Reduce new code smells (extract constants, fix unused vars, simplify conditionals)"
		elif .metricKey == "new_duplicated_lines_density" then
			"Reduce code duplication in new code"
		else
			"Check SonarCloud dashboard for details"
		end)
		] | join("\n")
	') || failing_diagnostics=""

	if [[ -n "$failing_diagnostics" ]]; then
		failing_diagnostics=$(_sanitize_markdown "$failing_diagnostics")
		printf '\n**Failing conditions (badge blockers):**\n%s\n' "$failing_diagnostics"
	fi

	# Fetch unreviewed security hotspots count — this is the most
	# common quality gate blocker for DevOps repos (false positives
	# from shell patterns like curl, npm install, hash algorithms).
	local hotspots_response=""
	hotspots_response=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/hotspots/search?projectKey=${encoded_project_key}&status=TO_REVIEW&ps=5" || echo "")
	if [[ -n "$hotspots_response" ]] && echo "$hotspots_response" | jq -e '.paging' &>/dev/null; then
		local hotspot_total hotspot_details
		hotspot_total=$(echo "$hotspots_response" | jq -r '.paging.total // 0')
		[[ "$hotspot_total" =~ ^[0-9]+$ ]] || hotspot_total=0
		if [[ "$hotspot_total" -gt 0 ]]; then
			hotspot_details=$(echo "$hotspots_response" | jq -r '
				[.hotspots[:5][] |
				"  - `\(.component | split(":") | last):\(.line)` — \(.ruleKey): \(.message | .[0:100])"]
				| join("\n")
			') || hotspot_details=""
			hotspot_details=$(_sanitize_markdown "$hotspot_details")
			printf '\n**Unreviewed security hotspots (%s):**\n%s\n_Review these in SonarCloud UI or fix the underlying code to pass the quality gate._\n' \
				"$hotspot_total" "$hotspot_details"
		fi
	fi

	return 0
}

_CODACY_HEALTHY_STATE="HEALTHY"

_codacy_telemetry_is_valid() {
	local grade="$1"
	local issue_count="$2"
	local analysed_loc="$3"
	local complex_files="$4"
	local analysed_sha="$5"
	local remote_sha="$6"

	[[ "$grade" =~ ^[A-F]$ ]] && [[ "$issue_count" =~ ^[0-9]+$ ]] &&
		[[ "$analysed_loc" =~ ^[1-9][0-9]*$ ]] && [[ "$complex_files" =~ ^[0-9]+$ ]] &&
		[[ "$analysed_sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]]
}

_codacy_summary_fields() {
	local summary_response="$1"

	# API v3.1.0: the repository summary is wrapped in data, not top-level.
	jq -er '
		def count: type == "number" and . >= 0 and . == floor;
		def text: type == "string";
		.data | select(type == "object") |
		select(.gradeLetter | text and test("^[A-F]$")) |
		select(.issuesCount | count) | select(.loc | count and . > 0) |
		select(.complexFilesCount | count) |
		select(.lastAnalysedCommit.sha | text and test("^[0-9a-f]{40}$")) |
		select(.branch.name | text and length > 0) |
		[.gradeLetter, .issuesCount, .loc, .complexFilesCount, .lastAnalysedCommit.sha] | @tsv
	' <<<"$summary_response" 2>/dev/null
}

_codacy_read_healthy_state() {
	local state_file="$1"
	local previous_loc="" previous_sha=""

	if [[ -f "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
		previous_loc=$(jq -r '.healthy_loc // empty' "$state_file" 2>/dev/null || echo "")
		previous_sha=$(jq -r '.healthy_sha // empty' "$state_file" 2>/dev/null || echo "")
		[[ "$previous_loc" =~ ^[1-9][0-9]*$ ]] || previous_loc=""
		[[ "$previous_sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || previous_sha=""
	fi
	printf '%s|%s' "$previous_loc" "$previous_sha"
	return 0
}

_codacy_policy_drift() {
	local issues_response="$1"

	# Only an aggregate overview can establish absence. An issue-search page
	# (even one with pagination.total) cannot prove a policy rule is absent.
	jq -e '
		.data.counts.patterns | type == "array" and all(.[];
			(.id | type == "string") and
			(.total | type == "number" and . >= 0 and . == floor))
	' <<<"$issues_response" >/dev/null 2>&1 || return 1
	jq -r '
		["Bandit_B404", "ESLint8_es-x_no-modules",
		 "ESLint8_es-x_no-block-scoped-variables", "ESLint8_es-x_no-trailing-commas"] as $rules |
		.data.counts.patterns[] | select(.id as $id | $rules | index($id)) |
		select(.total > 0) | "  - `\(.id)`: \(.total)"
	' <<<"$issues_response"
	return 0
}

_codacy_classify_health() {
	local telemetry_valid="$1"
	local analysed_sha="$2"
	local remote_sha="$3"
	local previous_loc="$4"
	local previous_sha="$5"
	local analysed_loc="$6"
	local drift_output="$7"
	local health_unknown="$8"

	if [[ "$telemetry_valid" != true ]]; then
		printf '%s' "$health_unknown"
	elif [[ "$analysed_sha" != "$remote_sha" ]]; then
		printf '%s' "STALE_ANALYSIS"
	elif [[ -n "$previous_loc" && -n "$previous_sha" ]] && ((analysed_loc * 100 < previous_loc * 80)); then
		printf '%s' "INDEX_DEGRADED"
	elif [[ -n "$drift_output" ]]; then
		printf '%s' "POLICY_DRIFT"
	elif [[ -z "$previous_loc" || -z "$previous_sha" ]]; then
		printf '%s' "BASELINE_UNKNOWN"
	else
		printf '%s' "$_CODACY_HEALTHY_STATE"
	fi
	return 0
}

_codacy_save_healthy_state() {
	local state_file="$1"
	local grade="$2"
	local issue_count="$3"
	local analysed_loc="$4"
	local complex_files="$5"
	local analysed_sha="$6"
	local state_dir="${state_file%/*}"
	local state_tmp=""

	mkdir -p "$state_dir" || return 1
	state_tmp=$(mktemp "${state_file%.json}.XXXXXX" 2>/dev/null || echo "")
	if [[ -n "$state_tmp" ]] && jq -n \
		--arg grade "$grade" --arg sha "$analysed_sha" \
		--argjson issues "$issue_count" --argjson loc "$analysed_loc" --argjson complex "$complex_files" \
		'{grade: $grade, issue_count: $issues, healthy_loc: $loc, complex_files: $complex, healthy_sha: $sha}' >"$state_tmp" &&
		mv -f "$state_tmp" "$state_file"; then
		return 0
	fi
	[[ -n "$state_tmp" ]] && rm -f "$state_tmp"
	return 1
}

_codacy_grade_target() {
	local grade="$1"
	local health_state="$2"

	case "$health_state" in
	UNKNOWN | STALE_ANALYSIS) printf '%s' "UNVERIFIED" ;;
	*)
		if [[ "$grade" != "A" ]]; then
			printf '%s' "BELOW_TARGET"
		elif [[ "$health_state" == "$_CODACY_HEALTHY_STATE" ]]; then
			printf '%s' "AT_TARGET"
		else
			printf '%s' "UNVERIFIED"
		fi
		;;
	esac
	return 0
}

#######################################
# Run Codacy API check for a repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - local repository path (used to resolve the remote default SHA)
# Output: codacy_section markdown to stdout (UNKNOWN if unavailable)
#######################################
_sweep_codacy() {
	local repo_slug="$1"
	local repo_path="$2"
	local codacy_token=""
	local health_unknown="UNKNOWN"

	if command -v gopass &>/dev/null; then
		codacy_token=$(gopass show -o "aidevops/CODACY_API_TOKEN" 2>/dev/null || echo "")
	fi
	if [[ -z "$codacy_token" ]]; then
		printf '### Codacy\n\n- **Analysis health**: UNKNOWN\n- **Grade target**: A / UNVERIFIED\n- Codacy API credentials unavailable; no analysis verified.\n'
		return 0
	fi

	local codacy_org="${repo_slug%%/*}"
	local codacy_repo="${repo_slug##*/}"
	local summary_response issues_response summary_fields overview_body
	summary_response=$(curl -sS --fail --connect-timeout 5 --max-time 20 -H "api-token: ${codacy_token}" \
		"https://app.codacy.com/api/v3/analysis/organizations/gh/${codacy_org}/repositories/${codacy_repo}" 2>/dev/null || echo "")
	local grade="" issue_count="" analysed_loc="" complex_files="" analysed_sha="" remote_sha
	if summary_fields=$(_codacy_summary_fields "$summary_response"); then
		IFS=$'\t' read -r grade issue_count analysed_loc complex_files analysed_sha <<<"$summary_fields"
	fi
	overview_body=$(jq -c '{branchName: .data.branch.name}' <<<"$summary_response" 2>/dev/null || echo '{}')
	issues_response=$(curl -sS --fail --connect-timeout 5 --max-time 20 -H "api-token: ${codacy_token}" \
		"https://app.codacy.com/api/v3/analysis/organizations/gh/${codacy_org}/repositories/${codacy_repo}/issues/overview" \
		-X POST -H "Content-Type: application/json" -d "$overview_body" 2>/dev/null || echo "")
	remote_sha=$(git -C "$repo_path" ls-remote origin HEAD 2>/dev/null | cut -f1) || remote_sha=""

	local slug_safe="${repo_slug//\//-}"
	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.codacy-health.json"
	local previous_state previous_loc previous_sha drift_output health_state
	previous_state=$(_codacy_read_healthy_state "$state_file")
	IFS='|' read -r previous_loc previous_sha <<<"$previous_state"
	if drift_output=$(_codacy_policy_drift "$issues_response") &&
		_codacy_telemetry_is_valid "$grade" "$issue_count" "$analysed_loc" "$complex_files" "$analysed_sha" "$remote_sha"; then
		health_state=$(_codacy_classify_health true "$analysed_sha" "$remote_sha" "$previous_loc" "$previous_sha" "$analysed_loc" "$drift_output" "$health_unknown")
	else
		health_state="$health_unknown"
	fi
	if [[ "$health_state" == "BASELINE_UNKNOWN" || "$health_state" == "$_CODACY_HEALTHY_STATE" ]]; then
		# Repeated small drops must not ratchet a healthy denominator downward.
		# Retain the whole prior sample, not old LOC/SHA with new issue metrics.
		if [[ -z "$previous_loc" || -z "$previous_sha" ]] || ((analysed_loc >= previous_loc)); then
			_codacy_save_healthy_state "$state_file" "$grade" "$issue_count" "$analysed_loc" "$complex_files" "$analysed_sha" || health_state="$health_unknown"
		fi
	fi

	printf '### Codacy\n\n- **Grade**: %s\n- **Open issues**: %s\n- **Analysed LOC**: %s\n- **Complex files**: %s\n- **Analysed SHA**: %s\n- **Analysis health**: %s\n' \
		"${grade:-$health_unknown}" "${issue_count:-$health_unknown}" "${analysed_loc:-$health_unknown}" \
		"${complex_files:-$health_unknown}" "${analysed_sha:-$health_unknown}" "$health_state"
	printf -- '- **Grade target**: A / %s\n' "$(_codacy_grade_target "$grade" "$health_state")"
	[[ -n "$drift_output" ]] && printf '\n**Policy drift:**\n%s\n' "$drift_output"
	printf -- '- **Dashboard**: https://app.codacy.com/gh/%s/%s/dashboard\n' "$codacy_org" "$codacy_repo"
	return 0
}

#######################################
# Build the CodeRabbit trigger section for a quality sweep.
#
# Arguments:
#   $1 - repo slug
#   $2 - sweep_gate_status
#   $3 - sweep_total_issues
# Output: coderabbit_section markdown to stdout
#######################################
_sweep_coderabbit() {
	local repo_slug="$1"
	local sweep_gate_status="$2"
	local sweep_total_issues="$3"

	local prev_state
	prev_state=$(_load_sweep_state "$repo_slug")
	local prev_gate prev_issues prev_high_critical
	IFS='|' read -r prev_gate prev_issues prev_high_critical <<<"$prev_state"
	# Validate numeric fields from state file before arithmetic — corrupted or
	# missing values would cause $(( )) to fail or produce nonsense deltas.
	[[ "$prev_issues" =~ ^[0-9]+$ ]] || prev_issues=0
	[[ "$prev_high_critical" =~ ^[0-9]+$ ]] || prev_high_critical=0

	# First-run guard: if no previous state exists (prev_gate is UNKNOWN from
	# _load_sweep_state default), skip delta-based triggers. Without this, the
	# delta from 0 to current issue count always exceeds the spike threshold,
	# causing every first run (or run after state loss) to trigger a full review.
	if [[ "$prev_gate" == "UNKNOWN" ]]; then
		echo "[stats] CodeRabbit: first run for ${repo_slug} — saved baseline, skipping trigger" >>"$LOGFILE"
		printf '### CodeRabbit\n\n_First sweep run — baseline saved (%s issues, gate %s). Review trigger will activate on next sweep if quality degrades._\n' \
			"$sweep_total_issues" "$sweep_gate_status"
		return 0
	fi

	local issue_delta=$((sweep_total_issues - prev_issues))
	local reasons=()

	# Condition 1: Quality Gate is failing
	if [[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]]; then
		reasons+=("quality gate ${sweep_gate_status}")
	fi

	# Condition 2: Issue count spiked by threshold or more
	if [[ "$issue_delta" -ge "$CODERABBIT_ISSUE_SPIKE" ]]; then
		reasons+=("issue spike +${issue_delta}")
	fi

	if [[ ${#reasons[@]} -gt 0 ]]; then
		local trigger_reasons=""
		# Use printf -v to avoid subshell overhead (Gemini review on PR #2886)
		printf -v trigger_reasons '%s, ' "${reasons[@]}"
		trigger_reasons="${trigger_reasons%, }"
		echo "[stats] CodeRabbit: active review triggered for ${repo_slug} (${trigger_reasons})" >>"$LOGFILE"
		printf '### CodeRabbit\n\n**Trigger**: %s\n\n@coderabbitai Please run a full codebase review of this repository. Focus on:\n- Security vulnerabilities and credential exposure\n- Shell script quality (error handling, quoting, race conditions)\n- Code duplication and maintainability\n- Documentation accuracy\n' \
			"$trigger_reasons"
	else
		printf '### CodeRabbit\n\n_Monitoring: %s issues (delta: %s), gate %s — no active review needed._\n' \
			"$sweep_total_issues" "$issue_delta" "$sweep_gate_status"
	fi

	return 0
}

#######################################
# Run merged PR review scanner for a repo.
#
# Arguments:
#   $1 - repo slug
# Output: review_scan_section markdown to stdout (empty if unavailable)
#######################################
_sweep_review_scanner() {
	local repo_slug="$1"

	local review_helper="${SCRIPT_DIR}/quality-feedback-helper.sh"
	[[ -x "$review_helper" ]] || return 0

	local scan_output
	scan_output=$("$review_helper" scan-merged \
		--repo "$repo_slug" \
		--batch 30 \
		--create-issues \
		--min-severity medium \
		--json) || scan_output=""

	[[ -z "$scan_output" ]] && return 0
	echo "$scan_output" | jq -e '.scanned' &>/dev/null || return 0

	# Single jq pass: extract all three fields at once
	local scan_data
	scan_data=$(echo "$scan_output" | jq -r '"\(.scanned // 0)|\(.findings // 0)|\(.issues_created // 0)"') || scan_data="0|0|0"
	local scanned="${scan_data%%|*}"
	local remainder="${scan_data#*|}"
	local scan_findings="${remainder%%|*}"
	local scan_issues="${remainder#*|}"
	# Validate integers before any arithmetic comparison
	[[ "$scanned" =~ ^[0-9]+$ ]] || scanned=0
	[[ "$scan_findings" =~ ^[0-9]+$ ]] || scan_findings=0
	[[ "$scan_issues" =~ ^[0-9]+$ ]] || scan_issues=0

	local review_scan_section="### Merged PR Review Scanner

- **PRs scanned**: ${scanned}
- **Findings**: ${scan_findings}
- **Issues created**: ${scan_issues}
"
	if [[ "$scan_findings" -gt 0 ]]; then
		review_scan_section="${review_scan_section}
_Issues labelled \`quality-debt\` — capped at 30% of dispatch concurrency._
"
	fi

	printf '%s' "$review_scan_section"
	return 0
}

#######################################
# Upsert the rolling quality-sweep summary comment.
#
# Older versions appended one comment per sweep to the persistent quality issue.
# This helper edits the latest generated sweep comment instead, falling back to
# one new comment when no generated comment exists yet.
#
# Args: $1 = issue number, $2 = repo slug, $3 = comment body
# Returns: gh edit/comment status
#######################################
_upsert_quality_sweep_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local comment_body="$3"
	local comments_api="" comments_json="" latest_comment_id=""

	printf -v comments_api 'repos/%s/issues/%s/comments' "$repo_slug" "$issue_number"
	comments_json=$(gh api "${comments_api}?per_page=100" --paginate --slurp 2>/dev/null) || comments_json=""

	if [[ -n "$comments_json" && "$comments_json" != "null" ]]; then
		latest_comment_id=$(printf '%s' "$comments_json" | jq -r \
			--arg array_type 'array' \
			--arg latest_marker '<!-- quality-sweep-latest -->' \
			--arg sweep_heading '## Daily Code Quality Sweep' \
			--arg sweep_footer 'daily quality sweep' '
			(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
			elif type == $array_type then .
			else [] end)
			| [ .[]
				| select(
					(.body // "") as $body
					| ($body | contains($latest_marker)) or
						(($body | contains($sweep_heading)) and ($body | contains($sweep_footer)))
				)
				| {id: .id, created_at: .created_at} ]
			| sort_by(.created_at // "")
			| last
			| .id // empty
		' 2>/dev/null) || latest_comment_id=""
	fi

	if [[ -n "$latest_comment_id" ]]; then
		gh api "repos/${repo_slug}/issues/comments/${latest_comment_id}" \
			--method PATCH --field body="$comment_body" >/dev/null
		return $?
	fi

	gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$comment_body" >/dev/null
	return $?
}

#######################################
# Build the daily quality sweep comment body.
#
# Arguments:
#   $1  - now_iso
#   $2  - repo_slug
#   $3  - tool_count
#   $4  - shellcheck_section
#   $5  - qlty_section
#   $6  - sonar_section
#   $7  - codacy_section
#   $8  - coderabbit_section
#   $9  - review_scan_section
# Output: comment markdown to stdout
#######################################
_build_sweep_comment() {
	local now_iso="$1"
	local repo_slug="$2"
	local tool_count="$3"
	local shellcheck_section="$4"
	local qlty_section="$5"
	local sonar_section="$6"
	local codacy_section="$7"
	local coderabbit_section="$8"
	local review_scan_section="$9"
	: "$repo_slug" # Repository context is implicit in the issue; keep slugs out of generated comments.

	cat <<COMMENT
<!-- quality-sweep-latest -->
## Daily Code Quality Sweep

**Date**: ${now_iso}
**Repository**: current repository
**Tools run**: ${tool_count}

---

${shellcheck_section}
${qlty_section}
${sonar_section}
${codacy_section}
${coderabbit_section}
${review_scan_section}

---
_Auto-generated by stats-wrapper.sh daily quality sweep. The supervisor will review findings and create actionable issues._
COMMENT
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" != "codacy" || "$#" -ne 3 ]]; then
		printf 'Usage: bash stats-quality-sweep-tools.sh codacy OWNER/REPO REPO_PATH\n' >&2
		exit 2
	fi
	if [[ ! "$2" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ || ! -d "$3" ]]; then
		printf 'A repository slug and existing local repository directory are required\n' >&2
		exit 2
	fi
	QUALITY_SWEEP_STATE_DIR="${QUALITY_SWEEP_STATE_DIR:-${HOME}/.aidevops/logs/quality-sweep-state}"
	_sweep_codacy "$2" "$3"
fi
