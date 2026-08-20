#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-smoke-help.sh
#
# Smoke tests: bash -n syntax check for ALL scripts, plus help command
# validation for scripts that define a help function.
#
# Usage: bash tests/test-smoke-help.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	fi
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# ============================================================
# SECTION 1: bash -n syntax check for ALL scripts
# ============================================================
section "Syntax Check (bash -n) - All Scripts"

syntax_pass=0
syntax_fail=0

while IFS= read -r script; do
	abs_path="$REPO_DIR/$script"
	name=$(basename "$script")

	if bash -n "$abs_path" 2>/dev/null; then
		pass "syntax: $name"
		syntax_pass=$((syntax_pass + 1))
	else
		fail "syntax: $name" "bash -n failed"
		syntax_fail=$((syntax_fail + 1))
	fi
done < <(git -C "$REPO_DIR" ls-files '.agents/scripts/*.sh' '.agents/scripts/**/*.sh' | grep -v '_archive/')

printf "  Syntax: %d passed, %d failed (of %d non-archived scripts)\n" \
	"$syntax_pass" "$syntax_fail" "$((syntax_pass + syntax_fail))"

# ============================================================
# SECTION 2: Help command smoke tests
# ============================================================
section "Help Command Smoke Tests"

# Scripts known to NOT support a help subcommand (libraries, hooks, utilities)
# These are sourced or run without arguments, not invoked with "help"
SKIP_HELP=(
	"shared-constants.sh"
	"loop-common.sh"
	"pre-commit-hook.sh"
	"cron-dispatch.sh"
	"aidevops-update-check.sh"
	"auto-version-bump.sh"
	"validate-version-consistency.sh"
	"extract-opencode-prompts.sh"
	"generate-opencode-commands.sh"
	"generate-claude-commands.sh"
	"generate-skills.sh"
	"opencode-prompt-drift-check.sh"
	"quality-fix.sh"
	"sonarcloud-autofix.sh"
	"monitor-code-review.sh"
	"code-audit-helper.sh"
	"session-time-helper.sh"
	"planning-commit-helper.sh"
	"log-issue-helper.sh"
	"humanise-update-helper.sh"
	"dns-helper.sh"
	"closte-helper.sh"
	"cloudron-helper.sh"
	"hetzner-helper.sh"
	"hostinger-helper.sh"
	"coolify-helper.sh"
	"ses-helper.sh"
	"servers-helper.sh"
	"pagespeed-helper.sh"
	"tool-version-check.sh"
	"todo-ready.sh"
	"localhost-helper.sh"
	"linters-local.sh"
	"markdown-lint-fix.sh"
	"generate-opencode-agents.sh"
	"setup-local-api-keys.sh"
	"stagehand-setup.sh"
	"stagehand-python-setup.sh"
	"test-stagehand-integration.sh"
	"test-stagehand-python-integration.sh"
	"test-stagehand-both-integration.sh"
	"crawl4ai-examples.sh"
	"ampcode-cli.sh"
	"agno-setup.sh"
	"sonarscanner-cli.sh"
	"codacy-cli.sh"
	"codacy-cli-chunked.sh"
	"coderabbit-pro-analysis.sh"
	"snyk-helper.sh"
	"verify-mirrors.sh"
	"webhosting-verify.sh"
	# Modularised scripts (sourced by parent, not standalone)
	"_common.sh"
	"store.sh"
	"recall.sh"
	"maintenance.sh"
	"verification.sh"
)

is_skip_help() {
	local name="$1"
	for s in "${SKIP_HELP[@]}"; do
		[[ "$name" == "$s" ]] && return 0
	done
	return 1
}

help_pass=0
help_fail=0
help_skip=0

while IFS= read -r script; do
	abs_path="$REPO_DIR/$script"
	name=$(basename "$script")

	# Skip archived scripts
	[[ "$script" == *"_archive/"* ]] && continue

	# Skip scripts that don't support help
	if is_skip_help "$name"; then
		skip "help: $name (not a help-command script)"
		help_skip=$((help_skip + 1))
		continue
	fi

	# Check if script defines a help function
	if ! grep -qE 'cmd_help\(\)|show_help\(\)|show_usage\(\)|usage\(\)' "$abs_path" 2>/dev/null; then
		skip "help: $name (no help function defined)"
		help_skip=$((help_skip + 1))
		continue
	fi

	# Run help command with timeout (5s max) and capture output
	help_output=$(timeout 5 bash "$abs_path" help 2>&1)
	help_exit=$?

	# Some scripts exit 0 on help, some exit 1 (usage error) - both are acceptable
	# as long as they produce output and don't hang/crash
	if [[ -n "$help_output" ]]; then
		pass "help: $name"
		help_pass=$((help_pass + 1))
	elif [[ $help_exit -eq 124 ]]; then
		fail "help: $name" "Timed out after 5 seconds"
		help_fail=$((help_fail + 1))
	else
		fail "help: $name" "No output produced (exit=$help_exit)"
		help_fail=$((help_fail + 1))
	fi
done < <(git -C "$REPO_DIR" ls-files '.agents/scripts/*.sh' '.agents/scripts/**/*.sh')

printf "  Help: %d passed, %d failed, %d skipped\n" \
	"$help_pass" "$help_fail" "$help_skip"

# ============================================================
# SECTION 3: ShellCheck on critical scripts (errors only)
# ============================================================
section "ShellCheck (errors only) - Critical Scripts"

CRITICAL_SCRIPTS=(
	"supervisor-helper.sh"
	"memory-helper.sh"
	"mail-helper.sh"
	"runner-helper.sh"
	"full-loop-helper.sh"
	"pre-edit-check.sh"
	"worktree-helper.sh"
	"credential-helper.sh"
	"secret-helper.sh"
)

if command -v shellcheck &>/dev/null; then
	for name in "${CRITICAL_SCRIPTS[@]}"; do
		script_path="$SCRIPTS_DIR/$name"
		if [[ ! -f "$script_path" ]]; then
			skip "shellcheck: $name (not found)"
			continue
		fi

		sc_output=$(shellcheck -S error "$script_path" 2>&1 || true)
		sc_errors=$(echo "$sc_output" | grep -c "error" || true)
		if [[ "$sc_errors" -eq 0 ]]; then
			pass "shellcheck: $name (0 errors)"
		else
			fail "shellcheck: $name ($sc_errors errors)" \
				"$(echo "$sc_output" | head -5)"
		fi
	done
else
	skip "shellcheck not installed"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
	"$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	echo ""
	printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
	exit 1
else
	echo ""
	printf "\033[0;32mAll tests passed.\033[0m\n"
	exit 0
fi
