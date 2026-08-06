// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {createBuzzAdapter} from "../team-interface-buzz-adapter.mjs";
import {createAdapterRegistry} from "../team-interface-adapters.mjs";
import {createRuntimeValidators} from "../team-interface-validators.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");
const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || path.join(os.homedir(), ".aidevops/.agent-workspace/tmp");

function copyPrivate(source, destination) {
  fs.copyFileSync(source, destination);
  fs.chmodSync(destination, 0o600);
}

function context(signal = new AbortController().signal) {
  return Object.freeze({runtime: Object.freeze({abort_signal: signal, read_only: true})});
}

function capability(observation, suffix) {
  return observation.capabilities.find(({capability_id: id}) => id.includes(suffix));
}

fs.mkdirSync(temporaryParent, {mode: 0o700, recursive: true});
const sandbox = fs.mkdtempSync(path.join(temporaryParent, "team-interface-buzz-"));
try {
  const app = path.join(sandbox, "Buzz.app");
  const data = path.join(sandbox, "data");
  const agents = path.join(data, "managed-agents.json");
  const teams = path.join(data, "teams.json");
  const infoPlist = path.join(app, "Contents/Info.plist");
  const webkit = path.join(sandbox, "WebsiteData");
  fs.mkdirSync(path.dirname(infoPlist), {mode: 0o700, recursive: true});
  fs.mkdirSync(data, {mode: 0o700, recursive: true});
  fs.mkdirSync(webkit, {mode: 0o700, recursive: true});
  fs.writeFileSync(infoPlist, "fixture metadata", {mode: 0o600});
  copyPrivate(path.join(fixtureDirectory, "buzz-managed-agents.json"), agents);
  copyPrivate(path.join(fixtureDirectory, "buzz-teams.json"), teams);

  let versionReads = 0;
  let communityReads = 0;
  let processChecks = 0;
  const dependencies = {
    platform: "darwin",
    paths: {app, agents, infoPlist, teams, webkit},
    now: () => "2026-08-06T10:00:00Z",
    async readVersion(_paths, signal) {
      assert.equal(signal.aborted, false);
      versionReads += 1;
      return "0.5.5";
    },
    async readCommunities(_paths, signal) {
      assert.equal(signal.aborted, false);
      communityReads += 1;
      return [{
        id: "community-primary",
        name: "Primary Community",
        relayUrl: "wss://relay.example.test",
        token: "community-token-private-canary",
        nsec: "community-nsec-private-canary",
        reposDir: "/private/fixture/repos-canary",
      }];
    },
    isProcessAlive(pid) {
      processChecks += 1;
      return pid === 4242;
    },
  };
  const adapter = createBuzzAdapter(dependencies);
  assert.deepEqual(Object.keys(adapter).sort(), [
    "adapter_id", "adapter_version", "capabilities", "detect", "provider_id", "status",
  ]);
  createAdapterRegistry([adapter]);

  const beforeAgents = fs.readFileSync(agents);
  const beforeTeams = fs.readFileSync(teams);
  const beforeAgentTime = fs.statSync(agents).mtimeMs;
  const detected = await adapter.detect(context());
  const status = await adapter.status(context());
  assert.deepEqual(status, detected, "status and detect must use the same read-only projection");
  assert.equal(versionReads, 2);
  assert.equal(communityReads, 2);
  assert.equal(processChecks, 4);
  assert.deepEqual(fs.readFileSync(agents), beforeAgents);
  assert.deepEqual(fs.readFileSync(teams), beforeTeams);
  assert.equal(fs.statSync(agents).mtimeMs, beforeAgentTime);

  const validators = createRuntimeValidators();
  assert.equal(validators.adapterObservation(detected), true, JSON.stringify(validators.adapterObservation.errors));
  assert.equal(detected.availability, "available");
  assert.equal(detected.compatibility.state, "compatible");
  assert.equal(detected.provider_version, "0.5.5");
  assert.deepEqual(detected.inventory.communities.map(({display_label: label}) => label), ["Primary Community"]);
  assert.deepEqual(detected.inventory.agents.map(({agent_kind: kind}) => kind).sort(), [
    "definition", "instance", "instance",
  ]);
  assert.equal(detected.inventory.runtimes.length, 1, "only referenced runtime identities are observed");
  const active = detected.inventory.agents.find(({display_label: label}) => label === "Builder");
  const definition = detected.inventory.agents.find(({agent_kind: kind}) => kind === "definition");
  const stopped = detected.inventory.agents.find(({display_label: label}) => label === "Stopped Instance");
  const alpha = detected.inventory.teams.find(({display_label: label}) => label === "Alpha Team");
  assert.equal(active.availability, "available");
  assert.equal(stopped.availability, "unavailable");
  assert.equal(definition.is_builtin, true);
  assert.equal(active.community_ref, detected.inventory.communities[0].community_id);
  assert.equal(active.team_ref, alpha.team_id);
  assert.deepEqual(alpha.member_refs, [active.agent_id], "persona IDs must not be treated as deployed members");

  const serialized = JSON.stringify(detected);
  for (const forbidden of [
    "aaaaaaaaaaaaaaaa", "relay.example.test", "private-canary", "fixture/", "settings:",
    "nsec-", "auth-", "model-private", "provider-private", "prompt-", "error-", "instructions-",
  ]) assert.equal(serialized.includes(forbidden), false, `${forbidden} escaped the projection`);

  const unknownVersion = createBuzzAdapter({...dependencies, readVersion: async () => "0.6.0"});
  const unknown = await unknownVersion.detect(context());
  assert.equal(unknown.compatibility.state, "unknown");
  assert.equal(unknown.availability, "available");

  let unsupportedRead = false;
  const unsupported = createBuzzAdapter({
    ...dependencies,
    platform: "linux",
    readVersion: async () => {
      unsupportedRead = true;
      throw new Error("must not read unsupported platform");
    },
  });
  const unsupportedObservation = await unsupported.detect(context());
  assert.equal(unsupportedObservation.availability, "unavailable");
  assert.equal(unsupportedRead, false);
  assert.deepEqual(unsupportedObservation.inventory, {communities: [], agents: [], teams: [], runtimes: []});

  const absentApp = createBuzzAdapter({...dependencies, paths: {...dependencies.paths, app: path.join(sandbox, "missing")}});
  assert.equal((await absentApp.detect(context())).availability, "unavailable");

  const missingStores = createBuzzAdapter({
    ...dependencies,
    paths: {
      ...dependencies.paths,
      agents: path.join(data, "missing-agents.json"),
      teams: path.join(data, "missing-teams.json"),
    },
    readCommunities: async () => null,
  });
  const missing = await missingStores.detect(context());
  assert.equal(missing.availability, "degraded");
  assert.equal(capability(missing, "communities").availability, "unavailable");
  assert.deepEqual(missing.inventory, {communities: [], agents: [], teams: [], runtimes: []});

  const malformedPath = path.join(data, "malformed-agents.json");
  fs.writeFileSync(malformedPath, "{not json", {mode: 0o600});
  const malformed = await createBuzzAdapter({
    ...dependencies,
    paths: {...dependencies.paths, agents: malformedPath},
  }).detect(context());
  assert.equal(capability(malformed, "agents").availability, "degraded");
  assert.deepEqual(malformed.inventory.agents, []);

  const oversizedPath = path.join(data, "oversized-agents.json");
  fs.writeFileSync(oversizedPath, `["${"x".repeat(4 * 1024 * 1024)}"]`, {mode: 0o600});
  const oversized = await createBuzzAdapter({
    ...dependencies,
    paths: {...dependencies.paths, agents: oversizedPath},
  }).detect(context());
  assert.equal(capability(oversized, "agents").availability, "degraded");

  const symlinkPath = path.join(data, "linked-agents.json");
  fs.symlinkSync(agents, symlinkPath);
  const symlinked = await createBuzzAdapter({
    ...dependencies,
    paths: {...dependencies.paths, agents: symlinkPath},
  }).detect(context());
  assert.equal(capability(symlinked, "agents").availability, "degraded");

  const abortController = new AbortController();
  const aborting = createBuzzAdapter({
    ...dependencies,
    readAgents(signal) {
      return new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), {once: true});
        setImmediate(() => resolve([]));
      });
    },
  });
  abortController.abort();
  await assert.rejects(aborting.detect(context(abortController.signal)), {name: "AbortError"});

  const renamedCommunities = createBuzzAdapter({
    ...dependencies,
    readCommunities: async () => [{
      id: "community-primary",
      name: "Renamed Label",
      relayUrl: "wss://relay.example.test",
    }],
  });
  const renamed = await renamedCommunities.detect(context());
  assert.equal(renamed.inventory.communities[0].community_id, detected.inventory.communities[0].community_id);
  assert.equal(renamed.inventory.communities[0].display_label, "Renamed Label");

  console.log("PASS: Buzz team-interface adapter is deterministic, read-only, and redacted");
} finally {
  fs.rmSync(sandbox, {force: true, recursive: true});
}
