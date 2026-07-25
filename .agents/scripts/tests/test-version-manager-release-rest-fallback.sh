#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-version-manager-release-rest-fallback.sh — GH#22213 regression guard.
#
# Asserts that GitHub release creation recovers through REST when `gh release`
# fails after the version commit/tag/push phase has already succeeded.

set -uo pipefail

# Keep the disposable fixture repository isolated from the developer Git shim.
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

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

if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
	printf 'GraphQL API rate limit already exceeded\n' >&2
	exit 1
fi

if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
	printf 'GraphQL API rate limit already exceeded\n' >&2
	exit 1
fi

if [[ "${1:-}" == "api" ]]; then
	endpoint="${2:-}"
	if [[ "$endpoint" == repos/*/releases/tags/* ]]; then
		if [[ "${FAKE_REST_VIEW_SUCCEEDS:-0}" == "1" || -f "$marker_file" ]]; then
			printf '{"tag_name":"v1.2.4"}\n'
			exit 0
		fi
		exit 1
	fi
	if [[ "$endpoint" == repos/*/releases ]]; then
		: >"$marker_file"
		printf '{"tag_name":"v1.2.4"}\n'
		exit 0
	fi
fi

exit 1
EOF
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"

REPO_DIR="${TEST_ROOT}/repo"
mkdir -p "$REPO_DIR"
cd "$REPO_DIR" || exit 1
git init -q -b main
git config user.email 'test@example.com'
git config user.name 'Test Runner'
git config commit.gpgsign false
git remote add origin 'git@github.com:marcusquinn/aidevops.git'

# Source in a git repo so version-manager.sh initialises REPO_ROOT to the
# fixture repository while loading implementation files from TEST_SCRIPTS_DIR.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager.sh"
set +e

export FAKE_GH_LOG="${TEST_ROOT}/gh.log"
export FAKE_GH_RELEASE_MARKER="${TEST_ROOT}/release-created.marker"

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
_verify_github_release_provenance() { return 1; }
rc=0
create_github_release '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 && ! -s "$FAKE_GH_LOG" ]]; then
	print_result 'GitHub release creation fails closed before publication' 0
else
	print_result 'GitHub release creation fails closed before publication' 1 "rc=$rc"
fi

_verify_github_release_provenance() { return 0; }
export FAKE_REST_VIEW_SUCCEEDS=1
rc=0
output=$(create_github_release '1.2.4' 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$output" == *"REST confirms v1.2.4 already exists"* ]]; then
	print_result 'REST view recovers an already-created partial release' 0
else
	print_result 'REST view recovers an already-created partial release' 1 "rc=$rc output=$output"
fi

if ! grep -q 'api repos/marcusquinn/aidevops/releases --method POST' "$FAKE_GH_LOG" 2>/dev/null; then
	print_result 'existing REST release recovery does not recreate release' 0
else
	print_result 'existing REST release recovery does not recreate release' 1 'unexpected REST POST call'
fi

rm -f "$FAKE_GH_LOG" "$FAKE_GH_RELEASE_MARKER"
export FAKE_REST_VIEW_SUCCEEDS=0
rc=0
output=$(create_github_release '1.2.4' 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$output" == *"Created GitHub release via REST fallback"* ]]; then
	print_result 'REST create recovers GraphQL-exhausted release creation' 0
else
	print_result 'REST create recovers GraphQL-exhausted release creation' 1 "rc=$rc output=$output"
fi

if grep -q 'api repos/marcusquinn/aidevops/releases --method POST' "$FAKE_GH_LOG" 2>/dev/null; then
	print_result 'REST fallback calls releases create endpoint' 0
else
	print_result 'REST fallback calls releases create endpoint' 1 'missing REST POST call'
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
