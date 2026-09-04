#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# MCP Index Helper - Tool description indexing for on-demand MCP discovery
# =============================================================================
# Creates and maintains an index of MCP tool descriptions for efficient
# on-demand discovery instead of loading all tool definitions upfront.
#
# Usage:
#   mcp-index-helper.sh sync              # Sync MCP descriptions from opencode.json
#   mcp-index-helper.sh search "query"    # Search for tools matching query
#   mcp-index-helper.sh list [mcp-name]   # List tools for an MCP server
#   mcp-index-helper.sh status            # Show index status
#   mcp-index-helper.sh rebuild           # Force rebuild index
#
# Architecture:
#   - Extracts tool descriptions from MCP server manifests
#   - Stores in SQLite FTS5 for fast full-text search
#   - Enables agents to discover tools without loading all MCPs
#   - Supports lazy-loading pattern: search → find MCP → enable MCP → use tool
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly INDEX_DIR="${AIDEVOPS_MCP_INDEX_DIR:-$HOME/.aidevops/.agent-workspace/mcp-index}"
readonly INDEX_DB="$INDEX_DIR/mcp-tools.db"
# Primary MCP config — use runtime registry if available, fallback to opencode (t1665.5)
if type rt_config_path &>/dev/null; then
	_MCP_IDX_CONFIG=$(rt_config_path "opencode") || _MCP_IDX_CONFIG=""
else
	_MCP_IDX_CONFIG="$HOME/.config/opencode/opencode.json"
fi
readonly OPENCODE_CONFIG="${_MCP_IDX_CONFIG}"
# shellcheck disable=SC2034  # Used for future cache invalidation
readonly CACHE_TTL_HOURS=24

# Logging: uses shared log_* from shared-constants.sh

#######################################
# Initialize SQLite database with FTS5
#######################################
init_db() {
	mkdir -p "$INDEX_DIR"

	if [[ ! -f "$INDEX_DB" ]]; then
		log_info "Creating MCP tool index at $INDEX_DB"

		sqlite3 "$INDEX_DB" <<'EOF'
-- Main tools table
CREATE TABLE IF NOT EXISTS mcp_tools (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mcp_name TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    description TEXT,
    input_schema TEXT,
    category TEXT,
    enabled_globally INTEGER DEFAULT 0,
    indexed_at TEXT DEFAULT (datetime('now')),
    UNIQUE(mcp_name, tool_name)
);

-- FTS5 virtual table for fast text search
CREATE VIRTUAL TABLE IF NOT EXISTS mcp_tools_fts USING fts5(
    mcp_name,
    tool_name,
    description,
    category,
    content='mcp_tools',
    content_rowid='id'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS mcp_tools_ai AFTER INSERT ON mcp_tools BEGIN
    INSERT INTO mcp_tools_fts(rowid, mcp_name, tool_name, description, category)
    VALUES (new.id, new.mcp_name, new.tool_name, new.description, new.category);
END;

CREATE TRIGGER IF NOT EXISTS mcp_tools_ad AFTER DELETE ON mcp_tools BEGIN
    INSERT INTO mcp_tools_fts(mcp_tools_fts, rowid, mcp_name, tool_name, description, category)
    VALUES ('delete', old.id, old.mcp_name, old.tool_name, old.description, old.category);
END;

CREATE TRIGGER IF NOT EXISTS mcp_tools_au AFTER UPDATE ON mcp_tools BEGIN
    INSERT INTO mcp_tools_fts(mcp_tools_fts, rowid, mcp_name, tool_name, description, category)
    VALUES ('delete', old.id, old.mcp_name, old.tool_name, old.description, old.category);
    INSERT INTO mcp_tools_fts(rowid, mcp_name, tool_name, description, category)
    VALUES (new.id, new.mcp_name, new.tool_name, new.description, new.category);
END;

-- Metadata table for tracking sync state
CREATE TABLE IF NOT EXISTS sync_metadata (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Index for common queries
CREATE INDEX IF NOT EXISTS idx_mcp_tools_mcp ON mcp_tools(mcp_name);
CREATE INDEX IF NOT EXISTS idx_mcp_tools_enabled ON mcp_tools(enabled_globally);
EOF
		log_success "Database initialized"
	fi
}

#######################################
# Check if index needs refresh
#######################################
needs_refresh() {
	if [[ ! -f "$INDEX_DB" ]]; then
		return 0
	fi

	local last_sync
	last_sync=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='last_sync'" 2>/dev/null || echo "")

	if [[ -z "$last_sync" ]]; then
		return 0
	fi

	# Check if opencode.json is newer than last sync
	if [[ -f "$OPENCODE_CONFIG" ]]; then
		local config_mtime
		config_mtime=$(_file_mtime_epoch "$OPENCODE_CONFIG")
		local sync_epoch
		sync_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_sync" +%s 2>/dev/null || date -d "$last_sync" +%s 2>/dev/null || echo "0")

		if [[ "$config_mtime" -gt "$sync_epoch" ]]; then
			return 0
		fi
	fi

	return 1
}

#######################################
# Insert MCP tools into the index database
# Reads opencode.json, iterates enabled MCP servers,
# classifies tools by category, and upserts rows.
# Prints "tool_count mcp_count" to stdout on success.
# Uses Python for reliable JSON parsing.
#######################################
_sync_insert_tools() {
	python3 - "$INDEX_DB" "$OPENCODE_CONFIG" <<'PYEOF'
import json
import sqlite3
import sys

db_path, config_path = sys.argv[1], sys.argv[2]

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except Exception as e:
    print(f"Error reading config: {e}", file=sys.stderr)
    sys.exit(1)

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Get MCP servers from config
mcp_servers = config.get('mcp', {})
global_tools = config.get('tools', {})

tool_count = 0
mcp_count = 0

# Common tool patterns based on MCP naming conventions
tool_categories = {
    'context7': ['query-docs', 'resolve-library-id'],
    'dataforseo': ['serp', 'keywords', 'backlinks', 'domain-analytics'],
    # serper - REMOVED: Uses curl subagent (.agents/seo/serper.md)
    'gsc': ['query', 'sitemaps', 'inspect'],
    'shadcn': ['browse', 'search', 'install'],
    'playwright': ['navigate', 'click', 'type', 'screenshot'],
    'playwriter': ['navigate', 'click', 'type', 'screenshot'],
    'macos-automator': ['run-applescript', 'run-jxa', 'list-apps'],
    'outscraper': ['google-maps', 'reviews', 'business-info'],
    'quickfile': ['invoices', 'expenses', 'reports'],
    'localwp': ['sites', 'start', 'stop'],
    'claude-code-mcp': ['run_claude_code'],
}

# More specific descriptions for known tools
tool_descriptions = {
    'query-docs': 'Query documentation for a library using Context7',
    'resolve-library-id': 'Resolve a library name to Context7 ID',
    'search': 'Search for content or code',
    'trace': 'Trace code execution paths',
    'skeleton': 'Generate code skeleton/structure',
    'pack_codebase': 'Package local codebase for AI analysis',
    'pack_remote_repository': 'Package remote GitHub repo for AI analysis',
    'run_claude_code': 'Run Claude Code as a one-shot subprocess',
}

for mcp_name, mcp_config in mcp_servers.items():
    if not isinstance(mcp_config, dict):
        continue

    # Skip disabled MCPs
    if not mcp_config.get('enabled', True):
        continue

    mcp_count += 1

    # Check if this MCP's tools are globally enabled
    tool_pattern = f"{mcp_name}_*"
    globally_enabled = 1 if global_tools.get(tool_pattern, False) else 0

    # Classify category and resolve known tools for this MCP
    category = 'general'
    known_tools = []

    for pattern, tools in tool_categories.items():
        if pattern in mcp_name.lower():
            known_tools = tools
            # Derive category from MCP name
            if 'seo' in mcp_name.lower() or pattern in ['dataforseo', 'gsc']:
                category = 'seo'
            elif pattern == 'context7':
                category = 'context'
            elif pattern in ['shadcn', 'playwright', 'playwriter']:
                category = 'browser'
            elif pattern == 'macos-automator':
                category = 'automation'
            elif pattern == 'outscraper':
                category = 'data-extraction'
            elif pattern == 'quickfile':
                category = 'accounting'
            elif pattern == 'localwp':
                category = 'wordpress'
            elif pattern == 'claude-code-mcp':
                category = 'ai-assistant'
            break

    # If no known tools, create a generic placeholder entry
    if not known_tools:
        known_tools = ['*']

    for tool in known_tools:
        tool_name = f"{mcp_name}_{tool}" if tool != '*' else f"{mcp_name}_*"
        description = tool_descriptions.get(tool, f"Tool from {mcp_name} MCP server")

        cursor.execute('''
            INSERT OR REPLACE INTO mcp_tools
            (mcp_name, tool_name, description, category, enabled_globally, indexed_at)
            VALUES (?, ?, ?, ?, ?, datetime('now'))
        ''', (mcp_name, tool_name, description, category, globally_enabled))
        tool_count += 1

conn.commit()
conn.close()

# Print counts for the caller to capture and store in metadata
print(f"{tool_count} {mcp_count}")
PYEOF
	return 0
}

#######################################
# Update sync metadata after a successful tool insert
# Args: $1=tool_count $2=mcp_count
#######################################
_sync_update_metadata() {
	local tool_count="$1"
	local mcp_count="$2"

	python3 - "$INDEX_DB" "$tool_count" "$mcp_count" <<'PYEOF'
import sqlite3
import sys

db_path, tool_count, mcp_count = sys.argv[1], sys.argv[2], sys.argv[3]

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

cursor.execute('''
    INSERT OR REPLACE INTO sync_metadata (key, value, updated_at)
    VALUES ('last_sync', datetime('now'), datetime('now'))
''')
cursor.execute('''
    INSERT OR REPLACE INTO sync_metadata (key, value, updated_at)
    VALUES ('mcp_count', ?, datetime('now'))
''', (mcp_count,))
cursor.execute('''
    INSERT OR REPLACE INTO sync_metadata (key, value, updated_at)
    VALUES ('tool_count', ?, datetime('now'))
''', (tool_count,))

conn.commit()
conn.close()
PYEOF
	return 0
}

#######################################
# Extract MCP tool descriptions from config
# Orchestrates: init_db → insert tools → update metadata
#######################################
sync_from_config() {
	init_db

	if [[ ! -f "$OPENCODE_CONFIG" ]]; then
		log_error "OpenCode config not found: $OPENCODE_CONFIG"
		return 1
	fi

	log_info "Syncing MCP tool descriptions from opencode.json..."

	local counts
	counts=$(_sync_insert_tools) || return 1

	local tool_count mcp_count
	tool_count=$(echo "$counts" | awk '{print $1}')
	mcp_count=$(echo "$counts" | awk '{print $2}')

	_sync_update_metadata "$tool_count" "$mcp_count" || return 1

	log_success "Synced $tool_count tools from $mcp_count MCP servers"
	return 0
}

#######################################
# Search for tools matching a query
# Uses Python with parameterized queries to prevent SQL injection
#######################################
search_tools() {
	local query="$1"
	local limit="${2:-10}"

	init_db

	# Auto-sync if needed
	if needs_refresh; then
		sync_from_config
	fi

	echo -e "${CYAN}Searching for tools matching: ${NC}$query"
	echo ""

	# Validate limit is a positive integer
	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		log_error "Limit must be a positive integer"
		return 1
	fi

	# Use Python with parameterized queries to prevent FTS5 injection
	python3 - "$INDEX_DB" "$query" "$limit" <<'PYEOF'
import sys
import sqlite3

db_path, query, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cursor = conn.cursor()

try:
    cursor.execute('''
        SELECT
            mcp_name AS MCP,
            tool_name AS Tool,
            description AS Description,
            category AS Category,
            CASE enabled_globally WHEN 1 THEN 'Yes' ELSE 'No' END AS Global
        FROM mcp_tools_fts
        WHERE mcp_tools_fts MATCH ?
        ORDER BY rank
        LIMIT ?
    ''', (query, limit))
    rows = cursor.fetchall()
except sqlite3.OperationalError as e:
    print(f"Search error (invalid query syntax): {e}", file=sys.stderr)
    conn.close()
    sys.exit(1)

if not rows:
    print("No results found.")
    conn.close()
    sys.exit(0)

# Print column-aligned output
cols = ['MCP', 'Tool', 'Description', 'Category', 'Global']
widths = [max(len(str(r[c])) for r in rows + [dict(zip(cols, cols))]) for c in cols]
header = '  '.join(c.ljust(w) for c, w in zip(cols, widths))
print(header)
print('  '.join('-' * w for w in widths))
for row in rows:
    print('  '.join(str(row[c]).ljust(w) for c, w in zip(cols, widths)))

conn.close()
PYEOF
	return 0
}

#######################################
# List tools for a specific MCP
#######################################
list_tools() {
	local mcp_name="${1:-}"

	init_db

	if [[ -z "$mcp_name" ]]; then
		# List all MCPs with tool counts
		echo -e "${CYAN}MCP Servers with indexed tools:${NC}"
		echo ""
		sqlite3 -header -column "$INDEX_DB" <<'EOF'
SELECT 
    mcp_name as MCP,
    COUNT(*) as Tools,
    category as Category,
    MAX(CASE enabled_globally WHEN 1 THEN 'Yes' ELSE 'No' END) as Global
FROM mcp_tools
GROUP BY mcp_name
ORDER BY mcp_name;
EOF
	else
		# List tools for specific MCP using parameterized query
		echo -e "${CYAN}Tools for MCP: ${NC}$mcp_name"
		echo ""
		python3 - "$INDEX_DB" "$mcp_name" <<'PYEOF'
import sys
import sqlite3

db_path, mcp_name = sys.argv[1], sys.argv[2]

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cursor = conn.cursor()

cursor.execute('''
    SELECT
        tool_name AS Tool,
        description AS Description,
        CASE enabled_globally WHEN 1 THEN 'Yes' ELSE 'No' END AS Global
    FROM mcp_tools
    WHERE mcp_name = ?
    ORDER BY tool_name
''', (mcp_name,))

rows = cursor.fetchall()
conn.close()

if not rows:
    print("No tools found for this MCP.")
    sys.exit(0)

cols = ['Tool', 'Description', 'Global']
widths = [max(len(str(r[c])) for r in rows + [dict(zip(cols, cols))]) for c in cols]
header = '  '.join(c.ljust(w) for c, w in zip(cols, widths))
print(header)
print('  '.join('-' * w for w in widths))
for row in rows:
    print('  '.join(str(row[c]).ljust(w) for c, w in zip(cols, widths)))
PYEOF
	fi
	return 0
}

#######################################
# Show index status
#######################################
show_status() {
	init_db

	echo -e "${CYAN}MCP Tool Index Status${NC}"
	echo "====================="
	echo ""

	local last_sync mcp_count tool_count
	last_sync=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='last_sync'" 2>/dev/null || echo "Never")
	mcp_count=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='mcp_count'" 2>/dev/null || echo "0")
	tool_count=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='tool_count'" 2>/dev/null || echo "0")

	echo "Database: $INDEX_DB"
	echo "Last sync: $last_sync"
	echo "MCP servers: $mcp_count"
	echo "Tools indexed: $tool_count"
	echo ""

	# Show globally enabled vs disabled
	local enabled disabled
	enabled=$(sqlite3 "$INDEX_DB" "SELECT COUNT(*) FROM mcp_tools WHERE enabled_globally = 1" 2>/dev/null || echo "0")
	disabled=$(sqlite3 "$INDEX_DB" "SELECT COUNT(*) FROM mcp_tools WHERE enabled_globally = 0" 2>/dev/null || echo "0")

	echo "Globally enabled tools: $enabled"
	echo "Disabled (on-demand): $disabled"
	echo ""

	# Show by category
	echo -e "${CYAN}Tools by category:${NC}"
	sqlite3 -header -column "$INDEX_DB" <<'EOF'
SELECT 
    category as Category,
    COUNT(*) as Tools,
    SUM(CASE enabled_globally WHEN 1 THEN 1 ELSE 0 END) as Enabled,
    SUM(CASE enabled_globally WHEN 0 THEN 1 ELSE 0 END) as OnDemand
FROM mcp_tools
GROUP BY category
ORDER BY Tools DESC;
EOF
	return 0
}

#######################################
# Rebuild index from scratch
#######################################
rebuild_index() {
	log_info "Rebuilding MCP tool index..."

	if [[ -f "$INDEX_DB" ]]; then
		rm -f "$INDEX_DB"
		log_info "Removed old index"
	fi

	sync_from_config
	log_success "Index rebuilt"
	return 0
}

#######################################
# Get MCP for a tool (for lazy-loading)
# Uses Python with parameterized queries to prevent SQL injection
#######################################
get_mcp_for_tool() {
	local tool_query="$1"

	init_db

	# Use Python with parameterized queries to prevent LIKE injection
	# (shell escaping of %, _, and ' in LIKE patterns is error-prone)
	python3 - "$INDEX_DB" "$tool_query" <<'PYEOF'
import sys
import sqlite3

db_path, tool_query = sys.argv[1], sys.argv[2]

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Parameterized LIKE: bind the pattern as a parameter, not via interpolation
pattern = f"%{tool_query}%"
cursor.execute('''
    SELECT DISTINCT mcp_name
    FROM mcp_tools
    WHERE tool_name LIKE ?
    LIMIT 1
''', (pattern,))

row = cursor.fetchone()
if row:
    print(row[0])

conn.close()
PYEOF
	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'EOF'
MCP Index Helper - Tool description indexing for on-demand MCP discovery

Usage:
  mcp-index-helper.sh sync              Sync MCP descriptions from opencode.json
  mcp-index-helper.sh search "query"    Search for tools matching query
  mcp-index-helper.sh list [mcp-name]   List tools (all MCPs or specific one)
  mcp-index-helper.sh status            Show index status
  mcp-index-helper.sh rebuild           Force rebuild index
  mcp-index-helper.sh get-mcp "tool"    Find which MCP provides a tool
  mcp-index-helper.sh help              Show this help

Examples:
  mcp-index-helper.sh search "screenshot"
  mcp-index-helper.sh search "seo keyword"
  mcp-index-helper.sh list context7
  mcp-index-helper.sh get-mcp "query-docs"

The index enables on-demand MCP discovery:
  1. Agent searches for capability: "I need to take screenshots"
  2. Index returns: playwright MCP has screenshot tools
  3. Agent enables playwright MCP for this session
  4. Agent uses the tool

This avoids loading all MCP tool definitions upfront, reducing context usage.
EOF
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	sync)
		sync_from_config
		;;
	search)
		if [[ -z "${1:-}" ]]; then
			log_error "Usage: mcp-index-helper.sh search \"query\""
			return 1
		fi
		search_tools "$1" "${2:-10}"
		;;
	list)
		list_tools "${1:-}"
		;;
	status)
		show_status
		;;
	rebuild)
		rebuild_index
		;;
	get-mcp)
		if [[ -z "${1:-}" ]]; then
			log_error "Usage: mcp-index-helper.sh get-mcp \"tool-name\""
			return 1
		fi
		get_mcp_for_tool "$1"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
