// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

function snapshotDigest(snapshot) {
  return snapshot.present ? snapshot.digest : null;
}

function driftEvidence(field, requestDigest, index) {
  return {
    actual_digest: snapshotDigest(field.actual),
    evidence_ref: `observation:runtime-${requestDigest.slice(7, 23)}-${index + 1}`,
    last_applied_digest: snapshotDigest(field.last_applied),
    observed_at: field.actual_observed_at,
  };
}

export function fieldDecision(field, request, requestDigest, index) {
  const desiredDigest = snapshotDigest(field.desired);
  const lastAppliedDigest = snapshotDigest(field.last_applied);
  const actualDigest = snapshotDigest(field.actual);
  const actualMatchesLastApplied = actualDigest === lastAppliedDigest;
  const desiredMatchesActual = desiredDigest === actualDigest;
  const decision = {
    actual_digest: actualDigest,
    actual_matches_last_applied: actualMatchesLastApplied,
    desired_digest: desiredDigest,
    desired_matches_actual: desiredMatchesActual,
    field_path: field.field_path,
    last_applied_digest: lastAppliedDigest,
    ownership: field.ownership,
  };
  if (field.ownership === "user_owned") return {...decision, decision: "preserve_actual", reason: "user_owned"};
  if (field.ownership === "unknown") {
    return {
      ...decision,
      decision: "review_required",
      drift_evidence: driftEvidence(field, requestDigest, index),
      reason: "unmanaged_resource",
    };
  }
  if (!actualMatchesLastApplied) {
    const securityRequired = field.ownership === "security_required";
    return {
      ...decision,
      decision: securityRequired ? request.security_drift_action : "preserve_actual",
      drift_evidence: driftEvidence(field, requestDigest, index),
      reason: securityRequired ? "security_drift" : "user_modified",
    };
  }
  if (desiredMatchesActual) return {...decision, decision: "no_change", reason: "already_desired"};
  return {...decision, decision: "apply_desired", reason: "managed_unchanged"};
}

function capabilitiesPermitMutation(capabilities) {
  return [
    capabilities.stable_external_ids,
    capabilities.managed_metadata,
    capabilities.supported_apply,
    capabilities.revision_cas,
    capabilities.compatibility === "compatible",
  ].every(Boolean);
}

export function derivePlanOutcome(request, decisions) {
  let outcome = "no_change";
  if (!capabilitiesPermitMutation(request.capabilities)) {
    outcome = request.capabilities.compatibility === "unsupported" ? "unsupported" : "owner_reviewed_draft";
  } else if (request.reconciliation_input.resource.management_identity_status !== "verified") {
    outcome = "review";
  } else if (decisions.some(({decision}) => decision === "disable_execution")) {
    outcome = "disable";
  } else if (decisions.some(({decision}) => decision === "review_required")) {
    outcome = "review";
  } else if (decisions.some(({decision}) => decision === "apply_desired")) {
    outcome = "update";
  }
  return outcome;
}
