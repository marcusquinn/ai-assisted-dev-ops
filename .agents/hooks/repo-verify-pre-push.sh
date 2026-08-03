#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# repo-verify-pre-push.sh — git pre-push hook (t3224).
#
# Runs the target repo's declared format/lint/typecheck commands BEFORE the
# push reaches CI. Closes the gap that lets workers ship PRs which fail
# Format/Lint on the next CI cycle and then sit in a CI-feedback loop.
#
# Discovery cascade (first match wins):
#   1. <repo_root>/.aidevops.json `.verify` block
#      { "format": "...", "format_fix": "...", "lint": "...",
#        "lint_fix": "...", "typecheck": "...", "enabled": true }
#   2. <repo_root>/package.json exact declared scripts. Mutating `format`
#      scripts and ambiguous package-manager lockfiles are never inferred.
#   3. .agents/configs/repo-verify-defaults.conf — evidence-based toolchain
#      detection (for example Cargo.toml or committed Ruff configuration)
#   4. No match: skip silently (exit 0). Repo is not verify-eligible.
#
# Auto-fix policy (FORMAT_FAILURE / LINT_FAILURE only — typecheck never auto-fixes):
#   - AIDEVOPS_PREPUSH_AUTOFIX=1: run `*_fix` on failure; if files changed,
#     `git add -A && git commit --amend --no-edit`; re-run check.
#   - AIDEVOPS_PREPUSH_AUTOFIX=0: emit mentoring failure with exact suggested
#     fix command; exit 1.
#   - Default: 1 in headless contexts (FULL_LOOP_HEADLESS / AIDEVOPS_HEADLESS /
#     OPENCODE_HEADLESS / GITHUB_ACTIONS), 0 in interactive sessions.
#
# Skip conditions (exit 0 fast):
#   - AIDEVOPS_PREPUSH_REPO_VERIFY=0
#   - GITHUB_ACTIONS=true (CI already runs these)
#   - Working tree dirty (warn — uncommitted changes would corrupt the result)
#   - No verify commands resolved
#   - Required tools missing (jq for config parsing)
#
# Exit codes:
#   0 = allow push (verify clean OR skipped OR auto-fixed and re-verified)
#   1 = block push (verify failed AND auto-fix unavailable/disabled/exhausted)
#
# Bypass for one push: AIDEVOPS_PREPUSH_REPO_VERIFY=0 git push ...
#                  or: git push --no-verify

set -u

GUARD_NAME='repo-verify'

# ----- bypass checks ------------------------------------------------------

if [[ "${AIDEVOPS_PREPUSH_REPO_VERIFY:-1}" == "0" ]]; then
	printf '[%s][INFO] AIDEVOPS_PREPUSH_REPO_VERIFY=0 — bypassing\n' "$GUARD_NAME" >&2
	exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
	# CI runs these checks itself — running again here is wasted cycles
	exit 0
fi

# ----- helpers ------------------------------------------------------------

_log() {
	local _level="$1"
	local _msg="$2"
	printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2
}
_dbg() {
	local _msg="$1"
	if [[ "${AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG:-0}" == "1" ]]; then
		printf '[%s][DBG] %s\n' "$GUARD_NAME" "$_msg" >&2
	fi
}

# Resolve the hook's directory through symlinks so config defaults can be
# located regardless of whether installed as a symlink or a copy.
_resolve_self() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir=$(cd -P "$(dirname "$src")" && pwd)
		src=$(readlink "$src")
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}

HOOK_DIR=$(_resolve_self)
VERIFY_LIB_REPO="${HOOK_DIR}/../scripts/repo-verify-config-lib.sh"
VERIFY_LIB_DEPLOYED="${HOME:+$HOME/.aidevops/agents/scripts/repo-verify-config-lib.sh}"
if [[ -f "$VERIFY_LIB_REPO" ]]; then
	# shellcheck source=../scripts/repo-verify-config-lib.sh
	source "$VERIFY_LIB_REPO"
elif [[ -f "$VERIFY_LIB_DEPLOYED" ]]; then
	# shellcheck source=/dev/null
	source "$VERIFY_LIB_DEPLOYED"
else
	_log INFO "repo verify configuration library unavailable — skipping"
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$REPO_ROOT" ]]; then
	_log INFO "not in a git repo — skipping"
	exit 0
fi

# Auto-fix default: ON in headless, OFF interactive. AIDEVOPS_PREPUSH_AUTOFIX
# (when set) wins over the heuristic.
_autofix_default() {
	if [[ -n "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${OPENCODE_HEADLESS:-}${GITHUB_ACTIONS:-}" ]]; then
		printf '1\n'
	else
		printf '0\n'
	fi
}
AUTOFIX="${AIDEVOPS_PREPUSH_AUTOFIX:-$(_autofix_default)}"

# ----- discovery ----------------------------------------------------------

# Globals consumed by the execution path. The shared detector populates its
# REPO_VERIFY_* namespace; this adapter preserves the hook's established names.
VERIFY_FORMAT=''
VERIFY_FORMAT_FIX=''
VERIFY_LINT=''
VERIFY_LINT_FIX=''
VERIFY_TYPECHECK=''
VERIFY_SOURCE=''

_load_verify_config() {
	repo_verify_detect "$REPO_ROOT" || true
	if [[ "$REPO_VERIFY_STATUS" == "disabled" ]]; then
		VERIFY_SOURCE='aidevops-json-disabled'
		return 0
	fi
	if [[ "$REPO_VERIFY_STATUS" != "ready" ]]; then
		[[ -n "$REPO_VERIFY_WARNING" ]] && _dbg "$REPO_VERIFY_WARNING"
		return 1
	fi
	VERIFY_FORMAT="$REPO_VERIFY_FORMAT"
	VERIFY_FORMAT_FIX="$REPO_VERIFY_FORMAT_FIX"
	VERIFY_LINT="$REPO_VERIFY_LINT"
	VERIFY_LINT_FIX="$REPO_VERIFY_LINT_FIX"
	VERIFY_TYPECHECK="$REPO_VERIFY_TYPECHECK"
	VERIFY_SOURCE="$REPO_VERIFY_SOURCE"
	return 0
}

# ----- run a single verify check ------------------------------------------

# _run_check NAME COMMAND -> exit 0 on pass, 1 on fail. Captures output for
# the failure mentor message. Echoes a concise status line on success.
_run_check() {
	local name="$1"
	local cmd="$2"
	local log
	log=$(mktemp -t "aidevops-prepush-${name}.XXXXXX")
	_log INFO "running $name: $cmd"
	if (cd "$REPO_ROOT" && eval "$cmd") >"$log" 2>&1; then
		_log OK "$name passed"
		rm -f "$log"
		return 0
	fi
	_log FAIL "$name failed — last 30 lines:"
	tail -n 30 "$log" >&2 || true
	# Stash log path on global for the autofix path to retain context
	LAST_FAIL_LOG="$log"
	return 1
}

# _run_autofix NAME FIX_COMMAND CHECK_COMMAND
# Returns 0 if check passes after autofix (with possible amend),
# 1 if autofix unavailable/disabled or still fails.
_run_autofix() {
	local name="$1"
	local fix_cmd="$2"
	local check_cmd="$3"

	if [[ -z "$fix_cmd" ]]; then
		_log INFO "$name autofix unavailable (no *_fix command declared)"
		return 1
	fi
	if [[ "$AUTOFIX" != "1" ]]; then
		_log INFO "$name autofix skipped (AIDEVOPS_PREPUSH_AUTOFIX=0)"
		return 1
	fi

	_log INFO "running $name autofix: $fix_cmd"
	if ! (cd "$REPO_ROOT" && eval "$fix_cmd") >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
		_log WARN "$name autofix command itself failed"
		return 1
	fi

	# Did autofix change any tracked files?
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
		_log INFO "$name autofix modified files — amending HEAD"
		# Redirect BOTH streams to the log so the hook never leaks chatter
		# into git's stdout (which gets surfaced in the calling shell).
		if ! git -C "$REPO_ROOT" add -A >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
			_log WARN "$name autofix git add failed"
			return 1
		fi
		if ! git -C "$REPO_ROOT" commit --amend --no-edit --no-verify >>"${LAST_FAIL_LOG:-/dev/null}" 2>&1; then
			_log WARN "$name autofix git commit --amend failed"
			return 1
		fi
		_log OK "$name autofix amended into HEAD"
	else
		_dbg "$name autofix produced no diff"
	fi

	# Re-run the check to confirm
	if _run_check "${name}-recheck" "$check_cmd"; then
		return 0
	fi
	return 1
}

# Emit a mentoring failure message for the next push attempt
_emit_mentor_fail() {
	local name="$1"
	local fix_cmd="$2"
	printf '\n' >&2
	printf '[%s][BLOCK] %s failed and autofix is %s.\n' "$GUARD_NAME" "$name" \
		"$([[ -z "$fix_cmd" ]] && printf 'unavailable' || printf 'disabled')" >&2
	printf '\n' >&2
	printf '  Resolution:\n' >&2
	if [[ -n "$fix_cmd" ]]; then
		printf '    1. Run: %s\n' "$fix_cmd" >&2
		printf '    2. git add -A && git commit --amend --no-edit\n' >&2
		printf '    3. git push (re-runs verify on the amended commit)\n' >&2
		printf '\n' >&2
		printf '  Or enable autofix for this push:\n' >&2
		printf '    AIDEVOPS_PREPUSH_AUTOFIX=1 git push\n' >&2
	else
		printf '    1. Read the failing command output above and fix the source\n' >&2
		printf '    2. Re-run: %s   (must pass)\n' "${3:-<original check>}" >&2
		printf '    3. git add -A && git commit --amend --no-edit && git push\n' >&2
	fi
	printf '\n' >&2
	printf '  Bypass once (CI will catch the failure):\n' >&2
	printf '    AIDEVOPS_PREPUSH_REPO_VERIFY=0 git push\n' >&2
	printf '\n' >&2
}

_typecheck_missing_bun_dev_dependencies() {
	local log_file="$1"
	[[ -f "$REPO_ROOT/package.json" && -f "$REPO_ROOT/bun.lock" ]] || return 1
	[[ ! -x "$REPO_ROOT/node_modules/.bin/tsc" && -f "$log_file" ]] || return 1
	grep -Eiq '(tsc([^[:alnum:]_]|$).*(command not found|not found)|(command not found|not found).*tsc([^[:alnum:]_]|$))' \
		"$log_file" 2>/dev/null || return 1
	return 0
}

_emit_missing_bun_dev_dependencies() {
	_log BLOCK "typecheck could not start: missing JavaScript dev dependencies"
	printf '\n' >&2
	printf '  Resolution:\n' >&2
	printf '    1. Run: bun install\n' >&2
	printf '    2. Re-run: %s\n' "$VERIFY_TYPECHECK" >&2
	printf '    3. git push (re-runs repo verification)\n' >&2
	printf '\n' >&2
	return 0
}

# ----- main orchestration -------------------------------------------------

main() {
	if _load_verify_config; then
		if [[ "$VERIFY_SOURCE" == "aidevops-json-disabled" ]]; then
			_log INFO "repo opts out via .aidevops.json .verify.enabled=false"
			exit 0
		fi
	else
		_dbg "no verify config resolved — skipping"
		exit 0
	fi

	if [[ -z "$VERIFY_FORMAT$VERIFY_LINT$VERIFY_TYPECHECK" ]]; then
		_dbg "config resolved but no commands set — skipping"
		exit 0
	fi

	# Working-tree cleanliness check: if the WT is dirty, the verify run
	# would conflate user WIP with the actual push state. Warn + skip.
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
		_log WARN "working tree has uncommitted changes — skipping verify"
		_log WARN "commit (or stash) and re-push to verify the push state"
		exit 0
	fi

	_log INFO "verify source: $VERIFY_SOURCE"
	local overall=0

	if [[ -n "$VERIFY_FORMAT" ]]; then
		if ! _run_check 'format' "$VERIFY_FORMAT"; then
			if _run_autofix 'format' "$VERIFY_FORMAT_FIX" "$VERIFY_FORMAT"; then
				:
			else
				_emit_mentor_fail 'format' "$VERIFY_FORMAT_FIX" "$VERIFY_FORMAT"
				overall=1
			fi
		fi
	fi

	if [[ -n "$VERIFY_LINT" ]]; then
		if ! _run_check 'lint' "$VERIFY_LINT"; then
			if _run_autofix 'lint' "$VERIFY_LINT_FIX" "$VERIFY_LINT"; then
				:
			else
				_emit_mentor_fail 'lint' "$VERIFY_LINT_FIX" "$VERIFY_LINT"
				overall=1
			fi
		fi
	fi

	# Typecheck never auto-fixes — semantic failures need code changes
	if [[ -n "$VERIFY_TYPECHECK" ]]; then
		if ! _run_check 'typecheck' "$VERIFY_TYPECHECK"; then
			if _typecheck_missing_bun_dev_dependencies "${LAST_FAIL_LOG:-}"; then
				_emit_missing_bun_dev_dependencies
			else
				_emit_mentor_fail 'typecheck' '' "$VERIFY_TYPECHECK"
			fi
			overall=1
		fi
	fi

	if [[ "$overall" -eq 0 ]]; then
		_log OK "all verify checks passed — allowing push"
	fi
	exit "$overall"
}

# Consume stdin so the dispatcher doesn't see SIGPIPE if we exit early.
# We don't actually use the ref list (we verify the WT, not a diff).
cat >/dev/null 2>&1 || true

main
