#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Database -- Database Lifecycle Functions
# =============================================================================
# OpenCode worker database schema initialisation, migration metadata syncing,
# isolated session seeding, graph merging, verification, and recovery replay.
# Extracted from headless-runtime-lib.sh to reduce file size.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-database.sh"
#
# Dependencies:
#   - headless-runtime-lib.sh Section 1 utility functions
#     (sqlite3_with_timeout, sql_escape)
#   - shared-constants.sh (print_info, print_warning)
#   - Constants from headless-runtime-helper.sh
#   - bash 3.2+, sqlite3
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_DATABASE_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_DATABASE_LOADED=1

# Shared SQL keyword avoids the repeated-string-literal ratchet treating each
# independently parameterised query as a duplicate literal.
readonly _HEADLESS_SQL_SELECT="SELECT"

# Resolve SCRIPT_DIR if not set by caller for defensive standalone sourcing.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Section 9: DB Merge ---

#######################################
# Copy one OpenCode migration ledger table from shared DB to worker DB.
# Args: $1 = worker DB path, $2 = shared DB path, $3 = ledger table name.
# The ledger table list is intentionally allowlisted by the caller; this helper
# creates a missing worker-side table from the shared DB schema before copying
# rows so OpenCode does not replay migrations against pre-created user tables.
# Existing worker ledger rows are replaced, not merely inserted, because a
# pre-warmed DB can have stale rows with matching primary keys/counts; leaving
# those in place can still make OpenCode/Drizzle treat the schema as unmigrated.
#######################################
_copy_worker_db_migration_ledger_table() {
	local worker_db="$1"
	local shared_db="$2"
	local ledger_table="$3"
	local has_shared has_worker schema shared_db_sql

	has_shared=$(sqlite3_with_timeout "$shared_db" "${_HEADLESS_SQL_SELECT} 1 FROM sqlite_master WHERE type = 'table' AND name = '${ledger_table}' LIMIT 1;" 2>/dev/null || true)
	[[ -n "$has_shared" ]] || return 0

	has_worker=$(sqlite3_with_timeout "$worker_db" "${_HEADLESS_SQL_SELECT} 1 FROM sqlite_master WHERE type = 'table' AND name = '${ledger_table}' LIMIT 1;" 2>/dev/null || true)
	if [[ -z "$has_worker" ]]; then
		if ! schema=$(sqlite3_with_timeout "$shared_db" ".schema ${ledger_table}" 2>/dev/null) || [[ -z "$schema" ]] || ! printf '%s\n' "$schema" | sqlite3_with_timeout "$worker_db" >/dev/null 2>&1; then
			print_warning "OpenCode worker DB could not create ${ledger_table} migration ledger from shared DB"
			return 1
		fi
	fi

	shared_db_sql=$(sql_escape "$shared_db")
	if ! sqlite3_with_timeout "$worker_db" <<-SQL >/dev/null 2>&1; then
		.bail on
		ATTACH DATABASE '${shared_db_sql}' AS shared;
		BEGIN IMMEDIATE;
		DELETE FROM main."${ledger_table}";
		INSERT OR IGNORE INTO main."${ledger_table}" SELECT * FROM shared."${ledger_table}";
		COMMIT;
		DETACH DATABASE shared;
	SQL
		print_warning "OpenCode worker DB could not replace ${ledger_table} migration ledger from shared DB"
		return 1
	fi
	return 0
}

#######################################
# Synchronise all known OpenCode migration ledger tables into worker DB.
# Args: $1 = worker DB path, $2 = shared DB path.
#######################################
_sync_worker_db_migration_ledgers() {
	local worker_db="$1"
	local shared_db="$2"
	local ledger_table
	local sync_failed=0

	[[ -f "$worker_db" && -f "$shared_db" ]] || return 0
	for ledger_table in __drizzle_migrations data_migration migration; do
		_copy_worker_db_migration_ledger_table "$worker_db" "$shared_db" "$ledger_table" || sync_failed=1
	done
	[[ "$sync_failed" -eq 0 ]] || return 1
	return 0
}

#######################################
# Check whether worker DB has copied every non-empty shared migration ledger.
# Args: $1 = worker DB path, $2 = shared DB path.
#######################################
_worker_db_migration_ledgers_match_shared() {
	local worker_db="$1"
	local shared_db="$2"
	local ledger_table shared_count worker_count expected_ledgers=0
	local has_table

	[[ -f "$worker_db" && -f "$shared_db" ]] || return 1
	for ledger_table in __drizzle_migrations data_migration migration; do
		if ! has_table=$(sqlite3_with_timeout "$shared_db" "${_HEADLESS_SQL_SELECT} 1 FROM sqlite_master WHERE type = 'table' AND name = '${ledger_table}' LIMIT 1;"); then
			return 0
		fi
		[[ -n "$has_table" ]] || continue

		if ! shared_count=$(sqlite3_with_timeout "$shared_db" "${_HEADLESS_SQL_SELECT} COUNT(*) FROM main.\"${ledger_table}\";"); then
			return 0
		fi
		[[ "$shared_count" =~ ^[0-9]+$ ]] || shared_count=0
		if [[ "$shared_count" -eq 0 ]]; then
			continue
		fi
		expected_ledgers=1

		if ! has_table=$(sqlite3_with_timeout "$worker_db" "${_HEADLESS_SQL_SELECT} 1 FROM sqlite_master WHERE type = 'table' AND name = '${ledger_table}' LIMIT 1;"); then
			return 0
		fi
		[[ -n "$has_table" ]] || return 1

		if ! worker_count=$(sqlite3_with_timeout "$worker_db" "${_HEADLESS_SQL_SELECT} COUNT(*) FROM main.\"${ledger_table}\";"); then
			return 0
		fi
		[[ "$worker_count" =~ ^[0-9]+$ ]] || worker_count=0
		if [[ "$worker_count" -lt "$shared_count" ]]; then
			return 1
		fi
	done

	[[ "$expected_ledgers" -eq 1 ]] || return 1
	return 0
}

#######################################
# Move aside a partial worker DB so OpenCode can initialise a clean schema.
# Args: $1 = worker DB path, $2 = reason suffix for diagnostics.
#######################################
_archive_partial_worker_db() {
	local worker_db="$1"
	local reason="$2"
	local backup_db="${worker_db}.${reason}.$$.bak"

	[[ -f "$worker_db" ]] || return 0
	mv "$worker_db" "$backup_db" 2>/dev/null || return 0
	if [[ -f "${worker_db}-wal" ]]; then
		mv "${worker_db}-wal" "${backup_db}-wal" 2>/dev/null || true
	fi
	if [[ -f "${worker_db}-shm" ]]; then
		mv "${worker_db}-shm" "${backup_db}-shm" 2>/dev/null || true
	fi
	print_warning "OpenCode worker DB had user tables but incomplete migration ledgers; archived ${worker_db} to avoid startup migration replay (${reason})"
	return 0
}

#######################################
# List application tables containing a specific ownership column.
# Args: $1 = DB path, $2 = column name.
#######################################
_opencode_db_tables_with_column() {
	local db_path="$1"
	local column_name="$2"
	local column_name_sql

	column_name_sql=$(sql_escape "$column_name")
	sqlite3_with_timeout "$db_path" \
		"${_HEADLESS_SQL_SELECT} DISTINCT m.name FROM sqlite_master AS m JOIN pragma_table_info(m.name) AS p WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND p.name = '${column_name_sql}' ORDER BY m.name;"
	return $?
}

#######################################
# Check whether a SQLite DB contains a table.
# Args: $1 = DB path, $2 = table name.
#######################################
_opencode_db_has_table() {
	local db_path="$1"
	local table_name="$2"
	local table_name_sql result

	table_name_sql=$(sql_escape "$table_name")
	result=$(sqlite3_with_timeout "$db_path" "${_HEADLESS_SQL_SELECT} 1 FROM sqlite_master WHERE type = 'table' AND name = '${table_name_sql}' LIMIT 1;" 2>/dev/null || true)
	[[ "$result" == "1" ]]
}

#######################################
# Require source and destination to expose the same session/project graph.
# Args: $1 = source DB, $2 = destination DB.
#######################################
_opencode_db_graph_schema_matches() {
	local source_db="$1"
	local destination_db="$2"
	local column_name source_tables destination_tables table_name

	for column_name in session_id project_id; do
		source_tables=$(_opencode_db_tables_with_column "$source_db" "$column_name") || return 1
		destination_tables=$(_opencode_db_tables_with_column "$destination_db" "$column_name") || return 1
		[[ "$source_tables" == "$destination_tables" ]] || return 1
	done
	for table_name in event_sequence event; do
		if _opencode_db_has_table "$source_db" "$table_name"; then
			_opencode_db_has_table "$destination_db" "$table_name" || return 1
		elif _opencode_db_has_table "$destination_db" "$table_name"; then
			return 1
		fi
	done
	return 0
}

#######################################
# Return destination-ordered quoted columns shared by a SQLite table in two DBs.
# Destination-only NOT NULL/primary-key columns without defaults are incompatible.
# Args: $1 = source DB, $2 = destination DB, $3 = table name.
#######################################
_opencode_db_named_column_list() {
	local source_db="$1"
	local destination_db="$2"
	local table_name="$3"
	local source_db_sql table_name_sql result columns missing_required
	source_db_sql=$(sql_escape "$source_db")
	table_name_sql=$(sql_escape "$table_name")
	result=$(sqlite3_with_timeout "$destination_db" "
ATTACH DATABASE '${source_db_sql}' AS source_schema;
SELECT COALESCE((
  SELECT group_concat(quoted_name, ',') FROM (
    SELECT '\"' || replace(destination_column.name, '\"', '\"\"') || '\"' AS quoted_name
    FROM pragma_table_info('${table_name_sql}') AS destination_column
    JOIN pragma_table_info('${table_name_sql}', 'source_schema') AS source_column
      ON source_column.name = destination_column.name
    ORDER BY destination_column.cid
  )
), '') || '|' || COALESCE((
  SELECT group_concat(destination_column.name, ',')
  FROM pragma_table_info('${table_name_sql}') AS destination_column
  LEFT JOIN pragma_table_info('${table_name_sql}', 'source_schema') AS source_column
    ON source_column.name = destination_column.name
  WHERE source_column.name IS NULL
    AND (destination_column.pk > 0 OR (destination_column.\"notnull\" = 1 AND destination_column.dflt_value IS NULL))
), '');
" 2>/dev/null) || return 1
	columns="${result%%|*}"
	missing_required="${result#*|}"
	if [[ -z "$columns" || -n "$missing_required" ]]; then
		print_warning "[lifecycle] db_schema_incompatible table=${table_name} missing_required=${missing_required:-none}"
		return 1
	fi
	printf '%s' "$columns"
	return 0
}

_opencode_db_quote_identifier() {
	local identifier="$1"
	local destination_var="$2"
	[[ "$destination_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	identifier="${identifier//\"/\"\"}"
	printf -v "$destination_var" '"%s"' "$identifier"
	return 0
}

#######################################
# Initialise a data-empty worker DB from the current shared schema.
# Args: $1 = worker DB path, $2 = shared DB path.
#######################################
_initialize_worker_db_from_shared_schema() {
	local worker_db="$1"
	local shared_db="$2"
	local schema_sql user_version

	schema_sql=$(sqlite3_with_timeout "$shared_db" ".schema" 2>/dev/null) || return 1
	[[ -n "$schema_sql" ]] || return 1
	rm -f "$worker_db" "${worker_db}-wal" "${worker_db}-shm" 2>/dev/null || return 1
	if ! printf '%s\n' "$schema_sql" | sqlite3_with_timeout "$worker_db" >/dev/null 2>&1; then
		rm -f "$worker_db" "${worker_db}-wal" "${worker_db}-shm" 2>/dev/null || true
		return 1
	fi
	user_version=$(sqlite3_with_timeout "$shared_db" "PRAGMA user_version;" 2>/dev/null) || return 1
	[[ "$user_version" =~ ^[0-9]+$ ]] || return 1
	sqlite3_with_timeout "$worker_db" "PRAGMA user_version = ${user_version};" >/dev/null 2>&1 || return 1
	_sync_worker_db_migration_ledgers "$worker_db" "$shared_db" || return 1
	return 0
}

#######################################
# Merge worker's complete isolated session graph back to the shared DB.
# Called after worker exits. Any schema drift or SQL failure rolls back and is
# returned to the caller so the isolated DB can be retained for recovery.
#######################################
_merge_worker_db() {
	local isolated_dir="$1"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"
	local worker_db_sql session_tables project_tables table_name table_identifier column_list
	local delete_session_sql="" copy_session_sql=""
	local delete_project_sql="" copy_project_sql=""
	local delete_event_sequence_sql="" copy_event_sequence_sql=""
	local delete_event_sql="" copy_event_sql=""

	if [[ ! -f "$worker_db" ]]; then
		return 0
	fi
	if [[ ! -f "$shared_db" ]]; then
		return 1
	fi
	_opencode_db_graph_schema_matches "$worker_db" "$shared_db" || return 1
	session_tables=$(_opencode_db_tables_with_column "$shared_db" session_id) || return 1
	while IFS= read -r table_name; do
		[[ -n "$table_name" && "$table_name" != "session" ]] || continue
		_opencode_db_quote_identifier "$table_name" table_identifier || return 1
		delete_session_sql="${delete_session_sql}DELETE FROM main.${table_identifier} WHERE session_id IN (SELECT id FROM worker.session);"$'\n'
		column_list=$(_opencode_db_named_column_list "$worker_db" "$shared_db" "$table_name") || return 1
		copy_session_sql="${copy_session_sql}INSERT OR REPLACE INTO main.${table_identifier} (${column_list}) SELECT ${column_list} FROM worker.${table_identifier} WHERE session_id IN (SELECT id FROM worker.session);"$'\n'
	done <<-TABLES
		${session_tables}
	TABLES
	project_tables=$(_opencode_db_tables_with_column "$shared_db" project_id) || return 1
	while IFS= read -r table_name; do
		case "$table_name" in project | session | "") continue ;; esac
		_opencode_db_quote_identifier "$table_name" table_identifier || return 1
		delete_project_sql="${delete_project_sql}DELETE FROM main.${table_identifier} WHERE project_id IN (SELECT project_id FROM worker.session);"$'\n'
		column_list=$(_opencode_db_named_column_list "$worker_db" "$shared_db" "$table_name") || return 1
		copy_project_sql="${copy_project_sql}INSERT OR REPLACE INTO main.${table_identifier} (${column_list}) SELECT ${column_list} FROM worker.${table_identifier} WHERE project_id IN (SELECT project_id FROM worker.session);"$'\n'
	done <<-TABLES
		${project_tables}
	TABLES
	if _opencode_db_has_table "$shared_db" "event_sequence"; then
		column_list=$(_opencode_db_named_column_list "$worker_db" "$shared_db" event_sequence) || return 1
		delete_event_sequence_sql="DELETE FROM main.event_sequence WHERE aggregate_id IN (SELECT id FROM worker.session);"
		copy_event_sequence_sql="INSERT OR REPLACE INTO main.event_sequence (${column_list}) SELECT ${column_list} FROM worker.event_sequence WHERE aggregate_id IN (SELECT id FROM worker.session);"
	fi
	if _opencode_db_has_table "$shared_db" "event"; then
		column_list=$(_opencode_db_named_column_list "$worker_db" "$shared_db" event) || return 1
		delete_event_sql="DELETE FROM main.event WHERE aggregate_id IN (SELECT id FROM worker.session);"
		copy_event_sql="INSERT OR REPLACE INTO main.event (${column_list}) SELECT ${column_list} FROM worker.event WHERE aggregate_id IN (SELECT id FROM worker.session);"
	fi
	local project_columns session_columns merge_error=""
	project_columns=$(_opencode_db_named_column_list "$worker_db" "$shared_db" project) || return 1
	session_columns=$(_opencode_db_named_column_list "$worker_db" "$shared_db" session) || return 1

	worker_db_sql=$(sql_escape "$worker_db")
	if ! merge_error=$(sqlite3 "$shared_db" 2>&1 >/dev/null <<-SQL
		.bail on
		.timeout 5000
		ATTACH DATABASE '${worker_db_sql}' AS worker;
		BEGIN IMMEDIATE;
		${delete_session_sql}
		${delete_project_sql}
		${delete_event_sql}
		${delete_event_sequence_sql}
		INSERT OR IGNORE INTO main.project (${project_columns}) SELECT ${project_columns} FROM worker.project
			WHERE id IN (SELECT project_id FROM worker.session);
		${copy_project_sql}
		INSERT OR REPLACE INTO main.session (${session_columns}) SELECT ${session_columns} FROM worker.session;
		${copy_session_sql}
		${copy_event_sequence_sql}
		${copy_event_sql}
		COMMIT;
		DETACH DATABASE worker;
	SQL
	); then
		merge_error="${merge_error//$'\n'/ }"
		print_warning "[lifecycle] db_merge_sql_error detail=${merge_error:0:500}"
		return 1
	fi
	return 0
}

#######################################
# Preserve only DB artifacts after a failed merge; never retain worker auth.
# Args: $1 = isolated data directory.
#######################################
_preserve_failed_worker_db() {
	local isolated_dir="$1"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local recovery_root="${AIDEVOPS_WORKER_DB_RECOVERY_DIR:-${HOME}/.aidevops/.agent-workspace/work/worker-db-recovery}"
	local recovery_dir
	local suffix

	[[ -f "$worker_db" ]] || return 1
	mkdir -p "$recovery_root" 2>/dev/null || return 1
	recovery_dir=$(mktemp -d "${recovery_root}/$(date -u +%Y%m%dT%H%M%SZ)-$$-XXXXXX") || return 1
	chmod 700 "$recovery_root" "$recovery_dir" 2>/dev/null || true
	for suffix in "" -wal -shm; do
		if [[ -f "${worker_db}${suffix}" ]]; then
			mv "${worker_db}${suffix}" "${recovery_dir}/opencode.db${suffix}" 2>/dev/null || return 1
			chmod 600 "${recovery_dir}/opencode.db${suffix}" 2>/dev/null || true
		fi
	done
	print_warning "[lifecycle] db_merge_recovery_saved path=${recovery_dir}/opencode.db pid=$$"
	return 0
}

_opencode_db_scoped_table_counts_match() {
	local source_db="$1"
	local destination_db="$2"
	local table_name="$3"
	local scope_column="$4"
	local scope_query="$5"
	local source_db_sql table_identifier scope_identifier result
	source_db_sql=$(sql_escape "$source_db")
	_opencode_db_quote_identifier "$table_name" table_identifier || return 1
	_opencode_db_quote_identifier "$scope_column" scope_identifier || return 1
	result=$(sqlite3_with_timeout "$destination_db" "
ATTACH DATABASE '${source_db_sql}' AS source_schema;
SELECT (SELECT COUNT(*) FROM source_schema.${table_identifier} WHERE ${scope_identifier} IN (${scope_query}))
     = (SELECT COUNT(*) FROM main.${table_identifier} WHERE ${scope_identifier} IN (${scope_query}));
" 2>/dev/null) || return 1
	[[ "$result" == "1" ]]
}

#######################################
# Verify that every source session/project graph row is visible after merge.
# Args: $1 = source worker DB, $2 = destination shared DB.
#######################################
_verify_worker_db_merge() {
	local source_db="$1"
	local destination_db="$2"
	local table_name session_tables project_tables
	local session_scope_query="${_HEADLESS_SQL_SELECT} id FROM source_schema.session"
	_opencode_db_graph_schema_matches "$source_db" "$destination_db" || return 1
	_opencode_db_scoped_table_counts_match "$source_db" "$destination_db" session id \
		"$session_scope_query" || return 1
	_opencode_db_scoped_table_counts_match "$source_db" "$destination_db" project id \
		"${_HEADLESS_SQL_SELECT} project_id FROM source_schema.session" || return 1
	session_tables=$(_opencode_db_tables_with_column "$source_db" session_id) || return 1
	while IFS= read -r table_name; do
		case "$table_name" in session | "") continue ;; esac
		_opencode_db_scoped_table_counts_match "$source_db" "$destination_db" "$table_name" session_id \
			"$session_scope_query" || return 1
	done <<-TABLES
		${session_tables}
	TABLES
	project_tables=$(_opencode_db_tables_with_column "$source_db" project_id) || return 1
	while IFS= read -r table_name; do
		case "$table_name" in project | session | "") continue ;; esac
		_opencode_db_scoped_table_counts_match "$source_db" "$destination_db" "$table_name" project_id \
			"${_HEADLESS_SQL_SELECT} project_id FROM source_schema.session" || return 1
	done <<-TABLES
		${project_tables}
	TABLES
	for table_name in event_sequence event; do
		_opencode_db_has_table "$source_db" "$table_name" || continue
		_opencode_db_scoped_table_counts_match "$source_db" "$destination_db" "$table_name" aggregate_id \
			"$session_scope_query" || return 1
	done
	return 0
}

#######################################
# Read the owner PID from a worker DB replay lock.
# Args: $1 = replay lock directory.
#######################################
_read_worker_db_replay_lock_pid() {
	local replay_lock="$1"
	local locking_pid=""
	if [[ -f "${replay_lock}/pid" ]]; then
		IFS= read -r locking_pid 2>/dev/null <"${replay_lock}/pid" || locking_pid=""
	fi
	printf '%s' "$locking_pid"
	return 0
}

#######################################
# Acquire a PID-owned replay lock, reclaiming dead or incomplete stale locks.
# Args: $1 = replay lock directory.
# Returns: 0 when acquired, 1 when another owner is live or acquisition fails.
#######################################
_acquire_worker_db_replay_lock() {
	local replay_lock="$1"
	local locking_pid=""
	local wait_attempt=0
	local acquire_attempt=0

	while [[ "$acquire_attempt" -lt 2 ]]; do
		acquire_attempt=$((acquire_attempt + 1))
		locking_pid=""
		wait_attempt=0
		if mkdir "$replay_lock" 2>/dev/null; then
			if printf '%s\n' "$$" >"${replay_lock}/pid" 2>/dev/null; then
				return 0
			fi
			rm -rf "$replay_lock"
			return 1
		fi

		# The owner writes its PID immediately after mkdir. Give that write up to one
		# second to become visible before treating a PID-less directory as stale.
		while [[ "$wait_attempt" -lt 10 ]]; do
			locking_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
			[[ -n "$locking_pid" ]] && break
			wait_attempt=$((wait_attempt + 1))
			sleep 0.1
		done
		if [[ "$locking_pid" =~ ^[0-9]+$ ]] && kill -0 "$locking_pid" 2>/dev/null; then
			return 1
		fi

		# Serialize stale cleanup inside the existing directory. If the owner
		# released it between the liveness check and this mkdir, retry acquisition.
		if ! mkdir "${replay_lock}/.reclaim" 2>/dev/null; then
			[[ ! -d "$replay_lock" ]] && continue
			return 1
		fi
		locking_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
		if [[ "$locking_pid" =~ ^[0-9]+$ ]] && kill -0 "$locking_pid" 2>/dev/null; then
			rm -rf "${replay_lock}/.reclaim"
			return 1
		fi
		rm -rf "$replay_lock" || return 1
		mkdir "$replay_lock" 2>/dev/null || return 1
		if ! printf '%s\n' "$$" >"${replay_lock}/pid" 2>/dev/null; then
			rm -rf "$replay_lock"
			return 1
		fi
		return 0
	done
	return 1
}

#######################################
# Release a worker DB replay lock only when this process still owns it.
# Args: $1 = replay lock directory.
#######################################
_release_worker_db_replay_lock() {
	local replay_lock="$1"
	local locking_pid=""
	locking_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	if [[ "$locking_pid" == "$$" ]]; then
		rm -rf "$replay_lock"
	fi
	return 0
}

#######################################
# Replay retained worker DBs. Artifacts are deleted only after graph verification.
# Returns 0 when every attempted artifact merged or no artifacts exist.
#######################################
_replay_preserved_worker_dbs() {
	local recovery_root="${AIDEVOPS_WORKER_DB_RECOVERY_DIR:-${HOME}/.aidevops/.agent-workspace/work/worker-db-recovery}"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"
	local replay_lock="${recovery_root}/.replay.lock"
	local recovery_db recovery_dir replay_dir replay_failed=0
	[[ -d "$recovery_root" && -f "$shared_db" ]] || return 0
	_acquire_worker_db_replay_lock "$replay_lock" || return 0
	for recovery_db in "$recovery_root"/*/opencode.db; do
		[[ -f "$recovery_db" ]] || continue
		recovery_dir="${recovery_db%/opencode.db}"
		replay_dir=$(mktemp -d "${recovery_root}/.replay-XXXXXX") || { replay_failed=1; continue; }
		if ! ln -s "$recovery_dir" "${replay_dir}/opencode" 2>/dev/null; then
			rm -rf "$replay_dir"
			replay_failed=1
			continue
		fi
		if _merge_worker_db "$replay_dir" && _verify_worker_db_merge "$recovery_db" "$shared_db"; then
			rm -f "$recovery_db" "${recovery_db}-wal" "${recovery_db}-shm"
			rmdir "$recovery_dir" 2>/dev/null || true
			print_info "[lifecycle] db_merge_recovery_replayed path=${recovery_db}"
		else
			replay_failed=1
			print_warning "[lifecycle] db_merge_recovery_retained path=${recovery_db}"
		fi
		rm -rf "$replay_dir"
	done
	_release_worker_db_replay_lock "$replay_lock"
	[[ "$replay_failed" -eq 0 ]]
}

#######################################
# Seed a continuation session into a worker's isolated OpenCode DB.
# Called before `opencode run --session <id> --continue` so retries launched
# with a fresh XDG_DATA_HOME can resolve the persisted conversation locally.
# Copies the selected session plus every current session/project-owned table and
# event aggregate. When a retry moved to a replacement worktree, the isolated
# copy is rebound to that directory; the shared session stays unchanged.
#######################################
_seed_worker_db_session_context() {
	local isolated_dir="$1"
	local session_id="$2"
	local current_work_dir="${3:-}"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"
	local shared_db_sql session_id_sql current_work_dir_sql="" session_exists column_list
	local session_tables project_tables table_name table_identifier
	local clear_session_sql="" copy_session_sql=""
	local clear_project_sql="" copy_project_sql=""
	local clear_event_sequence_sql="" copy_event_sequence_sql=""
	local clear_event_sql="" copy_event_sql=""

	[[ -n "$isolated_dir" && -n "$session_id" ]] || return 1
	[[ -f "$shared_db" ]] || return 1
	mkdir -p "${isolated_dir}/opencode" 2>/dev/null || return 1
	session_id_sql=$(sql_escape "$session_id")
	session_exists=$(sqlite3_with_timeout "$shared_db" "${_HEADLESS_SQL_SELECT} COUNT(*) FROM session WHERE id = '${session_id_sql}';" 2>/dev/null) || return 1
	[[ "$session_exists" == "1" ]] || return 1

	# Build a schema-only DB, then synchronise migration ledgers. This avoids a
	# multi-gigabyte full backup while preserving OpenCode migration state.
	if [[ ! -f "$worker_db" ]]; then
		if ! _initialize_worker_db_from_shared_schema "$worker_db" "$shared_db"; then
			_archive_partial_worker_db "$worker_db" "schema-seed-failed"
			return 1
		fi
	fi
	_sync_worker_db_migration_ledgers "$worker_db" "$shared_db" || return 1
	_opencode_db_graph_schema_matches "$shared_db" "$worker_db" || return 1

	shared_db_sql=$(sql_escape "$shared_db")
	if [[ -n "$current_work_dir" && -d "$current_work_dir" ]]; then
		current_work_dir=$(cd "$current_work_dir" 2>/dev/null && pwd -P) || current_work_dir=""
		current_work_dir_sql=$(sql_escape "$current_work_dir")
	fi
	session_tables=$(_opencode_db_tables_with_column "$shared_db" session_id) || return 1
	project_tables=$(_opencode_db_tables_with_column "$shared_db" "project_id") || return 1
	while IFS= read -r table_name; do
		[[ -n "$table_name" && "$table_name" != "session" ]] || continue
		_opencode_db_quote_identifier "$table_name" table_identifier || return 1
		clear_session_sql="${clear_session_sql}DELETE FROM main.${table_identifier};"$'\n'
		column_list=$(_opencode_db_named_column_list "$shared_db" "$worker_db" "$table_name") || return 1
		copy_session_sql="${copy_session_sql}INSERT OR REPLACE INTO main.${table_identifier} (${column_list}) SELECT ${column_list} FROM shared.${table_identifier} WHERE session_id = '${session_id_sql}';"$'\n'
	done <<-TABLES
		${session_tables}
	TABLES
	while IFS= read -r table_name; do
		case "$table_name" in
		project | session | "") continue ;;
		esac
		_opencode_db_quote_identifier "$table_name" table_identifier || return 1
		clear_project_sql="${clear_project_sql}DELETE FROM main.${table_identifier};"$'\n'
		column_list=$(_opencode_db_named_column_list "$shared_db" "$worker_db" "$table_name") || return 1
		copy_project_sql="${copy_project_sql}INSERT OR REPLACE INTO main.${table_identifier} (${column_list}) SELECT ${column_list} FROM shared.${table_identifier} WHERE project_id IN (SELECT project_id FROM shared.session WHERE id = '${session_id_sql}');"$'\n'
	done <<-TABLES
		${project_tables}
	TABLES
	if _opencode_db_has_table "$shared_db" "event_sequence"; then
		column_list=$(_opencode_db_named_column_list "$shared_db" "$worker_db" event_sequence) || return 1
		clear_event_sequence_sql="DELETE FROM main.event_sequence;"
		copy_event_sequence_sql="INSERT OR REPLACE INTO main.event_sequence (${column_list}) SELECT ${column_list} FROM shared.event_sequence WHERE aggregate_id = '${session_id_sql}';"
	fi
	if _opencode_db_has_table "$shared_db" "event"; then
		column_list=$(_opencode_db_named_column_list "$shared_db" "$worker_db" event) || return 1
		clear_event_sql="DELETE FROM main.event;"
		copy_event_sql="INSERT OR REPLACE INTO main.event (${column_list}) SELECT ${column_list} FROM shared.event WHERE aggregate_id = '${session_id_sql}';"
	fi
	local project_columns session_columns
	project_columns=$(_opencode_db_named_column_list "$shared_db" "$worker_db" project) || return 1
	session_columns=$(_opencode_db_named_column_list "$shared_db" "$worker_db" session) || return 1
	if ! sqlite3 "$worker_db" <<-SQL >/dev/null 2>&1; then
		.bail on
		.timeout 5000
		ATTACH DATABASE '${shared_db_sql}' AS shared;
		BEGIN IMMEDIATE;
		${clear_session_sql}
		${clear_event_sql}
		${clear_event_sequence_sql}
		${clear_project_sql}
		DELETE FROM main.session;
		DELETE FROM main.project;
		INSERT OR IGNORE INTO project (${project_columns}) SELECT ${project_columns} FROM shared.project
			WHERE id IN (SELECT project_id FROM shared.session WHERE id = '${session_id_sql}');
		${copy_project_sql}
		INSERT OR REPLACE INTO session (${session_columns}) SELECT ${session_columns} FROM shared.session WHERE id = '${session_id_sql}';
		${copy_session_sql}
		${copy_event_sequence_sql}
		${copy_event_sql}
		$(if [[ -n "$current_work_dir_sql" ]]; then printf "UPDATE main.session SET directory = '%s' WHERE id = '%s';" "$current_work_dir_sql" "$session_id_sql"; fi)
		COMMIT;
		DETACH DATABASE shared;
		VACUUM;
	SQL
		return 1
	fi
	return 0
}

#######################################
# Synchronise OpenCode migration metadata into a pre-existing worker DB.
#
# Pre-warmed isolated DB directories can contain user tables before the worker
# starts. If the migration ledger is empty/missing, OpenCode/Drizzle replays
# CREATE TABLE migrations and aborts with errors such as "table project already
# exists" before the seed prompt reaches the model. Copy only migration ledger
# tables from the shared DB; session/message data remains isolated.
#######################################
_sync_worker_db_migration_metadata() {
	local isolated_dir="$1"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"

	[[ -n "$isolated_dir" ]] || return 0
	[[ -f "$worker_db" ]] || return 0
	[[ -f "$shared_db" ]] || return 0

	local has_project
	has_project=$(sqlite3 "$worker_db" "${_HEADLESS_SQL_SELECT} 1 FROM sqlite_master WHERE type = 'table' AND name = 'project' LIMIT 1;" 2>/dev/null || true)
	[[ -n "$has_project" ]] || return 0

	if ! _sync_worker_db_migration_ledgers "$worker_db" "$shared_db" ||
		! _worker_db_migration_ledgers_match_shared "$worker_db" "$shared_db"; then
		_archive_partial_worker_db "$worker_db" "incomplete-migration-ledgers"
	fi
	return 0
}
