#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# OpenCode worker database persistence and prompt transport tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_DATABASE_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_DATABASE_TESTS_LOADED=1

create_complete_opencode_test_schema() {
	local db_path="$1"
	sqlite3 "$db_path" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE project_directory (project_id TEXT NOT NULL, directory TEXT NOT NULL, PRIMARY KEY(project_id, directory));
CREATE TABLE permission (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE workspace (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE todo (session_id TEXT NOT NULL, position INTEGER NOT NULL, content TEXT NOT NULL, PRIMARY KEY(session_id, position));
CREATE TABLE session_share (session_id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE session_context_epoch (session_id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE session_input (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE event_sequence (aggregate_id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE event (id TEXT PRIMARY KEY, aggregate_id TEXT NOT NULL, seq INTEGER NOT NULL, data TEXT NOT NULL);
SQL
	return 0
}

test_seed_worker_db_session_context_copies_only_selected_session() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-data"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO project VALUES ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO session VALUES ('session-other', 'project-other', 'Other');
INSERT INTO message VALUES ('message-keep-1', 'session-keep', 'one');
INSERT INTO message VALUES ('message-keep-2', 'session-keep', 'two');
INSERT INTO message VALUES ('message-other', 'session-other', 'other');
SQL
	sqlite3 "$shared_db" .schema | sqlite3 "$worker_db"

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local sessions messages other_sessions other_messages projects
	sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-keep';")
	messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-keep';")
	other_sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-other';")
	other_messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-other';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'project-keep';")

	if [[ "$sessions" == "1" && "$messages" == "2" && "$other_sessions" == "0" && "$other_messages" == "0" && "$projects" == "1" ]]; then
		print_result "seed worker DB copies only selected continuation session" 0
		return 0
	fi

	print_result "seed worker DB copies only selected continuation session" 1 \
		"sessions=$sessions messages=$messages other_sessions=$other_sessions other_messages=$other_messages projects=$projects"
	return 0
}

test_seed_worker_db_session_context_rebinds_replacement_worktree() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-rebound"
	local replacement_dir="${TEST_ROOT}/replacement-worktree"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local stale_dir="${TEST_ROOT}/removed-worktree"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode" "$replacement_dir"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<SQL
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', '${stale_dir}', 'Keep');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'one');
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep" "$replacement_dir"

	local worker_directory="" shared_directory="" expected_replacement=""
	expected_replacement=$(cd "$replacement_dir" && pwd -P)
	worker_directory=$(sqlite3 "$worker_db" "SELECT directory FROM session WHERE id = 'session-keep';")
	shared_directory=$(sqlite3 "$shared_db" "SELECT directory FROM session WHERE id = 'session-keep';")
	if [[ "$worker_directory" == "$expected_replacement" && "$shared_directory" == "$stale_dir" ]]; then
		print_result "seed worker DB rebinds stale session to replacement worktree only in isolation" 0
		return 0
	fi

	print_result "seed worker DB rebinds stale session to replacement worktree only in isolation" 1 \
		"worker_directory=$worker_directory shared_directory=$shared_directory"
	return 0
}

test_seed_worker_db_session_context_copies_migration_metadata() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-metadata"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v16-ready', 1700000000);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'one');
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local schema_migrations data_migrations migration_rows sessions messages
	schema_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'schema-ready';")
	data_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM data_migration WHERE id = 'data-ready';")
	migration_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM migration WHERE id = 'opencode-v16-ready';")
	sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-keep';")
	messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-keep';")

	if [[ "$schema_migrations" == "1" && "$data_migrations" == "1" && "$migration_rows" == "1" && "$sessions" == "1" && "$messages" == "1" ]]; then
		print_result "seed worker DB copies migration metadata for continuation" 0
		return 0
	fi

	print_result "seed worker DB copies migration metadata for continuation" 1 \
		"schema_migrations=$schema_migrations data_migrations=$data_migrations migration_rows=$migration_rows sessions=$sessions messages=$messages"
	return 0
}

test_seed_worker_db_session_context_uses_schema_only_fresh_db() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-backup-seed"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
PRAGMA user_version = 42;
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v17-ready', 1700000000);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO project VALUES ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO session VALUES ('session-other', 'project-other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'one');
INSERT INTO message VALUES ('message-other', 'session-other', 'other');
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local user_version schema_migrations sessions other_sessions messages other_messages projects other_projects
	local seed_definition initialize_definition
	user_version=$(sqlite3 "$worker_db" "PRAGMA user_version;")
	schema_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'schema-ready';")
	sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-keep';")
	other_sessions=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session WHERE id = 'session-other';")
	messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-keep';")
	other_messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-other';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'project-keep';")
	other_projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'project-other';")
	seed_definition=$(declare -f _seed_worker_db_session_context)
	initialize_definition=$(declare -f _initialize_worker_db_from_shared_schema)

	if [[ "$user_version" == "42" && "$schema_migrations" == "1" && "$sessions" == "1" && "$other_sessions" == "0" && "$messages" == "1" && "$other_messages" == "0" && "$projects" == "1" && "$other_projects" == "0" && "$seed_definition" != *".backup"* && "$initialize_definition" == *'".schema --nosys"'* ]]; then
		print_result "seed worker DB uses shared schema for fresh continuation DB" 0
		return 0
	fi

	print_result "seed worker DB uses shared schema for fresh continuation DB" 1 \
		"user_version=$user_version schema_migrations=$schema_migrations sessions=$sessions other_sessions=$other_sessions messages=$messages other_messages=$other_messages projects=$projects other_projects=$other_projects"
	return 0
}

test_fresh_worker_db_uses_shared_schema_before_launch() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-fresh-run"
	local isolated_data_dir="$isolated_dir"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
PRAGMA user_version = 77;
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-ready', 12345);
INSERT INTO project VALUES ('shared-project', 'must-not-copy');
INSERT INTO session VALUES ('shared-session', 'shared-project', 'must-not-copy');
CREATE INDEX session_project_idx ON session (project_id);
ANALYZE;
SQL

	local runtime_role="worker"
	local public_triage=0
	local private_workload=0
	local exit_code_file="${TEST_ROOT}/fresh-run-exit-code"
	local _invoke_persisted_session=""
	local _invoke_work_dir="${TEST_ROOT}"
	_invoke_opencode_export_isolation

	local user_version="" migration_rows="" session_rows="" stat_rows="" graph_match=1
	user_version=$(sqlite3 "$worker_db" "PRAGMA user_version;")
	migration_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'shared-ready';")
	session_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM session;")
	stat_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'sqlite_stat1';")
	_opencode_db_graph_schema_matches "$worker_db" "$shared_db" || graph_match=0

	if [[ "$user_version" == "77" && "$migration_rows" == "1" && "$session_rows" == "0" && "$stat_rows" == "0" && "$graph_match" -eq 1 ]]; then
		print_result "fresh worker DB uses shared schema before runtime launch" 0
		return 0
	fi
	print_result "fresh worker DB uses shared schema before runtime launch" 1 \
		"user_version=$user_version migrations=$migration_rows sessions=$session_rows stats=$stat_rows graph_match=$graph_match"
	return 0
}

test_seed_worker_db_session_context_vacuums_pruned_backup() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-vacuum-seed"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data BLOB NOT NULL);
INSERT INTO project VALUES ('project-keep', 'Keep Project');
INSERT INTO project VALUES ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'Keep');
INSERT INTO session VALUES ('session-other', 'project-other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', zeroblob(1024));
INSERT INTO message VALUES ('message-other', 'session-other', zeroblob(1048576));
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local other_messages freelist_count
	other_messages=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM message WHERE session_id = 'session-other';")
	freelist_count=$(sqlite3 "$worker_db" "PRAGMA freelist_count;")

	if [[ "$other_messages" == "0" && "$freelist_count" == "0" ]]; then
		print_result "seed worker DB vacuums pruned backup pages" 0
		return 0
	fi

	print_result "seed worker DB vacuums pruned backup pages" 1 \
		"other_messages=$other_messages freelist_count=$freelist_count"
	return 0
}

test_seed_worker_db_session_context_copies_complete_graph() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-complete-graph"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	create_complete_opencode_test_schema "$shared_db"

	sqlite3 "$shared_db" <<'SQL'
INSERT INTO project VALUES ('project-keep', 'Keep Project'), ('project-other', 'Other Project');
INSERT INTO project_directory VALUES ('project-keep', '/keep'), ('project-other', '/other');
INSERT INTO permission VALUES ('permission-keep', 'project-keep', 'keep'), ('permission-other', 'project-other', 'other');
INSERT INTO workspace VALUES ('workspace-keep', 'project-keep', 'keep'), ('workspace-other', 'project-other', 'other');
INSERT INTO session VALUES ('session-keep', 'project-keep', '/keep', 'Keep'), ('session-other', 'project-other', '/other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'keep'), ('message-other', 'session-other', 'other');
INSERT INTO part VALUES ('part-keep', 'message-keep', 'session-keep', 'keep'), ('part-other', 'message-other', 'session-other', 'other');
INSERT INTO todo VALUES ('session-keep', 0, 'keep'), ('session-other', 0, 'other');
INSERT INTO session_share VALUES ('session-keep', 'keep'), ('session-other', 'other');
INSERT INTO session_context_epoch VALUES ('session-keep', 'keep'), ('session-other', 'other');
INSERT INTO session_input VALUES ('input-keep', 'session-keep', 'keep'), ('input-other', 'session-other', 'other');
INSERT INTO session_message VALUES ('projection-keep', 'session-keep', 'keep'), ('projection-other', 'session-other', 'other');
INSERT INTO event_sequence VALUES ('session-keep', 1), ('session-other', 1);
INSERT INTO event VALUES ('event-keep', 'session-keep', 1, 'keep'), ('event-other', 'session-other', 1, zeroblob(1048576));
SQL

	_seed_worker_db_session_context "$isolated_dir" "session-keep"

	local session_graph_count project_graph_count unrelated_count event_count
	session_graph_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM message) + (SELECT COUNT(*) FROM part) + (SELECT COUNT(*) FROM todo) + (SELECT COUNT(*) FROM session_share) + (SELECT COUNT(*) FROM session_context_epoch) + (SELECT COUNT(*) FROM session_input) + (SELECT COUNT(*) FROM session_message);")
	project_graph_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM project_directory) + (SELECT COUNT(*) FROM permission) + (SELECT COUNT(*) FROM workspace);")
	unrelated_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM session WHERE id = 'session-other') + (SELECT COUNT(*) FROM message WHERE session_id = 'session-other') + (SELECT COUNT(*) FROM part WHERE session_id = 'session-other') + (SELECT COUNT(*) FROM event WHERE aggregate_id = 'session-other');")
	event_count=$(sqlite3 "$worker_db" "SELECT (SELECT COUNT(*) FROM event_sequence WHERE aggregate_id = 'session-keep') + (SELECT COUNT(*) FROM event WHERE aggregate_id = 'session-keep');")

	if [[ "$session_graph_count" == "7" && "$project_graph_count" == "3" && "$unrelated_count" == "0" && "$event_count" == "2" ]]; then
		print_result "seed worker DB copies complete selected session graph only" 0
		return 0
	fi

	print_result "seed worker DB copies complete selected session graph only" 1 \
		"session_graph=$session_graph_count project_graph=$project_graph_count unrelated=$unrelated_count events=$event_count"
	return 0
}

test_merge_worker_db_replaces_complete_session_graph_atomically() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-complete-graph"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	create_complete_opencode_test_schema "$shared_db"
	create_complete_opencode_test_schema "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
INSERT INTO project VALUES ('project-keep', 'Shared Project'), ('project-other', 'Other Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', '/old', 'Old'), ('session-other', 'project-other', '/other', 'Other');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'old'), ('message-other', 'session-other', 'other');
INSERT INTO part VALUES ('part-keep', 'message-keep', 'session-keep', 'old'), ('part-other', 'message-other', 'session-other', 'other');
INSERT INTO todo VALUES ('session-keep', 0, 'removed-by-worker');
INSERT INTO event_sequence VALUES ('session-keep', 1), ('session-other', 1);
INSERT INTO event VALUES ('event-keep', 'session-keep', 1, 'old'), ('event-other', 'session-other', 1, 'other');
SQL
	sqlite3 "$worker_db" <<'SQL'
INSERT INTO project VALUES ('project-keep', 'Worker Project');
INSERT INTO session VALUES ('session-keep', 'project-keep', '/new', 'New');
INSERT INTO message VALUES ('message-keep', 'session-keep', 'new');
INSERT INTO part VALUES ('part-keep', 'message-keep', 'session-keep', 'new');
INSERT INTO session_context_epoch VALUES ('session-keep', 'new');
INSERT INTO session_input VALUES ('input-keep', 'session-keep', 'new');
INSERT INTO session_message VALUES ('projection-keep', 'session-keep', 'new');
INSERT INTO event_sequence VALUES ('session-keep', 2);
INSERT INTO event VALUES ('event-keep', 'session-keep', 2, 'new');
SQL

	local merge_status=0
	_merge_worker_db "$isolated_dir" || merge_status=$?

	local merged_values unrelated_values
	merged_values=$(sqlite3 "$shared_db" "SELECT title || '|' || directory FROM session WHERE id = 'session-keep'; SELECT data FROM message WHERE id = 'message-keep'; SELECT data FROM part WHERE id = 'part-keep'; SELECT COUNT(*) FROM todo WHERE session_id = 'session-keep'; SELECT data FROM session_context_epoch WHERE session_id = 'session-keep'; SELECT seq || '|' || data FROM event WHERE id = 'event-keep';")
	unrelated_values=$(sqlite3 "$shared_db" "SELECT data FROM message WHERE id = 'message-other'; SELECT data FROM part WHERE id = 'part-other'; SELECT data FROM event WHERE id = 'event-other';")

	if [[ "$merge_status" -eq 0 && "$merged_values" == $'New|/new\nnew\nnew\n0\nnew\n2|new' && "$unrelated_values" == $'other\nother\nother' ]]; then
		print_result "merge worker DB atomically replaces complete session graph" 0
		return 0
	fi

	print_result "merge worker DB atomically replaces complete session graph" 1 \
		"status=$merge_status merged=$merged_values unrelated=$unrelated_values"
	return 0
}

test_fresh_worker_db_initializes_shared_schema_before_session_merge() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/fresh-opencode-session-merge"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local initialize_status=0 merge_status=0 graph_matches=0 ledger_rows="" session_count=""
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	create_complete_opencode_test_schema "$shared_db"
	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
SQL

	_initialize_worker_db_from_shared_schema "$worker_db" "$shared_db" || initialize_status=$?
	_opencode_db_graph_schema_matches "$worker_db" "$shared_db" || graph_matches=1
	ledger_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'shared-schema-ready';")
	# Simulate OpenCode creating a first-time worker session after isolation setup.
	sqlite3 "$worker_db" <<'SQL'
INSERT INTO project VALUES ('project-fresh', 'Fresh Worker Project');
INSERT INTO project_directory VALUES ('project-fresh', '/fresh');
INSERT INTO session VALUES ('session-fresh', 'project-fresh', '/fresh', 'Fresh Worker Session');
INSERT INTO message VALUES ('message-fresh', 'session-fresh', 'worker output');
INSERT INTO part VALUES ('part-fresh', 'message-fresh', 'session-fresh', 'worker output');
INSERT INTO session_input VALUES ('input-fresh', 'session-fresh', 'input');
INSERT INTO event_sequence VALUES ('session-fresh', 1);
INSERT INTO event VALUES ('event-fresh', 'session-fresh', 1, 'created');
SQL
	_merge_worker_db "$isolated_dir" || merge_status=$?
	session_count=$(sqlite3 "$shared_db" "SELECT COUNT(*) FROM session WHERE id = 'session-fresh';")

	if [[ "$initialize_status" -eq 0 && "$graph_matches" -eq 0 && "$ledger_rows" == "1" && "$merge_status" -eq 0 && "$session_count" == "1" ]]; then
		print_result "fresh worker DB uses shared schema and merges its first session" 0
		return 0
	fi

	print_result "fresh worker DB uses shared schema and merges its first session" 1 \
		"initialize=$initialize_status graph_matches=$graph_matches ledger_rows=$ledger_rows merge=$merge_status session_count=$session_count"
	return 0
}

test_fresh_worker_isolation_prepares_and_finalizes_first_session() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/fresh-opencode-invocation"
	local shared_db="${shared_dir}/opencode.db"
	local exit_code_file="${TEST_ROOT}/fresh-opencode-invocation.exit"
	local invocation_status=0 session_count="" isolated_exists=""
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$exit_code_file"

	create_complete_opencode_test_schema "$shared_db"
	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
SQL

	if ! (
		local isolated_data_dir="$isolated_dir"
		local runtime_role="worker"
		local public_triage=0 private_workload=0
		local exit_code_file="$exit_code_file"
		_invoke_persisted_session=""
		_invoke_opencode_export_isolation
		sqlite3 "${isolated_data_dir}/opencode/opencode.db" <<'SQL'
INSERT INTO project VALUES ('project-invocation', 'Fresh Invocation Project');
INSERT INTO session VALUES ('session-invocation', 'project-invocation', '/invocation', 'Fresh Invocation Session');
INSERT INTO message VALUES ('message-invocation', 'session-invocation', 'worker output');
SQL
		_finalize_isolated_runtime_data "$isolated_data_dir" "$runtime_role"
	); then
		invocation_status=1
	fi
	session_count=$(sqlite3 "$shared_db" "SELECT COUNT(*) FROM session WHERE id = 'session-invocation';")
	isolated_exists=$([[ -e "$isolated_dir" ]] && printf yes || printf no)

	if [[ "$invocation_status" -eq 0 && "$session_count" == "1" && "$isolated_exists" == "no" ]]; then
		print_result "fresh worker isolation initializes and finalizes its first session" 0
		return 0
	fi

	print_result "fresh worker isolation initializes and finalizes its first session" 1 \
		"invocation=$invocation_status session_count=$session_count isolated_exists=$isolated_exists"
	return 0
}

test_fresh_worker_schema_initialization_replaces_runtime_drift() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/fresh-opencode-schema-drift"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local initial_graph_matches=0 initialize_status=0 final_graph_matches=0
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	create_complete_opencode_test_schema "$shared_db"
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
SQL
	_opencode_db_graph_schema_matches "$worker_db" "$shared_db" || initial_graph_matches=1
	_initialize_worker_db_from_shared_schema "$worker_db" "$shared_db" || initialize_status=$?
	_opencode_db_graph_schema_matches "$worker_db" "$shared_db" || final_graph_matches=1

	if [[ "$initial_graph_matches" -eq 1 && "$initialize_status" -eq 0 && "$final_graph_matches" -eq 0 ]]; then
		print_result "fresh worker schema initialization eliminates runtime graph drift" 0
		return 0
	fi

	print_result "fresh worker schema initialization eliminates runtime graph drift" 1 \
		"initial_graph_matches=$initial_graph_matches initialize=$initialize_status final_graph_matches=$final_graph_matches"
	return 0
}

test_merge_worker_db_maps_columns_by_name() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-column-order"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL, note TEXT DEFAULT 'shared-default');
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, slug TEXT NOT NULL, title TEXT NOT NULL, optional_value TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL, optional_value TEXT);
INSERT INTO project VALUES ('project-keep', 'Shared', 'old');
INSERT INTO session VALUES ('session-keep', 'project-keep', 'shared-slug', 'Old', NULL);
INSERT INTO message VALUES ('message-keep', 'session-keep', 'old', NULL);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (name TEXT NOT NULL, id TEXT PRIMARY KEY);
CREATE TABLE session (title TEXT NOT NULL, slug TEXT NOT NULL, id TEXT PRIMARY KEY, project_id TEXT NOT NULL);
CREATE TABLE message (data TEXT NOT NULL, session_id TEXT NOT NULL, id TEXT PRIMARY KEY);
INSERT INTO project VALUES ('Worker', 'project-keep');
INSERT INTO session VALUES ('New', 'worker-slug', 'session-keep', 'project-keep');
INSERT INTO message VALUES ('new', 'session-keep', 'message-keep');
SQL

	local merge_status=0 merged_values=""
	_merge_worker_db "$isolated_dir" || merge_status=$?
	merged_values=$(sqlite3 "$shared_db" "SELECT slug || '|' || title || '|' || COALESCE(optional_value, 'null') FROM session WHERE id = 'session-keep'; SELECT data || '|' || COALESCE(optional_value, 'null') FROM message WHERE id = 'message-keep';")
	if [[ "$merge_status" -eq 0 && "$merged_values" == $'worker-slug|New|null\nnew|null' ]]; then
		print_result "merge worker DB maps reordered and additive columns by name" 0
		return 0
	fi
	print_result "merge worker DB maps reordered and additive columns by name" 1 \
		"status=$merge_status merged=$merged_values"
	return 0
}

test_merge_worker_db_rejects_missing_required_destination_column() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-missing-required"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	sqlite3 "$shared_db" "CREATE TABLE project (id TEXT PRIMARY KEY); CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, slug TEXT NOT NULL); INSERT INTO project VALUES ('project-keep'); INSERT INTO session VALUES ('session-keep', 'project-keep', 'original');"
	sqlite3 "$worker_db" "CREATE TABLE project (id TEXT PRIMARY KEY); CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL); INSERT INTO project VALUES ('project-keep'); INSERT INTO session VALUES ('session-keep', 'project-keep');"

	local merge_status=0 shared_slug=""
	_merge_worker_db "$isolated_dir" || merge_status=$?
	shared_slug=$(sqlite3 "$shared_db" "SELECT slug FROM session WHERE id = 'session-keep';")
	if [[ "$merge_status" -ne 0 && "$shared_slug" == "original" ]]; then
		print_result "merge worker DB rejects missing required destination columns" 0
		return 0
	fi
	print_result "merge worker DB rejects missing required destination columns" 1 \
		"status=$merge_status shared_slug=$shared_slug"
	return 0
}

test_merge_worker_db_failure_preserves_recovery_db_without_auth() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/merge-opencode-failure"
	local recovery_root="${TEST_ROOT}/worker-db-recovery"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	create_complete_opencode_test_schema "$shared_db"
	create_complete_opencode_test_schema "$worker_db"
	sqlite3 "$shared_db" "INSERT INTO project VALUES ('project-keep', 'Shared'); INSERT INTO session VALUES ('session-keep', 'project-keep', '/old', 'Old');"
	sqlite3 "$worker_db" "CREATE TABLE worker_only (id TEXT PRIMARY KEY, session_id TEXT NOT NULL); INSERT INTO project VALUES ('project-keep', 'Worker'); INSERT INTO session VALUES ('session-keep', 'project-keep', '/new', 'New');"
	printf '%s' 'test-auth-must-not-be-preserved' >"${isolated_dir}/opencode/auth.json"

	local merge_status=0
	_merge_worker_db "$isolated_dir" || merge_status=$?
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _preserve_failed_worker_db "$isolated_dir"

	local recovered_db="" recovery_auth_count=0 shared_title candidate
	for candidate in "$recovery_root"/*/opencode.db; do
		[[ -f "$candidate" ]] || continue
		recovered_db="$candidate"
		break
	done
	if compgen -G "${recovery_root}/*/auth.json" >/dev/null; then
		recovery_auth_count=1
	fi
	shared_title=$(sqlite3 "$shared_db" "SELECT title FROM session WHERE id = 'session-keep';")
	if [[ "$merge_status" -ne 0 && -f "$recovered_db" && "$recovery_auth_count" == "0" && -f "${isolated_dir}/opencode/auth.json" && "$shared_title" == "Old" ]]; then
		print_result "failed merge rolls back and preserves DB without worker auth" 0
		return 0
	fi

	print_result "failed merge rolls back and preserves DB without worker auth" 1 \
		"status=$merge_status recovered=${recovered_db:-none} recovery_auth=$recovery_auth_count shared_title=$shared_title"
	return 0
}

test_replay_preserved_worker_db_verifies_before_deletion() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/replay-opencode-worker"
	local recovery_root="${TEST_ROOT}/replay-worker-db-recovery"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"
	sqlite3 "$shared_db" "CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT); CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, slug TEXT NOT NULL, title TEXT NOT NULL); CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL); INSERT INTO project VALUES ('project-replay', 'Shared'); INSERT INTO session VALUES ('session-replay', 'project-replay', 'old-slug', 'Old');"
	sqlite3 "$worker_db" "CREATE TABLE project (name TEXT, id TEXT PRIMARY KEY); CREATE TABLE session (title TEXT NOT NULL, slug TEXT NOT NULL, project_id TEXT NOT NULL, id TEXT PRIMARY KEY); CREATE TABLE message (data TEXT NOT NULL, id TEXT PRIMARY KEY, session_id TEXT NOT NULL); INSERT INTO project VALUES ('Worker', 'project-replay'); INSERT INTO session VALUES ('Recovered', 'new-slug', 'project-replay', 'session-replay'); INSERT INTO message VALUES ('recovered-child', 'message-replay', 'session-replay');"
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _preserve_failed_worker_db "$isolated_dir"

	local first_status=0 second_status=0 merged_values="" artifact_count=0
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _replay_preserved_worker_dbs || first_status=$?
	AIDEVOPS_WORKER_DB_RECOVERY_DIR="$recovery_root" _replay_preserved_worker_dbs || second_status=$?
	merged_values=$(sqlite3 "$shared_db" "SELECT slug || '|' || title FROM session WHERE id = 'session-replay'; SELECT data FROM message WHERE session_id = 'session-replay';")
	for worker_db in "$recovery_root"/*/opencode.db; do
		[[ -f "$worker_db" ]] && artifact_count=$((artifact_count + 1))
	done
	if [[ "$first_status" -eq 0 && "$second_status" -eq 0 && "$merged_values" == $'new-slug|Recovered\nrecovered-child' && "$artifact_count" -eq 0 ]]; then
		print_result "recovery replay verifies graph, deletes artifact, and is idempotent" 0
		return 0
	fi
	print_result "recovery replay verifies graph, deletes artifact, and is idempotent" 1 \
		"first=$first_status second=$second_status merged=$merged_values artifacts=$artifact_count"
	return 0
}

test_worker_db_replay_lock_recovers_stale_owner_and_waits_for_pid() {
	local recovery_root="${TEST_ROOT}/replay-lock-recovery"
	local replay_lock="${recovery_root}/.replay.lock"
	local stale_status=0 live_status=0 race_status=0
	local acquired_pid="" observed_pid="" race_pid=""
	local lock_holder_pid="" pid_writer_pid=""

	mkdir -p "$replay_lock"
	printf '%s\n' '99999999' >"${replay_lock}/pid"
	_acquire_worker_db_replay_lock "$replay_lock" || stale_status=$?
	acquired_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	_release_worker_db_replay_lock "$replay_lock"

	mkdir -p "$replay_lock"
	command sleep 5 &
	lock_holder_pid=$!
	(
		command sleep 0.2
		printf '%s\n' "$lock_holder_pid" >"${replay_lock}/pid"
	) &
	pid_writer_pid=$!
	_acquire_worker_db_replay_lock "$replay_lock" || live_status=$?
	wait "$pid_writer_pid" 2>/dev/null || true
	observed_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	kill "$lock_holder_pid" 2>/dev/null || true
	wait "$lock_holder_pid" 2>/dev/null || true
	rm -rf "$replay_lock"

	mkdir -p "$replay_lock"
	printf '%s\n' '99999999' >"${replay_lock}/pid"
	mkdir() {
		local mkdir_target="$1"
		if [[ "$mkdir_target" == "${replay_lock}/.reclaim" ]]; then
			command rm -rf "$replay_lock"
			return 1
		fi
		command mkdir "$@"
		return $?
	}
	_acquire_worker_db_replay_lock "$replay_lock" || race_status=$?
	unset -f mkdir
	race_pid=$(_read_worker_db_replay_lock_pid "$replay_lock")
	_release_worker_db_replay_lock "$replay_lock"

	if [[ "$stale_status" -eq 0 && "$acquired_pid" == "$$" && "$live_status" -eq 1 && "$observed_pid" == "$lock_holder_pid" && "$race_status" -eq 0 && "$race_pid" == "$$" ]]; then
		print_result "worker DB replay lock reclaims stale owners, waits for PIDs, and retries owner release races" 0
		return 0
	fi
	print_result "worker DB replay lock reclaims stale owners, waits for PIDs, and retries owner release races" 1 \
		"stale_status=$stale_status acquired=$acquired_pid live_status=$live_status observed=$observed_pid holder=$lock_holder_pid race_status=$race_status race_pid=$race_pid"
	return 0
}

test_sync_worker_db_migration_metadata_repairs_prewarmed_project_table() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-prewarm"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v16-ready', 1700000000);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local schema_migrations data_migrations migration_rows projects
	schema_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM __drizzle_migrations WHERE hash = 'schema-ready';")
	data_migrations=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM data_migration WHERE id = 'data-ready';")
	migration_rows=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM migration WHERE id = 'opencode-v16-ready';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'prewarmed-project';")

	if [[ "$schema_migrations" == "1" && "$data_migrations" == "1" && "$migration_rows" == "1" && "$projects" == "1" ]]; then
		print_result "sync worker DB migration metadata repairs prewarmed project table" 0
		return 0
	fi

	print_result "sync worker DB migration metadata repairs prewarmed project table" 1 \
		"schema_migrations=$schema_migrations data_migrations=$data_migrations migration_rows=$migration_rows projects=$projects"
	return 0
}

test_sync_worker_db_migration_metadata_replaces_stale_ledgers() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-stale-ledger"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
INSERT INTO data_migration VALUES ('shared-data-ready', 67890);
INSERT INTO migration VALUES ('shared-opencode-ready', 1700000000);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'stale-schema-row', 11111);
INSERT INTO data_migration VALUES ('shared-data-ready', 22222);
INSERT INTO migration VALUES ('shared-opencode-ready', 33333);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local schema_hash data_updated_at migration_completed projects
	schema_hash=$(sqlite3 "$worker_db" "SELECT hash FROM __drizzle_migrations WHERE id = 1;")
	data_updated_at=$(sqlite3 "$worker_db" "SELECT updated_at FROM data_migration WHERE id = 'shared-data-ready';")
	migration_completed=$(sqlite3 "$worker_db" "SELECT time_completed FROM migration WHERE id = 'shared-opencode-ready';")
	projects=$(sqlite3 "$worker_db" "SELECT COUNT(*) FROM project WHERE id = 'prewarmed-project';")

	if [[ "$schema_hash" == "shared-schema-ready" && "$data_updated_at" == "67890" && "$migration_completed" == "1700000000" && "$projects" == "1" ]]; then
		print_result "sync worker DB replaces stale migration ledger rows" 0
		return 0
	fi

	print_result "sync worker DB replaces stale migration ledger rows" 1 \
		"schema_hash=$schema_hash data_updated_at=$data_updated_at migration_completed=$migration_completed projects=$projects"
	return 0
}

test_copy_worker_db_migration_ledger_preserves_rows_when_attach_fails() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-attach-failure"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local sqlite_wrapper
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'stale-schema-row', 11111);
SQL

	sqlite_wrapper=$(declare -f sqlite3_with_timeout | sed '1s/sqlite3_with_timeout/sqlite3_with_timeout_original_for_test/')
	eval "$sqlite_wrapper"
	sqlite3_with_timeout() {
		local db_path="${1:-}"
		local line
		local sql_input

		if [[ "$db_path" == "$worker_db" && "$#" -eq 1 ]]; then
			sql_input=""
			while IFS= read -r line; do
				sql_input+="${line}"$'\n'
			done
			if [[ "$sql_input" == *"ATTACH DATABASE"* ]]; then
				return 1
			fi
			printf '%s\n' "$sql_input" | sqlite3_with_timeout_original_for_test "$db_path"
			return $?
		fi

		sqlite3_with_timeout_original_for_test "$@"
		return $?
	}

	_copy_worker_db_migration_ledger_table "$worker_db" "$shared_db" "__drizzle_migrations" >/dev/null 2>&1 || true

	eval "$(declare -f sqlite3_with_timeout_original_for_test | sed '1s/sqlite3_with_timeout_original_for_test/sqlite3_with_timeout/')"
	unset -f sqlite3_with_timeout_original_for_test

	local schema_hash
	schema_hash=$(sqlite3 "$worker_db" "SELECT hash FROM __drizzle_migrations WHERE id = 1;")
	if [[ "$schema_hash" == "stale-schema-row" ]]; then
		print_result "copy worker DB migration ledger preserves rows when attach fails" 0
		return 0
	fi

	print_result "copy worker DB migration ledger preserves rows when attach fails" 1 "schema_hash=$schema_hash"
	return 0
}

test_copy_worker_db_migration_ledger_stops_when_schema_query_fails() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-schema-query-failure"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local sqlite_wrapper
	local create_attempts=0
	local rc=0
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
INSERT INTO __drizzle_migrations VALUES (1, 'shared-schema-ready', 12345);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
SQL

	sqlite_wrapper=$(declare -f sqlite3_with_timeout | sed '1s/sqlite3_with_timeout/sqlite3_with_timeout_original_for_test/')
	eval "$sqlite_wrapper"
	sqlite3_with_timeout() {
		local db_path="${1:-}"
		local sql_arg="${2:-}"
		local line

		if [[ "$db_path" == "$shared_db" && "$sql_arg" == ".schema __drizzle_migrations" ]]; then
			return 1
		fi
		if [[ "$db_path" == "$worker_db" && "$#" -eq 1 ]]; then
			create_attempts=$((create_attempts + 1))
			while IFS= read -r line; do
				:
			done
			return 0
		fi

		sqlite3_with_timeout_original_for_test "$@"
		return $?
	}

	_copy_worker_db_migration_ledger_table "$worker_db" "$shared_db" "__drizzle_migrations" >/dev/null 2>&1 || rc=$?

	eval "$(declare -f sqlite3_with_timeout_original_for_test | sed '1s/sqlite3_with_timeout_original_for_test/sqlite3_with_timeout/')"
	unset -f sqlite3_with_timeout_original_for_test

	if [[ "$rc" == "1" && "$create_attempts" == "0" ]]; then
		print_result "copy worker DB migration ledger stops when schema query fails" 0
		return 0
	fi

	print_result "copy worker DB migration ledger stops when schema query fails" 1 "rc=$rc create_attempts=$create_attempts"
	return 0
}

test_sync_worker_db_migration_metadata_archives_unrepairable_project_table() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-unrepairable"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local backup_count=0 backup_file
	for backup_file in "${isolated_dir}"/opencode/opencode.db.incomplete-migration-ledgers.*.bak; do
		[[ -f "$backup_file" ]] || continue
		backup_count=$((backup_count + 1))
	done
	if [[ ! -f "$worker_db" && "$backup_count" == "1" ]]; then
		print_result "sync worker DB archives unrepairable prewarmed project table" 0
		return 0
	fi

	print_result "sync worker DB archives unrepairable prewarmed project table" 1 \
		"Expected worker DB archived once, file_exists=$([[ -f "$worker_db" ]] && printf yes || printf no) backups=${backup_count}"
	return 0
}

test_sync_worker_db_migration_metadata_preserves_worker_db_when_shared_query_fails() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-shared-query-fails"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	printf '%s\n' 'not a sqlite database' >"$shared_db"
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	_sync_worker_db_migration_metadata "$isolated_dir"

	local backup_count=0 backup_file
	for backup_file in "${isolated_dir}"/opencode/opencode.db.incomplete-migration-ledgers.*.bak; do
		[[ -f "$backup_file" ]] || continue
		backup_count=$((backup_count + 1))
	done
	if [[ -f "$worker_db" && "$backup_count" == "0" ]]; then
		print_result "sync worker DB preserves prewarmed DB when shared query fails" 0
		return 0
	fi

	print_result "sync worker DB preserves prewarmed DB when shared query fails" 1 \
		"Expected worker DB preserved, file_exists=$([[ -f "$worker_db" ]] && printf yes || printf no) backups=${backup_count}"
	return 0
}

test_sync_worker_db_migration_metadata_repeated_launch_reaches_seed() {
	local shared_dir="${HOME}/.local/share/opencode"
	local isolated_dir="${TEST_ROOT}/isolated-opencode-repeat"
	local shared_db="${shared_dir}/opencode.db"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local attempts=0 failures=0 launch_output=""
	mkdir -p "$shared_dir" "${isolated_dir}/opencode"
	rm -f "$shared_db" "$worker_db"

	sqlite3 "$shared_db" <<'SQL'
CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, created_at INTEGER);
CREATE TABLE data_migration (name TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO __drizzle_migrations VALUES (1, 'schema-ready', 12345);
INSERT INTO data_migration VALUES ('data-ready', 67890);
INSERT INTO migration VALUES ('opencode-v17-ready', 1700000000);
SQL
	sqlite3 "$worker_db" <<'SQL'
CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT);
INSERT INTO project VALUES ('prewarmed-project', 'Prewarmed Project');
SQL

	while [[ "$attempts" -lt 2 ]]; do
		attempts=$((attempts + 1))
		_sync_worker_db_migration_metadata "$isolated_dir"
		if ! _worker_db_migration_ledgers_match_shared "$worker_db" "$shared_db"; then
			failures=$((failures + 1))
			launch_output="${launch_output}SQLiteError: table project already exists\n"
			continue
		fi
		launch_output="${launch_output}SEED_PROMPT_REACHED attempt=${attempts}\n"
	done

	if [[ "$attempts" -eq 2 && "$failures" -eq 0 && "$launch_output" == *"SEED_PROMPT_REACHED attempt=1"* && "$launch_output" == *"SEED_PROMPT_REACHED attempt=2"* ]]; then
		print_result "sync worker DB lets repeated prewarmed launches reach seed prompt" 0
		return 0
	fi

	print_result "sync worker DB lets repeated prewarmed launches reach seed prompt" 1 \
		"attempts=${attempts} failures=${failures} output=${launch_output}"
	return 0
}

test_opencode_project_table_migration_replay_detected() {
	local output_file="${TEST_ROOT}/opencode-project-replay.log"
	local project_table_error="table \`project\` already exists"
	printf '%s\n' 'Error: Unexpected error' "$project_table_error" >"$output_file"

	if _opencode_project_table_migration_replay_detected 1 "$output_file" &&
		! _opencode_project_table_migration_replay_detected 0 "$output_file"; then
		print_result "detects OpenCode project table migration replay startup failure" 0
		return 0
	fi

	print_result "detects OpenCode project table migration replay startup failure" 1 \
		"Expected non-zero exit with project table replay output to be detected only on failure"
	return 0
}

test_large_opencode_prompt_uses_file_attachment() {
	local prompt="large-seed-prompt-with-worker-contract"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	local old_prompt_dir="${AIDEVOPS_HEADLESS_PROMPT_DIR:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=8

	_prepare_runtime_prompt_transport "opencode" "$prompt"

	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	local prompt_dir="${prompt_file%/*}"
	local observed_prompt_dir="${AIDEVOPS_HEADLESS_PROMPT_DIR:-}"
	local cmd_text=""
	cmd_text=$(
		while IFS= read -r -d '' arg; do
			printf '<%s>' "$arg"
		done < <(_build_run_cmd "anthropic/claude-sonnet-4-6" "$TEST_ROOT" "$prompt_arg" \
			"Prompt Transport Test" "" "" "" --file "$prompt_file")
	)

	if [[ "$prompt_arg" != *"$prompt"* ]] &&
		[[ -f "$prompt_file" ]] &&
		[[ "$(<"$prompt_file")" == "$prompt" ]] &&
		[[ "$observed_prompt_dir" == "$prompt_dir" ]] &&
		[[ "$cmd_text" == *"<--file><${prompt_file}>"* ]] &&
		[[ "$cmd_text" != *"$prompt"* ]]; then
		_cleanup_headless_runtime_temp_paths
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		if [[ -n "$old_prompt_dir" ]]; then
			AIDEVOPS_HEADLESS_PROMPT_DIR="$old_prompt_dir"
		else
			unset AIDEVOPS_HEADLESS_PROMPT_DIR
		fi
		print_result "large opencode prompts use file attachment instead of argv" 0
		return 0
	fi

	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	if [[ -n "$old_prompt_dir" ]]; then
		AIDEVOPS_HEADLESS_PROMPT_DIR="$old_prompt_dir"
	else
		unset AIDEVOPS_HEADLESS_PROMPT_DIR
	fi
	print_result "large opencode prompts use file attachment instead of argv" 1 \
		"prompt_arg=${prompt_arg} prompt_file=${prompt_file} prompt_dir=${observed_prompt_dir} cmd=${cmd_text}"
	return 0
}

test_public_triage_prompt_forces_file_attachment() {
	local prompt="small-public-triage-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	local transport_status=0
	local failure_status=0
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=999999

	_prepare_runtime_prompt_transport "opencode" "$prompt" 1 || transport_status=$?
	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	(
		_create_headless_runtime_temp_dir() {
			local purpose="$1"
			: "$purpose"
			return 1
		}
		_prepare_runtime_prompt_transport "opencode" "$prompt" 1
	) >/dev/null 2>&1 || failure_status=$?

	local ok=0
	[[ "$transport_status" -eq 0 ]] || ok=1
	[[ "$prompt_arg" != *"$prompt"* ]] || ok=1
	[[ -f "$prompt_file" && "$(<"$prompt_file")" == "$prompt" ]] || ok=1
	[[ "$failure_status" -ne 0 ]] || ok=1
	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "public triage prompts always use fail-closed file transport" "$ok" \
		"transport=${transport_status} failure=${failure_status} arg=${prompt_arg} file=${prompt_file}"
	return 0
}

test_public_triage_isolated_data_is_discarded() {
	local triage_dir="${TEST_ROOT}/triage-isolated-data"
	mkdir -p "$triage_dir"
	local lifecycle_state=""
	lifecycle_state=$(
		local merge_count=0 replay_count=0 preserve_count=0
		_replay_preserved_worker_dbs() {
			replay_count=$((replay_count + 1))
			return 0
		}
		_merge_worker_db() {
			local isolated_dir="$1"
			: "$isolated_dir"
			merge_count=$((merge_count + 1))
			return 0
		}
		_preserve_failed_worker_db() {
			local isolated_dir="$1"
			: "$isolated_dir"
			preserve_count=$((preserve_count + 1))
			return 0
		}
		print_info() { return 0; }
		print_warning() { return 0; }
		_WORKER_ISOLATED_DB_PATH="${triage_dir}/opencode/opencode.db"
		_finalize_isolated_runtime_data "$triage_dir" "triage"
		printf '%s|%s|%s|%s|%s' "$merge_count" "$replay_count" "$preserve_count" \
			"$([[ -e "$triage_dir" ]] && printf yes || printf no)" \
			"${_WORKER_ISOLATED_DB_PATH:-}"
	)

	if [[ "$lifecycle_state" == "0|0|0|no|" ]]; then
		print_result "public triage discards isolated session data without DB merge or recovery" 0
		return 0
	fi
	print_result "public triage discards isolated session data without DB merge or recovery" 1 \
		"state=${lifecycle_state:-<empty>}"
	return 0
}

test_public_triage_cleanup_failure_is_reported() {
	local triage_dir="${TEST_ROOT}/triage-cleanup-failure"
	mkdir -p "$triage_dir"
	local lifecycle_state=""
	lifecycle_state=$(
		rm() { return 1; }
		print_info() { return 0; }
		print_warning() {
			local message="$1"
			printf '%s\n' "$message"
			return 0
		}
		_WORKER_ISOLATED_DB_PATH="${triage_dir}/opencode/opencode.db"
		local finalize_status=0
		_finalize_isolated_runtime_data "$triage_dir" "triage" || finalize_status=$?
		printf 'state=%s|%s|%s\n' "$finalize_status" \
			"$([[ -e "$triage_dir" ]] && printf yes || printf no)" \
			"${_WORKER_ISOLATED_DB_PATH:-}"
	)
	command rm -rf "$triage_dir"

	if [[ "$lifecycle_state" == *"db_cleanup_failed"* &&
		"$lifecycle_state" == *"guardian=retained"* &&
		"$lifecycle_state" == *"state=1|yes|"* ]]; then
		print_result "public triage reports isolated-data cleanup failure" 0
		return 0
	fi
	print_result "public triage reports isolated-data cleanup failure" 1 \
		"state=${lifecycle_state:-<empty>}"
	return 0
}

test_public_triage_does_not_persist_session_or_failure_output() {
	local AIDEVOPS_PRIVATE_WORKLOAD=0
	local session_state=""
	session_state=$(
		store_session_id() {
			local provider="$1"
			local session_key="$2"
			local session_id="$3"
			local selected_model="$4"
			printf '%s|%s|%s|%s\n' "$provider" "$session_key" "$session_id" "$selected_model"
			return 0
		}
		_store_headless_session_if_allowed "openai" "triage-42" "ses_triage" "openai/test" "triage"
		_store_headless_session_if_allowed "openai" "issue-42" "ses_worker" "openai/test" "worker"
	)

	local marker="PUBLIC_TRIAGE_OUTPUT_MUST_NOT_PERSIST_28705"
	local output_file="${TEST_ROOT}/public-triage-no-activity.log"
	local details_file="${TEST_ROOT}/public-triage-provider-details.log"
	printf '%s\n' "$marker" >"$output_file"
	printf 'HTTP 503 service unavailable: %s\n' "$marker" >"$details_file"
	local handle_status=0
	_handle_run_result 0 "$output_file" "triage" "openai" "triage-42" "openai/test" \
		>/dev/null 2>&1 || handle_status=$?
	record_provider_backoff "openai" "provider_error" "$details_file" \
		"openai/public-triage-test" 1
	local stored_details=""
	stored_details=$(db_query "SELECT details FROM provider_backoff WHERE provider = 'openai/public-triage-test';")
	clear_provider_backoff "openai/public-triage-test"
	local persisted_marker=0
	if grep -R -Fq "$marker" "${HOME}/.aidevops/logs" 2>/dev/null; then
		persisted_marker=1
	fi

	if [[ "$session_state" == "openai|issue-42|ses_worker|openai/test" &&
		"$handle_status" -eq 75 && ! -f "$output_file" &&
		"$stored_details" == "ephemeral workload details suppressed" &&
		"$persisted_marker" -eq 0 ]]; then
		print_result "public triage persists neither sessions nor transcript-derived failure output" 0
		return 0
	fi
	print_result "public triage persists neither sessions nor transcript-derived failure output" 1 \
		"session=${session_state:-<empty>} status=${handle_status} output=$([[ -f "$output_file" ]] && printf present || printf removed) details=${stored_details:-<empty>} marker=${persisted_marker}"
	return 0
}

test_large_claude_prompt_uses_stdin_file() {
	local prompt="large-claude-seed-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=8

	_prepare_runtime_prompt_transport "claude" "$prompt"

	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local stdin_file="$_HEADLESS_CLAUDE_STDIN_FILE"
	local cmd_text=""
	cmd_text=$(
		while IFS= read -r -d '' arg; do
			printf '<%s>' "$arg"
		done < <(_build_claude_cmd "anthropic/claude-sonnet-4-6" "$TEST_ROOT" "$prompt_arg" \
			"Prompt Transport Test" "")
	)

	if [[ -z "$prompt_arg" ]] &&
		[[ -f "$stdin_file" ]] &&
		[[ "$(<"$stdin_file")" == "$prompt" ]] &&
		[[ "$cmd_text" == "<claude><-p>"* ]] &&
		[[ "$cmd_text" != *"$prompt"* ]]; then
		_cleanup_headless_runtime_temp_paths
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "large claude prompts use stdin file instead of argv" 0
		return 0
	fi

	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "large claude prompts use stdin file instead of argv" 1 \
		"prompt_arg=${prompt_arg} stdin_file=${stdin_file} cmd=${cmd_text}"
	return 0
}

test_registered_prompt_temp_cleanup_removes_dir() {
	local prompt="cleanup-seed-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=1

	_prepare_runtime_prompt_transport "opencode" "$prompt"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	local prompt_dir="${prompt_file%/*}"
	_cleanup_headless_runtime_temp_paths

	if [[ -n "$prompt_dir" && ! -e "$prompt_dir" ]]; then
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "registered prompt temp cleanup removes prompt dir" 0
		return 0
	fi

	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "registered prompt temp cleanup removes prompt dir" 1 \
		"Prompt temp dir still exists: ${prompt_dir:-<empty>}"
	return 0
}

test_registered_temp_cleanup_failure_is_reported_and_retained() {
	local managed_root=""
	managed_root=$(aidevops_sensitive_temp_root)
	local temp_path="${managed_root}/aidevops-headless-cleanup-failure"
	mkdir -p "$temp_path"
	_HEADLESS_RUNTIME_TEMP_PATHS=""
	_register_headless_runtime_temp_path "$temp_path"

	local state=""
	state=$(
		rm() { return 0; }
		print_warning() {
			local message="$1"
			printf '%s\n' "$message"
			return 0
		}
		local cleanup_status=0
		_cleanup_headless_runtime_temp_paths || cleanup_status=$?
		printf 'status=%s retained=%s\n' "$cleanup_status" \
			"${_HEADLESS_RUNTIME_TEMP_PATHS:-}"
	)
	_HEADLESS_RUNTIME_TEMP_PATHS=""
	command rm -rf "$temp_path"

	if [[ "$state" == *"headless_runtime_temp_cleanup_failed"* &&
		"$state" == *"status=1 retained=${temp_path}"* ]]; then
		print_result "registered temp cleanup reports and retains undeleted paths" 0
		return 0
	fi
	print_result "registered temp cleanup reports and retains undeleted paths" 1 \
		"state=${state:-<empty>}"
	return 0
}

test_public_triage_output_temp_starts_cleanup_guardian() {
	local managed_root=""
	managed_root=$(aidevops_sensitive_temp_root)
	local output_path="${managed_root}/aidevops-headless-runtime.guard-test"
	: >"$output_path"
	local state=""
	state=$(
		_HEADLESS_RUNTIME_TEMP_PATHS=""
		_start_headless_runtime_temp_guardian() {
			local guarded_path="$1"
			local owner_pid="$2"
			printf 'guardian=%s owner=%s\n' "$guarded_path" "$owner_pid"
			return 0
		}
		_register_headless_runtime_output_temp_path "triage" "$output_path"
		printf 'registered=%s\n' "${_HEADLESS_RUNTIME_TEMP_PATHS:-}"
	)
	command rm -f "$output_path"

	if [[ "$state" == *"guardian=${output_path}"* &&
		"$state" == *"registered=${output_path}"* ]]; then
		print_result "public triage output temp starts a detached cleanup guardian" 0
		return 0
	fi
	print_result "public triage output temp starts a detached cleanup guardian" 1 \
		"state=${state:-<empty>}"
	return 0
}

test_launch_helpers_tolerate_unset_state() {
	if (
		unset _HEADLESS_RUNTIME_TEMP_PATHS session_key work_dir title prompt prompt_file
		_cleanup_headless_runtime_temp_paths &&
			! _validate_run_args >/dev/null 2>&1
	); then
		print_result "launch helpers tolerate unset state under nounset" 0
		return 0
	fi

	print_result "launch helpers tolerate unset state under nounset" 1 \
		"Expected cleanup to succeed and validation to report missing arguments"
	return 0
}

# Helper: create a bare git repo and a feature branch with optional commits.
# Each call uses work_dir-derived remote path to avoid inter-test collisions.
# Args: $1 = work_dir path, $2 = 1 to add a commit (0 for none)
