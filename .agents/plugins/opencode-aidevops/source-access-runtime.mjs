// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { promisify } from "node:util";
import { sourceGitArguments, sourceGitEnvironment } from "./source-access-git.mjs";
import {
  createSourceContextResponder,
  listenSourceContext,
  prepareSourceContextDirectory,
  SOURCE_CONTEXT_QUERY,
  sourceContextInstanceId,
} from "./source-access-context.mjs";

const run = promisify(execFile);
const SESSION_ID = /^ses_[A-Za-z0-9._:-]{2,252}$/;

function commandEnvironment() {
  // A shell's Git overrides are not the runtime's repository identity.
  return Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !key.startsWith("GIT_") && !["BASH_ENV", "ENV"].includes(key)));
}

async function command(program, args, signal) {
  const environment = commandEnvironment();
  if (program === "/usr/bin/git") args = sourceGitArguments(args);
  const { stdout } = await run(program, args, {
    encoding: "utf8", timeout: 3000, maxBuffer: 256 * 1024,
    env: program === "/usr/bin/git" ? sourceGitEnvironment(environment) : environment, signal,
  });
  return stdout;
}

async function gitPath(root, argument, signal) {
  const value = (await command("/usr/bin/git", ["-C", root, "rev-parse", argument], signal)).trim();
  if (!value) throw new Error("source context repository is unavailable");
  return realpath(resolve(root, value));
}

async function sameRepository(startupDirectory, sessionDirectory, requestedRoot, signal) {
  const root = await realpath(requestedRoot);
  if (root !== requestedRoot || await gitPath(root, "--show-toplevel", signal) !== root) return false;
  const common = await gitPath(root, "--git-common-dir", signal);
  if (await gitPath(root, "--git-dir", signal) === common) return false;
  if (await gitPath(startupDirectory, "--git-common-dir", signal) !== common
    || await gitPath(sessionDirectory, "--git-common-dir", signal) !== common) return false;
  const worktrees = await command("/usr/bin/git", ["-C", startupDirectory,
    "worktree", "list", "--porcelain", "-z"], signal);
  return worktrees.split("\0").includes(`worktree ${root}`);
}

async function abortable(promise, signal) {
  let abort;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      abort = () => reject(new Error("source context lookup cancelled"));
      signal.addEventListener("abort", abort, { once: true });
      if (signal.aborted) abort();
    })]);
  } finally {
    signal.removeEventListener("abort", abort);
  }
}

/** V1 plugin SDK adapter: fresh lookup, not cached events or caller-written state. */
export function createSourceAccessRuntime({ client, directory, scriptsDir, tempDir, enabled = true }) {
  let endpoint;
  let starting;
  let closed = false;
  let pendingLookups = 0;
  const respond = createSourceContextResponder({
    async lookupSession(id, signal) {
      // The /v1 plugin uses SDK get({path:{id}, query:{directory}}). V2 is
      // deliberately unsupported; malformed/error responses never prove life.
      if (closed || pendingLookups >= 8) throw new Error("source context lookup unavailable");
      pendingLookups++;
      const lookup = Promise.resolve().then(() =>
        client.session.get({ path: { id }, query: { directory }, signal }))
        .finally(() => { pendingLookups--; });
      // A defective SDK that ignores cancellation cannot hang a tool or free
      // capacity for unlimited outstanding calls: retain its slot until settled.
      const result = await abortable(lookup, signal);
      if (result?.error || !result?.data) throw new Error("source context session is unavailable");
      return result.data;
    },
    sameRepository: (sessionDirectory, root, signal) =>
      sameRepository(directory, sessionDirectory, root, signal),
    async verifyOwner(root, sessionId, signal) {
      const result = await command(join(scriptsDir, "worktree-helper.sh"),
        ["registry", "verify-owner", root, sessionId], signal);
      return result.trim() === "VERIFIED";
    },
  });

  async function start() {
    if (closed || !enabled) return undefined;
    if (endpoint) return endpoint;
    starting ??= (async () => {
      const listener = await listenSourceContext({
        directory: prepareSourceContextDirectory(tempDir), respond,
      });
      if (closed) {
        listener.close();
        return undefined;
      }
      endpoint = listener;
      process.once("exit", close);
      return listener;
    })();
    try {
      return await starting;
    } finally {
      starting = undefined;
    }
  }

  function close() {
    closed = true;
    endpoint?.close();
    endpoint = undefined;
    process.removeListener("exit", close);
  }

  async function resolveContext(sessionId, repoRoot, signal = AbortSignal.timeout(4000)) {
    if (closed || !enabled) return undefined;
    try {
      const reply = await respond({ schema: SOURCE_CONTEXT_QUERY, nonce: randomBytes(32).toString("hex"),
        session_id: sessionId, repo_root: repoRoot }, signal);
      return closed || signal.aborted ? undefined : reply;
    } catch {
      return undefined;
    }
  }

  return {
    // Shell hints locate the channel; they NEVER supply consumer authority.
    async environment(sessionId) {
      const env = { AIDEVOPS_SOURCE_CONTEXT_SOCKET: "", AIDEVOPS_SOURCE_CONTEXT_INSTANCE: "" };
      if (!SESSION_ID.test(sessionId)) return env;
      try {
        const listener = await start();
        if (listener) {
          env.AIDEVOPS_SOURCE_CONTEXT_SOCKET = listener.socketPath;
          env.AIDEVOPS_SOURCE_CONTEXT_INSTANCE = sourceContextInstanceId;
        }
      } catch {
        // Unsupported/private-directory failures leave only legacy approval usable.
      }
      return env;
    },
    resolve: resolveContext,
    async contexts(sessionId, paths) {
      const contexts = new Map();
      if (closed || !enabled || !Array.isArray(paths) || paths.length > 32) return contexts;
      const signal = AbortSignal.timeout(4000);
      const roots = new Map();
      for (const path of new Set(paths)) {
        if (signal.aborted) break;
        try {
          if (typeof path !== "string" || !isAbsolute(path)) continue;
          const root = await gitPath(dirname(path), "--show-toplevel", signal);
          if (!roots.has(root)) roots.set(root, await resolveContext(sessionId, root, signal));
          contexts.set(resolve(path), roots.get(root));
        } catch {
          // No context for an unavailable path; do not borrow another scope.
        }
      }
      return signal.aborted || closed ? new Map() : contexts;
    },
    handleEvent(input) {
      const event = input?.event;
      if (event?.type === "server.instance.disposed" && event.properties?.directory === directory) close();
    },
    close,
  };
}
