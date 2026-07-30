#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FILTER="${REPO_ROOT}/.agents/scripts/jq/release-owned-check-runs.jq"
WORKFLOW_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-release-workflow-runs.json"
CHECK_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-release-owned-check-runs.json"
RECOVERY_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-recovery-workflow-runs.json"
RECOVERY_RUNS=$(jq -c . "$RECOVERY_FIXTURE")

scope_checks() {
	jq -c \
		--arg release_sha "release-sha" \
		--arg release_tag "v1.2.3" \
		--arg self_name "Verify Release Health" \
		--slurpfile release_run_documents "$WORKFLOW_FIXTURE" \
		--slurpfile recovery_run_documents <(printf '%s\n' "$RECOVERY_RUNS") \
		-f "$FILTER"
	return 0
}

SCOPED=$(scope_checks <"$CHECK_FIXTURE")

jq -e '
  (.check_runs | length) == 2 and
  any(.check_runs[]; .name == "Framework Validation" and .check_suite.id == 501) and
  any(.check_runs[]; .name == "Publish GitHub, npm, and Homebrew" and .recovery_workflow_run_id == 1101) and
  all(.check_runs[]; .status == "completed" and .conclusion == "success") and
  (.advisory_check_runs | length) == 1 and
  .advisory_check_runs[0].name == "Socket Security: Project Report" and
  .advisory_check_runs[0].status == "in_progress" and
  (all((.check_runs + .advisory_check_runs)[]; .name != "Verify Release Health")) and
  (.unrelated_workflow_runs | length) == 2 and
  [.unrelated_workflow_runs[].event] == ["issues", "issue_comment"] and
  (.recovery_workflow_runs | length) == 1 and
  .recovery_workflow_runs[0].id == 1101
' <<<"$SCOPED" >/dev/null

printf 'PASS: superseded, self, and unrelated checks do not delay successful release checks\n'
printf 'PASS: pending external checks are classified as non-required advisories\n'
printf 'PASS: newer unrelated issue and comment runs are reported separately\n'
printf 'PASS: exact-tag recovery success supersedes only its earlier publication failure\n'
printf 'PASS: malformed, other-tag, and wrong-workflow recovery identities are ignored\n'

PAGINATED_SCOPED=$(jq -c \
	--arg release_sha "release-sha" \
	--arg release_tag "v1.2.3" \
	--arg self_name "Verify Release Health" \
	--slurpfile release_run_documents <(jq -s '.' "$WORKFLOW_FIXTURE") \
	--slurpfile recovery_run_documents <(jq -s '.' "$RECOVERY_FIXTURE") \
	-f "$FILTER" \
	"$CHECK_FIXTURE")
jq -e '(.check_runs | length) == 2' <<<"$PAGINATED_SCOPED" >/dev/null

printf 'PASS: paginated workflow-run response retains release-owned suites\n'

RECOVERY_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1101)) |= (.status = "in_progress" | .conclusion = null)' "$RECOVERY_FIXTURE")
PENDING_RECOVERY=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.check_runs[]; .name == "Publish GitHub, npm, and Homebrew" and .status == "in_progress" and .conclusion == null)' \
	<<<"$PENDING_RECOVERY" >/dev/null

printf 'PASS: matching pending recovery publication remains pending\n'

RECOVERY_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1101)) |= (.conclusion = "failure")' "$RECOVERY_FIXTURE")
FAILED_RECOVERY=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.check_runs[]; .name == "Publish GitHub, npm, and Homebrew" and .status == "completed" and .conclusion == "failure")' \
	<<<"$FAILED_RECOVERY" >/dev/null

printf 'PASS: matching failed recovery publication remains blocking\n'

RECOVERY_RUNS=$(jq -c . "$RECOVERY_FIXTURE")

PENDING_INPUT=$(jq '(.check_runs[] | select(.id == 2001)) |= (.status = "in_progress" | .conclusion = null)' "$CHECK_FIXTURE")
PENDING=$(scope_checks <<<"$PENDING_INPUT")
jq -e '[.check_runs[] | select(.status != "completed")] | length == 1' <<<"$PENDING" >/dev/null

printf 'PASS: pending release-quality checks remain pending\n'

FAILED_INPUT=$(jq '(.check_runs[] | select(.id == 2001)) |= (.name = "Qlty Code Quality" | .conclusion = "failure")' "$CHECK_FIXTURE")
FAILED=$(scope_checks <<<"$FAILED_INPUT")
jq -e '([.check_runs[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required"))] | length == 1) and any(.check_runs[]; .name == "Qlty Code Quality" and .conclusion == "failure")' <<<"$FAILED" >/dev/null

printf 'PASS: terminal release-quality failures such as Qlty remain named and blocking\n'

grep -Fq "actions/runs?head_sha=\${COMMIT_SHA}&per_page=100" "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'actions/workflows/publish-packages.yml/runs?event=workflow_dispatch&branch=main&per_page=100' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'release-owned-check-runs.jq' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--slurpfile release_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--slurpfile recovery_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--arg release_tag "$RELEASE_TAG"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'RELEASE_TAG: ${{ github.event.inputs.tag || github.event.release.tag_name || github.ref_name }}' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'Prepare reviewed postflight runtime' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'git cat-file -e "${GITHUB_SHA}^{commit}"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'git worktree add --detach "$RUNTIME_PATH" "$GITHUB_SHA"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'POSTFLIGHT_RUNTIME: ${{ steps.postflight_runtime.outputs.path }}' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.agents/scripts/jq/release-owned-check-runs.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.github/scripts/effective-check-runs.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.github/scripts/reconcile-superseded-cancellations.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
if grep -Fq -- '-f .agents/scripts/jq/' "${REPO_ROOT}/.github/workflows/postflight.yml" ||
	grep -Fq -- '-f .github/scripts/' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: exact-tag postflight executes filters from immutable tag content\n' >&2
	exit 1
fi
grep -Fq 'non-required advisory check(s) remain non-terminal' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'load_release_owned_checks' "${REPO_ROOT}/.agents/scripts/postflight-check.sh"
grep -Fq 'unrelated issue/comment workflow run(s) excluded' "${REPO_ROOT}/.agents/scripts/postflight-check.sh"
grep -Fq -- '--reconcile-existing' "${REPO_ROOT}/.github/workflows/publish-packages.yml"
grep -Fq 'actions: write' "${REPO_ROOT}/.github/workflows/publish-packages.yml"
grep -Fq 'Queue exact-tag postflight' "${REPO_ROOT}/.github/workflows/publish-packages.yml"
grep -Fq 'gh workflow run postflight.yml' "${REPO_ROOT}/.github/workflows/publish-packages.yml"
grep -Fq -- '--ref main' "${REPO_ROOT}/.github/workflows/publish-packages.yml"
grep -Fq -- "\"tag=\$RELEASE_TAG\"" "${REPO_ROOT}/.github/workflows/publish-packages.yml"
if grep -Fq "release:" "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: postflight retains an event trigger that can duplicate canonical dispatches\n' >&2
	exit 1
fi

QUEUE_LINE=$(grep -n 'Queue exact-tag postflight' "${REPO_ROOT}/.github/workflows/publish-packages.yml" | cut -d: -f1)
VERIFY_LINE=$(grep -n 'Verify Homebrew tap' "${REPO_ROOT}/.github/workflows/publish-packages.yml" | cut -d: -f1)
if [[ "$QUEUE_LINE" -le "$VERIFY_LINE" ]]; then
	printf 'FAIL: postflight dispatch must follow final package verification\n' >&2
	exit 1
fi

printf 'PASS: postflight dispatches one canonical exact-tag run after publication verification\n'
