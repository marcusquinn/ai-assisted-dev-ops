#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || exit 1
RELEASE_WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
PACKAGE_WORKFLOW="${REPO_ROOT}/.github/workflows/publish-packages.yml"
SETTINGS_HELPER="${REPO_ROOT}/.agents/scripts/release-publication-settings-helper.sh"
readonly SNAPSHOT_MODE="snapshot-empty"

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
assert_absent "Homebrew publication failures are not masked" "continue-on-error: true" "$PACKAGE_WORKFLOW"
assert_order "release provenance precedes release creation" \
	"release-provenance-helper.sh verify" "github-release-helper.sh create" "$RELEASE_WORKFLOW"
assert_order "package provenance precedes npm publication" \
	"release-provenance-helper.sh verify" "npm publish --provenance" "$PACKAGE_WORKFLOW"

release_environment_count=$(grep -cE \
	'^[[:space:]]*environment:[[:space:]]*release[[:space:]]*$' "$RELEASE_WORKFLOW" || true)
package_environment_count=$(grep -cE \
	'^[[:space:]]*environment:[[:space:]]*release[[:space:]]*$' "$PACKAGE_WORKFLOW" || true)
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
endpoint=""
paginate="false"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--method)
		shift 2
		;;
	--paginate)
		paginate="true"
		shift
		;;
	*)
		endpoint="$1"
		shift
		;;
	esac
done
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
	if [[ "$paginate" != "true" ]]; then
		printf 'rulesets endpoint was not paginated\n' >&2
		exit 1
	fi
	if [[ "$mode" == "snapshot-empty" ]]; then
		printf '%s\n' '[]'
	else
		printf '%s\n' '[{"id":99,"name":"Protect aidevops release tags","target":"tag","enforcement":"active"}]'
	fi
	;;
repos/test/repo/rulesets/99)
	if [[ "$mode" == "bad-ruleset" ]]; then
		printf '%s\n' '{"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"deletion"}],"bypass_actors":[]}'
	elif [[ "$mode" == "bad-ruleset-exclusion" ]]; then
		printf '%s\n' '{"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":["refs/tags/v*"]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":7,"actor_type":"User","bypass_mode":"always"}]}'
	elif [[ "$mode" == "bad-bypass-actor" ]]; then
		printf '%s\n' '{"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":7,"actor_type":"User","bypass_mode":"always"},{"actor_id":8,"actor_type":"User","bypass_mode":"always"}]}'
	else
		printf '%s\n' '{"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":7,"actor_type":"User","bypass_mode":"always"}]}'
	fi
	;;
repos/test/repo/environments)
	if [[ "$paginate" != "true" ]]; then
		printf 'environments endpoint was not paginated\n' >&2
		exit 1
	fi
	if [[ "$mode" == "snapshot-empty" ]]; then
		printf '%s\n' '{"total_count":0,"environments":[]}'
	else
		printf '%s\n' '{"total_count":1,"environments":[{"name":"release"}]}'
	fi
	;;
repos/test/repo/environments/release)
	if [[ "$mode" == "bad-environment" ]]; then
		printf '%s\n' '{"name":"release","protection_rules":[],"deployment_branch_policy":null}'
	elif [[ "$mode" == "bad-reviewer-team" ]]; then
		printf '%s\n' '{"name":"release","protection_rules":[{"type":"required_reviewers","prevent_self_review":false,"reviewers":[{"type":"Team","reviewer":{"slug":"release-team"}}]}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
	elif [[ "$mode" == "bad-self-review" ]]; then
		printf '%s\n' '{"name":"release","protection_rules":[{"type":"required_reviewers","prevent_self_review":true,"reviewers":[{"type":"User","reviewer":{"login":"releaser"}}]}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
	else
		printf '%s\n' '{"name":"release","protection_rules":[{"type":"required_reviewers","prevent_self_review":false,"reviewers":[{"type":"User","reviewer":{"login":"releaser"}}]}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
	fi
	;;
repos/test/repo/environments/release/deployment-branch-policies)
	if [[ "$mode" == "bad-deployment-policy" ]]; then
		printf '%s\n' '{"total_count":2,"branch_policies":[{"id":8,"name":"v*","type":"tag"},{"id":9,"name":"main","type":"branch"}]}'
	else
		printf '%s\n' '{"total_count":1,"branch_policies":[{"id":8,"name":"v*","type":"tag"}]}'
	fi
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

snapshot=$(run_settings_helper "$SNAPSHOT_MODE" snapshot --repo test/repo) || {
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

snapshot_file="${TEST_ROOT}/release-settings.json"
snapshot_output=$(run_settings_helper "$SNAPSHOT_MODE" snapshot --repo test/repo \
	--output "$snapshot_file") || {
	printf 'FAIL settings snapshot output path was rejected\n'
	exit 1
}
if [[ "$snapshot_output" != "SNAPSHOT_FILE=${snapshot_file}" ]] ||
	! jq -e '.schema == "aidevops.release-publication-settings/v1"' "$snapshot_file" >/dev/null; then
	printf 'FAIL settings snapshot output contract is invalid\n'
	exit 1
fi
snapshot_mode=""
if snapshot_mode=$(stat -f '%Lp' "$snapshot_file" 2>/dev/null); then
	:
elif snapshot_mode=$(stat -c '%a' "$snapshot_file" 2>/dev/null); then
	:
else
	printf 'FAIL settings snapshot mode could not be read\n'
	exit 1
fi
if [[ "$snapshot_mode" != "600" ]]; then
	printf 'FAIL settings snapshot permissions are %s, expected 600\n' "$snapshot_mode"
	exit 1
fi
overwrite_output=""
if overwrite_output=$(run_settings_helper "$SNAPSHOT_MODE" snapshot --repo test/repo \
	--output "$snapshot_file" 2>&1); then
	printf 'FAIL settings snapshot overwrote an existing file\n'
	exit 1
fi
if ! grep -qF 'release-settings: refusing to overwrite snapshot:' <<<"$overwrite_output"; then
	printf 'FAIL settings snapshot overwrite failed for an unexpected reason\n'
	exit 1
fi
missing_parent_output=""
if missing_parent_output=$(run_settings_helper "$SNAPSHOT_MODE" snapshot --repo test/repo \
	--output "${TEST_ROOT}/missing/release-settings.json" 2>&1); then
	printf 'FAIL settings snapshot created a missing parent directory\n'
	exit 1
fi
if ! grep -qF 'release-settings: snapshot parent directory does not exist:' \
	<<<"$missing_parent_output"; then
	printf 'FAIL settings snapshot parent check failed for an unexpected reason\n'
	exit 1
fi
dangling_snapshot="${TEST_ROOT}/dangling-release-settings.json"
ln -s "${TEST_ROOT}/missing-target.json" "$dangling_snapshot"
dangling_output=""
if dangling_output=$(run_settings_helper "$SNAPSHOT_MODE" snapshot --repo test/repo \
	--output "$dangling_snapshot" 2>&1); then
	printf 'FAIL settings snapshot followed a dangling symlink\n'
	exit 1
fi
if ! grep -qF 'release-settings: refusing to overwrite snapshot:' <<<"$dangling_output"; then
	printf 'FAIL dangling snapshot failed for an unexpected reason\n'
	exit 1
fi
printf 'PASS settings snapshot output is atomic and private\n'

verify_output=$(run_settings_helper valid verify-github --repo test/repo \
	--release-author releaser --reviewer releaser) || {
	printf 'FAIL valid GitHub release settings were rejected\n'
	exit 1
}
for expected_marker in \
	'GITHUB_RELEASE_CONTROLS=verified' \
	'MANUAL_CHECK_REQUIRED=environment_admin_bypass_disabled' \
	'MANUAL_CHECK_REQUIRED=publisher_workflow_and_environment'; do
	if ! grep -qxF "$expected_marker" <<<"$verify_output"; then
		printf 'FAIL verify-github omitted marker: %s\n' "$expected_marker"
		exit 1
	fi
done
printf 'PASS valid GitHub release settings permit explicit maintainer self-approval\n'

for invalid_mode in bad-author bad-actions bad-ruleset bad-ruleset-exclusion \
	bad-bypass-actor bad-environment bad-reviewer-team bad-self-review \
	bad-deployment-policy; do
	expected_error=""
	case "$invalid_mode" in
	bad-author) expected_error="release author must retain repository admin authority" ;;
	bad-actions) expected_error="Actions defaults are not read-only with PR approval disabled" ;;
	bad-ruleset | bad-ruleset-exclusion | bad-bypass-actor)
		expected_error="release tag ruleset does not match the fail-closed policy"
		;;
	bad-environment) expected_error="release environment does not use custom ref policies" ;;
	bad-reviewer-team | bad-self-review)
		expected_error="release environment reviewer set is not exact"
		;;
	bad-deployment-policy)
		expected_error="release environment is not limited to the v* tag policy"
		;;
	esac
	invalid_output=""
	if invalid_output=$(run_settings_helper "$invalid_mode" verify-github --repo test/repo \
		--release-author releaser --reviewer releaser 2>&1); then
		printf 'FAIL invalid settings mode was accepted: %s\n' "$invalid_mode"
		exit 1
	fi
	if ! grep -qF "release-settings: ${expected_error}" <<<"$invalid_output"; then
		printf 'FAIL mode %s failed for an unexpected reason: %s\n' \
			"$invalid_mode" "$invalid_output"
		exit 1
	fi
done
printf 'PASS malformed GitHub release settings fail closed\n'

exit 0
