// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Agent index registration and fail-closed research-only profile construction.

import { existsSync, readFileSync, realpathSync } from "fs";
import { homedir } from "os";
import { isAbsolute, join, relative, resolve, sep } from "path";
import { loadAgentIndex } from "./agent-loader.mjs";
import { getOnDemandMcpAgents } from "./mcp-registry.mjs";
import { DEFAULT_ESCALATION_ORDER, normalizeRoutingTier } from "./model-routing.mjs";

const ROUTING_TIER_METADATA = "aidevops_model_tier";

function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return "";
}

export function applyAgentRoutingProfile(profile, tier, routing) {
  if (!profile || !routing) return false;
  const explicitModel = String(profile.model || "");
  if (explicitModel.includes("/")) return false;

  const authoredTier = [profile[ROUTING_TIER_METADATA], explicitModel, tier]
    .find((value) => DEFAULT_ESCALATION_ORDER.includes(String(value || "").trim().toLowerCase()));
  const routeTier = normalizeRoutingTier(authoredTier);
  if (!routing.tiers?.[routeTier]) return false;
  if (explicitModel) delete profile.model;
  delete profile[ROUTING_TIER_METADATA];
  return true;
}

export function registerAgentRoutingIntent(state, name, profile, tier, routing) {
  if (!state || !name || !profile) return false;
  const explicitModel = String(profile.model || "");
  if (explicitModel.includes("/")) {
    state.tiers.delete(name);
    state.pinned.add(name);
    delete profile[ROUTING_TIER_METADATA];
    return false;
  }

  const existingTier = state.tiers.get(name);
  const authoredTier = [profile[ROUTING_TIER_METADATA], explicitModel, existingTier, tier]
    .find((value) => DEFAULT_ESCALATION_ORDER.includes(String(value || "").trim().toLowerCase()));
  state.pinned.delete(name);
  state.tiers.set(name, normalizeRoutingTier(authoredTier));
  return applyAgentRoutingProfile(profile, authoredTier, routing);
}

function registerConfiguredRoutingIntents(config, routing, state) {
  Object.entries(config.agent || {}).forEach(([name, profile]) => {
    const model = String(profile?.model || "");
    const metadata = String(profile?.[ROUTING_TIER_METADATA] || "");
    if (
      model.includes("/")
      || DEFAULT_ESCALATION_ORDER.includes(model.toLowerCase())
      || DEFAULT_ESCALATION_ORDER.includes(metadata.toLowerCase())
    ) {
      registerAgentRoutingIntent(state, name, profile, metadata || model, routing);
    }
  });
}

function registerBuiltInRoutedAgents(config, routing, state) {
  const builtIns = [
    ["explore", "simple", "Fast repository exploration"],
    ["general", "standard", "General-purpose delegated work"],
  ];
  let injected = 0;
  builtIns.forEach(([name, tier, description]) => {
    if (!config.agent[name]) {
      config.agent[name] = { description, mode: "subagent" };
      injected++;
    }
    registerAgentRoutingIntent(state, name, config.agent[name], tier, routing);
  });
  return injected;
}

const MCP_ACTIVATION_TOOL = "aidevops_mcp";

function agentPromptFromSource(source) {
  const match = source.match(/^---\n[\s\S]*?\n---\n?([\s\S]*)$/);
  return match?.[1]?.trim() || "";
}

function onDemandMcpPrompt(mcp, agentsDir) {
  const source = readIfExists(join(agentsDir, ...mcp.agentSource));
  const parsed = source ? parseAgentFrontmatter(source) : null;
  const prompt = parsed?.prompt
    || agentPromptFromSource(source)
    || `Use the ${mcp.name} MCP for ${mcp.description}.`;
  return { parsed, prompt };
}

function createOnDemandMcpProfile(mcp, agentsDir) {
  const { parsed, prompt } = onDemandMcpPrompt(mcp, agentsDir);
  return {
    description: parsed?.profile.description || mcp.description,
    mode: "subagent",
    prompt: [
      `Before the first ${mcp.name} operation, call ${MCP_ACTIVATION_TOOL} with action \"connect\" and name \"${mcp.name}\".`,
      `After it succeeds, continue on the next step with ${mcp.toolPattern} tools.`,
      `When the requested ${mcp.name} work is complete, call ${MCP_ACTIVATION_TOOL} with action \"disconnect\".`,
      ...(mcp.activationGuidance || []),
      "",
      prompt,
    ].join("\n"),
    tools: {
      ...(parsed?.profile.tools || {}),
      [MCP_ACTIVATION_TOOL]: true,
      [mcp.toolPattern]: true,
    },
    permission: {
      ...parsed?.profile.permission,
      [MCP_ACTIVATION_TOOL]: "allow",
      [mcp.toolPattern]: "allow",
    },
  };
}

function ensureOnDemandMcpAgent(config, mcp, agentsDir) {
  if (!config.agent[mcp.agentName]) {
    config.agent[mcp.agentName] = createOnDemandMcpProfile(mcp, agentsDir);
    return true;
  }

  if (!config.agent[mcp.agentName].tools) config.agent[mcp.agentName].tools = {};
  if (!(MCP_ACTIVATION_TOOL in config.agent[mcp.agentName].tools)) {
    config.agent[mcp.agentName].tools[MCP_ACTIVATION_TOOL] = true;
  }
  config.agent[mcp.agentName].tools[mcp.toolPattern] = true;
  if (!config.agent[mcp.agentName].permission) config.agent[mcp.agentName].permission = {};
  if (!(MCP_ACTIVATION_TOOL in config.agent[mcp.agentName].permission)) {
    config.agent[mcp.agentName].permission[MCP_ACTIVATION_TOOL] = "allow";
  }
  config.agent[mcp.agentName].permission[mcp.toolPattern] = "allow";
  return false;
}

/**
 * Register the small, explicit set of leaf agents that activate MCPs at
 * runtime. Never replace this allowlist with recursive leaf discovery.
 * @param {object} config
 * @param {string} agentsDir
 * @param {object} [routing]
 * @param {object} [state]
 * @returns {number}
 */
export function registerOnDemandMcpAgents(config, agentsDir, routing, state) {
  if (!config.agent) config.agent = {};
  if (!config.tools) config.tools = {};
  config.tools[MCP_ACTIVATION_TOOL] = false;

  let injected = 0;
  getOnDemandMcpAgents().forEach((mcp) => {
    if (ensureOnDemandMcpAgent(config, mcp, agentsDir)) injected++;
    if (routing && state) {
      registerAgentRoutingIntent(
        state,
        mcp.agentName,
        config.agent[mcp.agentName],
        mcp.modelTier,
        routing,
      );
    }
  });
  return injected;
}

export function registerAgents(config, agentsDir, routing, state) {
  registerConfiguredRoutingIntents(config, routing, state);
  const indexAgents = loadAgentIndex(agentsDir, readIfExists);
  let injected = 0;

  indexAgents.forEach((agent) => {
    if (!config.agent[agent.name]) {
      config.agent[agent.name] = {
        description: agent.description,
        mode: "subagent",
      };
      injected++;
    }
    registerAgentRoutingIntent(state, agent.name, config.agent[agent.name], agent.modelTier, routing);
  });
  return injected
    + registerOnDemandMcpAgents(config, agentsDir, routing, state)
    + registerBuiltInRoutedAgents(config, routing, state);
}

const RESEARCH_ONLY_AGENT_NAME = "research-only";
const AI_RESEARCH_TOOL_CEILING_ENV = "AIDEVOPS_AI_RESEARCH_TOOL_CEILING";
const RESEARCH_STAGING_DIRECTORY = "research-staging";
const RESEARCH_STAGING_DENIED_NAMES = [
  ".env", ".env.*", ".ssh", ".gnupg", ".aws", ".azure", ".kube",
  ".netrc", ".npmrc", ".pypirc", ".git-credentials", "auth.json", "credential*",
];
const UNSAFE_FRONTMATTER_KEYS = new Set(["__proto__", "constructor", "prototype"]);
const RESEARCH_ONLY_FALLBACK_PROMPT = `# Research-only subagent

Gather evidence from the assigned repository and read-only web sources. Return
findings, citations, uncertainty, and recommendations. Never modify local or
external state, invoke another agent, access credentials, or perform Git,
account, network-write, or worktree operations.`;

function parseFrontmatterScalar(value) {
  const booleans = { true: true, false: false };
  if (Object.hasOwn(booleans, value)) return booleans[value];
  return value.startsWith('"') ? JSON.parse(value) : value;
}

function parseFrontmatterEntry(line) {
  if (!line.trim() || line.trimStart().startsWith("#")) return null;
  const entry = line.match(/^( *)(?:"([^"]+)"|([A-Za-z0-9_.-]+)):\s*(.*)$/);
  if (!entry || entry[1].length % 2 !== 0) throw new Error("Invalid agent frontmatter entry");
  return entry;
}

function assignFrontmatterEntry(stack, entry) {
  const indent = entry[1].length;
  while (stack.at(-1).indent >= indent) stack.pop();
  if (indent > stack.at(-1).indent + 2) throw new Error("Invalid agent frontmatter indentation");

  const key = entry[2] || entry[3];
  const parent = stack.at(-1).value;
  if (UNSAFE_FRONTMATTER_KEYS.has(key) || Object.hasOwn(parent, key)) {
    throw new Error("Unsafe or duplicate agent frontmatter key");
  }
  parent[key] = entry[4] ? parseFrontmatterScalar(entry[4]) : {};
  if (!entry[4]) stack.push({ indent, value: parent[key] });
}

function parseAgentFrontmatter(source) {
  try {
    const match = source.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    if (!match) throw new Error("Agent frontmatter is missing");

    const profile = {};
    const stack = [{ indent: -1, value: profile }];
    match[1].split("\n")
      .map(parseFrontmatterEntry)
      .filter(Boolean)
      .forEach((entry) => assignFrontmatterEntry(stack, entry));
    return { profile, prompt: match[2].trim() };
  } catch {
    return null;
  }
}

function researchOnlyProfile(agentsDir) {
  const source = readIfExists(join(agentsDir, "tools", "ai-assistants", "research-only.md"));
  const parsed = source ? parseAgentFrontmatter(source) : null;
  if (!parsed || typeof parsed.profile.description !== "string") {
    return {
      description: "Research-only profile unavailable",
      mode: "subagent",
      disable: true,
      prompt: RESEARCH_ONLY_FALLBACK_PROMPT,
      tools: { "*": false },
      permission: { "*": "deny" },
    };
  }

  const profile = { ...parsed.profile };
  delete profile.name;
  return { ...profile, prompt: parsed.prompt || RESEARCH_ONLY_FALLBACK_PROMPT };
}

function isPathWithin(base, candidate) {
  const remainder = relative(base, candidate);
  return remainder === ""
    || (!isAbsolute(remainder) && remainder !== ".." && !remainder.startsWith(`..${sep}`));
}

function researchStagingDirectories(env) {
  const tempBase = resolve(
    env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp"),
  );
  const stagingRoot = join(tempBase, RESEARCH_STAGING_DIRECTORY);
  if (!existsSync(stagingRoot)) return [stagingRoot];

  try {
    const resolvedBase = realpathSync(tempBase);
    const resolvedRoot = realpathSync(stagingRoot);
    if (!isPathWithin(resolvedBase, resolvedRoot)) return [];
    return [...new Set([stagingRoot, resolvedRoot])];
  } catch {
    return [];
  }
}

function addResearchStagingPermissions(profile, env) {
  if (!profile.permission || typeof profile.permission !== "object") return;

  const rules = { "*": "deny" };
  researchStagingDirectories(env).forEach((directory) => {
    rules[directory] = "allow";
    rules[`${directory}/**`] = "allow";
    RESEARCH_STAGING_DENIED_NAMES.forEach((name) => {
      rules[`${directory}/**/${name}`] = "deny";
      rules[`${directory}/**/${name}/**`] = "deny";
    });
  });
  profile.permission.external_directory = rules;
}

export function registerResearchOnlyAgent(config, agentsDir, env = process.env) {
  if (!config.agent) config.agent = {};
  const profile = researchOnlyProfile(agentsDir);
  if (env[AI_RESEARCH_TOOL_CEILING_ENV] === "1") {
    // The native ai_research tool supplies all context up front. Its nested
    // runtime needs inference only, so fail closed even against read-only tools
    // that the general research-only profile normally permits.
    profile.tools = { "*": false };
    profile.permission = { "*": "deny" };
  } else if (!profile.disable) {
    addResearchStagingPermissions(profile, env);
  }
  config.agent[RESEARCH_ONLY_AGENT_NAME] = profile;
  return 1;
}
