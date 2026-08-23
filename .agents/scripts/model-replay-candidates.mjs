// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { resolve } from "node:path";
import { TIERS, readJson } from "./model-replay-core.mjs";
import { CANDIDATE_SCHEMA } from "./model-replay-contracts.mjs";

const LOWER_IDENTIFIER_CHARACTERS = "abcdefghijklmnopqrstuvwxyz0123456789._-";
const MODEL_CHARACTERS = `${LOWER_IDENTIFIER_CHARACTERS}ABCDEFGHIJKLMNOPQRSTUVWXYZ:/`;

function startsWithAlphanumeric(value) {
  const first = value[0]?.toLowerCase() || "";
  return "abcdefghijklmnopqrstuvwxyz0123456789".includes(first);
}

function charactersAreAllowed(value, characters) {
  return [...value].every((character) => characters.includes(character));
}

function isLowerIdentifier(value) {
  return typeof value === "string" && value === value.toLowerCase()
    && startsWithAlphanumeric(value) && charactersAreAllowed(value, LOWER_IDENTIFIER_CHARACTERS);
}

function isModelIdentifier(value) {
  if (typeof value !== "string") return false;
  const separator = value.indexOf("/");
  if (separator < 1 || separator === value.length - 1) return false;
  const provider = value.slice(0, separator);
  const model = value.slice(separator + 1);
  return isLowerIdentifier(provider) && startsWithAlphanumeric(model)
    && charactersAreAllowed(model, MODEL_CHARACTERS);
}

function referencesAnthropic(value) {
  const normalized = String(value).toLowerCase();
  return normalized.includes("anthropic") || normalized.includes("claude");
}

function isEffortIdentifier(value) {
  if (value === "default") return true;
  return typeof value === "string" && startsWithAlphanumeric(value)
    && charactersAreAllowed(value, "abcdefghijklmnopqrstuvwxyz0123456789-");
}

function parseISODate(value, label) {
  const timestamp = Date.parse(value || "");
  if (!Number.isFinite(timestamp)) throw new Error(`${label} must be an ISO date`);
  return timestamp;
}

function validateCandidateModel(candidate) {
  if (!candidate || !isModelIdentifier(candidate.model)) {
    throw new Error("Each candidate requires provider/model");
  }
}

function validateCandidateIdentity(candidate, allowedProviders) {
  validateCandidateModel(candidate);
  const provider = candidate.model.slice(0, candidate.model.indexOf("/"));
  if (referencesAnthropic(candidate.model)) {
    throw new Error(`Anthropic-family candidate ${candidate.model} is excluded by benchmark policy`);
  }
  if (!allowedProviders.includes(provider)) {
    throw new Error(`Candidate provider ${provider} is not in the explicit allowlist`);
  }
  if (!TIERS.includes(candidate.tier)) throw new Error(`Invalid candidate tier for ${candidate.model}`);
  if (candidate.runtime && candidate.runtime !== "opencode") {
    throw new Error(`Candidate ${candidate.model} runtime must be opencode for isolated replay`);
  }
}

function validateEffortVariants(candidate) {
  if (!Array.isArray(candidate.efforts) || candidate.efforts.length === 0) {
    throw new Error(`Candidate ${candidate.model} requires effort variants`);
  }
  for (const effort of candidate.efforts) {
    if (!isEffortIdentifier(effort)) {
      throw new Error(`Invalid effort ${effort} for ${candidate.model}`);
    }
  }
}

function validateCandidateEfforts(candidate) {
  validateEffortVariants(candidate);
  if (typeof candidate.primary_effort !== "string"
    || !candidate.efforts.includes(candidate.primary_effort)) {
    throw new Error(`Candidate ${candidate.model} primary_effort must appear in efforts`);
  }
  if (new Set(candidate.efforts).size !== candidate.efforts.length) {
    throw new Error(`Candidate ${candidate.model} effort variants must be unique`);
  }
}

function validateCandidate(candidate, allowedProviders) {
  validateCandidateIdentity(candidate, allowedProviders);
  validateCandidateEfforts(candidate);
  const timeout = Number(candidate.timeout_seconds ?? 3600);
  if (!Number.isInteger(timeout) || timeout < 60 || timeout > 21600) {
    throw new Error(`Candidate ${candidate.model} timeout_seconds must be 60..21600`);
  }
  if (candidate.knowledge_cutoff) parseISODate(candidate.knowledge_cutoff, "knowledge_cutoff");
}

function validateProviderAllowlist(candidates) {
  if (!Array.isArray(candidates.allowed_providers) || candidates.allowed_providers.length === 0) {
    throw new Error("Candidate configuration requires an explicit provider allowlist");
  }
  const invalidProvider = candidates.allowed_providers.find(
    (provider) => !isLowerIdentifier(provider),
  );
  if (invalidProvider || new Set(candidates.allowed_providers).size !== candidates.allowed_providers.length) {
    throw new Error("Allowed providers must be unique lowercase identifiers");
  }
  if (candidates.allowed_providers.some(referencesAnthropic)) {
    throw new Error("Anthropic-family providers are excluded by benchmark policy");
  }
}

export function loadCandidates(path) {
  const candidates = readJson(resolve(path));
  if (candidates.schema_version !== CANDIDATE_SCHEMA) {
    throw new Error("Unsupported candidate configuration schema");
  }
  validateProviderAllowlist(candidates);
  if (!Array.isArray(candidates.candidates) || candidates.candidates.length === 0) {
    throw new Error("Candidate configuration has no candidates");
  }
  candidates.candidates.forEach((candidate) => {
    validateCandidate(candidate, candidates.allowed_providers);
  });
  const models = candidates.candidates.map((candidate) => candidate.model);
  if (new Set(models).size !== models.length) {
    throw new Error("Candidate models must be unique within an experiment");
  }
  return candidates;
}

export function contaminationFor(definition, candidate) {
  if (definition.provenance.visibility === "private") return "fresh";
  if (!definition.provenance.merged_at || !candidate.knowledge_cutoff) return "unknown";
  return parseISODate(definition.provenance.merged_at, "merged_at")
    > parseISODate(candidate.knowledge_cutoff, "knowledge_cutoff")
    ? "fresh"
    : "known";
}
