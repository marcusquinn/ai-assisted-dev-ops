// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

function tokenCount(tokens) {
  if (Number.isFinite(tokens)) return Number(tokens);
  if (!tokens || typeof tokens !== "object") return 0;
  if (Number.isFinite(tokens.total_tokens)) return Number(tokens.total_tokens);
  if (Number.isFinite(tokens.total)) return Number(tokens.total);
  return ["input", "output", "reasoning", "cache_read", "cache_write", "read", "write"]
    .reduce((total, key) => total + (Number(tokens[key]) || 0), 0)
    + tokenCount(tokens.cache);
}

function parsedStepFinish(line) {
  let record;
  try {
    record = JSON.parse(line);
  } catch {
    return null;
  }
  const part = record.part || record.message || record;
  if (record.type !== "step_finish" || part.type !== "step-finish") return null;
  return { record, part };
}

function addRequestUsage(summary, part) {
  const tokens = part.tokens || part.usage;
  const cost = Number(part.cost ?? part.cost_usd);
  if (!tokens && !Number.isFinite(cost)) return;
  summary.request_count += 1;
  summary.tokens_total += tokenCount(tokens);
  if (Number.isFinite(cost)) {
    summary.cost_usd += cost;
    summary.cost_count += 1;
  }
}

function requestProvider(record, part) {
  return part.providerID || part.provider_id || record.providerID || record.provider_id;
}

function requestModel(record, part) {
  return part.modelID || part.model_id || record.modelID || record.model_id;
}

function addRequestIdentity(summary, record, part) {
  const provider = requestProvider(record, part);
  const model = requestModel(record, part);
  if (provider && model) summary.models.add(`${provider}/${model}`);
  const variant = part.variant || record.variant;
  if (variant) summary.variants.add(String(variant));
}

function outputUsage(output) {
  const summary = {
    request_count: 0,
    tokens_total: 0,
    cost_usd: 0,
    cost_count: 0,
    models: new Set(),
    variants: new Set(),
  };
  for (const line of String(output || "").split("\n")) {
    const parsed = parsedStepFinish(line);
    if (!parsed) continue;
    addRequestUsage(summary, parsed.part);
    addRequestIdentity(summary, parsed.record, parsed.part);
  }
  const completeCost = summary.request_count > 0 && summary.cost_count === summary.request_count;
  return {
    request_count: summary.request_count,
    tokens_total: summary.tokens_total,
    cost_usd: completeCost ? summary.cost_usd : null,
    cost_count: summary.cost_count,
    models: [...summary.models].join(","),
    variants: [...summary.variants].join(","),
  };
}

export function csvValues(value) {
  return [...new Set(String(value || "").split(",").filter(Boolean))];
}

function positiveInteger(value) {
  return Number.isInteger(value) && value > 0 ? value : 0;
}

function metricUsage(metric) {
  const requestCount = Number(metric.observed_usage_count || 0);
  const costCount = Number(metric.observed_cost_count || 0);
  return {
    request_count: positiveInteger(requestCount),
    tokens_total: Number(metric.observed_tokens_total || 0),
    cost_usd: costCount > 0 ? Number(metric.observed_cost_usd) : null,
    cost_count: positiveInteger(costCount),
    models: String(metric.observed_model || ""),
    variants: String(metric.observed_variant || ""),
  };
}

function mergeUsage(...sources) {
  const normalized = sources.filter((usage) => Number(usage?.request_count || 0) > 0);
  const requestCount = Math.max(0, ...normalized.map((usage) => Number(usage.request_count)));
  const complete = normalized.find((usage) => (
    Number(usage.request_count) === requestCount
    && Number(usage.cost_count || 0) === requestCount
    && Number.isFinite(Number(usage.cost_usd))
  ));
  const tokenSource = normalized.find((usage) => Number(usage.request_count) === requestCount);
  return {
    request_count: requestCount,
    tokens_total: tokenSource ? Number(tokenSource.tokens_total || 0) : 0,
    cost_usd: complete ? Number(complete.cost_usd) : null,
    cost_count: complete ? requestCount : 0,
    models: [...new Set(normalized.flatMap((usage) => csvValues(usage.models)))].join(","),
    variants: [...new Set(normalized.flatMap((usage) => csvValues(usage.variants)))].join(","),
  };
}

export function combinedUsage(metric, output) {
  return mergeUsage(metricUsage(metric), outputUsage(output));
}
