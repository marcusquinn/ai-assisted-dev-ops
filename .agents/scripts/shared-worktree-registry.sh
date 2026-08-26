#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# Worktree Ownership Registry (t189)
# SQLite-backed registry that tracks which session/batch owns each worktree.
# Prevents cross-session worktree removal — the root cause of t189.
#
# Extracted from shared-constants.sh to keep that file < 2000 lines.
# Source shared-constants.sh (which sources this file) rather than sourcing
# this file directly — the include guard prevents double-loading.
#
# Available to all scripts that source shared-constants.sh.
#
# Usage: source .agents/scripts/shared-constants.sh
#        # Then call register_worktree, claim_worktree_ownership, etc.

# cool — include guard prevents readonly errors when sourced multiple times
[[ -n "${_SHARED_WORKTREE_REGISTRY_LOADED:-}" ]] && return 0
_SHARED_WORKTREE_REGISTRY_LOADED=1

# =============================================================================
# Worktree Ownership Registry (t189)
# =============================================================================

_worktree_registry_dir_is_safe() {
	local path="$1"
	[[ -n "$path" ]] || return 1
	[[ -L "$path" ]] && return 1
	[[ -e "$path" && ! -O "$path" ]] && return 1
	[[ -e "$path" && ! -d "$path" ]] && return 1
	return 0
}

_worktree_registry_ensure_dir() {
	local path="$1"
	_worktree_registry_dir_is_safe "$path" || return 1
	if [[ ! -d "$path" ]]; then
		(umask 0077 && mkdir -p "$path") || return 1
	fi
	_worktree_registry_dir_is_safe "$path" || return 1
	return 0
}

_WORKTREE_REGISTRY_HOME="${HOME:-}"
if [[ -z "$_WORKTREE_REGISTRY_HOME" ]]; then
	if _WORKTREE_REGISTRY_UID="$(id -u)"; then
		:
	else
		_WORKTREE_REGISTRY_UID="shared"
	fi
	_WORKTREE_REGISTRY_TMPDIR="${WORKTREE_REGISTRY_TMPDIR:-/tmp}"
	_WORKTREE_REGISTRY_HOME="${_WORKTREE_REGISTRY_TMPDIR}/aidevops-${_WORKTREE_REGISTRY_UID}"
	if ! _worktree_registry_ensure_dir "$_WORKTREE_REGISTRY_HOME"; then
		_WORKTREE_REGISTRY_HOME="${_WORKTREE_REGISTRY_TMPDIR}/aidevops-${_WORKTREE_REGISTRY_UID}-$$"
		if ! _worktree_registry_ensure_dir "$_WORKTREE_REGISTRY_HOME"; then
			_WORKTREE_REGISTRY_HOME="$(mktemp -d "${_WORKTREE_REGISTRY_TMPDIR}/aidevops-${_WORKTREE_REGISTRY_UID}.XXXXXXXXXX")" || _WORKTREE_REGISTRY_HOME=""
		fi
	fi
	if [[ -z "${_WORKTREE_REGISTRY_HOME:-}" ]] || ! _worktree_registry_dir_is_safe "$_WORKTREE_REGISTRY_HOME"; then
		printf 'ERROR: unable to create a safe worktree registry home under %s\n' "${_WORKTREE_REGISTRY_TMPDIR:-}" >&2
		return 1
	fi
fi
WORKTREE_REGISTRY_DIR="${WORKTREE_REGISTRY_DIR:-${_WORKTREE_REGISTRY_HOME}/.aidevops/.agent-workspace}"
WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DB:-${WORKTREE_REGISTRY_DIR}/worktree-registry.db}"
WORKTREE_OWNER_DEAD_COOLDOWN_MINUTES="${WORKTREE_OWNER_DEAD_COOLDOWN_MINUTES:-60}"
_WORKTREE_REGISTRY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1

# Get the command name (basename) for a given PID.
# Returns empty string if the PID does not exist or info is unavailable.
# Arguments:
#   $1 - PID to inspect
# Returns: command basename on stdout
_get_proc_comm() {
	local pid="${1:-}"
	[[ -z "$pid" ]] && return 0

	local comm=""
	if [[ -r "/proc/$pid/status" ]]; then
		# Linux: read Name field from /proc
		comm=$(awk '/^Name:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
	else
		# macOS/BSD: use ps
		comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ') || comm=""
	fi
	printf '%s' "${comm##*/}"
	return 0
}

# Resolve a stable process-generation token. Prefer the canonical helper after
# shared-constants.sh finishes loading; direct library consumers use the same
# Linux /proc start-tick or portable process-start-time identity.
_wt_process_start_token_for_pid() {
	local pid="$1"
	local process_start=""
	local stat_content=""
	local stat_after_comm=""
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	if declare -F _process_start_token >/dev/null 2>&1; then
		process_start=$(_process_start_token "$pid") || return 1
	elif [[ -r "/proc/${pid}/stat" ]]; then
		stat_content=$(<"/proc/${pid}/stat") || stat_content=""
		[[ -n "$stat_content" ]] || return 1
		stat_after_comm="${stat_content##*) }"
		process_start=$(printf '%s\n' "$stat_after_comm" | awk '{print $20}') || process_start=""
	else
		process_start=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ') || process_start=""
		process_start="${process_start#"${process_start%%[![:space:]]*}"}"
		process_start="${process_start%"${process_start##*[![:space:]]}"}"
	fi
	[[ -n "$process_start" ]] || return 1
	printf '%s' "$process_start"
	return 0
}

# Get the parent PID for a given PID.
# Returns empty string if the PID does not exist or info is unavailable.
# Arguments:
#   $1 - PID to inspect
# Returns: parent PID on stdout
_get_proc_ppid() {
	local pid="${1:-}"
	[[ -z "$pid" ]] && return 0

	local parent_pid=""
	if [[ -r "/proc/$pid/status" ]]; then
		# Linux: read PPid field from /proc
		parent_pid=$(awk '/^PPid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
	else
		# macOS/BSD: use ps
		parent_pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || parent_pid=""
	fi
	printf '%s' "$parent_pid"
	return 0
}

# Check if a command name matches a known AI interactive runtime.
# These are long-lived processes that spawn transient bash subprocesses for tool calls.
# Arguments:
#   $1 - command basename (e.g. ".opencode", "claude", "node")
# Returns: 0 if it is a known AI runtime, 1 otherwise
_is_ai_runtime_comm() {
	local comm="${1:-}"
	case "$comm" in
	# OpenCode runtime (may appear as ".opencode" on Linux)
	opencode | .opencode)
		return 0
		;;
	# Claude Code CLI
	claude | .claude)
		return 0
		;;
	# Node.js-based runtimes (Claude Code, OpenCode web, etc.)
	# Only match if the parent is not itself a shell — node is too generic
	# to match unconditionally, but it is the common wrapper for AI runtimes.
	node | .node)
		return 0
		;;
	esac
	return 1
}

# Check if a command name is a transient shell subprocess.
# Arguments:
#   $1 - command basename
# Returns: 0 if it is a shell, 1 otherwise
_is_shell_comm() {
	local comm="${1:-}"
	case "$comm" in
	bash | sh | dash | zsh | ksh | fish)
		return 0
		;;
	esac
	return 1
}

# Resolve the long-lived process ID that should own a worktree lock.
# Priority:
#   1) Explicit override (first argument)
#   2) OpenCode interactive PID (OPENCODE_PID)
#   3) If PPID is a transient shell whose parent is a known AI runtime,
#      return the AI runtime PID (GH#18090 fix)
#   4) PPID as-is (stable user shell or other long-lived process)
#   5) Current shell PID ($$)
# Returns: PID string on stdout
#
# GH#18090: Interactive sessions (Claude Code, OpenCode) spawn short-lived bash
# subprocesses for tool calls. Registering PPID directly causes stale registry
# entries because the bash process exits immediately after the tool call.
# We check one level up: if PPID is a shell AND its parent is a known AI runtime,
# use the AI runtime PID. This avoids collapsing independent user shell sessions
# (e.g. multiple tmux panes) under a single parent PID.
_resolve_worktree_owner_pid() {
	local explicit_pid="${1:-}"
	if [[ -n "$explicit_pid" ]]; then
		if [[ "$explicit_pid" =~ ^[0-9]+$ ]]; then
			printf '%s' "$explicit_pid"
		else
			printf '%s' "$$"
		fi
		return 0
	fi

	if [[ -n "${OPENCODE_PID:-}" ]]; then
		printf '%s' "$OPENCODE_PID"
		return 0
	fi

	if [[ -n "${PPID:-}" ]]; then
		# Check if PPID is a transient shell subprocess of a known AI runtime.
		# If so, register the AI runtime PID instead of the short-lived shell.
		local ppid_comm
		ppid_comm=$(_get_proc_comm "$PPID")
		if _is_shell_comm "$ppid_comm"; then
			local grandparent_pid
			grandparent_pid=$(_get_proc_ppid "$PPID")
			if [[ -n "$grandparent_pid" ]] && [[ "$grandparent_pid" -gt 1 ]] 2>/dev/null; then
				local grandparent_comm
				grandparent_comm=$(_get_proc_comm "$grandparent_pid")
				if _is_ai_runtime_comm "$grandparent_comm"; then
					# PPID is a shell spawned by an AI runtime — use the runtime PID
					printf '%s' "$grandparent_pid"
					return 0
				fi
			fi
		fi
		# PPID is not a transient AI-runtime shell — use it as-is
		printf '%s' "$PPID"
		return 0
	fi

	printf '%s' "$$"
	return 0
}

# SQL-escape a value for SQLite (double single quotes)
_wt_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
}

_wt_sqlite_set_owner_pid_param() {
	local owner_pid="$1"
	printf '.parameter init\n'
	printf '.parameter set :owner_pid %s\n' "$owner_pid"
	return 0
}

# Normalize a filesystem path to a stable absolute form.
# This prevents duplicate registry rows for equivalent paths
# such as /var/... vs /private/var/... on macOS.
_wt_normalize_path() {
	local raw_path="$1"
	if [[ -z "$raw_path" ]]; then
		printf '%s' ""
		return 0
	fi

	local normalized=""
	if command -v python3 >/dev/null 2>&1; then
		normalized=$(
			python3 - "$raw_path" <<'PY' 2>/dev/null || true
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
		)
	fi

	if [[ -z "$normalized" ]]; then
		if [[ -d "$raw_path" ]]; then
			normalized=$(cd "$raw_path" 2>/dev/null && pwd -P) || normalized="$raw_path"
		else
			normalized="$raw_path"
		fi
	fi

	printf '%s' "$normalized"
	return 0
}

_wt_registry_resolve_path_python() {
	local requested_path="$1"
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 2
	command -v python3 >/dev/null 2>&1 || return 2

	python3 - "$WORKTREE_REGISTRY_DB" "$requested_path" <<'PY' 2>/dev/null
import os
import sqlite3
import sys

database_path, requested_path = sys.argv[1:]
normalized = os.path.realpath(requested_path)
try:
    with sqlite3.connect(database_path) as connection:
        rows = connection.execute("SELECT worktree_path FROM worktree_owners")
        for (stored_path,) in rows:
            if stored_path and os.path.realpath(stored_path) == normalized:
                print(stored_path)
                raise SystemExit(0)
except sqlite3.Error:
    raise SystemExit(2)
print(normalized)
PY
	return $?
}

# Resolve the registry key for a worktree path. Resolve all legacy rows in one
# Python process so a lookup remains O(rows) without spawning one interpreter
# per row. If Python or SQLite access fails, retain the portable shell fallback.
_wt_registry_lookup_path() {
	local requested_path="$1"
	local resolved_path=""
	if resolved_path=$(_wt_registry_resolve_path_python "$requested_path"); then
		printf '%s' "$resolved_path"
		return 0
	fi

	local normalized=""
	normalized=$(_wt_normalize_path "$requested_path")

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
		printf '%s' "$normalized"
		return 0
	}

	local stored_path=""
	while IFS= read -r stored_path; do
		[[ -z "$stored_path" ]] && continue
		local stored_normalized
		stored_normalized=$(_wt_normalize_path "$stored_path")
		if [[ "$stored_normalized" == "$normalized" ]]; then
			printf '%s' "$stored_path"
			return 0
		fi
	done < <(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT worktree_path FROM worktree_owners;" 2>/dev/null || true)

	printf '%s' "$normalized"
	return 0
}

# Classify an existing path through the runtime-neutral canonical policy.
# Synthetic/nonexistent fixture paths classify as outside Git and remain valid.
_wt_worktree_classification() {
	local wt_path="$1"
	local policy_helper="${_WORKTREE_REGISTRY_SCRIPT_DIR}/canonical-write-policy-helper.py"
	[[ -f "$policy_helper" ]] || return 1
	python3 "$policy_helper" classify --cwd "$wt_path" --field classification 2>/dev/null
	return $?
}

_wt_path_is_canonical() {
	local wt_path="$1"
	local classification=""
	classification=$(_wt_worktree_classification "$wt_path") || return 1
	[[ "$classification" == "canonical" ]]
	return $?
}

_wt_delete_owner_row() {
	local wt_path="$1"
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 0
	sqlite3 "$WORKTREE_REGISTRY_DB" \
		"DELETE FROM worktree_owners WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';" \
		2>/dev/null || return 1
	return 0
}

# Initialize the registry database
_init_registry_db() {
	mkdir -p "$WORKTREE_REGISTRY_DIR" 2>/dev/null || true
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS worktree_owners (
            worktree_path TEXT PRIMARY KEY,
            branch        TEXT,
            owner_pid     INTEGER,
            owner_session TEXT DEFAULT '',
            owner_batch   TEXT DEFAULT '',
            task_id       TEXT DEFAULT '',
            owner_comm    TEXT DEFAULT '',
            owner_process_start TEXT DEFAULT '',
            owner_dead_seen_at TEXT DEFAULT '',
            created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
    " 2>/dev/null || true

	local has_dead_seen_column
	has_dead_seen_column=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT 1 FROM pragma_table_info('worktree_owners')
        WHERE name = 'owner_dead_seen_at';
    " 2>/dev/null || echo "")
	if [[ -z "$has_dead_seen_column" ]]; then
		sqlite3 "$WORKTREE_REGISTRY_DB" "
            ALTER TABLE worktree_owners
            ADD COLUMN owner_dead_seen_at TEXT DEFAULT '';
        " 2>/dev/null || true
	fi

	local has_owner_comm_column
	has_owner_comm_column=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT 1 FROM pragma_table_info('worktree_owners')
        WHERE name = 'owner_comm';
    " 2>/dev/null || echo "")
	if [[ -z "$has_owner_comm_column" ]]; then
		sqlite3 "$WORKTREE_REGISTRY_DB" "
            ALTER TABLE worktree_owners
            ADD COLUMN owner_comm TEXT DEFAULT '';
		" 2>/dev/null || true
	fi

	local has_owner_process_start_column
	has_owner_process_start_column=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT 1 FROM pragma_table_info('worktree_owners')
        WHERE name = 'owner_process_start';
    " 2>/dev/null || echo "")
	if [[ -z "$has_owner_process_start_column" ]]; then
		sqlite3 "$WORKTREE_REGISTRY_DB" "
            ALTER TABLE worktree_owners
            ADD COLUMN owner_process_start TEXT DEFAULT '';
		" 2>/dev/null || return 1
	fi
	has_owner_process_start_column=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT 1 FROM pragma_table_info('worktree_owners')
        WHERE name = 'owner_process_start';
    " 2>/dev/null) || return 1
	[[ "$has_owner_process_start_column" == "1" ]] || return 1
	return 0
}

# Public recovery hook: delete only a structurally canonical ownership row.
remove_canonical_worktree_owner() {
	local wt_path="$1"
	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")
	_wt_path_is_canonical "$wt_path" || return 1
	_wt_delete_owner_row "$wt_path" || return 1
	return 0
}

# Register ownership of a worktree
# Arguments:
#   $1 - worktree path (required)
#   $2 - branch name (required)
#   Flags: --task <id>, --batch <id>, --session <id>
register_worktree() {
	local wt_path="$1"
	local branch="$2"
	shift 2

	local task_id="" batch_id="" session_id="" owner_pid_override=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task_id="${2:-}"
			shift 2
			;;
		--batch)
			batch_id="${2:-}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--owner-pid)
			owner_pid_override="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$session_id" ]]; then
		session_id="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
	fi

	local owner_pid
	owner_pid=$(_resolve_worktree_owner_pid "$owner_pid_override")
	local owner_comm
	owner_comm=$(_get_proc_comm "$owner_pid")
	local owner_process_start=""
	owner_process_start=$(_wt_process_start_token_for_pid "$owner_pid") || return 1

	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")
	if _wt_path_is_canonical "$wt_path"; then
		_wt_delete_owner_row "$wt_path" || return 1
		return 1
	fi

	{
		_wt_sqlite_set_owner_pid_param "$owner_pid"
		printf '%s\n' "
        INSERT OR REPLACE INTO worktree_owners
			(worktree_path, branch, owner_pid, owner_session, owner_batch, task_id, owner_comm, owner_process_start, owner_dead_seen_at)
        VALUES
		 ('$(_wt_sql_escape "$wt_path")',
		  '$(_wt_sql_escape "$branch")',
		  :owner_pid,
		  '$(_wt_sql_escape "$session_id")',
		  '$(_wt_sql_escape "$batch_id")',
		  '$(_wt_sql_escape "$task_id")',
		  '$(_wt_sql_escape "$owner_comm")',
		  '$(_wt_sql_escape "$owner_process_start")',
		  '');
    "
	} | sqlite3 "$WORKTREE_REGISTRY_DB" 2>/dev/null || return 1
	return 0
}

_wt_is_trusted_opencode_session() {
	local session_id="$1"
	[[ -n "${OPENCODE_SESSION_ID:-}" ]] || return 1
	[[ "$session_id" == "$OPENCODE_SESSION_ID" ]] || return 1
	[[ "$session_id" == ses_* ]] || return 1
	return 0
}

_wt_claim_owner_record() {
	local wt_path="$1"
	local branch="$2"
	local owner_pid="$3"
	local session_id="$4"
	local batch_id="$5"
	local task_id="$6"
	local owner_comm="$7" owner_process_start="$8" trusted_opencode_session="$9"

	python3 - "$WORKTREE_REGISTRY_DB" "$wt_path" "$branch" "$owner_pid" "$session_id" \
		"$batch_id" "$task_id" "$owner_comm" "$owner_process_start" "$trusted_opencode_session" <<'PY' || return 1
import os
import sqlite3
import sys

(
    db_path,
    worktree_path,
    branch,
    owner_pid_text,
    session_id,
    batch_id,
    task_id,
    owner_comm,
    owner_process_start,
    trusted_session_text,
) = sys.argv[1:]
owner_pid = int(owner_pid_text)
trusted_session = trusted_session_text == "1"

connection = sqlite3.connect(db_path, isolation_level=None)
try:
    connection.execute("BEGIN IMMEDIATE")
    existing_owner = connection.execute(
        """SELECT owner_pid, COALESCE(owner_session, '')
           FROM worktree_owners WHERE worktree_path = ?""",
        (worktree_path,),
    ).fetchone()
    if (
        existing_owner
        and isinstance(existing_owner[0], int)
        and existing_owner[0] != owner_pid
    ):
        try:
            os.kill(existing_owner[0], 0)
        except ProcessLookupError:
            connection.execute(
                """DELETE FROM worktree_owners
                   WHERE worktree_path = ? AND owner_pid = ?
                     AND COALESCE(owner_session, '') = ?""",
                (worktree_path, existing_owner[0], existing_owner[1]),
            )
        except (PermissionError, OSError):
            pass

    connection.execute(
        """UPDATE worktree_owners
           SET branch = ?, owner_pid = ?, owner_session = ?, owner_batch = ?,
               task_id = ?, owner_comm = ?, owner_process_start = ?, owner_dead_seen_at = ''
           WHERE worktree_path = ?
             AND (owner_pid = ? OR (? AND owner_session = ?))""",
        (
            branch,
            owner_pid,
            session_id,
            batch_id,
            task_id,
            owner_comm,
            owner_process_start,
            worktree_path,
            owner_pid,
            trusted_session,
            session_id,
        ),
    )
    connection.execute(
        """INSERT OR IGNORE INTO worktree_owners
           (worktree_path, branch, owner_pid, owner_session, owner_batch,
            task_id, owner_comm, owner_process_start, owner_dead_seen_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, '')""",
        (worktree_path, branch, owner_pid, session_id, batch_id, task_id, owner_comm, owner_process_start),
    )
    final_owner = connection.execute(
        """SELECT owner_pid, COALESCE(owner_session, '')
           FROM worktree_owners WHERE worktree_path = ?""",
        (worktree_path,),
    ).fetchone()
    connection.execute("COMMIT")
except Exception:
    if connection.in_transaction:
        connection.execute('ROLLBACK')
    raise
finally:
    connection.close()

if final_owner:
    print(f"{final_owner[0]}|{final_owner[1]}")
PY
	return 0
}

# Claim ownership of a worktree without overwriting another live owner.
# Arguments:
#   $1 - worktree path (required)
#   $2 - branch name (required)
#   Flags: --task <id>, --batch <id>, --session <id>, --owner-pid <pid>
# Returns:
#   0 - ownership acquired or already held by this owner_pid or OpenCode session
#   1 - another live owner currently holds the worktree
claim_worktree_ownership() {
	local wt_path="$1"
	local branch="$2"
	shift 2

	local task_id="" batch_id="" session_id="" owner_pid_override=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task_id="${2:-}"
			shift 2
			;;
		--batch)
			batch_id="${2:-}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--owner-pid)
			owner_pid_override="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$session_id" ]]; then
		session_id="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
	fi

	local owner_pid
	owner_pid=$(_resolve_worktree_owner_pid "$owner_pid_override")
	local owner_comm
	owner_comm=$(_get_proc_comm "$owner_pid")
	local owner_process_start=""
	owner_process_start=$(_wt_process_start_token_for_pid "$owner_pid") || return 1
	local trusted_opencode_session=0
	_wt_is_trusted_opencode_session "$session_id" && trusted_opencode_session=1

	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")
	if _wt_path_is_canonical "$wt_path"; then
		_wt_delete_owner_row "$wt_path" || return 1
		return 1
	fi

	local final_owner_info=""
	final_owner_info=$(_wt_claim_owner_record "$wt_path" "$branch" "$owner_pid" "$session_id" \
		"$batch_id" "$task_id" "$owner_comm" "$owner_process_start" "$trusted_opencode_session") || return 1

	if [[ "${final_owner_info%%|*}" == "$owner_pid" ]]; then
		return 0
	fi

	return 1
}

_wt_compare_and_swap_owner_record() {
	local wt_path="$1"
	shift
	local branch="$1"
	shift
	local owner_pid="$1"
	shift
	local session_id="$1"
	shift
	local batch_id="$1"
	shift
	local task_id="$1"
	shift
	local owner_comm="$1"
	shift
	local owner_process_start="$1"
	shift
	local expected_owner_pid="$1"
	shift
	local expected_session_id="$1"
	shift
	local expected_batch_id="$1"
	shift
	local expected_task_id="$1"
	shift
	local expected_created_at="$1"
	shift
	local expected_process_start="$1"

	python3 - "$WORKTREE_REGISTRY_DB" "$wt_path" "$branch" "$owner_pid" \
		"$session_id" "$batch_id" "$task_id" "$owner_comm" "$owner_process_start" \
		"$expected_owner_pid" "$expected_session_id" "$expected_batch_id" \
		"$expected_task_id" "$expected_created_at" "$expected_process_start" <<'PY' || return 1
import sqlite3
import sys

(
    db_path,
    worktree_path,
    branch,
    owner_pid_text,
    session_id,
    batch_id,
    task_id,
    owner_comm,
    owner_process_start,
    expected_owner_pid_text,
    expected_session_id,
    expected_batch_id,
    expected_task_id,
    expected_created_at,
    expected_process_start,
) = sys.argv[1:]

connection = sqlite3.connect(db_path, isolation_level=None)
try:
    connection.execute("BEGIN IMMEDIATE")
    cursor = connection.execute(
        """UPDATE worktree_owners
           SET branch = ?, owner_pid = ?, owner_session = ?, owner_batch = ?,
               task_id = ?, owner_comm = ?, owner_process_start = ?, owner_dead_seen_at = '',
               created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
           WHERE worktree_path = ?
             AND owner_pid = ?
             AND COALESCE(owner_session, '') = ?
              AND COALESCE(owner_batch, '') = ?
              AND COALESCE(task_id, '') = ?
              AND COALESCE(created_at, '') = ?
              AND COALESCE(owner_process_start, '') = ?""",
        (
            branch,
            int(owner_pid_text),
            session_id,
            batch_id,
            task_id,
            owner_comm,
            owner_process_start,
            worktree_path,
            int(expected_owner_pid_text),
            expected_session_id,
            expected_batch_id,
            expected_task_id,
            expected_created_at,
            expected_process_start,
        ),
    )
    if cursor.rowcount != 1:
        connection.execute('ROLLBACK')
        sys.exit(1)
    connection.execute("COMMIT")
except Exception:
    if connection.in_transaction:
        connection.execute("ROLLBACK")
    raise
finally:
    connection.close()
PY
	return 0
}

# Atomically transfer ownership when the complete expected owner record still
# matches. This is the only path allowed to take over a live continuation owner;
# callers must validate continuation authority before invoking it.
# Arguments:
#   $1 - worktree path (required)
#   $2 - branch name (required)
#   Flags: --task <id>, --batch <id>, --session <id>, --owner-pid <pid>,
#          --expected-task <id>, --expected-batch <id>,
#          --expected-session <id>, --expected-owner-pid <pid>,
#          --expected-created-at <timestamp>, --expected-process-start <token>
# Returns:
#   0 - exact expected owner was atomically replaced
#   1 - validation failed or the owner record changed before the transition
transfer_worktree_ownership_if_expected() {
	[[ $# -ge 2 ]] || return 1
	local wt_path="$1"
	local branch="$2"
	shift 2

	local task_id=""
	local batch_id=""
	local session_id=""
	local owner_pid_override=""
	local expected_task_id=""
	local expected_batch_id=""
	local expected_session_id=""
	local expected_owner_pid=""
	local expected_created_at=""
	local expected_process_start=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--task | --batch | --session | --owner-pid | --expected-task | --expected-batch | --expected-session | --expected-owner-pid | --expected-created-at | --expected-process-start)
			[[ $# -ge 2 ]] || return 1
			;;
		esac
		case "$option" in
		--task) task_id="$2"; shift 2 ;;
		--batch) batch_id="$2"; shift 2 ;;
		--session) session_id="$2"; shift 2 ;;
		--owner-pid) owner_pid_override="$2"; shift 2 ;;
		--expected-task) expected_task_id="$2"; shift 2 ;;
		--expected-batch) expected_batch_id="$2"; shift 2 ;;
		--expected-session) expected_session_id="$2"; shift 2 ;;
		--expected-owner-pid) expected_owner_pid="$2"; shift 2 ;;
		--expected-created-at) expected_created_at="$2"; shift 2 ;;
		--expected-process-start) expected_process_start="$2"; shift 2 ;;
		*) return 1 ;;
		esac
	done

	[[ -n "$wt_path" && -n "$task_id" && "$task_id" == "$expected_task_id" ]] || return 1
	[[ "$expected_owner_pid" =~ ^[0-9]+$ && -n "$expected_created_at" && -n "$expected_process_start" ]] || return 1
	if [[ -z "$session_id" ]]; then
		session_id="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
	fi

	local owner_pid=""
	owner_pid=$(_resolve_worktree_owner_pid "$owner_pid_override")
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	local owner_comm=""
	owner_comm=$(_get_proc_comm "$owner_pid")
	local owner_process_start=""
	owner_process_start=$(_wt_process_start_token_for_pid "$owner_pid") || return 1

	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")
	if _wt_path_is_canonical "$wt_path"; then
		_wt_delete_owner_row "$wt_path" || return 1
		return 1
	fi
	_wt_compare_and_swap_owner_record "$wt_path" "$branch" "$owner_pid" \
		"$session_id" "$batch_id" "$task_id" "$owner_comm" "$owner_process_start" \
		"$expected_owner_pid" "$expected_session_id" "$expected_batch_id" \
		"$expected_task_id" "$expected_created_at" "$expected_process_start" || return 1
	return 0
}

# Unregister ownership of a worktree
# Arguments:
#   $1 - worktree path (required)
unregister_worktree() {
	local wt_path="$1"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || true
	return 0
}

# Remove a clean linked worktree only while the complete expected ownership row
# remains protected by the same SQLite write transaction. Registry writers
# cannot transfer or replace ownership between verification and `git worktree
# remove`; dirty worktrees still fail closed because removal is never forced.
# Arguments: worktree path, repository root, expected branch, owner PID,
#            owner session, owner batch, task ID, and created-at timestamp.
remove_worktree_if_owner_contract() {
	[[ $# -eq 8 ]] || return 1
	local wt_path="$1"
	local repository_root="$2"
	local expected_branch="$3"
	local expected_owner_pid="$4"
	local expected_owner_session="$5"
	local expected_owner_batch="$6"
	local expected_task_id="$7"
	local expected_created_at="$8"
	local expected_process_start=""
	local git_path=""
	local owner_remove_helper="${_WORKTREE_REGISTRY_SCRIPT_DIR}/worktree-owner-contract-remove.py"

	[[ -n "$wt_path" && -n "$repository_root" && -n "$expected_branch" ]] || return 1
	[[ "$expected_owner_pid" =~ ^[0-9]+$ && -n "$expected_created_at" ]] || return 1
	expected_process_start=$(_wt_process_start_token_for_pid "$expected_owner_pid") || return 1
	command -v python3 >/dev/null 2>&1 || return 1
	git_path=$(command -v git) || return 1
	[[ -f "$owner_remove_helper" && ! -L "$owner_remove_helper" ]] || return 1
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 1
	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path") || return 1
	[[ -d "$wt_path" && ! -L "$wt_path" ]] || return 1
	if _wt_path_is_canonical "$wt_path"; then
		return 1
	fi
	repository_root=$(cd "$repository_root" 2>/dev/null && pwd -P) || return 1
	"$git_path" -C "$repository_root" rev-parse --git-common-dir >/dev/null 2>&1 || return 1

	python3 "$owner_remove_helper" "$WORKTREE_REGISTRY_DB" "$wt_path" "$repository_root" "$git_path" \
		"$expected_branch" "$expected_owner_pid" "$expected_owner_session" \
		"$expected_owner_batch" "$expected_task_id" "$expected_created_at" \
		"$expected_process_start" || return 1
	return 0
}

unregister_worktree_if_owner_pid() {
	local wt_path="$1"
	local expected_owner_pid="$2"
	[[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 1
	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path") || return 1

	local changed="0"
	changed=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
		DELETE FROM worktree_owners
		WHERE worktree_path = '$(_wt_sql_escape "$wt_path")'
		  AND owner_pid = ${expected_owner_pid};
		SELECT changes();
	" 2>/dev/null || printf '0')
	[[ "$changed" == "1" ]] || return 1
	return 0
}

# Delete an ownership row only when its complete lease contract still matches.
# This atomic compare-and-delete prevents cleanup failure paths from erasing a
# replacement owner that reused the same process ID.
unregister_worktree_if_owner_contract() {
	local wt_path="$1"
	local expected_owner_pid="$2"
	local expected_owner_session="$3"
	local expected_task_id="$4"
	local expected_process_start=""
	local changed="0"

	[[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$expected_owner_session" && -n "$expected_task_id" ]] || return 1
	expected_process_start=$(_wt_process_start_token_for_pid "$expected_owner_pid") || return 1
	command -v sqlite3 >/dev/null 2>&1 || return 1
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path") || return 1
	changed=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
		DELETE FROM worktree_owners
		WHERE worktree_path = '$(_wt_sql_escape "$wt_path")'
		  AND owner_pid = ${expected_owner_pid}
		  AND owner_session = '$(_wt_sql_escape "$expected_owner_session")'
		  AND task_id = '$(_wt_sql_escape "$expected_task_id")'
		  AND COALESCE(owner_process_start, '') = '$(_wt_sql_escape "$expected_process_start")';
		SELECT changes();
	" 2>/dev/null) || return 1
	[[ "$changed" == "1" ]] || return 1
	return 0
}

# Return success only when the registry contains the complete expected owner
# contract. Callers use this positive proof after acquiring destructive leases;
# missing, replaced, malformed, or unreadable registry evidence must fail closed.
worktree_has_exact_owner_contract() {
	local wt_path="$1"
	local expected_owner_pid="$2"
	local expected_owner_session="$3"
	local expected_task_id="$4"
	local expected_process_start=""
	local exact_match=""

	[[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$expected_owner_session" && -n "$expected_task_id" ]] || return 1
	expected_process_start=$(_wt_process_start_token_for_pid "$expected_owner_pid") || return 1
	command -v sqlite3 >/dev/null 2>&1 || return 1
	[[ -f "$WORKTREE_REGISTRY_DB" ]] || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path") || return 1
	exact_match=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
		SELECT 1
		FROM worktree_owners
		WHERE worktree_path = '$(_wt_sql_escape "$wt_path")'
		  AND owner_pid = ${expected_owner_pid}
		  AND owner_session = '$(_wt_sql_escape "$expected_owner_session")'
		  AND task_id = '$(_wt_sql_escape "$expected_task_id")'
		  AND COALESCE(owner_process_start, '') = '$(_wt_sql_escape "$expected_process_start")'
		LIMIT 1;
	" 2>/dev/null) || return 1
	[[ "$exact_match" == "1" ]] || return 1
	return 0
}

# Read the complete owner generation in one registry query.
# Arguments:
#   $1 - worktree path
# Output: owner info (pid|session|batch|task|created_at|process_start) or empty
# Returns: 0 if owned, 1 if not owned
check_worktree_owner_snapshot() {
	local wt_path="$1"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 1
	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	local owner_info
	owner_info=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid, owner_session, owner_batch, task_id, created_at,
               COALESCE(owner_process_start, '')
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || printf '')

	if [[ -n "$owner_info" ]]; then
		printf '%s\n' "$owner_info"
		return 0
	fi
	return 1
}

# Check who owns a worktree while preserving the historical five-field output.
# Arguments:
#   $1 - worktree path
# Output: owner info (pid|session|batch|task|created_at) or empty
# Returns: 0 if owned, 1 if not owned
check_worktree_owner() {
	local wt_path="$1"
	local owner_info=""
	local owner_pid="" owner_session="" owner_batch="" owner_task="" owner_created_at="" owner_process_start=""

	owner_info=$(check_worktree_owner_snapshot "$wt_path") || return 1
	IFS='|' read -r owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start <<<"$owner_info"
	printf '%s|%s|%s|%s|%s\n' "$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$owner_created_at"
	return 0
}

# Return the timestamp when a dead owner PID was first observed.
# Arguments:
#   $1 - worktree path
# Output: ISO timestamp or empty
worktree_owner_dead_seen_at() {
	local wt_path="$1"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0
	_init_registry_db
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	local dead_seen_at
	dead_seen_at=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT COALESCE(owner_dead_seen_at, '')
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")
	printf '%s' "$dead_seen_at"
	return 0
}

_wt_owner_dead_cooldown_minutes() {
	local cooldown_minutes="${WORKTREE_OWNER_DEAD_COOLDOWN_MINUTES:-60}"
	if [[ ! "$cooldown_minutes" =~ ^[0-9]+$ ]] || [[ "$cooldown_minutes" -lt 1 ]]; then
		cooldown_minutes=60
	fi
	printf '%s' "$cooldown_minutes"
	return 0
}

_wt_mark_owner_dead_seen() {
	local wt_path="$1"

	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET owner_dead_seen_at = CASE
            WHEN COALESCE(owner_dead_seen_at, '') = '' THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            ELSE owner_dead_seen_at
        END
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || true
	return 0
}

_wt_owner_dead_cooldown_expired() {
	local wt_path="$1"
	local cooldown_minutes
	cooldown_minutes=$(_wt_owner_dead_cooldown_minutes)

	local expired
	expired=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT CASE
            WHEN COALESCE(owner_dead_seen_at, '') != ''
             AND datetime(replace(replace(owner_dead_seen_at, 'T', ' '), 'Z', ''), '+${cooldown_minutes} minutes') <= datetime('now')
            THEN 1 ELSE 0 END
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "0")
	[[ "$expired" == "1" ]] && return 0
	return 1
}

# Return success only when the PID is conclusively absent. Permission or probe
# errors remain protected rather than entering destructive stale-owner cleanup.
_wt_pid_is_definitely_absent() {
	local owner_pid="$1"
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	python3 - "$owner_pid" <<'PY' >/dev/null 2>&1 || return 1
import os
import sys

try:
    os.kill(int(sys.argv[1]), 0)
except ProcessLookupError:
    raise SystemExit(0)
except (PermissionError, OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(1)
PY
	return 0
}

_wt_owner_comm_for_path() {
	local wt_path="$1"
	local owner_comm
	owner_comm=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT COALESCE(owner_comm, '')
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || echo "")
	printf '%s' "$owner_comm"
	return 0
}

# Return the PID, process-generation token, and creation timestamp from one
# registry snapshot. Read failures are ownership-unknown and fail closed.
_wt_owner_generation_contract_for_path() {
	local wt_path="$1"
	local separator=$'\x1f'
	local owner_contract=""
	owner_contract=$(sqlite3 -separator "$separator" "$WORKTREE_REGISTRY_DB" "
        SELECT owner_pid, COALESCE(owner_process_start, ''), COALESCE(created_at, '')
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
	" 2>/dev/null) || return 1
	printf '%s' "$owner_contract"
	return 0
}

# Delete only the exact owner generation that was inspected. A concurrent
# registration or transfer changes the token or timestamp and remains intact.
_wt_unregister_owner_if_generation_matches() {
	local wt_path="$1"
	local expected_owner_pid="$2"
	local expected_process_start="$3"
	local expected_created_at="$4"
	local changed="0"

	[[ "$expected_owner_pid" =~ ^[0-9]+$ && -n "$expected_created_at" ]] || return 1
	changed=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")'
          AND owner_pid = ${expected_owner_pid}
          AND COALESCE(owner_process_start, '') = '$(_wt_sql_escape "$expected_process_start")'
          AND COALESCE(created_at, '') = '$(_wt_sql_escape "$expected_created_at")';
        SELECT changes();
	" 2>/dev/null) || return 1
	[[ "$changed" == "1" ]] || return 1
	return 0
}

# For a legacy row without a stored token, prove PID reuse only when the live
# process started after the registry row. Token stability closes the inspection
# race; missing or unparsable evidence remains protected.
_wt_live_process_started_after_registry_row() {
	local owner_pid="$1"
	local expected_process_start="$2"
	local created_at="$3"
	local process_lstart=""
	local verified_process_start=""

	[[ -n "$created_at" && -n "$expected_process_start" ]] || return 1
	process_lstart=$(LC_ALL=C ps -p "$owner_pid" -o lstart= 2>/dev/null) || return 1
	verified_process_start=$(_wt_process_start_token_for_pid "$owner_pid") || return 1
	[[ "$verified_process_start" == "$expected_process_start" ]] || return 1

	LC_ALL=C python3 - "$created_at" "$process_lstart" <<'PY' >/dev/null 2>&1 || return 1
from datetime import datetime, timezone
import sys

created_at, process_lstart = sys.argv[1:]
created = datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
process_started = datetime.strptime(process_lstart.strip(), "%a %b %d %H:%M:%S %Y")
process_started = process_started.astimezone(timezone.utc)
raise SystemExit(0 if process_started > created else 1)
PY
	return 0
}

_wt_owner_live_pid_reused_or_untrusted() {
	local owner_pid="$1"
	local registered_process_start="$2"
	local registered_created_at="$3"
	local current_process_start=""

	current_process_start=$(_wt_process_start_token_for_pid "$owner_pid") || return 1
	if [[ -n "$registered_process_start" ]]; then
		[[ "$registered_process_start" != "$current_process_start" ]]
		return $?
	fi
	_wt_live_process_started_after_registry_row "$owner_pid" "$current_process_start" \
		"$registered_created_at"
	return $?
}

_wt_legacy_dispatch_precreate_systemd_owner_expired() {
	local wt_path="$1"
	local owner_pid="$2"
	local grace_minutes="${WORKTREE_DISPATCH_PRECREATE_LEGACY_GRACE_MINUTES:-15}"
	local registered_comm=""
	local current_comm=""
	local expired=""

	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	if [[ ! "$grace_minutes" =~ ^[0-9]+$ || "$grace_minutes" -lt 1 ]]; then
		grace_minutes=15
	fi
	current_comm=$(_get_proc_comm "$owner_pid")
	registered_comm=$(_wt_owner_comm_for_path "$wt_path")
	[[ "$current_comm" == "systemd" && "$registered_comm" == "systemd" ]] || return 1

	expired=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT CASE
            WHEN owner_pid = ${owner_pid}
             AND COALESCE(owner_process_start, '') = ''
             AND COALESCE(task_id, '') != ''
             AND task_id NOT GLOB '*[^0-9]*'
             AND owner_session = 'dispatch-precreate-' || task_id
             AND COALESCE(created_at, '') != ''
             AND datetime(replace(replace(created_at, 'T', ' '), 'Z', ''), '+${grace_minutes} minutes') <= datetime('now')
            THEN 1 ELSE 0 END
        FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';
    " 2>/dev/null || printf '0')
	[[ "$expired" == "1" ]] || return 1
	return 0
}

# Compare a registry owner against an already-resolved caller PID.
_wt_is_worktree_owned_by_others_for_resolved_pid() {
	local wt_path="$1"
	local my_pid="$2"

	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 1
	_init_registry_db || return 0
	wt_path=$(_wt_registry_lookup_path "$wt_path")

	local owner_contract=""
	local owner_pid=""
	local registered_process_start=""
	local registered_created_at=""
	owner_contract=$(_wt_owner_generation_contract_for_path "$wt_path") || return 0
	IFS=$'\x1f' read -r owner_pid registered_process_start registered_created_at <<<"$owner_contract"

	# No owner registered
	[[ -z "$owner_pid" ]] && return 1

	if [[ "$owner_pid" == "$my_pid" ]]; then
		local current_process_start=""
		current_process_start=$(_wt_process_start_token_for_pid "$my_pid") || return 0
		if [[ -n "$registered_process_start" && "$registered_process_start" == "$current_process_start" ]]; then
			return 1
		fi
	fi

	# Owner process is dead. Keep the ownership row quarantined for a cooldown
	# window so cleanup never treats one failed PID probe as immediate abandon.
	if ! kill -0 "$owner_pid" 2>/dev/null; then
		_wt_pid_is_definitely_absent "$owner_pid" || return 0
		_wt_mark_owner_dead_seen "$wt_path"
		if _wt_owner_dead_cooldown_expired "$wt_path"; then
			if _wt_unregister_owner_if_generation_matches "$wt_path" "$owner_pid" \
				"$registered_process_start" "$registered_created_at"; then
				return 1
			fi
		fi
		return 0
	fi
	# Deployed versions before GH#28807 registered dispatch-precreate handoffs
	# against the immortal systemd --user parent. That identity is never a valid
	# specialized handoff owner. Preserve a bounded launch grace, then remove only
	# exact numeric task/session pairs so legacy rows can no longer block cleanup.
	if [[ -z "$registered_process_start" ]] &&
		_wt_legacy_dispatch_precreate_systemd_owner_expired "$wt_path" "$owner_pid"; then
		if _wt_unregister_owner_if_generation_matches "$wt_path" "$owner_pid" \
			"$registered_process_start" "$registered_created_at"; then
			return 1
		fi
		return 0
	fi

	# Owner recovered or PID was reused while still registered; clear any stale
	# marker so a later dead observation gets a fresh cooldown window.
	if _wt_owner_live_pid_reused_or_untrusted "$owner_pid" "$registered_process_start" \
		"$registered_created_at"; then
		if _wt_unregister_owner_if_generation_matches "$wt_path" "$owner_pid" \
			"$registered_process_start" "$registered_created_at"; then
			return 1
		fi
		return 0
	fi

	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET owner_dead_seen_at = ''
        WHERE worktree_path = '$(_wt_sql_escape "$wt_path")'
          AND owner_pid = ${owner_pid}
          AND COALESCE(owner_process_start, '') = '$(_wt_sql_escape "$registered_process_start")'
          AND COALESCE(created_at, '') = '$(_wt_sql_escape "$registered_created_at")'
          AND COALESCE(owner_dead_seen_at, '') != '';
    " 2>/dev/null || true

	# Owner process is alive and it's not us — NOT safe to remove
	return 0
}

# Check if a worktree is owned by a DIFFERENT process or quarantined stale owner.
# Generic callers use the stable runtime identity so transient shell subprocesses
# match registrations created by the same interactive runtime (GH#21740).
# Arguments:
#   $1 - worktree path
# Returns: 0 if owned by another live process or within stale-owner cooldown,
#          1 if safe to remove
is_worktree_owned_by_others() {
	local wt_path="$1"
	local my_pid=""
	my_pid=$(_resolve_worktree_owner_pid "")
	_wt_is_worktree_owned_by_others_for_resolved_pid "$wt_path" "$my_pid"
	return $?
}

# Check ownership against an explicit short-lived lease holder. Destructive
# cleanup uses this capability-aware path after claiming a lease under its leaf
# executor PID; generic interactive ownership resolution remains unchanged.
# Arguments:
#   $1 - worktree path
#   $2 - exact expected lease-holder PID
# Returns: 0 if owned by another process (or input is invalid), 1 if this exact
#          PID owns the lease or no blocking owner remains
is_worktree_owned_by_others_for_pid() {
	[[ $# -eq 2 ]] || return 0
	local wt_path="$1"
	local expected_owner_pid="$2"
	[[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 0
	_wt_is_worktree_owned_by_others_for_resolved_pid "$wt_path" "$expected_owner_pid"
	return $?
}

# Delete registry paths in one sqlite transaction.
# Arguments:
#   $1 - newline-separated entries as worktree_path|reason
_wt_registry_delete_paths_batch() {
	local stale_entries="$1"
	[[ -z "$stale_entries" ]] && return 0

	{
		printf 'BEGIN IMMEDIATE;\n'
		while IFS='|' read -r wt_path _reason; do
			[[ -z "$wt_path" ]] && continue
			local escaped_wt_path="${wt_path//\'/\'\'}"
			printf "DELETE FROM worktree_owners WHERE worktree_path = '%s';\n" "$escaped_wt_path"
		done <<<"$stale_entries"
		printf 'COMMIT;\n'
	} | sqlite3 "$WORKTREE_REGISTRY_DB" >/dev/null 2>&1 || return 1
	return 0
}

# Print prunable missing-directory entries as worktree_path|reason lines.
_wt_registry_missing_directory_entries() {
	local entries="$1"
	[[ -z "$entries" ]] && return 0

	while IFS='|' read -r wt_path _owner_pid; do
		[[ -z "$wt_path" ]] && continue
		if [[ ! -d "$wt_path" ]]; then
			printf '%s|directory missing\n' "$wt_path"
		fi
	done <<<"$entries"
	return 0
}

# Print verbose prune lines for already-selected entries.
_wt_registry_print_pruned_entries() {
	local stale_entries="$1"
	[[ -z "$stale_entries" ]] && return 0

	while IFS='|' read -r wt_path prune_reason; do
		[[ -z "$wt_path" ]] && continue
		echo "  Pruned: $wt_path ($prune_reason)"
	done <<<"$stale_entries"
	return 0
}

# Count newline-separated entries.
_wt_registry_entry_count() {
	local entries="$1"
	[[ -z "$entries" ]] && {
		printf '0'
		return 0
	}

	local count
	count=$(grep -c . <<<"$entries" || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s' "$count"
	return 0
}

# Prune stale registry entries (dead PIDs, missing directories, corrupted paths)
# (t197) Enhanced to handle:
#   - Dead PIDs with missing directories
#   - Paths with ANSI escape codes (corrupted entries)
#   - Test artifacts in /tmp or /var/folders
prune_worktree_registry() {
	[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0
	_init_registry_db

	local pruned_count=0

	# First, delete entries with ANSI escape codes (corrupted entries)
	# These often have newlines and break normal parsing
	local ansi_count
	ansi_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners 
        WHERE worktree_path LIKE '%'||char(27)||'%' 
           OR worktree_path LIKE '%[0;%'
           OR worktree_path LIKE '%[1m%';
        SELECT changes();
    " 2>/dev/null || echo "0")
	pruned_count=$((pruned_count + ansi_count))
	[[ -n "${VERBOSE:-}" && "$ansi_count" -gt 0 ]] && echo "  Pruned $ansi_count entries with ANSI escape codes"

	# Next, delete test artifacts in temp directories
	local temp_count
	temp_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        DELETE FROM worktree_owners 
        WHERE worktree_path LIKE '/tmp/%' 
           OR worktree_path LIKE '/var/folders/%';
        SELECT changes();
    " 2>/dev/null || echo "0")
	pruned_count=$((pruned_count + temp_count))
	[[ -n "${VERBOSE:-}" && "$temp_count" -gt 0 ]] && echo "  Pruned $temp_count test artifacts in temp directories"

	# Now process remaining entries for missing directories. Delete selected rows in
	# one sqlite transaction; the old path called unregister_worktree once per row,
	# which made large stale backlogs exceed common assistant/tool timeouts.
	local entries
	entries=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT worktree_path, owner_pid FROM worktree_owners;
    " 2>/dev/null || echo "")

	if [[ -n "$entries" ]]; then
		local stale_entries
		stale_entries=$(_wt_registry_missing_directory_entries "$entries")
		if [[ -n "$stale_entries" ]]; then
			_wt_registry_delete_paths_batch "$stale_entries" || return 1
			pruned_count=$((pruned_count + $(_wt_registry_entry_count "$stale_entries")))
			[[ -n "${VERBOSE:-}" ]] && _wt_registry_print_pruned_entries "$stale_entries"
		fi
	fi

	[[ -n "${VERBOSE:-}" ]] && echo "Pruned $pruned_count entries total"
	return 0
}
