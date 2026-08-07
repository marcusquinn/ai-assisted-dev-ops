// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
} from "node:fs";
import {isAbsolute, join, resolve} from "node:path";

import {
  canonicalDigest,
  canonicalJson,
  ConversationOverlayError,
  parseCanonicalOverlayText,
  sourceFilenameFromReference,
} from "./team-interface-overlay-contract.mjs";

const MAX_AGENT_SOURCE_BYTES = 1024 * 1024;
const MAX_OVERLAY_BYTES = 64 * 1024;
const MAX_ROSTER_BYTES = 1024 * 1024;
const PYTHON_BINARY = "/usr/bin/python3";
const ROSTER_KEYS = ["agents", "document_type", "roster_digest", "roster_id", "schema_version"];
const ROSTER_AGENT_KEYS = [
  "agent_id",
  "description",
  "display_name",
  "kind",
  "source_digest",
  "source_ref",
  "workload_tier",
];
const SELECTED_AGENT_KEYS = ["agent_id", "display_name", "kind", "source_digest", "source_ref"];

export function readBoundedRegularFile(filePath, maximumBytes, label) {
  const absolutePath = resolve(filePath);
  let before;
  try {
    before = lstatSync(absolutePath);
  } catch {
    throw new ConversationOverlayError("missing_document", `${label} is unavailable`);
  }
  if (!before.isFile() || before.isSymbolicLink()) {
    throw new ConversationOverlayError("unsafe_path", `${label} must be a regular non-symlink file`);
  }
  if (before.size > maximumBytes) {
    throw new ConversationOverlayError("document_too_large", `${label} exceeds its size limit`);
  }

  let descriptor;
  try {
    descriptor = openSync(absolutePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino) {
      throw new ConversationOverlayError("unsafe_path", `${label} changed while it was opened`);
    }
    const bytes = readFileSync(descriptor);
    if (bytes.length > maximumBytes) {
      throw new ConversationOverlayError("document_too_large", `${label} exceeds its size limit`);
    }
    const after = lstatSync(absolutePath);
    if (!after.isFile() || after.isSymbolicLink() || after.dev !== opened.dev || after.ino !== opened.ino) {
      throw new ConversationOverlayError("unsafe_path", `${label} changed while it was read`);
    }
    return {absolutePath, bytes, contents: bytes.toString("utf8")};
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export function readCanonicalOverlayFile(filePath) {
  if (!isAbsolute(filePath || "")) {
    throw new ConversationOverlayError("unsafe_path", "OpenCode launch overlay path must be absolute");
  }
  const {absolutePath, contents} = readBoundedRegularFile(filePath, MAX_OVERLAY_BYTES, "OpenCode launch overlay");
  return {absolutePath, document: parseCanonicalOverlayText(contents)};
}

export function requireExactObjectKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ConversationOverlayError("invalid_document", `${label} must be an object`);
  }
  if (canonicalJson(Object.keys(value).sort()) !== canonicalJson([...expected].sort())) {
    throw new ConversationOverlayError("invalid_document", `${label} contains missing or unsupported fields`);
  }
}

function validateCanonicalRoster(roster) {
  requireExactObjectKeys(roster, ROSTER_KEYS, "canonical agent roster");
  const invalidStructure = [
    roster.schema_version !== 1,
    roster.document_type !== "agent_roster",
    roster.roster_id !== "agent-roster.aidevops",
    !Array.isArray(roster.agents),
    roster.agents.length < 2,
  ].some(Boolean);
  if (invalidStructure) {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster structure is invalid");
  }
  const unsigned = structuredClone(roster);
  delete unsigned.roster_digest;
  if (roster.roster_digest !== canonicalDigest(unsigned)) {
    throw new ConversationOverlayError("digest_mismatch", "canonical agent roster digest is invalid");
  }
  const ids = new Set();
  let guideCount = 0;
  for (const agent of roster.agents) {
    requireExactObjectKeys(agent, ROSTER_AGENT_KEYS, "canonical roster agent");
    if (ids.has(agent.agent_id)) {
      throw new ConversationOverlayError("invalid_roster", "canonical agent roster contains duplicate IDs");
    }
    ids.add(agent.agent_id);
    if (agent.kind === "framework_guide") guideCount += 1;
  }
  if (guideCount !== 1) {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster must contain one framework guide");
  }
  return roster;
}

export function loadCanonicalAgentRoster(agentsDir) {
  const rosterScript = join(resolve(agentsDir), "scripts", "team-interface-agent-roster.py");
  let scriptMetadata;
  try {
    scriptMetadata = lstatSync(rosterScript);
  } catch {
    throw new ConversationOverlayError("missing_document", "canonical agent roster generator is unavailable");
  }
  if (!scriptMetadata.isFile() || scriptMetadata.isSymbolicLink()) {
    throw new ConversationOverlayError("unsafe_path", "canonical agent roster generator is not a regular file");
  }

  let output;
  try {
    output = execFileSync(
      PYTHON_BINARY,
      ["-I", "-B", rosterScript, "--agents-dir", resolve(agentsDir)],
      {
        encoding: "utf8",
        env: {PATH: "/usr/bin:/bin", PYTHONNOUSERSITE: "1"},
        maxBuffer: MAX_ROSTER_BYTES,
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15000,
      },
    );
  } catch {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster generation failed");
  }

  let roster;
  try {
    roster = JSON.parse(output);
  } catch {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster output is invalid JSON");
  }
  return validateCanonicalRoster(roster);
}

export function bindOverlayToCanonicalRoster(document, canonicalRoster) {
  const roster = validateCanonicalRoster(canonicalRoster);
  if (document.roster_digest !== roster.roster_digest) {
    throw new ConversationOverlayError("roster_mismatch", "OpenCode launch overlay does not bind to the current canonical roster");
  }
  const matches = roster.agents.filter(({agent_id: agentID}) => agentID === document.agent.agent_id);
  if (matches.length !== 1) {
    throw new ConversationOverlayError("unknown_agent", "selected overlay agent is not uniquely present in the canonical roster");
  }
  const selected = Object.fromEntries(
    SELECTED_AGENT_KEYS.map((key) => [key, matches[0][key]]),
  );
  if (canonicalJson(selected) !== canonicalJson(document.agent)) {
    throw new ConversationOverlayError("agent_mismatch", "selected overlay agent does not match its canonical roster entry");
  }
  return matches[0];
}

export function readVerifiedAgentSource(agentsDir, agent) {
  const sourcePath = join(resolve(agentsDir), sourceFilenameFromReference(agent.source_ref));
  const {bytes, contents} = readBoundedRegularFile(sourcePath, MAX_AGENT_SOURCE_BYTES, "selected agent source");
  const sourceDigest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  if (sourceDigest !== agent.source_digest) {
    throw new ConversationOverlayError("digest_mismatch", "selected agent source digest no longer matches the overlay");
  }
  return contents;
}
