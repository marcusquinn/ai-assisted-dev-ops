// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

function selectedProfileIsAvailable(selected) {
  if (!selected || selected.disable) return false;
  if (selected.mode !== "primary") return false;
  return typeof selected.prompt === "string" && selected.prompt.length > 0;
}

export function verifyConversationEffectiveConfig(config, document) {
  const selectedName = document.agent.display_name;
  const evidence = conversationConfigEvidence(selectedName);
  for (const key of EFFECTIVE_CONFIG_KEYS) {
    requireCanonicalMatch(config[key], evidence[key], `effective config ${key}`);
  }

  const selected = config.agent?.[selectedName];
  if (!selectedProfileIsAvailable(selected)) {
    throw new ConversationOverlayError("unsafe_effective_config", "selected restricted agent profile is unavailable");
  }
  requireCanonicalMatch(selected.tools, evidence.agent[selectedName].tools, "selected agent tools");
  requireCanonicalMatch(selected.permission, evidence.agent[selectedName].permission, "selected agent permissions");

  for (const [name, profile] of Object.entries(config.agent || {})) {
    if (name !== selectedName && profile?.disable !== true) {
      throw new ConversationOverlayError("unsafe_effective_config", "an unselected agent remains enabled");
    }
  }
}
