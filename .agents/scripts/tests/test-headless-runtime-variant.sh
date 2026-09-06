#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load the same routing dependency as the production headless entrypoint.
# shellcheck source=/dev/null
source "${AGENTS_SCRIPTS}/shared-constants.sh"
# shellcheck source=/dev/null
source "${AGENTS_SCRIPTS}/headless-runtime-model.sh"

failures=0

assert_equals() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$message" "$expected" "$actual" >&2
		failures=$((failures + 1))
		return 1
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

with_clean_variant_env() {
	unset AIDEVOPS_HEADLESS_VARIANT || true
	unset AIDEVOPS_HEADLESS_VARIANT_SIMPLE || true
	unset AIDEVOPS_HEADLESS_VARIANT_STANDARD || true
	unset AIDEVOPS_HEADLESS_VARIANT_THINKING || true
	unset AIDEVOPS_HEADLESS_WORKER_VARIANT || true
	unset AIDEVOPS_HEADLESS_PULSE_VARIANT || true
	return 0
}

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_STANDARD="high"
actual=$(resolve_headless_variant "worker" "standard" "openai/gpt-5.5")
assert_equals "" "$actual" "GPT-5.5 standard worker omits env-derived high variant" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_STANDARD="high"
actual=$(resolve_headless_variant "worker" "standard" "openai/gpt-5.4")
assert_equals "high" "$actual" "non-GPT-5.5 standard worker keeps high variant" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_THINKING="xhigh"
actual=$(resolve_headless_variant "worker" "thinking" "openai/gpt-5.5")
assert_equals "xhigh" "$actual" "GPT-5.5 thinking worker keeps configured variant" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_STANDARD="high"
actual=$(resolve_headless_variant "pulse" "standard" "openai/gpt-5.5")
assert_equals "high" "$actual" "pulse standard routing keeps configured variant" || true

with_clean_variant_env
actual=$(resolve_headless_variant "worker" "simple" "openai/gpt-5.6-luna")
assert_equals "low" "$actual" "GPT-5.6 Luna simple worker uses low routed effort" || true

with_clean_variant_env
actual=$(resolve_headless_variant "worker" "standard" "openai/gpt-5.6-terra")
assert_equals "low" "$actual" "GPT-5.6 Terra standard worker uses low routed effort" || true

with_clean_variant_env
actual=$(resolve_headless_variant "worker" "thinking" "openai/gpt-5.6-sol")
assert_equals "medium" "$actual" "GPT-5.6 Sol thinking worker uses medium routed effort" || true

with_clean_variant_env
actual=$(resolve_headless_variant "worker" "thinking" "openai/gpt-5.6-sol-fast")
assert_equals "" "$actual" "unmapped Sol Fast ID does not inherit another model's reasoning" || true

with_clean_variant_env
actual=$(resolve_headless_variant "worker" "standard" "openai/gpt-5.6-sol")
assert_equals "" "$actual" "Sol outside its configured tier does not inherit Terra reasoning" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_THINKING="high"
actual=$(resolve_headless_variant "worker" "thinking" "openai/gpt-5.6-sol")
assert_equals "high" "$actual" "explicit GPT-5.6 Sol high variant remains stable" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_THINKING="max"
actual=$(resolve_headless_variant "worker" "thinking" "openai/gpt-5.6-sol")
assert_equals "max" "$actual" "explicit GPT-5.6 Sol max opt-in remains available" || true

with_clean_variant_env
AIDEVOPS_HEADLESS_VARIANT_THINKING="xhigh"
actual=$(resolve_headless_variant "worker" "thinking" "openai/gpt-5.6-sol")
assert_equals "xhigh" "$actual" "explicit GPT-5.6 Sol xhigh opt-in remains available" || true

with_clean_variant_env
actual=$(resolve_headless_variant "pulse" "thinking" "openai/gpt-5.6-sol")
assert_equals "medium" "$actual" "pulse thinking tier uses the same medium runtime mapping" || true

with_clean_variant_env

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d variant regression test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll headless runtime variant tests passed\n'
exit 0
