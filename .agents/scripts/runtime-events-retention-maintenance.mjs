// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Bounded orchestration around the verified runtime-event partition primitive. */

function normalizedBound(value, defaultValue, maximum, label) {
  const parsed = Number.parseInt(String(value ?? defaultValue), 10);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum) {
    throw new TypeError(`${label} must be an integer from 1 to ${maximum}`);
  }
  return parsed;
}

function maintenanceConfig(options, dependencies) {
  const maxPartitions = normalizedBound(
    options.maxPartitions,
    dependencies.maxPartitionsDefault,
    1000,
    "maintenance max partitions",
  );
  const maxDurationSeconds = normalizedBound(
    options.maxDurationSeconds,
    dependencies.maxDurationSecondsDefault,
    3600,
    "maintenance max duration seconds",
  );
  const clock = typeof options.clock === "function" ? options.clock : Date.now;
  const cutoff = dependencies.normalizeCutoff(options.cutoff, options);
  const archiveOptions = { ...options, cutoff };
  delete archiveOptions.clock;
  delete archiveOptions.maxDurationSeconds;
  delete archiveOptions.maxPartitions;
  return { archiveOptions, clock, maxDurationSeconds, maxPartitions };
}

function planMaintenance(config, archive) {
  const planned = archive({ ...config.archiveOptions, apply: false });
  return Object.freeze({
    ...planned,
    max_duration_seconds: config.maxDurationSeconds,
    max_partitions: config.maxPartitions,
    status: planned.status === "dry_run" ? "maintenance_dry_run" : planned.status,
  });
}

function newTotals() {
  return {
    archive_bytes: 0,
    compacted_rows: 0,
    partition_ids: [],
    partitions_archived: 0,
    protected_rows: 0,
    source_bytes_archived: 0,
    source_rows_archived: 0,
  };
}

function accumulatePartition(totals, result) {
  totals.archive_bytes += Number(result.archive_bytes || 0);
  totals.compacted_rows += Number(result.compacted_rows || 0);
  totals.partition_ids.push(result.partition_id);
  totals.partitions_archived += 1;
  totals.protected_rows += Number(result.protected_rows || 0);
  totals.source_bytes_archived += Number(result.candidate_bytes || 0);
  totals.source_rows_archived += Number(result.candidate_rows || 0);
}

function maintenanceSummary(totals, config, stopReason, lastResult) {
  const backlogRemaining = stopReason === "max_duration" ||
    (stopReason === "max_partitions" && Boolean(lastResult?.more_candidates));
  const status = totals.partitions_archived > 0
    ? "maintained"
    : (lastResult?.status || stopReason);
  return Object.freeze({
    ...totals,
    applied: totals.partitions_archived > 0,
    backlog_remaining: backlogRemaining,
    max_duration_seconds: config.maxDurationSeconds,
    max_partitions: config.maxPartitions,
    status,
    stop_reason: stopReason,
  });
}

function applyMaintenance(config, archive) {
  const startedAt = config.clock();
  const totals = newTotals();
  let lastResult;
  let stopReason = "max_partitions";

  while (totals.partitions_archived < config.maxPartitions) {
    if ((config.clock() - startedAt) >= config.maxDurationSeconds * 1000) {
      stopReason = "max_duration";
      break;
    }
    const result = archive({ ...config.archiveOptions, apply: true });
    lastResult = result;
    if (result.status === "database_missing" || result.status === "no_candidates") {
      stopReason = result.status;
      break;
    }
    if (!result.applied || result.status !== "archived") {
      throw new Error(`unexpected runtime-event archive result: ${result.status}`);
    }
    accumulatePartition(totals, result);
    if (!result.more_candidates) {
      stopReason = "no_candidates";
      break;
    }
  }
  return maintenanceSummary(totals, config, stopReason, lastResult);
}

export function runRuntimeEventMaintenance(options, dependencies) {
  const config = maintenanceConfig(options, dependencies);
  return options.apply
    ? applyMaintenance(config, dependencies.archive)
    : planMaintenance(config, dependencies.archive);
}
