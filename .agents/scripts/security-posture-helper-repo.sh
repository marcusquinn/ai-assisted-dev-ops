#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Security Posture Helper -- Per-Repo Audit Sub-Library
# =============================================================================
# Per-repo security posture checks (t1412.11): workflow security, branch
# protection, review-bot-gate, dependency scanning, collaborator access,
# repository security basics, and SYNC_PAT detection.
#
# Usage: source "${SCRIPT_DIR}/security-posture-helper-repo.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - security-posture-helper.sh orchestrator (utility functions, constants)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SECURITY_POSTURE_REPO_LIB_LOADED:-}" ]] && return 0
_SECURITY_POSTURE_REPO_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

RULESET_ENFORCEMENT_ACTIVE="active"
RULESET_DEFAULT_BRANCH_TOKEN="~DEFAULT_BRANCH"
RULESET_ALL_BRANCHES_TOKEN="~ALL"
RULESET_ALL_HEADS_PATTERN="refs/heads/*"
GH_CLI_NOT_AVAILABLE_MSG="gh CLI not available"
NO_GITHUB_REMOTE_MSG="No GitHub remote"
NO_REQUIRED_STATUS_CHECKS_MSG="No required status checks"
SECURITY_POSTURE_UNKNOWN="unknown"
SYNC_PAT_NEED_NOT_NEEDED="not_needed"
SYNC_PAT_PROTECTION_CLASSIC="classic"

# _repo_is_public_admin <slug>
# Returns 0 only when GitHub confirms this operator has admin rights on a
# public repository. API/auth failures are fail-open for audit availability: the
# caller should keep baseline severities instead of inventing repository scope.
_repo_is_public_admin() {
	local slug="$1"

	local repo_json
	repo_json=$(gh api "repos/${slug}" 2>/dev/null) || return 1
	[[ -z "$repo_json" ]] && return 1

	local is_private has_admin
	is_private=$(echo "$repo_json" | jq -r 'if has("private") then .private else true end' 2>/dev/null) || return 1
	has_admin=$(echo "$repo_json" | jq -r '.permissions.admin // false' 2>/dev/null) || return 1

	[[ "$is_private" == false && "$has_admin" == "true" ]]
	return $?
}

# _classic_required_checks_count <protection-json>
# Counts both legacy `.contexts[]` and modern `.checks[]` required-check shapes.
_classic_required_checks_count() {
	local protection_json="$1"

	local required_checks
	required_checks=$(echo "$protection_json" | jq -r '((.required_status_checks.contexts // []) | length) + ((.required_status_checks.checks // []) | length)' 2>/dev/null) || required_checks="0"
	[[ "$required_checks" =~ ^[0-9]+$ ]] || required_checks="0"
	printf '%s\n' "$required_checks"
	return 0
}

_classic_branch_protection_json() {
	local slug="$1"
	local default_branch="$2"

	gh api "repos/$slug/branches/$default_branch/protection" 2>/dev/null
	return $?
}

# _collaborator_access_json <slug>
# Emits one compact object per collaborator from the paginated endpoint.
_collaborator_access_json() {
	local slug="$1"

	gh api --paginate "repos/$slug/collaborators?per_page=100" \
		--jq '.[] | {login: .login, type: .type, role: .role_name, permissions: .permissions}' 2>/dev/null
	return $?
}

# _rulesets_pr_gating_state <slug> <default-branch>
# Emits tab-separated: protected pull_requests reviews checks bypass. A public
# ADMIN repo is considered ruleset-backed only when active default-branch
# rulesets enforce pull requests and at least one required status check. Bypass
# actors are surfaced as admin-bypass risk because they weaken the invariant.
_rulesets_pr_gating_state() {
	local slug="$1"
	local default_branch="$2"
	local ruleset_details="${3:-}"

	if [[ "$#" -lt 3 ]]; then
		ruleset_details=$(_default_branch_ruleset_details "$slug" "$default_branch") || return 1
	fi
	[[ -z "$ruleset_details" ]] && return 1

	local protected=0
	local pull_requests=0
	local reviews=0
	local checks=0
	local bypass=0
	local detail
	while IFS= read -r detail; do
		[[ -z "$detail" ]] && continue
		protected=1

		local pull_request_count approval_count status_count bypass_count
		pull_request_count=$(jq -r '[.rules[]? | select(.type == "pull_request")] | length' <<<"$detail" 2>/dev/null) || pull_request_count="0"
		approval_count=$(jq -r '[.rules[]? | select(.type == "pull_request") | (.parameters.required_approving_review_count // 0)] | max // 0' <<<"$detail" 2>/dev/null) || approval_count="0"
		status_count=$(jq -r '[.rules[]? | select(.type == "required_status_checks") | (.parameters.required_status_checks // []) | length] | add // 0' <<<"$detail" 2>/dev/null) || status_count="0"
		bypass_count=$(jq -r '(.bypass_actors // []) | length' <<<"$detail" 2>/dev/null) || bypass_count="0"

		[[ "$pull_request_count" =~ ^[0-9]+$ ]] || pull_request_count="0"
		[[ "$approval_count" =~ ^[0-9]+$ ]] || approval_count="0"
		[[ "$status_count" =~ ^[0-9]+$ ]] || status_count="0"
		[[ "$bypass_count" =~ ^[0-9]+$ ]] || bypass_count="0"

		[[ "$pull_request_count" -gt 0 ]] && pull_requests=1
		[[ "$approval_count" -gt 0 ]] && reviews=1
		[[ "$status_count" -gt 0 ]] && checks=1
		[[ "$bypass_count" -gt 0 ]] && bypass=1
	done <<<"$ruleset_details"

	printf '%s\t%s\t%s\t%s\t%s\n' "$protected" "$pull_requests" "$reviews" "$checks" "$bypass"
	return 0
}

# Phase 1: Scan .github/workflows/ for unsafe AI patterns
# Checks for:
#   - shell + credentials + untrusted input (injection risk)
#   - allowed_non_write_users: "*" (overly permissive)
#   - cached long-lived tokens
check_workflow_security() {
	local repo_path="$1"
	local workflows_dir="$repo_path/.github/workflows"

	print_header "Phase 1: GitHub Actions Workflow Security"

	if [[ ! -d "$workflows_dir" ]]; then
		print_skip "No .github/workflows/ directory found"
		add_finding "$SEVERITY_INFO" "$CAT_WORKFLOWS" "No .github/workflows/ directory"
		return 0
	fi

	local workflow_files
	workflow_files=$(find "$workflows_dir" -name "*.yml" -o -name "*.yaml" 2>/dev/null)

	if [[ -z "$workflow_files" ]]; then
		print_skip "No workflow files found"
		add_finding "$SEVERITY_INFO" "$CAT_WORKFLOWS" "No workflow YAML files found"
		return 0
	fi

	local file_count
	file_count=$(echo "$workflow_files" | wc -l | tr -d ' ')
	print_info "Scanning $file_count workflow file(s)..."

	local unsafe_found=false

	while IFS= read -r wf; do
		[[ -z "$wf" ]] && continue
		local wf_name
		wf_name=$(basename "$wf")

		# Check 1: Shell commands using github.event context (injection vector)
		# Pattern: run: ... ${{ github.event.issue.title }} or similar
		if grep -qE '\$\{\{\s*github\.event\.(issue|pull_request|comment)\.' "$wf" 2>/dev/null; then
			if grep -qE '^\s*run:' "$wf" 2>/dev/null; then
				print_crit "$wf_name: Uses github.event context in shell run step (injection risk)"
				add_finding "$SEVERITY_CRITICAL" "$CAT_WORKFLOWS" "$wf_name: github.event context in shell run step"
				unsafe_found=true
			fi
		fi

		# Check 2: Overly permissive allowed_non_write_users or permissions
		if grep -qE 'allowed_non_write_users:\s*"\*"' "$wf" 2>/dev/null; then
			print_crit "$wf_name: allowed_non_write_users set to wildcard '*'"
			add_finding "$SEVERITY_CRITICAL" "$CAT_WORKFLOWS" "$wf_name: allowed_non_write_users wildcard"
			unsafe_found=true
		fi

		# Check 3: Workflow uses pull_request_target with checkout of PR head
		# This is the classic "pwn request" pattern
		if grep -qE 'pull_request_target' "$wf" 2>/dev/null; then
			if grep -qE 'ref:\s*\$\{\{\s*github\.event\.pull_request\.head\.(ref|sha)' "$wf" 2>/dev/null; then
				print_crit "$wf_name: pull_request_target with PR head checkout (pwn request risk)"
				add_finding "$SEVERITY_CRITICAL" "$CAT_WORKFLOWS" "$wf_name: pull_request_target with PR head checkout"
				unsafe_found=true
			else
				print_warn "$wf_name: Uses pull_request_target (review checkout refs carefully)"
				add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: uses pull_request_target"
			fi
		fi

		# Check 4: Long-lived tokens cached or stored in artifacts
		if grep -qE 'actions/cache.*token|save-state.*token|GITHUB_TOKEN.*>>.*GITHUB_ENV' "$wf" 2>/dev/null; then
			print_warn "$wf_name: Possible token caching pattern detected"
			add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: possible token caching"
		fi

		# Check 5: Overly broad permissions
		if grep -qE '^\s*permissions:\s*write-all' "$wf" 2>/dev/null; then
			print_warn "$wf_name: Uses write-all permissions (prefer least-privilege)"
			add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: write-all permissions"
		fi

		# Check 6: Third-party actions pinned to branch instead of SHA
		local unpinned_actions
		unpinned_actions=$(grep -oE 'uses:\s+[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+@(main|master|v[0-9]+)' "$wf" 2>/dev/null | head -5) || true
		if [[ -n "$unpinned_actions" ]]; then
			local unpinned_count
			unpinned_count=$(echo "$unpinned_actions" | wc -l | tr -d ' ')
			print_warn "$wf_name: $unpinned_count action(s) pinned to branch/tag instead of SHA"
			add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: $unpinned_count actions not SHA-pinned"
		fi

	done <<<"$workflow_files"

	if [[ "$unsafe_found" == false ]]; then
		print_pass "No critical workflow security issues found"
		add_finding "$SEVERITY_PASS" "$CAT_WORKFLOWS" "No critical issues"
	fi

	return 0
}

# _report_rulesets_branch_protection <slug> <default-branch> <public-admin-flag> [ruleset-details]
_report_rulesets_branch_protection() {
	local slug="$1"
	local default_branch="$2"
	local public_admin="$3"
	local ruleset_details="${4:-}"

	local rulesets_state protected_by_rulesets rulesets_pull_requests rulesets_reviews rulesets_checks rulesets_bypass
	if [[ -n "$ruleset_details" ]]; then
		rulesets_state=$(_rulesets_pr_gating_state "$slug" "$default_branch" "$ruleset_details") || true
	else
		rulesets_state=$(_rulesets_pr_gating_state "$slug" "$default_branch") || true
	fi
	if [[ -n "$rulesets_state" ]]; then
		IFS=$'\t' read -r protected_by_rulesets rulesets_pull_requests rulesets_reviews rulesets_checks rulesets_bypass <<<"$rulesets_state"
	else
		protected_by_rulesets=0
		rulesets_pull_requests=0
		rulesets_reviews=0
		rulesets_checks=0
		rulesets_bypass=0
	fi

	if [[ "$protected_by_rulesets" -ne 1 ]]; then
		print_crit "Default branch '$default_branch' has NO branch protection or active matching ruleset"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "No branch protection on $default_branch"
		return 0
	fi

	print_pass "Default branch '$default_branch' protected by active repository ruleset(s)"
	add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Rulesets protect $default_branch"
	_report_rulesets_review_requirement "$default_branch" "$public_admin" "$rulesets_reviews" "$rulesets_pull_requests"
	_report_rulesets_check_requirement "$default_branch" "$public_admin" "$rulesets_checks"
	_report_rulesets_bypass_requirement "$public_admin" "$rulesets_bypass"
	return 0
}

_report_rulesets_review_requirement() {
	local default_branch="$1"
	local public_admin="$2"
	local rulesets_reviews="$3"
	local pull_requests_required="${4:-0}"

	if [[ "$rulesets_reviews" -eq 1 ]]; then
		print_pass "Rulesets require pull request approval"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Rulesets require PR approval"
	elif [[ "$public_admin" -eq 1 && "$pull_requests_required" -eq 1 ]]; then
		print_pass "Rulesets allow zero native approvals; maintainer authority is enforced separately"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Native PR approval optional with enforced pull requests"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "Rulesets do not require pull request approval on public ADMIN repo"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "Rulesets missing PR approval requirement"
	else
		print_warn "Rulesets do not require pull request approval on $default_branch"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "Rulesets missing PR approval requirement"
	fi
	return 0
}

_report_rulesets_check_requirement() {
	local default_branch="$1"
	local public_admin="$2"
	local rulesets_checks="$3"

	if [[ "$rulesets_checks" -eq 1 ]]; then
		print_pass "Rulesets require status checks"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Rulesets require status checks"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "Rulesets do not require status checks on public ADMIN repo"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "Rulesets missing required status checks"
	else
		print_warn "Rulesets do not require status checks on $default_branch"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "Rulesets missing required status checks"
	fi
	return 0
}

_report_rulesets_bypass_requirement() {
	local public_admin="$1"
	local rulesets_bypass="$2"

	if [[ "$rulesets_bypass" -eq 1 && "$public_admin" -eq 1 ]]; then
		print_crit "Rulesets define bypass actors on public ADMIN repo"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "Rulesets allow bypass actors"
	elif [[ "$rulesets_bypass" -eq 1 ]]; then
		print_warn "Rulesets define bypass actors"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "Rulesets allow bypass actors"
	else
		print_pass "Rulesets have no bypass actors"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Rulesets have no bypass actors"
	fi
	return 0
}

_report_classic_branch_protection() {
	local protection_json="$1"
	local default_branch="$2"
	local public_admin="$3"

	local pull_requests_required required_reviews required_checks enforce_admins
	pull_requests_required=$(echo "$protection_json" | jq -r 'if .required_pull_request_reviews == null then 0 else 1 end' 2>/dev/null) || pull_requests_required="0"
	required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null) || required_reviews="0"
	required_checks=$(_classic_required_checks_count "$protection_json")
	enforce_admins=$(echo "$protection_json" | jq -r '.enforce_admins.enabled // false' 2>/dev/null) || enforce_admins=false

	_report_classic_review_requirement "$default_branch" "$public_admin" "$required_reviews" "$pull_requests_required"
	_report_classic_check_requirement "$default_branch" "$public_admin" "$required_checks"
	_report_classic_admin_enforcement "$public_admin" "$enforce_admins"
	return 0
}

_report_classic_review_requirement() {
	local default_branch="$1"
	local public_admin="$2"
	local required_reviews="$3"
	local pull_requests_required="${4:-0}"

	if [[ "$required_reviews" -gt 0 ]]; then
		print_pass "PR reviews required ($required_reviews approving review(s))"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "PR reviews required: $required_reviews"
	elif [[ "$public_admin" -eq 1 && "$pull_requests_required" -eq 1 ]]; then
		print_pass "Zero native approvals accepted; maintainer authority is enforced separately"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Native PR approval optional with enforced pull requests"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "PR reviews not required on public ADMIN repo default branch '$default_branch'"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "PR reviews not required"
	else
		print_warn "PR reviews not required on $default_branch"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "PR reviews not required"
	fi
	return 0
}

_report_classic_check_requirement() {
	local default_branch="$1"
	local public_admin="$2"
	local required_checks="$3"

	if [[ "$required_checks" -gt 0 ]]; then
		print_pass "Required status checks configured ($required_checks check(s))"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Status checks configured: $required_checks"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "$NO_REQUIRED_STATUS_CHECKS_MSG on public ADMIN repo default branch '$default_branch'"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "$NO_REQUIRED_STATUS_CHECKS_MSG"
	else
		print_warn "$NO_REQUIRED_STATUS_CHECKS_MSG on $default_branch"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "$NO_REQUIRED_STATUS_CHECKS_MSG"
	fi
	return 0
}

_report_classic_admin_enforcement() {
	local public_admin="$1"
	local enforce_admins="$2"

	if [[ "$enforce_admins" == "true" ]]; then
		print_pass "Branch protection enforced for admins"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Enforced for admins"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "Branch protection allows admin bypass on public ADMIN repo"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "Not enforced for admins"
	else
		print_info "Branch protection not enforced for admins (common for solo repos)"
		add_finding "$SEVERITY_INFO" "$CAT_BRANCH_PROTECTION" "Not enforced for admins"
	fi
	return 0
}

# Phase 2: Check branch protection
check_branch_protection() {
	local repo_path="$1"
	local ruleset_details="${2:-}"

	print_header "Phase 2: Branch Protection"

	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI (gh) not installed — cannot check branch protection"
		add_finding "$SEVERITY_INFO" "$CAT_BRANCH_PROTECTION" "$GH_CLI_NOT_AVAILABLE_MSG"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "$NO_GITHUB_REMOTE_MSG — branch protection check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_BRANCH_PROTECTION" "$NO_GITHUB_REMOTE_MSG"
		return 0
	fi

	local default_branch public_admin protection_json
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
	default_branch="${default_branch:-main}"
	public_admin=0
	if _repo_is_public_admin "$slug"; then
		public_admin=1
		print_info "Repository is public and current token has admin access — PR merge gating is required"
	fi

	protection_json=$(_classic_branch_protection_json "$slug" "$default_branch") || true
	if [[ -z "$protection_json" || "$protection_json" == *"Not Found"* || "$protection_json" == *"Branch not protected"* ]]; then
		if [[ "$#" -ge 2 ]]; then
			_report_rulesets_branch_protection "$slug" "$default_branch" "$public_admin" "$ruleset_details"
		else
			_report_rulesets_branch_protection "$slug" "$default_branch" "$public_admin" ""
		fi
		return 0
	fi

	_report_classic_branch_protection "$protection_json" "$default_branch" "$public_admin"
	return 0
}

# Phase 3: Check review-bot-gate
check_review_bot_gate() {
	local repo_path="$1"

	print_header "Phase 3: Review Bot Gate"

	# Check if review-bot-gate workflow exists locally
	local gate_workflow="$repo_path/.github/workflows/review-bot-gate.yml"
	if [[ -f "$gate_workflow" ]]; then
		print_pass "review-bot-gate.yml workflow present"
		add_finding "$SEVERITY_PASS" "$CAT_REVIEW_BOT_GATE" "Workflow file present"
	else
		print_warn "No review-bot-gate.yml workflow — AI review bots may not be gated"
		add_finding "$SEVERITY_WARNING" "$CAT_REVIEW_BOT_GATE" "No review-bot-gate.yml workflow"
		print_info "  Suggestion: Copy from aidevops repo or add review-bot-gate as required check"
	fi

	# Check if review-bot-gate is a required status check (via branch protection)
	if ! command -v gh &>/dev/null; then
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		return 0
	fi

	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
	default_branch="${default_branch:-main}"

	local check_contexts
	check_contexts=$(gh api "repos/$slug/branches/$default_branch/protection/required_status_checks" 2>/dev/null | jq -r '.contexts[]? // empty' 2>/dev/null) || true

	if echo "$check_contexts" | grep -q "review-bot-gate" 2>/dev/null; then
		print_pass "review-bot-gate is a required status check"
		add_finding "$SEVERITY_PASS" "$CAT_REVIEW_BOT_GATE" "Required status check configured"
	else
		if [[ -f "$gate_workflow" ]]; then
			print_warn "review-bot-gate workflow exists but is not a required status check"
			add_finding "$SEVERITY_WARNING" "$CAT_REVIEW_BOT_GATE" "Not configured as required status check"
			print_info "  Add 'review-bot-gate' to branch protection required checks"
		fi
	fi

	return 0
}

_default_branch_for_repo() {
	local repo_path="$1"
	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
	default_branch="${default_branch:-main}"
	printf '%s\n' "$default_branch"
	return 0
}

_ruleset_targets_default_branch() {
	local detail="$1"
	local default_branch="$2"

	local include_patterns pattern
	include_patterns=$(jq -r '.conditions.ref_name.include // [] | .[]' <<<"$detail" 2>/dev/null) || return 1

	while IFS= read -r pattern; do
		[[ -z "$pattern" ]] && continue
		case "$pattern" in
		"refs/heads/${default_branch}" | "$RULESET_DEFAULT_BRANCH_TOKEN" | "$RULESET_ALL_BRANCHES_TOKEN" | "$RULESET_ALL_HEADS_PATTERN")
			return 0
			;;
		esac
	done <<<"$include_patterns"

	return 1
}

_default_branch_ruleset_details() {
	local slug="$1"
	local default_branch="$2"
	local rulesets_json="${3:-}"

	if [[ -z "$rulesets_json" ]]; then
		rulesets_json=$(gh api "repos/${slug}/rulesets" 2>/dev/null) || return 1
	fi
	[[ -z "$rulesets_json" || "$rulesets_json" == "[]" ]] && return 1

	local active_ids
	active_ids=$(jq -r --arg active "$RULESET_ENFORCEMENT_ACTIVE" '.[] | select(.enforcement == $active) | .id' <<<"$rulesets_json" 2>/dev/null) || return 1
	[[ -z "$active_ids" ]] && return 1

	local id detail
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		detail=$(gh api "repos/${slug}/rulesets/${id}" 2>/dev/null) || continue
		_ruleset_targets_default_branch "$detail" "$default_branch" || continue
		jq -c '.' <<<"$detail" 2>/dev/null || true
	done <<<"$active_ids"
	return 0
}

_classic_required_check_contexts() {
	local protection_json="$1"
	jq -r '(.required_status_checks.contexts // [])[], (.required_status_checks.checks // [])[].context? // empty' <<<"$protection_json" 2>/dev/null || true
	return 0
}

_rulesets_required_check_contexts() {
	local slug="$1"
	local default_branch="$2"
	local ruleset_details="${3:-}"

	if [[ "$#" -lt 3 ]]; then
		ruleset_details=$(_default_branch_ruleset_details "$slug" "$default_branch") || return 0
	fi
	[[ -z "$ruleset_details" ]] && return 0

	local detail
	while IFS= read -r detail; do
		[[ -z "$detail" ]] && continue
		jq -r '.rules[]? | select(.type == "required_status_checks") | (.parameters.required_status_checks // [])[] | (.context // .name // empty)' <<<"$detail" 2>/dev/null || true
	done <<<"$ruleset_details"
	return 0
}

_required_check_present() {
	local contexts="$1"
	local required_context="$2"
	printf '%s\n' "$contexts" | grep -qxF "$required_context" 2>/dev/null
	return $?
}

# Phase 3.25: Check maintainer authority workflow and required status.
# Public ADMIN repositories need this independently of native approval count so
# external contributions remain blocked by needs-maintainer-review while trusted
# maintainers can progress without synthetic cross-approvals.
check_maintainer_gate() {
	local repo_path="$1"
	local ruleset_details="${2:-}"

	print_header "Phase 3.25: Maintainer Authority Gate"

	local gate_workflow="$repo_path/.github/workflows/maintainer-gate.yml"
	local slug=""
	local public_admin=0
	if command -v gh &>/dev/null && slug=$(resolve_slug "$repo_path"); then
		if _repo_is_public_admin "$slug"; then
			public_admin=1
		fi
	fi

	if [[ -f "$gate_workflow" ]]; then
		print_pass "maintainer-gate.yml workflow present"
		add_finding "$SEVERITY_PASS" "$CAT_MAINTAINER_GATE" "Workflow file present"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "Missing maintainer-gate.yml on public ADMIN repo — external contributions lack NMR enforcement"
		add_finding "$SEVERITY_CRITICAL" "$CAT_MAINTAINER_GATE" "maintainer-gate.yml missing on public ADMIN repo"
		return 0
	else
		print_warn "Missing maintainer-gate.yml — external contributions may lack NMR enforcement"
		add_finding "$SEVERITY_WARNING" "$CAT_MAINTAINER_GATE" "maintainer-gate.yml missing"
		return 0
	fi

	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI unavailable — cannot verify maintainer-gate required status"
		add_finding "$SEVERITY_INFO" "$CAT_MAINTAINER_GATE" "GitHub CLI unavailable for maintainer-gate check"
		return 0
	fi

	if [[ -z "$slug" ]]; then
		print_skip "Maintainer-gate required status check skipped: GitHub remote unavailable"
		add_finding "$SEVERITY_INFO" "$CAT_MAINTAINER_GATE" "GitHub remote unavailable for maintainer-gate check"
		return 0
	fi

	local default_branch protection_json check_contexts
	default_branch=$(_default_branch_for_repo "$repo_path")
	protection_json=$(_classic_branch_protection_json "$slug" "$default_branch") || true
	check_contexts="$(_classic_required_check_contexts "$protection_json")"
	check_contexts+=$'\n'
	if [[ "$#" -ge 2 ]]; then
		check_contexts+="$(_rulesets_required_check_contexts "$slug" "$default_branch" "$ruleset_details")"
	else
		check_contexts+="$(_rulesets_required_check_contexts "$slug" "$default_branch")"
	fi

	if _required_check_present "$check_contexts" "maintainer-gate"; then
		print_pass "maintainer-gate is a required status check"
		add_finding "$SEVERITY_PASS" "$CAT_MAINTAINER_GATE" "Maintainer gate required status configured"
	elif [[ "$public_admin" -eq 1 ]]; then
		print_crit "maintainer-gate is not required on public ADMIN repo — external NMR can be bypassed"
		add_finding "$SEVERITY_CRITICAL" "$CAT_MAINTAINER_GATE" "maintainer-gate not required on public ADMIN repo"
	else
		print_warn "maintainer-gate workflow exists but is not required by branch protection or rulesets"
		add_finding "$SEVERITY_WARNING" "$CAT_MAINTAINER_GATE" "maintainer-gate not required"
	fi

	return 0
}

# Phase 3.5: Check linked-issue-check workflow and required status
check_linked_issue_gate() {
	local repo_path="$1"
	local ruleset_details="${2:-}"

	print_header "Phase 3.5: Linked-Issue PR Check"

	local gate_workflow="$repo_path/.github/workflows/linked-issue-check.yml"
	if [[ -f "$gate_workflow" ]]; then
		print_pass "linked-issue-check.yml workflow present"
		add_finding "$SEVERITY_PASS" "$CAT_LINKED_ISSUE_GATE" "Workflow file present"
	else
		print_warn "Missing linked-issue-check.yml workflow — PRs may merge without issue references"
		add_finding "$SEVERITY_WARNING" "$CAT_LINKED_ISSUE_GATE" "linked-issue-check.yml missing"
		return 0
	fi

	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI unavailable — cannot check linked-issue required status"
		add_finding "$SEVERITY_INFO" "$CAT_LINKED_ISSUE_GATE" "GitHub CLI unavailable for linked-issue check"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "Linked-issue required status check skipped: GitHub remote unavailable"
		add_finding "$SEVERITY_INFO" "$CAT_LINKED_ISSUE_GATE" "GitHub remote unavailable for linked-issue check"
		return 0
	fi

	local default_branch protection_json check_contexts
	default_branch=$(_default_branch_for_repo "$repo_path")
	protection_json=$(_classic_branch_protection_json "$slug" "$default_branch") || true
	check_contexts="$(_classic_required_check_contexts "$protection_json")"
	check_contexts+=$'\n'
	if [[ "$#" -ge 2 ]]; then
		check_contexts+="$(_rulesets_required_check_contexts "$slug" "$default_branch" "$ruleset_details")"
	else
		check_contexts+="$(_rulesets_required_check_contexts "$slug" "$default_branch")"
	fi

	if _required_check_present "$check_contexts" "linked-issue-check"; then
		print_pass "linked-issue-check is a required status check"
		add_finding "$SEVERITY_PASS" "$CAT_LINKED_ISSUE_GATE" "Required status check configured"
	else
		print_warn "linked-issue-check workflow exists but is not required by branch protection or rulesets"
		add_finding "$SEVERITY_WARNING" "$CAT_LINKED_ISSUE_GATE" "linked-issue-check not required"
		print_info "  Add 'linked-issue-check' to branch protection or default-branch rulesets"
	fi

	return 0
}

# Phase 4: Dependency scanning — helpers

# Check npm/Node.js dependencies via npm audit
# Usage: _check_npm_deps <repo-path>
# Sets has_deps=true if package.json found; emits findings directly.
_check_npm_deps() {
	local repo_path="$1"

	[[ -f "$repo_path/package.json" ]] || return 0
	# Signal to caller that at least one manifest was found
	has_deps=true
	print_info "Found package.json — checking npm dependencies..."

	if [[ ! -f "$repo_path/package-lock.json" ]]; then
		print_warn "package.json exists but no package-lock.json — cannot run npm audit"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "Missing package-lock.json"
		return 0
	fi

	if ! command -v npm &>/dev/null; then
		print_skip "npm not installed — cannot audit Node.js dependencies"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "npm not available"
		return 0
	fi

	local audit_output
	audit_output=$(npm audit --json --prefix "$repo_path" 2>/dev/null) || true

	if [[ -z "$audit_output" ]]; then
		print_skip "npm audit returned no output"
		return 0
	fi

	local vuln_total vuln_critical vuln_high
	vuln_total=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.total // 0' 2>/dev/null) || vuln_total="0"
	vuln_critical=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.critical // 0' 2>/dev/null) || vuln_critical="0"
	vuln_high=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.high // 0' 2>/dev/null) || vuln_high="0"

	if [[ "$vuln_critical" -gt 0 ]]; then
		print_crit "npm audit: $vuln_critical critical, $vuln_high high ($vuln_total total vulnerabilities)"
		add_finding "$SEVERITY_CRITICAL" "$CAT_DEPENDENCIES" "npm: $vuln_critical critical, $vuln_high high vulnerabilities"
	elif [[ "$vuln_high" -gt 0 ]]; then
		print_warn "npm audit: $vuln_high high ($vuln_total total vulnerabilities)"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "npm: $vuln_high high vulnerabilities"
	elif [[ "$vuln_total" -gt 0 ]]; then
		print_info "npm audit: $vuln_total low/moderate vulnerabilities"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "npm: $vuln_total low/moderate vulnerabilities"
	else
		print_pass "npm audit: no known vulnerabilities"
		add_finding "$SEVERITY_PASS" "$CAT_DEPENDENCIES" "npm: clean audit"
	fi

	return 0
}

# Check Python dependencies via pip-audit
# Usage: _check_pip_deps <repo-path>
_check_pip_deps() {
	local repo_path="$1"

	[[ -f "$repo_path/requirements.txt" ]] || [[ -f "$repo_path/pyproject.toml" ]] || return 0
	has_deps=true
	print_info "Found Python project — checking dependencies..."

	if ! command -v pip-audit &>/dev/null; then
		print_skip "pip-audit not installed — install with: pip install pip-audit"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "pip-audit not available"
		return 0
	fi

	local pip_output
	pip_output=$(pip-audit --requirement "$repo_path/requirements.txt" --format json 2>/dev/null) || true

	if [[ -z "$pip_output" ]]; then
		return 0
	fi

	local pip_vulns
	pip_vulns=$(echo "$pip_output" | jq 'length' 2>/dev/null) || pip_vulns="0"

	if [[ "$pip_vulns" -gt 0 ]]; then
		print_warn "pip-audit: $pip_vulns vulnerable package(s)"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "pip: $pip_vulns vulnerable packages"
	else
		print_pass "pip-audit: no known vulnerabilities"
		add_finding "$SEVERITY_PASS" "$CAT_DEPENDENCIES" "pip: clean audit"
	fi

	return 0
}

# Check Rust dependencies via cargo audit
# Usage: _check_cargo_deps <repo-path>
_check_cargo_deps() {
	local repo_path="$1"

	[[ -f "$repo_path/Cargo.toml" ]] || return 0
	has_deps=true

	if ! command -v cargo-audit &>/dev/null; then
		print_skip "cargo-audit not installed — install with: cargo install cargo-audit"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "cargo-audit not available"
		return 0
	fi

	print_info "Found Cargo.toml — running cargo audit..."
	local cargo_output
	cargo_output=$(cargo audit --json 2>/dev/null) || true

	if [[ -z "$cargo_output" ]]; then
		return 0
	fi

	local cargo_vulns
	cargo_vulns=$(echo "$cargo_output" | jq '.vulnerabilities.found // 0' 2>/dev/null) || cargo_vulns="0"

	if [[ "$cargo_vulns" -gt 0 ]]; then
		print_warn "cargo audit: $cargo_vulns vulnerability(ies)"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "cargo: $cargo_vulns vulnerabilities"
	else
		print_pass "cargo audit: no known vulnerabilities"
		add_finding "$SEVERITY_PASS" "$CAT_DEPENDENCIES" "cargo: clean audit"
	fi

	return 0
}

# Phase 4: Dependency scanning — orchestrator
check_dependencies() {
	local repo_path="$1"

	print_header "Phase 4: Dependency Security"

	local has_deps=false

	_check_npm_deps "$repo_path"
	_check_pip_deps "$repo_path"
	_check_cargo_deps "$repo_path"

	if [[ "$has_deps" == false ]]; then
		print_skip "No dependency manifests found (package.json, requirements.txt, Cargo.toml)"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "No dependency manifests found"
	fi

	return 0
}

# Phase 5: Check collaborators (per-repo, never cached globally)
check_collaborators() {
	local repo_path="$1"

	print_header "Phase 5: Collaborator Access"

	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI (gh) not installed"
		add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "$GH_CLI_NOT_AVAILABLE_MSG"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "$NO_GITHUB_REMOTE_MSG"
		add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "$NO_GITHUB_REMOTE_MSG"
		return 0
	fi

	# Per-repo collaborator check — never use a global cache (t1412.11: must paginate)
	local collab_json
	collab_json=$(_collaborator_access_json "$slug") || true

	if [[ -z "$collab_json" ]]; then
		print_skip "Cannot access collaborator list (may require admin permissions)"
		add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "Cannot access collaborator list"
		return 0
	fi

	local admin_count
	admin_count=$(echo "$collab_json" | jq -s '[.[] | select(.role == "admin")] | length' 2>/dev/null) || admin_count="0"
	local write_count
	write_count=$(echo "$collab_json" | jq -s '[.[] | select(.role == "write" or .role == "maintain")] | length' 2>/dev/null) || write_count="0"
	local total_count
	total_count=$(echo "$collab_json" | jq -s 'length' 2>/dev/null) || total_count="0"

	print_info "Collaborators: $total_count total ($admin_count admin, $write_count write)"
	add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "$total_count collaborators ($admin_count admin, $write_count write)"

	if [[ "$admin_count" -gt 5 ]]; then
		print_warn "High number of admin collaborators ($admin_count) — review access levels"
		add_finding "$SEVERITY_WARNING" "$CAT_COLLABORATORS" "High admin count: $admin_count"
	else
		print_pass "Admin collaborator count is reasonable ($admin_count)"
		add_finding "$SEVERITY_PASS" "$CAT_COLLABORATORS" "Admin count OK: $admin_count"
	fi

	return 0
}

# Phase 6: General repo security checks
check_repo_security() {
	local repo_path="$1"

	print_header "Phase 6: Repository Security"

	# Check for SECURITY.md
	if [[ -f "$repo_path/SECURITY.md" ]]; then
		print_pass "SECURITY.md present"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "SECURITY.md present"
	else
		print_warn "No SECURITY.md — add a security policy for vulnerability reporting"
		add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "Missing SECURITY.md"
	fi

	# Check for .gitignore with common secret patterns
	if [[ -f "$repo_path/.gitignore" ]]; then
		local missing_patterns=()
		for pattern in ".env" "*.pem" "*.key" "credentials.json"; do
			if ! grep -qF "$pattern" "$repo_path/.gitignore" 2>/dev/null; then
				missing_patterns+=("$pattern")
			fi
		done

		if [[ ${#missing_patterns[@]} -gt 0 ]]; then
			print_warn ".gitignore missing common secret patterns: ${missing_patterns[*]}"
			add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "gitignore missing: ${missing_patterns[*]}"
		else
			print_pass ".gitignore covers common secret file patterns"
			add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "gitignore covers secret patterns"
		fi
	else
		print_warn "No .gitignore file"
		add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "No .gitignore"
	fi

	# Check for committed secrets (quick scan of tracked files)
	local secret_files
	secret_files=$(git -C "$repo_path" ls-files '*.env' '*.pem' '*.key' 'credentials.json' '.env.*' 2>/dev/null) || true

	if [[ -n "$secret_files" ]]; then
		local secret_count
		secret_count=$(echo "$secret_files" | wc -l | tr -d ' ')
		print_crit "$secret_count potential secret file(s) tracked by git"
		add_finding "$SEVERITY_CRITICAL" "$CAT_REPO_SECURITY" "$secret_count secret files tracked: $(echo "$secret_files" | head -3 | tr '\n' ', ')"
	else
		print_pass "No obvious secret files tracked by git"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "No secret files tracked"
	fi

	# Check for Dependabot or Renovate config
	if [[ -f "$repo_path/.github/dependabot.yml" ]] || [[ -f "$repo_path/.github/dependabot.yaml" ]]; then
		print_pass "Dependabot configured"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "Dependabot configured"
	elif [[ -f "$repo_path/renovate.json" ]] || [[ -f "$repo_path/.github/renovate.json" ]] || [[ -f "$repo_path/renovate.json5" ]]; then
		print_pass "Renovate configured"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "Renovate configured"
	else
		print_warn "No automated dependency update tool (Dependabot/Renovate)"
		add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "No dependency update automation"
	fi

	return 0
}

# Phase 7: SYNC_PAT detection helpers (t2374)

# Emit a SYNC_PAT advisory file for a repo that needs it.
# Usage: _emit_sync_pat_advisory <slug> <slug_sanitised> <advisory_file> <protection_desc>
# protection_desc is a human-readable description of the detected protection,
# e.g. "requiring 1 approving review(s)" (classic) or "rulesets-based
# protection" (t2806, rulesets path).
_emit_sync_pat_advisory() {
	local slug="$1"
	local slug_sanitised="$2"
	local advisory_file="$3"
	local protection_desc="$4"

	local advisory_dir
	advisory_dir="$(dirname "$advisory_file")"
	mkdir -p "$advisory_dir"

	cat >"$advisory_file" <<ADVISORY_EOF
[ADVISORY] SYNC_PAT not set for ${slug}

This repo uses issue-sync.yml and has protection on the default branch
(${protection_desc}).
Direct publication therefore routes through one deterministic pull request.
This repository does not allow GitHub Actions to create pull requests, so the
job-scoped token cannot open that fallback PR. Without SYNC_PAT, TODO.md
auto-completion fails after publishing its protected-branch candidate.

For a guided fix across all affected repos, run \`/setup-git\` in
your AI assistant (OpenCode or Claude Code). It walks you through
each repo with the correct pre-filled token-creation URL.

To fix this single repo manually (run in a separate terminal, NOT in AI chat):

1. Create a fine-grained PAT for this repository with Contents: Read and write
   and Pull requests: Read and write (the URL pre-fills the Contents scope):
   https://github.com/settings/personal-access-tokens/new?name=aidevops-sync-pat&description=SYNC_PAT+for+aidevops+TODO+auto-completion&expires_in=none&target_name=${slug}&permissions=contents:write,metadata:read

2. Set the secret:
   gh secret set SYNC_PAT --repo ${slug}
   (interactive prompt — safer than --body which lands in shell history)

Verify:
   gh secret list --repo ${slug} | grep SYNC_PAT

Dismiss once fixed:
   aidevops security dismiss sync-pat-${slug_sanitised}

See AGENTS.md "Known limitation — issue-sync TODO auto-completion" for background.
ADVISORY_EOF

	print_info "  Advisory written to: $advisory_file"
	return 0
}

# Check whether the default branch is protected via repository rulesets
# (the modern replacement for classic branch-protection rules, see t2806).
# Returns 0 if any active ruleset targets the default branch with a
# meaningful protection rule; 1 otherwise (including API errors).
# Usage: _branch_is_rulesets_protected <slug> <default_branch> [ruleset-details]
#
# Fail-open: empty/errored rulesets API returns 1 (not protected). A
# false negative here loses the advisory; a false positive just results
# in an advisory the user can dismiss. Per t2806, we prefer the former
# because classic detection already covers the review-requiring cases.
_branch_is_rulesets_protected() {
	local slug="$1"
	local default_branch="$2"
	local ruleset_details="${3:-}"

	if [[ "$#" -lt 3 ]]; then
		ruleset_details=$(_default_branch_ruleset_details "$slug" "$default_branch") || return 1
	fi
	[[ -z "$ruleset_details" ]] && return 1

	local detail rule_types
	while IFS= read -r detail; do
		[[ -z "$detail" ]] && continue

		# Protection signals: pull_request review requirement OR
		# required_status_checks. Either blocks direct bot pushes via
		# the PR-required or checks-required gate, and is a strong
		# signal that SYNC_PAT is needed downstream (t2449 author
		# association chain, t2806).
		rule_types=$(jq -r '.rules[].type' <<<"$detail" 2>/dev/null) || continue
		if grep -qE '^(pull_request|required_status_checks)$' <<<"$rule_types"; then
			return 0
		fi
	done <<<"$ruleset_details"

	return 1
}

# Return 0 when the repository permits GITHUB_TOKEN to create pull requests.
# GitHub exposes the combined "create and approve" repository setting through
# can_approve_pull_request_reviews on the Actions workflow-permissions endpoint.
_actions_can_create_pull_requests() {
	local slug="$1"
	local permissions_json
	permissions_json=$(gh api "repos/${slug}/actions/permissions/workflow" 2>/dev/null) || return 1
	if jq -e '.can_approve_pull_request_reviews == true' <<<"$permissions_json" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Check whether a repo requires SYNC_PAT based on workflow + branch protection.
# Writes result to global SYNC_PAT_NEED_RESULT: "needed:<desc>" | "not_needed".
# Side effect: prints findings and cleans stale advisories.
#
# NOTE (t2806): earlier versions returned the result via stdout capture
# (`$()`), which was broken because `print_pass` / `add_finding` also
# write to stdout — the captured result included ANSI-wrapped "[PASS]"
# lines and the equality check against "not_needed" failed. Using a
# dedicated global eliminates the capture conflict entirely.
#
# Usage: _check_sync_pat_need <repo_path> <slug> <advisory_file> [ruleset-details]
_check_sync_pat_need() {
	local repo_path="$1"
	local slug="$2"
	local advisory_file="$3"
	local ruleset_details="${4:-}"

	SYNC_PAT_NEED_RESULT=""

	# Step 1: Does the repo use issue-sync.yml?
	if ! gh api "repos/${slug}/contents/.github/workflows/issue-sync.yml" &>/dev/null 2>&1; then
		print_pass "No issue-sync.yml — SYNC_PAT not needed for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "No issue-sync.yml in $slug"
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		SYNC_PAT_NEED_RESULT="$SYNC_PAT_NEED_NOT_NEEDED"
		return 0
	fi

	# Step 2: Does the repo have branch protection?
	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
	default_branch="${default_branch:-main}"

	# Step 2a: Classic branch-protection endpoint (legacy path).
	local protection_json
	protection_json=$(gh api "repos/${slug}/branches/${default_branch}/protection" 2>/dev/null) || true

	local protected_kind="none"
	local protection_desc=""

	if [[ -n "$protection_json" && "$protection_json" != *"Not Found"* && "$protection_json" != *"Branch not protected"* ]]; then
		protected_kind="$SYNC_PAT_PROTECTION_CLASSIC"
	elif { [[ "$#" -ge 4 ]] && _branch_is_rulesets_protected "$slug" "$default_branch" "$ruleset_details"; } || { [[ "$#" -lt 4 ]] && _branch_is_rulesets_protected "$slug" "$default_branch"; }; then
		# Step 2b: Rulesets-based protection (t2806). Modern repos
		# return 404 on the classic endpoint but carry rulesets via
		# /repos/{slug}/rulesets — the legacy detector silently
		# skipped these. See GH#20745.
		protected_kind="rulesets"
		protection_desc="rulesets-based protection"
	fi

	if [[ "$protected_kind" == "none" ]]; then
		print_pass "No branch protection — SYNC_PAT not needed for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "No branch protection in $slug"
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		SYNC_PAT_NEED_RESULT="$SYNC_PAT_NEED_NOT_NEEDED"
		return 0
	fi
	if [[ "$protected_kind" == "$SYNC_PAT_PROTECTION_CLASSIC" ]] &&
		! jq -e '.required_pull_request_reviews != null or .required_status_checks != null' \
			<<<"$protection_json" >/dev/null 2>&1; then
		print_pass "Branch protection does not block direct issue-sync publication — SYNC_PAT not needed for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "No publication-blocking protection in $slug"
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		SYNC_PAT_NEED_RESULT="$SYNC_PAT_NEED_NOT_NEEDED"
		return 0
	fi

	# The job-scoped token is sufficient when Actions may create pull requests,
	# even though direct publication is blocked by default-branch protection.
	if _actions_can_create_pull_requests "$slug"; then
		print_pass "Actions can create the issue-sync PR — SYNC_PAT not needed for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "Actions PR creation enabled in $slug"
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		SYNC_PAT_NEED_RESULT="$SYNC_PAT_NEED_NOT_NEEDED"
		return 0
	fi

	# When Actions PR creation is disabled, every meaningful default-branch
	# protection path needs the PAT fallback. Zero required approvals does not
	# remove the repository's pull-request or status-check requirement.
	if [[ "$protected_kind" == "$SYNC_PAT_PROTECTION_CLASSIC" ]]; then
		local required_reviews
		required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null) || required_reviews="0"

		if [[ "$required_reviews" -gt 0 ]]; then
			protection_desc="requiring ${required_reviews} approving review(s) with Actions PR creation disabled"
		else
			protection_desc="classic branch protection with Actions PR creation disabled"
		fi
	else
		protection_desc="${protection_desc} with Actions PR creation disabled"
	fi

	# Step 3: Is SYNC_PAT set?
	local secret_check
	secret_check=$(gh secret list --repo "$slug" --json name -q '.[] | select(.name == "SYNC_PAT") | .name' 2>/dev/null) || true

	if [[ -n "$secret_check" ]]; then
		print_pass "SYNC_PAT is set for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "SYNC_PAT set for $slug"
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		SYNC_PAT_NEED_RESULT="$SYNC_PAT_NEED_NOT_NEEDED"
		return 0
	fi

	# Needs SYNC_PAT — return the protection description for the advisory
	SYNC_PAT_NEED_RESULT="needed:${protection_desc}"
	return 0
}

# Phase 7: Check SYNC_PAT secret for repos using issue-sync.yml (t2374)
# Detects repos that need SYNC_PAT but don't have it set, and emits
# per-repo advisories via ~/.aidevops/advisories/sync-pat-<slug>.advisory.
check_sync_pat() {
	local repo_path="$1"
	local ruleset_details="${2:-}"

	print_header "Phase 7: SYNC_PAT Detection (issue-sync)"

	# Need gh CLI
	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI (gh) not installed — cannot check SYNC_PAT"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "$GH_CLI_NOT_AVAILABLE_MSG"
		return 0
	fi

	# Need authenticated gh — fail open on auth failure
	if ! gh auth status &>/dev/null 2>&1; then
		print_skip "gh not authenticated — SYNC_PAT check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "gh not authenticated"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "$NO_GITHUB_REMOTE_MSG — SYNC_PAT check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "$NO_GITHUB_REMOTE_MSG"
		return 0
	fi

	local slug_sanitised
	slug_sanitised="${slug//\//-}"

	local advisory_dir="$HOME/.aidevops/advisories"
	local advisory_file="$advisory_dir/sync-pat-${slug_sanitised}.advisory"
	local dismissed_file="$advisory_dir/.dismissed-sync-pat-${slug_sanitised}"

	# If already dismissed, skip silently
	if [[ -f "$dismissed_file" ]]; then
		print_pass "SYNC_PAT advisory dismissed for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "Advisory dismissed for $slug"
		return 0
	fi

	# Check need via helper. Result is written to SYNC_PAT_NEED_RESULT — NOT
	# returned via stdout, because `print_pass` / `add_finding` inside the
	# helper also write to stdout and would pollute a `$()` capture (t2806).
	if [[ "$#" -ge 2 ]]; then
		_check_sync_pat_need "$repo_path" "$slug" "$advisory_file" "$ruleset_details"
	else
		_check_sync_pat_need "$repo_path" "$slug" "$advisory_file"
	fi

	if [[ "$SYNC_PAT_NEED_RESULT" == "$SYNC_PAT_NEED_NOT_NEEDED" ]]; then
		return 0
	fi

	# Extract protection description from "needed:<description>" result.
	# For classic protection this is e.g. "requiring 1 approving review(s)";
	# for rulesets-based protection (t2806) it is "rulesets-based protection".
	local protection_desc
	protection_desc="${SYNC_PAT_NEED_RESULT#needed:}"

	print_warn "SYNC_PAT not set for $slug — protected issue-sync cannot create its fallback PR"
	add_finding "$SEVERITY_WARNING" "$CAT_SYNC_PAT" "SYNC_PAT not set for $slug"

	_emit_sync_pat_advisory "$slug" "$slug_sanitised" "$advisory_file" "$protection_desc"

	return 0
}

# Phase 8: Cross-account secrets:inherit detection helpers (t2880)

# Detect whether a repo's issue-sync.yml uses the cross-account secrets:inherit
# pattern — i.e., it calls the marcusquinn/aidevops reusable workflow AND relies
# on secrets:inherit rather than mapping SYNC_PAT explicitly.
#
# GitHub policy: secrets:inherit only propagates within the same org/enterprise.
# A caller in a different org will silently receive no secrets, causing
# issue-sync to fail with insufficient permissions.
#
# Usage: _detect_cross_account_inherit <slug>
# Returns:
#   0 — broken pattern detected (caller + secrets:inherit present)
#   1 — not broken (explicit mapping, OR not a marcusquinn/aidevops caller)
#   2 — file missing or unfetchable (skip silently)
_detect_cross_account_inherit() {
	local slug="$1"

	local workflow_content
	workflow_content=$(gh api "repos/${slug}/contents/.github/workflows/issue-sync.yml" \
		--jq '.content' 2>/dev/null) || return 2

	if [[ -z "$workflow_content" ]]; then
		return 2
	fi

	local decoded
	decoded=$(printf '%s' "$workflow_content" | base64 -d 2>/dev/null) || return 2

	# Must be a marcusquinn/aidevops reusable-workflow caller
	if ! printf '%s' "$decoded" | grep -q 'uses:.*marcusquinn/aidevops/'; then
		return 1
	fi

	# Must use an active secrets:inherit key (the broken cross-account pattern).
	# Explanatory comments in the canonical caller must not trigger the advisory.
	if ! printf '%s' "$decoded" | grep -qE \
		'^[[:space:]]*secrets:[[:space:]]*inherit([[:space:]]+#.*)?[[:space:]]*$'; then
		return 1
	fi

	return 0
}

# Emit a cross-account-inherit advisory file for a repo that uses secrets:inherit.
# Usage: _emit_cross_account_inherit_advisory <slug> <slug_sanitised>
_emit_cross_account_inherit_advisory() {
	local slug="$1"
	local slug_sanitised="$2"

	local advisory_dir="$HOME/.aidevops/advisories"
	local advisory_file="$advisory_dir/cross-account-inherit-${slug_sanitised}.advisory"

	mkdir -p "$advisory_dir"

	cat >"$advisory_file" <<ADVISORY_EOF
[ADVISORY] Cross-account secrets:inherit detected for ${slug}

This repo's .github/workflows/issue-sync.yml calls the marcusquinn/aidevops
reusable workflow with \`secrets: inherit\` instead of an explicit
\`secrets: SYNC_PAT: \${{ secrets.SYNC_PAT }}\` mapping.

GitHub only propagates secrets:inherit within the same org/enterprise. Callers
from a different account (org or personal) silently receive no secrets — so
issue-sync will fail with permission errors on every run without any obvious
error message pointing at this root cause.

The fix is to re-sync the workflow from the updated canonical template:

  aidevops sync-workflows --apply --repo ${slug}

This replaces the secrets:inherit line with the explicit SYNC_PAT mapping that
works across org/account boundaries (fix landed in #20976).

For a guided walkthrough across all affected repos, run \`/setup-git\` in
your AI assistant (OpenCode or Claude Code).

Dismiss once fixed:
  aidevops security dismiss cross-account-inherit-${slug_sanitised}

See reference/reusable-workflows.md for the cross-account secrets architecture.
ADVISORY_EOF

	print_info "  Advisory written to: $advisory_file"
	return 0
}

# Phase 8: Check for cross-account secrets:inherit in issue-sync.yml (t2880)
# For each repo using the marcusquinn/aidevops reusable workflow with
# secrets:inherit, emits a cross-account-inherit advisory so setup-debt-helper.sh
# can surface it in the toast and /setup-git can walk the operator through the fix.
check_cross_account_inherit() {
	local repo_path="$1"

	print_header "Phase 8: Cross-Account secrets:inherit Detection (t2880)"

	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI (gh) not installed — cannot check cross-account inherit"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "$GH_CLI_NOT_AVAILABLE_MSG (cross-account check)"
		return 0
	fi

	if ! gh auth status &>/dev/null 2>&1; then
		print_skip "gh not authenticated — cross-account inherit check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "gh not authenticated (cross-account check)"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "$NO_GITHUB_REMOTE_MSG — cross-account inherit check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "$NO_GITHUB_REMOTE_MSG (cross-account check)"
		return 0
	fi

	local slug_sanitised
	slug_sanitised="${slug//\//-}"

	local advisory_dir="$HOME/.aidevops/advisories"
	local dismissed_file="$advisory_dir/dismissed.txt"

	# If already dismissed, skip silently
	local adv_id="cross-account-inherit-${slug_sanitised}"
	if [[ -f "$dismissed_file" ]] && grep -qxF "$adv_id" "$dismissed_file" 2>/dev/null; then
		print_pass "cross-account-inherit advisory dismissed for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "cross-account-inherit advisory dismissed for $slug"
		return 0
	fi

	local detect_result=0
	_detect_cross_account_inherit "$slug" || detect_result=$?

	case "$detect_result" in
	0)
		# Broken pattern detected
		print_warn "Cross-account secrets:inherit detected for $slug — run: aidevops sync-workflows --apply --repo $slug"
		add_finding "$SEVERITY_WARNING" "$CAT_SYNC_PAT" "Cross-account secrets:inherit in issue-sync.yml for $slug"
		_emit_cross_account_inherit_advisory "$slug" "$slug_sanitised"
		;;
	1)
		# Not broken
		print_pass "issue-sync.yml cross-account pattern OK for $slug"
		add_finding "$SEVERITY_PASS" "$CAT_SYNC_PAT" "issue-sync.yml cross-account pattern OK for $slug"
		;;
	2)
		# Missing / unfetchable — skip silently
		print_skip "issue-sync.yml not found for $slug — cross-account inherit check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_SYNC_PAT" "issue-sync.yml missing for $slug"
		;;
	esac

	return 0
}

# Store security posture in .aidevops.json
store_posture() {
	local repo_path="$1"
	local config_file="$repo_path/.aidevops.json"

	if [[ ! -f "$config_file" ]]; then
		print_info "No .aidevops.json found — skipping posture storage"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warn "jq not installed — cannot store posture in .aidevops.json"
		return 0
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local total_findings
	total_findings=$((FINDINGS_CRITICAL + FINDINGS_WARNING + FINDINGS_INFO + FINDINGS_PASS))

	local posture_status="$SECURITY_POSTURE_UNKNOWN"
	if [[ "$FINDINGS_CRITICAL" -gt 0 ]]; then
		posture_status="$SEVERITY_CRITICAL"
	elif [[ "$FINDINGS_WARNING" -gt 0 ]]; then
		posture_status="$SEVERITY_WARNING"
	elif [[ "$FINDINGS_INFO" -gt 0 && "$FINDINGS_PASS" -eq 0 ]]; then
		posture_status="partial"
	elif [[ "$total_findings" -gt 0 ]]; then
		posture_status="good"
	fi

	local temp_file="${config_file}.tmp"
	jq --arg status "$posture_status" \
		--arg ts "$timestamp" \
		--argjson critical "$FINDINGS_CRITICAL" \
		--argjson warnings "$FINDINGS_WARNING" \
		--argjson info "$FINDINGS_INFO" \
		--argjson passed "$FINDINGS_PASS" \
		--argjson findings "$FINDINGS_JSON" \
		'.security_posture = {
			"status": $status,
			"last_audit": $ts,
			"critical": $critical,
			"warnings": $warnings,
			"info": $info,
			"passed": $passed,
			"findings": $findings
		}' "$config_file" >"$temp_file" && mv "$temp_file" "$config_file"

	print_info "Security posture stored in .aidevops.json (status: $posture_status)"
	return 0
}

# Print summary (one-line for greeting — per-repo)
print_summary() {
	local repo_path="$1"

	# Try to read from stored posture first
	local config_file="$repo_path/.aidevops.json"
	if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
		local stored_status
		stored_status=$(jq -r '.security_posture.status // empty' "$config_file" 2>/dev/null) || true

		if [[ -n "$stored_status" ]]; then
			local stored_critical
			stored_critical=$(jq -r '.security_posture.critical // 0' "$config_file" 2>/dev/null) || stored_critical="0"
			local stored_warnings
			stored_warnings=$(jq -r '.security_posture.warnings // 0' "$config_file" 2>/dev/null) || stored_warnings="0"
			local stored_ts
			stored_ts=$(jq -r --arg unknown "$SECURITY_POSTURE_UNKNOWN" '.security_posture.last_audit // $unknown' "$config_file" 2>/dev/null) || stored_ts="$SECURITY_POSTURE_UNKNOWN"

			case "$stored_status" in
			critical)
				echo "Security: $stored_critical critical issue(s), $stored_warnings warning(s) — run \`aidevops security audit\` (last: $stored_ts)"
				;;
			warning)
				echo "Security: $stored_warnings warning(s) — run \`aidevops security audit\` for details (last: $stored_ts)"
				;;
			partial)
				echo "Security: audit completed with skipped checks — review findings (last: $stored_ts)"
				;;
			good)
				echo "Security: all checks passed (last: $stored_ts)"
				;;
			*)
				echo "Security: run \`aidevops security audit\` for baseline assessment"
				;;
			esac
			return 0
		fi
	fi

	echo "Security: not yet audited — run \`aidevops security audit\`"
	return 0
}

# Print final report
print_report() {
	echo ""
	echo -e "${BOLD}═══════════════════════════════════════${NC}"
	echo -e "${BOLD}  Security Posture Summary${NC}"
	echo -e "${BOLD}═══════════════════════════════════════${NC}"
	echo ""

	if [[ "$FINDINGS_CRITICAL" -gt 0 ]]; then
		echo -e "  ${RED}Critical:${NC}  $FINDINGS_CRITICAL"
	fi
	if [[ "$FINDINGS_WARNING" -gt 0 ]]; then
		echo -e "  ${YELLOW}Warnings:${NC}  $FINDINGS_WARNING"
	fi
	echo -e "  ${GREEN}Passed:${NC}    $FINDINGS_PASS"
	echo -e "  ${CYAN}Info/Skip:${NC} $FINDINGS_INFO"
	echo ""

	local total_issues=$((FINDINGS_CRITICAL + FINDINGS_WARNING))
	if [[ "$total_issues" -eq 0 ]]; then
		echo -e "  ${GREEN}${BOLD}Overall: GOOD${NC} — no critical or warning findings"
	elif [[ "$FINDINGS_CRITICAL" -gt 0 ]]; then
		echo -e "  ${RED}${BOLD}Overall: CRITICAL${NC} — $FINDINGS_CRITICAL critical issue(s) need attention"
	else
		echo -e "  ${YELLOW}${BOLD}Overall: WARNING${NC} — $FINDINGS_WARNING issue(s) to review"
	fi
	echo ""

	return 0
}

# Run all per-repo checks
run_all_checks() {
	local repo_path="$1"

	echo -e "${CYAN}"
	echo "╔═══════════════════════════════════════════════════════════╗"
	echo "║         Per-Repo Security Posture Assessment             ║"
	echo "╚═══════════════════════════════════════════════════════════╝"
	echo -e "${NC}"

	print_info "Repository: $repo_path"

	local slug default_branch ruleset_details
	if command -v gh &>/dev/null && slug=$(resolve_slug "$repo_path"); then
		default_branch=$(_default_branch_for_repo "$repo_path")
		ruleset_details=$(_default_branch_ruleset_details "$slug" "$default_branch") || ruleset_details=""
	else
		ruleset_details=""
	fi

	check_workflow_security "$repo_path"
	check_branch_protection "$repo_path" "$ruleset_details"
	check_review_bot_gate "$repo_path"
	check_maintainer_gate "$repo_path" "$ruleset_details"
	check_linked_issue_gate "$repo_path" "$ruleset_details"
	check_dependencies "$repo_path"
	check_collaborators "$repo_path"
	check_repo_security "$repo_path"
	check_sync_pat "$repo_path" "$ruleset_details"
	check_cross_account_inherit "$repo_path"
	print_report

	return 0
}
