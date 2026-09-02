// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const DEFAULT_THRESHOLD_MS = 3 * 60 * 60 * 1000;
const MAX_TRACKED_SESSIONS = 64;

function eventFrom(input) {
  return input?.event || input || {};
}

function sessionIDFrom(event) {
  return event.properties?.sessionID || event.properties?.info?.sessionID || event.properties?.info?.id || "";
}

function unwrap(response) {
  return response?.data ?? response;
}

function capMap(map) {
  while (map.size > MAX_TRACKED_SESSIONS) map.delete(map.keys().next().value);
}

function rememberSession(sessions, info, now) {
  if (!info?.id) return null;
  const previous = sessions.get(info.id);
  const observedCreatedAt = Number(info.time?.created);
  const createdAt = Number.isFinite(observedCreatedAt) ? observedCreatedAt : previous?.createdAt ?? now();
  const state = {
    createdAt,
    root: previous?.root ?? !info.parentID,
  };
  sessions.set(info.id, state);
  capMap(sessions);
  return state;
}

async function resolveSessionState({ client, event, now, sessions, sessionID }) {
  const eventInfo = event.properties?.info;
  if (eventInfo?.id === sessionID) return rememberSession(sessions, eventInfo, now);
  const known = sessions.get(sessionID);
  if (known) return known;
  try {
    const info = unwrap(await client?.session?.get?.({ path: { id: sessionID } }));
    return rememberSession(sessions, info, now);
  } catch {
    return null;
  }
}

function advisoryBody() {
  return {
    title: "Session checkpoint",
    message: "This interactive session has run for 3+ hours. At this safe pause, preserve a concise continuation checkpoint with active task IDs, worktree and branch, PRs, blockers, and the exact next action, then consider /new. Active work continues unless you choose to start fresh.",
    variant: "info",
    duration: 15000,
  };
}

/** Emit one long-session suggestion at a verified interactive root idle boundary. */
export function createSessionBoundaryAdvisory({
  client,
  isHeadless = () => false,
  now = () => Date.now(),
  thresholdMs = DEFAULT_THRESHOLD_MS,
  hasCompetingToast = () => false,
} = {}) {
  const sessions = new Map();
  const emitted = new Set();

  const maybeEmitAdvisory = async (event, sessionID) => {
    if (event.type !== "session.idle" || emitted.has(sessionID) || hasCompetingToast(sessionID)) return;
    const state = await resolveSessionState({ client, event, now, sessions, sessionID });
    if (!state?.root || now() - state.createdAt < thresholdMs) return;

    await client?.tui?.showToast?.({ body: advisoryBody() });
    emitted.add(sessionID);
  };

  return async function sessionBoundaryAdvisory(input) {
    if (isHeadless()) return;
    const event = eventFrom(input);
    const sessionID = sessionIDFrom(event);
    if (!sessionID) return;

    if (event.type === "session.deleted") {
      sessions.delete(sessionID);
      emitted.delete(sessionID);
    } else if (["session.created", "session.updated"].includes(event.type)) {
      rememberSession(sessions, event.properties?.info, now);
    } else {
      await maybeEmitAdvisory(event, sessionID);
    }
  };
}

export { DEFAULT_THRESHOLD_MS };
