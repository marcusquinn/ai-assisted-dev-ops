// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Credential transcript scrubbing shared by OpenCode post-tool hooks. */

const CREDENTIAL_PATTERN =
  /(^|[^A-Za-z0-9_-])(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;
const NAMED_CREDENTIAL_ASSIGNMENT_PATTERN =
  /(^|[^A-Za-z0-9_])((?:"[A-Za-z_][A-Za-z0-9_. -]*"|'[A-Za-z_][A-Za-z0-9_. -]*'|(?:API[ \t]+KEY|PRIVATE[ \t]+KEY|SECRET[ \t]+KEY|ACCESS[ \t]+TOKEN|AUTH[ \t]+TOKEN|CLIENT[ \t]+SECRET|USER[ \t]+PASSWORD)|[A-Za-z_][A-Za-z0-9_.-]*))(\s*(?:=|:)\s*)("(?:\\.|[^"\\])*"[^\r\n\s,}\])&;|<>]*|'(?:\\.|[^'\\])*'[^\r\n\s,}\])&;|<>]*|\[[^\r\n\s,};&|<>]*\][^\r\n\s,}\])&;|<>]*|<[^>\r\n]*>[^\r\n\s,}\])&;|<>]*|\([^()\r\n]*\)[^\r\n\s,}\])&;|<>]*|not[ \t]+set(?=$|[\s,}\])&;|<>])|[^\s,}\])&;|<>]+)/gim;
const PEM_BEGIN_MARKER = "-----BEGIN ";
const PEM_KEY_SUFFIX = "PRIVATE KEY-----";
const PEM_LABEL_PATTERN = /^[A-Z0-9 ]*$/;
const PLACEHOLDER_VALUES = new Set([
  "",
  "***",
  "[redacted]",
  "[redacted-credential]",
  "[redacted-private-key]",
  "(not set)",
  "<redacted>",
  "missing",
  "none",
  "not set",
  "null",
  "undefined",
]);

export const REDACTION_TOKEN = "[redacted-credential]";
export const PEM_REDACTION_TOKEN = "[redacted-private-key]";

function scrubPrivateKeys(text) {
  const chunks = [];
  let cursor = 0;
  let count = 0;
  while (cursor < text.length) {
    const start = text.indexOf(PEM_BEGIN_MARKER, cursor);
    if (start < 0) break;
    const labelStart = start + PEM_BEGIN_MARKER.length;
    const suffixStart = text.indexOf(PEM_KEY_SUFFIX, labelStart);
    if (suffixStart < 0) break;
    const label = text.slice(labelStart, suffixStart);
    const headerEnd = suffixStart + PEM_KEY_SUFFIX.length;
    if (!PEM_LABEL_PATTERN.test(label)) {
      chunks.push(text.slice(cursor, labelStart));
      cursor = labelStart;
      continue;
    }
    const endMarker = `-----END ${label}${PEM_KEY_SUFFIX}`;
    const nextStart = text.indexOf(PEM_BEGIN_MARKER, headerEnd);
    const segmentEnd = nextStart < 0 ? text.length : nextStart;
    const relativeEnd = text.slice(headerEnd, segmentEnd).indexOf(endMarker);
    if (relativeEnd < 0) {
      chunks.push(text.slice(cursor, headerEnd));
      cursor = headerEnd;
      continue;
    }
    const end = headerEnd + relativeEnd;
    chunks.push(text.slice(cursor, start), PEM_REDACTION_TOKEN);
    cursor = end + endMarker.length;
    count++;
  }
  chunks.push(text.slice(cursor));
  return { scrubbed: chunks.join(""), count };
}

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
  return /(?:^|_)(?:API_?KEY|PRIVATE_KEY|SECRET_KEY|ACCESS_KEY|ACCESS_KEY_ID|ENCRYPTION_KEY|SIGNING_KEY|TOKEN|SECRET|PASSWORD|PASSWD)$/.test(
    normalizeFieldName(name),
  );
}

function isPlaceholderValue(value) {
  return PLACEHOLDER_VALUES.has(unquote(value).toLowerCase());
}

function preservesSensitiveValue(value) {
  return value == null || (typeof value === "string" && isPlaceholderValue(value));
}

function redactAssignedValue(value) {
  if (isPlaceholderValue(value)) return value;
  const quote = value.at(0);
  if ((quote === '"' || quote === "'") && value.endsWith(quote)) {
    return `${quote}${REDACTION_TOKEN}${quote}`;
  }
  if (quote === "(" && value.endsWith(")")) return `(${REDACTION_TOKEN})`;
  return REDACTION_TOKEN;
}

/** Scrub known token prefixes and unknown-format values under sensitive names. */
export function scrubCredentials(text) {
  const { scrubbed: pemScrubbed, count: pemCount } = scrubPrivateKeys(text);
  let count = pemCount;
  const namedScrubbed = pemScrubbed.replace(
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
      if (isSensitiveFieldName(key) && !preservesSensitiveValue(nestedValue)) {
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
