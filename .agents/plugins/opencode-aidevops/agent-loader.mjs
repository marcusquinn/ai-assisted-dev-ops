import { readFileSync, realpathSync } from "fs";
import { createHash } from "node:crypto";
import { join } from "path";
import { primaryDeliveryEvidence } from "./primary-delivery-evidence.mjs";

// Re-export MCP tool permissions (extracted to reduce file complexity)
export { applyToolPatternsToAgent, applyAgentMcpTools } from "./agent-mcp-tools.mjs";

/** Names to skip when discovering agents. */
const SKIP_NAMES = new Set([
  "README",
  "AGENTS",
  "SKILL",
  "SKILL-SCAN-RESULTS",
  "node_modules",
  "references",
  "loop-state",
]);

/**
 * Collect leaf agent names from a pipe-separated key_files string.
 * @param {string} keyFiles - e.g. "dataforseo|serper|semrush"
 * @param {string} purpose - Description for the agent entry
 * @param {Array} agents - Mutable agents array
 * @param {Set} seen - Dedup set
 */
export function collectLeafAgents(keyFiles, purpose, agents, seen) {
  for (const leaf of keyFiles.split("|")) {
    const name = leaf.trim();
    if (!name || SKIP_NAMES.has(name) || name.endsWith("-skill")) continue;
    if (seen.has(name)) continue;
    seen.add(name);
    agents.push({ name, description: purpose });
  }
}

/**
 * Parse a TOON subagents block into agent entries.
 * Each line: folder,purpose,keyfile1|keyfile2|...
 * @param {string} blockText - Raw text from the TOON block
 * @returns {Array<{name: string, description: string, modelTier?: string}>}
 */
export function parseToonSubagentBlock(blockText) {
  const agents = [];
  const seen = new Set();

  for (const line of blockText.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const parts = trimmed.split(",");
    if (parts.length < 3) continue;

    const folder = parts[0] || "";
    if (folder.includes("references/") || folder.includes("loop-state/")) continue;

    collectLeafAgents(parts.slice(2).join(","), parts[1] || "", agents, seen);
  }

  return agents;
}

/**
 * Parse top-level agents from a TOON block and append to agents array.
 * Format: name,file,purpose,model_tier — one per line
 * @param {string} blockText
 * @param {Array} agents - Mutable agents array
 */
function parseTopLevelAgents(blockText, agents) {
  const seen = new Set(agents.map((a) => a.name));
  for (const line of blockText.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const parts = trimmed.split(",");
    if (parts.length < 3) continue;
    const name = parts[0].trim();
    const purpose = parts[2].trim();
    if (name && !seen.has(name)) {
      seen.add(name);
      const modelTier = parts[3]?.trim() || "standard";
      agents.push({ name, description: purpose, modelTier });
    }
  }
}

export function loadAgentIndex(agentsDir, readIfExists) {
  const indexPath = join(agentsDir, "subagent-index.toon");
  const content = readIfExists(indexPath);
  if (!content) return [];

  // Only register top-level agents (agent picker entries), not leaf
  // subagents. OpenCode 1.4.8 evaluates permissions per-agent at startup;
  // 900+ agents causes multi-minute hangs. Subagent routing is handled
  // internally by the primary agent via the Task tool — no need to register
  // every leaf file as a selectable agent.
  const agents = [];

  const topLevelMatch = content.match(
    /<!--TOON:agents\[\d+\]\{[^}]+\}:\n([\s\S]*?)-->/,
  );
  if (topLevelMatch) {
    parseTopLevelAgents(topLevelMatch[1], agents);
  }

  // Missing/legacy indexes never widen registration to every leaf. Native
  // primary profiles and the explicit built-in/MCP fallback remain available.
  return agents;
}

/** Two inference-only execution roles, not another domain/leaf registry. */
export function registerDelegatedDomainProfiles(config, agentsDir, state) {
  if (!state) return 0;
  config.agent ||= {};
  const previous = state.domainDelegation?.profiles || new Map();
  const profiles = new Map();
  const sources = new Map(primaryDeliveryEvidence(config, agentsDir).sources
    .filter((entry) => entry.delivery === "delivered")
    .map((entry) => [entry.source, entry.sha256]));
  let injected = 0;
  for (const name of ["domain-focused", "domain-light"]) {
    if (config.agent[name] && config.agent[name] !== previous.get(name)) continue;
    if (!config.agent[name]) injected++;
    const profile = {
      description: `${name}: canonical domain advisory inference; requires a JSON child envelope (reference/agent-routing.md)`,
      mode: "subagent",
      prompt: [
        "Use only the supplied canonical domain knowledge and task evidence for independent advisory work.",
        "The child envelope bounds the objective, scope, essential decisions, evidence contract and effort.",
        "Domain instructions describe expertise, not grants of tools, authority, spending or recursion.",
        "Never invoke tools, delegate, publish, or claim to have read sources not supplied by the parent.",
        "Return task identity, findings, supplied evidence citations, uncertainty, exclusions and next action.",
        "Missing knowledge or capabilities means unavailable; cancellation means cancelled, never success.",
        "The parent owns synthesis, verification, cancellation and all external resource cleanup.",
      ].join("\n"),
      tools: { "*": false },
      permission: { "*": "deny" },
    };
    config.agent[name] = profile;
    profiles.set(name, profile);
    state.tiers?.delete(name);
    state.pinned?.delete(name);
  }
  state.domainDelegation = { agentsDir, sources, profiles };
  return injected;
}

/** Load one verified primary, never follow leaf pointers or repository paths. */
export function loadDelegatedDomainKnowledge(registry, source, light = false) {
  const expected = registry?.sources?.get(source);
  if (!expected || !/^[a-z0-9-]+\.md$/.test(source)) {
    throw new Error("[aidevops] Domain source unavailable or unverified");
  }
  const root = realpathSync(registry.agentsDir);
  const path = join(root, source);
  if (realpathSync(path) !== path) throw new Error("[aidevops] Domain source must be canonical");
  const text = readFileSync(path, "utf8").trim();
  if (createHash("sha256").update(text).digest("hex") !== expected) {
    throw new Error("[aidevops] Domain source changed; reload profiles before delegation");
  }
  const body = text.replace(/^---\n[\s\S]*?\n---\n?/, "").trim();
  const knowledge = light
    ? body.match(/<!-- AI-CONTEXT-START -->([\s\S]*?)<!-- AI-CONTEXT-END -->/)?.[1]?.trim()
    : body;
  if (!knowledge) throw new Error("[aidevops] Required domain knowledge unavailable");
  return { source, sha256: expected, knowledge };
}
