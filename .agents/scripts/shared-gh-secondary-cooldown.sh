#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub secondary-rate-limit cooldown guard (GH#23605)
# =============================================================================
# Sourced by shared-gh-wrappers.sh. Provides a small shared state file that all
# gh wrapper call sites can consult before starting noncritical GitHub work.

[[ -n "${_SHARED_GH_SECONDARY_COOLDOWN_LOADED:-}" ]] && return 0
_SHARED_GH_SECONDARY_COOLDOWN_LOADED=1

: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS:=300}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME:=${HOME:-/tmp/.aidevops-${USER:-uid-${UID:-unknown}}}}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE:=${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME}/.aidevops/cache/gh-secondary-cooldown.json}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE:=${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME}/.aidevops/cache/gh-cooldown-events.jsonl}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_LINES:=100}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_BYTES:=262144}"
: "${AIDEVOPS_GH_READ_RAMP_ENABLED:=1}"
: "${AIDEVOPS_GH_READ_RAMP_BOOT_SECS:=180}"
: "${AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS:=300}"
: "${AIDEVOPS_GH_READ_RAMP_BUDGET:=60}"
: "${AIDEVOPS_GH_READ_RAMP_STATE_FILE:=${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME}/.aidevops/cache/gh-read-ramp-state.tsv}"

_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=0
_GH_SECONDARY_COOLDOWN_LOGGED_RAMP=0
_GH_SECONDARY_READ_OP="read"
_GH_SECONDARY_COOLDOWN_ACTION_CREATED="created"
_GH_SECONDARY_COOLDOWN_UNKNOWN="unknown"
_GH_SECONDARY_COOLDOWN_GRAPHQL="graphql"

_gh_secondary_cooldown_now() {
	date +%s
	return 0
}

_gh_secondary_cooldown_file() {
	printf '%s' "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}"
	return 0
}

_gh_secondary_cooldown_event_file() {
	printf '%s' "${AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE}"
	return 0
}

_gh_secondary_cooldown_detect() {
	local text="$1"
	printf '%s' "$text" | grep -Eqi 'secondary rate limit|abuse detection mechanism|You have exceeded a secondary rate limit' || return 1
	return 0
}

_gh_secondary_cooldown_request_id() {
	local text="$1"
	local request_id=""
	request_id=$(printf '%s\n' "$text" | sed -nE 's/.*([Xx]-[Gg]it[Hh]ub-[Rr]equest-[Ii]d|request[_ -]?id)[=: ]+([A-Za-z0-9:-]+).*/\2/p' | sed -n '1p')
	printf '%s' "$request_id"
	return 0
}

_gh_secondary_cooldown_safe_value() {
	local value="$1"
	local max_len="${2:-120}"
	value=${value//$'\r'/ }
	value=${value//$'\n'/ }
	value=${value//$'\t'/ }
	if [[ "$max_len" =~ ^[0-9]+$ && "${#value}" -gt "$max_len" ]]; then
		value="${value:0:$max_len}"
	fi
	printf '%s' "$value"
	return 0
}

_gh_secondary_cooldown_safe_family() {
	local value="$1"
	local max_len="${2:-80}"
	value="${value##*/}"
	value="$(_gh_secondary_cooldown_safe_value "$value" "$max_len")"
	value=$(printf '%s' "$value" | tr -c 'A-Za-z0-9._:@+=,-' '_' 2>/dev/null || printf 'unknown')
	[[ -n "$value" ]] || value="$_GH_SECONDARY_COOLDOWN_UNKNOWN"
	printf '%s' "$value"
	return 0
}

_gh_secondary_cooldown_safe_context_value() {
	local value="$1"
	local max_len="${2:-160}"
	value="$(_gh_secondary_cooldown_safe_value "$value" "$max_len")"
	value=$(printf '%s' "$value" | tr -c 'A-Za-z0-9._:/?&=<>{},+@ -' '_' 2>/dev/null || printf '%s' "$_GH_SECONDARY_COOLDOWN_UNKNOWN")
	[[ -n "$value" ]] || value="$_GH_SECONDARY_COOLDOWN_UNKNOWN"
	printf '%s' "$value"
	return 0
}

_gh_secondary_cooldown_sanitized_endpoint() {
	local endpoint="${1:-${AIDEVOPS_GH_COOLDOWN_ENDPOINT:-$_GH_SECONDARY_COOLDOWN_UNKNOWN}}"
	local rest=""
	local suffix=""
	endpoint="${endpoint#https://api.github.com}"
	endpoint="${endpoint#http://api.github.com}"
	endpoint="${endpoint%%#*}"
	endpoint="${endpoint%%\?*}"
	[[ -n "$endpoint" ]] || endpoint="$_GH_SECONDARY_COOLDOWN_UNKNOWN"
	if [[ "$endpoint" != "$_GH_SECONDARY_COOLDOWN_GRAPHQL" && "$endpoint" != gh://* && "$endpoint" != /* && "$endpoint" != "$_GH_SECONDARY_COOLDOWN_UNKNOWN" ]]; then
		endpoint="/${endpoint}"
	fi
	case "$endpoint" in
	/repos/*/*)
		rest="${endpoint#/repos/}"
		rest="${rest#*/}"
		suffix="$(_gh_secondary_cooldown_owner_suffix "$rest")"
		endpoint="/repos/<owner>/<repo>${suffix}"
		;;
	/users/*)
		rest="${endpoint#/users/}"
		suffix="$(_gh_secondary_cooldown_owner_suffix "$rest")"
		endpoint="/users/<owner>${suffix}"
		;;
	/orgs/*)
		rest="${endpoint#/orgs/}"
		suffix="$(_gh_secondary_cooldown_owner_suffix "$rest")"
		endpoint="/orgs/<owner>${suffix}"
		;;
	esac
	_gh_secondary_cooldown_safe_context_value "$endpoint" 180
	return 0
}

_gh_secondary_cooldown_owner_suffix() {
	local rest="$1"
	if [[ "$rest" == */* ]]; then
		printf '/%s' "${rest#*/}"
	fi
	return 0
}

_gh_secondary_cooldown_sanitized_query_shape() {
	local query="${1:-}"
	local endpoint="${2:-${AIDEVOPS_GH_COOLDOWN_ENDPOINT:-}}"
	local rest=""
	local part=""
	local key=""
	local shape=""
	if [[ -z "$query" && "$endpoint" == *\?* ]]; then
		query="${endpoint#*\?}"
	fi
	query="${query%%#*}"
	query="${query#\?}"
	[[ -n "$query" ]] || {
		printf ''
		return 0
	}
	rest="$query"
	while [[ -n "$rest" ]]; do
		if [[ "$rest" == *'&'* ]]; then
			part="${rest%%&*}"
			rest="${rest#*&}"
		else
			part="$rest"
			rest=""
		fi
		[[ -n "$part" ]] || continue
		key="${part%%=*}"
		key="$(_gh_secondary_cooldown_safe_family "$key" 60)"
		if [[ -n "$shape" ]]; then
			shape="${shape}&${key}=<redacted>"
		else
			shape="${key}=<redacted>"
		fi
	done
	_gh_secondary_cooldown_safe_context_value "$shape" 180
	return 0
}

_gh_secondary_cooldown_method() {
	local method="${1:-${AIDEVOPS_GH_COOLDOWN_METHOD:-unknown}}"
	method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]' 2>/dev/null || printf 'UNKNOWN')
	case "$method" in
	GET | POST | PATCH | PUT | DELETE | HEAD | GH-CLI | GRAPHQL | UNKNOWN) ;;
	*) method="$(_gh_secondary_cooldown_safe_family "$method" 24)" ;;
	esac
	printf '%s' "$method"
	return 0
}

_gh_secondary_cooldown_auth_mode() {
	local auth_mode="${AIDEVOPS_GH_AUTH_MODE:-}"
	[[ -n "$auth_mode" ]] || auth_mode="gh-pat"
	case "$auth_mode" in
	github-app | gh-pat | gh-oauth | unknown) ;;
	*) auth_mode="$(_gh_secondary_cooldown_safe_family "$auth_mode" 40)" ;;
	esac
	printf '%s' "$auth_mode"
	return 0
}

_gh_secondary_cooldown_auth_principal() {
	local principal="${1:-${AIDEVOPS_GH_AUTH_PRINCIPAL:-}}"
	local auth_mode="${2:-${AIDEVOPS_GH_AUTH_MODE:-}}"
	if [[ -z "$principal" && "$auth_mode" == "github-app" ]]; then
		principal="app-installation:unknown"
	elif [[ -z "$principal" && -n "${GITHUB_ACTOR:-}" ]]; then
		principal="user:${GITHUB_ACTOR}"
	elif [[ -z "$principal" && -n "${AIDEVOPS_SESSION_USER:-}" ]]; then
		principal="user:${AIDEVOPS_SESSION_USER}"
	fi
	[[ -n "$principal" ]] || principal="$_GH_SECONDARY_COOLDOWN_UNKNOWN"
	_gh_secondary_cooldown_safe_context_value "$principal" 120
	return 0
}

_gh_secondary_cooldown_caller_family() {
	local i=1
	local src=""
	local base=""
	while [[ "$i" -lt "${#BASH_SOURCE[@]}" ]]; do
		src="${BASH_SOURCE[$i]:-}"
		base="${src##*/}"
		case "$base" in
		shared-gh-secondary-cooldown.sh | shared-gh-wrappers.sh | shared-constants.sh | bash | -bash | zsh | -zsh | "")
			i=$((i + 1))
			continue
			;;
		esac
		_gh_secondary_cooldown_safe_family "$base" 80
		return 0
	done
	printf 'unknown'
	return 0
}

_gh_secondary_cooldown_endpoint_family() {
	local context_endpoint="${1:-${AIDEVOPS_GH_COOLDOWN_ENDPOINT:-}}"
	local endpoint="${AIDEVOPS_GH_COOLDOWN_ENDPOINT_FAMILY:-${AIDEVOPS_GH_API_POOL:-${AIDEVOPS_GH_ROUTE_DECISION:-unknown}}}"
	if [[ -n "$context_endpoint" && "$context_endpoint" != "$_GH_SECONDARY_COOLDOWN_GRAPHQL" && "$context_endpoint" != gh://* && "$context_endpoint" != /* ]]; then
		context_endpoint="/${context_endpoint}"
	fi
	if [[ "$endpoint" == "$_GH_SECONDARY_COOLDOWN_UNKNOWN" || -z "$endpoint" ]]; then
		case "$context_endpoint" in
		"$_GH_SECONDARY_COOLDOWN_GRAPHQL") endpoint="$_GH_SECONDARY_COOLDOWN_GRAPHQL" ;;
		/search/* | */search/*) endpoint="rest-search" ;;
		/repos/* | /users/* | /orgs/*) endpoint="rest-core" ;;
		gh://*) endpoint="other" ;;
		*) endpoint="$_GH_SECONDARY_COOLDOWN_UNKNOWN" ;;
		esac
	fi
	case "$endpoint" in
	graphql | rest | rest-core | rest-search | search-graphql | search-rest | other | unknown) ;;
	*) endpoint="$_GH_SECONDARY_COOLDOWN_UNKNOWN" ;;
	esac
	_gh_secondary_cooldown_safe_family "$endpoint" 80
	return 0
}

_gh_secondary_cooldown_body_classification() {
	local response_text="$1"
	local status="${2:-}"
	local remaining="${3:-}"
	if printf '%s' "$response_text" | grep -Eqi 'abuse detection mechanism'; then
		printf 'abuse-detection'
		return 0
	fi
	if printf '%s' "$response_text" | grep -Eqi 'secondary rate limit|You have exceeded a secondary rate limit'; then
		printf 'secondary-rate-limit'
		return 0
	fi
	if printf '%s' "$response_text" | grep -Eqi 'GraphQL: API rate limit already exceeded|API rate limit exceeded'; then
		printf 'primary-rate-limit'
		return 0
	fi
	if printf '%s' "$response_text" | grep -Eqi 'Resource not accessible by integration'; then
		printf 'resource-not-accessible'
		return 0
	fi
	if printf '%s' "$response_text" | grep -Eqi 'requires?.*(permission|scope)|permission.*required|must have.*(admin|write|read)|insufficient.*permission'; then
		printf 'requires-permission'
		return 0
	fi
	if [[ "$remaining" =~ ^[0-9]+$ && "$remaining" -eq 0 ]]; then
		printf 'primary-rate-limit'
		return 0
	fi
	case "$status" in
	403)
		printf 'generic-forbidden'
		return 0
		;;
	429)
		printf 'rate-limit-message'
		return 0
		;;
	esac
	if [[ -z "${response_text//[[:space:]]/}" ]]; then
		printf 'empty-response'
		return 0
	fi
	printf 'other-error'
	return 0
}

_gh_secondary_cooldown_response_body() {
	local response_text="$1"
	local body=""
	body=$(printf '%s\n' "$response_text" | awk '
		BEGIN { in_body = 0; saw_header = 0 }
		/^HTTP\// { saw_header = 1 }
		{ line = $0; sub(/\r$/, "", line) }
		in_body { print line; next }
		saw_header && line == "" { in_body = 1; next }
	' 2>/dev/null || true)
	if [[ -n "$body" ]]; then
		printf '%s' "$body"
	else
		printf '%s' "$response_text"
	fi
	return 0
}

_gh_secondary_cooldown_body_message_excerpt() {
	local response_text="$1"
	local body=""
	local excerpt=""
	body="$(_gh_secondary_cooldown_response_body "$response_text")"
	if command -v jq >/dev/null 2>&1; then
		excerpt=$(printf '%s' "$body" | jq -r '.message // .errors[0].message // empty' 2>/dev/null || true)
	fi
	[[ -n "$excerpt" ]] || excerpt="$body"
	excerpt="$(_gh_secondary_cooldown_safe_value "$excerpt" 180)"
	printf '%s' "$excerpt"
	return 0
}

_gh_secondary_cooldown_diagnostic_only_403() {
	local status="$1"
	local retry_after="$2"
	local remaining="$3"
	local body_classification="$4"
	[[ "$status" == "403" ]] || return 1
	[[ -z "$retry_after" ]] || return 1
	[[ "$remaining" =~ ^[0-9]+$ && "$remaining" -gt 0 ]] || return 1
	case "$body_classification" in
	generic-forbidden | resource-not-accessible | requires-permission) return 0 ;;
	*) return 1 ;;
	esac
}

_gh_secondary_cooldown_json_string() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}
	printf '"%s"' "$value"
	return 0
}

_gh_secondary_cooldown_recent_event_count() {
	local field="$1"
	local value="$2"
	local window_secs="$3"
	local now="$4"
	local file=""
	local cutoff=0
	local count="0"
	file="$(_gh_secondary_cooldown_event_file)"
	[[ -f "$file" && "$window_secs" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || {
		printf '0'
		return 0
	}
	cutoff=$((now - window_secs))
	if command -v jq >/dev/null 2>&1; then
		count=$(jq -r --arg field "$field" --arg value "$value" --argjson cutoff "$cutoff" \
			'select((.timestamp // 0) >= $cutoff and ((.[$field] // "") | tostring) == $value) | 1' "$file" 2>/dev/null | wc -l | tr -d ' ')
	fi
	[[ "$count" =~ ^[0-9]+$ ]] || count="0"
	printf '%s' "$count"
	return 0
}

_gh_secondary_cooldown_recent_secondary_count() {
	local window_secs="$1"
	local now="$2"
	local file=""
	local cutoff=0
	local count="0"
	file="$(_gh_secondary_cooldown_event_file)"
	[[ -f "$file" && "$window_secs" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || {
		printf '0'
		return 0
	}
	cutoff=$((now - window_secs))
	if command -v jq >/dev/null 2>&1; then
		count=$(jq -r --argjson cutoff "$cutoff" \
			'select((.timestamp // 0) >= $cutoff and ((.body_message_class // "") == "secondary-rate-limit" or (.body_message_class // "") == "abuse-detection")) | 1' "$file" 2>/dev/null | wc -l | tr -d ' ')
	fi
	[[ "$count" =~ ^[0-9]+$ ]] || count="0"
	printf '%s' "$count"
	return 0
}

_gh_secondary_cooldown_tail_event_lines() {
	local file="$1"
	local keep_lines="$2"
	local tmp=""
	[[ -f "$file" && "$keep_lines" =~ ^[0-9]+$ && "$keep_lines" -gt 0 ]] || return 1
	tmp="${file}.tmp"
	if tail -n "$keep_lines" "$file" >"$tmp" 2>/dev/null && mv "$tmp" "$file"; then
		return 0
	fi
	rm -f "$tmp"
	return 1
}

_gh_secondary_cooldown_trim_events() {
	local file="$1"
	local max_lines="${AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_LINES:-100}"
	local max_bytes="${AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_BYTES:-262144}"
	local line_count="0"
	local byte_count="0"
	local keep_lines="0"
	[[ -f "$file" ]] || return 0
	[[ "$max_lines" =~ ^[0-9]+$ && "$max_lines" -gt 0 ]] || max_lines=100
	[[ "$max_bytes" =~ ^[0-9]+$ && "$max_bytes" -gt 0 ]] || max_bytes=262144
	line_count=$(wc -l <"$file" 2>/dev/null | tr -d ' ' || printf '0')
	if [[ "$line_count" =~ ^[0-9]+$ && "$line_count" -gt "$max_lines" ]]; then
		_gh_secondary_cooldown_tail_event_lines "$file" "$max_lines" || return 0
	fi
	byte_count=$(wc -c <"$file" 2>/dev/null | tr -d ' ' || printf '0')
	if [[ "$byte_count" =~ ^[0-9]+$ && "$byte_count" -gt "$max_bytes" ]]; then
		line_count=$(wc -l <"$file" 2>/dev/null | tr -d ' ' || printf '0')
		[[ "$line_count" =~ ^[0-9]+$ && "$line_count" -gt 0 ]] || return 0
		keep_lines="$line_count"
		if [[ "$keep_lines" -gt "$max_lines" ]]; then
			keep_lines="$max_lines"
		fi
		while [[ "$keep_lines" -gt 1 && "$byte_count" -gt "$max_bytes" ]]; do
			keep_lines=$((keep_lines - 1))
			_gh_secondary_cooldown_tail_event_lines "$file" "$keep_lines" || return 0
			byte_count=$(wc -c <"$file" 2>/dev/null | tr -d ' ' || printf '0')
			[[ "$byte_count" =~ ^[0-9]+$ ]] || return 0
		done
	fi
	return 0
}

_gh_secondary_cooldown_append_event_json() {
	local file="$1"
	jq -cn \
		--argjson timestamp "$now" \
		--arg cooldown_action "$cooldown_action" \
		--arg cooldown_reason "$cooldown_reason" \
		--arg decision_branch "$decision_branch" \
		--arg method "$method" \
		--arg endpoint "$endpoint" \
		--arg query_shape "$query_shape" \
		--arg operation "$operation" \
		--arg wrapper "$wrapper" \
		--arg pulse_stage "$pulse_stage" \
		--arg auth_mode "$auth_mode" \
		--arg auth_principal "$auth_principal" \
		--arg status "$status" \
		--arg body_message_class "$body_classification" \
		--arg body_message_excerpt "$body_excerpt" \
		--arg retry_after "$retry_after" \
		--arg ratelimit_limit "$ratelimit_limit" \
		--arg ratelimit_remaining "$ratelimit_remaining" \
		--arg ratelimit_reset "$ratelimit_reset" \
		--arg ratelimit_used "$ratelimit_used" \
		--arg ratelimit_resource "$ratelimit_resource" \
		--arg request_id "$request_id" \
		--arg accepted_permissions "$accepted_permissions" \
		--arg oauth_scopes "$oauth_scopes" \
		--arg accepted_oauth_scopes "$accepted_oauth_scopes" \
		--argjson recent_403_count_1m "$recent_403_count_1m" \
		--argjson recent_403_count_5m "$recent_403_count_5m" \
		--argjson recent_secondary_count_5m "$recent_secondary_count_5m" \
		'{timestamp:$timestamp,cooldown_action:$cooldown_action,cooldown_reason:$cooldown_reason,decision_branch:$decision_branch,method:$method,endpoint:$endpoint,query_shape:$query_shape,operation:$operation,wrapper:$wrapper,pulse_stage:$pulse_stage,auth_mode:$auth_mode,auth_principal:$auth_principal,http_status:(if $status == "" then null else ($status|tonumber? // $status) end),body_message_class:$body_message_class,body_message_excerpt:$body_message_excerpt,headers:{retry_after:$retry_after,x_ratelimit_limit:$ratelimit_limit,x_ratelimit_remaining:$ratelimit_remaining,x_ratelimit_reset:$ratelimit_reset,x_ratelimit_used:$ratelimit_used,x_ratelimit_resource:$ratelimit_resource,x_github_request_id:$request_id,x_accepted_github_permissions:$accepted_permissions,x_oauth_scopes:$oauth_scopes,x_accepted_oauth_scopes:$accepted_oauth_scopes},recent_403_count_1m:$recent_403_count_1m,recent_403_count_5m:$recent_403_count_5m,recent_secondary_count_5m:$recent_secondary_count_5m}' >>"$file" 2>/dev/null
	return $?
}

_gh_secondary_cooldown_record_event() {
	local cooldown_action="$1"
	local cooldown_reason="$2"
	local decision_branch="$3"
	local response_text="${4:-}"
	local method_arg="${5:-}"
	local endpoint_arg="${6:-}"
	local query_shape_arg="${7:-}"
	local operation_arg="${8:-}"
	local wrapper_arg="${9:-}"
	local pulse_stage_arg="${10:-}"
	local now_arg="${11:-}"
	local now=""
	local file=""
	local dir=""
	local request_id=""
	local status=""
	local retry_after=""
	local ratelimit_limit=""
	local ratelimit_remaining=""
	local ratelimit_reset=""
	local ratelimit_used=""
	local ratelimit_resource=""
	local accepted_permissions=""
	local oauth_scopes=""
	local accepted_oauth_scopes=""
	local body_classification=""
	local body_excerpt=""
	local method=""
	local endpoint=""
	local query_shape=""
	local operation=""
	local operation_source=""
	local wrapper=""
	local wrapper_source=""
	local pulse_stage=""
	local pulse_stage_source=""
	local auth_mode=""
	local auth_principal=""
	local recent_403_count_1m="0"
	local recent_403_count_5m="0"
	local recent_secondary_count_5m="0"
	command -v jq >/dev/null 2>&1 || return 0
	now="$now_arg"
	[[ "$now" =~ ^[0-9]+$ ]] || now="$(_gh_secondary_cooldown_now)"
	file="$(_gh_secondary_cooldown_event_file)"
	dir="${file%/*}"
	mkdir -p "$dir" 2>/dev/null || return 0
	request_id="$(_gh_secondary_cooldown_request_id "$response_text")"
	_gh_secondary_cooldown_parse_response_metadata "$response_text"
	body_classification="$(_gh_secondary_cooldown_body_classification "$response_text" "$status" "$ratelimit_remaining")"
	body_excerpt="$(_gh_secondary_cooldown_body_message_excerpt "$response_text")"
	method="$(_gh_secondary_cooldown_method "$method_arg")"
	endpoint="$(_gh_secondary_cooldown_sanitized_endpoint "$endpoint_arg")"
	query_shape="$(_gh_secondary_cooldown_sanitized_query_shape "$query_shape_arg" "$endpoint_arg")"
	operation_source="${operation_arg:-${AIDEVOPS_GH_COOLDOWN_OPERATION:-$_GH_SECONDARY_COOLDOWN_UNKNOWN}}"
	wrapper_source="${wrapper_arg:-${AIDEVOPS_GH_COOLDOWN_WRAPPER:-$(_gh_secondary_cooldown_caller_family)}}"
	pulse_stage_source="${pulse_stage_arg:-${AIDEVOPS_GH_COOLDOWN_STAGE:-$_GH_SECONDARY_COOLDOWN_UNKNOWN}}"
	operation="$(_gh_secondary_cooldown_safe_family "$operation_source" 120)"
	wrapper="$(_gh_secondary_cooldown_safe_family "$wrapper_source" 120)"
	pulse_stage="$(_gh_secondary_cooldown_safe_family "$pulse_stage_source" 120)"
	auth_mode="$(_gh_secondary_cooldown_auth_mode)"
	auth_principal="$(_gh_secondary_cooldown_auth_principal "" "$auth_mode")"
	recent_403_count_1m="$(_gh_secondary_cooldown_recent_event_count http_status 403 60 "$now")"
	recent_403_count_5m="$(_gh_secondary_cooldown_recent_event_count http_status 403 300 "$now")"
	recent_secondary_count_5m="$(_gh_secondary_cooldown_recent_secondary_count 300 "$now")"
	[[ "$recent_403_count_1m" =~ ^[0-9]+$ ]] || recent_403_count_1m="0"
	[[ "$recent_403_count_5m" =~ ^[0-9]+$ ]] || recent_403_count_5m="0"
	[[ "$recent_secondary_count_5m" =~ ^[0-9]+$ ]] || recent_secondary_count_5m="0"
	if [[ "$status" == "403" ]]; then
		recent_403_count_1m=$((recent_403_count_1m + 1))
		recent_403_count_5m=$((recent_403_count_5m + 1))
	fi
	case "$body_classification" in
	secondary-rate-limit | abuse-detection) recent_secondary_count_5m=$((recent_secondary_count_5m + 1)) ;;
	*) ;;
	esac
	_gh_secondary_cooldown_append_event_json "$file" || return 0
	_gh_secondary_cooldown_trim_events "$file"
	return 0
}

_gh_secondary_cooldown_write_state_jq() {
	local file="$1"
	jq -n \
		--arg reason "$reason" --arg first_seen "$now" --arg expires_at "$expires" \
		--arg request_id "$request_id" --arg decision_branch "$decision_branch" \
		--arg cooldown_action "$cooldown_action" --arg status "$status" \
		--arg method "$method" --arg endpoint "$endpoint" --arg query_shape "$query_shape" \
		--arg operation "$operation" --arg wrapper "$wrapper" --arg pulse_stage "$pulse_stage" \
		--arg auth_mode "$auth_mode" --arg auth_principal "$auth_principal" \
		--arg retry_after "$retry_after" --arg ratelimit_limit "$ratelimit_limit" \
		--arg ratelimit_remaining "$ratelimit_remaining" --arg ratelimit_reset "$ratelimit_reset" \
		--arg ratelimit_used "$ratelimit_used" --arg ratelimit_resource "$ratelimit_resource" \
		--arg accepted_permissions "$accepted_permissions" --arg oauth_scopes "$oauth_scopes" \
		--arg accepted_oauth_scopes "$accepted_oauth_scopes" \
		--arg body_classification "$body_classification" --arg body_excerpt "$body_excerpt" \
		--arg caller_family "$caller_family" --arg endpoint_family "$endpoint_family" \
		--argjson recent_403_count_1m "$recent_403_count_1m" \
		--argjson recent_403_count_5m "$recent_403_count_5m" \
		--argjson recent_secondary_count_5m "$recent_secondary_count_5m" \
		'{reason:$reason, first_seen:($first_seen|tonumber), expires_at:($expires_at|tonumber), last_request_id:$request_id, diagnostic:{cooldown_action:$cooldown_action, cooldown_reason:$reason, decision_branch:$decision_branch, method:$method, endpoint:$endpoint, query_shape:$query_shape, operation:$operation, wrapper:$wrapper, pulse_stage:$pulse_stage, auth_mode:$auth_mode, auth_principal:$auth_principal, http_status:$status, request_id:$request_id, body_classification:$body_classification, body_message_class:$body_classification, body_message_excerpt:$body_excerpt, caller_family:$caller_family, endpoint_family:$endpoint_family, headers:{retry_after:$retry_after, x_ratelimit_limit:$ratelimit_limit, x_ratelimit_remaining:$ratelimit_remaining, x_ratelimit_reset:$ratelimit_reset, x_ratelimit_used:$ratelimit_used, x_ratelimit_resource:$ratelimit_resource, x_github_request_id:$request_id, x_accepted_github_permissions:$accepted_permissions, x_oauth_scopes:$oauth_scopes, x_accepted_oauth_scopes:$accepted_oauth_scopes}, recent_403_count_1m:$recent_403_count_1m, recent_403_count_5m:$recent_403_count_5m, recent_secondary_count_5m:$recent_secondary_count_5m}}' >"${file}.tmp" || {
		printf 'Failed to write to %s\n' "${file}.tmp" >&2
		return 1
	}
	return 0
}

_gh_secondary_cooldown_write_state_fallback() {
	local file="$1"
	local reason_json request_id_json decision_branch_json status_json cooldown_action_json
	local retry_after_json ratelimit_limit_json ratelimit_remaining_json ratelimit_reset_json
	local ratelimit_used_json ratelimit_resource_json accepted_permissions_json oauth_scopes_json
	local accepted_oauth_scopes_json body_classification_json body_excerpt_json caller_family_json
	local endpoint_family_json method_json endpoint_json query_shape_json operation_json wrapper_json
	local pulse_stage_json auth_mode_json auth_principal_json
	reason_json="$(_gh_secondary_cooldown_json_string "$reason")"
	request_id_json="$(_gh_secondary_cooldown_json_string "$request_id")"
	decision_branch_json="$(_gh_secondary_cooldown_json_string "$decision_branch")"
	status_json="$(_gh_secondary_cooldown_json_string "$status")"
	cooldown_action_json="$(_gh_secondary_cooldown_json_string "$cooldown_action")"
	retry_after_json="$(_gh_secondary_cooldown_json_string "$retry_after")"
	ratelimit_limit_json="$(_gh_secondary_cooldown_json_string "$ratelimit_limit")"
	ratelimit_remaining_json="$(_gh_secondary_cooldown_json_string "$ratelimit_remaining")"
	ratelimit_reset_json="$(_gh_secondary_cooldown_json_string "$ratelimit_reset")"
	ratelimit_used_json="$(_gh_secondary_cooldown_json_string "$ratelimit_used")"
	ratelimit_resource_json="$(_gh_secondary_cooldown_json_string "$ratelimit_resource")"
	accepted_permissions_json="$(_gh_secondary_cooldown_json_string "$accepted_permissions")"
	oauth_scopes_json="$(_gh_secondary_cooldown_json_string "$oauth_scopes")"
	accepted_oauth_scopes_json="$(_gh_secondary_cooldown_json_string "$accepted_oauth_scopes")"
	body_classification_json="$(_gh_secondary_cooldown_json_string "$body_classification")"
	body_excerpt_json="$(_gh_secondary_cooldown_json_string "$body_excerpt")"
	caller_family_json="$(_gh_secondary_cooldown_json_string "$caller_family")"
	endpoint_family_json="$(_gh_secondary_cooldown_json_string "$endpoint_family")"
	method_json="$(_gh_secondary_cooldown_json_string "$method")"
	endpoint_json="$(_gh_secondary_cooldown_json_string "$endpoint")"
	query_shape_json="$(_gh_secondary_cooldown_json_string "$query_shape")"
	operation_json="$(_gh_secondary_cooldown_json_string "$operation")"
	wrapper_json="$(_gh_secondary_cooldown_json_string "$wrapper")"
	pulse_stage_json="$(_gh_secondary_cooldown_json_string "$pulse_stage")"
	auth_mode_json="$(_gh_secondary_cooldown_json_string "$auth_mode")"
	auth_principal_json="$(_gh_secondary_cooldown_json_string "$auth_principal")"
	printf '{"reason":%s,"first_seen":%s,"expires_at":%s,"last_request_id":%s,"diagnostic":{"cooldown_action":%s,"cooldown_reason":%s,"decision_branch":%s,"method":%s,"endpoint":%s,"query_shape":%s,"operation":%s,"wrapper":%s,"pulse_stage":%s,"auth_mode":%s,"auth_principal":%s,"http_status":%s,"request_id":%s,"body_classification":%s,"body_message_class":%s,"body_message_excerpt":%s,"caller_family":%s,"endpoint_family":%s,"headers":{"retry_after":%s,"x_ratelimit_limit":%s,"x_ratelimit_remaining":%s,"x_ratelimit_reset":%s,"x_ratelimit_used":%s,"x_ratelimit_resource":%s,"x_github_request_id":%s,"x_accepted_github_permissions":%s,"x_oauth_scopes":%s,"x_accepted_oauth_scopes":%s},"recent_403_count_1m":%s,"recent_403_count_5m":%s,"recent_secondary_count_5m":%s}}\n' \
		"$reason_json" "$now" "$expires" "$request_id_json" "$cooldown_action_json" "$reason_json" "$decision_branch_json" "$method_json" "$endpoint_json" "$query_shape_json" "$operation_json" "$wrapper_json" "$pulse_stage_json" "$auth_mode_json" "$auth_principal_json" "$status_json" "$request_id_json" "$body_classification_json" "$body_classification_json" "$body_excerpt_json" "$caller_family_json" "$endpoint_family_json" "$retry_after_json" "$ratelimit_limit_json" "$ratelimit_remaining_json" "$ratelimit_reset_json" "$ratelimit_used_json" "$ratelimit_resource_json" "$request_id_json" "$accepted_permissions_json" "$oauth_scopes_json" "$accepted_oauth_scopes_json" "$recent_403_count_1m" "$recent_403_count_5m" "$recent_secondary_count_5m" >"${file}.tmp" || {
		printf 'Failed to write to %s\n' "${file}.tmp" >&2
		return 1
	}
	return 0
}

# Parses HTTP response metadata from response_text.
# Modifies these caller-local variables via Bash dynamic scoping:
#   status, retry_after, ratelimit_limit, ratelimit_remaining, ratelimit_reset,
#   ratelimit_used, ratelimit_resource, accepted_permissions, oauth_scopes,
#   accepted_oauth_scopes
_gh_secondary_cooldown_parse_response_metadata() {
	local response_text="$1"
	local meta_line=""
	local meta_key=""
	local meta_value=""
	while IFS= read -r meta_line || [[ -n "$meta_line" ]]; do
		meta_line="${meta_line%$'\r'}"
		[[ -n "$meta_line" ]] || break
		if [[ "$meta_line" =~ ^HTTP/[0-9.]+[[:space:]]+([0-9]+) ]]; then
			status="${BASH_REMATCH[1]}"
			continue
		fi
		[[ "$meta_line" =~ ^([^:]+):[[:space:]]*(.*)$ ]] || continue
		meta_key="${BASH_REMATCH[1]}"
		meta_value="${BASH_REMATCH[2]}"
		meta_value="${meta_value%"${meta_value##*[![:space:]]}"}"
		case "$meta_key" in
		[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]) retry_after="$meta_value" ;;
		[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Ll][Ii][Mm][Ii][Tt]) ratelimit_limit="$meta_value" ;;
		[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Mm][Aa][Ii][Nn][Ii][Ng]) ratelimit_remaining="$meta_value" ;;
		[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Ss][Ee][Tt]) ratelimit_reset="$meta_value" ;;
		[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Uu][Ss][Ee][Dd]) ratelimit_used="$meta_value" ;;
		[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Ss][Oo][Uu][Rr][Cc][Ee]) ratelimit_resource="$meta_value" ;;
		[Xx]-[Aa][Cc][Cc][Ee][Pp][Tt][Ee][Dd]-[Gg][Ii][Tt][Hh][Uu][Bb]-[Pp][Ee][Rr][Mm][Ii][Ss][Ss][Ii][Oo][Nn][Ss]) accepted_permissions="$meta_value" ;;
		[Xx]-[Oo][Aa][Uu][Tt][Hh]-[Ss][Cc][Oo][Pp][Ee][Ss]) oauth_scopes="$meta_value" ;;
		[Xx]-[Aa][Cc][Cc][Ee][Pp][Tt][Ee][Dd]-[Oo][Aa][Uu][Tt][Hh]-[Ss][Cc][Oo][Pp][Ee][Ss]) accepted_oauth_scopes="$meta_value" ;;
		*) ;;
		esac
	done <<<"$response_text"
	return 0
}

_gh_secondary_cooldown_write_until() {
	local reason="$1"
	local response_text="${2:-}"
	local expires_at="${3:-}"
	local decision_branch="${4:-$reason}"
	local cooldown_action="${5:-$_GH_SECONDARY_COOLDOWN_ACTION_CREATED}"
	local method_arg="${6:-}"
	local endpoint_arg="${7:-}"
	local query_shape_arg="${8:-}"
	local operation_arg="${9:-}"
	local wrapper_arg="${10:-}"
	local pulse_stage_arg="${11:-}"
	local now=""
	local expires=""
	local file=""
	local dir=""
	local request_id=""
	local status=""
	local retry_after=""
	local ratelimit_limit=""
	local ratelimit_remaining=""
	local ratelimit_reset=""
	local ratelimit_used=""
	local ratelimit_resource=""
	local accepted_permissions=""
	local oauth_scopes=""
	local accepted_oauth_scopes=""
	local body_classification=""
	local body_excerpt=""
	local caller_family=""
	local endpoint_family=""
	local method=""
	local endpoint=""
	local query_shape=""
	local operation=""
	local operation_source=""
	local wrapper=""
	local wrapper_source=""
	local pulse_stage=""
	local pulse_stage_source=""
	local auth_mode=""
	local auth_principal=""
	local recent_403_count_1m="0"
	local recent_403_count_5m="0"
	local recent_secondary_count_5m="0"
	now="$(_gh_secondary_cooldown_now)"
	if [[ "$expires_at" =~ ^[0-9]+$ && "$expires_at" -gt "$now" ]]; then
		expires="$expires_at"
	else
		expires=$((now + AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS))
	fi
	file="$(_gh_secondary_cooldown_file)"
	dir="${file%/*}"
	request_id="$(_gh_secondary_cooldown_request_id "$response_text")"
	_gh_secondary_cooldown_parse_response_metadata "$response_text"
	body_classification="$(_gh_secondary_cooldown_body_classification "$response_text" "$status" "$ratelimit_remaining")"
	body_excerpt="$(_gh_secondary_cooldown_body_message_excerpt "$response_text")"
	caller_family="$(_gh_secondary_cooldown_caller_family)"
	endpoint_family="$(_gh_secondary_cooldown_endpoint_family "$endpoint_arg")"
	method="$(_gh_secondary_cooldown_method "$method_arg")"
	endpoint="$(_gh_secondary_cooldown_sanitized_endpoint "$endpoint_arg")"
	query_shape="$(_gh_secondary_cooldown_sanitized_query_shape "$query_shape_arg" "$endpoint_arg")"
	operation_source="${operation_arg:-${AIDEVOPS_GH_COOLDOWN_OPERATION:-$_GH_SECONDARY_COOLDOWN_UNKNOWN}}"
	wrapper_source="${wrapper_arg:-${AIDEVOPS_GH_COOLDOWN_WRAPPER:-$caller_family}}"
	pulse_stage_source="${pulse_stage_arg:-${AIDEVOPS_GH_COOLDOWN_STAGE:-$_GH_SECONDARY_COOLDOWN_UNKNOWN}}"
	operation="$(_gh_secondary_cooldown_safe_family "$operation_source" 120)"
	wrapper="$(_gh_secondary_cooldown_safe_family "$wrapper_source" 120)"
	pulse_stage="$(_gh_secondary_cooldown_safe_family "$pulse_stage_source" 120)"
	auth_mode="$(_gh_secondary_cooldown_auth_mode)"
	auth_principal="$(_gh_secondary_cooldown_auth_principal "" "$auth_mode")"
	_gh_secondary_cooldown_record_event "$cooldown_action" "$reason" "$decision_branch" "$response_text" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg" "$now"
	recent_403_count_1m="$(_gh_secondary_cooldown_recent_event_count http_status 403 60 "$now")"
	recent_403_count_5m="$(_gh_secondary_cooldown_recent_event_count http_status 403 300 "$now")"
	recent_secondary_count_5m="$(_gh_secondary_cooldown_recent_secondary_count 300 "$now")"
	[[ "$recent_403_count_1m" =~ ^[0-9]+$ ]] || recent_403_count_1m="0"
	[[ "$recent_403_count_5m" =~ ^[0-9]+$ ]] || recent_403_count_5m="0"
	[[ "$recent_secondary_count_5m" =~ ^[0-9]+$ ]] || recent_secondary_count_5m="0"
	mkdir -p "$dir" 2>/dev/null || return 1

	if command -v jq >/dev/null 2>&1; then
		_gh_secondary_cooldown_write_state_jq "$file" || return 1
	else
		_gh_secondary_cooldown_write_state_fallback "$file" || return 1
	fi
	mv "${file}.tmp" "$file" || return 1
	printf '[gh-cooldown] secondary-rate-limit active=true expires_at=%s reason=%s\n' "$expires" "$reason" >&2
	return 0
}

_gh_secondary_cooldown_write() {
	local reason="$1"
	local response_text="${2:-}"
	_gh_secondary_cooldown_write_until "$reason" "$response_text" ""
	return $?
}

_gh_secondary_cooldown_header_value() {
	local response_text="$1"
	local header_name="$2"
	printf '%s\n' "$response_text" | awk -v name="$header_name" '
		BEGIN { target = tolower(name) ":" }
		{ line = $0; sub(/\r$/, "", line); if (line == "") { exit } lower = tolower(line); if (index(lower, target) == 1) { sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]+$/, "", line); print line; exit } }
	' 2>/dev/null
	return 0
}

_gh_secondary_cooldown_status() {
	local response_text="$1"
	printf '%s\n' "$response_text" | awk '
		{ line = $0; sub(/\r$/, "", line); if (line == "") { exit } }
		line ~ /^HTTP\// { split(line, parts, /[[:space:]]+/); print parts[2]; exit }
	' 2>/dev/null || printf ''
	return 0
}

_gh_secondary_cooldown_header_expires_at() {
	local response_text="$1"
	local now=""
	local retry_after=""
	local reset_at=""

	now="$(_gh_secondary_cooldown_now)"
	retry_after="$(_gh_secondary_cooldown_header_value "$response_text" "retry-after")"
	if [[ "$retry_after" =~ ^[0-9]+$ && "$retry_after" -gt 0 ]]; then
		printf '%s' $((now + retry_after))
		return 0
	fi
	reset_at="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-reset")"
	if [[ "$reset_at" =~ ^[0-9]+$ && "$reset_at" -gt "$now" ]]; then
		printf '%s' "$reset_at"
		return 0
	fi
	printf '%s' $((now + AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS))
	return 0
}

_gh_secondary_cooldown_rest_reset_at() {
	local endpoint_arg="${1:-}"
	# The native transport boundary already owns response headers. Do not
	# recursively query a projection while recording a stopped transport.
	[[ "${AIDEVOPS_GH_COOLDOWN_NO_PROBE:-0}" != 1 ]] || return 1
	local endpoint_family=""
	local resource_key="core"
	local reset_at=""
	local now=""
	endpoint_family="$(_gh_secondary_cooldown_endpoint_family "$endpoint_arg")"
	case "$endpoint_family" in
	rest-core) resource_key="core" ;;
	rest-search) resource_key="search" ;;
	*) return 1 ;;
	esac
	command -v gh >/dev/null 2>&1 || return 1
	reset_at=$(gh api rate_limit --jq ".resources.${resource_key} | select(.remaining == 0) | .reset" 2>/dev/null || true)
	now="$(_gh_secondary_cooldown_now)"
	if [[ "$reset_at" =~ ^[0-9]+$ && "$reset_at" -gt "$now" ]]; then
		printf '%s' "$reset_at"
		return 0
	fi
	return 1
}

_gh_search_cooldown_preflight() {
	local arg="" search_request=0
	for arg in "$@"; do
		case "$arg" in search | search/* | /search/*) search_request=1 ;; esac
	done
	[[ "$search_request" -eq 1 ]] || return 0
	local AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-search"
	if _gh_secondary_cooldown_active; then
		printf '[gh-cooldown] primary-search active=true; unrelated API resources remain available\n' >&2
		return 75
	fi
	return 0
}

_gh_search_primary_response() {
	local response="$1"
	shift
	local status="" remaining="" resource="" reset="" now=""
	status=$(_gh_secondary_cooldown_status "$response")
	case "$status" in 200 | 403) ;; *) return 1 ;; esac
	remaining=$(_gh_secondary_cooldown_header_value "$response" "x-ratelimit-remaining")
	resource=$(_gh_secondary_cooldown_header_value "$response" "x-ratelimit-resource")
	[[ "$remaining" == "0" && "$resource" == "search" ]] || return 1
	[[ -z "$(_gh_secondary_cooldown_header_value "$response" "retry-after")" ]] || return 1
	_gh_secondary_cooldown_detect "$response" && return 1
	reset=$(_gh_secondary_cooldown_header_value "$response" "x-ratelimit-reset")
	now=$(_gh_secondary_cooldown_now)
	[[ "$reset" =~ ^[0-9]{1,10}$ && "$reset" -le $((now + 3600)) ]] || return 1
	# A successful last search request is primary-resource evidence, not abuse.
	# Already-reset headers do not authorize a fabricated five-minute global hold.
	[[ "$reset" -gt "$now" ]] || return 0
	local AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-search"
	_gh_secondary_cooldown_write_until "github-search-primary-exhausted" "$response" "$reset" \
		"primary-search" "$_GH_SECONDARY_COOLDOWN_ACTION_CREATED" "$@"
	return $?
}

_gh_secondary_cooldown_record_response_if_needed() {
	local rc="$1"
	local response_text="${2:-}"
	local method_arg="${3:-}"
	local endpoint_arg="${4:-}"
	local query_shape_arg="${5:-}"
	local operation_arg="${6:-}"
	local wrapper_arg="${7:-}"
	local pulse_stage_arg="${8:-}"
	local status=""
	local remaining=""
	local retry_after=""
	local body_classification=""
	local expires_at=""

	if _gh_search_primary_response "$response_text" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg"; then
		return 0
	fi
	status="$(_gh_secondary_cooldown_status "$response_text")"
	remaining="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-remaining")"
	retry_after="$(_gh_secondary_cooldown_header_value "$response_text" "retry-after")"
	body_classification="$(_gh_secondary_cooldown_body_classification "$response_text" "$status" "$remaining")"
	case "$status" in
	403)
		if _gh_secondary_cooldown_diagnostic_only_403 "$status" "$retry_after" "$remaining" "$body_classification"; then
			_gh_secondary_cooldown_record_event "diagnostic-only" "github-api-forbidden-status-403" "status-403-diagnostic-only" "$response_text" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg"
			return 0
		fi
		expires_at="$(_gh_secondary_cooldown_header_expires_at "$response_text")"
		if [[ -z "$retry_after" ]] && ! [[ "$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-reset")" =~ ^[0-9]+$ ]]; then
			expires_at="$(_gh_secondary_cooldown_rest_reset_at "$endpoint_arg" || printf '%s' "$expires_at")"
		fi
		_gh_secondary_cooldown_write_until "github-api-rate-limit-status-${status}" "$response_text" "$expires_at" "status-${status}" "$_GH_SECONDARY_COOLDOWN_ACTION_CREATED" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg" || true
		return 0
		;;
	429)
		expires_at="$(_gh_secondary_cooldown_header_expires_at "$response_text")"
		if [[ -z "$retry_after" ]] && ! [[ "$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-reset")" =~ ^[0-9]+$ ]]; then
			expires_at="$(_gh_secondary_cooldown_rest_reset_at "$endpoint_arg" || printf '%s' "$expires_at")"
		fi
		_gh_secondary_cooldown_write_until "github-api-rate-limit-status-${status}" "$response_text" "$expires_at" "status-${status}" "$_GH_SECONDARY_COOLDOWN_ACTION_CREATED" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg" || true
		return 0
		;;
	esac
	if [[ "$remaining" =~ ^[0-9]+$ && "$remaining" -eq 0 ]]; then
		expires_at="$(_gh_secondary_cooldown_header_expires_at "$response_text")"
		if [[ -z "$retry_after" ]] && ! [[ "$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-reset")" =~ ^[0-9]+$ ]]; then
			expires_at="$(_gh_secondary_cooldown_rest_reset_at "$endpoint_arg" || printf '%s' "$expires_at")"
		fi
		_gh_secondary_cooldown_write_until "github-api-rate-limit-remaining-zero" "$response_text" "$expires_at" "remaining-zero" "$_GH_SECONDARY_COOLDOWN_ACTION_CREATED" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg" || true
		return 0
	fi
	if [[ "$rc" -ne 0 ]]; then
		_gh_secondary_cooldown_detect "$response_text" || return 0
		_gh_secondary_cooldown_write_until "github-secondary-rate-limit" "$response_text" "" "secondary-text" "$_GH_SECONDARY_COOLDOWN_ACTION_CREATED" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg" || true
	fi
	return 0
}

_gh_secondary_cooldown_expires_at() {
	local file=""
	file="$(_gh_secondary_cooldown_file)"
	[[ -f "$file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -r '.expires_at // 0' "$file" 2>/dev/null
		return 0
	fi
	sed -nE 's/.*"expires_at"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$file" | sed -n '1p'
	return 0
}

_gh_secondary_cooldown_active() {
	local expires=""
	local now=""
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$expires" =~ ^[0-9]+$ ]] || return 1
	now="$(_gh_secondary_cooldown_now)"
	[[ "$expires" -gt "$now" ]] || return 1
	return 0
}

_gh_secondary_system_boot_ts() {
	local boot_ts=""
	if [[ -r /proc/stat ]]; then
		boot_ts=$(sed -nE 's/^btime[[:space:]]+([0-9]+).*/\1/p' /proc/stat 2>/dev/null | sed -n '1p')
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	if command -v sysctl >/dev/null 2>&1; then
		boot_ts=$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*sec = ([0-9]+).*/\1/p' | sed -n '1p')
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	return 1
}

_gh_secondary_read_ramp_phase() {
	local now=""
	local boot_ts=""
	local expires=""
	now="$(_gh_secondary_cooldown_now)"
	boot_ts="$(_gh_secondary_system_boot_ts 2>/dev/null || true)"
	if [[ "$boot_ts" =~ ^[0-9]+$ && "$AIDEVOPS_GH_READ_RAMP_BOOT_SECS" =~ ^[0-9]+$ ]]; then
		if [[ "$now" -ge "$boot_ts" && $((now - boot_ts)) -lt "$AIDEVOPS_GH_READ_RAMP_BOOT_SECS" ]]; then
			printf 'boot'
			return 0
		fi
	fi
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	if [[ "$expires" =~ ^[0-9]+$ && "$AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS" =~ ^[0-9]+$ ]]; then
		if [[ "$now" -ge "$expires" && $((now - expires)) -lt "$AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS" ]]; then
			printf 'cooldown-recovery'
			return 0
		fi
	fi
	return 1
}

_gh_secondary_read_ramp_state_file() {
	printf '%s' "$AIDEVOPS_GH_READ_RAMP_STATE_FILE"
	return 0
}

_gh_secondary_read_ramp_take_token() {
	local phase="$1"
	local now=""
	local minute=""
	local file=""
	local dir=""
	local lock_dir=""
	local old_phase=""
	local old_minute=""
	local old_count=""
	local count=0
	[[ "$AIDEVOPS_GH_READ_RAMP_BUDGET" =~ ^[0-9]+$ && "$AIDEVOPS_GH_READ_RAMP_BUDGET" -gt 0 ]] || return 0
	now="$(_gh_secondary_cooldown_now)"
	minute=$((now / 60))
	file="$(_gh_secondary_read_ramp_state_file)"
	dir="${file%/*}"
	lock_dir="${file}.lock"
	mkdir -p "$dir" 2>/dev/null || return 0
	if ! mkdir "$lock_dir" 2>/dev/null; then
		return 0
	fi
	if [[ -r "$file" ]]; then
		IFS=$'\t' read -r old_phase old_minute old_count <"$file" || true
	fi
	if [[ "$old_phase" == "$phase" && "$old_minute" == "$minute" && "$old_count" =~ ^[0-9]+$ ]]; then
		count="$old_count"
	fi
	if [[ "$count" -ge "$AIDEVOPS_GH_READ_RAMP_BUDGET" ]]; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi
	count=$((count + 1))
	printf '%s\t%s\t%s\n' "$phase" "$minute" "$count" >"${file}.tmp" 2>/dev/null || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	}
	mv "${file}.tmp" "$file" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_gh_secondary_read_ramp_log_deferred() {
	local phase="$1"
	local budget="$AIDEVOPS_GH_READ_RAMP_BUDGET"
	if [[ "$_GH_SECONDARY_COOLDOWN_LOGGED_RAMP" -eq 1 ]]; then
		return 0
	fi
	printf '[gh-cooldown] read-ramp active=true phase=%s budget_per_minute=%s action=defer\n' "$phase" "$budget" >&2
	_GH_SECONDARY_COOLDOWN_LOGGED_RAMP=1
	return 0
}

_gh_secondary_read_ramp_preflight() {
	local op_class="${1:-}"
	local phase=""
	[[ -n "$op_class" ]] || op_class="$_GH_SECONDARY_READ_OP"
	[[ "${AIDEVOPS_GH_READ_RAMP_ENABLED:-1}" == "1" ]] || return 0
	[[ "$op_class" == "$_GH_SECONDARY_READ_OP" ]] || return 0
	[[ "${AIDEVOPS_GH_READ_RAMP_OVERRIDE:-0}" == "1" ]] && return 0
	phase="$(_gh_secondary_read_ramp_phase 2>/dev/null || true)"
	[[ -n "$phase" ]] || return 0
	_gh_secondary_read_ramp_take_token "$phase" && return 0
	_gh_secondary_read_ramp_log_deferred "$phase"
	return 75
}

_gh_secondary_cooldown_log_active_once() {
	local op_class="$1"
	local expires=""
	if [[ "$_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE" -eq 1 ]]; then
		return 0
	fi
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || printf 'unknown')"
	printf '[gh-cooldown] secondary-rate-limit active=true skip=%s expires_at=%s\n' "$op_class" "$expires" >&2
	_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=1
	return 0
}

_gh_secondary_cooldown_preflight() {
	local op_class="${1:-}"
	[[ -n "$op_class" ]] || op_class="$_GH_SECONDARY_READ_OP"
	if ! _gh_secondary_cooldown_active; then
		_gh_secondary_read_ramp_preflight "$op_class" || return $?
		return 0
	fi
	if [[ "${AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE:-0}" == "1" ]]; then
		printf '[gh-cooldown] secondary-rate-limit override=true op=%s actor=%s\n' \
			"$op_class" "${GITHUB_ACTOR:-${USER:-unknown}}" >&2
		return 0
	fi
	_gh_secondary_cooldown_log_active_once "$op_class"
	return 75
}

_gh_secondary_cooldown_record_if_needed() {
	local rc="$1"
	local response_text="${2:-}"
	local method_arg="${3:-}"
	local endpoint_arg="${4:-}"
	local query_shape_arg="${5:-}"
	local operation_arg="${6:-}"
	local wrapper_arg="${7:-}"
	local pulse_stage_arg="${8:-}"
	_gh_secondary_cooldown_record_response_if_needed "$rc" "$response_text" "$method_arg" "$endpoint_arg" "$query_shape_arg" "$operation_arg" "$wrapper_arg" "$pulse_stage_arg"
	return 0
}
