#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression test for GH#27401: shipped defaults must satisfy the shipped schema.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
DEFAULTS_FILE="${SCRIPT_DIR}/../../configs/aidevops.defaults.jsonc"
SCHEMA_FILE="${SCRIPT_DIR}/../../configs/aidevops-config.schema.json"

node - "$DEFAULTS_FILE" "$SCHEMA_FILE" <<'JS'
const fs = require("node:fs");
const Ajv2020 = require("ajv/dist/2020").default;

function stripJsoncComments(source) {
  let output = "";
  let index = 0;
  let inString = false;
  let escaped = false;

  while (index < source.length) {
    const char = source[index];
    const nextChar = source[index + 1] || "";

    if (inString) {
      output += char;
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      index += 1;
      continue;
    }

    if (char === '"') {
      inString = true;
      output += char;
      index += 1;
    } else if (char === "/" && nextChar === "/") {
      index += 2;
      while (index < source.length && !"\r\n".includes(source[index])) index += 1;
    } else if (char === "/" && nextChar === "*") {
      const commentEnd = source.indexOf("*/", index + 2);
      if (commentEnd === -1) throw new Error("Unterminated JSONC block comment");
      index = commentEnd + 2;
    } else {
      output += char;
      index += 1;
    }
  }

  return output;
}

const [, , defaultsPath, schemaPath] = process.argv;
const defaults = JSON.parse(stripJsoncComments(fs.readFileSync(defaultsPath, "utf8")));
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const validate = new Ajv2020({ allErrors: true, strict: false, validateFormats: false }).compile(schema);

function assertValid(config, label) {
  if (validate(config)) return;
  for (const error of validate.errors || []) {
    console.error(`${label} ${error.instancePath || "<root>"}: ${error.message}`);
  }
  process.exit(1);
}

assertValid(defaults, "defaults");
console.log("PASS: complete shipped defaults satisfy the shipped config schema");

const validOverride = {
  ...defaults,
  foss: { enabled: true, max_daily_tokens: 0, max_concurrent_contributions: 1 },
  orchestration: {
    ...defaults.orchestration,
    triage_known_contributors: "known-user,another-user",
    triage_refresh_interval_seconds: 600,
  },
};
assertValid(validOverride, "valid override");
console.log("PASS: valid FOSS overrides satisfy the shipped config schema");

for (const invalidFoss of [
  { enabled: "yes", max_daily_tokens: 1, max_concurrent_contributions: 1 },
  { enabled: true, max_daily_tokens: -1, max_concurrent_contributions: 1 },
  { enabled: true, max_daily_tokens: 1, max_concurrent_contributions: 0 },
  { enabled: true, max_daily_tokens: 1, max_concurrent_contributions: 1, unknown: true },
]) {
  if (validate({ ...defaults, foss: invalidFoss })) {
    console.error(`invalid FOSS config unexpectedly passed: ${JSON.stringify(invalidFoss)}`);
    process.exit(1);
  }
}
console.log("PASS: malformed and unknown FOSS settings are rejected");

for (const invalidOrchestration of [
  { ...defaults.orchestration, triage_known_contributors: ["known-user"] },
  { ...defaults.orchestration, triage_refresh_interval_seconds: 29 },
  { ...defaults.orchestration, unknown_triage_setting: true },
]) {
  if (validate({ ...defaults, orchestration: invalidOrchestration })) {
    console.error(`invalid orchestration config unexpectedly passed: ${JSON.stringify(invalidOrchestration)}`);
    process.exit(1);
  }
}
console.log("PASS: malformed and unknown triage orchestration settings are rejected");
JS
