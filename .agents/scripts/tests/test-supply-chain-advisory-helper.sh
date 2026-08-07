#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#23640.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../supply-chain-advisory-helper.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

make_tmpdir() {
	local tmpdir
	tmpdir=$(mktemp -d) || return 1
	printf '%s\n' "$tmpdir"
	return 0
}

is_safe_test_tmpdir() {
	local tmpdir="${1:-}"
	[[ -n "$tmpdir" ]] || return 1
	[[ "$tmpdir" == /*[!/.]* ]] || return 1
	[[ "$tmpdir" != */.. ]] || return 1
	[[ "$tmpdir" != */../* ]] || return 1
	return 0
}

cleanup_test_tmpdir() {
	local tmpdir="${1:-}"
	if ! is_safe_test_tmpdir "$tmpdir"; then
		return 0
	fi
	rm -rf -- "$tmpdir" || return 1
	return 0
}

test_cleanup_test_tmpdir_rejects_unsafe_paths() {
	local test_name="cleanup helper rejects unsafe tmpdir paths"
	local path
	for path in '' relative / // /// //// /. /.. /./ /../ //./ //../ /tmp/.. /tmp/../unsafe; do
		if is_safe_test_tmpdir "$path"; then
			print_result "$test_name" 1 "accepted unsafe path: ${path:-<empty>}"
			return 0
		fi
	done
	print_result "$test_name" 0
	return 0
}

prepare_test_dirs() {
	local test_name="$1"
	local tmpdir="$2"
	shift 2
	local paths=("$@")
	if mkdir -p "${paths[@]}"; then
		return 0
	fi
	print_result "$test_name" 1 "mkdir failed"
	cleanup_test_tmpdir "$tmpdir"
	return 1
}

test_self_reference_only_scan_succeeds() {
	local test_name="self-reference-only scan exits cleanly"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "$test_name" "$tmpdir" \
		"${tmpdir}/.agents/reference" "${tmpdir}/.agents/scripts" || return 0
	printf '%s\n' 'Documented IOC: router_''init.js and gh-token-''monitor.' \
		>"${tmpdir}/.agents/reference/npm-supply-chain-response.md"
	printf '%s\n' 'readonly IOC_PATTERN="router_''init.js|gh-token-''monitor"' \
		>"${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh"

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] &&
		[[ "$output" == *"known-safe scanner self-reference"* ]] &&
		[[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_relative_self_reference_only_scan_succeeds() {
	local test_name="relative self-reference-only scan exits cleanly"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "$test_name" "$tmpdir" \
		"${tmpdir}/.agents/reference" "${tmpdir}/.agents/scripts" || return 0
	printf '%s\n' 'Documented IOC: router_''init.js and gh-token-''monitor.' \
		>"${tmpdir}/.agents/reference/npm-supply-chain-response.md"
	printf '%s\n' 'readonly IOC_PATTERN="router_''init.js|gh-token-''monitor"' \
		>"${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh"

	local output
	local status=0
	output=$(cd "$tmpdir" && HOME="$tmpdir" bash "$HELPER_SCRIPT" scan .agents 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] &&
		[[ "$output" == *"known-safe scanner self-reference"* ]] &&
		[[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_single_file_self_reference_only_scan_succeeds() {
	local test_name="single-file self-reference-only scan exits cleanly"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "$test_name" "$tmpdir" \
		"${tmpdir}/.agents/scripts" || return 0
	printf '%s\n' 'readonly IOC_PATTERN="router_''init.js|gh-token-''monitor"' \
		>"${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh"

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh" 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] &&
		[[ "$output" == *"known-safe scanner self-reference"* ]] &&
		[[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_non_self_ioc_scan_fails() {
	local test_name="non-self IOC scan still fails"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "$test_name" "$tmpdir" "${tmpdir}/docs" || return 0
	printf '%s\n' 'Suspicious artifact: router_''init.js' >"${tmpdir}/docs/evidence.md"

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 1 ]] &&
		[[ "$output" == *"docs/evidence.md"* ]] &&
		[[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_similar_agents_suffix_ioc_scan_fails() {
	local test_name="similarly named agents directory still fails"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	if ! prepare_test_dirs "$test_name" "$tmpdir" \
		"${tmpdir}/not.agents/reference"; then
		return 0
	fi
	if ! printf '%s\n' 'Suspicious artifact: router_''init.js' >"${tmpdir}/not.agents/reference/npm-supply-chain-response.md"; then
		print_result "$test_name" 1 "fixture write failed"
		cleanup_test_tmpdir "$tmpdir"
		return 0
	fi

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 1 ]] &&
		[[ "$output" == *"not.agents/reference/npm-supply-chain-response.md"* ]] &&
		[[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_keyv_preinstall_ioc_scan_fails() {
	local test_name="Keyv preinstall IOC fails"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	printf '%s\n' '{"scripts":{"preinstall":"node setup.mjs"}}' >"${tmpdir}/package.json"
	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 1 ]] && [[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_known_malware_hash_scan_fails() {
	local test_name="known malware hash fails"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "$test_name" "$tmpdir" "${tmpdir}/bin" || return 0
	printf '%s\n' 'export const benign = true;' >"${tmpdir}/setup.mjs"
	printf '%s\n' '#!/usr/bin/env bash' \
		'printf '\''%s  fixture\n'\'' '\''54dc7ea54a1317cca0e890a2770630cf7fa6c97813e0cb9d2caa93012b350668'\''' \
		>"${tmpdir}/bin/shasum"
	chmod +x "${tmpdir}/bin/shasum"

	local output
	local status=0
	output=$(PATH="${tmpdir}/bin:${PATH}" HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 1 ]] &&
		[[ "$output" == *"Known malware hash: ${tmpdir}/setup.mjs"* ]] &&
		[[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_malware_hash_count_does_not_wrap() {
	local test_name="malware hash count does not wrap at 256"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "$test_name" "$tmpdir" "${tmpdir}/bin" || return 0
	printf '%s\n' '#!/usr/bin/env bash' \
		'printf '\''%s  fixture\n'\'' '\''54dc7ea54a1317cca0e890a2770630cf7fa6c97813e0cb9d2caa93012b350668'\''' \
		>"${tmpdir}/bin/shasum"
	chmod +x "${tmpdir}/bin/shasum"
	local index=1
	while [[ "$index" -le 256 ]]; do
		mkdir -p "${tmpdir}/candidate-${index}"
		printf '%s\n' 'export const benign = true;' >"${tmpdir}/candidate-${index}/setup.mjs"
		index=$((index + 1))
	done

	local output
	local status=0
	output=$(PATH="${tmpdir}/bin:${PATH}" HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	local hash_matches=0
	local output_line
	while IFS= read -r output_line; do
		if [[ "$output_line" == *"Known malware hash:"* ]]; then
			hash_matches=$((hash_matches + 1))
		fi
	done <<<"$output"
	if [[ "$status" -eq 1 ]] && [[ "$hash_matches" -eq 256 ]] &&
		[[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} hash_matches=${hash_matches}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_keyv_bun_runtime_iocs_scan_fail() {
	local test_name="Keyv Bun runtime IOCs fail"
	local ioc
	for ioc in '/tmp/bun-dl-a1b2/bun' 'User-Agent: Bun/1.3.13'; do
		local tmpdir
		tmpdir=$(make_tmpdir) || {
			print_result "$test_name" 1 "mktemp failed"
			return 0
		}
		printf '%s\n' "$ioc" >"${tmpdir}/runtime.log"

		local output
		local status=0
		output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
		if [[ "$status" -ne 1 ]] || [[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
			print_result "$test_name" 1 "ioc=${ioc} status=${status} output=${output}"
			cleanup_test_tmpdir "$tmpdir"
			return 0
		fi
		cleanup_test_tmpdir "$tmpdir"
	done
	print_result "$test_name" 0
	return 0
}

test_nearby_bun_runtime_strings_scan_succeed() {
	local test_name="nearby Bun runtime strings remain clean"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	printf '%s\n' '/tmp/bun-dl-/bun' 'User-Agent: Bun/1.3.130' >"${tmpdir}/runtime.log"
	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] && [[ "$output" == *"No known Shai-Hulud indicators"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

test_benign_matching_basenames_scan_succeeds() {
	local test_name="benign matching basenames remain clean"
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "$test_name" 1 "mktemp failed"
		return 0
	}

	printf '%s\n' 'export const benign = true;' >"${tmpdir}/setup.mjs"
	printf '%s\n' 'module.exports = "unicode category";' >"${tmpdir}/Math_Symbol.js"
	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] && [[ "$output" == *"No known Shai-Hulud indicators"* ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "status=${status} output=${output}"
	fi
	cleanup_test_tmpdir "$tmpdir"
	return 0
}

main() {
	test_cleanup_test_tmpdir_rejects_unsafe_paths
	test_self_reference_only_scan_succeeds
	test_relative_self_reference_only_scan_succeeds
	test_single_file_self_reference_only_scan_succeeds
	test_non_self_ioc_scan_fails
	test_similar_agents_suffix_ioc_scan_fails
	test_keyv_preinstall_ioc_scan_fails
	test_known_malware_hash_scan_fails
	test_malware_hash_count_does_not_wrap
	test_keyv_bun_runtime_iocs_scan_fail
	test_nearby_bun_runtime_strings_scan_succeed
	test_benign_matching_basenames_scan_succeeds

	printf '\nTests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
