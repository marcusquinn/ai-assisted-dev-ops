#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
SCRIPT_DIR="$repo_root/.agents/scripts"
route_table="$repo_root/.agents/configs/model-routing-table.json"
workflow="$repo_root/.agents/workflows/cross-review.md"
failures=0

# shellcheck source=../compare-models-cross-review-lib.sh
source "$SCRIPT_DIR/compare-models-cross-review-lib.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	failures=$((failures + 1))
	return 0
}

default_models=$(_cross_review_models_for_tier standard) ||
	fail "standard tier should provide a default comparison set"
expected_models=$(jq -r '.tiers.standard.models | join(",")' "$route_table")
if [[ "$default_models" != "$expected_models" ]]; then
	fail "default comparison set should come directly from the standard routing tier"
fi

IFS=',' read -r -a model_array <<<"$default_models"
if [[ "${#model_array[@]}" -lt 2 ]]; then
	fail "default comparison should include at least two standard-tier models"
fi

for model in "${model_array[@]}"; do
	if ! jq -e --arg model "$model" '.tiers.standard.models | index($model) != null' \
		"$route_table" >/dev/null; then
		fail "$model is not in the standard routing tier"
	fi
	if ! model_key=$(_cross_review_model_key "$model"); then
		fail "$model should produce a safe result key"
		continue
	fi
	if [[ "$model_key" == *"/"* ]]; then
		fail "$model produced a path-unsafe result key"
	fi
done

provider_key=$(_cross_review_model_key "openai/gpt-5.6-sol") ||
	fail "provider-qualified model IDs should be accepted"
if [[ "$provider_key" != "openai%2Fgpt-5.6-sol" ]]; then
	fail "provider-qualified model IDs should have deterministic result keys"
fi
slash_key=$(_cross_review_model_key "provider/model") || fail "slash model key should resolve"
flat_key=$(_cross_review_model_key "provider--model") || fail "flat model key should resolve"
if [[ "$slash_key" == "$flat_key" ]]; then
	fail "distinct model identifiers should not collide in result paths"
fi
upper_key=$(_cross_review_model_key "Provider/model") || fail "uppercase model key should resolve"
lower_key=$(_cross_review_model_key "provider/model") || fail "lowercase model key should resolve"
if [[ "$upper_key" == "$lower_key" ]]; then
	fail "result paths should remain distinct on case-insensitive filesystems"
fi
model_runner=$(_cross_review_runner_name model 1) || fail "model runner name should resolve"
judge_runner=$(_cross_review_runner_name judge 0) || fail "judge runner name should resolve"
for runner_name in "$model_runner" "$judge_runner"; do
	if [[ ! "$runner_name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
		fail "$runner_name is not compatible with runner-helper validation"
	fi
	if [[ "${#runner_name}" -gt 40 ]]; then
		fail "$runner_name exceeds runner-helper's length limit"
	fi
done

if _cross_review_model_key "../escape" >/dev/null; then
	fail "path traversal should be rejected as a model identifier"
fi
if _cross_review_models_for_tier legacy >/dev/null; then
	fail "legacy provider-family tiers should be rejected"
fi
if rg -Fq 'models_str="sonnet,opus"' "$SCRIPT_DIR/compare-models-cross-review-lib.sh"; then
	fail "cross-review should not default to one provider family's aliases"
fi
if ! rg -Fq "same prompt, context, tools, timeout, and" "$workflow"; then
	fail "cross-review guidance should require like-for-like evaluation context"
fi

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d cross-review tier contract check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'PASS: cross-review uses like-for-like standard-tier defaults\n'
