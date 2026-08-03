#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# label-sync-helper.sh — Canonical GitHub label color definitions and cross-repo sync.
#
# Defines the authoritative color palette for all aidevops-managed labels.
# Syncs labels across all repos in repos.json (non-local, admin-accessible).
#
# Usage:
#   label-sync-helper.sh sync [--dry-run] [--repo owner/repo]
#   label-sync-helper.sh audit [--repo owner/repo]
#   label-sync-helper.sh color-for-tag <tag-name>
#
# The "sync" command applies canonical colors to all managed repos.
# The "audit" command reports drift (labels with wrong colors).
# The "color-for-tag" command returns the canonical color hex for a TODO.md tag.

set -euo pipefail

# Source shared constants (colors, logging, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

LOG_PREFIX="LABEL-SYNC"

# =============================================================================
# Canonical Label Definitions
# =============================================================================
# Format: "name|color|description"
# Colors are 6-char hex WITHOUT the # prefix (GitHub API format).
#
# These are the SINGLE SOURCE OF TRUTH for label colors. Every other script
# that creates labels should either call this helper or use color_for_tag().

# --- GitHub Defaults (standard issue triage) ---
GITHUB_DEFAULT_LABELS=(
	"bug|D73A4A|Something isn't working"
	"documentation|0075CA|Improvements or additions to documentation"
	"duplicate|CFD3D7|This issue or pull request already exists"
	"enhancement|A2EEEF|New feature or request"
	"good first issue|7057FF|Good for newcomers"
	"help wanted|008672|Extra attention is needed"
	"invalid|E4E669|This doesn't seem right"
	"question|D876E3|Further information is requested"
	"wontfix|FFFFFF|This will not be worked on"
)

# --- Status Lifecycle (mutually exclusive, managed by set_issue_status) ---
STATUS_LABELS=(
	"status:available|0E8A16|Task is available for claiming"
	"status:queued|FBCA04|Worker dispatched, not yet started"
	"status:claimed|F9D0C4|Interactive session claimed this task"
	"status:in-progress|1D76DB|Worker actively running"
	"status:in-review|5319E7|PR open, awaiting review/merge"
	"status:done|6F42C1|Task is complete"
	"status:blocked|D73A4A|Waiting on blocker task"
)

# --- Status Exceptions (out-of-band, not managed by set_issue_status) ---
STATUS_EXCEPTION_LABELS=(
	"status:needs-testing|FBCA04|Code merged, needs manual or integration testing"
	"status:stale|BFD4F2|No activity for 30+ days — needs triage"
	"status:verify-failed|E4E669|Task verification failed"
	"status:orphaned|EDEDED|Worker died, issue needs recovery"
)

# --- Origin Labels ---
ORIGIN_LABELS=(
	"origin:worker|1D76DB|Created by headless/pulse worker session"
	"origin:interactive|1D76DB|Created by interactive user session"
	"origin:worker-takeover|1D76DB|Worker took over work from another origin"
)

# --- Tier Labels (model routing) ---
TIER_LABELS=(
	"tier:simple|BFD4F2|Simple workload: docs, formatting, config, bounded transforms"
	"tier:standard|1D76DB|Standard workload: implementation, bug fixes, refactors"
	"tier:thinking|7057FF|Thinking workload: architecture, novel design, complex trade-offs"
)

# --- Priority Labels ---
PRIORITY_LABELS=(
	"priority:critical|D73A4A|Critical — stopping work completely, security, or data loss risk"
	"priority:high|D93F0B|High — systemic throughput bottleneck or significant quality issue"
	"priority:medium|FBCA04|Medium severity — moderate quality issue"
	"priority:low|0E8A16|Low severity — minor quality issue"
)

# --- Dispatch Tracking Labels ---
DISPATCH_LABELS=(
	"dispatched:simple|1D76DB|Task dispatched at the simple workload tier"
	"dispatched:standard|1D76DB|Task dispatched at the standard workload tier"
	"dispatched:thinking|1D76DB|Task dispatched at the thinking workload tier"
	"implemented:simple|0075CA|Task implemented at the simple workload tier"
	"implemented:standard|0075CA|Task implemented at the standard workload tier"
	"implemented:thinking|0075CA|Task implemented at the thinking workload tier"
	"retried:simple|E4E669|Task retried at the simple workload tier"
	"retried:standard|E4E669|Task retried at the standard workload tier"
	"retried:thinking|E4E669|Task retried at the thinking workload tier"
	"failed:simple|D93F0B|Task failed at the simple workload tier"
	"failed:standard|D93F0B|Task failed at the standard workload tier"
	"failed:thinking|D93F0B|Task failed at the thinking workload tier"
)

# --- aidevops System Labels ---
SYSTEM_LABELS=(
	"auto-dispatch|0E8A16|Eligible for automated worker dispatch"
	"no-auto-dispatch|EDEDED|Opt-out: block all auto-dispatch on this issue"
	"hold-for-review|D73A4A|Opt-out: block issue auto-dispatch or PR auto-merge for maintainer review"
	"needs-credentials|FBCA04|Opt-out: block auto-dispatch — requires credentials or account access"
	"ai-approved|0E8A16|Issue approved for AI agent processing"
	"persistent|FBCA04|Persistent issue — do not close"
	"supervisor|1D76DB|Supervisor health dashboard"
	"contributor|A2EEEF|Contributor health dashboard"
	"critical|D73A4A|Critical human-attention issue"
	"security|D73A4A|Security-sensitive issue"
	"security-adjacent|D73A4A|Security-adjacent issue requiring human attention"
	"needs-review|D73A4A|Flagged for human review by AI supervisor"
	"needs-maintainer-review|D73A4A|External-author gate requiring maintainer approval before work begins"
	"needs-maintainer-permissions|B60205|Block: background work paused for a scoped maintainer permission grant"
	"security-review|D73A4A|Requires security review — suspicious AI request"
	"parent-task|D4C5F9|Parent/meta task — children implement, not this issue"
	"quality-debt|D93F0B|Unactioned review feedback from merged PRs"
	"quality-review|7057FF|Daily code quality review"
	"review-feedback-scanned|5319E7|Merged PR already scanned for quality feedback"
	"code-reviews-actioned|0E8A16|All review feedback has been actioned"
	"not-planned|FFFFFF|Closed without implementation — not planned"
	"already-fixed|E4E669|Already fixed by another change"
	"needs-consolidation|FBCA04|Issue needs comment consolidation before dispatch"
	"consolidation-task|C5DEF5|Task created from consolidated duplicate issues"
	"consolidation-in-progress|CFD3D7|Another runner is creating a consolidation child issue (cross-runner advisory lock)"
	"consolidated|BFD4F2|Original issue consolidated into a task"
	"needs-simplification|FBCA04|File exceeds complexity threshold"
	"file-size-debt|D93F0B|File exceeds the line-count threshold and needs splitting before implementation can proceed"
	"function-complexity-debt|E05D44|Functions exceed complexity threshold and need refactoring before implementation can proceed"
	"recheck-simplicity|D4C5F9|File flagged for simplification recheck"
	"triage-failed|D93F0B|Automated triage could not classify this issue"
	"review:approve|0E8A16|Advisory automated triage recommendation: approve"
	"review:feedback|FBCA04|Advisory automated triage recommendation: request changes"
	"review:decline|D73A4A|Advisory automated triage recommendation: decline"
	"circuit-breaker|D93F0B|Circuit breaker tripped — automatic retry paused"
	"needs-review-fixes|D73A4A|PR has unaddressed review comments"
	"coderabbit-pulse|7057FF|Daily CodeRabbit pulse review tracking"
	"multi-model|E99695|Cross-provider model routing"
)

# --- Source Provenance Labels (all same green) ---
SOURCE_LABELS=(
	"source:health-dashboard|C2E0C6|Auto-created by stats-functions.sh health dashboard"
	"source:quality-sweep|C2E0C6|Auto-created by stats-functions.sh quality sweep"
	"source:review-feedback|C2E0C6|Auto-created by quality-feedback-helper.sh"
	"source:review-scanner|C2E0C6|Auto-created by post-merge-review-scanner"
	"source:ci-failure-miner|C2E0C6|Auto-created by gh-failure-miner-helper.sh"
	"source:circuit-breaker|C2E0C6|Auto-created by circuit-breaker-helper.sh"
	"source:mission-validation|C2E0C6|Auto-created by milestone-validation-worker"
)

# --- Routine Labels ---
ROUTINE_LABELS=(
	"routines|0E8A16|Routine tracking"
	"core|1D76DB|Framework-managed routine"
	"routine-tracking|BFDADC|Execution tracking issue — not a task (pulse skips these)"
)

# =============================================================================
# Tag-to-Color Category Map
# =============================================================================
# When issue-sync creates labels from TODO.md #tags, it should use these
# semantic colors instead of the universal #EDEDED gray. Tags not in any
# category fall through to EDEDED.

# Category: Bug/Fix — red
TAG_CAT_BUG="fix hotfix critical"

# Category: Enhancement — teal
TAG_CAT_ENHANCEMENT="feature enhancement"

# Category: DevOps/Infrastructure — light blue
TAG_CAT_DEVOPS="ci git deploy deployment infrastructure shell setup workflow devops release chore issue-sync cli mcp headless bash-compat automation local-dev preflight changelog no-auto-dispatch brief retry decomposition upstream github bots pulse network hosting local-hosting cloudflare linux windows geo harness localhost bridge"

# Category: Code Quality — lavender
TAG_CAT_QUALITY="refactor testing quality cleanup verification shellcheck eslint prettier coderabbit sonarcloud auto-review code-quality qlty test codacy code-review evaluation convention enforcement reliability efficiency"

# Category: Security — peach
TAG_CAT_SECURITY="security security-adjacent audit encryption auth prompt-injection sandboxing sandbox opsec"

# Category: UI/Frontend — mint green
TAG_CAT_UI="ui ux dashboard browser mobile responsive navigation react chrome browser-extension design"

# Category: Backend/Data — butter yellow
TAG_CAT_BACKEND="api db database migration ingestion validation zod sdk hono rls algorithm scoring entry matching rag vector-search"

# Category: Architecture — teal-gray
TAG_CAT_ARCH="architecture orchestration platform multi-tenant multi-tenancy performance plan"

# Category: Docs/Content — blue
TAG_CAT_DOCS="content seo communications email voice video documents document ocr audio"

# Category: Research/Planning — pink
TAG_CAT_RESEARCH="research investigation business mission outreach entity product future"

# Category: AI/Agent — purple
TAG_CAT_AI="ai agent agents models skill skills plugin plugins self-healing self-improvement opencode higgsfield tools multi-model model-routing routing model-comparison memory session-miner context7 local-models anchor reference"

# Category: Domain-specific — soft blue
TAG_CAT_DOMAIN="wordpress cloudron matrix turbostarter accounting awards payments deliverability"

# Category: Observability/Monitoring — teal (reuses arch color)
TAG_CAT_MONITORING="monitoring observability auto-update"

# Map category name → hex color
declare -A TAG_CATEGORY_COLORS=(
	[bug]="D73A4A"
	[enhancement]="A2EEEF"
	[devops]="BFD4F2"
	[quality]="D4C5F9"
	[security]="D73A4A"
	[ui]="C2E0C6"
	[backend]="FEF2C0"
	[arch]="BFDADC"
	[docs]="0075CA"
	[research]="D876E3"
	[ai]="7057FF"
	[domain]="C5DEF5"
	[monitoring]="BFDADC"
	[default]="EDEDED"
)

# =============================================================================
# Functions
# =============================================================================

# Returns the canonical hex color for a given tag name.
# Usage: color=$(color_for_tag "security")
color_for_tag() {
	local tag="$1"
	[[ -z "$tag" ]] && {
		echo "EDEDED"
		return 0
	}

	# Normalise: lowercase, strip leading #
	tag=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
	tag="${tag#\#}"

	# Check each category
	local word
	for word in $TAG_CAT_BUG; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[bug]}"
		return 0
	}; done
	for word in $TAG_CAT_ENHANCEMENT; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[enhancement]}"
		return 0
	}; done
	for word in $TAG_CAT_DEVOPS; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[devops]}"
		return 0
	}; done
	for word in $TAG_CAT_QUALITY; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[quality]}"
		return 0
	}; done
	for word in $TAG_CAT_SECURITY; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[security]}"
		return 0
	}; done
	for word in $TAG_CAT_UI; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[ui]}"
		return 0
	}; done
	for word in $TAG_CAT_BACKEND; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[backend]}"
		return 0
	}; done
	for word in $TAG_CAT_ARCH; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[arch]}"
		return 0
	}; done
	for word in $TAG_CAT_DOCS; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[docs]}"
		return 0
	}; done
	for word in $TAG_CAT_RESEARCH; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[research]}"
		return 0
	}; done
	for word in $TAG_CAT_AI; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[ai]}"
		return 0
	}; done
	for word in $TAG_CAT_DOMAIN; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[domain]}"
		return 0
	}; done
	for word in $TAG_CAT_MONITORING; do [[ "$tag" == "$word" ]] && {
		echo "${TAG_CATEGORY_COLORS[monitoring]}"
		return 0
	}; done

	echo "${TAG_CATEGORY_COLORS[default]}"
	return 0
}

# Apply a single label definition to a repo.
# Usage: _apply_label "owner/repo" "name|color|description" [--dry-run]
_apply_label() {
	local repo="$1"
	local definition="$2"
	local dry_run="${3:-}"

	local name color desc
	IFS='|' read -r name color desc <<<"$definition"

	if [[ "$dry_run" == "--dry-run" ]]; then
		echo "  [DRY-RUN] $name → #$color ($desc)"
		return 0
	fi

	gh label create "$name" --repo "$repo" \
		--color "$color" --description "$desc" --force 2>/dev/null || true
	return 0
}

# Apply all canonical labels from an array to a repo.
# Usage: _apply_label_set "owner/repo" ARRAY_NAME [--dry-run]
_apply_label_set() {
	local repo="$1"
	local label_array_name="$2"
	local dry_run="${3:-}"

	local definition
	eval "set -- \"\${${label_array_name}[@]}\""
	for definition in "$@"; do
		_apply_label "$repo" "$definition" "$dry_run"
	done
	return 0
}

# Get list of all non-local, non-contributed repos from repos.json
_get_admin_repos() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	[[ -f "$repos_json" ]] || {
		print_error "repos.json not found at $repos_json"
		return 1
	}

	jq -r '.initialized_repos[]
		| select(.local_only != true)
		| select(.contributed != true)
		| select(.slug != null and .slug != "")
		| select(.slug | test("^ssh://") | not)
		| .slug' "$repos_json" 2>/dev/null || true
	return 0
}

# Fix existing labels that have drifted from canonical colors.
# Reads current labels from repo and applies --force for any that differ.
_fix_existing_tag_labels() {
	local repo="$1"
	local dry_run="${2:-}"

	# Get all existing labels with "Auto-created from TODO.md tag" description
	local existing
	existing=$(gh label list --repo "$repo" --json name,color,description --limit 200 2>/dev/null || echo "[]")

	echo "$existing" | jq -r '.[] | select(.description == "Auto-created from TODO.md tag") | "\(.name)\t\(.color)"' 2>/dev/null | while IFS=$'\t' read -r name color; do
		local canonical_color
		canonical_color=$(color_for_tag "$name")

		# Normalise both to uppercase for comparison
		local current_upper canonical_upper
		current_upper="${color^^}"
		canonical_upper="${canonical_color^^}"

		if [[ "$current_upper" != "$canonical_upper" ]]; then
			if [[ "$dry_run" == "--dry-run" ]]; then
				echo "  [DRIFT] $name: #$color → #$canonical_color"
			else
				gh label create "$name" --repo "$repo" \
					--color "$canonical_color" --description "Auto-created from TODO.md tag" --force 2>/dev/null || true
				echo "  [FIXED] $name: #$color → #$canonical_color"
			fi
		fi
	done
	return 0
}

# Fix existing labels that should match system label definitions but have
# drifted (e.g., bug with wrong color, status labels from before standardization).
_fix_drifted_system_labels() {
	local repo="$1"
	local dry_run="${2:-}"

	local existing
	existing=$(gh label list --repo "$repo" --json name,color --limit 200 2>/dev/null || echo "[]")

	# Build lookup of canonical labels
	local all_canonical=()
	all_canonical+=("${GITHUB_DEFAULT_LABELS[@]}")
	all_canonical+=("${STATUS_LABELS[@]}")
	all_canonical+=("${STATUS_EXCEPTION_LABELS[@]}")
	all_canonical+=("${ORIGIN_LABELS[@]}")
	all_canonical+=("${TIER_LABELS[@]}")
	all_canonical+=("${PRIORITY_LABELS[@]}")
	all_canonical+=("${SYSTEM_LABELS[@]}")
	all_canonical+=("${SOURCE_LABELS[@]}")

	local definition
	for definition in "${all_canonical[@]}"; do
		local name color desc
		IFS='|' read -r name color desc <<<"$definition"

		# Check if this label exists on the repo with a different color
		local current_color
		current_color=$(echo "$existing" | jq -r --arg n "$name" '.[] | select(.name == $n) | .color' 2>/dev/null || true)

		if [[ -n "$current_color" ]]; then
			local current_upper canonical_upper
			current_upper="${current_color^^}"
			canonical_upper="${color^^}"

			if [[ "$current_upper" != "$canonical_upper" ]]; then
				if [[ "$dry_run" == "--dry-run" ]]; then
					echo "  [DRIFT] $name: #$current_color → #$color"
				else
					gh label create "$name" --repo "$repo" \
						--color "$color" --description "$desc" --force 2>/dev/null || true
					echo "  [FIXED] $name: #$current_color → #$color"
				fi
			fi
		fi
	done
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_sync() {
	local dry_run=""
	local target_repo=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run="--dry-run"
			shift
			;;
		--repo)
			target_repo="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local repos=()
	if [[ -n "$target_repo" ]]; then
		repos=("$target_repo")
	else
		while IFS= read -r slug; do
			[[ -n "$slug" ]] && repos+=("$slug")
		done < <(_get_admin_repos)
	fi

	if [[ ${#repos[@]} -eq 0 ]]; then
		print_error "No repos found to sync"
		return 1
	fi

	local repo
	for repo in "${repos[@]}"; do
		echo ""
		print_info "=== Syncing labels for $repo ==="

		# Check if we have admin access (can create labels)
		if ! gh label list --repo "$repo" --limit 1 >/dev/null 2>&1; then
			print_warning "Cannot access $repo — skipping"
			continue
		fi

		# 1. Apply all canonical system labels
		echo "  Applying GitHub defaults..."
		_apply_label_set "$repo" GITHUB_DEFAULT_LABELS "$dry_run"

		echo "  Applying status labels..."
		_apply_label_set "$repo" STATUS_LABELS "$dry_run"
		_apply_label_set "$repo" STATUS_EXCEPTION_LABELS "$dry_run"

		echo "  Applying origin labels..."
		_apply_label_set "$repo" ORIGIN_LABELS "$dry_run"

		echo "  Applying tier labels..."
		_apply_label_set "$repo" TIER_LABELS "$dry_run"

		echo "  Applying priority labels..."
		_apply_label_set "$repo" PRIORITY_LABELS "$dry_run"

		echo "  Applying system labels..."
		_apply_label_set "$repo" SYSTEM_LABELS "$dry_run"

		echo "  Applying source labels..."
		_apply_label_set "$repo" SOURCE_LABELS "$dry_run"

		# 2. Fix existing tag labels that have drifted from canonical colors
		echo "  Fixing drifted TODO.md tag labels..."
		_fix_existing_tag_labels "$repo" "$dry_run"

		# 3. Fix system labels that exist but with wrong colors
		echo "  Fixing drifted system labels..."
		_fix_drifted_system_labels "$repo" "$dry_run"

		print_success "Done: $repo"
	done

	echo ""
	print_success "Label sync complete for ${#repos[@]} repo(s)"
	return 0
}

cmd_audit() {
	local target_repo=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			target_repo="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local repos=()
	if [[ -n "$target_repo" ]]; then
		repos=("$target_repo")
	else
		while IFS= read -r slug; do
			[[ -n "$slug" ]] && repos+=("$slug")
		done < <(_get_admin_repos)
	fi

	local total_drift=0
	local repo
	for repo in "${repos[@]}"; do
		echo ""
		print_info "=== Auditing $repo ==="

		if ! gh label list --repo "$repo" --limit 1 >/dev/null 2>&1; then
			print_warning "Cannot access $repo — skipping"
			continue
		fi

		local drift_count=0

		# Check system label drift
		_fix_drifted_system_labels "$repo" "--dry-run" | while read -r line; do
			echo "$line"
			drift_count=$((drift_count + 1))
		done

		# Check tag label drift
		_fix_existing_tag_labels "$repo" "--dry-run" | while read -r line; do
			echo "$line"
			drift_count=$((drift_count + 1))
		done

		total_drift=$((total_drift + drift_count))
	done

	echo ""
	if [[ $total_drift -gt 0 ]]; then
		print_warning "Found label drift. Run 'label-sync-helper.sh sync' to fix."
	else
		print_success "All labels are in sync."
	fi
	return 0
}

cmd_color_for_tag() {
	local tag="${1:-}"
	if [[ -z "$tag" ]]; then
		print_error "Usage: label-sync-helper.sh color-for-tag <tag-name>"
		return 1
	fi
	color_for_tag "$tag"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	sync) cmd_sync "$@" ;;
	audit) cmd_audit "$@" ;;
	color-for-tag) cmd_color_for_tag "$@" ;;
	help | --help | -h)
		echo "Usage: label-sync-helper.sh <command> [options]"
		echo ""
		echo "Commands:"
		echo "  sync [--dry-run] [--repo owner/repo]  Sync canonical label colors to repos"
		echo "  audit [--repo owner/repo]              Report label color drift"
		echo "  color-for-tag <tag>                    Return canonical color for a tag"
		echo ""
		echo "Options:"
		echo "  --dry-run    Show what would change without applying"
		echo "  --repo       Target a specific repo instead of all in repos.json"
		return 0
		;;
	*)
		print_error "Unknown command: $command"
		echo "Run 'label-sync-helper.sh help' for usage."
		return 1
		;;
	esac
}

# Only run main when executed directly, not when sourced (e.g., by issue-sync-helper.sh
# which sources this file to access color_for_tag()).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
