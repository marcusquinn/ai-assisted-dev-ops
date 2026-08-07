// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {normalizeMatrixIngress} from "../team-interface-matrix-ingress.mjs";
import {createRuntimeValidators} from "../team-interface-validators.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");

function readJson(filename) {
  return JSON.parse(fs.readFileSync(path.join(fixtureDirectory, filename), "utf8"));
}

function normalize(config, fixtures, event = fixtures.accepted, roomId = fixtures.room_id) {
  return normalizeMatrixIngress({
    botUserId: fixtures.bot_user_id,
    config,
    event,
    roomId,
  });
}

const config = readJson("matrix-config.json");
const fixtures = readJson("matrix-events.json");
const validators = createRuntimeValidators();
const accepted = normalize(config, fixtures);

assert.equal(accepted.status, "accepted");
assert.equal(accepted.prompt, "Review the fixture safely");
assert.equal(accepted.runnerName, "runner-beta-canary");
assert.equal(validators.event(accepted.envelope), true, JSON.stringify(validators.event.errors));
assert.equal(accepted.envelope.event.lineage.provider_event_id, fixtures.accepted.event_id);
assert.equal(accepted.envelope.event.verified_actor.roles[0], "matrix_allowed_user");
assert.equal(accepted.envelope.event.authority_scope.broker_decision_ref, "authority:matrix-legacy-allowlist");
assert.deepEqual(normalize(config, fixtures), accepted, "event replay must normalize byte-for-byte");

const renamed = structuredClone(fixtures.accepted);
renamed.content.displayname = "A DIFFERENT SPOOFED NAME";
const renamedResult = normalize(config, fixtures, renamed);
assert.equal(renamedResult.actorId, accepted.actorId);
assert.equal(renamedResult.conversationId, accepted.conversationId);

const otherRoom = normalize(config, fixtures, fixtures.accepted, "!room-other:fixture.invalid");
assert.equal(otherRoom.status, "accepted");
assert.equal(otherRoom.runnerName, "runner-alpha-canary");
assert.equal(otherRoom.actorId, accepted.actorId);
assert.notEqual(otherRoom.conversationId, accepted.conversationId);

const otherActor = structuredClone(fixtures.accepted);
otherActor.sender = "@second:fixture.invalid";
const openConfig = {...structuredClone(config), allowedUsers: ""};
const openResult = normalize(openConfig, fixtures, otherActor);
assert.equal(openResult.status, "accepted");
assert.notEqual(openResult.actorId, accepted.actorId);
assert.notEqual(openResult.conversationId, accepted.conversationId);
assert.equal(openResult.envelope.event.verified_actor.roles[0], "matrix_legacy_user");
assert.equal(openResult.envelope.event.trust_profile_ref, "trust:matrix-legacy-open-policy");

const otherEvent = structuredClone(fixtures.accepted);
otherEvent.event_id = "$event-beta:fixture.invalid";
const otherEventResult = normalize(config, fixtures, otherEvent);
assert.notEqual(otherEventResult.envelope.event.event_id, accepted.envelope.event.event_id);
assert.notEqual(otherEventResult.eventKey, accepted.eventKey);
assert.notEqual(otherEventResult.envelope.event.correlation_id, accepted.envelope.event.correlation_id);

for (const [reason, event] of Object.entries(fixtures.ignored)) {
  const result = normalize(config, fixtures, event);
  assert.deepEqual(result, {reason, status: "ignored"}, reason);
}

const unmappedConfig = {...structuredClone(config), defaultRunner: "", roomMappings: {}};
assert.deepEqual(normalize(unmappedConfig, fixtures), {reason: "unmapped_room", status: "ignored"});
const oversizedConfig = {...structuredClone(config), maxPromptLength: 4};
assert.deepEqual(normalize(oversizedConfig, fixtures), {reason: "prompt_too_long", status: "ignored"});
const invalidTimestamp = {...structuredClone(fixtures.accepted), origin_server_ts: "now"};
assert.deepEqual(normalize(config, fixtures, invalidTimestamp), {reason: "invalid_timestamp", status: "ignored"});

const serialized = JSON.stringify(accepted.envelope);
for (const forbidden of [
  fixtures.room_id,
  fixtures.accepted.sender,
  config.homeserverUrl,
  config.defaultRunner,
  config.roomMappings[fixtures.room_id],
  fixtures.accepted.content.displayname,
  config.accessToken,
  config.privatePathCanary,
  config.diagnosticCanary,
]) assert.equal(serialized.includes(forbidden), false, `${forbidden} escaped normalized evidence`);

console.log("team-interface Matrix ingress tests passed");
