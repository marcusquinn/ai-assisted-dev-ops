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
  for (const field of ["input_tokens", "output_tokens", "reasoning_tokens", "cache_read_tokens", "cache_write_tokens"]) {
    tokens[field] = sum(completions, field);
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
    peak_prompt_tokens_proxy: promptSizes.length && promptSizes.every((v) => v !== null)
      ? Math.max(...promptSizes) : null,
    observed_context_limits: [...new Set(requests.map((r) => r.context_limit).filter(Number.isFinite))],
    compactions_requested: requested.length, compactions_completed: completed.length,
    summary_completions: summaries.length,
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
  if (telemetry.profile !== manifest.profile || !records.some((r) => r.type === "config.applied")
    || (manifest.profile !== "stock" && !(records[0].framework_tool_count > 0))) {
    throw new Error("Missing or mismatched plugin-loading evidence");
  }
  if (manifest.experimental_context_limit != null
    && (!telemetry.observed_context_limits.length
      || !telemetry.observed_context_limits.every((limit) => limit === manifest.experimental_context_limit))) {
    throw new Error("Experiment context limit was overridden");
  }
  const usage = manifest.relay?.upstream_usage || [];
  const total = (key) => usage.length && usage.every((r) => Number.isFinite(r[key]) && r[key] >= 0)
    ? usage.reduce((sum, r) => sum + r[key], 0) : null;
  const duration = (range) => {
    const ms = Date.parse(range?.finished_at) - Date.parse(range?.started_at);
    return Number.isFinite(ms) && ms >= 0 ? Math.round(ms) / 1000 : null;
  };
  const reward = trial.verifier_result?.rewards?.reward;
  const digest = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
  return {
    profile: manifest.profile, model: manifest.model,
    framework_commit: manifest.framework_commit, opencode_version: manifest.opencode_version,
    task_checksum: trial.task_checksum,
    source_result_sha256: digest(trialPath), source_events_sha256: digest(eventsPath),
    source_manifest_sha256: digest(join(root, "manifest.json")),
    billing: manifest.inference_route, leaderboard_comparable: false,
    experimental_context_limit: manifest.experimental_context_limit ?? null,
    verifier_reward: Number.isFinite(reward) ? reward : null,
    task_passed: reward === 1 && !trial.exception_info,
    trial_exception: /^[A-Za-z][A-Za-z0-9_]*$/.test(trial.exception_info?.exception_type || "")
      ? trial.exception_info.exception_type : null,
    agent_seconds: duration(trial.agent_execution), setup_seconds: duration(trial.agent_setup),
    relay_requests: manifest.relay?.requests ?? null,
    upstream_completed_responses: usage.length,
    upstream_usage_scope: "completed responses only",
    upstream_usage_complete: usage.length === manifest.relay?.requests
      && manifest.relay?.stream_failures === 0,
    upstream_input_tokens_including_cache: total("input_tokens"),
    upstream_output_tokens: total("output_tokens"), upstream_cached_tokens: total("cached_tokens"),
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
