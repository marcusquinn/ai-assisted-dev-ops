#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../issue-sync-helper.sh
source "${SCRIPTS_DIR}/issue-sync-helper.sh"

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

deadline_probe() {
	printf 'called\n' >>"${TMP_DIR}/deadline-probe.log"
	return 0
}

: >"${TMP_DIR}/deadline-probe.log"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) - 1 ))
deadline_rc=0
_gh_with_timeout read deadline_probe || deadline_rc=$?
[[ "$deadline_rc" -eq 124 ]] || fail "expired aggregate deadline did not return 124"
[[ ! -s "${TMP_DIR}/deadline-probe.log" ]] || fail "expired aggregate deadline invoked the child command"
pass "expired aggregate deadline stops before the next GitHub call"

cat >"${TMP_DIR}/slow-command" <<'SLOW_EOF'
#!/usr/bin/env bash
sleep 5
printf 'late\n'
SLOW_EOF
chmod +x "${TMP_DIR}/slow-command"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 1 ))
started_at=$(date +%s)
slow_rc=0
_gh_with_timeout write "${TMP_DIR}/slow-command" >/dev/null 2>&1 || slow_rc=$?
elapsed=$(( $(date +%s) - started_at ))
[[ "$slow_rc" -eq 124 ]] || fail "remaining aggregate budget did not cap a slow child"
[[ "$elapsed" -le 3 ]] || fail "slow child exceeded aggregate deadline allowance (${elapsed}s)"
pass "remaining aggregate budget caps an individual slow call"

slow_function_probe() {
	sleep 5
	printf 'late\n'
	return 0
}

AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 1 ))
started_at=$(date +%s)
slow_rc=0
_gh_with_timeout write slow_function_probe >/dev/null 2>&1 || slow_rc=$?
elapsed=$(( $(date +%s) - started_at ))
[[ "$slow_rc" -eq 124 ]] || fail "remaining aggregate budget did not cap a slow shell function"
[[ "$elapsed" -le 3 ]] || fail "slow shell function exceeded aggregate deadline allowance (${elapsed}s)"
pass "remaining aggregate budget caps a slow shell function"

unset AIDEVOPS_GH_DEADLINE_EPOCH
_init_relationship_sync_state || fail "relationship invocation state did not initialize"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 30 ))
DRY_RUN=true

_cache_issue_sync_repository_id example/repo REPO_NODE
cached_repository_id=$(resolve_repository_node_id example/repo)
[[ "$cached_repository_id" == "REPO_NODE" ]] || fail "repository identity was not reused within the invocation"
_cache_issue_sync_node_id 999 ISSUE_NODE_999
grep -q '^999=ISSUE_NODE_999$' "$_NODE_ID_CACHE_FILE" || fail "coordinator issue node ID was not shared with relationship resolution"
pass "invocation mapping caches share repository and issue node identities"

resolve_task_gh_number() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$todo_file" "$repo"
	case "$task_id" in
	t1) printf '101\n' ;;
	t2) printf '102\n' ;;
	t3) printf '103\n' ;;
	t4) printf '104\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_cached_node_id() {
	local issue_num="$1"
	local repo="$2"
	: "$repo"
	printf 'NODE_%s\n' "$issue_num"
	return 0
}

_dependency_cycle_should_skip_edge() {
	local blocked_task="$1"
	local blocker_task="$2"
	local blocked_num="$3"
	local blocker_num="$4"
	local todo_file="$5"
	: "$blocked_task" "$blocker_task" "$blocked_num" "$blocker_num" "$todo_file"
	return 1
}

first_result=$(_sync_declared_blocked_by_edges t1 "${TMP_DIR}/TODO.md" example/repo 101 NODE_101 t2)
reciprocal_result=$(_sync_declared_blocks_edges t2 "${TMP_DIR}/TODO.md" example/repo 102 NODE_102 t1)
[[ "$first_result" == "1:0" ]] || fail "first normalized edge was not attempted once: $first_result"
[[ "$reciprocal_result" == "0:0" ]] || fail "reciprocal declaration replayed normalized edge: $reciprocal_result"
[[ "$(wc -l <"$_RELATIONSHIP_EDGE_SEEN_FILE" | tr -d '[:space:]')" -eq 1 ]] || fail "edge set did not retain exactly one normalized edge"
pass "reciprocal declarations attempt one normalized native edge"

AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) - 1 ))
expired_result=$(_sync_declared_blocked_by_edges t1 "${TMP_DIR}/TODO.md" example/repo 101 NODE_101 t2,t3,t4)
[[ "$expired_result" == "0:1" ]] || fail "expired edge loop did not stop with retryable state: $expired_result"
pass "edge loop stops with retryable state after aggregate exhaustion"

: >"$_RELATIONSHIP_RESULT_FILE"
# The preceding edge-loop assertion intentionally expires the aggregate scope.
# Start a fresh fixture scope before exercising bounded mutation behavior.
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 30 ))
MUTATION_FIXTURE=""
_gh_with_timeout() {
	local operation="$1"
	if [[ "$MUTATION_FIXTURE" == batched* ]]; then
		printf '%s\n' "${AIDEVOPS_GH_OPERATION_CLASS:-other}" >>"$_RELATIONSHIP_BACKEND_CALL_FILE"
		sleep 1
		case "${AIDEVOPS_GH_OPERATION_CLASS:-other}" in
		snapshot)
			printf '%s\n' '{"data":{"q0":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"q1":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"q2":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
			;;
		mutation)
			if [[ "$MUTATION_FIXTURE" == "batched-uncertain" ]]; then
				[[ "${AIDEVOPS_GH_QUOTA_COST:-}" == "2" ]] || return 1
				printf '%s\n' '{"errors":[{"message":"UNCERTAIN_BATCH"}]}'
				return 124
			fi
			if [[ "$MUTATION_FIXTURE" == "batched-mixed" ]]; then
				printf '%s\n' '{"data":{"e0":{"issue":{"number":101}}},"errors":[{"path":["e1"],"message":"secondary rate limit"},{"path":["e2"],"message":"validation failed"}]}'
				return 0
			fi
			[[ "${AIDEVOPS_GH_QUOTA_COST:-}" == "3" ]] || return 1
			printf '%s\n' '{"data":{"e0":{"issue":{"number":101}},"e1":{"issue":{"number":101}},"e2":{"issue":{"number":101}}}}'
			;;
		verify)
			if [[ "$MUTATION_FIXTURE" == "batched-mixed" ]]; then
				printf '%s\n' '{"data":{"q0":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
			else
				printf '%s\n' '{"data":{"q0":{"blockedBy":{"nodes":[{"id":"NODE_102"},{"id":"NODE_103"},{"id":"NODE_104"}],"pageInfo":{"hasNextPage":false}}},"q1":{"blockedBy":{"nodes":[{"id":"NODE_102"},{"id":"NODE_103"},{"id":"NODE_104"}],"pageInfo":{"hasNextPage":false}}},"q2":{"blockedBy":{"nodes":[{"id":"NODE_102"},{"id":"NODE_103"},{"id":"NODE_104"}],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
			fi
			;;
		status) printf '\n' ;;
		*) return 1 ;;
		esac
		return 0
	fi
	if [[ "$operation" == "read" ]]; then
		[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || return 1
	else
		[[ "${AIDEVOPS_GH_QUOTA_COST:-}" == "1" && "$*" != *"rateLimit"* ]] || return 1
	fi
	case "$MUTATION_FIXTURE" in
	created)
		if [[ "$operation" == "read" ]]; then
			printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
		else
			printf '%s\n' '{"data":{"addBlockedBy":{"issue":{"number":101}}}}'
		fi
		return 0
		;;
	already-present)
		printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[{"id":"NODE_103"}],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
		return 0
		;;
	failed)
		if [[ "$operation" == "read" ]]; then
			printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
			return 0
		fi
		printf '%s\n' '{"errors":[{"message":"SECRET_PAYLOAD"}]}'
		return 1
		;;
	partial-error)
		if [[ "$operation" == "read" ]]; then
			printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
		else
			printf '%s\n' '{"data":{"addBlockedBy":{"issue":{"number":101}}},"errors":[{"message":"UNCERTAIN_WRITE"}]}'
		fi
		return 0
		;;
	esac
	return 1
}
DRY_RUN=false
MUTATION_FIXTURE="created"
_gh_add_blocked_by NODE_101 NODE_102 || fail "created mutation fixture failed"
MUTATION_FIXTURE="already-present"
_gh_add_blocked_by NODE_101 NODE_103 || fail "already-present mutation fixture failed"
MUTATION_FIXTURE="failed"
mutation_rc=0
_gh_add_blocked_by NODE_101 NODE_104 || mutation_rc=$?
[[ "$mutation_rc" -eq 1 ]] || fail "failed mutation fixture did not fail"
MUTATION_FIXTURE="partial-error"
mutation_rc=0
_gh_add_blocked_by NODE_101 NODE_105 || mutation_rc=$?
[[ "$mutation_rc" -eq 1 ]] || fail "partial GraphQL error was treated as mutation success"
_relationship_record_outcome "deferred:deadline"
mixed_summary=$(_relationship_print_summary 1 0 1 2 true)
[[ "$mixed_summary" == *"Edges: created=1 already-present=1 failed=2 deferred=1"* ]] || fail "mixed outcomes were not distinguished: $mixed_summary"
[[ "$mixed_summary" == *"Tasks: attempted=1 complete=0/1"* ]] || fail "partial task was presented as complete: $mixed_summary"
[[ "$mixed_summary" == *"Failure: failed:graphql"* ]] || fail "sanitized failure class was not retained: $mixed_summary"
[[ "$mixed_summary" != *"SECRET_PAYLOAD"* ]] || fail "raw GraphQL payload leaked into summary"
[[ "$mixed_summary" != *"UNCERTAIN_WRITE"* ]] || fail "partial GraphQL error leaked into summary"
[[ "$mixed_summary" == *"Recovery: rerun"* ]] || fail "partial summary omitted recovery command"
pass "mixed relationship outcomes remain actionable and sanitized"

# A small mapped workset shares one native snapshot, one bounded mutation, one
# verification snapshot, and one status read. At one second per backend call,
# the optimized path remains comfortably inside the aggregate budget.
: >"$_RELATIONSHIP_RESULT_FILE"
: >"$_RELATIONSHIP_BACKEND_CALL_FILE"
: >"$_RELATIONSHIP_EDGE_SEEN_FILE"
: >"$_RELATIONSHIP_NATIVE_CACHE_FILE"
: >"$_RELATIONSHIP_STATUS_SYNCED_FILE"
: >"$_RELATIONSHIP_OPERATION_TIMING_FILE"
MUTATION_FIXTURE="batched"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 8 ))
batch_started=$(date +%s)
batch_result=$(_sync_declared_blocked_by_edges t1 "${TMP_DIR}/TODO.md" example/repo 101 NODE_101 t2,t3,t4)
batch_elapsed=$(( $(date +%s) - batch_started ))
[[ "$batch_result" == "3:0" ]] || fail "small workset batch did not converge: $batch_result"
[[ "$batch_elapsed" -le 6 ]] || fail "small workset batch exceeded bounded latency (${batch_elapsed}s)"
[[ "$(_relationship_backend_call_count)" -eq 4 ]] || fail "small workset did not use four shared backend calls"
for expected_class in snapshot mutation verify status; do
	[[ "$(_relationship_backend_call_count_for "$expected_class")" -eq 1 ]] || \
		fail "small workset backend class ${expected_class} was not called once"
done
batch_summary=$(_relationship_print_summary 1 1 1 0 false 1 0 fresh 0 "$batch_elapsed" 4)
[[ "$batch_summary" == *"Backend classes: mapping=0 snapshot=1 mutation=1 verify=1 status=1 other=0"* ]] || \
	fail "small workset summary omitted backend classes: $batch_summary"
[[ "$batch_summary" == *"Operation timing: mapping=0s snapshot=1s mutation=1s verify=1s status=1s"* ]] || \
	fail "small workset summary omitted operation timing: $batch_summary"
pass "small relationship worksets batch calls within the aggregate deadline"

snapshot_query=$(_relationship_snapshot_query \
	'NODE_101|NODE_102|101' 'NODE_101|NODE_103|101' 'NODE_101|NODE_104|101')
[[ "$snapshot_query" == *'q0:node'* && "$snapshot_query" != *'q1:node'* && "$snapshot_query" != *'q2:node'* ]] || \
	fail "snapshot query repeated a blocked node connection: $snapshot_query"
pass "snapshot batches reuse one blocked-node connection across sibling edges"

# If the initial snapshot consumes the remaining aggregate budget, no mutation
# starts and the untouched edges remain deferred rather than uncertain writes.
: >"$_RELATIONSHIP_RESULT_FILE"
: >"$_RELATIONSHIP_BACKEND_CALL_FILE"
MUTATION_FIXTURE="batched-deadline"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 1 ))
deadline_batch_result=$(_relationship_apply_planned_batches example/repo \
	'NODE_101|NODE_102|101' 'NODE_101|NODE_103|101')
[[ "$deadline_batch_result" == "0:2" ]] || fail "post-snapshot deadline did not defer untouched edges: $deadline_batch_result"
[[ "$(_relationship_backend_call_count_for snapshot)" -eq 1 ]] || fail "deadline fixture did not run exactly one snapshot"
[[ "$(_relationship_backend_call_count_for mutation)" -eq 0 ]] || fail "mutation started after snapshot exhausted the deadline"
[[ "$(_relationship_outcome_count "$_REL_OUTCOME_DEFERRED_DEADLINE")" -eq 2 ]] || \
	fail "post-snapshot deadline did not record two deferred edges"
pass "snapshot deadline exhaustion defers edges before mutation"

# A timed-out grouped mutation is idempotently recoverable when the bounded
# verification snapshot proves that GitHub applied the uncertain writes.
: >"$_RELATIONSHIP_RESULT_FILE"
: >"$_RELATIONSHIP_BACKEND_CALL_FILE"
: >"$_RELATIONSHIP_EDGE_SEEN_FILE"
: >"$_RELATIONSHIP_NATIVE_CACHE_FILE"
: >"$_RELATIONSHIP_STATUS_SYNCED_FILE"
: >"$_RELATIONSHIP_OPERATION_TIMING_FILE"
MUTATION_FIXTURE="batched-uncertain"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 8 ))
uncertain_result=$(_sync_declared_blocked_by_edges t1 "${TMP_DIR}/TODO.md" example/repo 101 NODE_101 t2,t3)
[[ "$uncertain_result" == "2:0" ]] || fail "uncertain grouped mutation did not recover from native verification: $uncertain_result"
[[ "$(_relationship_outcome_count "$_REL_OUTCOME_ALREADY_PRESENT")" -eq 2 ]] || \
	fail "uncertain grouped mutation did not classify verified edges as present"
[[ "$(_relationship_outcome_count failed)" -eq 0 ]] || fail "verified uncertain grouped mutation retained a false failure"
pass "uncertain grouped mutations converge through bounded verification"

# Alias-scoped GraphQL errors must not leak cooldown classification from one
# failed edge into another edge in the same grouped mutation.
: >"$_RELATIONSHIP_RESULT_FILE"
: >"$_RELATIONSHIP_BACKEND_CALL_FILE"
: >"$_RELATIONSHIP_STATUS_SYNCED_FILE"
MUTATION_FIXTURE="batched-mixed"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 8 ))
mixed_batch_result=$(_relationship_apply_planned_batches example/repo \
	'NODE_101|NODE_102|101' 'NODE_101|NODE_103|101' 'NODE_101|NODE_104|101')
[[ "$mixed_batch_result" == "1:2" ]] || fail "mixed alias batch returned unexpected counts: $mixed_batch_result"
[[ "$(_relationship_outcome_count "$_REL_OUTCOME_CREATED")" -eq 1 ]] || fail "mixed alias success was not retained"
[[ "$(_relationship_outcome_count 'deferred:cooldown')" -eq 1 ]] || fail "alias cooldown was not isolated"
[[ "$(_relationship_outcome_count 'failed:graphql')" -eq 1 ]] || fail "alias GraphQL failure was not isolated"
pass "mixed mutation aliases retain independent failure classes"

# Declared relationships with no immutable self-mapping are unfinished work,
# while a task with no relationship metadata remains a successful no-op.
printf '%s\n' '- [ ] t3 Declared edge blocked-by:t2' '- [ ] t4 No relationship metadata' >"${TMP_DIR}/TODO.md"
resolve_task_gh_number() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$task_id" "$todo_file" "$repo"
	return 1
}
: >"$_RELATIONSHIP_RESULT_FILE"
unresolved_result=$(_sync_blocked_by_for_task t3 "${TMP_DIR}/TODO.md" example/repo)
[[ "$unresolved_result" == "RELS:0 RETRYABLE:1" ]] || fail "unresolved declared mapping was not retryable: $unresolved_result"
grep -q '^failed:resolution$' "$_RELATIONSHIP_RESULT_FILE" || fail "unresolved mapping did not record failed resolution"
noop_result=$(_sync_blocked_by_for_task t4 "${TMP_DIR}/TODO.md" example/repo)
[[ "$noop_result" == "RELS:0 RETRYABLE:0" ]] || fail "relationship-free task was not a successful no-op: $noop_result"
pass "declared mapping failures retry while relationship-free tasks no-op"

_sync_blocked_by_for_task() {
	printf 'RELS:0 RETRYABLE:0\n'
	return 0
}
_sync_subtask_hierarchy_for_task() {
	printf 'RELS:0 RETRYABLE:0\n'
	return 0
}
_cleanup_relationship_sync_state
_RELATIONSHIP_SYNC_SCOPE_ACTIVE=0
_begin_relationship_sync_scope || fail "command relationship scope did not initialize"
_ensure_relationship_sync_deadline || fail "command relationship deadline did not initialize"
scope_file="$_RELATIONSHIP_EDGE_SEEN_FILE"
scope_deadline="$_RELATIONSHIP_SYNC_DEADLINE_EPOCH"
_relationship_edge_should_attempt 201 202 || fail "command scope did not retain its first edge"
sync_relationships_for_task t1 "${TMP_DIR}/TODO.md" example/repo || fail "nested task relationship sync failed"
[[ "$_RELATIONSHIP_EDGE_SEEN_FILE" == "$scope_file" ]] || fail "nested task sync replaced the command edge set"
[[ "$_RELATIONSHIP_SYNC_DEADLINE_EPOCH" == "$scope_deadline" ]] || fail "nested task sync reset the command deadline"
if _relationship_edge_should_attempt 201 202; then
	fail "nested task sync cleared command-level edge deduplication"
fi
_end_relationship_sync_scope
pass "nested task sync reuses command deadline and edge set"

MAPPING_LOG="${TMP_DIR}/mapping.log"
: >"$MAPPING_LOG"
_PUSH_CREATED_NUM=123
add_gh_ref_to_todo() {
	local task_id="$1"
	local issue_num="$2"
	local todo_file="$3"
	printf 'mapped:%s:%s:%s\n' "$task_id" "$issue_num" "$todo_file" >>"$MAPPING_LOG"
	return 0
}
require_task_issue_mapping() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	local issue_num="$4"
	: "$task_id" "$todo_file" "$repo" "$issue_num"
	return 0
}
sync_relationships_for_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$task_id" "$todo_file" "$repo"
	return 1
}
finalize_output=$(_push_finalize_task_creation t1 example/repo "${TMP_DIR}/TODO.md" "title" "" "bug" "body" 2>"${TMP_DIR}/finalize.err")
[[ "$finalize_output" == *"CREATED RELATIONSHIPS_PENDING"* ]] || fail "post-create pending result was not actionable"
grep -q '^mapped:t1:123:' "$MAPPING_LOG" || fail "durable mapping was not preserved before pending relationship result"
grep -q 'durable mapping preserved' "${TMP_DIR}/finalize.err" || fail "pending result omitted durable-mapping diagnostic"
pass "post-create relationship timeout preserves mapping and reports pending recovery"

printf 'PASS: issue-sync relationship aggregate deadline regressions\n'
