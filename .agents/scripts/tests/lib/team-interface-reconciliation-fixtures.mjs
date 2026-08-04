// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";

export function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function formatErrors(errors) {
  return (errors || [])
    .map((error) => `${error.instancePath || "<root>"} ${error.keyword}: ${error.message}`)
    .join("\n");
}

export function assertValid(validate, document, label) {
  assert.equal(validate(document), true, `${label} failed:\n${formatErrors(validate.errors)}`);
}

export function assertInvalid(validate, document, label) {
  assert.equal(validate(document), false, `${label} unexpectedly validated`);
}

export function documentId(document) {
  return document.receipt_id || document.plan_id || document.input_id || document.policy_id;
}

function decodePointerSegment(segment) {
  return segment.replaceAll("~1", "/").replaceAll("~0", "~");
}

export function applyMutation(document, invalidCase) {
  const clone = structuredClone(document);
  const mutate = (pointer, value, operation = "replace") => {
    const segments = pointer.split("/").slice(1).map(decodePointerSegment);
    const property = segments.pop();
    let target = clone;
    for (const segment of segments) target = target[segment];
    if (operation === "remove") delete target[property];
    else if (operation === "pop") target[property].pop();
    else target[property] = value;
  };
  mutate(invalidCase.path, invalidCase.value, invalidCase.operation);
  if (invalidCase.second_path) mutate(invalidCase.second_path, invalidCase.second_value);
  return clone;
}

function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
    return `{${entries.join(",")}}`;
  }
  return JSON.stringify(value);
}

export function canonicalPlanHash(plan) {
  const payload = structuredClone(plan);
  delete payload.plan_hash;
  return `sha256:${crypto.createHash("sha256").update(stableStringify(payload)).digest("hex")}`;
}

export function assertUniquePaths(records, label) {
  const paths = records.map(({field_path: fieldPath}) => fieldPath);
  assert.equal(new Set(paths).size, paths.length, `${label} contains duplicate field paths`);
}

export function snapshotDigest(snapshot) {
  return snapshot.present ? snapshot.digest : null;
}

export function collectEnumValues(value, result = []) {
  if (Array.isArray(value)) {
    for (const item of value) collectEnumValues(item, result);
    return result;
  }
  if (!value || typeof value !== "object") return result;
  if (Array.isArray(value.enum)) result.push(...value.enum);
  if (Object.hasOwn(value, "const")) result.push(value.const);
  for (const child of Object.values(value)) collectEnumValues(child, result);
  return result;
}

export function assertNoSecretValueProperties(value, location = "<root>") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoSecretValueProperties(item, `${location}/${index}`));
    return;
  }
  if (!value || typeof value !== "object") return;
  if (value.properties) {
    for (const propertyName of Object.keys(value.properties)) {
      assert.doesNotMatch(
        propertyName,
        /^(token|password|private[_-]?key|credential[_-]?value|secret[_-]?value)$/i,
        `secret-value property exposed at ${location}/properties/${propertyName}`,
      );
    }
  }
  for (const [key, child] of Object.entries(value)) assertNoSecretValueProperties(child, `${location}/${key}`);
}
