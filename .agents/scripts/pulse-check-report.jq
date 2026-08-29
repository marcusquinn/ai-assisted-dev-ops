def number_or_zero: (tonumber? // 0);

def finding($id; $severity; $title; $evidence; $recommendation; $autofile): {
  id: $id,
  severity: $severity,
  title: $title,
  evidence: $evidence,
  recommendation: $recommendation,
  autofile: $autofile
};

(if ($current.active_worker_processes // $current.pulse_health.workers_active // null) == null then null else ($current.active_worker_processes // $current.pulse_health.workers_active | number_or_zero) end) as $active_worker_processes |
($current.pulse_gauges.dispatch_capacity_final_max_workers // $current.pulse_health.workers_max // null) as $raw_max_workers |
($current.current_state_guardrails.available_slots_last // $current.pulse_gauges.pulse_dispatch_guardrail_available_slots // (if ($current.pulse_health.workers_max // null) == null or $active_worker_processes == null then null else ([($current.pulse_health.workers_max | number_or_zero) - $active_worker_processes, 0] | max) end)) as $raw_available_slots |
($raw_available_slots // 0 | number_or_zero) as $available_slots |
(if $raw_max_workers == null then
  (if $active_worker_processes == null then $available_slots else ($active_worker_processes + $available_slots) end)
else
  ($raw_max_workers | number_or_zero)
end) as $max_workers |
([$max_workers - $available_slots, 0] | max) as $inferred_active_workers |
(if $active_worker_processes == null then $inferred_active_workers else $active_worker_processes end) as $active_workers |
(if $active_worker_processes == null then $available_slots else ([$max_workers - $active_worker_processes, 0] | max) end) as $effective_available_slots |
($queue.aggregate.available_unassigned // 0 | number_or_zero) as $available_issues |
($queue.aggregate.eligible_available_unassigned // $queue.aggregate.available_unassigned // 0 | number_or_zero) as $eligible_issues |
($queue.aggregate.available_old // 0 | number_or_zero) as $old_available |
($queue.aggregate.dependency_inconsistent_available // 0 | number_or_zero) as $dependency_inconsistent |
($queue.aggregate.needs_tier // 0 | number_or_zero) as $needs_tier |
($queue.aggregate.needs_status // 0 | number_or_zero) as $needs_status |
($queue.aggregate.nmr_inactive // 0 | number_or_zero) as $nmr_inactive |
($queue.aggregate.oldest_nmr_inactivity_age_min // 0 | number_or_zero) as $oldest_nmr_inactivity_age_min |
($queue.aggregate.nmr_inactivity_threshold_min // 0 | number_or_zero) as $nmr_inactivity_threshold_min |
($queue.aggregate.gh_errors // 0 | number_or_zero) as $gh_errors |
($queue.error // "") as $queue_error |
($queue_error == "" and $gh_errors == 0) as $queue_scan_complete |
($current.dispatch_alive // false) as $dispatch_alive |
($current.worker_outcomes.spawned // 0 | number_or_zero) as $spawned |
($current.worker_outcomes.launch_validation_failed // $current.pulse_counter_hits.dispatch_worker_launch_failed // 0 | number_or_zero) as $launch_validation_failed |
($current.worker_terminal_events // 0 | number_or_zero) as $current_terminal_events |
($recent_summary.metrics.total // 0 | number_or_zero) as $recent_total |
($summary.metrics.total // 0 | number_or_zero) as $hist_total |
($summary.metrics.terminal_session_total // $summary.metrics.total // 0 | number_or_zero) as $hist_terminal_total |
($summary.metrics.runtime_handoffs // $summary.metrics.succeeded // 0 | number_or_zero) as $hist_handoffs |
($summary.delivery_stages // {}) as $hist_delivery |
(if $hist_delivery.delivered_successes == null then null else ($hist_delivery.delivered_successes | number_or_zero) end) as $hist_delivered |
($summary.metrics.failure_families // []) as $failure_families |
($recent_summary.metrics.failure_families // []) as $recent_failure_families |
($summary.progress_blockers // {}) as $progress_blockers |
($current.canonical_reconciliation.refusal_count // 0 | number_or_zero) as $canonical_reconciliation_refusal_count |
($current.canonical_reconciliation.classification // "none") as $canonical_reconciliation_classification |
($current.canonical_reconciliation.canonical_recovery_advisory_observed // false) as $canonical_recovery_advisory_observed |
([$progress_blockers.retained_unverified[]?
  | select(((.reason // "") | contains("permission"))
    and ((((.session_key // "") | startswith("supervisor-pulse")))
      or (((.source // "") | contains("supervisor-pulse")))))] | length) as $bounded_retained_supervisor_permission_blockers |
($progress_blockers.retained_supervisor_permission_total // $bounded_retained_supervisor_permission_blockers | number_or_zero) as $retained_supervisor_permission_blockers |
($api.graphql_circuit_breaker_trips // 0 | number_or_zero) as $graphql_trips |
{
  generated_at: (now | todateiso8601),
  inputs: {current_window: $window, historical_window: $since, recent_window: $recent},
  summary: {
    max_workers: $max_workers,
    active_workers: $active_workers,
    active_workers_source: (if $active_worker_processes == null then "capacity_gauge" else "process_scan" end),
    inferred_active_workers: $inferred_active_workers,
    available_slots: $effective_available_slots,
    dispatch_alive: $dispatch_alive,
    dispatch_stage_events: ($current.dispatch_stage_events // 0),
    worker_launches_in_window: $spawned,
    worker_terminal_events_in_window: $current_terminal_events,
    worker_launch_validation_failures_in_window: $launch_validation_failed,
    recent_worker_events: $recent_total,
    historical_worker_events: $hist_total,
    historical_worker_runtime_handoffs: $hist_handoffs,
    historical_runtime_handoff_rate: (if $hist_terminal_total > 0 then (($hist_handoffs / $hist_terminal_total) * 100 | floor) else null end),
    historical_worker_delivered_successes: $hist_delivered,
    historical_delivery_success_rate: (if $hist_terminal_total > 0 and $hist_delivered != null then (($hist_delivered / $hist_terminal_total) * 100 | floor) else null end),
    historical_worker_successes: $hist_delivered,
    historical_success_rate: (if $hist_terminal_total > 0 and $hist_delivered != null then (($hist_delivered / $hist_terminal_total) * 100 | floor) else null end),
    auto_dispatch_open: ($queue.aggregate.auto_dispatch_open // 0),
    auto_dispatch_available_unassigned: $available_issues,
    auto_dispatch_eligible_available_unassigned: $eligible_issues,
    auto_dispatch_available_old: $old_available,
    auto_dispatch_dependency_inconsistent_available: $dependency_inconsistent,
    auto_dispatch_repos_with_available: ($queue.aggregate.repos_with_available // 0),
    auto_dispatch_scan_errors: $gh_errors,
    auto_dispatch_scan_state: (if $queue_error == "" then "scanned" else $queue_error end),
    graphql_budget_status: ($current.graphql_budget_status // "unknown"),
    runner_health: ($runner.finding // "unknown"),
    retained_supervisor_permission_blockers: $retained_supervisor_permission_blockers,
    canonical_reconciliation_refusals: $canonical_reconciliation_refusal_count,
    recurrent_failure_families: ([$failure_families[] | select((.count // 0) >= $failure_threshold and (.confidence // "low") == "high" and (.family // "") != "other-failure")] | length)
  },
  queue: ($queue.aggregate // {}),
  current_state: {
    dispatch_stage_counts: ($current.dispatch_stage_counts // {}),
    worker_outcomes: ($current.worker_outcomes // {}),
    pulse_counter_hits: ($current.pulse_counter_hits // {}),
    pulse_gauges: ($current.pulse_gauges // {}),
    current_state_guardrails: ($current.current_state_guardrails // {}),
    dispatch_pacing: ($current.dispatch_pacing // {}),
    canonical_reconciliation: {
      refusal_count: $canonical_reconciliation_refusal_count,
      classification: $canonical_reconciliation_classification,
      canonical_recovery_advisory_observed: $canonical_recovery_advisory_observed
    },
    active_worker_processes: ($current.active_worker_processes // null),
    top_pre_launch_blockers: ($current.top_pre_launch_blockers // [])
  },
  worker_activity: {
    historical: {
      window: ($summary.window // {}),
      metrics: (($summary.metrics // {}) | del(.recent_examples, .failure_groups, .failure_families)),
      pulse_stats: ($summary.pulse_stats // {}),
      delivery_stages: ($summary.delivery_stages // {check_state: "unavailable"})
    },
    recent: {
      window: ($recent_summary.window // {}),
      metrics: (($recent_summary.metrics // {}) | del(.recent_examples, .failure_groups, .failure_families)),
      pulse_stats: ($recent_summary.pulse_stats // {}),
      delivery_stages: ($recent_summary.delivery_stages // {check_state: "unavailable"})
    },
    providers: ($providers.provider_diagnostics // {}),
    progress_blockers: {
      scope: ($progress_blockers.scope // "global"),
      events_in_window: ($progress_blockers.event_total // 0),
      proven_current: ($progress_blockers.active_total // 0),
      retained_unverified: ($progress_blockers.retained_unverified_total // 0),
      retained_supervisor_permission: $retained_supervisor_permission_blockers
    }
  },
  failure_family_remediation: ($failure_families | map(. as $family | {
    fingerprint,
    family,
    count,
    distinct_sessions,
    first_ts,
    last_ts,
    confidence,
    recovery_outcome,
    recent_count: (([$recent_failure_families[] | select(.fingerprint == $family.fingerprint)] | first | .count) // 0)
  })),
  runner_health: $runner,
  api_budget: {
    graphql_circuit_breaker_trips: ($api.graphql_circuit_breaker_trips // 0),
    reserve_mode_cycles: ($api.reserve_mode_cycles // 0),
    deferred_optional_stages: ($api.deferred_optional_stages // 0),
    secondary_cooldown_state: ($api.secondary_cooldown_state // "unknown"),
    cadence_api_risk: ($api.cadence_api_risk // "unknown")
  },
  findings: ([
    if $canonical_reconciliation_refusal_count > 0 then
      finding(
        "pulse-canonical-reconciliation-stops";
        "medium";
        "Canonical reconciliation stopped on a non-exact default-branch HEAD";
        [
          ("reconciliation_refusal_count=" + ($canonical_reconciliation_refusal_count | tostring)),
          ("canonical_reconciliation_classification=" + $canonical_reconciliation_classification),
          ("canonical_recovery_advisory_observed=" + ($canonical_recovery_advisory_observed | tostring))
        ];
        "Inspect the audited canonical-recovery advisory and reconciliation evidence. Preserve canonical checkout state; do not reset, stash, or clean it from pulse.";
        false
      )
    else empty end,
    if $retained_supervisor_permission_blockers > 0 then
      finding(
        "retained-supervisor-permission-blockers";
        "medium";
        "Retained supervisor permission blockers require classification";
        [
          ("retained_supervisor_permission_blockers=" + ($retained_supervisor_permission_blockers | tostring)),
          ("retained_unverified_blockers_all_sources=" + (($progress_blockers.retained_unverified_total // 0) | tostring)),
          "blocker_evidence=aggregate_redacted"
        ];
        "Run worker-activity-helper.sh live-workers and worker-activity-helper.sh summary --since 7d to classify retained records. Reconcile only confirmed stale sessions by appending an audited non-blocking terminal event with worker-blocker-cli.mjs resolve-session; do not delete blocker evidence or clear records that still have a live owner.";
        false
      )
    else empty end,
    if ($queue_scan_complete and $dependency_inconsistent > 0) then
      finding(
        "pulse-dependency-inconsistent-availability";
        "high";
        "Auto-dispatch issues are labelled available with unresolved dependencies";
        [("dependency_inconsistent_available=" + ($dependency_inconsistent | tostring))];
        "Run issue relationship synchronization and dependency status normalization before the next dispatch scan.";
        true
      )
    else empty end,
    if ($queue_scan_complete and $dispatch_alive and $eligible_issues >= $threshold and $active_workers == 0) then
      finding(
        "pulse-underfilled-auto-dispatch-queue";
        "high";
        "Auto-dispatch queue is visible while worker capacity is empty";
        [
          ("active_workers=" + ($active_workers | tostring) + "/" + ($max_workers | tostring)),
          ("eligible_available_unassigned_auto_dispatch=" + ($eligible_issues | tostring)),
          ("available_older_than_threshold=" + ($old_available | tostring)),
          "dispatch_alive=true",
          ("dispatch_stage_events=" + (($current.dispatch_stage_events // 0) | tostring))
        ];
        "Inspect why the pulse did not retain active workers for visible status:available auto-dispatch issues; start with pulse-current-state-helper, worker-activity-helper, and pulse-diagnose-helper cycle-health.";
        true
      )
    else empty end,
    if ($queue_scan_complete and $dispatch_alive and $effective_available_slots >= $threshold and $eligible_issues < $threshold) then
      finding(
        "pulse-eligible-queue-under-target";
        "medium";
        "Dispatch-eligible queue depth is below the bounded capacity target";
        [
          ("available_slots=" + ($effective_available_slots | tostring)),
          ("eligible_available_unassigned=" + ($eligible_issues | tostring)),
          ("eligible_depth_target=" + ($threshold | tostring)),
          "dispatch_alive=true",
          ("auto_dispatch_open=" + (($queue.aggregate.auto_dispatch_open // 0) | tostring)),
          ("assigned_in_flight=" + (($queue.aggregate.assigned_in_flight // $queue.aggregate.assigned // 0) | tostring)),
          ("blocked_explicit_hold=" + (($queue.aggregate.blocked_explicit_hold // $queue.aggregate.blocked_labels // 0) | tostring)),
          ("needs_maintainer_review=" + (($queue.aggregate.nmr // 0) | tostring)),
          ("missing_tier=" + ($needs_tier | tostring)),
          ("missing_status=" + ($needs_status | tostring))
        ];
        "Run existing task generators and metadata normalisers for already-authorized work; if no eligible issues remain, request maintainer authorization decisions. Do not add auto-dispatch, clear needs-maintainer-review, or infer dispatch consent from status/origin labels.";
        false
      )
    else empty end,
    if ($queue_scan_complete and $nmr_inactive > 0) then
      finding(
        "pulse-inactive-nmr-holds";
        "medium";
        "Needs-maintainer-review holds have aged aggregate inactivity";
        [
          ("needs_maintainer_review=" + (($queue.aggregate.nmr // 0) | tostring)),
          ("nmr_inactive_at_threshold=" + ($nmr_inactive | tostring)),
          ("nmr_inactivity_threshold_minutes=" + ($nmr_inactivity_threshold_min | tostring)),
          ("oldest_nmr_inactivity_minutes=" + ($oldest_nmr_inactivity_age_min | tostring)),
          "nmr_inactivity_basis=issue_updatedAt_not_label_application_time"
        ];
        "Request authority-aware maintainer review of inactive NMR holds without removing needs-maintainer-review, adding auto-dispatch, posting approval markers, or commenting on individual held issues.";
        false
      )
    else empty end,
    if ($dispatch_alive and ($spawned - ([($recent_total), ($current_terminal_events)] | max) - $launch_validation_failed) >= 3 and $active_workers == 0) then
      finding(
        "pulse-launch-accounting-gap";
        "high";
        "Pulse recorded worker launches without active workers or recent terminal metrics";
        [
          ("worker_launches_in_current_window=" + ($spawned | tostring)),
          ("recent_worker_metric_events=" + ($recent_total | tostring)),
          ("worker_terminal_events_in_current_window=" + ($current_terminal_events | tostring)),
          ("worker_launch_validation_failures_in_current_window=" + ($launch_validation_failed | tostring)),
          ("active_workers=" + ($active_workers | tostring)),
          ("available_slots=" + ($available_slots | tostring)),
          "dispatch_alive=true"
        ];
        "Add or repair launch-validation evidence so every spawned worker becomes an active process, a terminal metric, or a classified launch failure.";
        true
      )
    else empty end,
    if ($needs_tier > 0) then
      finding(
        "auto-dispatch-missing-tier-labels";
        "medium";
        "Some auto-dispatch issues are missing tier labels";
        [("missing_tier_count=" + ($needs_tier | tostring))];
        "Run or repair label normalisation so auto-dispatch issues carry exactly one tier label before worker pickup.";
        false
      )
    else empty end,
    if ($gh_errors > 0) then
      finding(
        "pulse-check-gh-scan-errors";
        "medium";
        "Auto-dispatch queue scan had GitHub read errors";
        [("gh_errors=" + ($gh_errors | tostring))];
        "Check GitHub authentication and API budget before treating queue counts as complete.";
        false
      )
    else empty end,
    if ($queue_error != "") then
      finding(
        "pulse-check-queue-scan-skipped";
        "medium";
        "Auto-dispatch queue scan was skipped or incomplete";
        [("queue_scan_state=" + $queue_error)];
        "Re-run pulse-check after API cooldown clears before making queue-depth or underfill claims.";
        false
      )
    else empty end,
    if ($graphql_trips > 0 or ($current.dispatch_api_blocked // false) == true) then
      finding(
        "github-api-budget-blocking-dispatch";
        "high";
        "GitHub API budget is blocking or degrading dispatch";
        [("graphql_circuit_breaker_trips=" + ($graphql_trips | tostring)), ("dispatch_api_blocked=" + (($current.dispatch_api_blocked // false) | tostring))];
        "Use pulse-diagnose-helper api-budget to identify top callers and shift avoidable reads to cache/REST before increasing concurrency.";
        true
      )
    else empty end,
    if ($hist_terminal_total >= 10 and (($hist_handoffs * 100) / $hist_terminal_total) < 70) then
      finding(
        "worker-runtime-handoff-rate-regression";
        "medium";
        "Historical worker runtime handoff rate is below the productivity target";
        [("runtime_handoff_rate_percent=" + (((($hist_handoffs * 100) / $hist_terminal_total) | floor) | tostring)), ("terminal_session_outcomes=" + ($hist_terminal_total | tostring)), ("worker_events=" + ($hist_total | tostring))];
        "Cluster failure families with worker-activity-helper summary --json, then file targeted fixes for the dominant cause instead of increasing concurrency.";
        false
      )
    else empty end,
    if ($hist_terminal_total >= 10 and $hist_delivered != null and (($hist_delivered * 100) / $hist_terminal_total) < 70) then
      finding(
        "worker-delivery-rate-regression";
        "medium";
        "Historical worker delivered-success rate is below the productivity target";
        [("delivered_success_rate_percent=" + (((($hist_delivered * 100) / $hist_terminal_total) | floor) | tostring)), ("delivered_successes=" + ($hist_delivered | tostring)), ("terminal_session_outcomes=" + ($hist_terminal_total | tostring))];
        "Compare runtime handoffs, opened PRs, merged PRs, and solved issues with worker-activity-helper summary --pr-check before changing dispatch capacity.";
        false
      )
    else empty end
    ,
    ($failure_families[] as $family
      | $family
      | select((.count // 0) >= $failure_threshold and (.distinct_sessions // 0) >= 2 and (.confidence // "low") == "high" and (.family // "") != "other-failure")
      | (([$recent_failure_families[] | select(.fingerprint == $family.fingerprint)] | first | .count) // 0) as $family_recent_count
      | select($family_recent_count >= $failure_threshold)
      | finding(
          ("worker-failure-family-" + (.family // "unknown"));
          "high";
          ("Remediate recurrent worker failure family: " + (.family // "unknown"));
          [
            ("fingerprint=" + (.fingerprint // "unknown")),
            ("family=" + (.family // "unknown")),
            ("failures_in_window=" + ((.count // 0) | tostring)),
            ("distinct_sessions=" + ((.distinct_sessions // 0) | tostring)),
            ("confidence=" + (.confidence // "unknown")),
            ("first_observed_epoch=" + ((.first_ts // 0) | tostring)),
            ("last_observed_epoch=" + ((.last_ts // 0) | tostring))
          ];
          "Fix or reclassify this stable failure family, add a fixture for its canonical metric shape, and verify that its recurrence count falls below threshold in both recent and historical windows.";
          true
        ) + {
          family_fingerprint: (.fingerprint // ""),
          family: (.family // "unknown"),
          family_count: (.count // 0),
          family_recent_count: $family_recent_count,
          family_first_ts: (.first_ts // 0),
          family_last_ts: (.last_ts // 0),
          family_confidence: (.confidence // "unknown")
        })
  ])
}
