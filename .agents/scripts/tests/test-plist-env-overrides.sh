#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for plist env override injection (GH#20563 / t2759).
# Tests: missing file, valid file with label match, valid file without label match, malformed JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SCHEDULERS_SH="$REPO_ROOT/.agents/scripts/setup/modules/schedulers.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Load only the functions we need from schedulers.sh.
# schedulers.sh uses print_info / print_warning from shared-constants.sh;
# stub them so the sourced code doesn't blow up without the full setup context.
# ---------------------------------------------------------------------------

_load_schedulers_functions() {
	# Stubs for helpers that schedulers.sh calls at source-time or in helpers we use
	print_info()    { : ; }
	print_warning() { echo "[WARN] $*" >&2; }
	print_error()   { echo "[ERROR] $*" >&2; }
	_xml_escape()   { printf '%s' "$1"; }   # passthrough — not testing XML escaping here

	# shellcheck source=/dev/null
	source "$SCHEDULERS_SH" 2>/dev/null || {
		echo "SKIP: could not source $SCHEDULERS_SH (missing dependencies?)"
		exit 0
	}
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_missing_file() {
	local missing_file="$TEST_DIR/nonexistent-plist-env-overrides.json"
	local output
	output=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$missing_file")
	if [[ -z "$output" ]]; then
		print_result "missing_file: emits empty output" 0
	else
		print_result "missing_file: emits empty output" 1 "got: $output"
	fi
	return 0
}

test_label_match_injects_vars() {
	local override_file="$TEST_DIR/plist-env-overrides.json"
	cat >"$override_file" <<'EOF'
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "SCANNER_NUDGE_AGE_HOURS": "0",
    "AUTO_DECOMPOSER_INTERVAL": "86400"
  }
}
EOF
	local output
	output=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$override_file")

	local ok=0
	echo "$output" | grep -q "SCANNER_NUDGE_AGE_HOURS" || ok=1
	echo "$output" | grep -q "<string>0</string>" || ok=1
	echo "$output" | grep -q "AUTO_DECOMPOSER_INTERVAL" || ok=1
	echo "$output" | grep -q "<string>86400</string>" || ok=1

	print_result "label_match: injects SCANNER_NUDGE_AGE_HOURS and AUTO_DECOMPOSER_INTERVAL" "$ok" \
		"output was: $output"
	return 0
}

test_underscore_keys_skipped() {
	local override_file="$TEST_DIR/plist-env-overrides.json"
	cat >"$override_file" <<'EOF'
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "_doc": "example comment",
    "_SKIP_ME": "should not appear",
    "KEEP_ME": "keep"
  }
}
EOF
	local output
	output=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$override_file")

	local ok=0
	echo "$output" | grep -q "_doc" && ok=1
	echo "$output" | grep -q "_SKIP_ME" && ok=1
	echo "$output" | grep -q "KEEP_ME" || ok=1

	print_result "underscore_keys: _-prefixed keys are skipped, non-_ keys are kept" "$ok" \
		"output was: $output"
	return 0
}

test_no_label_match_emits_nothing() {
	local override_file="$TEST_DIR/plist-env-overrides.json"
	cat >"$override_file" <<'EOF'
{
  "com.aidevops.some-other-label": {
    "FOO": "bar"
  }
}
EOF
	local output
	output=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$override_file")

	if [[ -z "$output" ]]; then
		print_result "no_label_match: emits empty output" 0
	else
		print_result "no_label_match: emits empty output" 1 "got: $output"
	fi
	return 0
}

test_malformed_json_logs_warn_and_emits_nothing() {
	local override_file="$TEST_DIR/plist-env-overrides.json"
	printf '{invalid json' >"$override_file"

	local output stderr_output
	stderr_output=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$override_file" 2>&1 >/dev/null) || true
	output=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$override_file" 2>/dev/null) || true

	local ok=0
	[[ -z "$output" ]] || ok=1
	echo "$stderr_output" | grep -qi "WARN\|malformed" || ok=1

	print_result "malformed_json: emits WARN and no output" "$ok" \
		"stderr: $stderr_output | stdout: $output"
	return 0
}

test_default_path_prefers_stable_config_with_legacy_fallback() {
	local original_home="$HOME"
	local label="com.aidevops.aidevops-supervisor-pulse"
	local legacy_file="$TEST_DIR/home/.aidevops/agents/configs/plist-env-overrides.json"
	local stable_file="$TEST_DIR/home/.config/aidevops/plist-env-overrides.json"
	local output=""
	local ok=0
	HOME="$TEST_DIR/home"
	mkdir -p "${legacy_file%/*}" "${stable_file%/*}"
	printf '{"%s":{"LEGACY_KEY":"legacy-value"}}\n' "$label" >"$legacy_file"

	output=$(_build_plist_env_overrides_xml "$label")
	[[ "$output" == *"LEGACY_KEY"* && "$output" == *"legacy-value"* ]] || ok=1
	printf '{"%s":{"STABLE_KEY":"stable-value"}}\n' "$label" >"$stable_file"
	output=$(_build_plist_env_overrides_xml "$label")
	[[ "$output" == *"STABLE_KEY"* && "$output" == *"stable-value"* ]] || ok=1
	[[ "$output" != *"LEGACY_KEY"* && "$output" != *"legacy-value"* ]] || ok=1

	HOME="$original_home"
	print_result "default_path: stable config wins with legacy fallback" "$ok" "output was: $output"
	return 0
}

test_logging_contains_keys_not_values() {
	local override_file="$TEST_DIR/logging-plist-env-overrides.json"
	local output=""
	local ok=0
	cat >"$override_file" <<'EOF'
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "VISIBLE_KEY_NAME": "value-must-not-be-logged"
  }
}
EOF
	print_info() { printf '%s\n' "$*"; return 0; }
	output=$(_log_plist_env_overrides "com.aidevops.aidevops-supervisor-pulse" "$override_file")
	[[ "$output" == *"VISIBLE_KEY_NAME"* ]] || ok=1
	[[ "$output" != *"value-must-not-be-logged"* ]] || ok=1
	print_result "logging: reports override keys without values" "$ok" "output was: $output"
	return 0
}

test_merge_scheduler_injects_label_overrides() {
	local original_home="$HOME"
	local label="com.aidevops.aidevops-supervisor-merge"
	local override_file="$TEST_DIR/home/.config/aidevops/plist-env-overrides.json"
	local captured_plist=""
	local ok=0
	HOME="$TEST_DIR/home"
	mkdir -p "${override_file%/*}" "$TEST_DIR/logs"
	cat >"$override_file" <<'EOF'
{
  "com.aidevops.aidevops-supervisor-merge": {
    "AIDEVOPS_GH_EXACT_QUOTA_CAPTURE": "1"
  }
}
EOF
	_resolve_modern_bash() {
		printf '/bin/bash'
		return 0
	}
	_launchd_install_if_changed() {
		local installed_label="$1"
		local installed_path="$2"
		local installed_content="$3"
		[[ "$installed_label" == "$label" ]] || return 1
		[[ "$installed_path" == "$HOME/Library/LaunchAgents/${label}.plist" ]] || return 1
		captured_plist="$installed_content"
		return 0
	}

	_install_pulse_merge_routine_launchd "$label" "$TEST_DIR/pulse-merge-routine.sh" "$TEST_DIR/logs"
	[[ "$captured_plist" == *"AIDEVOPS_GH_EXACT_QUOTA_CAPTURE"* ]] || ok=1
	[[ "$captured_plist" == *"<string>1</string>"* ]] || ok=1

	HOME="$original_home"
	print_result "merge_scheduler: injects overrides for dedicated merge label" "$ok" \
		"captured plist was: $captured_plist"
	return 0
}

test_xml_structure_valid() {
	# Check that the output is parseable XML when embedded in a minimal plist.
	# Only runs if xmllint is available.
	if ! command -v xmllint >/dev/null 2>&1; then
		echo "SKIP xml_structure_valid: xmllint not available"
		return 0
	fi

	local override_file="$TEST_DIR/plist-env-overrides.json"
	cat >"$override_file" <<'EOF'
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "MY_VAR": "my_value"
  }
}
EOF
	local xml_fragment
	xml_fragment=$(_build_plist_env_overrides_xml "com.aidevops.aidevops-supervisor-pulse" "$override_file")

	local test_plist
	test_plist="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
${xml_fragment}
</dict></plist>"

	local ok=0
	if echo "$test_plist" | xmllint --noout - 2>/dev/null; then
		ok=0
	else
		ok=1
	fi
	print_result "xml_structure_valid: injected XML parses as valid plist" "$ok" \
		"fragment: $xml_fragment"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	setup

	if ! command -v jq >/dev/null 2>&1; then
		echo "SKIP all tests: jq not available"
		exit 0
	fi

	_load_schedulers_functions

	test_missing_file
	test_label_match_injects_vars
	test_underscore_keys_skipped
	test_no_label_match_emits_nothing
	test_malformed_json_logs_warn_and_emits_nothing
	test_default_path_prefers_stable_config_with_legacy_fallback
	test_logging_contains_keys_not_values
	test_merge_scheduler_injects_label_overrides
	test_xml_structure_valid

	echo ""
	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
