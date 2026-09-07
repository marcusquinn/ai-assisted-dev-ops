// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { chmodSync, lstatSync, unlinkSync } from "node:fs";
import { createServer } from "node:net";
import { dirname, isAbsolute, join } from "node:path";

export const sourceContextInstanceId = randomBytes(16).toString("hex");
export const SOURCE_CONTEXT_QUERY = "aidevops-source-context-query/v1";
export const SOURCE_CONTEXT_REPLY = "aidevops-source-context-reply/v1";
const MAX_QUERY_BYTES = 8192;

function validQuery(query) {
  return query?.schema === SOURCE_CONTEXT_QUERY
    && /^[a-f0-9]{64}$/.test(query.nonce)
    && /^ses_[A-Za-z0-9._:-]{2,252}$/.test(query.session_id)
    && typeof query.repo_root === "string" && isAbsolute(query.repo_root)
    && !/[\u0000-\u001f\u007f]/.test(query.repo_root);
}

/**
 * Metadata, NOT authority. Admission additionally needs kernel peer identity,
 * the exact proposal and human consent; grant consumers must bind this runtime
 * instance. An arbitrary live PID or caller-authored JSON is not session proof.
 * Callbacks run in the unprivileged runtime, never in the root signing broker.
 */
export function createSourceContextResponder({ lookupSession, verifyOwner, sameRepository }) {
  if (![lookupSession, verifyOwner, sameRepository].every((value) => typeof value === "function")) {
    throw new Error("source context requires runtime and worktree verifiers");
  }
  return async (query, signal) => {
    if (!validQuery(query) || signal?.aborted) throw new Error("invalid source context query");
    const session = await lookupSession(query.session_id, signal);
    if (session?.id !== query.session_id || !Number.isSafeInteger(session.time?.created)
      || session.time.created < 0 || session.time.archived != null
      || typeof session.directory !== "string" || typeof session.projectID !== "string"
      || !session.projectID || session.projectID.length > 256) {
      throw new Error("source context session is unavailable");
    }
    if (await sameRepository(session.directory, query.repo_root, signal) !== true
      || await verifyOwner(query.repo_root, query.session_id, signal) !== true
      || signal?.aborted) {
      throw new Error("source context worktree ownership is unavailable");
    }
    return {
      schema: SOURCE_CONTEXT_REPLY, nonce: query.nonce, authority: "none",
      session_id: session.id, session_created_at: session.time.created,
      project_id: session.projectID, repo_root: query.repo_root,
      runtime_instance_id: sourceContextInstanceId, runtime_pid: process.pid,
      uid: process.getuid(),
    };
  };
}

function privateSocketDirectory(directory) {
  if (!isAbsolute(directory) || process.getuid() === 0) return false;
  let current = directory;
  while (true) {
    const metadata = lstatSync(current);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) return false;
    if (current === directory && (metadata.uid !== process.getuid() || (metadata.mode & 0o077))) {
      return false;
    }
    const parent = dirname(current);
    if (parent === current) return true;
    current = parent;
  }
}

function acceptContextQuery(connection, respond, state) {
  const { connections } = state;
  if (connections.size >= 8 || state.pending >= 8) return connection.destroy();
  connections.add(connection);
  const controller = new AbortController();
  let input = Buffer.alloc(0);
  let started = false;
  const deadline = setTimeout(() => connection.destroy(), 5000);
  deadline.unref();
  connection.on("error", () => connection.destroy());
  connection.once("close", () => {
    clearTimeout(deadline);
    controller.abort();
    connections.delete(connection);
  });
  connection.on("data", (chunk) => {
    if (started) return connection.destroy();
    input = Buffer.concat([input, chunk]);
    if (input.length > MAX_QUERY_BYTES) return connection.destroy();
    if (!input.includes(10)) return;
    started = true;
    let query;
    try {
      query = JSON.parse(input.toString("utf8"));
    } catch {
      connection.destroy();
      return;
    }
    if (state.pending >= 8) return connection.destroy();
    state.pending++;
    Promise.resolve().then(() => respond(query, controller.signal)).then((reply) => {
      if (!connection.destroyed) connection.end(`${JSON.stringify(reply)}\n`);
    }).catch(() => {
      // Never forward SDK errors, titles, messages, credentials or source bytes.
      if (!connection.destroyed) connection.end('{"error":"context unavailable"}\n');
    }).finally(() => {
      state.pending--;
    });
  });
}

/** Opt-in transport primitive; importing this module starts no listener. */
export async function listenSourceContext({ directory, respond }) {
  if (typeof respond !== "function" || !privateSocketDirectory(directory)) {
    throw new Error("source context requires an existing private user directory");
  }
  const socketPath = join(directory, `${process.pid}-${randomBytes(8).toString("hex")}.sock`);
  if (Buffer.byteLength(socketPath) >= 104) throw new Error("source context socket path is too long");
  const state = { connections: new Set(), pending: 0 };
  const server = createServer((connection) => acceptContextQuery(connection, respond, state));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  let identity;
  try {
    chmodSync(socketPath, 0o600);
    identity = lstatSync(socketPath);
  } catch {
    server.close();
    throw new Error("source context listener setup failed");
  }
  server.unref();
  let closed = false;
  return {
    socketPath,
    close() {
      if (closed) return;
      closed = true;
      for (const connection of state.connections) connection.destroy();
      server.close();
      try {
        const current = lstatSync(socketPath);
        if (current.isSocket() && current.dev === identity.dev && current.ino === identity.ino) {
          unlinkSync(socketPath);
        }
      } catch {
        // Node also cleans up its reserved endpoint; tolerate its prior removal.
      }
    },
  };
}
