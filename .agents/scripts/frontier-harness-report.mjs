#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
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

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 3) throw new Error("Usage: frontier-harness-report.mjs EVENTS.jsonl");
    const text = readFileSync(process.argv[2], "utf8");
    const records = text.trim().split("\n").map((line) => JSON.parse(line));
    console.log(JSON.stringify(summarize(records), null, 2));
  } catch {
    console.error("Cannot summarize telemetry: expected one complete observer JSONL file");
    process.exitCode = 1;
  }
}
