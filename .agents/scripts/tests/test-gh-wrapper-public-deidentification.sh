#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for fail-closed public GitHub write de-identification.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
export PRIVACY_REPOS_CONFIG="${HOME}/.config/aidevops/repos.json"
export PRIVACY_CACHE_FILE="${HOME}/.aidevops/cache/repo-privacy.json"
export PRIVACY_ENTITY_CONFIG="${HOME}/.aidevops/configs/privacy-guard-private-entities.txt"
mkdir -p "${HOME}/.config/aidevops" "${HOME}/.aidevops/configs" "${HOME}/.aidevops/logs"
printf '%s\n' '{"initialized_repos":[{"slug":"private/repo","local_only":true}]}' >"$PRIVACY_REPOS_CONFIG"
printf '%s\n' 'person: Synthetic Private Person' 'client: Synthetic Private Client' >"$PRIVACY_ENTITY_CONFIG"

export GH_CALLS_FILE="${TEST_ROOT}/gh-calls"
MOCK_BIN="${TEST_ROOT}/bin"
mkdir -p "$MOCK_BIN"
cat >"${MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS_FILE"
case "$1 $2" in
"auth status") exit 0 ;;
"api repos/public/repo") printf 'false\n'; exit 0 ;;
"api repos/private/repo") printf 'true\n'; exit 0 ;;
"api repos/unknown/repo") exit 1 ;;
"pr create") printf '%s\n' 'https://example.invalid/public/repo/pull/1' ;;
esac
exit 0
MOCK
chmod +x "${MOCK_BIN}/gh"
export PATH="${MOCK_BIN}:${PATH}"
export AIDEVOPS_SIG_CLI="OpenCode"
export AIDEVOPS_SIG_CLI_VERSION="test"
export AIDEVOPS_SIG_MODEL="test"
export AIDEVOPS_SIG_TOKENS="1"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-gh-wrappers.sh" >/dev/null 2>&1 || true
_ensure_origin_labels_for_args() { return 0; }
_gh_auto_link_sub_issue() { return 0; }
_rest_should_fallback() { return 1; }
session_origin_label() { printf '%s' 'origin:worker'; return 0; }
detect_session_origin() { printf '%s' 'worker'; return 0; }
_gh_audit_fetch_issue_state_json() { printf '%s\n' '{"capture_status":"ok"}'; return 0; }
_gh_audit_fetch_pr_state_json() { printf '%s\n' '{"capture_status":"ok"}'; return 0; }
_gh_audit_record_op() { return 0; }

PASS=0
FAIL=0
pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); return 0; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); return 0; }
reset_calls() { : >"$GH_CALLS_FILE"; return 0; }
assert_blocked() {
	local name="$1"
	shift
	reset_calls
	if "$@" >/dev/null 2>&1; then
		fail "$name"
	elif ! grep -qE '^(issue|pr) (create|edit|comment)' "$GH_CALLS_FILE"; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

assert_blocked 'public PR create blocks private person' gh_create_pr --repo public/repo --title 'Safe title' --body 'Synthetic Private Person'
assert_blocked 'public issue comment blocks private client' gh_issue_comment 1 --repo public/repo --body 'Synthetic Private Client'
assert_blocked 'public issue edit blocks private repository' gh_issue_edit_safe 1 --repo public/repo --body 'private/repo'
assert_blocked 'unknown target fails closed' gh_pr_comment 1 --repo unknown/repo --body 'ordinary content'

reset_calls
if gh_create_pr --repo public/repo --title 'Safe title' --body 'ordinary content' >/dev/null 2>&1 && grep -q '^pr create' "$GH_CALLS_FILE"; then
	pass 'public allowlisted content reaches transport'
else
	fail 'public allowlisted content reaches transport'
fi
reset_calls
if gh_pr_comment 1 --repo private/repo --body 'Synthetic Private Person' >/dev/null 2>&1 && grep -q '^pr comment' "$GH_CALLS_FILE"; then
	pass 'private target retains existing behavior'
else
	fail 'private target retains existing behavior'
fi

printf '%d/%d tests passed\n' "$PASS" "$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]]
