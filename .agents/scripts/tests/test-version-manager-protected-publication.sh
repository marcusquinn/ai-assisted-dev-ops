#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify aidevops publication waits for exact protected workflow runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "true" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: %s\n' "$name" "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
args=" $* "
if [[ "$args" == *"actions/workflows/release.yml/runs"* ]]; then
	printf '%s\n' "${FAKE_RELEASE_RUNS_JSON:?}"
	exit 0
fi
if [[ "$args" == *"actions/workflows/publish-packages.yml/runs"* ]]; then
	if [[ "${FAKE_PACKAGE_RUNS_API_FAILURE:-0}" == "1" ]]; then
		exit 1
	fi
	case "${FAKE_PACKAGE_RUNS_SCHEMA_MODE:-valid}" in
	empty) exit 0 ;;
	object)
		printf '%s\n' '{}'
		exit 0
		;;
	malformed)
		printf '%s\n' '{'
		exit 0
		;;
	esac
	if grep -q 'actions/workflows/publish-packages.yml/dispatches' "${FAKE_GH_LOG:?}" 2>/dev/null &&
		[[ -n "${FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON:-}" ]]; then
		printf '%s\n' "$FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON"
	else
		printf '%s\n' "${FAKE_PACKAGE_RUNS_JSON:?}"
	fi
	exit 0
fi
if [[ "$args" == *"actions/workflows/publish-packages.yml/dispatches"* ]]; then
	exit 0
fi
if [[ "$args" == *"actions/runs/501"* ]]; then
	printf '%s\n' "${FAKE_RELEASE_RUN_JSON:?}"
	exit 0
fi
if [[ "$args" == *"actions/runs/502"* ]]; then
	printf '%s\n' "${FAKE_PACKAGE_RUN_JSON:?}"
	exit 0
fi
if [[ "$args" == *"releases/tags/v1.2."* ]]; then
	printf '%s\n' "${FAKE_RELEASE_JSON:?}"
	exit 0
fi
exit 1
STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export FAKE_GH_LOG="${TEST_ROOT}/gh.log"

cd "${TEST_ROOT}/repo"
git init -q -b main
git config user.email 'test@example.com'
git config user.name 'Test Runner'
git config commit.gpgsign false
git remote add origin 'git@github.com:marcusquinn/aidevops.git'
printf 'fixture\n' >fixture.txt
git add fixture.txt
git commit -q -m 'fixture'
git tag v1.2.3
OLD_TAG_COMMIT=$(git rev-parse HEAD)
mkdir -p .github/workflows
printf 'on:\n  workflow_dispatch:\n' >.github/workflows/publish-packages.yml
git add .github/workflows/publish-packages.yml
git commit -q -m 'add protected package dispatch'
git tag v1.2.4
TAG_COMMIT=$(git rev-parse HEAD)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/version-manager.sh"
set +e

export AIDEVOPS_RELEASE_WORKFLOW_TIMEOUT_SECONDS=3
export AIDEVOPS_RELEASE_WORKFLOW_POLL_SECONDS=1
export FAKE_RELEASE_RUNS_JSON="{\"workflow_runs\":[{\"id\":501,\"event\":\"push\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:00Z\",\"html_url\":\"\"}]}"
export FAKE_RELEASE_RUN_JSON="{\"id\":501,\"event\":\"push\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"\"}"
export FAKE_PACKAGE_RUNS_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"release\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:01Z\",\"html_url\":\"\"}]}"
export FAKE_PACKAGE_RUN_JSON="{\"id\":502,\"event\":\"release\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"\"}"
export FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON=""
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":false,"published_at":"2026-07-27T00:00:00Z"}'
export FAKE_PACKAGE_RUNS_API_FAILURE=0
export FAKE_PACKAGE_RUNS_SCHEMA_MODE=valid
export AIDEVOPS_RELEASE_DISPATCH_REQUEST_ID='request-123'

if _release_package_dispatch_supported_at_tag 'v1.2.4' &&
	! _release_package_dispatch_supported_at_tag 'v1.2.3'; then
	print_result 'dispatch support is read from the immutable tag workflow' true
else
	print_result 'dispatch support is read from the immutable tag workflow' false
fi

rc=0
_release_wait_exact_workflow '1.2.4' 'release.yml' 'push' 'GitHub release' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'actions/runs/501' "$FAKE_GH_LOG"; then
	print_result 'exact release workflow reaches terminal success' true
else
	print_result 'exact release workflow reaches terminal success' false "rc=${rc}"
fi

rc=0
_release_wait_exact_workflow '1.2.4' 'publish-packages.yml' 'release' 'package publication' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'actions/runs/502' "$FAKE_GH_LOG"; then
	print_result 'exact package workflow reaches terminal success' true
else
	print_result 'exact package workflow reaches terminal success' false "rc=${rc}"
fi

: >"$FAKE_GH_LOG"
export FAKE_PACKAGE_RUNS_JSON='{"workflow_runs":[]}'
export FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"workflow_dispatch\",\"head_sha\":\"${TAG_COMMIT}\",\"display_title\":\"Publish packages for v1.2.4 (request-123)\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:02Z\",\"html_url\":\"\"}]}"
export FAKE_PACKAGE_RUN_JSON="{\"id\":502,\"event\":\"workflow_dispatch\",\"head_sha\":\"${TAG_COMMIT}\",\"display_title\":\"Publish packages for v1.2.4 (request-123)\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"\"}"
_verify_github_release_provenance() { return 0; }
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] &&
	grep -q 'actions/workflows/publish-packages.yml/dispatches' "$FAKE_GH_LOG" &&
	grep -q 'ref=v1.2.4' "$FAKE_GH_LOG" &&
	grep -q 'inputs\[tag\]=v1.2.4' "$FAKE_GH_LOG" &&
	grep -q 'inputs\[request_id\]=request-123' "$FAKE_GH_LOG"; then
	print_result 'package publication explicitly dispatches the signed tag' true
else
	print_result 'package publication explicitly dispatches the signed tag' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi

: >"$FAKE_GH_LOG"
export FAKE_PACKAGE_RUNS_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"workflow_dispatch\",\"head_sha\":\"${TAG_COMMIT}\",\"display_title\":\"Publish packages for v1.2.4 (request-123)\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:02Z\",\"html_url\":\"\"}]}"
export FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON=""
export FAKE_PACKAGE_RUN_JSON="{\"id\":502,\"event\":\"workflow_dispatch\",\"head_sha\":\"${TAG_COMMIT}\",\"display_title\":\"Publish packages for v1.2.4 (request-123)\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"\"}"
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'same request identity reuses its exact dispatch run' true
else
	print_result 'same request identity reuses its exact dispatch run' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi

: >"$FAKE_GH_LOG"
export FAKE_PACKAGE_RUNS_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"workflow_dispatch\",\"head_sha\":\"${TAG_COMMIT}\",\"display_title\":\"Publish packages for v1.2.4 (different-request)\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:02Z\",\"html_url\":\"\"}]}"
export FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"workflow_dispatch\",\"head_sha\":\"${TAG_COMMIT}\",\"display_title\":\"Publish packages for v1.2.4 (request-123)\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:03Z\",\"html_url\":\"\"}]}"
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'wrong dispatch title cannot satisfy request correlation' true
else
	print_result 'wrong dispatch title cannot satisfy request correlation' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi

: >"$FAKE_GH_LOG"
export FAKE_PACKAGE_RUNS_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"release\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:01Z\",\"html_url\":\"\"}]}"
export FAKE_PACKAGE_RUNS_AFTER_DISPATCH_JSON=""
export FAKE_PACKAGE_RUN_JSON="{\"id\":502,\"event\":\"release\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"\"}"
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'existing exact package run suppresses duplicate dispatch' true
else
	print_result 'existing exact package run suppresses duplicate dispatch' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi

: >"$FAKE_GH_LOG"
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.3","draft":false,"published_at":"2026-07-27T00:00:00Z"}'
export FAKE_PACKAGE_RUNS_JSON="{\"workflow_runs\":[{\"id\":502,\"event\":\"release\",\"head_sha\":\"${OLD_TAG_COMMIT}\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:01Z\",\"html_url\":\"\"}]}"
export FAKE_PACKAGE_RUN_JSON="{\"id\":502,\"event\":\"release\",\"head_sha\":\"${OLD_TAG_COMMIT}\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"\"}"
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.3' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'historical tag reuses the retained release-event recovery' true
else
	print_result 'historical tag reuses the retained release-event recovery' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi

: >"$FAKE_GH_LOG"
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":true,"published_at":null}'
export FAKE_PACKAGE_RUNS_JSON='{"workflow_runs":[]}'
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'unpublished GitHub release blocks package dispatch' true
else
	print_result 'unpublished GitHub release blocks package dispatch' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":false,"published_at":"2026-07-27T00:00:00Z"}'

: >"$FAKE_GH_LOG"
export FAKE_PACKAGE_RUNS_API_FAILURE=1
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'package-run API failure blocks dispatch' true
else
	print_result 'package-run API failure blocks dispatch' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi
export FAKE_PACKAGE_RUNS_API_FAILURE=0

for schema_mode in empty object malformed; do
	: >"$FAKE_GH_LOG"
	export FAKE_PACKAGE_RUNS_SCHEMA_MODE="$schema_mode"
	rc=0
	# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
	_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
		print_result "${schema_mode} package-run response blocks dispatch" true
	else
		print_result "${schema_mode} package-run response blocks dispatch" false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
	fi
done
export FAKE_PACKAGE_RUNS_SCHEMA_MODE=valid

: >"$FAKE_GH_LOG"
_verify_github_release_provenance() { return 1; }
rc=0
# shellcheck disable=SC2218 # Loaded from version-manager.sh before the later route-test stub.
_wait_for_protected_package_publication '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q '/dispatches' "$FAKE_GH_LOG"; then
	print_result 'provenance failure blocks package dispatch' true
else
	print_result 'provenance failure blocks package dispatch' false "rc=${rc} log=$(tr '\n' ' ' <"$FAKE_GH_LOG")"
fi
_verify_github_release_provenance() { return 0; }

route_log="${TEST_ROOT}/route.log"
release_source_pr_required() { return 0; }
_wait_for_protected_github_release() {
	local version="$1"
	printf 'protected:%s\n' "$version" >>"$route_log"
	return 0
}
create_github_release() {
	local version="$1"
	printf 'direct:%s\n' "$version" >>"$route_log"
	return 0
}
get_current_version() {
	printf '1.2.4\n'
	return 0
}
main github-release
if grep -qx 'protected:1.2.4' "$route_log" && ! grep -q '^direct:' "$route_log"; then
	print_result 'aidevops github-release recovery cannot create a release directly' true
else
	print_result 'aidevops github-release recovery cannot create a release directly' false "$(tr '\n' ' ' <"$route_log")"
fi

: >"$route_log"
release_source_pr_required() { return 1; }
_publish_github_release '1.2.4'
if grep -qx 'direct:1.2.4' "$route_log"; then
	print_result 'non-aidevops release retains direct publication compatibility' true
else
	print_result 'non-aidevops release retains direct publication compatibility' false "$(tr '\n' ' ' <"$route_log")"
fi

: >"$route_log"
release_source_pr_required() { return 0; }
_wait_for_protected_package_publication() {
	local version="$1"
	printf 'package:%s\n' "$version" >>"$route_log"
	return 0
}
run_post_release_agent_sync() {
	printf 'deploy\n' >>"$route_log"
	return 0
}
rc=0
run_post_publication_gates '1.2.4' 0 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && "$(tr '\n' ',' <"$route_log")" == 'package:1.2.4,deploy,' ]]; then
	print_result 'protected package publication completes before local deployment' true
else
	print_result 'protected package publication completes before local deployment' false "rc=${rc} events=$(tr '\n' ' ' <"$route_log")"
fi

: >"$route_log"
_wait_for_protected_package_publication() {
	local version="$1"
	printf 'package-failed:%s\n' "$version" >>"$route_log"
	return 1
}
rc=0
run_post_publication_gates '1.2.4' 0 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q '^deploy$' "$route_log"; then
	print_result 'failed protected package publication blocks local completion' true
else
	print_result 'failed protected package publication blocks local completion' false "rc=${rc} events=$(tr '\n' ' ' <"$route_log")"
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
