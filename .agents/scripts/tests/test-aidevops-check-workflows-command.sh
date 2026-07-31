#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Root CLI delegation regression tests for GH#28866.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/home/.config/aidevops" "${TEST_ROOT}/bin"

# A help request must not invoke jq or parse this deliberately invalid registry.
printf 'registry sentinel: must not be read\n' >"${TEST_ROOT}/home/.config/aidevops/repos.json"
cat >"${TEST_ROOT}/bin/jq" <<'STUB'
#!/usr/bin/env bash
printf 'registry sentinel was read\n' >>"$SENTINEL_LOG"
exit 97
STUB
chmod +x "${TEST_ROOT}/bin/jq"

run_help() {
	local flag="$1"
	local output rc=0
	output=$(HOME="${TEST_ROOT}/home" \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		SENTINEL_LOG="${TEST_ROOT}/sentinel.log" \
		AIDEVOPS_REPO_PATH="$REPO_ROOT" \
		bash "$AIDEVOPS_SH" check-workflows "$flag" 2>&1) || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		printf 'FAIL check-workflows %s exited %d\n%s\n' "$flag" "$rc" "$output" >&2
		return 1
	fi
	if [[ "$output" != *"check-workflows-helper.sh [--repo OWNER/REPO]"* ]] ||
		[[ "$output" == *"Summary:"* ]] || [[ "$output" == *"local evidence"* ]]; then
		printf 'FAIL check-workflows %s did not print bounded usage only\n%s\n' "$flag" "$output" >&2
		return 1
	fi
	if [[ -e "${TEST_ROOT}/sentinel.log" ]]; then
		printf 'FAIL check-workflows %s read the repository registry\n' "$flag" >&2
		return 1
	fi
	printf 'PASS check-workflows %s prints usage without registry access\n' "$flag"
	return 0
}

run_help --help
run_help -h

exit 0
