#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

custom_table="${TEST_ROOT}/routing.json"
cat >"$custom_table" <<'JSON'
{
  "tiers": {
    "standard": {
      "models": ["custom/standard"],
      "reasoning": {"custom": "xhigh"}
    }
  }
}
JSON

export AIDEVOPS_MODEL_ROUTING_TABLE="$custom_table"
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

[[ "$(model_tier_candidates standard)" == "custom/standard" ]]
[[ "$(model_tier_candidates simple | sed -n '1p')" == "openai/gpt-5.6-luna" ]]
[[ "$(model_tier_variant simple openai/gpt-5.6-luna)" == "max" ]]
[[ "$(model_tier_next simple)" == "standard" ]]

cat >"$custom_table" <<'JSON'
{"tiers":{"simple":{"reasoning":{"openai/gpt-5.6-luna":""}}}}
JSON
[[ -z "$(model_tier_variant simple openai/gpt-5.6-luna)" ]]

# shellcheck source=../fallback-chain-helper.sh
source "${SCRIPTS_DIR}/fallback-chain-helper.sh"
is_model_available() {
	return 0
}
[[ "$(cmd_resolve simple --quiet)" == "openai/gpt-5.6-luna" ]]

cat >"$custom_table" <<'JSON'
{"tiers":{"simple":{"models":[]}}}
JSON
if model_tier_candidates simple >/dev/null 2>&1; then
	printf 'FAIL: explicit empty tier did not disable framework inheritance\n' >&2
	exit 1
fi

cat >"$custom_table" <<'JSON'
{"tiers":{"standard":{"models":[]}}}
JSON
[[ "$(model_tier_next simple)" == "thinking" ]]

printf 'PASS: partial shell routing overrides inherit unspecified framework tiers\n'
