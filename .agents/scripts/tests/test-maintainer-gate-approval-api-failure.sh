#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27611/GH#28622: approval API failures and copied
# marker text must restore NMR, while authenticated maintainer authority passes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/maintainer-gate-reusable.yml"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s' "$test_name"
	if [[ -n "$detail" ]]; then
		printf ': %s' "$detail"
	fi
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t maintainer-gate-approval.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export GH_CALLS="${TEST_ROOT}/gh-calls.log"
	: >"$GH_CALLS"

	python3 - "$WORKFLOW_FILE" "$TEST_ROOT" <<'PY'
import pathlib
import sys
import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
for job_name, output_name in (
    ("check-pr", "check-pr-job.sh"),
    ("protect-labels", "issue-job.sh"),
    ("protect-pr-labels", "pr-job.sh"),
):
    steps = workflow["jobs"][job_name]["steps"]
    run = next(step["run"] for step in steps if "run" in step)
    (root / output_name).write_text(run)
PY

	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	case "${GH_SCENARIO:-}" in
		pr-label-failure) exit 1 ;;
		check-pr-nmr) printf 'needs-maintainer-review\n'; exit 0 ;;
		pr-*) printf 'external-contributor\n'; exit 0 ;;
	esac
fi

if [[ "${1:-}" == "api" && "$*" == *"/comments"* ]]; then
	case "${GH_SCENARIO:-}" in
		issue-api-failure|pr-approval-failure) exit 1 ;;
		issue-invalid|pr-invalid) printf '{"message":"rate limited"}\n'; exit 0 ;;
		issue-signed|pr-signed) printf '[[{"body":"<!-- aidevops-signed-approval -->","user":{"login":"maintainer"},"author_association":"OWNER"}]]\n'; exit 0 ;;
		issue-other-maintainer|pr-other-maintainer) printf '[[{"body":"<!-- aidevops-signed-approval -->","user":{"login":"owner"},"author_association":"OWNER"}]]\n'; exit 0 ;;
		issue-collab|pr-collab|issue-permission-failure|pr-permission-failure) printf '[[{"body":"<!-- aidevops-signed-approval -->","user":{"login":"trusted-collab"},"author_association":"COLLABORATOR"}]]\n'; exit 0 ;;
		issue-forged|pr-forged) printf '[[{"body":"<!-- aidevops-signed-approval -->","user":{"login":"external"},"author_association":"NONE"}]]\n'; exit 0 ;;
		issue-bot|pr-bot) printf '[[{"body":"<!-- aidevops-signed-approval -->","user":{"login":"github-actions[bot]"},"author_association":"NONE"}]]\n'; exit 0 ;;
		issue-unsigned|pr-unsigned) printf '[[]]\n'; exit 0 ;;
	esac
fi

if [[ "${1:-}" == "api" && "$*" == *"collaborators/trusted-collab/permission"* ]]; then
	case "${GH_SCENARIO:-}" in
		issue-permission-failure|pr-permission-failure) exit 1 ;;
		*) printf 'write\n'; exit 0 ;;
	esac
fi

if [[ "${1:-}" == "api" && "$*" == *"/statuses/"* ]]; then
	exit 0
fi

if [[ "${1:-}" == "issue" && ( "${2:-}" == "edit" || "${2:-}" == "comment" ) ]]; then
	exit 0
fi
if [[ "${1:-}" == "pr" && ( "${2:-}" == "edit" || "${2:-}" == "comment" ) ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_issue_job() {
	local scenario="$1"
	local actor="${2:-maintainer}"
	local labels_json="${3:-[]}"
	GH_SCENARIO="$scenario" \
		ISSUE_NUMBER=42 \
		ISSUE_AUTHOR=external \
		ACTOR="$actor" \
		ACTOR_ASSOCIATION=OWNER \
		ISSUE_LABELS_JSON="$labels_json" \
		REPO=owner/repo \
		GH_TOKEN=test-token \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/issue-job.sh" || return 1
	return 0
}

run_pr_job() {
	local scenario="$1"
	local actor="${2:-maintainer}"
	GH_SCENARIO="$scenario" \
		PR_NUMBER=43 \
		PR_AUTHOR=external \
		ACTOR="$actor" \
		REPO=owner/repo \
		GH_TOKEN=test-token \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/pr-job.sh" || return 1
	return 0
}

assert_no_mutation() {
	local test_name="$1"
	if grep -qE '^(issue|pr) edit ' "$GH_CALLS"; then
		print_result "$test_name" 1 "unexpected edit: $(grep -E '^(issue|pr) edit ' "$GH_CALLS")"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

assert_job_restores_nmr() {
	local target="$1"
	local scenario="$2"
	local test_prefix="$3"
	local actor="${4:-maintainer}"
	: >"$GH_CALLS"
	if [[ "$target" == "issue" ]]; then
		run_issue_job "$scenario" "$actor" >/dev/null 2>&1 || true
		if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
			print_result "$test_prefix restores NMR" 0
		else
			print_result "$test_prefix restores NMR" 1 "expected issue edit"
		fi
	else
		run_pr_job "$scenario" "$actor" >/dev/null 2>&1 || true
		if grep -q '^pr edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
			print_result "$test_prefix restores NMR" 0
		else
			print_result "$test_prefix restores NMR" 1 "expected PR edit"
		fi
	fi
	return 0
}

test_issue_approval_paths() {
	assert_job_restores_nmr issue issue-api-failure "issue approval API failure"
	assert_job_restores_nmr issue issue-invalid "invalid issue approval response"
	assert_job_restores_nmr issue issue-forged "forged external issue marker"
	assert_job_restores_nmr issue issue-permission-failure "unverifiable collaborator issue marker" "trusted-collab"
	assert_job_restores_nmr issue issue-bot "bot-authored issue marker" "github-actions[bot]"
	assert_job_restores_nmr issue issue-other-maintainer "different actor's issue marker"
	: >"$GH_CALLS"
	if run_issue_job issue-signed >/dev/null 2>&1; then
		print_result "signed issue approval is accepted" 0
	else
		print_result "signed issue approval is accepted" 1 "job returned non-zero"
	fi
	assert_no_mutation "signed issue approval does not restore NMR"
	: >"$GH_CALLS"
	if run_issue_job issue-collab trusted-collab >/dev/null 2>&1; then
		print_result "write-collaborator issue approval is accepted" 0
	else
		print_result "write-collaborator issue approval is accepted" 1 "job returned non-zero"
	fi
	assert_no_mutation "write-collaborator issue approval does not restore NMR"
	: >"$GH_CALLS"
	run_issue_job issue-unsigned maintainer '["persistent"]' >/dev/null 2>&1 || true
	if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "persistent issue cannot bypass protected NMR removal" 0
	else
		print_result "persistent issue cannot bypass protected NMR removal" 1 "expected issue edit"
	fi
	run_issue_job issue-unsigned maintainer '{"malformed":true}' >/dev/null 2>&1 || true
	if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "malformed persistent-label metadata fails closed" 0
	else
		print_result "malformed persistent-label metadata fails closed" 1 "expected issue edit"
	fi
	: >"$GH_CALLS"
	run_issue_job issue-unsigned >/dev/null 2>&1 || true
	if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "confirmed unsigned issue restores NMR" 0
	else
		print_result "confirmed unsigned issue restores NMR" 1 "expected issue edit"
	fi
	return 0
}

test_pr_approval_paths() {
	assert_job_restores_nmr pr pr-label-failure "PR label API failure"
	assert_job_restores_nmr pr pr-approval-failure "PR approval API failure"
	assert_job_restores_nmr pr pr-invalid "invalid PR approval response"
	assert_job_restores_nmr pr pr-forged "forged external PR marker"
	assert_job_restores_nmr pr pr-permission-failure "unverifiable collaborator PR marker" "trusted-collab"
	assert_job_restores_nmr pr pr-bot "bot-authored PR marker" "github-actions[bot]"
	assert_job_restores_nmr pr pr-other-maintainer "different actor's PR marker"
	: >"$GH_CALLS"
	if run_pr_job pr-signed >/dev/null 2>&1; then
		print_result "signed PR approval is accepted" 0
	else
		print_result "signed PR approval is accepted" 1 "job returned non-zero"
	fi
	assert_no_mutation "signed PR approval does not restore NMR"
	: >"$GH_CALLS"
	if run_pr_job pr-collab trusted-collab >/dev/null 2>&1; then
		print_result "write-collaborator PR approval is accepted" 0
	else
		print_result "write-collaborator PR approval is accepted" 1 "job returned non-zero"
	fi
	assert_no_mutation "write-collaborator PR approval does not restore NMR"
	: >"$GH_CALLS"
	run_pr_job pr-unsigned >/dev/null 2>&1 || true
	if grep -q '^pr edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "confirmed unsigned external PR restores NMR" 0
	else
		print_result "confirmed unsigned external PR restores NMR" 1 "expected PR edit"
	fi
	return 0
}

test_live_pr_nmr_blocks_before_comments() {
	local output_file="${TEST_ROOT}/check-pr-output"
	: >"$GH_CALLS"
	: >"$output_file"
	if GH_SCENARIO=check-pr-nmr \
		PR_TITLE="External change" \
		PR_BODY="" \
		PR_NUMBER=44 \
		PR_AUTHOR=external \
		HEAD_SHA=fixture-head \
		PR_AUTHOR_ASSOCIATION=NONE \
		REPO=owner/repo \
		REPO_OWNER=owner \
		GH_TOKEN=test-token \
		MAINTAINER_GATE_DEBUG=false \
		GITHUB_OUTPUT="$output_file" \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/check-pr-job.sh" >/dev/null 2>&1; then
		if grep -q '^blocked=true$' "$output_file" && ! grep -q '/comments' "$GH_CALLS"; then
			print_result "live PR NMR blocks without consulting comment markers" 0
		else
			print_result "live PR NMR blocks without consulting comment markers" 1 "missing blocked output or comments API was queried"
		fi
	else
		print_result "live PR NMR blocks without consulting comment markers" 1 "check-pr job returned non-zero"
	fi
	return 0
}

has_combined_slurp_and_jq() {
	local workflow_file="$1"
	if sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' "$workflow_file" |
		grep 'gh[[:space:]][[:space:]]*api' |
		grep -F -- '--slurp' |
		grep -Fq -- '--jq'; then
		return 0
	fi
	return 1
}

test_slurp_and_jq_are_separate() {
	local combined_fixture="${TEST_ROOT}/combined-flags.sh"
	cat >"$combined_fixture" <<'EOF'
gh api --jq '.[]' \
  --paginate \
  --slurp repos/example/project/issues/1/comments
EOF
	if has_combined_slurp_and_jq "$combined_fixture"; then
		print_result "slurp/jq detector handles reordered multiline flags" 0
	else
		print_result "slurp/jq detector handles reordered multiline flags" 1 "forbidden fixture was not detected"
	fi

	if has_combined_slurp_and_jq "$WORKFLOW_FILE"; then
		print_result "maintainer gate separates gh --slurp from jq" 1 "unsupported gh flag combination remains"
	else
		print_result "maintainer gate separates gh --slurp from jq" 0
	fi
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_issue_approval_paths
	test_pr_approval_paths
	test_live_pr_nmr_blocks_before_comments
	test_slurp_and_jq_are_separate
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
