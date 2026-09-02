import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { toolCallSucceeded } from "./observability-tool-calls.mjs";

const DEFAULT_COMPACT_BYTES = 8192;
const DEFAULT_COMPACT_LINES = 80;
const outputPolicyByCallId = new Map();

function positiveThreshold(name, fallback) {
  const value = Number.parseInt(process.env[name] || "", 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function requiresExactOutput(command) {
  if (typeof command !== "string") return false;
  return /^(?:cat|head|tail|less|more)\s|^git\s+diff\b|\s--json(?:\s|$)|\ssecurity\s|secret|credential/i.test(command.trim());
}

function pruneOutputPolicies() {
  if (outputPolicyByCallId.size <= 2000) return;
  for (const callID of Array.from(outputPolicyByCallId.keys()).slice(0, 1000)) {
    outputPolicyByCallId.delete(callID);
  }
}

export function rememberBashOutputPolicy(callID, args) {
  if (!callID) return;
  outputPolicyByCallId.set(callID, {
    exact: requiresExactOutput(args?.command),
  });
  pruneOutputPolicies();
}

function isVerboseOutput(text) {
  const byteCount = Buffer.byteLength(text, "utf8");
  const lineCount = (text.match(/\n/g) || []).length;
  return byteCount >= positiveThreshold("AIDEVOPS_OUTPUT_SANDBOX_COMPACT_BYTES", DEFAULT_COMPACT_BYTES)
    || lineCount >= positiveThreshold("AIDEVOPS_OUTPUT_SANDBOX_COMPACT_LINES", DEFAULT_COMPACT_LINES);
}

export function compactSuccessfulBashOutput({ callID, output, scriptsDir, durationMs, log }) {
  const policy = outputPolicyByCallId.get(callID);
  outputPolicyByCallId.delete(callID);
  const text = output?.output;
  if (policy?.exact || typeof text !== "string" || !toolCallSucceeded(output) || !isVerboseOutput(text)) {
    return false;
  }

  const helper = join(scriptsDir, "output-sandbox-helper.sh");
  if (!existsSync(helper)) return false;
  try {
    const summary = execFileSync(
      helper,
      ["compact", "--command", "bash", "--duration-ms", String(durationMs ?? 0), "--tag", "opencode-tool"],
      { input: text, encoding: "utf8", maxBuffer: 64 * 1024 },
    );
    if (!summary.trim()) return false;
    output.output = summary.trimEnd();
    log("INFO", `[output-sandbox] retained verbose Bash output as a bounded receipt`);
    return true;
  } catch {
    log("WARN", `[output-sandbox] retention unavailable; returning native Bash output`);
    return false;
  }
}
