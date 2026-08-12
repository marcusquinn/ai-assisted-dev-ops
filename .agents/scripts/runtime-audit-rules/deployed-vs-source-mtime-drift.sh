#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# deployed-vs-source-mtime-drift.sh — Flag stale deployed scripts (t3072).
#
# For each hot file in $WATCHED_FILES, compares the deployed copy at
# ~/.aidevops/agents/scripts/<f> to the source at ~/Git/aidevops/.agents/
# scripts/<f>. If the deployed mtime is older than the source mtime by
# more than $DRIFT_SECONDS (default 86400 = 24h), files a finding.
#
# This catches the canonical "fix landed in source but never deployed"
# bug that t2036 documented as a recurring footgun.
#
# Inputs (env):
#   AIDEVOPS_DEPLOYED_DIR  default ~/.aidevops/agents/scripts
#   AIDEVOPS_SOURCE_DIR    default ~/Git/aidevops/.agents/scripts
#   DRIFT_SECONDS          default 86400 (24h)
#   WATCHED_FILES          default canonical hot-file set (space-separated)
#
# Function contract: runtime_audit_check returns 0/1; emits one JSON line.

# shellcheck shell=bash

runtime_audit_id() {
	printf 'deployed-vs-source-mtime-drift\n'
	return 0
}

_runtime_audit_sha256() {
	local path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | cut -d ' ' -f 1
		return $?
	fi
	shasum -a 256 "$path" | cut -d ' ' -f 1
	return $?
}

_runtime_audit_bounded_diff() {
	local deployed_path="$1"
	local source_path="$2"
	local name="$3"
	local deployed_dir="$4"
	local source_dir="$5"
	local rendered=""

	rendered=$(diff -u --label "deployed/${name}" --label "source/${name}" \
		"$deployed_path" "$source_path" 2>/dev/null | sed -n '1,80p') || true
	# Source files can themselves mention either checkout. Redact those literals so
	# generated worker instructions never require or disclose host-only paths.
	rendered=${rendered//"$deployed_dir"/<deployed-dir>}
	rendered=${rendered//"$source_dir"/<source-dir>}
	printf '%s\n' "$rendered"
	return 0
}

runtime_audit_check() {
	local deployed_dir="${AIDEVOPS_DEPLOYED_DIR:-${HOME}/.aidevops/agents/scripts}"
	local source_dir="${AIDEVOPS_SOURCE_DIR:-${HOME}/Git/aidevops/.agents/scripts}"
	local drift="${DRIFT_SECONDS:-86400}"
	# Default watched set: hot files most likely to be runtime-relevant
	local files="${WATCHED_FILES:-pulse-wrapper.sh pulse-merge.sh pulse-merge-process.sh pulse-cleanup.sh dispatch-dedup-helper.sh}"

	if [[ ! -d "$deployed_dir" || ! -d "$source_dir" ]]; then
		return 0
	fi

	local now_epoch="${NOW_EPOCH:-$(date +%s)}"
	local drifted=()
	local f deployed_mtime source_mtime delta
	# shellcheck disable=SC2086  # word-splitting is intentional for $files
	for f in $files; do
		[[ -f "${deployed_dir}/${f}" && -f "${source_dir}/${f}" ]] || continue
		deployed_mtime=$(_file_mtime_epoch "${deployed_dir}/${f}" 2>/dev/null) || deployed_mtime=0
		source_mtime=$(_file_mtime_epoch "${source_dir}/${f}" 2>/dev/null) || source_mtime=0
		[[ -z "$deployed_mtime" || -z "$source_mtime" ]] && continue
		delta=$((source_mtime - deployed_mtime))
		if [[ "$delta" -gt "$drift" ]]; then
			drifted+=("${f}|${delta}|${deployed_mtime}|${source_mtime}")
		fi
		# Sanity: also flag if deployed is ahead of "now" + 1h (clock skew)
		if [[ "$deployed_mtime" -gt $((now_epoch + 3600)) ]]; then
			drifted+=("${f}|FUTURE_MTIME|${deployed_mtime}|${now_epoch}")
		fi
	done

	if [[ ${#drifted[@]} -eq 0 ]]; then
		return 0
	fi

	local evidence_table="| File | Drift | Deployed mtime | Source mtime | Deployed SHA-256 | Source SHA-256 |"$'\n'"| --- | --- | --- | --- | --- | --- |"
	local comparison_evidence=""
	local entry name d_str dm sm deployed_sha source_sha bounded_diff
	for entry in "${drifted[@]}"; do
		IFS='|' read -r name d_str dm sm <<<"$entry"
		deployed_sha=$(_runtime_audit_sha256 "${deployed_dir}/${name}" 2>/dev/null || printf 'unavailable')
		source_sha=$(_runtime_audit_sha256 "${source_dir}/${name}" 2>/dev/null || printf 'unavailable')
		evidence_table+=$'\n'"| \`${name}\` | ${d_str}s | $(date -r "$dm" '+%Y-%m-%d %H:%M:%SZ' || printf '%s\n' "$dm") | $(date -r "$sm" '+%Y-%m-%d %H:%M:%SZ' || printf '%s\n' "$sm") | \`${deployed_sha}\` | \`${source_sha}\` |"
		bounded_diff=$(_runtime_audit_bounded_diff "${deployed_dir}/${name}" "${source_dir}/${name}" "$name" "$deployed_dir" "$source_dir")
		comparison_evidence+=$'\n'"### \`${name}\`"$'\n\n'"~~~~diff"$'\n'"${bounded_diff}"$'\n'"~~~~"$'\n'
	done

	local first_file
	first_file="${drifted[0]%%|*}"

	local title="runtime-audit: deployed script lags source by >$((drift / 3600))h (\`${first_file}\`)"
	local drift_hours=$((drift / 3600))
	# Keep literal newlines intact without printf %b interpreting filename backslashes.
	local evidence_rendered
	evidence_rendered="$evidence_table"
	local body
	body=$(
		cat <<MARKDOWN
## Task

The pulse executes a deployed runtime copy, while the repository remains the source of truth. The trusted audit compared both copies before dispatch. The files below have a source-newer-than-deployed delta exceeding ${drift}s (${drift_hours}h).

## Evidence

${evidence_rendered}

The following sanitized comparison was captured by the audit. Each diff is limited to its first 80 lines; host-only checkout paths are replaced with placeholders.

${comparison_evidence}

## Why

This is the canonical t2036 footgun — debugging a runtime symptom by reading source instead of the deployed copy. When source is committed but the deploy never ran (or the user skipped \`aidevops update\`), the running pulse keeps the old behaviour while the operator believes the new fix is live.

## How

1. Review the embedded hashes and bounded diff; do not read the host's canonical checkout.
2. If the source-side change is desired live, run \`aidevops update\` from the worker's normal project boundary.
3. Restart pulse if pulse-* files were touched: \`pulse-lifecycle-helper.sh restart-if-running\`.
4. If the source-side change should NOT be deployed yet (work-in-progress): note that here and close. The drift will resolve when the work merges and a deploy fires.

## Acceptance Criteria

1. Each drifted file is either deployed (delta becomes <60s) or has a documented reason for staying out-of-sync.
2. Re-running the audit shows the drift block is gone.

## Verification

Re-run the audit; the cited files should no longer appear:

\`\`\`
~/.aidevops/agents/scripts/runtime-health-audit-helper.sh --dry-run --only deployed-vs-source-mtime-drift
\`\`\`

<!-- aidevops:generator=runtime-audit detector=deployed-vs-source-mtime-drift -->
MARKDOWN
	)

	jq -n --arg id "deployed-vs-source-mtime-drift" --arg title "$title" --arg body "$body" \
		'{id: $id, title: $title, body: $body}'
	return 1
}
