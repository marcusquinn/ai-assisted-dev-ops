#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only transport evidence for Pulse; this never admits an HTTP request.

_cb_rest_core_local_observation() {
	local ttl="$1"
	local now="$2"
	local snapshot=""
	local state_dir="${AIDEVOPS_GH_TRANSPORT_STATE_DIR:-${HOME}/.aidevops/state/gh-transport}"
	[[ -f "${state_dir}/admission.sqlite3" ]] || return 2
	# The transport status CLI currently resolves github.com only. Never reuse
	# that principal's evidence for an explicitly selected enterprise host.
	[[ "${GH_HOST:-github.com}" == "github.com" ]] || return 2
	[[ -f "${SCRIPT_DIR}/gh_transport_budget.py" ]] || return 2
	snapshot=$(python3 "${SCRIPT_DIR}/gh_transport_budget.py" status 2>/dev/null) || return 2
	# The transport owns quota-owner alias resolution and conservative accounting.
	# Reuse only fresh header evidence, subtracting all outstanding reservations.
	# A recent server cooldown is zero usable headroom, never a positive grant.
	printf '%s\n' "$snapshot" | jq -er --argjson ttl "$ttl" --argjson now "$now" '
		select(.source == "local_response_headers") |
		select(.state == "available" or .state == "exhausted" or .state == "cooldown") |
		select(all((.remaining, .limit, .reserved, .reset, .observation_age_seconds);
			type == "number" and . >= 0 and floor == .)) |
		select(.limit > 0 and .remaining <= .limit) |
		if .state == "cooldown" then
			select(.blocked_until | type == "number" and . > $now) |
			[0, .limit, ([.reset, (.blocked_until | ceil)] | max)]
		else
			select(.reset > $now and .observation_age_seconds <= $ttl) |
			[([0, (.remaining - .reserved)] | max), .limit, .reset]
		end | map(tostring) | join(" ")
	' 2>/dev/null || return 2
	return 0
}
