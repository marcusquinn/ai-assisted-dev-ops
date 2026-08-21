// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function integer(value, fallback = 0) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function firstValue(record, ...keys) {
  for (const key of keys) {
    const value = record?.[key];
    if (value !== undefined && value !== null && value !== "") return value;
  }
  return "";
}

function parseArgs(argv) {
  const options = {
    db: process.env.AIDEVOPS_OBS_DB_OVERRIDE || join(homedir(), ".aidevops", ".agent-workspace", "observability", "llm-requests.db"),
    metricsFile: process.env.AIDEVOPS_HEADLESS_METRICS_FILE || join(homedir(), ".aidevops", "logs", "headless-runtime-metrics.jsonl"),
    format: "markdown",
    headingLevel: 3,
    session: "",
    sessionKey: "",
    repo: "",
    issue: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--session") options.session = argv[++index] || "";
    else if (flag === "--session-key") options.sessionKey = argv[++index] || "";
    else if (flag === "--routine") options.sessionKey = `routine-${argv[++index] || ""}`;
    else if (flag === "--repo") options.repo = argv[++index] || "";
    else if (flag === "--issue") options.issue = argv[++index] || "";
    else if (flag === "--db") options.db = argv[++index] || "";
    else if (flag === "--metrics-file") options.metricsFile = argv[++index] || "";
    else if (flag === "--format") options.format = argv[++index] || "markdown";
    else if (flag === "--heading-level") options.headingLevel = integer(argv[++index], 3);
  }
  return options;
}

function parseMetricRecord(line) {
  if (!line.trim()) return null;
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function metricMatchesOptions(record, options) {
  const recordSessionKey = String(firstValue(record, "session_key", "sessionKey"));
  const recordSessionID = String(firstValue(record, "session_id", "sessionID"));
  const issueMatches = Boolean(options.issue) && [
    String(firstValue(record, "issue_number", "issueNumber")),
    recordSessionKey.replace(/^issue-/, ""),
  ].includes(String(options.issue));
  const repoMatches = !options.repo
    || String(firstValue(record, "repo_slug", "repoSlug")) === options.repo;
  const sessionMatches = Boolean(options.sessionKey)
    && [recordSessionKey, recordSessionID].includes(options.sessionKey);
  const directSessionMatches = Boolean(options.session)
    && [recordSessionID, recordSessionKey].includes(options.session);
  return [issueMatches && repoMatches, sessionMatches, directSessionMatches].some(Boolean);
}

function loadMetrics(options) {
  if (!options.metricsFile || !existsSync(options.metricsFile)) return [];
  const records = [];
  for (const line of readFileSync(options.metricsFile, "utf8").split("\n")) {
    const record = parseMetricRecord(line);
    if (record && metricMatchesOptions(record, options)) records.push(record);
  }
  return records;
}

function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function optionalRequestColumns(dbPath) {
  try {
    const output = execFileSync(
      "sqlite3",
      ["-readonly", dbPath, "SELECT name FROM pragma_table_info('llm_requests');"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 3000 },
    );
    const columns = new Set(output.trim().split("\n").filter(Boolean));
    return ["routing_population", "pricing_version"]
      .map((column) => columns.has(column) ? column : `NULL AS ${column}`)
      .join(", ");
  } catch {
    return "NULL AS routing_population, NULL AS pricing_version";
  }
}

function loadRequests(options, attempts) {
  if (!options.db || !existsSync(options.db)) return [];
  const sessionIDs = new Set();
  if (options.session) sessionIDs.add(options.session);
  for (const record of attempts) {
    const sessionID = firstValue(record, "session_id", "sessionID");
    if (sessionID) sessionIDs.add(String(sessionID));
  }
  if (sessionIDs.size === 0) return [];
  const values = [...sessionIDs].map(sqlString).join(",");
  const optionalColumns = optionalRequestColumns(options.db);
  const sql = `SELECT session_id, parent_session_id, provider_id, model_id, tokens_total, cost, error_type, finish_reason, variant, routing_tier, routing_candidate_index, routing_attempt, routing_reason, routing_escalated, aidevops_version, ${optionalColumns} FROM llm_requests WHERE session_id IN (${values}) OR parent_session_id IN (${values}) ORDER BY id;`;
  try {
    const output = execFileSync("sqlite3", ["-readonly", "-json", options.db, sql], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3000,
    }).trim();
    return output ? JSON.parse(output) : [];
  } catch {
    return [];
  }
}

export function runRoutingFeedbackCommand(argv, {
  summarizeRoutingFeedback,
  formatRoutingFeedbackMarkdown,
  formatRoutingFeedbackToast,
}) {
  const options = parseArgs(argv);
  const attempts = loadMetrics(options);
  const requests = loadRequests(options, attempts);
  const summary = summarizeRoutingFeedback({ requests, attempts });
  if (options.format === "json") return JSON.stringify(summary);
  if (options.format === "toast") return formatRoutingFeedbackToast(summary);
  return formatRoutingFeedbackMarkdown(summary, { headingLevel: options.headingLevel });
}
