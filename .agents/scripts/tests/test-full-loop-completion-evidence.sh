#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "${ROOT}/bin"
receipt_dir="${ROOT}/receipts"
cleanup_receipt_dir="${ROOT}/cleanup-receipts"

cat >"${ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
merge_sha="${COMPLETION_PR_MERGE_SHA:-1111111111111111111111111111111111111111}"
release_mode="${COMPLETION_RELEASE_MODE:-valid}"
if [[ "$*" == *"repos/marcusquinn/aidevops/git/ref/tags/v3.0.0"* ]]; then
	if [[ "$release_mode" == "wrong-tag-commit" ]]; then
		printf '%s\n' '{"ref":"refs/tags/v3.0.0","object":{"type":"commit","sha":"2222222222222222222222222222222222222222"}}'
	else
		jq -cn --arg sha "$merge_sha" '{ref:"refs/tags/v3.0.0",object:{type:"commit",sha:$sha}}'
	fi
	exit 0
fi
if [[ "$*" == *"repos/marcusquinn/aidevops/releases/tags/v3.0.0"* ]]; then
	if [[ "$release_mode" == "draft-release" ]]; then
		printf '%s\n' '{"tag_name":"v3.0.0","draft":true}'
	else
		printf '%s\n' '{"tag_name":"v3.0.0","draft":false}'
	fi
	exit 0
fi
if [[ "$*" == *"repos/marcusquinn/aidevops/actions/runs?event=release"* ]]; then
	case "$release_mode" in
	failed-workflow)
		jq -cn --arg sha "$merge_sha" '{workflow_runs:[{event:"release",status:"completed",conclusion:"failure",head_branch:"v3.0.0",head_sha:$sha}]}'
		;;
	wrong-workflow-tag)
		jq -cn --arg sha "$merge_sha" '{workflow_runs:[{event:"release",status:"completed",conclusion:"success",head_branch:"v3.0.1",head_sha:$sha}]}'
		;;
	*)
		jq -cn --arg sha "$merge_sha" '{workflow_runs:[{event:"release",status:"completed",conclusion:"success",head_branch:"v3.0.0",head_sha:$sha}]}'
		;;
	esac
	exit 0
fi
if [[ "$*" == *"repos/marcusquinn/aidevops/actions/workflows/release.yml/runs?event=push&status=success&per_page=100"* ]]; then
	case "$release_mode" in
	push-failed-workflow)
		jq -cn --arg sha "$merge_sha" '{workflow_runs:[{event:"push",status:"completed",conclusion:"failure",head_branch:"main",head_sha:$sha}]}'
		;;
	push-wrong-event)
		jq -cn --arg sha "$merge_sha" '{workflow_runs:[{event:"workflow_dispatch",status:"completed",conclusion:"success",head_branch:"main",head_sha:$sha}]}'
		;;
	push-wrong-sha)
		printf '%s\n' '{"workflow_runs":[{"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"2222222222222222222222222222222222222222"}]}'
		;;
	*)
		jq -cn --arg sha "$merge_sha" '{workflow_runs:[{event:"push",status:"completed",conclusion:"success",head_branch:"main",head_sha:$sha}]}'
		;;
	esac
	exit 0
fi
if [[ "$*" == *"state,mergedAt,mergeCommit,headRefName,headRefOid,headRepository,isCrossRepository"* ]]; then
	jq -cn \
		--arg head_ref "${COMPLETION_PR_HEAD_REF:-}" \
		--arg head_oid "${COMPLETION_PR_HEAD_OID:-}" \
		--arg head_repo "${COMPLETION_PR_HEAD_REPO:-}" \
		--arg merge_sha "$merge_sha" \
		'{state:"MERGED",mergedAt:"2026-07-11T00:00:00Z",mergeCommit:{oid:$merge_sha},
		  headRefName:$head_ref,headRefOid:$head_oid,headRepository:{nameWithOwner:$head_repo},isCrossRepository:false}'
	exit 0
fi
if [[ "$*" == *"headRefName,headRefOid,headRepository,isCrossRepository"* ]]; then
	jq -cn \
		--arg head_ref "${COMPLETION_PR_HEAD_REF:-}" \
		--arg head_oid "${COMPLETION_PR_HEAD_OID:-}" \
		--arg head_repo "${COMPLETION_PR_HEAD_REPO:-}" \
		'{headRefName:$head_ref,headRefOid:$head_oid,headRepository:{nameWithOwner:$head_repo},isCrossRepository:false}'
	exit 0
fi
call_count=1
if [[ -n "${COMPLETION_PR_STATE_CALLS:-}" ]]; then
	[[ -f "$COMPLETION_PR_STATE_CALLS" ]] && call_count=$(( $(<"$COMPLETION_PR_STATE_CALLS") + 1 ))
	printf '%s\n' "$call_count" >"$COMPLETION_PR_STATE_CALLS"
fi
if [[ -n "${COMPLETION_PR_CACHE_CALLS:-}" ]]; then
	printf '%s\n' "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" >>"$COMPLETION_PR_CACHE_CALLS"
fi
if [[ "${COMPLETION_PR_STATE:-MERGED}" == "API_FAILURE" ]]; then
	exit 70
elif [[ "${COMPLETION_PR_STATE:-MERGED}" == "MERGED" ]] ||
	[[ "${COMPLETION_PR_STATE:-MERGED}" == "STALE_THEN_MERGED" && "$call_count" -gt 1 ]]; then
	jq -cn --arg merge_sha "$merge_sha" '{state:"MERGED",mergedAt:"2026-07-11T00:00:00Z",mergeCommit:{oid:$merge_sha}}'
else
	printf '%s\n' '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
fi
exit 0
STUB
chmod +x "${ROOT}/bin/gh"

cat >"${ROOT}/release-runner.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RELEASE_CALL_LOG:?}"
if [[ "${RELEASE_RUNNER_EXIT:-0}" -eq 0 ]]; then
	receipt_dir="${AIDEVOPS_FULL_LOOP_RECEIPT_DIR:?}"
	repo="${AIDEVOPS_FULL_LOOP_REPO:?}"
	pr_number="${2:?}"
	mkdir -p "$receipt_dir"
	status="${RELEASE_RUNNER_STATUS:-published}"
	receipt_base="${receipt_dir}/${repo//\//_}-${pr_number}"
	printf '%s\n' "$status" >"${receipt_base}.status"
	if [[ "$status" == "superseded" ]]; then
		printf '%s\n' '{"schema_version":1,"status":"superseded","repository":"marcusquinn/aidevops","pr_number":42,"source_merge":"0000000000000000000000000000000000000001","aggregate_pr":99,"aggregate_merge":"0000000000000000000000000000000000000002","release_tag":"v3.0.0","release_commit":"0000000000000000000000000000000000000003","recorded_at":"2026-08-01T00:00:00Z"}' >"${receipt_base}.aggregate.json"
	fi
fi
exit "${RELEASE_RUNNER_EXIT:-0}"
STUB
chmod +x "${ROOT}/release-runner.sh"

runner="${ROOT}/runner.sh"
cat >"$runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
source '${SCRIPTS_DIR}/shared-constants.sh'
[[ -z "\${BOLD+x}" ]] && BOLD=''
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_complete_after_cleanup "\$@"
RUNNER
chmod +x "$runner"

removed_path="${ROOT}/removed-worktree"
cleanup_log="${ROOT}/cleanup.log"
printf '[2026-07-11T00:00:01Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' "$removed_path" >"$cleanup_log"
export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir"
export FULL_LOOP_MERGED_EVIDENCE_ATTEMPTS=2
export FULL_LOOP_MERGED_EVIDENCE_DELAY_SECONDS=0
# shellcheck source=../full-loop-cleanup-receipt.sh
source "${SCRIPTS_DIR}/full-loop-cleanup-receipt.sh"
full_loop_write_cleanup_deferred testorg/repo 42 "$removed_path" feature/test-cleanup \
	"$$" test-session pending FINALIZATION_PENDING >/dev/null

record_runner="${ROOT}/record-runner.sh"
cat >"$record_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_record_no_release "\$@"
RUNNER
chmod +x "$record_runner"

published_record_runner="${ROOT}/published-record-runner.sh"
cat >"$published_record_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_record_published_release "\$@"
RUNNER
chmod +x "$published_record_runner"

finalize_runner="${ROOT}/finalize-runner.sh"
cat >"$finalize_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_finalize_receipt "\$@"
RUNNER
chmod +x "$finalize_runner"

migration_runner="${ROOT}/migration-runner.sh"
cat >"$migration_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_migrate_repository_receipt "\$@"
RUNNER
chmod +x "$migration_runner"

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null
grep -qx 'not-requested' "${receipt_dir}/marcusquinn_aidevops-42.status"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null
printf 'PASS direct merge-only lifecycle records idempotent no-release evidence\n'

published_worktree="${ROOT}/published-release-worktree"
mkdir -p "$published_worktree"
published_cleanup_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops 58 "$published_worktree" \
	feature/published-release "$$" published-release-session pending FINALIZATION_PENDING)
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$published_record_runner" 58 v3.0.0 marcusquinn/aidevops >/dev/null
grep -qx 'published' "${receipt_dir}/marcusquinn_aidevops-58.status"
jq -e '.release_status == "published"' "$published_cleanup_receipt" >/dev/null
cp "$published_cleanup_receipt" "${ROOT}/published-release-receipt-before.json"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$published_record_runner" 58 v3.0.0 marcusquinn/aidevops >/dev/null
cmp -s "$published_cleanup_receipt" "${ROOT}/published-release-receipt-before.json"
printf 'PASS verified manual release records published evidence and reconciles cleanup idempotently\n'

push_published_worktree="${ROOT}/push-published-release-worktree"
mkdir -p "$push_published_worktree"
push_published_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops 61 "$push_published_worktree" \
	feature/push-published-release "$$" push-published-release-session pending FINALIZATION_PENDING)
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$published_record_runner" 61 v3.0.0 marcusquinn/aidevops \
		--workflow release.yml --event push >/dev/null
grep -qx 'published' "${receipt_dir}/marcusquinn_aidevops-61.status"
jq -e '.release_status == "published"' "$push_published_receipt" >/dev/null
printf 'PASS exact repository-owned push workflow records published evidence\n'

for invalid_push_mode in push-failed-workflow push-wrong-event push-wrong-sha; do
	invalid_push_worktree="${ROOT}/invalid-${invalid_push_mode}"
	mkdir -p "$invalid_push_worktree"
	invalid_push_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops 62 "$invalid_push_worktree" \
		feature/invalid-push "$$" invalid-push-session pending FINALIZATION_PENDING)
	cp "$invalid_push_receipt" "${ROOT}/${invalid_push_mode}-before.json"
	if COMPLETION_RELEASE_MODE="$invalid_push_mode" AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
		AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$published_record_runner" 62 v3.0.0 marcusquinn/aidevops \
			--workflow release.yml --event push >/dev/null 2>&1; then
		printf 'FAIL %s evidence recorded a published release\n' "$invalid_push_mode"
		exit 1
	fi
	[[ ! -e "${receipt_dir}/marcusquinn_aidevops-62.status" ]]
	cmp -s "$invalid_push_receipt" "${ROOT}/${invalid_push_mode}-before.json"
	rm -f "$invalid_push_receipt" "${ROOT}/${invalid_push_mode}-before.json"
done
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$published_record_runner" 62 v3.0.0 marcusquinn/aidevops --event push >/dev/null 2>&1; then
	printf 'FAIL unbound push event recorded a published release\n'
	exit 1
fi
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$published_record_runner" 62 v3.0.0 marcusquinn/aidevops \
		--workflow ../release.yml --event push >/dev/null 2>&1; then
	printf 'FAIL unsafe workflow identifier recorded a published release\n'
	exit 1
fi
printf 'PASS failed, mismatched, unbound, and unsafe push workflow evidence fails closed\n'

for invalid_release_mode in wrong-tag-commit draft-release failed-workflow wrong-workflow-tag; do
	invalid_published_worktree="${ROOT}/invalid-published-${invalid_release_mode}"
	invalid_published_pr=59
	mkdir -p "$invalid_published_worktree"
	invalid_published_cleanup_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops "$invalid_published_pr" \
		"$invalid_published_worktree" feature/invalid-published "$$" invalid-published-session pending FINALIZATION_PENDING)
	cp "$invalid_published_cleanup_receipt" "${ROOT}/invalid-published-${invalid_release_mode}-before.json"
	if COMPLETION_RELEASE_MODE="$invalid_release_mode" AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
		AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$published_record_runner" "$invalid_published_pr" v3.0.0 marcusquinn/aidevops >/dev/null 2>&1; then
		printf 'FAIL %s evidence recorded a published release\n' "$invalid_release_mode"
		exit 1
	fi
	[[ ! -e "${receipt_dir}/marcusquinn_aidevops-${invalid_published_pr}.status" ]]
	cmp -s "$invalid_published_cleanup_receipt" "${ROOT}/invalid-published-${invalid_release_mode}-before.json"
	rm -f "$invalid_published_cleanup_receipt" "${ROOT}/invalid-published-${invalid_release_mode}-before.json"
done
printf 'PASS forged tags, draft releases, and non-successful release workflows leave receipts unchanged\n'

printf '%s\n' not-requested >"${receipt_dir}/marcusquinn_aidevops-60.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$published_record_runner" 60 v3.0.0 marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL conflicting terminal release receipt was replaced by published evidence\n'
	exit 1
fi
grep -qx 'not-requested' "${receipt_dir}/marcusquinn_aidevops-60.status"
printf 'PASS conflicting terminal receipts cannot be replaced by manual publication evidence\n'

direct_worktree="${ROOT}/direct-merge-worktree"
mkdir -p "$direct_worktree"
direct_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops 42 "$direct_worktree" feature/direct \
	"$$" direct-session pending FINALIZATION_PENDING)
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$finalize_runner" 42 marcusquinn/aidevops >/dev/null
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "not-requested"' "$direct_receipt" >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$finalize_runner" 42 marcusquinn/aidevops >/dev/null
printf 'PASS direct merge-only receipt finalizes idempotently without local lifecycle state\n'

superseded_worktree="${ROOT}/superseded-worktree"
mkdir -p "$superseded_worktree"
superseded_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops 46 "$superseded_worktree" feature/superseded \
	"$$" superseded-session pending FINALIZATION_PENDING)
supersede_runner="${ROOT}/supersede-runner.sh"
cat >"$supersede_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
_full_loop_write_superseded_release_receipt "\$@"
RUNNER
chmod +x "$supersede_runner"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$supersede_runner" marcusquinn/aidevops 46 \
	"$(printf '%040d' 1)" 99 "$(printf '%040d' 2)" v3.0.0 "$(printf '%040d' 3)"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$finalize_runner" 46 marcusquinn/aidevops >/dev/null
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "superseded"' "$superseded_receipt" >/dev/null
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$record_runner" 46 marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL superseded aggregate evidence was downgraded to no-release\n'
	exit 1
fi
printf 'PASS superseded source receipts finalize truthfully and cannot be downgraded\n'

successor_superseded_worktree="${ROOT}/successor-superseded-worktree"
mkdir -p "$successor_superseded_worktree"
successor_superseded_receipt=$(full_loop_write_cleanup_deferred marcusquinn/aidevops 49 \
	"$successor_superseded_worktree" feature/successor-superseded \
	"$$" successor-superseded-session pending FINALIZATION_PENDING)
successor_supersede_runner="${ROOT}/successor-supersede-runner.sh"
cat >"$successor_supersede_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
_full_loop_write_successor_release_receipt "\$@"
RUNNER
chmod +x "$successor_supersede_runner"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$successor_supersede_runner" marcusquinn/aidevops 49 \
	"$(printf '%040d' 1)" v3.0.0 "$(printf '%040d' 3)" 101 \
	99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" 202
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$finalize_runner" 49 marcusquinn/aidevops >/dev/null
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "superseded"' \
	"$successor_superseded_receipt" >/dev/null
jq -e '.evidence_type == "post-publication-supersession" and .source_pr == 49
	and .source_workflow_run == 101 and .successor_pr == 99 and .release_workflow_run == 202
	and .source_release_tag == "v3.0.0" and .release_tag == "v3.0.1"' \
	"${receipt_dir}/marcusquinn_aidevops-49.successor.json" >/dev/null
cp "${receipt_dir}/marcusquinn_aidevops-49.successor.json" "${ROOT}/successor-evidence-before.json"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$successor_supersede_runner" marcusquinn/aidevops 49 \
	"$(printf '%040d' 1)" v3.0.0 "$(printf '%040d' 3)" 101 \
	99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" 202
cmp -s "${receipt_dir}/marcusquinn_aidevops-49.successor.json" "${ROOT}/successor-evidence-before.json"

printf '%s\n' failed >"${receipt_dir}/marcusquinn_aidevops-50.status"
cp "${receipt_dir}/marcusquinn_aidevops-46.aggregate.json" \
	"${receipt_dir}/marcusquinn_aidevops-50.aggregate.json"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$successor_supersede_runner" marcusquinn/aidevops 50 \
	"$(printf '%040d' 1)" v3.0.0 "$(printf '%040d' 3)" 101 \
	99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" 202 >/dev/null 2>&1; then
	printf 'FAIL aggregate evidence allowed a conflicting post-publication supersession receipt\n'
	exit 1
fi
grep -qx 'failed' "${receipt_dir}/marcusquinn_aidevops-50.status"
[[ ! -e "${receipt_dir}/marcusquinn_aidevops-50.successor.json" ]]

AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$successor_supersede_runner" marcusquinn/aidevops 52 \
	"$(printf '%040d' 1)" v3.0.0 "$(printf '%040d' 3)" 101 \
	99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" 202
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$supersede_runner" marcusquinn/aidevops 52 \
	"$(printf '%040d' 1)" 99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" >/dev/null 2>&1; then
	printf 'FAIL successor evidence allowed conflicting aggregate provenance\n'
	exit 1
fi
[[ -f "${receipt_dir}/marcusquinn_aidevops-52.successor.json" ]]
[[ ! -e "${receipt_dir}/marcusquinn_aidevops-52.aggregate.json" ]]
printf 'PASS post-publication successor receipts finalize idempotently without fabricating aggregate provenance\n'

alias_canonical="${ROOT}/alias-canonical"
alias_worktree="${ROOT}/alias-worktree"
alias_branch="bugfix/repair-pr-head"
alias_pr_head="$alias_branch"
alias_repo="marcusquinn/aidevops"
fixture_git="${AIDEVOPS_TEST_GIT_BIN:-$(command -p -v git)}"
mkdir -p "$alias_canonical"
"$fixture_git" -C "$alias_canonical" init -q -b main
"$fixture_git" -C "$alias_canonical" config user.email test@example.invalid
"$fixture_git" -C "$alias_canonical" config user.name 'Aidevops Test'
"$fixture_git" -C "$alias_canonical" config commit.gpgsign false
printf 'alias fixture\n' >"${alias_canonical}/README.md"
"$fixture_git" -C "$alias_canonical" add README.md
"$fixture_git" -C "$alias_canonical" commit -q -m 'init alias fixture'
"$fixture_git" -C "$alias_canonical" worktree add -q "$alias_worktree" -b "$alias_branch"
alias_head=$("$fixture_git" -C "$alias_worktree" rev-parse HEAD)
"$fixture_git" -C "$alias_worktree" remote add pr-head "https://github.com/${alias_repo}.git"

adopt_receipt_runner="${ROOT}/adopt-receipt-runner.sh"
cat >"$adopt_receipt_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
source '${SCRIPTS_DIR}/full-loop-helper-merge.sh'
cd "\$1"
cmd_adopt_merged_receipt "\$2" "\$3"
RUNNER
chmod +x "$adopt_receipt_runner"

COMPLETION_PR_HEAD_REF="$alias_pr_head" \
	COMPLETION_PR_HEAD_OID="$alias_head" \
	COMPLETION_PR_HEAD_REPO="$alias_repo" \
	AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$record_runner" 43 "$alias_repo" >/dev/null
COMPLETION_PR_HEAD_REF="$alias_pr_head" \
	COMPLETION_PR_HEAD_OID="$alias_head" \
	COMPLETION_PR_HEAD_REPO="$alias_repo" \
	AIDEVOPS_SESSION_ID=completion-alias \
	AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$adopt_receipt_runner" "$alias_worktree" 43 "$alias_repo" >/dev/null
alias_receipt="${cleanup_receipt_dir}/marcusquinn_aidevops-43.json"
jq -e --arg branch "$alias_branch" '
	.executor_completion_state == "FINALIZATION_PENDING"
	and .resource_cleanup_state == "CLEANUP_DEFERRED"
	and .release_status == "not-requested"
	and .branch == $branch
' "$alias_receipt" >/dev/null
cp "$alias_receipt" "${ROOT}/adopted-receipt-before.json"
COMPLETION_PR_HEAD_REF="$alias_pr_head" COMPLETION_PR_HEAD_OID="$alias_head" COMPLETION_PR_HEAD_REPO="$alias_repo" \
	AIDEVOPS_SESSION_ID=completion-alias AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$adopt_receipt_runner" "$alias_worktree" 43 "$alias_repo" >/dev/null
cmp -s "$alias_receipt" "${ROOT}/adopted-receipt-before.json"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$finalize_runner" 43 "$alias_repo" >/dev/null
jq -e --arg branch "$alias_branch" '
	.executor_completion_state == "COMPLETE"
	and .resource_cleanup_state == "CLEANUP_DEFERRED"
	and .release_status == "not-requested"
	and .branch == $branch
' "$alias_receipt" >/dev/null
printf 'PASS public merged-receipt adoption is idempotent and flows through finalization\n'

cp "$direct_receipt" "${ROOT}/direct-receipt-before.json"
if COMPLETION_PR_STATE=OPEN AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$finalize_runner" 42 marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL open PR finalized a direct-merge receipt\n'
	exit 1
fi
cmp -s "$direct_receipt" "${ROOT}/direct-receipt-before.json"
printf 'PASS rejected finalization leaves cleanup evidence unchanged\n'

migration_worktree="${ROOT}/migration-worktree"
mkdir -p "$migration_worktree"
migration_receipt=$(full_loop_write_cleanup_deferred example/old-repo 44 "$migration_worktree" feature/migrate \
	"$$" migration-session not-requested FINALIZATION_PENDING)
full_loop_transition_cleanup_receipt "$migration_receipt" "$_FULL_LOOP_CLEANUP_LEASED" "$$"
migration_created=$(jq -r '.created_at' "$migration_receipt")
mkdir -p "$receipt_dir"
printf '%s\n' not-requested >"${receipt_dir}/example_old-repo-44.status"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 44 example/old-repo example/renamed-repo >/dev/null
migrated_receipt="${cleanup_receipt_dir}/example_renamed-repo-44.json"
[[ ! -e "${cleanup_receipt_dir}/example_old-repo-44.json" ]]
[[ ! -e "${receipt_dir}/example_old-repo-44.status" ]]
grep -qx 'not-requested' "${receipt_dir}/example_renamed-repo-44.status"
jq -e --arg created "$migration_created" --argjson lease_pid "$$" '
	.repository == "example/renamed-repo"
	and .created_at == $created
	and .owner.session == "migration-session"
	and .resource_cleanup_state == "CLEANUP_LEASED"
	and .cleanup_lease.pid == $lease_pid
	and .migration.from_repository == "example/old-repo"
' "$migrated_receipt" >/dev/null
full_loop_cleanup_owner_alive "$migrated_receipt"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 44 example/old-repo example/renamed-repo >/dev/null
printf 'PASS repository migration preserves owner, lease, creation, cleanup, and release evidence idempotently\n'

successor_migration_worktree="${ROOT}/successor-migration-worktree"
mkdir -p "$successor_migration_worktree"
full_loop_write_cleanup_deferred example/successor-old 51 "$successor_migration_worktree" \
	feature/successor-migration "$$" successor-migration-session pending FINALIZATION_PENDING >/dev/null
printf '%s\n' superseded >"${receipt_dir}/example_successor-old-51.status"
jq -cn '{schema_version:1,evidence_type:"post-publication-supersession",status:"superseded",
	repository:"example/successor-old",pr_number:51,source_pr:51,source_merge:("1" * 40),
	source_release_tag:"v3.0.0",source_release_commit:("2" * 40),source_workflow_run:101,
	successor_pr:99,successor_merge:("3" * 40),release_tag:"v3.0.1",
	release_commit:("4" * 40),release_workflow_run:202,recorded_at:"2026-08-01T00:00:00Z"}' \
	>"${receipt_dir}/example_successor-old-51.successor.json"
full_loop_update_cleanup_release_status example/successor-old 51 superseded
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 51 example/successor-old example/successor-new >/dev/null
[[ ! -e "${receipt_dir}/example_successor-old-51.status" ]]
[[ ! -e "${receipt_dir}/example_successor-old-51.successor.json" ]]
grep -qx 'superseded' "${receipt_dir}/example_successor-new-51.status"
jq -e '.repository == "example/successor-new" and .source_pr == 51
	and .migration.from_repository == "example/successor-old"' \
	"${receipt_dir}/example_successor-new-51.successor.json" >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 51 example/successor-old example/successor-new >/dev/null
printf 'PASS repository migration preserves distinct post-publication supersession evidence idempotently\n'

malformed_migration_worktree="${ROOT}/malformed-migration-worktree"
mkdir -p "$malformed_migration_worktree"
full_loop_write_cleanup_deferred example/malformed-old 53 "$malformed_migration_worktree" \
	feature/malformed-migration "$$" malformed-migration-session pending FINALIZATION_PENDING >/dev/null
printf '%s\n' superseded >"${receipt_dir}/example_malformed-old-53.status"
jq -cn '{schema_version:1,evidence_type:"post-publication-supersession",status:"superseded",
	repository:"example/malformed-old",pr_number:53,source_pr:53,successor_pr:99}' \
	>"${receipt_dir}/example_malformed-old-53.successor.json"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 53 example/malformed-old example/malformed-new >/dev/null 2>&1; then
	printf 'FAIL repository migration accepted an incomplete successor evidence schema\n'
	exit 1
fi
[[ -f "${cleanup_receipt_dir}/example_malformed-old-53.json" ]]
[[ -f "${receipt_dir}/example_malformed-old-53.status" ]]
[[ -f "${receipt_dir}/example_malformed-old-53.successor.json" ]]
[[ ! -e "${cleanup_receipt_dir}/example_malformed-new-53.json" ]]
printf 'PASS repository migration rejects incomplete supersession evidence without deleting its source\n'

evidence_conflict_worktree="${ROOT}/evidence-conflict-worktree"
mkdir -p "$evidence_conflict_worktree"
full_loop_write_cleanup_deferred example/evidence-old 54 "$evidence_conflict_worktree" \
	feature/evidence-conflict "$$" evidence-conflict-session pending FINALIZATION_PENDING >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$successor_supersede_runner" example/evidence-old 54 \
	"$(printf '%040d' 1)" v3.0.0 "$(printf '%040d' 3)" 101 \
	99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" 202
jq --arg repo example/evidence-new --arg old_repo example/evidence-old \
	'.repository = $repo | .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:"2026-08-01T01:00:00Z"}' \
	"${cleanup_receipt_dir}/example_evidence-old-54.json" \
	>"${cleanup_receipt_dir}/example_evidence-new-54.json"
printf '%s\n' superseded >"${receipt_dir}/example_evidence-new-54.status"
jq --arg repo example/evidence-new --arg old_repo example/evidence-old \
	'.repository = $repo | .release_workflow_run = 303
	| .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:"2026-08-01T01:00:00Z"}' \
	"${receipt_dir}/example_evidence-old-54.successor.json" \
	>"${receipt_dir}/example_evidence-new-54.successor.json"
cp "${receipt_dir}/example_evidence-old-54.successor.json" "${ROOT}/evidence-conflict-source-before.json"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 54 example/evidence-old example/evidence-new >/dev/null 2>&1; then
	printf 'FAIL conflicting complete destination evidence reported a successful migration\n'
	exit 1
fi
cmp -s "${receipt_dir}/example_evidence-old-54.successor.json" "${ROOT}/evidence-conflict-source-before.json"
[[ -f "${cleanup_receipt_dir}/example_evidence-old-54.json" ]]
jq -e '.release_workflow_run == 303' "${receipt_dir}/example_evidence-new-54.successor.json" >/dev/null
printf 'PASS conflicting complete destination evidence cannot delete a valid migration source\n'

partial_migration_worktree="${ROOT}/partial-migration-worktree"
mkdir -p "$partial_migration_worktree"
full_loop_write_cleanup_deferred example/partial-old 55 "$partial_migration_worktree" \
	feature/partial-migration "$$" partial-migration-session pending FINALIZATION_PENDING >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	bash "$successor_supersede_runner" example/partial-old 55 \
	"$(printf '%040d' 1)" v3.0.0 "$(printf '%040d' 3)" 101 \
	99 "$(printf '%040d' 2)" v3.0.1 "$(printf '%040d' 4)" 202
jq --arg repo example/partial-new --arg old_repo example/partial-old \
	'.repository = $repo | .updated_at = "2026-08-01T02:00:00Z"
	| .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:"2026-08-01T02:00:00Z"}' \
	"${cleanup_receipt_dir}/example_partial-old-55.json" \
	>"${cleanup_receipt_dir}/example_partial-new-55.json"
jq --arg repo example/partial-new --arg old_repo example/partial-old \
	'.repository = $repo | .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:"2026-08-01T02:00:00Z"}' \
	"${receipt_dir}/example_partial-old-55.successor.json" \
	>"${receipt_dir}/example_partial-new-55.successor.json"
[[ ! -e "${receipt_dir}/example_partial-new-55.status" ]]
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 55 example/partial-old example/partial-new >/dev/null
[[ ! -e "${cleanup_receipt_dir}/example_partial-old-55.json" ]]
[[ ! -e "${receipt_dir}/example_partial-old-55.status" ]]
[[ ! -e "${receipt_dir}/example_partial-old-55.successor.json" ]]
grep -qx 'superseded' "${receipt_dir}/example_partial-new-55.status"
jq -e '.repository == "example/partial-new" and .source_pr == 55
	and .release_workflow_run == 202 and .migration.from_repository == "example/partial-old"' \
	"${receipt_dir}/example_partial-new-55.successor.json" >/dev/null
printf 'PASS repository migration recovers verified partial destination publication idempotently\n'

successor_worktree="${ROOT}/successor-worktree"
mkdir -p "$successor_worktree"
full_loop_write_cleanup_deferred example/old-repo 44 "$successor_worktree" feature/successor \
	"$$" successor-session pending FINALIZATION_PENDING >/dev/null
selected_predecessor=$(full_loop_cleanup_receipt_for_worktree "$migration_worktree")
[[ "$selected_predecessor" == "$migrated_receipt" ]]
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 44 example/old-repo example/renamed-repo >/dev/null
[[ -f "${cleanup_receipt_dir}/example_old-repo-44.json" ]]
printf 'PASS old-slug reuse cannot associate the predecessor worktree with the successor receipt\n'

conflict_source_worktree="${ROOT}/conflict-source"
conflict_destination_worktree="${ROOT}/conflict-destination"
mkdir -p "$conflict_source_worktree" "$conflict_destination_worktree"
full_loop_write_cleanup_deferred example/conflict-old 45 "$conflict_source_worktree" feature/conflict-old \
	"$$" conflict-old-session not-requested FINALIZATION_PENDING >/dev/null
full_loop_write_cleanup_deferred example/conflict-new 45 "$conflict_destination_worktree" feature/conflict-new \
	"$$" conflict-new-session not-requested FINALIZATION_PENDING >/dev/null
printf '%s\n' not-requested >"${receipt_dir}/example_conflict-old-45.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$migration_runner" 45 example/conflict-old example/conflict-new >/dev/null 2>&1; then
	printf 'FAIL repository migration accepted conflicting destination evidence\n'
	exit 1
fi
[[ -f "${cleanup_receipt_dir}/example_conflict-old-45.json" ]]
[[ -f "${cleanup_receipt_dir}/example_conflict-new-45.json" ]]
[[ -f "${receipt_dir}/example_conflict-old-45.status" ]]
printf 'PASS repository migration fails closed and preserves conflicting source and destination evidence\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
stale_calls="${ROOT}/stale-evidence-calls.txt"
cache_calls="${ROOT}/stale-evidence-cache-control.txt"
COMPLETION_PR_STATE=STALE_THEN_MERGED \
	COMPLETION_PR_STATE_CALLS="$stale_calls" \
	COMPLETION_PR_CACHE_CALLS="$cache_calls" \
	AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$record_runner" 42 marcusquinn/aidevops >/dev/null
grep -qx 'not-requested' "${receipt_dir}/marcusquinn_aidevops-42.status"
[[ "$(<"$stale_calls")" == "2" ]]
[[ "$(grep -c '^1$' "$cache_calls")" == "2" ]]
printf 'PASS no-release recovers stale evidence through bounded cache-disabled reads\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
if COMPLETION_PR_STATE=API_FAILURE AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL API-indeterminate evidence created no-release evidence\n'
	exit 1
fi
[[ ! -e "${receipt_dir}/marcusquinn_aidevops-42.status" ]]
printf 'PASS API-indeterminate evidence cannot create no-release evidence\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
if COMPLETION_PR_STATE=OPEN AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL open PR created no-release evidence\n'
	exit 1
fi
[[ ! -e "${receipt_dir}/marcusquinn_aidevops-42.status" ]]
printf 'PASS open PR cannot create no-release evidence\n'

printf '%s\n' published >"${receipt_dir}/marcusquinn_aidevops-42.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL published evidence was downgraded to no-release\n'
	exit 1
fi
grep -qx 'published' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS published evidence cannot be downgraded\n'

if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 published marcusquinn/aidevops >/dev/null 2>&1; then
	printf 'FAIL record-no-release accepted a forged status argument\n'
	exit 1
fi
printf 'PASS record-no-release rejects status injection\n'

state_runner="${ROOT}/state-runner.sh"
cat >"$state_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
print_phase() { return 0; }
is_headless() {
	return 1
}
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
mkdir -p "\$STATE_DIR"
RELEASE_INTENT="\${TEST_RELEASE_INTENT:-true}"
RELEASE_TYPE="\${TEST_RELEASE_TYPE:-patch}"
DEPLOYMENT_SCOPE="\${TEST_DEPLOYMENT_SCOPE:-incremental}"
RELEASE_STATUS="\${TEST_RELEASE_STATUS:-authorized}"
CURRENT_PHASE=pr-review
SAVED_PROMPT=test
PR_NUMBER=42
STARTED_AT=2026-07-11T00:00:00Z
save_state pr-review test 42 "\$STARTED_AT"
cmd_resume
load_state
printf '%s\n' "\$RELEASE_STATUS"
RUNNER
chmod +x "$state_runner"

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
: >"${ROOT}/release-calls.log"
flow_env=(AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops AIDEVOPS_FULL_LOOP_RELEASE_RUNNER="${ROOT}/release-runner.sh" RELEASE_CALL_LOG="${ROOT}/release-calls.log")
output=$(env "${flow_env[@]}" TEST_RELEASE_TYPE=minor TEST_DEPLOYMENT_SCOPE=full bash "$state_runner")
status="${output##*$'\n'}"
[[ "$status" == "published" ]]
grep -qx 'minor 42 full' "${ROOT}/release-calls.log"
grep -qx 'published' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS authorized lifecycle invokes release and persists published status\n'

: >"${ROOT}/release-calls.log"
output=$(env "${flow_env[@]}" bash "$state_runner")
status="${output##*$'\n'}"
[[ "$status" == "published" && ! -s "${ROOT}/release-calls.log" ]]
printf 'PASS published detached-release receipt prevents duplicate publication\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status" "${receipt_dir}/marcusquinn_aidevops-42.aggregate.json" \
	"${cleanup_receipt_dir}/marcusquinn_aidevops-42.json"
: >"${ROOT}/release-calls.log"
output=$(env "${flow_env[@]}" RELEASE_RUNNER_STATUS=superseded bash "$state_runner")
status="${output##*$'\n'}"
[[ "$status" == "superseded" ]]
grep -qx 'superseded' "${receipt_dir}/marcusquinn_aidevops-42.status"
grep -q '^release_status: superseded$' "${ROOT}/state/full-loop.state"
printf 'PASS authorized aggregate lifecycle reconciles superseded source state without fabricating publication\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status" "${receipt_dir}/marcusquinn_aidevops-42.aggregate.json"

: >"${ROOT}/release-calls.log"
output=$(env "${flow_env[@]}" TEST_RELEASE_INTENT=false TEST_RELEASE_STATUS=not-requested bash "$state_runner")
status="${output##*$'\n'}"
[[ "$status" == "not-requested" && ! -s "${ROOT}/release-calls.log" ]]
grep -qx 'not-requested' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS merge-only lifecycle persists skipped publication without invoking release\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
if env "${flow_env[@]}" RELEASE_RUNNER_EXIT=1 bash "$state_runner" >/dev/null 2>&1; then
	printf 'FAIL failed release transition returned success\n'
	exit 1
fi
grep -qx 'failed' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS failed publication persists failed status and stops transition\n'

complete_runner="${ROOT}/complete-runner.sh"
cat >"$complete_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_complete
RUNNER
chmod +x "$complete_runner"
if bash "$complete_runner" >/dev/null 2>&1; then
	printf 'FAIL release:failed allowed cleanup handoff\n'
	exit 1
fi
printf 'PASS release:failed blocks cleanup before worktree removal\n'

handoff_runner="${ROOT}/handoff-runner.sh"
cat >"$handoff_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/handoff-state'
STATE_FILE='${ROOT}/handoff-state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
CURRENT_PHASE=complete
SAVED_PROMPT=test
PR_NUMBER="\${TEST_PR_NUMBER:-43}"
STARTED_AT=2026-07-11T00:00:00Z
RELEASE_STATUS="\${TEST_RELEASE_STATUS:-not-requested}"
save_state complete test "\$PR_NUMBER" "\$STARTED_AT"
cmd_complete
cmd_status --json
RUNNER
chmod +x "$handoff_runner"
handoff_output=$(AIDEVOPS_FULL_LOOP_REPO=testorg/repo AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" bash "$handoff_runner")
printf '%s\n' "$handoff_output" | grep -q '<promise>FULL_LOOP_CLEANUP_DEFERRED</promise>'
handoff_json="${handoff_output##*$'\n'}"
printf '%s' "$handoff_json" | jq -e \
	'.executor_completion_state == "COMPLETE" and .resource_cleanup_state == "CLEANUP_DEFERRED"' >/dev/null
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "not-requested"' \
	"${cleanup_receipt_dir}/testorg_repo-43.json" >/dev/null
printf 'PASS interactive completion emits durable executor handoff and machine-readable cleanup state\n'

printf '%s\n' published >"${receipt_dir}/marcusquinn_aidevops-44.status"
published_handoff_output=$(AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
	AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	TEST_PR_NUMBER=44 TEST_RELEASE_STATUS=authorized bash "$handoff_runner")
printf '%s\n' "$published_handoff_output" | grep -q '<promise>FULL_LOOP_CLEANUP_DEFERRED</promise>'
grep -q '^release_status: published$' "${ROOT}/handoff-state/full-loop.state"
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "published"' \
	"${cleanup_receipt_dir}/marcusquinn_aidevops-44.json" >/dev/null
printf 'PASS matching published receipt atomically promotes stale authorized lifecycle state\n'

printf '%s\n' superseded >"${receipt_dir}/marcusquinn_aidevops-47.status"
jq -cn '{schema_version:1,status:"superseded",repository:"marcusquinn/aidevops",pr_number:47,
	source_merge:("1" * 40),aggregate_pr:99,aggregate_merge:("2" * 40),release_tag:"v3.0.0",
	release_commit:("3" * 40),recorded_at:"2026-08-01T00:00:00Z"}' \
	>"${receipt_dir}/marcusquinn_aidevops-47.aggregate.json"
superseded_handoff_output=$(AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops \
	AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	TEST_PR_NUMBER=47 TEST_RELEASE_STATUS=not-requested bash "$handoff_runner")
printf '%s\n' "$superseded_handoff_output" | grep -q '<promise>FULL_LOOP_CLEANUP_DEFERRED</promise>'
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "superseded"' \
	"${cleanup_receipt_dir}/marcusquinn_aidevops-47.json" >/dev/null
AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" TEST_PR_NUMBER=47 TEST_RELEASE_STATUS=not-requested \
	bash "$handoff_runner" >/dev/null
printf 'PASS stale no-release completion converges verified superseded evidence idempotently\n'

printf '%s\n' superseded >"${receipt_dir}/marcusquinn_aidevops-48.status"
jq -cn '{schema_version:1,status:"superseded",repository:"wrong/repo",pr_number:48}' \
	>"${receipt_dir}/marcusquinn_aidevops-48.aggregate.json"
if AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
	AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" TEST_PR_NUMBER=48 TEST_RELEASE_STATUS=not-requested \
	bash "$handoff_runner" >/dev/null 2>&1; then
	printf 'FAIL malformed aggregate evidence allowed stale no-release completion\n'
	exit 1
fi
[[ ! -e "${cleanup_receipt_dir}/marcusquinn_aidevops-48.json" ]]
printf 'PASS malformed aggregate evidence cannot create converged cleanup state\n'

for invalid_case in missing failed mismatched; do
	invalid_pr=45
	rm -f "${receipt_dir}/marcusquinn_aidevops-45.status"
	case "$invalid_case" in
	failed) printf '%s\n' failed >"${receipt_dir}/marcusquinn_aidevops-45.status" ;;
	mismatched) printf '%s\n' published >"${receipt_dir}/other_repo-45.status" ;;
	esac
	if AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
		AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" TEST_PR_NUMBER="$invalid_pr" \
		TEST_RELEASE_STATUS=authorized bash "$handoff_runner" >/dev/null 2>&1; then
		printf 'FAIL %s release receipt allowed stale authorized lifecycle completion\n' "$invalid_case"
		exit 1
	fi
	grep -q '^release_status: authorized$' "${ROOT}/handoff-state/full-loop.state"
done
printf 'PASS missing failed and mismatched receipts keep authorized lifecycle blocked\n'

mkdir -p "$receipt_dir"
printf '%s\n' not-requested >"${receipt_dir}/testorg_repo-42.status"
different_removed_path="${ROOT}/different-removed-worktree"
printf '[2026-07-11T00:00:02Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"$different_removed_path" >>"$cleanup_log"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" wrong/repo >/dev/null 2>&1; then
	printf 'FAIL conflicting repository identity was accepted as complete\n'
	exit 1
fi
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 999 "$removed_path" testorg/repo >/dev/null 2>&1; then
	printf 'FAIL conflicting PR identity was accepted as complete\n'
	exit 1
fi
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$different_removed_path" testorg/repo >/dev/null 2>&1; then
	printf 'FAIL conflicting worktree identity was accepted as complete\n'
	exit 1
fi
jq -e '.resource_cleanup_state == "CLEANUP_DEFERRED" and .executor_completion_state == "FINALIZATION_PENDING"' \
	"${cleanup_receipt_dir}/testorg_repo-42.json" >/dev/null
printf 'PASS completion rejects conflicting repository, PR, and worktree identities without mutation\n'

release_conflict_path="${ROOT}/release-conflict-worktree"
printf '[2026-07-11T00:00:03Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"$release_conflict_path" >>"$cleanup_log"
release_conflict_receipt=$(full_loop_write_cleanup_deferred testorg/repo 49 "$release_conflict_path" \
	feature/release-conflict "$$" release-conflict-session published FINALIZATION_PENDING)
printf '%s\n' not-requested >"${receipt_dir}/testorg_repo-49.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 49 "$release_conflict_path" testorg/repo >/dev/null 2>&1; then
	printf 'FAIL conflicting release identity was accepted as complete\n'
	exit 1
fi
jq -e '.resource_cleanup_state == "CLEANED" and .executor_completion_state == "FINALIZATION_PENDING"
	and .release_status == "published"' "$release_conflict_receipt" >/dev/null
printf 'PASS completion preserves audited cleanup while rejecting conflicting release identity\n'

AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null || {
	printf 'FAIL complete merged and cleaned evidence was rejected\n'
	exit 1
}
jq -e '.resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released"
	and .executor_completion_state == "COMPLETE" and .release_status == "not-requested"
	and (.cleaned_at | length > 0)' \
	"${cleanup_receipt_dir}/testorg_repo-42.json" >/dev/null
printf 'PASS merged removal audit and terminal release evidence finalize the cleanup receipt\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null
full_loop_write_cleanup_deferred marcusquinn/aidevops 42 "$removed_path" feature/test-cleanup "$$" test-session not-requested >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" marcusquinn/aidevops >/dev/null || {
	printf 'FAIL merge-only aidevops lifecycle did not complete with release:not-requested\n'
	exit 1
}
printf 'PASS merge-only aidevops lifecycle skips publication evidence\n'

release_sha="$(printf '%040d' 3)"
release_repo_root="${ROOT}/release-repo"
release_home="${ROOT}/release-home"
release_bin="${ROOT}/release-bin"
postflight_dir="${ROOT}/postflight"
postflight_log="${ROOT}/postflight-calls.log"
mkdir -p "$release_repo_root" "${release_home}/.aidevops/agents" "$release_bin" "$postflight_dir"
printf '%s\n' 3.0.0 >"${release_repo_root}/VERSION"
printf '%s\n' 3.0.0 >"${release_home}/.aidevops/agents/VERSION"

cat >"${release_bin}/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
"rev-parse --show-toplevel")
	printf '%s\n' "${TEST_RELEASE_REPO_ROOT:?}"
	;;
"ls-remote --exit-code --tags origin refs/tags/v3.0.0^{}")
	printf '%s\t%s\n' "${TEST_RELEASE_SHA:?}" 'refs/tags/v3.0.0^{}'
	;;
"worktree list --porcelain") ;;
*) exit 1 ;;
esac
STUB
chmod +x "${release_bin}/git"

cat >"${postflight_dir}/postflight-check.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "${POSTFLIGHT_RELEASE_TAG-unset}" "$*" >>"${TEST_POSTFLIGHT_LOG:?}"
[[ "${POSTFLIGHT_RELEASE_TAG+x}" != x ]]
[[ "$*" == "--quick --sha ${TEST_RELEASE_SHA:?} --tag v3.0.0" ]]
STUB
chmod +x "${postflight_dir}/postflight-check.sh"

release_completion_runner="${ROOT}/release-completion-runner.sh"
cat >"$release_completion_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/release-completion-state'
STATE_FILE='${ROOT}/release-completion-state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
source '${SCRIPTS_DIR}/shared-constants.sh'
[[ -z "\${BOLD+x}" ]] && BOLD=''
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
SCRIPT_DIR='${postflight_dir}'
cmd_complete_after_cleanup "\$@"
RUNNER
chmod +x "$release_completion_runner"

published_removed_path="${ROOT}/published-removed-worktree"
superseded_removed_path="${ROOT}/superseded-removed-worktree"
printf '[2026-08-01T00:00:01Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"$published_removed_path" >>"$cleanup_log"
printf '[2026-08-01T00:00:02Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"$superseded_removed_path" >>"$cleanup_log"
printf '%s\n' published >"${receipt_dir}/marcusquinn_aidevops-56.status"
full_loop_write_cleanup_deferred marcusquinn/aidevops 56 "$published_removed_path" \
	feature/published-cleanup "$$" published-cleanup-session published >/dev/null
printf '%s\n' superseded >"${receipt_dir}/marcusquinn_aidevops-57.status"
jq -cn --arg release_sha "$release_sha" \
	'{schema_version:1,status:"superseded",repository:"marcusquinn/aidevops",pr_number:57,
	  source_merge:("1" * 40),aggregate_pr:99,aggregate_merge:("2" * 40),release_tag:"v3.0.0",
	  release_commit:$release_sha,recorded_at:"2026-08-01T00:00:00Z"}' \
	>"${receipt_dir}/marcusquinn_aidevops-57.aggregate.json"
full_loop_write_cleanup_deferred marcusquinn/aidevops 57 "$superseded_removed_path" \
	feature/superseded-cleanup "$$" superseded-cleanup-session superseded >/dev/null

for release_case in "56:$published_removed_path" "57:$superseded_removed_path"; do
	IFS=: read -r release_pr release_removed_path <<<"$release_case"
	env -u POSTFLIGHT_RELEASE_TAG \
		HOME="$release_home" AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" \
		AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" \
		TEST_RELEASE_REPO_ROOT="$release_repo_root" TEST_RELEASE_SHA="$release_sha" \
		TEST_POSTFLIGHT_LOG="$postflight_log" \
		PATH="${release_bin}:${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$release_completion_runner" "$release_pr" "$release_removed_path" marcusquinn/aidevops >/dev/null
done
[[ "$(wc -l <"$postflight_log" | tr -d ' ')" -eq 2 ]]
grep -qx "unset|--quick --sha ${release_sha} --tag v3.0.0" "$postflight_log"
printf 'PASS published and superseded cleanup pass exact release tags to postflight without environment overrides\n'

printf '%s\n' failed >"${receipt_dir}/marcusquinn_aidevops-42.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" marcusquinn/aidevops >/dev/null; then
	printf 'FAIL release:failed lifecycle was accepted as complete\n'
	exit 1
fi
printf 'PASS release:failed keeps lifecycle open\n'

mkdir -p "$removed_path"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL existing worktree was accepted as cleaned\n'
	exit 1
fi
printf 'PASS existing worktree keeps cleanup pending\n'
rm -rf "$removed_path"

if COMPLETION_PR_STATE=OPEN AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL open PR was accepted as complete\n'
	exit 1
fi
printf 'PASS open PR blocks lifecycle completion\n'

if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="${ROOT}/missing.log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL absent cleanup audit was accepted as complete\n'
	exit 1
fi
printf 'PASS absent cleanup audit blocks lifecycle completion\n'

exit 0
