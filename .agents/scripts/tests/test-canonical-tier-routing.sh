#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify canonical workload-tier routing and escalation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENTS_SCRIPTS="$REPO_ROOT/.agents/scripts"

tests_run=0
tests_passed=0

assert_equals() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	tests_run=$((tests_run + 1))
	if [[ "$expected" == "$actual" ]]; then
		tests_passed=$((tests_passed + 1))
		printf 'PASS: %s\n' "$name"
		return 0
	fi
	printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
	return 1
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local name="$3"
	tests_run=$((tests_run + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		tests_passed=$((tests_passed + 1))
		printf 'PASS: %s\n' "$name"
		return 0
	fi
	printf 'FAIL: %s\n  missing: %s\n' "$name" "$needle"
	return 1
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

cat >"$sandbox/model-availability-helper.sh" <<'HELPER'
#!/usr/bin/env bash
if [[ "${1:-}" != "resolve" ]]; then
	exit 1
fi
case "${2:-}" in
simple) printf '%s' "openai/gpt-5.6-luna" ;;
standard) printf '%s' "openai/gpt-5.6-luna" ;;
thinking) printf '%s' "openai/gpt-5.6-sol" ;;
*) exit 1 ;;
esac
exit 0
HELPER
chmod +x "$sandbox/model-availability-helper.sh"

export MODEL_AVAILABILITY_HELPER="$sandbox/model-availability-helper.sh"

# shellcheck source=/dev/null
source "$AGENTS_SCRIPTS/pulse-model-routing.sh"

assert_equals "openai/gpt-5.6-luna" \
	"$(resolve_dispatch_model_for_labels 'tier:simple')" \
	"simple tier resolves through runtime mapping"
assert_equals "openai/gpt-5.6-luna" \
	"$(resolve_dispatch_model_for_labels 'tier:standard')" \
	"standard tier resolves through runtime mapping"
assert_equals "openai/gpt-5.6-sol" \
	"$(resolve_dispatch_model_for_labels 'tier:thinking')" \
	"thinking tier resolves through runtime mapping"
assert_equals "" \
	"$(resolve_dispatch_model_for_labels '')" \
	"missing tier leaves fallback selection to the caller"

cat >"$sandbox/gh" <<'STUB'
#!/usr/bin/env bash
args=("$@")
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "view" ]]; then
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [[ "${args[i]}" == "--jq" ]]; then
			case "${args[i + 1]:-}" in
			*labels*) printf '%s' "${CURRENT_LABELS:-}"; exit 0 ;;
			*body*) printf '%s' "${ISSUE_BODY:-}"; exit 0 ;;
			esac
		fi
	done
fi
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "edit" ]]; then
	printf '%s\n' "${args[*]}" >>"${GH_EDIT_TRACE:-/dev/null}"
	exit 0
fi
exit 0
STUB
chmod +x "$sandbox/gh"
export PATH="$sandbox:$PATH"

# shellcheck source=/dev/null
source "$AGENTS_SCRIPTS/worker-lifecycle-common.sh"

run_escalate() {
	local current_labels="$1"
	local failure_count="${2:-2}"
	local trace
	trace=$(mktemp)
	GH_EDIT_TRACE="$trace" CURRENT_LABELS="$current_labels" \
		ISSUE_BODY=$'## How\nEDIT: .agents/scripts/pulse-model-routing.sh:29-61' \
		escalate_issue_tier 99 "test/repo" "$failure_count" \
		"repeated_failure" "partial" >/dev/null 2>&1 || true
	if [[ -s "$trace" ]]; then
		while IFS= read -r line; do
			printf '%s\n' "$line"
		done <"$trace"
	fi
	rm -f "$trace"
	return 0
}

trace=$(run_escalate "tier:thinking")
assert_equals "" "$trace" "thinking is the terminal workload tier"

trace=$(run_escalate "tier:standard")
assert_contains "$trace" "--add-label tier:thinking" \
	"standard escalates to thinking"
assert_contains "$trace" "--remove-label tier:standard" \
	"standard label is replaced during escalation"

trace=$(run_escalate "tier:simple")
assert_contains "$trace" "--add-label tier:standard" \
	"simple escalates to standard"
assert_contains "$trace" "--remove-label tier:simple" \
	"simple label is replaced during escalation"

trace=$(run_escalate "tier:standard" 1)
assert_equals "" "$trace" "sub-threshold failures do not escalate"

printf '\nTests passed: %s / %s\n' "$tests_passed" "$tests_run"
[[ "$tests_passed" -eq "$tests_run" ]]
