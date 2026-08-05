#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime-risk and testing-evidence classification for full-loop PR bodies.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_FULL_LOOP_RISK_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_RISK_LIB_LOADED=1
_full_loop_runtime_verified_marker="runtime-verified"

# Normalize a caller-supplied risk level to the spelling used in PR bodies.
_normalize_runtime_risk() {
	local requested_risk="${1:-}"
	local normalized=""
	normalized=$(printf '%s' "$requested_risk" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
	critical) printf 'Critical\n' ;;
	high) printf 'High\n' ;;
	medium) printf 'Medium\n' ;;
	low) printf 'Low\n' ;;
	*)
		print_error "Invalid --risk-level '${requested_risk}'. Expected Critical, High, Medium, or Low."
		return 1
		;;
	esac
	return 0
}

# Normalize an explicit testing-evidence level to the spelling used in PR bodies.
_normalize_runtime_testing_level() {
	local requested_testing_level="${1:-}"
	local normalized=""
	normalized=$(printf '%s' "$requested_testing_level" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
	"$_full_loop_runtime_verified_marker" | self-assessed) printf '%s\n' "$normalized" ;;
	*)
		print_error "Invalid --testing-level '${requested_testing_level}'. Expected ${_full_loop_runtime_verified_marker} or self-assessed."
		return 1
		;;
	esac
	return 0
}

# Reject invalid caller-supplied metadata before commit-and-pr mutates Git state.
# Empty values remain deferred because their defaults require the final diff.
_validate_explicit_pr_metadata() {
	local requested_risk="${1:-}"
	local requested_testing_level="${2:-}"

	if [[ -n "$requested_risk" ]]; then
		_normalize_runtime_risk "$requested_risk" >/dev/null || return 1
	fi
	if [[ -n "$requested_testing_level" ]]; then
		_normalize_runtime_testing_level "$requested_testing_level" >/dev/null || return 1
	fi
	return 0
}

_runtime_risk_rank() {
	local runtime_risk="$1"
	case "$runtime_risk" in
	Critical) printf '4\n' ;;
	High) printf '3\n' ;;
	Medium) printf '2\n' ;;
	Low) printf '1\n' ;;
	*) return 1 ;;
	esac
	return 0
}

# Low-risk paths are the non-runtime categories listed in full-loop.md.
_runtime_path_is_low() {
	local path="$1"
	case "$path" in
	*.md | *.mdx | *.rst | *.adoc | docs/*.txt | */docs/*.txt | README | README.* | */README | */README.* | CHANGELOG* | */CHANGELOG* | LICENSE | LICENSE.* | */LICENSE | */LICENSE.* | \
		*.d.ts | *.d.mts | *.d.cts | *.pyi | */tests/* | */test/* | */__tests__/* | test-* | test_* | *_test.* | *.test.* | *.spec.* | \
		.github/* | .qlty/* | .shellcheckrc | */.shellcheckrc | .markdownlint* | */.markdownlint* | .yamllint* | */.yamllint* | \
		.eslintrc* | */.eslintrc* | eslint.config.* | */eslint.config.* | .prettierrc* | */.prettierrc* | prettier.config.* | */prettier.config.* | \
		.stylelintrc* | */.stylelintrc* | stylelint.config.* | */stylelint.config.* | biome.json | */biome.json | *lint*.config.* | *linters*.conf | \
		.agents/prompts/*)
		return 0
		;;
	*) return 1 ;;
	esac
}

_runtime_paths_are_low() {
	local files_changed="${1:-}"
	local path=""
	local saw_path=0
	while IFS= read -r path; do
		path="${path#"${path%%[![:space:]]*}"}"
		[[ -z "$path" ]] && continue
		saw_path=1
		if ! _runtime_path_is_low "$path"; then
			return 1
		fi
	done < <(printf '%s\n' "$files_changed" | tr ',' '\n')
	[[ "$saw_path" -eq 1 ]] && return 0
	return 1
}

# Print only runtime-relevant path names from the comma-separated PR file list.
# Low-only path names must not contribute policy keywords to a mixed diff.
_runtime_paths_keyword_context() {
	local files_changed="${1:-}"
	local path=""
	while IFS= read -r path; do
		path="${path#"${path%%[![:space:]]*}"}"
		[[ -z "$path" ]] && continue
		if ! _runtime_path_is_low "$path"; then
			printf '%s\n' "$path"
		fi
	done < <(printf '%s\n' "$files_changed" | tr ',' '\n')
	return 0
}

# Print diff hunks only for runtime-relevant files. Documentation, tests,
# fixtures, and linter configuration remain evidence that the branch changed,
# but their prose must not raise the risk of unrelated runtime code.
_runtime_diff_keyword_context() {
	local base_ref="$1"
	local path=""
	git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1 || return 1
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		if ! _runtime_path_is_low "$path"; then
			git diff --unified=0 --no-color --no-ext-diff "${base_ref}..HEAD" -- "$path" 2>/dev/null || true
		fi
	done < <(git diff --name-only "${base_ref}..HEAD" 2>/dev/null)
	return 0
}

# Return success only when every changed content line is visibly a comment or
# whitespace. Ambiguous block-comment edits fail upward to Medium.
_runtime_diff_is_comments_only() {
	local base_ref="$1"
	local line="" content="" trimmed="" trailing="" current_path=""
	local block_kind="" c_block_end="*/" html_block_end="-->"
	local saw_change=0
	git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1 || return 1

	while IFS= read -r line; do
		case "$line" in
		"+++ b/"*)
			[[ -n "$block_kind" ]] && return 1
			current_path="${line#+++ b/}"
			continue
			;;
		"@@"*)
			[[ -n "$block_kind" ]] && return 1
			continue
			;;
		"+++ /dev/null" | "--- /dev/null" | "--- a/"* | "diff --git "* | "index "* | "new file mode "* | "deleted file mode "*) continue ;;
		+* | -*) ;;
		*) continue ;;
		esac

		saw_change=1
		content="${line:1}"
		trimmed="${content#"${content%%[![:space:]]*}"}"
		[[ -z "$trimmed" ]] && continue

		if [[ -n "$block_kind" ]]; then
			if [[ "$block_kind" == "c" && "$trimmed" == *"$c_block_end"* ]]; then
				trailing="${trimmed#*"$c_block_end"}"
				block_kind=""
			elif [[ "$block_kind" == "html" && "$trimmed" == *"$html_block_end"* ]]; then
				trailing="${trimmed#*"$html_block_end"}"
				block_kind=""
			else
				continue
			fi
			trailing="${trailing#"${trailing%%[![:space:]]*}"}"
			[[ -z "$trailing" ]] && continue
			return 1
		fi

		case "$trimmed" in
		\#!* | \#include* | \#define* | \#if* | \#elif* | \#else* | \#endif* | \#pragma* | \#error* | \#undef*) return 1 ;;
		\#* | //* | -- | --[[:space:]]*) continue ;;
		\;*)
			case "$current_path" in
			*.ini | *.cfg | *.conf) continue ;;
			esac
			return 1
			;;
		"/*"*)
			if [[ "$trimmed" == *"$c_block_end"* ]]; then
				trailing="${trimmed#*"$c_block_end"}"
				trailing="${trailing#"${trailing%%[![:space:]]*}"}"
				[[ -z "$trailing" ]] && continue
				return 1
			fi
			block_kind="c"
			;;
		"<!--"*)
			if [[ "$trimmed" == *"$html_block_end"* ]]; then
				trailing="${trimmed#*"$html_block_end"}"
				trailing="${trailing#"${trailing%%[![:space:]]*}"}"
				[[ -z "$trailing" ]] && continue
				return 1
			fi
			block_kind="html"
			;;
		*) return 1 ;;
		esac
	done < <(git diff --unified=0 --no-color --no-ext-diff "${base_ref}..HEAD" -- 2>/dev/null)

	[[ "$saw_change" -eq 1 && -z "$block_kind" ]] && return 0
	return 1
}

_runtime_context_has_session_pattern() {
	local context="$1"
	if [[ "$context" =~ (^|[^[:alnum:]_])sessions?([^[:alnum:]_]|$) ]]; then
		return 0
	fi
	return 1
}

_runtime_context_has_non_session_critical_pattern() {
	local context="$1"
	if [[ "$context" =~ (^|[^[:alnum:]_])(payments?|billing|auth|authentication|authorization|credentials?|crypto|cryptograph(y|ic|ical)?)([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])data[[:space:]_/-]*delet(e|es|ed|ing|ion)([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])delet(e|es|ed|ing|ion)[[:space:]_/-]*data([^[:alnum:]_]|$) ]]; then
		return 0
	fi
	return 1
}

_runtime_context_has_critical_pattern() {
	local context="$1"
	_runtime_context_has_non_session_critical_pattern "$context" && return 0
	_runtime_context_has_session_pattern "$context" && return 0
	return 1
}

# Remove complete single-line string and regular-expression literals. If a
# literal is incomplete or ambiguous, return the original line so classification
# remains fail-closed. Regex literals are recognized only after an expression
# delimiter, which covers array/object/assignment forms without treating division
# or paths as literals.
_runtime_line_without_complete_literals() {
	local line="$1"
	local output="" mode="" character="" next_character=""
	local previous_significant="" escaped=0 index=0 length=${#line}
	while [[ "$index" -lt "$length" ]]; do
		character="${line:$index:1}"
		if [[ -n "$mode" ]]; then
			if [[ "$escaped" -eq 1 ]]; then
				escaped=0
				index=$((index + 1))
				continue
			fi
			if [[ "$character" == "\\" ]]; then
				escaped=1
				index=$((index + 1))
				continue
			fi
			case "$mode" in
			single) [[ "$character" == "'" ]] && mode="" ;;
			double) [[ "$character" == '"' ]] && mode="" ;;
			backtick) [[ "$character" == '`' ]] && mode="" ;;
			regex) [[ "$character" == "/" ]] && mode="" ;;
			esac
			index=$((index + 1))
			continue
		fi

		case "$character" in
		"'") mode="single" ;;
		'"') mode="double" ;;
		'`') mode="backtick" ;;
		"/")
			next_character="${line:$((index + 1)):1}"
			if [[ "$next_character" != "/" && "$next_character" != "*" ]]; then
				case "$previous_significant" in
				"" | "[" | "(" | "{" | "=" | "," | ":" | ";" | "!" | "?" | "&" | "|") mode="regex" ;;
				*) output+="$character" ;;
				esac
			else
				output+="$character"
			fi
			;;
		*) output+="$character" ;;
		esac
		if [[ -z "$mode" && ! "$character" =~ [[:space:]] ]]; then
			previous_significant="$character"
		fi
		index=$((index + 1))
	done

	if [[ -n "$mode" ]]; then
		printf '%s\n' "$line"
	else
		printf '%s\n' "$output"
	fi
	return 0
}

_runtime_context_has_session_operation_pattern() {
	local context="$1"
	if [[ "$context" =~ (^|[^[:alnum:]_])(create|destroy|delete|revoke|rotate|validate|refresh|expire|invalidate|set|clear)[[:space:]_/-]*(session|cookie|token|login|logout|store)([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])(session|cookie|token|login|logout)[[:space:]_/-]*(create|destroy|delete|revoke|rotate|validate|refresh|expire|invalidate|set|clear|store|manager|handler|service)([^[:alnum:]_]|$) ]]; then
		return 0
	fi
	return 1
}

# Raw diff hunks are untyped text. Preserve conservative matching for every
# critical category except the broad `session` noun; for that noun, ignore only
# complete literals that have no adjacent executable session operation.
_runtime_diff_has_critical_pattern() {
	local context="$1"
	local line="" content="" executable_context=""
	while IFS= read -r line; do
		case "$line" in
		"+++ "* | "--- "* | "diff --git "* | "index "* | "@@"*) continue ;;
		+* | -*) content="${line:1}" ;;
		*) continue ;;
		esac
		_runtime_context_has_non_session_critical_pattern "$content" && return 0
		if _runtime_context_has_session_pattern "$content"; then
			executable_context=$(_runtime_line_without_complete_literals "$content") || return 0
			_runtime_context_has_session_pattern "$executable_context" && return 0
			_runtime_context_has_session_operation_pattern "$executable_context" && return 0
		fi
	done <<<"$context"
	return 1
}

_runtime_context_has_high_pattern() {
	local context="$1"
	if [[ "$context" =~ (^|[^[:alnum:]_])(websockets?|sse)([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])server[[:space:]_/-]*sent[[:space:]_/-]*events?([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])poll(ing)?[[:space:]_/-]*(loops?|intervals?)([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])state[[:space:]_/-]*machines?([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])form[[:space:]_/-]*handlers?([^[:alnum:]_]|$) ]] ||
		[[ "$context" =~ (^|[^[:alnum:]_])api[[:space:]_/-]*endpoints?([^[:alnum:]_]|$) ]]; then
		return 0
	fi
	return 1
}

_select_conservative_runtime_risk() {
	local detected_risk="$1"
	local requested_risk="${2:-}"
	local normalized="" detected_rank="" requested_rank=""
	if [[ -z "$requested_risk" ]]; then
		printf '%s\n' "$detected_risk"
		return 0
	fi

	normalized=$(_normalize_runtime_risk "$requested_risk") || return 1
	detected_rank=$(_runtime_risk_rank "$detected_risk") || return 1
	requested_rank=$(_runtime_risk_rank "$normalized") || return 1
	if [[ "$requested_rank" -gt "$detected_rank" ]]; then
		printf '%s\n' "$normalized"
	else
		printf '%s\n' "$detected_risk"
	fi
	return 0
}

# Derive the most conservative runtime-risk level supported by the supplied
# metadata and branch diff. Explicit levels can raise ambiguous classifications
# but cannot downgrade policy patterns. Unmatched runtime changes fail upward to
# Medium; policy-listed non-runtime and comment-only changes remain Low.
# Arguments: requested_risk, files_changed, summary_what, base_ref (optional)
_derive_runtime_risk() {
	local requested_risk="${1:-}"
	local files_changed="${2:-}"
	local summary_what="${3:-}"
	local base_ref="${4:-}"
	local runtime_paths=""
	local context="${summary_what}"
	local diff_context=""
	local runtime_context=""
	local detected_risk="Medium"

	if _runtime_paths_are_low "$files_changed"; then
		detected_risk="Low"
	elif [[ -n "$base_ref" ]] && _runtime_diff_is_comments_only "$base_ref"; then
		detected_risk="Low"
	else
		runtime_paths=$(_runtime_paths_keyword_context "$files_changed") || return 1
		runtime_context="${context} ${runtime_paths}"
		if [[ -n "$base_ref" ]]; then
			if ! diff_context=$(_runtime_diff_keyword_context "$base_ref"); then
				return 1
			fi
		fi
		runtime_context=$(printf '%s' "$runtime_context" | tr '[:upper:]' '[:lower:]')
		diff_context=$(printf '%s' "$diff_context" | tr '[:upper:]' '[:lower:]')
		context="${runtime_context} ${diff_context}"
		if _runtime_context_has_critical_pattern "$runtime_context" ||
			_runtime_diff_has_critical_pattern "$diff_context"; then
			detected_risk="Critical"
		elif _runtime_context_has_high_pattern "$context"; then
			detected_risk="High"
		fi
	fi

	if ! _select_conservative_runtime_risk "$detected_risk" "$requested_risk"; then
		return 1
	fi
	return 0
}

_summary_declares_runtime_verified() {
	local summary_testing="${1:-}"
	local normalized=""
	normalized=$(printf '%s' "$summary_testing" | tr '[:upper:]' '[:lower:]')
	if [[ "$normalized" == *"not ${_full_loop_runtime_verified_marker}"* ]] ||
		[[ "$normalized" == *"not runtime verified"* ]] ||
		[[ "$normalized" == *"no ${_full_loop_runtime_verified_marker}"* ]] ||
		[[ "$normalized" == *"without ${_full_loop_runtime_verified_marker}"* ]]; then
		return 1
	fi
	[[ "$normalized" == *"$_full_loop_runtime_verified_marker"* ]] && return 0
	return 1
}

_runtime_evidence_is_substantive() {
	local summary_testing="${1:-}"
	local normalized="" detail=""
	normalized=$(printf '%s' "$summary_testing" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
	"" | none | n/a | na | self-assessed) return 1 ;;
	esac
	if [[ "$normalized" == *"no additional evidence"* ]] ||
		[[ "$normalized" == *"no evidence"* ]] ||
		[[ "$normalized" == *"no runtime evidence"* ]] ||
		[[ "$normalized" == *"not ${_full_loop_runtime_verified_marker}"* ]] ||
		[[ "$normalized" == *"not runtime verified"* ]]; then
		return 1
	fi
	detail="${normalized//$_full_loop_runtime_verified_marker/}"
	detail=$(printf '%s' "$detail" | tr -d '[:space:][:punct:]')
	[[ -n "$detail" ]] && return 0
	return 1
}

# Resolve testing evidence and enforce the runtime gate. The literal evidence
# marker is machine-readable, while a non-empty detail prevents a bare marker
# from claiming runtime verification without any supporting evidence.
# Arguments: runtime_risk, requested_testing_level, summary_testing
_resolve_runtime_testing_level() {
	local runtime_risk="$1"
	local requested_testing_level="${2:-}"
	local summary_testing="${3:-}"
	local testing_level=""

	if [[ -n "$requested_testing_level" ]]; then
		testing_level=$(_normalize_runtime_testing_level "$requested_testing_level") || return 1
	elif _summary_declares_runtime_verified "$summary_testing"; then
		testing_level="$_full_loop_runtime_verified_marker"
	else
		testing_level="self-assessed"
	fi

	if [[ "$testing_level" == "$_full_loop_runtime_verified_marker" ]] && ! _runtime_evidence_is_substantive "$summary_testing"; then
		print_error "${_full_loop_runtime_verified_marker} requires non-empty testing evidence; PR body generation blocked."
		return 1
	fi

	if [[ "$runtime_risk" == "Critical" || "$runtime_risk" == "High" ]] &&
		[[ "$testing_level" != "$_full_loop_runtime_verified_marker" ]]; then
		print_error "${runtime_risk} runtime risk requires ${_full_loop_runtime_verified_marker} evidence; PR body generation blocked."
		return 1
	fi

	printf '%s\n' "$testing_level"
	return 0
}
