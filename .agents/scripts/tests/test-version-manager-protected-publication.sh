#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify aidevops publication queues exact protected workflow runs durably.

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
if [[ "$args" == *"actions/workflows/publish-packages.yml/runs"* ]]; then
	if [[ "${FAKE_RELEASE_RUNS_API_FAILURE:-0}" == "1" ]]; then
		exit 1
	fi
	case "${FAKE_RELEASE_RUNS_SCHEMA_MODE:-valid}" in
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
	printf '%s\n' "${FAKE_RELEASE_RUNS_JSON:?}"
	exit 0
fi
if [[ "$args" == *"releases/tags/v1.2.4"* ]]; then
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
git tag v1.2.4
TAG_COMMIT=$(git rev-parse HEAD)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/version-manager.sh"
set +e

export AIDEVOPS_RELEASE_WORKFLOW_DISCOVERY_TIMEOUT_SECONDS=3
export AIDEVOPS_RELEASE_WORKFLOW_POLL_SECONDS=1
export FAKE_RELEASE_RUNS_API_FAILURE=0
export FAKE_RELEASE_RUNS_SCHEMA_MODE=valid
export FAKE_RELEASE_RUNS_JSON="{\"workflow_runs\":[{\"id\":501,\"event\":\"push\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:00Z\",\"html_url\":\"\"}]}"
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":false,"published_at":"2026-07-27T00:00:00Z"}'

rc=0
deadline=$(($(date +%s) + 3))
run_json=$(_release_find_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
	'push' "$TAG_COMMIT" "$deadline" 1) || rc=$?
if [[ "$rc" -eq 0 && "$(jq -r '.id' <<<"$run_json")" == "501" ]]; then
	print_result 'exact unified publication workflow is discovered by tag commit' true
else
	print_result 'exact unified publication workflow is discovered by tag commit' false "rc=${rc}"
fi

for schema_mode in empty object malformed; do
	export FAKE_RELEASE_RUNS_SCHEMA_MODE="$schema_mode"
	rc=0
	_release_lookup_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
		'push' "$TAG_COMMIT" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "${schema_mode} workflow-run response fails closed" true
	else
		print_result "${schema_mode} workflow-run response fails closed" false
	fi
done
export FAKE_RELEASE_RUNS_SCHEMA_MODE=valid

export FAKE_RELEASE_RUNS_API_FAILURE=1
rc=0
_release_lookup_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
	'push' "$TAG_COMMIT" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result 'workflow-run API failure fails closed' true
else
	print_result 'workflow-run API failure fails closed' false
fi
export FAKE_RELEASE_RUNS_API_FAILURE=0

rc=0
_release_lookup_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
	'push' '0000000000000000000000000000000000000000' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 3 ]]; then
	print_result 'wrong workflow commit cannot satisfy exact correlation' true
else
	print_result 'wrong workflow commit cannot satisfy exact correlation' false "rc=${rc}"
fi

protected_wait_body=$(declare -f _wait_for_protected_github_release)
if [[ "$protected_wait_body" == *'"publish-packages.yml" "push"'* ]] &&
	[[ "$protected_wait_body" != *'actions/runs/'* ]]; then
	print_result 'canonical release observes the unified tag workflow without terminal waiting' true
else
	print_result 'canonical release observes the unified tag workflow without terminal waiting' false "$protected_wait_body"
fi

: >"$FAKE_GH_LOG"
rc=0
_wait_for_protected_github_release '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 8 ]] && ! grep -q 'actions/runs/501' "$FAKE_GH_LOG"; then
	print_result 'queued publication returns pending without a foreground terminal waiter' true
else
	print_result 'queued publication returns pending without a foreground terminal waiter' false "rc=${rc}"
fi

export FAKE_RELEASE_RUNS_JSON="{\"workflow_runs\":[{\"id\":501,\"event\":\"push\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"completed\",\"conclusion\":\"success\",\"created_at\":\"2026-07-27T00:00:00Z\",\"html_url\":\"\"}]}"
_verify_github_release_provenance() { return 0; }
rc=0
_wait_for_protected_github_release '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'already-completed publication reconciles immediately' true
else
	print_result 'already-completed publication reconciles immediately' false "rc=${rc}"
fi

export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":true,"published_at":null}'
if ! _github_release_rest_published 'marcusquinn/aidevops' 'v1.2.4'; then
	print_result 'draft release cannot satisfy completed publication' true
else
	print_result 'draft release cannot satisfy completed publication' false
fi
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":false,"published_at":"2026-07-27T00:00:00Z"}'

route_log="${TEST_ROOT}/route.log"
release_source_pr_required() { return 0; }
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
if [[ ! -s "$route_log" ]]; then
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
run_post_release_agent_sync() {
	printf 'deploy\n' >>"$route_log"
	return 0
}
rc=0
run_post_publication_gates '1.2.4' 0 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && "$(tr '\n' ',' <"$route_log")" == 'deploy,' ]]; then
	print_result 'remote publication is not redundantly awaited before local deployment' true
else
	print_result 'remote publication is not redundantly awaited before local deployment' false "rc=${rc} events=$(tr '\n' ' ' <"$route_log")"
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
