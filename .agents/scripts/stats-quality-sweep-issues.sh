#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Quality Sweep Issues -- Quality issue management functions
# =============================================================================
# Contains functions for managing persistent quality review issues, sweep
# state persistence, grade computation, simplification issue body building,
# debt statistics, and quality issue dashboard body/title updates.
# Extracted from stats-quality-sweep.sh to reduce file size below the
# 1500-line gate.
#
# Usage: source "${SCRIPT_DIR}/stats-quality-sweep-issues.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_create_issue,
#     gh_issue_edit_safe, gh_issue_comment, etc.)
#   - stats-quality-sweep-coverage.sh (_compute_bot_coverage,
#     _compute_badge_indicator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_STATS_QUALITY_SWEEP_ISSUES_LIB_LOADED:-}" ]] && return 0
_STATS_QUALITY_SWEEP_ISSUES_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Search for an open quality dashboard issue by labels.
#
# Fail-closed: returns 1 on any gh API error so the caller aborts
# instead of falling through to creation (the original fail-open bug).
#
# Arguments:
#   $1 - repo_slug
#   $2 - quality-review label name
#   $3 - persistent label name
# Output: issue number to stdout (empty if not found)
# Returns: 0 on success (even if not found), 1 on API error
#######################################
_quality_issue_label_search() {
	local repo_slug="$1"
	local lbl_review="$2"
	local lbl_persist="$3"

	local raw_output exit_code
	raw_output=$(gh issue list --repo "$repo_slug" \
		--label "$lbl_review" --label "$lbl_persist" \
		--state open --json number \
		--jq '.[0].number // empty' 2>&1)
	exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		echo "[stats] Quality sweep: label search API error (exit ${exit_code}): ${raw_output}" >>"${LOGFILE:-/dev/null}"
		return 1
	fi

	printf '%s' "$raw_output"
	return 0
}

#######################################
# Search for an open quality dashboard issue by title prefix.
#
# Used as a fallback when label search returns empty but succeeds.
# Labels can be stripped by reconcilers; the title prefix is invariant.
# Fail-closed: returns 1 on any gh API error.
#
# Arguments:
#   $1 - repo_slug
# Output: issue number to stdout (empty if not found)
# Returns: 0 on success (even if not found), 1 on API error
#######################################
_quality_issue_title_search() {
	local repo_slug="$1"

	local raw_output exit_code
	raw_output=$(gh issue list --repo "$repo_slug" \
		--state open --search "\"Code Audit Routines\" in:title" \
		--json number --jq '.[0].number // empty' 2>&1)
	exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		echo "[stats] Quality sweep: title search API error (exit ${exit_code}): ${raw_output}" >>"${LOGFILE:-/dev/null}"
		return 1
	fi

	printf '%s' "$raw_output"
	return 0
}

#######################################
# Close all open "Code Audit Routines" sibling issues except the survivor.
#
# Self-healing sweep: called post-create to close any duplicates that
# accumulated during prior label-search failures. Models on
# pulse-merge.sh::_close_superseded_prs — close with comment, best-effort.
#
# Arguments:
#   $1 - repo_slug
#   $2 - survivor_issue_number (the one to keep open)
# Returns: 0 always (best-effort, never blocks the caller)
#######################################
_quality_issue_close_duplicates() {
	local repo_slug="$1"
	local survivor="$2"

	local siblings_json
	siblings_json=$(gh issue list --repo "$repo_slug" \
		--state open --search "\"Code Audit Routines\" in:title" \
		--json number --jq '[.[].number]' 2>/dev/null) || return 0

	[[ -z "$siblings_json" ]] && return 0

	local num
	while IFS= read -r num; do
		[[ -z "$num" ]] && continue
		[[ "$num" == "$survivor" ]] && continue
		local close_body="> Auto-closed: superseded by #${survivor} as duplicate quality dashboard."
		gh issue comment "$num" --repo "$repo_slug" --body "$close_body" 2>/dev/null || true
		gh issue close "$num" --repo "$repo_slug" 2>/dev/null || true
		echo "[stats] Quality sweep: closed duplicate dashboard #${num} (survivor: #${survivor})" >>"${LOGFILE:-/dev/null}"
	done < <(printf '%s\n' "$siblings_json" | jq -r '.[]' 2>/dev/null)

	return 0
}

#######################################
# Ensure persistent quality review issue exists for a repo.
#
# Creates or finds the "Code Audit Routines" dashboard issue.
# Dedup strategy (fail-closed, t3074):
#   1. Try per-machine cache (fast path).
#   2. Validate cache via gh issue view — only invalidate on definitive
#      non-OPEN state; transient API errors keep the cache to prevent
#      false-create.
#   3. Label search (fail-closed) — abort entire sweep on API error.
#   4. Title-prefix fallback — runs only when label search returns empty.
#      Abort if this API call also fails.
#   5. Create only when BOTH searches confirmed zero matches.
#   6. Post-create: run _quality_issue_close_duplicates to reclaim any
#      siblings created during prior failures.
#
# Arguments:
#   $1 - repo slug
# Output: issue number to stdout
# Returns: 0 on success, 1 if issue could not be found/created or if
#          any dedup API call fails (fail-closed)
#######################################
_ensure_quality_issue() {
	local repo_slug="$1"
	local slug_safe="${repo_slug//\//-}"
	local cache_file="${HOME}/.aidevops/logs/quality-issue-${slug_safe}"
	# Label constants — used for search, create, and attach
	local lbl_review="quality-review"
	local lbl_persist="persistent"
	local lbl_source="source:quality-sweep"

	mkdir -p "${HOME}/.aidevops/logs"

	# Try cached issue number
	local issue_number=""
	if [[ -f "$cache_file" ]]; then
		issue_number=$(cat "$cache_file" 2>/dev/null || echo "")
	fi

	# Validate cached issue — only invalidate on a definitive non-OPEN
	# response. Transient API failures (non-zero exit, empty state) keep
	# the cache to avoid triggering the creation path erroneously.
	if [[ -n "$issue_number" ]]; then
		local state gh_exit
		state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null)
		gh_exit=$?
		if [[ "$gh_exit" -eq 0 && -n "$state" && "$state" != "OPEN" ]]; then
			# Definitively closed/merged — invalidate cache
			issue_number=""
			rm -f "$cache_file" 2>/dev/null || true
		fi
		# Transient failure: keep cache and proceed as if valid
	fi

	# Label search — fail-closed: abort sweep on any API error
	if [[ -z "$issue_number" ]]; then
		local label_result
		label_result=$(_quality_issue_label_search "$repo_slug" "$lbl_review" "$lbl_persist") || {
			echo "[stats] Quality sweep: aborting — label search API failure for ${repo_slug}" >>"${LOGFILE:-/dev/null}"
			return 1
		}
		issue_number="$label_result"
	fi

	# Title-prefix fallback — only runs when label search returned empty
	if [[ -z "$issue_number" ]]; then
		local title_result
		title_result=$(_quality_issue_title_search "$repo_slug") || {
			echo "[stats] Quality sweep: aborting — title search API failure for ${repo_slug}" >>"${LOGFILE:-/dev/null}"
			return 1
		}
		issue_number="$title_result"
	fi

	# Create only when BOTH searches confirmed zero open matches
	if [[ -z "$issue_number" ]]; then
		# Ensure labels exist
		gh label create "$lbl_review" --repo "$repo_slug" --color "7057FF" \
			--description "Daily code quality review" --force 2>/dev/null || true
		gh label create "$lbl_persist" --repo "$repo_slug" --color "FBCA04" \
			--description "Persistent issue — do not close" --force 2>/dev/null || true
		gh label create "$lbl_source" --repo "$repo_slug" --color "C2E0C6" \
			--description "Auto-created by stats-functions.sh quality sweep" --force 2>/dev/null || true

		local qa_body="Persistent dashboard for automated code quality and simplification routines (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit). The supervisor posts findings here and creates actionable issues from them. **Do not close this issue.**"
		local qa_sig=""
		qa_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$qa_body" 2>/dev/null || true)
		qa_body="${qa_body}${qa_sig}"

		issue_number=$(gh_create_issue --repo "$repo_slug" \
			--title "Code Audit Routines" \
			--body "$qa_body" \
			--label "$lbl_review" --label "$lbl_persist" --label "$lbl_source" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$issue_number" ]]; then
			echo "[stats] Quality sweep: could not create issue for ${repo_slug}" >>"${LOGFILE:-/dev/null}"
			return 1
		fi

		# Pin (best-effort)
		local node_id
		node_id=$(gh issue view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi

		echo "[stats] Quality sweep: created and pinned issue #${issue_number} in ${repo_slug}" >>"${LOGFILE:-/dev/null}"

		# Post-create defensive sweep: close any siblings from prior failures
		_quality_issue_close_duplicates "$repo_slug" "$issue_number"
	fi

	# Cache the winner
	echo "$issue_number" >"$cache_file"
	echo "$issue_number"
	return 0
}

#######################################
# Ensure an actionable issue exists for a failing SonarCloud quality gate.
#
# Public README badges are useful confidence signals only when failures route
# to work automatically. This helper deduplicates one open badge-blocker issue
# per repo and keeps the persistent dashboard as the summary surface.
#
# Arguments:
#   $1 - repo slug
#   $2 - gate status
#   $3 - SonarCloud markdown section with failing-condition diagnostics
# Returns: 0 always (best-effort; quality sweep should still finish)
#######################################
_ensure_sonar_gate_blocker_issue() {
	local repo_slug="$1"
	local gate_status="$2"
	local sonar_section="$3"

	case "$gate_status" in
	ERROR | WARN) ;;
	*) return 0 ;;
	esac

	local issue_title="quality gate: resolve SonarCloud badge blockers"
	local existing_count existing_output
	if ! existing_output=$(gh issue list --repo "$repo_slug" \
		--label "sonarcloud" --label "quality-gate-blocker" --state open \
		--search "in:title \"$issue_title\"" \
		--json number --jq 'length' 2>/dev/null); then
		echo "[stats] SonarCloud quality gate issue search failed for ${repo_slug}; skipping create" >>"${LOGFILE:-/dev/null}"
		return 0
	fi
	existing_count="$existing_output"
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	if [[ "$existing_count" -gt 0 ]]; then
		echo "[stats] SonarCloud quality gate issue already open for ${repo_slug}" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	gh label create "sonarcloud" --repo "$repo_slug" --color "4E9BCD" \
		--description "SonarCloud quality findings" --force 2>/dev/null || true
	gh label create "quality-gate-blocker" --repo "$repo_slug" --color "D93F0B" \
		--description "Public quality badge or gate is failing" --force 2>/dev/null || true

	local issue_body="## What
SonarCloud reports a failing quality gate for this repository, which makes the public README quality badge show a failure state.

## Why
Public verification badges are user-confidence signals. When one goes red, the framework should route the cause to implementation work automatically instead of hiding the badge or leaving the failure as dashboard noise.

## How
Files to inspect:
- EDIT: sonar-project.properties — check whether the failing rule is a validated false positive that belongs in project-level exclusions.
- EDIT: cited source files from the SonarCloud diagnostics below — fix real vulnerabilities, bugs, smells, duplication, or hotspot review gaps.

Reference pattern:
- Model config-level false-positive handling on the existing \`sonar.issue.ignore.multicriteria.*\` entries in \`sonar-project.properties\`.
- Model real code fixes on neighbouring functions in the cited source files.

Verification:
- Run the SonarCloud API check: \`curl -s \"https://sonarcloud.io/api/qualitygates/project_status?projectKey=<project-key>\" | jq '.projectStatus'\`.
- The failing condition should clear after the next SonarCloud analysis.
- The README Quality Gate badge should return to passing.

## Current diagnostics

${sonar_section}"

	local gate_sig=""
	gate_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$issue_body" 2>/dev/null || true)
	issue_body="${issue_body}${gate_sig}"

	if gh_create_issue --repo "$repo_slug" \
		--title "$issue_title" \
		--body "$issue_body" \
		--label "auto-dispatch" --label "tier:standard" --label "quality-debt" \
		--label "source:quality-sweep" --label "sonarcloud" --label "quality-gate-blocker" >/dev/null 2>&1; then
		echo "[stats] Created SonarCloud quality gate blocker issue for ${repo_slug}" >>"${LOGFILE:-/dev/null}"
	else
		echo "[stats] Failed to create SonarCloud quality gate blocker issue for ${repo_slug}" >>"${LOGFILE:-/dev/null}"
	fi

	return 0
}

#######################################
# Load previous quality sweep state for a repo
#
# Reads gate_status, total_issues, high_critical, and qlty_smells from the
# per-repo state file. Returns defaults if no state file exists (first run).
#
# t2066: added qlty_smells as a 4th field so the sweep can render a smell-count
# delta vs the previous sweep in the dashboard. Callers that only want the
# first three fields still work because `IFS='|' read -r a b c` ignores
# trailing fields.
#
# Arguments:
#   $1 - repo slug
# Output: "gate_status|total_issues|high_critical_count|qlty_smells" to stdout
#######################################
_load_sweep_state() {
	local repo_slug="$1"
	local slug_safe="${repo_slug//\//-}"
	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"
	local default_gate="UNKNOWN"

	if [[ -f "$state_file" ]]; then
		local prev_gate prev_issues prev_high_critical prev_qlty_smells
		prev_gate=$(jq -r ".gate_status // \"${default_gate}\"" "$state_file" 2>/dev/null || echo "$default_gate")
		prev_issues=$(jq -r '.total_issues // 0' "$state_file" 2>/dev/null || echo "0")
		prev_high_critical=$(jq -r '.high_critical_count // 0' "$state_file" 2>/dev/null || echo "0")
		prev_qlty_smells=$(jq -r '.qlty_smells // 0' "$state_file" 2>/dev/null || echo "0")
		echo "${prev_gate}|${prev_issues}|${prev_high_critical}|${prev_qlty_smells}"
	else
		echo "${default_gate}|0|0|0"
	fi
	return 0
}

#######################################
# Map a local qlty smell count to an A/B/C/D/F grade.
#
# Reads grade bucket thresholds from complexity-thresholds.conf so they are
# ratchet-able the same way the shell complexity thresholds are. The grade
# thresholds are UPPER BOUNDS (inclusive): a count <= QLTY_GRADE_A_MAX is A,
# etc. Counts above QLTY_GRADE_D_MAX are F.
#
# t2066: this replaces the previous "parse grade out of the cloud badge SVG"
# flow. The local SARIF smell count is deterministic, always available, and
# already computed by the sweep — using the cloud badge as the primary grade
# source was a telemetry antipattern (the badge 404s periodically, and lags).
#
# Arguments:
#   $1 - smell count (integer)
# Output: "A", "B", "C", "D", "F", or "UNKNOWN" to stdout
#######################################
_compute_qlty_grade_from_count() {
	local smell_count="$1"
	local grade_fallback="UNKNOWN"

	# Validate input — non-numeric values degrade to the fallback rather than
	# silently bucketing to A (which a straight comparison would do for
	# empty strings under set -u).
	if ! [[ "$smell_count" =~ ^[0-9]+$ ]]; then
		printf '%s' "$grade_fallback"
		return 0
	fi

	# Locate the config relative to this script so it works in deployed
	# (~/.aidevops/agents/) and development (~/Git/aidevops/.agents/) trees.
	local script_dir conf_file
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
		printf '%s' "$grade_fallback"
		return 0
	}
	conf_file="${script_dir}/../configs/complexity-thresholds.conf"
	if [[ ! -f "$conf_file" ]]; then
		printf '%s' "$grade_fallback"
		return 0
	fi

	local a_max b_max c_max d_max
	a_max=$(grep '^QLTY_GRADE_A_MAX=' "$conf_file" | cut -d= -f2)
	b_max=$(grep '^QLTY_GRADE_B_MAX=' "$conf_file" | cut -d= -f2)
	c_max=$(grep '^QLTY_GRADE_C_MAX=' "$conf_file" | cut -d= -f2)
	d_max=$(grep '^QLTY_GRADE_D_MAX=' "$conf_file" | cut -d= -f2)

	# Validate thresholds — any missing or non-numeric value degrades to the
	# fallback so we never silently use default 0 thresholds that would bucket
	# everything into F.
	for val in "$a_max" "$b_max" "$c_max" "$d_max"; do
		if ! [[ "$val" =~ ^[0-9]+$ ]]; then
			printf '%s' "$grade_fallback"
			return 0
		fi
	done

	if ((smell_count <= a_max)); then
		printf '%s' "A"
	elif ((smell_count <= b_max)); then
		printf '%s' "B"
	elif ((smell_count <= c_max)); then
		printf '%s' "C"
	elif ((smell_count <= d_max)); then
		printf '%s' "D"
	else
		printf '%s' "F"
	fi
	return 0
}

#######################################
# Save current quality sweep state for a repo
#
# Persists gate_status, total_issues, and high/critical severity
# count so the next sweep can compute deltas.
#
# Arguments:
#   $1 - repo slug
#   $2 - gate status (OK/ERROR/UNKNOWN)
#   $3 - total issue count
#   $4 - high+critical severity count
#######################################
_save_sweep_state() {
	local repo_slug="$1"
	local gate_status="$2"
	local total_issues="$3"
	local high_critical_count="$4"
	local qlty_smells="${5:-0}"
	local qlty_grade="${6:-UNKNOWN}"
	local slug_safe="${repo_slug//\//-}"

	mkdir -p "$QUALITY_SWEEP_STATE_DIR"

	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"
	printf '{"gate_status":"%s","total_issues":%d,"high_critical_count":%d,"qlty_smells":%d,"qlty_grade":"%s","updated_at":"%s"}\n' \
		"$gate_status" "$total_issues" "$high_critical_count" "$qlty_smells" "$qlty_grade" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>"$state_file"
	return 0
}

#######################################
# Build the function-complexity-debt issue body for a single file.
#
# t2066: rule breakdown is now surfaced as a bulleted list section (was
# inline on a single line), so the worker can see which rule groups are
# driving the smell count and prioritise the highest-count rules first.
#
# Arguments:
#   $1 - file_path
#   $2 - smell_count
#   $3 - rule_breakdown (comma-separated "rule: count" pairs from the caller)
#   $4 - repository smell count (optional)
#   $5 - configured threshold (optional)
#   $6 - repository threshold deficit (optional)
# Output: issue body markdown to stdout
#######################################
_build_simplification_issue_body() {
	local file_path="$1"
	local smell_count="$2"
	local rule_breakdown="$3"
	local actual_count="${4:-$smell_count}"
	local smell_threshold="${5:-0}"
	local smell_deficit="${6:-$actual_count}"

	# t2066: split the rule breakdown into a bulleted list so the reader can
	# see the distribution at a glance. Input format is "rule1: N, rule2: M".
	local rule_breakdown_list=""
	if [[ -n "$rule_breakdown" && "$rule_breakdown" != "(could not parse)" ]]; then
		local IFS_SAVE="$IFS"
		IFS=','
		local rule_entry
		for rule_entry in $rule_breakdown; do
			# Trim leading whitespace from each comma-separated entry
			rule_entry="${rule_entry#"${rule_entry%%[![:space:]]*}"}"
			rule_breakdown_list="${rule_breakdown_list}- \`${rule_entry}\`
"
		done
		IFS="$IFS_SAVE"
	else
		rule_breakdown_list="- _(rule breakdown unavailable)_
"
	fi

	cat <<BODY
<!-- aidevops:generator=function-complexity-sweep cited_file=${file_path} smell_count=${smell_count} actual=${actual_count} threshold=${smell_threshold} deficit=${smell_deficit} -->

## Qlty Maintainability — ${file_path}

**Smells detected**: ${smell_count}
**Repository evidence**: actual ${actual_count}, threshold ${smell_threshold}, deficit ${smell_deficit}

### Files Scope

- EDIT: \`${file_path}\`

### Rule breakdown

${rule_breakdown_list}
This file contributes to a verified repository-wide threshold deficit on the current default branch. It is a baseline repair task, not evidence that an unrelated pull request introduced the smells. Low-density files are intentionally eligible so distributed debt cannot evade remediation.

### Suggested approach

1. Read the cited file and inspect the listed Qlty rules and locations
2. Apply the smallest behavior-preserving refactor that removes those findings
3. Verify with \`qlty smells ${file_path}\` after each change
4. No behavior changes — pure structural refactoring

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for file splits — sections 2-3 cover the canonical split pattern and identity-key preservation; section 5 covers pre-commit hook gotchas).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). For shell scripts, copy the include-guard and SCRIPT_DIR-fallback pattern from the simple precedent.

**Expected CI gate overrides:** If this refactoring splits functions into new files, the PR may trigger complexity or smell regression gates. Apply the \`ratchet-bump\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing the Qlty smell reduction. See the playbook section 4 (Known CI False-Positive Classes).

**Quality gate invariant:** New PR-specific smells remain blocking. Do not raise \`QLTY_SMELL_THRESHOLD\` or use an unrelated-baseline override to absorb findings introduced by this repair.

### Verification

- Run the repository's language-specific syntax/typecheck and focused tests for \`${file_path}\`
- Smell check: \`qlty smells ${file_path} --no-snippets --quiet\`
- No public API changes

### Dispatch and review policy

Trusted maintainer-owned sweeps label safe structural cleanup for bounded autonomous dispatch at \`tier:thinking\`. External or unverified creators retain \`needs-maintainer-review\` only until authority is approved. If trusted automation identifies a genuine behavior, API, security, or architecture decision, use \`hold-for-review\`; model strength alone is not a review gate.
BODY
	return 0
}

#######################################
# Compute quality-debt backlog stats for the quality issue dashboard.
#
# Arguments:
#   $1 - repo slug
# Output: pipe-delimited "debt_open|debt_closed|debt_total|debt_resolution_pct"
#######################################
_compute_debt_stats() {
	local repo_slug="$1"

	# Use GraphQL issueCount for accurate totals without pagination limits
	# (CodeRabbit review feedback — gh issue list defaults to 30 results).
	local debt_open=0
	local debt_closed=0
	debt_open=$(gh api graphql \
		-F searchQuery="repo:${repo_slug} is:issue is:open label:quality-debt" \
		-f query="
		query(\$searchQuery: String!) {
			search(query: \$searchQuery, type: ISSUE, first: 1) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	debt_closed=$(gh api graphql \
		-F searchQuery="repo:${repo_slug} is:issue is:closed label:quality-debt" \
		-f query="
		query(\$searchQuery: String!) {
			search(query: \$searchQuery, type: ISSUE, first: 1) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	# Validate integers
	[[ "$debt_open" =~ ^[0-9]+$ ]] || debt_open=0
	[[ "$debt_closed" =~ ^[0-9]+$ ]] || debt_closed=0
	local debt_total=$((debt_open + debt_closed))
	local debt_resolution_pct=0
	if [[ "$debt_total" -gt 0 ]]; then
		debt_resolution_pct=$((debt_closed * 100 / debt_total))
	fi

	printf '%s|%s|%s|%s' "$debt_open" "$debt_closed" "$debt_total" "$debt_resolution_pct"
	return 0
}

#######################################
# Gather all stats needed for the quality issue dashboard body.
#
# Collects debt backlog, PR scan lifetime stats, bot coverage,
# badge indicator, and simplification progress for a single repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - gate_status (OK/ERROR/WARN/UNKNOWN)
#   $3 - qlty_grade (A/B/C/D/F/UNKNOWN)
# Output: newline-delimited fields:
#   debt_open, debt_closed, debt_total, debt_resolution_pct,
#   prs_scanned_lifetime, issues_created_lifetime,
#   bot_coverage_section, badge_indicator, simplified_count
#######################################
_gather_quality_issue_stats() {
	local repo_slug="$1"
	local gate_status="$2"
	local qlty_grade="$3"

	# Quality-debt backlog stats
	local debt_raw
	debt_raw=$(_compute_debt_stats "$repo_slug")
	local debt_open="${debt_raw%%|*}"
	local debt_remainder="${debt_raw#*|}"
	local debt_closed="${debt_remainder%%|*}"
	debt_remainder="${debt_remainder#*|}"
	local debt_total="${debt_remainder%%|*}"
	local debt_resolution_pct="${debt_remainder#*|}"

	# PR scan lifetime stats from state file
	local slug_safe="${repo_slug//\//-}"
	local scan_state_file="${HOME}/.aidevops/logs/review-scan-state-${slug_safe}.json"
	local prs_scanned_lifetime=0
	local issues_created_lifetime=0
	if [[ -f "$scan_state_file" ]]; then
		prs_scanned_lifetime=$(jq -r '.scanned_prs | length // 0' "$scan_state_file" 2>>"$LOGFILE" || echo "0")
		issues_created_lifetime=$(jq -r '.issues_created // 0' "$scan_state_file" 2>>"$LOGFILE" || echo "0")
	fi
	[[ "$prs_scanned_lifetime" =~ ^[0-9]+$ ]] || prs_scanned_lifetime=0
	[[ "$issues_created_lifetime" =~ ^[0-9]+$ ]] || issues_created_lifetime=0

	# Bot review coverage on open PRs (t1411)
	local bot_coverage_section
	bot_coverage_section=$(_compute_bot_coverage "$repo_slug")

	# Badge status indicator
	local badge_indicator
	badge_indicator=$(_compute_badge_indicator "$gate_status" "$qlty_grade")

	# Simplification progress — count files tracked in simplification state
	local simplified_count=0
	local repo_path
	repo_path=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .path // empty' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || repo_path=""
	local state_file=""
	if [[ -n "$repo_path" ]]; then
		state_file="${repo_path}/.agents/configs/simplification-state.json"
	fi
	if [[ -f "$state_file" ]]; then
		simplified_count=$(jq '.files | length' "$state_file" 2>/dev/null) || simplified_count=0
	fi

	printf '%s\n' \
		"$debt_open" "$debt_closed" "$debt_total" "$debt_resolution_pct" \
		"$prs_scanned_lifetime" "$issues_created_lifetime" \
		"$bot_coverage_section" "$badge_indicator" "$simplified_count"
	return 0
}

#######################################
# Update the quality review issue title if stats have changed.
#
# Avoids unnecessary API calls by comparing the new title to the
# current one before issuing an edit.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - debt_open
#   $4 - debt_closed
#   $5 - simplified_count
#######################################
_update_quality_issue_title() {
	local issue_number="$1"
	local repo_slug="$2"
	local debt_open="$3"
	local debt_closed="$4"
	local simplified_count="$5"

	local quality_title="Code Audit Routines — Open: ${debt_open} | Closed: ${debt_closed} | Simplified: ${simplified_count}"
	local current_title
	current_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>>"$LOGFILE" || echo "")
	if [[ "$current_title" != "$quality_title" ]]; then
		gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --title "$quality_title" 2>>"$LOGFILE" >/dev/null || true
	fi
	return 0
}

#######################################
# Update the quality review issue body with a stats dashboard
#
# Mirrors the supervisor health issue pattern: the body shows at-a-glance
# stats (gate status, backlog, bot coverage, scan history), while daily
# sweep comments preserve the full history.
#
# Delegates to:
#   _gather_quality_issue_stats  — collects all stats (API calls)
#   _build_quality_issue_body    — assembles markdown (pure formatting)
#   _update_quality_issue_title  — updates title if changed
#
# Arguments:
#   $1  - repo slug
#   $2  - issue number
#   $3  - gate status (OK/ERROR/WARN/UNKNOWN)
#   $4  - total SonarCloud issues
#   $5  - high/critical count (MAJOR+CRITICAL+BLOCKER aggregate; retained
#        for state-file back-compat, no longer displayed directly per t2717)
#   $6  - sweep timestamp (ISO)
#   $7  - tool count
#   $8  - qlty smell count (optional)
#   $9  - qlty grade (optional)
#   $10 - qlty smell delta (optional, t2066; signed int)
#   $11 - qlty smell count previous (optional, t2066; 0 = first run)
#   $12 - sev_inline (optional, t2717; per-severity inline summary string,
#        e.g., "0 BLOCKER · 0 CRITICAL · 98 MAJOR · 196 MINOR · 0 INFO";
#        empty on first-run / pre-t2717 state reads)
#######################################
_update_quality_issue_body() {
	local repo_slug="$1"
	local issue_number="$2"
	local gate_status="$3"
	local total_issues="$4"
	local high_critical="$5"
	local sweep_time="$6"
	local tool_count="$7"
	local qlty_smell_count="${8:-0}"
	local qlty_grade="${9:-UNKNOWN}"
	local qlty_smell_delta="${10:-0}"
	local qlty_smell_count_prev="${11:-0}"
	local sev_inline="${12:-}"

	# Sanitize inputs to single-line values — prevents multi-line tool output
	# (e.g., ShellCheck findings) from leaking into the dashboard table.
	gate_status="${gate_status%%$'\n'*}"
	total_issues="${total_issues%%$'\n'*}"
	high_critical="${high_critical%%$'\n'*}"
	qlty_grade="${qlty_grade%%$'\n'*}"
	qlty_smell_count="${qlty_smell_count%%$'\n'*}"
	qlty_smell_delta="${qlty_smell_delta%%$'\n'*}"
	qlty_smell_count_prev="${qlty_smell_count_prev%%$'\n'*}"
	# t2717: sev_inline must stay single-line too — stray newlines would
	# break the dashboard table row.
	sev_inline="${sev_inline%%$'\n'*}"
	# Validate numeric fields — fall back to 0 if corrupted
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical" =~ ^[0-9]+$ ]] || high_critical=0
	[[ "$qlty_smell_count" =~ ^[0-9]+$ ]] || qlty_smell_count=0
	# qlty_smell_delta is signed — allow optional leading minus
	[[ "$qlty_smell_delta" =~ ^-?[0-9]+$ ]] || qlty_smell_delta=0
	[[ "$qlty_smell_count_prev" =~ ^[0-9]+$ ]] || qlty_smell_count_prev=0

	# Gather all stats via temp file (avoids subshell variable loss)
	local stats_tmp
	stats_tmp=$(mktemp)
	_gather_quality_issue_stats "$repo_slug" "$gate_status" "$qlty_grade" >"$stats_tmp"

	local debt_open debt_closed debt_total debt_resolution_pct
	local prs_scanned_lifetime issues_created_lifetime
	local bot_coverage_section badge_indicator simplified_count
	{
		IFS= read -r debt_open
		IFS= read -r debt_closed
		IFS= read -r debt_total
		IFS= read -r debt_resolution_pct
		IFS= read -r prs_scanned_lifetime
		IFS= read -r issues_created_lifetime
		IFS= read -r bot_coverage_section
		IFS= read -r badge_indicator
		IFS= read -r simplified_count
	} <"$stats_tmp"
	rm -f "$stats_tmp"

	local body
	body=$(_build_quality_issue_body \
		"$sweep_time" "$repo_slug" "$tool_count" "$badge_indicator" \
		"$gate_status" "$total_issues" "$high_critical" \
		"$qlty_grade" "$qlty_smell_count" \
		"$debt_open" "$debt_closed" "$simplified_count" "$debt_resolution_pct" \
		"$prs_scanned_lifetime" "$issues_created_lifetime" "$bot_coverage_section" \
		"$qlty_smell_delta" "$qlty_smell_count_prev" "$sev_inline")

	# Update issue body — redirect stderr to log for debugging on failure
	local edit_stderr
	edit_stderr=$(gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Quality sweep: failed to update body on #${issue_number} in ${repo_slug}: ${edit_stderr}" >>"$LOGFILE"
		return 0
	}

	_update_quality_issue_title "$issue_number" "$repo_slug" \
		"$debt_open" "$debt_closed" "$simplified_count"

	echo "[stats] Quality sweep: updated dashboard on #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}
