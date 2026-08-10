#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../dispatch-dedup-helper.sh"

assert_reason() {
	local signal="$1"
	local expected="$2"
	local actual
	actual=$("$HELPER" classify-blocker "$signal")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL signal=%s expected=%s actual=%s\n' "$signal" "$expected" "$actual" >&2
		return 1
	fi
	return 0
}

assert_reason 'COST_BUDGET_EXCEEDED (spent=123 budget=100)' 'cost_budget_exceeded'
assert_reason 'DISPATCH_BLOCK_REASON reason=dedup_active_claim signal=assigned to runner' 'dedup_active_claim'
assert_reason 'DISPATCH_BLOCK_REASON reason=interactive_review_hold signal=interactive review hold label present' 'interactive_review_hold'
assert_reason 'Dispatch blocked for #4849 in exampleorg/examplerepo: target is a pull request, not a dispatchable issue (GH#22948)' 'pr_target_not_dispatchable'
assert_reason 'DISPATCH_BLOCK_REASON reason=renovate_dependency_dashboard signal=renovate_dependency_dashboard issue=#24975 repo=marcusquinn/aidevops' 'renovate_dependency_dashboard'
assert_reason 'GraphQL budget below circuit-breaker threshold' 'graphql_circuit_breaker'
assert_reason 'DISPATCH_COOLDOWN_ACTIVE until=2026-05-02T23:00:00Z reason=no_worker_process' 'cooldown_no_worker_process'
assert_reason 'dispatch_with_dedup: BLOCKED #3638 in exampleorg/examplerepo — requires cryptographic approval (ever-NMR)' 'ever_nmr_without_approval'
assert_reason 'DISPATCH_BLOCK_REASON reason=ever_nmr_without_approval signal=ever-NMR issue requires approval' 'ever_nmr_without_approval'
assert_reason 'dispatch_with_dedup: BLOCKED #3638 in exampleorg/examplerepo — ever-NMR issue lacks approval' 'ever_nmr_without_approval'
assert_reason 'blocked by local capacity gate (ever-nmr check not run)' 'local_capacity_gate'
assert_reason 'review-followup exemption: skipping historical ever-NMR check (GH#18648)' 'unclassified_signal'
assert_reason 'skipping historical ever-NMR check for bot-generated cleanup issue (GH#18648)' 'unclassified_signal'
assert_reason 'DISPATCH_BLOCK_REASON reason=blocked_by_native_lookup_unavailable signal=native blockedBy lookup unavailable and no body blocked-by markers found' 'blocked_by_native_lookup_unavailable'
assert_reason 'pre-dispatch validator failed: missing worker context; needs-brief label present' 'missing_worker_context'
assert_reason 'dedup.worktree_cap blocked by max worktree count' 'local_capacity_gate'
assert_reason 'dedup guard blocked #303 in some-org/infrastructure' 'dedup_active_claim'
assert_reason 'PARENT_TASK_BLOCKED (label=parent-task)' 'parent_task'
assert_reason 'PUBLICATION_PENDING_BLOCKED (label=publication:pending)' 'publication_pending'
assert_reason 'NO_AUTO_DISPATCH_BLOCKED (label=no-auto-dispatch)' 'no_auto_dispatch'
assert_reason 'FOOTPRINT_OVERLAP path=.agents/scripts/pulse-dispatch-engine.sh issue=#25229' 'footprint_overlap'
assert_reason '[dispatch_with_dedup] Hard-stop before worker bootstrap for #25233 in marcusquinn/aidevops: unresolved blocked-by dependency (GH#23932)' 'blocked_by_unresolved'
assert_reason 'dispatch candidate skipped: issue #25275 state=CLOSED' 'issue_closed'
assert_reason 'dispatch candidate skipped: consolidated into #25279' 'consolidated'
assert_reason 'INFRASTRUCTURE_BLOCKED (label=infrastructure)' 'policy_gate'
assert_reason 'HOLD_FOR_REVIEW_BLOCKED (label=hold-for-review)' 'policy_gate'
assert_reason 'external_author_gate blocked no-auto-dispatch policy' 'policy_gate'
assert_reason '' 'no_recent_log_evidence'
assert_reason 'new blocker shape not yet classified' 'unclassified_signal'

printf 'PASS dispatch-candidate-failure-reasons\n'
