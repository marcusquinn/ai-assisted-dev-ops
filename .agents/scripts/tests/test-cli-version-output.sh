#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#31161 version-warning output channels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
CLI_SOURCE="${REPO_ROOT}/aidevops.sh"
TEST_ROOT=$(mktemp -d)

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message"
	exit 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

run_cli() {
	(
		cd "${TEST_ROOT}/other-repo" || exit 1
		HOME="${TEST_ROOT}/home" AIDEVOPS_AGENTS_DIR="${TEST_ROOT}/agents" \
			bash "${TEST_ROOT}/bin/aidevops.sh" "$@"
	)
	return $?
}

write_fixture() {
	local canonical_root="${TEST_ROOT}/home/Git/aidevops"
	local repo_version=""
	mkdir -p "${TEST_ROOT}/bin" "${canonical_root}/.agents/scripts" "${TEST_ROOT}/agents" "${TEST_ROOT}/other-repo"
	git -C "${TEST_ROOT}/other-repo" init -q
	IFS= read -r repo_version <"${REPO_ROOT}/VERSION"
	cp "$CLI_SOURCE" "${TEST_ROOT}/bin/aidevops.sh"
	cp -R "${REPO_ROOT}/.agents/scripts/aidevops-cli" "${canonical_root}/.agents/scripts/"
	cp "${REPO_ROOT}/.agents/scripts/plugin-source-trust-lib.sh" "${canonical_root}/.agents/scripts/"
	cp "${REPO_ROOT}/.agents/scripts/runtime-bundle-manifest.sh" "${canonical_root}/.agents/scripts/"
	cp "${REPO_ROOT}/.agents/scripts/runtime-bundle-verifier.sh" "${canonical_root}/.agents/scripts/"
	printf '%s\n' "$repo_version" >"${canonical_root}/VERSION"
	printf '%s\n' 'fixture-agents-version' >"${TEST_ROOT}/agents/VERSION"
	printf '%s\n' '#!/usr/bin/env bash' >"${canonical_root}/.agents/scripts/secret-helper.sh"
	# shellcheck disable=SC2016 # The generated fixture expands these variables when dispatched.
	printf '%s\n' 'if [[ "${1:-}" == "get" && "${2:-}" == "AIDEVOPS_OUTPUT_TEST_SYNTHETIC" ]]; then' >>"${canonical_root}/.agents/scripts/secret-helper.sh"
	printf '%s\n' "printf 'fixture-value\\n'" >>"${canonical_root}/.agents/scripts/secret-helper.sh"
	printf '%s\n' 'exit 0' >>"${canonical_root}/.agents/scripts/secret-helper.sh"
	printf '%s\n' 'fi' >>"${canonical_root}/.agents/scripts/secret-helper.sh"
	printf '%s\n' "printf '[ERROR] Synthetic fixture not found\\n' >&2" >>"${canonical_root}/.agents/scripts/secret-helper.sh"
	printf '%s\n' 'exit 1' >>"${canonical_root}/.agents/scripts/secret-helper.sh"
	chmod +x "${TEST_ROOT}/bin/aidevops.sh" "${canonical_root}/.agents/scripts/secret-helper.sh"
	return 0
}

write_fixture
printf 'fixture-value\n' >"${TEST_ROOT}/expected.stdout"

success_rc=0
run_cli secret get AIDEVOPS_OUTPUT_TEST_SYNTHETIC >"${TEST_ROOT}/success.stdout" 2>"${TEST_ROOT}/success.stderr" || success_rc=$?
[[ "$success_rc" -eq 0 ]] || fail "mismatched successful lookup returned $success_rc"
cmp -s "${TEST_ROOT}/expected.stdout" "${TEST_ROOT}/success.stdout" || fail "mismatched successful lookup contaminated stdout"
grep -Fq 'Version mismatch' "${TEST_ROOT}/success.stderr" || fail "mismatched successful lookup omitted version warning from stderr"
pass 'mismatched successful lookup keeps stdout credential-only'

missing_rc=0
run_cli secret get AIDEVOPS_OUTPUT_TEST_MISSING >"${TEST_ROOT}/missing.stdout" 2>"${TEST_ROOT}/missing.stderr" || missing_rc=$?
[[ "$missing_rc" -eq 1 ]] || fail "mismatched missing lookup returned $missing_rc"
[[ ! -s "${TEST_ROOT}/missing.stdout" ]] || fail "mismatched missing lookup wrote to stdout"
grep -Fq 'Version mismatch' "${TEST_ROOT}/missing.stderr" || fail "mismatched missing lookup omitted version warning from stderr"
grep -Fq 'Synthetic fixture not found' "${TEST_ROOT}/missing.stderr" || fail "mismatched missing lookup omitted helper error from stderr"
pass 'mismatched missing lookup keeps diagnostics on stderr'

IFS= read -r repo_version <"${REPO_ROOT}/VERSION"
printf '%s\n' "$repo_version" >"${TEST_ROOT}/agents/VERSION"
matching_rc=0
run_cli secret get AIDEVOPS_OUTPUT_TEST_SYNTHETIC >"${TEST_ROOT}/matching.stdout" 2>"${TEST_ROOT}/matching.stderr" || matching_rc=$?
[[ "$matching_rc" -eq 0 ]] || fail "matching successful lookup returned $matching_rc"
cmp -s "${TEST_ROOT}/expected.stdout" "${TEST_ROOT}/matching.stdout" || fail "matching successful lookup changed stdout"
[[ ! -s "${TEST_ROOT}/matching.stderr" ]] || fail "matching successful lookup wrote unexpected diagnostics"
pass 'matching versions preserve existing command behavior'
