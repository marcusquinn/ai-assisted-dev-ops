#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# =============================================================================
# OpenCode Database Maintenance Helper
# =============================================================================
# Periodic SQLite maintenance for opencode's session database to reduce
# lock contention under concurrent session load.
#
# Problem: opencode stores session state in ~/.local/share/opencode/opencode.db
# (SQLite + WAL). Each opencode process opens 2+ connections (one per
# read-pool + writer). A single TUI with 10+ FDs is already multi-writer
# from SQLite's perspective. As the DB grows (1 GB+ is common for active
# users), write transactions exceed the compiled busy_timeout (5s) and
# fail as "database is locked" — halting the session mid-turn.
#
# Related upstream issues (anomalyco/opencode):
#   #21215 — SQLITE_BUSY on concurrent sessions (busy_timeout=0 in some paths)
#   #21000 — Bash tool hangs on massive output, locks DB
#   #20935 — Per-session-tree sharding (architectural fix, pending)
#   #21579 — Harden per-session SQLite sharding (PR, pending)
#
# This helper cannot fix the architectural problem (sharding must land
# upstream), but it can minimise lock-hold time by:
#   1. Truncating the WAL file (wal_checkpoint TRUNCATE)
#   2. Reclaiming free pages (VACUUM)
#   3. Refreshing query planner stats (PRAGMA optimize)
#   4. Right-sizing the WAL journal limit
#
# A 30-50% size reduction after VACUUM is typical for DBs that have seen
# heavy delete/prune activity. Smaller DB = faster writes = shorter locks.
#
# Subcommands:
#   check                — report readiness; does opencode.db exist, is it locked?
#   report               — human-readable DB stats (size, row counts, fragmentation)
#   maintain [--force]   — run maintenance; aborts if opencode processes active
#   maintenance-window    — stop pulse/headless workers, optionally archive,
#                          maintain, then restart pulse (explicitly disruptive)
#   auto                 — run maintenance only if safe (no active processes);
#                          used by the r913 weekly routine. Silent no-op if
#                          opencode is not installed.
#   install              — macOS only: install/refresh LaunchAgent for weekly
#                          auto-run on Sun 04:00 local (t2183). Linux install
#                          is handled by .agents/scripts/setup/modules/schedulers.sh directly.
#   uninstall            — macOS only: remove LaunchAgent. Idempotent.
#   status               — report scheduler install state (launchd on macOS,
#                          systemd/cron on Linux).
#   notice               — emit one toast-safe warning line when due/scheduled.
#   sessions             — read-only lookup for hidden/child/archived sessions.
#   help                 — show this help
#
# Usage:
#   opencode-db-maintenance-helper.sh <subcommand> [options]
#
# Exit codes:
#   0   — success (or no-op on auto mode when opencode not installed)
#   1   — DB path unreadable, integrity check failed, sqlite3 missing
#   2   — opencode processes active (maintain aborted without --force)
#   10  — maintenance partially completed (some step failed, see logs)
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
	echo "ERROR: cannot resolve script dir" >&2
	exit 1
}

# Source shared constants if present; tolerate standalone execution.
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Reuse the portable filesystem-capacity probe when available. Standalone
# copies without the library fail closed only when a VACUUM would run.
# shellcheck source=disk-capacity-lib.sh
if [[ -f "${SCRIPT_DIR}/disk-capacity-lib.sh" ]]; then
	source "${SCRIPT_DIR}/disk-capacity-lib.sh"
fi

# Color fallbacks (GH#18702 pattern): guard each assignment so we don't
# clobber readonlies from shared-constants.sh when sourced.
[[ -z "${RED+x}" ]] && RED=$'\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN=$'\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW=$'\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE=$'\033[0;34m'
[[ -z "${NC+x}" ]] && NC=$'\033[0m'

# -----------------------------------------------------------------------------
# Paths and defaults
# -----------------------------------------------------------------------------

readonly OPENCODE_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
readonly OPENCODE_DB="${OPENCODE_DB_PATH:-${OPENCODE_DB:-${OPENCODE_DATA_DIR}/opencode.db}}"
readonly OPENCODE_ARCHIVE_DB="${OPENCODE_ARCHIVE_DB:-${OPENCODE_DATA_DIR}/opencode-archive.db}"
readonly OPENCODE_WAL="${OPENCODE_DB}-wal"
readonly OPENCODE_SHM="${OPENCODE_DB}-shm"
readonly MAINTENANCE_WINDOW_MODE="maintenance-window"
readonly SQLITE_QUICK_CHECK="PRAGMA quick_check;"
readonly PRAGMA_PAGE_COUNT="page_count"
readonly PRAGMA_FREELIST_COUNT="freelist_count"
readonly SESSION_PARENT_ID_COLUMN="parent_id"
readonly SESSION_PROJECT_ID_COLUMN="project_id"

readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/work/opencode-maintenance"
readonly STATE_FILE="${STATE_DIR}/last-run.json"
readonly LOG_FILE="${STATE_DIR}/maintenance.log"

# Thresholds — overrideable via env for advanced users.
# VACUUM_FREELIST_THRESHOLD: only VACUUM if free pages > this fraction (default 10%)
: "${VACUUM_FREELIST_THRESHOLD:=0.10}"
# Legacy variable name: this now controls compact-large reporting only. Size
# alone is not evidence that VACUUM can reclaim space.
: "${FORCE_VACUUM_SIZE_MB:=500}"
: "${AUTO_MIN_SECONDS_BETWEEN:=518400}"
: "${WAL_LARGE_THRESHOLD_MB:=500}"
[[ "$FORCE_VACUUM_SIZE_MB" =~ ^[0-9]+$ ]] && FORCE_VACUUM_SIZE_MB=$((10#$FORCE_VACUUM_SIZE_MB)) || FORCE_VACUUM_SIZE_MB=500
[[ "$AUTO_MIN_SECONDS_BETWEEN" =~ ^[0-9]+$ ]] && AUTO_MIN_SECONDS_BETWEEN=$((10#$AUTO_MIN_SECONDS_BETWEEN)) || AUTO_MIN_SECONDS_BETWEEN=518400
[[ "$WAL_LARGE_THRESHOLD_MB" =~ ^[0-9]+$ ]] && WAL_LARGE_THRESHOLD_MB=$((10#$WAL_LARGE_THRESHOLD_MB)) || WAL_LARGE_THRESHOLD_MB=500
: "${MAINTENANCE_WINDOW_KEEP_SESSIONS:=500}"  # maintenance-window count target
: "${MAINTENANCE_WINDOW_RETENTION_DAYS:=30}" # maintenance-window age target
# Scheduler knobs: safe default is weekly Sun 04:00 running non-disruptive auto.
: "${OPENCODE_DB_MAINTENANCE_HOUR:=4}"
: "${OPENCODE_DB_MAINTENANCE_MINUTE:=0}"
: "${OPENCODE_DB_MAINTENANCE_MODE:=auto}"
readonly VACUUM_FREE_SPACE_MULTIPLIER=3

# Scheduler (macOS launchd) — used by cmd_install / cmd_uninstall / cmd_status.
# Linux systemd/cron install is handled by .agents/scripts/setup/modules/schedulers.sh
# (setup_opencode_db_maintenance → _install_scheduler_linux).
readonly LAUNCHD_LABEL="sh.aidevops.opencode-db-maintenance"
readonly LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SCHEDULER_LOG_DIR="${HOME}/.aidevops/.agent-workspace/logs"
readonly SCHEDULER_LOG_FILE="${SCHEDULER_LOG_DIR}/opencode-db-maintenance.log"

# Helper paths are overrideable for tests. Empty values mean "auto-detect".
if [[ -z "${PULSE_LIFECYCLE_HELPER:-}" ]]; then
	if [[ -x "${SCRIPT_DIR}/pulse-lifecycle-helper.sh" ]]; then
		PULSE_LIFECYCLE_HELPER="${SCRIPT_DIR}/pulse-lifecycle-helper.sh"
	else
		PULSE_LIFECYCLE_HELPER="pulse-lifecycle-helper.sh"
	fi
fi
: "${OPENCODE_DB_ARCHIVE_HELPER:=${SCRIPT_DIR}/opencode-db-archive.sh}"
: "${SQLITE3_BIN:=sqlite3}"

# -----------------------------------------------------------------------------
# Output helpers (fallback if shared-constants didn't provide them)
# -----------------------------------------------------------------------------

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
fi

# -----------------------------------------------------------------------------
# Logging to state dir (separate from terminal output)
# -----------------------------------------------------------------------------

_log() {
	local level="$1"
	shift
	local msg="$*"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	mkdir -p "$STATE_DIR"
	printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

# _opencode_installed — 0 if opencode CLI and DB both present
_opencode_installed() {
	[[ -f "$OPENCODE_DB" ]] || return 1
	return 0
}

# _sqlite_available — 0 if sqlite3 is on PATH
_sqlite_available() {
	command -v sqlite3 >/dev/null 2>&1
}

# _opencode_process_count — number of running opencode processes
# Combines two signals to cover Homebrew, manual, and npm-installed builds:
#   1. pgrep against a broad regex that matches "opencode", ".opencode",
#      and path-prefixed variants like opencode-ai/bin/.opencode.
#   2. lsof against the DB file to catch any process holding it open,
#      even if argv doesn't contain the word "opencode" (e.g. via a
#      renamed binary).
# Deduplicates by PID so a process matched by both methods is counted once.
_opencode_process_count() {
	local pids=""
	# shellcheck disable=SC2009
	pids=$(pgrep -f '(^|/)\.?opencode($|[[:space:]])' 2>/dev/null || true)
	if [[ -f "$OPENCODE_DB" ]] && command -v lsof >/dev/null 2>&1; then
		local lsof_pids
		lsof_pids=$(lsof "$OPENCODE_DB" 2>/dev/null | awk 'NR>1 {print $2}' || true)
		pids=$(printf '%s\n%s\n' "$pids" "$lsof_pids")
	fi
	printf '%s\n' "$pids" | awk 'NF' | sort -u | wc -l | tr -d ' '
}

# _db_size_bytes <path> — portable file-size getter
_db_size_bytes() {
	local path="$1"
	[[ -f "$path" ]] || {
		echo 0
		return 0
	}
	_file_size_bytes "$path"
}

# _db_size_human <bytes> — portable human-readable byte formatter.
# Uses integer math with a fixed-point split so it works without bc.
_db_size_human() {
	local bytes="$1"
	if [[ "$bytes" -lt 1024 ]]; then
		echo "${bytes} B"
	elif [[ "$bytes" -lt 1048576 ]]; then
		# KB, 1 decimal: bytes*10/1024 → tenths of KB
		local tenths=$((bytes * 10 / 1024))
		printf '%d.%d KB\n' "$((tenths / 10))" "$((tenths % 10))"
	elif [[ "$bytes" -lt 1073741824 ]]; then
		# MB, 1 decimal
		local tenths=$((bytes * 10 / 1048576))
		printf '%d.%d MB\n' "$((tenths / 10))" "$((tenths % 10))"
	else
		# GB, 2 decimals
		local hundredths=$((bytes * 100 / 1073741824))
		printf '%d.%02d GB\n' "$((hundredths / 100))" "$((hundredths % 100))"
	fi
}

# _state_mtime_epoch <path> — portable file mtime getter for last-run state.
_state_mtime_epoch() {
	local path="$1"
	[[ -f "$path" ]] || {
		echo 0
		return 0
	}
	if declare -f _file_mtime_epoch >/dev/null 2>&1; then
		_file_mtime_epoch "$path"
		return 0
	fi
	echo 0
	return 0
}

# _pragma <db> <name>
_pragma() {
	local db="$1"
	local name="$2"
	sqlite3 "$db" "PRAGMA ${name};" 2>/dev/null
	return 0
}

_state_json_field() {
	local field="$1"
	[[ -f "$STATE_FILE" ]] || {
		printf '%s' ""
		return 0
	}
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg field "$field" '.[$field] // empty' "$STATE_FILE" 2>/dev/null || true
		return 0
	fi
	local value
	value=$(sed -n "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$STATE_FILE" 2>/dev/null | awk 'NR == 1 {print; exit}' || true)
	printf '%s' "$value"
	return 0
}

_freelist_exceeds_threshold() {
	local freelist_count="$1"
	local page_count="$2"
	[[ "$freelist_count" =~ ^[0-9]+$ && "$page_count" =~ ^[0-9]+$ && "$VACUUM_FREELIST_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
	[[ $((10#$page_count)) -eq 0 ]] && return 1
	local threshold_met
	threshold_met=$(awk -v free="$freelist_count" -v pages="$page_count" -v threshold="$VACUUM_FREELIST_THRESHOLD" 'BEGIN { if (pages <= 0) { print 0; exit } print ((free / pages) >= threshold) ? 1 : 0 }' </dev/null)
	if [[ "$threshold_met" == "1" ]]; then
		return 0
	fi
	return 1
}

# _wal_checkpoint_probe <db>
# Runs PRAGMA wal_checkpoint(PASSIVE) and emits "blocked log checkpointed"
# as space-separated integers. PASSIVE is non-blocking — safe with live sessions.
# blocked=1 means at least one reader still holds frames in the WAL.
# On sqlite3 error or empty output, emits "0 0 0".
_wal_checkpoint_probe() {
	local db="$1"
	[[ -f "$db" ]] || { printf '%s' "0 0 0"; return 0; }
	local result
	result=$(sqlite3 "$db" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || true)
	if [[ -z "$result" ]]; then
		printf '%s' "0 0 0"
		return 0
	fi
	local blocked log_pages ckpt_pages
	IFS='|' read -r blocked log_pages ckpt_pages <<<"$result"
	printf '%s %s %s' "${blocked:-0}" "${log_pages:-0}" "${ckpt_pages:-0}"
	return 0
}

# _wal_list_db_holders <db>
# Emits "PID CMDNAME" lines for processes holding <db> open (via lsof).
# Returns empty when lsof is unavailable or no holders found.
_wal_list_db_holders() {
	local db="$1"
	[[ -f "$db" ]] || return 0
	command -v lsof >/dev/null 2>&1 || return 0
	lsof "$db" 2>/dev/null | awk 'NR>1 {print $2, $1}' | sort -u || true
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: sessions
# -----------------------------------------------------------------------------

_sql_quote() {
	local value="$1"
	value=${value//\'/\'\'}
	printf "'%s'" "$value"
	return 0
}

_json_escape() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\t'/\\t}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	printf '%s' "$value"
	return 0
}

_sessions_column_exists() {
	local db="$1"
	local column="$2"
	if "$SQLITE3_BIN" -readonly "$db" "SELECT 1 FROM pragma_table_info('session') WHERE name='$column' LIMIT 1;" 2>/dev/null | grep -q '^1$'; then
		return 0
	fi
	return 1
}

_sessions_select_expr() {
	local db="$1"
	local column="$2"
	local fallback="$3"
	if _sessions_column_exists "$db" "$column"; then
		printf 's.%s' "$column"
	else
		printf '%s' "$fallback"
	fi
	return 0
}

_sessions_parent_title_expr() {
	local db="$1"
	if _sessions_column_exists "$db" "$SESSION_PARENT_ID_COLUMN"; then
		printf "COALESCE(p.title, '')"
	else
		printf "''"
	fi
	return 0
}

_sessions_from_join() {
	local db="$1"
	if _sessions_column_exists "$db" "$SESSION_PARENT_ID_COLUMN"; then
		printf 'session s LEFT JOIN session p ON p.id = s.%s' "$SESSION_PARENT_ID_COLUMN"
	else
		printf 'session s'
	fi
	return 0
}

_sessions_status_expr() {
	local db="$1"
	local source="$2"
	if [[ "$source" == "archive" ]]; then
		printf "'archived'"
	elif _sessions_column_exists "$db" "$SESSION_PARENT_ID_COLUMN"; then
		printf "CASE WHEN COALESCE(s.%s, '') <> '' THEN 'active-child' ELSE 'active-top-level' END" "$SESSION_PARENT_ID_COLUMN"
	else
		printf "'active-top-level'"
	fi
	return 0
}

_sessions_project_mismatch_expr() {
	local db="$1"
	if _sessions_column_exists "$db" "$SESSION_PROJECT_ID_COLUMN"; then
		printf "CASE WHEN COALESCE(s.directory, '') <> '' AND (SELECT COUNT(DISTINCT COALESCE(s2.%s, '')) FROM session s2 WHERE s2.directory = s.directory) > 1 THEN 'possible-project-id-mismatch' ELSE '' END" "$SESSION_PROJECT_ID_COLUMN"
	else
		printf "''"
	fi
	return 0
}

_sessions_query_db() {
	local db="$1"
	local source="$2"
	local query="$3"
	local exact_id="$4"
	local directory="$5"
	local limit="$6"

	[[ -f "$db" ]] || return 0

	local title_expr directory_expr project_expr parent_expr created_expr updated_expr parent_title_expr from_join status_expr mismatch_expr
	title_expr=$(_sessions_select_expr "$db" "title" "''")
	directory_expr=$(_sessions_select_expr "$db" "directory" "''")
	project_expr=$(_sessions_select_expr "$db" "$SESSION_PROJECT_ID_COLUMN" "''")
	parent_expr=$(_sessions_select_expr "$db" "$SESSION_PARENT_ID_COLUMN" "''")
	created_expr=$(_sessions_select_expr "$db" "time_created" "''")
	updated_expr=$(_sessions_select_expr "$db" "time_updated" "$created_expr")
	parent_title_expr=$(_sessions_parent_title_expr "$db")
	from_join=$(_sessions_from_join "$db")
	status_expr=$(_sessions_status_expr "$db" "$source")
	mismatch_expr=$(_sessions_project_mismatch_expr "$db")

	local where="1=1"
	if [[ -n "$exact_id" ]]; then
		where="s.id = $(_sql_quote "$exact_id")"
	elif [[ -n "$query" ]]; then
		local like
		like=$(_sql_quote "%${query}%")
		where="(s.id LIKE $like OR $title_expr LIKE $like OR $directory_expr LIKE $like OR $project_expr LIKE $like)"
	fi
	if [[ -n "$directory" ]]; then
		local dir_like
		dir_like=$(_sql_quote "%${directory}%")
		where="($where) AND $directory_expr LIKE $dir_like"
	fi

	"$SQLITE3_BIN" -readonly -separator $'\037' "$db" "
SELECT '$source', $status_expr, s.id, COALESCE($title_expr, ''), COALESCE($directory_expr, ''),
       COALESCE($project_expr, ''), COALESCE($parent_expr, ''), $parent_title_expr,
       COALESCE($created_expr, ''), COALESCE($updated_expr, ''), $mismatch_expr
FROM $from_join
WHERE $where
ORDER BY COALESCE($updated_expr, $created_expr, 0) DESC, s.id
LIMIT $limit;" 2>/dev/null || return 1
	return 0
}

_sessions_print_json() {
	local rows="$1"
	local first=true
	printf '[\n'
	while IFS=$'\037' read -r source status id title directory project_id parent_id parent_title created updated mismatch; do
		[[ -n "${id:-}" ]] || continue
		if [[ "$first" == true ]]; then
			first=false
		else
			printf ',\n'
		fi
		printf '  {"source":"%s","status":"%s","id":"%s","title":"%s","directory":"%s","project_id":"%s","parent_id":"%s","parent_title":"%s","created":"%s","updated":"%s","diagnostic":"%s"}' \
			"$(_json_escape "$source")" "$(_json_escape "$status")" "$(_json_escape "$id")" \
			"$(_json_escape "$title")" "$(_json_escape "$directory")" "$(_json_escape "$project_id")" \
			"$(_json_escape "$parent_id")" "$(_json_escape "$parent_title")" "$(_json_escape "$created")" \
			"$(_json_escape "$updated")" "$(_json_escape "$mismatch")"
	done <<<"$rows"
	printf '\n]\n'
	return 0
}

_sessions_print_table() {
	local rows="$1"
	printf '%-8s %-44s %-22s %-30s %-36s %s\n' "SOURCE" "STATUS" "ID" "TITLE" "PARENT" "DIRECTORY"
	printf '%-8s %-44s %-22s %-30s %-36s %s\n' "--------" "--------------------------------------------" "----------------------" "------------------------------" "------------------------------------" "---------"
	while IFS=$'\037' read -r source status id title directory project_id parent_id parent_title created updated mismatch; do
		[[ -n "${id:-}" ]] || continue
		local parent="-"
		if [[ -n "$parent_id" ]]; then
			parent="$parent_id"
			[[ -n "$parent_title" ]] && parent="${parent_id} (${parent_title})"
		fi
		[[ -n "$mismatch" ]] && status="${status}+${mismatch}"
		printf '%-8.8s %-44s %-22.22s %-30.30s %-36s %s\n' "$source" "$status" "$id" "$title" "$parent" "$directory"
	done <<<"$rows"
	printf '\nDiagnostic notes:\n'
	printf '  active-child: session has parent_id and may be hidden from top-level OpenCode session lists.\n'
	printf '  archived: row is in opencode-archive.db, which the OpenCode TUI/CLI does not read.\n'
	printf '  possible-project-id-mismatch: same directory has multiple project_id values.\n'
	return 0
}

cmd_sessions() {
	local query=""
	local exact_id=""
	local directory=""
	local include_archive=false
	local json=false
	local limit=20

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--query | -q)
			query="${2:-}"
			shift 2
			;;
		--id)
			exact_id="${2:-}"
			shift 2
			;;
		--directory | --dir)
			directory="${2:-}"
			shift 2
			;;
		--include-archive | --archive)
			include_archive=true
			shift
			;;
		--json)
			json=true
			shift
			;;
		--limit)
			limit="${2:-20}"
			shift 2
			;;
		--help | -h)
			printf 'Usage: opencode-db-maintenance-helper.sh sessions [--query TEXT|--id ID] [--directory PATH] [--include-archive] [--limit N] [--json]\n'
			return 0
			;;
		*)
			print_error "Unknown sessions option: $arg"
			return 1
			;;
		esac
	done

	if ! _sqlite_available; then
		print_error "${SQLITE3_BIN} CLI not available"
		return 1
	fi
	if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]]; then
		print_error "--limit must be a positive integer"
		return 1
	fi
	if [[ -n "$exact_id" && -n "$query" ]]; then
		print_error "Use either --id or --query, not both"
		return 1
	fi
	if [[ ! -f "$OPENCODE_DB" && "$include_archive" != true ]]; then
		print_info "opencode DB not found at $OPENCODE_DB"
		return 0
	fi

	local rows=""
	if [[ -f "$OPENCODE_DB" ]]; then
		rows+="$(_sessions_query_db "$OPENCODE_DB" "active" "$query" "$exact_id" "$directory" "$limit")"
	fi
	if [[ "$include_archive" == true && -f "$OPENCODE_ARCHIVE_DB" ]]; then
		[[ -n "$rows" ]] && rows+=$'\n'
		rows+="$(_sessions_query_db "$OPENCODE_ARCHIVE_DB" "archive" "$query" "$exact_id" "$directory" "$limit")"
	elif [[ "$include_archive" == true && "$json" != true ]]; then
		print_warning "archive DB not found at $OPENCODE_ARCHIVE_DB; continuing with active DB only"
	fi

	if [[ "$json" == true ]]; then
		_sessions_print_json "$rows"
	elif [[ -z "$rows" ]]; then
		print_info "No matching OpenCode sessions found"
	else
		_sessions_print_table "$rows"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: check
# -----------------------------------------------------------------------------

cmd_check() {
	local exit_code=0

	# Installation check
	if ! _opencode_installed; then
		print_info "opencode not installed (no DB at $OPENCODE_DB) — nothing to maintain"
		return 0
	fi

	# sqlite3 check
	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available on PATH — cannot run maintenance"
		return 1
	fi

	# Integrity check (quick)
	local integrity
	integrity=$(sqlite3 "$OPENCODE_DB" "PRAGMA quick_check;" 2>&1 || echo "error")
	if [[ "$integrity" != "ok" ]]; then
		print_error "quick_check failed: $integrity"
		exit_code=1
	else
		print_success "DB integrity quick_check: ok"
	fi

	# Active processes
	local n
	n=$(_opencode_process_count)
	if [[ "$n" -gt 0 ]]; then
		print_warning "$n opencode process(es) currently active — maintain will refuse without --force"
	else
		print_success "no opencode processes active — maintain is safe"
	fi

	# Size reporting
	local db_bytes wal_bytes
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")
	print_info "DB:  $(_db_size_human "$db_bytes") ($OPENCODE_DB)"
	print_info "WAL: $(_db_size_human "$wal_bytes") ($OPENCODE_WAL)"

	# WAL-specific warning: if WAL is large, probe checkpoint state and name blockers
	local wal_mb=$(( wal_bytes / 1048576 ))
	if [[ "$wal_mb" -ge "${WAL_LARGE_THRESHOLD_MB}" ]] && [[ -f "$OPENCODE_WAL" ]]; then
		local probe_result probe_blocked probe_log probe_ckpt
		probe_result=$(_wal_checkpoint_probe "$OPENCODE_DB")
		read -r probe_blocked probe_log probe_ckpt <<<"$probe_result"
		if [[ "$probe_blocked" == "1" ]]; then
			local unckpt=$(( probe_log - probe_ckpt ))
			print_warning "WAL large and checkpoint BUSY — ${unckpt} frame(s) still held by active readers"
			local holders
			holders=$(_wal_list_db_holders "$OPENCODE_DB")
			if [[ -n "$holders" ]]; then
				print_info "Active DB holders blocking WAL truncation (PID process):"
				while IFS=' ' read -r pid name; do
					print_info "  PID ${pid}  ${name}"
				done <<<"$holders"
			fi
			print_info "Next step: close all OpenCode sessions, then run:"
			print_info "  opencode-db-maintenance-helper.sh maintain"
		else
			print_info "WAL large but checkpoint is not blocked — run maintain to truncate"
		fi
	fi

	return "$exit_code"
}

# -----------------------------------------------------------------------------
# Subcommand: report
# -----------------------------------------------------------------------------

_report_print_compact_large_note() {
	local top_tables="$1"
	local top_table_name="" top_table_bytes="" top_table_line=""
	if [[ -n "$top_tables" ]]; then
		top_table_line=${top_tables%%$'\n'*}
		top_table_name=${top_table_line%%|*}
		top_table_bytes=${top_table_line#*|}
	fi
	printf '\n  Maintenance note: DB is compact but large; WAL and free pages are below maintenance thresholds.\n'
	if [[ -n "$top_table_name" && "$top_table_line" == *'|'* ]]; then
		printf '                    Largest object is %s (%s), which may be retained live data.\n' \
			"$top_table_name" "$(_db_size_human "$top_table_bytes")"
	fi
	printf '                    Re-running maintenance-window is unlikely to reclaim space.\n'
	return 0
}

_report_print_wal_status() {
	local wal_bytes="$1"
	local wal_mb_report=$((wal_bytes / 1048576))
	[[ "$wal_mb_report" -ge "${WAL_LARGE_THRESHOLD_MB}" ]] || return 0
	[[ -f "$OPENCODE_WAL" ]] || return 0
	local rp_result rp_blocked rp_log rp_ckpt
	rp_result=$(_wal_checkpoint_probe "$OPENCODE_DB")
	read -r rp_blocked rp_log rp_ckpt <<<"$rp_result"
	if [[ "$rp_blocked" == "1" ]]; then
		local rp_unckpt=$((rp_log - rp_ckpt))
		printf '  WAL status:    BUSY — checkpoint blocked by active readers\n'
		printf '                 (%s frames total, %s checkpointed, %s held)\n' \
			"$rp_log" "$rp_ckpt" "$rp_unckpt"
		local rp_holders
		rp_holders=$(_wal_list_db_holders "$OPENCODE_DB")
		if [[ -n "$rp_holders" ]]; then
			printf '  WAL blockers:  (PID process)\n'
			while IFS=' ' read -r pid name; do
				printf '                 PID %-8s %s\n' "$pid" "$name"
			done <<<"$rp_holders"
		fi
		printf '  Next step:     close all OpenCode sessions, then:\n'
		printf '                 opencode-db-maintenance-helper.sh maintain\n'
	else
		printf '  WAL status:    ok (checkpoint not blocked)\n'
	fi
	return 0
}

cmd_report() {
	if ! _opencode_installed; then
		print_info "opencode not installed — nothing to report"
		return 0
	fi
	if ! _sqlite_available; then
		print_error "${SQLITE3_BIN} CLI not available"
		return 1
	fi

	local db_bytes wal_bytes
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")

	local page_count page_size freelist_count
	page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
	page_size=$(_pragma "$OPENCODE_DB" "page_size")
	freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
	if [[ ! "$page_count" =~ ^[0-9]+$ || ! "$freelist_count" =~ ^[0-9]+$ || ! "$page_size" =~ ^[0-9]+$ ]]; then
		print_error "Unable to read SQLite page counts or page size from $OPENCODE_DB"; return 1
	fi

	local freelist_pct=0
	if [[ $((10#$page_count)) -ne 0 ]]; then
		freelist_pct=$(awk -v free="$freelist_count" -v pages="$page_count" 'BEGIN { if (pages <= 0) { print "0"; exit } printf "%.2f", (free * 100) / pages }' </dev/null)
	fi

	local journal_mode sync_mode busy_timeout mmap_size
	journal_mode=$(_pragma "$OPENCODE_DB" "journal_mode")
	sync_mode=$(_pragma "$OPENCODE_DB" "synchronous")
	busy_timeout=$(_pragma "$OPENCODE_DB" "busy_timeout")
	mmap_size=$(_pragma "$OPENCODE_DB" "mmap_size")

	printf '\n%b== OpenCode DB Report ==%b\n\n' "$BLUE" "$NC"
	printf '  Path:          %s\n' "$OPENCODE_DB"
	printf '  DB size:       %s\n' "$(_db_size_human "$db_bytes")"
	printf '  WAL size:      %s\n' "$(_db_size_human "$wal_bytes")"
	# WAL status: distinguish active-DB table size from WAL size; show checkpoint state
	# when WAL is large so users understand why it hasn't shrunk after archiving.
	_report_print_wal_status "$wal_bytes"
	printf '  Pages:         %s (page_size=%sB)\n' "$page_count" "$page_size"
	printf '  Free pages:    %s (%s%% of total)\n' "$freelist_count" "$freelist_pct"
	local compact_large=false
	if [[ $((db_bytes / 1048576)) -ge "$FORCE_VACUUM_SIZE_MB" ]] && \
		[[ $((wal_bytes / 1048576)) -lt "$WAL_LARGE_THRESHOLD_MB" ]] && \
		! _freelist_exceeds_threshold "$freelist_count" "$page_count"; then
		compact_large=true
	fi
	printf '\n  PRAGMAs (fresh CLI connection — not what opencode uses):\n'
	printf '    journal_mode = %s\n' "$journal_mode"
	printf '    synchronous  = %s\n' "$sync_mode"
	printf '    busy_timeout = %s\n' "$busy_timeout"
	printf '    mmap_size    = %s\n' "$mmap_size"

	# Top tables by size if dbstat is available
	local top_tables
	top_tables=$(sqlite3 "$OPENCODE_DB" \
		"SELECT name, SUM(pgsize) FROM dbstat WHERE aggregate=TRUE GROUP BY name ORDER BY 2 DESC LIMIT 5;" 2>/dev/null || true)
	if [[ -z "$top_tables" ]]; then
		# Fallback without aggregate
		top_tables=$(sqlite3 "$OPENCODE_DB" \
			"SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 5;" 2>/dev/null || true)
	fi
	if [[ -n "$top_tables" ]]; then
		printf '\n  Top 5 tables/indexes by size:\n'
		printf '%s\n' "$top_tables" | while IFS='|' read -r name bytes; do
			printf '    %-40s %s\n' "$name" "$(_db_size_human "$bytes")"
		done
	fi
	if [[ "$compact_large" == true ]]; then
		_report_print_compact_large_note "$top_tables"
	fi

	# Last run info
	if [[ -f "$STATE_FILE" ]]; then
		printf '\n  Last maintenance run:\n'
		if command -v jq >/dev/null 2>&1; then
			jq -r '. | "    timestamp:       \(.timestamp)\n    outcome:         \(.outcome)\n    duration_sec:    \(.duration_sec)\n    bytes_reclaimed: \(.bytes_reclaimed)"' "$STATE_FILE" 2>/dev/null || cat "$STATE_FILE"
		else
			cat "$STATE_FILE"
		fi
	else
		printf '\n  No previous maintenance runs recorded.\n'
	fi

	echo
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: maintain
# -----------------------------------------------------------------------------
# Runs wal_checkpoint(TRUNCATE) → PRAGMA optimize → optional VACUUM.
# Aborts with exit 2 if opencode processes are active, unless --force.

# _maintain_preflight <force:bool> <is_auto:bool>
# Validates environment before maintenance. Returns 0 to proceed, other
# codes to exit cmd_maintain with (handled by caller).
_maintain_preflight() {
	local force="$1"
	local is_auto="$2"

	if ! _opencode_installed; then
		if [[ "$is_auto" == true ]]; then
			_log INFO "auto: opencode not installed — no-op"
			return 100
		fi
		print_info "opencode not installed — nothing to maintain"
		return 100
	fi

	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available"
		return 1
	fi

	local n
	n=$(_opencode_process_count)
	if [[ "$n" -gt 0 ]]; then
		if [[ "$force" == true ]]; then
			print_warning "$n opencode process(es) active — running anyway (--force)"
			_log WARN "--force: proceeding with $n active processes"
			return 0
		fi
		print_warning "$n opencode process(es) currently active"
		print_info "Close all opencode TUIs first, or re-run with --force (may cause session errors)"
		_log INFO "refused: $n active processes (no --force)"
		return 2
	fi
	return 0
}

# _maintain_should_vacuum <before_bytes>
# Echoes "true"/"false" based only on reclaimable freelist fragmentation.
_maintain_should_vacuum() {
	local before_bytes="$1"
	local freelist_count page_count size_mb
	freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
	page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
	size_mb=$((before_bytes / 1048576))

	if _freelist_exceeds_threshold "$freelist_count" "$page_count"; then
		printf '%s %s %s %s' true "$freelist_count" "$page_count" "$size_mb"
		return 0
	fi
	printf '%s %s %s %s' false "$freelist_count" "$page_count" "$size_mb"
	return 0
}

# _maintain_vacuum_capacity <before_bytes>
# Emits "available_kb required_kb reason". VACUUM may need one database-sized
# temporary copy plus one database-sized WAL. Requiring 3x the DB size as free
# space reserves an additional database-sized safety margin.
_maintain_vacuum_capacity() {
	local before_bytes="$1"
	local db_kb=$(((before_bytes + 1023) / 1024))
	local required_kb=$((db_kb * VACUUM_FREE_SPACE_MULTIPLIER))
	local available_kb=0
	local reason="capacity-unknown"

	if ! declare -f aidevops_disk_capacity_snapshot >/dev/null 2>&1; then
		printf '%s %s %s' "$available_kb" "$required_kb" "$reason"
		return 2
	fi
	if ! aidevops_disk_capacity_snapshot "$OPENCODE_DB"; then
		printf '%s %s %s' "$available_kb" "$required_kb" "$reason"
		return 2
	fi
	available_kb="$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB"
	if [[ "$available_kb" -lt "$required_kb" ]]; then
		reason="insufficient-capacity"
		printf '%s %s %s' "$available_kb" "$required_kb" "$reason"
		return 1
	fi
	printf '%s %s %s' "$available_kb" "$required_kb" "available"
	return 0
}

# _maintain_run_steps <before_bytes>
# Runs the SQLite maintenance steps. Echoes
# "step_failures vacuum_ran vacuum_deferred".
_maintain_run_steps() {
	local before_bytes="$1"
	local step_failures=0
	local vacuum_ran=false
	local vacuum_deferred=false

	# Step 1: Truncate WAL — fold pending writes back into main DB and shrink the WAL file.
	print_info "Step 1/3: wal_checkpoint(TRUNCATE)..."
	if ! sqlite3 "$OPENCODE_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
		print_warning "wal_checkpoint failed (non-fatal)"
		_log WARN "wal_checkpoint failed"
		step_failures=$((step_failures + 1))
	fi

	# Step 2: Refresh query planner stats.
	print_info "Step 2/3: PRAGMA optimize..."
	if ! sqlite3 "$OPENCODE_DB" "PRAGMA optimize;" >/dev/null 2>&1; then
		print_warning "PRAGMA optimize failed (non-fatal)"
		_log WARN "optimize failed"
		step_failures=$((step_failures + 1))
	fi

	# Step 3: VACUUM only if needed — it rewrites the entire DB.
	local vacuum_decision
	vacuum_decision=$(_maintain_should_vacuum "$before_bytes")
	local do_vacuum freelist_count page_count size_mb
	read -r do_vacuum freelist_count page_count size_mb <<<"$vacuum_decision"

	if [[ "$do_vacuum" == true ]]; then
		local capacity_result capacity_rc=0 available_kb=0 required_kb=0 capacity_reason=""
		capacity_result=$(_maintain_vacuum_capacity "$before_bytes") || capacity_rc=$?
		read -r available_kb required_kb capacity_reason <<<"$capacity_result"
		if [[ "$capacity_rc" -ne 0 ]]; then
			vacuum_deferred=true
			print_warning "Step 3/3: VACUUM deferred (${capacity_reason}; available ${available_kb} KiB, required ${required_kb} KiB)"
			_log WARN "VACUUM deferred: reason=${capacity_reason} available_kb=${available_kb} required_kb=${required_kb}"
		else
			print_info "Step 3/3: VACUUM (DB ${size_mb} MB, ${freelist_count}/${page_count} free pages; ${available_kb} KiB available)..."
			local vacuum_err
			vacuum_ran=true
			if ! vacuum_err=$(sqlite3 "$OPENCODE_DB" "VACUUM;" 2>&1); then
				print_error "VACUUM failed: ${vacuum_err}"
				_log ERROR "VACUUM failed: ${vacuum_err}"
				step_failures=$((step_failures + 1))
			fi
		fi
	else
		print_info "Step 3/3: VACUUM skipped (low fragmentation: ${freelist_count}/${page_count} free pages, ${size_mb} MB)"
	fi

	# VACUUM itself can write a large WAL. The manual 2026-05-01 run saw
	# maintenance report success while opencode.db-wal grew to DB-size. Always
	# checkpoint again after VACUUM so success means "DB compact and WAL folded".
	if [[ "$vacuum_ran" == true ]]; then
		print_info "Final step: post-VACUUM wal_checkpoint(TRUNCATE)..."
		local final_ckpt
		if ! final_ckpt=$("$SQLITE3_BIN" "$OPENCODE_DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1); then
			print_warning "post-VACUUM wal_checkpoint failed (non-fatal): ${final_ckpt}"
			_log WARN "post-VACUUM wal_checkpoint failed: ${final_ckpt}"
			step_failures=$((step_failures + 1))
		elif [[ "$final_ckpt" == 1\|* ]]; then
			print_warning "post-VACUUM wal_checkpoint busy: ${final_ckpt}"
			_log WARN "post-VACUUM wal_checkpoint busy: ${final_ckpt}"
			step_failures=$((step_failures + 1))
		fi
	fi

	printf '%s %s %s' "$step_failures" "$vacuum_ran" "$vacuum_deferred"
	return 0
}

# _maintain_write_state <before_bytes> <after_bytes> <before_wal> <after_wal> <duration> <vacuum_ran> <vacuum_deferred> <step_failures>
# Writes last-run.json and prints the summary.
_maintain_write_state() {
	local before_bytes="$1"
	local after_bytes="$2"
	local before_wal="$3"
	local after_wal="$4"
	local duration="$5"
	local vacuum_ran="$6"
	local vacuum_deferred="$7"
	local step_failures="$8"
	local reclaimed=$((before_bytes - after_bytes))
	local outcome="success"
	if [[ "$step_failures" -gt 0 ]]; then
		outcome="partial"
	elif [[ "$vacuum_deferred" == true ]]; then
		outcome="deferred"
	fi

	mkdir -p "$STATE_DIR"
	cat >"$STATE_FILE" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "outcome": "$outcome",
  "duration_sec": $duration,
  "bytes_before": $before_bytes,
  "bytes_after": $after_bytes,
  "bytes_reclaimed": $reclaimed,
  "wal_before": $before_wal,
  "wal_after": $after_wal,
  "vacuum_ran": $vacuum_ran,
  "vacuum_deferred": $vacuum_deferred,
  "step_failures": $step_failures
}
EOF

	if [[ "$outcome" == "partial" ]]; then
		print_warning "Maintenance partially completed in ${duration}s"
	elif [[ "$outcome" == "deferred" ]]; then
		print_warning "Maintenance deferred after safe preliminary steps in ${duration}s"
	else
		print_success "Maintenance complete in ${duration}s"
	fi
	print_info "DB:  $(_db_size_human "$before_bytes") → $(_db_size_human "$after_bytes") (reclaimed $(_db_size_human "$reclaimed"))"
	print_info "WAL: $(_db_size_human "$before_wal") → $(_db_size_human "$after_wal")"
	_log INFO "done: outcome=$outcome duration=${duration}s reclaimed=${reclaimed} step_failures=${step_failures}"
	return 0
}

cmd_maintain() {
	local force=false
	local is_auto=false
	local arg
	for arg in "$@"; do
		case "$arg" in
		--force) force=true ;;
		--auto) is_auto=true ;;
		esac
	done

	_maintain_preflight "$force" "$is_auto"
	local rc=$?
	# 100 = clean no-op (opencode not installed)
	[[ "$rc" -eq 100 ]] && return 0
	# Any other non-zero = error, propagate
	[[ "$rc" -ne 0 ]] && return "$rc"

	local start_epoch before_bytes before_wal
	start_epoch=$(date +%s)
	before_bytes=$(_db_size_bytes "$OPENCODE_DB")
	before_wal=$(_db_size_bytes "$OPENCODE_WAL")

	print_info "Starting maintenance (DB: $(_db_size_human "$before_bytes"), WAL: $(_db_size_human "$before_wal"))"
	_log INFO "start: db=${before_bytes} wal=${before_wal}"

	local steps_result
	steps_result=$(_maintain_run_steps "$before_bytes")
	local step_failures vacuum_ran vacuum_deferred
	read -r step_failures vacuum_ran vacuum_deferred <<<"$steps_result"

	local end_epoch after_bytes after_wal duration
	end_epoch=$(date +%s)
	after_bytes=$(_db_size_bytes "$OPENCODE_DB")
	after_wal=$(_db_size_bytes "$OPENCODE_WAL")
	duration=$((end_epoch - start_epoch))

	_maintain_write_state "$before_bytes" "$after_bytes" "$before_wal" "$after_wal" \
		"$duration" "$vacuum_ran" "$vacuum_deferred" "$step_failures"

	if [[ "$step_failures" -gt 0 ]]; then
		return 10
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: maintenance-window
# -----------------------------------------------------------------------------
# Explicitly disruptive run for off-hours windows: stop aidevops-managed pulse
# processes, archive old sessions, run DB maintenance, then restart pulse even
# when a step fails. Interactive OpenCode TUIs are not stopped; they require
# --force-opencode so the operator consciously accepts the risk.

cmd_maintenance_window() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	local force_opencode=false
	local keep_sessions="$MAINTENANCE_WINDOW_KEEP_SESSIONS"
	local retention_days="$MAINTENANCE_WINDOW_RETENTION_DAYS"
	local skip_archive=false
	local arg

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--force-opencode)
			force_opencode=true; shift
			;;
		--keep-sessions)
			keep_sessions="${2:-}"; shift 2
			;;
		--retention-days)
			retention_days="${2:-}"; shift 2
			;;
		--skip-archive)
			skip_archive=true; shift
			;;
		*)
			print_error "Unknown maintenance-window option: $arg"
			return 1
			;;
		esac
	done

	[[ "$keep_sessions" =~ ^[0-9]+$ ]] || { print_error "--keep-sessions must be a non-negative integer: ${keep_sessions}"; return 1; }
	[[ "$retention_days" =~ ^[0-9]+$ ]] || { print_error "--retention-days must be a non-negative integer: ${retention_days}"; return 1; }
	if ! _opencode_installed; then
		print_info "opencode not installed — nothing to maintain"
		return 0
	fi
	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available"
		return 1
	fi

	if command -v "$PULSE_LIFECYCLE_HELPER" >/dev/null 2>&1; then
		print_info "Stopping pulse for maintenance window..."
		"$PULSE_LIFECYCLE_HELPER" stop || print_warning "pulse stop returned non-zero; continuing with DB holder checks"
		local restart_cmd
		restart_cmd=$(printf '%q start' "$PULSE_LIFECYCLE_HELPER")
		push_cleanup "$restart_cmd"
	else
		print_warning "pulse lifecycle helper not found; skipping pulse stop/start"
	fi

	local active_count
	active_count=$(_opencode_process_count)
	if [[ "$active_count" -gt 0 ]] && [[ "$force_opencode" != true ]]; then
		print_warning "$active_count OpenCode DB holder(s) still active after stopping pulse"
		print_info "maintenance-window stops pulse/headless workers only; close interactive TUIs or pass --force-opencode"
		return 2
	fi

	local rc=0
	if [[ "$skip_archive" != true ]] && [[ -x "$OPENCODE_DB_ARCHIVE_HELPER" ]]; then
		print_info "Archiving old OpenCode sessions (inactive ${retention_days}+ days and outside newest ${keep_sessions})..."
		"$OPENCODE_DB_ARCHIVE_HELPER" archive --retention-days "$retention_days" --keep-sessions "$keep_sessions" --max-duration-seconds 300 || rc=$?
		if [[ "$rc" -ne 0 ]]; then
			print_warning "archive step failed (rc=${rc}); continuing to maintenance"
		fi
	fi

	local maintain_args=()
	if [[ "$force_opencode" == true ]]; then
		maintain_args+=(--force)
	fi
	cmd_maintain "${maintain_args[@]}" || rc=$?

	local integrity
	integrity=$("$SQLITE3_BIN" "$OPENCODE_DB" "$SQLITE_QUICK_CHECK" 2>&1 || echo "error")
	if [[ "$integrity" != "ok" ]]; then
		print_error "post-maintenance quick_check failed: $integrity"
		rc=1
	else
		print_success "post-maintenance quick_check: ok"
	fi

	trap - RETURN
	_run_cleanups
	return "$rc"
}

# -----------------------------------------------------------------------------
# Subcommand: auto
# -----------------------------------------------------------------------------
# Safe wrapper for the weekly r913 routine. Exits 0 silently when opencode
# isn't installed (other users benefit from the routine being registered
# without seeing errors).

cmd_auto() {
	# Silent no-op if opencode not installed
	if ! _opencode_installed; then
		_log INFO "auto: opencode not installed — no-op"
		return 0
	fi

	# Throttle: skip if last run was recent
	if [[ -f "$STATE_FILE" ]]; then
		local last_ts_str last_epoch now_epoch delta
		if command -v jq >/dev/null 2>&1; then
			last_ts_str=$(jq -r '.timestamp // empty' "$STATE_FILE" 2>/dev/null || true)
		else
			last_ts_str=$(grep -Eo '"timestamp":[[:space:]]*"[^"]+"' "$STATE_FILE" 2>/dev/null |
				sed 's/.*"\([^"]*\)"$/\1/' || true)
		fi
		if [[ -n "$last_ts_str" ]]; then
			# Try GNU date first, then BSD date
			last_epoch=$(date -u -d "$last_ts_str" +%s 2>/dev/null ||
				date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts_str" +%s 2>/dev/null ||
				echo 0)
			now_epoch=$(date +%s)
			delta=$((now_epoch - last_epoch))
			if [[ "$delta" -lt "$AUTO_MIN_SECONDS_BETWEEN" ]]; then
				_log INFO "auto: throttled (last run ${delta}s ago, min ${AUTO_MIN_SECONDS_BETWEEN}s)"
				print_info "Skipping: last maintenance was ${delta}s ago (threshold: ${AUTO_MIN_SECONDS_BETWEEN}s)"
				return 0
			fi
		fi
	fi

	# Delegate to maintain without --force (respects active processes).
	# Exit 2 = "opencode is running, skipping" — this is expected state for
	# a scheduled routine, not a failure. Translate to exit 0 so the
	# scheduler doesn't flag it as a failed run.
	local rc=0
	cmd_maintain --auto || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		_log INFO "auto: skipped — opencode active"
		return 0
	fi
	return "$rc"
}

# -----------------------------------------------------------------------------
# Subcommand: install / uninstall / status (macOS launchd scheduler, t2183)
# -----------------------------------------------------------------------------
# Helper owns its plist generation (Approach B, mirrors repo-sync-helper.sh).
# Linux systemd/cron install is handled by .agents/scripts/setup/modules/schedulers.sh calling
# _install_scheduler_linux — these subcommands are macOS-only; on Linux they
# print an info message and exit 0 (success, nothing to do here).

# _is_macos — 0 on Darwin
_is_macos() {
	[[ "$(uname -s)" == "Darwin" ]]
}

# _launchd_is_loaded — 0 if our LaunchAgent is listed
# SIGPIPE-safe under set -o pipefail (t1265): capture to variable first
_launchd_is_loaded() {
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$LAUNCHD_LABEL"
}

# _resolve_self_path — emit the path that launchd should exec.
# Prefer the deployed copy at ~/.aidevops/agents/scripts/ so the LaunchAgent
# survives repo moves. Fall back to the running script's dir when the deployed
# copy is missing (first-install from a checkout).
_resolve_self_path() {
	local deployed="${HOME}/.aidevops/agents/scripts/opencode-db-maintenance-helper.sh"
	if [[ -f "$deployed" ]]; then
		printf '%s' "$deployed"
	else
		printf '%s' "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
	fi
}

# _generate_plist_content <self_path>
# Emit the LaunchAgent plist XML for the r913 weekly schedule.
# Uses StartCalendarInterval (not StartInterval) with Weekday=0 (Sunday),
# Hour=4, Minute=0 — matches the routine's declared "weekly(sun@04:00)".
_generate_plist_content() {
	local self_path="$1"
	local scheduler_subcommand="auto"
	if [[ "$OPENCODE_DB_MAINTENANCE_MODE" == "$MAINTENANCE_WINDOW_MODE" ]]; then
		scheduler_subcommand="$MAINTENANCE_WINDOW_MODE"
	fi
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${self_path}</string>
		<string>${scheduler_subcommand}</string>
$([[ "$scheduler_subcommand" == "$MAINTENANCE_WINDOW_MODE" ]] && printf '\t\t<string>--force-opencode</string>\n')
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Weekday</key>
		<integer>0</integer>
		<key>Hour</key>
		<integer>${OPENCODE_DB_MAINTENANCE_HOUR}</integer>
		<key>Minute</key>
		<integer>${OPENCODE_DB_MAINTENANCE_MINUTE}</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>${SCHEDULER_LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${SCHEDULER_LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
EOF
}

cmd_install() {
	if ! _is_macos; then
		print_info "install: Linux scheduling is handled by .agents/scripts/setup/modules/schedulers.sh (systemd/cron)"
		print_info "This helper's install subcommand is macOS-only — exiting cleanly"
		return 0
	fi

	mkdir -p "$LAUNCHD_DIR" "$SCHEDULER_LOG_DIR"

	local self_path new_content
	self_path=$(_resolve_self_path)
	new_content=$(_generate_plist_content "$self_path")

	# Content-diff: skip reload if identical and already loaded (same semantics
	# as _launchd_install_if_changed in setup.sh).
	if [[ -f "$LAUNCHD_PLIST" ]] && _launchd_is_loaded; then
		local existing
		existing=$(cat "$LAUNCHD_PLIST" 2>/dev/null || echo "")
		if [[ "$existing" == "$new_content" ]]; then
			print_info "Already installed with identical config ($LAUNCHD_LABEL)"
			return 0
		fi
	fi

	# Unload before replacing plist (avoid stale config)
	if _launchd_is_loaded; then
		launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
	fi

	printf '%s\n' "$new_content" >"$LAUNCHD_PLIST"
	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		print_success "opencode DB maintenance scheduled (weekly, Sun 04:00 local)"
		print_info "  Label:  $LAUNCHD_LABEL"
		print_info "  Plist:  $LAUNCHD_PLIST"
		print_info "  Script: $self_path"
		print_info "  Logs:   $SCHEDULER_LOG_FILE"
		_log INFO "install: LaunchAgent loaded ($LAUNCHD_LABEL → $self_path)"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		_log ERROR "install: launchctl load failed"
		return 1
	fi
	return 0
}

cmd_uninstall() {
	if ! _is_macos; then
		print_info "uninstall: Linux scheduling is handled by .agents/scripts/setup/modules/schedulers.sh"
		return 0
	fi

	local changed=false
	if _launchd_is_loaded; then
		launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
		changed=true
	fi
	if [[ -f "$LAUNCHD_PLIST" ]]; then
		rm -f "$LAUNCHD_PLIST"
		changed=true
	fi

	if [[ "$changed" == true ]]; then
		print_success "LaunchAgent removed ($LAUNCHD_LABEL)"
		_log INFO "uninstall: LaunchAgent removed"
	else
		print_info "Not installed (nothing to remove)"
	fi
	return 0
}

cmd_status() {
	local installed=false
	if _is_macos; then
		if _launchd_is_loaded; then
			print_success "macOS LaunchAgent loaded: $LAUNCHD_LABEL"
			installed=true
		fi
		if [[ -f "$LAUNCHD_PLIST" ]]; then
			print_info "  Plist: $LAUNCHD_PLIST"
		fi
	fi

	if command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled aidevops-opencode-db-maintenance.timer >/dev/null 2>&1; then
		print_success "Linux systemd timer enabled: aidevops-opencode-db-maintenance.timer"
		installed=true
	fi

	if command -v crontab >/dev/null 2>&1 &&
		crontab -l 2>/dev/null | grep -qF "aidevops: opencode-db-maintenance"; then
		print_success "Cron entry installed"
		installed=true
	fi

	if [[ "$installed" == false ]]; then
		print_info "Scheduler not installed (run: opencode-db-maintenance-helper.sh install)"
	fi

	if [[ -f "$SCHEDULER_LOG_FILE" ]]; then
		print_info "  Log:   $SCHEDULER_LOG_FILE"
	fi
	return 0
}

# Subcommand: notice
# Emits at most one warning line for OpenCode's session-start toast.
cmd_notice() {
	if ! _opencode_installed; then
		return 0
	fi

	if [[ "$OPENCODE_DB_MAINTENANCE_MODE" == "$MAINTENANCE_WINDOW_MODE" ]]; then
		printf '[OPENCODE MAINTENANCE] Scheduled weekly Sun %02d:%02d local: maintenance-window pauses pulse/headless workers while compacting opencode.db.\n' \
			"$OPENCODE_DB_MAINTENANCE_HOUR" "$OPENCODE_DB_MAINTENANCE_MINUTE"
		return 0
	fi

	local now last_ts age db_bytes wal_bytes db_mb wal_mb due=false reason="" compact_notice=false
	now=$(date +%s)
	last_ts=$(_state_mtime_epoch "$STATE_FILE")
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")
	db_mb=$((db_bytes / 1048576))
	wal_mb=$((wal_bytes / 1048576))

	if [[ "$last_ts" -eq 0 ]]; then
		due=true
		reason="no previous run recorded"
	else
		age=$((now - last_ts))
		if [[ "$age" -ge "$AUTO_MIN_SECONDS_BETWEEN" ]]; then
			due=true
			reason="last run older than scheduler interval"
		fi
	fi

	if [[ "$wal_mb" -ge "$WAL_LARGE_THRESHOLD_MB" ]]; then
		due=true
		reason="WAL ${wal_mb}MB >= ${WAL_LARGE_THRESHOLD_MB}MB"
	elif [[ "$db_mb" -ge "$FORCE_VACUUM_SIZE_MB" ]]; then
		if [[ "$due" == true ]]; then
			reason="${reason}; DB ${db_mb}MB >= ${FORCE_VACUUM_SIZE_MB}MB"
		elif _sqlite_available; then
			local page_count freelist_count state_outcome
			page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
			freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
			[[ "$page_count" =~ ^[0-9]+$ ]] || page_count=0
			[[ "$freelist_count" =~ ^[0-9]+$ ]] || freelist_count=0
			state_outcome=$(_state_json_field "outcome")
			if [[ "$last_ts" -gt 0 ]] && [[ "$state_outcome" == "success" ]] && \
				! _freelist_exceeds_threshold "$freelist_count" "$page_count"; then
				compact_notice=true
			else
				due=true
				reason="DB ${db_mb}MB >= ${FORCE_VACUUM_SIZE_MB}MB"
			fi
		else
			due=true
			reason="DB ${db_mb}MB >= ${FORCE_VACUUM_SIZE_MB}MB"
		fi
	fi

	if [[ "$due" == true ]]; then
		printf '[OPENCODE MAINTENANCE] Recommended: %s. Run aidevops opencode-db maintenance-window off-hours; pulse/headless workers pause during the window.\n' "$reason"
	elif [[ "$compact_notice" == true ]]; then
		printf '[OPENCODE MAINTENANCE] Compact but large: DB %sMB >= %sMB, WAL is low, and free pages are below threshold after recent successful maintenance. Re-running maintenance-window is unlikely to reclaim space; run aidevops opencode-db report for retained-data details.\n' \
			"$db_mb" "$FORCE_VACUUM_SIZE_MB"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

cmd_help() {
	cat <<'EOF'
opencode-db-maintenance-helper.sh — periodic SQLite maintenance for opencode

Usage:
  opencode-db-maintenance-helper.sh <subcommand> [options]

Subcommands:
  check                  Preflight: DB exists, sqlite3 available, no locks
  report                 Human-readable DB stats (size, pages, free list, PRAGMAs)
  maintain [--force]     Run maintenance. Aborts if opencode processes active
                         unless --force is passed (may cause session errors).
  maintenance-window     Disruptive off-hours mode: stop pulse/headless workers,
                         archive old sessions, maintain DB, quick_check, restart pulse.
                         Pass --force-opencode to continue with interactive TUIs open.
  auto                   Safe mode for scheduled use (r913). Silent no-op when
                         opencode not installed; throttles rapid re-runs.
  install                macOS: install/refresh LaunchAgent (weekly Sun 04:00).
                         Linux: no-op (handled by .agents/scripts/setup/modules/schedulers.sh).
  uninstall              macOS: remove LaunchAgent. Idempotent.
  status                 Report scheduler state (launchd/systemd/cron).
  notice                 Emit one toast-safe warning when maintenance is due or disruptive mode is scheduled.
  sessions               Read-only lookup for active child, archived, and project-id-hidden sessions.
  help                   This help

What maintenance does:
  1. wal_checkpoint(TRUNCATE) — folds pending writes back into main DB
  2. PRAGMA optimize         — refreshes query planner stats
  3. VACUUM (conditional)    — reclaims free pages only when the free-page
                               fraction exceeds 10% and 3x DB size is free

Why it helps:
  opencode SQLite locks ("database is locked") surface when a writer holds
  the WAL beyond the compiled busy_timeout (5s). Smaller DB and shorter WAL
  = shorter lock windows = fewer session-halting errors.
  Full upstream context: anomalyco/opencode #21215, #21000, #20935.

Environment variables (advanced):
  VACUUM_FREELIST_THRESHOLD    Fraction of free pages triggering VACUUM (default 0.10)
  FORCE_VACUUM_SIZE_MB         Compact-large reporting threshold (default 500)
  AUTO_MIN_SECONDS_BETWEEN     Throttle for auto mode (default 518400 = 6 days)
  WAL_LARGE_THRESHOLD_MB       Warn/report large WAL above this size (default 500)
  MAINTENANCE_WINDOW_KEEP_SESSIONS  Archive keep target for maintenance-window (default 500)
  MAINTENANCE_WINDOW_RETENTION_DAYS Preserve active /sessions history during maintenance-window (default 30)
  OPENCODE_DB_MAINTENANCE_HOUR Scheduled local hour for install (default 4)
  OPENCODE_DB_MAINTENANCE_MINUTE Scheduled local minute for install (default 0)
  OPENCODE_DB_MAINTENANCE_MODE  Scheduler mode: auto or maintenance-window
  OPENCODE_DB_PATH              Active DB override for sessions/maintenance
  OPENCODE_ARCHIVE_DB           Archive DB override for sessions lookup

Session lookup examples:
  opencode-db-maintenance-helper.sh sessions --query "24396" --include-archive
  opencode-db-maintenance-helper.sh sessions --id "ses_..." --json
  opencode-db-maintenance-helper.sh sessions --directory "/path/to/repo" --limit 20

State:
  ~/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json
  ~/.aidevops/.agent-workspace/work/opencode-maintenance/maintenance.log

Exit codes:
  0   success (including auto no-op)
  1   DB unreadable, integrity check failed, sqlite3 missing
  2   opencode processes active (maintain without --force)
  10  partial success (some step failed)
EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

main() {
	local sub="${1:-help}"
	shift || true
	case "$sub" in
	check) cmd_check "$@" ;;
	report) cmd_report "$@" ;;
	maintain | run) cmd_maintain "$@" ;;
	"$MAINTENANCE_WINDOW_MODE" | window) cmd_maintenance_window "$@" ;;
	auto) cmd_auto "$@" ;;
	install) cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	status) cmd_status "$@" ;;
	notice) cmd_notice "$@" ;;
	sessions | find-session | find-sessions) cmd_sessions "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $sub"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
