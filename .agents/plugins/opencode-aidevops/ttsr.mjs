import { existsSync } from "fs";
import { join } from "path";
import { compactSystemContext } from "./context-catalogue.mjs";
import {
  BUILTIN_TTSR_RULES,
  loadTtsrRules,
  scanForViolations,
  getRecentAssistantMessages,
  collectDedupedViolations,
  recordFiredViolations,
} from "./ttsr-rules.mjs";
// Prompt injection and the startup toast intentionally share cache provenance
// and freshness policy so they cannot present contradictory version pairs.
import { isGreetingCacheUsable, readGreetingCache, REFRESH_TTL_MS } from "./greeting.mjs";

// ---------------------------------------------------------------------------
// Token Cost Advisory
// ---------------------------------------------------------------------------
// Injects a synthetic message for interactive sessions when session context
// exceeds a token threshold, prompting the LLM to advise the user to run
// /compact. Fires at 300k tokens, then every 50k above that (350k, 400k, ...).
// Uses the last assistant message's token counts — which represent the full
// context sent to the model on that turn — so the number tracks real cost, not
// model capacity.
//
// Headless sessions and GPT-5.5+ models are excluded: headless workers should
// not spend output budget on user-facing cost advice, and GPT-5.5+ models are
// registered with a 500k context limit so OpenCode auto-compacts around 400k.

const TOKEN_ADVISORY_INITIAL = 300_000;
const TOKEN_ADVISORY_INTERVAL = 50_000;

/**
 * Compute token total from an assistant message's token counts.
 * @param {object} tokens - { input, output, reasoning, cache: { read, write } }
 * @returns {number}
 */
function getTokenTotal(tokens) {
  if (!tokens) return 0;
  return (tokens.input || 0) +
    (tokens.output || 0) +
    (tokens.reasoning || 0) +
    (tokens.cache?.read || 0) +
    (tokens.cache?.write || 0);
}

/**
 * Check whether the active model is GPT-5.5 or newer.
 * @param {object} input
 * @returns {boolean}
 */
function isGpt55OrNewer(input) {
  const modelID = String(input?.model?.modelID || input?.modelID || input?.model || "").toLowerCase();
  const match = modelID.match(/(?:^|[^a-z0-9])gpt-(\d+)(?:\.(\d+))?/);
  let result = false;

  if (match) {
    const major = Number.parseInt(match[1], 10);
    const minor = Number.parseInt(match[2] || "0", 10);
    result = major > 5 || (major === 5 && minor >= 5);
  }

  return result;
}

// ---------------------------------------------------------------------------
// TTSR state
// ---------------------------------------------------------------------------

/**
 * Create per-session TTSR state.
 * @param {string} ttsrRulesPath
 * @param {(path: string) => string} readIfExists
 * @returns {object}
 */
function createTtsrState(ttsrRulesPath, readIfExists) {
  return {
    ttsrRulesPath,
    readIfExists,
    /** @type {Array<object> | null} */
    ttsrRules: null,
    /** @type {Map<string, Set<string>>} */
    ttsrFiredState: new Map(),
    /** @type {Map<string, number>} Maps sessionID → highest threshold warned about. */
    tokenAdvisoryState: new Map(),
  };
}

// ---------------------------------------------------------------------------
// Token advisory helpers
// ---------------------------------------------------------------------------

/**
 * Prune old session entries from the advisory state map.
 * @param {Map<string, number>} tokenAdvisoryState
 */
function pruneAdvisoryState(tokenAdvisoryState) {
  if (tokenAdvisoryState.size <= 500) return;
  const keys = Array.from(tokenAdvisoryState.keys());
  for (const k of keys.slice(0, 250)) tokenAdvisoryState.delete(k);
}

/**
 * Check whether the token cost advisory should fire for this message set.
 * @param {Array<object>} messages
 * @param {Map<string, number>} tokenAdvisoryState
 * @param {object} input
 * @param {() => boolean} isHeadless
 * @returns {{ sessionID: string, totalK: number, total: number } | null}
 */
function checkTokenAdvisory(messages, tokenAdvisoryState, input, isHeadless) {
  let result = null;

  if (!isHeadless() && !isGpt55OrNewer(input)) {
    for (let i = messages.length - 1; i >= 0; i--) {
      const info = messages[i].info;
      if (info?.role !== "assistant" || !info.tokens) continue;

      const total = getTokenTotal(info.tokens);
      if (total >= TOKEN_ADVISORY_INITIAL) {
        const sessionID = info.sessionID || "";
        const lastWarned = tokenAdvisoryState.get(sessionID) || 0;
        const stepsAboveInitial = Math.floor((total - TOKEN_ADVISORY_INITIAL) / TOKEN_ADVISORY_INTERVAL);
        const currentThreshold = TOKEN_ADVISORY_INITIAL + stepsAboveInitial * TOKEN_ADVISORY_INTERVAL;

        if (currentThreshold > lastWarned) {
          tokenAdvisoryState.set(sessionID, currentThreshold);
          pruneAdvisoryState(tokenAdvisoryState);
          result = { sessionID, totalK: Math.round(total / 1000), total };
        }
      }

      break;
    }
  }

  return result;
}

/**
 * Build the synthetic advisory message injected into the message stream.
 * @param {{ sessionID: string, totalK: number }} advisory
 * @returns {object}
 */
function buildTokenAdvisoryMessage(advisory) {
  const advisoryId = `token-advisory-${Date.now()}`;
  const text = [
    `[TOKEN COST ADVISORY] This session has reached approximately ${advisory.totalK}k tokens.`,
    "",
    "Briefly inform the user in your next response:",
    `The token cost of this session is rising with each interaction \u2014 currently at ~${advisory.totalK}k tokens. ` +
      "You can use the /compact command to significantly reduce ongoing costs. " +
      "Compaction preserves full understanding of what we\u2019re working on, so nothing is lost.",
    "",
    "Deliver this as a short note at the start of your response, then continue normally.",
    "Do not repeat this advisory if you have already mentioned it.",
  ].join("\n");

  return {
    info: { id: advisoryId, sessionID: advisory.sessionID, role: "user", time: { created: Date.now() }, parentID: "" },
    parts: [{
      id: `${advisoryId}-part`,
      sessionID: advisory.sessionID,
      messageID: advisoryId,
      type: "text",
      text,
      synthetic: true,
    }],
  };
}

// ---------------------------------------------------------------------------
// Correction message builder (called only from ttsrMessagesTransform)
// ---------------------------------------------------------------------------

function buildCorrectionMessage(violations, sessionID) {
  const corrections = violations.map((v) => {
    const severity = v.rule.severity === "error" ? "ERROR" : "WARNING";
    return `[${severity}] ${v.rule.id}: ${v.rule.correction}`;
  });
  const correctionText = [
    "[aidevops TTSR] Rule violations detected in recent output:",
    ...corrections, "",
    "Apply these corrections in your next response.",
  ].join("\n");
  const correctionId = `ttsr-correction-${Date.now()}`;
  return {
    info: { id: correctionId, sessionID, role: "user", time: { created: Date.now() }, parentID: "" },
    parts: [{ id: `${correctionId}-part`, sessionID, messageID: correctionId, type: "text", text: correctionText, synthetic: true }],
  };
}

// ---------------------------------------------------------------------------
// Hook implementations (module-level, accept state + deps as parameters)
// ---------------------------------------------------------------------------

export function buildSessionStartGreetingInstruction(agentsDir, readIfExists, options = {}) {
  const now = options.now ?? Date.now;
  const readCache = options.readGreetingCache ?? readGreetingCache;
  const refreshTtlMs = options.refreshTtlMs ?? REFRESH_TTL_MS;
  const initializedAtMs = options.initializedAtMs ?? Number.NEGATIVE_INFINITY;
  const cachePath = join(agentsDir, "..", "cache", "session-greeting-opencode.txt");
  const cached = readCache(cachePath);
  const cacheLines = isGreetingCacheUsable(cached, now(), refreshTtlMs, initializedAtMs)
    ? cached.output.split("\n").map((line) => line.trim()).filter(Boolean)
    : [];
  const cacheLine = cacheLines[0] || "";
  const cacheMatch = cacheLine.match(/^aidevops v(\S+) running in (.+?) v(\S+)(?:\s|$)/);
  const deployedVersion = (readIfExists(join(agentsDir, "VERSION")) ?? "").trim().split("\n")[0];
  const version = deployedVersion || cacheMatch?.[1] || "X";
  const cacheMatchesDeployedVersion = !deployedVersion || cacheMatch?.[1] === deployedVersion;
  const runtime = cacheMatch?.[2] || "OpenCode";
  const runtimeVersion = cacheMatchesDeployedVersion ? cacheMatch?.[3] : undefined;
  const versionLine = runtimeVersion
    ? `We're running aidevops v${version} in ${runtime} v${runtimeVersion}.`
    : `We're running aidevops v${version}.`;

  return [
    "## Session-start greeting order",
    "This plugin-injected block is the authoritative greeting instruction. The version values are already resolved; do not read the greeting cache or VERSION before responding.",
    "On the first assistant turn of an interactive session, the first visible text in the assistant response MUST be this exact aidevops greeting:",
    "",
    "Hi!",
    "",
    versionLine,
    "",
    "What would you like to work on?",
    "",
    "This greeting constrains the first visible assistant text, not the first assistant action. Tool calls may precede it when needed to start an initial task, especially when the runtime cannot interleave visible text and tool calls.",
    "Do not include startup status or advisory messages in chat; those are already shown by the OpenCode toast/sidebar surfaces.",
    "If the user launched the session with an initial message, the greeting is only a required prefix: immediately execute or fully answer that message in the SAME assistant turn.",
    "A task request already authorises task work. Never emit a greeting-only response or stop after acknowledging, restating, promising, or asking the user to say continue. Call the appropriate tools immediately, before visible text if necessary, unless genuinely blocked.",
    "Do not claim that tool access is unavailable without first attempting an appropriate configured tool and reporting concrete failure evidence.",
    "If the initial user message is only a greeting/salutation, do not add any additional salutations, greetings, introductory questions, or equivalent help prompts after the exact greeting above.",
    "Do not repeat the greeting after the first assistant turn, and do not duplicate the framework-status toast/sidebar content.",
  ].join("\n");
}

/**
 * Allow the greeting instruction exactly once for each interactive root
 * session. Child sessions are subagents/subtasks and must never inherit a
 * startup greeting; otherwise a late child request can reproduce the greeting
 * immediately before the parent session's summary.
 */
export function createSessionStartGreetingGate(client, isHeadless = () => false) {
  const attemptedSessions = new Set();

  if (typeof client?.session?.get !== "function") {
    return async () => false;
  }

  return async function shouldInjectSessionStartGreeting(input) {
    if (isHeadless()) return false;

    const sessionID = input?.sessionID;
    if (!sessionID || attemptedSessions.has(sessionID)) return false;
    // Claim the one startup opportunity before the asynchronous lookup. A
    // metadata failure must not allow a later turn to inject a stale greeting.
    attemptedSessions.add(sessionID);

    try {
      const response = await client.session.get({ path: { id: sessionID } });
      const session = response?.data ?? response ?? {};
      return !session.parentID;
    } catch {
      return false;
    }
  };
}

/**
 * system.transform hook: prepend session-start greeting order, identity prefix,
 * and quality rules.
 */
async function ttsrSystemTransform(input, output, context) {
  const { state, intentField, shouldInjectGreeting, agentsDir, readIfExists, greetingOptions } = context;
  output.system = compactSystemContext(output.system);
  if (input.model?.providerID === "anthropic") {
    const prefix = "You are Claude Code, Anthropic's official CLI for Claude.";
    output.system.unshift(prefix);
    if (output.system[1]) output.system[1] = prefix + "\n\n" + output.system[1];
  }

  const greeting = await shouldInjectGreeting(input)
    ? buildSessionStartGreetingInstruction(agentsDir, readIfExists, greetingOptions)
    : null;
  // Preserve the Anthropic compatibility prefix contract. Other providers keep
  // all durable guidance ahead of the one-shot greeting for stable prefix reuse.
  if (greeting && input.model?.providerID === "anthropic") output.system.unshift(greeting);

  const rules = loadTtsrRules(state);
  const ruleLines = rules.filter((r) => r.systemPrompt).map((r) => `- ${r.systemPrompt}`);

  const intentInstruction = [
    "## Intent Tracing (observability)",
    `When calling any tool, include a field named \`${intentField}\` in the tool arguments.`,
    "Value: one sentence in present participle form describing your intent (e.g., \"Reading the file to understand the existing schema\").",
    "No trailing period. This field is used for debugging and audit trails — it is stripped before tool execution.",
  ].join("\n");

  output.system.push(intentInstruction);
  if (ruleLines.length > 0) output.system.push([
    "## aidevops Quality Rules (enforced)",
    "The following rules are actively enforced. Violations will be flagged.",
    ...ruleLines,
  ].join("\n"));
  if (greeting && input.model?.providerID !== "anthropic") output.system.push(greeting);
}

/**
 * messages.transform hook: inject token advisory and TTSR violation corrections.
 */
async function ttsrMessagesTransform(input, output, state, qualityLog, isHeadless) {
  if (!output.messages || output.messages.length === 0) return;

  const advisory = checkTokenAdvisory(output.messages, state.tokenAdvisoryState, input, isHeadless);
  if (advisory) {
    output.messages.push(buildTokenAdvisoryMessage(advisory));
    qualityLog("INFO", `Token advisory: session ${advisory.sessionID} at ~${advisory.totalK}k tokens`);
  }

  const assistantMessages = getRecentAssistantMessages(output.messages, 3);
  if (assistantMessages.length === 0) return;

  const allViolations = collectDedupedViolations(assistantMessages, state);
  if (allViolations.length === 0) return;

  recordFiredViolations(allViolations, state.ttsrFiredState);

  const sessionID = output.messages[0]?.info?.sessionID || "";
  output.messages.push(buildCorrectionMessage(allViolations, sessionID));

  qualityLog(
    "INFO",
    `TTSR messages.transform: injected ${allViolations.length} correction(s): ${allViolations.map((v) => v.rule.id).join(", ")}`,
  );
}

/**
 * Record TTSR violations to the pattern tracker script if available.
 * @param {Array<{ rule: object }>} violations
 * @param {{ scriptsDir: string, run: Function }} execDeps
 */
function recordViolationsToTracker(violations, execDeps) {
  const patternTracker = join(execDeps.scriptsDir, "pattern-tracker-helper.sh");
  if (!existsSync(patternTracker)) return;
  const ruleIds = violations.map((v) => v.rule.id).join(",");
  execDeps.run(
    `bash "${patternTracker}" record "TTSR_VIOLATION" "rules: ${ruleIds}" --tag "ttsr" 2>/dev/null`,
    5000,
  );
}

/**
 * text.complete hook: scan output text and append TTSR violation markers.
 * @param {object} input
 * @param {object} output
 * @param {object} state
 * @param {{ scriptsDir: string, run: Function }} execDeps
 * @param {(level: string, message: string) => void} qualityLog
 */
async function ttsrTextComplete(input, output, state, execDeps, qualityLog) {
  if (!output.text) return;

  const violations = scanForViolations(output.text, state);
  if (violations.length === 0) return;

  for (const v of violations) {
    qualityLog(
      v.rule.severity === "error" ? "ERROR" : "WARN",
      `TTSR violation [${v.rule.id}]: ${v.rule.description} (session: ${input.sessionID}, message: ${input.messageID})`,
    );
  }

  const markers = violations.map((v) => {
    const severity = v.rule.severity === "error" ? "ERROR" : "WARN";
    return `<!-- TTSR:${severity}:${v.rule.id} — ${v.rule.correction} -->`;
  });

  output.text = output.text + "\n" + markers.join("\n");
  recordViolationsToTracker(violations, execDeps);
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/**
 * Build TTSR hook functions with injected dependencies from index.mjs.
 * @param {object} deps
 * @param {string} deps.agentsDir
 * @param {string} deps.scriptsDir
 * @param {(path: string) => string} deps.readIfExists
 * @param {(level: string, message: string) => void} deps.qualityLog
 * @param {(cmd: string, timeout?: number) => string} deps.run
 * @param {string} deps.intentField
 * @param {(path: string) => { output: string, mtimeMs: number } | null} [deps.readGreetingCache]
 * @param {() => number} [deps.now]
 * @param {number} [deps.refreshTtlMs]
 * @param {number} [deps.initializedAtMs]
 * @returns {{ loadTtsrRules: Function, systemTransformHook: Function, messagesTransformHook: Function, textCompleteHook: Function }}
 */
export function createTtsrHooks(deps) {
  const { agentsDir, scriptsDir, readIfExists, qualityLog, run, intentField } = deps;
  const isHeadless = deps.isHeadless || (() => false);
  const shouldInjectGreeting = deps.shouldInjectGreeting || (async () => !isHeadless());
  const ttsrRulesPath = join(agentsDir, "configs", "ttsr-rules.json");
  const state = createTtsrState(ttsrRulesPath, readIfExists);
  const execDeps = { scriptsDir, run };
  const greetingOptions = {
    readGreetingCache: deps.readGreetingCache,
    now: deps.now,
    refreshTtlMs: deps.refreshTtlMs,
    initializedAtMs: deps.initializedAtMs,
  };
  const systemTransformContext = { state, intentField, shouldInjectGreeting, agentsDir, readIfExists, greetingOptions };

  return {
    loadTtsrRules: () => loadTtsrRules(state),
    systemTransformHook: (input, output) => ttsrSystemTransform(input, output, systemTransformContext),
    messagesTransformHook: (_input, output) => ttsrMessagesTransform(_input, output, state, qualityLog, isHeadless),
    textCompleteHook: (input, output) => ttsrTextComplete(input, output, state, execDeps, qualityLog),
  };
}

// Re-export BUILTIN_TTSR_RULES for callers that access it directly.
export { BUILTIN_TTSR_RULES };
