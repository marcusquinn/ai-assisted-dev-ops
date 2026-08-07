// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Agent index registration and fail-closed research-only profile construction.

import { existsSync, readFileSync, realpathSync } from "fs";
import { homedir } from "os";
import { isAbsolute, join, relative, resolve, sep } from "path";
import { loadAgentIndex } from "./agent-loader.mjs";
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
  for (const [name, profile] of Object.entries(config.agent || {})) {
    const model = String(profile?.model || "");
    const metadata = String(profile?.[ROUTING_TIER_METADATA] || "");
    if (
      model.includes("/")
      || DEFAULT_ESCALATION_ORDER.includes(model.toLowerCase())
      || DEFAULT_ESCALATION_ORDER.includes(metadata.toLowerCase())
    ) {
      registerAgentRoutingIntent(state, name, profile, metadata || model, routing);
    }
  }
}

function registerBuiltInRoutedAgents(config, routing, state) {
  const builtIns = [
    ["explore", "simple", "Fast repository exploration"],
    ["general", "standard", "General-purpose delegated work"],
  ];
  let injected = 0;
  for (const [name, tier, description] of builtIns) {
    if (!config.agent[name]) {
      config.agent[name] = { description, mode: "subagent" };
      injected++;
    }
    registerAgentRoutingIntent(state, name, config.agent[name], tier, routing);
  }
  return injected;
}

export function registerAgents(config, agentsDir, routing, state) {
  registerConfiguredRoutingIntents(config, routing, state);
  const indexAgents = loadAgentIndex(agentsDir, readIfExists);
  let injected = 0;

  for (const agent of indexAgents) {
    if (!config.agent[agent.name]) {
      config.agent[agent.name] = {
        description: agent.description,
        mode: "subagent",
      };
      injected++;
    }
    registerAgentRoutingIntent(state, agent.name, config.agent[agent.name], agent.modelTier, routing);
  }
  return injected + registerBuiltInRoutedAgents(config, routing, state);
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
    for (const line of match[1].split("\n")) {
      const entry = parseFrontmatterEntry(line);
      if (entry) assignFrontmatterEntry(stack, entry);
    }
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
  for (const directory of researchStagingDirectories(env)) {
    rules[directory] = "allow";
    rules[`${directory}/**`] = "allow";
    for (const name of RESEARCH_STAGING_DENIED_NAMES) {
      rules[`${directory}/**/${name}`] = "deny";
      rules[`${directory}/**/${name}/**`] = "deny";
    }
  }
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
