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

const universalControls = [
  "signature_provenance",
  "schema",
  "size_type_path",
  "correlation",
  "idempotency",
  "output_secret",
];
const highRiskCapabilities = [
  "administrator",
  "secret_access",
  "destructive",
  "billing",
  "publication",
  "release",
];
const cacheKeyFields = [
  "content_digest",
  "attachment_digests",
  "provider_id",
  "provenance_class",
  "trust_profile_id",
  "scanner_engine",
  "scanner_version",
  "policy_version",
  "requested_capability_class",
];

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

function isSorted(values) {
  return values.every((value, index) => index === 0 || values[index - 1] <= value);
}

function allTrue(...conditions) {
  return conditions.every(Boolean);
}

function cacheKeyMatches(storedKey, candidateKey) {
  if (!isSorted(storedKey.attachment_digests) || !isSorted(candidateKey.attachment_digests)) return false;
  if (!cacheKeyFields.every((field) => Object.hasOwn(storedKey, field) && Object.hasOwn(candidateKey, field))) return false;
  return cacheKeyFields.every((field) => JSON.stringify(storedKey[field]) === JSON.stringify(candidateKey[field]));
}

function authorityAllows(decision, policy) {
  const requested = decision.requested_capability_class;
  const actorRoles = new Set(decision.verified_actor.roles);
  const profile = policy.profiles.find((candidate) => candidate.profile_id === decision.trust_profile_id);
  const policyRef = `${policy.policy_id}:v${policy.policy_version}`;
  const configured = decision.configured_grants.some(
    (grant) => {
      const policyGrant = policy.role_grants.find((candidate) => candidate.role_id === grant.role_id);
      if (!policyGrant) return false;
      return allTrue(
        actorRoles.has(grant.role_id),
        grant.grant_basis === "configured_role",
        grant.configuration_ref === decision.grant_configuration_ref,
        grant.capability_classes.every((capability) => policyGrant.capability_classes.includes(capability)),
        grant.capability_classes.includes(requested),
      );
    },
  );
  const withinCeiling = profile
    && decision.capability_ceiling.every((capability) => profile.capability_ceiling.includes(capability))
    && decision.capability_ceiling.includes(requested);
  const explicitHighRiskGate = !highRiskCapabilities.includes(requested)
    || decision.explicit_gates.some(
      (gate) => gate.capability_class === requested && gate.authority_ref === policy.gate_authority_ref,
    );
  return allTrue(
    decision.policy_ref === policyRef,
    decision.grant_configuration_ref === policy.grant_configuration_ref,
    configured,
    withinCeiling,
    explicitHighRiskGate,
  );
}

function scanSupportsAllow(verdict, decision) {
  const blockedStatuses = new Set(["not_run", "findings", "quarantined", "error"]);
  if (verdict.result !== "clean" || Object.values(verdict.stages).some((stage) => blockedStatuses.has(stage.status))) {
    return false;
  }
  if (verdict.stages.structural.status !== "clean") return false;
  const elevated = highRiskCapabilities.includes(decision.requested_capability_class);
  const hasAttachments = decision.event_attachment_digests.length > 0;
  const deterministicRequired = decision.trust_profile_id !== "owner-local"
    || decision.provenance_class !== "owner_direct"
    || hasAttachments
    || elevated;
  const semanticRequired = decision.trust_profile_id === "external-bridged"
    || ["forwarded", "external", "unknown"].includes(decision.provenance_class)
    || hasAttachments
    || elevated;
  return (!deterministicRequired || verdict.stages.deterministic.status === "clean")
    && (!semanticRequired || verdict.stages.semantic.status === "clean")
    && (!hasAttachments || verdict.stages.attachment.status === "clean");
}

function decisionEvidenceMatches(decision, verdicts) {
  const verdict = verdicts.get(decision.scan_verdict_ref);
  if (!verdict) return false;
  const key = verdict.verdict_key;
  return allTrue(
    decision.scan_result === verdict.result,
    cacheKeyMatches(key, decision.scan_verdict_key),
    key.provider_id === decision.provider_id,
    key.content_digest === decision.event_content_digest,
    JSON.stringify(key.attachment_digests) === JSON.stringify(decision.event_attachment_digests),
    key.provenance_class === decision.provenance_class,
    key.trust_profile_id === decision.trust_profile_id,
    key.policy_version === decision.policy_version,
    key.requested_capability_class === decision.requested_capability_class,
    decision.configured_grants.every(
      (grant) => grant.configuration_ref === decision.grant_configuration_ref,
    ),
  );
}

function attachmentsSupportDecision(decision) {
  if (decision.decision !== "allow") return true;
  const allAccepted = decision.attachment_decisions.every((attachment) => attachment.outcome === "accept");
  const requiresSandbox = ["shared-member", "external-bridged"].includes(decision.trust_profile_id);
  return allAccepted && (!requiresSandbox
    || decision.attachment_decisions.every((attachment) => attachment.extraction === "sandboxed"));
}

function decisionIsSemanticallyValid(decision, verdicts, policy) {
  if (!decisionEvidenceMatches(decision, verdicts)) return false;
  if (decision.decision !== "allow") return !scanSupportsAllow(verdicts.get(decision.scan_verdict_ref), decision)
    || !authorityAllows(decision, policy)
    || decision.attachment_decisions.some((attachment) => attachment.outcome !== "accept");
  return allTrue(
    decision.provenance_class !== "unknown",
    decision.output_secret_guard.status === "clean",
    authorityAllows(decision, policy),
    scanSupportsAllow(verdicts.get(decision.scan_verdict_ref), decision),
    attachmentsSupportDecision(decision),
  );
}

function applyShallowChange(value, change) {
  return Object.assign(structuredClone(value), structuredClone(change));
}

const coreSchema = readJson(path.join(schemaDirectory, "core-v1.schema.json"));
const trustSchema = readJson(path.join(schemaDirectory, "trust-v1.schema.json"));
assert.equal(trustSchema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(trustSchema.$id, "urn:aidevops:team-interface:trust:v1");

const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
ajv.addSchema(coreSchema);
const validate = ajv.compile(trustSchema);

const policy = readJson(path.join(fixtureDirectory, "trust-policy-defaults.json"));
assertValid(validate, policy, "canonical trust policy");
assert.deepEqual(policy.high_risk_capabilities.slice().sort(), highRiskCapabilities.slice().sort());

const profiles = new Map(policy.profiles.map((profile) => [profile.profile_id, profile]));
assert.deepEqual([...profiles.keys()], ["owner-local", "trusted-team", "shared-member", "external-bridged"]);
for (const profile of profiles.values()) {
  assert.deepEqual(profile.structural_controls.slice().sort(), universalControls.slice().sort());
  assert.equal(profile.attachment_policy.owner_bypass_allowed, false);
  assert.equal(profile.attachment_policy.active_content_allowed, false);
  assert.equal(profile.attachment_policy.sandbox_required_for_extraction, true);
  for (const capability of profile.default_capabilities) {
    assert.ok(profile.capability_ceiling.includes(capability), `${profile.profile_id} default exceeds its ceiling`);
  }
}

const ownerLocal = profiles.get("owner-local");
assert.equal(ownerLocal.deterministic_scan_mode, "conditional");
assert.equal(ownerLocal.semantic_scan_mode, "conditional");
for (const condition of ["suspicious_encoding", "forwarded_content", "external_attachment", "elevated_operation"]) {
  assert.ok(ownerLocal.escalation_conditions.includes(condition), `owner-local omits ${condition}`);
}
assert.ok(highRiskCapabilities.every((capability) => ownerLocal.explicit_gate_capabilities.includes(capability)));

const trustedTeam = profiles.get("trusted-team");
assert.equal(trustedTeam.deterministic_scan_mode, "cached_required");
assert.ok(!trustedTeam.capability_ceiling.some((capability) => highRiskCapabilities.includes(capability)));

const sharedMember = profiles.get("shared-member");
assert.equal(sharedMember.deterministic_scan_mode, "required");
assert.deepEqual(sharedMember.default_capabilities, ["read", "answer", "draft"]);
assert.ok(!sharedMember.capability_ceiling.some((capability) => highRiskCapabilities.includes(capability)));

const externalBridged = profiles.get("external-bridged");
assert.equal(externalBridged.deterministic_scan_mode, "strict");
assert.deepEqual(externalBridged.default_capabilities, ["read", "draft"]);
assert.deepEqual(externalBridged.capability_ceiling, ["read", "draft"]);

const widenedTeamPolicy = structuredClone(policy);
widenedTeamPolicy.profiles[1].capability_ceiling.push("administrator");
assertInvalid(validate, widenedTeamPolicy, "trusted-team high-risk ceiling widening");
const widenedSharedDefaults = structuredClone(policy);
widenedSharedDefaults.profiles[2].default_capabilities.push("non_admin_operation");
assertInvalid(validate, widenedSharedDefaults, "shared-member default widening");
const weakenedAttachmentPolicy = structuredClone(policy);
weakenedAttachmentPolicy.profiles[0].attachment_policy.sandbox_required_for_extraction = false;
assertInvalid(validate, weakenedAttachmentPolicy, "owner-local sandbox weakening");
const weakenedOwnerEscalation = structuredClone(policy);
weakenedOwnerEscalation.profiles[0].escalation_conditions = weakenedOwnerEscalation.profiles[0].escalation_conditions
  .filter((condition) => condition !== "deterministic_findings");
assertInvalid(validate, weakenedOwnerEscalation, "owner-local findings escalation removal");
const weakenedTeamProvenance = structuredClone(policy);
weakenedTeamProvenance.profiles[1].escalation_conditions = weakenedTeamProvenance.profiles[1].escalation_conditions
  .filter((condition) => condition !== "unknown_provenance");
assertInvalid(validate, weakenedTeamProvenance, "trusted-team provenance escalation removal");
const weakenedSharedForwarding = structuredClone(policy);
weakenedSharedForwarding.profiles[2].escalation_conditions = weakenedSharedForwarding.profiles[2].escalation_conditions
  .filter((condition) => condition !== "forwarded_content");
assertInvalid(validate, weakenedSharedForwarding, "shared-member forwarding escalation removal");

const validFixture = readJson(path.join(fixtureDirectory, "trust-valid-decisions.json"));
for (const [index, document] of validFixture.documents.entries()) {
  assertValid(validate, document, `valid trust document ${index}`);
}

const verdicts = new Map(
  validFixture.documents
    .filter((document) => document.document_type === "scan_verdict")
    .map((document) => [document.verdict_id, document]),
);
const decisions = new Map(
  validFixture.documents
    .filter((document) => document.document_type === "ingress_decision")
    .map((document) => [document.decision_id, document]),
);
assert.deepEqual(new Set([...decisions.values()].map((decision) => decision.decision)), new Set(["allow", "deny", "review", "quarantine"]));
for (const decision of decisions.values()) {
  assert.equal(decisionEvidenceMatches(decision, verdicts), true, `${decision.decision_id} has unresolved or stale scan evidence`);
  assert.equal(decisionIsSemanticallyValid(decision, verdicts, policy), true, `${decision.decision_id} violates semantic decision policy`);
}

const allowedDecision = decisions.get("decision.owner.allow");
assert.equal(authorityAllows(allowedDecision, policy), true);
assert.equal(scanSupportsAllow(verdicts.get(allowedDecision.scan_verdict_ref), allowedDecision), true);
const fabricatedPolicyReference = structuredClone(allowedDecision);
fabricatedPolicyReference.policy_ref = "team-interface.trust.fabricated:v1";
assert.equal(authorityAllows(fabricatedPolicyReference, policy), false, "fabricated policy authorized ingress");

const scannerErrorDecision = decisions.get("decision.team.deny");
assert.equal(verdicts.get(scannerErrorDecision.scan_verdict_ref).result, "error");
assert.notEqual(scannerErrorDecision.decision, "allow", "error must resolve to deny, review, or quarantine");

const unknownProvenanceAllow = structuredClone(allowedDecision);
unknownProvenanceAllow.provenance_class = "unknown";
assertInvalid(validate, unknownProvenanceAllow, "unknown provenance allow");

const scannerErrorAllow = structuredClone(scannerErrorDecision);
scannerErrorAllow.decision = "allow";
assertInvalid(validate, scannerErrorAllow, "scanner error allow");
assert.equal(scanSupportsAllow(verdicts.get(scannerErrorAllow.scan_verdict_ref), scannerErrorAllow), false);
assert.equal(decisionIsSemanticallyValid(scannerErrorAllow, verdicts, policy), false);

const unsafeAttachmentAllow = structuredClone(allowedDecision);
unsafeAttachmentAllow.attachment_decisions = [
  structuredClone(decisions.get("decision.external.quarantine").attachment_decisions[0]),
];
assertInvalid(validate, unsafeAttachmentAllow, "unsafe attachment allow");

const baseVerdict = verdicts.get("verdict.owner.clean");
assert.deepEqual(Object.keys(baseVerdict.verdict_key).sort(), cacheKeyFields.slice().sort());
assert.equal(cacheKeyMatches(baseVerdict.verdict_key, structuredClone(baseVerdict.verdict_key)), true);
const keyChanges = {
  content_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  attachment_digests: ["ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"],
  provider_id: "matrix",
  provenance_class: "forwarded",
  trust_profile_id: "trusted-team",
  scanner_engine: "semantic-guard",
  scanner_version: "2.0.0",
  policy_version: 2,
  requested_capability_class: "draft",
};
for (const [field, value] of Object.entries(keyChanges)) {
  const changedKey = structuredClone(baseVerdict.verdict_key);
  changedKey[field] = value;
  assert.equal(cacheKeyMatches(baseVerdict.verdict_key, changedKey), false, `${field} change reused stale verdict`);
  const staleDecision = structuredClone(allowedDecision);
  staleDecision.scan_verdict_key = changedKey;
  assert.equal(decisionIsSemanticallyValid(staleDecision, verdicts, policy), false, `${field} stale key authorized ingress`);
}

const copiedEventVerdict = structuredClone(allowedDecision);
copiedEventVerdict.event_content_digest = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
assert.equal(decisionIsSemanticallyValid(copiedEventVerdict, verdicts, policy), false, "stale verdict authorized another event");

const fabricatedGrantConfiguration = structuredClone(allowedDecision);
fabricatedGrantConfiguration.grant_configuration_ref = "role-config:fabricated:v1";
fabricatedGrantConfiguration.configured_grants[0].configuration_ref = "role-config:fabricated:v1";
assert.equal(authorityAllows(fabricatedGrantConfiguration, policy), false, "fabricated role configuration authorized ingress");

const invalidCache = readJson(path.join(fixtureDirectory, "trust-invalid-cache-key.json"));
for (const invalidCase of invalidCache.cases) {
  const candidateVerdict = structuredClone(baseVerdict);
  if (invalidCase.remove) {
    delete candidateVerdict.verdict_key[invalidCase.remove];
    assertInvalid(validate, candidateVerdict, invalidCase.label);
    continue;
  }
  Object.assign(candidateVerdict.verdict_key, invalidCase.change);
  assertValid(validate, candidateVerdict, `${invalidCase.label} remains a well-formed distinct verdict`);
  assert.equal(cacheKeyMatches(baseVerdict.verdict_key, candidateVerdict.verdict_key), false, invalidCase.label);
}

const invalidAuthority = readJson(path.join(fixtureDirectory, "trust-invalid-authority.json"));
for (const invalidCase of invalidAuthority.cases) {
  let candidate = structuredClone(allowedDecision);
  if (invalidCase.add) {
    candidate = applyShallowChange(candidate, invalidCase.add);
    assertInvalid(
      validate,
      candidate,
      `trust-invalid-authority: ${invalidCase.label}`,
      (errors) => errors.some((error) => error.keyword === "additionalProperties"),
    );
    continue;
  }
  candidate = applyShallowChange(candidate, invalidCase.change);
  assertInvalid(validate, candidate, `trust-invalid-authority: ${invalidCase.label}`);
  assert.equal(authorityAllows(candidate, policy), false, invalidCase.label);
}

const explicitlyGatedAdministrator = applyShallowChange(allowedDecision, {
  requested_capability_class: "administrator",
  capability_ceiling: ["read", "administrator"],
  configured_grants: [{
    role_id: "owner",
    grant_basis: "configured_role",
    configuration_ref: "role-config:team-interface:v1",
    capability_classes: ["read", "administrator"],
  }],
  explicit_gates: [{
    capability_class: "administrator",
    gate_ref: "gate:administrator:approved",
    authority_ref: "authority-broker:team-interface:v1",
  }],
});
const administratorVerdict = structuredClone(baseVerdict);
administratorVerdict.verdict_id = "verdict.owner.administrator.clean";
administratorVerdict.verdict_key.requested_capability_class = "administrator";
administratorVerdict.stages.deterministic = {status: "clean", evidence_refs: ["evidence:scanner:administrator"]};
administratorVerdict.stages.semantic = {status: "clean", evidence_refs: ["evidence:semantic:administrator"]};
explicitlyGatedAdministrator.scan_verdict_ref = administratorVerdict.verdict_id;
explicitlyGatedAdministrator.scan_verdict_key = structuredClone(administratorVerdict.verdict_key);
const verdictsWithAdministrator = new Map(verdicts);
verdictsWithAdministrator.set(administratorVerdict.verdict_id, administratorVerdict);
assertValid(validate, administratorVerdict, "explicitly gated administrator verdict");
assertValid(validate, explicitlyGatedAdministrator, "explicitly gated administrator decision");
assert.equal(authorityAllows(explicitlyGatedAdministrator, policy), true);
assert.equal(scanSupportsAllow(administratorVerdict, explicitlyGatedAdministrator), true);
assert.equal(decisionIsSemanticallyValid(explicitlyGatedAdministrator, verdictsWithAdministrator, policy), true);

const fabricatedGateAuthority = structuredClone(explicitlyGatedAdministrator);
fabricatedGateAuthority.explicit_gates[0].authority_ref = "authority-broker:fabricated:v1";
assert.equal(authorityAllows(fabricatedGateAuthority, policy), false, "fabricated gate authority authorized ingress");

const safeAttachmentDecision = decisions.get("decision.shared.review").attachment_decisions[0];
const invalidAttachments = readJson(path.join(fixtureDirectory, "trust-invalid-attachment.json"));
for (const invalidCase of invalidAttachments.cases) {
  const candidate = structuredClone(decisions.get("decision.shared.review"));
  candidate.attachment_decisions[0] = applyShallowChange(safeAttachmentDecision, invalidCase.change);
  assertInvalid(validate, candidate, `trust-invalid-attachment: ${invalidCase.label}`);
}

console.log("PASS: team-interface trust schema enforces adaptive screening, complete cache keys, and deterministic authority ceilings");
