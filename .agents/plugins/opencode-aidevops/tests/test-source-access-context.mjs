// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import test, { mock } from "node:test";
import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { connect } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { createSourceAccessRuntime } from "../source-access-runtime.mjs";
import { createShellEnvHook } from "../shell-env.mjs";
import {
  createSourceContextResponder, listenSourceContext, SOURCE_CONTEXT_QUERY, sourceContextInstanceId,
} from "../source-access-context.mjs";

function contextFixture() {
  const session = { id: "ses_context_fixture", projectID: "fixture", directory: "/repo",
    time: { created: 1800000000000 } };
  const query = { schema: SOURCE_CONTEXT_QUERY, nonce: "a".repeat(64),
    session_id: session.id, repo_root: "/implementation" };
  const state = { present: true, owned: true, sameRepo: true, lookups: 0 };
  const respond = createSourceContextResponder({
    lookupSession: async (id) => {
      state.lookups++;
      assert.equal(id, session.id);
      return state.present ? session : undefined;
    },
    verifyOwner: async () => state.owned,
    sameRepository: async () => state.sameRepo,
  });
  return { respond, query, state, session };
}

test("privileged runtimes cannot execute session or owner callbacks", async () => {
  const uid = process.getuid();
  for (const realUid of [0, uid]) {
    try {
      mock.method(process, "getuid", () => realUid);
      mock.method(process, "geteuid", () => 0);
      const fixture = contextFixture();
      await assert.rejects(fixture.respond(fixture.query), /unprivileged runtime/);
      assert.equal(fixture.state.lookups, 0);
      let lookups = 0;
      const runtime = createSourceAccessRuntime({ client: { session: { get: () => { lookups++; } } },
        directory: "/repo", scriptsDir: "/untrusted/scripts", tempDir: "/untrusted/temp" });
      assert.equal(await runtime.resolve("ses_disabled_runtime", "/implementation"), undefined);
      assert.deepEqual(await runtime.environment("ses_disabled_runtime"), {
        AIDEVOPS_SOURCE_CONTEXT_SOCKET: "", AIDEVOPS_SOURCE_CONTEXT_INSTANCE: "",
      });
      assert.equal(lookups, 0);
      runtime.close();
    } finally {
      mock.restoreAll();
    }
  }
});

test("source context rechecks an idle session without granting authority", async () => {
  const fixture = contextFixture();
  const first = await fixture.respond(fixture.query);
  assert.equal(first.authority, "none");
  assert.equal(first.runtime_instance_id, sourceContextInstanceId);
  assert.equal(first.runtime_pid, process.pid);
  assert.equal(first.session_created_at, fixture.session.time.created);
  fixture.state.present = false;
  await assert.rejects(fixture.respond(fixture.query), /session is unavailable/);
  assert.equal(fixture.state.lookups, 2);
});

test("source context refuses foreign worktrees, missing owners and cancelled queries", async () => {
  const fixture = contextFixture();
  fixture.state.sameRepo = false;
  await assert.rejects(fixture.respond(fixture.query), /ownership is unavailable/);
  fixture.state.sameRepo = true;
  fixture.state.owned = false;
  await assert.rejects(fixture.respond(fixture.query), /ownership is unavailable/);
  fixture.state.owned = true;
  await assert.rejects(fixture.respond({ ...fixture.query, nonce: "invalid" }), /invalid/);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(fixture.respond(fixture.query, controller.signal), /invalid/);
});

function contextRoundTrip(socketPath, query) {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let result = "";
    socket.setTimeout(2000, () => socket.destroy(new Error("context fixture timed out")));
    socket.on("error", reject);
    socket.on("connect", () => socket.write(`${JSON.stringify(query)}\n`));
    socket.on("data", (data) => { result += data; });
    socket.on("end", () => {
      try { resolve(JSON.parse(result)); } catch (error) { reject(error); }
    });
  });
}

test("source context transport returns only bounded metadata and sanitized failure", async () => {
  const parent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(parent, { recursive: true });
  const directory = mkdtempSync(join(parent, "sc-"));
  const fixture = contextFixture();
  let listener;
  try {
    listener = await listenSourceContext({ directory, respond: fixture.respond });
    const reply = await contextRoundTrip(listener.socketPath, fixture.query);
    assert.equal(reply.nonce, fixture.query.nonce);
    assert.equal(reply.authority, "none");
    fixture.state.present = false;
    assert.deepEqual(await contextRoundTrip(listener.socketPath, fixture.query), { error: "context unavailable" });
  } finally {
    listener?.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Python context probe uses kernel peer identity rather than a claimed PID", async () => {
  const parent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(parent, { recursive: true });
  const root = mkdtempSync(join(parent, "sc-"));
  const directory = join(root, "p");
  mkdirSync(directory, { mode: 0o700 });
  const fixture = contextFixture();
  const helper = fileURLToPath(new URL("../../../scripts/source-access-helper.py", import.meta.url));
  const script = "import runpy,sys,json,os; m=runpy.run_path(sys.argv[1]); "
    + "print(json.dumps(m['_SOURCE_CORE'].query_source_context(sys.argv[2],sys.argv[3],sys.argv[4],os.getuid())))";
  let forged = false;
  let listener;
  try {
    listener = await listenSourceContext({ directory, respond: async (...args) => {
      const reply = await fixture.respond(...args);
      return forged ? { ...reply, runtime_pid: process.pid + 1 } : reply;
    } });
    const query = () => promisify(execFile)("python3", ["-I", "-B", "-c", script,
      helper, listener.socketPath, fixture.query.session_id, fixture.query.repo_root], { timeout: 10000 });
    const { stdout } = await query();
    const context = JSON.parse(stdout);
    assert.equal(context.runtime_pid, process.pid);
    assert.equal(context.uid, process.getuid());
    assert.equal(context.runtime_instance_id, sourceContextInstanceId);
    forged = true;
    await assert.rejects(query(), /peer identity or challenge did not match/);
    forged = false;
    chmodSync(root, 0o777);
    await assert.rejects(query(), /unsafe context socket ancestry/);
    await assert.rejects(listenSourceContext({ directory, respond: fixture.respond }), /private user directory/);
  } finally {
    chmodSync(root, 0o700);
    listener?.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("runtime adapter uses fresh V1 SDK lookup, exact linked ownership and private lazy transport", async () => {
  const parent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(parent, { recursive: true });
  const root = mkdtempSync(join(parent, "r"));
  const repo = join(root, "repo");
  const worktree = join(root, "wt");
  const scripts = join(root, "scripts");
  mkdirSync(scripts);
  execFileSync("git", ["init", "-q", repo]);
  execFileSync("git", ["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "commit", "--allow-empty", "-qm", "fixture"]);
  execFileSync("git", ["-C", repo, "worktree", "add", "--detach", worktree], { stdio: "ignore" });
  const session = { id: "ses_runtime_fixture", projectID: "fixture", directory: repo, time: { created: 1000 } };
  const ownerHelper = join(scripts, "worktree-helper.sh");
  writeFileSync(ownerHelper, '#!/bin/sh\n[ "$1" = registry ] && [ "$2" = verify-owner ] && '
    + '[ "$4" = ses_runtime_fixture ] || exit 1\nprintf "VERIFIED\\n"\n', { mode: 0o700 });
  let present = true;
  let lookups = 0;
  const runtime = createSourceAccessRuntime({ directory: repo, scriptsDir: scripts, tempDir: root,
    client: { session: { get: async (options) => {
      lookups++;
      assert.deepEqual(options.path, { id: session.id });
      assert.deepEqual(options.query, { directory: repo });
      assert.ok(options.signal instanceof AbortSignal);
      return present ? { data: session } : { error: { message: "private SDK error" } };
    } } },
  });
  try {
    const first = await runtime.resolve(session.id, worktree);
    assert.equal(first?.runtime_instance_id, sourceContextInstanceId);
    assert.equal(first?.repo_root, worktree);
    assert.equal(first?.authority, "none");
    assert.equal(await runtime.resolve(session.id, repo), undefined, "canonical checkout is not an implementation worktree");
    const shell = createShellEnvHook({ sourceAccessRuntime: runtime });
    const output = { env: { AIDEVOPS_SOURCE_CONTEXT_SOCKET: "inherited-forgery" } };
    await shell({ sessionID: session.id, cwd: repo }, output);
    const socketPath = output.env.AIDEVOPS_SOURCE_CONTEXT_SOCKET;
    assert.ok(socketPath && socketPath !== "inherited-forgery");
    const query = { schema: SOURCE_CONTEXT_QUERY, nonce: "a".repeat(64), session_id: session.id, repo_root: worktree };
    assert.equal((await contextRoundTrip(socketPath, query)).session_created_at, 1000);
    present = false;
    assert.equal(await runtime.resolve(session.id, worktree), undefined);
    assert.deepEqual(await contextRoundTrip(socketPath, query), { error: "context unavailable" });
    present = true;
    writeFileSync(ownerHelper, "#!/bin/sh\nexit 1\n");
    assert.equal(await runtime.resolve(session.id, worktree), undefined, "lost owner never uses cached success");
    assert.equal(lookups, 6);
    runtime.handleEvent({ event: { type: "server.instance.disposed", properties: { directory: repo } } });
    assert.equal(await runtime.resolve(session.id, worktree), undefined);
    assert.deepEqual(await runtime.environment(session.id), {
      AIDEVOPS_SOURCE_CONTEXT_SOCKET: "", AIDEVOPS_SOURCE_CONTEXT_INSTANCE: "",
    });
    await assert.rejects(contextRoundTrip(socketPath, query));
  } finally {
    runtime.close();
    rmSync(root, { recursive: true, force: true });
  }
});
