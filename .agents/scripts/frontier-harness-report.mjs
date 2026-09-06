#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

/** Summarize observer records without interpreting untrusted text as a verdict. */
export function summarize(records) {
  if (!records.length || records[0].type !== "observer.started") {
    throw new Error("Missing observer startup evidence");
  }
  const profile = records[0].profile;
  for (const [index, record] of records.entries()) {
    if (record.schema !== 1 || record.profile !== profile || record.sequence !== index + 1) {
      throw new Error("Mixed, duplicate, or incomplete telemetry sequence");
    }
  }
  const completions = records.filter((r) => r.type === "completion");
  const summaries = completions.filter((r) => r.summary);
  const requests = records.filter((r) => r.type === "request");
  const requested = records.filter((r) => r.type === "compaction.requested");
  const completed = records.filter((r) => r.type === "compaction.completed");
  const sum = (rows, field) => rows.length && rows.every((r) => Number.isFinite(r[field]) && r[field] >= 0)
    ? rows.reduce((total, r) => total + r[field], 0) : null;
  const tokens = {};
  const usageCoverage = {};
  for (const field of ["input_tokens", "output_tokens", "reasoning_tokens", "cache_read_tokens", "cache_write_tokens"]) {
    tokens[field] = sum(completions, field);
    const measured = completions.filter((r) => Number.isFinite(r[field]) && r[field] >= 0);
    usageCoverage[field] = { measured_completions: measured.length,
      missing_completions: completions.length - measured.length,
      completed_subtotal: sum(measured, field) };
  }
  // Input + cache reads + cache writes is an occupancy PROXY, not a tokenizer
  // measurement of the actual live context. Never add cumulative session usage.
  const promptSizes = completions.map((r) => {
    const values = [r.input_tokens, r.cache_read_tokens, r.cache_write_tokens];
    return values.every((v) => Number.isFinite(v) && v >= 0)
      ? values.reduce((a, b) => a + b, 0) : null;
  });
  const afterCompaction = completions.filter((r) => !r.summary
    && completed.some((c) => c.session === r.session && c.sequence < r.sequence));
  return {
    schema: 1, profile, billing: null, evidence_kind: "contestant-reported",
    api_spend_usd: null, verifier_success: null,
    requests: requests.length, completions: completions.length,
    errors: completions.filter((r) => r.error).length,
    ...tokens,
    usage_coverage: usageCoverage,
    calibration: {
      initial: records.filter((r) => r.type === "calibration.initial"),
      stopped: records.filter((r) => r.type === "calibration.stopped"),
      applied: requests.map((r) => ({ session: r.session, context: r.context_limit,
        input: r.input_limit, output: r.output_limit, capacity: r.capacity ?? null })),
      footprints: records.filter((r) => r.type === "request.footprint"),
    },
    peak_prompt_tokens_proxy: promptSizes.length && promptSizes.every((v) => v !== null)
      ? Math.max(...promptSizes) : null,
    observed_context_limits: [...new Set(requests.map((r) => r.context_limit).filter(Number.isFinite))],
    compactions_requested: requested.length, compactions_completed: completed.length,
    summary_completions: summaries.length,
    summary_input_tokens: sum(summaries, "input_tokens"),
    summary_cache_read_tokens: sum(summaries, "cache_read_tokens"),
    summary_cache_write_tokens: sum(summaries, "cache_write_tokens"),
    summary_output_tokens: sum(summaries, "output_tokens"),
    completions_after_compaction: afterCompaction.length,
    errors_after_compaction: afterCompaction.filter((r) => r.error).length,
    caveats: [
      "Contestant-writable telemetry is diagnostic, not tamper-proof; corroborate usage with the host relay manifest.",
      "Billing route is established by the host manifest, not by contestant telemetry.",
      "Telemetry does not establish verifier success; join the runner's explicit verifier result.",
      "No incremental API charge is inferred; subscription usage is not free compute.",
      "No compaction events means compaction effectiveness was not exercised.",
      "Post-compaction completion/error counts are descriptive, not causal evidence.",
      "Summary calls or child sessions not emitted by the runtime remain unobserved.",
    ],
  };
}

function validateRunEvidence(manifest, records, telemetry) {
  if (telemetry.profile !== manifest.profile || !records.some((r) => r.type === "config.applied")
    || (manifest.profile !== "stock" && !(records[0].framework_tool_count > 0))) {
    throw new Error("Missing or mismatched plugin-loading evidence");
  }
  const limitsMatch = telemetry.calibration.applied.every((limit) => limit.context === manifest.experimental_context_limit
    && limit.input === manifest.experimental_context_limit - manifest.experimental_output_reserve
    && limit.output === manifest.experimental_output_reserve);
  const limitsObserved = telemetry.observed_context_limits.length > 0;
  if (manifest.experimental_context_limit != null && (!limitsObserved || !limitsMatch)) {
    throw new Error("Experiment model limits were overridden or unobserved");
  }
}

function transportUsage(manifest) {
  const usage = manifest.relay?.upstream_usage || [];
  const total = (key) => usage.length && usage.every((r) => Number.isFinite(r[key]) && r[key] >= 0)
    ? usage.reduce((sum, r) => sum + r[key], 0) : null;
  const usageFieldsComplete = usage.length > 0 && usage.every((row) =>
    ["input_tokens", "output_tokens", "cached_tokens"].every((key) => Number.isFinite(row[key]) && row[key] >= 0));
  return {
    relay_requests: manifest.relay?.requests ?? null,
    upstream_completed_responses: usage.length,
    upstream_usage_scope: "completed responses only",
    upstream_responses_without_usage: Number.isInteger(manifest.relay?.requests)
      ? Math.max(0, manifest.relay.requests - usage.length) : null,
    upstream_usage_complete: usageFieldsComplete && usage.length === manifest.relay?.requests
      && manifest.relay?.stream_failures === 0,
    upstream_input_tokens_including_cache: total("input_tokens"),
    upstream_output_tokens: total("output_tokens"), upstream_cached_tokens: total("cached_tokens"),
  };
}

function calibrationStatus(manifest, telemetry) {
  if (telemetry.calibration.stopped.length > 0) return "infeasible_configuration";
  const initial = [...new Map(telemetry.calibration.initial.map((row) => [row.session, row])).values()];
  const initialFits = initial.every((row) => row.status === "initial_input_fits" && row.capacity?.usable_input > 0);
  const capacityKnown = telemetry.calibration.applied.every((row) => {
    const validReserve = Number.isFinite(row.capacity?.reserve) && row.capacity.reserve >= 0;
    return validReserve && row.capacity?.formula === "opencode-1.18.29-explicit-input-v1"
      && row.capacity.usable_input === Math.max(0, row.input - row.capacity.reserve);
  });
  const observed = initial.length > 0 && telemetry.calibration.applied.length > 0;
  const calibrated = manifest.opencode_version === "1.18.29" && observed && initialFits && capacityKnown;
  return calibrated ? "initial_input_fits" : "unknown";
}

function runVerdict(manifest, trial, status) {
  const reward = trial.verifier_result?.rewards?.reward;
  const successfulExit = manifest.status === "runner_finished" && manifest.runner_exit_code === 0 && !manifest.interrupted;
  const runnerFinished = successfulExit && manifest.completed_trials === 1 && manifest.errored_trials === 0;
  const taskPassed = reward === 1 && !trial.exception_info;
  return {
    calibration_status: status,
    verifier_reward: Number.isFinite(reward) ? reward : null,
    task_passed: taskPassed,
    comparison_valid: taskPassed && status !== "infeasible_configuration" && runnerFinished
      && (manifest.experimental_context_limit == null || status === "initial_input_fits"),
    runner_finished: runnerFinished,
    trial_exception: /^[A-Za-z][A-Za-z0-9_]*$/.test(trial.exception_info?.exception_type || "")
      ? trial.exception_info.exception_type : null,
  };
}

/** Join host-owned transport accounting with the runner's explicit verdict. */
export function summarizeRun(root) {
  const json = (path) => JSON.parse(readFileSync(path, "utf8"));
  const manifest = json(join(root, "manifest.json"));
  const jobs = join(root, "jobs/pilot");
  const dirs = readdirSync(jobs, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  if (dirs.length !== 1) throw new Error("Expected exactly one immutable pilot trial");
  const trialDir = join(jobs, dirs[0].name);
  const trialPath = join(trialDir, "result.json");
  const trial = json(trialPath);
  const eventsPath = join(trialDir, "agent/frontier-events.jsonl");
  const records = readFileSync(eventsPath, "utf8").trim().split("\n").map(JSON.parse);
  const telemetry = summarize(records);
  validateRunEvidence(manifest, records, telemetry);
  const duration = (range) => {
    const ms = Date.parse(range?.finished_at) - Date.parse(range?.started_at);
    return Number.isFinite(ms) && ms >= 0 ? Math.round(ms) / 1000 : null;
  };
  const digest = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
  return {
    profile: manifest.profile, model: manifest.model,
    framework_commit: manifest.framework_commit, opencode_version: manifest.opencode_version,
    task_checksum: trial.task_checksum,
    source_result_sha256: digest(trialPath), source_events_sha256: digest(eventsPath),
    source_manifest_sha256: digest(join(root, "manifest.json")),
    billing: manifest.inference_route, leaderboard_comparable: false,
    experimental_context_limit: manifest.experimental_context_limit ?? null,
    ...runVerdict(manifest, trial, calibrationStatus(manifest, telemetry)),
    agent_seconds: duration(trial.agent_execution), setup_seconds: duration(trial.agent_setup),
    ...transportUsage(manifest),
    telemetry,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length === 4 && process.argv[2] === "--run") {
      console.log(JSON.stringify(summarizeRun(process.argv[3]), null, 2));
    } else {
      if (process.argv.length !== 3) throw new Error("Expected EVENTS.jsonl or --run RUN_DIRECTORY");
      const text = readFileSync(process.argv[2], "utf8");
      const records = text.trim().split("\n").map((line) => JSON.parse(line));
      console.log(JSON.stringify(summarize(records), null, 2));
    }
  } catch {
    console.error("Cannot summarize telemetry: expected one complete observer JSONL file");
    process.exitCode = 1;
  }
}
