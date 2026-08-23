#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Model DB Library — SQL Utilities, Config & Usage Tracking
# =============================================================================
# SQL injection helpers, directory setup, config loading, SQLite database
# initialisation/migration/schema-management, and per-request usage recording.
#
# Usage: source "${SCRIPT_DIR}/local-model-db.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, etc.)
#   - sqlite3 (optional — tracking silently disabled when missing)
#   - jq (optional — config loading falls back to defaults when missing)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCAL_MODEL_DB_LIB_LOADED:-}" ]] && return 0
_LOCAL_MODEL_DB_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# SQL Injection Prevention Utilities
# =============================================================================

# Escape single quotes for safe SQL string interpolation
# Usage: sqlite3 "$db" "SELECT * FROM t WHERE col = '$(sql_escape "$val")';"
sql_escape() {
	local val="$1"
	printf '%s' "${val//\'/\'\'}"
	return 0
}

# Sanitize a value for use as a bare (unquoted) SQL integer.
# Returns the value if it matches an integer pattern, otherwise returns the
# provided default (or 0).  This prevents SQL injection via numeric parameters.
# Usage: sqlite3 "$db" "INSERT INTO t (col) VALUES ($(sql_int "$val"));"
sql_int() {
	local val="$1"
	local default="${2:-0}"
	if [[ "$val" =~ ^-?[0-9]+$ ]]; then
		printf '%s' "$val"
	else
		printf '%s' "$default"
	fi
	return 0
}

# Sanitize a value for use as a bare (unquoted) SQL real/float.
# Returns the value if it matches a numeric pattern, otherwise returns the
# provided default (or 0.0).
sql_real() {
	local val="$1"
	local default="${2:-0.0}"
	if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
		printf '%s' "$val"
	else
		printf '%s' "$default"
	fi
	return 0
}

# =============================================================================
# Directory & Config Utilities
# =============================================================================

# Ensure the local-models directory structure exists
ensure_dirs() {
	mkdir -p "$LOCAL_BIN_DIR" 2>/dev/null || true
	mkdir -p "$LOCAL_MODELS_STORE" 2>/dev/null || true
	mkdir -p "$LOCAL_MODELS_DB_DIR" 2>/dev/null || true
	return 0
}

# Load config.json defaults if present
load_config() {
	if [[ -f "$LOCAL_CONFIG_FILE" ]] && suppress_stderr command -v jq; then
		LLAMA_PORT="$(jq -r '.port // 8080' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "8080")"
		LLAMA_HOST="$(jq -r '.host // "127.0.0.1"' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")"
		LLAMA_CTX_SIZE="$(jq -r '.ctx_size // 8192' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "8192")"
		LLAMA_GPU_LAYERS="$(jq -r '.gpu_layers // "auto"' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "auto")"
		LLAMA_FLASH_ATTN="$(jq -r '.flash_attn // true' "$LOCAL_CONFIG_FILE" 2>/dev/null || echo "true")"
	fi
	return 0
}

# Write default config.json if it doesn't exist
write_default_config() {
	if [[ ! -f "$LOCAL_CONFIG_FILE" ]]; then
		cat >"$LOCAL_CONFIG_FILE" <<-'CONFIGEOF'
			{
			  "port": 8080,
			  "host": "127.0.0.1",
			  "ctx_size": 8192,
			  "threads": "auto",
			  "gpu_layers": "auto",
			  "flash_attn": true
			}
		CONFIGEOF
		print_info "Created default config at ${LOCAL_CONFIG_FILE}"
	fi
	return 0
}

# =============================================================================
# Database Initialisation & Migration
# =============================================================================

# Initialize the usage tracking SQLite database (t1338.5)
# Schema: model_usage (per-request logging with session ID),
#          model_inventory (downloaded models with size tracking)
init_usage_db() {
	if ! suppress_stderr command -v sqlite3; then
		print_warning "sqlite3 not found — usage tracking disabled"
		return 0
	fi

	ensure_dirs

	# Migrate from legacy DB path if it exists and new one doesn't
	if [[ -f "$LOCAL_USAGE_DB_LEGACY" ]] && [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		_migrate_legacy_db
	fi

	if [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		log_stderr "init_usage_db" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'
			CREATE TABLE IF NOT EXISTS model_usage (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				model TEXT NOT NULL,
				session_id TEXT DEFAULT '',
				timestamp TEXT NOT NULL DEFAULT (datetime('now')),
				tokens_in INTEGER DEFAULT 0,
				tokens_out INTEGER DEFAULT 0,
				duration_ms INTEGER DEFAULT 0,
				tok_per_sec REAL DEFAULT 0.0
			);
			CREATE TABLE IF NOT EXISTS model_inventory (
				model TEXT PRIMARY KEY,
				file_path TEXT NOT NULL DEFAULT '',
				repo_source TEXT DEFAULT '',
				size_bytes INTEGER DEFAULT 0,
				quantization TEXT DEFAULT '',
				first_seen TEXT NOT NULL DEFAULT (datetime('now')),
				last_used TEXT NOT NULL DEFAULT (datetime('now')),
				total_requests INTEGER DEFAULT 0
			);
			CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
			CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
			CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
			CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
		SQLEOF
		print_info "Initialized usage database at ${LOCAL_USAGE_DB}"
	else
		# Ensure schema is up to date (idempotent migrations)
		_ensure_schema_current
	fi
	return 0
}

# Migrate legacy usage.db (old path, old table names) to new location/schema
_migrate_legacy_db() {
	local legacy_db="$LOCAL_USAGE_DB_LEGACY"
	local migration_failed=false
	print_info "Migrating legacy usage database to ${LOCAL_USAGE_DB}..."

	# Backup the legacy DB before migration
	backup_sqlite_db "$legacy_db" "pre-migrate-t1338.5" >/dev/null 2>&1 || true

	# Create new DB with new schema
	if ! log_stderr "migrate_legacy_db" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'; then
		CREATE TABLE IF NOT EXISTS model_usage (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			model TEXT NOT NULL,
			session_id TEXT DEFAULT '',
			timestamp TEXT NOT NULL DEFAULT (datetime('now')),
			tokens_in INTEGER DEFAULT 0,
			tokens_out INTEGER DEFAULT 0,
			duration_ms INTEGER DEFAULT 0,
			tok_per_sec REAL DEFAULT 0.0
		);
		CREATE TABLE IF NOT EXISTS model_inventory (
			model TEXT PRIMARY KEY,
			file_path TEXT NOT NULL DEFAULT '',
			repo_source TEXT DEFAULT '',
			size_bytes INTEGER DEFAULT 0,
			quantization TEXT DEFAULT '',
			first_seen TEXT NOT NULL DEFAULT (datetime('now')),
			last_used TEXT NOT NULL DEFAULT (datetime('now')),
			total_requests INTEGER DEFAULT 0
		);
		CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
		CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
		CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
		CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
	SQLEOF
		print_error "Failed to create new schema during migration"
		return 1
	fi

	# Copy data from legacy tables if they exist
	local has_usage has_model_access
	has_usage="$(sqlite3 "$legacy_db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='usage';" 2>/dev/null || echo "0")"
	has_model_access="$(sqlite3 "$legacy_db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_access';" 2>/dev/null || echo "0")"

	if [[ "$has_usage" == "1" ]]; then
		# Use ATTACH DATABASE with explicit column mapping to avoid schema mismatch
		if log_stderr "migrate_usage_rows" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF; then
			ATTACH DATABASE '$(sql_escape "$legacy_db")' AS legacy;
			INSERT OR IGNORE INTO model_usage (model, session_id, timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec)
			SELECT model, '', timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec
			FROM legacy.usage;
			DETACH DATABASE legacy;
		SQLEOF
			print_info "Migrated usage records to model_usage"
		else
			print_error "Failed to migrate usage records — legacy DB preserved"
			migration_failed=true
		fi
	fi

	if [[ "$has_model_access" == "1" ]]; then
		# Use ATTACH DATABASE with explicit column mapping for model_access -> model_inventory
		if log_stderr "migrate_model_access_rows" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF; then
			ATTACH DATABASE '$(sql_escape "$legacy_db")' AS legacy;
			INSERT OR IGNORE INTO model_inventory (model, first_seen, last_used, total_requests)
			SELECT model, first_used, last_used, total_requests
			FROM legacy.model_access;
			DETACH DATABASE legacy;
		SQLEOF
			print_info "Migrated model_access records to model_inventory"
		else
			print_error "Failed to migrate model_access records — legacy DB preserved"
			migration_failed=true
		fi
	fi

	if [[ "$migration_failed" == "true" ]]; then
		print_error "Migration partially failed. Legacy DB preserved at ${legacy_db}"
		return 1
	fi

	print_success "Migration complete. Legacy DB preserved at ${legacy_db}"
	return 0
}

# Ensure schema is current (add missing columns/tables idempotently)
_ensure_schema_current() {
	# Check if model_usage table exists (might be old schema with 'usage' table)
	local has_model_usage has_model_inventory
	has_model_usage="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_usage';" 2>/dev/null || echo "0")"
	has_model_inventory="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_inventory';" 2>/dev/null || echo "0")"

	if [[ "$has_model_usage" == "0" ]]; then
		# Create model_usage table
		log_stderr "ensure_schema_usage" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'
			CREATE TABLE IF NOT EXISTS model_usage (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				model TEXT NOT NULL,
				session_id TEXT DEFAULT '',
				timestamp TEXT NOT NULL DEFAULT (datetime('now')),
				tokens_in INTEGER DEFAULT 0,
				tokens_out INTEGER DEFAULT 0,
				duration_ms INTEGER DEFAULT 0,
				tok_per_sec REAL DEFAULT 0.0
			);
			CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
			CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
			CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
		SQLEOF

		# Migrate from legacy 'usage' table if it exists (check separately to avoid prepare-time errors)
		local has_legacy_usage
		has_legacy_usage="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='usage';" 2>/dev/null || echo "0")"
		if [[ "$has_legacy_usage" == "1" ]]; then
			sqlite3 "$LOCAL_USAGE_DB" "INSERT OR IGNORE INTO model_usage (model, session_id, timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec) SELECT model, '', timestamp, tokens_in, tokens_out, duration_ms, tok_per_sec FROM usage;" 2>/dev/null || true
		fi
	fi

	if [[ "$has_model_inventory" == "0" ]]; then
		# Create model_inventory table
		log_stderr "ensure_schema_inventory" sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF'
			CREATE TABLE IF NOT EXISTS model_inventory (
				model TEXT PRIMARY KEY,
				file_path TEXT NOT NULL DEFAULT '',
				repo_source TEXT DEFAULT '',
				size_bytes INTEGER DEFAULT 0,
				quantization TEXT DEFAULT '',
				first_seen TEXT NOT NULL DEFAULT (datetime('now')),
				last_used TEXT NOT NULL DEFAULT (datetime('now')),
				total_requests INTEGER DEFAULT 0
			);
			CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
		SQLEOF

		# Migrate from legacy 'model_access' table if it exists
		local has_legacy_access
		has_legacy_access="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='model_access';" 2>/dev/null || echo "0")"
		if [[ "$has_legacy_access" == "1" ]]; then
			sqlite3 "$LOCAL_USAGE_DB" "INSERT OR IGNORE INTO model_inventory (model, first_seen, last_used, total_requests) SELECT model, first_used, last_used, total_requests FROM model_access;" 2>/dev/null || true
		fi
	fi

	# Column-level drift detection: add missing columns idempotently.
	# Each ALTER TABLE is wrapped individually so a failure on one column
	# (e.g. column already exists) does not prevent subsequent columns from
	# being checked.
	local usage_cols
	usage_cols="$(sqlite3 "$LOCAL_USAGE_DB" "PRAGMA table_info('model_usage');" 2>/dev/null || echo "")"
	if [[ -n "$usage_cols" ]]; then
		if ! printf '%s' "$usage_cols" | grep -q "session_id"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_usage ADD COLUMN session_id TEXT DEFAULT '';" 2>/dev/null || true
		fi
	fi

	local inv_cols
	inv_cols="$(sqlite3 "$LOCAL_USAGE_DB" "PRAGMA table_info('model_inventory');" 2>/dev/null || echo "")"
	if [[ -n "$inv_cols" ]]; then
		if ! printf '%s' "$inv_cols" | grep -q "file_path"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN file_path TEXT NOT NULL DEFAULT '';" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "repo_source"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN repo_source TEXT DEFAULT '';" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "size_bytes"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN size_bytes INTEGER DEFAULT 0;" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "quantization"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN quantization TEXT DEFAULT '';" 2>/dev/null || true
		fi
		if ! printf '%s' "$inv_cols" | grep -q "first_seen"; then
			sqlite3 "$LOCAL_USAGE_DB" "ALTER TABLE model_inventory ADD COLUMN first_seen TEXT NOT NULL DEFAULT '';" 2>/dev/null || true
			sqlite3 "$LOCAL_USAGE_DB" "UPDATE model_inventory SET first_seen = datetime('now') WHERE first_seen = '';" 2>/dev/null || true
		fi
	fi

	# Ensure indexes exist
	sqlite3 "$LOCAL_USAGE_DB" <<-'SQLEOF' 2>/dev/null || true
		CREATE INDEX IF NOT EXISTS idx_model_usage_model ON model_usage(model);
		CREATE INDEX IF NOT EXISTS idx_model_usage_timestamp ON model_usage(timestamp);
		CREATE INDEX IF NOT EXISTS idx_model_usage_session ON model_usage(session_id);
		CREATE INDEX IF NOT EXISTS idx_model_inventory_last_used ON model_inventory(last_used);
	SQLEOF
	return 0
}

# =============================================================================
# Usage Recording & Inventory Sync
# =============================================================================

# Record a usage event (t1338.5: per-session logging)
record_usage() {
	local model="$1"
	local tokens_in="${2:-0}"
	local tokens_out="${3:-0}"
	local duration_ms="${4:-0}"
	local tok_per_sec="${5:-0.0}"
	local session_id="${6:-${CLAUDE_SESSION_ID:-${OPENCODE_SESSION_ID:-}}}"

	if ! suppress_stderr command -v sqlite3 || [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		return 0
	fi

	local escaped_model escaped_session
	escaped_model="$(sql_escape "$model")"
	escaped_session="$(sql_escape "$session_id")"

	# Sanitize numeric parameters to prevent SQL injection via integer/real fields
	local safe_tokens_in safe_tokens_out safe_duration_ms safe_tok_per_sec
	safe_tokens_in="$(sql_int "$tokens_in")"
	safe_tokens_out="$(sql_int "$tokens_out")"
	safe_duration_ms="$(sql_int "$duration_ms")"
	safe_tok_per_sec="$(sql_real "$tok_per_sec")"

	log_stderr "record_usage" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF
		INSERT INTO model_usage (model, session_id, tokens_in, tokens_out, duration_ms, tok_per_sec)
		VALUES ('${escaped_model}', '${escaped_session}', ${safe_tokens_in}, ${safe_tokens_out}, ${safe_duration_ms}, ${safe_tok_per_sec});

		INSERT INTO model_inventory (model, total_requests)
		VALUES ('${escaped_model}', 1)
		ON CONFLICT(model) DO UPDATE SET
			last_used = datetime('now'),
			total_requests = total_requests + 1;
	SQLEOF
	return 0
}

# Register a model in the inventory when downloaded (t1338.5)
register_model_inventory() {
	local model_name="$1"
	local file_path="${2:-}"
	local repo_source="${3:-}"
	local size_bytes="${4:-0}"
	local quantization="${5:-}"

	if ! suppress_stderr command -v sqlite3 || [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		return 0
	fi

	local escaped_name escaped_path escaped_repo escaped_quant safe_size_bytes
	escaped_name="$(sql_escape "$model_name")"
	escaped_path="$(sql_escape "$file_path")"
	escaped_repo="$(sql_escape "$repo_source")"
	escaped_quant="$(sql_escape "$quantization")"
	safe_size_bytes="$(sql_int "$size_bytes")"

	log_stderr "register_model_inventory" sqlite3 "$LOCAL_USAGE_DB" <<-SQLEOF
		INSERT INTO model_inventory (model, file_path, repo_source, size_bytes, quantization)
		VALUES ('${escaped_name}', '${escaped_path}', '${escaped_repo}', ${safe_size_bytes}, '${escaped_quant}')
		ON CONFLICT(model) DO UPDATE SET
			file_path = '${escaped_path}',
			repo_source = CASE WHEN '${escaped_repo}' != '' THEN '${escaped_repo}' ELSE repo_source END,
			size_bytes = CASE WHEN ${safe_size_bytes} > 0 THEN ${safe_size_bytes} ELSE size_bytes END,
			quantization = CASE WHEN '${escaped_quant}' != '' THEN '${escaped_quant}' ELSE quantization END;
	SQLEOF
	return 0
}

# Sync model_inventory with files on disk (t1338.5)
# Scans LOCAL_MODELS_STORE and ensures every .gguf file is registered
sync_model_inventory() {
	if ! suppress_stderr command -v sqlite3 || [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		return 0
	fi

	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"
	[[ -z "$models" ]] && return 0

	while IFS= read -r model_path; do
		local name size_bytes quant
		name="$(basename "$model_path")"

		size_bytes="$(_file_size_bytes "$model_path")"

		# Extract quantization from filename
		quant="$(echo "$name" | grep -oiE '(q[0-9]_[a-z0-9_]+|iq[0-9]_[a-z0-9]+|f16|f32|bf16)' | head -1 | tr '[:lower:]' '[:upper:]')"

		register_model_inventory "$name" "$model_path" "" "$size_bytes" "$quant"
	done <<<"$models"

	# Mark models in inventory that no longer exist on disk
	local db_models
	db_models="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT model FROM model_inventory;" 2>/dev/null || echo "")"
	if [[ -n "$db_models" ]]; then
		while IFS= read -r db_model; do
			local found=false
			while IFS= read -r model_path; do
				if [[ "$(basename "$model_path")" == "$db_model" ]]; then
					found=true
					break
				fi
			done <<<"$models"
			if [[ "$found" == "false" ]]; then
				# Model file removed from disk — update inventory (keep record for history)
				local escaped_db_model
				escaped_db_model="$(sql_escape "$db_model")"
				sqlite3 "$LOCAL_USAGE_DB" "UPDATE model_inventory SET file_path = '' WHERE model = '${escaped_db_model}' AND file_path != '';" 2>/dev/null || true
			fi
		done <<<"$db_models"
	fi

	return 0
}
