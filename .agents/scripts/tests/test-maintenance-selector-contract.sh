#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

python3 - "$REPO_ROOT" <<'PYEOF'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

required_functions = {
    ".agents/custom/scripts/r-stub-title-scan.sh": ["_get_pulse_repos"],
    ".agents/scripts/cloudron-package-monitor-helper.sh": ["_cloudron_monitor_run"],
    ".agents/scripts/dashboard-freshness-check.sh": ["_repo_slugs_for_dashboard_scan"],
    ".agents/scripts/dependabot-alert-monitor.sh": ["_dam_list_repos"],
    ".agents/scripts/gh-failure-miner-helper.sh": ["load_pulse_repo_allowlist"],
    ".agents/scripts/inbox-digest-routine.sh": ["main"],
    ".agents/scripts/mission-dashboard-helper.sh": ["_status_print_blockers"],
    ".agents/scripts/orchestration-efficiency-collector.sh": ["collect_audit_trails"],
    ".agents/scripts/peer-productivity-monitor.sh": ["_list_pulse_repos"],
    ".agents/scripts/pr-salvage-helper.sh": ["scan_all_repos"],
    ".agents/scripts/foss-contribution-helper.sh": ["_get_foss_repos"],
    ".agents/scripts/pulse-ancillary-dispatch.sh": [
        "dispatch_foss_workers",
        "dispatch_routine_comment_responses",
    ],
    ".agents/scripts/pulse-batch-prefetch-helper.sh": ["_group_repos_by_owner"],
    ".agents/scripts/pulse-capacity-alloc.sh": [
        "_count_dispatchable_product_repos",
        "_count_priority_repos",
        "_scan_pr_salvage",
    ],
    ".agents/scripts/pulse-capacity.sh": [
        "count_queued_without_worker",
        "count_runnable_candidates",
    ],
    ".agents/scripts/pulse-canonical-maintenance.sh": ["_canonical_fast_forward"],
    ".agents/scripts/pulse-dep-graph.sh": ["build_dependency_graph_cache"],
    ".agents/scripts/pulse-dispatch-engine.sh": [
        "_should_run_llm_supervisor",
        "build_ranked_dispatch_candidates_json",
    ],
    ".agents/scripts/pulse-fix-the-fixer-detector.sh": ["cmd_run"],
    ".agents/scripts/pulse-issue-reconcile-normalize.sh": ["_normalize_label_invariants"],
    ".agents/scripts/pulse-issue-reconcile-parent.sh": ["reconcile_completed_parent_tasks"],
    ".agents/scripts/pulse-issue-reconcile.sh": [
        "_normalize_reassign_self",
        "reconcile_issues_single_pass",
        "reconcile_labelless_aidevops_issues",
    ],
    ".agents/scripts/pulse-merge-pass.sh": ["merge_ready_prs_all_repos"],
    ".agents/scripts/pulse-nmr-approval.sh": ["auto_approve_maintainer_issues"],
    ".agents/scripts/pulse-prefetch.sh": ["prefetch_state"],
    ".agents/scripts/pulse-prefetch-workers.sh": ["prefetch_foss_scan"],
    ".agents/scripts/pulse-queue-governor.sh": ["_fetch_queue_metrics"],
    ".agents/scripts/pulse-repo-tier.sh": ["cmd_classify"],
    ".agents/scripts/pulse-routines.sh": ["evaluate_routines"],
    ".agents/scripts/pulse-session-helper.sh": ["get_pulse_repo_count"],
    ".agents/scripts/pulse-simplification-scan.sh": ["_pulse_enabled_repo_slugs"],
    ".agents/scripts/pulse-triage-evaluation.sh": [
        "_reevaluate_consolidation_labels",
        "_reevaluate_simplification_labels",
    ],
    ".agents/scripts/pulse-wrapper-cycle-gates.sh": ["_pulse_scope_repos_for_available_work_gate"],
    ".agents/scripts/pulse-wrapper-cycle.sh": [
        "_pulse_reconcile_stale_blocked_if_due",
        "sync_todo_refs_all_repos",
    ],
    ".agents/scripts/session-miner-pulse.sh": ["run_actuation"],
    ".agents/scripts/setup/modules/migrations.sh": ["backfill_issue_relationships"],
    ".agents/scripts/stats-health-dashboard-data.sh": [
        "_compute_worker_success_rates",
        "_refresh_person_stats_cache",
    ],
    ".agents/scripts/stats-health-dashboard.sh": ["update_health_issues"],
    ".agents/scripts/stats-quality-sweep.sh": ["run_daily_quality_sweep"],
    ".agents/scripts/repo-aidevops-health-helper.sh": ["_check_version_bumps"],
}


def function_body(path: pathlib.Path, name: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    start_pattern = re.compile(rf"^{re.escape(name)}\(\) \{{$")
    for index, line in enumerate(lines):
        if not start_pattern.match(line):
            continue
        for end in range(index + 1, len(lines)):
            if lines[end] == "}":
                return "\n".join(lines[index : end + 1])
        raise AssertionError(f"{path}: unterminated function {name}")
    raise AssertionError(f"{path}: function {name} not found")


errors = []
for relative_path, function_names in required_functions.items():
    path = root / relative_path
    for function_name in function_names:
        try:
            body = function_body(path, function_name)
        except AssertionError as exc:
            errors.append(str(exc))
            continue
        if ".maintenance != false" not in body:
            errors.append(
                f"{relative_path}:{function_name} lacks the recurring maintenance predicate"
            )

remote_recurring_functions = {
    ".agents/scripts/foss-contribution-helper.sh": ["_get_foss_repos"],
    ".agents/scripts/pulse-ancillary-dispatch.sh": ["dispatch_foss_workers"],
    ".agents/scripts/pulse-prefetch-workers.sh": ["prefetch_foss_scan"],
}
for relative_path, function_names in remote_recurring_functions.items():
    path = root / relative_path
    for function_name in function_names:
        body = function_body(path, function_name)
        if "(.local_only // false) == false" not in body:
            errors.append(
                f"{relative_path}:{function_name} lacks the local-only exclusion"
            )

safety_functions = {
    ".agents/scripts/aidevops-update-check.sh": ["_detect_stuck_index_conflict"],
    ".agents/scripts/contribution-watch-helper.sh": [
        "_get_managed_repo_slugs",
        "cmd_seed",
    ],
    ".agents/scripts/contributor-insight-helper.sh": ["_load_private_slugs"],
    ".agents/scripts/interactive-session-helper-scan.sh": [
        "_isc_scan_closed_pr_orphans",
        "_isc_scan_stampless_phase",
    ],
    ".agents/scripts/pulse-canonical-maintenance.sh": ["_stale_worktree_sweep"],
    ".agents/scripts/pulse-cleanup.sh": ["cleanup_stalled_workers", "cleanup_stashes"],
    ".agents/scripts/pulse-cleanup-worktree-removal.sh": ["cleanup_worktrees"],
    ".agents/scripts/pulse-cleanup-worktree-state.sh": [
        "_cleanup_merged_prs_for_all_repos"
    ],
    ".agents/scripts/pulse-dirty-pr-sweep.sh": ["dirty_pr_sweep_all_repos"],
    ".agents/scripts/pulse-issue-reconcile.sh": [
        "_normalize_unassign_stampless_interactive"
    ],
    ".agents/scripts/pulse-issue-reconcile-stale.sh": ["_normalize_unassign_stale"],
    ".agents/scripts/repo-aidevops-health-helper.sh": [
        "_check_missing_folders",
        "_check_no_init_repos",
    ],
    ".agents/scripts/shared-dispatch-label-cleanup.sh": [
        "_dispatch_label_sweep_repos"
    ],
}
for relative_path, function_names in safety_functions.items():
    path = root / relative_path
    for function_name in function_names:
        try:
            body = function_body(path, function_name)
        except AssertionError as exc:
            errors.append(str(exc))
            continue
        if ".maintenance" in body or ".pulse" in body:
            errors.append(
                f"{relative_path}:{function_name} safety scope must ignore maintenance and Pulse state"
            )

guarded_safety_writes = {
    ".agents/scripts/pulse-issue-reconcile.sh": [
        "_normalize_unassign_stampless_interactive"
    ],
    ".agents/scripts/pulse-issue-reconcile-stale.sh": ["_normalize_unassign_stale"],
    ".agents/scripts/pulse-triage-dispatch.sh": [
        "_backfill_stale_consolidation_labels"
    ],
    ".agents/scripts/shared-dispatch-label-cleanup.sh": [
        "sweep_closed_auto_dispatch_issues"
    ],
}
for relative_path, function_names in guarded_safety_writes.items():
    path = root / relative_path
    for function_name in function_names:
        body = function_body(path, function_name)
        if "repo_allows_pulse_write_actions" not in body:
            errors.append(
                f"{relative_path}:{function_name} lacks contributor/write-authority guard"
            )

close_source = (root / ".agents/scripts/pulse-issue-reconcile-close.sh").read_text(
    encoding="utf-8"
)
if "_pir_close_slug_filter='.initialized_repos[] | select(.maintenance != false" not in close_source:
    errors.append("pulse-issue-reconcile-close.sh shared selector lacks maintenance predicate")

triage_body = function_body(
    root / ".agents/scripts/pulse-triage-dispatch.sh",
    "_backfill_stale_consolidation_labels",
)
if "if .maintenance == false then false else true end" not in triage_body:
    errors.append("triage consolidation scan does not expose effective maintenance state")
if "(.pulse // false)" not in triage_body:
    errors.append("triage consolidation scan does not expose Pulse state")
if '[[ "$maintenance_flag" == "false" || "$pulse_flag" != "true" ]] && continue' not in triage_body:
    errors.append("triage consolidation scan does not gate dispatch work for dormant repos")

hygiene_body = function_body(
    root / ".agents/scripts/pulse-prefetch-secondary.sh", "prefetch_hygiene"
)
if ".maintenance" in hygiene_body or ".pulse" in hygiene_body:
    errors.append("safety hygiene prefetch must ignore maintenance and Pulse state")

if errors:
    raise SystemExit("FAIL\n- " + "\n- ".join(errors))

print("PASS recurring selectors enforce maintenance while safety hygiene retains visibility")
PYEOF
