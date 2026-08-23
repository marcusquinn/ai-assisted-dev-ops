#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Root CLI delegation tests for `aidevops release`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/home" "${TEST_ROOT}/agents/scripts" "${TEST_ROOT}/other-repo"
git -C "${TEST_ROOT}/other-repo" init -q

IFS= read -r repo_version <"${REPO_ROOT}/VERSION"
printf '%s\n' "$repo_version" >"${TEST_ROOT}/agents/VERSION"
cp "$AIDEVOPS_SH" "${TEST_ROOT}/agents/aidevops.sh"
cp -R "${REPO_ROOT}/.agents/scripts/aidevops-cli" "${TEST_ROOT}/agents/scripts/"
cp "${REPO_ROOT}/.agents/scripts/plugin-source-trust-lib.sh" "${TEST_ROOT}/agents/scripts/"
cp "${REPO_ROOT}/.agents/scripts/runtime-bundle-manifest.sh" "${TEST_ROOT}/agents/scripts/"
cp "${REPO_ROOT}/.agents/scripts/runtime-bundle-verifier.sh" "${TEST_ROOT}/agents/scripts/"

run_cli() {
	(
		cd "${TEST_ROOT}/other-repo" || exit 1
		HOME="${TEST_ROOT}/home" AIDEVOPS_AGENTS_DIR="${TEST_ROOT}/agents" \
			AIDEVOPS_REPO_PATH="$REPO_ROOT" bash "$AIDEVOPS_SH" "$@"
	)
	return $?
}

run_deployed_cli() {
	(
		cd "${TEST_ROOT}/other-repo" || exit 1
		HOME="${TEST_ROOT}/home" AIDEVOPS_AGENTS_DIR="${TEST_ROOT}/agents" \
			AIDEVOPS_REPO_PATH="$REPO_ROOT" bash "${TEST_ROOT}/agents/aidevops.sh" "$@"
	)
	return $?
}

help_output=$(run_cli help)
if [[ "$help_output" != *"release <cmd>"* ]]; then
	printf 'FAIL root help does not list release command\n'
	exit 1
fi
printf 'PASS root help lists release command\n'

release_output=$(run_cli release --help)
if [[ "$release_output" != *"aidevops release status SOURCE_PR"* ]] ||
	[[ "$release_output" != *"aidevops release reconcile SOURCE_PR"* ]]; then
	printf 'FAIL release help did not reach the release helper\n'
	exit 1
fi
printf 'PASS release command delegates from an unrelated repository to aidevops\n'

release_rc=0
run_cli release status not-a-pr >/dev/null 2>&1 || release_rc=$?
if [[ "$release_rc" -ne 1 ]]; then
	printf 'FAIL release helper validation exit code was not preserved\n'
	exit 1
fi
printf 'PASS release helper validation exit code is preserved\n'

mkdir -p "${TEST_ROOT}/home/Git/aidevops/.agents/scripts/aidevops-cli"
cat >"${TEST_ROOT}/home/Git/aidevops/.agents/scripts/full-loop-release-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf 'stale canonical helper invoked\n'
exit 71
STUB
printf '# canonical module marker\n' \
	>"${TEST_ROOT}/home/Git/aidevops/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"
cat >"${TEST_ROOT}/agents/scripts/full-loop-release-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf 'deployed release helper: %s\n' "$*"
exit "${FAKE_DEPLOYED_HELPER_RC:-0}"
STUB
chmod +x "${TEST_ROOT}/home/Git/aidevops/.agents/scripts/full-loop-release-helper.sh" \
	"${TEST_ROOT}/agents/scripts/full-loop-release-helper.sh"

deployed_rc=0
deployed_output=$(FAKE_DEPLOYED_HELPER_RC=23 run_deployed_cli release status 90) || deployed_rc=$?
if [[ "$deployed_output" != *"deployed release helper: status 90"* ]] ||
	[[ "$deployed_output" == *"stale canonical helper invoked"* ]] ||
	[[ "$deployed_rc" -ne 23 ]]; then
	printf 'FAIL deployed CLI did not preserve coherent helper selection and exit status\n'
	exit 1
fi
printf 'PASS deployed CLI ignores stale canonical helpers and preserves helper exit status\n'

expected_set_output=$(run_deployed_cli release patch 90 full --expected-sources 89,90)
if [[ "$expected_set_output" != *"deployed release helper: patch 90 full --expected-sources 89,90"* ]]; then
	printf 'FAIL root CLI did not preserve the explicit expected source set\n'
	exit 1
fi
printf 'PASS root CLI preserves explicit multi-PR release authorization input\n'

gap_output=$(run_deployed_cli release authorization-gap 90 --tag v3.32.200 \
	--expected-sources 89@1111111111111111111111111111111111111111 \
	--reason 'historical authorization gap')
if [[ "$gap_output" != *"deployed release helper: authorization-gap 90 --tag v3.32.200 --expected-sources 89@1111111111111111111111111111111111111111 --reason historical authorization gap"* ]]; then
	printf 'FAIL root CLI did not preserve historical authorization-gap evidence input\n'
	exit 1
fi
printf 'PASS root CLI preserves historical authorization-gap evidence input\n'

exit 0
