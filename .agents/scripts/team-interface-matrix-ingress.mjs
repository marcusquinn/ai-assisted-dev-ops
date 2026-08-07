// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {requireValid, validatorsFor} from "./team-interface-validators.mjs";

const MAX_EXTERNAL_ID_LENGTH = 1024;
const MAX_PREFIX_LENGTH = 100;
const MAX_PROMPT_LENGTH = 100000;
const MAX_ROOM_MAPPINGS = 1000;
const MAX_ALLOWED_USERS = 1000;

function ignored(reason) {
  return Object.freeze({reason, status: "ignored"});
}

function boundedString(value, maxLength, allowEmpty = false) {
  return typeof value === "string"
    && value.length <= maxLength
    && (allowEmpty || value.length > 0);
}

function hashId(prefix, namespace, value) {
  const valueHash = createHash("sha256").update(`${namespace}\0${value}`, "utf8").digest("hex");
  return `${prefix}.${valueHash}`;
}

function normalizedHomeserver(value) {
  if (!boundedString(value, 2048)) return null;
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) return null;
  parsed.hash = "";
  parsed.search = "";
  return parsed.toString().replace(/\/$/u, "");
}

function allowedPolicy(config, sender) {
  if (config.allowedUsers === undefined || config.allowedUsers === "") {
    return {allowed: true, policy: "open"};
  }
  if (!boundedString(config.allowedUsers, 64 * 1024)) return {allowed: false, policy: "invalid"};
  const users = config.allowedUsers.split(",").map((entry) => entry.trim());
  if (users.length > MAX_ALLOWED_USERS || users.some((entry) => !boundedString(entry, MAX_EXTERNAL_ID_LENGTH))) {
    return {allowed: false, policy: "invalid"};
  }
  return {allowed: users.includes(sender), policy: "allowlist"};
}

function selectedRunner(config, roomId) {
  const mappings = config.roomMappings ?? {};
  if (!mappings || typeof mappings !== "object" || Array.isArray(mappings)) return null;
  if (Object.keys(mappings).length > MAX_ROOM_MAPPINGS) return null;
  const mapped = Object.hasOwn(mappings, roomId) ? mappings[roomId] : config.defaultRunner;
  return boundedString(mapped, 255) ? mapped : null;
}

function occurredAt(event) {
  if (!Number.isSafeInteger(event.origin_server_ts) || event.origin_server_ts < 0) return null;
  const value = new Date(event.origin_server_ts);
  return Number.isNaN(value.getTime()) ? null : value.toISOString();
}

function configuredPromptLimit(config) {
  const configured = config.maxPromptLength;
  if (configured === undefined) return 4000;
  if (!Number.isSafeInteger(configured) || configured < 1 || configured > MAX_PROMPT_LENGTH) return null;
  return configured;
}

function normalizedEnvelope(input, state) {
  const communityId = hashId("community.matrix", "matrix-community", state.homeserver);
  const actorId = hashId("subject.matrix", "matrix-actor", input.event.sender);
  const conversationSeed = `${input.roomId}\0${input.event.sender}`;
  const providerEventSeed = `${state.homeserver}\0${input.event.event_id}`;
  const conversationId = hashId("conversation.matrix", "matrix-conversation", conversationSeed);
  const eventId = hashId("event.matrix", "matrix-event", providerEventSeed);
  const correlationId = hashId("correlation.matrix", "matrix-correlation", providerEventSeed);
  const idempotencyKey = hashId("idempotency.matrix", "matrix-idempotency", providerEventSeed);
  const runnerRef = hashId("runtime.matrix.runner", "matrix-runner", state.runnerName);
  const explicitAllowlist = state.policy === "allowlist";
  return {
    actorId,
    conversationId,
    eventKey: idempotencyKey,
    envelope: {
      schema_version: 1,
      document_type: "event",
      event: {
        event_id: eventId,
        direction: "inbox",
        provider_id: "matrix",
        provider_version: "client-v3-unprobed",
        lineage: {
          community_id: communityId,
          conversation_resource_id: conversationId,
          provider_event_id: input.event.event_id,
        },
        verified_actor: {
          subject_id: actorId,
          subject_type: "human",
          roles: [explicitAllowlist ? "matrix_allowed_user" : "matrix_legacy_user"],
          verification: {
            status: "verified",
            method: "provider_session",
            evidence_ref: "evidence:matrix-provider-session",
          },
          signature_status: "not_present",
        },
        target: {
          agent_ref: runnerRef,
          app_team_ref: "app-team:matrix-legacy-dispatch",
        },
        content: {
          content_type: "text/plain",
          text: state.prompt,
          attachments: [],
          metadata: {},
        },
        requested_operation: "receive",
        authority_scope: {
          scopes: ["matrix.runner.dispatch"],
          broker_decision_ref: explicitAllowlist
            ? "authority:matrix-legacy-allowlist"
            : "authority:matrix-legacy-open-policy",
        },
        trust_profile_ref: explicitAllowlist
          ? "trust:matrix-legacy-allowlist"
          : "trust:matrix-legacy-open-policy",
        scan_verdict_ref: "scan:matrix-text-not-performed",
        correlation_id: correlationId,
        idempotency_key: idempotencyKey,
        occurred_at: state.occurredAt,
      },
    },
  };
}

function inputRejection(input) {
  let reason = null;
  if (!input || typeof input !== "object") {
    reason = "invalid_input";
  } else {
    const {botUserId, config, event, roomId} = input;
    if (!config || typeof config !== "object" || Array.isArray(config)) reason = "invalid_config";
    else if (!event || typeof event !== "object" || Array.isArray(event)) reason = "invalid_event";
    else if (!boundedString(roomId, MAX_EXTERNAL_ID_LENGTH)
      || !boundedString(event.sender, MAX_EXTERNAL_ID_LENGTH)) reason = "invalid_identity";
    else if (config.ignoreOwnMessages && event.sender === botUserId) reason = "own_message";
    else if (!event.content || event.content.msgtype !== "m.text") reason = "non_text";
    else if (!boundedString(event.event_id, MAX_EXTERNAL_ID_LENGTH)) reason = "invalid_event_id";
  }
  return reason;
}

function promptState(config, event) {
  const body = event.content.body ?? "";
  const prefix = config.botPrefix ?? "!ai";
  let prompt = "";
  let reason = null;
  if (!boundedString(event.content.body ?? "", MAX_PROMPT_LENGTH + MAX_PREFIX_LENGTH, true)) {
    reason = "invalid_body";
  } else if (!boundedString(prefix, MAX_PREFIX_LENGTH)) {
    reason = "invalid_config";
  } else if (!body.startsWith(prefix)) {
    reason = "wrong_prefix";
  } else {
    prompt = body.slice(prefix.length).trim();
    const promptLimit = configuredPromptLimit(config);
    if (!prompt) reason = "empty_prompt";
    else if (promptLimit === null) reason = "invalid_config";
    else if (prompt.length > promptLimit) reason = "prompt_too_long";
  }
  return reason ? {reason} : {prompt};
}

function routingState(config, event, roomId) {
  const permission = allowedPolicy(config, event.sender);
  const runnerName = selectedRunner(config, roomId);
  const homeserver = normalizedHomeserver(config.homeserverUrl);
  const eventTime = occurredAt(event);
  let reason = null;
  if (permission.policy === "invalid") reason = "invalid_config";
  else if (!permission.allowed) reason = "unauthorized";
  else if (!runnerName) reason = "unmapped_room";
  else if (!homeserver) reason = "invalid_config";
  else if (!eventTime) reason = "invalid_timestamp";
  return reason ? {reason} : {eventTime, homeserver, permission, runnerName};
}

export function normalizeMatrixIngress(input, options = {}) {
  const rejected = inputRejection(input);
  if (rejected) return ignored(rejected);
  const {config, event, roomId} = input;
  const prompt = promptState(config, event);
  if (prompt.reason) return ignored(prompt.reason);
  const routing = routingState(config, event, roomId);
  if (routing.reason) return ignored(routing.reason);

  const normalized = normalizedEnvelope(input, {
    homeserver: routing.homeserver,
    occurredAt: routing.eventTime,
    policy: routing.permission.policy,
    prompt: prompt.prompt,
    runnerName: routing.runnerName,
  });
  const validators = validatorsFor(options.validators);
  requireValid(validators.event, normalized.envelope, "Matrix normalized event");
  return Object.freeze({
    ...normalized,
    prompt: prompt.prompt,
    runnerName: routing.runnerName,
    status: "accepted",
  });
}
