#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression guard: routine postflight observes release evidence and must not
# duplicate source scans already owned by development, CI, and release preflight.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
POSTFLIGHT="$ROOT_DIR/.agents/scripts/postflight-check.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/postflight.yml"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_absent() {
	local pattern="$1"
	local file="$2"
	local description="$3"
	if grep -Eq -- "$pattern" "$file"; then
		fail "$description"
		return 1
	fi
	return 0
}

full_mode_body() {
	awk '
		/^[[:space:]]*full\)/ { in_full = 1; next }
		in_full && /^[[:space:]]*;;/ { exit }
		in_full { print }
	' "$POSTFLIGHT"
	return 0
}

main() {
	assert_absent 'linters-local\.sh.*--full|check_local_quality' "$POSTFLIGHT" \
		'postflight must not invoke full local lint'
	local full_body=""
	full_body=$(full_mode_body)
	if grep -Eq 'check_(snyk|secrets|npm_audit|local_quality)' <<<"$full_body"; then
		fail 'routine postflight must not invoke local source scans'
		return 1
	fi
	assert_absent 'bun install -g snyk|bunx --no-install secretlint|name: Security Scan with Snyk|name: Check for Secrets' "$WORKFLOW" \
		'automated postflight must not reinstall scanners or rescan source'
	grep -Fq "release_sha=\"\${POSTFLIGHT_COMMIT_SHA:-" "$POSTFLIGHT" &&
	grep -Fq "load_release_owned_checks \"\$repo\" \"\$release_sha\"" "$POSTFLIGHT" ||
		fail 'local postflight must query exact-SHA workflow evidence'
	grep -Fq 'steps.release_commit.outputs.sha' "$WORKFLOW" ||
		fail 'automated postflight must bind checks and reports to the checked-out release SHA'
	grep -Fq 'remained non-terminal after timeout' "$WORKFLOW" ||
		fail 'automated postflight must fail when check runs remain pending'
	grep -Fq 'No terminal check-run evidence exists' "$WORKFLOW" ||
		fail 'automated postflight must fail when release evidence is absent'
	printf 'PASS: postflight reuses terminal release evidence without source rescans\n'
	return 0
}

main "$@"
