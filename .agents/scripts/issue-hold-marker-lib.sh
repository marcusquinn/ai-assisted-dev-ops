#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared issue-body hold/defer marker detection.

[[ -n "${_ISSUE_HOLD_MARKER_LIB_LOADED:-}" ]] && return 0
_ISSUE_HOLD_MARKER_LIB_LOADED=1

# issue_body_has_defer_marker — detect an explicit non-dispatch hold in issue text.
# Args: $1=issue body
# Output: true or false
issue_body_has_defer_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qiE 'defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]'; then
		printf 'true\n'
	else
		printf 'false\n'
	fi
	return 0
}
