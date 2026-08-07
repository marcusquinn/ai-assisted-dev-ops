// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {
  canonicalJson,
  conversationConfigEvidence,
  ConversationOverlayError,
} from "../plugins/opencode-aidevops/team-interface-overlay-contract.mjs";

const EFFECTIVE_CONFIG_KEYS = [
  "default_agent",
  "formatter",
  "lsp",
  "mcp",
  "permission",
  "share",
  "snapshot",
  "subagent_depth",
  "tools",
];

function requireCanonicalMatch(actual, expected, label) {
  if (canonicalJson(actual) !== canonicalJson(expected)) {
    throw new ConversationOverlayError(
      "unsafe_effective_config",
      `${label} does not match the restricted conversation profile`,
    );
  }
}

function selectedProfileIsAvailable(selected, sourceDigest) {
  if (!selected || selected.disable) return false;
  if (selected.mode !== "primary") return false;
  if (typeof selected.prompt !== "string" || selected.prompt.length === 0) return false;
  const promptDigest = `sha256:${createHash("sha256").update(selected.prompt).digest("hex")}`;
  return promptDigest === sourceDigest;
}

export function verifyConversationEffectiveConfig(config, document, {pluginUrl} = {}) {
  const selectedName = document.agent.display_name;
  const evidence = conversationConfigEvidence(selectedName);
  for (const key of EFFECTIVE_CONFIG_KEYS) {
    requireCanonicalMatch(config[key], evidence[key], `effective config ${key}`);
  }

  const selected = config.agent?.[selectedName];
  if (!selectedProfileIsAvailable(selected, document.agent.source_digest)) {
    throw new ConversationOverlayError("unsafe_effective_config", "selected restricted agent prompt does not match canonical source bytes");
  }
  requireCanonicalMatch(selected.tools, evidence.agent[selectedName].tools, "selected agent tools");
  requireCanonicalMatch(selected.permission, evidence.agent[selectedName].permission, "selected agent permissions");

  for (const [name, profile] of Object.entries(config.agent || {})) {
    if (name !== selectedName && profile?.disable !== true) {
      throw new ConversationOverlayError("unsafe_effective_config", "an unselected agent remains enabled");
    }
  }
  if (!pluginUrl) {
    throw new ConversationOverlayError("runtime_incompatible", "pinned conversation plugin evidence is unavailable");
  }
  requireCanonicalMatch(config.plugin, [pluginUrl], "effective config plugin allowlist");
  requireCanonicalMatch(config.instructions, [], "effective config instruction allowlist");
  requireCanonicalMatch(config.command, {}, "effective config command allowlist");
}
