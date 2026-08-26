#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Init and Scaffold Library
# =============================================================================
# Project initialisation and scaffolding functions extracted from aidevops.sh
# to keep the orchestrator under the 2000-line file-size threshold.
#
# Covers:
#   1. Scaffold helpers: _scaffold_contributing, _scaffold_security, _scaffold_coc,
#      scaffold_repo_courtesy_files, _generate_security_section, scaffold_agents_md,
#      _update_agents_md_security
#   2. Init helpers: _init_parse_features, _seed_mission_control_template,
#      _init_scaffold_commands_symlinks, _init_scaffold_scope_gated_files
#   3. cmd_init: main init command dispatcher
#
# Usage: source "${SCRIPT_DIR}/aidevops-init-lib.sh"
#
# Dependencies:
#   - INSTALL_DIR, AGENTS_DIR, CONFIG_DIR (set by aidevops.sh)
#   - print_* helpers and utility functions (defined in aidevops.sh before sourcing)
#   - register_repo(), get_repo_slug() from aidevops-repos-lib.sh (sourced first)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_INIT_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_INIT_LIB_LOADED=1

_init_lib_dir="${BASH_SOURCE[0]%/*}"
[[ "$_init_lib_dir" == "${BASH_SOURCE[0]}" ]] && _init_lib_dir="."
# shellcheck source=aidevops-project-config-lib.sh
source "${_init_lib_dir}/aidevops-project-config-lib.sh"
# shellcheck source=aidevops-project-context-lib.sh
source "${_init_lib_dir}/aidevops-project-context-lib.sh"
unset _init_lib_dir

_AGENT_SOURCE_TEMPLATE_VERSION="1"

_init_load_repo_verify_lib() {
	if declare -F repo_verify_detect >/dev/null 2>&1; then
		return 0
	fi
	local candidate="${INSTALL_DIR}/.agents/scripts/repo-verify-config-lib.sh"
	[[ -f "$candidate" ]] || candidate="${AGENTS_DIR}/scripts/repo-verify-config-lib.sh"
	[[ -f "$candidate" ]] || return 1
	# shellcheck source=/dev/null
	source "$candidate"
	return 0
}

_init_write_project_config() {
	local config_file="$1"
	local version="$2"
	local init_scope="$3"
	local has_interface="$4"
	local is_agent_source="$5"
	local enable_planning="$6"
	local enable_git_workflow="$7"
	local enable_code_quality="$8"
	local enable_time_tracking="$9"
	shift 9
	local enable_database="$1"
	local enable_beads="$2"
	local enable_sops="$3"
	local enable_security="$4"
	local enable_deployment_context="$5"
	local enable_wordpress_context="$6"
	local desired_file merged_file
	_init_load_repo_verify_lib || return 1
	_repo_verify_lock_acquire "$config_file" || return 1
	if [[ -f "$config_file" ]] && ! jq -e 'type == "object"' "$config_file" >/dev/null 2>&1; then
		_repo_verify_lock_release
		return 1
	fi
	desired_file=$(mktemp "${config_file}.desired.XXXXXX") || {
		_repo_verify_lock_release
		return 1
	}
	merged_file=$(mktemp "${config_file}.merged.XXXXXX") || {
		rm -f "$desired_file"
		_repo_verify_lock_release
		return 1
	}
	if ! jq -n \
		--arg version "$version" --arg initialized "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg init_scope "$init_scope" --argjson has_interface "$has_interface" \
		--argjson agent_source "$is_agent_source" --argjson planning "$enable_planning" \
		--argjson git_workflow "$enable_git_workflow" --argjson code_quality "$enable_code_quality" \
		--argjson time_tracking "$enable_time_tracking" --argjson database "$enable_database" \
		--argjson beads "$enable_beads" --argjson sops "$enable_sops" --argjson security "$enable_security" \
		--argjson deployment_context "$enable_deployment_context" --argjson wordpress_context "$enable_wordpress_context" \
		'{version:$version,initialized:$initialized,init_scope:$init_scope,has_interface:$has_interface,agent_source:$agent_source,
		features:{planning:$planning,git_workflow:$git_workflow,code_quality:$code_quality,time_tracking:$time_tracking,database:$database,beads:$beads,sops:$sops,security:$security,deployment_context:$deployment_context,wordpress_context:$wordpress_context},
		time_tracking:{enabled:$time_tracking,prompt_on_commit:true,auto_record_branch_start:true},
		database:{enabled:$database,schema_path:"schemas",migrations_path:"migrations",seeds_path:"seeds",auto_generate_migration:true},
		beads:{enabled:$beads,sync_on_commit:false,auto_ready_check:true},
		sops:{enabled:$sops,backend:"age",patterns:["*.secret.yaml","*.secret.json","configs/*.enc.json","configs/*.enc.yaml"]},plugins:[]}' >"$desired_file"; then
		rm -f "$desired_file" "$merged_file"
		_repo_verify_lock_release
		return 1
	fi
	if [[ -f "$config_file" ]] && jq -e 'type == "object"' "$config_file" >/dev/null 2>&1; then
		jq -s --arg version "$version" '.[0] * .[1] | .version = $version' "$desired_file" "$config_file" >"$merged_file" || {
			rm -f "$desired_file" "$merged_file"
			_repo_verify_lock_release
			return 1
		}
	else
		cp "$desired_file" "$merged_file"
	fi
	_repo_verify_preserve_mode "$config_file" "$merged_file"
	mv "$merged_file" "$config_file"
	rm -f "$desired_file"
	_repo_verify_lock_release
	return 0
}

_init_configure_repo_verify() {
	local project_root="$1"
	local config_file="${project_root}/.aidevops.json"
	[[ -f "$config_file" ]] || return 0
	[[ "$(jq -r '.features.code_quality == true' "$config_file" 2>/dev/null)" == "true" ]] || return 0
	if ! _init_load_repo_verify_lib; then
		print_warning "Repo verify configuration helper unavailable"
		return 0
	fi
	local apply_status=0
	repo_verify_apply_config "$project_root" false >/dev/null 2>&1 || apply_status=$?
	case "$apply_status" in
	0) print_success "Seeded exact repository verify commands" ;;
	2) print_info "No exact native verify commands detected; leaving verify policy unset" ;;
	3) print_warning "Tracked verify config requires a linked-worktree change" ;;
	4)
		print_info "Explicit verify opt-out preserved"
		return 0
		;;
	*) print_warning "Repository verify configuration could not be updated" ;;
	esac
	if repo_verify_install_hook "$project_root" >/dev/null 2>&1; then
		print_success "Installed/refreshed repo-verify pre-push hook"
	else
		print_warning "Repo-verify hook not installed (inspect unmanaged pre-push hook conflict)"
	fi
	return 0
}

_init_finalize_repo_verify() {
	local project_root="$1"
	local config_file="${project_root}/.aidevops.json"
	[[ -f "$config_file" ]] || return 0
	[[ "$(jq -r '.features.code_quality == true and .verify.enabled != false' "$config_file" 2>/dev/null)" == "true" ]] || return 0
	if ! _init_load_repo_verify_lib; then
		print_error "Repo verify configuration helper unavailable during final hook verification"
		return 1
	fi

	local hook_status=""
	hook_status=$(repo_verify_hook_status "$project_root") || hook_status="unavailable"
	if [[ "$hook_status" != "installed" ]] || ! _init_repo_verify_hook_integrity "$project_root"; then
		repo_verify_install_hook "$project_root" >/dev/null 2>&1 || {
			print_error "Required repo-verify pre-push hook was replaced during initialization"
			return 1
		}
		hook_status=$(repo_verify_hook_status "$project_root") || hook_status="unavailable"
	fi
	if [[ "$hook_status" != "installed" ]] || ! _init_repo_verify_hook_integrity "$project_root"; then
		print_error "Required repo-verify pre-push hook failed its final integrity check (status: ${hook_status})"
		return 1
	fi
	print_success "Verified final repo-verify pre-push hook integrity"
	return 0
}

_init_repo_verify_hook_integrity() {
	local project_root="$1"
	local common_dir="" hook_file=""
	common_dir=$(git -C "$project_root" rev-parse --git-common-dir 2>/dev/null) || return 1
	[[ "$common_dir" == /* ]] || common_dir="${project_root}/${common_dir}"
	hook_file="${common_dir}/hooks/pre-push"
	[[ -x "$hook_file" ]] || return 1
	bash -n "$hook_file" >/dev/null 2>&1 || return 1
	# shellcheck disable=SC2016 # Match literal dispatcher expressions.
	grep -Fq '_stdin_data=$(cat)' "$hook_file" || return 1
	grep -Fq '_repo_verify_hook=""' "$hook_file" || return 1
	# shellcheck disable=SC2016 # Match literal dispatcher expressions.
	grep -Fq '"$_repo_verify_hook" "$@" || _exit_code=$?' "$hook_file" || return 1
	# shellcheck disable=SC2016 # Match literal dispatcher expressions.
	grep -Fq 'exit "$_exit_code"' "$hook_file" || return 1
	return 0
}

_init_run_beads_init() {
	local project_root="$1"
	if bd init --help 2>&1 | grep -q -- '--skip-hooks'; then
		(cd "$project_root" && bd init --skip-hooks 2>/dev/null)
		return $?
	fi

	local common_dir="" hook_file="" hook_backup="" beads_status=0
	common_dir=$(git -C "$project_root" rev-parse --git-common-dir 2>/dev/null) || return 1
	[[ "$common_dir" == /* ]] || common_dir="${project_root}/${common_dir}"
	hook_file="${common_dir}/hooks/pre-push"
	if [[ -f "$hook_file" ]]; then
		hook_backup=$(mktemp "${hook_file}.aidevops-init.XXXXXX") || return 1
		cp -p "$hook_file" "$hook_backup" || return 1
	fi
	(cd "$project_root" && bd init 2>/dev/null) || beads_status=$?
	if [[ -n "$hook_backup" ]]; then
		mv "$hook_backup" "$hook_file" || return 1
	fi
	return "$beads_status"
}

_agent_source_template_dir() {
	printf '%s\n' "${AGENTS_DIR}/templates/agent-source-repo"
	return 0
}

_agent_source_apply_managed_template_file() {
	local project_root="$1"
	local relative_path="$2"
	local template_dir dest src dest_dir
	template_dir=$(_agent_source_template_dir)
	src="$template_dir/$relative_path"
	dest="$project_root/$relative_path"
	dest_dir="${dest%/*}"

	[[ -f "$src" ]] || return 1
	[[ "$dest_dir" != "$dest" ]] && mkdir -p "$dest_dir"

	if [[ ! -f "$dest" ]]; then
		cp "$src" "$dest"
		return 0
	fi

	if ! grep -q '<!-- aidevops:agent-source-template:start -->' "$dest" 2>/dev/null; then
		return 0
	fi
	if ! grep -q '<!-- aidevops:agent-source-template:end -->' "$dest" 2>/dev/null; then
		return 0
	fi

	python3 - "$dest" "$src" <<'PY'
from pathlib import Path
import sys

dest = Path(sys.argv[1])
src = Path(sys.argv[2])
start = "<!-- aidevops:agent-source-template:start -->"
end = "<!-- aidevops:agent-source-template:end -->"
old = dest.read_text()
new = src.read_text()
if start not in old or end not in old or start not in new or end not in new:
    sys.exit(0)
old_prefix = old.split(start, 1)[0]
old_suffix = old.split(end, 1)[1]
new_block = start + new.split(start, 1)[1].split(end, 1)[0] + end
dest.write_text(old_prefix + new_block + old_suffix)
PY
	return 0
}

seed_agent_source_repo_templates() {
	local project_root="$1"
	local template_dir
	template_dir=$(_agent_source_template_dir)

	if [[ ! -d "$template_dir" ]]; then
		print_warning "Agent source template directory missing: $template_dir"
		return 1
	fi

	local rel_dir
	for rel_dir in \
		".agents" \
		".agents/tools" \
		".agents/services" \
		".agents/workflows" \
		".agents/reference" \
		".agents/scripts" \
		".agents/scripts/commands" \
		".agents/configs" \
		".agents/bundles" \
		".agents/templates" \
		".agents/rules" \
		".agents/tests" \
		".agents/custom" \
		".agents/draft"; do
		mkdir -p "$project_root/$rel_dir"
	done

	_agent_source_apply_managed_template_file "$project_root" "AGENTS.md" || return 1
	_agent_source_apply_managed_template_file "$project_root" ".agents/AGENTS.md" || return 1
	print_success "Seeded agent-source repository templates (v${_AGENT_SOURCE_TEMPLATE_VERSION})"
	return 0
}

# Scaffold standard repo courtesy files if they don't exist
# Scaffold helpers (extracted for complexity reduction)
_scaffold_contributing() {
	local project_root="$1" repo_name="$2"
	[[ -f "$project_root/CONTRIBUTING.md" ]] && return 1
	local c="# Contributing to $repo_name"
	c="$c"$'\n\n'"Thanks for your interest in contributing!"
	c="$c"$'\n\n'"## Quick Start"$'\n\n'"1. Fork the repository"
	c="$c"$'\n'"2. Create a safe linked worktree for your change: \`git worktree add ../${repo_name}-feature-your-feature -b feature/your-feature main\`"
	c="$c"$'\n'"3. Create or find the GitHub issue for your change before coding"
	c="$c"$'\n'"4. Make your changes"
	c="$c"$'\n'"5. Commit with conventional commits: \`git commit -m \"feat: add new feature\"\`"
	c="$c"$'\n'"6. Push and open a PR with the issue reference in the PR body"
	c="$c"$'\n\n'"<!-- aidevops:issue-first-pr:start -->"
	c="$c"$'\n'"<!-- aidevops:issue-first-pr:scope=external -->"
	c="$c"$'\n'"## Issue-first pull requests"
	c="$c"$'\n\n'"If you are not a repository owner, member, or collaborator, create or find a GitHub issue before opening a pull request. Maintainers monitor issues more frequently than unsolicited pull requests."
	c="$c"$'\n\n'"Include \`Closes #NNN\`, \`Fixes #NNN\`, \`Resolves #NNN\`, \`For #NNN\`, or \`Ref #NNN\` in the PR body. External human-authored PRs without an issue reference are blocked. Bot PRs and trusted maintainer task workflows are exempt."
	c="$c"$'\n'"<!-- aidevops:issue-first-pr:end -->"
	c="$c"$'\n\n'"## Commit Messages"$'\n\n'"We use [Conventional Commits](https://www.conventionalcommits.org/):"
	c="$c"$'\n\n'"- \`feat:\` - New feature"$'\n'"- \`fix:\` - Bug fix"$'\n'"- \`docs:\` - Documentation only"
	c="$c"$'\n'"- \`refactor:\` - Code change that neither fixes a bug nor adds a feature"$'\n'"- \`chore:\` - Maintenance tasks"
	printf '%s\n' "$c" >"$project_root/CONTRIBUTING.md"
	return 0
}

_scaffold_security() {
	local project_root="$1"
	[[ -f "$project_root/SECURITY.md" ]] && return 1
	local se="" ge
	ge=$(git -C "$project_root" config user.email 2>/dev/null || echo "")
	[[ -n "$ge" ]] && se="$ge"
	cat >"$project_root/SECURITY.md" <<SECEOF
# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately.
SECEOF
	[[ -n "$se" ]] && cat >>"$project_root/SECURITY.md" <<SECEOF

**Email:** $se

Please do not open public issues for security vulnerabilities.
SECEOF
	return 0
}

_scaffold_coc() {
	local project_root="$1"
	[[ -f "$project_root/CODE_OF_CONDUCT.md" ]] && return 1
	cat >"$project_root/CODE_OF_CONDUCT.md" <<'COCEOF'
# Contributor Covenant Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in our
community a harassment-free experience for everyone.

## Our Standards

Examples of behavior that contributes to a positive environment:

- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community

## Attribution

This Code of Conduct is adapted from the [Contributor Covenant](https://www.contributor-covenant.org),
version 2.1.
COCEOF
	return 0
}

# Scaffold standard repo courtesy files if they don't exist
# Creates: README.md, LICENCE, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md
scaffold_repo_courtesy_files() {
	local project_root="$1"
	local scope="${2:-standard}" # Default to standard for backward compatibility
	local created=0
	local repo_name
	repo_name=$(basename "$project_root")
	local author_name
	author_name=$(git -C "$project_root" config user.name 2>/dev/null || echo "")
	local current_year
	current_year=$(date +%Y)
	print_info "Checking repo courtesy files (scope: $scope)..."

	# README.md: requires "standard" scope
	if _scope_includes "$scope" "standard"; then
		if [[ ! -f "$project_root/README.md" ]]; then
			local rc="# $repo_name"
			if [[ -f "$project_root/.aidevops.json" ]]; then
				local desc
				desc=$(jq -r '.description // empty' "$project_root/.aidevops.json" 2>/dev/null || echo "")
				[[ -n "$desc" ]] && rc="$rc"$'\n\n'"$desc"
			fi
			{ [[ -f "$project_root/LICENCE" ]] || [[ -f "$project_root/LICENSE" ]]; } && rc="$rc"$'\n\n'"## Licence"$'\n\n'"See [LICENCE](LICENCE) for details."
			printf '%s\n' "$rc" >"$project_root/README.md"
			((++created))
		fi
	fi

	# LICENCE: requires "public" scope
	if _scope_includes "$scope" "public"; then
		if [[ ! -f "$project_root/LICENCE" ]] && [[ ! -f "$project_root/LICENSE" ]]; then
			local lh="${author_name:-$(whoami)}"
			cat >"$project_root/LICENCE" <<LICEOF
MIT License

Copyright (c) $current_year $lh

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICEOF
			((++created))
		fi
	fi

	# CHANGELOG.md: requires "public" scope
	if _scope_includes "$scope" "public"; then
		if [[ ! -f "$project_root/CHANGELOG.md" ]]; then
			cat >"$project_root/CHANGELOG.md" <<'CHEOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
CHEOF
			((++created))
		fi
	fi

	# CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md: require "public" scope
	if _scope_includes "$scope" "public"; then
		_scaffold_contributing "$project_root" "$repo_name" && ((++created))
		_scaffold_security "$project_root" && ((++created))
		_scaffold_coc "$project_root" && ((++created))
	fi

	[[ $created -gt 0 ]] && print_success "Created $created repo courtesy file(s) (README, LICENCE, CHANGELOG, etc.)" || print_info "Repo courtesy files already exist"
	return 0
}

# Generate the Security section content based on project type (t1412.11)
# Returns the content via stdout so callers can use it for create or update.
_generate_security_section() {
	local project_root="$1"

	# Detect project type for security recommendations
	local is_js_ts=false
	if [[ -f "$project_root/package.json" ]]; then
		is_js_ts=true
	fi

	cat <<'SECHEADER'
## Security

SECHEADER

	if [[ "$is_js_ts" == "true" ]]; then
		cat <<'SECEOF'
### Prompt Injection Defense

Any feature that processes untrusted content (tool outputs, user input, webhook
payloads) and passes it to an LLM must defend against prompt injection. This is
a JS/TS project — use `@stackone/defender` to sanitize untrusted tool results
before they enter the LLM context:

```bash
npm install @stackone/defender
```

```typescript
import { createPromptDefense } from '@stackone/defender';

const defense = createPromptDefense({ enableTier2: true, blockHighRisk: true });

// Sanitize untrusted tool output before adding to LLM context
const result = await defense.defendToolResult(toolResponse, 'tool_name');
if (!result.allowed) {
  throw new Error('Blocked untrusted content');
}
const safeContent = result.sanitized;
```

For features that don't use LLMs but process untrusted text (webhooks, form
submissions, API endpoints), validate and sanitize inputs at the boundary.

### General Security Rules

- Never log or expose API keys, tokens, or credentials in output
- Store secrets via `aidevops secret set <NAME>` (gopass-encrypted) or
  environment variables — never hardcode them in source
- Use `<PLACEHOLDER>` values in code examples; note the secure storage location
- Validate all external input (user input, webhook payloads, API responses)
- Pin third-party GitHub Actions to SHA hashes, not branch tags
- Run `aidevops security audit` periodically to check security posture
- See `~/.aidevops/agents/tools/security/prompt-injection-defender.md` for
  the framework's prompt injection defense patterns
SECEOF
	else
		cat <<'SECEOF'
### Prompt Injection Defense

Any feature that passes untrusted content to an LLM — user input, tool outputs,
retrieved documents, emails, tickets, or webhook payloads — must defend against
prompt injection. Sanitize and validate that content before including it in
prompts:

- Strip or escape control characters and instruction-like patterns
- Use structured prompt templates with clear system/user boundaries
- Never concatenate raw external content directly into system prompts
- Validate all externally sourced content (tool results, API responses, database
  records) before inclusion in prompts
- Consider allowlist-based input validation where possible

### General Security Rules

- Never log or expose API keys, tokens, or credentials in output
- Store secrets via `aidevops secret set <NAME>` (gopass-encrypted) or
  environment variables — never hardcode them in source
- Use `<PLACEHOLDER>` values in code examples; note the secure storage location
- Validate all external input (user input, webhook payloads, API responses)
- Pin third-party GitHub Actions to SHA hashes, not branch tags
- Run `aidevops security audit` periodically to check security posture
- See `~/.aidevops/agents/tools/security/prompt-injection-defender.md` for
  the framework's prompt injection defense patterns
SECEOF
	fi

	return 0
}

# Scaffold .agents/AGENTS.md with context-aware Security section (t1412.11)
# Idempotent: creates the file if missing, or updates the Security section
# in an existing file (preserving all other custom content).
scaffold_agents_md() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"

	mkdir -p "$(dirname "$agents_md")"

	if [[ -f "$agents_md" ]]; then
		# File exists — update managed sections idempotently
		_update_agents_md_security "$project_root" || return 1
		_update_agents_md_worktrees "$project_root"
		return $?
	fi

	# File missing — create from scratch with base template + security
	local security_content
	security_content=$(_generate_security_section "$project_root")

	cat >"$agents_md" <<'AGENTSEOF'
# Agent Instructions

This directory contains project-specific agent context. The [aidevops](https://aidevops.sh)
framework is loaded separately via the global config (`~/.aidevops/agents/`).

## Purpose

Files in `.agents/` provide project-specific instructions that AI assistants
read when working in this repository. Use this for:

- Domain-specific conventions not covered by the framework
- Project architecture decisions and patterns
- API design rules, data models, naming conventions
- Integration details (third-party services, deployment targets)

## Adding Agents

Create `.md` files in this directory for domain-specific context:

```text
.agents/
  AGENTS.md              # This file - overview and index
  api-patterns.md        # API design conventions
  deployment.md          # Deployment procedures
  data-model.md          # Database schema and relationships
```

Each file is read on demand by AI assistants when relevant to the task.

## Git Worktrees

Keep the canonical repo on `main`/`master`. Create temporary linked worktrees
with `worktree-helper.sh`; aidevops stores them by default under
`${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}` as flat `<repo>-<slug>`
directories so that backup tools can exclude that directory.

AGENTSEOF

	# Append the generated security section
	printf '%s\n' "$security_content" >>"$agents_md"

	return 0
}

_generate_worktree_section() {
	cat <<'EOF'
## Git Worktrees

Keep the canonical repo on `main`/`master`. Create temporary linked worktrees
with `worktree-helper.sh`; aidevops stores them by default under
`${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}` as flat `<repo>-<slug>`
directories so that backup tools can exclude that directory.
EOF
	return 0
}

_update_agents_md_worktrees() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"
	local tmp_file="${agents_md}.tmp.$$"
	local worktree_content
	worktree_content=$(_generate_worktree_section)
	local in_section=false
	local has_section=false

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ ^'## Git Worktrees'[[:space:]]*$ ]]; then
			in_section=true
			has_section=true
			printf '%s\n' "$worktree_content" >>"$tmp_file"
			continue
		fi
		if [[ "$in_section" == "true" ]]; then
			if [[ "$line" == "## "* || "$line" == "<!-- aidevops:"*":start -->" ]]; then
				in_section=false
				printf '\n%s\n' "$line" >>"$tmp_file"
			fi
			continue
		fi
		printf '%s\n' "$line" >>"$tmp_file"
	done <"$agents_md"

	if [[ "$has_section" == "false" ]]; then
		printf '\n%s\n' "$worktree_content" >>"$tmp_file"
	fi
	mv "$tmp_file" "$agents_md"
	return 0
}

# Update the Security section in an existing .agents/AGENTS.md (t1412.11)
# Replaces everything from "## Security" to the next "## " heading (or EOF)
# with the latest security guidance. Preserves all other content.
_update_agents_md_security() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"
	local tmp_file="${agents_md}.tmp.$$"

	local security_content
	security_content=$(_generate_security_section "$project_root")

	local in_security=false
	local has_security_section=false

	# Process line by line: skip old Security section, insert new one
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Match "## Security" exactly, with optional trailing whitespace
		if [[ "$line" =~ ^'## Security'[[:space:]]*$ ]]; then
			# Found the Security heading — replace it
			in_security=true
			has_security_section=true
			printf '%s\n' "$security_content" >>"$tmp_file"
			continue
		fi

		if [[ "$in_security" == "true" ]]; then
			# Check if we've hit the next ## heading (end of Security section)
			if [[ "$line" == "## "* || "$line" == "<!-- aidevops:"*":start -->" ]]; then
				in_security=false
				printf '\n%s\n' "$line" >>"$tmp_file"
			fi
			# Skip lines within the old Security section
			continue
		fi

		printf '%s\n' "$line" >>"$tmp_file"
	done <"$agents_md"

	if [[ "$has_security_section" == "false" ]]; then
		# No existing Security section — append it
		printf '\n%s\n' "$security_content" >>"$tmp_file"
	fi

	mv "$tmp_file" "$agents_md"

	return 0
}

# Init helpers (extracted for complexity reduction)
_init_parse_features() {
	local features="$1"
	case "$features" in
	all) echo "planning git_workflow code_quality time_tracking database beads security" ;;
	planning) echo "planning" ;; git-workflow) echo "git_workflow" ;; code-quality) echo "code_quality" ;;
	time-tracking) echo "time_tracking planning" ;; database) echo "database" ;;
	beads) echo "beads planning" ;; sops) echo "sops" ;; security) echo "security" ;;
	deployment-context | hosting-context) echo "deployment_context" ;;
	wordpress-context) echo "wordpress_context deployment_context" ;;
	*)
		local result=""
		IFS=',' read -ra FL <<<"$features"
		for f in "${FL[@]}"; do
			case "$f" in
			planning) result="$result planning" ;; git-workflow) result="$result git_workflow" ;;
			code-quality) result="$result code_quality" ;; time-tracking) result="$result time_tracking planning" ;;
			database) result="$result database" ;; beads) result="$result beads planning" ;;
			sops) result="$result sops" ;; security) result="$result security" ;;
			deployment-context | hosting-context) result="$result deployment_context" ;;
			wordpress-context) result="$result wordpress_context deployment_context" ;;
			esac
		done
		echo "$result"
		;;
	esac
	return 0
}

# Seed mission-control onboarding template when initializing a mission-control repo.
# Usage: _seed_mission_control_template <project_root> <personal|org>
_seed_mission_control_template() {
	local project_root="$1"
	local scope="$2"
	local seed_file="$project_root/todo/mission-control-seed.md"

	if [[ -z "$scope" ]]; then
		return 0
	fi

	if [[ -f "$seed_file" ]]; then
		return 0
	fi

	mkdir -p "$project_root/todo"

	if [[ "$scope" == "personal" ]]; then
		cat >"$seed_file" <<'EOF'
# Mission Control Seed (Personal)

Starter checklist for a personal mission-control repo initialized with aidevops.

## First-Day Setup

- [ ] Confirm `~/.config/aidevops/repos.json` has all active repos registered with correct `slug` and `path`
- [ ] Set `pulse: true` only for repos you want actively supervised
- [ ] Add `pulse_hours` windows to avoid dispatch during daytime manual development
- [ ] Verify profile and archive repos are `pulse: false` and `priority: "profile"` where applicable

## Operating Rhythm

- [ ] Define weekly review cadence for `aidevops pulse` health and backlog aging
- [ ] Add hygiene tasks for stale branches, stale worktrees, and stale queued issues
- [ ] Track cross-repo blockers in TODO with clear `blocked-by:` links
EOF
	else
		cat >"$seed_file" <<'EOF'
# Mission Control Seed (Organization)

Starter checklist for an organization mission-control repo initialized with aidevops.

## First-Day Setup

- [ ] Register all managed org repos in `~/.config/aidevops/repos.json` with `slug`, `path`, `priority`, and `maintainer`
- [ ] Set `pulse: true` only for repos approved for autonomous dispatch
- [ ] Configure `pulse_hours` and optional `pulse_expires` windows for sprint-based focus
- [ ] Keep sensitive/internal-only repos `pulse: false` until policy checks are complete

## Governance

- [ ] Define maintainer response SLA for `needs-maintainer-review` triage
- [ ] Document worker guardrails (release, merge, and security boundaries)
- [ ] Add a weekly audit task for repo registration drift and label hygiene
EOF
	fi

	print_success "Seeded mission-control template: todo/mission-control-seed.md (${scope})"
	return 0
}

# Scaffold .agents/commands/ and .windsurf/workflows/ symlinks so that clients
# which read repo-local command directories (Amp reads .agents/commands/ natively;
# Windsurf reads .windsurf/workflows/) see the aidevops main-agent slash commands.
#
# Behavior is idempotent:
#   - If .agents/commands/ already contains the expected aidevops-*.md symlinks
#     (this repo IS the aidevops source), do nothing.
#   - Otherwise link .agents/commands/ → ~/.aidevops/agents/commands/
#   - Always link .windsurf/workflows/ → ../.agents/commands/ (relative)
_init_scaffold_commands_symlinks() {
	local project_root="$1"
	local source_dir="$HOME/.aidevops/agents/commands"
	local commands_dir="$project_root/.agents/commands"
	local windsurf_dir="$project_root/.windsurf"
	local workflows_link="$windsurf_dir/workflows"

	# If .agents/commands/ already contains main-agent symlinks, this repo
	# manages them directly (e.g. the aidevops source repo itself) — leave
	# it alone so we never overwrite authoritative content.
	if [[ -e "$commands_dir/aidevops-build-plus.md" ]]; then
		print_info ".agents/commands/ already contains main-agent symlinks — preserving"
	elif [[ ! -d "$source_dir" ]]; then
		print_warning "Framework commands dir not found at $source_dir — run setup.sh first to deploy main-agent symlinks"
	elif [[ -L "$commands_dir" ]]; then
		# Existing symlink — point at the canonical source
		local current_target
		current_target=$(readlink "$commands_dir")
		if [[ "$current_target" != "$source_dir" ]]; then
			rm "$commands_dir"
			ln -s "$source_dir" "$commands_dir"
			print_success "Re-linked .agents/commands/ → $source_dir"
		else
			print_info ".agents/commands/ already linked correctly"
		fi
	elif [[ -d "$commands_dir" ]]; then
		print_warning ".agents/commands/ exists as a real directory — not overwriting"
	else
		ln -s "$source_dir" "$commands_dir"
		print_success "Linked .agents/commands/ → $source_dir (Amp reads this natively)"
	fi

	# .windsurf/workflows/ → ../.agents/commands/ (relative, so the link
	# resolves inside the repo regardless of checkout path).
	mkdir -p "$windsurf_dir"
	if [[ -L "$workflows_link" ]]; then
		print_info ".windsurf/workflows/ already linked"
	elif [[ -d "$workflows_link" ]]; then
		print_warning ".windsurf/workflows/ exists as a real directory — not overwriting"
	else
		(cd "$windsurf_dir" && ln -s "../.agents/commands" workflows)
		print_success "Linked .windsurf/workflows/ → ../.agents/commands (Windsurf slash commands)"
	fi
	return 0
}

# Scaffold optional files gated by init_scope (t2265) and interface detection.
# Extracted from cmd_init to reduce nesting depth and function length.
# Usage: _init_scaffold_scope_gated_files <project_root> <init_scope> <repo_name> [has_interface]
_init_scaffold_scope_gated_files() {
	local project_root="$1"
	local init_scope="$2"
	local repo_name="$3"
	local has_interface="${4:-false}"

	# Collaborator pointer files — require standard scope
	if _scope_includes "$init_scope" "standard"; then
		local pointer_content="Read AGENTS.md for all project context and instructions."
		local pointer_files=(".cursorrules" ".windsurfrules" ".clinerules")
		local pointer_created=0
		local pf
		for pf in "${pointer_files[@]}"; do
			local pf_path="$project_root/$pf"
			if [[ ! -f "$pf_path" ]]; then
				mkdir -p "$(dirname "$pf_path")"
				echo "$pointer_content" >"$pf_path"
				((++pointer_created))
			fi
		done

		local copilot_path="$project_root/.github/copilot-instructions.md"
		if [[ ! -f "$copilot_path" ]]; then
			mkdir -p "$(dirname "$copilot_path")"
			cat >"$copilot_path" <<'EOF'
# GitHub Copilot instructions

Read [AGENTS.md](../AGENTS.md) for all project context and instructions.
EOF
			((++pointer_created))
		fi
		if [[ $pointer_created -gt 0 ]]; then
			print_success "Created $pointer_created collaborator pointer file(s) (.cursorrules, etc.)"
		else
			print_info "Collaborator pointer files already exist"
		fi
	else
		print_info "Collaborator pointer files skipped (init_scope: $init_scope)"
	fi

	# DESIGN.md — standard scope, plus minimal-scope repos when a GUI/interface is detected.
	if _scope_includes "$init_scope" "standard" || [[ "$has_interface" == "true" ]]; then
		_init_scaffold_design_md "$project_root" "$repo_name"
	else
		print_info "DESIGN.md skipped (init_scope: $init_scope, interface: $has_interface)"
	fi

	# Courtesy files (README, LICENCE, CHANGELOG, etc.) — scope handled internally
	scaffold_repo_courtesy_files "$project_root" "$init_scope"

	# MODELS.md — requires standard scope
	if _scope_includes "$init_scope" "standard"; then
		local generate_models_script="$AGENTS_DIR/scripts/generate-models-md.sh"
		if [[ -x "$generate_models_script" ]] && command -v sqlite3 &>/dev/null; then
			print_info "Generating MODELS.md (model performance leaderboard)..."
			if "$generate_models_script" --output "$project_root/MODELS.md" --repo-path "$project_root" --quiet 2>/dev/null; then
				print_success "Created MODELS.md (per-repo model leaderboard)"
			else
				print_warning "MODELS.md generation failed (will be populated as tasks run)"
			fi
		else
			print_info "MODELS.md skipped (sqlite3 or generate script not available)"
		fi
	else
		print_info "MODELS.md skipped (init_scope: $init_scope)"
	fi

	return 0
}

_init_configure_coderabbit_abort_on_close() {
	local project_root="$1"
	local enable_code_quality="$2"
	local config_file="$project_root/.coderabbit.yaml"
	local desired="${AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE:-}"

	[[ "$enable_code_quality" == "true" ]] || return 0

	if [[ -z "$desired" && -t 0 && "${AIDEVOPS_NON_INTERACTIVE:-false}" != "true" ]]; then
		printf '%b' "${BLUE}[INFO]${NC} CodeRabbit option: keep reviews running after merge so aidevops can turn useful findings into follow-up issues? [y/N] "
		local reply=""
		read -r reply || reply=""
		case "$reply" in
		[yY] | [yY][eE][sS]) desired="false" ;;
		*) desired="" ;;
		esac
	fi

	if [[ -z "$desired" ]]; then
		print_info "CodeRabbit post-merge review completion not changed (set AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE=false to enable during init)"
		return 0
	fi

	case "$desired" in
	true | false) ;;
	*)
		print_warning "Ignoring invalid AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE='$desired' (expected true or false)"
		return 0
		;;
	esac

	if ! command -v python3 >/dev/null 2>&1; then
		print_warning "Python 3 unavailable; skipping CodeRabbit .coderabbit.yaml update"
		return 0
	fi

	python3 - "$config_file" "$desired" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
desired = sys.argv[2]

text = path.read_text() if path.exists() else ""

line = f"abort_on_close: {desired}"

if not text.strip():
    text = f"reviews:\n  {line}\n"
elif re.search(r"(?m)^[ \t]*abort_on_close:", text):
    text = re.sub(
        r"(?m)^([ \t]*abort_on_close:)[ \t]*[^\s#]*(?:[ \t]*(#.*))?[ \t]*$",
        lambda match: f"{match.group(1)} {desired}{f' {match.group(2)}' if match.group(2) else ''}",
        text,
        count=1,
    )
elif re.search(r"(?m)^[ \t]*reviews:", text):
    text = re.sub(r"(?m)^([ \t]*)(reviews:.*)$", rf"\g<1>\g<2>\n\g<1>  {line}", text, count=1)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += f"\nreviews:\n  {line}\n"

path.write_text(text)
PY

	print_success "Set CodeRabbit reviews.abort_on_close: $desired in .coderabbit.yaml"
	return 0
}

# Validate the repository context before init performs any project writes.
_init_validate_context() {
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		print_error "Not in a git repository"
		print_info "Run 'git init' first or navigate to a git repository"
		return 1
	fi

	check_protected_branch "chore" "aidevops-init" || return 1
	return 0
}

# Run the init workflow after the public command has validated its context.
# cmd_init locals remain visible here through Bash dynamic scoping.
_init_run_workflow() {
	local features="${1:-all}"

	local project_root
	project_root=$(git rev-parse --show-toplevel)
	print_info "Project root: $project_root"
	echo ""

	# Parse features using helper
	local parsed
	parsed=$(_init_parse_features "$features")
	local enable_planning=false enable_git_workflow=false enable_code_quality=false
	local enable_time_tracking=false enable_database=false enable_beads=false
	local enable_sops=false enable_security=false enable_deployment_context=false
	local enable_wordpress_context=false
	local init_security_posture="not-requested"
	local _f
	for _f in $parsed; do
		case "$_f" in
		planning) enable_planning=true ;; git_workflow) enable_git_workflow=true ;;
		code_quality) enable_code_quality=true ;; time_tracking) enable_time_tracking=true ;;
		database) enable_database=true ;; beads) enable_beads=true ;;
		sops) enable_sops=true ;; security) enable_security=true ;;
		deployment_context) enable_deployment_context=true ;;
		wordpress_context) enable_wordpress_context=true ;;
		esac
	done

	# Determine init_scope: minimal | standard | public
	# Infer from context when not set; user can override via repos.json or .aidevops.json
	local init_scope
	init_scope=$(_infer_init_scope "$project_root")
	print_info "Init scope: $init_scope (controls which scaffolding files are created)"

	local has_interface=false
	_init_repo_has_interface "$project_root" && has_interface=true

	local is_agent_source=false
	if is_agent_source_repo "$project_root"; then
		is_agent_source=true
		print_info "Agent source repo: true (seeding core-style agent organization)"
	fi

	_init_config_and_agents || return 1
	return 0
}

_init_prepare_project_config() {
	local config_file="$1"
	local aidevops_version="$2"
	if _project_config_is_tracked "$project_root"; then
		config_migration_deferred=true
		if ! _project_config_migrate_linked_worktree "$project_root"; then
			_project_config_write_migration_plan "$project_root" || print_warning "Could not write tracked config repair plan"
		fi
		print_info "Preserved tracked .aidevops.json byte-for-byte during migration"
		return 0
	fi
	_init_write_project_config "$config_file" "$aidevops_version" "$init_scope" "$has_interface" "$is_agent_source" \
		"$enable_planning" "$enable_git_workflow" "$enable_code_quality" "$enable_time_tracking" \
		"$enable_database" "$enable_beads" "$enable_sops" "$enable_security" \
		"$enable_deployment_context" "$enable_wordpress_context" || {
		print_error "Failed to write .aidevops.json"
		return 1
	}
	return 0
}

_init_config_and_agents() {

	# Create .aidevops.json config
	local config_file="$project_root/.aidevops.json"
	local aidevops_version
	aidevops_version=$(get_version)

	print_info "Creating or refreshing .aidevops.json..."
	local config_migration_deferred=false
	_init_prepare_project_config "$config_file" "$aidevops_version" || return 1
	# Note: plugins array is always present but empty by default.
	# Users add plugins via: aidevops plugin add <repo-url> [--namespace <name>]
	# Schema per plugin entry:
	# {
	#   "name": "pro",
	#   "repo": "https://github.com/user/aidevops-pro.git",
	#   "branch": "main",
	#   "namespace": "pro",
	#   "enabled": true
	# }
	# Plugins deploy to ~/.aidevops/agents/<namespace>/ (namespaced, no collisions)
	if [[ "$config_migration_deferred" == "true" ]]; then
		print_success "Preserved .aidevops.json pending index migration"
	else
		print_success "Created .aidevops.json"
	fi
	_init_configure_repo_verify "$project_root"

	# Derive repo name for scaffolding
	# In worktrees, basename gives the worktree dir name (e.g., "repo-chore-foo"),
	# not the actual repo name. Prefer: git remote URL > main worktree basename > cwd basename.
	local repo_name
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || true)
	local repo_slug=""
	if [[ "$remote_url" == *github.com[:/]* || "$remote_url" == git@github.com:* ]]; then
		repo_slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	fi
	if [[ -n "$remote_url" ]]; then
		repo_name=$(basename "$remote_url" .git)
	else
		# No remote — try main worktree path (first line of `git worktree list`)
		local main_wt
		main_wt=$(git -C "$project_root" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
		if [[ -n "$main_wt" ]]; then
			repo_name=$(basename "$main_wt")
		else
			repo_name=$(basename "$project_root")
		fi
	fi

	# Create .agents/ directory for project-specific agent context
	# (The aidevops framework is loaded globally via ~/.aidevops/agents/ — this
	# directory is for project-specific agents, conventions, and architecture docs)
	if [[ -L "$project_root/.agents" ]]; then
		# Migrate legacy symlink to real directory
		rm -f "$project_root/.agents"
		print_info "Removed legacy .agents symlink (framework is loaded globally now)"
	fi
	# Also clean up legacy .agent symlink/directory
	if [[ -L "$project_root/.agent" ]]; then
		rm -f "$project_root/.agent"
		print_info "Removed legacy .agent symlink"
	elif [[ -d "$project_root/.agent" && ! -d "$project_root/.agents" ]]; then
		mv "$project_root/.agent" "$project_root/.agents"
		print_success "Migrated .agent/ -> .agents/ directory"
	fi

	if [[ ! -d "$project_root/.agents" ]]; then
		mkdir -p "$project_root/.agents"
		print_success "Created .agents/ directory"
	fi

	# Link .agents/commands/ and .windsurf/workflows/ so Amp (native) and Windsurf
	# (symlinked) can see the aidevops main-agent slash commands.
	_init_scaffold_commands_symlinks "$project_root"

	if [[ "$is_agent_source" == "true" ]]; then
		seed_agent_source_repo_templates "$project_root"
	else
		# Scaffold or update .agents/AGENTS.md (idempotent — creates if missing,
		# updates Security section if file already exists)
		local _agents_md_existed=false
		[[ -f "$project_root/.agents/AGENTS.md" ]] && _agents_md_existed=true
		scaffold_agents_md "$project_root"
		if [[ "$_agents_md_existed" == "true" ]]; then
			print_success "Updated managed sections in .agents/AGENTS.md"
		else
			print_success "Created .agents/AGENTS.md"
		fi
	fi
	_init_scaffold_project_context "$project_root" "$enable_deployment_context" "$enable_wordpress_context" || return 1

	_init_root_agents_file || return 1
	return 0
}

_init_root_agents_file() {

	# Scaffold root AGENTS.md if missing
	if [[ "$is_agent_source" != "true" && ! -f "$project_root/AGENTS.md" ]]; then
		cat >"$project_root/AGENTS.md" <<ROOTAGENTSEOF
# $repo_name

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Build**: \`# TODO: add build command\`
- **Test**: \`# TODO: add test command\`
- **Deploy**: \`# TODO: add deploy command\`

## Project Overview

<!-- Brief description of what this project does and why it exists. -->

## Architecture

<!-- Key architectural decisions, tech stack, directory structure. -->

## Conventions

- Commits: [Conventional Commits](https://www.conventionalcommits.org/)
- Branches: \`feature/\`, \`bugfix/\`, \`hotfix/\`, \`refactor/\`, \`chore/\`

## Key Files

| File | Purpose |
|------|---------|
| \`.agents/AGENTS.md\` | Project-specific agent instructions |
| \`TODO.md\` | Task tracking |
| \`CHANGELOG.md\` | Version history |

<!-- AI-CONTEXT-END -->
ROOTAGENTSEOF
		print_success "Created AGENTS.md"
	fi

	_init_planning_files || return 1
	return 0
}

_init_planning_files() {

	# Create planning files if enabled
	if [[ "$enable_planning" == "true" ]]; then
		print_info "Setting up planning files..."

		# Create TODO.md from template
		if [[ ! -f "$project_root/TODO.md" ]]; then
			if [[ -f "$AGENTS_DIR/templates/todo-template.md" ]]; then
				cp "$AGENTS_DIR/templates/todo-template.md" "$project_root/TODO.md"
				print_success "Created TODO.md"
			else
				# Fallback minimal template
				cat >"$project_root/TODO.md" <<'EOF'
# TODO

## In Progress

<!-- Tasks currently being worked on -->

## Backlog

<!-- Prioritized list of upcoming tasks -->

---

*Format: `- [ ] Task description @owner #tag ~estimate`*
*Time tracking: `started:`, `completed:`, `actual:`*
EOF
				print_success "Created TODO.md (minimal template)"
			fi
		else
			print_warning "TODO.md already exists, skipping"
		fi

		# Create todo/ directory and PLANS.md
		mkdir -p "$project_root/todo/tasks"

		if [[ ! -f "$project_root/todo/PLANS.md" ]]; then
			if [[ -f "$AGENTS_DIR/templates/plans-template.md" ]]; then
				cp "$AGENTS_DIR/templates/plans-template.md" "$project_root/todo/PLANS.md"
				print_success "Created todo/PLANS.md"
			else
				# Fallback minimal template
				cat >"$project_root/todo/PLANS.md" <<'EOF'
# Execution Plans

Complex, multi-session work that requires detailed planning.

## Active Plans

<!-- Plans currently in progress -->

## Completed Plans

<!-- Archived completed plans -->

---

*See `.agents/workflows/plans.md` for planning workflow*
EOF
				print_success "Created todo/PLANS.md (minimal template)"
			fi
		else
			print_warning "todo/PLANS.md already exists, skipping"
		fi

		# Create .gitkeep in tasks
		touch "$project_root/todo/tasks/.gitkeep"

		# Seed mission-control starter template for personal/org control repos
		local init_actor=""
		if command -v gh &>/dev/null; then
			init_actor=$(gh api user --jq '.login' 2>/dev/null || echo "")
		fi
		local mission_scope=""
		mission_scope=$(_resolve_mission_control_scope "$repo_slug" "$init_actor" 2>/dev/null || echo "")
		_seed_mission_control_template "$project_root" "$mission_scope"
	fi

	_init_database_and_beads || return 1
	return 0
}

_init_database_and_beads() {

	# Create database directories if enabled
	if [[ "$enable_database" == "true" ]]; then
		print_info "Setting up database schema directories..."

		# Create schemas directory with AGENTS.md
		if [[ ! -d "$project_root/schemas" ]]; then
			mkdir -p "$project_root/schemas"
			cat >"$project_root/schemas/AGENTS.md" <<'EOF'
# Database Schemas

Declarative schema files - source of truth for database structure.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created schemas/ directory"
		else
			print_warning "schemas/ already exists, skipping"
		fi

		# Create migrations directory with AGENTS.md
		if [[ ! -d "$project_root/migrations" ]]; then
			mkdir -p "$project_root/migrations"
			cat >"$project_root/migrations/AGENTS.md" <<'EOF'
# Database Migrations

Auto-generated versioned migration files. Do not edit manually.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created migrations/ directory"
		else
			print_warning "migrations/ already exists, skipping"
		fi

		# Create seeds directory with AGENTS.md
		if [[ ! -d "$project_root/seeds" ]]; then
			mkdir -p "$project_root/seeds"
			cat >"$project_root/seeds/AGENTS.md" <<'EOF'
# Database Seeds

Initial and reference data (roles, statuses, test accounts).

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created seeds/ directory"
		else
			print_warning "seeds/ already exists, skipping"
		fi
	fi

	# Initialize Beads if enabled
	if [[ "$enable_beads" == "true" ]]; then
		print_info "Setting up Beads task graph..."

		# Check if Beads CLI is installed
		if ! command -v bd &>/dev/null; then
			print_warning "Beads CLI (bd) not installed"
			echo "  Install with: brew install steveyegge/beads/bd"
			echo "  Or download: https://github.com/steveyegge/beads/releases"
			echo "  Or via Go:   go install github.com/steveyegge/beads/cmd/bd@latest"
		else
			# Initialize Beads in the project
			if [[ ! -d "$project_root/.beads" ]]; then
				print_info "Initializing Beads database..."
				if _init_run_beads_init "$project_root"; then
					print_success "Beads initialized"
				else
					print_warning "Beads init failed - run manually: bd init"
				fi
			else
				print_info "Beads already initialized"
			fi

			# Run initial sync from TODO.md/PLANS.md
			if [[ -f "$AGENTS_DIR/scripts/beads-sync-helper.sh" ]]; then
				print_info "Syncing tasks to Beads..."
				if bash "$AGENTS_DIR/scripts/beads-sync-helper.sh" push "$project_root" 2>/dev/null; then
					print_success "Tasks synced to Beads"
				else
					print_warning "Beads sync failed - run manually: beads-sync-helper.sh push"
				fi
			fi
		fi
	fi

	_init_sops_support || return 1
	return 0
}

_init_sops_support() {

	# Initialize SOPS if enabled
	if [[ "$enable_sops" == "true" ]]; then
		print_info "Setting up SOPS encrypted config support..."

		# Check for sops and age
		local sops_ready=true
		if ! command -v sops &>/dev/null; then
			print_warning "SOPS not installed"
			echo "  Install with: brew install sops"
			sops_ready=false
		fi
		if ! command -v age-keygen &>/dev/null; then
			print_warning "age not installed (default SOPS backend)"
			echo "  Install with: brew install age"
			sops_ready=false
		fi

		# Generate age key if none exists
		local age_key_file="$HOME/.config/sops/age/keys.txt"
		if [[ "$sops_ready" == "true" ]] && [[ ! -f "$age_key_file" ]]; then
			print_info "Generating age key for SOPS..."
			mkdir -p "$(dirname "$age_key_file")"
			age-keygen -o "$age_key_file" 2>/dev/null
			chmod 600 "$age_key_file"
			print_success "Age key generated at $age_key_file"
		fi

		# Create .sops.yaml if it doesn't exist
		if [[ ! -f "$project_root/.sops.yaml" ]]; then
			local age_pubkey=""
			if [[ -f "$age_key_file" ]]; then
				age_pubkey=$(grep -o 'age1[a-z0-9]*' "$age_key_file" | head -1)
			fi

			if [[ -n "$age_pubkey" ]]; then
				cat >"$project_root/.sops.yaml" <<SOPSEOF
# SOPS configuration - encrypts values in config files while keeping keys visible
# See: .agents/tools/credentials/sops.md
creation_rules:
  - path_regex: '\.secret\.(yaml|yml|json)$'
    age: >-
      $age_pubkey
  - path_regex: 'configs/.*\.enc\.(yaml|yml|json)$'
    age: >-
      $age_pubkey
SOPSEOF
				print_success "Created .sops.yaml with age key"
			else
				cat >"$project_root/.sops.yaml" <<'SOPSEOF'
# SOPS configuration - encrypts values in config files while keeping keys visible
# See: .agents/tools/credentials/sops.md
#
# Generate an age key first:
#   age-keygen -o ~/.config/sops/age/keys.txt
#
# Then replace AGE_PUBLIC_KEY below with your public key:
creation_rules:
  - path_regex: '\.secret\.(yaml|yml|json)$'
    age: >-
      AGE_PUBLIC_KEY
  - path_regex: 'configs/.*\.enc\.(yaml|yml|json)$'
    age: >-
      AGE_PUBLIC_KEY
SOPSEOF
				print_warning "Created .sops.yaml template (replace AGE_PUBLIC_KEY with your key)"
			fi
		else
			print_info ".sops.yaml already exists"
		fi
	fi

	_init_git_metadata || return 1
	return 0
}

_init_update_gitignore() {
	local project_root="$1"
	local enable_beads="$2"
	# Add aidevops runtime artifacts to .gitignore
	# Note: .agents/ itself is NOT ignored — it contains committed project-specific agents.
	# Only runtime artifacts (loop state, tmp, memory) are ignored.
	local gitignore="$project_root/.gitignore"
	if [[ ! -f "$gitignore" ]]; then
		cat >"$gitignore" <<'GITIGNOREEOF' || return 1
# aidevops runtime artifacts
.agents/loop-state/
.agents/tmp/
.agents/memory/
.aidevops.json
GITIGNOREEOF
		if [[ "$enable_beads" == "true" ]]; then
			printf '.beads\n' >>"$gitignore" || return 1
		fi
		print_success "Created .gitignore with aidevops runtime artifact ignores"
		return 0
	fi

	local gitignore_updated=false
	if grep -qFx ".agents" "$gitignore" 2>/dev/null; then
		sed -i '' '/^\.agents$/d' "$gitignore" 2>/dev/null ||
			sed -i '/^\.agents$/d' "$gitignore" 2>/dev/null || true
		sed -i '' '/^# aidevops$/{ N; /^# aidevops\n$/d; }' "$gitignore" 2>/dev/null || true
		print_info "Removed legacy bare .agents from .gitignore (now tracked)"
		gitignore_updated=true
	fi
	if grep -qFx ".agent" "$gitignore" 2>/dev/null; then
		sed -i '' '/^\.agent$/d' "$gitignore" 2>/dev/null ||
			sed -i '/^\.agent$/d' "$gitignore" 2>/dev/null || true
		gitignore_updated=true
	fi

	local needs_runtime_entries=false
	local runtime_entry
	for runtime_entry in ".agents/loop-state/" ".agents/tmp/" ".agents/memory/"; do
		grep -qFx "$runtime_entry" "$gitignore" 2>/dev/null || needs_runtime_entries=true
	done
	if [[ "$needs_runtime_entries" == "true" ]]; then
		ensure_trailing_newline "$gitignore"
		if ! grep -qFx "# aidevops runtime artifacts" "$gitignore" 2>/dev/null; then
			[[ ! -s "$gitignore" ]] || printf '\n' >>"$gitignore"
			printf '# aidevops runtime artifacts\n' >>"$gitignore" || return 1
		fi
		for runtime_entry in ".agents/loop-state/" ".agents/tmp/" ".agents/memory/"; do
			grep -qFx "$runtime_entry" "$gitignore" 2>/dev/null || printf '%s\n' "$runtime_entry" >>"$gitignore" || return 1
		done
		print_success "Added .agents/ runtime artifact ignores to .gitignore"
		gitignore_updated=true
	fi

	if ! grep -qFx ".aidevops.json" "$gitignore" 2>/dev/null; then
		ensure_trailing_newline "$gitignore"
		printf '.aidevops.json\n' >>"$gitignore" || return 1
		gitignore_updated=true
	fi
	if [[ "$enable_beads" == "true" ]] && ! grep -qFx ".beads" "$gitignore" 2>/dev/null; then
		ensure_trailing_newline "$gitignore"
		printf '.beads\n' >>"$gitignore" || return 1
		print_success "Added .beads to .gitignore"
		gitignore_updated=true
	fi
	[[ "$gitignore_updated" != "true" ]] || print_info "Updated .gitignore"
	return 0
}

_init_git_metadata() {

	# Ensure .gitattributes has ai-training=false (opt out of AI model training)
	# GitHub and other platforms respect this attribute to exclude repo content
	# from AI/ML training datasets. Idempotent — only adds if not already present.
	local gitattributes="$project_root/.gitattributes"
	if [[ -f "$gitattributes" ]]; then
		if ! grep -qE '^\*[[:space:]]+ai-training=false' "$gitattributes" 2>/dev/null; then
			ensure_trailing_newline "$gitattributes"
			{
				echo ""
				echo "# Opt out of AI model training"
				echo "* ai-training=false"
			} >>"$gitattributes"
			print_success "Added ai-training=false to .gitattributes"
		else
			print_info ".gitattributes already has ai-training=false"
		fi
	else
		cat >"$gitattributes" <<'GITATTRSEOF'
# Opt out of AI model training
* ai-training=false
GITATTRSEOF
		print_success "Created .gitattributes with ai-training=false"
	fi

	_init_update_gitignore "$project_root" "$enable_beads" || return 1

	_init_optional_scaffolding || return 1
	return 0
}

_init_optional_scaffolding() {

	# Scaffold optional files gated by init_scope (collaborator pointers,
	# DESIGN.md, courtesy files, MODELS.md). Extracted to reduce cmd_init
	# nesting depth and function length (t2265).
	_init_scaffold_scope_gated_files "$project_root" "$init_scope" "$repo_name" "$has_interface"

	_init_configure_coderabbit_abort_on_close "$project_root" "$enable_code_quality"
	_init_scaffold_cloudron_release_workflow "$project_root" || return 1

	# ─── Badge + local repo metrics initialization (t2975) ───────────────────
	# Seed the canonical README badge block, generate local metrics artifacts,
	# and install the weekly refresh workflow for repos with a remote. The README
	# references relative docs/metrics assets, so freshly initialised READMEs do
	# not depend on remote badge services or a delayed GitHub Actions commit.
	local _badges_helper="$AGENTS_DIR/scripts/readme-badges-helper.sh"
	local _managed_readme_helper="$AGENTS_DIR/scripts/managed-readme-helper.sh"
	local _metrics_helper="$AGENTS_DIR/scripts/repo-metrics-helper.sh"
	local _label_sync_helper="$AGENTS_DIR/scripts/label-sync-helper.sh"
	local _wf_template="$AGENTS_DIR/templates/workflows/loc-badge-caller.yml"
	local _wf_dest="$project_root/.github/workflows/loc-badge.yml"

	if [[ -n "$repo_slug" ]]; then
		local _is_local_only
		_is_local_only=$(jq -r --arg s "$repo_slug" \
			'.initialized_repos // [] | map(select(.slug == $s)) | if length > 0 then .[0].local_only // false else false end' \
			"$HOME/.config/aidevops/repos.json" 2>/dev/null || echo "false")

		# Install repo metrics refresh workflow for repos that can run GitHub Actions.
		if [[ "$_is_local_only" != "true" && -f "$_wf_template" && ! -f "$_wf_dest" ]]; then
			mkdir -p "$project_root/.github/workflows"
			cp "$_wf_template" "$_wf_dest"
			print_success "Installed .github/workflows/loc-badge.yml (repo metrics refresh workflow)"
		elif [[ -f "$_wf_dest" ]]; then
			print_info ".github/workflows/loc-badge.yml already present"
		elif [[ "$_is_local_only" == "true" ]]; then
			print_info "Skipping GitHub repo metrics refresh workflow for local-only repo"
		fi

		# Seed the canonical badge block in README.md
		local _readme_path="$project_root/README.md"
		if [[ -f "$_badges_helper" && -f "$_readme_path" ]]; then
			if bash "$_badges_helper" inject "$_readme_path" "$repo_slug" 2>/dev/null; then
				print_success "Seeded canonical badge block in README.md"
			else
				print_warning "Badge block injection failed — run manually: aidevops badges sync --repo $repo_slug --apply"
			fi
		elif [[ ! -f "$_readme_path" ]]; then
			print_info "No README.md found — skipping badge block injection (create README.md first)"
		fi

		# Seed the managed Star History chart, weekly caller, and verified
		# Built with aidevops section. Authentication or metadata failures are
		# fail-soft so initialization never invents ownership or emits a broken embed.
		if [[ "$_is_local_only" != "true" && -f "$_managed_readme_helper" && -f "$_readme_path" ]]; then
			if bash "$_managed_readme_helper" sync --repo "$repo_slug" --root "$project_root"; then
				print_success "Seeded managed Star History and aidevops README sections"
			else
				print_warning "Managed README sections skipped — verify GitHub ownership, then run: managed-readme-helper.sh sync --repo $repo_slug --root $project_root"
			fi
		elif [[ "$_is_local_only" == "true" ]]; then
			print_info "Skipping managed Star History and aidevops attribution for local-only repo"
		fi

		# Generate committed local metrics after README injection so LOC/language
		# numbers include the final README badge block.
		if [[ -f "$_metrics_helper" ]]; then
			if bash "$_metrics_helper" generate \
				--output-dir "$project_root/docs/metrics" \
				--badge-dir "$project_root/docs/metrics/badges" \
				--legacy-badge-dir "$project_root/.github/badges" \
				"$project_root" >/dev/null; then
				print_success "Generated local repo metrics in docs/metrics"
			else
				print_warning "Repo metrics generation failed — run manually: aidevops metrics generate"
			fi
		fi

		# Sync the canonical GitHub label palette for this repo. This is a
		# best-effort external GitHub setup step: warn on auth/API/access issues, but
		# do not abort repo initialization.
		if [[ "$_is_local_only" != "true" && -f "$_label_sync_helper" ]]; then
			if bash "$_label_sync_helper" sync --repo "$repo_slug" >/dev/null; then
				print_success "Synced canonical GitHub labels for $repo_slug"
			else
				print_warning "GitHub label sync failed — run manually: label-sync-helper.sh sync --repo $repo_slug"
			fi
		elif [[ "$_is_local_only" == "true" ]]; then
			print_info "Skipping GitHub label sync for local-only repo"
		fi

		# Remind about SYNC_PAT if the repo has a remote and isn't local_only
		if [[ "$_is_local_only" != "true" ]]; then
			print_info "Reminder: set SYNC_PAT so GitHub Actions can refresh repo metrics and Star History — see: aidevops --help sync-pat"
		fi
	fi

	_init_security_and_registration || return 1
	return 0
}

_init_scaffold_cloudron_release_workflow() {
	local target_root="$1"
	[[ -f "${target_root}/CloudronManifest.json" ]] || return 0
	local template_path="${AGENTS_DIR}/templates/workflows/cloudron-package-release-caller.yml"
	local workflow_path="${target_root}/.github/workflows/cloudron-package-release.yml"
	if [[ -f "$workflow_path" ]]; then
		print_info ".github/workflows/cloudron-package-release.yml already present"
		return 0
	fi
	if [[ ! -f "$template_path" ]]; then
		print_warning "Cloudron package release caller template is unavailable"
		return 1
	fi
	mkdir -p "${target_root}/.github/workflows"
	cp "$template_path" "$workflow_path"
	print_success "Installed .github/workflows/cloudron-package-release.yml"
	return 0
}

_init_assess_security_posture() {
	if [[ "$enable_security" == "true" && "${config_migration_deferred:-false}" != "true" ]]; then
		local security_posture_script="$AGENTS_DIR/scripts/security-posture-helper.sh"
		if [[ -f "$security_posture_script" ]]; then
			print_info "Running security posture assessment..."
			local security_status=0
			bash "$security_posture_script" store "$project_root" || security_status=$?
			init_security_posture=$(jq -r '.security_posture.status // "warning"' "$project_root/.aidevops.json" 2>/dev/null || printf 'warning')
			if [[ "$security_status" -eq 0 && "$init_security_posture" == "good" ]]; then
				print_success "Security posture assessed and stored in .aidevops.json"
			elif [[ "$security_status" -le 1 ]]; then
				print_warning "Security posture assessment found issues (review with: aidevops security audit)"
			else
				print_error "Security posture assessment failed before completion"
				return 1
			fi
		else
			init_security_posture="skipped"
			print_info "Security posture check skipped (security-posture-helper.sh not available)"
		fi
	elif [[ "$enable_security" == "true" ]]; then
		init_security_posture="deferred"
		print_info "Security posture storage deferred until .aidevops.json migration is committed"
	fi
	return 0
}

_init_security_and_registration() {
	_init_finalize_repo_verify "$project_root" || return 1
	_init_assess_security_posture || return 1

	# Build features string for registration
	local features_list=""
	[[ "$enable_planning" == "true" ]] && features_list="${features_list}planning,"
	[[ "$enable_git_workflow" == "true" ]] && features_list="${features_list}git-workflow,"
	[[ "$enable_code_quality" == "true" ]] && features_list="${features_list}code-quality,"
	[[ "$enable_time_tracking" == "true" ]] && features_list="${features_list}time-tracking,"
	[[ "$enable_database" == "true" ]] && features_list="${features_list}database,"
	[[ "$enable_beads" == "true" ]] && features_list="${features_list}beads,"
	[[ "$enable_sops" == "true" ]] && features_list="${features_list}sops,"
	[[ "$enable_security" == "true" ]] && features_list="${features_list}security,"
	[[ "$enable_deployment_context" == "true" ]] && features_list="${features_list}deployment-context,"
	[[ "$enable_wordpress_context" == "true" ]] && features_list="${features_list}wordpress-context,"
	features_list="${features_list%,}" # Remove trailing comma

	# Register the *main* repo path (not the worktree path) in repos.json.
	# When check_protected_branch creates a worktree and cd's into it,
	# $project_root (resolved via git rev-parse --show-toplevel) points to the
	# worktree directory. We must register the canonical main worktree path so
	# that pulse and cleanup processes don't treat the worktree as a standalone repo.
	local register_path="$project_root"
	if [[ -n "${WORKTREE_PATH:-}" ]]; then
		# We're inside a worktree — resolve the main worktree path from git metadata
		local main_wt_path
		main_wt_path=$(git -C "$project_root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
		if [[ -n "$main_wt_path" ]] && [[ "$main_wt_path" != "$project_root" ]]; then
			register_path="$main_wt_path"
		fi
	fi
	register_repo "$register_path" "$aidevops_version" "$features_list"

	_init_commit_files || return 1
	return 0
}

_init_commit_files() {

	# Auto-commit initialized files so they don't linger as mystery unstaged
	# changes (#2570 bug 2). Collect all files that cmd_init creates/modifies.
	local init_files=()
	[[ -f "$project_root/.gitattributes" ]] && init_files+=(".gitattributes")
	[[ -f "$project_root/.gitignore" ]] && init_files+=(".gitignore")
	[[ -d "$project_root/.agents" ]] && init_files+=(".agents/")
	[[ -f "$project_root/.aidevops/.gitignore" ]] && init_files+=(".aidevops/.gitignore")
	[[ -f "$project_root/.aidevops/deployments.yaml" ]] && init_files+=(".aidevops/deployments.yaml")
	[[ -f "$project_root/.aidevops/wordpress.yaml" ]] && init_files+=(".aidevops/wordpress.yaml")
	[[ -f "$project_root/AGENTS.md" ]] && init_files+=("AGENTS.md")
	[[ -f "$project_root/DESIGN.md" ]] && init_files+=("DESIGN.md")
	[[ -f "$project_root/TODO.md" ]] && init_files+=("TODO.md")
	[[ -d "$project_root/todo" ]] && init_files+=("todo/")
	[[ -f "$project_root/MODELS.md" ]] && init_files+=("MODELS.md")
	[[ -f "$project_root/LICENCE" ]] && init_files+=("LICENCE")
	[[ -f "$project_root/CHANGELOG.md" ]] && init_files+=("CHANGELOG.md")
	[[ -f "$project_root/README.md" ]] && init_files+=("README.md")
	[[ -d "$project_root/docs/metrics" ]] && init_files+=("docs/metrics/")
	[[ -f "$project_root/.cursorrules" ]] && init_files+=(".cursorrules")
	[[ -f "$project_root/.windsurfrules" ]] && init_files+=(".windsurfrules")
	[[ -f "$project_root/.clinerules" ]] && init_files+=(".clinerules")
	[[ -f "$project_root/.coderabbit.yaml" ]] && init_files+=(".coderabbit.yaml")
	[[ -d "$project_root/.github" ]] && init_files+=(".github/")
	[[ -f "$project_root/.sops.yaml" ]] && init_files+=(".sops.yaml")
	[[ -d "$project_root/schemas" ]] && init_files+=("schemas/")
	[[ -d "$project_root/migrations" ]] && init_files+=("migrations/")
	[[ -d "$project_root/seeds" ]] && init_files+=("seeds/")

	local committed=false
	if [[ ${#init_files[@]} -gt 0 ]]; then
		# Stage all init files (--force not needed; .aidevops.json is gitignored above)
		if git -C "$project_root" add -- "${init_files[@]}" 2>/dev/null; then
			# Only commit if there are staged changes
			if ! git -C "$project_root" diff --cached --quiet 2>/dev/null; then
				if git -C "$project_root" commit -m "chore: initialize aidevops v${aidevops_version}" 2>/dev/null; then
					committed=true
					print_success "Committed initialized files"
				else
					print_warning "Auto-commit failed (pre-commit hook rejected?)"
				fi
			fi
		fi
	fi

	_init_print_summary || return 1
	return 0
}

_init_print_summary() {

	echo ""
	case "$init_security_posture" in
	critical)
		print_warning "AI DevOps local scaffolding initialized (scope: $init_scope); security and remote hardening remain CRITICAL"
		;;
	warning | partial | deferred | skipped | unknown)
		print_warning "AI DevOps local scaffolding initialized (scope: $init_scope); security or remote hardening remains incomplete"
		;;
	*)
		print_success "AI DevOps initialized! (scope: $init_scope)"
		;;
	esac
	echo ""
	echo "Enabled features:"
	[[ "$enable_planning" == "true" ]] && echo "  ✓ Planning (TODO.md, PLANS.md)"
	[[ "$enable_git_workflow" == "true" ]] && echo "  ✓ Git workflow (branch management)"
	[[ "$enable_code_quality" == "true" ]] && echo "  ✓ Code quality (linting, auditing)"
	[[ "$enable_time_tracking" == "true" ]] && echo "  ✓ Time tracking (estimates, actuals)"
	[[ "$enable_database" == "true" ]] && echo "  ✓ Database (schemas/, migrations/, seeds/)"
	[[ "$enable_beads" == "true" ]] && echo "  ✓ Beads (task graph visualization)"
	[[ "$enable_sops" == "true" ]] && echo "  ✓ SOPS (encrypted config files with age backend)"
	[[ "$enable_security" == "true" ]] && echo "  ✓ Security (per-repo posture assessment)"
	[[ "$enable_deployment_context" == "true" ]] && echo "  ✓ Deployment context (.aidevops/deployments.yaml)"
	[[ "$enable_wordpress_context" == "true" ]] && echo "  ✓ WordPress context (.aidevops/wordpress.yaml)"
	[[ -f "$project_root/MODELS.md" ]] && echo "  ✓ MODELS.md (per-repo model performance leaderboard)"
	echo ""
	# When init ran inside a worktree (check_protected_branch created one),
	# print explicit instructions so the user knows where to find their work.
	# Without this, the user's shell is back in the main repo after aidevops exits
	# and the worktree appears to have "disappeared".
	if [[ -n "${WORKTREE_PATH:-}" ]]; then
		local worktree_branch
		worktree_branch=$(git branch --show-current 2>/dev/null || echo "chore/aidevops-init")
		echo "Worktree location:"
		echo "  $WORKTREE_PATH"
		echo ""
		echo "Your init commit is in the worktree above. To continue:"
		echo "  cd $WORKTREE_PATH"
		echo "  git push -u origin ${worktree_branch}"
		echo "  gh pr create --fill" # aidevops-allow: raw-gh-wrapper
		echo ""
	fi
	echo "Next steps:"
	local step=1
	if [[ "$committed" != "true" ]]; then
		echo "  ${step}. Commit the initialized files: git add -A && git commit -m 'chore: initialize aidevops'"
		((++step))
	fi
	if [[ "$enable_beads" == "true" ]]; then
		echo "  ${step}. Add tasks to TODO.md with dependencies (blocked-by:t001)"
		((++step))
		echo "  ${step}. Run /ready to see unblocked tasks"
		((++step))
		echo "  ${step}. Run /sync-beads to sync with Beads graph"
		((++step))
		echo "  ${step}. Use 'bd' CLI for graph visualization"
	elif [[ "$enable_database" == "true" ]]; then
		echo "  ${step}. Add schema files to schemas/"
		((++step))
		echo "  ${step}. Run diff to generate migrations"
		((++step))
		echo "  ${step}. See .agents/workflows/sql-migrations.md"
	else
		echo "  ${step}. Add tasks to TODO.md"
		((++step))
		echo "  ${step}. Use /create-prd for complex features"
		((++step))
		echo "  ${step}. Use /feature to start development"
	fi

	return 0
}

# Print init-specific usage before repository validation or project writes.
_init_print_help() {
	cat <<'INITHELPEOF'
Usage: aidevops init [FEATURES]

Initialize aidevops in the current Git repository.

FEATURES may be `all` (the default standard set), one feature, or a
comma-separated list of features:
  planning, git-workflow, code-quality, time-tracking, database, beads,
  sops, security, deployment-context, hosting-context, wordpress-context

Examples:
  aidevops init
  aidevops init planning
  aidevops init planning,git-workflow,code-quality

Run `aidevops features` for feature descriptions.
INITHELPEOF
	return 0
}

# Init command - initialize aidevops in a project
cmd_init() {
	local features="${1:-all}"
	case "$features" in
	-h | --help | help)
		_init_print_help
		return 0
		;;
	esac

	print_header "Initialize AI DevOps in Project"
	echo ""

	_init_validate_context || return 1
	_init_run_workflow "$features" || return 1
	return 0
}
