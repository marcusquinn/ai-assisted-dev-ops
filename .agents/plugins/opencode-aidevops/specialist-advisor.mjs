// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { routingProfile } from "./model-routing.mjs";

export const SPECIALIST_ADVISOR = "specialist-advisor";

// A separate explicit profile, never another rung in the automatic tier ladder.
// Existing user profiles (including disable:true) retain ownership of their name.
export function registerSpecialistAdvisor(config, agentsDir, routing, state) {
  const route = routing?.specialistAdvisor;
  if (state && state.specialistAdvisor !== config.agent?.[SPECIALIST_ADVISOR]) {
    delete state.specialistAdvisor;
  }
  if (!route || config.agent?.[SPECIALIST_ADVISOR]) return 0;
  let prompt;
  try {
    prompt = readFileSync(join(agentsDir, "prompts/specialist-advisor.md"), "utf8").trim();
  } catch {
    return 0; // Missing canonical guidance must not create an unbounded adviser.
  }
  if (!prompt) return 0;
  config.agent ||= {};
  config.agent[SPECIALIST_ADVISOR] = {
    description: "Explicit higher-capability advisory inference over supplied evidence; requires an escalation reason",
    mode: "subagent",
    model: route.model,
    variant: route.variant,
    prompt,
    tools: { "*": false },
    permission: { "*": "deny" },
  };
  if (state) state.specialistAdvisor = config.agent[SPECIALIST_ADVISOR];
  state?.pinned?.add(SPECIALIST_ADVISOR);
  return 1;
}

export function validateSpecialistRequest(text) {
  let envelope;
  try {
    envelope = JSON.parse(String(text).replace(/^\[effort:(simple|standard|thinking)\]\s*/i, ""));
  } catch {
    throw new Error("[aidevops] Specialist adviser requires a bounded JSON evidence envelope");
  }
  const required = ["objective", "scope", "evidence", "escalation_reason", "output"];
  if (!required.every((key) => typeof envelope?.[key] === "string" && envelope[key].trim())) {
    throw new Error("[aidevops] Specialist adviser requires objective, scope, evidence, escalation_reason and output");
  }
}

// Defaults only: never migrate an explicit user model/effort pin behind their back.
export function applyDailyDriverDefaults(config, routing) {
  const route = routingProfile(routing, "thinking");
  if (!route.model) return;
  config.model ||= route.model;
  for (const profile of Object.values(config.agent || {})) {
    if (profile?.mode !== "primary" || profile.variant) continue;
    if ((profile.model || config.model) === route.model && route.variant) {
      profile.variant = route.variant;
    }
  }
}
