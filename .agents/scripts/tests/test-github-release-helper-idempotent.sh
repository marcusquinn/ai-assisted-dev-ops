#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-github-release-helper-idempotent.sh — GH#22434 regression guard.
#
# Asserts that duplicate GitHub release creation is treated as already complete
# instead of failing the release flow.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
mkdir -p "${HOME}/.aidevops/logs" "${TEST_ROOT}/bin"

cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u

log_file="${FAKE_GH_LOG:?}"
marker_file="${FAKE_GH_RELEASE_MARKER:?}"
printf '%s\n' "$*" >>"$log_file"

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
	printf 'marcusquinn/aidevops\n'
	exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
	if [[ "${FAKE_RELEASE_EXISTS:-0}" == "1" || -f "$marker_file" ]]; then
		printf 'release %s exists\n' "${3:-}"
		exit 0
	fi
	exit 1
fi

if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
	if [[ "${FAKE_CREATE_RATE_LIMIT:-0}" == "1" ]]; then
		printf 'HTTP 403: API rate limit exceeded for installation while calling /repos/marcusquinn/aidevops/releases\n' >&2
		exit 1
	fi
	if [[ "${FAKE_CREATE_PERMISSION:-0}" == "1" ]]; then
		printf 'HTTP 403: Resource not accessible by integration\n' >&2
		exit 1
	fi
	if [[ "${FAKE_CREATE_DUPLICATES:-0}" == "1" ]]; then
		: >"$marker_file"
		printf 'HTTP 422: Validation Failed (Release.tag_name already exists)\n' >&2
		exit 1
	fi
	: >"$marker_file"
	printf 'created %s\n' "${3:-}"
	exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "edit" ]]; then
	if [[ "${FAKE_EDIT_RATE_LIMIT:-0}" == "1" ]]; then
		printf 'HTTP 403: API rate limit exceeded for installation\n' >&2
		exit 1
	fi
	if [[ "${FAKE_EDIT_PERMISSION:-0}" == "1" ]]; then
		printf 'HTTP 403: Resource not accessible by integration\n' >&2
		exit 1
	fi
	exit 0
fi

exit 1
EOF
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"
export FAKE_GH_LOG="${TEST_ROOT}/gh.log"
export FAKE_GH_RELEASE_MARKER="${TEST_ROOT}/release-created.marker"

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_RELEASE_EXISTS=1
export FAKE_CREATE_DUPLICATES=0
export FAKE_CREATE_RATE_LIMIT=0
export FAKE_CREATE_PERMISSION=0
export FAKE_EDIT_RATE_LIMIT=0
export FAKE_EDIT_PERMISSION=0
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$output" == *"already exists"* ]]; then
	print_result 'existing release exits successfully' 0
else
	print_result 'existing release exits successfully' 1 "rc=$rc output=$output"
fi

if ! grep -q 'release create' "$FAKE_GH_LOG" 2>/dev/null; then
	print_result 'existing release does not call create' 0
else
	print_result 'existing release does not call create' 1 'unexpected release create call'
fi

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_RELEASE_EXISTS=0
export FAKE_CREATE_DUPLICATES=1
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$output" == *"duplicate create"* ]]; then
	print_result 'duplicate create race exits successfully' 0
else
	print_result 'duplicate create race exits successfully' 1 "rc=$rc output=$output"
fi

if grep -q 'release view v1.2.4 --repo marcusquinn/aidevops' "$FAKE_GH_LOG" 2>/dev/null && grep -q 'release create v1.2.4' "$FAKE_GH_LOG" 2>/dev/null; then
	print_result 'duplicate create race verifies release after create failure' 0
else
	print_result 'duplicate create race verifies release after create failure' 1 'missing expected gh calls'
fi

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_RELEASE_EXISTS=1
export FAKE_CREATE_DUPLICATES=0
export FAKE_EDIT_RATE_LIMIT=1
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' --reconcile-existing 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$output" == *"publication is verified"* && "$output" == *"metadata reconciliation is deferred"* ]]; then
	print_result 'rate-limited metadata edit preserves verified publication' 0
else
	print_result 'rate-limited metadata edit preserves verified publication' 1 "rc=$rc output=$output"
fi

EDIT_COUNT=$(grep -c 'release edit' "$FAKE_GH_LOG" 2>/dev/null || true)
if [[ "$EDIT_COUNT" -eq 1 ]]; then
	print_result 'rate-limited metadata reconciliation stops without retry storm' 0
else
	print_result 'rate-limited metadata reconciliation stops without retry storm' 1 "edit_count=$EDIT_COUNT"
fi

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_RELEASE_EXISTS=0
export FAKE_CREATE_RATE_LIMIT=1
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' --reconcile-existing 2>&1) || rc=$?
if [[ "$rc" -eq 75 && "$output" == *"operation deferred"* && "$output" == *"Re-run the same create command"* ]]; then
	print_result 'installation rate-limited create returns recoverable deferral' 0
else
	print_result 'installation rate-limited create returns recoverable deferral' 1 "rc=$rc output=$output"
fi

CREATE_COUNT=$(grep -c 'release create' "$FAKE_GH_LOG" 2>/dev/null || true)
if [[ "$CREATE_COUNT" -eq 1 ]]; then
	print_result 'rate-limited create stops without retry storm' 0
else
	print_result 'rate-limited create stops without retry storm' 1 "create_count=$CREATE_COUNT"
fi

VIEW_COUNT=$(grep -c 'release view' "$FAKE_GH_LOG" 2>/dev/null || true)
if [[ "$VIEW_COUNT" -eq 1 ]]; then
	print_result 'rate-limited create avoids a second quota-bound existence check' 0
else
	print_result 'rate-limited create avoids a second quota-bound existence check' 1 "view_count=$VIEW_COUNT"
fi

export FAKE_CREATE_RATE_LIMIT=0
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' --reconcile-existing 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$output" == *"created"* && -f "$FAKE_GH_RELEASE_MARKER" ]]; then
	print_result 'rerun after rate-limit reset creates missing release' 0
else
	print_result 'rerun after rate-limit reset creates missing release' 1 "rc=$rc output=$output"
fi

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_RELEASE_EXISTS=0
export FAKE_CREATE_PERMISSION=1
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' 2>&1) || rc=$?
if [[ "$rc" -eq 1 && "$output" == *"Resource not accessible"* && "$output" != *"operation deferred"* ]]; then
	print_result 'permanent create permission failure fails closed' 0
else
	print_result 'permanent create permission failure fails closed' 1 "rc=$rc output=$output"
fi

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_CREATE_PERMISSION=0
export FAKE_RELEASE_EXISTS=1
export FAKE_EDIT_RATE_LIMIT=0
export FAKE_EDIT_PERMISSION=1
rc=0
output=$("${TEST_SCRIPTS_DIR}/github-release-helper.sh" create 1.2.4 --repo marcusquinn/aidevops --notes 'notes' --reconcile-existing 2>&1) || rc=$?
if [[ "$rc" -eq 1 && "$output" == *"permanent permission error"* && "$output" != *"metadata reconciliation is deferred"* ]]; then
	print_result 'permanent metadata permission failure fails closed' 0
else
	print_result 'permanent metadata permission failure fails closed' 1 "rc=$rc output=$output"
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
