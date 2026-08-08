#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#22192 / t3402: LaunchAgent PATH generation must not
# serialize raw inherited shell PATH entries that do not exist on this host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

# shellcheck source=../shared-constants.sh
source "$REPO_ROOT/.agents/scripts/shared-constants.sh"

LAUNCHD_LABEL="com.test.aidevops-auto-update"
LOG_FILE="${TMPDIR:-/tmp}/aidevops-launchd-sanitized-path-test.log"
LAUNCHD_DIR="${TMPDIR:-/tmp}"
LAUNCHD_PLIST="${TMPDIR:-/tmp}/com.test.aidevops-auto-update.plist"
SYSTEMD_SERVICE_DIR="${TMPDIR:-/tmp}"
SYSTEMD_UNIT_NAME="aidevops-auto-update"
CRON_MARKER="# aidevops-auto-update"
DEFAULT_INTERVAL=10
INSTALL_DIR="$REPO_ROOT"

# shellcheck source=../auto-update-helper-scheduler.sh
source "$REPO_ROOT/.agents/scripts/auto-update-helper-scheduler.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR=""

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n  %s\n' "$name" "$detail" >&2
	return 0
}

assert_not_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		fail "$name" "unexpected PATH entry present: $needle"
		return 1
	fi
	return 0
}

test_sanitized_path_filters_unsafe_entries() {
	local test_home="$TEST_DIR/home"
	local stable_bun_bin="$test_home/.bun/bin"
	local stable_local_bin="$test_home/.local/bin"
	local stable_scripts="$test_home/.aidevops/agents/scripts"
	local stable_bin="$test_home/.aidevops/bin"
	local stale_bundle="$test_home/.aidevops/runtime-bundles/old/agents/scripts"
	local existing_dir="$TEST_DIR/existing-bin"
	local missing_dir="$TEST_DIR/missing-bin"
	mkdir -p "$stable_bun_bin" "$stable_local_bin" "$stable_scripts" "$stable_bin" \
		"$stale_bundle" "$existing_dir"

	local polluted_path result
	polluted_path="${stale_bundle}:${missing_dir}:${existing_dir}:/usr/bin:${stable_scripts}:${existing_dir}:/opt/pkg/env/active/bin:/opt/pmk/env/global/bin"
	result=$(HOME="$test_home" aidevops_launchd_sanitized_path "$polluted_path")

	local ok=0 stable_scripts_count=0
	[[ "$result" == "${stable_bun_bin}:${stable_local_bin}:${stable_scripts}:${stable_bin}:"* ]] || ok=1
	[[ "$result" == *"$existing_dir"* ]] || ok=1
	[[ "$result" == *"/usr/bin"* ]] || ok=1
	stable_scripts_count=$(printf '%s' "$result" | tr ':' '\n' | grep -Fxc "$stable_scripts" || true)
	[[ "$stable_scripts_count" -eq 1 ]] || ok=1
	assert_not_contains "test_sanitized_path_filters_unsafe_entries" "$result" "$stale_bundle" || ok=1
	assert_not_contains "test_sanitized_path_filters_unsafe_entries" "$result" "$missing_dir" || ok=1
	if [[ ! -d /opt/pkg/env/active/bin ]]; then
		assert_not_contains "test_sanitized_path_filters_unsafe_entries" "$result" "/opt/pkg/env/active/bin" || ok=1
	fi
	if [[ ! -d /opt/pmk/env/global/bin ]]; then
		assert_not_contains "test_sanitized_path_filters_unsafe_entries" "$result" "/opt/pmk/env/global/bin" || ok=1
	fi

	if [[ "$ok" -eq 0 ]]; then
		pass "test_sanitized_path_filters_unsafe_entries"
	else
		fail "test_sanitized_path_filters_unsafe_entries" "sanitized PATH was: $result"
	fi
	return 0
}

test_sanitized_path_preserves_unset_ifs() {
	local test_home="$TEST_DIR/unset-ifs-home"
	mkdir -p "$test_home/.aidevops/agents/scripts"

	local ifs_state=""
	ifs_state=$(
		unset IFS
		HOME="$test_home" aidevops_launchd_sanitized_path "/usr/bin:/bin" >/dev/null
		if [[ -z "${IFS+x}" ]]; then
			printf 'unset'
		else
			printf 'set'
		fi
	)

	if [[ "$ifs_state" == "unset" ]]; then
		pass "test_sanitized_path_preserves_unset_ifs"
	else
		fail "test_sanitized_path_preserves_unset_ifs" "IFS became set after sanitization"
	fi
	return 0
}

test_auto_update_plist_filters_polluted_env_path() {
	local existing_dir="$TEST_DIR/existing-tool-bin"
	local missing_dir="$TEST_DIR/missing-tool-bin"
	mkdir -p "$existing_dir"

	local polluted_path plist plist_file ok
	polluted_path="${missing_dir}:${existing_dir}:/usr/bin:/opt/pkg/env/active/bin:/opt/pmk/env/global/bin"
	plist=$(_generate_auto_update_plist "/bin/true" "600" "$polluted_path")
	plist_file="$TEST_DIR/auto-update.plist"
	printf '%s\n' "$plist" >"$plist_file"

	ok=0
	[[ "$plist" == *"$existing_dir"* ]] || ok=1
	assert_not_contains "test_auto_update_plist_filters_polluted_env_path" "$plist" "$missing_dir" || ok=1
	if [[ ! -d /opt/pkg/env/active/bin ]]; then
		assert_not_contains "test_auto_update_plist_filters_polluted_env_path" "$plist" "/opt/pkg/env/active/bin" || ok=1
	fi
	if [[ ! -d /opt/pmk/env/global/bin ]]; then
		assert_not_contains "test_auto_update_plist_filters_polluted_env_path" "$plist" "/opt/pmk/env/global/bin" || ok=1
	fi
	if command -v plutil >/dev/null 2>&1; then
		plutil -lint "$plist_file" >/dev/null 2>&1 || ok=1
	fi

	if [[ "$ok" -eq 0 ]]; then
		pass "test_auto_update_plist_filters_polluted_env_path"
	else
		fail "test_auto_update_plist_filters_polluted_env_path" "generated plist retained polluted PATH"
	fi
	return 0
}

test_auto_update_plist_injects_label_overrides() {
	local original_home="$HOME"
	local override_file="$TEST_DIR/home/.config/aidevops/plist-env-overrides.json"
	local plist ok
	HOME="$TEST_DIR/home"
	mkdir -p "${override_file%/*}"
	cat >"$override_file" <<'EOF'
{
  "com.test.aidevops-auto-update": {
    "AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT": "3",
    "BACKUP_KEEP_COUNT": "2"
  }
}
EOF

	plist=$(_generate_auto_update_plist "/bin/true" "600" "/usr/bin:/bin")
	ok=0
	[[ "$plist" == *"<key>AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT</key>"* ]] || ok=1
	[[ "$plist" == *"<string>3</string>"* ]] || ok=1
	[[ "$plist" == *"<key>BACKUP_KEEP_COUNT</key>"* ]] || ok=1
	[[ "$plist" == *"<string>2</string>"* ]] || ok=1
	HOME="$original_home"

	if [[ "$ok" -eq 0 ]]; then
		pass "test_auto_update_plist_injects_label_overrides"
	else
		fail "test_auto_update_plist_injects_label_overrides" "generated plist omitted auto-update overrides"
	fi
	return 0
}

main() {
	setup
	test_sanitized_path_filters_unsafe_entries
	test_sanitized_path_preserves_unset_ifs
	test_auto_update_plist_filters_polluted_env_path
	test_auto_update_plist_injects_label_overrides

	printf 'Ran %d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
