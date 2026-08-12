#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for public GitHub write privacy secret-material scanning.
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
HELPER_SRC="${SCRIPT_DIR}/../privacy-guard-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '    %s\n' "$detail"
	fi
	FAIL=$((FAIL + 1))
	return 0
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gh-public-privacy-guard)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts"
cp "$HELPER_SRC" "$TMP/scripts/privacy-guard-helper.sh"

# Build the basename in pieces so the test source itself does not contain a
# token-looking fixture while still reproducing an aidevops helper filename with
# an embedded credential-prefix-shaped substring.
ALLOWED_BASENAME="ta""sk-dispatch-helper.sh"
touch "$TMP/scripts/$ALLOWED_BASENAME"
ALLOWED_NODE_BASENAME="${ALLOWED_BASENAME%.sh}.mjs"
touch "$TMP/scripts/$ALLOWED_NODE_BASENAME"

# shellcheck source=/dev/null
source "$TMP/scripts/privacy-guard-helper.sh"

printf '=== gh public privacy guard tests ===\n\n'

printf '%s\n' '{"initialized_repos":[{"slug":"private/repo","local_only":true}]}' >"$TMP/repos.json"
printf '%s\n' 'person: Synthetic Private Person' 'client: Synthetic Private Client' >"$TMP/entities.txt"
PRIVACY_REPOS_CONFIG="$TMP/repos.json"
PRIVACY_ENTITY_CONFIG="$TMP/entities.txt"
entities_file="$TMP/private-entities.tsv"
if privacy_enumerate_private_entities "$entities_file" &&
	redacted=$(privacy_redact_public_text 'Synthetic Private Person and Synthetic Private Client' "$entities_file") &&
	[[ "$redacted" == '[private-person] and [private-client]' ]]; then
	pass "private entity inventory redacts generic placeholders"
else
	fail "private entity inventory redacts generic placeholders"
fi

redacted=$(privacy_redact_public_text 'Local source: /Users/example/Git/private-project' "$entities_file")
if [[ "$redacted" == 'Local source: [local-path]' ]]; then
	pass "public text redacts local filesystem paths"
else
	fail "public text redacts local filesystem paths" "redacted=$redacted"
fi

redacted=$(privacy_redact_public_text_from_inventory 'Synthetic Private Person at /Users/example/Git/private-project')
if [[ "$redacted" == '[private-person] at [local-path]' ]]; then
	pass "public text inventory helper redacts before publication"
else
	fail "public text inventory helper redacts before publication" "redacted=$redacted"
fi

out=$(privacy_scan_public_text 'Synthetic Private Person' "$entities_file")
rc=$?
if [[ "$rc" -eq 1 && "$out" == '[private-person]' ]]; then
	pass "private person hit does not expose matched value"
else
	fail "private person hit is generic" "rc=$rc out=$out"
fi

out=$(privacy_scan_secret_material_text "Worker guidance: edit .agents/scripts/$ALLOWED_BASENAME" 2>"$TMP/allow-path.err")
rc=$?
err=$(<"$TMP/allow-path.err")
if [[ "$rc" -eq 0 && -z "$out" && -z "$err" ]]; then
	pass "aidevops script path reference is allowed without bypass output"
else
	fail "aidevops script path reference" "rc=$rc out=$out err=$err"
fi

out=$(privacy_scan_secret_material_text "Worker guidance: edit .agents/scripts/$ALLOWED_NODE_BASENAME" 2>"$TMP/allow-node-path.err")
rc=$?
err=$(<"$TMP/allow-node-path.err")
if [[ "$rc" -eq 0 && -z "$out" && -z "$err" ]]; then
	pass "aidevops Node script path reference is allowed without bypass output"
else
	fail "aidevops Node script path reference" "rc=$rc out=$out err=$err"
fi

precomputed_input="Worker guidance: edit .agents/scripts/$ALLOWED_BASENAME"
redacted=$(_privacy_redact_aidevops_script_references "$precomputed_input" "$ALLOWED_BASENAME")
if [[ "$redacted" == *'[aidevops-script-reference]'* ]]; then
	pass "precomputed aidevops script basename allowlist is used"
else
	fail "precomputed aidevops script basename allowlist" "redacted=$redacted"
fi

redacted=$(_privacy_redact_aidevops_script_references "$precomputed_input" "")
if [[ "$redacted" == "$precomputed_input" ]]; then
	pass "empty precomputed aidevops script basename allowlist skips fallback discovery"
else
	fail "empty precomputed aidevops script basename allowlist" "redacted=$redacted"
fi

out=$(privacy_scan_secret_material_text "Reference basename \`$ALLOWED_BASENAME\` in the issue body" 2>"$TMP/allow-basename.err")
rc=$?
err=$(<"$TMP/allow-basename.err")
if [[ "$rc" -eq 0 && -z "$out" && -z "$err" ]]; then
	pass "backticked aidevops script basename is allowed without bypass output"
else
	fail "backticked aidevops script basename" "rc=$rc out=$out err=$err"
fi

synthetic_token="sk-""abcdefghijklmnopqrstuvwxyz"
out=$(privacy_scan_secret_material_text "Synthetic secret fixture: $synthetic_token" 2>"$TMP/block-secret.err")
rc=$?
if [[ "$rc" -eq 1 && "$out" == *'credential token prefix'* ]]; then
	pass "synthetic credential-like token remains blocked"
else
	fail "synthetic credential-like token" "rc=$rc out=$out"
fi

out=$(privacy_scan_secret_material_text "Filename-like but undocumented: ${synthetic_token}.sh" 2>"$TMP/block-undocumented.err")
rc=$?
if [[ "$rc" -eq 1 && "$out" == *'credential token prefix'* ]]; then
	pass "undocumented filename-like credential token remains blocked"
else
	fail "undocumented filename-like credential token" "rc=$rc out=$out"
fi

# Credential prefixes are only secret-like at a token boundary. Keep the
# canonical task-coordinator filename split so this regression fixture cannot
# itself be mistaken for a credential by source scanners using the old regex.
TASK_COORDINATOR_BASENAME="$ALLOWED_BASENAME"
while IFS='|' read -r label input; do
	out=$(privacy_scan_secret_material_text "$input" 2>"$TMP/allow-boundary.err")
	rc=$?
	if [[ "$rc" -eq 0 && -z "$out" ]]; then
		pass "$label is allowed as an embedded-word prefix"
	else
		fail "$label embedded-word prefix" "rc=$rc out=$out"
	fi
done <<EOF
task-coordinator path|Worker guidance: edit .agents/scripts/tests/$TASK_COORDINATOR_BASENAME
underscore boundary|Identifier prefix_${synthetic_token}
hyphen boundary|Identifier prefix-${synthetic_token}
EOF

while IFS='|' read -r label input; do
	out=$(privacy_scan_secret_material_text "$input" 2>"$TMP/block-boundary.err")
	rc=$?
	if [[ "$rc" -eq 1 && "$out" == *'credential token prefix'* ]]; then
		pass "$label credential-like token remains blocked"
	else
		fail "$label credential-like token" "rc=$rc out=$out"
	fi
done <<EOF
start-of-string|$synthetic_token
whitespace boundary|Fixture $synthetic_token
punctuation boundary|Fixture ($synthetic_token)
EOF

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
	printf '%d/%d tests passed\n' "$PASS" "$PASS"
	exit 0
fi

exit 1
