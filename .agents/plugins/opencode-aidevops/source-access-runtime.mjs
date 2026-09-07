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
  isUnprivilegedSourceRuntime,
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

class SourceAccessRuntime {
  #config;
  #respond;
  #endpoint;
  #starting;
  #closed = false;
  #pendingLookups = 0;
  #onExit = () => this.close();

  constructor({ enabled = true, ...config }) {
    this.#config = { ...config, enabled: Boolean(enabled && isUnprivilegedSourceRuntime()) };
    this.#respond = createSourceContextResponder({
      lookupSession: (id, signal) => this.#lookupSession(id, signal),
      sameRepository: (sessionDirectory, root, signal) =>
        sameRepository(this.#config.directory, sessionDirectory, root, signal),
      verifyOwner: (root, sessionId, signal) => this.#verifyOwner(root, sessionId, signal),
    });
  }

  async #lookupSession(id, signal) {
    // The /v1 plugin uses SDK get({path:{id}, query:{directory}}). V2 is
    // deliberately unsupported; malformed/error responses never prove life.
    if (this.#closed || this.#pendingLookups >= 8) throw new Error("source context lookup unavailable");
    this.#pendingLookups++;
    const { client, directory } = this.#config;
    const lookup = Promise.resolve().then(() => client.session.get({ path: { id }, query: { directory }, signal }))
      .finally(() => { this.#pendingLookups--; });
    // Keep a defective SDK's slot occupied until it actually settles, even
    // when cancellation releases the caller; outstanding work stays bounded.
    const result = await abortable(lookup, signal);
    if (result?.error || !result?.data) throw new Error("source context session is unavailable");
    return result.data;
  }

  async #verifyOwner(root, sessionId, signal) {
    const result = await command(join(this.#config.scriptsDir, "worktree-helper.sh"),
      ["registry", "verify-owner", root, sessionId], signal);
    return result.trim() === "VERIFIED";
  }

  async #start() {
    if (this.#closed || !this.#config.enabled) return undefined;
    if (this.#endpoint) return this.#endpoint;
    this.#starting ??= this.#bindListener();
    try {
      return await this.#starting;
    } finally {
      this.#starting = undefined;
    }
  }

  async #bindListener() {
    const listener = await listenSourceContext({
      directory: prepareSourceContextDirectory(this.#config.tempDir), respond: this.#respond,
    });
    if (this.#closed) {
      listener.close();
      return undefined;
    }
    this.#endpoint = listener;
    process.once("exit", this.#onExit);
    return listener;
  }

  close() {
    this.#closed = true;
    this.#endpoint?.close();
    this.#endpoint = undefined;
    process.removeListener("exit", this.#onExit);
  }

  async resolve(sessionId, repoRoot, signal = AbortSignal.timeout(4000)) {
    if (this.#closed || !this.#config.enabled) return undefined;
    try {
      const reply = await this.#respond({ schema: SOURCE_CONTEXT_QUERY, nonce: randomBytes(32).toString("hex"),
        session_id: sessionId, repo_root: repoRoot }, signal);
      return this.#closed || signal.aborted ? undefined : reply;
    } catch {
      return undefined;
    }
  }

  // Shell hints locate the channel; they NEVER supply consumer authority.
  async environment(sessionId) {
    const env = { AIDEVOPS_SOURCE_CONTEXT_SOCKET: "", AIDEVOPS_SOURCE_CONTEXT_INSTANCE: "" };
    if (!SESSION_ID.test(sessionId)) return env;
    try {
      const listener = await this.#start();
      if (listener) {
        env.AIDEVOPS_SOURCE_CONTEXT_SOCKET = listener.socketPath;
        env.AIDEVOPS_SOURCE_CONTEXT_INSTANCE = sourceContextInstanceId;
      }
    } catch {
      // Unsupported/private-directory failures leave only legacy approval usable.
    }
    return env;
  }

  async contexts(sessionId, paths) {
    const contexts = new Map();
    if (this.#closed || !this.#config.enabled || !Array.isArray(paths) || paths.length > 32) return contexts;
    const signal = AbortSignal.timeout(4000);
    const roots = new Map();
    for (const path of new Set(paths)) {
      if (signal.aborted) break;
      try {
        if (typeof path !== "string" || !isAbsolute(path)) continue;
        const root = await gitPath(dirname(path), "--show-toplevel", signal);
        if (!roots.has(root)) roots.set(root, await this.resolve(sessionId, root, signal));
        contexts.set(resolve(path), roots.get(root));
      } catch {
        // No context for an unavailable path; do not borrow another scope.
      }
    }
    return signal.aborted || this.#closed ? new Map() : contexts;
  }

  handleEvent(input) {
    const event = input?.event;
    if (event?.type === "server.instance.disposed" && event.properties?.directory === this.#config.directory) this.close();
  }
}

/** V1 plugin SDK adapter: fresh lookup, not cached events or caller-written state. */
export function createSourceAccessRuntime(config) {
  return new SourceAccessRuntime(config);
}
