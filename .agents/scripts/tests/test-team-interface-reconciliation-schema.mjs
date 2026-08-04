// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import path from "node:path";
import {fileURLToPath} from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import {
  applyMutation,
  assertInvalid,
  assertNoSecretValueProperties,
  assertUniquePaths,
  assertValid,
  collectEnumValues,
  documentId,
  readJson,
} from "./lib/team-interface-reconciliation-fixtures.mjs";
import {
  assertInputPolicy,
  assertPlanSemantics,
  assertReceiptSemantics,
  assertRollbackSemantics,
  recordOperation,
} from "./lib/team-interface-reconciliation-semantics.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const schemaDirectory = path.join(testDirectory, "../../schemas/team-interface");
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");

const coreSchema = readJson(path.join(schemaDirectory, "core-v1.schema.json"));
const reconciliationSchema = readJson(path.join(schemaDirectory, "reconciliation-v1.schema.json"));
assert.equal(reconciliationSchema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(reconciliationSchema.$id, "urn:aidevops:team-interface:reconciliation:v1");
assertNoSecretValueProperties(reconciliationSchema);
assert.equal(collectEnumValues(reconciliationSchema).includes("delete"), false, "automatic delete must be unrepresentable");

const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
ajv.addSchema(coreSchema);
ajv.addSchema(reconciliationSchema);
const validate = ajv.getSchema(reconciliationSchema.$id);
const validateFieldDecision = ajv.compile({$ref: `${reconciliationSchema.$id}#/$defs/field_decision`});

const validPlanFixture = readJson(path.join(fixtureDirectory, "reconciliation-valid-plan.json"));
const validLifecycleFixture = readJson(path.join(fixtureDirectory, "reconciliation-valid-retire-rollback.json"));
const validDocuments = [...validPlanFixture.documents, ...validLifecycleFixture.documents];
const documentById = new Map(validDocuments.map((document) => [documentId(document), document]));

for (const document of validDocuments) {
  assertValid(validate, document, `valid ${document.document_type} ${documentId(document)}`);
}

const policy = validDocuments.find(({document_type: type}) => type === "ownership_policy");
assertUniquePaths(policy.field_rules, "ownership policy");
assert.equal(policy.unknown_field_ownership, "review_required");
const inputById = new Map(
  validDocuments.filter(({document_type: type}) => type === "reconciliation_input")
    .map((document) => [document.input_id, document]),
);
for (const reconciliationInput of inputById.values()) assertInputPolicy(reconciliationInput, policy);
const context = {policy, inputById, receiptByReference: new Map()};

const input = documentById.get("reconciliation-input.agent-alpha.7");
assert.equal(input.resource.match_basis, "stable_ids", "display labels must not identify or adopt resources");
const sensitiveInput = input.fields.find(({sensitive}) => sensitive);
for (const snapshotName of ["desired", "last_applied", "actual"]) {
  assert.equal(sensitiveInput[snapshotName].data.kind, "secret_reference", "sensitive data must remain a secret reference");
}

const decisionPlan = documentById.get("plan.agent-alpha.7");
const decisions = new Map(decisionPlan.field_decisions.map((decision) => [decision.field_path, decision]));
assert.equal(decisions.get("/display_label").decision, "preserve_actual");
assert.equal(decisions.get("/model_ref").decision, "apply_desired");
assert.equal(decisions.get("/startup_mode").decision, "no_change");
assert.equal(decisions.get("/instructions_ref").reason, "user_modified");
assert.equal(decisions.get("/authority_ref").decision, "review_required");
assert.equal(decisions.get("/credential_ref").decision, "disable_execution");
assert.equal(decisions.get("/unclassified_provider_field").reason, "unmanaged_resource");

const fallbackPlan = documentById.get("plan.agent-alpha.draft-8");
assert.equal(fallbackPlan.outcome, "owner_reviewed_draft");
assert.ok(Object.values(fallbackPlan.capabilities).includes(false), "fallback plan must demonstrate a capability gap");

const operationRegistry = {operationHashes: new Map(), idempotencyHashes: new Map()};
for (const plan of validDocuments.filter(({document_type: type}) => type === "reconciliation_plan")) {
  assertPlanSemantics(plan, context);
  recordOperation(operationRegistry, plan);
}

const receipts = validDocuments.filter(({document_type: type}) => type === "apply_receipt");
for (const receipt of receipts) assertReceiptSemantics(receipt);
for (const receipt of receipts.filter(({state}) => ["partial", "indeterminate"].includes(state))) {
  assert.equal(receipt.read_after_write_required, true, `${receipt.state} must require read-after-write reconciliation`);
  assert.equal(receipt.audit.redaction, "redacted");
}
const receiptByReference = new Map(receipts.map((receipt) => [`receipt:${receipt.receipt_id}`, receipt]));
context.receiptByReference = receiptByReference;
const rollback = documentById.get("plan.agent-alpha.rollback-12");
assertRollbackSemantics(rollback, context);
recordOperation(operationRegistry, rollback);

const invalidOverwrite = readJson(path.join(fixtureDirectory, "reconciliation-invalid-overwrite.json"));
for (const invalidCase of invalidOverwrite.cases) {
  assertInvalid(validateFieldDecision, invalidCase.decision, invalidCase.label);
}

const invalidCas = readJson(path.join(fixtureDirectory, "reconciliation-invalid-cas.json"));
for (const invalidCase of invalidCas.cases) {
  const base = documentById.get(invalidCase.base);
  assert.ok(base, `missing fixture base ${invalidCase.base}`);
  const mutated = applyMutation(base, invalidCase);
  if (invalidCase.validation === "schema") {
    assertInvalid(validate, mutated, invalidCase.label);
    continue;
  }
  assertValid(validate, mutated, `${invalidCase.label} structural precondition`);
  if (invalidCase.validation === "operation_conflict") {
    const collisionRegistry = {operationHashes: new Map(), idempotencyHashes: new Map()};
    recordOperation(collisionRegistry, base);
    assert.throws(() => recordOperation(collisionRegistry, mutated), new RegExp(invalidCase.error, "i"));
    continue;
  }
  if (invalidCase.validation === "idempotency_conflict") {
    const collisionRegistry = {operationHashes: new Map(), idempotencyHashes: new Map()};
    recordOperation(collisionRegistry, base);
    assert.throws(() => recordOperation(collisionRegistry, mutated), new RegExp(invalidCase.error, "i"));
    continue;
  }
  let semanticCheck;
  if (mutated.document_type === "rollback_plan") {
    semanticCheck = () => assertRollbackSemantics(mutated, context, invalidCase.apply_at);
  } else if (mutated.document_type === "reconciliation_input") {
    semanticCheck = () => assertInputPolicy(mutated, policy);
  } else if (mutated.document_type === "apply_receipt") {
    semanticCheck = () => assertReceiptSemantics(mutated);
  } else {
    semanticCheck = () => assertPlanSemantics(mutated, context, invalidCase.apply_at);
  }
  assert.throws(semanticCheck, new RegExp(invalidCase.error, "i"));
}

const invalidAdoptionDelete = readJson(
  path.join(fixtureDirectory, "reconciliation-invalid-adoption-delete.json"),
);
for (const invalidCase of invalidAdoptionDelete.cases) {
  const base = documentById.get(invalidCase.base);
  assert.ok(base, `missing fixture base ${invalidCase.base}`);
  const mutated = applyMutation(base, invalidCase);
  if (invalidCase.validation === "schema") assertInvalid(validate, mutated, invalidCase.label);
  else {
    assertValid(validate, mutated, `${invalidCase.label} structural precondition`);
    assert.throws(() => assertPlanSemantics(mutated, context), new RegExp(invalidCase.error, "i"));
  }
}

console.log("PASS: reconciliation contracts preserve ownership, CAS, retirement, rollback, and audit safety");
