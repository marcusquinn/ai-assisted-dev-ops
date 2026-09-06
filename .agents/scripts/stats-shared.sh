#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-shared.sh - Shared utility functions for the stats subsystem
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase 1)
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Globals read:
#   - LOGFILE, REPOS_JSON
# Globals written:
#   - none (caches written to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_SHARED_LOADED:-}" ]] && return 0
_STATS_SHARED_LOADED=1

# Bounded decimal configuration: reject overflow and normalize leading zeroes.
_stats_seconds() {
	local value="$1" fallback="$2"
	[[ "$value" =~ ^[0-9]{1,9}$ ]] || value="$fallback"
	printf '%s\n' "$((10#$value))"
	return 0
}

# The wrapper already reserves 30s for its own cleanup. Standalone callers get
# the same finite ceiling; phases must resolve it once, not per repository.
_stats_work_deadline() {
	local now deadline seconds
	now=$(date +%s)
	seconds=$(_stats_seconds "${STATS_TIMEOUT:-600}" 600)
	deadline=$((now + seconds - 30))
	if [[ "${AIDEVOPS_GH_DEADLINE_EPOCH:-}" =~ ^[0-9]{1,11}$ ]]; then
		[[ "$((10#$AIDEVOPS_GH_DEADLINE_EPOCH))" -lt "$deadline" ]] && deadline="$((10#$AIDEVOPS_GH_DEADLINE_EPOCH))"
	fi
	printf '%s\n' "$deadline"
	return 0
}

# Bound an entire shell function, not only its GitHub calls. Functions retain
# the caller's loaded libraries/configuration in the child, but variable changes
# do not return to the parent. Disk state/stdout are the explicit output channel.
# Nested gh timeout process groups must also die, rather than escaping a kill
# directed only at the immediate group. Freeze parents before discovering their
# children so they cannot spawn replacements during cleanup.
# Args: maximum seconds, absolute deadline, command and arguments. 124=deferred.
_stats_run_bounded() {
	local seconds="$1" deadline="$2"
	shift 2
	local now end_epoch child_pid result=0 child_result=0 scratch
	now=$(date +%s)
	[[ "$deadline" -gt "$((now + 2))" && "$seconds" -gt 0 ]] || return 124
	end_epoch=$((now + seconds))
	[[ "$end_epoch" -lt "$((deadline - 2))" ]] || end_epoch=$((deadline - 2))
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/stats-batch.XXXXXX") || return 1
	(
		trap - EXIT
		export TMPDIR="$scratch"
		export AIDEVOPS_GH_DEADLINE_EPOCH="$end_epoch"
		"$@"
	) &
	child_pid=$!
	while kill -0 "$child_pid" 2>/dev/null; do
		now=$(date +%s)
		if [[ "$now" -ge "$end_epoch" ]]; then
			_stats_kill_bounded_tree "$child_pid"
			result=124
			break
		fi
		sleep 0.2
	done
	wait "$child_pid" 2>/dev/null || child_result=$?
	[[ "$result" -eq 124 ]] || result="$child_result"
	rm -rf "$scratch"
	return "$result"
}

_stats_kill_bounded_tree() {
	local pid="$1" child
	kill -STOP "$pid" 2>/dev/null || return 0
	while IFS= read -r child; do
		[[ -z "$child" ]] || _stats_kill_bounded_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill -KILL "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Validate a repo slug matches the expected owner/repo format.
# Rejects path traversal, quotes, and other injection vectors.
# Arguments:
#   $1 - repo slug to validate
# Returns: 0 if valid, 1 if invalid
#######################################
_validate_repo_slug() {
	local slug="$1"
	# Must be non-empty, match owner/repo with only alphanumeric, hyphens,
	# underscores, and dots (GitHub's allowed characters)
	if [[ "$slug" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
		return 0
	fi
	echo "[stats] Invalid repo slug rejected: ${slug}" >>"$LOGFILE"
	return 1
}

#######################################
# Sanitize a runner/identity token before using it in cache filenames.
# Arguments:
#   $1 - identity token
# Output: filesystem-safe token, bounded to avoid long-path failures
#######################################
_sanitize_runner_identity_for_cache() {
	local identity="$1"
	identity="${identity//[^a-zA-Z0-9._-]/-}"
	identity="${identity:0:80}"
	[[ -n "$identity" ]] || identity="unknown-runner"
	printf '%s' "$identity"
	return 0
}

#######################################
# Read an expired runner-role cache entry for transient API failure fallback.
# Args: $1=disk_cache_file $2=repo_slug
# Output: stale role, when present.
# Returns: 0 always.
#######################################
_get_stale_runner_role() {
	local disk_cache_file="$1"
	local repo_slug="$2"
	local stale_role="" stale_ts=""
	if [[ -f "$disk_cache_file" ]]; then
		IFS='|' read -r stale_role stale_ts <"$disk_cache_file" 2>/dev/null || stale_role=""
		if [[ -n "$stale_role" ]]; then
			echo "[stats] _get_runner_role: API failed for ${repo_slug}, using stale cache: ${stale_role}" >>"${LOGFILE:-/dev/null}"
		fi
	fi
	printf '%s\n' "$stale_role"
	return 0
}

# check_session_count: now provided by worker-lifecycle-common.sh (sourced by caller).
# Previously duplicated here (17 lines) — see t1431. Consolidated to eliminate
# divergence risk and ensure single source of truth.

#######################################
# Determine runner role for a repo: supervisor or contributor
#
# Resolution order (first match wins):
#   1. In-process env-var cache (per pulse cycle, no I/O)
#   2. repos.json maintainer field (deterministic, no API)
#   3. Persistent disk cache with 24h TTL (~/.aidevops/logs/)
#   4. GitHub API permission check (fallback)
#
# Layers 1-3 prevent the bug where a transient API failure (rate
# limit, network) defaulted to "contributor" and created duplicate
# [Contributor:user] health issues alongside the correct [Supervisor]
# ones. See t1929 for the full root-cause analysis.
#
# Arguments:
#   $1 - runner GitHub login
#   $2 - repo slug (owner/repo)
# Output: "supervisor" or "contributor" to stdout
#######################################
_get_runner_role() {
	local runner_user="$1"
	local repo_slug="$2"

	# Validate slug before using in API path (defense-in-depth)
	if ! _validate_repo_slug "$repo_slug"; then
		echo "contributor"
		return 0
	fi

	# Layer 1: in-process env-var cache (per pulse cycle)
	local cache_key="__RUNNER_ROLE_${repo_slug//[^a-zA-Z0-9]/_}"
	local cached_role="${!cache_key:-}"
	if [[ -n "$cached_role" ]]; then
		echo "$cached_role"
		return 0
	fi

	# Layer 2: repos.json maintainer field (deterministic, no API needed).
	# If the runner matches the registered maintainer, they are supervisor.
	# This is the primary defense against API failure causing role misdetection.
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	if [[ -f "$repos_json" ]]; then
		local registered_maintainer
		registered_maintainer=$(jq -r \
			--arg slug "$repo_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
			"$repos_json" 2>/dev/null | head -1)
		if [[ -n "$registered_maintainer" && "$registered_maintainer" == "$runner_user" ]]; then
			export "$cache_key=supervisor"
			_persist_role_cache "$runner_user" "$repo_slug" "supervisor"
			echo "supervisor"
			return 0
		fi
	fi

	# Layer 3: persistent disk cache with 24h TTL.
	# Survives across pulse cycles; prevents API failure from flipping role.
	local disk_cache_dir="${HOME}/.aidevops/logs"
	local slug_safe="${repo_slug//\//-}"
	local runner_user_cache_safe
	runner_user_cache_safe=$(_sanitize_runner_identity_for_cache "$runner_user")
	local disk_cache_file="${disk_cache_dir}/runner-role-${runner_user_cache_safe}-${slug_safe}"
	if [[ -f "$disk_cache_file" ]]; then
		local disk_role disk_ts now_ts
		IFS='|' read -r disk_role disk_ts <"$disk_cache_file" 2>/dev/null || disk_role=""
		disk_ts="${disk_ts//[^0-9]/}"
		disk_ts="${disk_ts:-0}"
		now_ts=$(date +%s)
		# 24h TTL (86400 seconds)
		if [[ -n "$disk_role" && $((now_ts - disk_ts)) -lt 86400 ]]; then
			export "$cache_key=$disk_role"
			echo "$disk_role"
			return 0
		fi
	fi

	# Layer 4: GitHub API permission check (fallback).
	# On failure, use expired disk cache if available rather than defaulting
	# to "contributor" — this prevents role flip-flop on transient errors.
	local role=""
	local response=""
	local lookup_failed=0
	# #aidevops:trust-boundary — runner role classification uses confirmed
	# collaborator permission; transient lookup failures prefer stale cache.
	_gh_collaborator_permission_lookup "$repo_slug" "$runner_user" response || lookup_failed=1

	case "$response" in
	admin | maintain | write)
		role="supervisor"
		;;
	read | none)
		role="contributor"
		;;
	"")
		role=$(_get_stale_runner_role "$disk_cache_file" "$repo_slug")
		[[ -z "$role" ]] && role="contributor"
		;;
	*)
		# Unknown permission value — fail closed
		role="contributor"
		;;
	esac

	if [[ "$lookup_failed" -eq 1 ]]; then
		echo "$role"
		return 0
	fi

	# Persist to both caches
	export "$cache_key=$role"
	_persist_role_cache "$runner_user" "$repo_slug" "$role"

	echo "$role"
	return 0
}

# Write role to persistent disk cache.
# Format: "role|epoch_timestamp" — simple, no JSON dependency.
# Arguments:
#   $1 - runner_user
#   $2 - repo_slug
#   $3 - role (supervisor|contributor)
_persist_role_cache() {
	local runner_user="$1"
	local repo_slug="$2"
	local role="$3"
	local disk_cache_dir="${HOME}/.aidevops/logs"
	local slug_safe="${repo_slug//\//-}"
	local runner_user_cache_safe
	runner_user_cache_safe=$(_sanitize_runner_identity_for_cache "$runner_user")
	local disk_cache_file="${disk_cache_dir}/runner-role-${runner_user_cache_safe}-${slug_safe}"
	mkdir -p "$disk_cache_dir" 2>/dev/null || true
	printf '%s|%s\n' "$role" "$(date +%s)" >"$disk_cache_file" 2>/dev/null || true
	return 0
}

#######################################
# Normalize a dashboard identity token for alias comparisons.
# Arguments:
#   $1 - identity token
# Output: lower-case trimmed token
#######################################
_normalize_dashboard_identity_token() {
	local token="$1"
	token="${token#"${token%%[![:space:]]*}"}"
	token="${token%"${token##*[![:space:]]}"}"
	printf '%s' "$token" | tr '[:upper:]' '[:lower:]'
	return 0
}

#######################################
# Resolve the identity-alias config path.
# Output: config path, or empty when no config exists
#######################################
_dashboard_identity_alias_config_path() {
	local configured_path="${AIDEVOPS_IDENTITY_ALIASES_CONF:-}"
	if [[ -n "$configured_path" && -f "$configured_path" ]]; then
		printf '%s' "$configured_path"
		return 0
	fi

	local repo_config=""
	if [[ -n "${SCRIPT_DIR:-}" ]]; then
		repo_config="${SCRIPT_DIR%/scripts}/configs/identity-aliases.conf"
		if [[ -f "$repo_config" ]]; then
			printf '%s' "$repo_config"
			return 0
		fi
	fi

	local deployed_config="${HOME}/.aidevops/agents/configs/identity-aliases.conf"
	if [[ -f "$deployed_config" ]]; then
		printf '%s' "$deployed_config"
	fi
	return 0
}

#######################################
# Print canonical identity and aliases for a dashboard runner.
# Config format: canonical=alias-one,alias-two
# Arguments:
#   $1 - runner user/login
#   $2 - optional preloaded identity-aliases.conf content
# Output: canonical on line 1, aliases one per following line
#######################################
_dashboard_identity_aliases() {
	local runner_user="$1"
	local preloaded_config="${2:-}"
	local has_preloaded_config=0
	if [[ $# -ge 2 ]]; then
		has_preloaded_config=1
	fi
	local normalized_runner
	normalized_runner=$(_normalize_dashboard_identity_token "$runner_user")
	local canonical="$normalized_runner"
	local aliases="$normalized_runner"
	local config_content=""
	if ((has_preloaded_config)); then
		config_content="$preloaded_config"
	else
		local config_path
		config_path=$(_dashboard_identity_alias_config_path)
		if [[ -n "$config_path" ]]; then
			config_content=$(<"$config_path")
		fi
	fi

	if [[ -n "$config_content" ]]; then
		local line lhs rhs alias normalized_lhs normalized_alias candidate_aliases _identity_alias_parts
		while IFS= read -r line || [[ -n "$line" ]]; do
			line="${line%%#*}"
			[[ "$line" == *"="* ]] || continue
			lhs="${line%%=*}"
			rhs="${line#*=}"
			normalized_lhs=$(_normalize_dashboard_identity_token "$lhs")
			[[ -n "$normalized_lhs" ]] || continue
			candidate_aliases="$normalized_lhs"
			IFS=',' read -r -a _identity_alias_parts <<<"$rhs"
			for alias in "${_identity_alias_parts[@]}"; do
				normalized_alias=$(_normalize_dashboard_identity_token "$alias")
				[[ -n "$normalized_alias" ]] || continue
				candidate_aliases="${candidate_aliases}"$'\n'"${normalized_alias}"
			done
			if printf '%s\n' "$candidate_aliases" | grep -Fx -- "$normalized_runner" >/dev/null 2>&1; then
				canonical="$normalized_lhs"
				aliases="$candidate_aliases"
				break
			fi
		done <<<"$config_content"
	fi

	printf '%s\n' "$canonical"
	printf '%s\n' "$aliases" | awk 'NF && !seen[$0]++'
	return 0
}

#######################################
# Resolve a runner to the canonical dashboard identity only.
# Arguments:
#   $1 - runner user/login
# Output: canonical identity
#######################################
_resolve_dashboard_canonical_identity() {
	local runner_user="$1"
	_dashboard_identity_aliases "$runner_user" | sed -n '1p'
	return 0
}
