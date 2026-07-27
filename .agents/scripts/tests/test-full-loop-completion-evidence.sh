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
	printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","mergeCommit":{"oid":"merge123"}}'
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
		printf '%s\n' '{"schema_version":1,"status":"superseded","repository":"marcusquinn/aidevops","pr_number":42,"source_merge":"0000000000000000000000000000000000000001","aggregate_pr":99,"aggregate_merge":"0000000000000000000000000000000000000002","release_tag":"v3.0.0","release_commit":"0000000000000000000000000000000000000003"}' >"${receipt_base}.aggregate.json"
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
full_loop_write_cleanup_deferred testorg/repo 42 "$removed_path" feature/test-cleanup "$$" test-session not-requested >/dev/null

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

alias_canonical="${ROOT}/alias-canonical"
alias_worktree="${ROOT}/alias-worktree"
alias_branch="bugfix/repair-pr-head"
alias_pr_head="feature/original-pr-head"
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

alias_receipt_runner="${ROOT}/alias-receipt-runner.sh"
cat >"$alias_receipt_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-merge.sh'
cd "\$1"
cleanup_plan=\$(_merge_fresh_worktree_cleanup_plan "\$2" "\$3")
[[ -n "\$cleanup_plan" ]]
_merge_record_deferred_cleanup_owner "\$2" "\$3" "\$cleanup_plan"
RUNNER
chmod +x "$alias_receipt_runner"

COMPLETION_PR_HEAD_REF="$alias_pr_head" \
	COMPLETION_PR_HEAD_OID="$alias_head" \
	COMPLETION_PR_HEAD_REPO="$alias_repo" \
	AIDEVOPS_SESSION_ID=completion-alias \
	AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$alias_receipt_runner" "$alias_worktree" 43 "$alias_repo" >/dev/null
alias_receipt="${cleanup_receipt_dir}/marcusquinn_aidevops-43.json"
jq -e --arg branch "$alias_branch" '
	.executor_completion_state == "FINALIZATION_PENDING"
	and .resource_cleanup_state == "CLEANUP_DEFERRED"
	and .branch == $branch
' "$alias_receipt" >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$record_runner" 43 "$alias_repo" >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir" \
	PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" \
	bash "$finalize_runner" 43 "$alias_repo" >/dev/null
jq -e --arg branch "$alias_branch" '
	.executor_completion_state == "COMPLETE"
	and .resource_cleanup_state == "CLEANUP_DEFERRED"
	and .release_status == "not-requested"
	and .branch == $branch
' "$alias_receipt" >/dev/null
printf 'PASS exact-head alias receipt flows through record-no-release and finalize-receipt without reconstruction\n'

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

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status" "${receipt_dir}/marcusquinn_aidevops-42.aggregate.json"
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

AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null || {
	printf 'FAIL complete merged and cleaned evidence was rejected\n'
	exit 1
}
jq -e '.resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released" and (.cleaned_at | length > 0)' \
	"${cleanup_receipt_dir}/testorg_repo-42.json" >/dev/null
printf 'PASS merged and cleaned evidence completes lifecycle\n'

rm -f "${receipt_dir}/marcusquinn_aidevops-42.status"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$record_runner" 42 marcusquinn/aidevops >/dev/null
full_loop_write_cleanup_deferred marcusquinn/aidevops 42 "$removed_path" feature/test-cleanup "$$" test-session not-requested >/dev/null
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" marcusquinn/aidevops >/dev/null || {
	printf 'FAIL merge-only aidevops lifecycle did not complete with release:not-requested\n'
	exit 1
}
printf 'PASS merge-only aidevops lifecycle skips publication evidence\n'

printf '%s\n' failed >"${receipt_dir}/marcusquinn_aidevops-42.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" marcusquinn/aidevops >/dev/null; then
	printf 'FAIL release:failed lifecycle was accepted as complete\n'
	exit 1
fi
printf 'PASS release:failed keeps lifecycle open\n'

mkdir -p "$removed_path"
if AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL existing worktree was accepted as cleaned\n'
	exit 1
fi
printf 'PASS existing worktree keeps cleanup pending\n'
rm -rf "$removed_path"

if COMPLETION_PR_STATE=OPEN AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL open PR was accepted as complete\n'
	exit 1
fi
printf 'PASS open PR blocks lifecycle completion\n'

if AIDEVOPS_CLEANUP_LOG="${ROOT}/missing.log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL absent cleanup audit was accepted as complete\n'
	exit 1
fi
printf 'PASS absent cleanup audit blocks lifecycle completion\n'

exit 0
