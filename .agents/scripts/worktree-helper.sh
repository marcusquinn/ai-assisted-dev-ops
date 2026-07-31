#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Git Worktree Helper Script -- Orchestrator
# =============================================================================
# Manage multiple working directories for parallel branch work.
# Each worktree is an independent directory on a different branch,
# sharing the same git database.
#
# Usage:
#   worktree-helper.sh <command> [options]
#
# Commands:
#   add <branch> [path] [--issue NNN] [--base REF] [--fresh-on-collision]
#                          Create worktree for branch (auto-names path)
#   list                   List all worktrees with status
#   remove <path|branch>   Remove a worktree
#   status                 Show current worktree info
#   switch <branch>        Open/create worktree for branch (prints path)
#   clean [--auto] [--force-merged]  Remove worktrees for merged branches
#   help                   Show this help
#
# Examples:
#   worktree-helper.sh add feature/auth
#   worktree-helper.sh switch bugfix/login
#   worktree-helper.sh list
#   worktree-helper.sh remove feature/auth
#   worktree-helper.sh clean
#
# Sub-libraries (sourced below):
#   worktree-helper-integration.sh  localdev + preview proxy integration
#   worktree-helper-git.sh          git utilities + stale remote handling
#   worktree-helper-add.sh          path utils + cmd_add and all its helpers
#   worktree-helper-cmds.sh         cmd_list, remove, status, switch, registry, help
#   worktree-clean-lib.sh           cmd_clean (existing split, GH#21409),
#                                   including branch-merged safety proof gates
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# shellcheck source=./disk-capacity-lib.sh
source "${SCRIPT_DIR}/disk-capacity-lib.sh"

# t2559: canonical-guard-helper.sh provides is_registered_canonical,
# assert_git_available, assert_main_worktree_sane. Sourced after
# shared-constants.sh so its fallback colour vars are available if this
# module is loaded standalone. Guarded in case older deployments lack
# the helper — sourcing errors fail open (guards become no-ops).
if [[ -f "${SCRIPT_DIR}/canonical-guard-helper.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/canonical-guard-helper.sh"
fi

# t2976/GH#23074: canonical audit logger for worktree-removal events
# (removed / skipped), including optional guard context when callers provide it.
# Fallback definitions guard against set -u failures when the helper is absent
# (e.g. older deployments). The source block below overrides these when the file exists.
# The stub uses command -v so it is only defined when the real function is not yet
# loaded — prevents unconditional overwrite when audit-worktree-removal-helper.sh was
# already sourced by a caller (e.g. pulse-cleanup.sh) before worktree-helper.sh is
# re-sourced; the double-source guard in that helper would otherwise prevent restore.
_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
command -v log_worktree_removal_event >/dev/null 2>&1 || log_worktree_removal_event() { :; }
if [[ -f "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
fi
# Caller ID used in every log_worktree_removal_event call below (avoids repeated literals).
_WTAR_WH_CALLER="worktree-helper.sh"

set -euo pipefail

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# nice — ownership registry functions are centralised in shared-constants.sh (t189):
#   register_worktree, unregister_worktree, check_worktree_owner,
#   is_worktree_owned_by_others, prune_worktree_registry

# =============================================================================
# Localdev + Preview Proxy Constants
# =============================================================================
# These constants are used by worktree-helper-integration.sh and must be
# defined before sourcing that sub-library.

readonly LOCALDEV_PORTS_FILE="$HOME/.local-dev-proxy/ports.json"
readonly LOCALDEV_HELPER="${SCRIPT_DIR}/localdev-helper.sh"

# =============================================================================
# Preview Proxy Integration (GH#21560)
# =============================================================================
readonly PREVIEW_PROXY_HELPER="${SCRIPT_DIR}/preview-proxy-helper.sh"

# =============================================================================
# Sub-Libraries
# =============================================================================

# shellcheck source=./worktree-helper-integration.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-helper-integration.sh"

# shellcheck source=./worktree-helper-git.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-helper-git.sh"

# shellcheck source=./worktree-paths.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-paths.sh"

# shellcheck source=./worktree-helper-add.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-helper-add.sh"

# shellcheck source=./worktree-helper-cmds.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-helper-cmds.sh"

# =============================================================================
# Clean Command sub-library (worktree-clean-lib.sh)
# =============================================================================
# shellcheck source=./worktree-clean-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worktree-clean-lib.sh"

# =============================================================================
# MAIN
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	add)
		cmd_add "$@"
		;;
	list | ls)
		cmd_list "$@"
		;;
	remove | rm)
		cmd_remove "$@"
		;;
	status | st)
		cmd_status "$@"
		;;
	switch | sw)
		cmd_switch "$@"
		;;
	clean)
		cmd_clean "$@"
		;;
	registry | reg)
		cmd_registry "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo -e "${RED}Unknown command: $command${NC}"
		echo "Run 'worktree-helper.sh help' for usage"
		return 1
		;;
	esac
}

main "$@"
