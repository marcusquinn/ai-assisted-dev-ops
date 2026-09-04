#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../browser-qa-helper.sh"
PLAYWRIGHT_RUNTIME="${SCRIPT_DIR}/../playwright-runtime.mjs"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${TEST_RESET} ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
		return 0
	fi

	echo -e "${TEST_RED}FAIL${TEST_RESET} ${test_name}"
	if [[ -n "$message" ]]; then
		echo "       ${message}"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_resolve_default_max_dim() {
	local value
	value=$(resolve_max_image_dim "")
	if [[ "$value" == "4000" ]]; then
		print_result "resolve default max dimension" 0
	else
		print_result "resolve default max dimension" 1 "expected 4000, got ${value}"
	fi
	return 0
}

test_resolve_invalid_max_dim_falls_back() {
	local value
	value=$(resolve_max_image_dim "not-a-number")
	if [[ "$value" == "4000" ]]; then
		print_result "invalid max dimension falls back to default" 0
	else
		print_result "invalid max dimension falls back to default" 1 "expected 4000, got ${value}"
	fi
	return 0
}

test_resolve_clamps_to_anthropic_limit() {
	local value
	value=$(resolve_max_image_dim "12000")
	if [[ "$value" == "8000" ]]; then
		print_result "max dimension clamps to Anthropic limit" 0
	else
		print_result "max dimension clamps to Anthropic limit" 1 "expected 8000, got ${value}"
	fi
	return 0
}

test_guardrail_resizes_oversized_images() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	touch "${tmp_dir}/small.png"
	touch "${tmp_dir}/large.png"

	get_image_dimensions() {
		local image_path="$1"
		case "$(basename "$image_path")" in
		small.png) echo "1200x900" ;;
		large.png)
			if [[ -f "${image_path}.resized" ]]; then
				echo "4000x2500"
			else
				echo "9000x5000"
			fi
			;;
		*) return 1 ;;
		esac
		return 0
	}

	resize_image_to_max_dim() {
		local image_path="$1"
		local max_dim="$2"
		if [[ "$max_dim" != "4000" ]]; then
			return 1
		fi
		touch "${image_path}.resized"
		return 0
	}

	if enforce_screenshot_size_guardrails "$tmp_dir" "4000"; then
		print_result "guardrail resizes oversized screenshots" 0
	else
		print_result "guardrail resizes oversized screenshots" 1 "expected enforcement success"
	fi

	rm -rf "$tmp_dir"
	return 0
}

test_guardrail_fails_hard_limit_violation() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	touch "${tmp_dir}/too-large.png"

	get_image_dimensions() {
		local image_path="$1"
		if [[ "$(basename "$image_path")" == "too-large.png" ]]; then
			echo "9001x9001"
			return 0
		fi
		return 1
	}

	resize_image_to_max_dim() {
		local image_path="$1"
		local max_dim="$2"
		if [[ -z "$image_path" || -z "$max_dim" ]]; then
			return 1
		fi
		return 0
	}

	if enforce_screenshot_size_guardrails "$tmp_dir" "8000"; then
		print_result "guardrail fails when hard limit remains exceeded" 1 "expected failure for image > 8000px"
	else
		print_result "guardrail fails when hard limit remains exceeded" 0
	fi

	rm -rf "$tmp_dir"
	return 0
}

test_stability_requires_url() {
	local output exit_code
	exit_code=0
	output=$(cmd_stability 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 ]] && printf '%s' "$output" | grep -q "URL is required"; then
		print_result "stability: missing --url returns error" 0
	else
		print_result "stability: missing --url returns error" 1 "expected non-zero exit with URL error, got exit=${exit_code}"
	fi
	return 0
}

test_stability_rejects_invalid_reloads() {
	local output exit_code
	exit_code=0
	output=$(cmd_stability --url "http://localhost:9999" --reloads "abc" 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 ]] && printf '%s' "$output" | grep -q "positive integer"; then
		print_result "stability: invalid --reloads rejected" 0
	else
		print_result "stability: invalid --reloads rejected" 1 "expected non-zero exit with integer error, got exit=${exit_code}"
	fi
	return 0
}

test_stability_rejects_zero_reloads() {
	local output exit_code
	exit_code=0
	output=$(cmd_stability --url "http://localhost:9999" --reloads "0" 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 ]] && printf '%s' "$output" | grep -q "positive integer"; then
		print_result "stability: zero --reloads rejected" 0
	else
		print_result "stability: zero --reloads rejected" 1 "expected non-zero exit with integer error, got exit=${exit_code}"
	fi
	return 0
}

test_stability_unknown_option_rejected() {
	local output exit_code
	exit_code=0
	output=$(cmd_stability --url "http://localhost:9999" --unknown-flag "val" 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 ]]; then
		print_result "stability: unknown option rejected" 0
	else
		print_result "stability: unknown option rejected" 1 "expected non-zero exit for unknown option"
	fi
	return 0
}

test_stability_script_generation() {
	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local script_dir script_file
	script_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-stability-XXXXXX")
	script_file="$script_dir/script.mjs"
	_generate_stability_script "$script_file" "http://localhost:3000" "'/'," "3" "30000" "500" "10000"
	local exit_code=$?
	if [[ "$exit_code" -eq 0 ]] && [[ -s "$script_file" ]]; then
		if grep -q "waitForNetworkQuiescence" "$script_file" && grep -q "domFingerprint" "$script_file"; then
			print_result "stability: script generation includes quiescence and fingerprint functions" 0
		else
			print_result "stability: script generation includes quiescence and fingerprint functions" 1 "missing expected JS functions"
		fi
	else
		print_result "stability: script generation produces non-empty file" 1 "exit=${exit_code} or empty file"
	fi
	rm -rf "$script_dir"
	return 0
}

test_format_stability_markdown_stable() {
	local json='{"summary":{"total":1,"stable":1,"unstable":0},"pages":[{"page":"/","reloads":3,"stable":true,"allLoadsOk":true,"stable_dom":true,"totalConsoleErrors":0,"totalNetworkErrors":0,"avgLoadMs":120,"baseFingerprint":null,"reloadResults":[]}]}'
	local output
	output=$(_format_stability_markdown "$json")
	if printf '%s' "$output" | grep -q "Stability Test Report" && printf '%s' "$output" | grep -q "Pages tested"; then
		print_result "stability: markdown format renders stable result" 0
	else
		print_result "stability: markdown format renders stable result" 1 "missing expected markdown sections"
	fi
	return 0
}

test_format_stability_markdown_unstable() {
	local json='{"summary":{"total":1,"stable":0,"unstable":1},"pages":[{"page":"/","reloads":3,"stable":false,"allLoadsOk":true,"stable_dom":false,"totalConsoleErrors":2,"totalNetworkErrors":0,"avgLoadMs":200,"baseFingerprint":null,"reloadResults":[]}]}'
	local output
	output=$(_format_stability_markdown "$json")
	if printf '%s' "$output" | grep -q "Unstable Pages"; then
		print_result "stability: markdown format renders unstable section" 0
	else
		print_result "stability: markdown format renders unstable section" 1 "missing Unstable Pages section"
	fi
	return 0
}

test_runtime_resolves_npx_cached_package() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	local fake_bin="${tmp_dir}/bin"
	local fake_modules="${tmp_dir}/cache/node_modules"
	local isolated_dir="${tmp_dir}/isolated"
	local browser_path="${tmp_dir}/chromium"
	local brave_path="${fake_bin}/brave"
	local brave_windows_path="${fake_bin}/brave.exe"
	mkdir -p "$fake_bin" "${fake_modules}/.bin" "${fake_modules}/playwright" "$isolated_dir"
	touch "$browser_path" "$brave_path" "$brave_windows_path"
	chmod +x "$brave_path" "$brave_windows_path"

	cat >"${fake_modules}/playwright/package.json" <<'JSON'
{"name":"playwright","type":"module","exports":"./index.mjs"}
JSON
	cat >"${fake_modules}/playwright/index.mjs" <<'JS'
export const chromium = { executablePath: () => process.env.FAKE_PLAYWRIGHT_BROWSER };
JS
	cat >"${fake_bin}/npx" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--no-install" ]] || exit 2
while [[ $# -gt 0 && "$1" != "node" ]]; do shift; done
[[ "${1:-}" == "node" ]] || exit 2
shift
export PATH="${FAKE_PLAYWRIGHT_MODULES}/.bin:${PATH}"
exec node "$@"
SH
	chmod +x "${fake_bin}/npx"

	local node_path
	node_path=$(command -v node)
	local direct_exit=0
	(
		cd "$isolated_dir" || exit 1
		PATH="${node_path%/*}:/usr/bin:/bin" node --input-type=module -e "import('playwright')"
	) >/dev/null 2>&1 || direct_exit=$?

	local resolved=""
	resolved=$(
		AIDEVOPS_PLAYWRIGHT_MODULE="" \
			FAKE_PLAYWRIGHT_BROWSER="$browser_path" \
			FAKE_PLAYWRIGHT_MODULES="$fake_modules" \
			PATH="${fake_bin}:${node_path%/*}:/usr/bin:/bin" \
			node "$PLAYWRIGHT_RUNTIME" check
	) || true
	local brave_status=""
	brave_status=$(
		AIDEVOPS_PLAYWRIGHT_MODULE="${fake_modules}/playwright/index.mjs" \
			FAKE_PLAYWRIGHT_BROWSER="$browser_path" \
			PATH="${fake_bin}:${node_path%/*}:/usr/bin:/bin" \
			node "$PLAYWRIGHT_RUNTIME" status
	) || true
	local status_prefers_brave=0
	if node -e 'const s=JSON.parse(process.argv[1]); process.exit(s.browserBinaryAvailable && s.browserExecutable !== process.argv[2] && /(?:Brave Browser|brave(?:-browser)?(?:\.exe)?)$/.test(s.browserExecutable) ? 0 : 1)' "$brave_status" "$browser_path"; then
		status_prefers_brave=1
	fi

	rm -f "$browser_path"
	local missing_browser_status=""
	missing_browser_status=$(
		AIDEVOPS_PLAYWRIGHT_MODULE="" \
			AIDEVOPS_PLAYWRIGHT_BROWSER="chromium" \
			FAKE_PLAYWRIGHT_BROWSER="$browser_path" \
			FAKE_PLAYWRIGHT_MODULES="$fake_modules" \
			PATH="${fake_bin}:${node_path%/*}:/usr/bin:/bin" \
			node "$PLAYWRIGHT_RUNTIME" status
	) || true
	local status_distinguishes_browser=0
	if node -e 'const s=JSON.parse(process.argv[1]); process.exit(s.packageImportable && !s.browserBinaryAvailable ? 0 : 1)' "$missing_browser_status"; then
		status_distinguishes_browser=1
	fi

	if [[ "$direct_exit" -ne 0 && "$resolved" == *"${fake_modules}/playwright/index.mjs" && "$status_prefers_brave" -eq 1 && "$status_distinguishes_browser" -eq 1 && ! -e "${isolated_dir}/package.json" && ! -d "${isolated_dir}/node_modules" ]]; then
		print_result "runtime resolves npx cache and prefers Brave" 0
	else
		print_result "runtime resolves npx cache and prefers Brave" 1 "direct_exit=${direct_exit}, resolved=${resolved:-none}, brave_status=${brave_status:-none}, browser_status=${missing_browser_status:-none}"
	fi

	rm -rf "$tmp_dir"
	return 0
}

main() {
	# Source after function declarations so helper functions are available here.
	# main() in helper is guarded and will not auto-run when sourced.
	# shellcheck source=../browser-qa-helper.sh
	source "$HELPER"

	echo "============================================="
	echo "  browser-qa-helper.sh guardrail tests"
	echo "============================================="

	test_resolve_default_max_dim
	test_resolve_invalid_max_dim_falls_back
	test_resolve_clamps_to_anthropic_limit
	test_guardrail_resizes_oversized_images
	test_guardrail_fails_hard_limit_violation

	echo "============================================="
	echo "  browser-qa-helper.sh stability tests"
	echo "============================================="

	test_stability_requires_url
	test_stability_rejects_invalid_reloads
	test_stability_rejects_zero_reloads
	test_stability_unknown_option_rejected
	test_stability_script_generation
	test_format_stability_markdown_stable
	test_format_stability_markdown_unstable
	test_runtime_resolves_npx_cached_package

	echo "============================================="
	echo "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	echo "============================================="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
