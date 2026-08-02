#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
set -euo pipefail

# email-poll-helper.sh
# Pulse-driven IMAP polling for the aidevops knowledge plane.
#
# Polls configured mailboxes, fetches new .eml files to _knowledge/inbox/,
# and maintains per-mailbox high-watermark state at _knowledge/.imap-state.json.
#
# Usage:
#   email-poll-helper.sh tick              Poll all configured mailboxes
#   email-poll-helper.sh backfill <id>     Backfill mailbox --since <date>
#     --since YYYY-MM-DD                   Fetch history from this date
#     --rate-limit N                       Max messages/min (default 100)
#   email-poll-helper.sh test <id>         Dry-run: connect + fetch, no writes
#   email-poll-helper.sh list              List mailboxes + last-polled status
#   email-poll-helper.sh help              Show this help
#
# Config locations (in priority order):
#   _config/mailboxes.json                 Per-repo config (git-trackable)
#   ~/.config/aidevops/mailboxes.json      Personal / global config
#
# State:  _knowledge/.imap-state.json      Per-folder high-watermark UIDs
# Inbox:  _knowledge/inbox/               Output .eml files
#
# Part of aidevops email system (t2855).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly POLL_PY="${SCRIPT_DIR}/email_poll.py"
readonly _ERR_NO_CONFIG="No mailboxes.json config found"
readonly COLLECTION_LINEAGE_FILTERED="filtered"

# Config resolution order (first-found wins)
_REPO_CONFIG="_config/mailboxes.json"
_GLOBAL_CONFIG="${HOME}/.config/aidevops/mailboxes.json"
_FILTER_CONFIG="_config/email-filters.json"

# State and inbox paths (relative to CWD = repo root)
_STATE_FILE="_knowledge/.imap-state.json"
_INBOX_DIR="_knowledge/inbox"

# Lock file: one poll per pulse cycle
_LOCK_DIR="${HOME}/.aidevops/.agent-workspace/locks"
_LOCK_FILE="${_LOCK_DIR}/email-poll.lock"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_find_config() {
	if [[ -f "$_REPO_CONFIG" ]]; then
		echo "$_REPO_CONFIG"
		return 0
	fi
	if [[ -f "$_GLOBAL_CONFIG" ]]; then
		echo "$_GLOBAL_CONFIG"
		return 0
	fi
	return 1
}

_require_python3() {
	if ! command -v python3 &>/dev/null; then
		log_error "python3 is required for email polling"
		return 1
	fi
	return 0
}

_require_poll_py() {
	if [[ ! -f "$POLL_PY" ]]; then
		log_error "email_poll.py not found: $POLL_PY"
		log_error "Run: aidevops update"
		return 1
	fi
	return 0
}

_collection_state_lineage_status() {
	local state_path="$1"
	local lineage_marker="$2"
	if [[ ! -f "$state_path" ]]; then
		printf '%s\n' "none"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		log_error "jq is required to inspect ${state_path}; refusing unfiltered mailbox collection"
		return 1
	fi
	if ! jq -e 'type == "object"' "$state_path" >/dev/null 2>&1; then
		log_error "Invalid ${state_path}; refusing unfiltered mailbox collection"
		return 1
	fi
	if jq -e --arg marker "$lineage_marker" '[keys[] | select(contains($marker))] | length > 0' "$state_path" >/dev/null 2>&1; then
		printf '%s\n' "$COLLECTION_LINEAGE_FILTERED"
	else
		printf '%s\n' "none"
	fi
	return 0
}

_resolve_collection_filter_config() {
	# Versionless legacy filters remain post-ingest-only until a mailbox has
	# filtered lineage state. After migration, only an explicit v2 ruleset may
	# restore unfiltered reads (for example, collection:false on every rule).
	local lineage_status
	lineage_status=$(_collection_state_lineage_status "$_STATE_FILE" "/imap/filter/") || return 1
	if [[ ! -f "$_FILTER_CONFIG" ]]; then
		if [[ "$lineage_status" == "$COLLECTION_LINEAGE_FILTERED" ]]; then
			log_error "Missing ${_FILTER_CONFIG} after filtered collection; refusing unfiltered mailbox collection"
			return 1
		fi
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		log_error "jq is required to validate ${_FILTER_CONFIG}; refusing unfiltered mailbox collection"
		return 1
	fi
	if ! jq -e 'type == "object"' "$_FILTER_CONFIG" >/dev/null 2>&1; then
		log_error "Invalid ${_FILTER_CONFIG}; refusing unfiltered mailbox collection"
		return 1
	fi
	local version
	version=$(jq -r 'if has("version") then (.version | tostring) else "" end' "$_FILTER_CONFIG")
	if [[ -z "$version" ]]; then
		if [[ "$lineage_status" == "$COLLECTION_LINEAGE_FILTERED" ]]; then
			log_error "Versionless ${_FILTER_CONFIG} cannot replace prior filtered collection; use an explicit version 2 config"
			return 1
		fi
		return 0
	fi
	if [[ "$version" != "2" ]]; then
		log_error "Unsupported email filter version ${version}; refusing unfiltered mailbox collection"
		return 1
	fi
	printf '%s\n' "$_FILTER_CONFIG"
	return 0
}

_acquire_lock() {
	mkdir -p "$_LOCK_DIR"
	if ! mkdir "${_LOCK_FILE}" 2>/dev/null; then
		local lock_pid=""
		lock_pid=$(cat "${_LOCK_FILE}/pid" 2>/dev/null || true)
		if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
			log_warn "Email poll already running (PID $lock_pid). Skipping tick."
			return 1
		fi
		# Stale lock — clear it
		log_warn "Clearing stale email-poll lock (PID ${lock_pid:-unknown} not running)"
		rm -rf "${_LOCK_FILE}"
		mkdir "${_LOCK_FILE}"
	fi
	echo "$$" >"${_LOCK_FILE}/pid"
	return 0
}

_release_lock() {
	rm -rf "${_LOCK_FILE}" 2>/dev/null || true
	return 0
}

_emit_collector_receipt() {
	local changed_count="$1"
	local collector_status="$2"
	local coverage_status="$3"
	printf '{"changed_count":%s,"collector_status":"%s","coverage_status":"%s"}\n' \
		"$changed_count" "$collector_status" "$coverage_status"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_tick() {
	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_info "skipped — no mailboxes configured; run aidevops email mailbox add to enable"
		if [[ "${AIDEVOPS_COLLECTOR_RECEIPT:-0}" == "1" ]]; then
			_emit_collector_receipt 0 complete complete
		fi
		return 0
	fi

	_require_python3 || return 1
	_require_poll_py || return 1
	local filter_config
	filter_config=$(_resolve_collection_filter_config) || return 1

	if ! _acquire_lock; then
		if [[ "${AIDEVOPS_COLLECTOR_RECEIPT:-0}" == "1" ]]; then
			_emit_collector_receipt 0 deferred unknown
		fi
		return 0
	fi
	trap '_release_lock' EXIT

	mkdir -p "$_INBOX_DIR"

	log_info "Polling mailboxes (config: $config_path)"
	local result
	local py_exit=0
	local _stderr_tmp
	local filter_args=()
	[[ -n "$filter_config" ]] && filter_args=(--filters "$filter_config")
	_stderr_tmp=$(mktemp)
	result=$(python3 "$POLL_PY" tick \
		--config "$config_path" \
		--state "$_STATE_FILE" \
		--inbox "$_INBOX_DIR" \
		"${filter_args[@]}" 2>"$_stderr_tmp") || py_exit=$?
	local _py_stderr
	_py_stderr=$(cat "$_stderr_tmp" 2>/dev/null || true)
	rm -f "$_stderr_tmp"
	[[ -n "$_py_stderr" ]] && log_warn "email_poll.py: $_py_stderr"
	if [[ "$py_exit" -ne 0 && -z "$result" ]]; then
		log_error "email_poll.py tick failed (exit $py_exit)"
		return 1
	fi

	# Parse summary from JSON result
	local overall_status fetched_count
	overall_status=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('overall_status', 'unknown'))
" 2>/dev/null || echo "unknown")
	fetched_count=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
total = sum(r.get('fetched_count', 0) for r in d.get('results', []))
print(total)
" 2>/dev/null || echo "0")

	local command_rc=0
	if [[ "$overall_status" == "ok" ]]; then
		log_info "Tick complete: $fetched_count new message(s)"
	else
		log_warn "Tick complete with errors: $fetched_count message(s) fetched"
		# Preserve legacy pulse behavior; filtered collection fails below.
		echo "$result" >&2
		if [[ -n "$filter_config" ]]; then
			command_rc=1
		fi
	fi
	if [[ "${AIDEVOPS_COLLECTOR_RECEIPT:-0}" == "1" ]]; then
		local coverage_status="partial"
		local collector_status="partial"
		[[ "$overall_status" == "ok" ]] && coverage_status="complete"
		[[ "$overall_status" == "ok" ]] && collector_status="complete"
		_emit_collector_receipt "$fetched_count" "$collector_status" "$coverage_status"
	fi

	_release_lock
	trap - EXIT
	return "$command_rc"
}

cmd_backfill() {
	local mailbox_id="${1:-}"
	shift || true

	if [[ -z "$mailbox_id" ]]; then
		log_error "Usage: email-poll-helper.sh backfill <mailbox-id> --since YYYY-MM-DD"
		return 1
	fi

	local since="" rate_limit=100
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local val="${2:-}"
		case "$flag" in
		--since)
			since="$val"
			shift 2
			;;
		--rate-limit)
			rate_limit="$val"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$since" ]]; then
		log_error "--since YYYY-MM-DD is required for backfill"
		return 1
	fi

	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1
	local filter_config
	filter_config=$(_resolve_collection_filter_config) || return 1

	mkdir -p "$_INBOX_DIR"

	log_info "Backfilling mailbox '$mailbox_id' from $since (rate: ${rate_limit}/min)"
	local filter_args=()
	[[ -n "$filter_config" ]] && filter_args=(--filters "$filter_config")
	python3 "$POLL_PY" backfill \
		--config "$config_path" \
		--state "$_STATE_FILE" \
		--inbox "$_INBOX_DIR" \
		--mailbox-id "$mailbox_id" \
		--since "$since" \
		--rate-limit "$rate_limit" \
		"${filter_args[@]}"

	return 0
}

cmd_test() {
	local mailbox_id="${1:-}"

	if [[ -z "$mailbox_id" ]]; then
		log_error "Usage: email-poll-helper.sh test <mailbox-id>"
		return 1
	fi

	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1

	log_info "Dry-run test for mailbox '$mailbox_id'"
	python3 "$POLL_PY" test \
		--config "$config_path" \
		--mailbox-id "$mailbox_id"

	return 0
}

cmd_list() {
	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1

	local state_arg=""
	if [[ -f "$_STATE_FILE" ]]; then
		state_arg="--state $_STATE_FILE"
	fi

	# shellcheck disable=SC2086
	python3 "$POLL_PY" list \
		--config "$config_path" \
		$state_arg | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('mailboxes', [])
if not rows:
    print('No mailboxes configured.')
    sys.exit(0)
print(f\"{'ID':<25} {'HOST':<30} {'USER':<35} {'POLLED':<22} {'ERROR'}\")
print('-' * 120)
for r in rows:
    polled = r.get('last_polled_at') or '-'
    err = (r.get('last_error') or '')[:40]
    print(f\"{r['id']:<25} {r['host']:<30} {r['user']:<35} {polled:<22} {err}\")
"
	return 0
}

cmd_help() {
	cat <<'EOF'
email-poll-helper.sh — IMAP polling for the aidevops knowledge plane (t2855)

Usage:
  email-poll-helper.sh tick                    Poll all configured mailboxes
  email-poll-helper.sh backfill <id>           Backfill a mailbox from a date
    --since YYYY-MM-DD                           Start date for backfill (required)
    --rate-limit N                               Max messages/min (default 100)
  email-poll-helper.sh test <id>               Dry-run: connect + fetch, no disk writes
  email-poll-helper.sh list                    Show mailboxes and last-polled status
  email-poll-helper.sh help                    Show this help

Config locations (first-found wins):
  _config/mailboxes.json                       Per-repo (git-trackable)
  ~/.config/aidevops/mailboxes.json            Personal / global

Version 2 rules in _config/email-filters.json are applied before persistence.
Only locally confirmed matches enter _knowledge/inbox; unmatched candidates
leave content-free per-rule coverage in _knowledge/.imap-state.json.

State:  _knowledge/.imap-state.json
Inbox:  _knowledge/inbox/

Credentials:
  Store passwords in gopass: aidevops secret set email/<mailbox-id>/password
  Reference in config as:    "password_ref": "gopass:aidevops/email/<id>/password"

Setup:
  aidevops email mailbox add                   Interactive guided setup
  aidevops email mailbox list                  Show all mailboxes
  aidevops email mailbox test <id>             Test connection
  aidevops email mailbox remove <id>           Remove a mailbox
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	tick) cmd_tick "$@" ;;
	backfill) cmd_backfill "$@" ;;
	test) cmd_test "$@" ;;
	list) cmd_list "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		log_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
