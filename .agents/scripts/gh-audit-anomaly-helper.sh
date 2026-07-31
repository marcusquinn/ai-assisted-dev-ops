#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-audit-anomaly-helper.sh — Scan gh-audit.log for anomalies (GH#20145)
# Commands: scan | status | help
# Docs: reference/gh-audit-log.md
#
# Reads ~/.aidevops/logs/gh-audit.log (or the path in GH_AUDIT_LOG_FILE),
# extracts entries with non-empty suspicious[] arrays, and opens a GitHub
# issue on marcusquinn/aidevops when anomalies are found.
#
# State is persisted in ~/.aidevops/logs/gh-audit-scanner.state (JSON):
#   {"last_scan_ts": "2026-04-20T09:00:00Z", "last_line": 42}
#
# Usage:
#   gh-audit-anomaly-helper.sh scan [--all] [--dry-run] [--repo SLUG]
#   gh-audit-anomaly-helper.sh status
#   gh-audit-anomaly-helper.sh help
#
# Environment:
#   GH_AUDIT_LOG_FILE         Override log path
#   GH_AUDIT_SCANNER_REPO     Repo slug for filed issues (default: marcusquinn/aidevops)
#   GH_AUDIT_QUIET            Suppress info output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" || true
init_log_file || true

# =============================================================================
# Constants
# =============================================================================

readonly GH_ANOMALY_VERSION="1.0.0"
readonly GH_ANOMALY_STATE_FILE_DEFAULT="${HOME}/.aidevops/logs/gh-audit-scanner.state"
readonly GH_ANOMALY_LOG_DIR_DEFAULT="${HOME}/.aidevops/logs"
readonly GH_ANOMALY_LOG_FILENAME="gh-audit.log"
readonly GH_ANOMALY_DEFAULT_REPO="marcusquinn/aidevops"
# Maximum anomaly entries to include in an issue (prevents overly large issues)
readonly GH_ANOMALY_MAX_ISSUE_ENTRIES=20

# =============================================================================
# Internal helpers
# =============================================================================

# Resolve the audit log file path.
_ga_log_path() {
	local dir="${GH_AUDIT_LOG_DIR:-${GH_ANOMALY_LOG_DIR_DEFAULT}}"
	local file="${GH_AUDIT_LOG_FILE:-${dir}/${GH_ANOMALY_LOG_FILENAME}}"
	echo "$file"
	return 0
}

# Resolve the scanner state file path.
_ga_state_path() {
	echo "${GH_ANOMALY_STATE_FILE:-${GH_ANOMALY_STATE_FILE_DEFAULT}}"
	return 0
}

# Print info to stderr (suppressed when GH_AUDIT_QUIET=true).
_ga_info() {
	local msg="$1"
	if [[ "${GH_AUDIT_QUIET:-false}" != "true" ]]; then
		printf '%b[GH-ANOMALY]%b %s\n' "${GREEN:-}" "${NC:-}" "$msg" >&2
	fi
	return 0
}

# Print warning to stderr.
_ga_warn() {
	local msg="$1"
	printf '%b[GH-ANOMALY WARN]%b %s\n' "${YELLOW:-}" "${NC:-}" "$msg" >&2
	return 0
}

# Read the last scanned line number from the state file.
# Returns 0 if state doesn't exist (scan from beginning).
_ga_read_last_line() {
	local state_file
	state_file="$(_ga_state_path)"

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	local last_line=0
	if command -v jq &>/dev/null; then
		last_line=$(jq -r '.last_line // 0' "$state_file" 2>/dev/null) || last_line=0
	fi
	echo "$last_line"
	return 0
}

# Write the scanner state file.
_ga_write_state() {
	local last_line="$1"
	local state_file
	state_file="$(_ga_state_path)"
	local ts
	ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
	local state_dir
	state_dir="$(dirname "$state_file")"
	[[ ! -d "$state_dir" ]] && mkdir -p "$state_dir" || true

	if command -v jq &>/dev/null; then
		jq -c -n \
			--arg ts "$ts" \
			--argjson last_line "$last_line" \
			'{last_scan_ts: $ts, last_line: $last_line}' >"$state_file" 2>/dev/null || true
	else
		printf '{"last_scan_ts":"%s","last_line":%s}\n' "$ts" "$last_line" >"$state_file" || true
	fi

	return 0
}

# Format a single anomaly entry for the issue body markdown table.
# Input: NDJSON line
# Output: markdown table row
_ga_format_anomaly_row() {
	local entry="$1"
	if ! command -v jq &>/dev/null; then
		echo "| (jq required) | | | | |"
		return 0
	fi

	local ts op repo number suspicious caller_function
	ts=$(printf '%s' "$entry" | jq -r '.ts // "?"')
	op=$(printf '%s' "$entry" | jq -r '.op // "?"')
	repo=$(printf '%s' "$entry" | jq -r '.repo // "?"')
	number=$(printf '%s' "$entry" | jq -r '.number // "?"')
	suspicious=$(printf '%s' "$entry" | jq -r '.suspicious | join(", ")' 2>/dev/null || echo "?")
	caller_function=$(printf '%s' "$entry" | jq -r '.caller_function // "?"')

	printf '| %s | %s | %s | #%s | %s | %s |\n' \
		"$ts" "$op" "$repo" "$number" "$suspicious" "$caller_function"

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Parse cmd_scan arguments. Populates caller-scoped output vars:
#   _sc_scan_all (0|1), _sc_dry_run (0|1), _sc_issue_repo (slug)
# Unknown args warned and skipped.
_cmd_scan_parse_args() {
	_sc_scan_all=0
	_sc_dry_run=0
	_sc_issue_repo="${GH_ANOMALY_REPO:-${GH_ANOMALY_DEFAULT_REPO}}"

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--all) _sc_scan_all=1; shift ;;
		--dry-run) _sc_dry_run=1; shift ;;
		--repo)
			_sc_issue_repo="${2:-${GH_ANOMALY_DEFAULT_REPO}}"
			shift 2
			;;
		*)
			_ga_warn "Unknown argument: ${_arg} (ignored)"
			shift
			;;
		esac
	done
	return 0
}

# Collect NDJSON entries with non-empty suspicious[] arrays into the
# caller-scoped array _sc_anomaly_entries.
# Args: log_file skip_count
# Returns 0 always.
_cmd_scan_collect_anomalies() {
	local log_file="$1" skip_count="$2"
	_sc_anomaly_entries=()

	if command -v jq &>/dev/null; then
		# Single jq pass: skip counted lines, emit only actionable anomalies.
		# Gemini feedback (GH#20145 PR #20153): avoid one-jq-per-line in while read loops.
		# The approval helper intentionally removes needs-maintainer-review only after
		# its signed approval checks pass. Keep that transition in the immutable log,
		# but do not file a daily alert when its complete provenance and delta match.
		local line
		while IFS= read -r line; do
			_sc_anomaly_entries+=("$line")
		done < <(tail -n +"$((skip_count + 1))" "$log_file" \
			| jq -c '
				select(.suspicious | length > 0)
				# aidevops:trust-boundary — fail closed unless every approval transition field matches.
				| select((
					.op == "issue_edit"
					and .caller_function == "_approval_apply_issue_lifecycle_updates"
					and ((.caller_script // "") | endswith("/agents/scripts/approval-helper.sh")
						or endswith("/.agents/scripts/approval-helper.sh"))
					and .suspicious == ["protected_label_removed:needs-maintainer-review"]
					and (.delta.labels_removed // []) == ["needs-maintainer-review"]
					and (((.delta.labels_added // []) - ["auto-dispatch"]) | length == 0)
					and ((.before.labels // []) | index("needs-maintainer-review") != null)
					and ((.after.labels // []) | index("needs-maintainer-review") == null)
				) | not)' 2>/dev/null || true)
		return 0
	fi

	# Fallback without jq: substring-match the suspicious field.
	local line line_num=0
	while IFS= read -r line; do
		line_num=$(( line_num + 1 ))
		[[ -z "$line" ]] && continue
		[[ "$line_num" -le "$skip_count" ]] && continue
		if [[ "$line" == *'"suspicious":['* ]] && [[ "$line" != *'"suspicious":[]'* ]]; then
			_sc_anomaly_entries+=("$line")
		fi
	done <"$log_file"
	return 0
}

# Build the markdown issue body for an anomaly report.
# Args: scan_ts anomaly_count skip_count total_lines entry1 entry2 ...
# Output: issue body markdown on stdout.
_cmd_scan_build_issue_body() {
	local scan_ts="$1" anomaly_count="$2" skip_count="$3" total_lines="$4"
	shift 4

	# Header (heredoc is easier to review than concatenation).
	cat <<BODY
## GH Audit Anomaly Report

**Scan time:** ${scan_ts}
**Anomalies found:** ${anomaly_count}
**Log scanned:** Lines $((skip_count + 1))–${total_lines} of \`gh-audit.log\`

## Anomalous Entries

| Timestamp | Op | Repo | Number | Signals | Caller |
|-----------|-----|------|--------|---------|--------|
BODY

	local entry included=0
	for entry in "$@"; do
		if [[ "$included" -ge "$GH_ANOMALY_MAX_ISSUE_ENTRIES" ]]; then
			printf '| ... | ... | ... | ... | (%s total, showing first %s) | |\n' \
				"$anomaly_count" "$GH_ANOMALY_MAX_ISSUE_ENTRIES"
			break
		fi
		_ga_format_anomaly_row "$entry"
		included=$(( included + 1 ))
	done

	cat <<FOOTER

## Next Steps

1. Review each entry in \`~/.aidevops/logs/gh-audit.log\`
2. Cross-reference with GitHub events API:
   \`gh api /repos/OWNER/REPO/issues/N/events --jq '[.[] | select(.event == "renamed")]'\`
3. If title/body wipe was unintended, restore from the before-state in the log.
4. See \`reference/gh-audit-log.md\` for the forensics workflow.

<!-- gh-audit-anomaly-scanner:${scan_ts} -->
FOOTER

	return 0
}

# File the anomaly issue on the target repo.
# Args: issue_repo title body_file
# Uses gh_create_issue (from shared-gh-wrappers.sh) per the framework rule
# that all issue/PR creation goes through a wrapper. Preserves gh stderr so
# transient auth/network failures are diagnosable (gemini feedback on PR #20153).
_cmd_scan_file_issue() {
	local issue_repo="$1" title="$2" body_file="$3"
	local issue_url gh_stderr_file
	gh_stderr_file="$(mktemp -t gh-audit-anomaly.XXXXXX)" || gh_stderr_file=""

	if ! command -v gh_create_issue &>/dev/null; then
		_ga_warn "gh_create_issue wrapper not available — shared-constants.sh likely not sourced"
		[[ -n "$gh_stderr_file" ]] && rm -f "$gh_stderr_file"
		return 1
	fi

	if [[ -n "$gh_stderr_file" ]]; then
		issue_url=$(gh_create_issue \
			--repo "$issue_repo" \
			--title "$title" \
			--body-file "$body_file" \
			--label "monitoring" \
			2>"$gh_stderr_file") || {
			local gh_err
			gh_err="$(tr '\n' ' ' <"$gh_stderr_file")"
			_ga_warn "Failed to create anomaly issue on ${issue_repo}: ${gh_err:-no-stderr}"
			rm -f "$gh_stderr_file"
			return 1
		}
		rm -f "$gh_stderr_file"
	else
		# No tmp file available — run without stderr capture but still surface failure.
		issue_url=$(gh_create_issue \
			--repo "$issue_repo" \
			--title "$title" \
			--body-file "$body_file" \
			--label "monitoring") || {
			_ga_warn "Failed to create anomaly issue on ${issue_repo}"
			return 1
		}
	fi

	_ga_info "Filed anomaly report: ${issue_url}"
	return 0
}

# Scan the gh-audit.log for entries with non-empty suspicious[] arrays.
# Files a GitHub issue if anomalies are found.
#
# Arguments:
#   --all         Scan from line 0 (ignore state file)
#   --dry-run     Print anomalies to stdout but do not file an issue or update state
#   --repo SLUG   Override the repo to file issues in
cmd_scan() {
	local _sc_scan_all _sc_dry_run _sc_issue_repo
	_cmd_scan_parse_args "$@"

	local log_file
	log_file="$(_ga_log_path)"

	if [[ ! -f "$log_file" ]]; then
		_ga_info "No log file found at ${log_file} — nothing to scan"
		return 0
	fi
	if [[ ! -s "$log_file" ]]; then
		_ga_info "Log file is empty — nothing to scan"
		return 0
	fi

	local total_lines start_line skip_count lines_to_scan
	total_lines="$(wc -l <"$log_file" | tr -d ' ')"
	start_line=0
	[[ "$_sc_scan_all" -eq 0 ]] && start_line="$(_ga_read_last_line)"
	skip_count="$start_line"
	lines_to_scan=$(( total_lines - skip_count ))

	if [[ "$lines_to_scan" -le 0 ]]; then
		_ga_info "No new entries since last scan (last_line=${start_line}, total=${total_lines})"
		return 0
	fi

	_ga_info "Scanning ${lines_to_scan} entries (lines ${start_line}+1..${total_lines})"

	local -a _sc_anomaly_entries=()
	_cmd_scan_collect_anomalies "$log_file" "$skip_count"

	local anomaly_count="${#_sc_anomaly_entries[@]}"
	_ga_info "Found ${anomaly_count} anomalous entries"

	[[ "$_sc_dry_run" -eq 0 ]] && _ga_write_state "$total_lines"

	if [[ "$anomaly_count" -eq 0 ]]; then
		_ga_info "No anomalies found — no issue filed"
		return 0
	fi

	local scan_ts
	scan_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"

	# Build the body in a tempfile; gh issue create --body-file is safer than
	# --body for large content (avoids argv size limits and shell quoting).
	local body_file
	body_file="$(mktemp -t gh-audit-anomaly-body.XXXXXX)"
	_cmd_scan_build_issue_body "$scan_ts" "$anomaly_count" "$skip_count" \
		"$total_lines" "${_sc_anomaly_entries[@]}" >"$body_file"

	if [[ "$_sc_dry_run" -eq 1 ]]; then
		_ga_info "DRY RUN — anomalies found, would file issue on ${_sc_issue_repo}"
		cat "$body_file"
		rm -f "$body_file"
		return 0
	fi

	if ! command -v gh &>/dev/null; then
		_ga_warn "gh CLI not available — cannot file issue. Body printed to stderr."
		cat "$body_file" >&2
		rm -f "$body_file"
		return 0
	fi

	local title="GH Audit Anomaly Alert: ${anomaly_count} suspicious operations detected"
	local exit_code=0
	_cmd_scan_file_issue "$_sc_issue_repo" "$title" "$body_file" || exit_code=$?
	rm -f "$body_file"
	return "$exit_code"
}

# Show scanner status.
cmd_status() {
	local log_file state_file
	log_file="$(_ga_log_path)"
	state_file="$(_ga_state_path)"

	echo "GH Audit Anomaly Scanner Status"
	echo "================================"
	echo "Version:    ${GH_ANOMALY_VERSION}"
	echo "Log file:   ${log_file}"
	echo "State file: ${state_file}"

	if [[ ! -f "$log_file" ]]; then
		echo "Log:        Not found"
		return 0
	fi

	local total_lines
	total_lines="$(wc -l <"$log_file" | tr -d ' ')"
	echo "Log lines:  ${total_lines}"

	if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
		local last_scan last_line
		last_scan=$(jq -r '.last_scan_ts // "never"' "$state_file" 2>/dev/null || echo "never")
		last_line=$(jq -r '.last_line // 0' "$state_file" 2>/dev/null || echo "0")
		echo "Last scan:  ${last_scan}"
		echo "Last line:  ${last_line}"
		echo "Unscanned:  $((total_lines - last_line)) entries"
	else
		echo "Last scan:  never"
	fi

	return 0
}

cmd_help() {
	cat <<'HELP'
gh-audit-anomaly-helper.sh — Scan gh-audit.log for anomalous operations

Reads the gh-audit.log, finds entries with non-empty suspicious[] arrays,
and opens a GitHub issue summary when anomalies are detected.

Commands:
  scan [--all] [--dry-run] [--repo SLUG]   Scan for anomalies, file issue
  status                                    Show scanner status
  help                                      Show this help

Options:
  --all        Scan from the beginning (ignore last-scan state)
  --dry-run    Print findings without filing an issue or updating state
  --repo SLUG  Override the repo to file issues in (default: marcusquinn/aidevops)

Routine entry for TODO.md:
  - [x] r-gh-audit-scan Scan gh-audit.log for anomalies \
        repeat:daily(@09:00) run:scripts/gh-audit-anomaly-helper.sh scan

State: ~/.aidevops/logs/gh-audit-scanner.state
Log:   ~/.aidevops/logs/gh-audit.log
Docs:  reference/gh-audit-log.md
HELP
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	scan)
		cmd_scan "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		_ga_warn "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
