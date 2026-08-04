// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const schemaDirectory = path.join(testDirectory, "../../schemas/team-interface");
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");
const requiredSurfaceCategories = [
  "managed_agent_apis",
  "acp_runtime",
  "teams_reconciliation",
  "workflows_approval",
  "project_repository_nip",
  "runners_relay_mesh",
  "release_install_packaging",
];
const requiredDedupScopes = [
  "missions",
  "todos",
  "open_closed_issues",
  "open_closed_prs",
  "verified_merged_fixes",
  "local_records",
];

function readJson(fileName) {
  return JSON.parse(fs.readFileSync(path.join(fixtureDirectory, fileName), "utf8"));
}

function formatErrors(errors) {
  return (errors || [])
    .map((error) => `${error.instancePath || "<root>"} ${error.keyword}: ${error.message}`)
    .join("\n");
}

function assertSchemaValid(validate, document, label) {
  assert.equal(validate(document), true, `${label} failed schema validation:\n${formatErrors(validate.errors)}`);
}

function claimUnique(claims, value, label) {
  assert.equal(claims.has(value), false, `duplicate ${label}: ${value}`);
  claims.add(value);
}

function assertSorted(values, label) {
  assert.deepEqual(values, [...values].sort(), `${label} must be sorted`);
}

function driftKey(components) {
  const input = [
    components.source_id,
    components.adapter_id,
    components.reviewed_from_commit,
    components.observed_to_commit,
    components.normalized_diff_digest,
    [...components.sorted_surface_ids].sort().join(","),
  ].join("\n");
  return `sha256:${createHash("sha256").update(input).digest("hex")}`;
}

function indexUnique(items, idProperty, label) {
  const ids = new Set();
  const indexed = new Map();
  for (const item of items) {
    claimUnique(ids, item[idProperty], label);
    indexed.set(item[idProperty], item);
  }
  return indexed;
}

function validateProfileSemantics(profile) {
  const surfaces = indexUnique(profile.watched_surfaces, "surface_id", "surface ID");
  const fixtures = indexUnique(profile.fixture_suite.fixtures, "fixture_id", "fixture ID");
  assert.deepEqual(
    [...new Set(profile.watched_surfaces.map(({category}) => category))].sort(),
    [...requiredSurfaceCategories].sort(),
    "Buzz profile must map every canonical watched-surface family",
  );

  for (const surface of surfaces.values()) {
    assert.ok(surface.path_patterns.length > 0 || surface.named_symbols.length > 0, `${surface.surface_id} has an empty path+symbol set`);
    for (const fixtureId of surface.fixture_ids) {
      assert.ok(fixtures.has(fixtureId), `${surface.surface_id} references unknown fixture ${fixtureId}`);
    }
  }

  for (const baseline of [profile.reviewed_baseline, profile.last_known_good_baseline]) {
    assert.equal(baseline.source.source_id, profile.source_id, "reviewed baseline source must match profile source");
  }
  assert.equal(profile.last_checked.source.source_id, profile.source_id, "last_checked source must match profile source");
  assert.equal(profile.reviewed_baseline.source.commit_id.length >= 40, true, "reviewed identity must be a full immutable commit");
  assert.equal(profile.last_known_good_baseline.source.commit_id.length >= 40, true, "last-known-good identity must be full");
}

function assertLifecyclePrerequisites(record, assessment) {
  assert.equal(record.state_history[0], "detected", `${record.record_id} must begin at detected`);
  assert.equal(record.state_history.at(-1), record.current_state, `${record.record_id} current state must close state history`);
  if (record.current_state !== "detected") {
    assert.ok(record.state_history.includes("bounded"), `${record.record_id} skipped bounded evidence`);
  }
  if (["premise_verified", "fixtures_terminal", "no_action", "decision_required", "actionable", "resolved"].includes(record.current_state)) {
    assert.ok(record.state_history.includes("premise_verified"), `${record.record_id} skipped premise verification`);
    assert.equal(assessment.premise.terminal, true, `${record.record_id} premise is not terminal`);
  }
  if (["fixtures_terminal", "no_action", "actionable", "resolved"].includes(record.current_state)) {
    assert.ok(record.state_history.includes("fixtures_terminal"), `${record.record_id} skipped terminal fixtures`);
    assert.equal(assessment.fixtures_terminal, true, `${record.record_id} fixtures are not terminal`);
  }
}

function assertBaselineDecision(assessment, observation) {
  const fixtureStates = assessment.fixture_results.map(({state}) => state);
  const hasPending = fixtureStates.some((state) => ["not_run", "pending"].includes(state));
  const hasFailure = fixtureStates.some((state) => ["failed", "error"].includes(state));
  const unknown = assessment.classification === "unknown_review" || assessment.premise.state === "unknown";

  if (hasPending || hasFailure || unknown) {
    assert.notEqual(
      assessment.baseline_decision,
      "promote_reviewed_and_last_known_good",
      "pending, failed, error, or unknown evidence cannot promote last_known_good",
    );
  }
  if (assessment.baseline_decision === "promote_reviewed_and_last_known_good") {
    assert.equal(assessment.fixtures_terminal, true, "baseline promotion requires terminal fixtures");
    assert.ok(assessment.fixture_results.every(({state}) => state === "passed"), "baseline promotion requires supported passing fixtures");
    assert.equal(assessment.premise.terminal, true, "baseline promotion requires terminal premise evidence");
    assert.equal(
      assessment.resulting_baseline.source.commit_id,
      observation.to_source.commit_id,
      "promoted baseline must match the observed immutable source",
    );
  }
}

function validateLifecycleSemantics(lifecycle, profile) {
  assert.equal(lifecycle.profile_ref, profile.profile_id, "lifecycle profile reference must resolve");
  const surfaces = new Set(profile.watched_surfaces.map(({surface_id: id}) => id));
  const fixtures = new Set(profile.fixture_suite.fixtures.map(({fixture_id: id}) => id));
  const observations = indexUnique(lifecycle.observations, "observation_id", "observation ID");
  const assessments = indexUnique(lifecycle.assessments, "assessment_id", "assessment ID");
  indexUnique(lifecycle.records, "record_id", "drift record ID");

  for (const observation of observations.values()) {
    assert.equal(observation.profile_ref, profile.profile_id, `${observation.observation_id} profile reference must resolve`);
    assert.equal(observation.from_source.source_id, profile.source_id, `${observation.observation_id} from source mismatch`);
    assert.equal(observation.to_source.source_id, profile.source_id, `${observation.observation_id} to source mismatch`);
    for (const surfaceId of observation.touched_surface_ids) {
      assert.ok(surfaces.has(surfaceId), `${observation.observation_id} is outside declared watch set: ${surfaceId}`);
    }
    assert.match(observation.untrusted_text_digest, /^sha256:/, "untrusted source text requires a digest");
    assert.ok(observation.prompt_scan_verdict_ref, "untrusted source text requires prompt-scan evidence before model classification");
  }

  for (const assessment of assessments.values()) {
    assert.ok(observations.has(assessment.observation_ref), `${assessment.assessment_id} observation reference must resolve`);
    assert.equal(
      assessment.fixtures_terminal,
      assessment.fixture_results.every(({terminal}) => terminal),
      `${assessment.assessment_id} fixture terminality mismatch`,
    );
    for (const result of assessment.fixture_results) {
      assert.ok(fixtures.has(result.fixture_id), `${assessment.assessment_id} references unknown fixture ${result.fixture_id}`);
      if (["not_run", "pending"].includes(result.state)) {
        assert.equal(result.terminal, false, `${result.state} is not a failure or terminal result`);
      }
    }
  }

  const seenDriftKeys = new Map();
  for (const record of lifecycle.records) {
    const observation = observations.get(record.observation_ref);
    const assessment = assessments.get(record.assessment_ref);
    assert.ok(observation, `${record.record_id} observation reference must resolve`);
    assert.ok(assessment, `${record.record_id} assessment reference must resolve`);
    assert.equal(assessment.observation_ref, observation.observation_id, `${record.record_id} assessment/observation mismatch`);
    assertLifecyclePrerequisites(record, assessment);
    assertBaselineDecision(assessment, observation);

    const components = record.dedup.components;
    assertSorted(components.sorted_surface_ids, `${record.record_id} sorted watched-surface set`);
    assert.deepEqual(
      components.sorted_surface_ids,
      [...observation.touched_surface_ids].sort(),
      `${record.record_id} dedup surfaces must equal bounded observation surfaces`,
    );
    assert.equal(components.source_id, observation.to_source.source_id, `${record.record_id} dedup source mismatch`);
    assert.equal(components.adapter_id, profile.adapter_id, `${record.record_id} dedup adapter mismatch`);
    assert.equal(components.reviewed_from_commit, observation.from_source.commit_id, `${record.record_id} dedup from-ref mismatch`);
    assert.equal(components.observed_to_commit, observation.to_source.commit_id, `${record.record_id} dedup to-ref mismatch`);
    assert.equal(components.normalized_diff_digest, observation.normalized_diff_digest, `${record.record_id} diff digest mismatch`);
    assert.equal(record.dedup.drift_key, driftKey(components), `${record.record_id} unstable drift key`);
    assert.deepEqual([...record.dedup.search.scopes].sort(), [...requiredDedupScopes].sort(), `${record.record_id} incomplete dedup search`);

    const priorRecord = seenDriftKeys.get(record.dedup.drift_key);
    assert.equal(priorRecord, undefined, `${record.record_id} duplicates concurrent lifecycle ${priorRecord}`);
    seenDriftKeys.set(record.dedup.drift_key, record.record_id);

    if (record.implementation_issue_ref) {
      assert.ok(["actionable", "resolved"].includes(record.current_state), `${record.record_id} publishes before actionable evidence`);
      assert.equal(assessment.premise.state, "confirmed", `${record.record_id} issue requires a confirmed premise`);
      assert.equal(assessment.fixtures_terminal, true, `${record.record_id} issue requires terminal fixtures`);
      assert.ok(record.actionability.local_files.length > 0, `${record.record_id} worker-ready files are unknown`);
      assert.ok(record.actionability.local_tests.length > 0, `${record.record_id} worker-ready tests are unknown`);
      assert.deepEqual(record.dedup.follow_up_refs, [record.implementation_issue_ref], `${record.record_id} must publish one canonical follow-up`);
    }
    if (record.current_state === "actionable") {
      assert.equal(record.dedup.verified_merged_fix_ref, undefined, `${record.record_id} recreated after a verified merged fix`);
      assert.ok(!["no_impact", "unknown_review"].includes(assessment.classification), `${record.record_id} classification is not actionable`);
    }
    if (record.dedup.verified_merged_fix_ref) {
      assert.equal(record.current_state, "resolved", `${record.record_id} merged fix prevents recreation`);
    }
  }
}

function setAtPath(target, dottedPath, value) {
  const segments = dottedPath.split(".");
  const finalSegment = segments.pop();
  let cursor = target;
  for (const segment of segments) cursor = cursor[Number.isInteger(Number(segment)) ? Number(segment) : segment];
  cursor[Number.isInteger(Number(finalSegment)) ? Number(finalSegment) : finalSegment] = value;
}

function deleteAtPath(target, dottedPath) {
  const segments = dottedPath.split(".");
  const finalSegment = segments.pop();
  let cursor = target;
  for (const segment of segments) cursor = cursor[Number.isInteger(Number(segment)) ? Number(segment) : segment];
  delete cursor[finalSegment];
}

function resolveMutationTarget(document, operation) {
  if (operation.target === "document") return document;
  const collections = {
    surface: [document.watched_surfaces, "surface_id"],
    observation: [document.observations, "observation_id"],
    assessment: [document.assessments, "assessment_id"],
    record: [document.records, "record_id"],
  };
  const [items, idProperty] = collections[operation.target] || [];
  assert.ok(items, `unknown mutation target ${operation.target}`);
  const target = items.find((item) => item[idProperty] === operation.id);
  assert.ok(target, `missing mutation target ${operation.target}:${operation.id}`);
  return target;
}

function applyInvalidCase(baseDocument, invalidCase) {
  const document = structuredClone(baseDocument);
  for (const operation of invalidCase.operations) {
    const target = resolveMutationTarget(document, operation);
    if (operation.op === "delete") deleteAtPath(target, operation.path);
    else setAtPath(target, operation.path, structuredClone(operation.value));
  }
  return document;
}

const coreSchema = JSON.parse(fs.readFileSync(path.join(schemaDirectory, "core-v1.schema.json"), "utf8"));
const compatibilitySchema = JSON.parse(fs.readFileSync(path.join(schemaDirectory, "compatibility-v1.schema.json"), "utf8"));
assert.equal(compatibilitySchema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(compatibilitySchema.$id, "urn:aidevops:team-interface:compatibility:v1");

const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
ajv.addSchema(coreSchema);
const validate = ajv.compile(compatibilitySchema);

const validProfile = readJson("compatibility-valid-profile.json");
const validLifecycle = readJson("compatibility-valid-drift-lifecycle.json");
assertSchemaValid(validate, validProfile, "valid Buzz profile");
assertSchemaValid(validate, validLifecycle, "valid drift lifecycle");
validateProfileSemantics(validProfile);
validateLifecycleSemantics(validLifecycle, validProfile);

const standaloneObservation = {
  ...structuredClone(validLifecycle.observations[0]),
  schema_version: 1,
  document_type: "source_observation",
};
const standaloneAssessment = {
  ...structuredClone(validLifecycle.assessments[0]),
  schema_version: 1,
  document_type: "compatibility_assessment",
};
assertSchemaValid(validate, standaloneObservation, "standalone source observation");
assertSchemaValid(validate, standaloneAssessment, "standalone compatibility assessment");

for (const fixtureName of ["compatibility-invalid-premature-issue.json", "compatibility-invalid-baseline.json"]) {
  for (const invalidCase of readJson(fixtureName).cases) {
    const document = applyInvalidCase(validLifecycle, invalidCase);
    assert.throws(
      () => {
        assertSchemaValid(validate, document, invalidCase.name);
        validateLifecycleSemantics(document, validProfile);
      },
      undefined,
      `${fixtureName}: ${invalidCase.name} unexpectedly passed lifecycle invariants`,
    );
  }
}

for (const invalidCase of readJson("compatibility-invalid-dedup-watch.json").cases) {
  const baseDocument = invalidCase.document === "profile" ? validProfile : validLifecycle;
  const document = applyInvalidCase(baseDocument, invalidCase);
  assert.throws(
    () => {
      assertSchemaValid(validate, document, invalidCase.name);
      if (invalidCase.document === "profile") validateProfileSemantics(document);
      else validateLifecycleSemantics(document, validProfile);
    },
    undefined,
    `invalid-dedup-watch: ${invalidCase.name} unexpectedly passed schema and semantic invariants`,
  );
}

const pendingAssessment = validLifecycle.assessments.find(({assessment_id: id}) => id === "assessment:buzz:feature-opportunity");
assert.equal(pendingAssessment.fixture_results[0].state, "pending");
assert.equal(pendingAssessment.fixture_results[0].terminal, false, "pending fixtures are never terminal failures");
const failedAssessment = validLifecycle.assessments.find(({assessment_id: id}) => id === "assessment:buzz:breaking");
assert.equal(failedAssessment.baseline_decision, "retain_last_known_good", "failed fixtures preserve the prior last_known_good baseline");

console.log("PASS: compatibility schema enforces bounded drift, terminal actionability, baseline, and dedup contracts");
