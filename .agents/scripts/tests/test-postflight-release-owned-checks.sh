#!/usr/bin/env bash
# shellcheck disable=SC2016 # Workflow assertions intentionally match literal expressions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FILTER="${REPO_ROOT}/.agents/scripts/jq/release-owned-check-runs.jq"
OUTCOME_FILTER="${REPO_ROOT}/.agents/scripts/jq/postflight-check-outcome.jq"
WORKFLOW_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-release-workflow-runs.json"
CHECK_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-release-owned-check-runs.json"
RECOVERY_FIXTURE="${SCRIPT_DIR}/fixtures/postflight-recovery-workflow-runs.json"
RELEASE_RUNS=$(jq -c . "$WORKFLOW_FIXTURE")
RECOVERY_RUNS=$(jq -c . "$RECOVERY_FIXTURE")
TEST_RELEASE_TAG="v1.2.3"

scope_checks() {
	jq -c \
		--arg release_sha "release-sha" \
		--arg release_tag "$TEST_RELEASE_TAG" \
		--arg self_name "Verify Release Health" \
		--slurpfile release_run_documents <(printf '%s\n' "$RELEASE_RUNS") \
		--slurpfile recovery_run_documents <(printf '%s\n' "$RECOVERY_RUNS") \
		-f "$FILTER"
	return 0
}

classify_outcome() {
	jq -c -f "$OUTCOME_FILTER"
	return 0
}

SCOPED=$(scope_checks <"$CHECK_FIXTURE")
OUTCOME=$(classify_outcome <<<"$SCOPED")

jq -e '
  (.check_runs | length) == 2 and
  any(.check_runs[]; .name == "Framework Validation" and .check_suite.id == 501) and
  any(.check_runs[]; .name == "Publish GitHub, npm, and Homebrew" and .recovery_workflow_run_id == 1101) and
  all(.check_runs[]; .status == "completed" and .conclusion == "success") and
  (.advisory_check_runs | length) == 2 and
  any(.advisory_check_runs[];
    .name == "Socket Security: Project Report" and
    .status == "in_progress" and
    .classification == "advisory" and
    .classification_reason == "external-provider") and
  any(.advisory_check_runs[];
    .name == "Qlty Smell Threshold" and
    .conclusion == "failure" and
    .classification == "advisory" and
    .classification_reason == "baseline-ratchet-covered-by-pr-regression-gate") and
  all(.check_runs[]; .classification == "required") and
  (all((.check_runs + .advisory_check_runs)[]; .name != "Verify Release Health")) and
  (.unrelated_workflow_runs | length) == 2 and
  [.unrelated_workflow_runs[].event] == ["issues", "issue_comment"] and
  (.recovery_workflow_runs | length) == 1 and
  .recovery_workflow_runs[0].id == 1101
' <<<"$SCOPED" >/dev/null
jq -e '
  .required.total == 2 and
  (.required.pending | length) == 0 and
  (.required.failed | length) == 0 and
  (.advisory.pending | length) == 1 and
  any(.advisory.failed[]; .name == "Qlty Smell Threshold")
' <<<"$OUTCOME" >/dev/null

ACCEPTED_CONCLUSIONS=$(jq -cn '{
  check_runs: (["success", "neutral", "skipped"] | map({
    name: ("Accepted " + .),
    status: "completed",
    conclusion: .,
    classification: "required",
    classification_reason: "test-fixture"
  })),
  advisory_check_runs: []
}')
jq -e '
  (.required.accepted | length) == 3 and
  (.required.failed | length) == 0 and
  ([.required.accepted[].conclusion] == ["success", "neutral", "skipped"])
' <<<"$(classify_outcome <<<"$ACCEPTED_CONCLUSIONS")" >/dev/null

printf 'PASS: superseded, self, and unrelated checks do not delay successful release checks\n'
printf 'PASS: pending external checks are classified as non-required advisories\n'
printf 'PASS: absolute Qlty baseline failure is advisory after the PR regression gate\n'
printf 'PASS: newer unrelated issue and comment runs are reported separately\n'
printf 'PASS: exact-tag recovery success supersedes only its earlier publication failure\n'
printf 'PASS: malformed, other-tag, and wrong-workflow recovery identities are ignored\n'
printf 'PASS: explicitly accepted terminal conclusions remain non-blocking\n'

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

RELEASE_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1001)) |=
  (.status = "completed" | .conclusion = "failure")' "$WORKFLOW_FIXTURE")
ADVISORY_AGGREGATE_FAILURE=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'all(.check_runs[]; .classification_reason != "release-owned-workflow")' \
	<<<"$ADVISORY_AGGREGATE_FAILURE" >/dev/null
jq -e '
  (.required.failed | length) == 0 and
  any(.advisory.failed[]; .name == "Qlty Smell Threshold")
' <<<"$(classify_outcome <<<"$ADVISORY_AGGREGATE_FAILURE")" >/dev/null

printf 'PASS: advisory suite failure does not re-block through workflow aggregate\n'

for conclusion in cancelled timed_out action_required startup_failure stale; do
	RELEASE_RUNS=$(jq -c --arg conclusion "$conclusion" \
		'(.workflow_runs[] | select(.id == 1001)) |=
      (.status = "completed" | .conclusion = $conclusion)' "$WORKFLOW_FIXTURE")
	ADVISORY_WITH_BLOCKING_AGGREGATE=$(scope_checks <"$CHECK_FIXTURE")
	jq -e --arg conclusion "$conclusion" 'any(.required.failed[];
    .name == "Workflow .github/workflows/code-quality.yml" and
    .conclusion == $conclusion)' \
		<<<"$(classify_outcome <<<"$ADVISORY_WITH_BLOCKING_AGGREGATE")" >/dev/null
done

printf 'PASS: advisory failure cannot hide non-failure workflow conclusions\n'

RELEASE_RUNS=$(jq -c '.workflow_runs += [{
  "id": 1013,
  "name": "Other Quality Gate",
  "event": "push",
  "path": ".github/workflows/other-quality.yml",
  "head_sha": "release-sha",
  "check_suite_id": 514,
  "status": "completed",
  "conclusion": "failure"
}]' "$WORKFLOW_FIXTURE")
SAME_NAME_REQUIRED_INPUT=$(jq '.check_runs += [{
  "id": 2018,
  "name": "Qlty Smell Threshold",
  "status": "completed",
  "conclusion": "failure",
  "check_suite": {"id": 514},
  "app": {"slug": "github-actions"}
}]' "$CHECK_FIXTURE")
SAME_NAME_REQUIRED=$(scope_checks <<<"$SAME_NAME_REQUIRED_INPUT")
jq -e 'any(.required.failed[];
  .name == "Qlty Smell Threshold" and
  .workflow_path == ".github/workflows/other-quality.yml")' \
	<<<"$(classify_outcome <<<"$SAME_NAME_REQUIRED")" >/dev/null

printf 'PASS: Qlty advisory classification requires exact workflow provenance\n'

RELEASE_RUNS=$(jq -c '.workflow_runs += [{
  "id": 1006,
  "name": "Startup Failure",
  "event": "push",
  "path": ".github/workflows/startup-failure.yml",
  "head_sha": "release-sha",
  "check_suite_id": 507,
  "status": "completed",
  "conclusion": "startup_failure",
  "created_at": "2026-07-13T20:02:00Z",
  "updated_at": "2026-07-13T20:02:01Z"
}]' "$WORKFLOW_FIXTURE")
STARTUP_RELEASE_RUNS="$RELEASE_RUNS"
STARTUP_FAILURE=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.check_runs[];
  .name == "Workflow .github/workflows/startup-failure.yml" and
  .classification_reason == "release-owned-workflow" and
  .conclusion == "startup_failure")' <<<"$STARTUP_FAILURE" >/dev/null
jq -e 'any(.required.failed[];
  .name == "Workflow .github/workflows/startup-failure.yml" and
  .conclusion == "startup_failure")' \
	<<<"$(classify_outcome <<<"$STARTUP_FAILURE")" >/dev/null

RELEASE_RUNS=$(jq -c '.workflow_runs += [
  {"id": 1007, "name": "Failure", "event": "push", "path": ".github/workflows/failure.yml", "head_sha": "release-sha", "check_suite_id": 508, "status": "completed", "conclusion": "failure"},
  {"id": 1008, "name": "Cancelled", "event": "push", "path": ".github/workflows/cancelled.yml", "head_sha": "release-sha", "check_suite_id": 509, "status": "completed", "conclusion": "cancelled"},
  {"id": 1009, "name": "Timed Out", "event": "push", "path": ".github/workflows/timed-out.yml", "head_sha": "release-sha", "check_suite_id": 510, "status": "completed", "conclusion": "timed_out"},
  {"id": 1010, "name": "Action Required", "event": "push", "path": ".github/workflows/action-required.yml", "head_sha": "release-sha", "check_suite_id": 511, "status": "completed", "conclusion": "action_required"},
  {"id": 1011, "name": "Stale", "event": "push", "path": ".github/workflows/stale.yml", "head_sha": "release-sha", "check_suite_id": 512, "status": "completed", "conclusion": "stale"}
]' <<<"$RELEASE_RUNS")
BLOCKING_WITH_CHECK_INPUT=$(jq '.check_runs += [
  {"id": 2011, "name": "Startup Placeholder", "status": "completed", "conclusion": "success", "check_suite": {"id": 507}, "app": {"slug": "github-actions"}},
  {"id": 2012, "name": "Failure Placeholder", "status": "completed", "conclusion": "success", "check_suite": {"id": 508}, "app": {"slug": "github-actions"}},
  {"id": 2013, "name": "Cancelled Placeholder", "status": "completed", "conclusion": "neutral", "check_suite": {"id": 509}, "app": {"slug": "github-actions"}},
  {"id": 2014, "name": "Timed Out Placeholder", "status": "completed", "conclusion": "skipped", "check_suite": {"id": 510}, "app": {"slug": "github-actions"}},
  {"id": 2015, "name": "Action Required Placeholder", "status": "completed", "conclusion": "success", "check_suite": {"id": 511}, "app": {"slug": "github-actions"}},
  {"id": 2016, "name": "Stale Placeholder", "status": "completed", "conclusion": "success", "check_suite": {"id": 512}, "app": {"slug": "github-actions"}}
]' "$CHECK_FIXTURE")
BLOCKING_WITH_CHECK=$(scope_checks <<<"$BLOCKING_WITH_CHECK_INPUT")
jq -e '
  (["startup_failure", "failure", "cancelled", "timed_out", "action_required", "stale"] -
    [.required.failed[] | select(.classification_reason == "release-owned-workflow") | .conclusion]
  ) | length == 0
' <<<"$(classify_outcome <<<"$BLOCKING_WITH_CHECK")" >/dev/null

RELEASE_RUNS=$(jq -c '.workflow_runs += [{
  "id": 1012,
  "name": "Startup Failure",
  "event": "push",
  "path": ".github/workflows/startup-failure.yml",
  "head_sha": "release-sha",
  "check_suite_id": 513,
  "status": "completed",
  "conclusion": "success"
}]' <<<"$STARTUP_RELEASE_RUNS")
DISTINCT_INVOCATION_INPUT=$(jq '.check_runs += [
  {"id": 2011, "name": "Startup Placeholder", "status": "completed", "conclusion": "success", "check_suite": {"id": 507}, "app": {"slug": "github-actions"}},
  {"id": 2017, "name": "Startup Placeholder", "status": "completed", "conclusion": "success", "check_suite": {"id": 513}, "app": {"slug": "github-actions"}}
]' "$CHECK_FIXTURE")
DISTINCT_INVOCATIONS=$(scope_checks <<<"$DISTINCT_INVOCATION_INPUT")
jq -e 'any(.check_runs[];
  .name == "Workflow .github/workflows/startup-failure.yml" and
  .workflow_run_id == 1006 and .conclusion == "startup_failure")' \
	<<<"$DISTINCT_INVOCATIONS" >/dev/null

RELEASE_RUNS="$STARTUP_RELEASE_RUNS"
RELEASE_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1006)) |=
  (.status = "queued" | .conclusion = null | .updated_at = null)' <<<"$RELEASE_RUNS")
STARTUP_PENDING=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.required.pending[];
  .name == "Workflow .github/workflows/startup-failure.yml" and .status == "queued")' \
	<<<"$(classify_outcome <<<"$STARTUP_PENDING")" >/dev/null

printf 'PASS: zero-check release workflows remain visible and fail closed\n'
printf 'PASS: distinct workflow invocations remain independent\n'

RELEASE_RUNS=$(jq -c . "$WORKFLOW_FIXTURE")

PRIMARY_INPUT=$(jq 'del(.check_runs[] | select(.name == "Publish GitHub, npm, and Homebrew"))' "$CHECK_FIXTURE")
RECOVERY_RUNS='{"workflow_runs":[]}'
RELEASE_RUNS=$(jq -c 'del(.workflow_runs[] | select(.path == ".github/workflows/publish-packages.yml"))' "$WORKFLOW_FIXTURE")
MISSING_PUBLICATION=$(scope_checks <<<"$PRIMARY_INPUT")
jq -e 'any(.check_runs[];
  .name == "Publish GitHub, npm, and Homebrew" and
  .status == "missing" and
  .classification_reason == "release-publication-missing")' <<<"$MISSING_PUBLICATION" >/dev/null
jq -e 'any(.required.pending[]; .classification_reason == "release-publication-missing")' \
	<<<"$(classify_outcome <<<"$MISSING_PUBLICATION")" >/dev/null

RELEASE_RUNS=$(jq -c '(.workflow_runs[] | select(.path == ".github/workflows/publish-packages.yml")) |=
  (.status = "in_progress" | .conclusion = null)' "$WORKFLOW_FIXTURE")
PENDING_PUBLICATION=$(scope_checks <<<"$PRIMARY_INPUT")
jq -e 'any(.required.pending[];
  .name == "Publish GitHub, npm, and Homebrew" and .status == "in_progress")' \
	<<<"$(classify_outcome <<<"$PENDING_PUBLICATION")" >/dev/null

for conclusion in startup_failure skipped; do
	RELEASE_RUNS=$(jq -c --arg conclusion "$conclusion" \
		'(.workflow_runs[] | select(.path == ".github/workflows/publish-packages.yml")) |=
      (.status = "completed" | .conclusion = $conclusion)' "$WORKFLOW_FIXTURE")
	INVALID_PUBLICATION=$(scope_checks <<<"$PRIMARY_INPUT")
	jq -e --arg conclusion "$conclusion" 'any(.required.failed[];
    .name == "Publish GitHub, npm, and Homebrew" and .conclusion == $conclusion)' \
		<<<"$(classify_outcome <<<"$INVALID_PUBLICATION")" >/dev/null
done

RELEASE_RUNS=$(jq -c '(.workflow_runs[] | select(.path == ".github/workflows/publish-packages.yml")) |=
  (.status = "completed" | .conclusion = "success")' "$WORKFLOW_FIXTURE")
SUCCESSFUL_PUBLICATION=$(scope_checks <<<"$PRIMARY_INPUT")
jq -e 'any(.required.accepted[];
  .name == "Publish GitHub, npm, and Homebrew" and .conclusion == "success")' \
	<<<"$(classify_outcome <<<"$SUCCESSFUL_PUBLICATION")" >/dev/null
TEST_RELEASE_TAG=""
MISSING_TAG_PUBLICATION=$(scope_checks <<<"$PRIMARY_INPUT")
jq -e 'any(.required.pending[]; .classification_reason == "release-publication-missing")' \
	<<<"$(classify_outcome <<<"$MISSING_TAG_PUBLICATION")" >/dev/null
TEST_RELEASE_TAG="v9.9.9"
CROSS_TAG_PUBLICATION=$(scope_checks <<<"$PRIMARY_INPUT")
jq -e 'any(.required.pending[]; .classification_reason == "release-publication-missing")' \
	<<<"$(classify_outcome <<<"$CROSS_TAG_PUBLICATION")" >/dev/null
TEST_RELEASE_TAG="v1.2.3"

printf 'PASS: primary publication evidence is mandatory, terminal, and successful\n'

RELEASE_RUNS=$(jq -c . "$WORKFLOW_FIXTURE")
RECOVERY_RUNS=$(jq -c . "$RECOVERY_FIXTURE")

RECOVERY_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1101)) |= (.status = "in_progress" | .conclusion = null)' "$RECOVERY_FIXTURE")
PENDING_RECOVERY=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.check_runs[]; .name == "Publish GitHub, npm, and Homebrew" and .status == "in_progress" and .conclusion == null)' \
	<<<"$PENDING_RECOVERY" >/dev/null

printf 'PASS: matching pending recovery publication remains pending\n'

RECOVERY_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1101)) |= (.conclusion = "failure")' "$RECOVERY_FIXTURE")
FAILED_RECOVERY=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.check_runs[]; .name == "Publish GitHub, npm, and Homebrew" and .status == "completed" and .conclusion == "failure")' \
	<<<"$FAILED_RECOVERY" >/dev/null
jq -e 'any(.required.failed[]; .name == "Publish GitHub, npm, and Homebrew")' \
	<<<"$(classify_outcome <<<"$FAILED_RECOVERY")" >/dev/null

printf 'PASS: matching failed recovery publication remains blocking\n'

for conclusion in startup_failure stale unknown_result; do
	RECOVERY_RUNS=$(jq -c --arg conclusion "$conclusion" \
		'(.workflow_runs[] | select(.id == 1101)) |= (.status = "completed" | .conclusion = $conclusion)' \
		"$RECOVERY_FIXTURE")
	UNKNOWN_RECOVERY=$(scope_checks <"$CHECK_FIXTURE")
	jq -e --arg conclusion "$conclusion" \
		'any(.required.failed[]; .name == "Publish GitHub, npm, and Homebrew" and .conclusion == $conclusion)' \
		<<<"$(classify_outcome <<<"$UNKNOWN_RECOVERY")" >/dev/null
done

RECOVERY_RUNS=$(jq -c '(.workflow_runs[] | select(.id == 1101)) |= (.status = "completed" | .conclusion = null)' "$RECOVERY_FIXTURE")
NULL_RECOVERY=$(scope_checks <"$CHECK_FIXTURE")
jq -e 'any(.required.failed[]; .name == "Publish GitHub, npm, and Homebrew" and .conclusion == null)' \
	<<<"$(classify_outcome <<<"$NULL_RECOVERY")" >/dev/null

printf 'PASS: unknown and missing publication conclusions fail closed\n'

RECOVERY_RUNS=$(jq -c . "$RECOVERY_FIXTURE")

PENDING_INPUT=$(jq '(.check_runs[] | select(.id == 2001)) |= (.status = "in_progress" | .conclusion = null)' "$CHECK_FIXTURE")
PENDING=$(scope_checks <<<"$PENDING_INPUT")
jq -e '[.check_runs[] | select(.status != "completed")] | length == 1' <<<"$PENDING" >/dev/null
jq -e 'any(.required.pending[]; .name == "Framework Validation")' \
	<<<"$(classify_outcome <<<"$PENDING")" >/dev/null

printf 'PASS: pending release-quality checks remain pending\n'

OVERLAPPING_INPUT=$(jq '
  (.check_runs[] | select(.id == 2001)).completed_at = "2026-07-13T20:10:00Z" |
  .check_runs += [{
    "id": 2010,
    "name": "Framework Validation",
    "status": "in_progress",
    "conclusion": null,
    "created_at": "2026-07-13T20:05:00Z",
    "started_at": "2026-07-13T20:05:00Z",
    "check_suite": {"id": 501},
    "app": {"slug": "github-actions"}
  }]
' "$CHECK_FIXTURE")
OVERLAPPING=$(scope_checks <<<"$OVERLAPPING_INPUT")
jq -e 'any(.check_runs[];
  .name == "Framework Validation" and .id == 2010 and .status == "in_progress")' \
	<<<"$OVERLAPPING" >/dev/null
jq -e 'any(.required.pending[]; .name == "Framework Validation" and .id == 2010)' \
	<<<"$(classify_outcome <<<"$OVERLAPPING")" >/dev/null

printf 'PASS: newer pending reruns outrank older late completions\n'

FAILED_INPUT=$(jq '(.check_runs[] | select(.id == 2001)) |= (.conclusion = "failure")' "$CHECK_FIXTURE")
FAILED=$(scope_checks <<<"$FAILED_INPUT")
jq -e 'any(.required.failed[]; .name == "Framework Validation" and .conclusion == "failure")' \
	<<<"$(classify_outcome <<<"$FAILED")" >/dev/null

printf 'PASS: terminal required release-quality failures remain named and blocking\n'

REGRESSION_INPUT=$(jq '.check_runs += [{
  "id": 2009,
  "name": "Qlty Smell Regression",
  "status": "completed",
  "conclusion": "failure",
  "completed_at": "2026-07-13T20:05:00Z",
  "check_suite": {"id": 501},
  "app": {"slug": "github-actions"}
}]' "$CHECK_FIXTURE")
REGRESSION=$(scope_checks <<<"$REGRESSION_INPUT")
jq -e 'any(.check_runs[];
  .name == "Qlty Smell Regression" and
  .conclusion == "failure" and
  .classification == "required" and
  .classification_reason == "release-owned-check")' <<<"$REGRESSION" >/dev/null
jq -e 'any(.required.failed[]; .name == "Qlty Smell Regression" and .conclusion == "failure")' \
	<<<"$(classify_outcome <<<"$REGRESSION")" >/dev/null

printf 'PASS: genuine Qlty regression failures remain required and blocking\n'

grep -Fq "actions/runs?head_sha=\${COMMIT_SHA}&per_page=100" "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'actions/workflows/publish-packages.yml/runs?event=workflow_dispatch&branch=main&per_page=100' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'release-owned-check-runs.jq' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--slurpfile release_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--slurpfile recovery_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--arg release_tag "$RELEASE_TAG"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'RELEASE_TAG: ${{ github.event.inputs.tag || github.event.release.tag_name || github.ref_name }}' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'ref: ${{ github.sha }}' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'git fetch --no-tags origin "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'git rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}"' "${REPO_ROOT}/.github/workflows/postflight.yml"
if grep -Fq 'git rev-parse HEAD' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: postflight resolves the dispatch commit instead of the requested tag\n' >&2
	exit 1
fi
grep -Fq 'Prepare reviewed postflight runtime' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'git cat-file -e "${GITHUB_SHA}^{commit}"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'git worktree add --detach "$RUNTIME_PATH" "$GITHUB_SHA"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'POSTFLIGHT_RUNTIME: ${{ steps.postflight_runtime.outputs.path }}' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.agents/scripts/jq/release-owned-check-runs.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.agents/scripts/jq/postflight-check-outcome.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.github/scripts/effective-check-runs.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '-f "$POSTFLIGHT_RUNTIME/.github/scripts/reconcile-superseded-cancellations.jq"' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'actions/runs?head_sha=${DEFAULT_SHA}&per_page=100' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq -- '--slurpfile workflow_run_documents' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'compare/${COMMIT_SHA}...${DEFAULT_SHA}' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'if [[ "$COMPARE_STATUS" == "ahead" || "$COMPARE_STATUS" == "identical" ]]' "${REPO_ROOT}/.github/workflows/postflight.yml"
if grep -Fq -- '-f .agents/scripts/jq/' "${REPO_ROOT}/.github/workflows/postflight.yml" ||
	grep -Fq -- '-f .github/scripts/' "${REPO_ROOT}/.github/workflows/postflight.yml"; then
	printf 'FAIL: exact-tag postflight executes filters from immutable tag content\n' >&2
	exit 1
fi
grep -Fq 'non-required advisory check(s) remain non-terminal' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'COMPLETE_STREAK=0' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'if [[ "$COMPLETE_STREAK" -ge 2 ]]' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'STABLE_COMPLETE=true' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'Final refresh catches a check' "${REPO_ROOT}/.github/workflows/postflight.yml"
grep -Fq 'baseline-ratchet-covered-by-pr-regression-gate' "$FILTER"
grep -Fq 'accepted_conclusion' "$OUTCOME_FILTER"
grep -Fq 'PR-specific' "${REPO_ROOT}/.github/workflows/code-quality.yml"
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
