#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Validate regression evidence for PRs that claim platform-specific fixes.

set -euo pipefail

_platform_evidence_usage() {
	cat <<'EOF'
Usage: platform-fix-regression-evidence.sh --title TITLE --body-file FILE --files-file FILE

The files file must contain one changed path per line.
EOF
	return 0
}

_platform_evidence_die() {
	local message="$1"
	printf 'platform regression evidence: %s\n' "$message" >&2
	return 1
}

_platform_fix_triggered() {
	local metadata="$1"
	printf '%s\n' "$metadata" | grep -qiE '(^|[^[:alnum:]_])(linux|ubuntu|systemd|cron|macos|darwin|bash[[:space:]]+3[.]2|portability|coreutils|mktemp|stat|readlink|getent)([^[:alnum:]_]|$)'
	return $?
}

_platform_changed_test() {
	local files_file="$1"
	local path=""
	while IFS= read -r path; do
		case "$path" in
		.agents/scripts/tests/*)
			printf '%s\n' "$path"
			return 0
			;;
		esac
	done <"$files_file"
	return 1
}

_platform_docs_only() {
	local files_file="$1"
	local path=""
	local saw_path=0
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		saw_path=1
		case "$path" in
		*.md | *.mdx | *.rst | docs/* | todo/*) ;;
		*) return 1 ;;
		esac
	done <"$files_file"
	[[ "$saw_path" -eq 1 ]] || return 1
	return 0
}

_platform_has_regression_evidence() {
	local body_file="$1"
	local line=""
	local in_section=0
	local rationale=""
	local normalized=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		if printf '%s\n' "$line" | grep -qiE '^[[:space:]]*#{1,6}[[:space:]]+Regression[[:space:]]+Evidence[[:space:]]*:?[[:space:]]*$'; then
			in_section=1
			continue
		fi
		if [[ "$in_section" -eq 1 ]] && printf '%s\n' "$line" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]+'; then
			break
		fi
		if [[ "$in_section" -eq 1 ]] && [[ -n "${line//[[:space:]]/}" ]]; then
			case "$line" in
			'<!--'*'-->') ;;
			*) rationale="${rationale} ${line}" ;;
			esac
		fi
	done <"$body_file"

	normalized=$(printf '%s' "$rationale" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]`*_.,:;-')
	case "$normalized" in
	"" | n/a | na | none | tbd | todo) return 1 ;;
	esac
	[[ "${#rationale}" -ge 20 ]] || return 1
	return 0
}

main() {
	local -a args=("$@")
	local title=""
	local body_file=""
	local files_file=""
	local body=""
	local changed_test=""
	local arg=""
	local arg_count="${#args[@]}"
	local index=0

	while [[ "$index" -lt "$arg_count" ]]; do
		arg="${args[$index]}"
		case "$arg" in
		--title)
			((index += 1))
			[[ "$index" -lt "$arg_count" ]] || {
				_platform_evidence_die '--title requires a value'
				return 1
			}
			title="${args[$index]}"
			;;
		--body-file)
			((index += 1))
			[[ "$index" -lt "$arg_count" ]] || {
				_platform_evidence_die '--body-file requires a value'
				return 1
			}
			body_file="${args[$index]}"
			;;
		--files-file)
			((index += 1))
			[[ "$index" -lt "$arg_count" ]] || {
				_platform_evidence_die '--files-file requires a value'
				return 1
			}
			files_file="${args[$index]}"
			;;
		-h | --help)
			_platform_evidence_usage
			return 0
			;;
		*)
			_platform_evidence_die "unknown argument: $arg"
			return 1
			;;
		esac
		((index += 1))
	done

	[[ -n "$title" ]] || {
		_platform_evidence_die '--title is required'
		return 1
	}
	[[ -r "$body_file" ]] || {
		_platform_evidence_die 'body file is missing or unreadable'
		return 1
	}
	[[ -r "$files_file" ]] || {
		_platform_evidence_die 'changed-files file is missing or unreadable'
		return 1
	}

	body=$(<"$body_file")
	if ! _platform_fix_triggered "${title}"$'\n'"${body}"; then
		printf 'platform regression evidence: not required (no platform-fix terms)\n'
		return 0
	fi
	if _platform_docs_only "$files_file"; then
		printf 'platform regression evidence: not required (docs-only changes)\n'
		return 0
	fi
	if changed_test=$(_platform_changed_test "$files_file"); then
		printf 'platform regression evidence: passed (changed %s)\n' "$changed_test"
		return 0
	fi
	if _platform_has_regression_evidence "$body_file"; then
		printf 'platform regression evidence: passed (PR rationale supplied)\n'
		return 0
	fi

	printf '%s\n' '::error::Platform-fix PRs must change a test under .agents/scripts/tests/ or include a non-empty "## Regression Evidence" rationale explaining why automated regression is not possible.' >&2
	printf '%s\n' 'See .agents/reference/bash-compat.md and todo/plans/shell-portability-hardening.md.' >&2
	return 1
}

main "$@"
