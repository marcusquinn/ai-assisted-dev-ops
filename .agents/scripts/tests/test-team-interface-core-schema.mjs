// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const schemaPath = path.join(testDirectory, "../../schemas/team-interface/core-v1.schema.json");
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function formatErrors(errors) {
  return (errors || [])
    .map((error) => `${error.instancePath || "<root>"} ${error.keyword}: ${error.message}`)
    .join("\n");
}

function assertInvalid(validate, document, label, predicate) {
  assert.equal(validate(document), false, `${label} unexpectedly validated`);
  assert.ok(predicate(validate.errors || []), `${label} failed for the wrong reason:\n${formatErrors(validate.errors)}`);
}

function assertSchemaHasNoSecretValueProperties(value, location = "<root>") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertSchemaHasNoSecretValueProperties(item, `${location}/${index}`));
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
  for (const [key, child] of Object.entries(value)) {
    assertSchemaHasNoSecretValueProperties(child, `${location}/${key}`);
  }
}

const schema = readJson(schemaPath);
assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(schema.$id, "urn:aidevops:team-interface:core:v1");
assertSchemaHasNoSecretValueProperties(schema);

const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
const validate = ajv.compile(schema);
const validFixture = readJson(path.join(fixtureDirectory, "core-valid.json"));

for (const [index, document] of validFixture.documents.entries()) {
  assert.equal(validate(document), true, `valid document ${index} failed:\n${formatErrors(validate.errors)}`);
}
assert.deepEqual(
  validFixture.documents.filter((document) => document.document_type === "event").map((document) => document.event.direction).sort(),
  ["inbox", "outbox"],
);

const invalidSecret = readJson(path.join(fixtureDirectory, "core-invalid-secret-value.json"));
assertInvalid(
  validate,
  invalidSecret,
  "core-invalid-secret-value",
  (errors) => errors.some((error) => error.keyword === "additionalProperties" && error.params.additionalProperty === "credential_value"),
);

const secretBearingMetadata = structuredClone(validFixture.documents[1]);
secretBearingMetadata.event.content.metadata.access_token = "forbidden-placeholder";
assertInvalid(
  validate,
  secretBearingMetadata,
  "secret-bearing metadata",
  (errors) => errors.some(
    (error) => error.keyword === "propertyNames"
      && error.instancePath === "/event/content/metadata"
      && error.params.propertyName === "access_token",
  ),
);

const invalidIdentities = readJson(path.join(fixtureDirectory, "core-invalid-identity.json"));
assertInvalid(
  validate,
  invalidIdentities.cases[0],
  "core-invalid-identity display-name-only",
  (errors) => errors.some((error) => error.keyword === "required" && error.instancePath.includes("/identities/0")),
);
assertInvalid(
  validate,
  invalidIdentities.cases[1],
  "core-invalid-identity unverified",
  (errors) => errors.some((error) => error.keyword === "const" && error.instancePath.endsWith("/verification/status")),
);

const invalidEvents = readJson(path.join(fixtureDirectory, "core-invalid-event.json"));
for (const invalidEvent of invalidEvents.cases) {
  assertInvalid(
    validate,
    invalidEvent.document,
    `core-invalid-event missing ${invalidEvent.missing}`,
    (errors) => errors.some(
      (error) => error.keyword === "required"
        && error.instancePath === "/event"
        && error.params.missingProperty === invalidEvent.missing,
    ),
  );
}

const unknownVersion = structuredClone(validFixture.documents[0]);
unknownVersion.schema_version = 2;
assertInvalid(
  validate,
  unknownVersion,
  "unknown schema version",
  (errors) => errors.some((error) => error.keyword === "const" && error.instancePath === "/schema_version"),
);

const unknownProperty = structuredClone(validFixture.documents[1]);
unknownProperty.event.provider_payload = {};
assertInvalid(
  validate,
  unknownProperty,
  "unknown event property",
  (errors) => errors.some(
    (error) => error.keyword === "additionalProperties"
      && error.instancePath === "/event"
      && error.params.additionalProperty === "provider_payload",
  ),
);

console.log("PASS: team-interface core schema accepts provider-neutral records and rejects unsafe inputs");
