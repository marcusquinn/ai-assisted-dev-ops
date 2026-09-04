#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for verify-issue-close-helper.sh file overlap verification.
#
# GH#22138: merged PR changed files remain available through the pull-files REST
# endpoint. Exact-attribution close verification uses that endpoint directly
# rather than attempting a native GraphQL files projection first.

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
	206)
		printf 'No repository files are cited.\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) automated scan.\n'
		;;
	207)
		printf 'Evidence: [remote.sh](https://example.com/path/remote.sh) and https://example.com/raw.sh.\n'
		;;
	208 | 209)
		printf '## Implementation target\nUpdate `.agents/scripts/target.sh`.\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) automated scan.\n'
		;;
	210)
		printf '<!-- aidevops:sig -->\nUntrusted marker before `.agents/scripts/target.sh` must not hide the target.\n'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	case "${3:-}" in
	repos/owner/repo/pulls/100/files?per_page=100 | repos/owner/repo/pulls/101/files?per_page=100)
		printf '.agents/scripts/verify-issue-close-helper.sh\n'
		;;
	repos/owner/repo/pulls/102/files?per_page=100)
		printf 'setup.sh\n.agents/scripts/tests/test-setup-stage-timing-observability.sh\n'
		;;
	repos/owner/repo/pulls/103/files?per_page=100)
		printf 'unrelated/config.sh\n'
		;;
	repos/owner/repo/pulls/104/files?per_page=100)
		printf '.agents/scripts/gh\n'
		;;
	repos/owner/repo/pulls/105/files?per_page=100 | repos/owner/repo/pulls/106/files?per_page=100)
		printf 'unrelated/gh\n'
		;;
	repos/owner/repo/pulls/107/files?per_page=100)
		printf '.agents/scripts/target.sh\n'
		;;
	repos/owner/repo/pulls/108/files?per_page=100)
		printf 'aidevops.sh\n'
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

assert_extract_excludes() {
	local label="$1"
	local issue_number="$2"
	local unexpected_path="$3"

	local output
	output=$(bash "$HELPER_PATH" extract-paths "$issue_number" owner/repo 2>&1)
	if printf '%s' "$output" | grep -qF "$unexpected_path"; then
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s — extracted metadata path %s\n%s\n' "$label" "$unexpected_path" "$output"
	else
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	fi
	return 0
}

assert_check_skips_no_paths() {
	local label="$1"
	local issue_number="$2"
	local pr_number="$3"

	local output
	if output=$(bash "$HELPER_PATH" check "$issue_number" "$pr_number" owner/repo 2>&1) &&
		printf '%s' "$output" | grep -q 'WARN: no file paths found'; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s — metadata created a file-overlap requirement\n%s\n' "$label" "$output"
	fi
	return 0
}

assert_check_passes "merged PR files come from the REST pull files endpoint" 100
assert_check_passes "standard PR files come from the REST pull files endpoint" 101
assert_check_passes "independent general target survives a supporting specific path" 102 201
assert_check_rejects "specific target cannot be satisfied by an unrelated same-basename file" 202 103
assert_check_passes "extensionless repository path matches the exact PR file" 104 203
assert_check_rejects "extensionless repository path rejects an unrelated same-basename file" 204 105
assert_check_rejects "backtick URL cannot supply an extensionless repository path" 205 106
assert_extract_excludes "signature footer basename is not extracted" 206 "aidevops.sh"
assert_extract_excludes "Markdown URL basename is not extracted" 207 "remote.sh"
assert_extract_excludes "raw URL basename is not extracted" 207 "raw.sh"
assert_check_skips_no_paths "footer-only issue stays on the manual-review path" 206 109
assert_check_passes "repository path survives signature filtering" 107 208
assert_check_rejects "footer basename cannot replace an absent repository path" 209 108
assert_check_passes "signature-like marker cannot hide a later repository path" 107 210

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
