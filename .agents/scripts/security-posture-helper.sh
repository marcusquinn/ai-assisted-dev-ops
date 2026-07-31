#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# security-posture-helper.sh — Security posture assessment (orchestrator)
# =============================================================================
# Thin orchestrator that sources per-repo audit and user-level sub-libraries.
# Split from a 1749-line monolith per reference/large-file-split.md.
#
# Two modes:
#   A. Per-repo audit (t1412.11) — scans a repository for security baseline issues
#   B. User-level startup check (t1412.6) — checks user's security configuration
#
# Per-repo audit commands:
#   security-posture-helper.sh check [repo-path]    # Run all repo checks, report findings
#   security-posture-helper.sh audit [repo-path]     # Alias for check
#   security-posture-helper.sh store [repo-path]     # Run checks and store in .aidevops.json
#   security-posture-helper.sh summary [repo-path]   # One-line summary for greeting
#
# User-level commands:
#   security-posture-helper.sh startup-check         # One-line summary for session greeting
#   security-posture-helper.sh setup                 # Interactive guided setup
#   security-posture-helper.sh status                # Detailed status report
#
#   security-posture-helper.sh help                  # Show usage
#
# Exit codes:
#   0 — All checks passed (or setup completed)
#   1 — Findings detected (non-zero issues / actions needed)
#   2 — Error (missing args, tool failure)
#
# Sub-libraries (sourced below):
#   - security-posture-helper-repo.sh  — per-repo audit checks (mode A)
#   - security-posture-helper-user.sh  — user-level checks and setup (mode B)
#
# t1412.6:  https://github.com/marcusquinn/aidevops/issues/3078
# t1412.11: https://github.com/marcusquinn/aidevops/issues/3087

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Paths
readonly AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$CONFIG_DIR/credentials.sh"

# ============================================================
# SHARED CONSTANTS (used by both sub-libraries)
# ============================================================

# Severity level constants (SonarCloud: avoid repeated string literals)
readonly SEVERITY_CRITICAL="critical"
readonly SEVERITY_WARNING="warning"
readonly SEVERITY_INFO="info"
readonly SEVERITY_PASS="pass"

# Category constants (SonarCloud: avoid repeated string literals)
readonly CAT_WORKFLOWS="workflows"
readonly CAT_BRANCH_PROTECTION="branch_protection"
readonly CAT_REVIEW_BOT_GATE="review_bot_gate"
readonly CAT_MAINTAINER_GATE="maintainer_gate"
readonly CAT_LINKED_ISSUE_GATE="linked_issue_gate"
readonly CAT_DEPENDENCIES="dependencies"
readonly CAT_COLLABORATORS="collaborators"
readonly CAT_REPO_SECURITY="repo_security"
readonly CAT_SYNC_PAT="sync_pat"

# Counters
FINDINGS_CRITICAL=0
FINDINGS_WARNING=0
FINDINGS_INFO=0
FINDINGS_PASS=0

# Collected findings for JSON output
FINDINGS_JSON="[]"

# ============================================================
# UTILITY FUNCTIONS (shared across sub-libraries)
# ============================================================

print_info() {
	local msg="$1"
	echo -e "${BLUE}[INFO]${NC} $msg"
	return 0
}
print_pass() {
	local msg="$1"
	echo -e "${GREEN}[PASS]${NC} $msg"
	((++FINDINGS_PASS))
	return 0
}
print_warn() {
	local msg="$1"
	echo -e "${YELLOW}[WARN]${NC} $msg"
	((++FINDINGS_WARNING))
	return 0
}
print_crit() {
	local msg="$1"
	echo -e "${RED}[CRIT]${NC} $msg"
	((++FINDINGS_CRITICAL))
	return 0
}
print_skip() {
	local msg="$1"
	echo -e "${CYAN}[SKIP]${NC} $msg"
	((++FINDINGS_INFO))
	return 0
}
print_header() {
	local msg="$1"
	echo -e "\n${BOLD}${CYAN}$msg${NC}"
	return 0
}

# Add a finding to the JSON array
# Usage: add_finding <severity> <category> <message>
add_finding() {
	local severity="$1"
	local category="$2"
	local message="$3"

	FINDINGS_JSON=$(echo "$FINDINGS_JSON" | jq \
		--arg sev "$severity" \
		--arg cat "$category" \
		--arg msg "$message" \
		'. += [{"severity": $sev, "category": $cat, "message": $msg}]')
	return 0
}

# Resolve the GitHub slug for a repo path
# Usage: resolve_slug <repo-path>
resolve_slug() {
	local repo_path="$1"
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	local slug
	slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	if [[ -n "$slug" && "$slug" == *"/"* ]]; then
		echo "$slug"
		return 0
	fi
	return 1
}

# ============================================================
# SOURCE SUB-LIBRARIES
# ============================================================

# shellcheck source=./security-posture-helper-repo.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/security-posture-helper-repo.sh"

# shellcheck source=./security-posture-helper-user.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/security-posture-helper-user.sh"

# ============================================================
# HELP & MAIN
# ============================================================

# Print usage
print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [repo-path]

Per-repo audit commands:
  check [path]         Run all security posture checks (default: current dir)
  audit [path]         Alias for check
  store [path]         Run checks and store results in .aidevops.json
  summary [path]       Print one-line summary (for session greeting)

User-level commands:
  startup-check        One-line user security posture for session greeting
  setup                Interactive guided security setup
  status               Detailed user security posture report

  help                 Show this help message

Per-repo checks (check/audit/store):
  1. GitHub Actions workflows for unsafe AI patterns
  2. Branch protection (pull requests and required status checks)
  3. Review-bot-gate as required status check
  4. Maintainer-gate as required NMR authority check
  5. Linked-issue-check as required status check
  6. Dependency vulnerabilities (npm/pip/cargo audit)
  7. Collaborator access levels (per-repo, never cached)
  8. Repository security basics (SECURITY.md, .gitignore, secrets)
  9. SYNC_PAT detection for repos using issue-sync.yml (t2374)
  10. Cross-account secrets:inherit detection

User-level checks (startup-check/setup/status):
  1. Prompt injection patterns (YAML file present and <30d old)
  2. Secret storage backend (gopass or credentials.sh with 600 perms)
  3. GitHub CLI authentication (gh auth status)
  4. SSH key (id_ed25519 or id_rsa)
  5. Git commit signing (optional, informational only)
  6. Secret scanning tool (secretlint installed)

Examples:
  $(basename "$0") check                    # Audit current repo
  $(basename "$0") check ~/Git/myproject    # Audit specific repo
  $(basename "$0") store                    # Audit and store in .aidevops.json
  $(basename "$0") startup-check            # Quick user posture for greeting
  $(basename "$0") setup                    # Walk through user security fixes

Exit codes:
  0 — All checks passed
  1 — Findings detected / actions needed
  2 — Error
EOF
	return 0
}

# Main
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	# Per-repo audit commands (t1412.11)
	check | audit)
		local repo_path="${1:-.}"
		if git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			repo_path=$(git -C "$repo_path" rev-parse --show-toplevel)
		fi
		run_all_checks "$repo_path"
		store_posture "$repo_path"
		local exit_code=0
		if [[ "$FINDINGS_CRITICAL" -gt 0 || "$FINDINGS_WARNING" -gt 0 ]]; then
			exit_code=1
		fi
		return "$exit_code"
		;;
	store)
		local repo_path="${1:-.}"
		if git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			repo_path=$(git -C "$repo_path" rev-parse --show-toplevel)
		fi
		run_all_checks "$repo_path"
		store_posture "$repo_path"
		if [[ "$FINDINGS_CRITICAL" -gt 0 || "$FINDINGS_WARNING" -gt 0 ]]; then
			return 1
		fi
		return 0
		;;
	summary)
		local repo_path="${1:-.}"
		if git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			repo_path=$(git -C "$repo_path" rev-parse --show-toplevel)
		fi
		print_summary "$repo_path"
		return 0
		;;
	# User-level commands (t1412.6)
	startup-check)
		cmd_startup_check
		;;
	setup)
		cmd_setup
		;;
	status)
		cmd_status
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		echo "Unknown command: $command" >&2
		print_usage >&2
		return 2
		;;
	esac
}

main "$@"
