#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# issue-body-format-helper.sh — structural lint for AI-composed issue bodies (GH#21991)
#
# Checks whether a --description body passed to claim-task-id.sh (or used as
# an issue body directly) is structurally worker-ready. Catches bodies that
# have useful content but inconsistent or missing headings before publication.
#
# Usage:
#   issue-body-format-helper.sh check     <body-text>
#   issue-body-format-helper.sh normalize <body-text>
#   issue-body-format-helper.sh help
#
# Exit codes (check):
#   0 — body passes all checks (or has advisory warnings only)
#   1 — body is non-dispatchable: missing both file scope and How section,
#         OR missing acceptance criteria. Controllable by env var.
#   2 — usage error
#
# Environment:
#   AIDEVOPS_BODY_FORMAT_STRICT=1  — treat non-dispatchable as hard error (default: 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	source "$SCRIPT_DIR/shared-constants.sh"
fi

# Inline fallbacks if shared-constants not sourced
if ! command -v log_info >/dev/null 2>&1; then
	log_info()  { printf '[INFO]  %s\n' "$*" >&2; return 0; }
	log_warn()  { printf '[WARN]  %s\n' "$*" >&2; return 0; }
	log_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
fi

# ---------------------------------------------------------------------------
# Structural signal detectors
# Each returns 0 (found) or 1 (not found).
# ---------------------------------------------------------------------------

# Only the execution-consumable canonical contract counts as ready.
_ibfh_has_file_scope() {
	local body="$1"
	bash "$SCRIPT_DIR/brief-readiness-helper.sh" scope-check "$body" >/dev/null 2>&1
	return $?
}

# _ibfh_has_acceptance: body contains acceptance-criteria section or checklist.
_ibfh_has_acceptance() {
	local body="$1"
	if printf '%s\n' "$body" | grep -qiE \
		'(^##+ Acceptance|^- \[[ xX]\])' 2>/dev/null; then
		return 0
	fi
	return 1
}

# _ibfh_has_verification: body contains a verification section or shell command block.
_ibfh_has_verification() {
	local body="$1"
	if printf '%s\n' "$body" | grep -qiE \
		'(^##+ Verification|^```(bash|sh|shell)?)' 2>/dev/null; then
		return 0
	fi
	return 1
}

# _ibfh_has_how_section: body contains an implementation guidance section.
_ibfh_has_how_section() {
	local body="$1"
	if printf '%s\n' "$body" | grep -qiE \
		'(^##+ How|^##+ Implementation|^##+ Worker Guidance)' 2>/dev/null; then
		return 0
	fi
	return 1
}

# _ibfh_has_reference_pattern: body contains a reference pattern hint.
_ibfh_has_reference_pattern() {
	local body="$1"
	if printf '%s\n' "$body" | grep -qiE \
		'(^##+ Reference( pattern)?|[Mm]odel on |[Ff]ollow pattern)' 2>/dev/null; then
		return 0
	fi
	return 1
}

# _ibfh_heading_count: emit the number of ## headings in the body.
_ibfh_heading_count() {
	local body="$1"
	local count=0
	count=$(printf '%s\n' "$body" | grep -cE '^##' 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%d\n' "$count"
	return 0
}

# _ibfh_has_escaped_markdown_newlines: detect issue bodies where Markdown
# structure was passed as literal "\n" text instead of real newlines. Keep the
# trigger structural so incidental prose like "the string \n means newline" is
# not rewritten.
_ibfh_has_escaped_markdown_newlines() {
	local body="$1"
	case "$body" in
	*'\n## '* | *'\n### '* | *'\n- '* | *'\n```'* | *'\n\n'*)
		return 0
		;;
	esac
	return 1
}

# _ibfh_decode_escaped_markdown_newlines: convert literal backslash-n tokens
# to real newlines after _ibfh_has_escaped_markdown_newlines has established
# that the body contains escaped Markdown structure.
_ibfh_decode_escaped_markdown_newlines() {
	local body="$1"
	printf '%s' "${body//\\n/$'\n'}"
	return 0
}

# ---------------------------------------------------------------------------
# Advisory checks (always emit to stderr, never abort on their own)
# ---------------------------------------------------------------------------

# _ibfh_warn_fence_spacing: warn about code fences missing a preceding blank line.
_ibfh_warn_fence_spacing() {
	local body="$1"
	local prev="" line fence_issues=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^'```' ]] && [[ -n "$prev" ]]; then
			fence_issues=$((fence_issues + 1))
		fi
		prev="$line"
	done < <(printf '%s\n' "$body")
	if [[ $fence_issues -gt 0 ]]; then
		log_warn "issue-body-format: $fence_issues code fence(s) lack a preceding blank line (MD031)"
	fi
	return 0
}

# _ibfh_warn_dense_prose: warn when body has fewer than 2 headings.
_ibfh_warn_dense_prose() {
	local body="$1"
	local count
	count=$(_ibfh_heading_count "$body")
	if [[ $count -lt 2 ]]; then
		log_warn "issue-body-format: body has $count heading(s) — dense prose reduces worker readability"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# normalize: auto-fix issues that can be corrected without human judgment.
# Currently: decode escaped Markdown newlines and insert blank lines before
# code fences that lack one.
# Prints corrected body on stdout.
# ---------------------------------------------------------------------------
cmd_normalize() {
	local body="$1"
	if _ibfh_has_escaped_markdown_newlines "$body"; then
		body=$(_ibfh_decode_escaped_markdown_newlines "$body")
	fi

	# This is a pure transformation. Persist local briefs through prepare-scope.
	if printf '%s\n' "$body" | grep -qiE '^#{2,3} Files (to Modify|Scope)[[:space:]]*$'; then
		body=$(bash "$SCRIPT_DIR/brief-readiness-helper.sh" scope-normalize "$body") || return 1
	fi

	local prev="" out="" line
	while IFS= read -r line; do
		if [[ "$line" =~ ^'```' ]] && [[ -n "$prev" ]]; then
			out="${out}"$'\n'
		fi
		out="${out}${line}"$'\n'
		prev="$line"
	done < <(printf '%s\n' "$body")
	# Strip the trailing newline added by the loop (printf '%s\n' already adds one)
	printf '%s' "${out%$'\n'}"
	return 0
}

# ---------------------------------------------------------------------------
# check: run all structural checks and emit advisory warnings.
# Exit 0 if body passes or has warnings only.
# Exit 1 if non-dispatchable (controlled by AIDEVOPS_BODY_FORMAT_STRICT).
# ---------------------------------------------------------------------------
cmd_check() {
	local body="$1"
	local strict="${AIDEVOPS_BODY_FORMAT_STRICT:-0}"
	local non_dispatchable=0

	if _ibfh_has_escaped_markdown_newlines "$body"; then
		log_warn "issue-body-format: body contains literal \\n sequences in Markdown structure; normalize before publishing"
		body=$(_ibfh_decode_escaped_markdown_newlines "$body")
	fi

	# Advisory-only checks
	_ibfh_warn_fence_spacing "$body"
	_ibfh_warn_dense_prose   "$body"

	# Optional-section advisories
	if ! _ibfh_has_reference_pattern "$body"; then
		log_warn "issue-body-format: no reference pattern found (## Reference pattern / 'model on')"
	fi
	if ! _ibfh_has_verification "$body"; then
		log_warn "issue-body-format: no verification section or command block found"
	fi

	# Non-dispatchable checks
	if ! _ibfh_has_file_scope "$body"; then
		log_warn "issue-body-format: body lacks valid canonical Files Scope — normalize explicit declarations before publication"
		non_dispatchable=1
	fi
	if ! _ibfh_has_acceptance "$body"; then
		log_warn "issue-body-format: no acceptance criteria found (## Acceptance or - [ ] list)"
		non_dispatchable=1
	fi

	if [[ $non_dispatchable -eq 1 && "$strict" == "1" ]]; then
		log_error "issue-body-format: body is non-dispatchable (AIDEVOPS_BODY_FORMAT_STRICT=1)"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
cmd_help() {
	grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
	return 0
}

main() {
	local cmd="${1:-help}"
	local body="${2:-}"

	case "$cmd" in
	check)
		[[ -z "$body" ]] && { log_error "check requires <body-text>"; return 2; }
		cmd_check "$body"
		;;
	normalize)
		[[ -z "$body" ]] && { log_error "normalize requires <body-text>"; return 2; }
		cmd_normalize "$body"
		;;
	help|--help|-h)
		cmd_help
		;;
	*)
		log_error "Unknown command: $cmd"
		return 2
		;;
	esac
	return $?
}

main "$@"
