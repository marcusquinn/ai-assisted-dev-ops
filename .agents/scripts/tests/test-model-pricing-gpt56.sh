#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../shared-constants.sh"

assert_equals() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$message" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_equals "10.0|50.0|1.0|12.50" "$(get_model_pricing openai/gpt-6-astra)" "Astra JSON pricing"
assert_equals "4.0|20.0|0.40|5.0" "$(get_model_pricing openai/gpt-5.6-sol)" "Sol JSON pricing"
assert_equals "2.0|12.0|0.20|2.50" "$(get_model_pricing openai/gpt-5.6-terra)" "Terra JSON pricing"
assert_equals "0.20|1.20|0.02|0.25" "$(get_model_pricing openai/gpt-5.6-luna)" "Luna JSON pricing"
assert_equals "3.0|15.0|0.30|3.75" "$(get_model_pricing openai/gpt-5.6-sol-pro)" "Sol Pro uses unknown-model default"

_MODEL_PRICING_JSON_LOADED=1
_MODEL_PRICING_JSON=""

assert_equals "10.0|50.0|1.0|12.50" "$(get_model_pricing openai/gpt-6-astra)" "Astra hardcoded fallback pricing"
assert_equals "4.0|20.0|0.40|5.0" "$(get_model_pricing openai/gpt-5.6-sol)" "Sol hardcoded fallback pricing"
assert_equals "2.0|12.0|0.20|2.50" "$(get_model_pricing openai/gpt-5.6-terra)" "Terra hardcoded fallback pricing"
assert_equals "0.20|1.20|0.02|0.25" "$(get_model_pricing openai/gpt-5.6-luna)" "Luna hardcoded fallback pricing"
assert_equals "3.0|15.0|0.30|3.75" "$(get_model_pricing openai/gpt-5.6-sol-pro)" "Sol Pro hardcoded unknown-model default"

exit 0
