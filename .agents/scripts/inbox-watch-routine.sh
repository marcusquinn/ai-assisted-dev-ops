#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# =============================================================================
# Inbox Watch Routine (t2867)
# =============================================================================
# Processes files dropped into _inbox/_drop/ — debounces, routes each item
# through inbox-helper.sh add, and records the audit log entry.
#
# Designed to run:
#   - As a pulse routine (every 5 min, configurable via INBOX_WATCH_INTERVAL)
#   - Manually: inbox-watch-routine.sh [<repo-path>]
#   - Via fswatch trigger (fswatch -o _inbox/_drop/ | xargs -n1 inbox-watch-routine.sh)
#
# Debounce: only processes files older than INBOX_WATCH_DEBOUNCE_SECS (default 5).
# Idempotent: files are moved out of _drop/ by inbox-helper.sh add, so
#             already-processed items are never double-processed.
#
# Usage:
#   inbox-watch-routine.sh [<repo-path>]
#
# Environment:
#   INBOX_WATCH_DEBOUNCE_SECS   Minimum file age before processing (default: 5)
#   INBOX_WATCH_MAX_BATCH       Max files per run (default: 50, safety limit)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
readonly INBOX_DIR_NAME="_inbox"
readonly DROP_DIR_NAME="_drop"
readonly DEBOUNCE_SECS="${INBOX_WATCH_DEBOUNCE_SECS:-5}"
readonly MAX_BATCH="${INBOX_WATCH_MAX_BATCH:-50}"

_emit_collector_receipt() {
	local changed_count="$1"
	local collector_status="$2"
	local coverage_status="$3"
	printf '{"changed_count":%s,"collector_status":"%s","coverage_status":"%s"}\n' \
		"$changed_count" "$collector_status" "$coverage_status"
	return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local inbox_dir="${repo_path}/${INBOX_DIR_NAME}"
	local drop_dir="${inbox_dir}/${DROP_DIR_NAME}"

	# Nothing to do if _drop/ doesn't exist
	if [[ ! -d "$drop_dir" ]]; then
		print_info "No _drop/ directory at ${drop_dir} — nothing to process"
		if [[ "${AIDEVOPS_COLLECTOR_RECEIPT:-0}" == "1" ]]; then
			_emit_collector_receipt 0 complete complete
		fi
		return 0
	fi

	local now_ts
	now_ts="$(date +%s)"

	local processed=0
	local skipped=0
	local errors=0

	# Collect files older than DEBOUNCE_SECS, up to MAX_BATCH
	while IFS= read -r -d '' file_path; do
		[[ "$processed" -ge "$MAX_BATCH" ]] && break

		# Skip if the file disappeared (race condition)
		[[ ! -f "$file_path" ]] && continue

		# Debounce: check modification time
		local file_mtime
		file_mtime="$(date -r "$file_path" +%s 2>/dev/null ||
			_file_mtime_epoch "$file_path")"
		local age=$((now_ts - file_mtime))

		if [[ "$age" -lt "$DEBOUNCE_SECS" ]]; then
			skipped=$((skipped + 1))
			continue
		fi

		# Process via inbox-helper.sh add (which handles the move + audit log)
		print_info "Processing: $(basename "$file_path") (age: ${age}s)"
		if bash "${SCRIPT_DIR}/inbox-helper.sh" add "$file_path"; then
			processed=$((processed + 1))
		else
			print_warning "Failed to process: ${file_path}"
			errors=$((errors + 1))
		fi
	done < <(find "$drop_dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null)

	if [[ "$processed" -gt 0 || "$errors" -gt 0 ]]; then
		print_info "Watch routine complete: processed=${processed} skipped=${skipped} errors=${errors}"
	fi
	if [[ "${AIDEVOPS_COLLECTOR_RECEIPT:-0}" == "1" ]]; then
		local coverage_status="complete"
		local collector_status="complete"
		[[ "$errors" -gt 0 ]] && coverage_status="partial"
		[[ "$errors" -gt 0 ]] && collector_status="partial"
		_emit_collector_receipt "$processed" "$collector_status" "$coverage_status"
	fi
	return 0
}

main "$@"
