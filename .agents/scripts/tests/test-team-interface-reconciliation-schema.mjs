// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const schemaDirectory = path.join(testDirectory, "../../schemas/team-interface");
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");

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

function assertInvalid(validate, document, label) {
  assert.equal(validate(document), false, `${label} unexpectedly validated`);
}

function documentId(document) {
  return document.receipt_id || document.plan_id || document.input_id || document.policy_id;
}

function decodePointerSegment(segment) {
  return segment.replaceAll("~1", "/").replaceAll("~0", "~");
}

function applyMutation(document, invalidCase) {
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

function canonicalPlanHash(plan) {
  const payload = structuredClone(plan);
  delete payload.plan_hash;
  return `sha256:${crypto.createHash("sha256").update(stableStringify(payload)).digest("hex")}`;
}

function assertUniquePaths(records, label) {
  const paths = records.map(({field_path: fieldPath}) => fieldPath);
  assert.equal(new Set(paths).size, paths.length, `${label} contains duplicate field paths`);
}

function snapshotDigest(snapshot) {
  return snapshot.present ? snapshot.digest : null;
}

function assertInputPolicy(input, policy) {
  assertUniquePaths(input.fields, `${input.input_id} input`);
  assert.equal(input.policy_ref, `policy:${policy.policy_id}`, "input policy reference mismatch");
  assert.equal(input.policy_version, policy.policy_version, "input policy version mismatch");
  const rules = new Map(policy.field_rules.map((rule) => [rule.field_path, rule]));
  for (const field of input.fields) {
    const rule = rules.get(field.field_path);
    if (field.ownership === "unknown") {
      assert.equal(rule, undefined, "unknown ownership cannot override an explicit policy rule");
      continue;
    }
    assert.ok(rule, `known field ${field.field_path} is absent from the ownership policy`);
    assert.equal(field.ownership, rule.ownership, `ownership mismatch for ${field.field_path}`);
    assert.equal(field.sensitive, rule.sensitive, `sensitivity mismatch for ${field.field_path}`);
  }
}

function assertDecisionEvidence(plan, input) {
  assertUniquePaths(plan.field_decisions, `${plan.plan_id} decisions`);
  const inputFields = new Map(input.fields.map((field) => [field.field_path, field]));
  assert.deepEqual(
    plan.field_decisions.map(({field_path: fieldPath}) => fieldPath).sort(),
    input.fields.map(({field_path: fieldPath}) => fieldPath).sort(),
    "every observed input field must have exactly one decision",
  );
  for (const decision of plan.field_decisions) {
    const field = inputFields.get(decision.field_path);
    assert.ok(field, `decision ${decision.field_path} is absent from source input`);
    assert.equal(decision.ownership, field.ownership, `decision ownership mismatch for ${decision.field_path}`);
    assert.equal(decision.desired_digest, snapshotDigest(field.desired), `desired digest mismatch for ${decision.field_path}`);
    assert.equal(
      decision.last_applied_digest,
      snapshotDigest(field.last_applied),
      `last-applied digest mismatch for ${decision.field_path}`,
    );
    assert.equal(decision.actual_digest, snapshotDigest(field.actual), `actual digest mismatch for ${decision.field_path}`);
    assert.equal(
      decision.actual_matches_last_applied,
      decision.actual_digest === decision.last_applied_digest,
      `derived equality mismatch for ${decision.field_path} actual/last-applied`,
    );
    assert.equal(
      decision.desired_matches_actual,
      decision.desired_digest === decision.actual_digest,
      `derived equality mismatch for ${decision.field_path} desired/actual`,
    );
    if (decision.drift_evidence) {
      assert.equal(decision.drift_evidence.last_applied_digest, decision.last_applied_digest);
      assert.equal(decision.drift_evidence.actual_digest, decision.actual_digest);
    }
  }
}

function assertPlanSemantics(plan, context, applyAt = plan.created_at, checkHash = true) {
  assert.equal(
    plan.precondition.expected_revision,
    plan.precondition.observed_revision,
    "expected revision must equal the freshly observed revision",
  );
  assert.ok(Date.parse(plan.expires_at) > Date.parse(applyAt), "expired plan cannot be applied");
  assert.ok(Date.parse(plan.created_at) >= Date.parse(plan.precondition.observed_at), "plan predates observation");
  assert.ok(Date.parse(plan.created_at) >= Date.parse(plan.capabilities.observed_at), "plan predates capability evidence");
  assert.ok(Date.parse(plan.capabilities.expires_at) > Date.parse(applyAt), "capability evidence is stale at apply time");

  const input = context.inputById.get(plan.source_input_id);
  assert.ok(input, "source input must exist");
  for (const [planKey, resourceKey = planKey] of [
    ["resource_id"],
    ["provider_id"],
    ["community_id"],
    ["provider_external_id"],
  ]) {
    assert.equal(plan[planKey], input.resource[resourceKey], `source input identity mismatch for ${planKey}`);
  }
  assert.equal(plan.policy_ref, input.policy_ref, "plan policy reference mismatch");
  assert.equal(plan.policy_version, input.policy_version, "plan policy version mismatch");
  assert.equal(plan.adapter_version, input.adapter_version, "plan adapter version mismatch");
  assert.equal(plan.precondition.observation_hash, input.observation_hash, "plan observation hash mismatch");
  assert.equal(plan.precondition.observed_at, input.observed_at, "plan observation time mismatch");

  const mutating = plan.document_type === "rollback_plan"
    || ["create", "update", "disable", "retire", "rollback"].includes(plan.outcome);
  if (mutating) {
    for (const capability of ["stable_external_ids", "managed_metadata", "supported_apply", "revision_cas"]) {
      assert.equal(plan.capabilities[capability], true, `mutating plan lacks ${capability}`);
    }
    assert.equal(plan.capabilities.compatibility, "compatible", "mutating plan has incompatible capabilities");
    assert.equal(input.resource.management_identity_status, "verified", "mutating plan source is unmanaged");
    assert.equal(plan.management_binding.status, "verified", "mutating plan lacks verified management identity");
    assert.equal(plan.management_binding.management_owner, input.resource.management_owner, "management owner mismatch");
    assert.equal(plan.management_binding.manager_marker, input.resource.manager_marker, "manager marker mismatch");
  }

  if (plan.field_decisions) assertDecisionEvidence(plan, input);
  if (checkHash) assert.equal(plan.plan_hash, canonicalPlanHash(plan), "plan hash does not cover canonical payload");
}

function recordOperation(registry, document) {
  const recordedHash = registry.operationHashes.get(document.operation_id);
  if (recordedHash && recordedHash !== document.plan_hash) {
    throw new Error("operation ID reused with a different plan hash");
  }
  const idempotencyHash = registry.idempotencyHashes.get(document.idempotency_key);
  if (idempotencyHash && idempotencyHash !== document.plan_hash) {
    throw new Error("idempotency key reused with a different plan hash");
  }
  registry.operationHashes.set(document.operation_id, document.plan_hash);
  registry.idempotencyHashes.set(document.idempotency_key, document.plan_hash);
}

function assertReceiptSemantics(receipt) {
  assertUniquePaths(receipt.field_outcomes, `${receipt.receipt_id} outcomes`);
  const effects = receipt.field_outcomes.map(({effect}) => effect);
  if (["partial", "indeterminate"].includes(receipt.state)) {
    assert.ok(effects.includes("unknown"), `${receipt.state} receipt lacks an unknown effect`);
  }
  if (receipt.state === "published") {
    assert.equal(effects.some((effect) => ["unknown", "not_applied"].includes(effect)), false);
  }
  if (["retryable", "terminal", "conflict"].includes(receipt.state)) {
    assert.ok(effects.every((effect) => effect === "not_applied"), `${receipt.state} receipt claims a side effect`);
  }
}

function assertRollbackSemantics(rollback, context, applyAt = rollback.created_at) {
  assertPlanSemantics(rollback, context, applyAt, false);
  const {receiptByReference} = context;
  const receipt = receiptByReference.get(rollback.receipt_binding.receipt_ref);
  assert.ok(receipt, "rollback receipt must exist");
  assert.equal(receipt.state, "published", "rollback receipt must be verified successful");
  assert.equal(
    rollback.receipt_binding.source_plan_hash,
    receipt.plan_hash,
    "rollback receipt plan hash must match the verified receipt",
  );
  assert.equal(
    rollback.precondition.expected_revision,
    receipt.after_revision,
    "rollback expected revision must bind the receipt after revision",
  );
  for (const identityKey of ["resource_id", "provider_id", "community_id"]) {
    assert.equal(rollback[identityKey], receipt[identityKey], `rollback receipt identity mismatch for ${identityKey}`);
  }
  const input = context.inputById.get(rollback.source_input_id);
  const inputFields = new Map(input.fields.map((field) => [field.field_path, field]));
  const receiptFields = new Map(receipt.field_outcomes.map((field) => [field.field_path, field]));
  const policyRules = new Map(context.policy.field_rules.map((rule) => [rule.field_path, rule]));
  assertUniquePaths(rollback.restore_fields, `${rollback.plan_id} restore fields`);
  for (const field of rollback.restore_fields) {
    assert.equal(field.ownership, "managed", "rollback may restore only managed fields");
    assert.equal(policyRules.get(field.field_path)?.ownership, "managed", "rollback field is not managed by current policy");
    const receiptField = receiptFields.get(field.field_path);
    assert.ok(receiptField, `rollback field ${field.field_path} is absent from receipt`);
    assert.equal(field.receipt_after_digest, receiptField.after_digest, "rollback field receipt digest mismatch");
    assert.equal(field.restore_digest, receiptField.before_digest, "rollback restore digest mismatch");
    assert.equal(snapshotDigest(inputFields.get(field.field_path).actual), receiptField.after_digest, "rollback actual state drifted");
  }
  assert.equal(rollback.plan_hash, canonicalPlanHash(rollback), "plan hash does not cover canonical payload");
}

function collectEnumValues(value, result = []) {
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

function assertNoSecretValueProperties(value, location = "<root>") {
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
