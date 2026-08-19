/**
 * TTSR rule definitions, loading, violation scanning, and message processing helpers.
 * Extracted from ttsr.mjs to keep that file's complexity below the threshold.
 */

// ---------------------------------------------------------------------------
// Built-in TTSR rules
// ---------------------------------------------------------------------------

/**
 * Built-in TTSR rules — enforced by default.
 * @type {Array<{id: string, description: string, pattern: string, correction: string, severity: string, systemPrompt: string}>}
 */
export const BUILTIN_TTSR_RULES = [
  {
    id: "no-glob-for-discovery",
    description: "Use git ls-files or fd instead of Glob/find for file discovery",
    pattern: "(?:mcp_glob|Glob tool|use.*\\bGlob\\b.*to find|I'll use Glob)",
    correction: "Use `git ls-files` or `fd` for file discovery, not Glob. Glob is a last resort when Bash is unavailable.",
    severity: "warn",
    systemPrompt: "File discovery: use `git ls-files '<pattern>'` for git-tracked files, `fd` for untracked. NEVER use Glob/find as primary discovery.",
  },
  {
    id: "no-cat-for-reading",
    description: "Use Read tool instead of cat/head/tail for file reading",
    pattern: "(?:^|\\s)cat\\s+['\"]?[/~\\w]|\\bhead\\s+-n|\\btail\\s+-n",
    correction: "Use the Read tool for file reading, not cat/head/tail. These are Bash commands that waste context.",
    severity: "info",
    systemPrompt: "Use the Read tool for file reading. Avoid cat/head/tail in Bash — they waste context tokens.",
  },
  {
    id: "read-before-edit",
    description: "Always Read a file before Edit or Write to existing files",
    // Text-only detection cannot know whether a Read tool call already happened,
    // so keep this as a system-prompt rule and leave enforcement to tool hooks.
    pattern: "(?!)",
    correction: "ALWAYS Read a file before Edit/Write to an existing file. These tools fail without a prior Read in this conversation. (This rule does not apply when creating new files.)",
    severity: "error",
    systemPrompt: "ALWAYS Read a file before Edit or Write to an existing file. These tools FAIL without a prior Read in this conversation. For NEW files, verify the parent directory exists instead.",
  },
  {
    id: "no-credentials-in-output",
    description: "Never expose credentials, API keys, or secrets in output",
    pattern: "(?:api[_-]?key|secret|password|token)\\s*[:=]\\s*['\"][A-Za-z0-9+/=_-]{16,}['\"]",
    correction: "SECURITY: Never expose credentials in output. Use `aidevops secret set NAME` for secure storage.",
    severity: "error",
    systemPrompt: "NEVER expose credentials, API keys, or secrets in output or logs.",
  },
  {
    id: "pre-edit-check",
    description: "Run pre-edit-check.sh before modifying files",
    pattern: "(?:I'll (?:create|modify|edit|write)|Let me (?:create|modify|edit|write)).*(?:on main|on master)\\b",
    correction: "Run pre-edit-check.sh before modifying files. NEVER edit on main/master branch.",
    severity: "error",
    systemPrompt: "Before ANY file modification: run pre-edit-check.sh. NEVER edit on main/master.",
  },
  {
    id: "mission-first-verification",
    description: "Prevent unapproved test-infrastructure scope drift",
    pattern: "\\b(?:I'll|I will|I'm going to|Let me|Let's|Let us|We should|I plan to)\\s+(?:create|add|build|set up|implement|expand|write|introduce)\\s+(?:(?:a|an|the)\\s+)?(?:new\\s+)?(?:(?:(?:unit|integration|regression|e2e|end-to-end)\\s+)?tests?\\b|test(?:ing)?\\s+(?:harness|framework|runner|infrastructure|suite)|(?:mock|fixture)s?(?:\\s+(?:server|system|framework|layer|data))?\\b|coverage\\s+(?:gate|threshold|tool|requirement)|CI\\s+test\\s+gate|test-only\\s+(?:interface|endpoint|path|hook))",
    correction: "New test infrastructure is permission-gated. Proceed only when the user explicitly requested or approved it; otherwise use production-facing paths, standard logs, and existing framework/test systems.",
    severity: "warn",
    systemPrompt: "Prioritise time-to-functional. Run existing required checks, but never add/expand tests by default. Add focused coverage only when explicitly requested, specifically required by acceptance/repository policy, or the lowest-cost way to resolve material uncertainty; prefer production paths/logs and ask before new runners, harnesses, mocks/fixtures, coverage or CI test gates, or test-only interfaces.",
  },
  {
    id: "shell-explicit-returns",
    description: "Shell functions must have explicit return statements",
    pattern: "(?:function\\s+\\w+|\\w+\\s*\\(\\)\\s*\\{)(?:(?!return\\s+[0-9]).){50,}\\}",
    correction: "Shell functions must have explicit `return 0` or `return 1` statements (SonarCloud S7682).",
    severity: "warn",
    systemPrompt: "Shell scripts: every function must have an explicit `return 0` or `return 1`.",
  },
  {
    id: "shell-local-params",
    description: "Use local var=\"$1\" pattern in shell functions",
    pattern: "^\\s+(?:echo|printf|return|if|\\[\\[).*(?<!\\\\)\\$[1-9](?![0-9.,])(?!\\/(?:mo(?:nth)?|yr|year|day|week|hr|hour)\\b)(?!\\s+(?:per|mo(?:nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)\\b)(?!.*local\\s+\\w+=)",
    correction: "Use `local var=\"$1\"` pattern — never use positional parameters directly (SonarCloud S7679).",
    severity: "warn",
    systemPrompt: "Shell scripts: use `local var=\"$1\"` — never use $1 directly in function bodies.",
  },
];

// ---------------------------------------------------------------------------
// TTSR rule loading
// ---------------------------------------------------------------------------

/**
 * Merge user-supplied TTSR rules into the rules array (update existing, append new).
 * @param {Array<object>} rules
 * @param {Array<object>} userRules
 */
export function mergeUserTtsrRules(rules, userRules) {
  for (const rule of userRules) {
    if (!rule.id || !rule.pattern) continue;
    const existingIdx = rules.findIndex((r) => r.id === rule.id);
    if (existingIdx >= 0) {
      rules[existingIdx] = { ...rules[existingIdx], ...rule };
    } else {
      rules.push(rule);
    }
  }
}

/**
 * Load (and cache) TTSR rules from state, merging user overrides if present.
 * @param {{ ttsrRules: Array|null, ttsrRulesPath: string, readIfExists: Function }} state
 * @returns {Array<object>}
 */
export function loadTtsrRules(state) {
  if (state.ttsrRules !== null) return state.ttsrRules;
  state.ttsrRules = [...BUILTIN_TTSR_RULES];
  const userContent = state.readIfExists(state.ttsrRulesPath);
  if (userContent) {
    try {
      const parsed = JSON.parse(userContent);
      if (Array.isArray(parsed)) mergeUserTtsrRules(state.ttsrRules, parsed);
    } catch {
      console.error("[aidevops] Failed to parse TTSR rules file — using built-in rules only");
    }
  }
  return state.ttsrRules;
}

// ---------------------------------------------------------------------------
// Rule violation scanning
// ---------------------------------------------------------------------------

/**
 * Test a single rule's pattern against a text string.
 * @param {string} text
 * @param {{ pattern: string }} rule
 * @returns {{ matched: boolean, matches: string[] }}
 */
export function checkRule(text, rule) {
  try {
    const regex = new RegExp(rule.pattern, "gim");
    const matches = [];
    let match;
    while ((match = regex.exec(text)) !== null) {
      matches.push(match[0].substring(0, 120));
      if (matches.length >= 3) break;
    }
    return { matched: matches.length > 0, matches };
  } catch {
    return { matched: false, matches: [] };
  }
}

/**
 * Scan a text string for all rule violations.
 * @param {string} text
 * @param {object} state
 * @returns {Array<{ rule: object, matches: string[] }>}
 */
export function scanForViolations(text, state) {
  const rules = loadTtsrRules(state);
  const violations = [];
  for (const rule of rules) {
    const result = checkRule(text, rule);
    if (result.matched) violations.push({ rule, matches: result.matches });
  }
  return violations;
}

// ---------------------------------------------------------------------------
// Message processing helpers
// ---------------------------------------------------------------------------

/**
 * Extract plain text from a message's parts array.
 * @param {Array<object>} parts
 * @param {{ excludeToolOutput?: boolean }} [options]
 * @returns {string}
 */
export function extractTextFromParts(parts, options = {}) {
  if (!Array.isArray(parts)) return "";
  return parts
    .filter((p) => {
      if (!p || typeof p.text !== "string") return false;
      if (p.type !== "text") return false;
      if (options.excludeToolOutput && (p.toolCallId || p.toolInvocationId)) return false;
      return true;
    })
    .map((p) => p.text)
    .join("\n");
}

/**
 * Get the most recent N assistant messages, excluding synthetic correction messages.
 * @param {Array<object>} messages
 * @param {number} windowSize
 * @returns {Array<object>}
 */
export function getRecentAssistantMessages(messages, windowSize) {
  return messages
    .filter((m) => {
      if (!m.info || m.info.role !== "assistant") return false;
      if (m.info.id && m.info.id.startsWith("ttsr-correction-")) return false;
      return true;
    })
    .slice(-windowSize);
}

/**
 * Collect deduped violations from recent assistant messages.
 * @param {Array<object>} assistantMessages
 * @param {object} state
 * @returns {Array<{ rule: object, matches: string[], msgId: string }>}
 */
export function collectDedupedViolations(assistantMessages, state) {
  const allViolations = [];
  for (const msg of assistantMessages) {
    const msgId = msg.info?.id || "";
    const text = extractTextFromParts(msg.parts, { excludeToolOutput: true });
    if (!text) continue;
    const violations = scanForViolations(text, state);
    for (const v of violations) {
      const firedOn = state.ttsrFiredState.get(v.rule.id);
      if (firedOn && firedOn.has(msgId)) continue;
      if (!allViolations.some((av) => av.rule.id === v.rule.id)) {
        allViolations.push({ ...v, msgId });
      }
    }
  }
  return allViolations;
}

/**
 * Record which violations fired so they are not re-injected.
 * @param {Array<{ rule: object, msgId: string }>} violations
 * @param {Map<string, Set<string>>} ttsrFiredState
 */
export function recordFiredViolations(violations, ttsrFiredState) {
  for (const v of violations) {
    if (!ttsrFiredState.has(v.rule.id)) ttsrFiredState.set(v.rule.id, new Set());
    ttsrFiredState.get(v.rule.id).add(v.msgId);
  }
}

// buildCorrectionMessage is defined in ttsr.mjs (only called there).
