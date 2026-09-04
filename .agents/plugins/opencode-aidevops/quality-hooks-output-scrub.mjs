// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Credential transcript scrubbing shared by OpenCode post-tool hooks. */

const CREDENTIAL_PATTERN =
  /(^|[^A-Za-z0-9_-])(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;
const NAMED_CREDENTIAL_ASSIGNMENT_PATTERN =
  /(^|[\s,{])((?:"[A-Za-z_][A-Za-z0-9_]*"|'[A-Za-z_][A-Za-z0-9_]*'|[A-Za-z_][A-Za-z0-9_]*))(\s*(?:=|:)\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\[(?:redacted|redacted-credential)\]|[^\s,}\]]+)/gm;
const PLACEHOLDER_VALUES = new Set([
  "",
  "***",
  "[redacted]",
  "[redacted-credential]",
  "<redacted>",
  "missing",
  "none",
  "not set",
  "null",
  "undefined",
]);

export const REDACTION_TOKEN = "[redacted-credential]";

function unquote(value) {
  const trimmed = String(value).trim();
  const quote = trimmed.at(0);
  if ((quote === '"' || quote === "'") && trimmed.endsWith(quote)) return trimmed.slice(1, -1);
  return trimmed;
}

function normalizeFieldName(name) {
  return unquote(name)
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[-.\s]+/g, "_")
    .toUpperCase();
}

function isSensitiveFieldName(name) {
  return /(?:^|_)(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD)$/.test(normalizeFieldName(name));
}

function isPlaceholderValue(value) {
  return PLACEHOLDER_VALUES.has(unquote(value).toLowerCase());
}

function redactAssignedValue(value) {
  if (isPlaceholderValue(value)) return value;
  const quote = value.at(0);
  if ((quote === '"' || quote === "'") && value.endsWith(quote)) {
    return `${quote}${REDACTION_TOKEN}${quote}`;
  }
  return REDACTION_TOKEN;
}

/** Scrub known token prefixes and unknown-format values under sensitive names. */
export function scrubCredentials(text) {
  let count = 0;
  const namedScrubbed = text.replace(
    NAMED_CREDENTIAL_ASSIGNMENT_PATTERN,
    (match, boundary, name, separator, value) => {
      if (!isSensitiveFieldName(name)) return match;
      const redacted = redactAssignedValue(value);
      if (redacted === value) return match;
      count++;
      return `${boundary}${name}${separator}${redacted}`;
    },
  );
  const scrubbed = namedScrubbed.replace(CREDENTIAL_PATTERN, (_match, boundary) => {
    count++;
    return `${boundary}${REDACTION_TOKEN}`;
  });
  return { scrubbed, count };
}

function scrubValue(value) {
  if (typeof value === "string") {
    const { scrubbed, count } = scrubCredentials(value);
    return { value: scrubbed, count };
  }
  if (Array.isArray(value)) {
    let total = 0;
    const result = value.map((item) => {
      const { value: scrubbed, count } = scrubValue(item);
      total += count;
      return scrubbed;
    });
    return { value: result, count: total };
  }
  if (value !== null && typeof value === "object") {
    let total = 0;
    const result = {};
    for (const [key, nestedValue] of Object.entries(value)) {
      if (isSensitiveFieldName(key) && typeof nestedValue === "string" && !isPlaceholderValue(nestedValue)) {
        result[key] = REDACTION_TOKEN;
        total++;
        continue;
      }
      const { value: scrubbed, count } = scrubValue(nestedValue);
      result[key] = scrubbed;
      total += count;
    }
    return { value: result, count: total };
  }
  return { value, count: 0 };
}

/** Scrub credentials from any JSON-serialisable tool output. */
export function scrubToolOutput(output) {
  const { value, count } = scrubValue(output);
  return { output: value, redacted: count > 0 };
}
