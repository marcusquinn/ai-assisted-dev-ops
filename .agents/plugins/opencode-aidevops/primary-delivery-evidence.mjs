// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Report only observed config delivery, never model comprehension or enforcement.

import { createHash } from "node:crypto";
import { readFileSync } from "fs";
import { join } from "path";

const PRIMARY_AGENT_DESCRIPTION = /^Read ~\/\.aidevops\/agents\/([a-z0-9-]+\.md)$/;

function readIfExists(filepath) {
  try {
    return readFileSync(filepath, "utf-8").trim();
  } catch {
    return "";
  }
}

function sha256OrNull(source) {
  return source ? createHash("sha256").update(source).digest("hex") : null;
}

function primaryAgentEvidence(profile, agentsDir) {
  const match = profile.description?.match(PRIMARY_AGENT_DESCRIPTION);
  if (!match) return null;

  const source = readIfExists(join(agentsDir, match[1]));
  return {
    source: match[1],
    sha256: sha256OrNull(source),
    delivery: !source ? "missing" : String(profile.prompt || "").trim() === source
      ? "delivered" : "shadowed_or_unresolved",
    profileSha256: createHash("sha256").update(JSON.stringify({
      tools: profile.tools || {}, permission: profile.permission || {},
    })).digest("hex"),
  };
}

function configuredCoreEvidence(config, agentsDir, core) {
  const instructions = Array.isArray(config.instructions) ? config.instructions : [];
  return {
    source: "AGENTS.md",
    configuredCount: instructions.filter((source) => source === join(agentsDir, "AGENTS.md")
      || source === "~/.aidevops/agents/AGENTS.md").length,
    sha256: sha256OrNull(core),
    delivery: "not_observed_at_config_stage",
  };
}

export function primaryDeliveryEvidence(config, agentsDir) {
  const core = readIfExists(join(agentsDir, "AGENTS.md"));
  const sources = Object.values(config.agent || {})
    .filter((profile) => profile.mode === "primary")
    .map((profile) => primaryAgentEvidence(profile, agentsDir))
    .filter(Boolean);
  return {
    stage: "config",
    enforcement: "not_observed",
    versionSha256: sha256OrNull(readIfExists(join(agentsDir, "VERSION"))),
    core: configuredCoreEvidence(config, agentsDir, core),
    sources,
  };
}
