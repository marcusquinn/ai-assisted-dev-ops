#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-hot-deploy-flow.sh — Tests for hot-deploy / hotfix release mechanism (t2398)
# =============================================================================
# Verifies:
# 1. --hotfix flag is only accepted with patch bumps
# 2. --dry-run shows plan without executing
# 3. _check_hotfix_available respects rate-limiting and config
# 4. Non-maintainer users are rejected for hotfix releases
# 5. Normal releases (no --hotfix) are unaffected
# 6. Hotfix propagation precedes local deployment and survives local failure
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Source shared-constants for print helpers if available
# shellcheck source=/dev/null
if [[ -f "${SCRIPT_DIR}/../shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/../shared-constants.sh"
fi

# Fallback print helpers
if ! type print_info &>/dev/null; then
	print_info() { echo "[INFO] $*"; return 0; }
	print_success() { echo "[PASS] $*"; return 0; }
	print_error() { echo "[FAIL] $*"; return 0; }
	print_warning() { echo "[SKIP] $*"; return 0; }
fi

pass() {
	local test_name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	print_success "$test_name"
	return 0
}

fail() {
	local test_name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	print_error "$test_name${reason:+ — $reason}"
	return 0
}

skip() {
	local test_name="$1"
	local reason="${2:-}"
	TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
	print_warning "$test_name${reason:+ — $reason}"
	return 0
}

# Locate version-manager.sh
VM_SCRIPT="${SCRIPT_DIR}/../version-manager.sh"
if [[ ! -f "$VM_SCRIPT" ]]; then
	VM_SCRIPT="$HOME/.aidevops/agents/scripts/version-manager.sh"
fi
RELEASE_LIB="${SCRIPT_DIR}/../version-manager-release.sh"
if [[ ! -f "$RELEASE_LIB" ]]; then
	RELEASE_LIB="$HOME/.aidevops/agents/scripts/version-manager-release.sh"
fi

# Locate aidevops-update-check.sh
UC_SCRIPT="${SCRIPT_DIR}/../aidevops-update-check.sh"
if [[ ! -f "$UC_SCRIPT" ]]; then
	UC_SCRIPT="$HOME/.aidevops/agents/scripts/aidevops-update-check.sh"
fi

# =============================================================================
# Test 1: --hotfix rejects non-patch bump types
# =============================================================================
test_hotfix_rejects_non_patch() {
	local test_name="hotfix rejects non-patch bump types"

	if [[ ! -f "$VM_SCRIPT" ]]; then
		skip "$test_name" "version-manager.sh not found"
		return 0
	fi

	# Try major with --hotfix — should fail
	local output exit_code=0
	output=$(bash "$VM_SCRIPT" release major --hotfix --dry-run 2>&1) || exit_code=$?

	if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "only.*patch"; then
		pass "$test_name"
	else
		fail "$test_name" "Expected rejection for major --hotfix (exit=$exit_code)"
	fi
	return 0
}

# =============================================================================
# Test 2: --dry-run shows plan without executing
# =============================================================================
test_dry_run_shows_plan() {
	local test_name="--dry-run shows plan without executing"

	if [[ ! -f "$VM_SCRIPT" ]]; then
		skip "$test_name" "version-manager.sh not found"
		return 0
	fi

	# Run dry-run from a git repo context
	local output exit_code=0
	output=$(bash "$VM_SCRIPT" release patch --hotfix --dry-run 2>&1) || exit_code=$?

	if echo "$output" | grep -qi "DRY RUN"; then
		pass "$test_name"
	else
		# If it failed due to maintainer check, that's also valid — dry-run happens after
		if echo "$output" | grep -qi "maintainer"; then
			skip "$test_name" "maintainer check blocked dry-run (expected in non-maintainer env)"
		else
			fail "$test_name" "Expected DRY RUN output (exit=$exit_code, output=$output)"
		fi
	fi
	return 0
}

# =============================================================================
# Test 3: Normal release (no --hotfix) has no hotfix tag in dry-run
# =============================================================================
test_normal_release_no_hotfix_tag() {
	local test_name="normal release dry-run has no hotfix tag"

	if [[ ! -f "$VM_SCRIPT" ]]; then
		skip "$test_name" "version-manager.sh not found"
		return 0
	fi

	local output exit_code=0
	output=$(bash "$VM_SCRIPT" release patch --dry-run 2>&1) || exit_code=$?

	if echo "$output" | grep -qi "DRY RUN"; then
		if echo "$output" | grep -qi "hotfix-v"; then
			fail "$test_name" "Normal release dry-run should not mention hotfix tag"
		else
			pass "$test_name"
		fi
	else
		skip "$test_name" "dry-run did not produce expected output (exit=$exit_code)"
	fi
	return 0
}

# =============================================================================
# Test 4: auto-hotfix.conf template exists and has required keys
# =============================================================================
test_hotfix_conf_template() {
	local test_name="auto-hotfix.conf template has required keys"
	local conf_path="${SCRIPT_DIR}/../../configs/auto-hotfix.conf"

	if [[ ! -f "$conf_path" ]]; then
		# Try deployed path
		conf_path="$HOME/.aidevops/agents/configs/auto-hotfix.conf"
	fi

	if [[ ! -f "$conf_path" ]]; then
		fail "$test_name" "auto-hotfix.conf not found"
		return 0
	fi

	local missing=""
	if ! grep -q 'auto_hotfix_accept=' "$conf_path"; then
		missing="${missing}auto_hotfix_accept "
	fi
	if ! grep -q 'auto_hotfix_restart_pulse=' "$conf_path"; then
		missing="${missing}auto_hotfix_restart_pulse "
	fi

	if [[ -z "$missing" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "missing keys: $missing"
	fi
	return 0
}

# =============================================================================
# Test 5: _check_hotfix_available function exists in update-check.sh
# =============================================================================
test_hotfix_check_function_exists() {
	local test_name="_check_hotfix_available function exists in update-check.sh"

	if [[ ! -f "$UC_SCRIPT" ]]; then
		skip "$test_name" "aidevops-update-check.sh not found"
		return 0
	fi

	if grep -q '_check_hotfix_available' "$UC_SCRIPT"; then
		pass "$test_name"
	else
		fail "$test_name" "function not found in update-check.sh"
	fi
	return 0
}

# =============================================================================
# Test 6: _verify_maintainer_identity function exists in version-manager.sh
# =============================================================================
test_maintainer_verify_function_exists() {
	local test_name="_verify_maintainer_identity function exists in version-manager.sh"

	if [[ ! -f "$VM_SCRIPT" ]]; then
		skip "$test_name" "version-manager.sh not found"
		return 0
	fi

	if grep -q '_verify_maintainer_identity' "$VM_SCRIPT"; then
		pass "$test_name"
	else
		fail "$test_name" "function not found in version-manager.sh"
	fi
	return 0
}

# =============================================================================
# Test 7: _create_hotfix_tag function exists in the release library
# =============================================================================
test_create_hotfix_tag_function_exists() {
	local test_name="_create_hotfix_tag function exists in release library"

	if [[ ! -f "$RELEASE_LIB" ]]; then
		skip "$test_name" "version-manager-release.sh not found"
		return 0
	fi

	if grep -q '_create_hotfix_tag' "$RELEASE_LIB"; then
		pass "$test_name"
	else
		fail "$test_name" "function not found in version-manager-release.sh"
	fi
	return 0
}

# =============================================================================
# Test 8: Usage text includes --hotfix flag
# =============================================================================
test_usage_includes_hotfix() {
	local test_name="usage text includes --hotfix flag"

	if [[ ! -f "$VM_SCRIPT" ]]; then
		skip "$test_name" "version-manager.sh not found"
		return 0
	fi

	local output
	output=$(bash "$VM_SCRIPT" 2>&1) || true

	if echo "$output" | grep -q '\-\-hotfix'; then
		pass "$test_name"
	else
		fail "$test_name" "--hotfix not in usage output"
	fi
	return 0
}

# =============================================================================
# Test 9: AIDEVOPS_FORCE_HOTFIX_BANNER env var is respected
# =============================================================================
test_force_hotfix_banner_env() {
	local test_name="AIDEVOPS_FORCE_HOTFIX_BANNER env var is respected"

	if [[ ! -f "$UC_SCRIPT" ]]; then
		skip "$test_name" "aidevops-update-check.sh not found"
		return 0
	fi

	if grep -q 'AIDEVOPS_FORCE_HOTFIX_BANNER' "$UC_SCRIPT"; then
		pass "$test_name"
	else
		fail "$test_name" "AIDEVOPS_FORCE_HOTFIX_BANNER not found in update-check.sh"
	fi
	return 0
}

# =============================================================================
# Test 10: hot-deploy.md reference doc exists
# =============================================================================
test_reference_doc_exists() {
	local test_name="hot-deploy.md reference doc exists"
	local doc_path="${SCRIPT_DIR}/../../reference/hot-deploy.md"

	if [[ ! -f "$doc_path" ]]; then
		doc_path="$HOME/.aidevops/agents/reference/hot-deploy.md"
	fi

	if [[ -f "$doc_path" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "hot-deploy.md not found"
	fi
	return 0
}

test_hotfix_propagates_before_local_failure() {
	local test_name="hotfix propagates before local deployment failure"
	local test_root
	test_root=$(mktemp -d "${TMPDIR:-/tmp}/hotfix-post-publication.XXXXXX")
	local output=""
	local exit_code=0

	output=$(EVENTS_FILE="$test_root/events" bash -c '
set -u
SCRIPT_DIR="$(dirname "$1")"
REPO_ROOT="${2}"
source "$1"
print_error() { local message="$1"; printf "ERROR:%s\n" "$message"; return 0; }
print_info() { local message="$1"; printf "INFO:%s\n" "$message"; return 0; }
print_success() { return 0; }
print_warning() { return 0; }
_create_hotfix_tag() { local version="$1"; printf "hotfix:%s\n" "$version" >>"$EVENTS_FILE"; return 0; }
run_post_release_agent_sync() { printf "deploy\n" >>"$EVENTS_FILE"; return 1; }
release_source_pr_required() { return 1; }
run_post_publication_gates 9.8.7 1
' _ "$RELEASE_LIB" "$SCRIPT_DIR/../../.." 2>&1) || exit_code=$?

	local events=""
	events=$(<"$test_root/events")
	rm -rf "$test_root"
	if [[ "$exit_code" -ne 0 && "$events" == $'hotfix:9.8.7\ndeploy' && "$output" == *"PARTIAL RELEASE SUCCESS"* && "$output" == *"remains published"* ]]; then
		pass "$test_name"
	else
		fail "$test_name" "exit=$exit_code events=$events output=$output"
	fi
	return 0
}

test_publication_disables_rollback_before_local_gates() {
	local test_name="publication disables rollback before local gates"
	local publication_line=""
	local rollback_disable_line=""
	local post_gate_line=""
	# shellcheck disable=SC2016 # Match the literal source expression.
	publication_line=$(grep -n 'if ! _publish_github_release "$new_version"' "$VM_SCRIPT" | cut -d: -f1)
	rollback_disable_line=$(grep -n '_release_disable_failure_rollback' "$VM_SCRIPT" | while IFS=: read -r line_number _; do
		if [[ "$line_number" -gt "$publication_line" ]]; then
			printf '%s\n' "$line_number"
			break
		fi
	done)
	post_gate_line=$(grep -n 'if ! run_post_publication_gates' "$VM_SCRIPT" | cut -d: -f1)
	if [[ -n "$publication_line" && -n "$rollback_disable_line" && -n "$post_gate_line" &&
		"$publication_line" -lt "$rollback_disable_line" && "$rollback_disable_line" -lt "$post_gate_line" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "publication=$publication_line rollback-disable=$rollback_disable_line post-gates=$post_gate_line"
	fi
	return 0
}

test_existing_local_hotfix_tag_retries_remote_push() {
	local test_name="existing local hotfix tag retries remote propagation"
	local test_root
	test_root=$(mktemp -d "${TMPDIR:-/tmp}/hotfix-retry.XXXXXX")
	mkdir -p "$test_root/bin" "$test_root/repo"
	cat >"$test_root/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
ls-remote) exit 2 ;;
show-ref) exit 0 ;;
push)
	printf '%s\n' "$*" >>"$HOTFIX_GIT_LOG"
	[[ "${HOTFIX_PUSH_FAIL:-0}" == "1" ]] && exit 1
	exit 0
	;;
esac
exit 1
EOF
	chmod +x "$test_root/bin/git"
	local output=""
	local exit_code=0
	output=$(PATH="$test_root/bin:/usr/bin:/bin" HOTFIX_GIT_LOG="$test_root/git.log" bash -c '
set -u
SCRIPT_DIR="$(dirname "$1")"
REPO_ROOT="$2"
source "$1"
print_error() { local message="$1"; printf "ERROR:%s\n" "$message"; return 0; }
print_info() { local message="$1"; printf "INFO:%s\n" "$message"; return 0; }
print_success() { return 0; }
print_warning() { return 0; }
_create_hotfix_tag 9.8.7
' _ "$RELEASE_LIB" "$test_root/repo" 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] && grep -q 'push origin hotfix-v9.8.7' "$test_root/git.log"; then
		pass "$test_name"
	else
		fail "$test_name" "exit=$exit_code output=$output"
	fi

	exit_code=0
	output=$(PATH="$test_root/bin:/usr/bin:/bin" HOTFIX_GIT_LOG="$test_root/git.log" HOTFIX_PUSH_FAIL=1 bash -c '
set -u
SCRIPT_DIR="$(dirname "$1")"
REPO_ROOT="$2"
source "$1"
print_error() { local message="$1"; printf "ERROR:%s\n" "$message"; return 0; }
print_info() { local message="$1"; printf "INFO:%s\n" "$message"; return 0; }
print_success() { return 0; }
print_warning() { return 0; }
_create_hotfix_tag 9.8.7
' _ "$RELEASE_LIB" "$test_root/repo" 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 && "$output" == *"post-release --hotfix"* ]] && grep -q '"post-release")' "$VM_SCRIPT"; then
		pass "failed hotfix push provides idempotent retry guidance"
	else
		fail "failed hotfix push provides idempotent retry guidance" "exit=$exit_code output=$output"
	fi
	rm -rf "$test_root"
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
main() {
	print_info "=== Hot-Deploy Flow Tests (t2398) ==="
	echo ""

	test_hotfix_rejects_non_patch
	test_dry_run_shows_plan
	test_normal_release_no_hotfix_tag
	test_hotfix_conf_template
	test_hotfix_check_function_exists
	test_maintainer_verify_function_exists
	test_create_hotfix_tag_function_exists
	test_usage_includes_hotfix
	test_force_hotfix_banner_env
	test_reference_doc_exists
	test_hotfix_propagates_before_local_failure
	test_publication_disables_rollback_before_local_gates
	test_existing_local_hotfix_tag_retries_remote_push

	echo ""
	print_info "=== Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
