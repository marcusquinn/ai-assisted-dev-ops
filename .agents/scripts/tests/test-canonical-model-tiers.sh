#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Prevent provider/model-family names from returning as workload tiers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

failures=0

check_absent() {
	local description="$1"
	local pattern="$2"
	shift 2
	local matches=""
	local rc=0
	matches=$(rg -n -e "$pattern" "$@" 2>&1) || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		printf '%s\n' "$matches"
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL: %s (rg exited %d: %s)\n' "$description" "$rc" "$matches" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}

check_present() {
	local description="$1"
	local pattern="$2"
	shift 2
	local rc=0
	rg -q -e "$pattern" "$@" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS: %s\n' "$description"
		return 0
	fi
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL: %s (rg exited %d)\n' "$description" "$rc" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'FAIL: %s\n' "$description" >&2
	failures=$((failures + 1))
	return 0
}

check_frontmatter_tiers() {
	local description="agent frontmatter uses only canonical workload tiers"
	local matches=""
	matches=$(git ls-files '*.md' | while IFS= read -r file; do
		awk '
			FNR == 1 {
				if ($0 != "---") exit
				next
			}
			$0 == "---" { exit }
			$0 ~ /^model(-tier)?:[[:space:]]*(haiku|sonnet|opus|flash|pro|composer2)([[:space:]]*(#.*)?)$/ {
				print FILENAME ":" FNR ":" $0
			}
		' "$file"
	done)
	if [[ -n "$matches" ]]; then
		printf '%s\n' "$matches"
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}

check_frontmatter_tiers

check_absent \
	"documentation does not describe provider families as tiers" \
	'\b(haiku|sonnet|opus|flash|pro|composer2)[ -]tier\b|\btier[ :_-]+(haiku|sonnet|opus|flash|pro|composer2)\b' \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

check_absent \
	"canonical task taxonomy does not hardcode provider families" \
	'\b(Haiku|Sonnet|Opus|Flash|Pro|Composer2)\b' \
	.agents/reference/task-taxonomy.md

for tier in simple standard thinking; do
	check_present \
		"canonical task taxonomy includes $tier workload tier" \
		"^\\| $tier \\| .*tier:$tier.*\\|" \
		.agents/reference/task-taxonomy.md
done

tier_policy_surfaces=(
	.agents/reference/task-taxonomy.md
	.agents/templates/brief-template.md
	.agents/workflows/brief.md
	.agents/workflows/define.md
	.agents/workflows/route.md
)
check_absent \
	"tier assignment surfaces do not restore retired numeric proxy gates" \
	'>[[:space:]]*2 files|>[[:space:]]*4 acceptance|[Ee]stimate >1h|[Ss]ingle file.*tier:simple|2-3 files with coordination|[Ee]very target file under 500' \
	"${tier_policy_surfaces[@]}"

check_absent \
	"tier assignment surfaces stay provider and relative-cost independent" \
	'\b(Haiku|Sonnet|Opus|Terra|Luna|Sol)\b|Relative cost|vs sonnet baseline' \
	"${tier_policy_surfaces[@]}"

model_registry=.agents/scripts/model-registry-helper.sh
classifier_src=$(awk '/^_route_classify_tier\(\) \{/,/^}$/ { print }' "$model_registry")
if [[ -z "$classifier_src" ]]; then
	printf 'FAIL: model registry tier classifier could not be extracted\n' >&2
	failures=$((failures + 1))
else
	# shellcheck disable=SC1090,SC1091  # evaluated repository function under test
	eval "$classifier_src"
	check_route_tier() {
		local description="$1"
		local expected="$2"
		local tier reason compute
		_route_classify_tier "$description" tier reason compute
		if [[ "$tier" == "$expected" ]]; then
			printf 'PASS: route %s -> %s\n' "$description" "$expected"
			return 0
		fi
		printf 'FAIL: route %s expected %s, got %s (%s)\n' "$description" "$expected" "$tier" "$reason" >&2
		failures=$((failures + 1))
		return 0
	}

	check_route_tier "rename variable_x to variable_y" "simple"
	check_route_tier "summarize this document without recommendations" "simple"
	check_route_tier "replace secret_old with secret_new in a test fixture" "simple"
	check_route_tier "replace auth_old with auth_new in the authorization test fixture" "simple"
	check_route_tier "replace allow_all with require_admin in production authorization middleware" "standard"
	check_route_tier "replace allow_all with require_admin in production authorization middleware and update the test fixture" "standard"
	check_route_tier "replace credential_old with credential_new in production config and update mock data" "standard"
	check_route_tier "replace retry_old with retry_new and decide whether to add fallback" "standard"
	check_route_tier "consolidate issue tier tagging policy across dispatch surfaces" "standard"
	check_route_tier "implement decided authentication validation using the existing middleware pattern" "standard"
	check_route_tier "design authentication trust boundaries and compare trade-offs" "thinking"
	check_route_tier "perform a security audit of the authorization architecture" "thinking"
	check_route_tier "refactor the entire project around a new abstraction" "thinking"
fi

check_absent \
	"framework configuration contains no legacy tier values" \
	'"(haiku|sonnet|opus|flash|pro|composer2)"' \
	.agents/configs .agents/bundles --glob '*.{json,jsonc}'

check_absent \
	"dispatch tracking labels use canonical tiers" \
	'(dispatched|implemented|retried|failed):(haiku|sonnet|opus|flash|pro|composer2)\b' \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

legacy_pin_pattern='model:'"opus-4-7|AIDEVOPS_"'OPUS_ESCALATION_MODEL'
check_absent \
	"dispatch metadata does not pin a concrete model label" \
	"$legacy_pin_pattern" \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

check_absent \
	"legacy tier-specific reasoning environment variables are absent" \
	'AIDEVOPS_HEADLESS_VARIANT_(HAIKU|SONNET|OPUS|FLASH|PRO)' \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

manual_dispatch_surfaces=(
	.agents/scripts/commands/dispatch-issue.md
	.agents/scripts/dispatch-single-issue-helper.sh
)
check_absent \
	"manual dispatch command surfaces do not recommend a provider-specific model pin" \
	'--model[[:space:]]+[[:alnum:]_.-]+/[[:alnum:]_.-]+' \
	"${manual_dispatch_surfaces[@]}"

check_absent \
	"launch-worker examples do not recommend a provider-specific model pin" \
	'aidevops launch-worker[^\r\n]*--model[[:space:]]+[[:alnum:]_.-]+/[[:alnum:]_.-]+' \
	.agents/reference/worker-diagnostics.md

check_present \
	"manual dispatch command guidance recommends canonical workload tiers" \
	'tier:simple.*tier:standard.*tier:thinking' \
	.agents/scripts/commands/dispatch-issue.md

check_present \
	"manual dispatch help recommends canonical workload tiers" \
	'tier:simple.*tier:standard.*tier:thinking' \
	.agents/scripts/dispatch-single-issue-helper.sh

check_present \
	"command docs mark exact model overrides as advanced compatibility behavior" \
	'[Aa]dvanced compatibility override' \
	.agents/scripts/commands/dispatch-issue.md

check_present \
	"CLI help marks exact model overrides as advanced compatibility behavior" \
	'[Aa]dvanced compatibility override' \
	.agents/scripts/dispatch-single-issue-helper.sh

actual_tiers=$(jq -r '.tiers | keys | sort | join(",")' .agents/configs/model-routing-table.json || true)
if [[ "$actual_tiers" == "simple,standard,thinking" ]]; then
	printf 'PASS: routing table exposes exactly three workload tiers\n'
else
	printf 'FAIL: routing table tiers are %s\n' "$actual_tiers" >&2
	failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d canonical tier check(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll canonical workload tier checks passed\n'
