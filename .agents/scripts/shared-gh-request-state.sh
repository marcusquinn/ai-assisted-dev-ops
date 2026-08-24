#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared GitHub request coordination: scoped rate snapshots and single-flight.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_SHARED_GH_REQUEST_STATE_LOADED:-}" ]] && return 0

_GHRS_SELF="${BASH_SOURCE[0]:-${0:-}}"
if ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
	# shellcheck source=./portable-stat.sh
	if ! source "${_GHRS_SELF%/*}/portable-stat.sh"; then
		[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1
		return 1
	fi
fi
_SHARED_GH_REQUEST_STATE_LOADED=1

_GHRS_LEASE_SCHEMA="aidevops-gh-request-lease/v1"
_GHRS_OUTCOME_SCHEMA="aidevops-gh-request-outcome/v1"
_GHRS_INVALIDATION_SCHEMA="aidevops-gh-request-invalidation/v1"
_GHRS_INVALIDATION_INITIAL="0000000000000000000000000000000000000000000000000000000000000000"
_GHRS_RATE_SCHEMA="aidevops-gh-rate-limit-state/v1"
_GHRS_REQUEST_PROJECTION="request-coordination/v1"
_GHRS_INVALIDATION_KEY_PROJECTION="request-invalidation-key/v1"
_GHRS_ROLE_BYPASS="bypass"
_GHRS_STATUS_SUCCESS="success"
_GHRS_STATUS_FAILURE="failure"
_GHRS_JSON_TYPE_NUMBER="number"
_GHRS_JSON_TYPE_OBJECT="object"
_GHRS_ACQUIRED_GENERATION=""
_GHRS_BEGIN_ROLE=""
_GHRS_BEGIN_GENERATION=""

_ghrs_now() {
	date +%s 2>/dev/null || printf '0\n'
	return 0
}

_ghrs_pid() {
	local process_pid="${BASHPID:-}"
	if [[ -z "$process_pid" ]]; then
		process_pid="$(exec sh -c 'printf "%s" "$PPID"')" || return 1
	fi
	[[ "$process_pid" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$process_pid"
	return 0
}

_ghrs_digest() {
	local material="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$material" | shasum -a 256 | awk '{print $1}')
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$material" | sha256sum | awk '{print $1}')
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(printf '%s' "$material" | openssl dgst -sha256 | awk '{print $NF}')
	else
		return 1
	fi
	[[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

_ghrs_auth_scope() {
	local pool="${1:-${AIDEVOPS_GH_API_POOL:-default}}"
	local base_scope="${AIDEVOPS_GH_REQUEST_STATE_AUTH_SCOPE:-${GH_HOST:-github.com}|${AIDEVOPS_GH_AUTH_MODE:-gh}|${AIDEVOPS_GH_AUTH_PRINCIPAL:-default}}"
	printf '%s|%s\n' "$base_scope" "$pool"
	return 0
}

_ghrs_scope_fingerprint() {
	local pool="${1:-${AIDEVOPS_GH_API_POOL:-default}}"
	local scope=""
	scope="$(_ghrs_auth_scope "$pool")" || return 1
	_ghrs_digest "$scope"
	return $?
}

gh_request_state_request_key() {
	local repository="$1"
	local operation="$2"
	local projection="$3"
	local identity="$4"
	local pool="${5:-${AIDEVOPS_GH_API_POOL:-default}}"
	local scope_fingerprint=""
	local material=""
	[[ -n "$repository" && -n "$operation" && -n "$projection" && -n "$identity" ]] || return 1
	scope_fingerprint="$(_ghrs_scope_fingerprint "$pool")" || return 1
	material=$(printf '%s\034%s\034%s\034%s\034%s\034%s' \
		"$_GHRS_REQUEST_PROJECTION" "$scope_fingerprint" "$repository" \
		"$operation" "$projection" "$identity")
	_ghrs_digest "$material"
	return $?
}

# Return an auth-independent invalidation identity. Request coalescing remains
# credential-scoped, while a verified repository event fences stale envelopes
# written by any rotated principal or API pool for the same canonical state.
gh_request_state_invalidation_key() {
	local repository="$1"
	local operation="$2"
	local projection="$3"
	local identity="$4"
	local host="${GH_HOST:-github.com}"
	local material=""
	[[ -n "$repository" && -n "$operation" && -n "$projection" && -n "$identity" ]] || return 1
	material=$(printf '%s\034%s\034%s\034%s\034%s\034%s' \
		"$_GHRS_INVALIDATION_KEY_PROJECTION" "$host" "$repository" \
		"$operation" "$projection" "$identity")
	_ghrs_digest "$material"
	return $?
}

_ghrs_base_dir() {
	local work_dir="${AIDEVOPS_WORK_DIR:-${HOME:+${HOME}/.aidevops/.agent-workspace/work}}"
	local base_dir="${AIDEVOPS_GH_REQUEST_STATE_DIR:-${work_dir:+${work_dir}/github-request-state}}"
	[[ -n "$base_dir" ]] || return 1
	(umask 077 && mkdir -p "$base_dir") 2>/dev/null || return 1
	chmod 700 "$base_dir" 2>/dev/null || return 1
	printf '%s\n' "$base_dir"
	return 0
}

_ghrs_request_dir() {
	local key="$1"
	local base_dir=""
	local request_dir=""
	[[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
	base_dir="$(_ghrs_base_dir)" || return 1
	request_dir="${base_dir}/requests/${key}"
	(umask 077 && mkdir -p "$request_dir") 2>/dev/null || return 1
	chmod 700 "${base_dir}/requests" "$request_dir" 2>/dev/null || return 1
	printf '%s\n' "$request_dir"
	return 0
}

_ghrs_invalidation_generation_valid() {
	local generation="$1"
	[[ "$generation" =~ ^[A-Fa-f0-9]{64}$ ]]
	return $?
}

# Return the current invalidation generation for one exact request identity.
# Missing markers map to a stable initial generation so pre-marker cache entries
# remain compatible until the first explicit invalidation.
gh_request_state_invalidation_generation_get() {
	local key="$1"
	local request_dir=""
	local marker_file=""
	local generation=""
	[[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	marker_file="${request_dir}/invalidation.json"
	if [[ ! -e "$marker_file" ]]; then
		printf '%s\n' "$_GHRS_INVALIDATION_INITIAL"
		return 0
	fi
	generation=$(jq -er --arg schema "$_GHRS_INVALIDATION_SCHEMA" --arg key "$key" '
		select(.schema == $schema and .key == $key) |
		select((.invalidated_at | type) == "number" and (.invalidated_at | floor) == .invalidated_at) |
		.invalidation_generation
	' "$marker_file" 2>/dev/null) || return 1
	_ghrs_invalidation_generation_valid "$generation" || return 1
	printf '%s\n' "$generation"
	return 0
}

gh_request_state_invalidation_generation_is_current() {
	local key="$1"
	local generation="$2"
	local current_generation=""
	_ghrs_invalidation_generation_valid "$generation" || return 1
	current_generation=$(gh_request_state_invalidation_generation_get "$key") || return 1
	[[ "$current_generation" == "$generation" ]]
	return $?
}

# Atomically advance one exact request identity before providers remove their
# cache entry. Late writers retain the old generation in their envelopes and
# therefore become safe misses even if they publish after the invalidation.
gh_request_state_invalidate() {
	local key="$1"
	local request_dir=""
	local marker_tmp=""
	local generation=""
	local now=""
	local process_pid=""
	[[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	now="$(_ghrs_now)"
	process_pid="$(_ghrs_pid)" || return 1
	[[ "$now" =~ ^[0-9]+$ && "$now" -gt 0 ]] || return 1
	marker_tmp=$(mktemp "${request_dir}/.invalidation.XXXXXX" 2>/dev/null) || return 1
	generation="$(_ghrs_digest "${key}:${now}:${process_pid}:${marker_tmp}")" || {
		rm -f "$marker_tmp"
		return 1
	}
	chmod 600 "$marker_tmp" 2>/dev/null || {
		rm -f "$marker_tmp"
		return 1
	}
	if ! jq -n --arg schema "$_GHRS_INVALIDATION_SCHEMA" --arg key "$key" \
		--arg generation "$generation" --argjson invalidated_at "$now" \
		'{schema:$schema,key:$key,invalidation_generation:$generation,
		invalidated_at:$invalidated_at}' >"$marker_tmp"; then
		rm -f "$marker_tmp"
		return 1
	fi
	mv "$marker_tmp" "${request_dir}/invalidation.json" 2>/dev/null || {
		rm -f "$marker_tmp"
		return 1
	}
	rm -f "${request_dir}/outcome.json" 2>/dev/null || true
	_ghrs_record invalidate
	return 0
}

_ghrs_sleep_jitter() {
	local base_ms="${AIDEVOPS_GH_SINGLEFLIGHT_WAIT_BASE_MS:-60}"
	local jitter_ms="${AIDEVOPS_GH_SINGLEFLIGHT_WAIT_JITTER_MS:-90}"
	[[ "$base_ms" =~ ^[0-9]+$ && "$base_ms" -le 900 ]] || base_ms=60
	[[ "$jitter_ms" =~ ^[0-9]+$ && "$jitter_ms" -le 900 ]] || jitter_ms=90
	local jitter_range=$((jitter_ms + 1))
	local jitter=$((RANDOM % jitter_range))
	local delay_ms=$((base_ms + jitter))
	local delay=""
	if [[ "$delay_ms" -ge 1000 ]]; then
		delay="1"
	else
		delay=$(printf '0.%03d' "$delay_ms")
	fi
	sleep "$delay"
	return 0
}

_ghrs_record() {
	local decision="$1"
	local operation="${2:-request}"
	if declare -F gh_record_call >/dev/null 2>&1; then
		gh_record_call other gh_request_singleflight unknown other "$decision" "$operation" coordination 2>/dev/null || true
	fi
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		case "$decision" in
		leader)
			gh_record_efficiency_evidence single_flight.leaders 1 2>/dev/null || true
			;;
		follower-success | follower-failure | timeout)
			gh_record_efficiency_evidence single_flight.waits 1 2>/dev/null || true
			;;
		takeover)
			gh_record_efficiency_evidence single_flight.waits 1 2>/dev/null || true
			gh_record_efficiency_evidence single_flight.takeovers 1 2>/dev/null || true
			;;
		esac
	fi
	return 0
}

_ghrs_owner_read() {
	local key="$1"
	local request_dir=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	jq -er --arg schema "$_GHRS_LEASE_SCHEMA" --arg key "$key" \
		--arg number_type "$_GHRS_JSON_TYPE_NUMBER" '
		select(.schema == $schema and .key == $key) |
		select(.generation | type == "string" and test("^[A-Za-z0-9:._-]+$")) |
		select(.pid | type == $number_type and floor == . and . > 0) |
		select(.created_at | type == $number_type and floor == . and . > 0) |
		select((.expires_at | type == $number_type and floor == .) and .expires_at >= .created_at) |
		[.generation, (.pid | tostring), (.created_at | tostring), (.expires_at | tostring)] | @tsv
	' "${request_dir}/lease/owner.json" 2>/dev/null
	return $?
}

_ghrs_owner_is_stale() {
	local key="$1"
	local owner_record="$2"
	local request_dir=""
	local lease_dir=""
	local now=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	lease_dir="${request_dir}/lease"
	now="$(_ghrs_now)"
	[[ "$now" =~ ^[0-9]+$ && "$now" -gt 0 ]] || return 1

	if [[ -n "$owner_record" ]]; then
		local generation="" owner_pid="" created_at="" expires_at=""
		IFS=$'\t' read -r generation owner_pid created_at expires_at <<<"$owner_record"
		[[ -n "$generation" && "$owner_pid" =~ ^[0-9]+$ && "$expires_at" =~ ^[0-9]+$ ]] || return 1
		[[ "$now" -ge "$expires_at" ]] && return 0
		kill -0 "$owner_pid" 2>/dev/null || return 0
		return 1
	fi

	local orphan_grace="${AIDEVOPS_GH_SINGLEFLIGHT_OWNER_GRACE_SECONDS:-2}"
	local modified_at=""
	local age=0
	[[ "$orphan_grace" =~ ^[0-9]+$ ]] || orphan_grace=2
	modified_at="$(_file_mtime_epoch "$lease_dir")" || return 1
	[[ "$modified_at" =~ ^[0-9]+$ ]] || return 1
	age=$((now - modified_at))
	[[ "$age" -lt 0 ]] && age=0
	[[ "$age" -ge "$orphan_grace" ]]
	return $?
}

_ghrs_reclaim_lease() {
	local key="$1"
	local observed_generation="$2"
	local request_dir=""
	local lease_dir=""
	local reclaim_dir=""
	local current_owner=""
	local current_generation=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	lease_dir="${request_dir}/lease"
	reclaim_dir="${request_dir}/lease.reclaim"
	mkdir "$reclaim_dir" 2>/dev/null || return 1

	if [[ ! -d "$lease_dir" ]]; then
		rmdir "$reclaim_dir" 2>/dev/null || true
		return 1
	fi
	current_owner="$(_ghrs_owner_read "$key")" || current_owner=""
	if [[ -n "$current_owner" ]]; then
		current_generation="${current_owner%%$'\t'*}"
		if [[ -z "$observed_generation" || "$current_generation" != "$observed_generation" ]]; then
			rmdir "$reclaim_dir" 2>/dev/null || true
			return 1
		fi
	fi

	rm -f "${lease_dir}/owner.json" "${lease_dir}"/.owner.* 2>/dev/null || true
	if ! rmdir "$lease_dir" 2>/dev/null; then
		rmdir "$reclaim_dir" 2>/dev/null || true
		return 1
	fi
	rmdir "$reclaim_dir" 2>/dev/null || true
	_ghrs_record takeover
	return 0
}

_ghrs_try_acquire() {
	local key="$1"
	local request_dir=""
	local lease_dir=""
	local process_pid=""
	local now=""
	local lease_seconds="${AIDEVOPS_GH_SINGLEFLIGHT_LEASE_SECONDS:-30}"
	local expires_at=0
	local generation=""
	local owner_tmp=""
	_GHRS_ACQUIRED_GENERATION=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	lease_dir="${request_dir}/lease"
	(umask 077 && mkdir "$lease_dir") 2>/dev/null || return 1
	process_pid="${BASHPID:-}"
	if [[ -z "$process_pid" ]]; then
		process_pid="$(_ghrs_pid)" || process_pid=""
	fi
	if [[ ! "$process_pid" =~ ^[0-9]+$ ]]; then
		rmdir "$lease_dir" 2>/dev/null || true
		return 1
	fi
	now="$(_ghrs_now)"
	[[ "$now" =~ ^[0-9]+$ && "$now" -gt 0 ]] || {
		rmdir "$lease_dir" 2>/dev/null || true
		return 1
	}
	[[ "$lease_seconds" =~ ^[1-9][0-9]*$ && "$lease_seconds" -le 300 ]] || lease_seconds=30
	expires_at=$((now + lease_seconds))
	generation="${process_pid}:${now}:${RANDOM}:${RANDOM}"
	owner_tmp=$(mktemp "${lease_dir}/.owner.XXXXXX" 2>/dev/null) || {
		rmdir "$lease_dir" 2>/dev/null || true
		return 1
	}
	chmod 600 "$owner_tmp" 2>/dev/null || {
		rm -f "$owner_tmp"
		rmdir "$lease_dir" 2>/dev/null || true
		return 1
	}
	if ! jq -n --arg schema "$_GHRS_LEASE_SCHEMA" --arg key "$key" \
		--arg generation "$generation" --argjson pid "$process_pid" \
		--argjson created_at "$now" --argjson expires_at "$expires_at" \
		'{schema:$schema,key:$key,generation:$generation,pid:$pid,
		created_at:$created_at,expires_at:$expires_at}' >"$owner_tmp"; then
		rm -f "$owner_tmp"
		rmdir "$lease_dir" 2>/dev/null || true
		return 1
	fi
	if ! mv "$owner_tmp" "${lease_dir}/owner.json" 2>/dev/null; then
		rm -f "$owner_tmp"
		rmdir "$lease_dir" 2>/dev/null || true
		return 1
	fi
	_GHRS_ACQUIRED_GENERATION="$generation"
	return 0
}

_ghrs_outcome_read() {
	local key="$1"
	local generation="$2"
	local request_dir=""
	local now=""
	local outcome_ttl="${AIDEVOPS_GH_SINGLEFLIGHT_OUTCOME_TTL_SECONDS:-10}"
	local entry=""
	local status="" completed_at=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	[[ "$outcome_ttl" =~ ^[1-9][0-9]*$ && "$outcome_ttl" -le 60 ]] || outcome_ttl=10
	entry=$(jq -er --arg schema "$_GHRS_OUTCOME_SCHEMA" --arg key "$key" \
		--arg generation "$generation" --arg success "$_GHRS_STATUS_SUCCESS" \
		--arg failure "$_GHRS_STATUS_FAILURE" \
		--arg number_type "$_GHRS_JSON_TYPE_NUMBER" '
		select(.schema == $schema and .key == $key and .generation == $generation) |
		select(.status == $success or .status == $failure) |
		select(.completed_at | type == $number_type and floor == . and . > 0) |
		[.status, (.completed_at | tostring)] | @tsv
	' "${request_dir}/outcome.json" 2>/dev/null) || entry=""
	[[ -n "$entry" ]] || return 1
	IFS=$'\t' read -r status completed_at <<<"$entry"
	now="$(_ghrs_now)"
	[[ "$now" =~ ^[0-9]+$ && "$completed_at" =~ ^[0-9]+$ ]] || return 1
	[[ "$now" -ge "$completed_at" && $((now - completed_at)) -le "$outcome_ttl" ]] || return 1
	printf '%s\n' "$status"
	return 0
}

gh_request_state_singleflight_begin() {
	local key="$1"
	_GHRS_BEGIN_ROLE=""
	_GHRS_BEGIN_GENERATION=""
	if [[ "${AIDEVOPS_GH_REQUEST_STATE_DISABLE:-0}" == "1" || "${AIDEVOPS_GH_SINGLEFLIGHT_DISABLE:-0}" == "1" ]]; then
		_GHRS_BEGIN_ROLE="$_GHRS_ROLE_BYPASS"
		_ghrs_record bypass-disabled
		return 0
	fi
	[[ "$key" =~ ^[A-Fa-f0-9]{64}$ ]] || {
		_GHRS_BEGIN_ROLE="$_GHRS_ROLE_BYPASS"
		_ghrs_record bypass-invalid
		return 0
	}

	local wait_seconds="${AIDEVOPS_GH_SINGLEFLIGHT_WAIT_SECONDS:-10}"
	local started_at=""
	local now=""
	local generation=""
	local owner_record=""
	local observed_generation=""
	local outcome=""
	local follower_role=""
	[[ "$wait_seconds" =~ ^[0-9]+$ && "$wait_seconds" -le 120 ]] || wait_seconds=10
	started_at="$(_ghrs_now)"
	[[ "$started_at" =~ ^[0-9]+$ && "$started_at" -gt 0 ]] || {
		_GHRS_BEGIN_ROLE="$_GHRS_ROLE_BYPASS"
		return 0
	}

	while true; do
		if [[ -n "$observed_generation" ]]; then
			outcome="$(_ghrs_outcome_read "$key" "$observed_generation")" || outcome=""
			if [[ "$outcome" == "$_GHRS_STATUS_SUCCESS" || "$outcome" == "$_GHRS_STATUS_FAILURE" ]]; then
				follower_role="follower-${outcome}"
				_GHRS_BEGIN_ROLE="$follower_role"
				_GHRS_BEGIN_GENERATION="$observed_generation"
				_ghrs_record "$follower_role"
				return 0
			fi
		fi
		if _ghrs_try_acquire "$key"; then
			generation="$_GHRS_ACQUIRED_GENERATION"
			_GHRS_BEGIN_ROLE="leader"
			_GHRS_BEGIN_GENERATION="$generation"
			_ghrs_record leader
			return 0
		fi

		owner_record="$(_ghrs_owner_read "$key")" || owner_record=""
		observed_generation=""
		[[ -n "$owner_record" ]] && observed_generation="${owner_record%%$'\t'*}"
		if [[ -n "$observed_generation" ]]; then
			outcome="$(_ghrs_outcome_read "$key" "$observed_generation")" || outcome=""
			if [[ "$outcome" == "$_GHRS_STATUS_SUCCESS" || "$outcome" == "$_GHRS_STATUS_FAILURE" ]]; then
				follower_role="follower-${outcome}"
				_GHRS_BEGIN_ROLE="$follower_role"
				_GHRS_BEGIN_GENERATION="$observed_generation"
				_ghrs_record "$follower_role"
				return 0
			fi
		fi

		if _ghrs_owner_is_stale "$key" "$owner_record"; then
			if _ghrs_reclaim_lease "$key" "$observed_generation"; then
				continue
			fi
		fi
		now="$(_ghrs_now)"
		if [[ "$now" =~ ^[0-9]+$ && $((now - started_at)) -ge "$wait_seconds" ]]; then
			_GHRS_BEGIN_ROLE="timeout"
			_ghrs_record timeout
			return 0
		fi
		_ghrs_sleep_jitter
	done
}

gh_request_state_singleflight_is_owner() {
	local key="$1"
	local generation="$2"
	local owner_record=""
	local actual_generation="" owner_pid="" created_at="" expires_at=""
	local now=""
	owner_record="$(_ghrs_owner_read "$key")" || return 1
	IFS=$'\t' read -r actual_generation owner_pid created_at expires_at <<<"$owner_record"
	[[ "$actual_generation" == "$generation" ]] || return 1
	now="$(_ghrs_now)"
	[[ "$now" =~ ^[0-9]+$ && "$expires_at" =~ ^[0-9]+$ && "$now" -lt "$expires_at" ]] || return 1
	return 0
}

_ghrs_write_outcome() {
	local key="$1"
	local generation="$2"
	local status="$3"
	local request_dir=""
	local now=""
	local outcome_tmp=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	now="$(_ghrs_now)"
	[[ "$now" =~ ^[0-9]+$ && "$now" -gt 0 ]] || return 1
	outcome_tmp=$(mktemp "${request_dir}/.outcome.XXXXXX" 2>/dev/null) || return 1
	chmod 600 "$outcome_tmp" 2>/dev/null || {
		rm -f "$outcome_tmp"
		return 1
	}
	if ! jq -n --arg schema "$_GHRS_OUTCOME_SCHEMA" --arg key "$key" \
		--arg generation "$generation" --arg status "$status" \
		--argjson completed_at "$now" \
		'{schema:$schema,key:$key,generation:$generation,status:$status,
		completed_at:$completed_at}' >"$outcome_tmp"; then
		rm -f "$outcome_tmp"
		return 1
	fi
	mv "$outcome_tmp" "${request_dir}/outcome.json" 2>/dev/null || {
		rm -f "$outcome_tmp"
		return 1
	}
	return 0
}

_ghrs_release_owned_lease() {
	local key="$1"
	local generation="$2"
	local request_dir=""
	local owner_record=""
	local actual_generation=""
	request_dir="$(_ghrs_request_dir "$key")" || return 1
	owner_record="$(_ghrs_owner_read "$key")" || return 1
	actual_generation="${owner_record%%$'\t'*}"
	[[ "$actual_generation" == "$generation" ]] || return 1
	rm -f "${request_dir}/lease/owner.json" "${request_dir}/lease"/.owner.* 2>/dev/null || true
	rmdir "${request_dir}/lease" 2>/dev/null || return 1
	return 0
}

gh_request_state_singleflight_finish() {
	local key="$1"
	local generation="$2"
	local status="$3"
	[[ "$status" == "$_GHRS_STATUS_SUCCESS" || "$status" == "$_GHRS_STATUS_FAILURE" ]] || return 1
	gh_request_state_singleflight_is_owner "$key" "$generation" || return 1
	_ghrs_write_outcome "$key" "$generation" "$status" || return 1
	_ghrs_release_owned_lease "$key" "$generation" || return 1
	_ghrs_record "leader-${status}"
	return 0
}

_ghrs_rate_parent_dir() {
	local rate_file="$1"
	local rate_dir="."
	[[ -n "$rate_file" ]] || return 1
	if [[ "$rate_file" == */* ]]; then
		rate_dir="${rate_file%/*}"
		[[ -n "$rate_dir" ]] || rate_dir="/"
	fi
	printf '%s\n' "$rate_dir"
	return 0
}

_ghrs_rate_file() {
	local rate_file="${AIDEVOPS_GH_REQUEST_STATE_RATE_FILE:-${AIDEVOPS_PULSE_RATE_LIMIT_CACHE:-${HOME:+${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json}}}"
	local rate_dir=""
	[[ -n "$rate_file" ]] || return 1
	rate_dir="$(_ghrs_rate_parent_dir "$rate_file")" || return 1
	case "$rate_dir" in
	"." | "/") ;;
	*)
		(umask 077 && mkdir -p "$rate_dir") 2>/dev/null || return 1
		chmod 700 "$rate_dir" 2>/dev/null || return 1
		;;
	esac
	printf '%s\n' "$rate_file"
	return 0
}

_ghrs_rate_json_valid() {
	local rate_json="$1"
	printf '%s' "$rate_json" | jq -e --arg number_type "$_GHRS_JSON_TYPE_NUMBER" \
		--arg object_type "$_GHRS_JSON_TYPE_OBJECT" '
		type == $object_type and (.resources | type == $object_type) and
		(.resources.graphql | type == $object_type) and
		(.resources.graphql.remaining | type == $number_type and floor == . and . >= 0) and
		(.resources.graphql.limit | type == $number_type and floor == . and . >= 0) and
		((.resources.graphql.reset // 0) | type == $number_type and floor == . and . >= 0)
	' >/dev/null 2>&1
	return $?
}

gh_request_state_rate_get() {
	local mode="${1:-normal}"
	local ttl="${2:-${AIDEVOPS_GH_REQUEST_STATE_RATE_TTL:-20}}"
	local rate_file=""
	local scope_fingerprint=""
	local pool="${AIDEVOPS_GH_API_POOL:-default}"
	local entry=""
	local observed_at="" reset_at="" rate_json="" now=""
	[[ "${AIDEVOPS_GH_REQUEST_STATE_DISABLE:-0}" != "1" && "${AIDEVOPS_GH_REQUEST_STATE_RATE_DISABLE:-0}" != "1" ]] || return 1
	[[ "$mode" == "normal" || "$mode" == "cached-only" ]] || return 1
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=20
	rate_file="$(_ghrs_rate_file)" || return 1
	[[ -s "$rate_file" ]] || return 1
	scope_fingerprint="$(_ghrs_scope_fingerprint "$pool")" || return 1
	entry=$(jq -cer --arg schema "$_GHRS_RATE_SCHEMA" \
		--arg scope_fingerprint "$scope_fingerprint" --arg pool "$pool" \
		--arg number_type "$_GHRS_JSON_TYPE_NUMBER" --arg object_type "$_GHRS_JSON_TYPE_OBJECT" '
		select(.schema == $schema and .scope_fingerprint == $scope_fingerprint and .pool == $pool) |
		select(.validation == "validated") |
		select(.observed_at | type == $number_type and floor == . and . > 0) |
		select(.rate | type == $object_type) |
		[.observed_at, (.rate.resources.graphql.reset // 0), .rate]
	' "$rate_file" 2>/dev/null) || entry=""
	[[ -n "$entry" ]] || return 1
	observed_at=$(printf '%s' "$entry" | jq -r '.[0]') || return 1
	reset_at=$(printf '%s' "$entry" | jq -r '.[1]') || return 1
	rate_json=$(printf '%s' "$entry" | jq -c '.[2]') || return 1
	_ghrs_rate_json_valid "$rate_json" || return 1
	if [[ "$mode" == "normal" ]]; then
		now="$(_ghrs_now)"
		[[ "$now" =~ ^[0-9]+$ && "$observed_at" =~ ^[0-9]+$ ]] || return 1
		[[ "$now" -ge "$observed_at" && "$ttl" -gt 0 && $((now - observed_at)) -lt "$ttl" ]] || return 1
		if [[ "$reset_at" =~ ^[0-9]+$ && "$reset_at" -gt 0 && "$now" -ge "$reset_at" ]]; then
			return 1
		fi
	fi
	printf '%s\n' "$rate_json"
	return 0
}

gh_request_state_rate_put() {
	local rate_json="$1"
	local rate_file=""
	local rate_dir=""
	local rate_tmp=""
	local now=""
	local pool="${AIDEVOPS_GH_API_POOL:-default}"
	local scope_fingerprint=""
	[[ "${AIDEVOPS_GH_REQUEST_STATE_DISABLE:-0}" != "1" && "${AIDEVOPS_GH_REQUEST_STATE_RATE_DISABLE:-0}" != "1" ]] || return 0
	_ghrs_rate_json_valid "$rate_json" || return 1
	rate_file="$(_ghrs_rate_file)" || return 1
	rate_dir="$(_ghrs_rate_parent_dir "$rate_file")" || return 1
	now="$(_ghrs_now)"
	[[ "$now" =~ ^[0-9]+$ && "$now" -gt 0 ]] || return 1
	scope_fingerprint="$(_ghrs_scope_fingerprint "$pool")" || return 1
	rate_tmp=$(mktemp "${rate_dir}/.gh-rate-limit.XXXXXX" 2>/dev/null) || return 1
	chmod 600 "$rate_tmp" 2>/dev/null || {
		rm -f "$rate_tmp"
		return 1
	}
	if ! jq -n --arg schema "$_GHRS_RATE_SCHEMA" --arg scope_fingerprint "$scope_fingerprint" \
		--arg pool "$pool" --argjson observed_at "$now" --argjson rate "$rate_json" \
		'{schema:$schema,scope_fingerprint:$scope_fingerprint,pool:$pool,
		observed_at:$observed_at,rate:$rate,validation:"validated"}' >"$rate_tmp"; then
		rm -f "$rate_tmp"
		return 1
	fi
	mv "$rate_tmp" "$rate_file" 2>/dev/null || {
		rm -f "$rate_tmp"
		return 1
	}
	return 0
}

_ghrs_rate_fetch_direct() {
	local fetch_function="$1"
	local rate_json=""
	declare -F "$fetch_function" >/dev/null 2>&1 || return 1
	rate_json=$("$fetch_function") || return 1
	_ghrs_rate_json_valid "$rate_json" || return 1
	gh_request_state_rate_put "$rate_json" || true
	printf '%s\n' "$rate_json"
	return 0
}

gh_request_state_rate_json() {
	local mode="${1:-normal}"
	local ttl="${2:-20}"
	local fetch_function="$3"
	local rate_json=""
	local key=""
	local role="" generation=""
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=20
	if rate_json="$(gh_request_state_rate_get "$mode" "$ttl")"; then
		printf '%s\n' "$rate_json"
		return 0
	fi
	[[ "$mode" != "cached-only" ]] || return 1
	if [[ "$ttl" -eq 0 || "${AIDEVOPS_GH_REQUEST_STATE_DISABLE:-0}" == "1" || "${AIDEVOPS_GH_REQUEST_STATE_RATE_DISABLE:-0}" == "1" ]]; then
		rate_json=$("$fetch_function") || return 1
		_ghrs_rate_json_valid "$rate_json" || return 1
		printf '%s\n' "$rate_json"
		return 0
	fi
	key=$(gh_request_state_request_key global rate-limit resources/v1 all "${AIDEVOPS_GH_API_POOL:-default}") || {
		_ghrs_rate_fetch_direct "$fetch_function"
		return $?
	}
	if ! gh_request_state_singleflight_begin "$key"; then
		_GHRS_BEGIN_ROLE="$_GHRS_ROLE_BYPASS"
	fi
	role="$_GHRS_BEGIN_ROLE"
	generation="$_GHRS_BEGIN_GENERATION"
	case "$role" in
	leader)
		if rate_json="$(gh_request_state_rate_get normal "$ttl")"; then
			gh_request_state_singleflight_finish "$key" "$generation" success || true
			printf '%s\n' "$rate_json"
			return 0
		fi
		if ! rate_json=$("$fetch_function"); then
			gh_request_state_singleflight_finish "$key" "$generation" failure || true
			return 1
		fi
		if ! _ghrs_rate_json_valid "$rate_json"; then
			gh_request_state_singleflight_finish "$key" "$generation" failure || true
			return 1
		fi
		if ! gh_request_state_singleflight_is_owner "$key" "$generation"; then
			gh_request_state_rate_get cached-only "$ttl"
			return $?
		fi
		gh_request_state_rate_put "$rate_json" || {
			gh_request_state_singleflight_finish "$key" "$generation" failure || true
			return 1
		}
		gh_request_state_singleflight_finish "$key" "$generation" success || true
		printf '%s\n' "$rate_json"
		return 0
		;;
	follower-success)
		gh_request_state_rate_get cached-only "$ttl"
		return $?
		;;
	follower-failure) return 1 ;;
	timeout | bypass | *)
		_ghrs_rate_fetch_direct "$fetch_function"
		return $?
		;;
	esac
	return 1
}
