#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# log-pattern-novelty.sh — Surface new high-frequency log patterns (t3072).
#
# Tails the last $RECENT_LINES lines of $LOG_FILE, normalises each line to
# a template (strip timestamps, PIDs, hashes, numbers), counts templates,
# and flags any template appearing >= $NOVELTY_THRESHOLD times in the
# recent window that did NOT appear in the prior $PRIOR_LINES.
#
# This is the "what changed in pulse log behaviour today vs yesterday"
# question that the supervisor LLM never asks because logs are out of band.
#
# Inputs (env):
#   LOG_FILE             default ~/.aidevops/logs/pulse-wrapper.log
#   RECENT_LINES         default 1000
#   PRIOR_LINES          default 5000
#   NOVELTY_THRESHOLD    default 5

# shellcheck shell=bash

runtime_audit_id() { printf 'log-pattern-novelty\n'; return 0; }

runtime_audit_check() {
	local log_file="${LOG_FILE:-${HOME}/.aidevops/logs/pulse-wrapper.log}"
	local recent="${RECENT_LINES:-1000}"
	local prior="${PRIOR_LINES:-5000}"
	local threshold="${NOVELTY_THRESHOLD:-5}"

	if [[ ! -f "$log_file" ]]; then
		return 0
	fi

	# Total lines available
	local total
	total=$(wc -l <"$log_file" 2>/dev/null | tr -d ' ')
	[[ "$total" =~ ^[0-9]+$ ]] || return 0
	[[ "$total" -lt "$((recent + 100))" ]] && return 0

	# Template normalisation: strip timestamps, PIDs, hex hashes, ISO dates,
	# pure numbers, then collapse whitespace. Conservative — keeps function
	# names, error categories, and quoted identifiers intact.
	# BSD sed (macOS) does not honor \b word boundaries — use a portable
	# pattern. Order matters: timestamps and epoch-length numbers consume
	# their digit runs first, so the bare [0-9]+ rule catches what remains
	# (small numeric IDs, iteration counts, error codes).
	_normalise_template() {
		sed -E \
			-e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9:]+)?/<TS>/g' \
			-e 's/[0-9]{10,}/<EPOCH>/g' \
			-e 's/PID[ =:]?[0-9]+/PID=<N>/g' \
			-e 's/[a-f0-9]{7,40}/<HASH>/g' \
			-e 's/[0-9]+/<N>/g' \
			-e 's/[[:space:]]+/ /g'
	}

	local recent_block prior_block
	recent_block=$(tail -n "$recent" "$log_file" 2>/dev/null) || return 0
	# Prior: skip the recent tail, take up to $prior lines preceding it
	local skip_from_end=$((recent + prior))
	if [[ "$total" -ge "$skip_from_end" ]]; then
		prior_block=$(head -n "$((total - recent))" "$log_file" 2>/dev/null | tail -n "$prior")
	else
		prior_block=$(head -n "$((total - recent))" "$log_file" 2>/dev/null)
	fi

	local recent_templates prior_templates
	recent_templates=$(printf '%s\n' "$recent_block" | _normalise_template | sort | uniq -c | sort -rn)
	prior_templates=$(printf '%s\n' "$prior_block" | _normalise_template | sort -u)

	# Find templates with count >= threshold in recent that are missing from prior.
	# Format of recent_templates: "  <count> <template>"
	local novel=()
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local count tmpl
		count=$(printf '%s' "$line" | awk '{print $1}')
		tmpl=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')
		[[ -z "$tmpl" ]] && continue
		[[ "$count" -lt "$threshold" ]] && break  # sorted desc, can stop
		# Skip very short templates (noise like single chars, log level headers)
		[[ "${#tmpl}" -lt 30 ]] && continue
		if ! printf '%s\n' "$prior_templates" | grep -qF -- "$tmpl"; then
			novel+=("${count}|${tmpl}")
			[[ ${#novel[@]} -ge 5 ]] && break  # cap evidence
		fi
	done <<<"$recent_templates"

	if [[ ${#novel[@]} -eq 0 ]]; then
		return 0
	fi

	local evidence_table="| Recent count | Normalised template |"$'\n'"| --- | --- |"
	local entry c t
	for entry in "${novel[@]}"; do
		IFS='|' read -r c t <<<"$entry"
		# Truncate long templates for table display
		[[ ${#t} -gt 200 ]] && t="${t:0:200}..."
		# Escape pipes inside template for markdown
		t="${t//|/\\|}"
		evidence_table+=$'\n'"| ${c} | \`${t}\` |"
	done

	local title="runtime-audit: ${#novel[@]} novel high-frequency log pattern(s) in last ${recent} lines"
	local body
	# shellcheck disable=SC2016  # intentional literal markdown backticks in format string
	body=$(printf '## Task\n\nThe last %s lines of `%s` contain log templates that appear >= %s times AND were not present in the prior %s lines. Sudden new high-frequency patterns are the supervisor LLM blind spot — logs are out-of-band, so a new error class can compound for hours before any issue is filed.\n\n## Evidence\n\n%s\n\nLog file: `%s`\n\n## Why\n\nNovel log templates almost always trace to a recently-deployed change. The supervisor never reads the log file directly, so the only way these patterns surface today is when an interactive operator runs `tail -f`. This detector closes that gap.\n\n## How\n\n1. Locate the source of each novel template:\n   - `grep -F "<sample-fragment>" .agents/scripts/*.sh` to find the emitting script.\n2. Check recent commits for that script: `git log --since="36 hours ago" -- <path>`.\n3. Cross-check `pulse-stats.json` for any counter that rose in the same window — see the `counter-trend-delta` detector.\n4. If the new pattern is benign (e.g. a new INFO line from a planned feature): close with rationale. If actionable (new error class, new warning): file a separate task with the implementation pattern.\n\n## Acceptance Criteria\n\n1. Each novel template is either traced to a known intentional change OR has a follow-up task linked.\n2. Re-running this detector shows the templates either drop below the threshold or move into the prior-window baseline.\n\n## Verification\n\n```\n~/.aidevops/agents/scripts/runtime-health-audit-helper.sh --dry-run --only log-pattern-novelty\n```\n\n<!-- aidevops:generator=runtime-audit detector=log-pattern-novelty -->\n' \
		"$recent" "$log_file" "$threshold" "$prior" \
		"$evidence_table" \
		"$log_file")

	jq -n --arg id "log-pattern-novelty" --arg title "$title" --arg body "$body" \
		'{id: $id, title: $title, body: $body}'
	return 1
}
