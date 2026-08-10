#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for t2119 + t2387 worker reliability self-heal bundle:
#
#   Part A — check_launchd_plist_drift:
#     - No drift: stored hash matches current schedulers.sh hash → no-op.
#     - Drift: stored hash differs → runs setup.sh and updates stamp.
#     - Bootstrap: no stored hash → treated as drift (self-heals pre-t2119 installs).
#     - Rate limit: stamp newer than interval → skipped without work.
#
#   Part B — escalate_issue_tier no_work skipping (t2119 + t2387):
#     - When crash_type="no_work", _escalate_body_quality_gate must NOT be
#       called regardless of body content (structural assertion on source).
#     - When crash_type="no_work", the entire tier cascade must be skipped
#       via an early return BEFORE any `gh issue edit` tier-mutation line
#       (t2387). The early-return block must call
#       _log_no_work_skip_escalation so operators get a diagnostic comment.
#     - _log_no_work_skip_escalation must exist and emit the
#       <!-- no-work-escalation-skip --> marker.
#
#   Part C — _preserve_no_activity_output:
#     - Moves the output file to the diagnostics dir instead of deleting.
#     - Size-caps at 256KB with truncation marker on overflow.
#     - Retention-caps the diagnostic directory to 50 files.
#     - Handles missing/empty output_file without erroring.
#
# Pattern matches .agents/scripts/tests/test-pulse-merge-update-branch.sh:
# extract the helper source from the real script via awk, eval it into the
# test shell, and drive the function with controlled inputs + stubs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# check_launchd_plist_drift moved to auto-update-freshness-lib.sh when
# auto-update-helper.sh was split in GH#20343.
AUTO_UPDATE_SCRIPT="${REPO_ROOT}/.agents/scripts/auto-update-freshness-lib.sh"
HEADLESS_SCRIPT="${REPO_ROOT}/.agents/scripts/headless-runtime-helper.sh"
HEADLESS_WORKER_SCRIPT="${REPO_ROOT}/.agents/scripts/headless-runtime-worker.sh"
LIFECYCLE_SCRIPT="${REPO_ROOT}/.agents/scripts/worker-lifecycle-common.sh"
SCHEDULERS_SCRIPT="${REPO_ROOT}/.agents/scripts/setup/modules/schedulers.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/home/.aidevops/.agent-workspace/tmp"
	mkdir -p "${TEST_ROOT}/home/.aidevops/logs"
	mkdir -p "${TEST_ROOT}/install/.agents/scripts"
	mkdir -p "${TEST_ROOT}/install/.agents/scripts/setup/modules"
	# Install a fake schedulers.sh so drift detection has something to hash
	printf '#!/usr/bin/env bash\n# fake schedulers v1\n' >"${TEST_ROOT}/install/.agents/scripts/setup/modules/schedulers.sh"
	# Install a fake setup.sh so drift detection can "run" it
	cat >"${TEST_ROOT}/install/setup.sh" <<'FSETUP'
#!/usr/bin/env bash
# Fake setup.sh for t2119 tests — records the invocation and succeeds.
printf '%s\n' "FAKE_SETUP_INVOKED $*" >>"${TEST_SETUP_LOG:-/tmp/fake-setup.log}"
exit 0
FSETUP
	chmod +x "${TEST_ROOT}/install/setup.sh"

	export HOME="${TEST_ROOT}/home"
	export INSTALL_DIR="${TEST_ROOT}/install"
	export LOG_FILE="${TEST_ROOT}/home/.aidevops/logs/auto-update.log"
	: >"$LOG_FILE"
	TEST_SETUP_LOG="${TEST_ROOT}/fake-setup.log"
	export TEST_SETUP_LOG
	: >"$TEST_SETUP_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Stub logging functions so extracted helpers can run standalone.
_install_log_stubs() {
	log_info() { printf '[info] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
	log_warn() { printf '[warn] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
	log_error() { printf '[error] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
	# Extracted preservation helper depends on the launch-level privacy guard.
	_headless_private_workload_enabled() { return 1; }
	return 0
}

# Extract + eval the check_launchd_plist_drift function from auto-update-helper.sh
define_drift_helper() {
	local helper_src
	helper_src=$(awk '
		/^check_launchd_plist_drift\(\) \{/,/^}$/ { print }
	' "$AUTO_UPDATE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract check_launchd_plist_drift\n' >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

define_preserve_helper() {
	local helper_src
	helper_src=$(awk '
		/^_preserve_no_activity_output\(\) \{/,/^}$/ { print }
	' "$HEADLESS_SCRIPT")
	if [[ -z "$helper_src" && -f "$HEADLESS_WORKER_SCRIPT" ]]; then
		helper_src=$(awk '
			/^_preserve_no_activity_output\(\) \{/,/^}$/ { print }
		' "$HEADLESS_WORKER_SCRIPT")
	fi
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _preserve_no_activity_output from %s or %s\n' \
			"$HEADLESS_SCRIPT" "$HEADLESS_WORKER_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

# -----------------------------------------------------------------
# Part A — plist drift tests
# -----------------------------------------------------------------

test_drift_bootstrap_triggers_setup() {
	# No stored hash → treat as drift → must run setup.sh
	rm -f "${HOME}/.aidevops/.agent-workspace/tmp/schedulers-template-hash.state"
	rm -f "${HOME}/.aidevops/.agent-workspace/tmp/plist-drift-check.stamp"
	: >"$TEST_SETUP_LOG"

	check_launchd_plist_drift

	if ! grep -q "FAKE_SETUP_INVOKED" "$TEST_SETUP_LOG"; then
		print_result "drift: bootstrap (no stored hash) runs setup.sh" 1 \
			"Expected setup.sh invocation; LOG_FILE: $(cat "$LOG_FILE" | tail -5)"
		return 0
	fi
	print_result "drift: bootstrap (no stored hash) runs setup.sh" 0
	return 0
}

test_drift_match_skips_setup() {
	# Pre-seed a matching hash → no drift → setup must NOT run
	local current_hash
	current_hash=$(shasum -a 256 "${INSTALL_DIR}/.agents/scripts/setup/modules/schedulers.sh" | awk '{print $1}')
	printf '%s\n' "$current_hash" >"${HOME}/.aidevops/.agent-workspace/tmp/schedulers-template-hash.state"
	rm -f "${HOME}/.aidevops/.agent-workspace/tmp/plist-drift-check.stamp"
	: >"$TEST_SETUP_LOG"

	check_launchd_plist_drift

	if grep -q "FAKE_SETUP_INVOKED" "$TEST_SETUP_LOG"; then
		print_result "drift: matching hash skips setup.sh" 1 \
			"setup.sh was invoked unexpectedly"
		return 0
	fi
	print_result "drift: matching hash skips setup.sh" 0
	return 0
}

test_drift_mismatch_triggers_setup() {
	# Stored hash differs → drift → must run setup.sh
	printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeef" \
		>"${HOME}/.aidevops/.agent-workspace/tmp/schedulers-template-hash.state"
	rm -f "${HOME}/.aidevops/.agent-workspace/tmp/plist-drift-check.stamp"
	: >"$TEST_SETUP_LOG"

	check_launchd_plist_drift

	if ! grep -q "FAKE_SETUP_INVOKED" "$TEST_SETUP_LOG"; then
		print_result "drift: mismatched hash runs setup.sh" 1 \
			"setup.sh was NOT invoked on drift"
		return 0
	fi
	print_result "drift: mismatched hash runs setup.sh" 0
	return 0
}

test_drift_rate_limit_suppresses_check() {
	# Fresh stamp + mismatched hash → should skip due to rate limit
	printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeef" \
		>"${HOME}/.aidevops/.agent-workspace/tmp/schedulers-template-hash.state"
	date +%s >"${HOME}/.aidevops/.agent-workspace/tmp/plist-drift-check.stamp"
	: >"$TEST_SETUP_LOG"

	check_launchd_plist_drift

	if grep -q "FAKE_SETUP_INVOKED" "$TEST_SETUP_LOG"; then
		print_result "drift: rate-limit stamp suppresses check" 1 \
			"setup.sh was invoked despite fresh stamp"
		return 0
	fi
	print_result "drift: rate-limit stamp suppresses check" 0
	return 0
}

test_drift_stores_stamp_after_run() {
	# After a drift-triggered run, stamp must exist and be recent
	rm -f "${HOME}/.aidevops/.agent-workspace/tmp/schedulers-template-hash.state"
	rm -f "${HOME}/.aidevops/.agent-workspace/tmp/plist-drift-check.stamp"

	check_launchd_plist_drift

	local stamp="${HOME}/.aidevops/.agent-workspace/tmp/plist-drift-check.stamp"
	if [[ ! -f "$stamp" ]]; then
		print_result "drift: stamp written after check" 1 \
			"stamp file not created"
		return 0
	fi
	local age=$(($(date +%s) - $(cat "$stamp")))
	if [[ "$age" -gt 5 ]]; then
		print_result "drift: stamp written after check" 1 \
			"stamp is stale (age=${age}s)"
		return 0
	fi
	print_result "drift: stamp written after check" 0
	return 0
}

# -----------------------------------------------------------------
# Part B — escalation skip for no_work crash_type
#
# Two structural assertions covering two related guards:
#
# 1. test_escalate_skips_body_gate_on_no_work (t2119 + t2387)
#    There must be a no_work-aware guard somewhere in escalate_issue_tier
#    that fires before _escalate_body_quality_gate runs. Originally this
#    was an inline `!=` guard at the body-gate call site (t2119). t2387
#    replaced it with an earlier `==` short-circuit that returns before
#    the gate is reached. Either form satisfies the invariant "no_work
#    crashes never invoke the body-gate" — so the regex accepts both.
#
# 2. test_escalate_skips_tier_cascade_on_no_work (t2387)
#    There must be an early-return for crash_type=="no_work" that fires
#    BEFORE any tier label mutation (the `gh issue edit ... --add-label`
#    line), so no_work crashes never cascade the tier. This is the
#    actual behavioural guarantee t2387 adds — the body-gate assertion
#    above is a weaker invariant that happens to follow from it.
# -----------------------------------------------------------------

test_escalate_skips_body_gate_on_no_work() {
	# Extract escalate_issue_tier function source
	local fn_src
	fn_src=$(awk '
		/^escalate_issue_tier\(\) \{/,/^}$/ { print }
	' "$LIFECYCLE_SCRIPT")

	if [[ -z "$fn_src" ]]; then
		print_result "escalate: no_work guard present (structural)" 1 \
			"could not extract escalate_issue_tier"
		return 0
	fi

	# Assertion 1: the function contains a no_work guard before the gate call.
	# Accept either the old t2119 inline `!=` form or the t2387 early-return
	# `==` form — both satisfy the invariant that no_work never invokes the
	# body-gate.
	local guard_pos gate_pos
	# shellcheck disable=SC2016  # matching literal source text, not expanding
	guard_pos=$(printf '%s\n' "$fn_src" | grep -nE '"\$crash_type" (!=|==) "no_work"' | head -1 | cut -d: -f1)
	gate_pos=$(printf '%s\n' "$fn_src" | grep -n '_escalate_body_quality_gate' | head -1 | cut -d: -f1)

	if [[ -z "$guard_pos" || -z "$gate_pos" ]]; then
		print_result "escalate: no_work guard present (structural)" 1 \
			"missing guard_pos=${guard_pos} or gate_pos=${gate_pos}"
		return 0
	fi

	# Assertion 2: the guard appears BEFORE the gate call line
	if [[ "$guard_pos" -ge "$gate_pos" ]]; then
		print_result "escalate: no_work guard present (structural)" 1 \
			"guard at line ${guard_pos} must precede gate at line ${gate_pos}"
		return 0
	fi

	print_result "escalate: no_work guard present (structural)" 0
	return 0
}

test_escalate_skips_tier_cascade_on_no_work() {
	# Extract escalate_issue_tier function source
	local fn_src
	fn_src=$(awk '
		/^escalate_issue_tier\(\) \{/,/^}$/ { print }
	' "$LIFECYCLE_SCRIPT")

	if [[ -z "$fn_src" ]]; then
		print_result "escalate: no_work tier-cascade skip (t2387)" 1 \
			"could not extract escalate_issue_tier"
		return 0
	fi

	# Assertion 1: the function contains an `== "no_work"` early-return guard.
	# This is the specific t2387 short-circuit — distinguished from the
	# original t2119 inline `!= "no_work"` guard.
	local early_return_pos
	# shellcheck disable=SC2016  # matching literal source text, not expanding
	early_return_pos=$(printf '%s\n' "$fn_src" | grep -n '"\$crash_type" == "no_work"' | head -1 | cut -d: -f1)

	if [[ -z "$early_return_pos" ]]; then
		print_result "escalate: no_work tier-cascade skip (t2387)" 1 \
			"early-return guard 'crash_type == \"no_work\"' not found"
		return 0
	fi

	# Assertion 2: the early return must precede the tier-mutation helper call.
	# Label mutation is intentionally encapsulated so the escalation orchestrator
	# remains below the function-complexity threshold.
	local tier_mutation_pos
	tier_mutation_pos=$(printf '%s\n' "$fn_src" | grep -n '_apply_tier_escalation_label' | head -1 | cut -d: -f1)

	if [[ -z "$tier_mutation_pos" ]]; then
		print_result "escalate: no_work tier-cascade skip (t2387)" 1 \
			"tier mutation helper call not found — cannot verify ordering"
		return 0
	fi

	if [[ "$early_return_pos" -ge "$tier_mutation_pos" ]]; then
		print_result "escalate: no_work tier-cascade skip (t2387)" 1 \
			"early-return at line ${early_return_pos} must precede tier mutation at line ${tier_mutation_pos}"
		return 0
	fi

	# Assertion 3: the early-return block calls _log_no_work_skip_escalation
	# (the diagnostic helper) before returning, so operators see the skip.
	local helper_call_pos
	helper_call_pos=$(printf '%s\n' "$fn_src" | grep -n '_log_no_work_skip_escalation' | head -1 | cut -d: -f1)
	if [[ -z "$helper_call_pos" ]]; then
		print_result "escalate: no_work tier-cascade skip (t2387)" 1 \
			"early-return block does not call _log_no_work_skip_escalation"
		return 0
	fi

	# The helper call must be between the early-return guard and the tier mutation
	if [[ "$helper_call_pos" -le "$early_return_pos" ]] || [[ "$helper_call_pos" -ge "$tier_mutation_pos" ]]; then
		print_result "escalate: no_work tier-cascade skip (t2387)" 1 \
			"helper call at ${helper_call_pos} not between guard ${early_return_pos} and mutation ${tier_mutation_pos}"
		return 0
	fi

	print_result "escalate: no_work tier-cascade skip (t2387)" 0
	return 0
}

test_log_no_work_skip_escalation_helper_exists() {
	# The helper _log_no_work_skip_escalation must exist as a function
	# definition in worker-lifecycle-common.sh. This guards against the
	# guard-only form being added without the accompanying helper.
	if ! grep -qE '^_log_no_work_skip_escalation\(\) \{' "$LIFECYCLE_SCRIPT"; then
		print_result "escalate: _log_no_work_skip_escalation helper defined" 1 \
			"function definition not found in $LIFECYCLE_SCRIPT"
		return 0
	fi

	# The helper must emit the <!-- no-work-escalation-skip --> marker so
	# idempotency checks and operator searches can find it.
	if ! grep -q 'no-work-escalation-skip' "$LIFECYCLE_SCRIPT"; then
		print_result "escalate: _log_no_work_skip_escalation helper defined" 1 \
			"marker 'no-work-escalation-skip' not found"
		return 0
	fi

	print_result "escalate: _log_no_work_skip_escalation helper defined" 0
	return 0
}

# -----------------------------------------------------------------
# Part B2 — t2769 no_work circuit breaker structural tests
# -----------------------------------------------------------------
# These are code-analysis assertions (no live GH calls). They verify
# that the t2769 circuit breaker wiring is correct by inspecting the
# source text of the two files it touches.

NMR_APPROVAL_SCRIPT="${NMR_APPROVAL_SCRIPT:-$(dirname "$LIFECYCLE_SCRIPT")/pulse-nmr-approval.sh}"

test_no_work_circuit_breaker_threshold_guard() {
	# _log_no_work_skip_escalation must reference NO_WORK_NMR_THRESHOLD
	# and delegate to the legacy-named structural breaker when the threshold is reached.

	# Assertion 1: NO_WORK_NMR_THRESHOLD is referenced in the function body.
	local fn_src
	fn_src=$(awk '/^_log_no_work_skip_escalation\(\) \{/,/^\}/' "$LIFECYCLE_SCRIPT" 2>/dev/null)
	if [[ -z "$fn_src" ]]; then
		print_result "t2769: no_work circuit breaker threshold guard" 1 \
			"_log_no_work_skip_escalation not found in $LIFECYCLE_SCRIPT"
		return 0
	fi

	if ! printf '%s\n' "$fn_src" | grep -q 'NO_WORK_NMR_THRESHOLD'; then
		print_result "t2769: no_work circuit breaker threshold guard" 1 \
			"NO_WORK_NMR_THRESHOLD not referenced in _log_no_work_skip_escalation"
		return 0
	fi

	# Assertion 2: the function delegates to the dedicated structural breaker helper.
	if ! printf '%s\n' "$fn_src" | grep -q '_apply_no_work_nmr_breaker'; then
		print_result "t2769: no_work circuit breaker threshold guard" 1 \
			"_apply_no_work_nmr_breaker not called in _log_no_work_skip_escalation"
		return 0
	fi

	# Assertion 3: the breaker path appears BEFORE the below-threshold diagnostic path
	# (threshold check is the first branch; diagnostic is the fallthrough).
	local nmr_line diag_line
	nmr_line=$(printf '%s\n' "$fn_src" | grep -n '_apply_no_work_nmr_breaker' | head -1 | cut -d: -f1)
	diag_line=$(printf '%s\n' "$fn_src" | grep -n 'no-work-escalation-skip' | head -1 | cut -d: -f1)
	if [[ -z "$nmr_line" || -z "$diag_line" ]]; then
		print_result "t2769: no_work circuit breaker threshold guard" 1 \
			"could not locate both NMR line (${nmr_line}) and diagnostic line (${diag_line})"
		return 0
	fi
	if [[ "$nmr_line" -ge "$diag_line" ]]; then
		print_result "t2769: no_work circuit breaker threshold guard" 1 \
			"NMR path (${nmr_line}) must appear before diagnostic path (${diag_line})"
		return 0
	fi

	print_result "t2769: no_work circuit breaker threshold guard" 0
	return 0
}

test_no_work_circuit_breaker_marker_posted() {
	# The structural breaker path must post the legacy machine marker, while the below-threshold
	# explanatory prose must not quote it and contaminate reason classification.

	local breaker_src="" skip_src=""
	breaker_src=$(awk '/^_apply_no_work_nmr_breaker\(\) \{/,/^\}/' "$LIFECYCLE_SCRIPT" 2>/dev/null)
	skip_src=$(awk '/^_log_no_work_skip_escalation\(\) \{/,/^\}/' "$LIFECYCLE_SCRIPT" 2>/dev/null)
	if [[ -z "$breaker_src" || -z "$skip_src" ]]; then
		print_result "t2769: no_work circuit breaker marker posted" 1 \
			"no_work breaker or below-threshold diagnostic function not found"
		return 0
	fi

	if ! printf '%s\n' "$breaker_src" | grep -q 'cost-circuit-breaker:no_work_loop'; then
		print_result "t2769: no_work circuit breaker marker posted" 1 \
			"marker 'cost-circuit-breaker:no_work_loop' not found in breaker function"
		return 0
	fi
	if printf '%s\n' "$skip_src" | grep -q 'cost-circuit-breaker:no_work_loop'; then
		print_result "t2769: no_work circuit breaker marker posted" 1 \
			"below-threshold diagnostic prose quotes the breaker marker"
		return 0
	fi

	print_result "t2769: no_work circuit breaker marker posted" 0
	return 0
}

test_nmr_approval_recognises_no_work_loop_marker() {
	# _nmr_application_is_circuit_breaker_trip in pulse-nmr-approval.sh must
	# include cost-circuit-breaker:no_work_loop in its regex so that
	# auto-approval preserves NMR (t2386 split semantics).

	if [[ ! -f "$NMR_APPROVAL_SCRIPT" ]]; then
		print_result "t2769: nmr-approval recognises no_work_loop marker" 1 \
			"pulse-nmr-approval.sh not found at $NMR_APPROVAL_SCRIPT"
		return 0
	fi

	local fn_src
	fn_src=$(awk '/^_nmr_application_is_circuit_breaker_trip\(\) \{/,/^\}/' "$NMR_APPROVAL_SCRIPT" 2>/dev/null)
	if [[ -z "$fn_src" ]]; then
		print_result "t2769: nmr-approval recognises no_work_loop marker" 1 \
			"_nmr_application_is_circuit_breaker_trip not found in $NMR_APPROVAL_SCRIPT"
		return 0
	fi

	if ! printf '%s\n' "$fn_src" | grep -q 'cost-circuit-breaker:no_work_loop'; then
		print_result "t2769: nmr-approval recognises no_work_loop marker" 1 \
			"marker 'cost-circuit-breaker:no_work_loop' not in recognition regex"
		return 0
	fi

	print_result "t2769: nmr-approval recognises no_work_loop marker" 0
	return 0
}

test_no_work_false_claim_comment_removed() {
	# The aspirational comment that falsely claimed cost-circuit-breaker-helper.sh
	# would apply NMR must no longer be present in worker-lifecycle-common.sh.
	# Acceptance criterion 3 from GH#20639.

	if grep -q 'cost-circuit-breaker-helper\.sh' "$LIFECYCLE_SCRIPT"; then
		print_result "t2769: false claim comment removed (AC3)" 1 \
			"'cost-circuit-breaker-helper.sh' still referenced in $LIFECYCLE_SCRIPT"
		return 0
	fi

	print_result "t2769: false claim comment removed (AC3)" 0
	return 0
}

# -----------------------------------------------------------------
# Part C — _preserve_no_activity_output tests
# -----------------------------------------------------------------

test_preserve_moves_to_diag_dir() {
	local src
	src=$(mktemp)
	printf 'synthetic worker output for test\n' >"$src"

	_preserve_no_activity_output "$src" "issue-99999" "anthropic/claude-sonnet-4-6"

	if [[ -f "$src" ]]; then
		print_result "preserve: source file removed after move" 1 \
			"source still exists at $src"
		return 0
	fi

	local diag_dir="${HOME}/.aidevops/logs/worker-no-activity"
	local found
	found=$(find "$diag_dir" -type f -name "*issue-99999*" 2>/dev/null | head -1)
	if [[ -z "$found" ]]; then
		print_result "preserve: source file removed after move" 1 \
			"no preserved file found in $diag_dir"
		return 0
	fi

	if ! grep -q "synthetic worker output for test" "$found"; then
		print_result "preserve: source file removed after move" 1 \
			"preserved file missing expected content"
		return 0
	fi

	print_result "preserve: source file removed after move" 0
	return 0
}

test_preserve_size_caps_at_256kb() {
	local src
	src=$(mktemp)
	# Generate 300KB of content — force truncation.
	# Avoid `yes | head` because SIGPIPE trips set -e. Use dd with bs=300 count=1024.
	dd if=/dev/zero of="$src" bs=300 count=1024 2>/dev/null || true

	_preserve_no_activity_output "$src" "issue-11111" "model-large"

	local diag_dir="${HOME}/.aidevops/logs/worker-no-activity"
	local found
	found=$(find "$diag_dir" -type f -name "*issue-11111*" 2>/dev/null | head -1)

	if [[ -z "$found" ]]; then
		print_result "preserve: size cap at 256KB with truncation marker" 1 \
			"no preserved file found"
		return 0
	fi

	local sz
	sz=$(wc -c <"$found" | tr -d ' ')
	# 256KB content + truncation marker ~ 262144 + ~80 bytes
	if [[ "$sz" -lt 262144 || "$sz" -gt 262300 ]]; then
		print_result "preserve: size cap at 256KB with truncation marker" 1 \
			"size ${sz} out of expected range (262144-262300)"
		return 0
	fi

	if ! grep -q "t2119 TRUNCATED" "$found"; then
		print_result "preserve: size cap at 256KB with truncation marker" 1 \
			"truncation marker missing from capped file"
		return 0
	fi

	print_result "preserve: size cap at 256KB with truncation marker" 0
	return 0
}

test_preserve_retention_cap() {
	local diag_dir="${HOME}/.aidevops/logs/worker-no-activity"
	# Pre-populate with 55 old files
	local i
	for i in $(seq 1 55); do
		printf '%s\n' "old content $i" >"${diag_dir}/20200101T00000${i}Z-old-${i}-old.log"
		# Stagger mtimes so ls -t ordering is deterministic
		touch -d "2020-01-01 00:00:$(printf '%02d' $((i % 60)))" \
			"${diag_dir}/20200101T00000${i}Z-old-${i}-old.log" 2>/dev/null || true
	done

	# Add one more new file → total 56, retention cap 50 → 6 should be pruned
	local src
	src=$(mktemp)
	printf 'newest\n' >"$src"
	_preserve_no_activity_output "$src" "issue-retention" "test"

	local remaining
	remaining=$(find "$diag_dir" -type f -name "*.log" 2>/dev/null | wc -l | tr -d ' ')

	# We asked to keep 50. Allow a small slack because ls ordering by
	# identical-second mtimes is non-deterministic on some filesystems.
	if [[ "$remaining" -gt 52 ]]; then
		print_result "preserve: retention cap prunes old files" 1 \
			"expected ~50 files, found ${remaining}"
		return 0
	fi
	if [[ "$remaining" -lt 48 ]]; then
		print_result "preserve: retention cap prunes old files" 1 \
			"pruned too aggressively, found ${remaining}"
		return 0
	fi

	print_result "preserve: retention cap prunes old files" 0
	return 0
}

test_preserve_noops_on_missing_output_file() {
	# Non-existent path must not error
	_preserve_no_activity_output "/nonexistent/path/that/does/not/exist" \
		"issue-nofile" "test" || {
		print_result "preserve: no-ops on missing output file" 1 \
			"function returned non-zero"
		return 0
	}
	print_result "preserve: no-ops on missing output file" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	_install_log_stubs

	if ! define_drift_helper; then
		printf 'FATAL: drift helper extraction failed\n' >&2
		return 1
	fi

	if ! define_preserve_helper; then
		printf 'FATAL: preserve helper extraction failed\n' >&2
		return 1
	fi

	# Part A: drift tests
	test_drift_bootstrap_triggers_setup
	test_drift_match_skips_setup
	test_drift_mismatch_triggers_setup
	test_drift_rate_limit_suppresses_check
	test_drift_stores_stamp_after_run

	# Part B: structural assertions for no_work escalation skipping
	test_escalate_skips_body_gate_on_no_work
	test_escalate_skips_tier_cascade_on_no_work
	test_log_no_work_skip_escalation_helper_exists

	# Part B2: t2769 no_work circuit breaker structural assertions
	test_no_work_circuit_breaker_threshold_guard
	test_no_work_circuit_breaker_marker_posted
	test_nmr_approval_recognises_no_work_loop_marker
	test_no_work_false_claim_comment_removed

	# Part C: preserve tests — clean out any pollution from Part A first
	rm -rf "${HOME}/.aidevops/logs/worker-no-activity" 2>/dev/null || true
	mkdir -p "${HOME}/.aidevops/logs/worker-no-activity" 2>/dev/null || true
	test_preserve_moves_to_diag_dir
	test_preserve_size_caps_at_256kb
	# Clean again before retention test so we control the file count
	rm -rf "${HOME}/.aidevops/logs/worker-no-activity" 2>/dev/null || true
	mkdir -p "${HOME}/.aidevops/logs/worker-no-activity" 2>/dev/null || true
	test_preserve_retention_cap
	test_preserve_noops_on_missing_output_file

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
