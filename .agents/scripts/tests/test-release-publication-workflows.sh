#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || exit 1
RELEASE_WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
PACKAGE_WORKFLOW="${REPO_ROOT}/.github/workflows/publish-packages.yml"
SETTINGS_HELPER="${REPO_ROOT}/.agents/scripts/release-publication-settings-helper.sh"

assert_contains() {
	local name="$1"
	local pattern="$2"
	local file="$3"
	if ! grep -qF -- "$pattern" "$file"; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_absent() {
	local name="$1"
	local pattern="$2"
	local file="$3"
	if grep -qF -- "$pattern" "$file"; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_order() {
	local name="$1"
	local first_pattern="$2"
	local second_pattern="$3"
	local file="$4"
	local first_line=""
	local second_line=""

	first_line=$(grep -nF -- "$first_pattern" "$file" | cut -d: -f1 | head -1)
	second_line=$(grep -nF -- "$second_pattern" "$file" | cut -d: -f1 | head -1)
	if [[ ! "$first_line" =~ ^[0-9]+$ || ! "$second_line" =~ ^[0-9]+$ || "$first_line" -ge "$second_line" ]]; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_absent "manual arbitrary-version publication is removed" "workflow_dispatch:" "$PACKAGE_WORKFLOW"
assert_absent "package metadata is not rewritten before publish" "--no-git-tag-version" "$PACKAGE_WORKFLOW"
assert_contains "release workflow verifies provenance" "release-provenance-helper.sh verify" "$RELEASE_WORKFLOW"
# shellcheck disable=SC2016 # Intentional literal GitHub Actions expression.
assert_contains "package workflow checks out release tag" 'ref: ${{ github.event.release.tag_name }}' "$PACKAGE_WORKFLOW"
assert_contains "Homebrew job has read-only repository permission" "contents: read" "$PACKAGE_WORKFLOW"
assert_order "release provenance precedes release creation" \
	"release-provenance-helper.sh verify" "github-release-helper.sh create" "$RELEASE_WORKFLOW"
assert_order "package provenance precedes npm publication" \
	"release-provenance-helper.sh verify" "npm publish --provenance" "$PACKAGE_WORKFLOW"

release_environment_count=$(grep -cF 'environment: release' "$RELEASE_WORKFLOW" || true)
package_environment_count=$(grep -cF 'environment: release' "$PACKAGE_WORKFLOW" || true)
if [[ "$release_environment_count" -ne 1 || "$package_environment_count" -ne 2 ]]; then
	printf 'FAIL all release and publication jobs must use the release environment\n'
	exit 1
fi
printf 'PASS all release and publication jobs use the release environment\n'

verification_count=$(grep -cF 'release-provenance-helper.sh verify' "$PACKAGE_WORKFLOW" || true)
if [[ "$verification_count" -ne 2 ]]; then
	printf 'FAIL npm and Homebrew jobs must each verify provenance\n'
	exit 1
fi
printf 'PASS npm and Homebrew jobs each verify provenance\n'

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_BIN="${TEST_ROOT}/bin"
mkdir -p "$TEST_BIN"

cat >"${TEST_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" != "api" ]]; then
	exit 1
fi
shift
if [[ "${1:-}" == "--method" ]]; then
	shift 2
fi
endpoint="${1:-}"
mode="${SETTINGS_TEST_MODE:-valid}"
case "$endpoint" in
repos/test/repo)
	printf '%s\n' '{"default_branch":"main","visibility":"public","permissions":{"admin":true}}'
	;;
repos/test/repo/actions/permissions/workflow)
	if [[ "$mode" == "bad-actions" ]]; then
		printf '%s\n' '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}'
	else
		printf '%s\n' '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
	fi
	;;
repos/test/repo/actions/permissions)
	printf '%s\n' '{"enabled":true,"allowed_actions":"all"}'
	;;
repos/test/repo/rulesets)
	if [[ "$mode" == "snapshot-empty" ]]; then
		printf '%s\n' '[]'
	else
		printf '%s\n' '[{"id":99,"name":"Protect aidevops release tags","target":"tag","enforcement":"active"}]'
	fi
	;;
repos/test/repo/rulesets/99)
	if [[ "$mode" == "bad-ruleset" ]]; then
		printf '%s\n' '{"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"}],"bypass_actors":[]}'
	else
		printf '%s\n' '{"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":7,"actor_type":"User","bypass_mode":"always"}]}'
	fi
	;;
repos/test/repo/environments)
	if [[ "$mode" == "snapshot-empty" ]]; then
		printf '%s\n' '{"total_count":0,"environments":[]}'
	else
		printf '%s\n' '{"total_count":1,"environments":[{"name":"release"}]}'
	fi
	;;
repos/test/repo/environments/release)
	if [[ "$mode" == "bad-environment" ]]; then
		printf '%s\n' '{"name":"release","protection_rules":[],"deployment_branch_policy":null}'
	else
		printf '%s\n' '{"name":"release","protection_rules":[{"type":"required_reviewers","prevent_self_review":true,"reviewers":[{"type":"User","reviewer":{"login":"reviewer"}}]}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
	fi
	;;
repos/test/repo/environments/release/deployment-branch-policies)
	printf '%s\n' '{"total_count":1,"branch_policies":[{"id":8,"name":"v*","type":"tag"}]}'
	;;
users/releaser)
	printf '%s\n' '{"id":7,"login":"releaser"}'
	;;
repos/test/repo/collaborators/releaser/permission)
	if [[ "$mode" == "bad-author" ]]; then
		printf '%s\n' '{"permission":"write","role_name":"write","user":{"login":"releaser"}}'
	else
		printf '%s\n' '{"permission":"admin","role_name":"admin","user":{"login":"releaser"}}'
	fi
	;;
*)
	printf 'unexpected endpoint: %s\n' "$endpoint" >&2
	exit 1
	;;
esac
exit 0
STUB
chmod +x "${TEST_BIN}/gh"

run_settings_helper() {
	local mode="$1"
	shift
	SETTINGS_TEST_MODE="$mode" PATH="${TEST_BIN}:${PATH}" bash "$SETTINGS_HELPER" "$@"
	return $?
}

snapshot=$(run_settings_helper snapshot-empty snapshot --repo test/repo) || {
	printf 'FAIL settings snapshot rejected readable empty live state\n'
	exit 1
}
if ! jq -e '.schema == "aidevops.release-publication-settings/v1"
	and .actions.workflow_permissions.default_workflow_permissions == "read"
	and (.rulesets.details | length) == 0
	and .environments.release.detail == null' <<<"$snapshot" >/dev/null; then
	printf 'FAIL settings snapshot omitted rollback state\n'
	exit 1
fi
printf 'PASS settings snapshot records rollback state\n'

if ! run_settings_helper valid verify-github --repo test/repo \
	--release-author releaser --reviewer reviewer >/dev/null; then
	printf 'FAIL valid GitHub release settings were rejected\n'
	exit 1
fi
printf 'PASS valid GitHub release settings are accepted\n'

for invalid_mode in bad-author bad-actions bad-ruleset bad-environment; do
	if run_settings_helper "$invalid_mode" verify-github --repo test/repo \
		--release-author releaser --reviewer reviewer >/dev/null 2>&1; then
		printf 'FAIL invalid settings mode was accepted: %s\n' "$invalid_mode"
		exit 1
	fi
done
printf 'PASS malformed GitHub release settings fail closed\n'

exit 0
