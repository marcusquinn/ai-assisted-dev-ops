import { existsSync, readdirSync } from "fs";
import { join } from "path";

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
 * Try to register a .md file entry as a discovered agent.
 * @param {object} entry - Dirent object
 * @param {string} folderDesc - Description fallback
 * @param {Array} agents - Mutable agents array
 * @param {Set} seen - Dedup set
 */
function tryRegisterMdAgent(entry, folderDesc, agents, seen) {
  if (!entry.isFile() || !entry.name.endsWith(".md")) return;
  const name = entry.name.replace(/\.md$/, "");
  if (SKIP_NAMES.has(name) || name.endsWith("-skill")) return;
  if (seen.has(name)) return;
  seen.add(name);
  agents.push({ name, description: `aidevops subagent: ${folderDesc}` });
}

/**
 * Recursively collect .md filenames from a directory tree.
 * Only calls readdirSync (directory listing) — never reads file contents.
 * @param {string} dirPath
 * @param {string} folderDesc - used as description fallback
 * @param {Array} agents
 * @param {Set} seen - dedup set
 */
function scanDirNames(dirPath, folderDesc, agents, seen) {
  let entries;
  try {
    entries = readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (SKIP_NAMES.has(entry.name)) continue;
      scanDirNames(join(dirPath, entry.name), folderDesc, agents, seen);
    } else {
      tryRegisterMdAgent(entry, folderDesc, agents, seen);
    }
  }
}

/**
 * Fallback: discover agents from directory names only (no file reads).
 * Lists .md filenames in known subdirectories — O(n) readdirSync calls
 * where n = number of subdirectories (~11), NOT number of files.
 * Each readdirSync returns filenames without reading file contents.
 * @param {string} agentsDir
 * @returns {Array<{name: string, description: string}>}
 */
function loadAgentsFallback(agentsDir) {
  if (!existsSync(agentsDir)) return [];

  const subdirs = [
    "aidevops",
    "content",
    "seo",
    "tools",
    "services",
    "workflows",
    "memory",
    "custom",
    "draft",
  ];

  const agents = [];
  const seen = new Set();

  for (const subdir of subdirs) {
    scanDirNames(join(agentsDir, subdir), subdir, agents, seen);
  }

  return agents;
}

/**
 * Parse subagent-index.toon and return leaf agent names with descriptions.
 * Reads ONE file instead of 500+. Returns entries like:
 *   { name: "dataforseo", description: "Search optimization - keywords..." }
 * @param {string} agentsDir
 * @param {(filepath: string) => string} readIfExists
 * @returns {Array<{name: string, description: string}>}
 */
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
  if (!content) return loadAgentsFallback(agentsDir);

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

  // If no top-level block found, fall back to minimal subagent set
  if (agents.length === 0) {
    const subagentMatch = content.match(
      /<!--TOON:subagents\[\d+\]\{[^}]+\}:\n([\s\S]*?)-->/,
    );
    if (!subagentMatch) return loadAgentsFallback(agentsDir);
    return parseToonSubagentBlock(subagentMatch[1]);
  }

  return agents;
}

