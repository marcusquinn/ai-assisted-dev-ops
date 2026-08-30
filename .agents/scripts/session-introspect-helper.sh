#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Session Introspect Helper — mid-session self-diagnosis for stuck workers (t2177)
#
# Reads the observability SQLite DB written by the opencode-aidevops plugin
# (plugins/opencode-aidevops/observability.mjs). Surfaces anti-patterns the
# worker itself can act on: file-reread loops, tool call rate spikes,
# error clusters, and recent intent history.
#
# Works offline — no OTEL sink required. When OTEL is enabled, the same data
# also lands in opencode's tool-spans (v1.4.7+); this helper complements that
# by giving the running session a cheap way to query its own activity without
# leaving the shell.
#
# Commands:
#   recent [N]       — last N tool calls for current session (default 20)
#   patterns         — tool distribution, file-reread detection, error rate
#   errors [N]       — last N failed tool calls with intent + duration
#   sessions [N]     — list recent N sessions (default 10)
#   help             — usage
#
# Flags (all commands):
#   --session <id>   — explicit session_id (default: most-recent in DB)
#   --db <path>      — override DB path (default: observability default)
#   --json           — machine-readable output
#   --since <minutes>— restrict to last N minutes of session (default: all)
#
# Environment overrides (for tests / custom deployments):
#   AIDEVOPS_INTROSPECT_DB — DB path (takes precedence over --db and default)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly DEFAULT_OBS_DB="${HOME}/.aidevops/.agent-workspace/observability/llm-requests.db"
readonly DEFAULT_RECENT_N=20
readonly DEFAULT_SESSIONS_N=10
readonly DEFAULT_ERRORS_N=10
readonly REPEATED_PATH_MIN_COUNT=2

# =============================================================================
# Helpers
# =============================================================================

_resolve_db_path() {
	local override="${1:-}"
	if [[ -n "${AIDEVOPS_INTROSPECT_DB:-}" ]]; then
		echo "${AIDEVOPS_INTROSPECT_DB}"
		return 0
	fi
	if [[ -n "$override" ]]; then
		echo "$override"
		return 0
	fi
	echo "$DEFAULT_OBS_DB"
	return 0
}

_require_db() {
	local db="$1"
	if [[ ! -f "$db" ]]; then
		print_error "observability DB not found: $db"
		print_info "is the opencode-aidevops plugin active? start opencode and run one tool call to seed it"
		return 1
	fi
	if ! command -v sqlite3 >/dev/null 2>&1; then
		print_error "sqlite3 binary required"
		return 1
	fi
	return 0
}

_resolve_session_id() {
	local db="$1" explicit="${2:-}"
	if [[ -n "$explicit" ]]; then
		echo "$explicit"
		return 0
	fi
	sqlite3 "$db" "SELECT session_id FROM tool_calls ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null
	return 0
}

# Parse --session / --db / --json / --since from args; emits K=V pairs on stdout.
# Remaining positional args are emitted as POS=... lines.
_parse_common_flags() {
	local session_id="" db_override="" json_flag=false since_min=""
	local positionals=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--db)
			db_override="${2:-}"
			shift 2
			;;
		--json) json_flag=true; shift ;;
		--since)
			since_min="${2:-}"
			shift 2
			;;
		--) shift; positionals+=("$@"); break ;;
		*) positionals+=("$1"); shift ;;
		esac
	done
	printf 'SESSION=%s\nDB=%s\nJSON=%s\nSINCE=%s\n' "$session_id" "$db_override" "$json_flag" "$since_min"
	local p
	for p in "${positionals[@]:-}"; do
		[[ -n "$p" ]] && printf 'POS=%s\n' "$p"
	done
	return 0
}

_since_clause() {
	local since_min="$1"
	if [[ -z "$since_min" ]]; then
		echo ""
		return 0
	fi
	if ! [[ "$since_min" =~ ^[0-9]+$ ]]; then
		print_error "--since must be a positive integer (minutes)"
		return 1
	fi
	# SQLite datetime(now,'-N minutes'). We compare timestamp strings ISO-8601.
	echo "AND timestamp >= datetime('now','-${since_min} minutes')"
	return 0
}

_escape_sql() {
	# Double single-quotes for SQL literal embedding.
	printf '%s' "$1" | sed "s/'/''/g"
}

_outcome_category_sql() {
	local db="$1"
	local has_column
	has_column=$(sqlite3 "$db" "SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='outcome_category';")
	if [[ "$has_column" == "1" ]]; then
		printf '%s' "CASE WHEN outcome_category IS NOT NULL AND outcome_category<>'' THEN outcome_category WHEN success=0 THEN 'unknown_failure' ELSE 'legacy_unknown' END"
	else
		printf '%s' "CASE WHEN success=0 THEN 'unknown_failure' ELSE 'legacy_unknown' END"
	fi
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_recent() {
	local parsed; parsed=$(_parse_common_flags "$@")
	local session_id db_override json_flag since_min limit=""
	session_id=$(echo "$parsed" | awk -F= '/^SESSION=/{sub(/^SESSION=/,"");print;exit}')
	db_override=$(echo "$parsed" | awk -F= '/^DB=/{sub(/^DB=/,"");print;exit}')
	json_flag=$(echo "$parsed" | awk -F= '/^JSON=/{sub(/^JSON=/,"");print;exit}')
	since_min=$(echo "$parsed" | awk -F= '/^SINCE=/{sub(/^SINCE=/,"");print;exit}')
	limit=$(echo "$parsed" | awk -F= '/^POS=/{sub(/^POS=/,"");print;exit}')
	[[ -z "$limit" ]] && limit="$DEFAULT_RECENT_N"
	[[ "$limit" =~ ^[0-9]+$ ]] || { print_error "N must be a positive integer"; return 1; }

	local db; db=$(_resolve_db_path "$db_override")
	_require_db "$db" || return 1

	local sid; sid=$(_resolve_session_id "$db" "$session_id")
	[[ -z "$sid" ]] && { print_warning "no sessions found in $db"; return 0; }

	local since; since=$(_since_clause "$since_min") || return 1
	local sid_esc; sid_esc=$(_escape_sql "$sid")

	local query="
		SELECT timestamp, tool_name, COALESCE(intent,''), COALESCE(duration_ms,0), success
		FROM tool_calls
		WHERE session_id='${sid_esc}' ${since}
		ORDER BY timestamp DESC
		LIMIT ${limit};
	"
	if [[ "$json_flag" == "true" ]]; then
		_recent_json "$db" "$sid" "$query"
	else
		_recent_table "$db" "$sid" "$query"
	fi
	return 0
}

_recent_table() {
	local db="$1" sid="$2" query="$3"
	printf 'Session: %s\n\n' "$sid"
	printf '%-23s  %-8s  %-6s  %-5s  %s\n' "TIMESTAMP" "TOOL" "MS" "OK" "INTENT"
	printf '%-23s  %-8s  %-6s  %-5s  %s\n' "-----------------------" "--------" "------" "-----" "----------------------------------------"
	local count=0
	while IFS='|' read -r ts tool intent dur ok; do
		[[ -z "$ts" ]] && continue
		local ok_sym="✓"
		[[ "$ok" == "0" ]] && ok_sym="✗"
		printf '%-23s  %-8s  %-6s  %-5s  %s\n' "${ts:0:23}" "${tool:0:8}" "${dur}" "$ok_sym" "${intent:0:60}"
		count=$((count + 1))
	done < <(sqlite3 -separator '|' "$db" "$query")
	printf '\n%d tool call(s) shown\n' "$count"
	return 0
}

_recent_json() {
	local db="$1" sid="$2" query="$3"
	command -v jq >/dev/null 2>&1 || { print_error "jq required with --json"; return 1; }
	local rows; rows=$(sqlite3 -separator '|' "$db" "$query" || true)
	printf '%s' "$rows" | jq -R -s --arg session "$sid" '
		split("\n") | map(select(length > 0) | split("|") | {
			timestamp: .[0],
			tool: .[1],
			intent: .[2],
			duration_ms: (.[3] | tonumber? // 0),
			success: (.[4] == "1")
		}) | { session: $session, calls: . }
	'
	return 0
}

cmd_patterns() {
	local parsed; parsed=$(_parse_common_flags "$@")
	local session_id db_override json_flag since_min
	session_id=$(echo "$parsed" | awk -F= '/^SESSION=/{sub(/^SESSION=/,"");print;exit}')
	db_override=$(echo "$parsed" | awk -F= '/^DB=/{sub(/^DB=/,"");print;exit}')
	json_flag=$(echo "$parsed" | awk -F= '/^JSON=/{sub(/^JSON=/,"");print;exit}')
	since_min=$(echo "$parsed" | awk -F= '/^SINCE=/{sub(/^SINCE=/,"");print;exit}')

	local db; db=$(_resolve_db_path "$db_override")
	_require_db "$db" || return 1
	local sid; sid=$(_resolve_session_id "$db" "$session_id")
	[[ -z "$sid" ]] && { print_warning "no sessions found in $db"; return 0; }

	local since; since=$(_since_clause "$since_min") || return 1
	local sid_esc; sid_esc=$(_escape_sql "$sid")

	# Aggregate stats for the session.
	local stats
	stats=$(sqlite3 -separator '|' "$db" "
		SELECT
			COUNT(*) AS total,
			SUM(CASE WHEN success=0 THEN 1 ELSE 0 END) AS errors,
			MIN(timestamp) AS first_ts,
			MAX(timestamp) AS last_ts,
			COALESCE(AVG(duration_ms),0) AS avg_dur,
			SUM(CASE WHEN intent IS NOT NULL AND LENGTH(TRIM(intent)) > 0 THEN 1 ELSE 0 END) AS intent_present,
			SUM(CASE WHEN intent IS NULL OR LENGTH(TRIM(intent)) = 0 THEN 1 ELSE 0 END) AS intent_missing,
			printf('%.1f', 100.0 * SUM(CASE WHEN intent IS NOT NULL AND LENGTH(TRIM(intent)) > 0 THEN 1 ELSE 0 END) / MAX(1, COUNT(*))) AS intent_coverage
		FROM tool_calls
		WHERE session_id='${sid_esc}' ${since};
	")
	local total errors first_ts last_ts avg_dur intent_present intent_missing intent_coverage
	IFS='|' read -r total errors first_ts last_ts avg_dur intent_present intent_missing intent_coverage <<<"$stats"
	total="${total:-0}"
	errors="${errors:-0}"
	intent_present="${intent_present:-0}"
	intent_missing="${intent_missing:-0}"
	intent_coverage="${intent_coverage:-0.0}"

	# Per-tool counts.
	local by_tool
	by_tool=$(sqlite3 -separator '|' "$db" "
		SELECT tool_name, COUNT(*) AS n, SUM(CASE WHEN success=0 THEN 1 ELSE 0 END) AS err
		FROM tool_calls
		WHERE session_id='${sid_esc}' ${since}
		GROUP BY tool_name
		ORDER BY n DESC;
	")

	# Additive outcome categories retain unknown legacy rows without guessing.
	local outcome_expr
	outcome_expr=$(_outcome_category_sql "$db")
	local outcomes
	outcomes=$(sqlite3 -separator '|' "$db" "
		SELECT ${outcome_expr} AS category, COUNT(*) AS n
		FROM tool_calls
		WHERE session_id='${sid_esc}' ${since}
		GROUP BY 1
		ORDER BY n DESC, category;
	")

	# Repeated-path evidence — parse filePath from metadata JSON. Two accesses is
	# the semantic minimum for repetition, not a heuristic problem threshold.
	# Report the evidence and leave interpretation to the retrospective.
	# metadata column is an opaque JSON blob; we extract .args.filePath or
	# .args.file_path where present. Works with both Read and Edit args.
	local rereads
	rereads=$(sqlite3 -separator '|' "$db" "
		SELECT
			COALESCE(json_extract(metadata,'\$.args.filePath'),
			         json_extract(metadata,'\$.args.file_path'),'') AS fp,
			COUNT(*) AS n
		FROM tool_calls
		WHERE session_id='${sid_esc}' ${since}
		  AND tool_name IN ('Read','read','Edit','edit','Write','write')
		GROUP BY fp
		HAVING fp<>'' AND n >= ${REPEATED_PATH_MIN_COUNT}
		ORDER BY n DESC
		LIMIT 10;
	")

	local rate_per_min="0.00"
	if [[ -n "$first_ts" && -n "$last_ts" && "$total" -gt 0 ]]; then
		rate_per_min=$(sqlite3 "$db" "
			SELECT printf('%.2f', ${total}*60.0 /
				MAX(1, (strftime('%s','${last_ts}') - strftime('%s','${first_ts}'))));")
	fi

	if [[ "$json_flag" == "true" ]]; then
		_patterns_json "$sid" "$total" "$errors" "$first_ts" "$last_ts" \
			"$avg_dur" "$rate_per_min" "$by_tool" "$rereads" "$outcomes" \
			"$intent_present" "$intent_missing" "$intent_coverage"
	else
		_patterns_table "$sid" "$total" "$errors" "$first_ts" "$last_ts" \
			"$avg_dur" "$rate_per_min" "$by_tool" "$rereads" "$outcomes" \
			"$intent_present" "$intent_missing" "$intent_coverage"
	fi
	return 0
}

_patterns_table() {
	local sid="$1" total="$2" errors="$3" first_ts="$4" last_ts="$5"
	local avg_dur="$6" rate="$7" by_tool="$8" rereads="$9"
	local outcomes="${10}"
	local intent_present="${11}" intent_missing="${12}" intent_coverage="${13}"
	printf 'Session: %s\n' "$sid"
	printf 'Window:  %s → %s\n' "${first_ts:-?}" "${last_ts:-?}"
	printf 'Calls:   %s total, %s error(s), %s calls/min, avg %sms\n' \
		"$total" "$errors" "$rate" "${avg_dur%.*}"
	printf 'Intent:  %s populated, %s missing (%s%% coverage)\n' \
		"$intent_present" "$intent_missing" "$intent_coverage"
	if [[ "$intent_missing" -gt 0 ]]; then
		printf 'Notice: missing intents limit reliable root-cause clustering.\n'
	fi
	printf '\n'

	printf 'Per-tool:\n'
	if [[ -n "$by_tool" ]]; then
		while IFS='|' read -r tool n err; do
			[[ -z "$tool" ]] && continue
			printf '  %-12s %6s calls (%s errors)\n' "$tool" "$n" "$err"
		done <<<"$by_tool"
	else
		printf '  (none)\n'
	fi

	printf '\nOutcome categories:\n'
	if [[ -n "$outcomes" ]]; then
		while IFS='|' read -r category n; do
			[[ -z "$category" ]] && continue
			printf '  %-18s %6s calls\n' "$category" "$n"
		done <<<"$outcomes"
	else
		printf '  (none)\n'
	fi

	printf '\nRepeated file access evidence:\n'
	if [[ -n "$rereads" ]]; then
		while IFS='|' read -r path n; do
			[[ -z "$path" ]] && continue
			printf '  %4sx  %s\n' "$n" "$path"
		done <<<"$rereads"
		printf '\nInterpret in context: verification rereads may be useful; unexplained rediscovery may indicate friction or lost understanding.\n'
	else
		printf '  (none detected)\n'
	fi
	return 0
}

_patterns_json() {
	local sid="$1" total="$2" errors="$3" first_ts="$4" last_ts="$5"
	local avg_dur="$6" rate="$7" by_tool="$8" rereads="$9"
	local outcomes="${10}"
	local intent_present="${11}" intent_missing="${12}" intent_coverage="${13}"
	command -v jq >/dev/null 2>&1 || { print_error "jq required with --json"; return 1; }
	local by_tool_json
	by_tool_json=$(printf '%s' "$by_tool" | jq -R -s '
		split("\n") | map(select(length > 0) | split("|") | {
			tool: .[0],
			count: (.[1] | tonumber? // 0),
			errors: (.[2] | tonumber? // 0)
		})
	')
	local rereads_json
	rereads_json=$(printf '%s' "$rereads" | jq -R -s '
		split("\n") | map(select(length > 0) | split("|") | {
			path: .[0],
			count: (.[1] | tonumber? // 0)
		})
	')
	local outcomes_json
	outcomes_json=$(printf '%s' "$outcomes" | jq -R -s '
		split("\n") | map(select(length > 0) | split("|") | {
			key: .[0],
			value: (.[1] | tonumber? // 0)
		}) | from_entries
	')
	jq -n \
		--arg sid "$sid" --arg first_ts "$first_ts" --arg last_ts "$last_ts" \
		--argjson total "${total:-0}" --argjson errors "${errors:-0}" \
		--argjson avg_dur "${avg_dur:-0}" --arg rate "$rate" \
		--argjson by_tool "$by_tool_json" --argjson outcomes "$outcomes_json" \
		--argjson rereads "$rereads_json" \
		--argjson intent_present "$intent_present" --argjson intent_missing "$intent_missing" \
		--arg intent_coverage "$intent_coverage" \
		--argjson minimum_repeat_count "$REPEATED_PATH_MIN_COUNT" '
		{
			session: $sid,
			window: { first: $first_ts, last: $last_ts },
			calls: {
				total: $total,
				errors: $errors,
				rate_per_min: ($rate|tonumber),
				avg_ms: $avg_dur,
				outcomes: $outcomes,
				intent_coverage: {
					populated: $intent_present,
					missing: $intent_missing,
					percentage: ($intent_coverage | tonumber)
				}
			},
			by_tool: $by_tool,
			repeated_file_access: {
				semantic_minimum: $minimum_repeat_count,
				evidence: $rereads,
				classification: "context_required"
			}
		}'
	return 0
}

cmd_errors() {
	local parsed; parsed=$(_parse_common_flags "$@")
	local session_id db_override json_flag since_min limit=""
	session_id=$(echo "$parsed" | awk -F= '/^SESSION=/{sub(/^SESSION=/,"");print;exit}')
	db_override=$(echo "$parsed" | awk -F= '/^DB=/{sub(/^DB=/,"");print;exit}')
	json_flag=$(echo "$parsed" | awk -F= '/^JSON=/{sub(/^JSON=/,"");print;exit}')
	since_min=$(echo "$parsed" | awk -F= '/^SINCE=/{sub(/^SINCE=/,"");print;exit}')
	limit=$(echo "$parsed" | awk -F= '/^POS=/{sub(/^POS=/,"");print;exit}')
	[[ -z "$limit" ]] && limit="$DEFAULT_ERRORS_N"
	[[ "$limit" =~ ^[0-9]+$ ]] || { print_error "N must be a positive integer"; return 1; }

	local db; db=$(_resolve_db_path "$db_override")
	_require_db "$db" || return 1
	local sid; sid=$(_resolve_session_id "$db" "$session_id")
	[[ -z "$sid" ]] && { print_warning "no sessions found in $db"; return 0; }

	local since; since=$(_since_clause "$since_min") || return 1
	local sid_esc; sid_esc=$(_escape_sql "$sid")
	local outcome_expr
	outcome_expr=$(_outcome_category_sql "$db")

	local query="
		SELECT timestamp, tool_name,
			CASE WHEN intent IS NULL OR LENGTH(TRIM(intent)) = 0 THEN '<missing>' ELSE intent END,
			COALESCE(duration_ms,0), ${outcome_expr}
		FROM tool_calls
		WHERE session_id='${sid_esc}' AND success=0 ${since}
		ORDER BY timestamp DESC
		LIMIT ${limit};
	"
	if [[ "$json_flag" == "true" ]]; then
		command -v jq >/dev/null 2>&1 || { print_error "jq required with --json"; return 1; }
		sqlite3 -separator '|' "$db" "$query" | jq -R -s --arg sid "$sid" '
			split("\n") | map(select(length > 0) | split("|") | {
				timestamp: .[0], tool: .[1], intent: .[2],
				duration_ms: (.[3] | tonumber? // 0), category: .[4]
			}) | { session: $sid, errors: . }'
	else
		printf 'Session: %s\n\n' "$sid"
		printf '%-23s  %-8s  %-6s  %-18s  %s\n' "TIMESTAMP" "TOOL" "MS" "CATEGORY" "INTENT"
		printf '%-23s  %-8s  %-6s  %-18s  %s\n' "-----------------------" "--------" "------" "------------------" "----------------------------------------"
		local count=0
		while IFS='|' read -r ts tool intent dur category; do
			[[ -z "$ts" ]] && continue
			printf '%-23s  %-8s  %-6s  %-18s  %s\n' \
				"${ts:0:23}" "${tool:0:8}" "${dur}" "${category:0:18}" "${intent:0:60}"
			count=$((count + 1))
		done < <(sqlite3 -separator '|' "$db" "$query")
		printf '\n%d error(s) shown\n' "$count"
	fi
	return 0
}

cmd_sessions() {
	local parsed; parsed=$(_parse_common_flags "$@")
	local db_override json_flag limit=""
	db_override=$(echo "$parsed" | awk -F= '/^DB=/{sub(/^DB=/,"");print;exit}')
	json_flag=$(echo "$parsed" | awk -F= '/^JSON=/{sub(/^JSON=/,"");print;exit}')
	limit=$(echo "$parsed" | awk -F= '/^POS=/{sub(/^POS=/,"");print;exit}')
	[[ -z "$limit" ]] && limit="$DEFAULT_SESSIONS_N"
	[[ "$limit" =~ ^[0-9]+$ ]] || { print_error "N must be a positive integer"; return 1; }

	local db; db=$(_resolve_db_path "$db_override")
	_require_db "$db" || return 1

	local query="
		SELECT session_id, request_count, total_tool_calls, total_errors, last_seen,
		       printf('%.4f', total_cost)
		FROM session_summaries
		ORDER BY last_seen DESC
		LIMIT ${limit};
	"
	if [[ "$json_flag" == "true" ]]; then
		command -v jq >/dev/null 2>&1 || { print_error "jq required with --json"; return 1; }
		sqlite3 -separator '|' "$db" "$query" | jq -R -s '
			split("\n") | map(select(length > 0) | split("|") | {
				session: .[0],
				requests: (.[1] | tonumber? // 0),
				tool_calls: (.[2] | tonumber? // 0),
				errors: (.[3] | tonumber? // 0),
				last_seen: .[4],
				cost_usd: (.[5] | tonumber? // 0)
			})'
	else
		printf '%-38s  %4s  %5s  %4s  %-23s  %s\n' "SESSION" "REQS" "TOOLS" "ERR" "LAST_SEEN" "COST"
		printf '%-38s  %4s  %5s  %4s  %-23s  %s\n' "--------------------------------------" "----" "-----" "----" "-----------------------" "------"
		local count=0
		while IFS='|' read -r sid reqs tc errs ls cost; do
			[[ -z "$sid" ]] && continue
			printf '%-38s  %4s  %5s  %4s  %-23s  $%s\n' "${sid:0:38}" "$reqs" "$tc" "$errs" "${ls:0:23}" "$cost"
			count=$((count + 1))
		done < <(sqlite3 -separator '|' "$db" "$query")
		printf '\n%d session(s) shown\n' "$count"
	fi
	return 0
}

cmd_help() {
	cat <<'EOF'
session-introspect-helper.sh — mid-session self-diagnosis over opencode observability SQLite

USAGE:
    session-introspect-helper.sh <command> [options]

COMMANDS:
    recent [N]       Last N tool calls in the current session (default 20)
    patterns         Tool distribution, repeated-path evidence, errors, calls/min
    errors [N]       Last N failed tool calls with intent (default 10)
    sessions [N]     Recent N sessions with request/cost summary (default 10)
    help             This message

FLAGS (all commands):
    --session <id>   Explicit session_id (default: most-recent in DB)
    --db <path>      DB path override
    --json           Machine-readable output
    --since <N>      Restrict output to last N minutes of the session

ENVIRONMENT:
    AIDEVOPS_INTROSPECT_DB   DB path (takes precedence over --db and default)

EXAMPLES:
    # "What have I been doing in the last 5 minutes?"
    session-introspect-helper.sh recent 30 --since 5

    # "Where did repeated access occur, and was it verification or rediscovery?"
    session-introspect-helper.sh patterns

    # "Show me my session's error history"
    session-introspect-helper.sh errors

    # "Summary of the last 5 sessions"
    session-introspect-helper.sh sessions 5 --json | jq '.[].tool_calls'

INTERPRETATION:
    This helper reports evidence, not universal problem thresholds. Compare the
    task's intent, peer sessions, verification needs, and comprehension outcomes.
    Preserve unexpected outliers even when they do not fit a known category.
EOF
	return 0
}

# =============================================================================
# Dispatch
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	recent) cmd_recent "$@" ;;
	patterns) cmd_patterns "$@" ;;
	errors) cmd_errors "$@" ;;
	sessions) cmd_sessions "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
