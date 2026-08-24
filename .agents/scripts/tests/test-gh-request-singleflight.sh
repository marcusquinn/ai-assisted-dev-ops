#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Cross-process coordination coverage for shared-gh-request-state.sh.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEMP_BASE="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_BASE"
TEST_ROOT="$(mktemp -d "${TEMP_BASE}/gh-request-state.XXXXXXXX")"
ORIGINAL_HOME="$HOME"

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_GH_REQUEST_STATE_DIR="${TEST_ROOT}/state"
export AIDEVOPS_GH_REQUEST_STATE_RATE_FILE="${TEST_ROOT}/rate.json"
export AIDEVOPS_GH_AUTH_MODE=gh
export AIDEVOPS_GH_AUTH_PRINCIPAL=default
export AIDEVOPS_GH_API_POOL=default
export AIDEVOPS_GH_SINGLEFLIGHT_WAIT_SECONDS=5
export AIDEVOPS_GH_SINGLEFLIGHT_LEASE_SECONDS=10
export AIDEVOPS_GH_SINGLEFLIGHT_WAIT_BASE_MS=20
export AIDEVOPS_GH_SINGLEFLIGHT_WAIT_JITTER_MS=30
mkdir -p "$HOME"

# shellcheck source=../shared-gh-request-state.sh
source "${SCRIPTS_DIR}/shared-gh-request-state.sh"

EFFICIENCY_EVENTS="${TEST_ROOT}/efficiency-events.tsv"
: >"$EFFICIENCY_EVENTS"
gh_record_efficiency_evidence() {
	local name="$1"
	local value="${2:-1}"
	printf '%s\t%s\n' "$name" "$value" >>"$EFFICIENCY_EVENTS"
	return 0
}

efficiency_event_total() {
	local name="$1"
	awk -F'\t' -v expected="$name" '$1 == expected { total += $2 } END { print total + 0 }' "$EFFICIENCY_EVENTS"
	return 0
}

cleanup() {
	export HOME="$ORIGINAL_HOME"
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$name"
	return 0
}

assert_ne() {
	local name="$1"
	local first="$2"
	local second="$3"
	if [[ "$first" == "$second" ]]; then
		printf 'FAIL: %s\n  both values: %s\n' "$name" "$first" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$name"
	return 0
}

wait_for_file() {
	local path="$1"
	local attempts=0
	while [[ ! -s "$path" && "$attempts" -lt 100 ]]; do
		sleep 0.02
		attempts=$((attempts + 1))
	done
	[[ -s "$path" ]]
	return $?
}

file_mode() {
	local path="$1"
	local mode=""
	mode=$(stat -f '%Lp' "$path" 2>/dev/null) || mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
	printf '%s\n' "$mode"
	return 0
}

singleflight_worker() {
	local key="$1"
	local result_file="$2"
	local counter_file="$3"
	local output_file="$4"
	local attempts=0
	local generation=""
	while [[ "$attempts" -lt 3 ]]; do
		if [[ -s "$result_file" ]]; then
			cp "$result_file" "$output_file"
			return 0
		fi
		gh_request_state_singleflight_begin "$key"
		generation="$_GHRS_BEGIN_GENERATION"
		case "$_GHRS_BEGIN_ROLE" in
		leader)
			if [[ -s "$result_file" ]]; then
				gh_request_state_singleflight_finish "$key" "$generation" success
				cp "$result_file" "$output_file"
				return 0
			fi
			printf 'transport\n' >>"$counter_file"
			sleep 0.25
			if ! gh_request_state_singleflight_is_owner "$key" "$generation"; then
				return 1
			fi
			local result_tmp="${result_file}.${BASHPID:-$$}"
			printf 'validated-result\n' >"$result_tmp"
			mv "$result_tmp" "$result_file"
			gh_request_state_singleflight_finish "$key" "$generation" success
			cp "$result_file" "$output_file"
			return 0
			;;
		follower-success)
			if [[ -s "$result_file" ]]; then
				cp "$result_file" "$output_file"
				return 0
			fi
			;;
		follower-failure | timeout) return 1 ;;
		bypass) return 1 ;;
		esac
		attempts=$((attempts + 1))
	done
	return 1
}

test_efficiency_event_mapping() {
	: >"$EFFICIENCY_EVENTS"
	_ghrs_record leader
	_ghrs_record follower-success
	_ghrs_record follower-failure
	_ghrs_record takeover
	_ghrs_record timeout
	assert_eq "leader acquisition emits one efficiency event" "1" \
		"$(efficiency_event_total single_flight.leaders)"
	assert_eq "followers, takeover, and timeout emit bounded waits" "4" \
		"$(efficiency_event_total single_flight.waits)"
	assert_eq "lease recovery emits one takeover" "1" \
		"$(efficiency_event_total single_flight.takeovers)"
	assert_eq "duplicate leaders stay absent without an observed violation" "0" \
		"$(efficiency_event_total single_flight.duplicate_leaders)"
	return 0
}

test_scope_key_isolation() {
	local key_default="" key_repeat="" key_repo="" key_projection="" key_identity="" key_principal="" key_pool=""
	local invalidation_default="" invalidation_principal="" invalidation_pool="" invalidation_repo=""
	key_default=$(gh_request_state_request_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa rest-core)
	key_repeat=$(gh_request_state_request_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa rest-core)
	key_repo=$(gh_request_state_request_key other/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa rest-core)
	key_projection=$(gh_request_state_request_key owner/repo checks aggregate/v2 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa rest-core)
	key_identity=$(gh_request_state_request_key owner/repo checks aggregate/v1 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb rest-core)
	AIDEVOPS_GH_AUTH_PRINCIPAL=alternate
	key_principal=$(gh_request_state_request_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa rest-core)
	AIDEVOPS_GH_AUTH_PRINCIPAL=default
	key_pool=$(gh_request_state_request_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa graphql)
	invalidation_default=$(gh_request_state_invalidation_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
	invalidation_repo=$(gh_request_state_invalidation_key other/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
	AIDEVOPS_GH_AUTH_PRINCIPAL=alternate
	invalidation_principal=$(gh_request_state_invalidation_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
	AIDEVOPS_GH_AUTH_PRINCIPAL=default
	AIDEVOPS_GH_API_POOL=graphql
	invalidation_pool=$(gh_request_state_invalidation_key owner/repo checks aggregate/v1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
	AIDEVOPS_GH_API_POOL=default

	assert_eq "identical request scope produces a stable key" "$key_default" "$key_repeat"
	assert_ne "repository changes the request key" "$key_default" "$key_repo"
	assert_ne "projection changes the request key" "$key_default" "$key_projection"
	assert_ne "immutable identity changes the request key" "$key_default" "$key_identity"
	assert_ne "auth principal changes the request key" "$key_default" "$key_principal"
	assert_ne "API pool changes the request key" "$key_default" "$key_pool"
	assert_ne "repository changes the invalidation key" "$invalidation_default" "$invalidation_repo"
	assert_eq "auth rotation preserves the canonical invalidation key" "$invalidation_default" "$invalidation_principal"
	assert_eq "API pool rotation preserves the canonical invalidation key" "$invalidation_default" "$invalidation_pool"
	return 0
}

test_default_state_root_is_operational() {
	local configured_root="$AIDEVOPS_GH_REQUEST_STATE_DIR"
	local actual_root=""
	unset AIDEVOPS_GH_REQUEST_STATE_DIR
	actual_root=$(_ghrs_base_dir)
	export AIDEVOPS_GH_REQUEST_STATE_DIR="$configured_root"
	assert_eq "default coordination state uses the operational workspace" \
		"${HOME}/.aidevops/.agent-workspace/work/github-request-state" "$actual_root"
	return 0
}

test_portable_mtime_dependency_is_available() {
	if ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
		printf 'FAIL: shared request state did not load portable mtime support\n' >&2
		return 1
	fi
	printf 'PASS: shared request state loads portable mtime support\n'
	return 0
}

test_concurrent_workers_share_one_result() {
	local key="" result_file="${TEST_ROOT}/shared-result" counter_file="${TEST_ROOT}/transport-count"
	local worker=0 pid=0 count=0 output=""
	local -a pids=()
	key=$(gh_request_state_request_key owner/repo checks aggregate/v1 cccccccccccccccccccccccccccccccccccccccc rest-core)
	: >"$counter_file"
	for worker in 1 2 3 4 5 6; do
		(singleflight_worker "$key" "$result_file" "$counter_file" "${TEST_ROOT}/worker-${worker}.out") &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		wait "$pid"
	done
	count=$(wc -l <"$counter_file" | tr -d '[:space:]')
	assert_eq "six concurrent readers perform one leader transport" "1" "$count"
	for worker in 1 2 3 4 5 6; do
		output=$(tr -d '\n' <"${TEST_ROOT}/worker-${worker}.out")
		assert_eq "worker ${worker} reuses the validated result" "validated-result" "$output"
	done
	assert_eq "coordination root is private" "700" "$(file_mode "$AIDEVOPS_GH_REQUEST_STATE_DIR")"
	return 0
}

test_observed_follower_consumes_matching_outcome() {
	local key="" generation="" follower_pid=0
	local waiting_file="${TEST_ROOT}/outcome-follower-waiting"
	local release_file="${TEST_ROOT}/outcome-follower-release"
	local result_file="${TEST_ROOT}/outcome-follower-result"
	local role="" follower_generation=""
	key=$(gh_request_state_request_key owner/repo checks aggregate/v1 observed-outcome rest-core)
	gh_request_state_singleflight_begin "$key"
	assert_eq "matching-outcome fixture elects its initial leader" "leader" "$_GHRS_BEGIN_ROLE"
	generation="$_GHRS_BEGIN_GENERATION"

	(
		_ghrs_sleep_jitter() {
			printf 'waiting\n' >"$waiting_file"
			while [[ ! -e "$release_file" ]]; do
				sleep 0.01
			done
			return 0
		}
		gh_request_state_singleflight_begin "$key"
		printf '%s\t%s\n' "$_GHRS_BEGIN_ROLE" "$_GHRS_BEGIN_GENERATION" >"$result_file"
	) &
	follower_pid=$!
	wait_for_file "$waiting_file"
	gh_request_state_singleflight_finish "$key" "$generation" success
	printf 'release\n' >"$release_file"
	wait "$follower_pid"
	IFS=$'\t' read -r role follower_generation <"$result_file"
	assert_eq "an existing follower consumes the completed typed outcome" "follower-success" "$role"
	assert_eq "the follower validates the exact observed generation" "$generation" "$follower_generation"
	return 0
}

crash_leader() {
	local key="$1"
	local generation_file="$2"
	gh_request_state_singleflight_begin "$key"
	[[ "$_GHRS_BEGIN_ROLE" == "leader" ]] || return 1
	printf '%s\n' "$_GHRS_BEGIN_GENERATION" >"$generation_file"
	sleep 30
	return 0
}

test_dead_leader_is_recovered() {
	local key="" generation_file="${TEST_ROOT}/dead-generation" leader_pid=0 generation=""
	key=$(gh_request_state_request_key owner/repo canonical issues/v1 dead-owner rest-core)
	(crash_leader "$key" "$generation_file") &
	leader_pid=$!
	wait_for_file "$generation_file"
	kill -KILL "$leader_pid" 2>/dev/null || true
	wait "$leader_pid" 2>/dev/null || true
	gh_request_state_singleflight_begin "$key"
	assert_eq "dead leader is replaced by a new leader" "leader" "$_GHRS_BEGIN_ROLE"
	generation="$_GHRS_BEGIN_GENERATION"
	gh_request_state_singleflight_finish "$key" "$generation" failure
	return 0
}

live_expiring_leader() {
	local key="$1"
	local generation_file="$2"
	local fence_file="$3"
	export AIDEVOPS_GH_SINGLEFLIGHT_LEASE_SECONDS=1
	gh_request_state_singleflight_begin "$key"
	[[ "$_GHRS_BEGIN_ROLE" == "leader" ]] || return 1
	local generation="$_GHRS_BEGIN_GENERATION"
	printf '%s\n' "$generation" >"$generation_file"
	sleep 3
	if gh_request_state_singleflight_is_owner "$key" "$generation"; then
		printf 'unsafe-owner\n' >"$fence_file"
	else
		printf 'fenced\n' >"$fence_file"
	fi
	return 0
}

test_expired_live_leader_is_fenced() {
	local key="" generation_file="${TEST_ROOT}/live-generation" fence_file="${TEST_ROOT}/fence-result"
	local old_pid=0 new_generation="" owner_record=""
	key=$(gh_request_state_request_key owner/repo canonical prs/v1 pid-reuse rest-core)
	(live_expiring_leader "$key" "$generation_file" "$fence_file") &
	old_pid=$!
	wait_for_file "$generation_file"
	sleep 2
	export AIDEVOPS_GH_SINGLEFLIGHT_LEASE_SECONDS=10
	gh_request_state_singleflight_begin "$key"
	assert_eq "expired live holder is replaced through lease takeover" "leader" "$_GHRS_BEGIN_ROLE"
	new_generation="$_GHRS_BEGIN_GENERATION"
	owner_record="$(_ghrs_owner_read "$key")"
	assert_eq "replacement generation owns the lease" "$new_generation" "${owner_record%%$'\t'*}"
	wait "$old_pid"
	assert_eq "late prior generation cannot publish" "fenced" "$(tr -d '\n' <"$fence_file")"
	owner_record="$(_ghrs_owner_read "$key")"
	assert_eq "late prior generation cannot delete the replacement lease" "$new_generation" "${owner_record%%$'\t'*}"
	gh_request_state_singleflight_finish "$key" "$new_generation" success
	return 0
}

test_live_leader_wait_is_bounded() {
	local key="" generation_file="${TEST_ROOT}/timeout-generation" leader_pid=0
	key=$(gh_request_state_request_key owner/repo canonical issues/v1 bounded-wait rest-core)
	export AIDEVOPS_GH_SINGLEFLIGHT_LEASE_SECONDS=30
	(crash_leader "$key" "$generation_file") &
	leader_pid=$!
	wait_for_file "$generation_file"
	export AIDEVOPS_GH_SINGLEFLIGHT_WAIT_SECONDS=1
	gh_request_state_singleflight_begin "$key"
	assert_eq "follower wait terminates at its configured bound" "timeout" "$_GHRS_BEGIN_ROLE"
	kill -KILL "$leader_pid" 2>/dev/null || true
	wait "$leader_pid" 2>/dev/null || true
	export AIDEVOPS_GH_SINGLEFLIGHT_WAIT_SECONDS=5
	return 0
}

test_failed_stale_reclaim_reaches_timeout() (
	local key="" request_dir="" original_generation="" stale_checks=0
	key=$(gh_request_state_request_key owner/repo canonical issues/v1 blocked-reclaim rest-core)
	gh_request_state_singleflight_begin "$key"
	assert_eq "blocked-reclaim fixture elects its initial leader" "leader" "$_GHRS_BEGIN_ROLE"
	original_generation="$_GHRS_BEGIN_GENERATION"
	request_dir="$(_ghrs_request_dir "$key")"
	mkdir "${request_dir}/lease.reclaim"
	export AIDEVOPS_GH_SINGLEFLIGHT_WAIT_SECONDS=0
	_ghrs_owner_is_stale() {
		local observed_key="$1"
		local owner_record="$2"
		: "$observed_key" "$owner_record"
		stale_checks=$((stale_checks + 1))
		[[ "$stale_checks" -eq 1 ]]
		return $?
	}

	gh_request_state_singleflight_begin "$key"
	assert_eq "failed stale reclaim reaches the configured timeout" "timeout" "$_GHRS_BEGIN_ROLE"
	assert_eq "failed stale reclaim checks the deadline before retrying" "1" "$stale_checks"
	assert_eq "failed stale reclaim preserves another reclaimer's lock" "true" \
		"$([[ -d "${request_dir}/lease.reclaim" ]] && printf 'true' || printf 'false')"
	assert_eq "failed stale reclaim preserves the observed owner generation" "$original_generation" \
		"$(_ghrs_owner_read "$key" | cut -f1)"
	return 0
)

test_ownerless_lease_recovery_and_disabled_mode() {
	local key="" request_dir="" generation=""
	key=$(gh_request_state_request_key owner/repo canonical issues/v1 ownerless rest-core)
	request_dir="$(_ghrs_request_dir "$key")"
	mkdir "${request_dir}/lease"
	export AIDEVOPS_GH_SINGLEFLIGHT_OWNER_GRACE_SECONDS=0
	gh_request_state_singleflight_begin "$key"
	assert_eq "ownerless lease is recovered after the grace bound" "leader" "$_GHRS_BEGIN_ROLE"
	generation="$_GHRS_BEGIN_GENERATION"
	gh_request_state_singleflight_finish "$key" "$generation" failure
	unset AIDEVOPS_GH_SINGLEFLIGHT_OWNER_GRACE_SECONDS

	export AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1
	gh_request_state_singleflight_begin "$key"
	assert_eq "disabled mode bypasses shared coordination" "bypass" "$_GHRS_BEGIN_ROLE"
	unset AIDEVOPS_GH_SINGLEFLIGHT_DISABLE
	return 0
}

test_request_invalidation_generations_are_atomic() {
	local key="" initial="" first="" second="" final="" request_dir="" generation=""
	local job=0 pid=0
	local -a pids=()
	key=$(gh_request_state_request_key owner/repo canonical-snapshot issues/v1 issues rest-core)
	initial=$(gh_request_state_invalidation_generation_get "$key")
	assert_eq "missing invalidation marker uses the stable initial generation" \
		"$_GHRS_INVALIDATION_INITIAL" "$initial"

	gh_request_state_invalidate "$key"
	first=$(gh_request_state_invalidation_generation_get "$key")
	assert_ne "explicit invalidation advances the request generation" "$initial" "$first"
	if ! gh_request_state_invalidation_generation_is_current "$key" "$first"; then
		printf 'FAIL: current invalidation generation was rejected\n' >&2
		return 1
	fi
	printf 'PASS: current invalidation generation is accepted\n'
	if gh_request_state_invalidation_generation_is_current "$key" "$initial"; then
		printf 'FAIL: invalidation retained the prior generation\n' >&2
		return 1
	fi
	printf 'PASS: prior invalidation generation is fenced\n'

	gh_request_state_singleflight_begin "$key"
	assert_eq "invalidation outcome fixture elects a leader" "leader" "$_GHRS_BEGIN_ROLE"
	generation="$_GHRS_BEGIN_GENERATION"
	gh_request_state_singleflight_finish "$key" "$generation" success
	request_dir="$(_ghrs_request_dir "$key")"
	[[ -f "${request_dir}/outcome.json" ]] || return 1
	gh_request_state_invalidate "$key"
	second=$(gh_request_state_invalidation_generation_get "$key")
	assert_ne "repeated invalidation cannot reuse a generation" "$first" "$second"
	assert_eq "invalidation marker remains private" "600" "$(file_mode "${request_dir}/invalidation.json")"
	assert_eq "invalidation removes stale single-flight outcomes" "false" \
		"$([[ -e "${request_dir}/outcome.json" ]] && printf true || printf false)"

	for job in 1 2 3 4; do
		(gh_request_state_invalidate "$key") &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		wait "$pid"
	done
	final=$(gh_request_state_invalidation_generation_get "$key")
	assert_ne "concurrent invalidations advance beyond the prior marker" "$second" "$final"
	if compgen -G "${request_dir}/.invalidation.*" >/dev/null; then
		printf 'FAIL: concurrent invalidation left temporary files behind\n' >&2
		return 1
	fi
	printf 'PASS: concurrent invalidation leaves no temporary files\n'
	return 0
}

rate_fixture() {
	local remaining="$1"
	local reset_at="$2"
	printf '{"resources":{"graphql":{"remaining":%s,"limit":5000,"reset":%s},"core":{"remaining":4500,"limit":5000,"reset":%s}}}\n' \
		"$remaining" "$reset_at" "$reset_at"
	return 0
}

test_rate_state_validation_scope_and_reset() {
	local now="" future_reset="" past_reset="" fixture="" result=""
	now="$(_ghrs_now)"
	future_reset=$((now + 3600))
	past_reset=$((now - 1))
	fixture=$(rate_fixture 0 "$future_reset")
	gh_request_state_rate_put "$fixture"
	result=$(gh_request_state_rate_get normal 20)
	assert_eq "shared rate state preserves exhausted zero distinctly" "0" "$(printf '%s' "$result" | jq -r '.resources.graphql.remaining')"
	AIDEVOPS_GH_AUTH_PRINCIPAL=alternate
	if gh_request_state_rate_get normal 20 >/dev/null 2>&1; then
		printf 'FAIL: shared rate state leaked across auth principals\n' >&2
		return 1
	fi
	printf 'PASS: shared rate state rejects another auth principal\n'
	AIDEVOPS_GH_AUTH_PRINCIPAL=default
	fixture=$(rate_fixture 100 "$past_reset")
	gh_request_state_rate_put "$fixture"
	if gh_request_state_rate_get normal 20 >/dev/null 2>&1; then
		printf 'FAIL: normal rate state trusted a snapshot after reset\n' >&2
		return 1
	fi
	printf 'PASS: normal rate state expires at the observed reset boundary\n'
	result=$(gh_request_state_rate_get cached-only 20)
	assert_eq "cached-only diagnostics retain validated historical state" "100" "$(printf '%s' "$result" | jq -r '.resources.graphql.remaining')"
	return 0
}

test_relative_rate_path_uses_current_directory() {
	local relative_file="relative-rate.json"
	local now="" reset_at="" fixture="" result=""
	(
		cd "$TEST_ROOT" || return 1
		export AIDEVOPS_GH_REQUEST_STATE_RATE_FILE="$relative_file"
		now="$(_ghrs_now)"
		reset_at=$((now + 3600))
		fixture=$(rate_fixture 321 "$reset_at")
		gh_request_state_rate_put "$fixture"
		if [[ ! -f "$relative_file" ]]; then
			printf 'FAIL: relative rate path was not written as a file\n' >&2
			return 1
		fi
		result=$(gh_request_state_rate_get normal 20)
		assert_eq "relative rate path preserves the validated snapshot" "321" \
			"$(printf '%s' "$result" | jq -r '.resources.graphql.remaining')"
		assert_eq "relative rate snapshot remains private" "600" "$(file_mode "$relative_file")"
		assert_eq "root-level rate paths resolve without chmodding root" "/" "$(_ghrs_rate_parent_dir /rate.json)"
	)
	return $?
}

rate_transport() {
	local now="" reset_at=""
	printf 'transport\n' >>"${TEST_ROOT}/rate-transport-count"
	sleep 0.25
	now="$(_ghrs_now)"
	reset_at=$((now + 3600))
	rate_fixture 4321 "$reset_at"
	return 0
}

test_concurrent_rate_probe_is_singleflight() {
	local worker=0 pid=0 count=0 output=""
	local -a pids=()
	rm -f "$AIDEVOPS_GH_REQUEST_STATE_RATE_FILE"
	: >"${TEST_ROOT}/rate-transport-count"
	for worker in 1 2 3 4; do
		(gh_request_state_rate_json normal 20 rate_transport >"${TEST_ROOT}/rate-${worker}.out") &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		wait "$pid"
	done
	count=$(wc -l <"${TEST_ROOT}/rate-transport-count" | tr -d '[:space:]')
	assert_eq "concurrent rate-limit readers perform one transport probe" "1" "$count"
	for worker in 1 2 3 4; do
		output=$(jq -r '.resources.graphql.remaining' "${TEST_ROOT}/rate-${worker}.out")
		assert_eq "rate follower ${worker} reuses the shared snapshot" "4321" "$output"
	done
	return 0
}

main() {
	test_efficiency_event_mapping
	test_scope_key_isolation
	test_default_state_root_is_operational
	test_portable_mtime_dependency_is_available
	test_concurrent_workers_share_one_result
	test_observed_follower_consumes_matching_outcome
	test_dead_leader_is_recovered
	test_expired_live_leader_is_fenced
	test_live_leader_wait_is_bounded
	test_failed_stale_reclaim_reaches_timeout
	test_ownerless_lease_recovery_and_disabled_mode
	test_request_invalidation_generations_are_atomic
	test_rate_state_validation_scope_and_reset
	test_relative_rate_path_uses_current_directory
	test_concurrent_rate_probe_is_singleflight
	printf 'PASS: shared GitHub request-state regression suite\n'
	return 0
}

main "$@"
