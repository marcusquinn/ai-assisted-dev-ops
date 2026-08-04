// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const schemaDirectory = path.join(testDirectory, "../../schemas/team-interface");
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");
const requiredContextAxes = ["app", "team", "community", "project", "actor", "audit"];

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function formatErrors(errors) {
  return (errors || [])
    .map((error) => `${error.instancePath || "<root>"} ${error.keyword}: ${error.message}`)
    .join("\n");
}

function assertValid(validate, document, label) {
  assert.equal(validate(document), true, `${label} failed:\n${formatErrors(validate.errors)}`);
}

function assertInvalid(validate, document, label, predicate = () => true) {
  assert.equal(validate(document), false, `${label} unexpectedly validated`);
  assert.ok(predicate(validate.errors || []), `${label} failed for the wrong reason:\n${formatErrors(validate.errors)}`);
}

function assertNoForbiddenSchemaProperties(value, location = "<root>") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoForbiddenSchemaProperties(item, `${location}/${index}`));
    return;
  }
  if (!value || typeof value !== "object") return;

  if (value.properties) {
    for (const propertyName of Object.keys(value.properties)) {
      assert.doesNotMatch(
        propertyName,
        /^(token|password|private[_-]?key|credential[_-]?value|secret[_-]?value|model[_-]?id|provider[_-]?id|workspace[_-]?path|display[_-]?name)$/i,
        `unsafe property exposed at ${location}/properties/${propertyName}`,
      );
    }
  }
  for (const [key, child] of Object.entries(value)) {
    assertNoForbiddenSchemaProperties(child, `${location}/${key}`);
  }
}

function claimUnique(claims, value, label) {
  assert.equal(claims.has(value), false, `${label} collision: ${value}`);
  claims.add(value);
}

function validateManifestSet(validate, documents) {
  const stableIds = new Set();
  const identityRefs = new Set();
  const memoryRefs = new Set();
  const workspaceRefs = new Set();

  for (const [documentIndex, document] of documents.entries()) {
    assertValid(validate, document, `manifest set document ${documentIndex}`);
    claimUnique(stableIds, document.manifest_id, "manifest ID");
    claimUnique(stableIds, document.app_id, "app ID");
    claimUnique(stableIds, document.team_id, "team ID");

    for (const specialist of document.specialists) {
      claimUnique(stableIds, specialist.instance_id, "specialist instance ID");
      if (specialist.mode === "shared") {
        assert.deepEqual(
          [...specialist.request_context_axes].sort(),
          [...requiredContextAxes].sort(),
          "shared capability must retain app, team, community, project, actor, and audit context",
        );
        assert.equal(specialist.publication_mode, "caller");
        assert.equal(specialist.persistent_teammate, false);
        continue;
      }

      claimUnique(identityRefs, specialist.identity_ref, "identity");
      claimUnique(memoryRefs, specialist.memory_namespace_ref, "memory namespace");
      for (const workspaceRef of specialist.workspace_root_refs) {
        claimUnique(workspaceRefs, workspaceRef, "workspace root");
      }
      assert.equal(specialist.publication_mode, "specialist_with_actor");
      assert.equal(specialist.initiating_actor_required, true);
    }
  }
}

const coreSchema = readJson(path.join(schemaDirectory, "core-v1.schema.json"));
const appTeamSchema = readJson(path.join(schemaDirectory, "app-team-v1.schema.json"));
assert.equal(appTeamSchema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(appTeamSchema.$id, "urn:aidevops:team-interface:app-team:v1");
assertNoForbiddenSchemaProperties(appTeamSchema);

const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
ajv.addSchema(coreSchema);
const validate = ajv.compile(appTeamSchema);

const validModes = readJson(path.join(fixtureDirectory, "app-team-valid-modes.json"));
assertValid(validate, validModes, "valid mode manifest");
assert.deepEqual(validModes.specialists.map(({mode}) => mode).sort(), ["cloned", "dedicated", "shared"]);
assert.deepEqual(
  validModes.specialists.map(({workload_tier: tier}) => tier).sort(),
  ["simple", "standard", "thinking"],
);

const validIsolation = readJson(path.join(fixtureDirectory, "app-team-valid-isolation.json"));
validateManifestSet(validate, validIsolation.documents);

const invalidIsolation = readJson(path.join(fixtureDirectory, "app-team-invalid-isolation.json"));
for (const {axis, collision} of invalidIsolation.cases) {
  const collidingDocuments = structuredClone(validIsolation.documents);
  const firstPersistent = collidingDocuments[0].specialists.find(({mode}) => mode !== "shared");
  const secondPersistent = collidingDocuments[1].specialists.find(({mode}) => mode !== "shared");
  firstPersistent[axis] = collision;
  secondPersistent[axis] = collision;
  assert.throws(
    () => validateManifestSet(validate, collidingDocuments),
    new RegExp(`${axis === "identity_ref" ? "identity" : axis === "memory_namespace_ref" ? "memory" : "workspace"}.*collision`, "i"),
    `invalid-isolation ${axis} did not collide`,
  );
}

const invalidSharedState = readJson(path.join(fixtureDirectory, "app-team-invalid-shared-state.json"));
for (const invalidCase of invalidSharedState.cases) {
  const document = structuredClone(validModes);
  document.specialists[invalidSharedState.base_specialist_index][invalidCase.property] = invalidCase.value;
  assertInvalid(validate, document, `invalid-shared-state ${invalidCase.property}`);
}

const inheritedCloneState = structuredClone(validModes);
inheritedCloneState.specialists.find(({mode}) => mode === "cloned").inherited_mutable_state = true;
assertInvalid(
  validate,
  inheritedCloneState,
  "cloned inherited mutable state",
  (errors) => errors.some((error) => error.keyword === "const" && error.instancePath.endsWith("/inherited_mutable_state")),
);

const invalidUnsafeFields = readJson(path.join(fixtureDirectory, "app-team-invalid-secret-model.json"));
for (const invalidCase of invalidUnsafeFields.cases) {
  const document = structuredClone(validModes);
  const target = invalidCase.target === "manifest" ? document : document.specialists[0];
  target[invalidCase.property] = invalidCase.value;
  assertInvalid(validate, document, `invalid-secret-model ${invalidCase.property}`);
}

for (const invalidTier of ["fast", "provider/model", "high"]) {
  const document = structuredClone(validModes);
  document.specialists[0].workload_tier = invalidTier;
  assertInvalid(
    validate,
    document,
    `concrete model tier ${invalidTier}`,
    (errors) => errors.some((error) => error.keyword === "enum" && error.instancePath.endsWith("/workload_tier")),
  );
}

const unknownVersion = structuredClone(validModes);
unknownVersion.schema_version = 2;
assertInvalid(validate, unknownVersion, "unknown schema version");

const unknownProperty = structuredClone(validModes);
unknownProperty.runtime_overlay = {};
assertInvalid(validate, unknownProperty, "unknown manifest property");

console.log("PASS: app-team manifests enforce dedicated, cloned, and shared isolation contracts");
