#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CORE_ROUTINES="${SCRIPT_DIR}/../routines/core-routines.sh"
INIT_ROUTINES="${SCRIPT_DIR}/../init-routines-helper.sh"
TEST_ROOT=""
PASSED=0
FAILED=0

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (missing=%s)\n' "$description" "$needle" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_not_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (unexpected=%s)\n' "$description" "$needle" >&2
	FAILED=$((FAILED + 1))
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	# shellcheck source=../routines/core-routines.sh
	source "$CORE_ROUTINES"
	local entries=""
	entries=$(get_core_routine_entries)
	assert_contains "$entries" 'r916|x|Cloudron packages — check upstream releases|repeat:daily(@01:30)|~2m|scripts/cloudron-package-monitor-helper.sh upstream --apply|script|UTC' "daily UTC upstream routine registered"
	assert_contains "$entries" 'r917|x|Cloudron packages — audit compatibility|repeat:weekly(sun@07:40)|~5m|scripts/cloudron-package-monitor-helper.sh compatibility --apply|script' "weekly compatibility routine registered"
	local r916_description=""
	local r917_description=""
	r916_description=$(describe_r916 linux)
	r917_description=$(describe_r917 linux)
	assert_contains "$r916_description" 'cloudron-package-monitor-helper.sh upstream --apply' "r916 description exposes exact command"
	assert_contains "$r917_description" 'cloudron-package-monitor-helper.sh compatibility --apply' "r917 description exposes exact command"
	# shellcheck disable=SC2016  # Markdown backticks are literal expected output.
	assert_contains "$r916_description" 'Supervisor Pulse evaluates version-controlled `repeat:daily(@01:30) timezone:UTC`' "r916 exposes full UTC scheduling contract"
	assert_contains "$r916_description" 'Daily at 01:30 UTC' "r916 describes its fixed UTC schedule"
	# shellcheck disable=SC2016  # Markdown backticks are literal expected output.
	assert_contains "$r917_description" 'Supervisor Pulse evaluates version-controlled `repeat:weekly(sun@07:40)`' "r917 names Pulse as scheduler"
	assert_contains "$r916_description" 'systemctl --user status sh.aidevops.pulse' "r916 exposes shared Pulse diagnostics"
	assert_not_contains "$r916_description" 'sh.aidevops.cloudron-package-upstream' "r916 omits fictional dedicated service"
	assert_not_contains "$r917_description" 'sh.aidevops.cloudron-package-compatibility' "r917 omits fictional dedicated service"

	(
		# shellcheck source=../init-routines-helper.sh
		source "$INIT_ROUTINES"
		DRY_RUN=false
		_write_todo_md "$TEST_ROOT"
	)
	local generated_todo=""
	local r917_line=""
	generated_todo=$(<"${TEST_ROOT}/TODO.md")
	r917_line=$(printf '%s\n' "$generated_todo" | grep '^- \[x\] r917 ')
	assert_contains "$generated_todo" '- [x] r916 Cloudron packages — check upstream releases repeat:daily(@01:30) timezone:UTC ~2m run:scripts/cloudron-package-monitor-helper.sh upstream --apply' "generated r916 TODO line places UTC after repeat expression"
	assert_not_contains "$r917_line" 'timezone:' "generated routines without overrides remain timezone-free"
	assert_contains "$generated_todo" 'timezone: -- optional per-routine IANA timezone override' "generated TODO header documents timezone field"
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
