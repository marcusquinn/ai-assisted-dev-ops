#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Observability Helper — LLM request and runtime-event evidence

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

readonly OBS_DIR="${HOME}/.aidevops/.agent-workspace/observability"
readonly OBS_METRICS="${OBS_DIR}/metrics.jsonl" OBS_OFFSETS="${OBS_DIR}/parse-offsets.json"
readonly CLAUDE_LOG_DIR="${HOME}/.claude/projects"
readonly RATE_LIMITS_CONFIG_USER="${HOME}/.config/aidevops/rate-limits.json"
readonly RATE_LIMITS_CONFIG_TEMPLATE="${SCRIPT_DIR}/../configs/rate-limits.json.txt"
readonly RUNTIME_EVENTS_RETENTION="${SCRIPT_DIR}/runtime-events-retention.mjs"
readonly DEFAULT_WARN_PCT=80 DEFAULT_WINDOW_MINUTES=1

init_storage() {
	mkdir -p "$OBS_DIR" 2>/dev/null || true
	[[ -f "$OBS_METRICS" ]] || touch "$OBS_METRICS"
	[[ -f "$OBS_OFFSETS" ]] || echo '{}' >"$OBS_OFFSETS"
}

get_offset() {
	[[ -f "$OBS_OFFSETS" ]] && command -v jq &>/dev/null || {
		echo "0"
		return 0
	}
	jq -r --arg f "$1" '.[$f] // 0' "$OBS_OFFSETS" 2>/dev/null || echo "0"
}

set_offset() {
	command -v jq &>/dev/null || return 0
	local tmp="${OBS_OFFSETS}.tmp"
	jq --arg f "$1" --argjson o "$2" '.[$f] = $o' "$OBS_OFFSETS" >"$tmp" 2>/dev/null && mv "$tmp" "$OBS_OFFSETS"
}

get_project_from_path() {
	local dir_name
	dir_name=$(basename "$(dirname "$1")")
	local project
	project=$(echo "$dir_name" | sed -E 's/^-Users-[^-]+-Git-//; s/-.*(feature|bugfix|hotfix|chore|refactor|experiment|release)-.*//')
	[[ -z "$project" || "$project" == "-" ]] && project="unknown"
	echo "$project"
}

_calc_costs() {
	local input_tokens="$1" output_tokens="$2" cache_read="$3" cache_write="$4" model="$5"
	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price output_price cr_price cw_price
	IFS='|' read -r input_price output_price cr_price cw_price <<<"$pricing"
	awk "BEGIN {
		ci=$input_tokens/1e6*$input_price; co=$output_tokens/1e6*$output_price
		cr=$cache_read/1e6*$cr_price; cw=$cache_write/1e6*$cw_price
		printf \"%.8f|%.8f|%.8f|%.8f|%.8f\",ci,co,cr,cw,ci+co+cr+cw
	}"
}

# Resolve prompt version from git history for a given file path.
# Returns the short hash of the last commit that touched the file, or empty string.
_resolve_prompt_version() {
	local file_path="$1"
	[[ -z "$file_path" ]] && {
		echo ""
		return 0
	}
	# Try to get the git short hash of the last commit that modified this file
	local version=""
	if command -v git &>/dev/null; then
		version=$(git log -1 --format='%h' -- "$file_path" 2>/dev/null) || version=""
	fi
	echo "$version"
	return 0
}

# Write a metrics entry to the JSONL log.
_write_metric() {
	local provider="$1" model="$2" session_id="$3" request_id="$4" project="$5"
	local input_tokens="$6" output_tokens="$7" cache_read="$8" cache_write="$9"
	local cost_input="${10}" cost_output="${11}" cost_cache_read="${12}" cost_cache_write="${13}" cost_total="${14}"
	local stop_reason="${15}" service_tier="${16}" git_branch="${17}" log_source="${18}" recorded_at="${19}"
	local error_message="${20:-}" prompt_version="${21:-}" prompt_file="${22:-}"
	jq -c -n \
		--arg pv "$provider" --arg md "$model" --arg si "$session_id" --arg ri "$request_id" \
		--arg pj "$project" --argjson it "$input_tokens" --argjson ot "$output_tokens" \
		--argjson cr "$cache_read" --argjson cw "$cache_write" \
		--arg ci "$cost_input" --arg co "$cost_output" --arg ccr "$cost_cache_read" \
		--arg ccw "$cost_cache_write" --arg ct "$cost_total" \
		--arg sr "$stop_reason" --arg st "$service_tier" --arg gb "$git_branch" \
		--arg ls "$log_source" --arg ra "$recorded_at" --arg em "$error_message" \
		--arg pmv "$prompt_version" --arg pmf "$prompt_file" \
		'{provider:$pv, model:$md, session_id:$si, request_id:$ri, project:$pj,
		  input_tokens:$it, output_tokens:$ot, cache_read_tokens:$cr, cache_write_tokens:$cw,
		  cost_input:($ci|tonumber), cost_output:($co|tonumber),
		  cost_cache_read:($ccr|tonumber), cost_cache_write:($ccw|tonumber),
		  cost_total:($ct|tonumber), stop_reason:$sr, service_tier:$st,
		  git_branch:$gb, log_source:$ls, recorded_at:$ra, error_message:$em,
		  prompt_version:$pmv, prompt_file:$pmf}' >>"$OBS_METRICS"
	return 0
}

parse_jsonl_file() {
	local file_path="$1"
	local start_offset="${2:-0}"
	[[ -f "$file_path" ]] || return 0

	local file_size
	file_size=$(wc -c <"$file_path" | tr -d ' ')
	if [[ "$start_offset" -ge "$file_size" ]]; then
		echo "$start_offset"
		return 0
	fi

	local project
	project=$(get_project_from_path "$file_path")

	local parsed_rows
	parsed_rows=$(dd if="$file_path" bs=1 skip="$start_offset" count=$((file_size - start_offset)) 2>/dev/null |
		jq -r 'select(.type == "assistant" and .message.usage != null) |
			[(.message.model // "unknown"), (.sessionId // ""), (.requestId // ""),
			 (.message.usage.input_tokens // 0), (.message.usage.output_tokens // 0),
			 (.message.usage.cache_read_input_tokens // 0),
			 ((.message.usage.cache_creation_input_tokens // 0) +
			  (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) +
			  (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)),
			 (.message.stop_reason // ""), (.timestamp // ""),
			 (.message.usage.service_tier // ""), (.gitBranch // "")] | join("|")
		' 2>/dev/null) || parsed_rows=""

	if [[ -z "$parsed_rows" ]]; then
		set_offset "$file_path" "$file_size"
		echo "$file_size"
		return 0
	fi

	local insert_count=0
	while IFS='|' read -r model sid rid itok otok crtok cwtok sr ts st gb; do
		[[ -z "$model" ]] && continue
		local total=$((itok + otok + crtok + cwtok))
		[[ "$total" -eq 0 ]] && continue

		local provider costs ci co ccr ccw ct
		provider=$(get_provider_from_model "$model")
		costs=$(_calc_costs "$itok" "$otok" "$crtok" "$cwtok" "$model")
		IFS='|' read -r ci co ccr ccw ct <<<"$costs"

		_write_metric "$provider" "$model" "$sid" "$rid" "$project" \
			"$itok" "$otok" "$crtok" "$cwtok" "$ci" "$co" "$ccr" "$ccw" "$ct" \
			"$sr" "$st" "$gb" "$file_path" "$ts"
		insert_count=$((insert_count + 1))
	done <<<"$parsed_rows"

	set_offset "$file_path" "$file_size"
	[[ "$insert_count" -gt 0 ]] && print_info "Parsed $insert_count requests from $(basename "$file_path")"
	echo "$file_size"
	return 0
}

cmd_ingest() {
	local quiet=false
	while [[ $# -gt 0 ]]; do
		case "$1" in --quiet) quiet=true ;; esac
		shift
	done

	# Primary source: OpenCode plugin writes to SQLite DB in real-time.
	# JSONL ingest is legacy (Claude Code transcripts, no longer updated).
	local obs_db="${OBS_DIR}/llm-requests.db"
	if [[ -f "$obs_db" ]] && command -v sqlite3 &>/dev/null; then
		local row_count
		if row_count=$(sqlite3 "$obs_db" "SELECT COUNT(*) FROM llm_requests;" 2>/dev/null); then
			[[ "$quiet" != "true" ]] && print_success "SQLite DB has $row_count rows (real-time via OpenCode plugin)"
			return 0
		fi
		[[ "$quiet" != "true" ]] && print_warning "SQLite DB exists but llm_requests could not be queried; falling back to legacy JSONL ingest"
	fi

	# Legacy fallback: parse Claude Code JSONL transcripts
	[[ -d "$CLAUDE_LOG_DIR" ]] || {
		print_warning "No data sources found. OpenCode plugin SQLite DB not found, Claude log directory not found."
		return 0
	}
	command -v jq &>/dev/null || {
		print_error "jq required. Install: brew install jq"
		return 1
	}

	local files_processed=0
	while IFS= read -r jsonl_file; do
		[[ -z "$jsonl_file" ]] && continue
		local current_offset file_size
		current_offset=$(get_offset "$jsonl_file")
		file_size=$(wc -c <"$jsonl_file" | tr -d ' ')
		[[ "$current_offset" -ge "$file_size" ]] && continue
		parse_jsonl_file "$jsonl_file" "$current_offset" >/dev/null
		files_processed=$((files_processed + 1))
	done < <(find "$CLAUDE_LOG_DIR" -name "*.jsonl" -type f 2>/dev/null)

	[[ "$quiet" != "true" ]] && print_success "Ingestion complete: processed $files_processed files"
	return 0
}

cmd_record() {
	local provider="" model="" input_tokens=0 output_tokens=0 cache_read_tokens=0 cache_write_tokens=0
	local session_id="" project="" stop_reason="" error_message=""
	local prompt_version="" prompt_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="${2:-}"
			shift 2
			;;
		--model)
			model="${2:-}"
			shift 2
			;;
		--input-tokens)
			input_tokens="${2:-0}"
			shift 2
			;;
		--output-tokens)
			output_tokens="${2:-0}"
			shift 2
			;;
		--cache-read)
			cache_read_tokens="${2:-0}"
			shift 2
			;;
		--cache-write)
			cache_write_tokens="${2:-0}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--project)
			project="${2:-}"
			shift 2
			;;
		--stop-reason)
			stop_reason="${2:-}"
			shift 2
			;;
		--error)
			error_message="${2:-}"
			shift 2
			;;
		--prompt-version)
			prompt_version="${2:-}"
			shift 2
			;;
		--prompt-file)
			prompt_file="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	[[ -z "$model" ]] && {
		print_error "Usage: observability-helper.sh record --model X [options]"
		return 1
	}
	[[ -z "$provider" ]] && provider=$(get_provider_from_model "$model")

	# Resolve prompt_version from git if prompt_file is provided and no explicit version
	if [[ -z "$prompt_version" && -n "$prompt_file" ]]; then
		prompt_version=$(_resolve_prompt_version "$prompt_file")
	fi

	local costs ci co ccr ccw ct
	costs=$(_calc_costs "$input_tokens" "$output_tokens" "$cache_read_tokens" "$cache_write_tokens" "$model")
	IFS='|' read -r ci co ccr ccw ct <<<"$costs"

	_write_metric "$provider" "$model" "$session_id" "" "$project" \
		"$input_tokens" "$output_tokens" "$cache_read_tokens" "$cache_write_tokens" \
		"$ci" "$co" "$ccr" "$ccw" "$ct" "$stop_reason" "" "" "" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		"$error_message" "$prompt_version" "$prompt_file"
	print_success "Recorded: $model ($provider) - \$${ct}"
}

_get_rate_limits_config() {
	[[ -f "$RATE_LIMITS_CONFIG_USER" ]] && {
		echo "$RATE_LIMITS_CONFIG_USER"
		return 0
	}
	[[ -f "$RATE_LIMITS_CONFIG_TEMPLATE" ]] && {
		echo "$RATE_LIMITS_CONFIG_TEMPLATE"
		return 0
	}
	return 1
}

# Read a field from rate-limits config. Usage: _rl_jq '.providers[$p][$f]' provider field [default]
_rl_jq() {
	local expr="$1" default="${4:-0}"
	local config_file
	config_file=$(_get_rate_limits_config) || {
		echo "$default"
		return 0
	}
	command -v jq &>/dev/null || {
		echo "$default"
		return 0
	}
	local val
	val=$(jq -r --arg p "${2:-}" --arg f "${3:-}" "$expr // empty" "$config_file" 2>/dev/null) || val=""
	echo "${val:-$default}"
}

# shellcheck disable=SC2016 # $p and $f are jq variable references, not shell variables
_get_rl_field() { _rl_jq '.providers[$p][$f]' "$1" "$2" "0"; }
# shellcheck disable=SC2016 # $f is a jq variable reference, not a shell variable
_get_config_val() { _rl_jq '.[$f]' "" "$1" "$2"; }

_count_usage_in_window() {
	local provider="$1" window_minutes="$2"

	# Prefer SQLite DB (populated by OpenCode plugin in real-time) over JSONL
	local obs_db="${OBS_DIR}/llm-requests.db"
	if [[ -f "$obs_db" ]] && command -v sqlite3 &>/dev/null; then
		local result
		result=$(sqlite3 "$obs_db" "
			SELECT COUNT(*), COALESCE(SUM(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write), 0)
			FROM llm_requests
			WHERE lower(provider_id) = lower('${provider}')
			  AND timestamp > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-${window_minutes} minutes');
		" 2>/dev/null) || result=""
		if [[ -n "$result" ]]; then
			local req_count tok_count
			IFS='|' read -r req_count tok_count <<<"$result"
			echo "${req_count:-0}|${tok_count:-0}"
			return 0
		fi
	fi

	# Fallback to JSONL (legacy — Claude Code transcripts, no longer updated)
	[[ -f "$OBS_METRICS" ]] || {
		echo "0|0"
		return 0
	}
	local cutoff
	if date --version &>/dev/null 2>&1; then
		cutoff=$(date -u -d "-${window_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ")
	else cutoff=$(date -u -v-"${window_minutes}"M +"%Y-%m-%dT%H:%M:%SZ"); fi
	jq -sr --arg p "$provider" --arg c "$cutoff" '
		[.[] | select(.provider == $p and .recorded_at >= $c)] |
		"\(length)|\(map(.input_tokens + .output_tokens + .cache_read_tokens + .cache_write_tokens) | add // 0)"
	' "$OBS_METRICS" 2>/dev/null || echo "0|0"
}

# Public API: called by model-availability-helper.sh. Returns: 0=ok, 1=warn, 2=critical.
check_rate_limit_risk() {
	local provider="$1"
	local wm
	wm=$(_get_config_val "window_minutes" "$DEFAULT_WINDOW_MINUTES")
	local wp
	wp=$(_get_config_val "warn_pct" "$DEFAULT_WARN_PCT")
	[[ "$wm" =~ ^[0-9]+$ && "$wm" -gt 0 ]] || wm="$DEFAULT_WINDOW_MINUTES"
	[[ "$wp" =~ ^[0-9]+$ ]] || wp="$DEFAULT_WARN_PCT"
	local rl
	rl=$(_get_rl_field "$provider" "requests_per_min")
	[[ "$rl" =~ ^[0-9]+$ ]] || rl=0
	local tl
	tl=$(_get_rl_field "$provider" "tokens_per_min")
	[[ "$tl" =~ ^[0-9]+$ ]] || tl=0
	[[ "$rl" -eq 0 && "$tl" -eq 0 ]] && {
		echo "ok"
		return 0
	}

	local usage ar at
	usage=$(_count_usage_in_window "$provider" "$wm")
	IFS='|' read -r ar at <<<"$usage"
	local max_pct
	max_pct=$(awk "BEGIN { rp=($rl>0)?$ar*100/$rl:0; tp=($tl>0)?$at*100/$tl:0; print (rp>tp)?rp:tp }")
	[[ "$max_pct" -ge 95 ]] && {
		echo "critical"
		return 2
	}
	[[ "$max_pct" -ge "$wp" ]] && {
		echo "warn"
		return 1
	}
	echo "ok"
	return 0
}

# Collect unique provider names from config and metrics JSONL.
# Prints one provider name per line to stdout.
# Usage: _rl_collect_providers config_file provider_filter
_rl_collect_providers() {
	local config_file="$1" provider_filter="$2"
	if [[ -n "$provider_filter" ]]; then
		echo "$provider_filter"
		return 0
	fi
	local seen=""
	if [[ -n "$config_file" ]] && command -v jq &>/dev/null; then
		while IFS= read -r p; do
			[[ -z "$p" || "$seen" == *"|${p}|"* ]] && continue
			echo "$p"
			seen="${seen}|${p}|"
		done < <(jq -r '.providers | keys[]' "$config_file" 2>/dev/null)
	fi
	if [[ -f "$OBS_METRICS" ]] && command -v jq &>/dev/null; then
		while IFS= read -r p; do
			[[ -z "$p" || "$seen" == *"|${p}|"* ]] && continue
			echo "$p"
			seen="${seen}|${p}|"
		done < <(jq -r '.provider' "$OBS_METRICS" 2>/dev/null | sort -u)
	fi
	return 0
}

# Build pipe-delimited usage rows for each provider.
# Each row: provider|req_used|req_limit|req_pct|tok_used|tok_limit|tok_pct|status|billing_type
# Prints one row per line to stdout.
# Usage: _rl_build_rows eff_window warn_pct provider [provider ...]
_rl_build_rows() {
	local ew="$1" wp="$2"
	shift 2
	local prov
	for prov in "$@"; do
		[[ -z "$prov" ]] && continue
		local rl tl bt usage ar at rp=0 tp=0
		rl=$(_get_rl_field "$prov" "requests_per_min")
		[[ "$rl" =~ ^[0-9]+$ ]] || rl=0
		tl=$(_get_rl_field "$prov" "tokens_per_min")
		[[ "$tl" =~ ^[0-9]+$ ]] || tl=0
		bt=$(_get_rl_field "$prov" "billing_type")
		[[ "$bt" == "0" ]] && bt="unknown"
		usage=$(_count_usage_in_window "$prov" "$ew")
		IFS='|' read -r ar at <<<"$usage"
		[[ "$rl" -gt 0 ]] && rp=$(awk "BEGIN { printf \"%d\", $ar * 100 / $rl }")
		[[ "$tl" -gt 0 ]] && tp=$(awk "BEGIN { printf \"%d\", $at * 100 / $tl }")
		local mp st="ok"
		mp=$(awk "BEGIN { print ($rp > $tp) ? $rp : $tp }")
		[[ "$mp" -ge 95 ]] && st="critical"
		[[ "$mp" -lt 95 && "$mp" -ge "$wp" ]] && st="warn"
		echo "${prov}|${ar}|${rl}|${rp}|${at}|${tl}|${tp}|${st}|${bt}"
	done
	return 0
}

# Emit JSON array from pipe-delimited rows on stdin. Usage: _rl_output_json eff_window
_rl_output_json() {
	local ew="$1"
	local json_arr="[" first=true row
	while IFS= read -r row; do
		IFS='|' read -r pv a r rp2 t l tp2 s _ <<<"$row"
		[[ "$first" == "true" ]] || json_arr="${json_arr},"
		first=false
		json_arr="${json_arr}{\"provider\":\"$pv\",\"requests_used\":${a:-0},\"requests_limit\":${r:-0},\"requests_pct\":${rp2:-0},\"tokens_used\":${t:-0},\"tokens_limit\":${l:-0},\"tokens_pct\":${tp2:-0},\"status\":\"$s\",\"window_minutes\":${ew:-1}}"
	done
	echo "${json_arr}]"
	return 0
}

# Emit human-readable table from pipe-delimited rows on stdin.
# Usage: _rl_output_table eff_window warn_pct config_file
_rl_output_table() {
	local ew="$1" wp="$2" config_file="$3"
	printf "\nRate Limit Utilisation (%smin window, warn at %s%%)\n" "$ew" "$wp"
	[[ -z "$config_file" ]] && print_warning "No rate-limits.json found"
	printf "  %-12s %6s %10s %5s %8s %10s %5s %s\n" "Provider" "Reqs" "Limit" "Pct" "Tokens" "Limit" "Pct" "Status"
	local row
	while IFS= read -r row; do
		IFS='|' read -r pv a r rp2 t l tp2 s _ <<<"$row"
		local sd="$s"
		[[ "$s" == "critical" ]] && sd="${RED}CRITICAL${NC}"
		[[ "$s" == "warn" ]] && sd="${YELLOW}WARN${NC}"
		[[ "$s" == "ok" ]] && sd="${GREEN}ok${NC}"
		printf "  %-12s %6s %10s %4s%% %8s %10s %4s%% %b\n" "$pv" "$a" "${r:-n/a}" "$rp2" "$t" "${l:-n/a}" "$tp2" "$sd"
	done
	echo ""
	return 0
}

cmd_rate_limits() {
	local json_flag=false provider_filter="" window_minutes=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		--provider)
			provider_filter="${2:-}"
			shift 2
			;;
		--window)
			window_minutes="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	cmd_ingest --quiet >/dev/null 2>&1 || true

	local config_file
	config_file=$(_get_rate_limits_config) || config_file=""
	local ew="${window_minutes:-$(_get_config_val "window_minutes" "$DEFAULT_WINDOW_MINUTES")}"
	local wp
	wp=$(_get_config_val "warn_pct" "$DEFAULT_WARN_PCT")
	[[ "$ew" =~ ^[0-9]+$ && "$ew" -gt 0 ]] || {
		print_error "--window must be a positive integer"
		return 1
	}
	[[ "$wp" =~ ^[0-9]+$ ]] || wp="$DEFAULT_WARN_PCT"

	local providers_out
	providers_out=$(_rl_collect_providers "$config_file" "$provider_filter")
	[[ -z "$providers_out" ]] && {
		[[ "$json_flag" == "true" ]] && echo "[]" || print_info "No provider data. Run 'ingest' first."
		return 0
	}

	local rows_out
	rows_out=$(while IFS= read -r prov; do
		_rl_build_rows "$ew" "$wp" "$prov"
	done <<<"$providers_out")

	if [[ "$json_flag" == "true" ]]; then
		_rl_output_json "$ew" <<<"$rows_out"
	else
		_rl_output_table "$ew" "$wp" "$config_file" <<<"$rows_out"
	fi
	return 0
}

readonly DEFAULT_CACHE_THRESHOLD=90
readonly DEFAULT_CACHE_WINDOW_HOURS=24

cmd_cache_health() {
	local json_flag=false threshold="$DEFAULT_CACHE_THRESHOLD" window_hours="$DEFAULT_CACHE_WINDOW_HOURS"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		--threshold)
			threshold="${2:-$DEFAULT_CACHE_THRESHOLD}"
			shift 2
			;;
		--window)
			window_hours="${2:-$DEFAULT_CACHE_WINDOW_HOURS}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local obs_db="${OBS_DIR}/llm-requests.db"
	[[ -f "$obs_db" ]] || {
		print_error "SQLite DB not found at $obs_db"
		return 1
	}
	command -v sqlite3 &>/dev/null || {
		print_error "sqlite3 required"
		return 1
	}

	# Single query: per-model cache stats over the window, only for providers
	# with Anthropic-style prompt caching (cache_read > 0 somewhere).
	local result
	result=$(sqlite3 -separator '|' "$obs_db" "
		SELECT
			model_id,
			COUNT(*) AS requests,
			SUM(tokens_cache_read) AS cache_read,
			SUM(tokens_cache_write) AS cache_write,
			SUM(tokens_input) AS uncached_input,
			ROUND(
				CAST(SUM(tokens_cache_read) AS REAL)
				/ NULLIF(SUM(tokens_cache_read) + SUM(tokens_input), 0) * 100, 1
			) AS cache_pct
		FROM llm_requests
		WHERE timestamp > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-${window_hours} hours')
		GROUP BY model_id
		HAVING SUM(tokens_cache_read) + SUM(tokens_cache_write) > 0
		ORDER BY requests DESC;
	" 2>/dev/null) || result=""

	[[ -z "$result" ]] && {
		if [[ "$json_flag" == "true" ]]; then
			echo '{"status":"ok","models":[],"message":"No cacheable requests in window"}'
		else
			print_info "No cacheable requests in the last ${window_hours}h"
		fi
		return 0
	}

	local overall_status="ok" degraded_models=""

	if [[ "$json_flag" == "true" ]]; then
		local json_arr="[" first=true
		while IFS='|' read -r model reqs cr cw ui pct; do
			[[ -z "$model" ]] && continue
			local status="ok"
			if [[ -n "$pct" ]] && awk "BEGIN { exit !($pct < $threshold) }"; then
				status="degraded"
				overall_status="degraded"
			fi
			[[ "$first" == "true" ]] || json_arr="${json_arr},"
			first=false
			json_arr="${json_arr}{\"model\":\"${model}\",\"requests\":${reqs:-0},\"cache_read\":${cr:-0},\"cache_write\":${cw:-0},\"uncached_input\":${ui:-0},\"cache_pct\":${pct:-0},\"status\":\"${status}\"}"
		done <<<"$result"
		echo "{\"status\":\"${overall_status}\",\"threshold\":${threshold},\"window_hours\":${window_hours},\"models\":${json_arr}]}"
	else
		printf "\nPrompt Cache Health (%sh window, threshold %s%%)\n" "$window_hours" "$threshold"
		printf "  %-30s %8s %12s %12s %7s %s\n" "Model" "Requests" "Cache Read" "Uncached" "Hit %" "Status"
		while IFS='|' read -r model reqs cr cw ui pct; do
			[[ -z "$model" ]] && continue
			local status="${GREEN}ok${NC}"
			# Check cache hit rate against threshold
			[[ -z "$pct" ]] || ! awk "BEGIN { exit !($pct < $threshold) }" || {
				status="${YELLOW}DEGRADED${NC}"
				overall_status="degraded"
				degraded_models="${degraded_models}${model} (${pct}%), "
			}
			printf "  %-30s %8s %12s %12s %6s%% %b\n" "$model" "$reqs" "$cr" "$ui" "$pct" "$status"
		done <<<"$result"
		echo ""
		[[ "$overall_status" != "degraded" ]] && print_success "All models above ${threshold}% cache hit rate" ||
			print_warning "Cache degradation: ${degraded_models%, }"
	fi

	[[ "$overall_status" == "ok" ]] && return 0
	return 1
}

cmd_runtime_events() {
	local limit="${1:-20}" obs_db="${OBS_DIR}/llm-requests.db"
	[[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 && "$limit" -le 1000 ]] || {
		print_error "runtime-events limit must be an integer from 1 to 1000"
		return 1
	}
	[[ -f "$obs_db" ]] || {
		print_error "SQLite DB not found at $obs_db"
		return 1
	}
	command -v sqlite3 &>/dev/null || {
		print_error "sqlite3 required"
		return 1
	}
	sqlite3 -json "$obs_db" "SELECT envelope_version, occurred_at, event_id, event_type, correlation_id, causation_id, subject_id, session_id, worker_id, root_event_id, parent_event_id, state_version, payload_json, payload_bytes, redaction_count FROM runtime_events ORDER BY id DESC LIMIT ${limit};"
	return 0
}

require_node() {
	command -v node &>/dev/null || {
		print_error "node required"
		return 1
	}
	return 0
}

cmd_storage() {
	require_node || return 1
	node "$RUNTIME_EVENTS_RETENTION" inventory --db "${OBS_DIR}/llm-requests.db" "$@"
	return $?
}

cmd_retention() {
	require_node || return 1
	node "$RUNTIME_EVENTS_RETENTION" archive --db "${OBS_DIR}/llm-requests.db" "$@"
	return $?
}

cmd_retention_maintenance() {
	require_node || return 1
	node "$RUNTIME_EVENTS_RETENTION" maintain --db "${OBS_DIR}/llm-requests.db" "$@"
	return $?
}

cmd_help() {
	cat <<EOF
Observability Helper — LLM request and runtime-event evidence
Usage: observability-helper.sh [command] [options]
Commands: ingest | record (--model X) | rate-limits | cache-health | runtime-events [limit]
          storage [--json] | retention [--dry-run|--apply] [--before ISO] [--max-rows N]
          retention-maintenance [--dry-run|--apply] [--max-partitions N] [--max-duration-seconds N] | help

Record options:
  --model MODEL          Model name (required)
  --provider PROVIDER    Provider name (auto-detected from model when omitted)
  --input-tokens N       Input token count
  --output-tokens N      Output token count
  --cache-read N         Cache read token count
  --cache-write N        Cache write token count
  --session ID           Session identifier
  --project NAME         Project name
  --stop-reason REASON   Stop reason
  --error MESSAGE        Error message
  --prompt-file PATH     Path to prompt file (auto-resolves git hash as version)
  --prompt-version VER   Explicit prompt version (overrides git hash detection)

Metrics: $OBS_METRICS
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	storage | storage-inventory | retention | archive | retention-maintenance | maintain-retention) ;;
	*)
		init_log_file
		init_storage || return 1
		;;
	esac
	case "$command" in
	ingest | parse | import) cmd_ingest "$@" ;; record | r) cmd_record "$@" ;;
	rate-limits | rate_limits | ratelimits | rl) cmd_rate_limits "$@" ;;
	cache-health | cache_health | ch) cmd_cache_health "$@" ;;
	runtime-events | runtime_events | events) cmd_runtime_events "$@" ;;
	storage | storage-inventory) cmd_storage "$@" ;;
	retention | archive) cmd_retention "$@" ;;
	retention-maintenance | maintain-retention) cmd_retention_maintenance "$@" ;;
	help | --help | -h) cmd_help ;; *)
		print_error "Unknown: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
