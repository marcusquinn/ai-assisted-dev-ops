#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for managed-markdown-block-helper.py (GH#28844).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../managed-markdown-block-helper.py"

PASS=0
FAIL=0

assert_contains() {
	local description="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASS=$((PASS + 1))
	else
		printf 'FAIL %s: missing %s\n' "$description" "$needle" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" -eq "$expected" ]]; then
		printf 'PASS %s\n' "$description"
		PASS=$((PASS + 1))
	else
		printf 'FAIL %s: expected %s, got %s\n' "$description" "$expected" "$actual" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

tmp_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp_dir"' EXIT
template="$tmp_dir/policy.md"
target="$tmp_dir/CONTRIBUTING.md"

cat >"$template" <<'EOF'
<!-- aidevops:issue-first-pr:start -->
## Issue-first pull requests

Create or find an issue before opening a pull request.
<!-- aidevops:issue-first-pr:end -->
EOF

rendered=$(python3 "$HELPER" render --file "$target" --template "$template")
assert_contains "missing file receives default heading" "$rendered" "# Contributing"
assert_contains "missing file receives managed block" "$rendered" "Issue-first pull requests"

python3 "$HELPER" apply --file "$target" --template "$template" >/dev/null
python3 "$HELPER" check --file "$target" --template "$template"
assert_exit "applied file is current" 0 "$?"

cat >"$target" <<'EOF'
# Contributing

Repository-specific introduction.

<!-- aidevops:issue-first-pr:start -->
## Stale heading

Stale text.
<!-- aidevops:issue-first-pr:end -->

Repository-specific footer.
EOF
python3 "$HELPER" apply --file "$target" --template "$template" >/dev/null
updated=$(<"$target")
assert_contains "content before block is preserved" "$updated" "Repository-specific introduction."
assert_contains "content after block is preserved" "$updated" "Repository-specific footer."
assert_contains "managed block is refreshed" "$updated" "Create or find an issue"

before=$(<"$target")
result=$(python3 "$HELPER" apply --file "$target" --template "$template")
after=$(<"$target")
assert_contains "second apply reports current" "$result" "CURRENT"
if [[ "$before" == "$after" ]]; then
	printf 'PASS second apply is byte-idempotent\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL second apply changed content\n' >&2
	FAIL=$((FAIL + 1))
fi

python3 - "$target" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace(
    "<!-- aidevops:issue-first-pr:start -->\n",
    "<!-- aidevops:issue-first-pr:start -->\n\n",
)
content = content.replace(
    "\n<!-- aidevops:issue-first-pr:end -->",
    "\n\n<!-- aidevops:issue-first-pr:end -->",
)
path.write_text(content, encoding="utf-8")
PY
formatter_before=$(<"$target")
python3 "$HELPER" check --file "$target" --template "$template"
assert_exit "formatter-added marker spacing is current" 0 "$?"
formatter_result=$(python3 "$HELPER" apply --file "$target" --template "$template")
formatter_after=$(<"$target")
assert_contains "formatter-spaced apply reports current" "$formatter_result" "CURRENT"
if [[ "$formatter_before" == "$formatter_after" ]]; then
	printf 'PASS formatter spacing is byte-preserved\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL formatter spacing changed\n' >&2
	FAIL=$((FAIL + 1))
fi

cat >"$target" <<'EOF'
# Contributing

<!-- aidevops:issue-first-pr:start -->
Malformed block without an end marker.
EOF
malformed_before=$(<"$target")
python3 "$HELPER" apply --file "$target" --template "$template" >/dev/null 2>&1
malformed_rc=$?
malformed_after=$(<"$target")
assert_exit "partial markers fail closed" 2 "$malformed_rc"
if [[ "$malformed_before" == "$malformed_after" ]]; then
	printf 'PASS malformed target remains unchanged\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL malformed target changed\n' >&2
	FAIL=$((FAIL + 1))
fi

if [[ "$FAIL" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$PASS"
	exit 0
fi
printf '%d of %d tests failed\n' "$FAIL" "$((PASS + FAIL))" >&2
exit 1
