#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# process-count-anomaly.sh — Detect pulse-wrapper process leak (t3072).
#
# Healthy state: at most a parent + a single in-flight child = 2 processes.
# A count > $LEAK_THRESHOLD (default 5) indicates the lifecycle helper is
# failing to reap children, or a launchd/systemd respawn loop is firing
# without killing the predecessor. This is invisible to the supervisor LLM
# cycle which never inspects the process table.
#
# Inputs (env):
#   PS_OUTPUT_OVERRIDE  fixture for tests; if set, used instead of `ps`
#   LEAK_THRESHOLD      max acceptable count (default 5)
#   PROC_PATTERN        pattern to match (default 'pulse-wrapper.sh')
#
# Function contract: runtime_audit_check returns 0/1; emits one JSON line
# on stdout when a finding is present.

# shellcheck shell=bash

runtime_audit_id() { printf 'process-count-anomaly\n'; return 0; }

runtime_audit_check() {
	local threshold="${LEAK_THRESHOLD:-5}"
	local pattern="${PROC_PATTERN:-pulse-wrapper.sh}"
	local ps_out
	if [[ -n "${PS_OUTPUT_OVERRIDE:-}" ]]; then
		ps_out="$PS_OUTPUT_OVERRIDE"
	else
		ps_out=$(ps -ax -o pid=,command= 2>/dev/null) || ps_out=""
	fi

	if [[ -z "$ps_out" ]]; then
		return 0
	fi

	# Count lines that contain the pattern but exclude greps of itself
	local matches
	matches=$(printf '%s\n' "$ps_out" | grep -F "$pattern" | grep -vE 'grep|runtime-audit|runtime-health-audit')
	if [[ -z "${PS_OUTPUT_OVERRIDE:-}" && -n "$matches" ]]; then
		local filtered_matches="" match_line pid ppid ppid_cmd
		while IFS= read -r match_line; do
			read -r pid _ <<<"$match_line"
			ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
			if [[ -n "$ppid" ]]; then
				ppid_cmd=$(ps -p "$ppid" -o command= 2>/dev/null)
				[[ "$ppid_cmd" == *"$pattern"* ]] && continue
			fi
			filtered_matches+="${filtered_matches:+$'\n'}${match_line}"
		done <<<"$matches"
		matches="$filtered_matches"
	fi
	local count
	count=$(printf '%s\n' "$matches" | grep -cE '\S' 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	if [[ "$count" -le "$threshold" ]]; then
		return 0
	fi

	local title="runtime-audit: ${pattern} process count anomaly (${count} > ${threshold})"
	local body
	body=$(cat <<MARKDOWN
## Task

The process table shows ${count} processes matching \`${pattern}\`, exceeding the threshold of ${threshold}. Healthy state is parent + at-most-one in-flight child = 2 processes. A count this high indicates either a lifecycle reaping failure or a respawn loop without predecessor kill.

## Evidence

\`\`\`
$(printf '%s\n' "$matches" | head -20)
\`\`\`

(Showing first 20 of ${count} matches.)

## Why

This is a structural blind spot of the supervisor LLM — it never inspects \`ps\`. Process leaks accumulate silently for hours until the operator notices CPU/memory pressure. Each lingering process holds open fds, scratch dirs, and (worse) may hold the pulse lock.

## How

1. Inspect the listed PIDs: \`ps -ax -o pid,etime,command | grep ${pattern}\` to see uptime per process.
2. Identify the launchd/systemd path: \`launchctl list | grep aidevops\` (macOS) or \`systemctl list-units --user | grep aidevops\` (Linux).
3. Read \`pulse-lifecycle-helper.sh\` for the reap path. Look for orphaned PIDs in \`~/.aidevops/logs/pulse.pid\` and \`~/.aidevops/cache/pulse-state/\`.
4. If launchd is respawning without kill: check \`KeepAlive\` semantics in the plist (typical bug: \`SuccessfulExit:false\` causes infinite loop on segfault).
5. Once root cause is fixed, kill the stragglers: \`pkill -f "(^|/)${pattern}( |$)" || true\` and let lifecycle restart cleanly.

## Acceptance Criteria

1. Root cause identified (lifecycle reap bug, respawn loop, or external killer).
2. Fix landed; subsequent audit runs show count <= 2 in steady state.

## Verification

After fix and pulse restart:
\`\`\`
ps -ax -o command | grep -c "${pattern}\$"
\`\`\`
should return 1 (parent only) or 2 (parent + in-flight child).

<!-- aidevops:generator=runtime-audit detector=process-count-anomaly -->
MARKDOWN
)

	jq -n --arg id "process-count-anomaly" --arg title "$title" --arg body "$body" \
		'{id: $id, title: $title, body: $body}'
	return 1
}
