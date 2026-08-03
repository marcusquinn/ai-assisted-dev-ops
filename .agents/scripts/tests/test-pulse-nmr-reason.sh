#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
FILTER="${SCRIPT_DIR}/../pulse-nmr-reason.jq"
TESTS_RUN=0
TESTS_FAILED=0

assert_reason() {
	local name="$1"
	local comments_json="$2"
	local expected="$3"
	local actual=""
	TESTS_RUN=$((TESTS_RUN + 1))
	actual=$(printf '%s' "$comments_json" | jq -c --argjson revalidate 3600 -f "$FILTER")
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

authority='{"code":"authority","class":"genuine-authority","source":"default","revalidate_after_seconds":null,"requires_crypto":true}'
billing='{"code":"billing","class":"genuine-authority","source":"legacy-marker","revalidate_after_seconds":null,"requires_crypto":true}'
cost_limit='{"code":"cost_limit","class":"temporary","source":"legacy-marker","revalidate_after_seconds":3600,"requires_crypto":false}'
diagnostic='{"code":"diagnostic_ambiguity","class":"temporary","source":"legacy-marker","revalidate_after_seconds":3600,"requires_crypto":false}'
structured='{"code":"billing","class":"genuine-authority","source":"structured-marker","revalidate_after_seconds":null,"requires_crypto":true}'

# shellcheck disable=SC2016 # Backticks are literal Markdown fixture content.
assert_reason "ops prose does not impersonate breaker marker" \
	'[[{"body":"<!-- ops:start -->\nBelow threshold mentions `cost-circuit-breaker:no_work_loop` as documentation.\n<!-- ops:end -->"}],[{"body":"<!-- ops:start -->\n<!-- stale-recovery-tick:escalated (threshold=2) -->\n<!-- ops:end -->"}]]' \
	"$diagnostic"

assert_reason "latest exact marker determines legacy reason" \
	'[{"body":"<!-- cost-circuit-breaker:fired tier=standard -->"},{"body":"<!-- stale-recovery-tick:escalated -->"}]' \
	"$diagnostic"

assert_reason "generated decision packet is not classifier evidence" \
	'[{"body":"<!-- nmr-decision-packet reason=billing -->\nReason: billing"},{"body":"<!-- stale-recovery-tick:escalated -->"}]' \
	"$diagnostic"

assert_reason "unrelated billing prose remains fail-closed authority" \
	'[{"body":"Documentation discusses billing and spend approval without an NMR marker."}]' \
	"$authority"

assert_reason "no-work cost breaker remains structural" \
	'[{"body":"<!-- cost-circuit-breaker:no_work_loop count=3 -->"}]' \
	"$diagnostic"

assert_reason "cost limit breaker remains structural" \
	'[{"body":"<!-- cost-circuit-breaker:fired tier=thinking -->"}]' \
	"$cost_limit"

assert_reason "explicit billing approval remains genuine authority" \
	'[{"body":"<!-- billing-approval-required -->"}]' \
	"$billing"

assert_reason "structured marker overrides later legacy marker" \
	'[{"body":"<!-- nmr-reason code=billing class=genuine-authority -->"},{"body":"<!-- stale-recovery-tick:escalated -->"}]' \
	"$structured"

printf '\n%d tests run, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
