#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-override-flags.sh — Regression tests for bypass flag audit (GH#20146)
#
# Verifies that operator-facing bypass flags:
#   1. Emit an info_log/warn_log at the bypass site (audit trail)
#   2. Actually bypass the intended check (flag is not silently ignored)
#   3. Have a minimum floor that still applies even when bypassed
#
# Flags covered by this test file (flags with existing coverage are noted):
#
#   FORCE_PUSH          — bulk issue push bypasses CI-only gate (issue-sync-helper.sh)
#   FORCE_CLOSE         — issue close bypasses evidence check (issue-sync-helper.sh)
#   AIDEVOPS_VM_SKIP_BUMP_VERIFY — tag bypass skips bump-commit verify (version-manager-release.sh)
#   AIDEVOPS_HEADLESS_SANDBOX_DISABLED — sandbox bypass falls back to bare exec (headless runtime modules)
#   SKIP_FRAMEWORK_ROUTING_CHECK — routing warning bypass (claim-task-id.sh)
#   FORCE_ENRICH        — enrich bypass skips content-preservation gate (issue-sync-helper.sh)
#                         (deep coverage in test-enrich-no-data-loss.sh; log audit only here)
#
# Flags with dedicated coverage elsewhere (not duplicated here):
#   TASK_ID_GUARD_DISABLE       — test-task-id-collision-guard.sh
#   PRIVACY_GUARD_DISABLE       — test-privacy-guard.sh (install-pre-push-guards.sh path)
#   COMPLEXITY_GUARD_DISABLE    — test-complexity-guard-parallel.sh
#   AIDEVOPS_SKIP_TIER_VALIDATOR — test-tier-simple-body-shape.sh
#   AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY — test-pre-dispatch-eligibility.sh
#   AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR   — test-pre-dispatch-validator.sh
#   AIDEVOPS_SKIP_AUTO_CLAIM    — test-worktree-auto-claim.sh (Test 7)
#   AIDEVOPS_BASH_REEXECED      — test-bash-reexec-guard.sh
#   AIDEVOPS_SCAN_STALE_AUTO_RELEASE — test-scan-stale-auto-release.sh
#
# Strategy:
#   - Source each helper with stubbed gh and logging.
#   - Set bypass flag, invoke the function, assert log message fires.
#   - Without bypass flag, assert the gate fires normally.
#   - Test floors: verify the floor invariant holds even when bypassed.

set -u
set +e

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

section() {
	local title="$1"
	printf '\n%s%s%s\n' "$TEST_BLUE" "$title" "$TEST_NC"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"
VERSION_MGMT_RELEASE="${SCRIPTS_DIR}/version-manager-release.sh"
CLAIM_HELPER="${SCRIPTS_DIR}/claim-task-id.sh"
HEADLESS_INVOKE="${SCRIPTS_DIR}/headless-runtime-invoke.sh"
HEADLESS_WORKER="${SCRIPTS_DIR}/headless-runtime-worker.sh"
WORKTREE_HELPER="${SCRIPTS_DIR}/worktree-helper.sh"

for f in "$HELPER" "$CLAIM_HELPER"; do
	if [[ ! -f "$f" ]]; then
		printf 'test harness cannot find %s\n' "$f" >&2
		exit 1
	fi
done

TMP=$(mktemp -d -t test-override-flags.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ============================================================
# Shared stub infrastructure
# ============================================================

# Log file for captured print_info/print_warning messages during tests.
INFO_LOG="${TMP}/info.log"
: >"$INFO_LOG"

# Install stub gh that always succeeds (tests don't need real GitHub API).
GH_STUB_BIN="${TMP}/bin/gh"
mkdir -p "${TMP}/bin"
cat >"$GH_STUB_BIN" <<'STUB'
#!/usr/bin/env bash
# Stub gh — records calls, simulates typical responses.
GH_CALLS_LOG="${GH_STUB_CALLS:-/dev/null}"
printf 'gh %s\n' "$*" >>"$GH_CALLS_LOG"

case "${1:-}" in
issue)
	case "${2:-}" in
	view) echo '{"body":"existing body content","title":"t9999: existing title","number":9999}'; exit 0 ;;
	edit) exit 0 ;;
	close) exit 0 ;;
	list) echo '[]'; exit 0 ;;
	esac ;;
pr)
	case "${2:-}" in
	list) echo '[]'; exit 0 ;;
	view) echo '{"state":"MERGED","number":1}'; exit 0 ;;
	esac ;;
api) echo '{"login":"testuser"}'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$GH_STUB_BIN"
export PATH="${TMP}/bin:$PATH"

# Stub logging helpers to capture output to INFO_LOG.
print_info() {
	printf '[INFO] %s\n' "$*" >>"$INFO_LOG"
	return 0
}
print_warning() {
	printf '[WARNING] %s\n' "$*" >>"$INFO_LOG"
	return 0
}
print_error() {
	printf '[ERROR] %s\n' "$*" >>"$INFO_LOG"
	return 0
}
print_success() { :; return 0; }
export -f print_info print_warning print_error print_success

reset_log() {
	: >"$INFO_LOG"
	return 0
}

log_contains() {
	local pattern="$1"
	grep -qF "$pattern" "$INFO_LOG" 2>/dev/null
	return $?
}

# ============================================================
# Section 1: FORCE_ENRICH bypass log (issue-sync-helper.sh)
# ============================================================
section "1. FORCE_ENRICH bypass log (issue-sync-helper.sh)"

# Source the helper with our stubs pre-installed.
# shellcheck disable=SC1090
source "$HELPER" 2>/dev/null || {
	printf 'failed to source %s\n' "$HELPER" >&2
	exit 1
}
set +e; set +u; set +o pipefail

# Re-stub after sourcing (the helper defines these).
print_info() { printf '[INFO] %s\n' "$*" >>"$INFO_LOG"; return 0; }
print_warning() { printf '[WARNING] %s\n' "$*" >>"$INFO_LOG"; return 0; }
print_error() { printf '[ERROR] %s\n' "$*" >>"$INFO_LOG"; return 0; }
export -f print_info print_warning print_error
find_project_root() { echo "$TMP"; }
detect_repo_slug() { echo "test/test"; }
export TMP INFO_LOG; export -f find_project_root detect_repo_slug

# Test 1a: FORCE_ENRICH=true logs the bypass
reset_log
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: real title" "real body content" >/dev/null 2>/dev/null || true
if log_contains "FORCE_ENRICH active"; then
	pass "FORCE_ENRICH=true emits info_log at bypass site"
else
	fail "FORCE_ENRICH=true should emit info_log" "log contents: $(cat "$INFO_LOG")"
fi

# Test 1b: FORCE_ENRICH floor — empty body still refused even with FORCE_ENRICH
reset_log
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: real title" "" >/dev/null 2>/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
	pass "FORCE_ENRICH floor: empty body refused even when FORCE_ENRICH=true"
else
	fail "FORCE_ENRICH floor: empty body should be refused even with FORCE_ENRICH=true"
fi

# Test 1c: FORCE_ENRICH floor — stub title still refused
reset_log
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: " "real body" >/dev/null 2>/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
	pass "FORCE_ENRICH floor: stub title refused even when FORCE_ENRICH=true"
else
	fail "FORCE_ENRICH floor: stub 'tNNN: ' title should be refused even with FORCE_ENRICH=true"
fi

# ============================================================
# Section 2: FORCE_PUSH bypass log (issue-sync-helper.sh)
# ============================================================
section "2. FORCE_PUSH bypass log (issue-sync-helper.sh)"

# Test 2a: FORCE_PUSH=false (default) — bulk push is skipped outside CI
reset_log
unset GITHUB_ACTIONS
FORCE_PUSH=false
_result=$(GITHUB_ACTIONS="" FORCE_PUSH=false cmd_push "" 2>&1)
if log_contains "Bulk push skipped" || printf '%s' "$_result" | grep -q "Bulk push skipped"; then
	pass "FORCE_PUSH=false correctly blocks bulk push outside CI"
else
	fail "FORCE_PUSH=false should block bulk push outside CI"
fi

# Test 2b: FORCE_PUSH=true — logs bypass
reset_log
# Create a minimal TODO.md fixture so cmd_push has something to read.
TODO_FIXTURE="${TMP}/TODO.md"
printf '## Tasks\n- [ ] t9999 Test task ref:GH#9999\n' >"$TODO_FIXTURE"
export TODO_FILE="$TODO_FIXTURE"
export GH_CALLS_LOG="${TMP}/gh-calls.log"
: >"$GH_CALLS_LOG"
FORCE_PUSH=true cmd_push "" 2>/dev/null || true
if log_contains "FORCE_PUSH active"; then
	pass "FORCE_PUSH=true emits info_log at bypass site"
else
	fail "FORCE_PUSH=true should emit info_log" "log: $(cat "$INFO_LOG")"
fi
unset TODO_FILE GH_CALLS_LOG

# ============================================================
# Section 3: FORCE_CLOSE bypass log (issue-sync-helper.sh)
# ============================================================
section "3. FORCE_CLOSE bypass log (issue-sync-helper.sh)"

# Test 3a: FORCE_CLOSE=false (default) — close blocked without evidence
reset_log
FORCE_CLOSE=false
# Invoke close_issue with a task that has no evidence (no pr: or verified:)
_result=$(FORCE_CLOSE=false cmd_close "t9999" 2>&1) || true
# Should have warned about no evidence
if log_contains "no merged PR or verified:" || printf '%s' "$_result" | grep -q "no merged PR"; then
	pass "FORCE_CLOSE=false correctly blocks close without evidence"
else
	fail "FORCE_CLOSE=false should block close without evidence"
fi

# Test 3b: FORCE_CLOSE=true — logs bypass
reset_log
# Create minimal TODO.md fixture
CLOSE_TODO="${TMP}/close-todo.md"
printf '## Tasks\n- [ ] t9999 Test task ref:GH#9999\n' >"$CLOSE_TODO"
FORCE_CLOSE=true _do_close "t9999" "9999" "$CLOSE_TODO" "test/test" 2>/dev/null || true
if log_contains "FORCE_CLOSE active"; then
	pass "FORCE_CLOSE=true emits info_log at bypass site"
else
	fail "FORCE_CLOSE=true should emit info_log" "log: $(cat "$INFO_LOG")"
fi

# ============================================================
# Section 4: AIDEVOPS_VM_SKIP_BUMP_VERIFY bypass log (version-manager-release.sh)
# ============================================================
section "4. AIDEVOPS_VM_SKIP_BUMP_VERIFY bypass log (version-manager-release.sh)"

if [[ ! -f "$VERSION_MGMT_RELEASE" ]]; then
	printf '  SKIP: %s not found\n' "$VERSION_MGMT_RELEASE"
else
	# We cannot source version-manager-release.sh without a git repo;
	# instead, grep for the log string as a structural assertion.
	if grep -qF "AIDEVOPS_VM_SKIP_BUMP_VERIFY=1 — bypassing bump-commit verification" "$VERSION_MGMT_RELEASE"; then
		pass "AIDEVOPS_VM_SKIP_BUMP_VERIFY bypass site has info_log (structural assertion)"
	else
		fail "AIDEVOPS_VM_SKIP_BUMP_VERIFY bypass site should have info_log" \
			"grep for 'bypassing bump-commit verification' in $VERSION_MGMT_RELEASE failed"
	fi

	# Verify the floor still exists (tag creation is after the bypass)
	if grep -qF "git tag -s" "$VERSION_MGMT_RELEASE"; then
		pass "AIDEVOPS_VM_SKIP_BUMP_VERIFY floor: git tag command still present after bypass site"
	else
		fail "AIDEVOPS_VM_SKIP_BUMP_VERIFY floor: git tag command missing from version-manager-release.sh"
	fi
fi

# ============================================================
# Section 5: AIDEVOPS_HEADLESS_SANDBOX_DISABLED bypass log (headless runtime modules)
# ============================================================
section "5. AIDEVOPS_HEADLESS_SANDBOX_DISABLED bypass log (headless runtime modules)"

if [[ ! -f "$HEADLESS_INVOKE" || ! -f "$HEADLESS_WORKER" ]]; then
	printf '  SKIP: headless runtime modules not found\n'
else
	# Structural assertion: log call is present at both bypass sites
	count=$(grep -h -c "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 —" "$HEADLESS_INVOKE" "$HEADLESS_WORKER" 2>/dev/null | awk '{ total += $1 } END { print total + 0 }')
	if [[ "$count" -ge 2 ]]; then
		pass "AIDEVOPS_HEADLESS_SANDBOX_DISABLED has info_log at both bypass sites (count=$count)"
	elif [[ "$count" -eq 1 ]]; then
		fail "AIDEVOPS_HEADLESS_SANDBOX_DISABLED: only 1 of 2 bypass sites has info_log (expected 2)"
	else
		fail "AIDEVOPS_HEADLESS_SANDBOX_DISABLED: no bypass sites have info_log" \
			"grep for 'AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 —' in headless runtime modules returned 0"
	fi

	# Floor: timeout command is still used even when sandbox is disabled
	if grep -q "timeout.*HEADLESS_SANDBOX_TIMEOUT" "$HEADLESS_INVOKE" "$HEADLESS_WORKER"; then
		pass "AIDEVOPS_HEADLESS_SANDBOX_DISABLED floor: timeout limit still enforced after bypass"
	else
		fail "AIDEVOPS_HEADLESS_SANDBOX_DISABLED floor: timeout enforcement missing from bypass path"
	fi
fi

# ============================================================
# Section 6: SKIP_FRAMEWORK_ROUTING_CHECK bypass log (claim-task-id.sh)
# ============================================================
section "6. SKIP_FRAMEWORK_ROUTING_CHECK bypass log (claim-task-id.sh)"

if [[ ! -f "$CLAIM_HELPER" ]]; then
	printf '  SKIP: %s not found\n' "$CLAIM_HELPER"
else
	# Structural assertion: log_info call present at bypass site
	if grep -qF "SKIP_FRAMEWORK_ROUTING_CHECK=true" "$CLAIM_HELPER" && \
	   grep -qF "suppressing framework routing warning" "$CLAIM_HELPER"; then
		pass "SKIP_FRAMEWORK_ROUTING_CHECK bypass site has log_info (structural assertion)"
	else
		fail "SKIP_FRAMEWORK_ROUTING_CHECK bypass site should have log_info" \
			"grep for 'suppressing framework routing warning' in $CLAIM_HELPER failed"
	fi

	# Structural assertion: the bypass uses log_info (confirmed by grep above)
	# and the early return is a plain `return 0` after the log call.
	if grep -A2 "SKIP_FRAMEWORK_ROUTING_CHECK" "$CLAIM_HELPER" | grep -q "return 0"; then
		pass "SKIP_FRAMEWORK_ROUTING_CHECK=true returns 0 after logging (structural)"
	else
		fail "SKIP_FRAMEWORK_ROUTING_CHECK=true: return 0 not found after bypass log"
	fi
fi

# ============================================================
# Section 7: FORCE_CLOSE audit log verified in issue-sync-helper.sh source
# ============================================================
section "7. Structural audit: all bypass sites have info_log calls"

# Verify each bypass site in issue-sync-helper.sh has the corresponding info_log
_check_audit_log_present() {
	local flag="$1"
	local log_marker="$2"
	local file="$3"
	if grep -qF "$log_marker" "$file" 2>/dev/null; then
		pass "Bypass site audit: '$flag' has audit log in $(basename "$file")"
	else
		fail "Bypass site audit: '$flag' missing audit log in $(basename "$file")" \
			"Expected to find: '$log_marker'"
	fi
	return 0
}

_check_audit_log_present "FORCE_ENRICH" "FORCE_ENRICH active" "$HELPER"
_check_audit_log_present "FORCE_PUSH" "FORCE_PUSH active" "$HELPER"
_check_audit_log_present "FORCE_CLOSE" "FORCE_CLOSE active" "$HELPER"
_check_audit_log_present "AIDEVOPS_SKIP_AUTO_CLAIM" "AIDEVOPS_SKIP_AUTO_CLAIM set" "${SCRIPTS_DIR}/worktree-helper.sh"
_check_audit_log_present "CONTENT_SCANNER_SKIP_NORMALIZE" "CONTENT_SCANNER_SKIP_NORMALIZE=true" "${SCRIPTS_DIR}/content-scanner-helper.sh"

# ============================================================
# Summary
# ============================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
