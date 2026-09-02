import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { toolCallSucceeded } from "./observability-tool-calls.mjs";

const DEFAULT_COMPACT_BYTES = 8192;
const DEFAULT_COMPACT_LINES = 80;
const outputPolicyByCallId = new Map();
const COMMAND_CONTROL_PATTERN = /[;&|`<>]|\$\(|\r|\n/;
const SENSITIVE_COMMAND_PATTERN = /secret|credential|password|authorization|token|--json/i;
const ELIGIBLE_COMMAND_PATTERN = /^(?:(?:npm|pnpm|yarn|bun)\s+(?:test|build|lint|check|typecheck|ci)\b|(?:npm|pnpm|yarn|bun)\s+run\s+(?:test|build|lint|check|typecheck)(?:[:_.-][\w.-]+)?\b|(?:python3?\s+-m\s+)?pytest\b|go\s+test\b|cargo\s+(?:test|build|check|clippy)\b|make(?:\s+(?:test|check|build|lint)(?:[:_.-][\w.-]+)?)?(?:\s|$)|cmake\s+--build\b|(?:gradle|\.\/gradlew)\s+(?:test|build|check|lint)\b|mvn\s+(?:test|verify|package|install|compile)\b|dotnet\s+(?:test|build)\b|shellcheck\b|(?:\S*\/)?linters-local\.sh\b|bash\s+\S*(?:test|lint)[^\s]*\.sh\b)/i;

function positiveThreshold(name, fallback) {
  const value = Number.parseInt(process.env[name] || "", 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function commandIsEligible(command) {
  if (typeof command !== "string") return false;
  const normalized = command.trim();
  if (COMMAND_CONTROL_PATTERN.test(normalized) || SENSITIVE_COMMAND_PATTERN.test(normalized)) return false;
  return ELIGIBLE_COMMAND_PATTERN.test(normalized);
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
    compact: commandIsEligible(args?.command),
  });
  pruneOutputPolicies();
}

export function isVerboseBashOutput(text) {
  if (typeof text !== "string") return false;
  const byteCount = Buffer.byteLength(text, "utf8");
  const lineCount = (text.match(/\n/g) || []).length;
  return byteCount >= positiveThreshold("AIDEVOPS_OUTPUT_SANDBOX_COMPACT_BYTES", DEFAULT_COMPACT_BYTES)
    || lineCount >= positiveThreshold("AIDEVOPS_OUTPUT_SANDBOX_COMPACT_LINES", DEFAULT_COMPACT_LINES);
}

export function compactSuccessfulBashOutput({ callID, output, scriptsDir, durationMs, wasVerbose, log }) {
  const policy = outputPolicyByCallId.get(callID);
  outputPolicyByCallId.delete(callID);
  const text = output?.output;
  if (policy?.compact !== true || typeof text !== "string" || !toolCallSucceeded(output)
    || !(wasVerbose ?? isVerboseBashOutput(text))) {
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
