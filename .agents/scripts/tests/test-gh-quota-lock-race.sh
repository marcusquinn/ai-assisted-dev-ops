#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#29107: quota lock reclamation must tolerate an
# owner releasing the lock between PID inspection and PID content capture.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."
TEST_ROOT=""
PASS=0
FAIL=0

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_eq() {
	local message="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$message"
	else
		fail "${message} (expected=${expected}, actual=${actual})"
	fi
	return 0
}

TEST_ROOT="$(mktemp -d -t aidevops-ghqa-lock-XXXXXX)" || exit 1
# shellcheck source=../gh-quota-attribution-lib.sh
source "${PARENT_DIR}/gh-quota-attribution-lib.sh"

race_lock_dir="${TEST_ROOT}/release-race.lock.d"
race_marker="${TEST_ROOT}/release-race-triggered"
race_stderr="${TEST_ROOT}/release-race.stderr"

# Intercept the PID reader so the existence check succeeds before the owner
# releases its PID. The reclaim guard keeps rmdir from removing the inspected
# directory while cat observes the disappeared file without emitting stderr.
cat() {
	local target="$1"
	local cat_rc=0
	if [[ "$target" == "${race_lock_dir}/pid" ]]; then
		rm -f "${race_lock_dir}/pid"
		command rmdir "$race_lock_dir" 2>/dev/null || true
		: >"$race_marker"
	fi
	command cat "$@" || cat_rc=$?
	[[ "$cat_rc" -eq 0 ]] || return 1
	return 0
}

ln() {
	local target="$2"
	local ln_rc=0
	local signal_pid=""
	command ln "$@" || ln_rc=$?
	if [[ "$ln_rc" -eq 0 && "$target" == "${signal_lock_dir:-}/.reclaim.guard" ]]; then
		signal_pid=$(command cat "$target" 2>/dev/null) || signal_pid=""
		[[ "$signal_pid" =~ ^[0-9]+$ ]] || return 1
		kill -TERM "$signal_pid"
	fi
	[[ "$ln_rc" -eq 0 ]] || return 1
	return 0
}

command mkdir "$race_lock_dir"
printf '%s\n' "${BASHPID:-$$}" >"${race_lock_dir}/pid"

race_rc=0
_ghqa_lock_reclaim "$race_lock_dir" 0 2>"$race_stderr" || race_rc=$?
unset -f cat
assert_eq "release race fixture reaches the guarded PID boundary" "yes" "$([[ -f "$race_marker" ]] && printf 'yes' || printf 'no')"
assert_eq "disappearing PID is treated as retryable contention" "1" "$race_rc"
stderr_bytes=$(wc -c <"$race_stderr" | tr -d ' ')
assert_eq "disappearing PID emits no shell diagnostic" "0" "$stderr_bytes"

acquire_rc=0
AIDEVOPS_GH_QUOTA_LOCK_TRIES=110 _ghqa_lock_acquire "$race_lock_dir" 2>>"$race_stderr" || acquire_rc=$?
assert_eq "ownerless lock left by the release race is eventually acquired" "0" "$acquire_rc"
acquired_owner=""
IFS= read -r acquired_owner 2>/dev/null <"${race_lock_dir}/pid" || acquired_owner=""
assert_eq "eventual acquisition publishes the contender PID" "${BASHPID:-$$}" "$acquired_owner"
_ghqa_lock_release "$race_lock_dir"

live_lock_dir="${TEST_ROOT}/live-owner.lock.d"
mkdir "$live_lock_dir"
printf '%s\n' "${BASHPID:-$$}" >"${live_lock_dir}/pid"
live_rc=0
_ghqa_lock_reclaim "$live_lock_dir" 100 || live_rc=$?
assert_eq "live owner lock is not reclaimed after the ownerless threshold" "1" "$live_rc"
live_owner=""
IFS= read -r live_owner <"${live_lock_dir}/pid" || live_owner=""
assert_eq "live owner PID remains intact" "${BASHPID:-$$}" "$live_owner"
_ghqa_lock_release "$live_lock_dir"

stale_lock_dir="${TEST_ROOT}/stale-owner.lock.d"
mkdir "$stale_lock_dir"
printf '%s\n' '999999999' >"${stale_lock_dir}/pid"
stale_rc=0
_ghqa_lock_reclaim "$stale_lock_dir" 0 || stale_rc=$?
assert_eq "dead owner lock remains immediately reclaimable" "0" "$stale_rc"
assert_eq "dead owner lock path is removed" "no" "$([[ -e "$stale_lock_dir" ]] && printf 'yes' || printf 'no')"

ownerless_lock_dir="${TEST_ROOT}/ownerless.lock.d"
mkdir "$ownerless_lock_dir"
ownerless_early_rc=0
_ghqa_lock_reclaim "$ownerless_lock_dir" 99 || ownerless_early_rc=$?
assert_eq "ownerless lock keeps its bounded grace" "1" "$ownerless_early_rc"
ownerless_bounded_rc=0
_ghqa_lock_reclaim "$ownerless_lock_dir" 100 || ownerless_bounded_rc=$?
assert_eq "ownerless lock is reclaimable after the bound" "0" "$ownerless_bounded_rc"

signal_lock_dir="${TEST_ROOT}/signal-owner.lock.d"
signal_stderr="${TEST_ROOT}/signal-owner.stderr"
command mkdir "$signal_lock_dir"
printf '%s\n' "${BASHPID:-$$}" >"${signal_lock_dir}/pid"
signal_rc=0
_ghqa_lock_reclaim "$signal_lock_dir" 0 2>"$signal_stderr" || signal_rc=$?
unset -f ln
assert_eq "guard-install interruption stops reclamation" "yes" "$([[ "$signal_rc" -ne 0 ]] && printf 'yes' || printf 'no')"
assert_eq "guard-install interruption leaves complete stale evidence" "yes" "$([[ -f "${signal_lock_dir}/.reclaim.guard" ]] && printf 'yes' || printf 'no')"
signal_recovery_rc=0
_ghqa_lock_reclaim "$signal_lock_dir" 0 2>>"$signal_stderr" || signal_recovery_rc=$?
assert_eq "retry clears an interrupted stale guard" "1" "$signal_recovery_rc"
assert_eq "stale guard recovery removes the orphan" "no" "$([[ -e "${signal_lock_dir}/.reclaim.guard" ]] && printf 'yes' || printf 'no')"
signal_owner=""
IFS= read -r signal_owner <"${signal_lock_dir}/pid" || signal_owner=""
assert_eq "stale guard recovery preserves the live owner" "${BASHPID:-$$}" "$signal_owner"
_ghqa_lock_release "$signal_lock_dir"

replacement_lock_dir="${TEST_ROOT}/replacement.lock.d"
replacement_expected_owner="${BASHPID:-$$}"
command mkdir "$replacement_lock_dir"
printf '%s\n' '999999999' >"${replacement_lock_dir}/pid"
mv() {
	local source="$1"
	local destination="$2"
	local mv_rc=0
	command mv "$source" "$destination" || mv_rc=$?
	if [[ "$mv_rc" -eq 0 && "$source" == "$replacement_lock_dir" ]]; then
		command mkdir "$replacement_lock_dir"
		printf '%s\n' "$replacement_expected_owner" >"${replacement_lock_dir}/pid"
	fi
	[[ "$mv_rc" -eq 0 ]] || return 1
	return 0
}
replacement_rc=0
_ghqa_lock_reclaim "$replacement_lock_dir" 0 || replacement_rc=$?
unset -f mv
assert_eq "stale reclaim completes after a replacement appears" "0" "$replacement_rc"
replacement_owner=""
IFS= read -r replacement_owner <"${replacement_lock_dir}/pid" || replacement_owner=""
assert_eq "stale cleanup preserves the replacement live owner" "$replacement_expected_owner" "$replacement_owner"
_ghqa_lock_release "$replacement_lock_dir"

concurrent_lock_dir="${TEST_ROOT}/concurrent.lock.d"
concurrent_records="${TEST_ROOT}/concurrent-records.tsv"
concurrent_stderr="${TEST_ROOT}/concurrent.stderr"
concurrent_start="${TEST_ROOT}/concurrent.start"
concurrent_active="${TEST_ROOT}/concurrent.active"
: >"$concurrent_records"
: >"$concurrent_stderr"
contender_pids=()
contender=1
while [[ "$contender" -le 12 ]]; do
	bash -c '
		set -uo pipefail
		# shellcheck source=/dev/null
		source "$1"
		while [[ ! -f "$5" ]]; do sleep 0.01; done
		AIDEVOPS_GH_QUOTA_LOCK_TRIES=2000 _ghqa_lock_acquire "$2" || exit 1
		if ! command mkdir "$6"; then
			_ghqa_lock_release "$2"
			exit 2
		fi
		sleep 0.02
		printf "%s\t%s\n" "${BASHPID:-$$}" "$4" >>"$3"
		if ! command rmdir "$6"; then
			_ghqa_lock_release "$2"
			exit 3
		fi
		_ghqa_lock_release "$2"
	' _ "${PARENT_DIR}/gh-quota-attribution-lib.sh" "$concurrent_lock_dir" "$concurrent_records" "$contender" \
		"$concurrent_start" "$concurrent_active" \
		2>>"$concurrent_stderr" &
	contender_pids+=("$!")
	contender=$((contender + 1))
done
: >"$concurrent_start"
concurrent_rc=0
for contender_pid in "${contender_pids[@]}"; do
	wait "$contender_pid" || concurrent_rc=1
done
assert_eq "concurrent contenders all eventually acquire the lock" "0" "$concurrent_rc"
concurrent_count=$(wc -l <"$concurrent_records" | tr -d ' ')
assert_eq "concurrent contenders each append exactly one record" "12" "$concurrent_count"
concurrent_records_valid=yes
while IFS=$'\t' read -r record_pid record_id; do
	if [[ ! "$record_pid" =~ ^[0-9]+$ || ! "$record_id" =~ ^[0-9]+$ ]]; then
		concurrent_records_valid=no
		break
	fi
done <"$concurrent_records"
assert_eq "concurrent records remain well formed" "yes" "$concurrent_records_valid"
concurrent_stderr_bytes=$(wc -c <"$concurrent_stderr" | tr -d ' ')
if [[ "$concurrent_stderr_bytes" != 0 ]]; then
	command cat "$concurrent_stderr" >&2
fi
assert_eq "concurrent contenders emit no lock diagnostics" "0" "$concurrent_stderr_bytes"
assert_eq "concurrent fixture releases the final lock" "no" "$([[ -e "$concurrent_lock_dir" ]] && printf 'yes' || printf 'no')"
assert_eq "concurrent fixture leaves no overlapping-owner marker" "no" "$([[ -e "$concurrent_active" ]] && printf 'yes' || printf 'no')"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
