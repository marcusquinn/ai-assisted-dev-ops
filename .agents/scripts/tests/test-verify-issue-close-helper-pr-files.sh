#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for verify-issue-close-helper.sh file overlap verification.
#
# GH#22138: `gh pr view --json files` may return `{"files":null}` for merged
# PRs even though the pull files REST endpoint still returns the changed files.
# The helper must treat that as a fallback condition, not a parse failure.

set -euo pipefail

PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../verify-issue-close-helper.sh"

if [[ ! -f "$HELPER_PATH" ]]; then
	printf 'FAIL: verify-issue-close-helper.sh not found at %s\n' "$HELPER_PATH" >&2
	exit 1
fi

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	case "${3:-}" in
	200)
		printf '## Files to modify\n- EDIT: .agents/scripts/verify-issue-close-helper.sh — robust PR file parsing\n'
		;;
	201)
		printf '## Implementation context\nUpdate `setup.sh` so setup continues.\n## Evidence\n`.agents/scripts/setup/modules/config.sh` establishes the child failure contract.\n'
		;;
	202)
		printf '## Implementation target\nUpdate `.agents/scripts/setup/modules/config.sh`; the `config.sh` implementation is defective.\n'
		;;
	203 | 204)
		printf '## Implementation target\nUpdate the extensionless repository path `.agents/scripts/gh`.\n'
		;;
	205)
		printf '## Implementation target\nUpdate `.agents/scripts/target.sh`; evidence is at `https://example.com/unrelated/gh`.\n'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	case "${3:-}" in
	100)
		printf '{"files":null}\n'
		;;
	101)
		printf '{"files":[{"path":".agents/scripts/verify-issue-close-helper.sh"}]}\n'
		;;
	102)
		printf '{"files":[{"path":"setup.sh"},{"path":".agents/scripts/tests/test-setup-stage-timing-observability.sh"}]}\n'
		;;
	103)
		printf '{"files":[{"path":"unrelated/config.sh"}]}\n'
		;;
	104)
		printf '{"files":[{"path":".agents/scripts/gh"}]}\n'
		;;
	105)
		printf '{"files":[{"path":"unrelated/gh"}]}\n'
		;;
	106)
		printf '{"files":[{"path":"unrelated/gh"}]}\n'
		;;
	*)
		printf '{"files":[]}\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	case "${3:-}" in
	repos/owner/repo/pulls/100/files)
		printf '.agents/scripts/verify-issue-close-helper.sh\n'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$TMPDIR/gh"
export PATH="$TMPDIR:$PATH"

assert_check_passes() {
	local label="$1"
	local pr_number="$2"
	local issue_number="${3:-200}"

	local output
	if output=$(bash "$HELPER_PATH" check "$issue_number" "$pr_number" owner/repo 2>&1); then
		if printf '%s' "$output" | grep -q 'VERIFIED: PR'; then
			PASS=$((PASS + 1))
			printf 'PASS: %s\n' "$label"
		else
			FAIL=$((FAIL + 1))
			printf 'FAIL: %s — missing VERIFIED verdict\n%s\n' "$label" "$output"
		fi
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s — helper exited non-zero\n%s\n' "$label" "$output"
	fi
	return 0
}

assert_check_rejects() {
	local label="$1"
	local issue_number="$2"
	local pr_number="$3"

	local output
	if output=$(bash "$HELPER_PATH" check "$issue_number" "$pr_number" owner/repo 2>&1); then
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s — helper accepted unsafe overlap\n%s\n' "$label" "$output"
	elif printf '%s' "$output" | grep -q 'REJECTED: PR'; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s — missing REJECTED verdict\n%s\n' "$label" "$output"
	fi
	return 0
}

assert_check_passes "merged PR files null falls back to REST pull files endpoint" 100
assert_check_passes "standard gh pr view files array still parses" 101
assert_check_passes "independent general target survives a supporting specific path" 102 201
assert_check_rejects "specific target cannot be satisfied by an unrelated same-basename file" 202 103
assert_check_passes "extensionless repository path matches the exact PR file" 104 203
assert_check_rejects "extensionless repository path rejects an unrelated same-basename file" 204 105
assert_check_rejects "backtick URL cannot supply an extensionless repository path" 205 106

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
