#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Linters — Ratchet Quality Check Sub-Library
# =============================================================================
# Ratchet system extracted from linters-local.sh (GH#21418).
# Tracks anti-pattern counts against the default-branch merge-base. Counts can
# only stay the same or decrease — never increase. The stored snapshot is
# retained for provenance and compatibility, not as the active comparison.
#
# Baseline: .agents/configs/ratchets.json
# Exceptions: .agents/configs/ratchet-exceptions/{pattern}.txt
#
# Usage: source "${SCRIPT_DIR}/linters-local-ratchet.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - ALL_SH_FILES array (populated by collect_shell_files in linters-local.sh)
#   - rg (ripgrep), jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LINTERS_LOCAL_RATCHET_LOADED:-}" ]] && return 0
_LINTERS_LOCAL_RATCHET_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Ratchet Quality Check (t1878)
# =============================================================================
# Tracks anti-pattern counts against a stored baseline. Counts can only stay
# the same or decrease — never increase. Prevents gradual quality regression
# without requiring zero violations immediately.
#
# Usage:
#   linters-local.sh                  # advisory ratchet check
#   linters-local.sh --strict         # blocking ratchet check
#   linters-local.sh --update-baseline # re-count and write new baseline

readonly RATCHET_SCHEMA_VERSION=2
readonly RATCHET_COUNTER_VERSION=2

# _ratchet_step_timeout_seconds: read and validate per-ratchet timeout.
# Returns: timeout seconds via stdout
_ratchet_step_timeout_seconds() {
	local configured="${RATCHET_STEP_TIMEOUT_SECONDS:-120}"
	if [[ ! "$configured" =~ ^[0-9]+$ ]] || [[ "$configured" -lt 1 ]]; then
		configured=120
	fi
	echo "$configured"
	return 0
}

# _ratchet_count_with_progress: run one ratchet counter with progress + timeout.
# Arguments: $1=display_name $2=counter_function $3=scripts_dir_or_empty
# Returns: counter output via stdout, 1 on timeout/counter failure
_ratchet_count_with_progress() {
	local display_name="$1"
	local counter_function="$2"
	local scripts_dir="${3:-}"
	local timeout_seconds
	timeout_seconds=$(_ratchet_step_timeout_seconds)
	local progress_interval=30
	local output_file error_file
	output_file=$(mktemp "${TMPDIR:-/tmp}/ratchet-count.XXXXXX") || return 1
	error_file=$(mktemp "${TMPDIR:-/tmp}/ratchet-count.err.XXXXXX") || {
		rm -f "$output_file"
		return 1
	}

	print_info "Ratchets: counting ${display_name} (timeout ${timeout_seconds}s)..." >&2
	(
		if [[ -n "$scripts_dir" ]]; then
			"$counter_function" "$scripts_dir"
		else
			"$counter_function"
		fi
	) >"$output_file" 2>"$error_file" &
	local counter_pid="$!"
	local start_time elapsed now status result
	start_time=$(date +%s)

	while kill -0 "$counter_pid" 2>"$error_file"; do
		now=$(date +%s)
		elapsed=$((now - start_time))
		if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
			print_error "Ratchets: ${display_name} timed out after ${timeout_seconds}s; rerun with RATCHET_STEP_TIMEOUT_SECONDS=<seconds> for diagnostics" >&2
			kill "$counter_pid" 2>"$error_file"
			if wait "$counter_pid" 2>"$error_file"; then
				status=0
			else
				status=$?
			fi
			rm -f "$output_file" "$error_file"
			return 1
		fi
		if [[ "$elapsed" -gt 0 ]] && [[ $((elapsed % progress_interval)) -eq 0 ]]; then
			print_info "Ratchets: still counting ${display_name} (${elapsed}s elapsed)..." >&2
		fi
		sleep 1
	done

	if wait "$counter_pid"; then
		status=0
	else
		status=$?
	fi
	if [[ "$status" -ne 0 ]]; then
		print_error "Ratchets: ${display_name} counter failed with exit ${status}" >&2
		rm -f "$output_file" "$error_file"
		return 1
	fi

	result=$(tr -d '[:space:]' <"$output_file")
	rm -f "$output_file" "$error_file"
	[[ "$result" =~ ^[0-9]+$ ]] || result=0
	echo "$result"
	return 0
}

# _ratchet_count_bare_positional: count $1-$9 in function bodies (not local assignments)
# Returns: count via stdout
_ratchet_count_bare_positional() {
	local scripts_dir="$1"
	local count=0
	[[ -d "$scripts_dir" ]] || return 1
	count=$(rg '\$[1-9]' --type sh --no-filename "$scripts_dir" 2> /dev/null |
		grep -v 'local.*=.*\$[1-9]' |
		grep -cv '^[[:space:]]*#') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_hardcoded_path: count literal ~/.aidevops or /Users/ in scripts
# Returns: count via stdout
_ratchet_count_hardcoded_path() {
	local scripts_dir="$1"
	local count=0
	[[ -d "$scripts_dir" ]] || return 1
	# Tilde is intentional: we search for the literal string ~/.aidevops in scripts
	# shellcheck disable=SC2088
	count=$(rg '~/.aidevops|/Users/' --type sh --no-filename "$scripts_dir" 2> /dev/null |
		grep -v '^[[:space:]]*#' |
		grep -cv '# ') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_broad_catch: count || true usage
# Returns: count via stdout
_ratchet_count_broad_catch() {
	local scripts_dir="$1"
	local count=0
	[[ -d "$scripts_dir" ]] || return 1
	count=$(rg '\|\| true' --type sh --no-filename "$scripts_dir" 2> /dev/null |
		wc -l | tr -d '[:space:]') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_silent_errors: count 2>/dev/null usage
# Returns: count via stdout
_ratchet_count_silent_errors() {
	local scripts_dir="$1"
	local count=0
	[[ -d "$scripts_dir" ]] || return 1
	count=$(rg '2>/dev/null' --type sh --no-filename "$scripts_dir" 2> /dev/null |
		wc -l | tr -d '[:space:]') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _ratchet_count_missing_return: count files containing a function with no return
# Arguments: $1=scripts_dir
# Returns: count via stdout
_ratchet_count_missing_return() {
	local scripts_dir="$1"
	local shell_files=()
	[[ -d "$scripts_dir" ]] || return 1
	while IFS= read -r file; do
		[[ -n "$file" ]] && shell_files+=("$file")
	done < <(rg --files --type sh "$scripts_dir" | grep -v '/_archive/' | LC_ALL=C sort)

	[[ ${#shell_files[@]} -gt 0 ]] || {
		echo "0"
		return 0
	}
	awk '
		function finish_function() {
			if (in_function && !has_return) file_missing = 1
			in_function = 0
			has_return = 0
		}
		function finish_file() {
			finish_function()
			if (file_missing) missing++
		}
		FNR == 1 {
			if (NR > 1) finish_file()
			file_missing = 0
		}
		/^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{$/ {
			finish_function()
			in_function = 1
			next
		}
		in_function && /return[[:space:]]+([0-9]+|\$)/ { has_return = 1 }
		in_function && /^}$/ { finish_function() }
		END { finish_file(); print missing + 0 }
	' "${shell_files[@]}"
	return 0
}

# _ratchet_load_exceptions: count non-comment lines in an exceptions file
# Arguments: $1=exceptions_file
# Returns: exception count via stdout
_ratchet_load_exceptions() {
	local exceptions_file="$1"
	local count=0
	if [[ -f "$exceptions_file" ]]; then
		count=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$exceptions_file" 2>/dev/null || echo "0")
		[[ "$count" =~ ^[0-9]+$ ]] || count=0
	fi
	echo "$count"
	return 0
}

# _ratchet_check_pattern: compare current count against baseline for one pattern
# Arguments: $1=name $2=current $3=baseline $4=exceptions $5=strict_mode
# Returns: 0=pass, 1=regressed
_ratchet_check_pattern() {
	local name="$1"
	local current="$2"
	local baseline="$3"
	local exceptions="$4"
	local strict_mode="$5"

	local effective_current=$((current - exceptions))
	local effective_baseline=$((baseline - exceptions))
	[[ "$effective_current" -lt 0 ]] && effective_current=0
	[[ "$effective_baseline" -lt 0 ]] && effective_baseline=0

	if [[ "$effective_current" -lt "$effective_baseline" ]]; then
		local improvement=$((effective_baseline - effective_current))
		print_success "  PASS: ${name} ${effective_baseline} -> ${effective_current} (improved by ${improvement})"
		return 0
	elif [[ "$effective_current" -eq "$effective_baseline" ]]; then
		print_success "  PASS: ${name} ${effective_current} (no change)"
		return 0
	else
		local regression=$((effective_current - effective_baseline))
		if [[ "$strict_mode" == "true" ]]; then
			print_error "  FAIL: ${name} ${effective_baseline} -> ${effective_current} (regressed by ${regression}) — remove the introduced occurrence"
		else
			print_warning "  WARN: ${name} ${effective_baseline} -> ${effective_current} (regressed by ${regression}) — advisory only (use --strict to block)"
		fi
		return 1
	fi
}

# _ratchet_count_all: count current values for all 5 ratchet patterns
# Arguments: $1=scripts_dir
# Outputs: 5 space-separated counts: bare hardcoded broad silent missing
# Returns: 0 always
_ratchet_count_all() {
	local scripts_dir="$1"
	local count_bare count_hardcoded count_broad count_silent count_missing
	count_bare=$(_ratchet_count_with_progress "bare_positional_params" "_ratchet_count_bare_positional" "$scripts_dir") || return 1
	count_hardcoded=$(_ratchet_count_with_progress "hardcoded_aidevops_path" "_ratchet_count_hardcoded_path" "$scripts_dir") || return 1
	count_broad=$(_ratchet_count_with_progress "broad_catch_or_true" "_ratchet_count_broad_catch" "$scripts_dir") || return 1
	count_silent=$(_ratchet_count_with_progress "silent_errors" "_ratchet_count_silent_errors" "$scripts_dir") || return 1
	count_missing=$(_ratchet_count_with_progress "missing_return_files" "_ratchet_count_missing_return" "$scripts_dir") || return 1
	echo "$count_bare $count_hardcoded $count_broad $count_silent $count_missing"
	return 0
}

# _ratchet_resolve_base_ref: resolve a verified default-branch merge-base.
# Arguments: $1=repo_root
# Returns: full commit SHA via stdout, 1 when no safe base is available.
_ratchet_resolve_base_ref() {
	local repo_root="$1"
	local configured_ref="${RATCHET_BASE_REF:-}"
	local default_ref=""
	local candidate=""
	local base_ref=""

	if [[ -n "$configured_ref" ]]; then
		git -C "$repo_root" rev-parse --verify "${configured_ref}^{commit}" 2> /dev/null
		return $?
	fi

	default_ref=$(git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || :)
	for candidate in "$default_ref" origin/main main origin/master master; do
		[[ -n "$candidate" ]] || continue
		base_ref=$(git -C "$repo_root" merge-base HEAD "$candidate" 2> /dev/null || :)
		if [[ -n "$base_ref" ]]; then
			printf '%s\n' "$base_ref"
			return 0
		fi
	done
	return 1
}

# _ratchet_make_temp_dir: create an internal comparison directory.
# Returns: directory path via stdout.
_ratchet_make_temp_dir() {
	local temp_parent="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"
	local temp_dir=""
	temp_dir=$(mktemp -d "${temp_parent%/}/ratchet-tree.XXXXXX") || return 1
	printf '%s\n' "$temp_dir"
	return 0
}

# _ratchet_count_ref: count all patterns in one verified Git commit.
# Arguments: $1=repo_root $2=commit_ref
# Returns: five space-separated counts via stdout.
_ratchet_count_ref() {
	local repo_root="$1"
	local commit_ref="$2"
	local temp_dir=""
	local counts=""
	temp_dir=$(_ratchet_make_temp_dir) || return 1

	if ! git -C "$repo_root" archive "$commit_ref" -- .agents/scripts .gitignore | tar -x -C "$temp_dir"; then
		print_error "Ratchets: failed to materialize base tree ${commit_ref}" >&2
		rm -rf "$temp_dir"
		return 1
	fi
	if ! counts=$(_ratchet_count_all "${temp_dir}/.agents/scripts"); then
		rm -rf "$temp_dir"
		return 1
	fi
	rm -rf "$temp_dir"
	printf '%s\n' "$counts"
	return 0
}

# _ratchet_counts_increased: detect whether any current count exceeds a snapshot.
# Arguments: $1=current_counts $2=previous_counts
# Returns: 0 when an increase exists, 1 otherwise.
_ratchet_counts_increased() {
	local current_counts="$1"
	local previous_counts="$2"
	local current_bare current_hardcoded current_broad current_silent current_missing
	local previous_bare previous_hardcoded previous_broad previous_silent previous_missing
	read -r current_bare current_hardcoded current_broad current_silent current_missing <<<"$current_counts"
	read -r previous_bare previous_hardcoded previous_broad previous_silent previous_missing <<<"$previous_counts"
	if ((current_bare > previous_bare || current_hardcoded > previous_hardcoded || current_broad > previous_broad || current_silent > previous_silent || current_missing > previous_missing)); then
		return 0
	fi
	return 1
}

# _ratchet_verify_update_tree: ensure snapshot counts bind to committed scripts.
# Arguments: $1=repo_root
# Returns: 0 when the scripts tree is clean, 1 otherwise.
_ratchet_verify_update_tree() {
	local repo_root="$1"
	local untracked=""
	if ! git -C "$repo_root" diff --quiet -- .agents/scripts || ! git -C "$repo_root" diff --cached --quiet -- .agents/scripts; then
		print_error "Ratchets: commit script changes before updating provenance"
		return 1
	fi
	untracked=$(git -C "$repo_root" ls-files --others --exclude-standard -- .agents/scripts)
	if [[ -n "$untracked" ]]; then
		print_error "Ratchets: untracked script files prevent a verified snapshot"
		return 1
	fi
	return 0
}

# _ratchet_build_baseline_json: render schema-v2 provenance and compatibility counts.
# Arguments: $1=updated $2=source_commit $3=scripts_tree $4=base_commit
#            $5=current_counts $6=previous_schema $7=previous_counter
#            $8=previous_source $9=previous_updated $10=previous_counts
#            $11=migration_json
# Returns: JSON via stdout.
_ratchet_build_baseline_json() {
	local updated="$1" source_commit="$2" scripts_tree="$3" base_commit="$4" current_counts="$5"
	local previous_schema="$6" previous_counter="$7" previous_source="$8" previous_updated="$9"
	local previous_counts="${10}" migration_json="${11}"
	jq -n \
		--argjson schema "$RATCHET_SCHEMA_VERSION" --argjson counter "$RATCHET_COUNTER_VERSION" \
		--arg updated "$updated" --arg source "$source_commit" --arg tree "$scripts_tree" --arg base "$base_commit" \
		--arg current "$current_counts" --argjson previous_schema "$previous_schema" \
		--argjson previous_counter "$previous_counter" --arg previous_source "$previous_source" \
		--arg previous_updated "$previous_updated" --arg previous "$previous_counts" \
		--argjson migration "$migration_json" '
		($current | split(" ") | map(tonumber)) as $c |
		($previous | split(" ") | map(tonumber)) as $p |
		{
			version: $schema,
			counter_version: $counter,
			updated: $updated,
			description: "Compatibility snapshot with verified provenance; active checks compare the working tree with its default-branch merge-base.",
			comparison: {mode: "merge-base", fail_closed_without_base: true},
			provenance: {
				source_commit: $source,
				scripts_tree: $tree,
				comparison_base_commit: $base,
				migration: $migration,
				previous_snapshot: {
					schema_version: $previous_schema, counter_version: $previous_counter,
					source_commit: $previous_source, updated: $previous_updated,
					counts: {bare_positional_params: $p[0], hardcoded_aidevops_path: $p[1], broad_catch_or_true: $p[2], silent_errors: $p[3], missing_return_files: $p[4]}
				}
			},
			ratchets: {
				bare_positional_params: {count: $c[0], description: "Direct positional parameters in function bodies", pattern: "positional_parameter"},
				hardcoded_aidevops_path: {count: $c[1], description: "Literal user-specific framework paths", pattern: "hardcoded_user_path"},
				broad_catch_or_true: {count: $c[2], description: "Broad success fallback", pattern: "broad_success_fallback"},
				silent_errors: {count: $c[3], description: "Discarded standard error", pattern: "discarded_standard_error"},
				missing_return_files: {count: $c[4], description: "Files containing a function without an explicit return", pattern: "functions_without_return"}
			}
		}'
	return $?
}

# _ratchet_write_json_atomically: validate and replace a baseline on one filesystem.
# Arguments: $1=baseline_file $2=new_json
# Returns: 0 on success, 1 without changing the baseline on failure.
_ratchet_write_json_atomically() {
	local baseline_file="$1"
	local new_json="$2"
	local temp_file=""
	temp_file=$(mktemp "${baseline_file}.tmp.XXXXXX") || return 1
	if ! printf '%s\n' "$new_json" >"$temp_file" || ! jq -e . "$temp_file" > /dev/null; then
		rm -f "$temp_file"
		print_error "Ratchets: generated baseline failed validation"
		return 1
	fi
	if ! mv "$temp_file" "$baseline_file"; then
		rm -f "$temp_file"
		print_error "Ratchets: atomic baseline replacement failed"
		return 1
	fi
	return 0
}

# _ratchet_write_baseline: validate and write (or dry-run) a provenance snapshot.
# Arguments: $1=baseline_file $2=repo_root $3=current_counts
# Returns: 0 on success, 1 when provenance or migration evidence is incomplete.
_ratchet_write_baseline() {
	local baseline_file="$1" repo_root="$2" current_counts="$3"
	local previous_schema=0 previous_counter=1 previous_counts="0 0 0 0 0"
	local previous_source="" previous_updated="" source_commit="" scripts_tree="" base_commit=""
	local verified_counts="" migration_json="null" migration_reason="" new_json="" now=""

	[[ -f "$baseline_file" ]] && previous_schema=$(jq -r '.version // 0' "$baseline_file" 2> /dev/null || printf '0')
	[[ -f "$baseline_file" ]] && previous_counter=$(jq -r '.counter_version // 1' "$baseline_file" 2> /dev/null || printf '1')
	[[ -f "$baseline_file" ]] && previous_counts=$(_ratchet_load_baselines "$baseline_file")
	[[ -f "$baseline_file" ]] && previous_updated=$(jq -r '.updated // ""' "$baseline_file" 2> /dev/null || :)
	[[ -f "$baseline_file" ]] && previous_source=$(jq -r '.provenance.source_commit // ""' "$baseline_file" 2> /dev/null || :)

	_ratchet_verify_update_tree "$repo_root" || return 1
	source_commit=$(git -C "$repo_root" rev-parse HEAD 2> /dev/null) || return 1
	scripts_tree=$(git -C "$repo_root" rev-parse 'HEAD:.agents/scripts' 2> /dev/null) || return 1
	base_commit=$(_ratchet_resolve_base_ref "$repo_root") || {
		print_error "Ratchets: baseline update requires a verified default-branch base"
		return 1
	}
	verified_counts=$(_ratchet_count_ref "$repo_root" "$source_commit") || return 1
	if [[ "$verified_counts" != "$current_counts" ]]; then
		print_error "Ratchets: working-tree counts do not match committed source ${source_commit}"
		return 1
	fi

	if [[ "$previous_schema" -ne "$RATCHET_SCHEMA_VERSION" ]] || _ratchet_counts_increased "$current_counts" "$previous_counts"; then
		if [[ "${RATCHET_ALLOW_MIGRATION:-false}" != "true" ]]; then
			print_error "Ratchets: snapshot increases/schema migration require --migrate-baseline with recorded evidence"
			return 1
		fi
		migration_reason="${RATCHET_MIGRATION_REASON:-}"
		[[ -n "$migration_reason" ]] || {
			print_error "Ratchets: RATCHET_MIGRATION_REASON is required for migration"
			return 1
		}
		[[ -n "$previous_source" ]] || previous_source="${RATCHET_PREVIOUS_SOURCE_COMMIT:-}"
		git -C "$repo_root" rev-parse --verify "${previous_source}^{commit}" > /dev/null 2>&1 || {
			print_error "Ratchets: previous source commit is missing or unavailable"
			return 1
		}
		migration_json=$(jq -n --arg reason "$migration_reason" --arg source "$previous_source" \
			--argjson schema "$previous_schema" --argjson counter "$previous_counter" \
			'{reason: $reason, previous_source_commit: $source, previous_schema_version: $schema, previous_counter_version: $counter}') || return 1
	else
		migration_json=$(jq -c '.provenance.migration // null' "$baseline_file") || return 1
	fi

	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	new_json=$(_ratchet_build_baseline_json "$now" "$source_commit" "$scripts_tree" "$base_commit" "$current_counts" \
		"$previous_schema" "$previous_counter" "$previous_source" "$previous_updated" "$previous_counts" "$migration_json") || return 1
	if [[ "${RATCHET_DRY_RUN:-false}" == "true" ]]; then
		print_info "Ratchets: --dry-run mode, validated baseline follows:"
		printf '%s\n' "$new_json" | jq -r '.ratchets | to_entries[] | "  \(.key): \(.value.count)"'
		return 0
	fi
	_ratchet_write_json_atomically "$baseline_file" "$new_json" || return 1
	print_success "Ratchets: baseline provenance updated in $baseline_file"
	printf '%s\n' "$new_json" | jq -r '.ratchets | to_entries[] | "  \(.key): \(.value.count)"'
	return 0
}

# _ratchet_load_baselines: read 5 baseline counts from the JSON baseline file
# Arguments: $1=baseline_file
# Outputs: 5 space-separated counts: bare hardcoded broad silent missing
# Returns: 0 always
_ratchet_load_baselines() {
	local baseline_file="$1"
	local baseline_bare baseline_hardcoded baseline_broad baseline_silent baseline_missing
	baseline_bare=$(jq -r '.ratchets.bare_positional_params.count // 0' "$baseline_file" 2> /dev/null) || baseline_bare=0
	baseline_hardcoded=$(jq -r '.ratchets.hardcoded_aidevops_path.count // 0' "$baseline_file" 2> /dev/null) || baseline_hardcoded=0
	baseline_broad=$(jq -r '.ratchets.broad_catch_or_true.count // 0' "$baseline_file" 2> /dev/null) || baseline_broad=0
	baseline_silent=$(jq -r '.ratchets.silent_errors.count // 0' "$baseline_file" 2> /dev/null) || baseline_silent=0
	baseline_missing=$(jq -r '.ratchets.missing_return_files.count // 0' "$baseline_file" 2> /dev/null) || baseline_missing=0
	echo "$baseline_bare $baseline_hardcoded $baseline_broad $baseline_silent $baseline_missing"
	return 0
}

# _ratchet_load_all_exceptions: load exception counts for all 5 patterns
# Arguments: $1=exceptions_dir
# Outputs: 5 space-separated exception counts: bare hardcoded broad silent missing
# Returns: 0 always
_ratchet_load_all_exceptions() {
	local exceptions_dir="$1"
	local exc_bare exc_hardcoded exc_broad exc_silent exc_missing
	exc_bare=$(_ratchet_load_exceptions "${exceptions_dir}/bare_positional_params.txt")
	exc_hardcoded=$(_ratchet_load_exceptions "${exceptions_dir}/hardcoded_aidevops_path.txt")
	exc_broad=$(_ratchet_load_exceptions "${exceptions_dir}/broad_catch_or_true.txt")
	exc_silent=$(_ratchet_load_exceptions "${exceptions_dir}/silent_errors.txt")
	exc_missing=$(_ratchet_load_exceptions "${exceptions_dir}/missing_return_files.txt")
	echo "$exc_bare $exc_hardcoded $exc_broad $exc_silent $exc_missing"
	return 0
}

# _ratchet_run_checks: run all 5 pattern checks and report aggregate result
# Arguments: $1=strict_mode $2=count_bare $3=count_hardcoded $4=count_broad $5=count_silent $6=count_missing
#            $7=baseline_bare $8=baseline_hardcoded $9=baseline_broad $10=baseline_silent $11=baseline_missing
#            $12=exc_bare $13=exc_hardcoded $14=exc_broad $15=exc_silent $16=exc_missing
# Returns: 0 if no regressions (or non-strict), 1 if regressions in strict mode
_ratchet_run_checks() {
	local strict_mode="$1"
	local count_bare="$2" count_hardcoded="$3" count_broad="$4" count_silent="$5" count_missing="$6"
	local baseline_bare="$7" baseline_hardcoded="$8" baseline_broad="$9" baseline_silent="${10}" baseline_missing="${11}"
	local exc_bare="${12}" exc_hardcoded="${13}" exc_broad="${14}" exc_silent="${15}" exc_missing="${16}"
	local ratchet_failures=0

	_ratchet_check_pattern "bare_positional_params" "$count_bare" "$baseline_bare" "$exc_bare" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "hardcoded_aidevops_path" "$count_hardcoded" "$baseline_hardcoded" "$exc_hardcoded" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "broad_catch_or_true" "$count_broad" "$baseline_broad" "$exc_broad" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "silent_errors" "$count_silent" "$baseline_silent" "$exc_silent" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))
	_ratchet_check_pattern "missing_return_files" "$count_missing" "$baseline_missing" "$exc_missing" "$strict_mode" || ratchet_failures=$((ratchet_failures + 1))

	if [[ "$ratchet_failures" -eq 0 ]]; then
		print_success "Ratchets: all 5 patterns passing (no regressions)"
		return 0
	fi

	if [[ "$strict_mode" == "true" ]]; then
		print_error "Ratchets: ${ratchet_failures} pattern(s) regressed against the verified merge-base"
		return 1
	fi

	print_warning "Ratchets: ${ratchet_failures} pattern(s) regressed against the verified merge-base (advisory — use --strict to block)"
	return 0
}

# _ratchet_validate_baseline_config: require the active schema and counter version.
# Arguments: $1=baseline_file
# Returns: 0 when compatible, 1 with an actionable diagnostic otherwise.
_ratchet_validate_baseline_config() {
	local baseline_file="$1"
	if ! jq -e --argjson schema "$RATCHET_SCHEMA_VERSION" --argjson counter "$RATCHET_COUNTER_VERSION" \
		'.version == $schema and .counter_version == $counter and .comparison.mode == "merge-base" and (.provenance.source_commit | type == "string")' \
		"$baseline_file" > /dev/null 2>&1; then
		print_error "Ratchets: baseline schema/counter mismatch; run the explicit migration workflow"
		return 1
	fi
	return 0
}

# check_ratchets: main ratchet check function
# Arguments: none (reads RATCHET_UPDATE_BASELINE and RATCHET_STRICT from env)
# Returns: 0 if all ratchets pass, 1 if any regressed (only blocks in strict mode)
check_ratchets() {
	echo -e "${BLUE}Checking Ratchet Quality Gates (t1878)...${NC}"

	local repo_root="" scripts_dir="" baseline_file="" exceptions_dir=""
	local strict_mode="${RATCHET_STRICT:-false}"
	repo_root=$(git rev-parse --show-toplevel 2> /dev/null) || {
		print_error "Ratchets: repository root unavailable"
		return 1
	}
	scripts_dir="${repo_root}/.agents/scripts"
	baseline_file="${repo_root}/.agents/configs/ratchets.json"
	exceptions_dir="${repo_root}/.agents/configs/ratchet-exceptions"

	if ! command -v rg &>/dev/null; then
		print_warning "Ratchets: rg (ripgrep) not installed — skipping (install: brew install ripgrep)"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "Ratchets: jq not installed — skipping (install: brew install jq)"
		return 0
	fi

	# Count current values for all patterns
	local counts count_bare count_hardcoded count_broad count_silent count_missing
	if ! counts=$(_ratchet_count_all "$scripts_dir"); then
		print_error "Ratchets: aborted because a ratchet counter failed or timed out"
		return 1
	fi
	read -r count_bare count_hardcoded count_broad count_silent count_missing <<<"$counts"

	# --update-baseline / --init-baseline: write new baseline and exit
	if [[ "${RATCHET_UPDATE_BASELINE:-false}" == "true" ]]; then
		_ratchet_write_baseline "$baseline_file" "$repo_root" "$counts"
		return $?
	fi

	if [[ ! -f "$baseline_file" ]]; then
		if [[ "$strict_mode" == "true" ]]; then
			print_error "Ratchets: no provenance config found at $baseline_file"
			return 1
		fi
		print_warning "Ratchets: no provenance config found at $baseline_file"
		return 0
	fi
	_ratchet_validate_baseline_config "$baseline_file" || return 1

	local base_ref="" base_counts="" exceptions=""
	local baseline_bare baseline_hardcoded baseline_broad baseline_silent baseline_missing
	local exc_bare exc_hardcoded exc_broad exc_silent exc_missing
	base_ref=$(_ratchet_resolve_base_ref "$repo_root") || {
		if [[ "$strict_mode" == "true" ]]; then
			print_error "Ratchets: default-branch merge-base unavailable; strict comparison is incomplete"
			return 1
		fi
		print_warning "Ratchets: default-branch merge-base unavailable; advisory comparison skipped"
		return 0
	}
	print_info "Ratchets: comparing working tree with ${base_ref} (counter v${RATCHET_COUNTER_VERSION})"
	base_counts=$(_ratchet_count_ref "$repo_root" "$base_ref") || {
		print_error "Ratchets: failed to count the verified base tree"
		return 1
	}
	exceptions=$(_ratchet_load_all_exceptions "$exceptions_dir")
	read -r baseline_bare baseline_hardcoded baseline_broad baseline_silent baseline_missing <<<"$base_counts"
	read -r exc_bare exc_hardcoded exc_broad exc_silent exc_missing <<<"$exceptions"

	_ratchet_run_checks "$strict_mode" \
		"$count_bare" "$count_hardcoded" "$count_broad" "$count_silent" "$count_missing" \
		"$baseline_bare" "$baseline_hardcoded" "$baseline_broad" "$baseline_silent" "$baseline_missing" \
		"$exc_bare" "$exc_hardcoded" "$exc_broad" "$exc_silent" "$exc_missing"
	return $?
}
