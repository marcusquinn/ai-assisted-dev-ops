#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# inbox-digest-routine.sh — Pulse-callable stale inbox digest + advisory (t2869)
# =============================================================================
# Iterates all pulse-enabled repos and the workspace inbox, identifies items
# in _inbox/_drop/ and _inbox/_needs-review/ older than AIDEVOPS_INBOX_DIGEST_AGE_DAYS
# (default: 7), and writes/removes advisories in ~/.aidevops/advisories/.
#
# Advisory filename: inbox-stale-{slug-sanitized}.advisory (stable; overwritten)
# Advisory ID used by: aidevops security dismiss inbox-stale-{slug-sanitized}
# Advisory first line is surfaced in session greeting via _check_advisories().
# Advisories self-clear when stale item count drops to zero.
#
# Usage:
#   inbox-digest-routine.sh [--age-days N] [--dry-run] [--force]
#
# Pulse routine entry (TODO.md):
#   - [x] r_inbox_digest Inbox stale item digest
#     repeat:weekly(sun@08:00)
#     run:scripts/inbox-digest-routine.sh
#
# Environment:
#   AIDEVOPS_INBOX_DIGEST_AGE_DAYS         Age threshold in days (default: 7)
#   AIDEVOPS_INBOX_DIGEST_INTERVAL_HOURS   Re-run guard interval (default: 168)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly ADVISORIES_DIR="${HOME}/.aidevops/advisories"
readonly WORKSPACE_INBOX_DIR="${HOME}/.aidevops/.agent-workspace/inbox"
readonly DIGEST_STAMP_FILE="${TMPDIR:-/tmp}/aidevops-inbox-digest.last"

INBOX_DIGEST_AGE_DAYS="${AIDEVOPS_INBOX_DIGEST_AGE_DAYS:-7}"
INBOX_DIGEST_INTERVAL_HOURS="${AIDEVOPS_INBOX_DIGEST_INTERVAL_HOURS:-168}"

# =============================================================================
# Helpers
# =============================================================================

# _slug_sanitize <slug>
# Converts owner/repo → owner-repo for safe use in advisory filenames.
_slug_sanitize() {
	local slug="$1"
	printf '%s' "$slug" | sed 's|/|-|g; s|[^a-zA-Z0-9._-]|-|g'
	return 0
}

# _within_rate_window
# Returns 0 if enough time has elapsed since the last run; 1 if too soon.
_within_rate_window() {
	[[ ! -f "$DIGEST_STAMP_FILE" ]] && return 0
	local last_run now elapsed interval_secs
	last_run="$(cat "$DIGEST_STAMP_FILE" 2>/dev/null || echo 0)"
	now="$(date +%s)"
	elapsed=$(( now - last_run ))
	interval_secs=$(( INBOX_DIGEST_INTERVAL_HOURS * 3600 ))
	[[ "$elapsed" -lt "$interval_secs" ]] && return 1
	return 0
}

# _stamp_last_run
_stamp_last_run() {
	date +%s > "$DIGEST_STAMP_FILE" 2>/dev/null || true
	return 0
}

# _count_stale <json_output>
# Counts items in digest --json output by counting "age_days" key occurrences.
# Uses the safe counter pattern (grep -c || true with type guard).
_count_stale() {
	local json_out="$1"
	local count
	count=$(printf '%s' "$json_out" | grep -c '"age_days"' 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# _write_advisory <adv_id> <count> <age_days> <label> <repo_path>
# Creates/overwrites an advisory file and removes the ID from dismissed.txt
# so the advisory re-appears after a clean period followed by new stale items.
_write_advisory() {
	local adv_id="$1"
	local count="$2"
	local age_days="$3"
	local label="$4"
	local repo_path="$5"

	local adv_file="${ADVISORIES_DIR}/${adv_id}.advisory"
	local dismissed_file="${ADVISORIES_DIR}/dismissed.txt"

	mkdir -p "$ADVISORIES_DIR"

	printf '[INBOX] %s stale item(s) >= %sd in %s/_inbox/\n\nRun: aidevops inbox digest --repo %s\n' \
		"$count" "$age_days" "$label" "$repo_path" > "$adv_file"

	# Remove this ID from dismissed.txt so it re-appears after a clean period
	if [[ -f "$dismissed_file" ]]; then
		local tmp_dis
		tmp_dis="$(mktemp)"
		grep -vxF "$adv_id" "$dismissed_file" > "$tmp_dis" 2>/dev/null || true
		mv "$tmp_dis" "$dismissed_file" 2>/dev/null || rm -f "$tmp_dis" || true
	fi

	print_success "Advisory written: ${adv_id}"
	return 0
}

# _clear_advisory <adv_id>
# Removes an advisory file when no stale items remain (self-clear).
_clear_advisory() {
	local adv_id="$1"
	local adv_file="${ADVISORIES_DIR}/${adv_id}.advisory"
	if [[ -f "$adv_file" ]]; then
		rm -f "$adv_file"
		print_info "Advisory cleared: ${adv_id}"
	fi
	return 0
}

# _process_inbox <label> <repo_path> <age_days> <dry_run>
# Runs digest --json for the given repo root and manages the advisory.
# Skips silently if _inbox/ does not exist at repo_path.
_process_inbox() {
	local label="$1"
	local repo_path="$2"
	local age_days="$3"
	local dry_run="$4"

	[[ -d "${repo_path}/_inbox" ]] || return 0

	local helper="${SCRIPT_DIR}/inbox-helper.sh"
	[[ -x "$helper" ]] || { print_error "inbox-helper.sh not found at ${helper}"; return 1; }

	local json_out
	json_out="$("$helper" digest --json --age-days "$age_days" \
		--repo "$repo_path" 2>/dev/null || echo '[]')"

	local count
	count="$(_count_stale "$json_out")"

	local adv_id
	adv_id="inbox-stale-$(_slug_sanitize "$label")"

	if [[ "$count" -gt 0 ]]; then
		print_info "${label}: ${count} stale item(s) >= ${age_days}d"
		if [[ "$dry_run" -eq 1 ]]; then
			print_info "[DRY RUN] Would write advisory: ${adv_id}"
		else
			_write_advisory "$adv_id" "$count" "$age_days" "$label" "$repo_path"
		fi
	else
		print_info "${label}: inbox clean (< ${age_days}d)"
		if [[ "$dry_run" -eq 1 ]]; then
			print_info "[DRY RUN] Would clear advisory: ${adv_id} (if present)"
		else
			_clear_advisory "$adv_id"
		fi
	fi
	return 0
}

# _process_workspace_inbox <age_days> <dry_run>
# Scans the workspace-level inbox using --include-workspace flag.
# Passes workspace parent as --repo so the repo _inbox/ scan finds nothing,
# and only the workspace inbox (inbox/) is scanned.
_process_workspace_inbox() {
	local age_days="$1"
	local dry_run="$2"

	[[ -d "$WORKSPACE_INBOX_DIR" ]] || return 0

	local helper="${SCRIPT_DIR}/inbox-helper.sh"
	[[ -x "$helper" ]] || return 0

	# Pass workspace parent as --repo: ~/.aidevops/.agent-workspace has no _inbox/
	# so repo scanning finds nothing; --include-workspace adds the real inbox/.
	local workspace_parent
	workspace_parent="$(dirname "$WORKSPACE_INBOX_DIR")"

	local json_out
	json_out="$("$helper" digest --json --age-days "$age_days" \
		--repo "$workspace_parent" --include-workspace 2>/dev/null || echo '[]')"

	local count
	count="$(_count_stale "$json_out")"

	local adv_id="inbox-stale-workspace"

	if [[ "$count" -gt 0 ]]; then
		print_info "workspace: ${count} stale item(s) >= ${age_days}d"
		if [[ "$dry_run" -eq 1 ]]; then
			print_info "[DRY RUN] Would write advisory: ${adv_id}"
		else
			_write_advisory "$adv_id" "$count" "$age_days" "workspace" "$workspace_parent"
		fi
	else
		print_info "workspace: inbox clean (< ${age_days}d)"
		if [[ "$dry_run" -eq 1 ]]; then
			print_info "[DRY RUN] Would clear advisory: ${adv_id} (if present)"
		else
			_clear_advisory "$adv_id"
		fi
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local age_days="${INBOX_DIGEST_AGE_DAYS}"
	local dry_run=0
	local force=0

	while [[ $# -gt 0 ]]; do
		local cur_arg="$1"
		case "$cur_arg" in
		--age-days)    age_days="${2:-7}"; shift 2 ;;
		--age-days=*)  age_days="${cur_arg#--age-days=}"; shift ;;
		--dry-run)     dry_run=1; shift ;;
		--force)       force=1; shift ;;
		*)
			print_error "Unknown flag: $cur_arg"
			exit 1
			;;
		esac
	done

	# Rate-window guard (skip unless --force or --dry-run)
	if [[ "$force" -eq 0 && "$dry_run" -eq 0 ]] && ! _within_rate_window; then
		print_info "Inbox digest: not yet due (interval: ${INBOX_DIGEST_INTERVAL_HOURS}h). Use --force to override."
		exit 0
	fi

	# jq is required to iterate repos.json
	if ! command -v jq &>/dev/null; then
		print_warning "jq not found. Skipping cross-repo digest. Install jq to enable."
		exit 0
	fi

	local processed=0

	# Iterate pulse-enabled repos from repos.json
	if [[ -f "$REPOS_JSON" ]]; then
		while IFS='|' read -r repo_path slug; do
			[[ -z "$repo_path" || -z "$slug" ]] && continue
			# Expand ~ to $HOME (repos.json may use unexpanded tildes)
			repo_path="${repo_path/#\~/$HOME}"
			[[ -d "$repo_path" ]] || continue
			_process_inbox "$slug" "$repo_path" "$age_days" "$dry_run" || true
			processed=$(( processed + 1 ))
		done < <(jq -r \
			'.initialized_repos[]? | select(.maintenance != false and .pulse == true and .local_only != true) | "\(.path)|\(.slug)"' \
			"$REPOS_JSON" 2>/dev/null)
	else
		print_warning "repos.json not found at ${REPOS_JSON}. Skipping repo scan."
	fi

	# Workspace inbox (always scanned, independent of repos.json)
	_process_workspace_inbox "$age_days" "$dry_run" || true
	processed=$(( processed + 1 ))

	print_info "Digest complete: ${processed} inbox(es) checked."

	if [[ "$dry_run" -eq 0 ]]; then
		_stamp_last_run
	fi
	return 0
}

main "$@"
