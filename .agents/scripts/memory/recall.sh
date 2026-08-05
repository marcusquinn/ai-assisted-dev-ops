#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# memory/recall.sh - Memory recall/search functions
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: cmd_recall, cmd_history, cmd_latest

# Include guard
[[ -n "${_MEMORY_RECALL_LOADED:-}" ]] && return 0
_MEMORY_RECALL_LOADED=1

#######################################
# Serialize parsed recall arguments as KEY=VALUE pairs
# Usage: _recall_serialize_args <query> <limit> <type_filter> <max_age_days>
#        <project_filter> <format> <recent_mode> <semantic_mode>
#        <hybrid_mode> <shared_mode> <auto_only> <manual_only> <entity_filter>
# Outputs: newline-separated KEY=VALUE pairs
#######################################
_recall_serialize_args() {
	local query="$1"
	local limit="$2"
	local type_filter="$3"
	local max_age_days="$4"
	local project_filter="$5"
	local format="$6"
	local recent_mode="$7"
	local semantic_mode="$8"
	local hybrid_mode="$9"
	local shared_mode="${10}"
	local auto_only="${11}"
	local manual_only="${12}"
	local entity_filter="${13}"

	printf '%s\n' \
		"query=${query}" \
		"limit=${limit}" \
		"type_filter=${type_filter}" \
		"max_age_days=${max_age_days}" \
		"project_filter=${project_filter}" \
		"format=${format}" \
		"recent_mode=${recent_mode}" \
		"semantic_mode=${semantic_mode}" \
		"hybrid_mode=${hybrid_mode}" \
		"shared_mode=${shared_mode}" \
		"auto_only=${auto_only}" \
		"manual_only=${manual_only}" \
		"entity_filter=${entity_filter}"
	return 0
}

#######################################
# Parse arguments for cmd_recall
# Usage: _recall_parse_args "$@"
# Outputs: newline-separated KEY=VALUE pairs (via _recall_serialize_args)
#######################################
_recall_parse_args() {
	local query=""
	local limit=5
	local type_filter=""
	local max_age_days=""
	local project_filter=""
	local format="text"
	local recent_mode=false
	local semantic_mode=false
	local hybrid_mode=false
	local shared_mode=false
	local auto_only=false
	local manual_only=false
	local entity_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--query | -q)
			query="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--type | -t)
			type_filter="$2"
			shift 2
			;;
		--max-age-days)
			max_age_days="$2"
			shift 2
			;;
		--project | -p)
			project_filter="$2"
			shift 2
			;;
		--entity | -e)
			entity_filter="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--recent)
			recent_mode=true
			# Only consume next arg as limit if it's a number (not another flag)
			if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
				limit="$2"
				shift 2
			else
				limit=10
				shift
			fi
			;;
		--semantic | --similar)
			semantic_mode=true
			shift
			;;
		--hybrid)
			hybrid_mode=true
			shift
			;;
		--shared)
			shared_mode=true
			shift
			;;
		--auto-only)
			auto_only=true
			shift
			;;
		--manual-only)
			manual_only=true
			shift
			;;
		*)
			# Allow query as positional argument
			if [[ -z "$query" ]]; then query="$1"; fi
			shift
			;;
		esac
	done

	_recall_serialize_args "$query" "$limit" "$type_filter" "$max_age_days" \
		"$project_filter" "$format" "$recent_mode" "$semantic_mode" \
		"$hybrid_mode" "$shared_mode" "$auto_only" "$manual_only" "$entity_filter"
	return 0
}

#######################################
# Build entity JOIN and WHERE clauses (t1363.3)
# Usage: _recall_build_entity_clauses <entity_filter>
# Outputs: two lines — entity_join and entity_where
#######################################
_recall_build_entity_clauses() {
	local entity_filter="$1"
	local entity_join=""
	local entity_where=""
	if [[ -n "$entity_filter" ]]; then
		local escaped_entity="${entity_filter//"'"/"''"}"
		entity_join="INNER JOIN learning_entities le ON l.id = le.learning_id"
		entity_where="AND le.entity_id = '$escaped_entity'"
	fi
	printf '%s\n' "$entity_join" "$entity_where"
	return 0
}

#######################################
# Build auto-capture filter clause
# Usage: _recall_build_auto_filter <auto_only> <manual_only>
# Outputs: filter SQL fragment
#######################################
_recall_build_auto_filter() {
	local auto_only="$1"
	local manual_only="$2"
	local auto_filter=""
	if [[ "$auto_only" == true ]]; then
		auto_filter="AND COALESCE(a.auto_captured, 0) = 1"
	elif [[ "$manual_only" == true ]]; then
		auto_filter="AND COALESCE(a.auto_captured, 0) = 0"
	fi
	printf '%s' "$auto_filter"
	return 0
}

#######################################
# Build extra SQL filters (type, age, project)
# Usage: _recall_build_extra_filters <type_filter> <max_age_days> <project_filter> [column_prefix]
# Outputs: SQL fragment or exits non-zero on validation error
#######################################
_recall_build_extra_filters() {
	local type_filter="$1"
	local max_age_days="$2"
	local project_filter="$3"
	local column_prefix="${4:-}"
	local extra_filters=""

	if [[ -n "$type_filter" ]]; then
		local type_pattern=" $type_filter "
		if [[ ! " $VALID_TYPES " =~ $type_pattern ]]; then
			log_error "Invalid type: $type_filter"
			log_error "Valid types: $VALID_TYPES"
			return 1
		fi
		extra_filters="$extra_filters AND ${column_prefix}type = '$type_filter'"
	fi
	if [[ -n "$max_age_days" ]]; then
		if ! [[ "$max_age_days" =~ ^[0-9]+$ ]]; then
			log_error "--max-age-days must be a positive integer"
			return 1
		fi
		extra_filters="$extra_filters AND ${column_prefix}created_at >= datetime('now', '-$max_age_days days')"
	fi
	if [[ -n "$project_filter" ]]; then
		local escaped_project="${project_filter//"'"/"''"}"
		escaped_project="${escaped_project//\\/\\\\}"
		escaped_project="${escaped_project//%/\\%}"
		escaped_project="${escaped_project//_/\\_}"
		extra_filters="$extra_filters AND ${column_prefix}project_path LIKE '%$escaped_project%' ESCAPE '\\'"
	fi

	printf '%s' "$extra_filters"
	return 0
}

#######################################
# Build FTS5 parameterised query string
# Usage: _recall_build_fts_param <query>
# Outputs: param_query string safe for .param set
#######################################
_recall_build_fts_param() {
	local query="$1"
	# Strip backslashes — not valid FTS5 syntax
	local query_clean="${query//\\/  }"
	local tokenised_query=""
	local token
	set -f # Disable globbing during tokenization (SC2086)
	for token in $query_clean; do
		token="${token//\"/\"\"}"
		if [[ -n "$tokenised_query" ]]; then
			tokenised_query="$tokenised_query \"$token\""
		else
			tokenised_query="\"$token\""
		fi
	done
	set +f # Re-enable globbing
	# Build SQL single-quoted literal, then escape for dot-command double-quoted arg (GH#5678)
	printf "'%s'" "$(printf '%s' "$tokenised_query" | sed "s/'/''/g")" | sed 's/\\/\\\\/g; s/"/\\"/g'
	return 0
}

#######################################
# Return whether a query is an exact memory or observation identifier.
# Usage: _recall_is_exact_id <query>
#######################################
_recall_is_exact_id() {
	local query="$1"
	[[ "$query" =~ ^(mem|obs)_[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || return 1
	return 0
}

#######################################
# Return whether a known memory table exists in a database.
# Usage: _recall_table_exists <db_path> <table_name>
#######################################
_recall_table_exists() {
	local db_path="$1"
	local table_name="$2"
	local exists

	exists=$(db "$db_path" "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = '$table_name';" 2>/dev/null || printf '0')
	[[ "$exists" == "1" ]] || return 1
	return 0
}

#######################################
# Look up an exact memory/observation ID and normalize it as recall JSON.
# Missing tables are skipped for compatibility with older memory databases.
# Usage: _recall_exact_id_db <db_path> <exact_id>
# Outputs: JSON array
#######################################
_recall_exact_id_db() {
	local db_path="$1"
	local exact_id="$2"
	local selects=()
	local union_sql=""
	local select_sql

	if [[ "$exact_id" == mem_* ]]; then
		if _recall_table_exists "$db_path" "learnings"; then
			selects+=("SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, '' AS last_accessed_at, 0 AS access_count, 0 AS auto_captured, 0.0 AS usefulness_score, 'live' AS truth_status, '' AS truth_evidence, '' AS replacement_id, '' AS superseded_by, 0.0 AS score, 'learning' AS record_kind, '' AS statement, '' AS observation_id FROM learnings l WHERE l.id = :exact_id")
		fi
		if _recall_table_exists "$db_path" "conversation_summaries"; then
			selects+=("SELECT cs.id, cs.summary AS content, 'CONVERSATION_SUMMARY' AS type, '' AS tags, 'medium' AS confidence, cs.created_at, '' AS last_accessed_at, 0 AS access_count, 0 AS auto_captured, 0.0 AS usefulness_score, 'live' AS truth_status, '' AS truth_evidence, '' AS replacement_id, COALESCE(cs.supersedes_id, '') AS superseded_by, 0.0 AS score, 'conversation_summary' AS record_kind, cs.summary AS statement, '' AS observation_id FROM conversation_summaries cs WHERE cs.id = :exact_id")
		fi
		if _recall_table_exists "$db_path" "interactions"; then
			selects+=("SELECT i.id, i.content, 'INTERACTION' AS type, i.channel AS tags, 'medium' AS confidence, i.created_at, '' AS last_accessed_at, 0 AS access_count, 0 AS auto_captured, 0.0 AS usefulness_score, 'live' AS truth_status, '' AS truth_evidence, '' AS replacement_id, '' AS superseded_by, 0.0 AS score, 'interaction' AS record_kind, i.content AS statement, '' AS observation_id FROM interactions i WHERE i.id = :exact_id")
		fi
	elif _recall_table_exists "$db_path" "observations"; then
		selects+=("SELECT o.observation_id AS id, o.statement AS content, o.kind AS type, '' AS tags, o.confidence, o.created_at, '' AS last_accessed_at, 0 AS access_count, 0 AS auto_captured, 0.0 AS usefulness_score, o.status AS truth_status, '' AS truth_evidence, '' AS replacement_id, '' AS superseded_by, 0.0 AS score, 'observation' AS record_kind, o.statement, o.observation_id FROM observations o WHERE o.observation_id = :exact_id")
	fi

	if [[ ${#selects[@]} -eq 0 ]]; then
		printf '[]'
		return 0
	fi

	for select_sql in "${selects[@]}"; do
		if [[ -n "$union_sql" ]]; then
			union_sql="$union_sql UNION ALL $select_sql"
		else
			union_sql="$select_sql"
		fi
	done

	local exact_results
	exact_results=$(
		db -json "$db_path" <<EOF
.parameter init
.parameter set :exact_id "$exact_id"
$union_sql;
EOF
	)
	local rc=$?
	[[ $rc -eq 0 ]] || return "$rc"
	printf '%s' "${exact_results:-[]}"
	return 0
}

#######################################
# Track an exact learning hit without creating access rows for other record types.
# Usage: _recall_update_exact_access <db_path> <exact_id>
#######################################
_recall_update_exact_access() {
	local db_path="$1"
	local exact_id="$2"

	[[ "$exact_id" == mem_* ]] || return 0
	_recall_table_exists "$db_path" "learnings" || return 0
	_recall_table_exists "$db_path" "learning_access" || return 0

	db "$db_path" <<EOF
.parameter init
.parameter set :exact_id "$exact_id"
INSERT INTO learning_access (id, last_accessed_at, access_count)
SELECT id, datetime('now'), 1 FROM learnings WHERE id = :exact_id
ON CONFLICT(id) DO UPDATE SET
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
	return $?
}

#######################################
# Execute FTS5 search against a database
# Usage: _recall_search_db <db_path> <param_query> <entity_fts_join> <entity_fts_where>
#                          <extra_filters> <auto_join_filter> <limit>
# Outputs: JSON results
#######################################
_recall_search_db() {
	local db_path="$1"
	local param_query="$2"
	local entity_fts_join="$3"
	local entity_fts_where="$4"
	local extra_filters="$5"
	local auto_join_filter="$6"
	local limit="$7"

	# Retrieval feedback loop: blend BM25 relevance with usefulness_score.
	# bm25() returns negative values (more negative = more relevant).
	# usefulness_score is 0.0+ (higher = more useful in practice).
	# Blended score: bm25 - (usefulness_score * 0.3)
	#   The 0.3 lambda weight means a memory with usefulness_score=3.0 gets
	#   a 0.9-point boost — enough to promote proven-useful results by ~1-2
	#   positions without overriding strong keyword relevance.
	# The lambda is conservative: relevance still dominates, but memories
	# that have proven useful in practice get a meaningful edge.
	db -json "$db_path" <<EOF
.param set :query "${param_query}"
SELECT
    learnings.id,
    learnings.content,
    learnings.type,
    learnings.tags,
    learnings.confidence,
    learnings.created_at,
    COALESCE(learning_access.last_accessed_at, '') as last_accessed_at,
    COALESCE(learning_access.access_count, 0) as access_count,
    COALESCE(learning_access.auto_captured, 0) as auto_captured,
    COALESCE(learning_access.usefulness_score, 0.0) as usefulness_score,
    COALESCE(latest_truth.status, 'live') as truth_status,
    COALESCE(latest_truth.evidence, '') as truth_evidence,
    COALESCE(latest_truth.replacement_id, '') as replacement_id,
    COALESCE(superseded_by.id, '') as superseded_by,
    bm25(learnings) as bm25_score,
    (bm25(learnings) - (COALESCE(learning_access.usefulness_score, 0.0) * 0.3)) as score
FROM learnings
INNER JOIN observations observation ON observation.observation_id = 'obs_learning_' || learnings.id
LEFT JOIN learning_access ON learnings.id = learning_access.id
LEFT JOIN learning_truth_events latest_truth ON latest_truth.event_id = (
    SELECT event_id FROM learning_truth_events truth_pick
    WHERE truth_pick.memory_id = learnings.id
    ORDER BY truth_pick.created_at DESC, truth_pick.event_id DESC
    LIMIT 1
)
LEFT JOIN learning_relations superseded_by ON superseded_by.supersedes_id = learnings.id
    AND superseded_by.relation_type = 'updates'
$entity_fts_join
WHERE learnings MATCH :query $extra_filters $auto_join_filter $entity_fts_where
AND observation.status = 'active'
AND (observation.expires_at IS NULL OR observation.expires_at > datetime('now'))
ORDER BY score
LIMIT $limit;
EOF
}

#######################################
# Update access tracking for returned results
# Usage: _recall_update_access <db_path> <json_results>
#######################################
_recall_update_access() {
	local db_path="$1"
	local results="$2"

	[[ -z "$results" || "$results" == "[]" ]] && return 0

	local ids
	ids=$(printf '%s' "$results" | extract_ids_from_json)
	[[ -z "$ids" ]] && return 0

	local id_values=""
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		local escaped_id="${id//"'"/"''"}"
		if [[ -n "$id_values" ]]; then
			id_values="${id_values}, ('${escaped_id}', datetime('now'), 1)"
		else
			id_values="('${escaped_id}', datetime('now'), 1)"
		fi
	done <<<"$ids"

	[[ -z "$id_values" ]] && return 0

	db "$db_path" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES $id_values
ON CONFLICT(id) DO UPDATE SET
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
	return 0
}

#######################################
# Build entity JOIN/WHERE for FTS5 queries (no alias support)
# Usage: _recall_build_entity_fts_clauses <entity_filter>
# Outputs: two lines — entity_fts_join and entity_fts_where
#######################################
_recall_build_entity_fts_clauses() {
	local entity_filter="$1"
	local entity_fts_join=""
	local entity_fts_where=""
	if [[ -n "$entity_filter" ]]; then
		local escaped_entity="${entity_filter//"'"/"''"}"
		entity_fts_join="INNER JOIN learning_entities ON learnings.id = learning_entities.learning_id"
		entity_fts_where="AND learning_entities.entity_id = '$escaped_entity'"
	fi
	printf '%s\n' "$entity_fts_join" "$entity_fts_where"
	return 0
}

#######################################
# Perform shared (global DB) search and update access tracking
# Usage: _recall_shared_search <param_query> <entity_fts_join> <entity_fts_where>
#                              <extra_filters> <auto_join_filter> <limit>
# Outputs: JSON results (may be empty)
#######################################
_recall_shared_search() {
	local param_query="$1"
	local entity_fts_join="$2"
	local entity_fts_where="$3"
	local extra_filters="$4"
	local auto_join_filter="$5"
	local limit="$6"

	local global_db
	global_db=$(global_db_path)
	[[ ! -f "$global_db" ]] && return 0

	local shared_results
	shared_results=$(_recall_search_db "$global_db" "$param_query" \
		"$entity_fts_join" "$entity_fts_where" \
		"$extra_filters" "$auto_join_filter" "$limit")

	_recall_update_access "$global_db" "$shared_results"
	printf '%s' "$shared_results"
	return 0
}

#######################################
# Handle --recent mode: query and print recent memories
# Usage: _recall_recent <db> <entity_join> <entity_where> <auto_filter> <limit> <format> <extra_filters>
#######################################
_recall_recent() {
	local db_path="$1"
	local entity_join="$2"
	local entity_where="$3"
	local auto_filter="$4"
	local limit="$5"
	local format="$6"
	local extra_filters="$7"

	local results
	results=$(db -json "$db_path" "SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count, COALESCE(a.auto_captured, 0) as auto_captured, COALESCE(a.usefulness_score, 0.0) as usefulness_score, o.status as truth_status, '' as truth_evidence, '' as replacement_id, '' as superseded_by FROM learnings l INNER JOIN observations o ON o.observation_id = 'obs_learning_' || l.id LEFT JOIN learning_access a ON l.id = a.id $entity_join WHERE 1=1 $entity_where $auto_filter $extra_filters AND o.status = 'active' AND (o.expires_at IS NULL OR o.expires_at > datetime('now')) ORDER BY l.created_at DESC LIMIT $limit;")
	if [[ "$format" == "json" ]]; then
		printf '%s\n' "$results"
	else
		printf '\n=== Recent Memories (last %s) ===\n\n' "$limit"
		printf '%s' "$results" | format_results_text
	fi
	return 0
}

#######################################
# Handle --semantic / --hybrid mode: delegate to embeddings helper
# Usage: _recall_semantic <query> <limit> <hybrid_mode> <format> <project> <entity> <type> <max_age>
# Returns: exit code from embeddings helper, or 1 if unavailable
#######################################
_recall_semantic() {
	local query="$1"
	local limit="$2"
	local hybrid_mode="$3"
	local format="$4"
	local project_filter="$5"
	local entity_filter="$6"
	local type_filter="$7"
	local max_age_days="$8"

	local embeddings_script
	embeddings_script="$(dirname "${BASH_SOURCE[0]}")/../memory-embeddings-helper.sh"
	if [[ ! -x "$embeddings_script" ]]; then
		log_error "Semantic search not available. Run: memory-embeddings-helper.sh setup"
		return 1
	fi
	local semantic_args=()
	if [[ -n "$MEMORY_NAMESPACE" ]]; then
		semantic_args+=("--namespace" "$MEMORY_NAMESPACE")
	fi
	semantic_args+=("search" "$query" "--limit" "$limit")
	if [[ "$hybrid_mode" == true ]]; then
		semantic_args+=("--hybrid")
	fi
	if [[ "$format" == "json" ]]; then
		semantic_args+=("--json")
	fi
	MEMORY_SEARCH_PROJECT="$project_filter" MEMORY_SEARCH_ENTITY="$entity_filter" \
		MEMORY_SEARCH_TYPE="$type_filter" MEMORY_SEARCH_MAX_AGE_DAYS="$max_age_days" \
		"$embeddings_script" "${semantic_args[@]}"
	return $?
}

#######################################
# Output recall results in the requested format
# Usage: _recall_output <format> <query> <entity_filter> <results> <shared_results> <limit>
#######################################
_recall_output() {
	local format="$1"
	local query="$2"
	local entity_filter="$3"
	local results="$4"
	local shared_results="$5"
	local limit="$6"

	if [[ "$format" == "json" ]]; then
		if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
			if command -v jq &>/dev/null; then
				local ns_json="${results:-[]}"
				jq -s '.[0] + .[1] | sort_by(.score) | .[:'"$limit"']' \
					<(printf '%s' "$ns_json") <(printf '%s' "$shared_results")
			else
				printf '%s\n' "$results" "$shared_results"
			fi
		else
			printf '%s\n' "$results"
		fi
		return 0
	fi

	# Text format
	if [[ -z "$results" || "$results" == "[]" ]] &&
		[[ -z "$shared_results" || "$shared_results" == "[]" ]]; then
		log_warn "No results found for: $query"
		return 0
	fi

	local header_suffix=""
	if [[ -n "$MEMORY_NAMESPACE" ]]; then
		header_suffix=" [namespace: $MEMORY_NAMESPACE]"
	fi
	if [[ -n "$entity_filter" ]]; then
		header_suffix="${header_suffix} [entity: $entity_filter]"
	fi

	printf '\n=== Memory Recall: "%s"%s ===\n\n' "$query" "$header_suffix"

	if [[ -n "$results" && "$results" != "[]" ]]; then
		printf '%s' "$results" | format_results_text
	fi

	if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
		printf '\n--- Shared (global) results ---\n\n'
		printf '%s' "$shared_results" | format_results_text
	fi
	return 0
}

#######################################
# Unpack parsed KEY=VALUE pairs into local variables for cmd_recall
# Usage: _recall_unpack_args <parsed_string>
# Sets: query limit type_filter max_age_days project_filter format
#       recent_mode semantic_mode hybrid_mode shared_mode
#       auto_only manual_only entity_filter
#######################################
_recall_unpack_args() {
	local parsed="$1"
	while IFS='=' read -r key val; do
		case "$key" in
		query) query="$val" ;;
		limit) limit="$val" ;;
		type_filter) type_filter="$val" ;;
		max_age_days) max_age_days="$val" ;;
		project_filter) project_filter="$val" ;;
		format) format="$val" ;;
		recent_mode) recent_mode="$val" ;;
		semantic_mode) semantic_mode="$val" ;;
		hybrid_mode) hybrid_mode="$val" ;;
		shared_mode) shared_mode="$val" ;;
		auto_only) auto_only="$val" ;;
		manual_only) manual_only="$val" ;;
		entity_filter) entity_filter="$val" ;;
		esac
	done <<<"$parsed"
	return 0
}

#######################################
# Execute FTS5 search: build query/filters, search DB, update access, shared search.
# Caller must have: query limit type_filter max_age_days project_filter
#                   auto_only manual_only entity_filter shared_mode MEMORY_DB
# Outputs: sets results and shared_results in caller scope
#######################################
_recall_execute_fts() {
	# Build FTS5 parameterised query
	param_query=$(_recall_build_fts_param "$query")

	# Build extra filters (validates type/age/project)
	extra_filters=$(_recall_build_extra_filters "$type_filter" "$max_age_days" "$project_filter") || return $?

	# Build auto-capture filter for FTS query (uses full table name, no alias)
	auto_join_filter=""
	if [[ "$auto_only" == true ]]; then
		auto_join_filter="AND COALESCE(learning_access.auto_captured, 0) = 1"
	elif [[ "$manual_only" == true ]]; then
		auto_join_filter="AND COALESCE(learning_access.auto_captured, 0) = 0"
	fi

	# Build entity clauses for FTS5 (no alias support)
	local entity_fts_clauses
	entity_fts_clauses=$(_recall_build_entity_fts_clauses "$entity_filter")
	entity_fts_join=$(printf '%s' "$entity_fts_clauses" | head -1)
	entity_fts_where=$(printf '%s' "$entity_fts_clauses" | tail -1)

	# Execute FTS5 search and update access tracking
	results=$(_recall_search_db "$MEMORY_DB" "$param_query" \
		"$entity_fts_join" "$entity_fts_where" \
		"$extra_filters" "$auto_join_filter" "$limit")
	_recall_update_access "$MEMORY_DB" "$results"

	# Shared search: also query global DB when in a namespace with --shared
	shared_results=""
	if [[ "$shared_mode" == true && -n "$MEMORY_NAMESPACE" ]]; then
		shared_results=$(_recall_shared_search "$param_query" \
			"$entity_fts_join" "$entity_fts_where" \
			"$extra_filters" "$auto_join_filter" "$limit")
	fi
	return 0
}

#######################################
# Recall learnings with search
#######################################
cmd_recall() {
	# Handle --stats early exit before argument parsing
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--stats" ]]; then
			cmd_stats
			return $?
		fi
	done

	# Parse arguments into KEY=VALUE pairs
	local parsed
	parsed=$(_recall_parse_args "$@") || return $?

	local query="" limit="" type_filter="" max_age_days="" project_filter="" format=""
	local recent_mode="" semantic_mode="" hybrid_mode="" shared_mode=""
	local auto_only="" manual_only="" entity_filter=""
	_recall_unpack_args "$parsed"

	init_db

	# Validate --entity if provided (t1363.3)
	if [[ -n "$entity_filter" ]]; then
		if ! validate_entity_id "$entity_filter"; then
			log_error "Entity not found: $entity_filter"
			return 1
		fi
	fi

	# Build entity clauses for non-FTS queries
	local entity_clauses entity_join entity_where
	entity_clauses=$(_recall_build_entity_clauses "$entity_filter")
	entity_join=$(printf '%s' "$entity_clauses" | head -1)
	entity_where=$(printf '%s' "$entity_clauses" | tail -1)

	# Build auto-capture filter
	local auto_filter
	auto_filter=$(_recall_build_auto_filter "$auto_only" "$manual_only")

	# Handle --recent mode (no query required)
	if [[ "$recent_mode" == true ]]; then
		if [[ "$semantic_mode" == true || "$hybrid_mode" == true || "$shared_mode" == true ]]; then
			log_error "--recent cannot be combined with --semantic, --hybrid, or --shared"
			return 1
		fi
		local recent_extra_filters=""
		recent_extra_filters=$(_recall_build_extra_filters "$type_filter" "$max_age_days" "$project_filter" "l.") || return $?
		_recall_recent "$MEMORY_DB" "$entity_join" "$entity_where" "$auto_filter" "$limit" "$format" "$recent_extra_filters"
		return 0
	fi

	if [[ -z "$query" ]]; then
		log_error "Query is required. Use --query \"search terms\" or --recent"
		return 1
	fi

	# Concrete IDs are deterministic lookups, even when semantic flags are present.
	# Do not fall through to FTS for a missing exact ID: an unrelated text match
	# would make a traceable identifier ambiguous.
	if _recall_is_exact_id "$query"; then
		local exact_results exact_shared_results=""
		exact_results=$(_recall_exact_id_db "$MEMORY_DB" "$query") || return $?
		_recall_update_exact_access "$MEMORY_DB" "$query" || return $?
		if [[ "$shared_mode" == true && -n "$MEMORY_NAMESPACE" ]]; then
			local exact_global_db
			exact_global_db=$(global_db_path)
			if [[ -f "$exact_global_db" ]]; then
				exact_shared_results=$(_recall_exact_id_db "$exact_global_db" "$query") || return $?
				_recall_update_exact_access "$exact_global_db" "$query" || return $?
			fi
		fi
		_recall_output "$format" "$query" "$entity_filter" "$exact_results" "$exact_shared_results" "$limit"
		return 0
	fi

	# Handle --semantic or --hybrid mode (delegate to embeddings helper)
	if [[ "$semantic_mode" == true || "$hybrid_mode" == true ]]; then
		if [[ "$auto_only" == true || "$manual_only" == true ||
			"$shared_mode" == true ]]; then
			log_error "Semantic/hybrid recall does not support --auto-only, --manual-only, or --shared"
			return 1
		fi
		_recall_semantic "$query" "$limit" "$hybrid_mode" "$format" \
			"$project_filter" "$entity_filter" "$type_filter" "$max_age_days"
		return $?
	fi

	# Execute FTS5 search (builds query, filters, entity clauses, shared search)
	local param_query extra_filters auto_join_filter
	local entity_fts_join="" entity_fts_where=""
	local results="" shared_results=""
	_recall_execute_fts || return $?

	_recall_output "$format" "$query" "$entity_filter" "$results" "$shared_results" "$limit"
	return 0
}

#######################################
# Display ancestor chain for a memory
# Usage: _history_show_ancestors <db_path> <escaped_id>
#######################################
_history_show_ancestors() {
	local db_path="$1"
	local escaped_id="$2"

	printf '\nSupersedes (ancestors):\n'
	local ancestors
	ancestors=$(
		db "$db_path" <<EOF
WITH RECURSIVE ancestors AS (
    SELECT lr.supersedes_id, lr.relation_type, 1 as depth
    FROM learning_relations lr
    WHERE lr.id = '$escaped_id'
    UNION ALL
    SELECT lr.supersedes_id, lr.relation_type, a.depth + 1
    FROM learning_relations lr
    JOIN ancestors a ON lr.id = a.supersedes_id
    WHERE a.depth < 10
)
SELECT a.supersedes_id, a.relation_type, a.depth,
       l.type, substr(l.content, 1, 60), l.created_at
FROM ancestors a
JOIN learnings l ON a.supersedes_id = l.id
ORDER BY a.depth;
EOF
	)

	if [[ -z "$ancestors" ]]; then
		printf '  (none - this is the original)\n'
	else
		printf '%s' "$ancestors" | while IFS='|' read -r sup_id rel_type depth mem_type content created; do
			local indent
			indent=$(printf '%*s' "$((depth * 2))" '')
			printf '%s[%s] %s\n' "$indent" "$rel_type" "$sup_id"
			printf '%s  [%s] %s...\n' "$indent" "$mem_type" "$content"
			printf '%s  Created: %s\n' "$indent" "$created"
		done
	fi
	return 0
}

#######################################
# Display descendant chain for a memory
# Usage: _history_show_descendants <db_path> <escaped_id>
#######################################
_history_show_descendants() {
	local db_path="$1"
	local escaped_id="$2"

	printf '\nSuperseded by (descendants):\n'
	local descendants
	descendants=$(
		db "$db_path" <<EOF
WITH RECURSIVE descendants AS (
    SELECT lr.id as child_id, lr.relation_type, 1 as depth
    FROM learning_relations lr
    WHERE lr.supersedes_id = '$escaped_id'
    UNION ALL
    SELECT lr.id, lr.relation_type, d.depth + 1
    FROM learning_relations lr
    JOIN descendants d ON lr.supersedes_id = d.child_id
    WHERE d.depth < 10
)
SELECT d.child_id, d.relation_type, d.depth,
       l.type, substr(l.content, 1, 60), l.created_at
FROM descendants d
JOIN learnings l ON d.child_id = l.id
ORDER BY d.depth;
EOF
	)

	if [[ -z "$descendants" ]]; then
		printf '  (none - this is the latest)\n'
	else
		printf '%s' "$descendants" | while IFS='|' read -r child_id rel_type depth mem_type content created; do
			local indent
			indent=$(printf '%*s' "$((depth * 2))" '')
			printf '%s[%s] %s\n' "$indent" "$rel_type" "$child_id"
			printf '%s  [%s] %s...\n' "$indent" "$mem_type" "$content"
			printf '%s  Created: %s\n' "$indent" "$created"
		done
	fi
	return 0
}

#######################################
# Show version history for a memory
# Traces the chain of updates/extends/derives
#######################################
cmd_history() {
	local memory_id="$1"

	if [[ -z "$memory_id" ]]; then
		log_error "Memory ID is required. Usage: memory-helper.sh history <id>"
		return 1
	fi
	init_db

	# Escape memory_id for SQL (prevents SQL injection)
	local escaped_id="${memory_id//"'"/"''"}"

	# Check if memory exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Memory not found: $memory_id"
		return 1
	fi

	printf '\n=== Version History for %s ===\n\n' "$memory_id"

	# Show the current memory
	printf 'Current:\n'
	db "$MEMORY_DB" <<EOF
SELECT '  [' || type || '] ' || substr(content, 1, 80) || '...'
FROM learnings WHERE id = '$escaped_id';
SELECT '  Created: ' || created_at || ' | Event: ' || COALESCE(event_date, 'N/A')
FROM learnings WHERE id = '$escaped_id';
EOF

	_history_show_ancestors "$MEMORY_DB" "$escaped_id"
	_history_show_descendants "$MEMORY_DB" "$escaped_id"

	return 0
}

#######################################
# Find the latest version of a memory
# Follows the chain of 'updates' relations to find the current truth
#######################################
cmd_latest() {
	local memory_id="$1"

	if [[ -z "$memory_id" ]]; then
		log_error "Memory ID is required. Usage: memory-helper.sh latest <id>"
		return 1
	fi

	init_db

	# Escape memory_id for SQL (prevents SQL injection)
	local escaped_id="${memory_id//"'"/"''"}"

	# Find the latest in the chain (no descendants with 'updates' relation)
	local latest_id
	latest_id=$(
		db "$MEMORY_DB" <<EOF
WITH RECURSIVE chain AS (
    SELECT '$escaped_id' as id
    UNION ALL
    SELECT lr.id
    FROM learning_relations lr
    JOIN chain c ON lr.supersedes_id = c.id
    WHERE lr.relation_type = 'updates'
)
SELECT id FROM chain
WHERE id NOT IN (SELECT supersedes_id FROM learning_relations WHERE relation_type = 'updates')
LIMIT 1;
EOF
	)

	if [[ -z "$latest_id" ]]; then
		latest_id="$memory_id"
	fi

	# Escape latest_id for the final query
	local escaped_latest="${latest_id//"'"/"''"}"

	printf '%s\n' "$latest_id"

	# Show the content
	db "$MEMORY_DB" <<EOF
SELECT '[' || type || '] ' || content
FROM learnings WHERE id = '$escaped_latest';
EOF

	return 0
}

#######################################
# Record retrieval feedback — mark a recalled memory as useful.
#
# Retrieval feedback loop (inspired by Ori Mnemos Q-value system):
# When a recalled memory leads to a downstream action (commit, PR, new memory,
# code edit), the caller records positive feedback. This increments the
# usefulness_score in learning_access. Future recalls boost results with
# higher usefulness_score, so memories that prove useful in practice
# surface more readily.
#
# Signal types and their reward values:
#   cited      (+1.0) — memory was referenced/linked in new content
#   edited     (+0.5) — memory was edited/updated after retrieval
#   led_to_new (+0.6) — a new memory was created after retrieving this one
#   reused     (+0.4) — same memory recalled across different queries in session
#   dead_end   (-0.15) — retrieved in top results but no follow-up action
#   false      (-2.0) — retrieved memory was false/debunked
#   debunked   (-2.0) — alias for false
#
# Usage:
#   memory-helper.sh feedback <memory_id> [--signal <type>] [--value <float>]
#   memory-helper.sh feedback mem_xxx --signal cited
#   memory-helper.sh feedback mem_xxx --signal dead_end
#   memory-helper.sh feedback mem_xxx --value 0.8
#######################################
_feedback_parse_args() {
	_FEEDBACK_MEMORY_ID=""
	_FEEDBACK_SIGNAL=""
	_FEEDBACK_CUSTOM_VALUE=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local next_arg="${2:-}"
		case "$arg" in
		--signal | -s)
			[[ $# -ge 2 ]] || {
				log_error "Option $arg requires an argument"
				return 1
			}
			_FEEDBACK_SIGNAL="$next_arg"
			shift 2
			;;
		--value | -v)
			[[ $# -ge 2 ]] || {
				log_error "Option $arg requires an argument"
				return 1
			}
			_FEEDBACK_CUSTOM_VALUE="$next_arg"
			shift 2
			;;
		*)
			if [[ -z "$_FEEDBACK_MEMORY_ID" ]]; then
				_FEEDBACK_MEMORY_ID="$arg"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$_FEEDBACK_MEMORY_ID" ]]; then
		log_error "Memory ID is required. Usage: memory-helper.sh feedback <id> [--signal <type>]"
		return 1
	fi
	if [[ -n "$_FEEDBACK_CUSTOM_VALUE" ]] && ! [[ "$_FEEDBACK_CUSTOM_VALUE" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
		log_error "--value must be numeric"
		return 1
	fi
	case "$_FEEDBACK_SIGNAL" in
	"" | cited | edited | led_to_new | reused | dead_end | false | debunked) ;;
	*)
		log_error "Unknown signal type: $_FEEDBACK_SIGNAL"
		log_error "Valid signals: cited, edited, led_to_new, reused, dead_end, false, debunked"
		return 1
		;;
	esac
	return 0
}

_feedback_resolve_reward() {
	local custom_value="$1"
	local signal="$2"
	if [[ -n "$custom_value" ]]; then
		printf '%s' "$custom_value"
		return 0
	fi
	case "$signal" in
	"") printf '0.5' ;;
	cited) printf '1.0' ;;
	edited) printf '0.5' ;;
	led_to_new) printf '0.6' ;;
	reused) printf '0.4' ;;
	dead_end) printf '%s' '-0.15' ;;
	false | debunked) printf '%s' '-2.0' ;;
	*)
		log_error "Unknown signal type: $signal"
		log_error "Valid signals: cited, edited, led_to_new, reused, dead_end, false, debunked"
		return 1
		;;
	esac
	return 0
}

_feedback_store_outcome() {
	local escaped_id="$1"
	local reward="$2"
	local signal="$3"

	db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count, usefulness_score)
VALUES ('$escaped_id', datetime('now'), 0, MAX(-5.0, $reward))
ON CONFLICT(id) DO UPDATE SET
    usefulness_score = MAX(-5.0, COALESCE(usefulness_score, 0.0) + $reward);
INSERT OR IGNORE INTO observation_outcomes (
    outcome_id, observation_id, outcome_kind, outcome_value, details, recorded_at
)
VALUES (
    'out_feedback_${escaped_id}_' || strftime('%Y%m%d%H%M%f', 'now'),
    'obs_learning_$escaped_id',
    CASE '$signal'
        WHEN 'cited' THEN 'helpful_recall'
        WHEN 'reused' THEN 'verified_reuse'
        WHEN 'dead_end' THEN 'rejected'
        WHEN 'false' THEN 'correction'
        WHEN 'debunked' THEN 'correction'
        ELSE 'retrieval_feedback'
    END,
    $reward, 'signal=${signal:-custom}', strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);
EOF
	db "$MEMORY_DB" "SELECT COALESCE(usefulness_score, 0.0) FROM learning_access WHERE id = '$escaped_id';" 2>/dev/null || printf '0.0'
	return 0
}

cmd_feedback() {
	_feedback_parse_args "$@" || return 1
	local memory_id="$_FEEDBACK_MEMORY_ID"
	local signal="$_FEEDBACK_SIGNAL"
	local custom_value="$_FEEDBACK_CUSTOM_VALUE"
	local escaped_id="${memory_id//"'"/"''"}"

	init_db
	local exists=""
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Memory not found: $memory_id"
		return 1
	fi

	local reward=""
	reward=$(_feedback_resolve_reward "$custom_value" "$signal") || return 1
	local new_score=""
	new_score=$(_feedback_store_outcome "$escaped_id" "$reward" "$signal")

	if [[ -n "$signal" ]]; then
		log_success "Feedback recorded: $memory_id signal=$signal reward=$reward (score now: $new_score)"
	else
		log_success "Feedback recorded: $memory_id reward=$reward (score now: $new_score)"
	fi
	return 0
}
