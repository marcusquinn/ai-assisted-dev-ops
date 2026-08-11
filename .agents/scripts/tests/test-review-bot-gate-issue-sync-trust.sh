#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Verify the reusable review gate's exact repository-generated Issue Sync trust
# classifier without duplicating its security-sensitive shell logic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/review-bot-gate-reusable.yml"
HELPER_FILE="${REPO_ROOT}/.agents/scripts/review-bot-gate-helper.sh"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "${STATE_DIR}"' EXIT
mkdir -p "${STATE_DIR}/bin"
cat >"${STATE_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "api" ]] || exit 2
[[ "${2:-}" == "repos/marcusquinn/aidevops/pulls/123" ]] || exit 2
case "${REVIEW_GATE_LIVE_TRUSTED:-false}" in
true)
	printf '%s\n' '{"author_association":"CONTRIBUTOR","user":{"login":"github-actions[bot]","id":41898282,"type":"Bot"},"head":{"ref":"aidevops/issue-sync-todo","sha":"head-123","repo":{"full_name":"marcusquinn/aidevops"}},"base":{"repo":{"full_name":"marcusquinn/aidevops"}},"body":"<!-- aidevops:issue-sync-todo-pr -->"}'
	;;
json)
	printf '%s\n' "${REVIEW_GATE_LIVE_JSON:-}"
	;;
error) exit 42 ;;
*)
	printf '%s\n' '{"author_association":"CONTRIBUTOR","user":{"login":"github-actions[bot]","id":999,"type":"Bot"}}'
	;;
esac
EOF
chmod +x "${STATE_DIR}/bin/gh"

START_COUNT=$(grep -Fc '# aidevops:review-gate-trust-start' "${WORKFLOW_FILE}")
END_COUNT=$(grep -Fc '# aidevops:review-gate-trust-end' "${WORKFLOW_FILE}")
if [[ "${START_COUNT}" -ne 1 || "${END_COUNT}" -ne 1 ]]; then
	printf 'FAIL: expected one review-gate trust classifier block\n' >&2
	exit 1
fi

CLASSIFIER=$(awk '
	/# aidevops:review-gate-trust-start/ { capture = 1; next }
	/# aidevops:review-gate-trust-end/ { capture = 0 }
	capture { sub(/^          /, ""); print }
' "${WORKFLOW_FILE}")
if [[ -z "${CLASSIFIER}" ]]; then
	printf 'FAIL: review-gate trust classifier extraction was empty\n' >&2
	exit 1
fi

assert_output() {
	local output_file="$1"
	local key="$2"
	local expected="$3"
	local case_name="$4"
	if ! grep -Fxq "${key}=${expected}" "${output_file}"; then
		printf 'FAIL: %s expected %s=%s\n' "${case_name}" "${key}" "${expected}" >&2
		return 1
	fi
	return 0
}

CASE_INDEX=0
run_case() {
	local case_name="$1"
	local expected_external="$2"
	local expected_trusted="$3"
	local expected_association="$4"
	local expected_rate_limit="$5"
	local expected_completion="$6"
	local author_association="$7"
	local author_login="$8"
	local author_id="$9"
	local author_type="${10}"
	local head_repository="${11}"
	local base_repository="${12}"
	local head_ref="${13}"
	local pr_body="${14}"
	local live_trusted="${15:-false}"
	local output_file=""

	CASE_INDEX=$((CASE_INDEX + 1))
	output_file="${STATE_DIR}/case-${CASE_INDEX}.out"
	if ! GITHUB_OUTPUT="${output_file}" \
		HELPER="${HELPER_FILE}" \
		PATH="${STATE_DIR}/bin:${PATH}" \
		PR_NUMBER=123 \
		REPO="marcusquinn/aidevops" \
		REVIEW_GATE_LIVE_TRUSTED="${live_trusted}" \
		REVIEW_GATE_AUTHOR_ASSOCIATION="${author_association}" \
		REVIEW_GATE_PR_AUTHOR_LOGIN="${author_login}" \
		REVIEW_GATE_PR_AUTHOR_ID="${author_id}" \
		REVIEW_GATE_PR_AUTHOR_TYPE="${author_type}" \
		REVIEW_GATE_PR_HEAD_REPOSITORY="${head_repository}" \
		REVIEW_GATE_PR_BASE_REPOSITORY="${base_repository}" \
		REVIEW_GATE_PR_HEAD_REF="${head_ref}" \
		REVIEW_GATE_PR_BODY="${pr_body}" \
		REVIEW_GATE_RATE_LIMIT_BEHAVIOR=pass \
		REVIEW_GATE_COMPLETION_BEHAVIOR=fast \
		bash -c "${CLASSIFIER}" >/dev/null; then
		printf 'FAIL: %s classifier execution failed\n' "${case_name}" >&2
		return 1
	fi

	assert_output "${output_file}" is_external_pr "${expected_external}" "${case_name}"
	assert_output "${output_file}" trusted_issue_sync_pr "${expected_trusted}" "${case_name}"
	assert_output "${output_file}" effective_author_association "${expected_association}" "${case_name}"
	assert_output "${output_file}" effective_rate_limit_behavior "${expected_rate_limit}" "${case_name}"
	assert_output "${output_file}" effective_completion_behavior "${expected_completion}" "${case_name}"
	printf 'PASS: %s\n' "${case_name}"
	return 0
}

MARKER='<!-- aidevops:issue-sync-todo-pr -->'

run_case \
	'official same-repository Issue Sync bot is trusted' \
	false true COLLABORATOR pass fast \
	CONTRIBUTOR 'github-actions[bot]' 41898282 Bot \
	'marcusquinn/aidevops' 'marcusquinn/aidevops' \
	'aidevops/issue-sync-todo' "${MARKER}"

run_case \
	'owner association remains trusted without automation normalization' \
	false false OWNER pass fast \
	OWNER maintainer 123 User \
	'marcusquinn/aidevops' 'marcusquinn/aidevops' \
	'feature/example' 'ordinary pull request'

run_case \
	'issue_comment metadata omission uses the live shared classifier' \
	false true COLLABORATOR pass fast \
	CONTRIBUTOR 'github-actions[bot]' 41898282 Bot \
	'' '' '' "${MARKER}" true

run_case \
	'external user cannot spoof marker and deterministic branch' \
	true false CONTRIBUTOR wait strict \
	CONTRIBUTOR attacker 999 User \
	'marcusquinn/aidevops' 'marcusquinn/aidevops' \
	'aidevops/issue-sync-todo' "${MARKER}"

run_case \
	'lookalike bot ID remains external' \
	true false CONTRIBUTOR wait strict \
	CONTRIBUTOR 'github-actions[bot]' 999 Bot \
	'marcusquinn/aidevops' 'marcusquinn/aidevops' \
	'aidevops/issue-sync-todo' "${MARKER}"

run_case \
	'forked Issue Sync branch remains external' \
	true false CONTRIBUTOR wait strict \
	CONTRIBUTOR 'github-actions[bot]' 41898282 Bot \
	'attacker/aidevops' 'marcusquinn/aidevops' \
	'aidevops/issue-sync-todo' "${MARKER}"

run_case \
	'wrong same-repository branch remains external' \
	true false CONTRIBUTOR wait strict \
	CONTRIBUTOR 'github-actions[bot]' 41898282 Bot \
	'marcusquinn/aidevops' 'marcusquinn/aidevops' \
	'feature/not-issue-sync' "${MARKER}"

run_case \
	'missing generated marker remains external' \
	true false CONTRIBUTOR wait strict \
	CONTRIBUTOR 'github-actions[bot]' 41898282 Bot \
	'marcusquinn/aidevops' 'marcusquinn/aidevops' \
	'aidevops/issue-sync-todo' 'ordinary pull request'

LIVE_ERROR_STATUS=0
if REVIEW_GATE_LIVE_TRUSTED=error PATH="${STATE_DIR}/bin:${PATH}" \
	bash "${HELPER_FILE}" is-trusted-issue-sync-pr 123 marcusquinn/aidevops >/dev/null 2>&1; then
	LIVE_ERROR_STATUS=0
else
	LIVE_ERROR_STATUS=$?
fi
if [[ "${LIVE_ERROR_STATUS}" -ne 2 ]]; then
	printf 'FAIL: live helper API failure expected exit 2, got %s\n' "${LIVE_ERROR_STATUS}" >&2
	exit 1
fi
printf 'PASS: live helper API failures remain distinct and fail-closed\n'

LIVE_BASE_JSON='{"author_association":"CONTRIBUTOR","user":{"login":"github-actions[bot]","id":41898282,"type":"Bot"},"head":{"ref":"aidevops/issue-sync-todo","sha":"head-123","repo":{"full_name":"marcusquinn/aidevops"}},"base":{"repo":{"full_name":"marcusquinn/aidevops"}},"body":"<!-- aidevops:issue-sync-todo-pr -->"}'

assert_live_rejected() {
	local case_name="$1"
	local payload="$2"
	if REVIEW_GATE_LIVE_TRUSTED=json REVIEW_GATE_LIVE_JSON="$payload" \
		PATH="${STATE_DIR}/bin:${PATH}" \
		bash "${HELPER_FILE}" is-trusted-issue-sync-pr \
			123 marcusquinn/aidevops head-123 >/dev/null 2>&1; then
		printf 'FAIL: live helper accepted %s\n' "$case_name" >&2
		return 1
	fi
	printf 'PASS: live helper rejects %s\n' "$case_name"
	return 0
}

assert_live_rejected 'wrong bot login' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.user.login = "github-actions"')"
assert_live_rejected 'wrong bot ID' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.user.id = 999')"
assert_live_rejected 'wrong actor type' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.user.type = "User"')"
assert_live_rejected 'different head repository' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.head.repo.full_name = "attacker/aidevops"')"
assert_live_rejected 'different base repository' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.base.repo.full_name = "other/aidevops"')"
assert_live_rejected 'different generated branch' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.head.ref = "feature/not-issue-sync"')"
assert_live_rejected 'missing generated body marker' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.body = "ordinary pull request"')"
assert_live_rejected 'different live head SHA' \
	"$(printf '%s' "$LIVE_BASE_JSON" | jq -c '.head.sha = "other-head"')"

if ! REVIEW_GATE_LIVE_TRUSTED=true PATH="${STATE_DIR}/bin:${PATH}" \
	bash "${HELPER_FILE}" is-trusted-issue-sync-pr 123 marcusquinn/aidevops head-123 >/dev/null; then
	printf 'FAIL: live helper rejected the exact expected PR head\n' >&2
	exit 1
fi
if REVIEW_GATE_LIVE_TRUSTED=true PATH="${STATE_DIR}/bin:${PATH}" \
	bash "${HELPER_FILE}" is-trusted-issue-sync-pr 123 marcusquinn/aidevops stale-head >/dev/null; then
	printf 'FAIL: live helper accepted a stale expected PR head\n' >&2
	exit 1
fi
printf 'PASS: live helper trust is optionally bound to the exact PR head\n'

HELP_OUTPUT=$(bash "${HELPER_FILE}" help 2>/dev/null || true)
if [[ "${HELP_OUTPUT}" != *"is-trusted-issue-sync-pr"* ]]; then
	printf 'FAIL: runtime help omits is-trusted-issue-sync-pr\n' >&2
	exit 1
fi
printf 'PASS: runtime help documents the live Issue Sync classifier\n'

printf 'All review-bot Issue Sync trust tests passed.\n'
