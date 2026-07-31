#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2059
#
# install-hooks-helper.sh
# Installs Claude Code PreToolUse hooks to block destructive git/filesystem commands
# and enforce the canonical-workspace protection rule (t1712/t1990, GH#21814).
# git_safety_guard.py is registered under BOTH the 'Bash' AND 'Edit|Write' matchers
# so the Edit/Write branch of the hook is reachable by Claude Code.
#
# Usage:
#   install-hooks-helper.sh install              # Install hooks (default)
#   install-hooks-helper.sh install --force-install  # Install, bypass validator preflight
#   install-hooks-helper.sh uninstall            # Remove hooks
#   install-hooks-helper.sh status               # Check installation status
#   install-hooks-helper.sh test                 # Run hook self-test
#
# Installs to:
#   ~/.aidevops/hooks/git_safety_guard.py  (hook script)
#   ~/.claude/settings.json                (hook configuration)
#
set -euo pipefail

# Colors — sourced from shared-constants.sh (Pattern A, t2053.3)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh disable=SC1091
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

HOOKS_DIR="$HOME/.aidevops/hooks"
HOOK_SCRIPT="$HOOKS_DIR/git_safety_guard.py"
POST_HOOK_SCRIPT="$HOOKS_DIR/mcp_task_post_hook.py"
CREDENTIAL_SCRUB_SCRIPT="$HOOKS_DIR/credential-transcript-scrub.py"
SECRET_READ_GUARD_SCRIPT="$HOOKS_DIR/secret_file_read_guard.py"
COMPLEXITY_ADVISORY_SCRIPT="$HOOKS_DIR/complexity_advisory_pre_edit.py"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOK_COMMAND="\$HOME/.aidevops/hooks/git_safety_guard.py"
POST_HOOK_COMMAND="\$HOME/.aidevops/hooks/mcp_task_post_hook.py"
CREDENTIAL_SCRUB_COMMAND="\$HOME/.aidevops/hooks/credential-transcript-scrub.py"
SECRET_READ_GUARD_COMMAND="\$HOME/.aidevops/hooks/secret_file_read_guard.py"
COMPLEXITY_ADVISORY_COMMAND="\$HOME/.aidevops/hooks/complexity_advisory_pre_edit.py"

# gh-wrapper-guard pre-push hook (t2113)
GH_WRAPPER_GUARD_MARKER="# aidevops-gh-wrapper-guard"
GH_WRAPPER_GUARD_DEPLOYED="$HOME/.aidevops/agents/hooks/gh-wrapper-guard-pre-push.sh"

# pre-commit quality-validation hook (t2191)
PRE_COMMIT_MARKER="# aidevops-pre-commit-hook"
PRE_COMMIT_DEPLOYED="$HOME/.aidevops/agents/scripts/pre-commit-hook.sh"

# pre-push quality-validation hook (t2207) — slow network checks split from pre-commit
PRE_PUSH_QUALITY_MARKER="# aidevops-pre-push-quality-hook"

# markdoc schema conformance pre-commit hook (t2968) — opt-in for knowledge plane repos
MARKDOC_VALIDATE_MARKER="# aidevops-markdoc-validate-hook"
MARKDOC_VALIDATE_DEPLOYED="$HOME/.aidevops/agents/scripts/markdoc-validate.sh"

print_info() {
	local msg="$1"
	printf "${BLUE}[INFO]${NC} %s\n" "$msg"
}
print_success() {
	local msg="$1"
	printf "${GREEN}[OK]${NC} %s\n" "$msg"
}
print_warning() {
	local msg="$1"
	printf "${YELLOW}[WARN]${NC} %s\n" "$msg"
}
print_error() {
	local msg="$1"
	printf "${RED}[ERROR]${NC} %s\n" "$msg"
}

# Find the source hook script (repo .agents/hooks/ or deployed ~/.aidevops/agents/hooks/)
find_source_hook() {
	local hook_name="${1:-git_safety_guard.py}"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_hook="$script_dir/../hooks/$hook_name"
	local deployed_hook="$HOME/.aidevops/agents/hooks/$hook_name"

	if [[ -f "$repo_hook" ]]; then
		echo "$repo_hook"
		return 0
	elif [[ -f "$deployed_hook" ]]; then
		echo "$deployed_hook"
		return 0
	else
		print_error "Source hook '$hook_name' not found in repo or deployed agents"
		return 1
	fi
}

# --- gh-wrapper-guard pre-push hook (t2113) ---

_find_gh_wrapper_guard_hook() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_hook="$script_dir/../hooks/gh-wrapper-guard-pre-push.sh"
	if [[ -f "$repo_hook" ]]; then
		echo "$repo_hook"
		return 0
	fi
	if [[ -f "$GH_WRAPPER_GUARD_DEPLOYED" ]]; then
		echo "$GH_WRAPPER_GUARD_DEPLOYED"
		return 0
	fi
	return 1
}

install_gh_wrapper_guard_hook() {
	# Only install if we're in a git repo
	local common_dir
	common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
		print_warning "Not in a git repo — skipping gh-wrapper-guard pre-push hook"
		return 0
	}

	local hook_path="${common_dir}/hooks/pre-push"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_gh_wrapper_guard_hook); then
		print_warning "gh-wrapper-guard-pre-push.sh not found — skipping"
		return 0
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$GH_WRAPPER_GUARD_MARKER" "$hook_path" 2>/dev/null; then
			print_info "gh-wrapper-guard already in pre-push hook — updating"
		elif grep -q "aidevops" "$hook_path" 2>/dev/null; then
			# Existing aidevops hook (e.g. privacy-guard) — chain ours in
			if ! grep -q "gh-wrapper-guard" "$hook_path" 2>/dev/null; then
				# Append our guard call before the final exec/exit
				# shellcheck disable=SC2016 # single quotes intentional — template content
				{
					printf '\n%s\n' "$GH_WRAPPER_GUARD_MARKER"
					printf '# gh-wrapper-guard: blocks raw gh issue/pr create calls\n'
					printf '_ghwg_hook=""\n'
					printf 'if git_dir=$(git rev-parse --show-toplevel 2>/dev/null); then\n'
					printf '  _ghwg_hook="${git_dir}/.agents/hooks/gh-wrapper-guard-pre-push.sh"\n'
					printf 'fi\n'
					printf 'if [[ -n "$_ghwg_hook" && -f "$_ghwg_hook" ]]; then\n'
					printf '  "$_ghwg_hook" "$@" || exit $?\n'
					printf 'elif [[ -f "%s" ]]; then\n' "$GH_WRAPPER_GUARD_DEPLOYED"
					printf '  "%s" "$@" || exit $?\n' "$GH_WRAPPER_GUARD_DEPLOYED"
					printf 'fi\n'
				} >>"$hook_path"
				print_success "chained gh-wrapper-guard into existing pre-push hook"
			fi
			return 0
		else
			print_warning "existing non-aidevops pre-push hook — cannot auto-install gh-wrapper-guard"
			print_warning "  manually add: $source_hook \"\$@\" || exit \$?"
			return 0
		fi
	fi

	# No existing hook — only install if no privacy-guard installer would manage it
	# Write a standalone dispatcher if no hook exists at all
	if [[ ! -f "$hook_path" ]]; then
		cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$GH_WRAPPER_GUARD_MARKER
# Managed by install-hooks-helper.sh — do not edit.
# Dispatcher for gh-wrapper-guard pre-push hook.
# Bypass with --no-verify or GH_WRAPPER_GUARD_DISABLE=1.

set -u

_ghwg_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_ghwg_hook="\${git_dir}/.agents/hooks/gh-wrapper-guard-pre-push.sh"
fi
_ghwg_deployed="$GH_WRAPPER_GUARD_DEPLOYED"

if [[ -n "\$_ghwg_hook" && -f "\$_ghwg_hook" ]]; then
	"\$_ghwg_hook" "\$@" || exit \$?
elif [[ -f "\$_ghwg_deployed" ]]; then
	"\$_ghwg_deployed" "\$@" || exit \$?
else
	printf '[gh-wrapper-guard][WARN] hook not found — allowing push\n' >&2
fi
HOOKEOF
		chmod +x "$hook_path"
		print_success "installed gh-wrapper-guard pre-push hook at $hook_path"
	fi
	return 0
}

# --- pre-commit quality-validation hook (t2191) ---

_find_pre_commit_hook() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_hook="$script_dir/pre-commit-hook.sh"
	if [[ -f "$repo_hook" ]]; then
		echo "$repo_hook"
		return 0
	fi
	if [[ -f "$PRE_COMMIT_DEPLOYED" ]]; then
		echo "$PRE_COMMIT_DEPLOYED"
		return 0
	fi
	return 1
}

install_pre_commit_hook() {
	# Only install if we're in a git repo
	local common_dir
	common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
		print_warning "Not in a git repo — skipping pre-commit quality hook"
		return 0
	}

	local hook_path="${common_dir}/hooks/pre-commit"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_pre_commit_hook); then
		print_warning "pre-commit-hook.sh not found — skipping"
		return 0
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$PRE_COMMIT_MARKER" "$hook_path" 2>/dev/null; then
			print_info "pre-commit hook already installed — refreshing dispatcher"
		elif grep -qE "^#[[:space:]]*aidevops-[a-z-]+" "$hook_path" 2>/dev/null; then
			# Existing aidevops-managed pre-commit hook — chain ours in.
			# Detection: a sibling aidevops marker line (e.g. the gh-wrapper-guard
			# marker if we ever share pre-commit) rather than bare mentions of
			# "aidevops" in comments/paths, which could false-match.
			if ! grep -q "pre-commit-hook.sh" "$hook_path" 2>/dev/null; then
				# shellcheck disable=SC2016 # single quotes intentional — template content
				{
					printf '\n%s\n' "$PRE_COMMIT_MARKER"
					printf '# pre-commit-hook: shellcheck, TODO.md validation (t2207: fast path only)\n'
					printf '_pch_hook=""\n'
					printf 'if git_dir=$(git rev-parse --show-toplevel 2>/dev/null); then\n'
					printf '  _pch_hook="${git_dir}/.agents/scripts/pre-commit-hook.sh"\n'
					printf 'fi\n'
					printf 'if [[ -n "$_pch_hook" && -f "$_pch_hook" ]]; then\n'
					printf '  HOOK_MODE=pre-commit "$_pch_hook" "$@" || exit $?\n'
					printf 'elif [[ -f "%s" ]]; then\n' "$PRE_COMMIT_DEPLOYED"
					printf '  HOOK_MODE=pre-commit "%s" "$@" || exit $?\n' "$PRE_COMMIT_DEPLOYED"
					printf 'fi\n'
				} >>"$hook_path"
				print_success "chained pre-commit-hook into existing pre-commit hook"
			fi
			return 0
		else
			print_warning "existing non-aidevops pre-commit hook — cannot auto-install"
			print_warning "  manually add: $source_hook \"\$@\" || exit \$?"
			return 0
		fi
	fi

	# Write a dispatcher that prefers the in-repo copy (so script updates
	# propagate without re-running this installer) and falls back to the
	# deployed copy when no repo checkout is available.
	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$PRE_COMMIT_MARKER
# Managed by install-hooks-helper.sh — do not edit.
# Dispatcher for pre-commit quality validation (shellcheck, TODO.md,
# root-file allowlist, task-completion proof-log).
# Slow checks (secretlint, SonarCloud, CodeRabbit) moved to pre-push (t2207).
# Bypass: git commit --no-verify

set -u

_pch_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_pch_hook="\${git_dir}/.agents/scripts/pre-commit-hook.sh"
fi
_pch_deployed="$PRE_COMMIT_DEPLOYED"

if [[ -n "\$_pch_hook" && -f "\$_pch_hook" ]]; then
	HOOK_MODE=pre-commit "\$_pch_hook" "\$@" || exit \$?
elif [[ -f "\$_pch_deployed" ]]; then
	HOOK_MODE=pre-commit "\$_pch_deployed" "\$@" || exit \$?
else
	printf '[pre-commit-hook][WARN] hook not found — allowing commit\n' >&2
fi
HOOKEOF
	chmod +x "$hook_path"
	print_success "installed pre-commit quality hook at $hook_path"
	return 0
}

# --- pre-push quality-validation hook (t2207) ---
# Chains into the existing pre-push hook alongside gh-wrapper-guard and privacy-guard.
# Calls pre-commit-hook.sh with HOOK_MODE=pre-push for slow network checks.

install_pre_push_quality_hook() {
	# Only install if we're in a git repo
	local common_dir
	common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
		print_warning "Not in a git repo — skipping pre-push quality hook"
		return 0
	}

	local hook_path="${common_dir}/hooks/pre-push"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_pre_commit_hook); then
		print_warning "pre-commit-hook.sh not found — skipping pre-push quality hook"
		return 0
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$PRE_PUSH_QUALITY_MARKER" "$hook_path" 2>/dev/null; then
			print_info "pre-push quality hook already installed — skipping"
			return 0
		fi
		# Existing hook (e.g. gh-wrapper-guard, privacy-guard) — chain ours in
		# shellcheck disable=SC2016 # single quotes intentional — template content
		{
			printf '\n%s\n' "$PRE_PUSH_QUALITY_MARKER"
			printf '# pre-push quality checks: secretlint, SonarCloud, CodeRabbit CLI (t2207)\n'
			printf '_ppq_hook=""\n'
			printf 'if git_dir=$(git rev-parse --show-toplevel 2>/dev/null); then\n'
			printf '  _ppq_hook="${git_dir}/.agents/scripts/pre-commit-hook.sh"\n'
			printf 'fi\n'
			printf 'if [[ -n "$_ppq_hook" && -f "$_ppq_hook" ]]; then\n'
			printf '  HOOK_MODE=pre-push "$_ppq_hook" "$@" || exit $?\n'
			printf 'elif [[ -f "%s" ]]; then\n' "$PRE_COMMIT_DEPLOYED"
			printf '  HOOK_MODE=pre-push "%s" "$@" || exit $?\n' "$PRE_COMMIT_DEPLOYED"
			printf 'fi\n'
		} >>"$hook_path"
		print_success "chained pre-push quality hook into existing pre-push hook"
		return 0
	fi

	# No existing hook — write a standalone dispatcher
	cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$PRE_PUSH_QUALITY_MARKER
# Managed by install-hooks-helper.sh — do not edit.
# Dispatcher for pre-push quality validation (secretlint, SonarCloud, CodeRabbit).
# Bypass: git push --no-verify

set -u

_ppq_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_ppq_hook="\${git_dir}/.agents/scripts/pre-commit-hook.sh"
fi
_ppq_deployed="$PRE_COMMIT_DEPLOYED"

if [[ -n "\$_ppq_hook" && -f "\$_ppq_hook" ]]; then
	HOOK_MODE=pre-push "\$_ppq_hook" "\$@" || exit \$?
elif [[ -f "\$_ppq_deployed" ]]; then
	HOOK_MODE=pre-push "\$_ppq_deployed" "\$@" || exit \$?
else
	printf '[pre-push-quality][WARN] hook not found — allowing push\n' >&2
fi
HOOKEOF
	chmod +x "$hook_path"
	print_success "installed pre-push quality hook at $hook_path"
	return 0
}

# --- Markdoc schema conformance pre-commit hook (t2968) ---
# Opt-in: installed when the repo has at least one knowledge plane directory
# OR when AIDEVOPS_MARKDOC_VALIDATE=1 is set. The validate-staged command
# is a no-op (exit 0) when no knowledge plane *.md files are staged.

_kp_dirs=(
	"_knowledge" "_cases" "_projects"
	"_performance" "_feedback" "_campaigns" "_inbox"
)

_has_knowledge_plane_dir() {
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	local _d
	for _d in "${_kp_dirs[@]}"; do
		[[ -d "${repo_root}/${_d}" ]] && return 0
	done
	return 1
}

install_markdoc_validate_hook() {
	# Opt-in: skip unless KP dirs exist or env flag set
	if [[ "${AIDEVOPS_MARKDOC_VALIDATE:-0}" != "1" ]] && ! _has_knowledge_plane_dir; then
		print_info "markdoc-validate: no knowledge plane dirs found — skipping (set AIDEVOPS_MARKDOC_VALIDATE=1 to force)"
		return 0
	fi

	local common_dir
	if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
		print_info "markdoc-validate: not in a git repo — skipping"
		return 0
	fi

	local hook_path="${common_dir}/hooks/pre-commit"

	if [[ -f "$hook_path" ]] && grep -q "$MARKDOC_VALIDATE_MARKER" "$hook_path" 2>/dev/null; then
		print_info "markdoc-validate pre-commit hook already installed — skipping"
		return 0
	fi

	# Build the hook body with a single-quoted heredoc (no \$ escaping needed).
	# AIDEVOPS_DEPLOYED_PLACEHOLDER is substituted for the actual path after the
	# heredoc, keeping the body text free of double-heredoc duplication which
	# would trigger the repeated-string-literal ratchet gate (t2968).
	local _deployed="${MARKDOC_VALIDATE_DEPLOYED}"
	local hook_snippet
	hook_snippet=$(cat <<'SNIPPET'
_mkdv_hook=""
if _mkdv_root=$(git rev-parse --show-toplevel 2>/dev/null); then
	_mkdv_hook="${_mkdv_root}/.agents/scripts/markdoc-validate.sh"
fi
_mkdv_deployed="AIDEVOPS_DEPLOYED_PLACEHOLDER"
if [[ -f "$_mkdv_hook" ]]; then
	"$_mkdv_hook" validate-staged || exit $?
elif [[ -f "$_mkdv_deployed" ]]; then
	"$_mkdv_deployed" validate-staged || exit $?
else
	printf '[markdoc-validate][WARN] markdoc-validate.sh not found — skipping\n' >&2
fi
SNIPPET
	)
	hook_snippet="${hook_snippet//AIDEVOPS_DEPLOYED_PLACEHOLDER/$_deployed}"

	local _header
	_header="$MARKDOC_VALIDATE_MARKER
# Managed by install-hooks-helper.sh — do not edit.
# Validates staged Markdoc-tagged knowledge plane files. Bypass: git commit --no-verify"

	if [[ ! -f "$hook_path" ]]; then
		# No existing hook — create a standalone dispatcher
		printf '#!/usr/bin/env bash\n%s\n\nset -u\n\n%s\n' \
			"$_header" "$hook_snippet" >"$hook_path"
		chmod +x "$hook_path"
		print_success "installed markdoc-validate pre-commit hook at $hook_path"
		return 0
	fi

	# Existing hook — append the snippet
	if grep -q "$MARKDOC_VALIDATE_MARKER" "$hook_path" 2>/dev/null; then
		print_info "markdoc-validate: already chained in $hook_path"
		return 0
	fi

	printf '\n%s\n\n%s\n' "$_header" "$hook_snippet" >>"$hook_path"
	print_success "chained markdoc-validate into existing pre-commit hook at $hook_path"
	return 0
}

_check_status_markdoc_validate_hook() {
	local common_dir hook_path
	if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
		print_info "markdoc-validate: not in a git repo — skipped"
		return 0
	fi
	hook_path="${common_dir}/hooks/pre-commit"
	if [[ -f "$hook_path" ]] && grep -q "$MARKDOC_VALIDATE_MARKER" "$hook_path" 2>/dev/null; then
		print_success "markdoc-validate: installed in pre-commit hook"
	else
		print_info "markdoc-validate: not installed (set AIDEVOPS_MARKDOC_VALIDATE=1 and run: install-hooks-helper.sh install)"
	fi
	return 0
}

# --- Pre-install validator dry-run (t2226) ---
# Runs all validate_* functions from pre-commit-hook.sh against HEAD state.
# If any validator fails a no-op commit, the hook is buggy and would strand
# the repo — abort before installing.

_dry_run_validators() {
	local hook_source="$1"
	local force_install="${2:-false}"

	print_info "Running pre-install validator dry-run against HEAD..."

	# Find the pre-commit-hook.sh source
	local pch_source
	pch_source=$(_find_pre_commit_hook) || {
		print_warning "pre-commit-hook.sh not found — skipping validator preflight"
		return 0
	}

	# Enumerate validator functions from the hook source
	local validators=()
	while IFS= read -r fn; do
		[[ -n "$fn" ]] && validators+=("$fn")
	done < <(grep -oE 'validate_[a-z_]+\(\)' "$pch_source" | sed 's/()//' | sort -u)

	if [[ ${#validators[@]} -eq 0 ]]; then
		print_warning "No validate_* functions found in $pch_source — skipping preflight"
		return 0
	fi

	print_info "Found ${#validators[@]} validators: ${validators[*]}"

	# Gather a representative sample of tracked .sh files for file-arg validators.
	# Use git ls-files from the repo root for consistent paths.
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."
	local shell_files=()
	while IFS= read -r f; do
		[[ -n "$f" ]] && shell_files+=("$f")
	done < <(git -C "$repo_root" ls-files '*.sh' 2>/dev/null | head -20)

	# Validators that accept file arguments (iterate over "$@" internally).
	# All others are no-arg (check staged state, which is empty for dry-run → pass).
	local file_arg_validators="validate_return_statements validate_positional_parameters validate_string_literals"

	local failed_validators=()

	for validator in "${validators[@]}"; do
		local exit_code=0
		# Run each validator in a subshell that sources the hook but skips main()
		if [[ " $file_arg_validators " == *" $validator "* ]]; then
			# File-arg validator: pass tracked shell files
			if [[ ${#shell_files[@]} -gt 0 ]]; then
				(
					# Source everything except the final main "$@" call
					# shellcheck disable=SC1090
					eval "$(sed '$ { /^main "\$@"$/d; }' "$pch_source")"
					"$validator" "${shell_files[@]}"
				) >/dev/null 2>&1 || exit_code=$?
			fi
		else
			# No-arg validator: call directly (nothing staged → trivial pass)
			(
				# shellcheck disable=SC1090
				eval "$(sed '$ { /^main "\$@"$/d; }' "$pch_source")"
				"$validator"
			) >/dev/null 2>&1 || exit_code=$?
		fi

		if [[ $exit_code -ne 0 ]]; then
			failed_validators+=("$validator")
			print_error "  FAIL: $validator (exit $exit_code)"
		else
			print_success "  PASS: $validator"
		fi
	done

	if [[ ${#failed_validators[@]} -gt 0 ]]; then
		echo ""
		if [[ "$force_install" == "true" ]]; then
			print_warning "Bypassing validator preflight (--force-install)."
			print_warning "Failing validators: ${failed_validators[*]}"
			print_warning "The installed hook may reject commits until these are fixed."
			return 0
		fi
		print_error "Validator preflight failed — ${#failed_validators[@]} validator(s) fail against current HEAD:"
		for v in "${failed_validators[@]}"; do
			print_error "  - $v"
		done
		echo ""
		print_error "Installing the hook would strand this repo (commits rejected until fixed)."
		print_info "Fix the validator(s) first, or re-run with --force-install to bypass:"
		print_info "  install-hooks-helper.sh install --force-install"
		return 1
	fi

	print_success "All ${#validators[@]} validators pass against HEAD — safe to install"
	return 0
}

install_hook() {
	local force_install="false"
	local arg
	for arg in "$@"; do
		case "$arg" in
		--force-install) force_install="true" ;;
		esac
	done

	print_info "Installing Claude Code safety hooks..."

	# Check Python is available
	if ! command -v python3 &>/dev/null; then
		print_error "Python 3 is required but not found"
		return 1
	fi

	# Find source hook
	local source_hook
	source_hook=$(find_source_hook) || return 1
	local source_post_hook
	source_post_hook=$(find_source_hook "mcp_task_post_hook.py") || return 1
	local source_credential_scrub_hook
	source_credential_scrub_hook=$(find_source_hook "credential-transcript-scrub.py") || return 1
	local source_secret_read_guard_hook
	source_secret_read_guard_hook=$(find_source_hook "secret_file_read_guard.py") || return 1
	local source_complexity_advisory_hook
	source_complexity_advisory_hook=$(find_source_hook "complexity_advisory_pre_edit.py") || return 1

	# Pre-install validator dry-run (t2226): abort if validators fail HEAD state
	_dry_run_validators "$source_hook" "$force_install" || return 1

	# Create hooks directory
	mkdir -p "$HOOKS_DIR"

	# Copy hook script
	cp "$source_hook" "$HOOK_SCRIPT"
	chmod +x "$HOOK_SCRIPT"
	print_success "Installed $HOOK_SCRIPT"
	cp "$source_post_hook" "$POST_HOOK_SCRIPT"
	chmod +x "$POST_HOOK_SCRIPT"
	print_success "Installed $POST_HOOK_SCRIPT"
	cp "$source_credential_scrub_hook" "$CREDENTIAL_SCRUB_SCRIPT"
	chmod +x "$CREDENTIAL_SCRUB_SCRIPT"
	print_success "Installed $CREDENTIAL_SCRUB_SCRIPT"
	cp "$source_secret_read_guard_hook" "$SECRET_READ_GUARD_SCRIPT"
	chmod +x "$SECRET_READ_GUARD_SCRIPT"
	print_success "Installed $SECRET_READ_GUARD_SCRIPT"
	cp "$source_complexity_advisory_hook" "$COMPLEXITY_ADVISORY_SCRIPT"
	chmod +x "$COMPLEXITY_ADVISORY_SCRIPT"
	print_success "Installed $COMPLEXITY_ADVISORY_SCRIPT"

	# Configure Claude Code settings.json
	configure_claude_settings || return 1

	# Run self-test
	test_hook || return 1

	echo ""
	print_success "Safety hooks installed successfully"
	echo ""
	echo "Blocked commands:"
	echo "  git checkout -- <files>    git restore <files>"
	echo "  git reset --hard           git clean -f"
	echo "  git push --force / -f      git branch -D"
	echo "  rm -rf (non-temp paths)    git stash drop/clear"
	echo ""
	print_warning "Restart Claude Code for the hook to take effect"

	# Also install the gh-wrapper-guard pre-push hook (t2113)
	install_gh_wrapper_guard_hook

	# Also install the pre-commit quality-validation hook (t2191)
	install_pre_commit_hook

	# Also install the pre-push quality-validation hook (t2207)
	install_pre_push_quality_hook

	# Also install the markdoc-validate pre-commit hook (t2968, opt-in)
	install_markdoc_validate_hook

	return 0
}

configure_claude_settings() {
	mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

	if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
		# Create new settings with hook
		python3 -c "
import json, sys, os, tempfile
settings = {
    'hooks': {
        'PreToolUse': [
            {
                'matcher': 'Bash',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$HOOK_COMMAND'
                    }
                ]
            },
            {
                'matcher': 'Read|Glob|NotebookRead',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$SECRET_READ_GUARD_COMMAND'
                    }
                ]
            },
            {
                'matcher': 'Edit|Write',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$HOOK_COMMAND'
                    },
                    {
                        'type': 'command',
                        'command': '$COMPLEXITY_ADVISORY_COMMAND'
                    }
                ]
            }
        ],
        'PostToolUse': [
            {
                'matcher': 'Task',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$POST_HOOK_COMMAND'
                    }
                ]
            },
            {
                'matcher': '.*',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$CREDENTIAL_SCRUB_COMMAND'
                    }
                ]
            }
        ]
    }
}
path = '$CLAUDE_SETTINGS'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, path)
" || {
			print_error "Failed to create settings.json"
			return 1
		}
		print_success "Created $CLAUDE_SETTINGS with hook configuration"
		return 0
	fi

	# Check if hook is already configured (including Edit|Write registration — GH#21814)
	if python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
hooks = d.get('hooks', {})
has_guard_bash = False
has_guard_edit_write = False
has_complexity = False
has_secret_read_guard = False
for h in hooks.get('PreToolUse', []):
    matcher = h.get('matcher', '')
    for sub in h.get('hooks', []):
        cmd = sub.get('command', '')
        if 'git_safety_guard' in cmd:
            if matcher == 'Bash':
                has_guard_bash = True
            if 'Edit' in matcher or 'Write' in matcher:
                has_guard_edit_write = True
        if 'complexity_advisory' in cmd:
            has_complexity = True
        if 'secret_file_read_guard' in cmd:
            has_secret_read_guard = True

has_post = False
has_scrub = False
for h in hooks.get('PostToolUse', []):
    for sub in h.get('hooks', []):
        if 'mcp_task_post_hook' in sub.get('command', ''):
            has_post = True
        if 'credential-transcript-scrub' in sub.get('command', ''):
            has_scrub = True

if has_guard_bash and has_guard_edit_write and has_complexity and has_secret_read_guard and has_post and has_scrub:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_info "Hook already configured in $CLAUDE_SETTINGS"
		return 0
	fi

	# Merge hook into existing settings
	python3 -c "
import json, sys, os, tempfile

with open('$CLAUDE_SETTINGS') as f:
    settings = json.load(f)

if 'hooks' not in settings:
    settings['hooks'] = {}

def has_hook(entries, needle):
    for entry in entries:
        for sub in entry.get('hooks', []):
            if needle in sub.get('command', ''):
                return True
    return False

def has_hook_in_matcher(entries, matcher_value, needle):
    # Return True if needle is in hooks of the entry with matcher == matcher_value
    for entry in entries:
        if entry.get('matcher') == matcher_value:
            for sub in entry.get('hooks', []):
                if needle in sub.get('command', ''):
                    return True
    return False

def ensure_hook_in_matcher(entries, matcher_value, hook_cmd):
    # Ensure hook_cmd is present in the entry with matcher_value (create entry if needed)
    hook_sub = {'type': 'command', 'command': hook_cmd}
    for entry in entries:
        if entry.get('matcher') == matcher_value:
            cmds = [s.get('command', '') for s in entry.get('hooks', [])]
            if not any(hook_cmd in c for c in cmds):
                # Insert at position 0 so git_safety_guard runs before complexity_advisory
                entry['hooks'].insert(0, hook_sub)
            return
    # matcher_value entry not found -- create it
    entries.append({'matcher': matcher_value, 'hooks': [hook_sub]})

hook_entry = {
    'matcher': 'Bash',
    'hooks': [
        {
            'type': 'command',
            'command': '$HOOK_COMMAND'
        }
    ]
}

complexity_advisory_entry = {
    'matcher': 'Edit|Write',
    'hooks': [
        {
            'type': 'command',
            'command': '$HOOK_COMMAND'
        },
        {
            'type': 'command',
            'command': '$COMPLEXITY_ADVISORY_COMMAND'
        }
    ]
}

secret_read_guard_entry = {
    'matcher': 'Read|Glob|NotebookRead',
    'hooks': [
        {
            'type': 'command',
            'command': '$SECRET_READ_GUARD_COMMAND'
        }
    ]
}

post_hook_entry = {
    'matcher': 'Task',
    'hooks': [
        {
            'type': 'command',
            'command': '$POST_HOOK_COMMAND'
        }
    ]
}

credential_scrub_entry = {
    'matcher': '.*',
    'hooks': [
        {
            'type': 'command',
            'command': '$CREDENTIAL_SCRUB_COMMAND'
        }
    ]
}

if 'PreToolUse' not in settings['hooks']:
    settings['hooks']['PreToolUse'] = [hook_entry, secret_read_guard_entry, complexity_advisory_entry]
else:
    if not has_hook(settings['hooks']['PreToolUse'], 'git_safety_guard'):
        settings['hooks']['PreToolUse'].append(hook_entry)
    # Also ensure git_safety_guard is in the Edit|Write matcher (GH#21814)
    ensure_hook_in_matcher(settings['hooks']['PreToolUse'], 'Edit|Write', '$HOOK_COMMAND')
    if not has_hook(settings['hooks']['PreToolUse'], 'complexity_advisory'):
        settings['hooks']['PreToolUse'].append(complexity_advisory_entry)
    if not has_hook(settings['hooks']['PreToolUse'], 'secret_file_read_guard'):
        settings['hooks']['PreToolUse'].append(secret_read_guard_entry)

if 'PostToolUse' not in settings['hooks']:
    settings['hooks']['PostToolUse'] = [post_hook_entry, credential_scrub_entry]
else:
    if not has_hook(settings['hooks']['PostToolUse'], 'mcp_task_post_hook'):
        settings['hooks']['PostToolUse'].append(post_hook_entry)
    if not has_hook(settings['hooks']['PostToolUse'], 'credential-transcript-scrub'):
        settings['hooks']['PostToolUse'].append(credential_scrub_entry)

path = '$CLAUDE_SETTINGS'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, path)
" || {
		print_error "Failed to update settings.json"
		return 1
	}
	print_success "Updated $CLAUDE_SETTINGS with hook configuration"
	return 0
}

uninstall_hook() {
	print_info "Removing Claude Code safety hooks..."

	# Remove hook script
	if [[ -f "$HOOK_SCRIPT" ]]; then
		rm "$HOOK_SCRIPT"
		print_success "Removed $HOOK_SCRIPT"
	else
		print_info "Hook script not found (already removed)"
	fi
	if [[ -f "$POST_HOOK_SCRIPT" ]]; then
		rm "$POST_HOOK_SCRIPT"
		print_success "Removed $POST_HOOK_SCRIPT"
	else
		print_info "Post hook script not found (already removed)"
	fi
	if [[ -f "$CREDENTIAL_SCRUB_SCRIPT" ]]; then
		rm "$CREDENTIAL_SCRUB_SCRIPT"
		print_success "Removed $CREDENTIAL_SCRUB_SCRIPT"
	else
		print_info "Credential scrub hook not found (already removed)"
	fi
	if [[ -f "$SECRET_READ_GUARD_SCRIPT" ]]; then
		rm "$SECRET_READ_GUARD_SCRIPT"
		print_success "Removed $SECRET_READ_GUARD_SCRIPT"
	else
		print_info "Secret read guard hook not found (already removed)"
	fi
	if [[ -f "$COMPLEXITY_ADVISORY_SCRIPT" ]]; then
		rm "$COMPLEXITY_ADVISORY_SCRIPT"
		print_success "Removed $COMPLEXITY_ADVISORY_SCRIPT"
	else
		print_info "Complexity advisory hook not found (already removed)"
	fi

	# Remove from Claude settings
	if [[ -f "$CLAUDE_SETTINGS" ]]; then
		python3 -c "
import json, os, tempfile

with open('$CLAUDE_SETTINGS') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {}).get('PreToolUse', [])
filtered = []
for h in hooks:
    sub_hooks = h.get('hooks', [])
    sub_filtered = [s for s in sub_hooks if 'git_safety_guard' not in s.get('command', '') and 'complexity_advisory' not in s.get('command', '') and 'secret_file_read_guard' not in s.get('command', '')]
    if sub_filtered:
        h['hooks'] = sub_filtered
        filtered.append(h)

if filtered:
    settings['hooks']['PreToolUse'] = filtered
elif 'PreToolUse' in settings.get('hooks', {}):
    del settings['hooks']['PreToolUse']

post_hooks = settings.get('hooks', {}).get('PostToolUse', [])
post_filtered = []
for h in post_hooks:
    sub_hooks = h.get('hooks', [])
    sub_filtered = [s for s in sub_hooks if 'mcp_task_post_hook' not in s.get('command', '') and 'credential-transcript-scrub' not in s.get('command', '')]
    if sub_filtered:
        h['hooks'] = sub_filtered
        post_filtered.append(h)

if post_filtered:
    settings['hooks']['PostToolUse'] = post_filtered
elif 'PostToolUse' in settings.get('hooks', {}):
    del settings['hooks']['PostToolUse']

if 'hooks' in settings and not settings['hooks']:
    del settings['hooks']

path = '$CLAUDE_SETTINGS'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, path)
" 2>/dev/null && print_success "Removed hook from $CLAUDE_SETTINGS"
	fi

	# Clean up empty hooks directory
	if [[ -d "$HOOKS_DIR" ]] && [[ -z "$(ls -A "$HOOKS_DIR" 2>/dev/null)" ]]; then
		rmdir "$HOOKS_DIR"
		print_info "Removed empty hooks directory"
	fi

	print_success "Safety hooks uninstalled"
	print_warning "Restart Claude Code for changes to take effect"
	return 0
}

# Individual status check helpers — extracted from check_status to keep the
# aggregator under the 100-line complexity threshold (t2207).
# Each returns 0 when the check passes, 1 when it fails; informational checks
# that never contribute to overall fail state (git-hook installation checks)
# always return 0.

_check_status_hook_script() {
	if [[ -f "$HOOK_SCRIPT" ]]; then
		print_success "Hook script: $HOOK_SCRIPT"
		if [[ -x "$HOOK_SCRIPT" ]]; then
			print_success "  Executable: yes"
			return 0
		fi
		print_warning "  Executable: no (run: chmod +x $HOOK_SCRIPT)"
		return 1
	fi
	print_error "Hook script: not installed"
	return 1
}

_check_status_python() {
	if command -v python3 &>/dev/null; then
		print_success "Python 3: $(python3 --version 2>&1)"
		return 0
	fi
	print_error "Python 3: not found"
	return 1
}

_check_status_claude_settings() {
	if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
		print_error "Claude settings: $CLAUDE_SETTINGS not found"
		return 1
	fi
	# Verify git_safety_guard is registered under BOTH Bash AND Edit|Write (GH#21814)
	if python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
hooks = d.get('hooks', {}).get('PreToolUse', [])
has_bash = False
has_edit_write = False
for h in hooks:
    matcher = h.get('matcher', '')
    for sub in h.get('hooks', []):
        if 'git_safety_guard' in sub.get('command', ''):
            if matcher == 'Bash':
                has_bash = True
            if 'Edit' in matcher or 'Write' in matcher:
                has_edit_write = True
if has_bash and has_edit_write:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_success "Claude settings: hook configured (Bash + Edit|Write)"
		return 0
	fi
	# Partial registration (old install): only in Bash
	if python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
hooks = d.get('hooks', {}).get('PreToolUse', [])
for h in hooks:
    for sub in h.get('hooks', []):
        if 'git_safety_guard' in sub.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_warning "Claude settings: hook in Bash only — Edit|Write registration missing (re-run: install-hooks-helper.sh install)"
		return 1
	fi
	print_warning "Claude settings: exists but hook not configured (run: install-hooks-helper.sh install)"
	return 1
}

_check_status_complexity_advisory() {
	if [[ -f "$COMPLEXITY_ADVISORY_SCRIPT" ]] && [[ -x "$COMPLEXITY_ADVISORY_SCRIPT" ]]; then
		print_success "complexity-advisory: $COMPLEXITY_ADVISORY_SCRIPT"
	elif [[ -f "$COMPLEXITY_ADVISORY_SCRIPT" ]]; then
		print_warning "complexity-advisory: installed but not executable"
		return 1
	else
		print_warning "complexity-advisory: not installed (run: install-hooks-helper.sh install)"
		return 1
	fi
	if [[ -f "$CLAUDE_SETTINGS" ]] && python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
for h in d.get('hooks', {}).get('PreToolUse', []):
    for sub in h.get('hooks', []):
        if 'complexity_advisory' in sub.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_success "  PreToolUse registration: present"
	else
		print_warning "  PreToolUse registration: missing (run: install-hooks-helper.sh install)"
		return 1
	fi
	return 0
}

_check_status_gh_wrapper_guard() {
	local common_dir hook_path
	if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
		print_info "gh-wrapper-guard: not in a git repo — skipped"
		return 0
	fi
	hook_path="${common_dir}/hooks/pre-push"
	if [[ -f "$hook_path" ]] && grep -q "$GH_WRAPPER_GUARD_MARKER" "$hook_path" 2>/dev/null; then
		print_success "gh-wrapper-guard: installed in pre-push hook"
	elif [[ -f "$hook_path" ]] && grep -q "gh-wrapper-guard" "$hook_path" 2>/dev/null; then
		print_success "gh-wrapper-guard: chained in pre-push hook"
	else
		print_warning "gh-wrapper-guard: not installed (run: install-hooks-helper.sh install)"
	fi
	return 0
}

_check_status_credential_scrub_hook() {
	if [[ -f "$CREDENTIAL_SCRUB_SCRIPT" ]] && [[ -x "$CREDENTIAL_SCRUB_SCRIPT" ]]; then
		print_success "credential-transcript-scrub: $CREDENTIAL_SCRUB_SCRIPT"
	elif [[ -f "$CREDENTIAL_SCRUB_SCRIPT" ]]; then
		print_warning "credential-transcript-scrub: installed but not executable"
		return 1
	else
		print_warning "credential-transcript-scrub: not installed (run: install-hooks-helper.sh install)"
		return 1
	fi
	if [[ -f "$CLAUDE_SETTINGS" ]] && python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
for h in d.get('hooks', {}).get('PostToolUse', []):
    for sub in h.get('hooks', []):
        if 'credential-transcript-scrub' in sub.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_success "  PostToolUse registration: present"
	else
		print_warning "  PostToolUse registration: missing (run: install-hooks-helper.sh install)"
		return 1
	fi
	return 0
}

_check_status_secret_read_guard_hook() {
	if [[ -f "$SECRET_READ_GUARD_SCRIPT" ]] && [[ -x "$SECRET_READ_GUARD_SCRIPT" ]]; then
		print_success "secret-file-read-guard: $SECRET_READ_GUARD_SCRIPT"
	elif [[ -f "$SECRET_READ_GUARD_SCRIPT" ]]; then
		print_warning "secret-file-read-guard: installed but not executable"
		return 1
	else
		print_warning "secret-file-read-guard: not installed (run: install-hooks-helper.sh install)"
		return 1
	fi
	if [[ -f "$CLAUDE_SETTINGS" ]] && python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
for h in d.get('hooks', {}).get('PreToolUse', []):
    for sub in h.get('hooks', []):
        if 'secret_file_read_guard' in sub.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_success "  PreToolUse registration: present"
	else
		print_warning "  PreToolUse registration: missing (run: install-hooks-helper.sh install)"
		return 1
	fi
	return 0
}

_check_status_precommit_hook() {
	local common_dir pc_hook_path
	if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
		print_info "pre-commit-hook: not in a git repo — skipped"
		return 0
	fi
	pc_hook_path="${common_dir}/hooks/pre-commit"
	if [[ -f "$pc_hook_path" ]] && grep -q "$PRE_COMMIT_MARKER" "$pc_hook_path" 2>/dev/null; then
		print_success "pre-commit-hook: installed"
	elif [[ -f "$pc_hook_path" ]] && grep -q "pre-commit-hook.sh" "$pc_hook_path" 2>/dev/null; then
		print_success "pre-commit-hook: chained in pre-commit hook"
	else
		print_warning "pre-commit-hook: not installed (run: install-hooks-helper.sh install)"
	fi
	return 0
}

_check_status_prepush_quality_hook() {
	local common_dir pp_hook_path
	if ! common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
		print_info "pre-push-quality-hook: not in a git repo — skipped"
		return 0
	fi
	pp_hook_path="${common_dir}/hooks/pre-push"
	if [[ -f "$pp_hook_path" ]] && grep -q "$PRE_PUSH_QUALITY_MARKER" "$pp_hook_path" 2>/dev/null; then
		print_success "pre-push-quality-hook: installed"
	elif [[ -f "$pp_hook_path" ]] && grep -q "HOOK_MODE=pre-push" "$pp_hook_path" 2>/dev/null; then
		print_success "pre-push-quality-hook: chained in pre-push hook"
	else
		print_warning "pre-push-quality-hook: not installed (run: install-hooks-helper.sh install)"
	fi
	return 0
}

check_status() {
	local all_ok=true

	echo "Claude Code Safety Hooks Status"
	echo "================================"

	_check_status_hook_script || all_ok=false
	_check_status_python || all_ok=false
	_check_status_claude_settings || all_ok=false

	echo ""
	echo "Complexity Advisory Hook (t2864)"
	echo "---------------------------------"
	_check_status_complexity_advisory || all_ok=false

	echo ""
	echo "Credential Transcript Scrub Hook (GH#20207)"
	echo "--------------------------------------------"
	_check_status_credential_scrub_hook || all_ok=false

	echo ""
	echo "Secret File Read Guard Hook (GH#22368)"
	echo "----------------------------------------"
	_check_status_secret_read_guard_hook || all_ok=false

	echo ""
	echo "GH Wrapper Guard (pre-push)"
	echo "----------------------------"
	_check_status_gh_wrapper_guard

	echo ""
	echo "Pre-commit Quality Hook"
	echo "------------------------"
	_check_status_precommit_hook

	echo ""
	echo "Pre-push Quality Hook (t2207)"
	echo "------------------------------"
	_check_status_prepush_quality_hook

	echo ""
	echo "Markdoc Validate Hook (t2968, opt-in)"
	echo "--------------------------------------"
	_check_status_markdoc_validate_hook

	echo ""
	if [[ "$all_ok" == "true" ]]; then
		print_success "All checks passed - safety hooks are active"
	else
		print_warning "Some checks failed - run: install-hooks-helper.sh install"
	fi
	return 0
}

_test_hook_script_path() {
	# Always test the source about to be installed. The currently deployed hook
	# may be stale while setup is repairing an interrupted deployment.
	local test_script=""
	test_script=$(find_source_hook) || return 1
	printf '%s\n' "$test_script"
	return 0
}

_test_hook_create_repo() {
	local test_root="$1"
	local managed="${2:-true}"
	local real_git="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
	"$real_git" -C "$test_root" init -b main >/dev/null 2>&1 || {
		"$real_git" -C "$test_root" init >/dev/null 2>&1
		"$real_git" -C "$test_root" checkout -b main >/dev/null 2>&1
	}
	"$real_git" -C "$test_root" config user.name "Aidevops Hook Test"
	"$real_git" -C "$test_root" config user.email "test@example.com"
	"$real_git" -C "$test_root" config commit.gpgsign false
	if [[ "$managed" == "true" ]]; then
		printf '{}\n' >"${test_root}/.aidevops.json"
	fi
	printf 'seed\n' >"${test_root}/README.md"
	"$real_git" -C "$test_root" add README.md >/dev/null 2>&1
	"$real_git" -C "$test_root" commit -m "test: seed hook self-test" >/dev/null 2>&1
	return 0
}

_test_hook_run() {
	local cwd="$1"
	local test_script="$2"
	local cmd="$3"
	local result
	local policy_guard="${SCRIPT_DIR}/canonical-git-command-guard.py"
	local hook_input="{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"$cmd\"}}"
	result=$(cd "$cwd" && AIDEVOPS_CANONICAL_GIT_GUARD="$policy_guard" python3 "$test_script" 2>/dev/null <<<"$hook_input")
	printf '%s\n' "$result"
	return 0
}

_test_hook_expect_blocked() {
	local test_root="$1"
	local test_script="$2"
	local cmd="$3"
	local result
	result=$(_test_hook_run "$test_root" "$test_script" "$cmd")
	if echo "$result" | grep -q "permissionDecision.*deny" 2>/dev/null; then
		return 0
	fi
	print_error "  FAIL: should block: $cmd"
	return 1
}

_test_hook_expect_allowed() {
	local cwd="$1"
	local test_script="$2"
	local cmd="$3"
	local message="$4"
	local result
	result=$(_test_hook_run "$cwd" "$test_script" "$cmd")
	if [[ -z "$result" ]]; then
		return 0
	fi
	print_error "  FAIL: $message: $cmd"
	return 1
}

_test_hook_run_blocked_cases() {
	local test_root="$1"
	local test_script="$2"
	local cmd
	local -a blocked_cmds=(
		"git checkout -- test.txt"
		"git reset --hard"
		"git clean -f"
		"git checkout -b new-branch"
		"git checkout --orphan gh-pages"
		"git push --force origin main"
		"git push -f origin main"
		"git branch -D old-branch"
		"rm -rf /some/path"
		"git stash drop"
		"git stash clear"
		"/usr/bin/git reset --hard"
		"git restore file.txt"
		"git restore --staged file.txt"
		"git push --force-with-lease"
		"git branch -d old-branch"
	)

	for cmd in "${blocked_cmds[@]}"; do
		if _test_hook_expect_blocked "$test_root" "$test_script" "$cmd"; then
			HOOK_TEST_PASS=$((HOOK_TEST_PASS + 1))
		else
			HOOK_TEST_FAIL=$((HOOK_TEST_FAIL + 1))
		fi
	done
	return 0
}

_test_hook_run_allowed_cases() {
	local test_root="$1"
	local test_script="$2"
	local cmd
	local -a allowed_cmds=(
		"git status"
		"git clean -fn"
		"git clean --dry-run"
		"rm -rf /tmp/test-dir"
		"ls -la"
	)

	for cmd in "${allowed_cmds[@]}"; do
		if _test_hook_expect_allowed "$test_root" "$test_script" "$cmd" "should allow"; then
			HOOK_TEST_PASS=$((HOOK_TEST_PASS + 1))
		else
			HOOK_TEST_FAIL=$((HOOK_TEST_FAIL + 1))
		fi
	done
	return 0
}

_test_hook_run_linked_worktree_cases() {
	local linked_worktree="$1"
	local test_script="$2"
	local cmd
	local -a linked_allowed_cmds=(
		"git checkout -b linked-branch"
		"git checkout --orphan linked-pages"
	)

	for cmd in "${linked_allowed_cmds[@]}"; do
		if _test_hook_expect_allowed "$linked_worktree" "$test_script" "$cmd" "should allow in linked worktree"; then
			HOOK_TEST_PASS=$((HOOK_TEST_PASS + 1))
		else
			HOOK_TEST_FAIL=$((HOOK_TEST_FAIL + 1))
		fi
	done
	return 0
}

_test_hook_run_unmanaged_cases() {
	local unmanaged_root="$1"
	local test_script="$2"

	if _test_hook_expect_allowed "$unmanaged_root" "$test_script" \
		"git branch -m main external/example" "should allow in unmanaged repository"; then
		HOOK_TEST_PASS=$((HOOK_TEST_PASS + 1))
	else
		HOOK_TEST_FAIL=$((HOOK_TEST_FAIL + 1))
	fi
	return 0
}

test_hook() {
	print_info "Running hook self-test..."

	local test_script
	test_script=$(_test_hook_script_path) || return 1

	local test_root=""
	test_root=$(mktemp -d) || return 1
	test_root=$(cd "$test_root" && pwd -P) || return 1
	_test_hook_create_repo "$test_root"

	local linked_worktree="${test_root}/linked-wt"
	local real_git="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
	"$real_git" -C "$test_root" worktree add "$linked_worktree" -b feature/hook-linked-test >/dev/null 2>&1
	local unmanaged_root="${test_root}/unmanaged-repo"
	mkdir -p "$unmanaged_root"
	_test_hook_create_repo "$unmanaged_root" false

	HOOK_TEST_PASS=0
	HOOK_TEST_FAIL=0
	_test_hook_run_blocked_cases "$test_root" "$test_script"
	_test_hook_run_allowed_cases "$test_root" "$test_script"
	_test_hook_run_linked_worktree_cases "$linked_worktree" "$test_script"
	_test_hook_run_unmanaged_cases "$unmanaged_root" "$test_script"

	"$real_git" -C "$test_root" worktree remove "$linked_worktree" >/dev/null 2>&1 || rm -rf "$linked_worktree"
	rm -rf "$test_root"

	if [[ "$HOOK_TEST_FAIL" -eq 0 ]]; then
		print_success "All $HOOK_TEST_PASS tests passed"
		return 0
	else
		print_error "$HOOK_TEST_FAIL tests failed, $HOOK_TEST_PASS passed"
		return 1
	fi
}

show_help() {
	echo "install-hooks-helper.sh - Claude Code destructive command protection"
	echo ""
	echo "Usage: install-hooks-helper.sh [command]"
	echo ""
	echo "Commands:"
	echo "  install               Install safety hooks (default)"
	echo "  install --force-install  Bypass validator preflight check"
	echo "  uninstall             Remove safety hooks"
	echo "  status                Check installation status"
	echo "  test                  Run hook self-test"
	echo "  help                  Show this help"
	echo ""
	echo "Installs to:"
	echo "  ~/.aidevops/hooks/git_safety_guard.py"
	echo "  ~/.claude/settings.json (PreToolUse hook config)"
	echo "  .git/hooks/pre-push (gh-wrapper-guard t2113, quality-validation t2207)"
	echo "  .git/hooks/pre-commit (fast quality-validation, t2191+t2207)"
	return 0
}

# Main
cmd="${1:-install}"
shift || true
case "$cmd" in
install) install_hook "$@" ;;
uninstall) uninstall_hook ;;
status) check_status ;;
test) test_hook ;;
help | --help | -h) show_help ;;
*)
	print_error "Unknown command: $cmd"
	show_help
	exit 1
	;;
esac
