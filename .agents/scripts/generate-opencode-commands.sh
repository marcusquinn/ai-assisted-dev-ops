#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# DEPRECATED: Use generate-runtime-config.sh instead (t1665.4)
# This script is kept for one release cycle as a fallback.
# .agents/scripts/setup/modules/config.sh will use generate-runtime-config.sh when available.
# =============================================================================
# Generate OpenCode Commands from Agent Files
# =============================================================================
# Creates /commands in OpenCode from agent markdown files
#
# Source: ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/
# Target: ~/.config/opencode/command/
#
# Commands are generated from:
#   - tools/build-agent/agent-review.md -> /agent-review
#   - workflows/*.md -> /workflow-name
#   - Other agents as needed
#
# Sub-libraries (sourced below):
#   - generate-opencode-commands-quality.sh    -- Quality & review commands
#   - generate-opencode-commands-git.sh        -- Git & release commands
#   - generate-opencode-commands-planning.sh   -- Planning & task commands
#   - generate-opencode-commands-seo.sh        -- SEO & AI search commands
#   - generate-opencode-commands-utility.sh    -- Setup, session, memory commands
#   - generate-opencode-commands-automation.sh -- Ralph loop & CI loop commands
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

OPENCODE_COMMAND_DIR="$HOME/.config/opencode/command"

echo -e "${BLUE}Generating OpenCode commands...${NC}"

# Ensure command directory exists
mkdir -p "$OPENCODE_COMMAND_DIR"

command_count=0
manual_command_names=" "

# Agent name constants (single source of truth for agent renames)
readonly AGENT_BUILD="Build+"
readonly AGENT_SEO="SEO"

# =============================================================================
# COMMAND CREATION HELPER
# =============================================================================
# Eliminates duplication across all manual command definitions.
#
# Usage:
#   create_command "name" "description" "agent" "subtask" <<'BODY'
#   Command body content here (without frontmatter)
#   BODY
#
# Parameters:
#   $1 - command name (e.g., "agent-review")
#   $2 - description for frontmatter
#   $3 - agent name (e.g., "Build+", "SEO", or "" for no agent field)
#   $4 - subtask flag ("true" to add subtask: true, "" to omit)
# =============================================================================
create_command() {
	(($# == 4)) || {
		echo -e "  ${RED}✗${NC} Error: create_command requires 4 arguments (got $#)" >&2
		return 1
	}
	local name="$1"
	[[ -n "$name" ]] || {
		echo -e "  ${RED}✗${NC} Error: command name required" >&2
		return 1
	}
	local description="$2"
	local agent="$3"
	local subtask="$4"
	local body
	body=$(cat)

	# Write command file
	{
		echo "---"
		echo "description: ${description}"
		[[ -n "$agent" ]] && echo "agent: ${agent}"
		[[ "$subtask" == "true" ]] && echo "subtask: true"
		echo "---"
		echo ""
		cat <<<"$body"
	} >"${OPENCODE_COMMAND_DIR}/${name}.md"

	manual_command_names+="${name} "
	((++command_count))
	echo -e "  ${GREEN}✓${NC} Created /${name} command"
	return 0
}

# =============================================================================
# SOURCE SUB-LIBRARIES
# =============================================================================

# shellcheck source=./generate-opencode-commands-quality.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-opencode-commands-quality.sh"

# shellcheck source=./generate-opencode-commands-git.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-opencode-commands-git.sh"

# shellcheck source=./generate-opencode-commands-planning.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-opencode-commands-planning.sh"

# shellcheck source=./generate-opencode-commands-seo.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-opencode-commands-seo.sh"

# shellcheck source=./generate-opencode-commands-utility.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-opencode-commands-utility.sh"

# shellcheck source=./generate-opencode-commands-automation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-opencode-commands-automation.sh"

# =============================================================================
# EXECUTE ALL COMMAND GROUPS
# =============================================================================

define_quality_commands
define_git_commands
define_planning_commands
define_seo_commands
define_seo_ai_commands
define_utility_commands
define_automation_commands

# =============================================================================
# AUTO-DISCOVERED COMMANDS FROM scripts/commands/
# =============================================================================
# Commands in .agents/scripts/commands/*.md are auto-generated
# Each file should have frontmatter with description and agent
# This prevents needing to manually add new commands to this script

copy_discovered_command() {
	local src="$1"
	local dest="$2"

	# OpenCode treats model values as concrete IDs, not workload tiers.
	awk '
		NR == 1 && /^---$/ { in_fm = 1; print; next }
		in_fm && /^---$/ { in_fm = 0; print; next }
		in_fm && /^model: (simple|standard|thinking)$/ { next }
		{ print }
	' "$src" >"$dest" || return 1
	return 0
}

discover_commands() {
	local commands_dir="${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/commands"

	[[ -d "$commands_dir" ]] || return 0

	local cmd_file cmd_name
	for cmd_file in "$commands_dir"/*.md; do
		[[ -f "$cmd_file" ]] || continue

		cmd_name=$(basename "$cmd_file" .md)

		# Skip SKILL.md (not a command)
		[[ "$cmd_name" == "SKILL" ]] && continue

		# Preserve commands defined explicitly during this run, but refresh
		# previously auto-discovered files so stale routing metadata cannot survive.
		case "$manual_command_names" in
		*" $cmd_name "*) continue ;;
		esac

		# Preserve OpenCode frontmatter while removing provider-neutral tiers.
		if copy_discovered_command "$cmd_file" "$OPENCODE_COMMAND_DIR/$cmd_name.md"; then
			((++command_count))
			echo -e "  ${GREEN}✓${NC} Auto-discovered /$cmd_name command"
		elif [[ ! -f "$cmd_file" ]]; then
			echo -e "  ${YELLOW}!${NC} Skipped /$cmd_name command (source missing: $cmd_file)" >&2
		else
			echo -e "  ${RED}✗${NC} Failed to copy /$cmd_name command" >&2
			exit 1
		fi
	done

	return 0
}

discover_commands

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
	echo ""
	echo -e "${GREEN}Done!${NC}"
	echo "  Commands created: $command_count"
	echo "  Location: $OPENCODE_COMMAND_DIR"
	echo ""
	echo "Available commands:"
	echo ""
	echo "  Planning:"
	echo "    /list-todo        - List tasks with sorting, filtering, grouping"
	echo "    /save-todo        - Save discussion as task/plan (auto-detects complexity)"
	echo "    /plan-status      - Show active plans and TODO.md status"
	echo "    /create-prd       - Generate Product Requirements Document"
	echo "    /generate-tasks   - Generate implementation tasks from PRD"
	echo ""
	echo "  Quality:"
	echo "    /preflight        - Quality checks before commit"
	echo "    /postflight       - Check code audit feedback on latest push"
	echo "    /review-issue-pr  - Review external issue/PR (validate problem, evaluate solution)"
	echo "    /linters-local    - Run local linting (ShellCheck, secretlint)"
	echo "    /code-audit-remote - Run remote auditing (CodeRabbit, Codacy, SonarCloud)"
	echo "    /code-standards   - Check against documented standards"
	echo "    /code-simplifier  - Simplify code for clarity and maintainability"
	echo ""
	echo "  Git & Release:"
	echo "    /feature          - Create feature linked worktree"
	echo "    /bugfix           - Create bugfix linked worktree"
	echo "    /hotfix           - Create hotfix linked worktree"
	echo "    /create-pr        - Create PR from current branch"
	echo "    /release          - Full release workflow"
	echo "    /version-bump     - Bump project version"
	echo "    /changelog        - Update CHANGELOG.md"
	echo ""
	echo "  SEO:"
	echo "    /keyword-research - Seed keyword expansion"
	echo "    /autocomplete-research - Google autocomplete long-tails"
	echo "    /keyword-research-extended - Full SERP analysis with weakness detection"
	echo "    /webmaster-keywords - Keywords from GSC + Bing for your sites"
	echo "    /seo-fanout                - Thematic sub-query fan-out planning"
	echo "    /seo-geo                   - GEO criteria and coverage strategy"
	echo "    /seo-sro                   - SRO grounding snippet optimization"
	echo "    /seo-hallucination-defense - Fact consistency and claim-evidence audit"
	echo "    /seo-agent-discovery       - Multi-turn AI discoverability diagnostics"
	echo "    /seo-ai-readiness          - End-to-end AI search readiness workflow"
	echo "    /seo-ai-baseline           - Baseline KPI scorecard generation"
	echo ""
	echo "  Utilities:"
	echo "    /onboarding       - Interactive setup wizard (START HERE for new users)"
	echo "    /setup-aidevops   - Deploy latest agent changes locally"
	echo "    /agent-review     - Review and improve agent instructions"
	echo "    /session-review   - Review session for completeness before ending"
	echo "    /context          - Build AI context"
	echo "    /list-keys        - List API keys with storage locations"
	echo "    /log-time-spent   - Log time spent on a task"
	echo ""
	echo "  Memory:"
	echo "    /remember         - Store a memory for cross-session recall"
	echo "    /recall           - Search memories from previous sessions"
	echo ""
	echo "  Automation (Ralph Loops):"
	echo "    /ralph-loop       - Start iterative AI development loop"
	echo "    /ralph-task       - Run Ralph loop for a TODO.md task by ID"
	echo "    /full-loop        - End-to-end: task -> preflight -> PR -> postflight"
	echo "    /cancel-ralph     - Cancel active Ralph loop"
	echo "    /ralph-status     - Show Ralph loop status"
	echo "    /preflight-loop   - Iterative preflight until all pass"
	echo "    /pr-loop          - Monitor PR until approved/merged"
	echo "    /postflight-loop  - Monitor release health"
	echo ""
	echo "New users: Start with /onboarding to configure your services"
	echo ""
	echo "Planning workflow: /list-todo -> pick task -> /feature -> implement -> /create-pr"
	echo "New work: discuss -> /save-todo -> later: /list-todo -> pick -> implement"
	echo "Quality workflow: /preflight-loop -> /create-pr -> /pr-loop -> /postflight-loop"
	echo "Ralph workflow: tag task #ralph -> /ralph-task t042 -> autonomous completion"
	echo "SEO workflow: /keyword-research -> /autocomplete-research -> /keyword-research-extended"
	echo "AI-baseline workflow: /seo-ai-baseline -> /seo-ai-readiness"
	echo "AI-search workflow: /seo-fanout -> /seo-geo -> /seo-sro ->"
	echo "                      /seo-hallucination-defense -> /seo-agent-discovery"
	echo ""
	echo "Restart OpenCode to load new commands."

	return 0
}

print_summary
