#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Model Registry Helper - Provider/Model Registry with Periodic Sync
# Maintains a SQLite registry of AI models from configured providers,
# compares against local subagent definitions, flags deprecated/renamed
# models, and suggests new models worth adding.
#
# Usage: model-registry-helper.sh [command] [options]
#
# Commands:
#   sync          Sync registry from all sources (subagents, embedded data, APIs)
#   list          List all models in the registry
#   status        Show registry health and staleness
#   check         Check configured models against live provider APIs
#   suggest       Suggest new models worth adding to subagent definitions
#   deprecations  Show deprecated/renamed/unavailable models
#   diff          Show differences between registry and local config
#   export        Export registry as JSON
#   help          Show this help
#
# Options:
#   --json        Output in JSON format (where supported)
#   --quiet       Suppress informational output
#   --force       Force full resync even if cache is fresh
#
# Runs on: aidevops update, optionally via cron
# Storage: ~/.aidevops/.agent-workspace/model-registry.db
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly REGISTRY_DIR="${HOME}/.aidevops/.agent-workspace"
readonly REGISTRY_DB="${REGISTRY_DIR}/model-registry.db"
readonly SYNC_INTERVAL=86400 # 24 hours in seconds
readonly AGENTS_DIR="${SCRIPT_DIR}/.."
readonly MODELS_DIR="${AGENTS_DIR}/tools/ai-assistants/models"

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
	mkdir -p "$REGISTRY_DIR" 2>/dev/null || true

	sqlite3 "$REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS models (
            model_id       TEXT NOT NULL,
            provider       TEXT NOT NULL,
            display_name   TEXT DEFAULT '',
            normalized_name TEXT DEFAULT '',
            context_window INTEGER DEFAULT 0,
            input_price    REAL DEFAULT 0.0,
            output_price   REAL DEFAULT 0.0,
            tier           TEXT DEFAULT '',
            capabilities   TEXT DEFAULT '',
            best_for       TEXT DEFAULT '',
            source         TEXT DEFAULT 'embedded',
            status         TEXT DEFAULT 'active',
            first_seen     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_seen      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_verified  TEXT DEFAULT '',
            deprecated     INTEGER DEFAULT 0,
            deprecation_note TEXT DEFAULT '',
            PRIMARY KEY (model_id, provider)
        );

        CREATE TABLE IF NOT EXISTS subagent_models (
            tier           TEXT PRIMARY KEY,
            model_id       TEXT NOT NULL,
            model_full_id  TEXT DEFAULT '',
            normalized_name TEXT DEFAULT '',
            fallback_id    TEXT DEFAULT '',
            subagent_file  TEXT NOT NULL,
            last_synced    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS provider_models (
            model_id       TEXT NOT NULL,
            provider       TEXT NOT NULL,
            discovered_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            in_registry    INTEGER DEFAULT 0,
            in_subagents   INTEGER DEFAULT 0,
            PRIMARY KEY (model_id, provider)
        );

        CREATE TABLE IF NOT EXISTS sync_log (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            sync_type      TEXT NOT NULL,
            source         TEXT NOT NULL,
            models_added   INTEGER DEFAULT 0,
            models_updated INTEGER DEFAULT 0,
            models_removed INTEGER DEFAULT 0,
            timestamp      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            details        TEXT DEFAULT ''
        );
    " 2>/dev/null || {
		print_error "Failed to initialize registry database"
		return 1
	}
	return 0
}

# =============================================================================
# Model Name Normalization
# =============================================================================
# Normalizes model names for fuzzy matching across different naming conventions.
# Example: provider/version variants normalize to a stable family label.

normalize_model_name() {
	local name="$1"
	# Strip provider prefix
	name="${name#*/}"
	# Strip date suffixes (e.g., -20250514, -20241022)
	name="${name%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
	# Strip preview suffixes
	name=$(echo "$name" | sed -E 's/-preview-[0-9]{2}-[0-9]{2}$//')
	# Strip version numbers (e.g., -3-5, -3.5, -4, -2.5, -2.0)
	name=$(echo "$name" | sed -E 's/-[0-9]+(\.[0-9]+)?//g')
	# Lowercase
	echo "$name" | tr '[:upper:]' '[:lower:]'
	return 0
}

# =============================================================================
# SQL Helpers
# =============================================================================

sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

db_query() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" "$REGISTRY_DB" "$query" 2>/dev/null
	return $?
}

db_query_csv() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" -csv -header "$REGISTRY_DB" "$query" 2>/dev/null
	return $?
}

db_query_json() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" -json "$REGISTRY_DB" "$query" 2>/dev/null
	return $?
}

# =============================================================================
# Sync: Subagent Frontmatter
# =============================================================================

# Parse model frontmatter fields from a single markdown file.
# Outputs: model_full, model_tier, model_fallback (one per line as key=value).
# Returns 1 if the file has no valid model frontmatter.
_parse_subagent_frontmatter() {
	local md_file="$1"
	local model_full="" model_tier="" model_fallback=""
	local in_frontmatter=false
	local line_num=0

	while IFS= read -r line; do
		line_num=$((line_num + 1))
		if [[ $line_num -eq 1 && "$line" == "---" ]]; then
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == "true" && "$line" == "---" ]]; then
			break
		fi
		if [[ "$in_frontmatter" == "true" ]]; then
			case "$line" in
			model:*)
				model_full="${line#model:}"
				model_full="${model_full#"${model_full%%[![:space:]]*}"}"
				;;
			model-tier:*)
				model_tier="${line#model-tier:}"
				model_tier="${model_tier#"${model_tier%%[![:space:]]*}"}"
				;;
			model-fallback:*)
				model_fallback="${line#model-fallback:}"
				model_fallback="${model_fallback#"${model_fallback%%[![:space:]]*}"}"
				;;
			esac
		fi
	done <"$md_file"

	if [[ -z "$model_tier" || -z "$model_full" ]]; then
		return 1
	fi

	printf 'model_full=%s\nmodel_tier=%s\nmodel_fallback=%s\n' \
		"$model_full" "$model_tier" "$model_fallback"
	return 0
}

# Upsert a single subagent model file into the subagent_models table.
# Arguments: md_file basename_file updated_ref
# Increments the named counter variable via eval on success.
_sync_subagent_file() {
	local md_file="$1"
	local basename_file="$2"
	local updated_ref="$3"

	local frontmatter
	frontmatter=$(_parse_subagent_frontmatter "$md_file") || return 0

	local model_full model_tier model_fallback
	model_full=$(echo "$frontmatter" | grep '^model_full=' | cut -d= -f2-)
	model_tier=$(echo "$frontmatter" | grep '^model_tier=' | cut -d= -f2-)
	model_fallback=$(echo "$frontmatter" | grep '^model_fallback=' | cut -d= -f2-)

	# Extract short model_id from full ID (e.g., anthropic/claude-sonnet-4-6 -> claude-sonnet-4-6)
	local model_short
	model_short="${model_full#*/}"
	# Strip trailing date suffix (e.g., -20250514)
	model_short="${model_short%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"

	local norm_name
	norm_name=$(normalize_model_name "$model_full")

	db_query "
        INSERT INTO subagent_models (tier, model_id, model_full_id, normalized_name, fallback_id, subagent_file, last_synced)
        VALUES (
            '$(sql_escape "$model_tier")',
            '$(sql_escape "$model_short")',
            '$(sql_escape "$model_full")',
            '$(sql_escape "$norm_name")',
            '$(sql_escape "$model_fallback")',
            '$(sql_escape "$basename_file")',
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        )
        ON CONFLICT(tier) DO UPDATE SET
            model_id = excluded.model_id,
            model_full_id = excluded.model_full_id,
            normalized_name = excluded.normalized_name,
            fallback_id = excluded.fallback_id,
            subagent_file = excluded.subagent_file,
            last_synced = excluded.last_synced;
    " && eval "${updated_ref}=\$(( ${updated_ref} + 1 ))"
	return 0
}

sync_subagents() {
	local added=0
	local updated=0

	if [[ ! -d "$MODELS_DIR" ]]; then
		print_warning "Models directory not found: $MODELS_DIR"
		return 0
	fi

	local md_file
	for md_file in "$MODELS_DIR"/*.md; do
		[[ ! -f "$md_file" ]] && continue
		local basename_file
		basename_file=$(basename "$md_file")

		# Skip README and non-model files
		[[ "$basename_file" == "README.md" ]] && continue
		[[ "$basename_file" == *"-reviewer.md" ]] && continue

		_sync_subagent_file "$md_file" "$basename_file" updated
	done

	# Log sync
	db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('subagents', 'frontmatter', $added, $updated, 'Synced from $MODELS_DIR');
    "

	print_info "Subagent sync: $updated tiers updated from frontmatter"
	return 0
}

# =============================================================================
# Sync: Embedded Model Data (from compare-models-helper.sh)
# =============================================================================

# Extract the MODEL_DATA block from compare-models-helper.sh.
# Outputs the raw pipe-delimited lines to stdout; returns 1 if not found.
_extract_model_data() {
	local compare_helper="$1"
	local model_data=""
	local in_model_data=false
	while IFS= read -r line; do
		if [[ "$line" == 'readonly MODEL_DATA="'* ]]; then
			in_model_data=true
			model_data="${line#*=\"}"
			if [[ "$model_data" == *'"' ]]; then
				model_data="${model_data%\"}"
				break
			fi
			continue
		fi
		if [[ "$in_model_data" == "true" ]]; then
			if [[ "$line" == *'"' ]]; then
				model_data="${model_data}
${line%\"}"
				break
			fi
			model_data="${model_data}
${line}"
		fi
	done <"$compare_helper"

	if [[ -z "$model_data" ]]; then
		return 1
	fi
	printf '%s\n' "$model_data"
	return 0
}

# Upsert a single pipe-delimited model line into the models table.
# Arguments: <pipe-delimited line> <added_var_name> <updated_var_name>
# Increments the named counter variables via eval.
_upsert_embedded_model() {
	local line="$1"
	local added_ref="$2"
	local updated_ref="$3"

	local model_id provider display_name ctx input output tier caps best_for
	model_id=$(echo "$line" | cut -d'|' -f1)
	provider=$(echo "$line" | cut -d'|' -f2)
	display_name=$(echo "$line" | cut -d'|' -f3)
	ctx=$(echo "$line" | cut -d'|' -f4)
	input=$(echo "$line" | cut -d'|' -f5)
	output=$(echo "$line" | cut -d'|' -f6)
	tier=$(echo "$line" | cut -d'|' -f7)
	caps=$(echo "$line" | cut -d'|' -f8)
	best_for=$(echo "$line" | cut -d'|' -f9)

	local norm_name
	norm_name=$(normalize_model_name "$model_id")

	local existing
	existing=$(db_query "SELECT model_id FROM models WHERE model_id='$(sql_escape "$model_id")' AND provider='$(sql_escape "$provider")';")

	if [[ -n "$existing" ]]; then
		db_query "
            UPDATE models SET
                display_name = '$(sql_escape "$display_name")',
                normalized_name = '$(sql_escape "$norm_name")',
                context_window = $ctx,
                input_price = $input,
                output_price = $output,
                tier = '$(sql_escape "$tier")',
                capabilities = '$(sql_escape "$caps")',
                best_for = '$(sql_escape "$best_for")',
                last_seen = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                source = 'embedded'
            WHERE model_id = '$(sql_escape "$model_id")' AND provider = '$(sql_escape "$provider")';
        "
		eval "${updated_ref}=\$(( ${updated_ref} + 1 ))"
	else
		db_query "
            INSERT INTO models (model_id, provider, display_name, normalized_name, context_window, input_price, output_price, tier, capabilities, best_for, source)
            VALUES (
                '$(sql_escape "$model_id")',
                '$(sql_escape "$provider")',
                '$(sql_escape "$display_name")',
                '$(sql_escape "$norm_name")',
                $ctx, $input, $output,
                '$(sql_escape "$tier")',
                '$(sql_escape "$caps")',
                '$(sql_escape "$best_for")',
                'embedded'
            );
        "
		eval "${added_ref}=\$(( ${added_ref} + 1 ))"
	fi
	return 0
}

sync_embedded() {
	local added=0
	local updated=0

	local compare_helper="${SCRIPT_DIR}/compare-models-helper.sh"
	if [[ ! -f "$compare_helper" ]]; then
		print_warning "compare-models-helper.sh not found"
		return 0
	fi

	local model_data
	if ! model_data=$(_extract_model_data "$compare_helper"); then
		print_warning "Could not extract MODEL_DATA from compare-models-helper.sh"
		return 0
	fi

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		_upsert_embedded_model "$line" added updated
	done <<<"$model_data"

	db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('embedded', 'compare-models-helper.sh', $added, $updated, 'Parsed MODEL_DATA');
    "

	print_info "Embedded sync: $added added, $updated updated from compare-models-helper.sh"
	return 0
}

# =============================================================================
# Sync: OpenCode Models (preferred — uses opencode CLI model registry)
# =============================================================================
# OpenCode maintains a model registry sourced from models.dev that includes
# all providers the user has configured. This is faster and more reliable than
# probing individual provider APIs directly, and works even without direct
# API keys (OpenCode routes through its gateway for opencode/* models).

sync_opencode() {
	local added=0

	# Check if opencode CLI is available
	if ! command -v opencode &>/dev/null; then
		print_info "OpenCode CLI not found, skipping opencode model sync"
		return 0
	fi

	# Try the cached models file first (instant, no network)
	local cache_file="${HOME}/.cache/opencode/models.json"
	local model_ids=""

	# Only extract models from providers we track (avoids processing 2500+ models
	# from the full models.dev registry — we only need ~100 from relevant providers)
	local relevant_providers='["anthropic","openai","google","openrouter","groq","deepseek","opencode"]'

	if [[ -f "$cache_file" && -s "$cache_file" ]]; then
		model_ids=$(jq -r --argjson providers "$relevant_providers" '
            to_entries[] |
            select(.key as $k | $providers | index($k)) |
            .key as $provider |
            .value.models // {} |
            keys[] |
            "\($provider)/\(.)"
        ' "$cache_file" 2>/dev/null) || true
	fi

	# Fallback: use opencode models CLI if cache is empty or missing
	if [[ -z "$model_ids" ]]; then
		print_info "  Cache miss, querying opencode models CLI..."
		model_ids=$(timeout "$DEFAULT_TIMEOUT" opencode models 2>/dev/null |
			grep -E '^(anthropic|openai|google|openrouter|groq|deepseek|opencode)/' | sort) || true
	fi

	if [[ -z "$model_ids" ]]; then
		print_warning "No models discovered from OpenCode"
		return 0
	fi

	# Build batch SQL for all models (much faster than individual queries)
	local sql_batch="BEGIN TRANSACTION;"
	while IFS= read -r full_id; do
		[[ -z "$full_id" ]] && continue
		# Skip non-text models (embeddings, tts, whisper, image-only)
		case "$full_id" in
		*embed* | *tts* | *whisper* | *dall-e* | *moderation* | *image*) continue ;;
		esac

		local provider
		provider="${full_id%%/*}"

		# Normalize provider name to match our conventions
		local norm_provider
		case "$provider" in
		anthropic) norm_provider="Anthropic" ;;
		openai) norm_provider="OpenAI" ;;
		google) norm_provider="Google" ;;
		openrouter) norm_provider="OpenRouter" ;;
		groq) norm_provider="Groq" ;;
		deepseek) norm_provider="DeepSeek" ;;
		opencode) norm_provider="OpenCode" ;;
		*) norm_provider="$provider" ;;
		esac

		sql_batch="${sql_batch}
            INSERT INTO provider_models (model_id, provider, in_registry, in_subagents, discovered_at)
            VALUES (
                '$(sql_escape "$full_id")',
                '$(sql_escape "$norm_provider")',
                0, 0,
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            )
            ON CONFLICT(model_id, provider) DO UPDATE SET
                discovered_at = excluded.discovered_at;"
		added=$((added + 1))
	done <<<"$model_ids"
	sql_batch="${sql_batch} COMMIT;"

	# Execute batch insert
	db_query "$sql_batch"

	db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('opencode', 'opencode-models', $added, 0, 'Discovered from OpenCode model registry');
    "

	print_info "OpenCode sync: $added models discovered"
	return 0
}

# =============================================================================
# Sync: Provider APIs (fallback — direct API key probing)
# =============================================================================
# Falls back to direct API probing when OpenCode CLI is not available.
# Requires individual provider API keys in environment.

# Fetch models JSON from a single provider API using the given key.
# Outputs newline-separated model IDs to stdout; returns 1 on failure.
_fetch_provider_models() {
	local provider="$1"
	local key_value="$2"

	local models_json=""
	case "$provider" in
	Anthropic)
		models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
			-H "x-api-key: ${key_value}" \
			-H "anthropic-version: 2023-06-01" \
			"https://api.anthropic.com/v1/models" 2>/dev/null) || return 1
		;;
	OpenAI)
		models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.openai.com/v1/models" 2>/dev/null) || return 1
		;;
	Google)
		models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
			"https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null) || return 1
		;;
	OpenRouter)
		models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
			-H "Authorization: Bearer ${key_value}" \
			"https://openrouter.ai/api/v1/models" 2>/dev/null) || return 1
		;;
	Groq)
		models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.groq.com/openai/v1/models" 2>/dev/null) || return 1
		;;
	DeepSeek)
		models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.deepseek.com/v1/models" 2>/dev/null) || return 1
		;;
	*)
		return 1
		;;
	esac

	[[ -z "$models_json" ]] && return 1

	case "$provider" in
	Google)
		echo "$models_json" | jq -r '.models[].name // empty' 2>/dev/null | sed 's|^models/||' | sort || return 1
		;;
	*)
		echo "$models_json" | jq -r '.data[].id // empty' 2>/dev/null | sort || return 1
		;;
	esac
	return 0
}

# Upsert a single model ID into provider_models for the given provider.
_upsert_provider_model() {
	local mid="$1"
	local provider="$2"

	local in_registry
	in_registry=$(db_query "SELECT COUNT(*) FROM models WHERE model_id LIKE '%$(sql_escape "$mid")%' AND provider='$(sql_escape "$provider")';")
	local in_reg_flag=0
	[[ "$in_registry" -gt 0 ]] && in_reg_flag=1

	local in_subagents
	in_subagents=$(db_query "SELECT COUNT(*) FROM subagent_models WHERE model_full_id LIKE '%$(sql_escape "$mid")%';")
	local in_sub_flag=0
	[[ "$in_subagents" -gt 0 ]] && in_sub_flag=1

	db_query "
        INSERT INTO provider_models (model_id, provider, in_registry, in_subagents, discovered_at)
        VALUES (
            '$(sql_escape "$mid")',
            '$(sql_escape "$provider")',
            $in_reg_flag,
            $in_sub_flag,
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        )
        ON CONFLICT(model_id, provider) DO UPDATE SET
            in_registry = excluded.in_registry,
            in_subagents = excluded.in_subagents,
            discovered_at = excluded.discovered_at;
    "
	return 0
}

sync_providers() {
	local added=0

	# Skip if opencode sync already ran successfully (check sync_log)
	local opencode_synced
	opencode_synced=$(db_query "
        SELECT models_added FROM sync_log
        WHERE sync_type = 'opencode'
        AND (julianday('now') - julianday(timestamp)) * 86400 < 60
        ORDER BY id DESC LIMIT 1;
    " 2>/dev/null || echo "")

	if [[ -n "$opencode_synced" && "$opencode_synced" -gt 0 ]]; then
		print_info "Skipping direct API probing (OpenCode sync already discovered $opencode_synced models)"
		return 0
	fi

	local provider_env_keys="Anthropic|ANTHROPIC_API_KEY
OpenAI|OPENAI_API_KEY
Google|GOOGLE_API_KEY,GEMINI_API_KEY
OpenRouter|OPENROUTER_API_KEY
Groq|GROQ_API_KEY
DeepSeek|DEEPSEEK_API_KEY"

	while IFS= read -r pline; do
		local provider key_names
		provider=$(echo "$pline" | cut -d'|' -f1)
		key_names=$(echo "$pline" | cut -d'|' -f2)

		local key_value=""
		local -a keys
		IFS=',' read -ra keys <<<"$key_names"
		for key_name in "${keys[@]}"; do
			if [[ -n "${!key_name:-}" ]]; then
				key_value="${!key_name}"
				break
			fi
		done

		[[ -z "$key_value" ]] && continue

		local model_ids=""
		model_ids=$(_fetch_provider_models "$provider" "$key_value") || continue
		[[ -z "$model_ids" ]] && continue

		local provider_count=0
		while IFS= read -r mid; do
			[[ -z "$mid" ]] && continue
			_upsert_provider_model "$mid" "$provider"
			provider_count=$((provider_count + 1))
		done <<<"$model_ids"

		added=$((added + provider_count))
		print_info "  $provider: $provider_count models discovered"
	done <<<"$provider_env_keys"

	db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('provider_api', 'live', $added, 0, 'Discovered from provider APIs');
    "

	print_info "Provider sync: $added total models discovered from APIs"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_sync() {
	local force=false
	local quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		*) shift ;;
		esac
	done

	# Check if sync is needed
	if [[ "$force" != "true" ]]; then
		local last_sync
		last_sync=$(db_query "SELECT timestamp FROM sync_log ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
		if [[ -n "$last_sync" ]]; then
			local last_epoch now_epoch
			if [[ "$(uname)" == "Darwin" ]]; then
				last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_sync" "+%s" 2>/dev/null || echo "0")
			else
				last_epoch=$(date -d "$last_sync" "+%s" 2>/dev/null || echo "0")
			fi
			now_epoch=$(date "+%s")
			local age=$((now_epoch - last_epoch))
			if [[ $age -lt $SYNC_INTERVAL ]]; then
				local hours_ago=$((age / 3600))
				[[ "$quiet" != "true" ]] && print_info "Registry synced ${hours_ago}h ago (interval: $((SYNC_INTERVAL / 3600))h). Use --force to resync."
				return 0
			fi
		fi
	fi

	[[ "$quiet" != "true" ]] && echo ""
	[[ "$quiet" != "true" ]] && echo "Model Registry Sync"
	[[ "$quiet" != "true" ]] && echo "==================="
	[[ "$quiet" != "true" ]] && echo ""

	# Backup before sync
	if [[ -f "$REGISTRY_DB" ]]; then
		backup_sqlite_db "$REGISTRY_DB" "pre-sync" >/dev/null 2>&1 || true
	fi

	# Phase 1: Sync subagent frontmatter
	[[ "$quiet" != "true" ]] && print_info "Phase 1: Syncing subagent frontmatter..."
	sync_subagents

	# Phase 2: Sync embedded model data
	[[ "$quiet" != "true" ]] && print_info "Phase 2: Syncing embedded model data..."
	sync_embedded

	# Phase 3: Sync from OpenCode model registry (preferred — fast, no API keys needed)
	[[ "$quiet" != "true" ]] && print_info "Phase 3: Discovering models from OpenCode registry..."
	sync_opencode

	# Phase 4: Fallback to direct provider API probing (skipped if Phase 3 succeeded)
	[[ "$quiet" != "true" ]] && print_info "Phase 4: Direct provider API discovery (fallback)..."
	sync_providers

	# Cleanup old backups
	cleanup_sqlite_backups "$REGISTRY_DB" 3

	[[ "$quiet" != "true" ]] && echo ""
	[[ "$quiet" != "true" ]] && print_success "Registry sync complete"
	return 0
}

cmd_list() {
	local json_flag=false
	local filter_provider=""
	local filter_tier=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		--provider)
			filter_provider="${2:-}"
			shift 2
			;;
		--tier)
			filter_tier="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local where_clause="WHERE 1=1"
	[[ -n "$filter_provider" ]] && where_clause="$where_clause AND provider='$(sql_escape "$filter_provider")'"
	[[ -n "$filter_tier" ]] && where_clause="$where_clause AND tier='$(sql_escape "$filter_tier")'"

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "
            SELECT model_id, provider, display_name, context_window, input_price, output_price,
                   tier, capabilities, status, deprecated, last_seen
            FROM models $where_clause
            ORDER BY provider, input_price;
        "
		return $?
	fi

	echo ""
	echo "Model Registry"
	echo "=============="
	echo ""

	local count
	count=$(db_query "SELECT COUNT(*) FROM models $where_clause;")

	if [[ "$count" -eq 0 ]]; then
		print_warning "Registry is empty. Run 'model-registry-helper.sh sync' first."
		return 0
	fi

	printf "%-24s %-10s %-8s %-10s %-10s %-7s %-8s\n" \
		"Model" "Provider" "Context" "In/1M" "Out/1M" "Tier" "Status"
	printf "%-24s %-10s %-8s %-10s %-10s %-7s %-8s\n" \
		"-----" "--------" "-------" "-----" "------" "----" "------"

	db_query "
        SELECT model_id, provider, context_window, input_price, output_price, tier, status, deprecated
        FROM models $where_clause
        ORDER BY provider, input_price;
    " | while IFS='|' read -r mid prov ctx inp outp tier stat dep; do
		local ctx_fmt
		if [[ "$ctx" -ge 1000000 ]]; then
			ctx_fmt="1M"
		elif [[ "$ctx" -ge 500000 ]]; then
			ctx_fmt="512K"
		elif [[ "$ctx" -ge 200000 ]]; then
			ctx_fmt="200K"
		elif [[ "$ctx" -ge 128000 ]]; then
			ctx_fmt="128K"
		else
			ctx_fmt="${ctx}"
		fi

		local status_display="$stat"
		[[ "$dep" == "1" ]] && status_display="DEPR"

		printf "%-24s %-10s %-8s \$%-9s \$%-9s %-7s %-8s\n" \
			"$mid" "$prov" "$ctx_fmt" "$inp" "$outp" "$tier" "$status_display"
	done

	echo ""
	echo "Total: $count models"
	return 0
}

cmd_status() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$REGISTRY_DB" ]]; then
		print_warning "Registry not initialized. Run 'model-registry-helper.sh sync' first."
		return 0
	fi

	local total_models total_providers total_subagents total_provider_models
	local last_sync deprecated_count

	total_models=$(db_query "SELECT COUNT(*) FROM models;")
	total_providers=$(db_query "SELECT COUNT(DISTINCT provider) FROM models;")
	total_subagents=$(db_query "SELECT COUNT(*) FROM subagent_models;")
	total_provider_models=$(db_query "SELECT COUNT(*) FROM provider_models;")
	deprecated_count=$(db_query "SELECT COUNT(*) FROM models WHERE deprecated=1;")
	last_sync=$(db_query "SELECT timestamp FROM sync_log ORDER BY id DESC LIMIT 1;" || echo "never")

	# Calculate staleness
	local staleness="unknown"
	if [[ -n "$last_sync" && "$last_sync" != "never" ]]; then
		local last_epoch now_epoch
		if [[ "$(uname)" == "Darwin" ]]; then
			last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_sync" "+%s" 2>/dev/null || echo "0")
		else
			last_epoch=$(date -d "$last_sync" "+%s" 2>/dev/null || echo "0")
		fi
		now_epoch=$(date "+%s")
		local age=$((now_epoch - last_epoch))
		if [[ $age -lt 3600 ]]; then
			staleness="fresh ($((age / 60))m ago)"
		elif [[ $age -lt 86400 ]]; then
			staleness="recent ($((age / 3600))h ago)"
		else
			staleness="stale ($((age / 86400))d ago)"
		fi
	fi

	if [[ "$json_flag" == "true" ]]; then
		echo "{\"total_models\":$total_models,\"total_providers\":$total_providers,\"subagent_tiers\":$total_subagents,\"provider_models_discovered\":$total_provider_models,\"deprecated\":$deprecated_count,\"last_sync\":\"$last_sync\",\"staleness\":\"$staleness\"}"
		return 0
	fi

	echo ""
	echo "Model Registry Status"
	echo "====================="
	echo ""
	echo "  Registry models:     $total_models"
	echo "  Providers:           $total_providers"
	echo "  Subagent tiers:      $total_subagents"
	echo "  API-discovered:      $total_provider_models"
	echo "  Deprecated:          $deprecated_count"
	echo "  Last sync:           ${last_sync:-never}"
	echo "  Staleness:           $staleness"
	echo ""

	# Show subagent tier mapping
	echo "Subagent Tier Mapping:"
	echo ""
	printf "  %-8s %-24s %-36s %-24s\n" "Tier" "Model" "Full ID" "Fallback"
	printf "  %-8s %-24s %-36s %-24s\n" "----" "-----" "-------" "--------"

	db_query "SELECT tier, model_id, model_full_id, fallback_id FROM subagent_models ORDER BY tier;" |
		while IFS='|' read -r tier mid full_id fallback; do
			printf "  %-8s %-24s %-36s %-24s\n" "$tier" "$mid" "$full_id" "$fallback"
		done

	echo ""

	# Show recent sync log
	echo "Recent Sync History:"
	echo ""
	db_query "
        SELECT timestamp, sync_type, source, models_added, models_updated
        FROM sync_log ORDER BY id DESC LIMIT 5;
    " | while IFS='|' read -r ts stype src added updated; do
		echo "  $ts  $stype ($src): +$added ~$updated"
	done

	echo ""
	return 0
}

cmd_check() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Model Availability Check"
	echo "========================"
	echo ""

	# Check each subagent model against provider APIs
	local issues=0

	db_query "SELECT tier, model_id, model_full_id, fallback_id FROM subagent_models;" |
		while IFS='|' read -r tier mid full_id fallback; do
			local provider
			provider=$(echo "$full_id" | cut -d'/' -f1)

			# Get normalized name for this subagent model
			local norm_name
			norm_name=$(db_query "SELECT normalized_name FROM subagent_models WHERE tier='$(sql_escape "$tier")';" 2>/dev/null || echo "")
			[[ -z "$norm_name" ]] && norm_name=$(normalize_model_name "$full_id")

			# Check if model exists in provider_models (try both directions for fuzzy match)
			local found
			found=$(db_query "
            SELECT COUNT(*) FROM provider_models
            WHERE (model_id LIKE '%$(sql_escape "$mid")%'
                   OR '$(sql_escape "$mid")' LIKE '%' || model_id || '%')
            AND provider LIKE '%$(sql_escape "$provider")%';
        " 2>/dev/null || echo "0")

			local status_icon="Y"
			local status_text="available"

			if [[ "$found" -eq 0 ]]; then
				# Not found in API discovery - check embedded registry via normalized name
				local in_embedded
				in_embedded=$(db_query "
                SELECT COUNT(*) FROM models
                WHERE normalized_name = '$(sql_escape "$norm_name")'
                   OR model_id LIKE '%$(sql_escape "$mid")%'
                   OR '$(sql_escape "$mid")' LIKE '%' || model_id || '%';
            " 2>/dev/null || echo "0")

				if [[ "$in_embedded" -gt 0 ]]; then
					status_icon="?"
					status_text="in registry, not verified via API"
				else
					status_icon="!"
					status_text="NOT FOUND in registry or API"
					issues=$((issues + 1))
				fi
			fi

			printf "  %s %-8s %-36s %s\n" "$status_icon" "$tier" "$full_id" "$status_text"
		done

	echo ""
	if [[ $issues -gt 0 ]]; then
		print_warning "$issues model(s) have availability issues"
	else
		print_success "All configured models appear available"
	fi
	echo ""
	return 0
}

cmd_suggest() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Model Suggestions"
	echo "================="
	echo ""
	echo "Models discovered from provider APIs but not in the registry:"
	echo ""

	local count=0
	db_query "
        SELECT pm.model_id, pm.provider, pm.discovered_at
        FROM provider_models pm
        WHERE pm.in_registry = 0
        AND pm.in_subagents = 0
        ORDER BY pm.provider, pm.model_id;
    " | while IFS='|' read -r mid prov discovered; do
		# Filter to interesting models (skip internal/deprecated-looking ones)
		case "$mid" in
		*embed* | *tts* | *whisper* | *dall-e* | *moderation* | *babbage* | *davinci-00* | *search* | *instruct* | *realtime*)
			continue
			;;
		esac
		echo "  [$prov] $mid (discovered: $discovered)"
		count=$((count + 1))
	done

	echo ""
	if [[ $count -eq 0 ]]; then
		print_info "No new model suggestions. Registry is up to date."
	else
		echo "  $count potential models found."
		echo "  Review and add relevant ones to compare-models-helper.sh MODEL_DATA"
		echo "  and create subagent files in $MODELS_DIR/ as needed."
	fi
	echo ""
	return 0
}

cmd_deprecations() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Deprecated/Unavailable Models"
	echo "============================="
	echo ""

	local dep_count
	dep_count=$(db_query "SELECT COUNT(*) FROM models WHERE deprecated=1;")

	if [[ "$dep_count" -eq 0 ]]; then
		print_info "No deprecated models found in registry."
		echo ""

		# Check for models in subagents that aren't in provider APIs
		echo "Models in subagents not confirmed by provider APIs:"
		echo ""
		local unconfirmed=0
		db_query "SELECT tier, model_id, model_full_id FROM subagent_models;" |
			while IFS='|' read -r tier mid full_id; do
				local short_id
				short_id="${full_id#*/}"
				local api_found
				api_found=$(db_query "
                SELECT COUNT(*) FROM provider_models
                WHERE model_id = '$(sql_escape "$short_id")';
            " 2>/dev/null || echo "0")

				if [[ "$api_found" -eq 0 ]]; then
					echo "  ! [$tier] $full_id - not found in API discovery"
					unconfirmed=$((unconfirmed + 1))
				fi
			done

		if [[ $unconfirmed -eq 0 ]]; then
			print_info "  All subagent models confirmed via API discovery."
		fi
	else
		db_query "
            SELECT model_id, provider, deprecation_note, last_seen
            FROM models WHERE deprecated=1
            ORDER BY provider, model_id;
        " | while IFS='|' read -r mid prov note last; do
			echo "  ! $mid ($prov)"
			[[ -n "$note" ]] && echo "    Note: $note"
			echo "    Last seen: $last"
		done
	fi

	echo ""
	return 0
}

cmd_diff() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Registry vs Local Config Diff"
	echo "=============================="
	echo ""

	# Compare subagent models with registry
	echo "Subagent Models vs Registry:"
	echo ""

	db_query "SELECT tier, model_id, model_full_id, normalized_name FROM subagent_models;" |
		while IFS='|' read -r tier mid full_id norm_name; do
			[[ -z "$norm_name" ]] && norm_name=$(normalize_model_name "$full_id")
			local reg_match
			reg_match=$(db_query "
            SELECT model_id, input_price, output_price
            FROM models
            WHERE normalized_name = '$(sql_escape "$norm_name")'
               OR model_id LIKE '%$(sql_escape "$mid")%'
               OR '$(sql_escape "$mid")' LIKE '%' || model_id || '%'
            LIMIT 1;
        " 2>/dev/null || echo "")

			if [[ -n "$reg_match" ]]; then
				local reg_id reg_input reg_output
				reg_id=$(echo "$reg_match" | cut -d'|' -f1)
				reg_input=$(echo "$reg_match" | cut -d'|' -f2)
				reg_output=$(echo "$reg_match" | cut -d'|' -f3)
				printf "  = %-8s %-24s (registry: %s, \$%s/\$%s)\n" \
					"$tier" "$full_id" "$reg_id" "$reg_input" "$reg_output"
			else
				printf "  ! %-8s %-24s (NOT in registry)\n" "$tier" "$full_id"
			fi
		done

	echo ""

	# Show registry models not in subagents
	echo "Registry Models Not in Subagents:"
	echo ""

	local orphan_count=0
	db_query "
        SELECT m.model_id, m.provider, m.tier
        FROM models m
        WHERE NOT EXISTS (
            SELECT 1 FROM subagent_models s
            WHERE m.normalized_name = s.normalized_name
               OR m.model_id LIKE '%' || s.model_id || '%'
               OR s.model_id LIKE '%' || m.model_id || '%'
        )
        ORDER BY m.provider, m.model_id;
    " | while IFS='|' read -r mid prov tier; do
		printf "  + %-24s %-10s %-7s\n" "$mid" "$prov" "$tier"
		orphan_count=$((orphan_count + 1))
	done

	echo ""
	return 0
}

cmd_export() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--csv)
			format="csv"
			shift
			;;
		*) shift ;;
		esac
	done

	case "$format" in
	csv)
		db_query_csv "
                SELECT model_id, provider, display_name, context_window,
                       input_price, output_price, tier, capabilities,
                       best_for, status, deprecated, last_seen
                FROM models ORDER BY provider, model_id;
            "
		;;
	*)
		db_query_json "
                SELECT model_id, provider, display_name, context_window,
                       input_price, output_price, tier, capabilities,
                       best_for, status, deprecated, last_seen
                FROM models ORDER BY provider, model_id;
            "
		;;
	esac
	return $?
}

# Classify a task description into a canonical workload tier.
# This deterministic fallback recognizes only high-confidence language; richer
# issue classification remains model judgment under reference/task-taxonomy.md.
# Sets variables tier, reason, compute in the caller's scope via eval.
# Arguments: <desc_lower>
_route_classify_tier() {
	local desc_lower="$1"
	local out_tier="$2"
	local out_reason="$3"
	local out_compute="$4"

	local _route_tier_value="standard"
	local _route_reason_value="Default tier for general development tasks"
	local _route_compute_value="balanced"
	local _route_has_exact_transform=0
	local _route_has_unresolved_choice=0
	local _route_has_sensitive_effect=0
	local _route_sensitive_confined_to_non_effective_context=0

	if printf '%s\n' "$desc_lower" | grep -qE 'oldstring.*newstring|apply.*(provided|exact).*verbatim|exact[[:space:]_.-]*(replacement|transform|edit)|rename[[:space:]]+[^[:space:]]+[[:space:]]+to[[:space:]]+[^[:space:]]+|replace[[:space:]]+[^[:space:]]+[[:space:]]+with[[:space:]]+[^[:space:]]+'; then
		_route_has_exact_transform=1
	fi
	if printf '%s\n' "$desc_lower" | grep -qE 'decid(e|ing)|design|choose|recommend|investigat|debug|diagnos|evaluate|compare|coordinate|fallback|retry|error[[:space:]_.-]*handling|conditional|compatib|migration|rollback'; then
		_route_has_unresolved_choice=1
	fi
	if printf '%s\n' "$desc_lower" | grep -qE 'production|auth(entication|orization)?|permission|access[[:space:]_.-]*control|trust[[:space:]_.-]*boundar|secret|credential|crypt|privacy|egress|billing|destructive|delete.*data'; then
		_route_has_sensitive_effect=1
	fi
	# A security-adjacent exact transform is simple only when the operation itself
	# is confined to one non-effective artifact. An unrelated fixture/docs mention
	# must not launder a production change into the simple tier.
	if printf '%s\n' "$desc_lower" | grep -qE '(in|within|inside|for)[[:space:]_.-]+((a|an|the)[[:space:]_.-]+)?([[:alnum:]_-]+[[:space:]_.-]+){0,2}(test[[:space:]_.-]*(fixture|data)|mock([[:space:]_.-]*data)?|documentation|docs|comment|example|sample|identifier)[[:space:][:punct:]]*$' &&
		! printf '%s\n' "$desc_lower" | grep -qE '[,;]|(^|[[:space:]])(and|also|plus)([[:space:]]|$)|production|runtime|middleware|handler|controller|service|endpoint|database|deployment|live[[:space:]_.-]*(system|app|code|data)|application|source[[:space:]_.-]*code|policy|config(uration)?'; then
		_route_sensitive_confined_to_non_effective_context=1
	fi

	# Thinking wins when the description explicitly names consequential unresolved
	# design/synthesis work. A security noun alone does not trigger this branch.
	if printf '%s\n' "$desc_lower" | grep -qE 'architect(ure|ural)?|system[[:space:]_.-]*design|security[[:space:]_.-]*audit|threat[[:space:]_.-]*model|trust[[:space:]_.-]*boundar|novel[[:space:]_.-]*(design|approach|solution)|trade[[:space:]_.-]*off|from[[:space:]_.-]*scratch|migration[[:space:]_.-]*strategy|refactor.*(entire|full)[[:space:]_.-]*(project|repo|codebase)|cross[[:space:]_.-]*(system|service).*decision|evaluate.*(architecture|approach|trade)'; then
		_route_tier_value="thinking"
		_route_reason_value="Consequential architecture, trust-boundary, novelty, or synthesis decision is explicit"
		_route_compute_value="higher"
	# Simple requires explicit evidence of a deterministic bounded transform.
	elif [[ "$_route_has_exact_transform" -eq 1 &&
		"$_route_has_unresolved_choice" -eq 0 &&
		("$_route_has_sensitive_effect" -eq 0 || "$_route_sensitive_confined_to_non_effective_context" -eq 1) ]]; then
		_route_tier_value="simple"
		_route_reason_value="Exact bounded transform is supplied with no decision language"
		_route_compute_value="lower"
	# Pure single-artifact processing is simple only when no recommendation or
	# cross-source synthesis is requested.
	elif printf '%s\n' "$desc_lower" | grep -qE '^(summari[sz]e|format|extract)[[:space:]]+(this|the)[[:space:]]+(single[[:space:]]+)?(document|file|text)([[:space:]]+without[[:space:]]+recommendations)?[[:space:]]*$'; then
		_route_tier_value="simple"
		_route_reason_value="Single-artifact transform has no recommendation or synthesis requirement"
		_route_compute_value="lower"
	fi

	eval "${out_tier}=\"\${_route_tier_value}\""
	eval "${out_reason}=\"\${_route_reason_value}\""
	eval "${out_compute}=\"\${_route_compute_value}\""
	return 0
}

# Look up primary and fallback models for a tier from the registry.
# Falls back to hardcoded defaults when the registry is empty.
# Sets primary_model and fallback_model in the caller's scope via eval.
_route_lookup_models() {
	local tier="$1"
	local out_primary="$2"
	local out_fallback="$3"

	local primary_model=""
	local fallback_model=""
	primary_model=$(db_query "SELECT model_id FROM models WHERE tier = '$tier' AND is_primary = 1 LIMIT 1;" 2>/dev/null || echo "")
	fallback_model=$(db_query "SELECT model_id FROM models WHERE tier = '$tier' AND is_fallback = 1 LIMIT 1;" 2>/dev/null || echo "")

	case "$tier" in
	simple)
		primary_model="${primary_model:-openai/gpt-5.6-terra}"
		fallback_model="${fallback_model:-anthropic/claude-haiku-4-5}"
		;;
	standard)
		primary_model="${primary_model:-openai/gpt-5.6-luna}"
		fallback_model="${fallback_model:-anthropic/claude-sonnet-4-6}"
		;;
	thinking)
		primary_model="${primary_model:-openai/gpt-5.6-sol}"
		fallback_model="${fallback_model:-anthropic/claude-opus-4-6}"
		;;
	esac

	eval "${out_primary}=\"\${primary_model}\""
	eval "${out_fallback}=\"\${fallback_model}\""
	return 0
}

# Print the routing result in human-readable or JSON format.
_route_output() {
	local json_flag="$1"
	local description="$2"
	local tier="$3"
	local primary_model="$4"
	local fallback_model="$5"
	local compute="$6"
	local reason="$7"

	if [[ "$json_flag" == "true" ]]; then
		printf '{"tier":"%s","model":"%s","fallback":"%s","compute":"%s","reason":"%s"}\n' \
			"$tier" "$primary_model" "$fallback_model" "$compute" "$reason"
	else
		echo ""
		echo "Task: $description"
		echo ""
		echo "  Recommended tier:  $tier"
		echo "  Primary model:     $primary_model"
		echo "  Fallback model:    $fallback_model"
		echo "  Compute profile:   $compute"
		echo "  Reason:            $reason"
		echo ""
	fi
	return 0
}

cmd_route() {
	local description="$*"
	local json_flag=false

	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done
	description="${args[*]}"

	if [[ -z "$description" ]]; then
		echo ""
		echo "Usage: model-registry-helper.sh route <task description>"
		echo ""
		echo "Examples:"
		echo "  model-registry-helper.sh route 'rename variable_x to variable_y'"
		echo "  model-registry-helper.sh route 'design auth system architecture'"
		echo "  model-registry-helper.sh route 'summarize this document without recommendations'"
		echo ""
		return 1
	fi

	local desc_lower
	desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

	local tier reason compute
	_route_classify_tier "$desc_lower" tier reason compute

	local primary_model fallback_model
	_route_lookup_models "$tier" primary_model fallback_model

	_route_output "$json_flag" "$description" "$tier" "$primary_model" "$fallback_model" "$compute" "$reason"
	return 0
}

cmd_help() {
	echo ""
	echo "Model Registry Helper - Provider/Model Registry with Periodic Sync"
	echo "==================================================================="
	echo ""
	echo "Usage: model-registry-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  sync          Sync registry from all sources (subagents, embedded data, APIs)"
	echo "  list          List all models in the registry"
	echo "  status        Show registry health, staleness, and tier mapping"
	echo "  check         Check configured subagent models against registry/APIs"
	echo "  suggest       Suggest new models discovered from APIs but not tracked"
	echo "  deprecations  Show deprecated/renamed/unavailable models"
	echo "  diff          Show differences between registry and local config"
	echo "  route <desc>  Recommend optimal model tier for a task description"
	echo "  export        Export registry data (JSON or CSV)"
	echo "  help          Show this help"
	echo ""
	echo "Options:"
	echo "  --json        Output in JSON format (list, status, export)"
	echo "  --quiet       Suppress informational output (sync)"
	echo "  --force       Force full resync even if cache is fresh (sync)"
	echo "  --provider X  Filter by provider name (list)"
	echo "  --tier X      Filter by tier (list)"
	echo "  --csv         Export as CSV instead of JSON (export)"
	echo ""
	echo "Examples:"
	echo "  model-registry-helper.sh sync                    # Full sync"
	echo "  model-registry-helper.sh sync --force            # Force resync"
	echo "  model-registry-helper.sh list                    # List all models"
	echo "  model-registry-helper.sh list --provider Google  # Google models only"
	echo "  model-registry-helper.sh status                  # Registry health"
	echo "  model-registry-helper.sh check                   # Verify subagent models"
	echo "  model-registry-helper.sh suggest                 # New model suggestions"
	echo "  model-registry-helper.sh diff                    # Config vs registry"
	echo "  model-registry-helper.sh route 'fix React bug'  # Recommend model tier"
	echo "  model-registry-helper.sh export --json           # Export as JSON"
	echo ""
	echo "Integration:"
	echo "  - Runs automatically on 'aidevops update'"
	echo "  - Can be added to cron for periodic sync"
	echo "  - Storage: $REGISTRY_DB"
	echo ""
	echo "Data Sources:"
	echo "  1. Subagent frontmatter ($MODELS_DIR/*.md)"
	echo "  2. Embedded data (compare-models-helper.sh MODEL_DATA)"
	echo "  3. OpenCode model registry (opencode models — preferred, from models.dev)"
	echo "  4. Provider APIs (Anthropic, OpenAI, Google, OpenRouter, Groq, DeepSeek)"
	echo ""
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Initialize DB for all commands except help
	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		init_db || return 1
	fi

	case "$command" in
	sync)
		cmd_sync "$@"
		;;
	list)
		cmd_list "$@"
		;;
	status)
		cmd_status "$@"
		;;
	check)
		cmd_check "$@"
		;;
	suggest)
		cmd_suggest "$@"
		;;
	deprecations | deprecated)
		cmd_deprecations "$@"
		;;
	diff)
		cmd_diff "$@"
		;;
	route)
		cmd_route "$@"
		;;
	export)
		cmd_export "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
