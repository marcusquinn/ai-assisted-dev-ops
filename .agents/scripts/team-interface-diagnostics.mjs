// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {homedir} from "node:os";

const DIAGNOSTIC_CODE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const ADAPTER_DIAGNOSTICS = Object.freeze({
  adapter_capability_mismatch: "adapter observation capability mismatch",
  adapter_identity_mismatch: "adapter observation identity mismatch",
  adapter_timeout: "adapter read timed out",
  duplicate_identity: "adapter observation contains duplicate identities",
  invalid_document: "adapter observation failed validation",
  unsupported_adapter_read: "adapter read method is unsupported",
});

function replaceControlCharacters(value) {
  return Array.from(value, (character) => {
    const code = character.charCodeAt(0);
    return code <= 31 || code === 127 ? " " : character;
  }).join("");
}

function safeMessage(error) {
  const message = error instanceof Error ? error.message : "unknown runtime failure";
  const home = homedir();
  const homeRedacted = home ? message.split(home).join("~") : message;
  return replaceControlCharacters(homeRedacted
    .replace(/\bBearer\s+[^\s,;]+/gi, "Bearer [REDACTED]")
    .replace(/\b(token|password|private[_-]?key|credential(?:[_-]?value)?|secret(?:[_-]?value)?)\s*[:=]\s*[^\s,;]+/gi, "$1=[REDACTED]"))
    .slice(0, 500);
}

function safeCode(error) {
  return typeof error?.code === "string" && DIAGNOSTIC_CODE_PATTERN.test(error.code)
    ? error.code
    : "runtime_error";
}

export function diagnostic(error, adapterId) {
  const adapterMessage = adapterId ? ADAPTER_DIAGNOSTICS[error?.code] : null;
  return {
    ...(adapterId ? {adapter_id: adapterId} : {}),
    code: adapterId ? (adapterMessage ? safeCode(error) : "adapter_read_failed") : safeCode(error),
    message: adapterId ? (adapterMessage || "adapter read failed") : safeMessage(error),
  };
}
