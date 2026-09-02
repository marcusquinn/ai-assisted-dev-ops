#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../objective-reconciliation-helper.sh"
LIFECYCLE="${SCRIPT_DIR}/../worker-lifecycle-common.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

fixture="$TMP_DIR/objectives.json"
cat >"$fixture" <<'JSON'
{
  "issues": [
    {"number":1,"repo":"owner/repo","updatedAt":1000,"labels":["status:queued"]},
    {"number":2,"repo":"owner/repo","updatedAt":9900,"lease_active":true,"process_active":true},
    {"number":3,"repo":"owner/repo","updatedAt":9900,"pr":{"number":30,"state":"OPEN"}},
    {"number":4,"repo":"owner/repo","updatedAt":9900,"dependency_blocked":true},
    {"number":5,"repo":"owner/repo","updatedAt":9900,"authority_required":true,"recovery_attempt":7},
    {"number":6,"repo":"owner/repo","updatedAt":9900,"state":"closed"},
    {"number":7,"repo":"owner/repo","updatedAt":9900,"cancelled":true},
    {"number":8,"repo":"owner/repo","updatedAt":9900,"impossible":true},
    {"number":9,"repo":"owner/repo","updatedAt":9900,"lease_active":true,"worktree_exists":true},
    {"number":10,"repo":"owner/repo","updatedAt":9900,"lease_active":true,"branch_exists":true},
    {"number":11,"repo":"owner/repo","updatedAt":9900,"lease_active":true},
    {"number":12,"repo":"owner/repo","updatedAt":9900,"labels":["status:in-review"]},
    {"number":13,"repo":"owner/repo","updatedAt":9900,"pr":{"number":130,"checks":"FAIL"}},
    {"number":14,"repo":"owner/repo","updatedAt":9900,"dependency_blocked":true,"dependency_resolved":true},
    {"number":15,"repo":"owner/repo","updatedAt":9900},
    {"number":16,"repo":"owner/repo","updatedAt":9900,"recovery_comment_at":9000,"subsequent_action_at":8000,"recovery_attempt":5},
    {"number":17,"repo":"owner/repo","updatedAt":9900,"recovery_comment_at":9000,"subsequent_action_at":8000,"recovery_attempt":6},
    {"number":18,"repo":"owner/repo","updatedAt":9900,"labels":["status:done"]}
  ],
  "prs": [],
  "merged_lookup": "|15=150|"
}
JSON

derived="$TMP_DIR/derived.json"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$TMP_DIR/missing-evidence.jsonl" \
	"$HELPER" derive --repo owner/repo --input "$fixture" --now 10000 --ttl 3600 >"$derived"

jq -e 'length == 18' "$derived" >/dev/null || fail "all objective fixtures must be derived"
jq -e '.[] | select(.number == 1 and .objective_state == "actionable" and .next_action == "dispatch_objective" and .assumption_expired == true)' "$derived" >/dev/null || fail "queued objective classification"
jq -e '.[] | select(.number == 2 and .objective_state == "actively owned" and .next_action == "monitor_worker")' "$derived" >/dev/null || fail "active ownership classification"
jq -e '.[] | select(.number == 3 and .objective_state == "under review" and .next_action == "monitor_pr")' "$derived" >/dev/null || fail "review classification"
jq -e '.[] | select(.number == 4 and .objective_state == "dependency-blocked" and .next_action == "reverify_dependency")' "$derived" >/dev/null || fail "dependency blocker classification"
jq -e '.[] | select(.number == 5 and .objective_state == "authority-blocked" and .next_action == "decision_ready_human_packet")' "$derived" >/dev/null || fail "authority escalation classification"
jq -e '.[] | select(.number == 6 and .objective_state == "completed" and .next_action == "none")' "$derived" >/dev/null || fail "completed classification"
jq -e '.[] | select(.number == 7 and .objective_state == "cancelled")' "$derived" >/dev/null || fail "cancelled classification"
jq -e '.[] | select(.number == 8 and .objective_state == "impossible")' "$derived" >/dev/null || fail "impossible classification"
jq -e '.[] | select(.number == 9 and .next_action == "resume_session")' "$derived" >/dev/null || fail "worktree resume recovery"
jq -e '.[] | select(.number == 10 and .next_action == "recover_branch")' "$derived" >/dev/null || fail "branch recovery"
jq -e '.[] | select(.number == 11 and .next_action == "narrow_redispatch")' "$derived" >/dev/null || fail "lease without process recovery"
jq -e '.[] | select(.number == 12 and .next_action == "recover_branch")' "$derived" >/dev/null || fail "review without PR recovery"
jq -e '.[] | select(.number == 13 and .next_action == "repair_pr")' "$derived" >/dev/null || fail "failing PR repair"
jq -e '.[] | select(.number == 14 and .next_action == "narrow_redispatch")' "$derived" >/dev/null || fail "resolved dependency recovery"
jq -e '.[] | select(.number == 15 and .objective_state == "completed" and .next_action == "close_issue")' "$derived" >/dev/null || fail "merged PR open issue drift"
jq -e '.[] | select(.number == 16 and .next_action == "model_escalation")' "$derived" >/dev/null || fail "model escalation ladder"
jq -e '.[] | select(.number == 17 and .next_action == "diagnostic_worker")' "$derived" >/dev/null || fail "diagnostic worker ladder"
jq -e '.[] | select(.number == 18 and .objective_state == "completed")' "$derived" >/dev/null || fail "done status classification"
jq -e '[.[] | select(.objective_state != "completed" and .objective_state != "cancelled" and .objective_state != "impossible") | select(.evidence_timestamp == null or .assumption_expires_at == null or .next_action == "" or .trigger_at == null or .responsible_component == "")] | length == 0' "$derived" >/dev/null || fail "nonterminal objective invariant"

state_file="$TMP_DIR/state.json"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$TMP_DIR/missing-evidence.jsonl" \
	"$HELPER" reconcile --repo owner/repo --input "$fixture" --state-file "$state_file" --now 10000 --ttl 3600 --max-repairs 3 >/dev/null
jq -e '.repairs_applied | length == 3' "$state_file" >/dev/null || fail "repair budget must cap applied actions"
jq -e '.repairs_deferred | length == 15' "$state_file" >/dev/null || fail "repair budget must retain deferred actions"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$TMP_DIR/missing-evidence.jsonl" \
	"$HELPER" reconcile --repo owner/repo --input "$fixture" --state-file "$state_file" --now 10000 --ttl 3600 --max-repairs 3 >/dev/null
jq -e '.repairs_applied | length == 0' "$state_file" >/dev/null || fail "repeated reconciliation must be idempotent"
jq -e '.repairs_deferred | length == 0' "$state_file" >/dev/null || fail "idempotent pass must not defer unchanged plans"

evidence_file="$TMP_DIR/evidence.jsonl"
HOME="$TMP_DIR" WORKER_ISSUE_NUMBER=1 GITHUB_REPOSITORY=owner/repo \
	AIDEVOPS_WORKER_ID=worker:test AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$evidence_file" \
	bash -c 'source "$1"; _emit_worker_runtime_event worker.failed failed runtime_error' _ "$LIFECYCLE"
jq -e 'select(.event_type == "worker.failed" and .issue_number == 1 and .next_action == "retry_infrastructure" and .commits_preserved == true)' "$evidence_file" >/dev/null || fail "terminal lifecycle evidence"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$evidence_file" \
	"$HELPER" derive --repo owner/repo --input "$fixture" --now 10000 --ttl 3600 >"$derived"
jq -e '.[] | select(.number == 1 and .execution_path_state == "recovery" and .preservation.commits == true)' "$derived" >/dev/null || fail "durable lifecycle evidence merge"
HOME="$TMP_DIR" WORKER_ISSUE_NUMBER=1 GITHUB_REPOSITORY=owner/repo \
	AIDEVOPS_WORKER_ID=worker:repair AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$evidence_file" \
	AIDEVOPS_PR_REPAIR_NUMBER=30 AIDEVOPS_PR_REPAIR_HEAD_SHA=abc123 \
	AIDEVOPS_PR_REPAIR_HEAD_REF=feature/repair AIDEVOPS_PR_REPAIR_FINGERPRINT=fp123 \
	bash -c 'source "$1"; _emit_worker_runtime_event worker.completed completed ci_repair' _ "$LIFECYCLE"
jq -e 'select(.event_type == "worker.completed" and .pr_repair.pr_number == 30 and .pr_repair.head_sha == "abc123" and .pr_repair.head_ref == "feature/repair" and .pr_repair.failure_fingerprint == "fp123" and .next_action == "monitor_pr")' "$evidence_file" >/dev/null || fail "PR repair lifecycle evidence"

printf '%s\n' '{"repo":"owner/repo","issue_number":999,"evidence_timestamp":10000,"event_type":"worker.failed"}' >>"$evidence_file"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$evidence_file" AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT=1 \
	"$HELPER" derive --repo owner/repo --input "$fixture" --now 10000 --ttl 3600 >"$derived"
jq -e '.[] | select(.number == 1 and .execution_path_state == "idle" and .preservation.commits == false)' "$derived" >/dev/null || fail "durable evidence read must honour the bounded tail"

outcome_file="$TMP_DIR/outcomes.jsonl"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$outcome_file" \
	"$HELPER" record-outcome --repo owner/repo --issue 41 \
	--attempt-id attempt-a --run-id run-a --raw-result premature_exit \
	--outcome success --status recovered --classification worker_complete \
	--next-action monitor_pr --timestamp 10100
printf '%s\n' '{"issue_number":"bad"}' >>"$outcome_file"
# First terminal outcome wins for an attempt, even if delayed raw cleanup tries
# to append a conflicting failure later.
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$outcome_file" \
	"$HELPER" record-outcome --repo owner/repo --issue 41 \
	--attempt-id attempt-a --run-id run-late --raw-result watchdog_stall_killed \
	--outcome failed --status failed --classification stale_cleanup \
	--next-action narrow_redispatch --timestamp 10200
jq -se '[.[] | select(.record_type == "attempt_outcome" and .attempt_id == "attempt-a")] | length == 1' \
	"$outcome_file" >/dev/null || fail "one reconciled terminal outcome per attempt"

disposition="$TMP_DIR/disposition.json"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$outcome_file" \
	"$HELPER" disposition --repo owner/repo --issue 41 --attempt-id attempt-a \
	--state-file "$state_file" >"$disposition"
jq -e '.source == "attempt_outcome" and .effective_outcome == "success" and
	.raw_result == "premature_exit" and .suppress_retry == true and
	.suppress_enrichment == true and .suppress_failure_mining == true' \
	"$disposition" >/dev/null || fail "successful reconciled disposition suppresses false failure routing"

AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$outcome_file" \
	"$HELPER" record-outcome --repo owner/repo --issue 41 \
	--attempt-id attempt-b --run-id run-b --raw-result premature_exit \
	--outcome failed --status failed --classification worker_failed \
	--next-action narrow_redispatch --timestamp 10300
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$outcome_file" \
	"$HELPER" disposition --repo owner/repo --issue 41 --attempt-id attempt-b \
	--state-file "$state_file" >"$disposition"
jq -e '.effective_outcome == "failed" and .suppress_retry == false and
	.suppress_enrichment == false and .suppress_failure_mining == false' \
	"$disposition" >/dev/null || fail "failed reconciled disposition remains actionable"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$outcome_file" \
	"$HELPER" disposition --repo owner/repo --issue 41 --attempt-id attempt-c \
	--state-file "$state_file" >"$disposition"
jq -e '.source == "none" and .effective_outcome == "unknown" and .suppress_retry == false' \
	"$disposition" >/dev/null || fail "another attempt outcome must not contaminate a new attempt"

# Issue-level consumers must prefer the newest logical attempt, not a delayed
# cleanup record with a later evidence timestamp from an older attempt.
chronology_file="$TMP_DIR/chronology.jsonl"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$chronology_file" \
	"$HELPER" record-outcome --repo owner/repo --issue 42 \
	--attempt-id attempt-new --run-id run-new --attempt-started-at 2000000000000000001 \
	--raw-result premature_exit --outcome failed --status failed \
	--classification worker_failed --next-action narrow_redispatch --timestamp 300
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$chronology_file" \
	"$HELPER" record-outcome --repo owner/repo --issue 42 \
	--attempt-id attempt-old --run-id run-old --attempt-started-at 2000000000000000000 \
	--raw-result recovered --outcome success --status recovered \
	--classification stale_cleanup --next-action monitor_pr --timestamp 400
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$chronology_file" \
	"$HELPER" disposition --repo owner/repo --issue 42 \
	--state-file "$state_file" >"$disposition"
jq -e '.attempt_id == "attempt-new" and .effective_outcome == "failed" and
	.suppress_retry == false' "$disposition" >/dev/null ||
	fail "issue-level disposition must sort by logical attempt chronology"

# Concurrent terminal writers for one attempt must produce one valid record.
concurrent_file="$TMP_DIR/concurrent.jsonl"
concurrent_pids=()
for concurrent_index in 1 2 3 4 5 6 7 8; do
	AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$concurrent_file" \
		"$HELPER" record-outcome --repo owner/repo --issue 43 \
		--attempt-id attempt-concurrent --run-id "run-${concurrent_index}" \
		--attempt-started-at 500 --raw-result premature_exit --outcome success \
		--status recovered --classification worker_complete \
		--next-action monitor_pr --timestamp "$((500 + concurrent_index))" &
	concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
	wait "$concurrent_pid" || fail "concurrent outcome writer failed"
done
jq -se 'length == 1 and .[0].attempt_id == "attempt-concurrent"' \
	"$concurrent_file" >/dev/null || fail "concurrent writes must remain valid and idempotent"

legacy_state="$TMP_DIR/legacy-state.json"
printf '%s\n' '{"objectives":[{"repo":"owner/repo","number":77,"objective_state":"completed","next_action":"none"}]}' >"$legacy_state"
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$TMP_DIR/missing-legacy-evidence.jsonl" \
	"$HELPER" disposition --repo owner/repo --issue 77 --attempt-id attempt-new \
	--state-file "$legacy_state" >"$disposition"
jq -e '.source == "objective_state" and .effective_outcome == "success" and
	.suppress_retry == true and .suppress_failure_mining == true' \
	"$disposition" >/dev/null || fail "legacy objective state remains readable"

large_evidence_file="$TMP_DIR/large-evidence.jsonl"
large_payload=$(printf '%0200000d' 0)
for large_index in 1 2 3 4 5 6 7 8 9 10; do
	printf '{"repo":"owner/repo","issue_number":%s,"event_type":"worker.failed","payload":"%s"}\n' \
		"$large_index" "$large_payload" >>"$large_evidence_file"
done
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$large_evidence_file" \
	"$HELPER" record-outcome --repo owner/repo --issue 88 \
	--attempt-id attempt-large --run-id run-large --raw-result recovered \
	--outcome success --status recovered --classification stale_cleanup \
	--next-action monitor_pr --timestamp 10400
AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="$large_evidence_file" \
	"$HELPER" disposition --repo owner/repo --issue 88 --attempt-id attempt-large \
	--state-file "$state_file" >"$disposition"
jq -e '.source == "attempt_outcome" and .effective_outcome == "success" and
	.raw_result == "recovered"' "$disposition" >/dev/null ||
	fail "large evidence disposition must avoid argv limits"

printf 'PASS objective-reconciliation\n'
