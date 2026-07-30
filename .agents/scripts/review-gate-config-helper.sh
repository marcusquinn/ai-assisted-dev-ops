#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# review-gate-config-helper.sh — CLI for configuring review_gate merge policies
# in ~/.config/aidevops/repos.json without hand-editing JSON.
#
# Usage:
#   aidevops review-gate                              Show config for all repos
#   aidevops review-gate list                         Same as above (explicit)
#   aidevops review-gate <slug>                       Show config for one repo
#   aidevops review-gate <slug> pass|wait|unset       Set per-repo default
#   aidevops review-gate <slug> --tool <bot> pass|wait|unset  Per-tool override
#   aidevops review-gate <slug> --completion fast|strict|unset  Completion policy
#   aidevops review-gate <slug> --tool <bot> --completion fast|strict|unset
#   aidevops review-gate <slug> --advisory-context <check> add|remove
#   aidevops review-gate --help                       Show this help
#
# Schema written to ~/.config/aidevops/repos.json under the matching
# initialized_repos entry:
#   { "review_gate": { "rate_limit_behavior": "pass",
#                      "completion_behavior": "fast",
#                      "tools": { "coderabbitai": { "rate_limit_behavior": "wait",
#                                                     "completion_behavior": "strict" } } } }
#
# Resolution order: per-tool > per-repo > env var > hardcoded default.
# This helper only edits repos.json. Env vars and defaults are untouched.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Fallback colors when shared-constants.sh is not present
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'

readonly REPOS_JSON="${AIDEVOPS_REPOS_JSON:-${HOME:+$HOME/.config/aidevops/repos.json}}"
readonly RATE_LIMIT_BEHAVIOR_FIELD="rate_limit_behavior"
readonly COMPLETION_BEHAVIOR_FIELD="completion_behavior"
readonly ADVISORY_CONTEXTS_FIELD="advisory_check_contexts"
readonly UNSET_VALUE="unset"

# Current bot logins for --tool validation. New bots warn but are not rejected
# (forward-compat: new bots should work without a helper update). Retired logins
# remain accepted only with `unset` so stale policy can be removed safely.
readonly KNOWN_BOT_LOGINS="coderabbitai augment-code augmentcode copilot"
readonly RETIRED_BOT_LOGINS="gemini-code-assist"

_print_ok() {
	local msg="$1"
	printf "${GREEN}[OK]${NC} %s\n" "$msg"
	return 0
}

_print_info() {
	local msg="$1"
	printf "${BLUE}[INFO]${NC} %s\n" "$msg"
	return 0
}

_print_warn() {
	local msg="$1"
	printf "${YELLOW}[WARN]${NC} %s\n" "$msg" >&2
	return 0
}

_print_error() {
	local msg="$1"
	printf "${RED}[ERROR]${NC} %s\n" "$msg" >&2
	return 0
}

# Validate that jq is available — required for all mutations.
_require_jq() {
	if ! command -v jq &>/dev/null; then
		_print_error "jq is required but not installed. Install with: brew install jq"
		return 1
	fi
	return 0
}

# Validate that repos.json exists and is readable.
_require_repos_json() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		_print_error "repos.json not found: $REPOS_JSON"
		_print_info "Run 'aidevops init' to create it."
		return 1
	fi
	return 0
}

# Validate a rate_limit_behavior value.
_validate_rate_limit_behavior() {
	local value="$1"
	case "$value" in
	pass | wait | unset) return 0 ;;
	*)
		_print_error "Invalid value '${value}'. Must be: pass, wait, or unset"
		return 1
		;;
	esac
}

# Validate a completion_behavior value.
_validate_completion_behavior() {
	local value="$1"
	case "$value" in
	fast | strict | unset) return 0 ;;
	*)
		_print_error "Invalid completion value '${value}'. Must be: fast, strict, or unset"
		return 1
		;;
	esac
}

_validate_advisory_context() {
	local value="$1"
	if [[ -z "$value" || ${#value} -gt 200 || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
		_print_error "Invalid advisory check context. Use one non-empty check name of at most 200 characters."
		return 1
	fi
	return 0
}

# Warn if a bot login is not in the known list (but don't reject it —
# forward-compat with new bots added after this helper was written).
_warn_if_unknown_bot() {
	local bot="$1"
	local known
	known="$KNOWN_BOT_LOGINS $RETIRED_BOT_LOGINS"
	local found=0
	local b
	for b in $known; do
		if [[ "$b" == "$bot" ]]; then
			found=1
			break
		fi
	done
	if [[ "$found" -eq 0 ]]; then
		_print_warn "Unknown bot login '${bot}'. Known bots: ${KNOWN_BOT_LOGINS}"
		_print_warn "Proceeding anyway — new bots will work if the name is correct."
	fi
	return 0
}

_validate_retired_bot_policy() {
	local bot="$1"
	local value="$2"
	local retired
	for retired in $RETIRED_BOT_LOGINS; do
		if [[ "$retired" == "$bot" ]]; then
			if [[ "$value" != "$UNSET_VALUE" ]]; then
				_print_error "Bot login '${bot}' is retired; only 'unset' is accepted for legacy configuration cleanup."
				return 1
			fi
			_print_warn "Removing legacy configuration for retired bot '${bot}'."
			return 0
		fi
	done
	return 0
}

# Look up a repo entry by slug (owner/repo) or by path.
# Prints the matched slug on success, empty on failure.
_resolve_slug() {
	local input="$1"
	_require_jq || return 1
	_require_repos_json || return 1

	local matched_slug=""

	# Try exact slug match first
	matched_slug=$(jq -r --arg input "$input" \
		'.initialized_repos[]? | select(.slug == $input) | .slug' \
		"$REPOS_JSON" 2>/dev/null | head -1)

	# Try path match if slug match failed
	if [[ -z "$matched_slug" ]]; then
		matched_slug=$(jq -r --arg input "$input" \
			'.initialized_repos[]? | select(.path == $input) | .slug' \
			"$REPOS_JSON" 2>/dev/null | head -1)
	fi

	printf '%s' "$matched_slug"
	return 0
}

# Print the effective rate_limit_behavior for a slug+bot combination,
# mirroring the resolution order in review-bot-gate-helper.sh.
_resolve_effective_behavior() {
	local slug="$1"
	local bot="${2:-}"
	local field="${3:-$RATE_LIMIT_BEHAVIOR_FIELD}"

	local per_tool_val=""
	local per_repo_val=""

	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		per_repo_val=$(jq -r --arg slug "$slug" --arg field "$field" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate[$field] // empty' \
			"$REPOS_JSON" 2>/dev/null) || per_repo_val=""

		if [[ -n "$bot" ]]; then
			per_tool_val=$(jq -r --arg slug "$slug" --arg bot "$bot" --arg field "$field" \
				'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate.tools[$bot][$field] // empty' \
				"$REPOS_JSON" 2>/dev/null) || per_tool_val=""
		fi
	fi

	local global_env="${REVIEW_GATE_RATE_LIMIT_BEHAVIOR:-pass}"
	if [[ "$field" == "$COMPLETION_BEHAVIOR_FIELD" ]]; then
		global_env="${REVIEW_GATE_COMPLETION_BEHAVIOR:-fast}"
	fi

	# Resolution order: per-tool > per-repo > env > "pass"
	if [[ -n "$bot" && -n "$per_tool_val" ]]; then
		printf '%s' "$per_tool_val"
	elif [[ -n "$per_repo_val" ]]; then
		printf '%s' "$per_repo_val"
	else
		printf '%s' "$global_env"
	fi
	return 0
}

# Error helper: called when a jq mutation pipeline fails.
_jq_mutation_failed() {
	_print_error "jq mutation failed — repos.json was not modified"
	return 1
}

# Safely write to repos.json: backup, apply mutation, validate, restore on failure.
_safe_write_repos_json() {
	local new_json="$1"
	local bak_file="${REPOS_JSON}.bak"

	# Validate the new JSON before writing
	if ! printf '%s' "$new_json" | jq . >/dev/null 2>&1; then
		_print_error "Generated JSON is invalid — not writing. This is a bug; please report it."
		return 1
	fi

	# Backup existing file
	cp "$REPOS_JSON" "$bak_file" || {
		_print_error "Could not create backup at ${bak_file}"
		return 1
	}

	# Write new content
	printf '%s\n' "$new_json" >"$REPOS_JSON"

	# Validate the written file
	if ! jq . "$REPOS_JSON" >/dev/null 2>&1; then
		_print_error "Validation failed after write. Restoring backup."
		cp "$bak_file" "$REPOS_JSON"
		rm -f "$bak_file"
		return 1
	fi

	rm -f "$bak_file"
	return 0
}

# ── List command ─────────────────────────────────────────────────────────────

cmd_list() {
	local filter_slug="${1:-}"

	_require_jq || return 1
	_require_repos_json || return 1

	local slugs
	if [[ -n "$filter_slug" ]]; then
		# Verify the slug is registered
		local resolved
		resolved=$(_resolve_slug "$filter_slug")
		if [[ -z "$resolved" ]]; then
			_print_error "No registered repo found matching '${filter_slug}'"
			_print_info "Run 'aidevops repos' to list registered repos."
			return 1
		fi
		slugs="$resolved"
	else
		slugs=$(jq -r '.initialized_repos[]? | .slug // empty' "$REPOS_JSON" 2>/dev/null) || slugs=""
	fi

	if [[ -z "$slugs" ]]; then
		_print_info "No repos registered. Run 'aidevops init' or 'aidevops repos'."
		return 0
	fi

	echo ""
	echo "Review Gate Configuration"
	echo "========================="
	echo ""

	local global_env="${REVIEW_GATE_RATE_LIMIT_BEHAVIOR:-pass}"
	printf "  Global default (env / hardcoded): %s\n" "$global_env"
	echo ""

	local slug
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue

		local rate_limit_val completion_val advisory_contexts repo_values
		repo_values=$(jq -r --arg slug "$slug" --arg rate_field "$RATE_LIMIT_BEHAVIOR_FIELD" --arg completion_field "$COMPLETION_BEHAVIOR_FIELD" \
			'first(.initialized_repos[]? | select(.slug == $slug)) // {} | [(.review_gate[$rate_field] // ""), (.review_gate[$completion_field] // "")] | @tsv' \
			"$REPOS_JSON" 2>/dev/null) || repo_values=$'\t'
		rate_limit_val="${repo_values%%$'\t'*}"
		completion_val="${repo_values#*$'\t'}"
		if [[ "$completion_val" == "$repo_values" ]]; then
			completion_val=""
		fi

		local rate_effective completion_effective
		rate_effective=$(_resolve_effective_behavior "$slug" "" "$RATE_LIMIT_BEHAVIOR_FIELD")
		completion_effective=$(_resolve_effective_behavior "$slug" "" "$COMPLETION_BEHAVIOR_FIELD")

		printf "  %s\n" "$slug"
		if [[ -n "$rate_limit_val" ]]; then
			printf "    rate-limit per-repo: %-6s  effective: %s\n" "$rate_limit_val" "$rate_effective"
		else
			printf "    rate-limit per-repo: %-6s  effective: %s\n" "(unset)" "$rate_effective"
		fi
		if [[ -n "$completion_val" ]]; then
			printf "    completion per-repo: %-6s  effective: %s\n" "$completion_val" "$completion_effective"
		else
			printf "    completion per-repo: %-6s  effective: %s\n" "(unset)" "$completion_effective"
		fi
		advisory_contexts=$(jq -r --arg slug "$slug" --arg field "$ADVISORY_CONTEXTS_FIELD" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate[$field] // [] | join(", ")' \
			"$REPOS_JSON" 2>/dev/null) || advisory_contexts=""
		printf "    advisory check contexts: %s\n" "${advisory_contexts:-(none; unknown failures block)}"

		# List per-tool overrides if present
		local tools_json
		tools_json=$(jq -r --arg slug "$slug" --arg rate_field "$RATE_LIMIT_BEHAVIOR_FIELD" --arg completion_field "$COMPLETION_BEHAVIOR_FIELD" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate.tools // empty | to_entries[]? | "\(.key)=\(.value[$rate_field] // "(unset)")|\(.value[$completion_field] // "(unset)")"' \
			"$REPOS_JSON" 2>/dev/null) || tools_json=""

		if [[ -n "$tools_json" ]]; then
			local tool_entry
			while IFS= read -r tool_entry; do
				[[ -z "$tool_entry" ]] && continue
				local tool_name rest tool_rate_val tool_completion_val tool_rate_effective tool_completion_effective
				tool_name="${tool_entry%%=*}"
				rest="${tool_entry#*=}"
				tool_rate_val="${rest%%|*}"
				tool_completion_val="${rest#*|}"
				tool_rate_effective=$(_resolve_effective_behavior "$slug" "$tool_name" "$RATE_LIMIT_BEHAVIOR_FIELD")
				tool_completion_effective=$(_resolve_effective_behavior "$slug" "$tool_name" "$COMPLETION_BEHAVIOR_FIELD")
				printf "    tool %-24s rate-limit: %-6s effective: %-6s completion: %-6s effective: %s\n" \
					"${tool_name}:" "$tool_rate_val" "$tool_rate_effective" "$tool_completion_val" "$tool_completion_effective"
			done <<<"$tools_json"
		fi

		echo ""
	done <<<"$slugs"

	return 0
}

cmd_advisory_context() {
	local slug="$1"
	local context_name="$2"
	local action="$3"

	_require_jq || return 1
	_require_repos_json || return 1
	_validate_advisory_context "$context_name" || return 1
	case "$action" in
	add | remove) ;;
	*)
		_print_error "Invalid advisory-context action '${action}'. Must be: add or remove"
		return 1
		;;
	esac

	local resolved_slug=""
	resolved_slug=$(_resolve_slug "$slug")
	if [[ -z "$resolved_slug" ]]; then
		_print_error "No registered repo found matching '${slug}'"
		return 1
	fi

	local current_json="" new_json=""
	current_json=$(<"$REPOS_JSON")
	if [[ "$action" == "add" ]]; then
		new_json=$(printf '%s' "$current_json" | jq --arg slug "$resolved_slug" --arg field "$ADVISORY_CONTEXTS_FIELD" --arg context "$context_name" '
			(.initialized_repos[] | select(.slug == $slug) | .review_gate[$field]) |= ((. // []) + [$context] | unique)
		' 2>/dev/null) || { _jq_mutation_failed; return 1; }
	else
		new_json=$(printf '%s' "$current_json" | jq --arg slug "$resolved_slug" --arg field "$ADVISORY_CONTEXTS_FIELD" --arg context "$context_name" '
			(.initialized_repos[] | select(.slug == $slug) | .review_gate[$field]) |= ((. // []) | map(select(. != $context)))
			| (.initialized_repos[] | select(.slug == $slug) | .review_gate) |= if (.[$field] // []) == [] then del(.[$field]) else . end
		' 2>/dev/null) || { _jq_mutation_failed; return 1; }
	fi

	_safe_write_repos_json "$new_json" || return 1
	_print_ok "${action} advisory check context '${context_name}' for ${resolved_slug}"
	_print_info "Configured advisory contexts are exact names; required, maintainer-gate, unknown, and evidence-less failures still block."
	return 0
}

# ── Set command ──────────────────────────────────────────────────────────────

cmd_set() {
	local slug="$1"
	local tool_login="${2:-}"
	local value="$3"
	local field="${4:-$RATE_LIMIT_BEHAVIOR_FIELD}"

	_require_jq || return 1
	_require_repos_json || return 1

	# Validate the value
	if [[ "$field" == "$COMPLETION_BEHAVIOR_FIELD" ]]; then
		_validate_completion_behavior "$value" || return 1
	else
		_validate_rate_limit_behavior "$value" || return 1
	fi

	# Resolve and validate the slug
	local resolved_slug
	resolved_slug=$(_resolve_slug "$slug")
	if [[ -z "$resolved_slug" ]]; then
		_print_error "No registered repo found matching '${slug}'"
		_print_info "Run 'aidevops repos' to list registered repos."
		return 1
	fi

	# Warn if bot login is unknown (but proceed)
	if [[ -n "$tool_login" ]]; then
		_validate_retired_bot_policy "$tool_login" "$value" || return 1
		_warn_if_unknown_bot "$tool_login"
	fi

	local current_json
	current_json=$(<"$REPOS_JSON")

	local new_json
	if [[ "$value" == "$UNSET_VALUE" ]]; then
		# Remove the field
		if [[ -n "$tool_login" ]]; then
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg bot "$tool_login" \
				--arg field "$field" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate.tools[$bot]) |= del(.[$field])' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
			# Clean up the empty bot object, then the tools object if it is empty.
			new_json=$(printf '%s' "$new_json" | jq \
				--arg slug "$resolved_slug" \
				--arg bot "$tool_login" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate) |=
					(if (.tools[$bot] // null) == {} then del(.tools[$bot]) else . end
					| if (.tools // {}) == {} then del(.tools) else . end)' \
				2>/dev/null) || true
		else
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg field "$field" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate) |= del(.[$field])' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
		fi
	else
		# Set the field
		if [[ -n "$tool_login" ]]; then
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg bot "$tool_login" \
				--arg field "$field" \
				--arg val "$value" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate.tools[$bot][$field]) |= $val' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
		else
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg field "$field" \
				--arg val "$value" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate[$field]) |= $val' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
		fi
	fi

	_safe_write_repos_json "$new_json" || return 1

	# Report what changed
	if [[ "$value" == "$UNSET_VALUE" ]]; then
		if [[ -n "$tool_login" ]]; then
			_print_ok "Removed per-tool ${field} override for '${tool_login}' on ${resolved_slug}"
			_print_info "Effective value now: $(_resolve_effective_behavior "$resolved_slug" "$tool_login" "$field")"
		else
			_print_ok "Removed per-repo ${field} override for ${resolved_slug}"
			_print_info "Effective value now: $(_resolve_effective_behavior "$resolved_slug" "" "$field")"
		fi
	else
		if [[ -n "$tool_login" ]]; then
			_print_ok "Set review_gate.tools.${tool_login}.${field} = ${value} for ${resolved_slug}"
		else
			_print_ok "Set review_gate.${field} = ${value} for ${resolved_slug}"
		fi
		_print_info "Effective value: $(_resolve_effective_behavior "$resolved_slug" "$tool_login" "$field")"
	fi

	return 0
}

# ── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
	echo "review-gate-config-helper.sh — Configure review_gate merge policies"
	echo ""
	echo "Controls what happens when a review bot is rate-limited during a merge check:"
	echo "  pass  (default) — treat rate-limit as a pass, preserve merge velocity"
	echo "  wait            — keep polling until the bot responds (strict review-before-merge)"
	echo ""
	echo "Controls whether code-quality add-on completion can delay merge:"
	echo "  fast   (permanent default) — advisory; required project CI controls merge readiness"
	echo "  strict                     — opt in to review-before-merge and terminal evidence"
	echo ""
	echo "Commands:"
	echo "  list [<slug>]                          Show config for all repos (or one)"
	echo "  <slug> pass|wait|unset                 Set per-repo default"
	echo "  <slug> --tool <bot> pass|wait|unset    Set per-tool override"
	echo "  <slug> --completion fast|strict|unset  Set completion default"
	echo "  <slug> --tool <bot> --completion fast|strict|unset"
	echo "  <slug> --advisory-context <check> add|remove"
	echo "  help                                   Show this help"
	echo ""
	echo "Arguments:"
	echo "  <slug>   owner/repo slug or local path (must be registered in repos.json)"
	echo "  <bot>    Active bot login: coderabbitai, augment-code, augmentcode, copilot"
	echo "           Retired login gemini-code-assist is accepted only with unset"
	echo "           Unknown bot logins produce a warning but are accepted (forward-compat)"
	echo ""
	echo "Examples:"
	echo "  aidevops review-gate                              # list all repos"
	echo "  aidevops review-gate marcusquinn/myrepo          # show one repo"
	echo "  aidevops review-gate marcusquinn/myrepo wait     # block merges on rate-limit"
	echo "  aidevops review-gate marcusquinn/myrepo pass     # restore default (pass)"
	echo "  aidevops review-gate marcusquinn/myrepo unset    # remove per-repo override"
	echo "  aidevops review-gate marcusquinn/myrepo --tool coderabbitai wait"
	echo "  aidevops review-gate marcusquinn/myrepo --tool coderabbitai unset"
	echo "  aidevops review-gate marcusquinn/myrepo --completion strict"
	echo "  aidevops review-gate marcusquinn/myrepo --completion fast    # restore advisory default"
	echo "  aidevops review-gate marcusquinn/myrepo --tool coderabbitai --completion strict"
	echo "  aidevops review-gate marcusquinn/myrepo --advisory-context 'CodeRabbit' add"
	echo ""
	echo "Resolution order (per-tool wins):"
	echo "  rate-limit: per-tool > per-repo > REVIEW_GATE_RATE_LIMIT_BEHAVIOR env > pass"
	echo "  completion: per-tool > per-repo > REVIEW_GATE_COMPLETION_BEHAVIOR env > fast"
	echo "  CI caller: AIDEVOPS_REVIEW_GATE_COMPLETION_BEHAVIOR Actions variable > fast"
	echo ""
	echo "Reference: .agents/reference/repos-json-fields.md"
	return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
	local command="${1:-list}"
	shift 2>/dev/null || true

	# Handle --help / -h as first arg
	case "$command" in
	--help | -h | help) cmd_help; return 0 ;;
	esac

	# Handle: bare (no args after binary) → list
	# Handle: list [slug]
	# Handle: <slug>                → show one repo
	# Handle: <slug> pass|wait|unset
	# Handle: <slug> --tool <bot> pass|wait|unset
	# Handle: <slug> --completion fast|strict|unset
	# Handle: <slug> --tool <bot> --completion fast|strict|unset

	case "$command" in
	list)
		cmd_list "${1:-}"
		;;
	*)
		# command is a slug (or path). Determine subcommand.
		local slug="$command"
		local subcommand="${1:-}"

		# Bare slug → show that repo's config
		if [[ -z "$subcommand" ]]; then
			cmd_list "$slug"
			return $?
		fi

		# slug --completion fast|strict|unset
		if [[ "$subcommand" == "--completion" ]]; then
			local value="${2:-}"
			if [[ -z "$value" ]]; then
				_print_error "Missing value after --completion. Expected: fast, strict, or unset"
				cmd_help
				return 1
			fi
			cmd_set "$slug" "" "$value" "$COMPLETION_BEHAVIOR_FIELD"
			return $?
		fi

		# slug --advisory-context <exact-check-name> add|remove
		if [[ "$subcommand" == "--advisory-context" ]]; then
			local context_name="${2:-}"
			local context_action="${3:-}"
			if [[ -z "$context_name" || -z "$context_action" ]]; then
				_print_error "Usage: aidevops review-gate <slug> --advisory-context <exact-check-name> add|remove"
				return 1
			fi
			cmd_advisory_context "$slug" "$context_name" "$context_action"
			return $?
		fi

		# slug --tool <bot> pass|wait|unset
		# slug --tool <bot> --completion fast|strict|unset
		if [[ "$subcommand" == "--tool" ]]; then
			local tool_login="${2:-}"
			local value="${3:-}"
			local field="$RATE_LIMIT_BEHAVIOR_FIELD"
			if [[ -z "$tool_login" ]]; then
				_print_error "Missing bot login after --tool"
				cmd_help
				return 1
			fi
			if [[ "$value" == "--completion" ]]; then
				field="$COMPLETION_BEHAVIOR_FIELD"
				value="${4:-}"
			fi
			if [[ -z "$value" ]]; then
				_print_error "Missing value after --tool ${tool_login}. Expected: pass, wait, unset, or --completion fast|strict|unset"
				cmd_help
				return 1
			fi
			cmd_set "$slug" "$tool_login" "$value" "$field"
			return $?
		fi

		# slug pass|wait|unset
		case "$subcommand" in
		pass | wait | unset)
			cmd_set "$slug" "" "$subcommand"
			return $?
			;;
		*)
			_print_error "Unknown subcommand: ${subcommand}"
			cmd_help
			return 1
			;;
		esac
		;;
	esac
}

main "$@"
