#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Conservative primary-rate quota attribution for direct `gh api` REST calls.
# The caller may record the returned value only after the command succeeds.
# Ambiguous transports intentionally return no value so benchmark evidence
# remains fail-closed rather than estimating cost from cumulative headers.

[[ -n "${_GH_QUOTA_ATTRIBUTION_LOADED:-}" ]] && return 0
_GH_QUOTA_ATTRIBUTION_LOADED=1

_GHQA_SOURCE="${BASH_SOURCE[0]:-$0}"
_GHQA_DIR="${_GHQA_SOURCE%/*}"
[[ "$_GHQA_DIR" != "$_GHQA_SOURCE" ]] || _GHQA_DIR="."
_GHQA_TRANSPORT_HANDLED=0

_GHQA_ENDPOINT=""
_GHQA_HOSTNAME=""
_GHQA_METHOD=""
_GHQA_FIELDS_REQUESTED=0
_GHQA_INPUT_REQUESTED=0
_GHQA_AMBIGUOUS=0

_ghqa_lower() {
	local value="$1"
	printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]'
	return 0
}

_ghqa_is_conditional_header() {
	local header="$1"
	header=$(_ghqa_lower "$header")
	[[ "$header" =~ ^[[:space:]]*if-(match|none-match|modified-since|unmodified-since)[[:space:]]*: ]]
	return $?
}

_ghqa_apply_option_value() {
	local option="$1"
	local value="$2"
	case "$option" in
	-X | --method) _GHQA_METHOD=$(_ghqa_lower "$value") ;;
	-H | --header)
		_ghqa_is_conditional_header "$value" && _GHQA_AMBIGUOUS=1
		;;
	--hostname) _GHQA_HOSTNAME=$(_ghqa_lower "$value") ;;
	-F | --field | -f | --raw-field) _GHQA_FIELDS_REQUESTED=1 ;;
	--input) _GHQA_INPUT_REQUESTED=1 ;;
	--cache) _GHQA_AMBIGUOUS=1 ;;
	-q | --jq | -p | --preview | -t | --template) ;;
	*) _GHQA_AMBIGUOUS=1 ;;
	esac
	return 0
}

_ghqa_parse_api_args() {
	local path="$1"
	shift
	local arg=""
	local option=""
	local value=""
	_GHQA_ENDPOINT=""
	_GHQA_HOSTNAME=$(_ghqa_lower "${GH_HOST:-github.com}")
	_GHQA_METHOD=""
	_GHQA_FIELDS_REQUESTED=0
	_GHQA_INPUT_REQUESTED=0
	_GHQA_AMBIGUOUS=0
	[[ ("$path" == "rest" || "$path" == "search-rest") && "${1:-}" == "api" ]] || return 1
	shift
	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--paginate) _GHQA_AMBIGUOUS=1 ;;
		--include | -i | --silent | --slurp | --verbose) ;;
		-X | --method | -H | --header | --hostname | -F | --field | -f | --raw-field | --input | --cache | -q | --jq | -p | --preview | -t | --template)
			if [[ $# -eq 0 ]]; then
				_GHQA_AMBIGUOUS=1
				continue
			fi
			value="$1"
			shift
			_ghqa_apply_option_value "$arg" "$value"
			;;
		--method=* | --header=* | --hostname=* | --field=* | --raw-field=* | --input=* | --cache=* | --jq=* | --preview=* | --template=*)
			option="${arg%%=*}"
			value="${arg#*=}"
			_ghqa_apply_option_value "$option" "$value"
			;;
		-X?*) _ghqa_apply_option_value -X "${arg#-X}" ;;
		-H?*) _ghqa_apply_option_value -H "${arg#-H}" ;;
		-F?*) _ghqa_apply_option_value -F "${arg#-F}" ;;
		-f?*) _ghqa_apply_option_value -f "${arg#-f}" ;;
		-q?*) _ghqa_apply_option_value -q "${arg#-q}" ;;
		-p?*) _ghqa_apply_option_value -p "${arg#-p}" ;;
		-t?*) _ghqa_apply_option_value -t "${arg#-t}" ;;
		-*) _GHQA_AMBIGUOUS=1 ;;
		*)
			if [[ -z "$_GHQA_ENDPOINT" ]]; then
				_GHQA_ENDPOINT="$arg"
			else
				_GHQA_AMBIGUOUS=1
			fi
			;;
		esac
	done
	[[ -n "$_GHQA_ENDPOINT" ]] || return 1
	return 0
}

_ghqa_normalize_endpoint() {
	local endpoint="$1"
	case "$endpoint" in
	https://api.github.com/*) endpoint="${endpoint#https://api.github.com/}" ;;
	https://github.com/api/v3/*) endpoint="${endpoint#https://github.com/api/v3/}" ;;
	http://* | https://* | *://*) return 1 ;;
	esac
	endpoint="${endpoint#/}"
	endpoint="${endpoint#api/v3/}"
	endpoint="${endpoint%%\?*}"
	endpoint="${endpoint%%#*}"
	[[ -n "$endpoint" ]] || return 1
	printf '%s' "$endpoint"
	return 0
}

# _ghqa_exact_success_cost <path> <gh argv...>
# Print an exact documented primary-rate cost only when one direct REST request
# is attributable after successful execution. Empty output/non-zero is unknown.
_ghqa_exact_success_cost() {
	local path="$1"
	shift
	local endpoint=""
	local method=""
	_ghqa_parse_api_args "$path" "$@" || return 1
	[[ "$_GHQA_AMBIGUOUS" -eq 0 && "$_GHQA_HOSTNAME" == "github.com" ]] || return 1
	endpoint=$(_ghqa_normalize_endpoint "$_GHQA_ENDPOINT") || return 1
	[[ "$endpoint" != "graphql" && "$endpoint" != graphql/* ]] || return 1
	method="$_GHQA_METHOD"
	if [[ -z "$method" ]]; then
		method="get"
		if [[ "$_GHQA_FIELDS_REQUESTED" -eq 1 || "$_GHQA_INPUT_REQUESTED" -eq 1 ]]; then
			method="post"
		fi
	fi
	if [[ "$method" == "get" && "$endpoint" == "rate_limit" ]]; then
		printf '0'
		return 0
	fi
	printf '1'
	return 0
}

_ghqa_target_host() {
	local arg=""
	local host="${GH_HOST:-github.com}"
	local expect_host=0
	for arg in "$@"; do
		if [[ "$expect_host" -eq 1 ]]; then
			host="$arg"
			expect_host=0
			continue
		fi
		case "$arg" in
		--hostname) expect_host=1 ;;
		--hostname=*) host="${arg#--hostname=}" ;;
		esac
	done
	[[ "$expect_host" -eq 0 ]] || return 1
	host=$(_ghqa_lower "$host")
	[[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
	printf '%s' "$host"
	return 0
}

_ghqa_sha256_stdin() {
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(shasum -a 256 2>/dev/null | awk '{print $1}') || digest=""
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum 2>/dev/null | awk '{print $1}') || digest=""
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(openssl dgst -sha256 2>/dev/null | awk '{print $NF}') || digest=""
	else
		return 1
	fi
	[[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
	printf '%s' "$digest"
	return 0
}

_ghqa_auth_fingerprint() {
	local executable="$1"
	local host="$2"
	local token=""
	local digest=""
	if [[ -n "${GH_TOKEN:-}" ]]; then
		token="$GH_TOKEN"
	elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
		token="$GITHUB_TOKEN"
	else
		token=$("$executable" auth token --hostname "$host" 2>/dev/null) || token=""
	fi
	[[ -n "$token" ]] || return 1
	digest=$(printf '%s\037%s' "$host" "$token" | _ghqa_sha256_stdin) || digest=""
	token=""
	[[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
	printf '%s' "$digest"
	return 0
}

_ghqa_prepare_private_dir() {
	local directory="$1"
	[[ -n "$directory" && "$directory" == /* ]] || return 1
	if [[ -L "$directory" ]]; then
		return 1
	fi
	mkdir -p "$directory" 2>/dev/null || return 1
	[[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || return 1
	chmod 0700 "$directory" 2>/dev/null || return 1
	return 0
}

_ghqa_lock_reclaim() {
	local lock_dir="$1"
	local tries="$2"
	local pid_file="${lock_dir}/pid"
	local owner=""
	[[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
	if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
		IFS= read -r owner <"$pid_file" 2>/dev/null || owner=""
		if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
			return 1
		fi
		rm -f "$pid_file" 2>/dev/null || return 1
		rmdir "$lock_dir" 2>/dev/null || return 1
		return 0
	fi
	[[ "$tries" -ge 100 ]] || return 1
	rm -f "$pid_file" 2>/dev/null || return 1
	rmdir "$lock_dir" 2>/dev/null || return 1
	return 0
}

_ghqa_lock_acquire() {
	local lock_dir="$1"
	local max_tries="${AIDEVOPS_GH_QUOTA_LOCK_TRIES:-3000}"
	local tries=0
	local owner_pid="${BASHPID:-$$}"
	[[ "$max_tries" =~ ^[0-9]+$ && "$max_tries" -gt 0 ]] || max_tries=3000
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if _ghqa_lock_reclaim "$lock_dir" "$tries"; then
			tries=0
			continue
		fi
		tries=$((tries + 1))
		[[ "$tries" -lt "$max_tries" ]] || return 1
		sleep 0.01 2>/dev/null || return 1
	done
	if ! printf '%s\n' "$owner_pid" >"${lock_dir}/pid" 2>/dev/null; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi
	return 0
}

_ghqa_lock_release() {
	local lock_dir="$1"
	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_ghqa_state_get() {
	local state_file="$1"
	local requested_resource="$2"
	local resource=""
	local used=""
	local reset=""
	[[ -f "$state_file" && ! -L "$state_file" ]] || return 1
	while IFS=$'\t' read -r resource used reset; do
		[[ "$resource" == "$requested_resource" ]] || continue
		[[ "$used" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ ]] || return 1
		printf '%s\t%s\n' "$used" "$reset"
		return 0
	done <"$state_file"
	return 1
}

_ghqa_state_write_all() {
	local state_file="$1"
	local core_used="$2"
	local core_reset="$3"
	local graphql_used="$4"
	local graphql_reset="$5"
	local search_used="$6"
	local search_reset="$7"
	local temporary=""
	local pair_count=0
	if [[ -n "$core_used" || -n "$core_reset" ]]; then
		[[ "$core_used" =~ ^[0-9]+$ && "$core_reset" =~ ^[0-9]+$ ]] || return 1
		pair_count=$((pair_count + 1))
	fi
	if [[ -n "$graphql_used" || -n "$graphql_reset" ]]; then
		[[ "$graphql_used" =~ ^[0-9]+$ && "$graphql_reset" =~ ^[0-9]+$ ]] || return 1
		pair_count=$((pair_count + 1))
	fi
	if [[ -n "$search_used" || -n "$search_reset" ]]; then
		[[ "$search_used" =~ ^[0-9]+$ && "$search_reset" =~ ^[0-9]+$ ]] || return 1
		pair_count=$((pair_count + 1))
	fi
	[[ "$pair_count" -gt 0 ]] || return 1
	temporary=$(mktemp "${state_file}.tmp.XXXXXX" 2>/dev/null) || return 1
	chmod 0600 "$temporary" 2>/dev/null || {
		rm -f "$temporary" 2>/dev/null || true
		return 1
	}
	if ! {
		[[ -z "$core_used" ]] || printf 'core\t%s\t%s\n' "$core_used" "$core_reset"
		[[ -z "$graphql_used" ]] || printf 'graphql\t%s\t%s\n' "$graphql_used" "$graphql_reset"
		[[ -z "$search_used" ]] || printf 'search\t%s\t%s\n' "$search_used" "$search_reset"
	} >"$temporary"; then
		rm -f "$temporary" 2>/dev/null || true
		return 1
	fi
	mv "$temporary" "$state_file" 2>/dev/null || {
		rm -f "$temporary" 2>/dev/null || true
		return 1
	}
	return 0
}

_ghqa_state_update() {
	local state_file="$1"
	local requested_resource="$2"
	local requested_used="$3"
	local requested_reset="$4"
	local core_used core_reset graphql_used graphql_reset search_used search_reset
	local resource used reset
	[[ "$requested_used" =~ ^[0-9]+$ && "$requested_reset" =~ ^[0-9]+$ ]] || return 1
	if [[ -f "$state_file" && ! -L "$state_file" ]]; then
		while IFS=$'\t' read -r resource used reset; do
			[[ "$used" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ ]] || continue
			case "$resource" in
			core) core_used="$used"; core_reset="$reset" ;;
			graphql) graphql_used="$used"; graphql_reset="$reset" ;;
			search) search_used="$used"; search_reset="$reset" ;;
			esac
		done <"$state_file"
	fi
	case "$requested_resource" in
	core) core_used="$requested_used"; core_reset="$requested_reset" ;;
	graphql) graphql_used="$requested_used"; graphql_reset="$requested_reset" ;;
	search) search_used="$requested_used"; search_reset="$requested_reset" ;;
	*) return 1 ;;
	esac
	_ghqa_state_write_all "$state_file" "$core_used" "$core_reset" \
		"$graphql_used" "$graphql_reset" "$search_used" "$search_reset"
	return $?
}

_ghqa_state_complete() {
	local state_file="$1"
	local resource=""
	for resource in core graphql search; do
		_ghqa_state_get "$state_file" "$resource" >/dev/null || return 1
	done
	return 0
}

_ghqa_elapsed_ms() {
	local started_ms="$1"
	local finished_ms="$2"
	if [[ "$started_ms" =~ ^[0-9]+$ && "$finished_ms" =~ ^[0-9]+$ \
		&& "$finished_ms" -ge "$started_ms" ]]; then
		printf '%s' "$((finished_ms - started_ms))"
		return 0
	fi
	return 1
}

_ghqa_record_bootstrap() {
	local outcome="$1"
	local elapsed_ms="$2"
	local quota_cost="$3"
	local page="$4"
	local remaining="$5"
	local logical_id=""
	declare -F gh_record_attempt >/dev/null 2>&1 || return 0
	logical_id=$(gh_new_logical_id 2>/dev/null || true)
	gh_record_attempt rest gh-quota-bootstrap "$logical_id" "" "$page" 0 "$outcome" \
		"" "$elapsed_ms" "$quota_cost" "${AIDEVOPS_GH_AUTH_MODE:-gh-pat}" \
		rest-core quota-state-bootstrap "$remaining"
	return 0
}

_ghqa_bootstrap_state() {
	local executable="$1"
	local state_file="$2"
	local output=""
	local started_ms finished_ms elapsed_ms
	local core_used core_remaining core_reset
	local graphql_used graphql_remaining graphql_reset
	local search_used search_remaining search_reset
	started_ms=$(_gh_now_ms 2>/dev/null || true)
	if output=$(GH_DEBUG='' "$executable" api rate_limit --jq \
		'[.resources.core.used,.resources.core.remaining,.resources.core.reset,.resources.graphql.used,.resources.graphql.remaining,.resources.graphql.reset,.resources.search.used,.resources.search.remaining,.resources.search.reset] | @tsv' \
		2>/dev/null); then
		finished_ms=$(_gh_now_ms 2>/dev/null || true)
		elapsed_ms=$(_ghqa_elapsed_ms "$started_ms" "$finished_ms" 2>/dev/null || true)
		IFS=$'\t' read -r core_used core_remaining core_reset \
			graphql_used graphql_remaining graphql_reset \
			search_used search_remaining search_reset <<<"$output"
		if _ghqa_state_write_all "$state_file" "$core_used" "$core_reset" \
			"$graphql_used" "$graphql_reset" "$search_used" "$search_reset"; then
			_ghqa_record_bootstrap success "$elapsed_ms" 0 1 "$core_remaining"
			return 0
		fi
	fi
	finished_ms=$(_gh_now_ms 2>/dev/null || true)
	elapsed_ms=$(_ghqa_elapsed_ms "$started_ms" "$finished_ms" 2>/dev/null || true)
	_ghqa_record_bootstrap error "$elapsed_ms" "" 0 ""
	return 1
}

_ghqa_path_for_resource() {
	local original_path="$1"
	local resource="$2"
	case "$resource" in
	core) printf 'rest' ;;
	graphql) printf 'graphql' ;;
	search) printf 'search-rest' ;;
	*) printf '%s' "$original_path" ;;
	esac
	return 0
}

_ghqa_pool_for_resource() {
	local resource="$1"
	case "$resource" in
	core) printf 'rest-core' ;;
	graphql) printf 'graphql' ;;
	search) printf 'rest-search' ;;
	*) printf 'other' ;;
	esac
	return 0
}

_ghqa_write_fallback_attempt() {
	local result_file="$1"
	local path="$2"
	local page="$3"
	local outcome="$4"
	local elapsed_ms="$5"
	local quota_cost="$6"
	local decision="${AIDEVOPS_GH_ROUTE_DECISION:-}"
	local pool=""
	pool=$(_gh_default_pool "$path")
	[[ -n "$decision" ]] || decision="${pool}-selected"
	[[ -n "$elapsed_ms" ]] || elapsed_ms=x
	[[ -n "$quota_cost" ]] || quota_cost=x
	printf 'attempt\t%s\t%s\t%s\tx\t%s\t%s\t%s\t%s\tx\n' \
		"$path" "$page" "$outcome" "$elapsed_ms" "$quota_cost" "$pool" "$decision" \
		>>"$result_file"
	return 0
}

_ghqa_run_uncaptured_to_result() {
	local result_file="$1"
	local path="$2"
	local page="$3"
	shift 3
	local started_ms finished_ms elapsed_ms exact_success_cost
	local rc=0 outcome=success quota_cost="${AIDEVOPS_GH_QUOTA_COST:-}"
	started_ms=$(_gh_now_ms 2>/dev/null || true)
	if "$@"; then
		rc=0
		exact_success_cost=$(_ghqa_exact_success_cost "$path" "${@:2}" 2>/dev/null || true)
		[[ -n "$quota_cost" ]] || quota_cost="$exact_success_cost"
	else
		rc=$?
		outcome=error
	fi
	finished_ms=$(_gh_now_ms 2>/dev/null || true)
	elapsed_ms=$(_ghqa_elapsed_ms "$started_ms" "$finished_ms" 2>/dev/null || true)
	_ghqa_write_fallback_attempt "$result_file" "$path" "$page" "$outcome" "$elapsed_ms" "$quota_cost"
	return "$rc"
}

_ghqa_capture_cleanup() {
	local debug_file="$1"
	local lock_dir="$2"
	[[ -z "$debug_file" ]] || rm -f "$debug_file" 2>/dev/null || true
	[[ -z "$lock_dir" ]] || _ghqa_lock_release "$lock_dir"
	return 0
}

_ghqa_capture_frames_valid() {
	local parsed="$1"
	local expected_frames="$2"
	local kind frame_index status_count status resource used remaining reset elapsed
	local rows=0
	while IFS=$'\t' read -r kind frame_index status_count status resource used remaining reset elapsed; do
		[[ "$kind" == frame ]] || continue
		rows=$((rows + 1))
		[[ "$frame_index" =~ ^[1-9][0-9]*$ && "$status_count" == 1 ]] || return 1
		[[ "$status" =~ ^[0-9]{3}$ ]] || return 1
		case "$resource" in core | graphql | search) ;; *) return 1 ;; esac
		for value in "$used" "$remaining" "$reset" "$elapsed"; do
			[[ "$value" =~ ^[0-9]+$ ]] || return 1
		done
	done <<<"$parsed"
	[[ "$rows" -eq "$expected_frames" && "$rows" -gt 0 ]]
	return $?
}

_ghqa_command_is_local_only() {
	local executable="$1"
	shift
	local subcommand="${1:-}"
	: "$executable"
	case "$subcommand" in
	--help | --version | help | version | completion | config | alias) return 0 ;;
	esac
	return 1
}

_ghqa_response_cost() {
	local state_file="$1"
	local resource="$2"
	local used="$3"
	local reset="$4"
	local previous previous_used previous_reset delta
	previous=$(_ghqa_state_get "$state_file" "$resource" 2>/dev/null || true)
	IFS=$'\t' read -r previous_used previous_reset <<<"$previous"
	if [[ "$previous_used" =~ ^[0-9]+$ && "$previous_reset" == "$reset" \
		&& "$used" -ge "$previous_used" ]]; then
		delta=$((used - previous_used))
	elif [[ "$previous_reset" =~ ^[0-9]+$ && "$previous_reset" != "$reset" ]]; then
		delta="$used"
	fi
	if [[ "$delta" == 1 ]]; then
		printf '1'
		return 0
	fi
	return 1
}

_ghqa_write_complete_frames() {
	local result_file="$1"
	local state_file="$2"
	local original_path="$3"
	local original_page="$4"
	local command_rc="$5"
	local parsed="$6"
	shift 6
	local kind frame_index status_count status resource used remaining reset elapsed
	local frame_total=0 path pool page outcome quota_cost exact_success_cost decision
	frame_total=$(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "frame" { count++ } END { print count + 0 }')
	if [[ "$command_rc" -eq 0 && "$frame_total" -eq 1 ]]; then
		exact_success_cost=$(_ghqa_exact_success_cost "$original_path" "${@:2}" 2>/dev/null || true)
	fi
	while IFS=$'\t' read -r kind frame_index status_count status resource used remaining reset elapsed; do
		[[ "$kind" == frame ]] || continue
		path=$(_ghqa_path_for_resource "$original_path" "$resource")
		pool=$(_ghqa_pool_for_resource "$resource")
		page="$original_page"
		[[ "$frame_total" -eq 1 ]] || page="$frame_index"
		outcome=success
		if [[ "$status" -ge 400 || ( "$frame_index" -eq "$frame_total" && "$command_rc" -ne 0 ) ]]; then
			outcome=error
		fi
		quota_cost=""
		if [[ "$frame_total" -eq 1 && -n "${AIDEVOPS_GH_QUOTA_COST:-}" ]]; then
			quota_cost="$AIDEVOPS_GH_QUOTA_COST"
		elif [[ -n "$exact_success_cost" ]]; then
			quota_cost="$exact_success_cost"
		else
			quota_cost=$(_ghqa_response_cost "$state_file" "$resource" "$used" "$reset" 2>/dev/null || true)
		fi
		[[ -n "$quota_cost" ]] || quota_cost=x
		# Always advance the observed counter state, including operation-owned
		# costs, so the next response can prove or reject continuity.
		_ghqa_state_update "$state_file" "$resource" "$used" "$reset" 2>/dev/null || true
		decision="${AIDEVOPS_GH_ROUTE_DECISION:-${pool}-selected}"
		printf 'attempt\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$path" "$page" "$outcome" "$status" "$elapsed" "$quota_cost" \
			"$pool" "$decision" "$remaining" >>"$result_file"
	done <<<"$parsed"
	return 0
}

_ghqa_capture_locked() {
	local result_file="$1"
	local state_file="$2"
	local lock_dir="$3"
	local temp_dir="$4"
	local parser="$5"
	local path="$6"
	local page="$7"
	shift 7
	local debug_file parsed header version frame_count
	local started_ms finished_ms elapsed_ms rc=0
	trap '_ghqa_capture_cleanup "$debug_file" "$lock_dir"' EXIT HUP INT TERM
	if ! _ghqa_lock_acquire "$lock_dir"; then
		lock_dir=""
		_ghqa_run_uncaptured_to_result "$result_file" "$path" "$page" "$@"
		return $?
	fi
	_ghqa_state_complete "$state_file" || _ghqa_bootstrap_state "$1" "$state_file" || true
	debug_file=$(mktemp "${temp_dir}/gh-quota-debug.XXXXXX" 2>/dev/null) || {
		_ghqa_run_uncaptured_to_result "$result_file" "$path" "$page" "$@"
		return $?
	}
	chmod 0600 "$debug_file" 2>/dev/null || {
		_ghqa_run_uncaptured_to_result "$result_file" "$path" "$page" "$@"
		return $?
	}
	started_ms=$(_gh_now_ms 2>/dev/null || true)
	if GH_DEBUG=api "$@" 2>"$debug_file"; then
		rc=0
	else
		rc=$?
	fi
	finished_ms=$(_gh_now_ms 2>/dev/null || true)
	elapsed_ms=$(_ghqa_elapsed_ms "$started_ms" "$finished_ms" 2>/dev/null || true)
	if ! parsed=$(python3 "$parser" "$debug_file"); then
		printf '[aidevops] gh quota telemetry suppressed unsanitized native diagnostics\n' >&2
		parsed=""
	fi
	rm -f "$debug_file" 2>/dev/null || true
	debug_file=""
	header=$(printf '%s\n' "$parsed" | awk -F '\t' '$1 == "v1" { print; exit }')
	IFS=$'\t' read -r version frame_count <<<"$header"
	if [[ "$version" == v1 && "$frame_count" == 0 ]]; then
		if [[ "$rc" -ne 0 ]]; then
			printf '[aidevops] native gh command failed before an HTTP request\n' >&2
		fi
		_ghqa_write_fallback_attempt "$result_file" "$path" 0 \
			"$([[ "$rc" -eq 0 ]] && printf success || printf error)" "$elapsed_ms" ""
		return "$rc"
	fi
	if [[ "$version" == v1 && "$frame_count" =~ ^[1-9][0-9]*$ ]] \
		&& _ghqa_capture_frames_valid "$parsed" "$frame_count"; then
		_ghqa_write_complete_frames "$result_file" "$state_file" "$path" "$page" "$rc" "$parsed" "$@"
	else
		_ghqa_write_fallback_attempt "$result_file" "$path" 0 \
			"$([[ "$rc" -eq 0 ]] && printf success || printf error)" "$elapsed_ms" ""
	fi
	return "$rc"
}

_ghqa_record_result_file() {
	local result_file="$1"
	local caller="$2"
	local logical_id="$3"
	local retry="$4"
	local kind path page outcome status elapsed quota pool decision budget
	local attempts=0
	while IFS=$'\t' read -r kind path page outcome status elapsed quota pool decision budget; do
		[[ "$kind" == attempt ]] || continue
		attempts=$((attempts + 1))
		gh_record_attempt "$path" "$caller" "$logical_id" "" "$page" "$retry" "$outcome" \
			"$status" "$elapsed" "$quota" "${AIDEVOPS_GH_AUTH_MODE:-}" "$pool" "$decision" "$budget"
	done <"$result_file"
	# An exact capture path that observed malformed debug output writes an opaque
	# row above. An empty result is valid only when gh made no HTTP request.
	: "$attempts"
	return 0
}

# Execute one native gh process with response-framed debug capture. Only numeric
# response metadata survives; request/query/response bodies are deleted before
# the attempt record is appended. A per-credential lock makes unit counter
# deltas provable while gaps and higher-cost ambiguity remain unknown.
_ghqa_run_transport_attempt() {
	local path="$1"
	local caller="$2"
	local logical_id="$3"
	local page="$4"
	local retry="$5"
	shift 5
	[[ "${1:-}" == -- ]] && shift
	local executable="${1:-}"
	local host fingerprint state_dir temp_dir state_file lock_dir result_file
	local parser="${_GHQA_DIR}/gh-quota-debug-filter.py"
	local rc=0
	_GHQA_TRANSPORT_HANDLED=1
	if _ghqa_command_is_local_only "$@"; then
		"$@"
		return $?
	fi
	if [[ "${AIDEVOPS_GH_EXACT_QUOTA_CAPTURE:-0}" != 1 || -n "${GH_DEBUG:-}" \
		|| ! -f "$parser" ]]; then
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	fi
	host=$(_ghqa_target_host "${@:2}" 2>/dev/null || true)
	if [[ "$host" != github.com ]]; then
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	fi
	fingerprint=$(_ghqa_auth_fingerprint "$executable" "$host" 2>/dev/null || true)
	if [[ ! "$fingerprint" =~ ^[a-f0-9]{64}$ ]]; then
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	fi
	state_dir="${AIDEVOPS_GH_QUOTA_STATE_DIR:-${HOME}/.aidevops/state/gh-quota-attribution}"
	temp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	if ! _ghqa_prepare_private_dir "$state_dir" || ! _ghqa_prepare_private_dir "$temp_dir"; then
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	fi
	state_file="${state_dir}/${fingerprint}.state"
	lock_dir="${state_file}.lock.d"
	result_file=$(mktemp "${temp_dir}/gh-quota-result.XXXXXX" 2>/dev/null) || {
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	}
	chmod 0600 "$result_file" 2>/dev/null || {
		rm -f "$result_file" 2>/dev/null || true
		_GHQA_TRANSPORT_HANDLED=0
		return 125
	}
	if ( _ghqa_capture_locked "$result_file" "$state_file" "$lock_dir" "$temp_dir" \
		"$parser" "$path" "$page" "$@" ); then
		rc=0
	else
		rc=$?
	fi
	_ghqa_record_result_file "$result_file" "$caller" "$logical_id" "$retry"
	rm -f "$result_file" 2>/dev/null || true
	return "$rc"
}
