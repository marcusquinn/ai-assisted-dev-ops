#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../shared-constants.sh
source "$REPO_ROOT/.agents/scripts/shared-constants.sh"

fail=0
assert_eq() {
	local description="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS: %s\n' "$description"
	else
		printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
		fail=$((fail + 1))
	fi
}

assert_eq "pin version is explicit" "1.18.23" "$OPENCODE_PINNED_VERSION"
assert_eq "pin platform is scoped" "Linux" "$OPENCODE_PIN_PLATFORM"
assert_eq "pin runtime is scoped" "headless" "$OPENCODE_PIN_RUNTIME_MODE"
assert_eq "introduction date is recorded" "2026-07-30" "$OPENCODE_PIN_INTRODUCED_DATE"
assert_eq "last canary is recorded" "2026-08-25" "$OPENCODE_PIN_LAST_CANARY_DATE"
assert_eq "review deadline is recorded" "2026-09-01" "$OPENCODE_PIN_REVIEW_DEADLINE"
assert_eq "plugin compatibility signal is explicit" "1.18.23" "$OPENCODE_PLUGIN_TESTED_VERSION"

scope_rc=0
aidevops_opencode_pin_applies Linux headless || scope_rc=$?
assert_eq "Linux headless remains fail-closed" "0" "$scope_rc"
scope_rc=0
aidevops_opencode_pin_applies Darwin headless || scope_rc=$?
assert_eq "macOS headless is outside observed scope" "1" "$scope_rc"
scope_rc=0
aidevops_opencode_pin_applies Linux interactive || scope_rc=$?
assert_eq "interactive setup is outside observed scope" "1" "$scope_rc"

status=$(
	PATH="/usr/bin:/bin" "$REPO_ROOT/.agents/scripts/opencode-pin-canary.sh" status
)
[[ "$status" == *"pinned=1.18.23"* && "$status" == *"registry-latest="* && "$status" == *"plugin-tested=1.18.23"* && "$status" == *"last-canary=2026-08-25"* ]] || {
	printf 'FAIL: status omits compatibility evidence: %s\n' "$status" >&2
	fail=$((fail + 1))
}

workflow="$REPO_ROOT/.github/workflows/opencode-pin-canary.yml"
canary_script="$REPO_ROOT/.agents/scripts/opencode-pin-canary.sh"
if grep -q 'persist-credentials: false' "$workflow" && grep -q 'record-review:' "$workflow" &&
	grep -q 'needs: linux-headless-canary' "$workflow" &&
	grep -q 'actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0' "$workflow"; then
	printf 'PASS: candidate execution is separated from the issue-write token\n'
else
	printf 'FAIL: candidate execution can retain or reach repository write credentials\n' >&2
	fail=$((fail + 1))
fi
if grep -q 'env -i' "$canary_script" && grep -q 'GIT_CONFIG_GLOBAL=/dev/null' "$canary_script" &&
	grep -q 'npm_config_userconfig=/dev/null' "$canary_script" &&
	grep -q 'npm ci --ignore-scripts --no-audit --no-fund' "$canary_script"; then
	printf 'PASS: package installation and candidate execution use isolated environments\n'
else
	printf 'FAIL: candidate execution is not explicitly isolated from user credentials/config\n' >&2
	fail=$((fail + 1))
fi
if grep -q 'run_isolated_probe "baseline-' "$canary_script" &&
	grep -q 'run_isolated_probe "candidate-' "$canary_script" &&
	grep -q 'canary-local-only' "$canary_script" && grep -q 'small_model:' "$canary_script" &&
	grep -q 'AIDEVOPS_MODEL_ROUTING_TABLE=' "$canary_script" && grep -q "'^RESULT=pass\$'" "$workflow"; then
	printf 'PASS: promotion requires a credential-free same-revision baseline and candidate pass\n'
else
	printf 'FAIL: promotion lacks a credential-free same-revision comparison gate\n' >&2
	fail=$((fail + 1))
fi
if grep -q 'cron:' "$workflow" && grep -q "title=\"Promote passing OpenCode compatibility candidate\"" "$workflow"; then
	printf 'PASS: scheduled passing candidates create a promotion review\n'
else
	printf 'FAIL: scheduled passing-candidate promotion path is missing\n' >&2
	fail=$((fail + 1))
fi
if grep -q "title=\"OpenCode compatibility pin review is due\"" "$workflow" &&
	grep -q 'Retain the current fail-closed pin after failed or inconclusive results' "$workflow"; then
	printf 'PASS: failed or inconclusive canaries retain the pin and create review work\n'
else
	printf 'FAIL: failed-canary retention path is missing\n' >&2
	fail=$((fail + 1))
fi

exit "$fail"
