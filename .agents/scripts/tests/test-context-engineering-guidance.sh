#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
architecture="$repo_root/.agents/aidevops/architecture.md"
self_purpose="$repo_root/.agents/aidevops/purpose.md"
self_improvement="$repo_root/.agents/reference/self-improvement.md"
failures=0

assert_contains() {
	local description="$1"
	local needle="$2"
	local file="$3"

	if ! rg -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi

	printf 'PASS: %s\n' "$description"
	return 0
}

assert_absent() {
	local description="$1"
	local needle="$2"
	local file="$3"

	if rg -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi

	printf 'PASS: %s\n' "$description"
	return 0
}

assert_contains \
	"architecture assigns open-ended decisions to model judgment" \
	"Use model judgment for open-ended decisions" \
	"$architecture"
assert_contains \
	"architecture retains deterministic enforcement" \
	"Deterministic hooks, validators, wrappers, and CI checks should enforce syntax" \
	"$architecture"
assert_contains \
	"architecture distinguishes judgment from mechanics" \
	"If reasonable models could choose differently" \
	"$architecture"
assert_contains \
	"architecture routes instruction changes through Agent Review" \
	".agents/tools/build-agent/agent-review.md" \
	"$architecture"
assert_absent \
	"architecture no longer rejects every script-based fix" \
	"Fix adds a \`.sh\` file or state mechanism" \
	"$architecture"
assert_absent \
	"architecture no longer defaults every model error to prose" \
	"When the agent errs, fix the guidance — not a new script" \
	"$architecture"

assert_contains \
	"canonical purpose defines the 100x target as an ambition" \
	"guaranteed or measured result" \
	"$self_purpose"
assert_contains \
	"architecture inherits the canonical purpose" \
	".agents/aidevops/purpose.md" \
	"$architecture"

assert_contains \
	"self-improvement work stays within established authority" \
	"within the established objective, authority" \
	"$self_improvement"
assert_contains \
	"safe in-scope process defects are repaired now" \
	"repair safe, authorised, in-scope process defects" \
	"$self_improvement"
assert_contains \
	"self-improvement selects deterministic enforcement for mechanics" \
	"Select deterministic enforcement for reproducible mechanics" \
	"$self_improvement"
assert_contains \
	"continuation authority is bounded" \
	"authorises continued progress on the current" \
	"$self_improvement"
assert_contains \
	"publication and consequential actions remain excluded" \
	"This does not authorise unrelated scope" \
	"$self_improvement"
assert_absent \
	"self-improvement no longer defers every response to an issue" \
	"Response: file an issue" \
	"$self_improvement"
assert_absent \
	"self-improvement no longer rejects deterministic alternatives" \
	"no deterministic alternative" \
	"$self_improvement"
assert_contains \
	"self-improvement keeps repository knowledge distinct from forge conversations" \
	"portable execution conversations, not the sole record" \
	"$self_improvement"

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d context-engineering guidance check(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll context-engineering guidance checks passed\n'
