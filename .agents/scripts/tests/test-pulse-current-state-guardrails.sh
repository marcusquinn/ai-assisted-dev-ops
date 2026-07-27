#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-current-state-guardrails.sh — mission m-20260504-1e325d task 3.4.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
export AIDEVOPS_HEADLESS_METRICS_FILE="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
: >"$LOGFILE"
: >"$AIDEVOPS_HEADLESS_METRICS_FILE"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

STATS_COUNTER_FILE="${TEST_ROOT}/stats-counter.log"
STATS_GAUGE_FILE="${TEST_ROOT}/stats-gauge.log"
: >"$STATS_COUNTER_FILE"
: >"$STATS_GAUGE_FILE"

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}

pulse_stats_set_gauge() {
	local gauge_name="$1"
	local gauge_value="$2"
	printf '%s=%s\n' "$gauge_name" "$gauge_value" >>"$STATS_GAUGE_FILE"
	return 0
}

get_max_workers_target() {
	printf '24\n'
	return 0
}

reset_guardrail_env() {
	: >"$LOGFILE"
	: >"$AIDEVOPS_HEADLESS_METRICS_FILE"
	: >"$STATS_COUNTER_FILE"
	: >"$STATS_GAUGE_FILE"
	unset PULSE_DISPATCH_CURRENT_STATE_COUNTS 2>/dev/null || true
	unset AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS 2>/dev/null || true
	export PULSE_DISPATCH_GUARDRAIL_RATE_LIMIT_THRESHOLD=4
	export PULSE_DISPATCH_GUARDRAIL_FAILURE_THRESHOLD=6
	export PULSE_DISPATCH_GUARDRAIL_OPEN_PR_THRESHOLD=12
	export PULSE_DISPATCH_GUARDRAIL_NO_DISPATCHABLE_THRESHOLD=2
	return 0
}

guardrail_slots() {
	local counts="$1"
	local available_slots="$2"
	local floor_active="${3:-0}"
	export PULSE_DISPATCH_CURRENT_STATE_COUNTS="$counts"
	_dispatch_apply_current_state_guardrails 24 4 "$available_slots" "$floor_active" | awk '{print $3}'
	return 0
}

test_provider_rate_limits_pause_without_success() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 4 4 0" 8)
	if [[ "$slots" == "0" ]] && grep -q 'provider_rate_limit_pressure' "$LOGFILE"; then
		print_result "guardrail: provider-wide rate limits pause launches when no success evidence exists" 0
	else
		print_result "guardrail: provider-wide rate limits pause launches when no success evidence exists" 1 "slots=${slots}"
	fi
	return 0
}

test_provider_rate_limits_keep_probe_slot_with_success() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "2 6 5 0" 8)
	if [[ "$slots" == "1" ]]; then
		print_result "guardrail: provider pressure keeps one safe probe slot when successes exist" 0
	else
		print_result "guardrail: provider pressure keeps one safe probe slot when successes exist" 1 "slots=${slots}"
	fi
	return 0
}

test_repeated_failures_pause_without_success() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 6 0 0" 8)
	if [[ "$slots" == "0" ]] && grep -q 'repeated_failure_pressure' "$LOGFILE"; then
		print_result "guardrail: repeated failures pause raw concurrency without success evidence" 0
	else
		print_result "guardrail: repeated failures pause raw concurrency without success evidence" 1 "slots=${slots}"
	fi
	return 0
}

test_open_pr_backlog_is_repo_scoped_with_debt_exemption() {
	reset_guardrail_env
	local repos_file="${TEST_ROOT}/repos-pr-backlog.json"
	cat >"$repos_file" <<'JSON'
{"initialized_repos":[
  {"slug":"owner/repo-a","path":"/tmp/repo-a","pulse":true,"priority":"tooling"},
  {"slug":"owner/repo-b","path":"/tmp/repo-b","pulse":true,"priority":"tooling"}
]}
JSON
	export REPOS_JSON="$repos_file"
	check_repo_pulse_schedule() {
		return 0
	}
	check_repo_pulse_interval() {
		return 0
	}
	update_repo_pulse_timestamp() {
		return 0
	}
	pulse_pr_list_get() {
		local repo_slug="" previous_arg=""
		local arg=""
		for arg in "$@"; do
			if [[ "$previous_arg" == "--repo" ]]; then
				repo_slug="$arg"
				break
			fi
			previous_arg="$arg"
		done
		case "$repo_slug" in
			owner/repo-a) jq -n '[range(0; 12) | {number: .}]' ;;
			*) printf '[]\n' ;;
		esac
		return 0
	}
	list_dispatchable_issue_candidates_json() {
		local repo_slug="$1"
		local limit="$2"
		printf '%s' "$limit" >/dev/null
		case "$repo_slug" in
			owner/repo-a) printf '%s\n' '[{"number":1,"labels":[{"name":"bug"}]},{"number":2,"labels":[{"name":"quality-debt"},{"name":"source:review-feedback"}]}]' ;;
			owner/repo-b) printf '%s\n' '[{"number":3,"labels":[{"name":"bug"}]}]' ;;
			*) printf '[]\n' ;;
		esac
		return 0
	}

	local ranked="" repo_a_numbers="" repo_b_numbers=""
	ranked=$(build_ranked_dispatch_candidates_json 10)
	repo_a_numbers=$(jq -r '[.[] | select(.repo_slug == "owner/repo-a") | .number] | join(",")' <<<"$ranked")
	repo_b_numbers=$(jq -r '[.[] | select(.repo_slug == "owner/repo-b") | .number] | join(",")' <<<"$ranked")
	if [[ "$repo_a_numbers" == "2" && "$repo_b_numbers" == "3" ]]; then
		print_result "guardrail: repo A backlog does not throttle repo B and trusted review debt is exempt" 0
	else
		print_result "guardrail: repo A backlog does not throttle repo B and trusted review debt is exempt" 1 "repo_a=${repo_a_numbers} repo_b=${repo_b_numbers}"
	fi
	return 0
}

test_historical_pr_events_cannot_throttle() {
	reset_guardrail_env
	printf '%s\n' 'PR opened #1' 'PR merged #1' 'merged PR #2' 'opened PR #3' >>"$LOGFILE"
	pulse_pr_list_get() {
		printf '[]\n'
		return 0
	}
	local counts=""
	counts=$(_dispatch_recent_current_state_counts)
	if [[ "$counts" == "0 0 0 0" ]]; then
		print_result "guardrail: merged and historical PR log events cannot throttle dispatch" 0
	else
		print_result "guardrail: merged and historical PR log events cannot throttle dispatch" 1 "counts=${counts}"
	fi
	return 0
}

test_no_dispatchable_evidence_keeps_probe_slot() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 0 0 2" 8)
	if [[ "$slots" == "1" ]] && grep -q 'no_dispatchable_evidence' "$LOGFILE"; then
		print_result "guardrail: no-dispatchable evidence keeps one probe slot" 0
	else
		print_result "guardrail: no-dispatchable evidence keeps one probe slot" 1 "slots=${slots}"
	fi
	return 0
}

test_no_dispatchable_evidence_preserves_min_floor_slots() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 0 0 2" 8 1)
	if [[ "$slots" == "8" ]] && grep -q 'no_dispatchable_floor_bypass' "$LOGFILE"; then
		print_result "guardrail: no-dispatchable evidence preserves minimum floor slots" 0
	else
		print_result "guardrail: no-dispatchable evidence preserves minimum floor slots" 1 "slots=${slots}"
	fi
	return 0
}

test_clean_state_preserves_available_slots() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "3 1 0 0" 8)
	if [[ "$slots" == "8" ]] && grep -q '^pulse_dispatch_guardrail_available_slots=8$' "$STATS_GAUGE_FILE" && grep -q '^pulse_dispatch_guardrail_successes=3$' "$STATS_GAUGE_FILE"; then
		print_result "guardrail: clean current state preserves safe slots" 0
	else
		print_result "guardrail: clean current state preserves safe slots" 1 "slots=${slots}"
	fi
	return 0
}

test_disabled_guardrail_still_updates_available_slots_gauge() {
	reset_guardrail_env
	export AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
	local slots
	slots=$(guardrail_slots "0 0 0 0" 5)
	if [[ "$slots" == "5" ]] && grep -q '^pulse_dispatch_guardrail_available_slots=5$' "$STATS_GAUGE_FILE"; then
		print_result "guardrail: disabled current-state path still refreshes slot gauge" 0
	else
		print_result "guardrail: disabled current-state path still refreshes slot gauge" 1 "slots=${slots}"
	fi
	return 0
}

test_interactive_hold_reason_is_classified() {
	reset_guardrail_env
	printf '%s\n' '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=interactive_review_hold signal=interactive_review_hold issue=#4772 repo=exampleorg/examplerepo' >>"$LOGFILE"
	local reason
	reason=$(_dispatch_candidate_failure_reason 4772 exampleorg/examplerepo 3)
	if [[ "$reason" == "interactive_review_hold" ]]; then
		print_result "guardrail: interactive review hold classifies as benign block" 0
	else
		print_result "guardrail: interactive review hold classifies as benign block" 1 "reason=${reason}"
	fi
	return 0
}

test_pr_target_reason_is_classified_as_benign_block() {
	reset_guardrail_env
	printf '%s\n' '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=pr_target_not_dispatchable signal=pr_target_not_dispatchable issue=#4849 repo=exampleorg/examplerepo' >>"$LOGFILE"
	local reason
	reason=$(_dispatch_candidate_failure_reason 4849 exampleorg/examplerepo 3)
	if [[ "$reason" == "pr_target_not_dispatchable" ]] && _dispatch_candidate_benign_block_reason "$reason"; then
		print_result "guardrail: PR target classifies as benign block" 0
	else
		print_result "guardrail: PR target classifies as benign block" 1 "reason=${reason}"
	fi
	return 0
}

test_deterministic_block_reasons_are_benign() {
	reset_guardrail_env
	local reason failures=0
	for reason in blocked_by_unresolved consolidated footprint_overlap issue_closed no_auto_dispatch parent_task; do
		if ! _dispatch_candidate_benign_block_reason "$reason"; then
			failures=$((failures + 1))
		fi
	done
	if [[ "$failures" -eq 0 ]]; then
		print_result "guardrail: deterministic blocker reasons are benign blocks" 0
	else
		print_result "guardrail: deterministic blocker reasons are benign blocks" 1 "failures=${failures}"
	fi
	return 0
}

test_benign_block_ledger_is_cycle_local_and_cleaned() {
	reset_guardrail_env
	local first_ledger second_ledger lingering_reason=""
	local scratch_dir="${HOME}/.aidevops/logs/.pulse-dispatch-benign-blocks"
	local first_basename=""
	local scratch_mode=""
	local ledger_mode=""
	_dispatch_begin_benign_blocks_cycle >/dev/null
	first_ledger="$_DISPATCH_BENIGN_BLOCKS_FILE"
	first_basename="${first_ledger##*/}"
	scratch_mode=$(_file_perms "$scratch_dir") || scratch_mode=""
	ledger_mode=$(_file_perms "$first_ledger") || ledger_mode=""
	_dispatch_mark_benign_blocked_candidate 23541 marcusquinn/aidevops dedup_active_claim
	_dispatch_cleanup_benign_blocks_cycle
	_dispatch_begin_benign_blocks_cycle >/dev/null
	second_ledger="$_DISPATCH_BENIGN_BLOCKS_FILE"
	lingering_reason=$(_dispatch_benign_blocked_candidate_reason 23541 marcusquinn/aidevops 2>/dev/null || true)
	_dispatch_cleanup_benign_blocks_cycle
	if [[ "$first_ledger" != "$second_ledger" && ! -e "$first_ledger" && ! -e "$second_ledger" && -z "$lingering_reason" ]] &&
		[[ "$first_ledger" == "$scratch_dir"/benign-blocks.*.* ]] &&
		_dispatch_benign_blocks_owner_pid "$first_basename" >/dev/null &&
		[[ "$scratch_mode" == "700" && "$ledger_mode" == "600" ]]; then
		print_result "guardrail: benign block ledger is cycle-local and cleaned" 0
	else
		print_result "guardrail: benign block ledger is cycle-local and cleaned" 1 "first=${first_ledger} second=${second_ledger} lingering=${lingering_reason} scratch_mode=${scratch_mode} ledger_mode=${ledger_mode}"
	fi
	return 0
}

test_stale_benign_block_ledgers_are_reaped_safely() {
	reset_guardrail_env
	local scratch_dir="${HOME}/.aidevops/logs/.pulse-dispatch-benign-blocks"
	local logs_dir="${HOME}/.aidevops/logs"
	local dead_pid=999999999
	local live_pid="${BASHPID:-$$}"
	local saved_min_age="$_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS"
	while kill -0 "$dead_pid" 2>/dev/null; do
		dead_pid=$((dead_pid - 1))
	done
	_dispatch_prepare_benign_blocks_scratch_dir || {
		print_result "guardrail: stale benign block cleanup is exact and owner-aware" 1 "scratch setup failed"
		return 0
	}

	local dead_file="${scratch_dir}/benign-blocks.${dead_pid}.ABC123"
	local live_file="${scratch_dir}/benign-blocks.${live_pid}.LIVE12"
	local invalid_file="${scratch_dir}/benign-blocks.${dead_pid}.ABC12_"
	local unrelated_file="${scratch_dir}/unrelated.${dead_pid}.ABC123"
	local symlink_target="${TEST_ROOT}/managed-symlink-target"
	local managed_symlink="${scratch_dir}/benign-blocks.${dead_pid}.SYM123"
	local legacy_mktemp="${logs_dir}/pulse-dispatch-benign-blocks.LEG123"
	local legacy_fallback="${logs_dir}/pulse-dispatch-benign-blocks.${dead_pid}.12345"
	local legacy_recent="${logs_dir}/pulse-dispatch-benign-blocks.NEW123"
	local legacy_near_match="${logs_dir}/pulse-dispatch-benign-blocks.TOOLONG"
	local legacy_symlink_target="${TEST_ROOT}/legacy-symlink-target"
	local legacy_symlink="${logs_dir}/pulse-dispatch-benign-blocks.SYM123"

	printf 'dead\n' >"$dead_file"
	printf 'live\n' >"$live_file"
	printf 'invalid\n' >"$invalid_file"
	printf 'unrelated\n' >"$unrelated_file"
	printf 'target\n' >"$symlink_target"
	ln -s "$symlink_target" "$managed_symlink"
	printf 'legacy mktemp\n' >"$legacy_mktemp"
	printf 'legacy fallback\n' >"$legacy_fallback"
	printf 'legacy recent\n' >"$legacy_recent"
	printf 'legacy near match\n' >"$legacy_near_match"
	printf 'legacy target\n' >"$legacy_symlink_target"
	ln -s "$legacy_symlink_target" "$legacy_symlink"
	touch -t 200001010000 "$legacy_mktemp" "$legacy_fallback" "$legacy_near_match"
	_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS=3600
	_dispatch_cleanup_stale_benign_blocks
	_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS="$saved_min_age"

	if [[ ! -e "$dead_file" && -f "$live_file" && -f "$invalid_file" && -f "$unrelated_file" ]] &&
		[[ -L "$managed_symlink" && -f "$symlink_target" ]] &&
		[[ ! -e "$legacy_mktemp" && ! -e "$legacy_fallback" && -f "$legacy_recent" && -f "$legacy_near_match" ]] &&
		[[ -L "$legacy_symlink" && -f "$legacy_symlink_target" ]]; then
		print_result "guardrail: stale benign block cleanup is exact and owner-aware" 0
	else
		print_result "guardrail: stale benign block cleanup is exact and owner-aware" 1 "dead=$([[ -e "$dead_file" ]] && printf yes || printf no) live=$([[ -f "$live_file" ]] && printf yes || printf no) legacy=$([[ -e "$legacy_mktemp" ]] && printf yes || printf no)"
	fi
	return 0
}

test_benign_block_ledger_crash_recovery() {
	reset_guardrail_env
	local lib_file="${SCRIPT_DIR}/pulse-dispatch-lib.sh"
	local graceful_marker="${TEST_ROOT}/graceful-ledger-path"
	local killed_marker="${TEST_ROOT}/killed-ledger-path"
	local kill_runner="${TEST_ROOT}/run-benign-ledger-sigkill"
	local graceful_status=0
	local killed_status=0
	local graceful_ledger=""
	local killed_ledger=""
	local killed_was_present=0

	LEDGER_MARKER="$graceful_marker" bash -c '
		source "$1"
		trap "_dispatch_cleanup_benign_blocks_cycle" EXIT
		_dispatch_begin_benign_blocks_cycle >/dev/null
		printf "%s\n" "$_DISPATCH_BENIGN_BLOCKS_FILE" >"$LEDGER_MARKER"
		exit 23
	' _ "$lib_file" >/dev/null 2>&1 || graceful_status=$?
	[[ -f "$graceful_marker" ]] && read -r graceful_ledger <"$graceful_marker"

	cat >"$kill_runner" <<'EOF_KILL_RUNNER'
#!/usr/bin/env bash
bash -c '
	source "$1"
	_dispatch_begin_benign_blocks_cycle >/dev/null
	printf "%s\n" "$_DISPATCH_BENIGN_BLOCKS_FILE" >"$LEDGER_MARKER"
	kill -KILL "${BASHPID:-$$}"
' _ "$1"
child_status=$?
exit "$child_status"
EOF_KILL_RUNNER
	chmod +x "$kill_runner"
	LEDGER_MARKER="$killed_marker" "$kill_runner" "$lib_file" >/dev/null 2>&1 || killed_status=$?
	[[ -f "$killed_marker" ]] && read -r killed_ledger <"$killed_marker"
	[[ -n "$killed_ledger" && -f "$killed_ledger" ]] && killed_was_present=1
	_dispatch_cleanup_stale_benign_blocks

	if [[ "$graceful_status" -eq 23 && -n "$graceful_ledger" && ! -e "$graceful_ledger" ]] &&
		[[ "$killed_status" -eq 137 && "$killed_was_present" -eq 1 && -n "$killed_ledger" && ! -e "$killed_ledger" ]]; then
		print_result "guardrail: EXIT cleanup and next-start SIGKILL recovery remove managed ledgers" 0
	else
		print_result "guardrail: EXIT cleanup and next-start SIGKILL recovery remove managed ledgers" 1 "graceful_status=${graceful_status} killed_status=${killed_status} killed_present=${killed_was_present}"
	fi
	return 0
}

test_wrapper_registers_benign_block_cleanup() {
	local wrapper_file="${SCRIPT_DIR}/pulse-wrapper.sh"
	local cleanup_stack_count=""
	cleanup_stack_count=$(grep -c "push_cleanup '_dispatch_cleanup_benign_blocks_cycle'" "$wrapper_file" 2>/dev/null || true)
	if grep -Fq "trap '_dispatch_cleanup_benign_blocks_cycle;" "$wrapper_file" &&
		grep -Fq $'\t_dispatch_cleanup_stale_benign_blocks || true' "$wrapper_file" &&
		[[ "$cleanup_stack_count" == "2" ]]; then
		print_result "guardrail: pulse wrapper registers graceful and startup benign-ledger cleanup" 0
		return 0
	fi
	print_result "guardrail: pulse wrapper registers graceful and startup benign-ledger cleanup" 1 "cleanup_stack_count=${cleanup_stack_count}"
	return 0
}

test_external_benign_block_ledger_is_preserved_and_refreshed() {
	reset_guardrail_env
	local external_ledger="${TEST_ROOT}/external-benign-blocks.tsv"
	local ledger_path=""
	printf '%s\t%s\t%s\n' 101 marcusquinn/aidevops caller_managed >"$external_ledger"
	export AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE="$external_ledger"
	_dispatch_begin_benign_blocks_cycle >/dev/null
	ledger_path="$_DISPATCH_BENIGN_BLOCKS_FILE"
	_dispatch_mark_benign_blocked_candidate 23575 marcusquinn/aidevops dedup_active_claim
	_dispatch_cleanup_benign_blocks_cycle
	unset AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE
	if [[ "$ledger_path" == "$external_ledger" ]] && [[ -f "$external_ledger" ]] && ! grep -q $'^101\tmarcusquinn/aidevops\tcaller_managed$' "$external_ledger" && grep -q $'^23575\tmarcusquinn/aidevops\tdedup_active_claim$' "$external_ledger"; then
		print_result "guardrail: external benign block ledger is preserved and refreshed" 0
	else
		print_result "guardrail: external benign block ledger is preserved and refreshed" 1 "ledger=${ledger_path}"
	fi
	return 0
}

test_apply_dispatch_max_preserves_benign_ledger_across_refill() {
	reset_guardrail_env
	export AIDEVOPS_MIN_WORKER_CONCURRENCY=2
	local dispatch_calls_file="${TEST_ROOT}/dispatch-calls"
	local refill_reason_file="${TEST_ROOT}/refill-seen-reason"
	local child_env_file="${TEST_ROOT}/refill-child-env-sees-ledger"
	printf '0\n' >"$dispatch_calls_file"
	: >"$refill_reason_file"
	: >"$child_env_file"
	local dispatch_calls=""
	local refill_seen_reason=""
	local child_env_seen=""
	local ledger_after=""

	dispatch_max() {
		local current_calls=""
		current_calls=$(<"$dispatch_calls_file")
		[[ "$current_calls" =~ ^[0-9]+$ ]] || current_calls=0
		current_calls=$((current_calls + 1))
		printf '%s\n' "$current_calls" >"$dispatch_calls_file"
		if [[ "$current_calls" -eq 1 ]]; then
			_dispatch_mark_benign_blocked_candidate 23541 marcusquinn/aidevops dedup_active_claim
			printf '1\n'
		else
			if bash -c '[[ -n "${_DISPATCH_BENIGN_BLOCKS_FILE:-}" && -f "${_DISPATCH_BENIGN_BLOCKS_FILE}" ]]'; then
				printf 'yes\n' >"$child_env_file"
			fi
			_dispatch_benign_blocked_candidate_reason 23541 marcusquinn/aidevops >"$refill_reason_file" 2>/dev/null || true
			printf '0\n'
		fi
		return 0
	}

	count_active_workers() {
		printf '0\n'
		return 0
	}

	_adaptive_launch_settle_wait() {
		return 0
	}

	apply_dispatch_max
	dispatch_calls=$(<"$dispatch_calls_file")
	refill_seen_reason=$(<"$refill_reason_file")
	child_env_seen=$(<"$child_env_file")
	ledger_after="${_DISPATCH_BENIGN_BLOCKS_FILE:-}"
	unset AIDEVOPS_MIN_WORKER_CONCURRENCY
	if [[ "$dispatch_calls" -ge 2 && "$refill_seen_reason" == "dedup_active_claim" && "$child_env_seen" == "yes" && -z "$ledger_after" ]]; then
		print_result "guardrail: apply_dispatch_max preserves benign block ledger across refill" 0
	else
		print_result "guardrail: apply_dispatch_max preserves benign block ledger across refill" 1 "calls=${dispatch_calls} reason=${refill_seen_reason} child_env=${child_env_seen} ledger_after=${ledger_after}"
	fi
	return 0
}

test_dispatch_max_exports_benign_ledger_for_direct_callers() {
	local engine_file="${SCRIPT_DIR}/pulse-dispatch-engine.sh"
	if awk '
		/^dispatch_max\(\) \{/ { in_dispatch=1 }
		in_dispatch && /_dispatch_begin_benign_blocks_cycle >\/dev\/null/ { saw_begin=1 }
		in_dispatch && saw_begin && /export _DISPATCH_BENIGN_BLOCKS_FILE/ { found=1; exit 0 }
		in_dispatch && /^}/ { exit 1 }
		END { exit(found ? 0 : 1) }
	' "$engine_file"; then
		print_result "guardrail: dispatch_max exports benign block ledger for direct callers" 0
		return 0
	fi

	print_result "guardrail: dispatch_max exports benign block ledger for direct callers" 1 "missing export in dispatch_max"
	return 0
}

test_ranked_candidates_prioritise_solvable_work() {
	reset_guardrail_env
	local repos_file="${TEST_ROOT}/repos.json"
	cat >"$repos_file" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/repo", "path": "/tmp/repo", "pulse": true, "priority": "tooling"}
  ]
}
JSON
	export REPOS_JSON="$repos_file"

	check_repo_pulse_schedule() {
		return 0
	}

	check_repo_pulse_interval() {
		return 0
	}

	update_repo_pulse_timestamp() {
		return 0
	}

	list_dispatchable_issue_candidates_json() {
		local repo_slug="$1"
		local limit="$2"
		printf '%s %s\n' "$repo_slug" "$limit" >/dev/null
		cat <<'JSON'
[
  {"number": 10, "title": "broad enhancement", "updatedAt": "2026-05-01T00:00:00Z", "labels": [{"name": "enhancement"}, {"name": "tier:thinking"}], "assignees": []},
  {"number": 11, "title": "small worker-ready fix", "updatedAt": "2026-05-02T00:00:00Z", "labels": [{"name": "enhancement"}, {"name": "tier:simple"}, {"name": "worker-ready"}, {"name": "auto-dispatch"}], "assignees": []},
  {"number": 12, "title": "plain bug", "updatedAt": "2026-05-03T00:00:00Z", "labels": [{"name": "bug"}], "assignees": []}
]
JSON
		return 0
	}

	local first_number=""
	first_number=$(build_ranked_dispatch_candidates_json 10 | jq -r '.[0].number' 2>/dev/null) || first_number=""
	if [[ "$first_number" == "11" ]]; then
		print_result "guardrail: ranked dispatch prefers solvable worker-ready issues over raw backlog" 0
	else
		print_result "guardrail: ranked dispatch prefers solvable worker-ready issues over raw backlog" 1 "first=${first_number}"
	fi
	return 0
}

test_ranked_candidates_prioritise_low_complexity_over_research() {
	reset_guardrail_env
	local repos_file="${TEST_ROOT}/repos-low-complexity.json"
	cat >"$repos_file" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/repo", "path": "/tmp/repo", "pulse": true, "priority": "tooling"}
  ]
}
JSON
	export REPOS_JSON="$repos_file"

	check_repo_pulse_schedule() {
		return 0
	}

	check_repo_pulse_interval() {
		return 0
	}

	update_repo_pulse_timestamp() {
		return 0
	}

	list_dispatchable_issue_candidates_json() {
		local repo_slug="$1"
		local limit="$2"
		printf '%s %s\n' "$repo_slug" "$limit" >/dev/null
		cat <<'JSON'
[
  {"number": 20, "title": "broad research priority", "updatedAt": "2026-05-01T00:00:00Z", "labels": [{"name": "priority:high"}, {"name": "research"}, {"name": "tier:thinking"}], "assignees": []},
  {"number": 21, "title": "low complexity actionable fix", "updatedAt": "2026-05-02T00:00:00Z", "labels": [{"name": "enhancement"}, {"name": "low-complexity"}, {"name": "status:available"}], "assignees": []}
]
JSON
		return 0
	}

	local first_number=""
	first_number=$(build_ranked_dispatch_candidates_json 10 | jq -r '.[0].number' 2>/dev/null) || first_number=""
	if [[ "$first_number" == "21" ]]; then
		print_result "guardrail: ranked dispatch prefers low-complexity actionable work over research backlog" 0
	else
		print_result "guardrail: ranked dispatch prefers low-complexity actionable work over research backlog" 1 "first=${first_number}"
	fi
	return 0
}

test_provider_rate_limits_pause_without_success
test_provider_rate_limits_keep_probe_slot_with_success
test_repeated_failures_pause_without_success
test_open_pr_backlog_is_repo_scoped_with_debt_exemption
test_historical_pr_events_cannot_throttle
test_no_dispatchable_evidence_keeps_probe_slot
test_no_dispatchable_evidence_preserves_min_floor_slots
test_clean_state_preserves_available_slots
test_disabled_guardrail_still_updates_available_slots_gauge
test_interactive_hold_reason_is_classified
test_pr_target_reason_is_classified_as_benign_block
test_deterministic_block_reasons_are_benign
test_benign_block_ledger_is_cycle_local_and_cleaned
test_stale_benign_block_ledgers_are_reaped_safely
test_benign_block_ledger_crash_recovery
test_wrapper_registers_benign_block_cleanup
test_external_benign_block_ledger_is_preserved_and_refreshed
test_dispatch_max_exports_benign_ledger_for_direct_callers
test_apply_dispatch_max_preserves_benign_ledger_across_refill
test_ranked_candidates_prioritise_solvable_work
test_ranked_candidates_prioritise_low_complexity_over_research

printf '\n====================\n'
printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
printf '====================\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
