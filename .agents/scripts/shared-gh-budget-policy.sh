#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Pure reset-aware scheduling hints. Request admission owns actual quota spend.

gh_budget_window_threshold() {
	local cap="$1"
	local reset="$2"
	local now="${3:-}"
	local window="${4:-3600}"
	[[ "$cap" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$now" ]] || now=$(date +%s)
	# Missing evidence cannot invent a reset or restore quota. Preserve the
	# configured scheduling hint until a valid snapshot replaces it.
	if [[ ! "$reset" =~ ^[0-9]{1,10}$ || ! "$now" =~ ^[0-9]{1,10}$ || ! "$window" =~ ^[1-9][0-9]{0,5}$ ]]; then
		printf '%s\n' "$cap"
		return 0
	fi
	local left=$((reset - now))
	[[ "$left" -ge 0 ]] || left=0
	[[ "$left" -le "$window" ]] || left="$window"
	# Round down: a scheduling hint must not strand the final available point.
	printf '%s\n' "$((cap * left / window))"
	return 0
}
