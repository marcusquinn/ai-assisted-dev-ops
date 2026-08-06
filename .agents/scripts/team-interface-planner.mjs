// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {assertUniqueIds, canonicalDigest, compareCanonicalText, requireTimestamp, TeamInterfaceError} from "./team-interface-common.mjs";
import {derivePlanOutcome, fieldDecision} from "./team-interface-plan-decisions.mjs";
import {requireValid, validatorsFor} from "./team-interface-validators.mjs";

const DEFAULT_MAX_PLAN_FIELDS = 500;

function normalizedPlanRequest(request) {
  const normalized = structuredClone(request);
  normalized.reconciliation_input.fields.sort((left, right) => compareCanonicalText(left.field_path, right.field_path));
  normalized.capabilities.evidence_refs.sort(compareCanonicalText);
  normalized.audit.evidence_refs.sort(compareCanonicalText);
  return normalized;
}

function assertManagedBaselines(fields) {
  for (const field of fields) {
    if (["managed", "security_required"].includes(field.ownership) && !field.last_applied.present) {
      throw new TeamInterfaceError("missing_last_applied", "managed fields require a present last-applied snapshot");
    }
  }
}

function assertPrecondition(request) {
  const input = request.reconciliation_input;
  if (request.precondition.expected_revision !== request.precondition.observed_revision) {
    throw new TeamInterfaceError("invalid_precondition", "expected revision must equal observed revision");
  }
  if (request.precondition.observation_hash !== input.observation_hash || request.precondition.observed_at !== input.observed_at) {
    throw new TeamInterfaceError("invalid_precondition", "plan precondition does not bind the reconciliation input");
  }
}

function assertEvidenceTimes(request) {
  const input = request.reconciliation_input;
  const createdAt = requireTimestamp(request.created_at, "plan creation time");
  const expiresAt = requireTimestamp(request.expires_at, "plan expiry");
  const observedAt = requireTimestamp(input.observed_at, "input observation time");
  const capabilityObservedAt = requireTimestamp(request.capabilities.observed_at, "capability observation time");
  const capabilityExpiresAt = requireTimestamp(request.capabilities.expires_at, "capability expiry");
  const auditRecordedAt = requireTimestamp(request.audit.recorded_at, "audit record time");
  if (expiresAt <= createdAt) throw new TeamInterfaceError("invalid_timestamp", "plan expiry must follow creation");
  if (createdAt < observedAt || createdAt < capabilityObservedAt) {
    throw new TeamInterfaceError("invalid_timestamp", "plan creation predates required evidence");
  }
  if (auditRecordedAt > createdAt) throw new TeamInterfaceError("invalid_timestamp", "audit record postdates plan creation");
  for (const field of input.fields) {
    if (requireTimestamp(field.actual_observed_at, "field observation time") > createdAt) {
      throw new TeamInterfaceError("invalid_timestamp", "field observation postdates plan creation");
    }
  }
  if (capabilityExpiresAt < expiresAt) {
    throw new TeamInterfaceError("stale_capability", "capability evidence does not cover the plan lifetime");
  }
}

function assertPlanRequestSemantics(request, maxPlanFields) {
  const fields = request.reconciliation_input.fields;
  assertUniqueIds(fields, "field_path", "reconciliation input");
  if (fields.length > maxPlanFields) throw new TeamInterfaceError("plan_too_large", "plan request has too many fields");
  assertManagedBaselines(fields);
  assertPrecondition(request);
  assertEvidenceTimes(request);
}

function assertFieldPolicy(field, rule) {
  if (field.ownership === "unknown") {
    if (rule) throw new TeamInterfaceError("policy_mismatch", "unknown field overrides a configured ownership rule");
    return;
  }
  if (!rule || rule.ownership !== field.ownership || rule.sensitive !== field.sensitive) {
    throw new TeamInterfaceError("policy_mismatch", "reconciliation field does not match configured ownership policy");
  }
}

export function assertInputPolicy(input, policy, resourceKind) {
  if (input.policy_ref !== `policy:${policy.policy_id}` || input.policy_version !== policy.policy_version) {
    throw new TeamInterfaceError("policy_mismatch", "reconciliation input does not bind the configured ownership policy");
  }
  if (resourceKind && policy.resource_kind !== resourceKind) {
    throw new TeamInterfaceError("policy_mismatch", "configured ownership policy does not match the registered resource kind");
  }
  assertUniqueIds(policy.field_rules, "field_path", "ownership policy");
  const rules = new Map(policy.field_rules.map((rule) => [rule.field_path, rule]));
  for (const field of input.fields) {
    assertFieldPolicy(field, rules.get(field.field_path));
  }
  const observedPaths = new Set(input.fields.map(({field_path: fieldPath}) => fieldPath));
  if (policy.field_rules.some(({field_path: fieldPath}) => !observedPaths.has(fieldPath))) {
    throw new TeamInterfaceError("policy_mismatch", "reconciliation input omits a configured ownership field");
  }
}

export function assertInputRegistry(input, registry) {
  assertUniqueIds(registry.resources, "resource_id", "provider registry resources");
  const resource = registry.resources.find(({resource_id: resourceId}) => resourceId === input.resource.resource_id);
  if (!resource) throw new TeamInterfaceError("registry_mismatch", "reconciliation resource is not registered");
  for (const property of ["provider_id", "community_id", "provider_external_id"]) {
    if (input.resource[property] !== resource[property]) {
      throw new TeamInterfaceError("registry_mismatch", `reconciliation resource does not match registered ${property}`);
    }
  }
  if (
    input.resource.management_identity_status === "verified"
    && input.resource.management_owner !== resource.management_owner
  ) {
    throw new TeamInterfaceError("registry_mismatch", "reconciliation management owner does not match the provider registry");
  }
  return resource;
}

export function generatePlan(planRequest, options = {}) {
  const validators = validatorsFor(options.validators);
  if (!options.policy || !options.registry) {
    throw new TeamInterfaceError("missing_planner_context", "planner requires configured policy and provider registry documents");
  }
  requireValid(validators.planRequest, planRequest, "team-interface plan request");
  requireValid(validators.ownershipPolicy, options.policy, "configured ownership policy");
  requireValid(validators.registry, options.registry, "configured provider registry");
  const request = normalizedPlanRequest(planRequest);
  assertPlanRequestSemantics(request, options.maxPlanFields || DEFAULT_MAX_PLAN_FIELDS);
  const resource = assertInputRegistry(request.reconciliation_input, options.registry);
  assertInputPolicy(request.reconciliation_input, options.policy, resource.kind);
  const requestDigest = canonicalDigest(request);
  const digestHex = requestDigest.slice(7);
  const input = request.reconciliation_input;
  const decisions = input.fields.map((field, index) => fieldDecision(field, request, requestDigest, index));
  const outcome = derivePlanOutcome(request, decisions);
  const plan = {
    adapter_version: input.adapter_version,
    audit: structuredClone(request.audit),
    authorization_ref: request.authorization_ref,
    capabilities: structuredClone(request.capabilities),
    community_id: input.resource.community_id,
    correlation_id: `correlation.runtime.${digestHex}`,
    created_at: request.created_at,
    desired_version: request.desired_version,
    document_type: "reconciliation_plan",
    expires_at: request.expires_at,
    field_decisions: decisions,
    idempotency_key: `idempotency.runtime.${digestHex}`,
    operation_id: `operation.runtime.${digestHex}`,
    outcome,
    plan_id: `plan.runtime.${digestHex}`,
    policy_ref: input.policy_ref,
    policy_version: input.policy_version,
    precondition: structuredClone(request.precondition),
    provider_external_id: input.resource.provider_external_id,
    provider_id: input.resource.provider_id,
    resource_id: input.resource.resource_id,
    schema_version: 1,
    source_input_id: input.input_id,
    verified_actor_ref: request.verified_actor_ref,
  };
  if (["create", "update", "disable", "retire", "rollback"].includes(outcome)) {
    plan.management_binding = {
      management_owner: input.resource.management_owner,
      manager_marker: input.resource.manager_marker,
      status: "verified",
    };
  }
  plan.plan_hash = canonicalDigest(plan);
  requireValid(validators.plan, plan, "generated reconciliation plan");
  return plan;
}
