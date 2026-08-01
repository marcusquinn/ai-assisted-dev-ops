#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
SANDBOX_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
NETWORK_HELPER="${SCRIPT_DIR}/network-tier-helper.sh"
HEADLESS_HELPER="${SCRIPT_DIR}/headless-runtime-helper.sh"
HEADLESS_INVOKE="${SCRIPT_DIR}/headless-runtime-invoke.sh"
HEADLESS_WORKER="${SCRIPT_DIR}/headless-runtime-worker.sh"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="${TEST_ROOT}/home"
BACKEND="${TEST_ROOT}/egress-backend"
TARGET="${TEST_ROOT}/adversary"
MARKER="${TEST_ROOT}/target-ran"
CHILD_MARKER="${TEST_ROOT}/child-ran"
INTERPRETER_MARKER="${TEST_ROOT}/interpreter-ran"
BACKEND_LOG="${TEST_ROOT}/backend-argv"
POLICY_LOG="${TEST_ROOT}/backend-policy.json"
CUSTOM_POLICY="${TEST_ROOT}/network-tiers-custom.conf"
TESTS=0
FAILURES=0
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_HOME"

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

write_fixtures() {
	cat >"$TARGET" <<EOF
#!/usr/bin/env bash
printf 'target' >"$MARKER"
(printf 'child' >"$CHILD_MARKER") &
wait
exit 0
EOF
	chmod +x "$TARGET"

	cat >"$BACKEND" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

case "${1:-}" in
probe)
	if [[ "${FAKE_BACKEND_MODE:-ready}" == "invalid" ]]; then
		printf '{"ready":true}'
		exit 0
	fi
	policy_file="${3:?}"
	if [[ -n "${FAKE_POLICY_LOG:-}" ]]; then
		cp "$policy_file" "$FAKE_POLICY_LOG"
	fi
	policy_sha256="$(python3 - "$policy_file" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
)"
	printf '{"schema":"aidevops.worker-egress-backend.v1","ready":true,"scope":"process-tree","enforcement":"kernel","policy_sha256":"%s","backend_id":"fixture-backend","capabilities":["direct-socket-deny","hostname-policy","private-network-deny"],"cleanup":"automatic"}' "$policy_sha256"
	exit 0
	;;
run)
	shift
	while [[ $# -gt 0 && "$1" != "--" ]]; do
		shift
	done
	[[ "${1:-}" == "--" ]] && shift
	printf '%s\n' "$@" >"${FAKE_BACKEND_LOG:?}"
	if [[ "${FAKE_BACKEND_MODE:-ready}" == "deny" ]]; then
		exit 77
	fi
	exec "$@"
	;;
*)
	exit 64
	;;
esac
EOF
	chmod +x "$BACKEND"
	return 0
}

test_policy_export_is_normalized() {
	local output=""
	output="$(HOME="$TEST_HOME" "$NETWORK_HELPER" export-policy)" || {
		fail "exports normalized backend policy" "export failed"
		return 0
	}
	if printf '%s' "$output" | jq -e \
		'.schema == "aidevops.worker-egress-policy.v1" and .raw_ip_action == "deny" and .private_network_action == "deny" and .loopback_action == "deny" and ([.rules[] | select(.tier == 5)] | length > 0) and ([.rules[] | select(.match == "exact" and .pattern == "github.com" and .action == "allow")] | length == 1) and ([.rules[] | select(.pattern == "api.openai.com" and (.action | startswith("allow")))] | length == 1)' \
		>/dev/null 2>&1; then
		pass "exports normalized backend policy"
	else
		fail "exports normalized backend policy" "invalid contract"
	fi
	return 0
}

test_policy_export_applies_user_override() {
	cat >"$CUSTOM_POLICY" <<'EOF'
[tier5]
github.com
EOF
	local output=""
	output="$(HOME="$TEST_HOME" AIDEVOPS_NETWORK_TIER_USER_POLICY="$CUSTOM_POLICY" "$NETWORK_HELPER" export-policy)" || {
		fail "normalized policy applies user overrides" "export failed"
		return 0
	}
	if printf '%s' "$output" | jq -e \
		'[.rules[] | select(.match == "exact" and .pattern == "github.com" and .tier == 5 and .action == "deny")] | length == 1' \
		>/dev/null 2>&1; then
		pass "normalized policy applies user overrides"
	else
		fail "normalized policy applies user overrides" "override missing"
	fi
	return 0
}

test_provider_policy_export_is_deny_by_default() {
	local output=""
	output="$(HOME="$TEST_HOME" "$NETWORK_HELPER" export-provider-policy openai)" || {
		fail "exports provider-only deny-by-default policy" "export failed"
		return 0
	}
	if printf '%s' "$output" | jq -e \
		'.schema == "aidevops.worker-egress-policy.v1" and .default_tier == 5 and .default_action == "deny" and .raw_ip_action == "deny" and .private_network_action == "deny" and .loopback_action == "deny" and (.rules | length == 1) and .rules[0].match == "exact" and .rules[0].pattern == "api.openai.com" and (.rules[0].action | startswith("allow")) and ([.rules[] | select(.pattern == "github.com")] | length == 0)' \
		>/dev/null 2>&1; then
		pass "exports provider-only deny-by-default policy"
	else
		fail "exports provider-only deny-by-default policy" "invalid contract"
	fi
	return 0
}

test_provider_policy_rejects_non_https_provider() {
	local status=0
	HOME="$TEST_HOME" "$NETWORK_HELPER" export-provider-policy local \
		>/dev/null 2>&1 || status=$?
	if [[ "$status" -ne 0 ]]; then
		pass "provider-only policy rejects local non-HTTPS endpoint"
	else
		fail "provider-only policy rejects local non-HTTPS endpoint" "export unexpectedly succeeded"
	fi
	return 0
}

test_required_mode_fails_closed_without_backend() {
	rm -f "$MARKER" "$CHILD_MARKER"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="" \
		"$SANDBOX_HELPER" run --egress-mode required -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" && ! -e "$CHILD_MARKER" ]]; then
		pass "required mode fails closed without backend"
	else
		fail "required mode fails closed without backend" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi
	return 0
}

test_required_mode_rejects_invalid_probe() {
	rm -f "$MARKER" "$CHILD_MARKER"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=invalid FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "required mode rejects invalid backend readiness"
	else
		fail "required mode rejects invalid backend readiness" "status=${status}"
	fi
	return 0
}

test_backend_wraps_process_tree() {
	rm -f "$MARKER" "$CHILD_MARKER" "$BACKEND_LOG"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=ready FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required --worker-id fixture-worker -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" && -e "$CHILD_MARKER" && -s "$BACKEND_LOG" ]] && \
		grep -F "$TARGET" "$BACKEND_LOG" >/dev/null 2>&1; then
		pass "verified backend wraps command and descendants"
	else
		fail "verified backend wraps command and descendants" "status=${status}"
	fi
	return 0
}

test_backend_denial_blocks_arbitrary_binary() {
	rm -f "$MARKER" "$CHILD_MARKER" "$BACKEND_LOG"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=deny FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required --worker-id fixture-worker -- "$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 77 && ! -e "$MARKER" && ! -e "$CHILD_MARKER" ]]; then
		pass "backend denial blocks arbitrary binary and descendants"
	else
		fail "backend denial blocks arbitrary binary and descendants" "status=${status}"
	fi
	return 0
}

test_backend_denial_blocks_interpreter() {
	rm -f "$INTERPRETER_MARKER" "$BACKEND_LOG"
	local status=0
	HOME="$TEST_HOME" INTERPRETER_MARKER="$INTERPRETER_MARKER" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=deny FAKE_BACKEND_LOG="$BACKEND_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required --worker-id fixture-worker --passthrough INTERPRETER_MARKER -- \
		python3 -c 'from pathlib import Path; import os; Path(os.environ["INTERPRETER_MARKER"]).write_text("ran")' \
		>/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 77 && ! -e "$INTERPRETER_MARKER" ]]; then
		pass "backend denial blocks arbitrary interpreter execution"
	else
		fail "backend denial blocks arbitrary interpreter execution" "status=${status}"
	fi
	return 0
}

test_provider_profile_binds_restricted_policy() {
	rm -f "$MARKER" "$CHILD_MARKER" "$BACKEND_LOG" "$POLICY_LOG"
	local status=0
	HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="$BACKEND" \
		FAKE_BACKEND_MODE=ready FAKE_BACKEND_LOG="$BACKEND_LOG" \
		FAKE_POLICY_LOG="$POLICY_LOG" \
		"$SANDBOX_HELPER" run --egress-mode required \
		--egress-policy-profile provider:openai --worker-id triage-fixture -- \
		"$TARGET" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 0 && -s "$POLICY_LOG" ]] && jq -e \
		'.default_action == "deny" and (.rules | length == 1) and .rules[0].pattern == "api.openai.com" and ([.rules[] | select(.pattern == "github.com")] | length == 0)' \
		"$POLICY_LOG" >/dev/null 2>&1; then
		pass "provider profile binds restricted policy to backend"
	else
		fail "provider profile binds restricted policy to backend" "status=${status} policy_present=$([[ -s "$POLICY_LOG" ]] && printf yes || printf no)"
	fi
	return 0
}

test_auto_mode_reports_non_containment() {
	rm -f "$MARKER" "$CHILD_MARKER"
	local output=""
	local status=0
	output="$(HOME="$TEST_HOME" AIDEVOPS_WORKER_EGRESS_BACKEND="" \
		"$SANDBOX_HELPER" run --egress-mode auto -- "$TARGET" 2>&1)" || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" && "$output" == *"state=command-policy-only"* && "$output" == *"egress=command-policy-only"* ]]; then
		pass "auto mode reports command-policy-only state"
	else
		fail "auto mode reports command-policy-only state" "status=${status} output=${output}"
	fi
	return 0
}

test_headless_runtime_binds_egress_contract() {
	local opencode_egress_count=0
	local claude_egress_count=0
	local required_guard_count=0
	local opencode_profile_count=0
	local triage_mode_policy_count=0
	local opencode_sandbox_policy_count=0
	# Literal source patterns intentionally retain the runtime variable names.
	# The OpenCode path is consolidated in the extracted invoke module, while
	# shared policy definitions remain in the identity-bearing helper.
	# shellcheck disable=SC2016
	opencode_egress_count="$(grep -cF -- '--egress-mode "$egress_mode" --egress-policy-profile "$egress_policy_profile" --worker-id "$egress_worker_id"' "$HEADLESS_INVOKE")"
	# shellcheck disable=SC2016
	claude_egress_count="$(grep -cF -- '--egress-mode "$egress_mode" --worker-id "$egress_worker_id"' "$HEADLESS_WORKER")"
	# shellcheck disable=SC2016
	required_guard_count="$(grep -h -cF -- '[[ "$egress_mode" == "required" ]]' "$HEADLESS_HELPER" "$HEADLESS_INVOKE" "$HEADLESS_WORKER" | awk '{ total += $1 } END { print total + 0 }')"
	# shellcheck disable=SC2016
	opencode_profile_count="$(grep -cF -- 'egress_policy_profile="provider:${_invoke_provider}"' "$HEADLESS_INVOKE")"
	triage_mode_policy_count="$(grep -h -cF -- '_resolve_public_triage_egress_mode' "$HEADLESS_HELPER" "$HEADLESS_INVOKE" | awk '{ total += $1 } END { print total + 0 }')"
	opencode_sandbox_policy_count="$(grep -h -cF -- '_headless_opencode_sandbox_required' "$HEADLESS_HELPER" "$HEADLESS_INVOKE" | awk '{ total += $1 } END { print total + 0 }')"
	if [[ "$opencode_egress_count" -eq 1 && "$claude_egress_count" -eq 4 && \
		"$required_guard_count" -eq 1 && "$opencode_profile_count" -eq 1 && \
		"$triage_mode_policy_count" -eq 2 && "$opencode_sandbox_policy_count" -eq 2 ]]; then
		pass "all headless runtimes bind egress and guard required mode"
	else
		fail "all headless runtimes bind egress and guard required mode" "opencode=${opencode_egress_count} claude=${claude_egress_count} guards=${required_guard_count} triage_profiles=${opencode_profile_count} triage_policy=${triage_mode_policy_count} sandbox_policy=${opencode_sandbox_policy_count}"
	fi
	return 0
}

main() {
	write_fixtures
	test_policy_export_is_normalized
	test_policy_export_applies_user_override
	test_provider_policy_export_is_deny_by_default
	test_provider_policy_rejects_non_https_provider
	test_required_mode_fails_closed_without_backend
	test_required_mode_rejects_invalid_probe
	test_backend_wraps_process_tree
	test_backend_denial_blocks_arbitrary_binary
	test_backend_denial_blocks_interpreter
	test_provider_profile_binds_restricted_policy
	test_auto_mode_reports_non_containment
	test_headless_runtime_binds_egress_contract
	printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
	[[ "$FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
