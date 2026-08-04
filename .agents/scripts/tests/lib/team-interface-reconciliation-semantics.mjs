// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {
  assertUniquePaths,
  canonicalPlanHash,
  snapshotDigest,
} from "./team-interface-reconciliation-fixtures.mjs";

export function assertInputPolicy(input, policy) {
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

export function assertPlanSemantics(plan, context, applyAt = plan.created_at, checkHash = true) {
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

export function recordOperation(registry, document) {
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

export function assertReceiptSemantics(receipt) {
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

export function assertRollbackSemantics(rollback, context, applyAt = rollback.created_at) {
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
