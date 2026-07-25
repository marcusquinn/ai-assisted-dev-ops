#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Runtime Config Generator -- Command Generation Sub-Library
# =============================================================================
# Slash command deployment for all supported runtimes. Handles per-runtime
# format transforms (OpenCode YAML, Claude Code YAML, Cursor frontmatter-strip,
# Kiro steering, Continue .prompt, Gemini CLI TOML, Kimi Skills).
#
# Usage: source "${SCRIPT_DIR}/generate-runtime-config-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - runtime-registry.sh (rt_display_name, rt_command_dir, rt_feature_commands)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_GENERATE_RUNTIME_CONFIG_COMMANDS_LIB_LOADED:-}" ]] && return 0
_GENERATE_RUNTIME_CONFIG_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Phase 2b: Command Generation -- Per-Runtime Adapters
# =============================================================================

# Shared command definitions -- the body content is defined once here.
# Each runtime adapter writes these to its command directory with the
# appropriate frontmatter format.

_GENERATED_HARDCODED_COMMAND_COUNT=0

# Helper: write a command file for OpenCode format
_write_opencode_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	local agent="$4"
	local subtask="$5"
	local body="$6"

	{
		echo "---"
		echo "description: ${description}"
		[[ -n "$agent" ]] && echo "agent: ${agent}"
		[[ "$subtask" == "true" ]] && echo "subtask: true"
		echo "---"
		echo ""
		echo "$body"
	} >"${cmd_dir}/${name}.md"
	return 0
}

# Helper: write a command file for Claude Code format
_write_claude_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	# Claude Code doesn't use agent/subtask fields
	local body="$4"

	cat >"${cmd_dir}/${name}.md" <<EOF
---
description: $description
---

$body
EOF
	return 0
}

# Helper: copy a source command file to a destination, stripping only
# OpenCode-specific frontmatter fields that confuse other runtimes.
# Safe default for clients that accept YAML frontmatter + markdown body
# (codex, droid, qwen, kimi, amp, windsurf).
_copy_cmd_strip_opencode_fields() {
	local src="$1"
	local dest="$2"
	sed -E '/^---$/,/^---$/{/^(agent|subtask|mode):/d;}' "$src" >"$dest"
}

# OpenCode requires model fields to contain concrete provider/model IDs. Source
# commands may instead carry canonical workload tiers for other orchestrators;
# strip only those tier values and inherit the active session model.
_copy_cmd_for_opencode() {
	local src="$1"
	local dest="$2"

	awk '
		NR == 1 && /^---$/ { in_fm = 1; print; next }
		in_fm && /^---$/ { in_fm = 0; print; next }
		in_fm && /^model: (simple|standard|thinking)$/ { next }
		{ print }
	' "$src" >"$dest" || return 1
	return 0
}

# Helper: Cursor command files -- Cursor Commands (1.6+) do not support
# YAML frontmatter at all. Strip the entire leading frontmatter block
# and emit only the markdown body.
_copy_cmd_strip_all_frontmatter() {
	local src="$1"
	local dest="$2"
	awk '
		BEGIN { in_fm = 0; past_fm = 0 }
		NR == 1 && /^---$/ { in_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
		in_fm { next }
		{ print }
	' "$src" >"$dest"
}

# Helper: Kiro steering files -- copy as-is but ensure the frontmatter
# contains `inclusion: manual` so the file appears as a user-invocable
# slash command rather than an always-on steering document.
_copy_cmd_kiro_steering() {
	local src="$1"
	local dest="$2"
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"
	if grep -q '^inclusion:' "$tmp"; then
		cp "$tmp" "$dest"
	else
		awk '
			NR == 1 && /^---$/ { print; print "inclusion: manual"; next }
			{ print }
		' "$tmp" >"$dest"
	fi
	rm -f "$tmp"
}

# Helper: Continue .prompt files -- Continue wants `.prompt` extension
# plus `invokable: true` in the frontmatter for the prompt to appear
# as a slash command in Chat/Plan/Agent modes.
_copy_cmd_continue_prompt() {
	local src="$1"
	local dest="$2" # caller already switched extension to .prompt
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"
	if grep -q '^invokable:' "$tmp"; then
		cp "$tmp" "$dest"
	else
		awk '
			NR == 1 && /^---$/ { print; print "invokable: true"; next }
			{ print }
		' "$tmp" >"$dest"
	fi
	rm -f "$tmp"
}

# Helper: Gemini CLI TOML files -- convert markdown with YAML frontmatter
# into Gemini's documented TOML format (geminicli.com/docs/cli/custom-commands).
# Output schema:
#   description = "<extracted from frontmatter>"
#   prompt = """
#   <body after frontmatter>
#   """
# Uses basic multi-line strings (`"""`) by default; falls back to literal
# multi-line strings (`'''`) if the body contains the triple-quote sequence.
_copy_cmd_gemini_toml() {
	local src="$1"
	local dest="$2" # caller already switched extension to .toml
	local description body delim
	local warning_line=""

	# Extract `description:` value from the YAML frontmatter block (first
	# fenced `---` region). Stop at the closing marker.
	description=$(awk '
		/^---$/ {
			if (in_fm) exit
			in_fm = 1
			next
		}
		in_fm && /^description:[[:space:]]*/ {
			sub(/^description:[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$src")

	# Extract the body (everything after the closing frontmatter marker).
	# If the file has no frontmatter, the whole file is the body.
	body=$(awk '
		BEGIN { in_fm = 0; past_fm = 0; has_fm = 0 }
		NR == 1 && /^---$/ { in_fm = 1; has_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
		in_fm { next }
		{ print }
	' "$src")

	# Pick a multi-line string delimiter the body will not collide with.
	delim='"""'
	if printf '%s' "$body" | grep -qF '"""'; then
		delim="'''"
		if printf '%s' "$body" | grep -qF "'''"; then
			warning_line="# WARNING: body contains both \"\"\" and ''' -- prompt string may need manual fix-up"
		fi
	fi

	# Escape double quotes in the description (TOML basic string rules).
	local escaped_desc
	escaped_desc=$(printf '%s' "$description" | sed 's/\\/\\\\/g; s/"/\\"/g')

	{
		[[ -n "$warning_line" ]] && echo "$warning_line"
		if [[ -n "$description" ]]; then
			printf 'description = "%s"\n' "$escaped_desc"
		fi
		printf 'prompt = %s\n' "$delim"
		printf '%s\n' "$body"
		printf '%s\n' "$delim"
	} >"$dest"
	return 0
}

# Helper: Kimi CLI Skills -- Kimi expects a directory-per-skill layout:
#   ~/.kimi/skills/<name>/SKILL.md
# where the parent directory name MUST match the `name:` frontmatter field.
# This helper creates the subdirectory, writes SKILL.md inside it, and
# injects/corrects the required `name:` and `description:` fields.
#
# Arguments:
#   $1 - source file
#   $2 - skills root dir (e.g. ~/.kimi/skills)
#   $3 - skill name (what the directory is called)
_copy_cmd_kimi_skill() {
	local src="$1"
	local skills_root="$2"
	local name="$3"
	local skill_dir="${skills_root}/${name}"
	local dest="${skill_dir}/SKILL.md"

	mkdir -p "$skill_dir"

	# Strip OpenCode-only fields first so other clients' frontmatter doesn't
	# confuse Kimi's skill loader.
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"

	# Ensure `name:` matches the directory name. If present, replace its
	# value; if absent, inject it right after the opening `---` marker.
	local tmp2
	tmp2=$(mktemp)
	if grep -q '^name:' "$tmp"; then
		sed "s|^name:.*|name: ${name}|" "$tmp" >"$tmp2"
	else
		awk -v n="$name" '
			NR == 1 && /^---$/ { print; print "name: " n; next }
			{ print }
		' "$tmp" >"$tmp2"
	fi

	# Ensure `description:` is present. Kimi requires it for auto-invocation;
	# inject a sensible fallback derived from the skill name if the source
	# file doesn't carry one.
	if grep -q '^description:' "$tmp2"; then
		cp "$tmp2" "$dest"
	else
		awk -v n="$name" '
			NR == 1 && /^---$/ { print; print "description: aidevops primary agent routing command: " n; next }
			{ print }
		' "$tmp2" >"$dest"
	fi

	rm -f "$tmp" "$tmp2"
	return 0
}

# Namespace prefix applied to every slash command deployed to clients.
# Differentiates aidevops commands from native client slash commands and
# groups them alphabetically in the client's command picker.
_AIDEVOPS_CMD_PREFIX="aidevops-"

# Deploy one source command file to a runtime's command directory,
# applying the correct per-runtime format transform.
# Arguments:
#   $1 - runtime_id
#   $2 - source file (full path)
#   $3 - deployed name (WITHOUT extension -- format-specific extension added here)
#   $4 - destination command dir
# Returns: 0 on success, 1 on failure.
_deploy_one_command() {
	local runtime_id="$1"
	local src="$2"
	local name="$3"
	local cmd_dir="$4"
	local dest

	case "$runtime_id" in
	opencode)
		# Canonical workload tiers are routing intent, not OpenCode model IDs.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_for_opencode "$src" "$dest" || return 1
		;;
	claude-code | codex | droid | amp | qwen)
		# Markdown + YAML frontmatter clients: strip opencode-only fields
		# (agent, subtask, mode) that other clients don't recognise.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_strip_opencode_fields "$src" "$dest" || return 1
		;;
	cursor)
		# Cursor Commands (1.6+) do not support YAML frontmatter. Strip it.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_strip_all_frontmatter "$src" "$dest" || return 1
		;;
	kiro)
		# Kiro steering files: add `inclusion: manual` so they appear as
		# user-invocable slash commands rather than always-on steering docs.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_kiro_steering "$src" "$dest" || return 1
		;;
	continue)
		# Continue: rename extension to .prompt and add `invokable: true`
		# so the file appears as a slash command in Chat/Plan/Agent modes.
		dest="${cmd_dir}/${name}.prompt"
		_copy_cmd_continue_prompt "$src" "$dest" || return 1
		;;
	gemini-cli)
		# Convert markdown + YAML frontmatter to Gemini CLI's documented TOML
		# format: `description = "..."` + `prompt = """..."""`. The helper
		# handles triple-quote collisions by falling back to literal strings.
		dest="${cmd_dir}/${name}.toml"
		_copy_cmd_gemini_toml "$src" "$dest" || return 1
		;;
	kimi)
		# Kimi Skills: directory-per-skill layout. The skill name (= directory
		# name) must match the `name:` frontmatter field. `cmd_dir` here is
		# the parent ~/.kimi/skills dir; the helper creates the subdirectory
		# and writes SKILL.md inside it.
		_copy_cmd_kimi_skill "$src" "$cmd_dir" "$name" || return 1
		;;
	kilo | windsurf | aider)
		# Kilo uses custom modes (different mechanism); Windsurf uses a
		# repo-local dir created by `aidevops init`; Aider has no native
		# slash commands. These are handled elsewhere -- skip here.
		return 0
		;;
	*)
		# Unknown runtime: conservative fall-through -- copy as-is.
		dest="${cmd_dir}/${name}.md"
		cp "$src" "$dest" || return 1
		;;
	esac
	return 0
}

# Generate all shared commands for a given runtime.
# Reads from two source directories:
#   1. ~/.aidevops/agents/commands/        -- main-agent symlinks (already
#                                            prefixed with `aidevops-`)
#   2. ~/.aidevops/agents/scripts/commands/ -- skills/workflows/utilities
#                                            (prefix is applied at deploy time)
# Gated on the per-runtime `commands` feature flag.
#
# Arguments: $1=runtime_id
_generate_commands_for_runtime() {
	local runtime_id="$1"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	# Feature flag gate -- user can disable commands installation per runtime
	# via AIDEVOPS_FEATURE_COMMANDS_<SUFFIX>=no.
	local feature_enabled
	feature_enabled=$(rt_feature_commands "$runtime_id" 2>/dev/null || echo "yes")
	if [[ "$feature_enabled" != "yes" ]]; then
		print_info "Commands installation disabled for $display_name (feature flag)"
		return 0
	fi

	local cmd_dir
	cmd_dir=$(rt_command_dir "$runtime_id") || cmd_dir=""

	if [[ -z "$cmd_dir" ]]; then
		print_info "No command directory for $display_name -- skipping commands"
		return 0
	fi

	mkdir -p "$cmd_dir"

	local command_count=0
	local skipped_count=0

	print_info "Generating $display_name commands..."

	# --- Source 1: .agents/commands/ (main-agent symlinks -- already prefixed) ---
	local main_src_dir="$HOME/.aidevops/agents/commands"
	if [[ -d "$main_src_dir" ]]; then
		local cmd_file cmd_name
		for cmd_file in "$main_src_dir"/*.md; do
			[[ -e "$cmd_file" ]] || continue
			cmd_name=$(basename "$cmd_file" .md)

			# Deploy with name as-is (already carries `aidevops-` prefix).
			if ! _deploy_one_command "$runtime_id" "$cmd_file" "$cmd_name" "$cmd_dir"; then
				if [[ ! -e "$cmd_file" ]]; then
					print_warning "Skipping main-agent command $cmd_name: source disappeared"
					skipped_count=$((skipped_count + 1))
					continue
				fi
				print_warning "Failed to deploy main-agent command $cmd_name for $display_name"
				return 1
			fi
			command_count=$((command_count + 1))
		done
	fi

	# --- Source 2: .agents/scripts/commands/ (skills + workflows) ---
	# These files are NOT prefixed at the source -- prepend `aidevops-` at deploy.
	local skills_src_dir="$HOME/.aidevops/agents/scripts/commands"
	if [[ -d "$skills_src_dir" ]]; then
		local cmd_file cmd_name deployed_name
		for cmd_file in "$skills_src_dir"/*.md; do
			[[ -f "$cmd_file" ]] || continue
			cmd_name=$(basename "$cmd_file" .md)

			# Skip non-commands
			[[ "$cmd_name" == "SKILL" ]] && continue

			# Apply namespace prefix.
			deployed_name="${_AIDEVOPS_CMD_PREFIX}${cmd_name}"

			if ! _deploy_one_command "$runtime_id" "$cmd_file" "$deployed_name" "$cmd_dir"; then
				if [[ ! -f "$cmd_file" ]]; then
					print_warning "Skipping command $cmd_name: source disappeared"
					skipped_count=$((skipped_count + 1))
					continue
				fi
				print_warning "Failed to deploy command $cmd_name for $display_name"
				return 1
			fi
			command_count=$((command_count + 1))
		done
	fi

	# Generate hardcoded commands that aren't in scripts/commands/
	# These are runtime-specific commands that have inline body content
	_generate_hardcoded_commands "$runtime_id" "$cmd_dir" || return 1
	command_count=$((command_count + _GENERATED_HARDCODED_COMMAND_COUNT))

	if [[ "$skipped_count" -gt 0 ]]; then
		print_warning "$display_name: skipped $skipped_count command file(s) that disappeared during generation"
	fi
	print_success "$display_name: $command_count commands in $cmd_dir"
	return 0
}

# Write a canonical hardcoded command using the appropriate runtime format.
# These names are owned by the generator, so replace stale legacy output on
# every uncached generation rather than preserving obsolete routing metadata.
# Arguments:
#   $1 - runtime_id
#   $2 - cmd_dir
#   $3 - command name
#   $4 - description
#   $5 - body content
#   $6 - OpenCode subtask flag (optional, defaults to true)
# Returns: 0 when written
_maybe_write_hardcoded_command() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local name="$3"
	local description="$4"
	local body="$5"
	local subtask="${6:-true}"

	case "$runtime_id" in
	opencode)
		_write_opencode_command "$cmd_dir" "$name" "$description" "Build+" "$subtask" "$body"
		;;
	*)
		_write_claude_command "$cmd_dir" "$name" "$description" "$body"
		;;
	esac
	return 0
}

# Generate quality/review hardcoded commands.
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Sets _GENERATED_HARDCODED_COMMAND_COUNT and returns 0 on success.
_generate_hardcoded_quality_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Agent Review ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "agent-review" \
		"Systematic review and improvement of agent instructions" \
		'Read ~/.aidevops/agents/tools/build-agent/agent-review.md and follow it as the canonical review rubric.

Review target: $ARGUMENTS

If no target is provided, review the instruction surfaces used in this session.'; then
		count=$((count + 1))
	fi

	# --- Issue / PR Review ---
	# Opening-message reviews must remain in the primary conversation so the
	# evidence trail and maintainer decisions stay visible in the parent session.
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "review-issue-pr" \
		"Review external issue or PR - validate problem and evaluate solution" \
		'Read ~/.aidevops/agents/workflows/review-issue-pr.md and follow its instructions.

Review this issue or PR: $ARGUMENTS

**Usage:**
- `/review-issue-pr 123` - Review issue or PR by number
- `/review-issue-pr https://github.com/owner/repo/issues/123` - Review by URL
- `/review-issue-pr https://github.com/owner/repo/pull/456` - Review PR by URL

**Core questions to answer:**
1. Is the issue real? (reproducible, not duplicate, actually a bug)
2. Is this the best solution? (simplest approach, fixes root cause)
3. Is the scope appropriate? (minimal changes, no scope creep)' \
		"false"; then
		count=$((count + 1))
	fi

	# --- Preflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "preflight" \
		"Run quality checks before version bump and release" \
		'Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)'; then
		count=$((count + 1))
	fi

	# --- Postflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "postflight" \
		"Check code audit feedback on latest push (branch or PR)" \
		'Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If in a linked worktree with open PR -> check that PR'\''s feedback
2. If in a linked worktree without PR -> check ref CI status
3. If on main -> check latest commit'\''s CI/audit status

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status

Report findings and recommend next actions (fix issues, merge, etc.)'; then
		count=$((count + 1))
	fi

	_GENERATED_HARDCODED_COMMAND_COUNT="$count"
	return 0
}

# Generate lifecycle hardcoded commands (release, onboarding, setup-aidevops).
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Sets _GENERATED_HARDCODED_COMMAND_COUNT and returns 0 on success.
_generate_hardcoded_lifecycle_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Release ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "release" \
		"Full release workflow with version bump, tag, and GitHub release" \
		'Execute a release for the current repository.

Release type: $ARGUMENTS (valid: major, minor, patch)

**Steps:**
1. Run `git log v$(cat VERSION 2>/dev/null || echo "0.0.0")..HEAD --oneline` to see commits since last release
2. If no release type provided, determine it from commits
3. Run the single release command:
   ```bash
   .agents/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL'; then
		count=$((count + 1))
	fi

	# --- Onboarding ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "onboarding" \
		"Interactive onboarding wizard - discover services, configure integrations" \
		'Read ${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/onboarding.md and follow its Welcome Flow instructions to guide the user through setup. Do NOT repeat these instructions — go straight to the Welcome Flow conversation.

Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	# --- Setup ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "setup-aidevops" \
		"Deploy latest aidevops agent changes locally" \
		'Run the aidevops setup script to deploy the latest changes.

```bash
AIDEVOPS_REPO="${AIDEVOPS_REPO:-$(jq -r ".initialized_repos[]?.path | select(test(\"/aidevops$\"))" ~/.config/aidevops/repos.json 2>/dev/null | head -n 1)}"
if [[ -z "$AIDEVOPS_REPO" ]]; then
  AIDEVOPS_REPO="$HOME/Git/aidevops"
fi
[[ -f "$AIDEVOPS_REPO/setup.sh" ]] || {
  echo "Unable to find setup.sh. Set AIDEVOPS_REPO to your aidevops clone path." >&2
  exit 1
}
cd "$AIDEVOPS_REPO" && ./setup.sh || exit
```

This deploys agents, updates commands, regenerates configs.
Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	_GENERATED_HARDCODED_COMMAND_COUNT="$count"
	return 0
}

# Generate hardcoded commands not in scripts/commands/
# Sets _GENERATED_HARDCODED_COMMAND_COUNT and returns 0 on success.
_generate_hardcoded_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	_generate_hardcoded_quality_commands "$runtime_id" "$cmd_dir" || return 1
	count=$((count + _GENERATED_HARDCODED_COMMAND_COUNT))

	_generate_hardcoded_lifecycle_commands "$runtime_id" "$cmd_dir" || return 1
	count=$((count + _GENERATED_HARDCODED_COMMAND_COUNT))

	_GENERATED_HARDCODED_COMMAND_COUNT="$count"
	return 0
}
