// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { createGptImageTool } from "../gpt-image-tool.mjs";

const PNG_BYTES = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const PNG_BASE64 = PNG_BYTES.toString("base64");
const WEBP_BASE64 = Buffer.from([
  0x52, 0x49, 0x46, 0x46, 0x12, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
  0x56, 0x50, 0x38, 0x4c, 0x05, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, 0x00, 0x00,
]).toString("base64");
const roots = [];
const schemaNode = { _zod: {}, optional() { return this; }, describe() { return this; } };
const z = {
  array: () => schemaNode,
  enum: () => schemaNode,
  string: () => schemaNode,
};

function git(cwd, args) {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

async function gitProject() {
  const root = await projectRoot();
  const canonical = join(root, "canonical");
  const linked = join(root, "linked");
  await mkdir(canonical);
  git(canonical, ["init", "--initial-branch=main"]);
  git(canonical, ["config", "user.email", "test@example.invalid"]);
  git(canonical, ["config", "user.name", "Test"]);
  git(canonical, ["config", "commit.gpgsign", "false"]);
  await writeFile(join(canonical, "README.md"), "fixture\n");
  git(canonical, ["add", "README.md"]);
  git(canonical, ["commit", "--no-gpg-sign", "-m", "fixture"]);
  git(canonical, ["worktree", "add", "-b", "feature/image-fixture", linked]);
  return { canonical, linked };
}

async function projectRoot() {
  const root = await mkdtemp(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "aidevops-gpt-tool-"));
  roots.push(root);
  return root;
}

function oauthSuccess(base64 = PNG_BASE64) {
  const event = `data: ${JSON.stringify({
    type: "response.output_item.done",
    item: { type: "image_generation_call", result: base64 },
  })}\n\n`;
  return new Response(event, { status: 200, headers: { "Content-Type": "text/event-stream" } });
}

function createTool(options) {
  return createGptImageTool((definition) => definition, z, {
    markOAuthRateLimit: () => {},
    markOAuthSuccess: () => {},
    ...options,
  });
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("GPT image OpenCode tool", () => {
  test("uses OAuth by default and writes a generated PNG", async () => {
    const root = await projectRoot();
    let calls = 0;
    const tool = createTool({
      projectRoot: root,
      resolveOAuthAccount: async () => ({ email: "person@example.test", access: "oauth-test-token" }),
      fetchImpl: async () => {
        calls += 1;
        return oauthSuccess();
      },
    });
    const output = await tool.execute({ prompt: "draw a test", out: "generated/test.png", quality: "low" });
    assert.equal(calls, 1);
    assert.match(output, /ChatGPT subscription OAuth/);
    assert.match(output, /generated\/test\.png/);
    assert.match(output, /Requested size: auto; native dimensions: 1x1/);
    assert.doesNotMatch(output, new RegExp(root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  });

  test("routes outputs and references into a validated session-owned linked worktree", async () => {
    const { canonical, linked } = await gitProject();
    await mkdir(join(linked, "refs"));
    await writeFile(join(linked, "refs", "source.png"), PNG_BYTES);
    let ownershipChecks = 0;
    let requestBody;
    const tool = createTool({
      projectRoot: canonical,
      verifyWorktreeOwnership: async ({ root, sessionID }) => {
        ownershipChecks += 1;
        assert.equal(root, linked);
        assert.equal(sessionID, "ses_image_fixture");
      },
      resolveOAuthAccount: async () => ({ email: "person@example.test", access: "oauth-test-token" }),
      fetchImpl: async (_url, init) => {
        requestBody = JSON.parse(init.body);
        return oauthSuccess();
      },
    });
    const args = {
      prompt: "edit the reference",
      out: "generated/test.png",
      images: ["refs/source.png"],
      workdir: linked,
    };
    const context = { sessionID: "ses_image_fixture" };
    const first = await tool.execute(args, context);
    const second = await tool.execute(args, context);

    assert.equal(ownershipChecks, 2);
    assert.match(first, /generated\/test\.png in the validated session-owned linked worktree/);
    assert.match(second, /versioned filename/);
    assert.equal(requestBody.input[0].content[1].type, "input_image");
    assert.deepEqual(await readFile(join(linked, "generated", "test.png")), PNG_BYTES);
    assert.deepEqual(await readFile(join(linked, "generated", "test-v2.png")), PNG_BYTES);
    await assert.rejects(access(join(canonical, "generated", "test.png")), /ENOENT/);
    assert.equal(git(canonical, ["status", "--porcelain"]), "");
  });

  test("rejects unsafe, unrelated, and incorrectly owned worktree roots", async () => {
    const first = await gitProject();
    const second = await gitProject();
    const alias = join(first.canonical, "linked-alias");
    await symlink(first.linked, alias, "dir");
    let calls = 0;
    const tool = createTool({
      projectRoot: first.canonical,
      verifyWorktreeOwnership: async ({ sessionID }) => {
        if (sessionID !== "ses_image_fixture") throw new Error("wrong session");
      },
      fetchImpl: async () => {
        calls += 1;
        return oauthSuccess();
      },
    });
    const args = { prompt: "draw", out: "generated/test.png" };
    await assert.rejects(tool.execute({ ...args, workdir: first.linked }, { sessionID: "ses_other" }), /wrong session/);
    await assert.rejects(tool.execute({ ...args, workdir: second.linked }, { sessionID: "ses_image_fixture" }), /unrelated Git repository/);
    await assert.rejects(tool.execute({ ...args, workdir: alias }, { sessionID: "ses_image_fixture" }), /unavailable or unsafe/);
    await assert.rejects(tool.execute({ ...args, workdir: first.linked }, {}), /current OpenCode session identity/);
    await assert.rejects(
      tool.execute({ ...args, out: "../escape.png", workdir: first.linked }, { sessionID: "ses_image_fixture" }),
      /parent traversal/,
    );
    assert.equal(calls, 0);
  });

  test("surfaces OAuth and Platform API dimension mismatches without writing artifacts", async () => {
    const root = await projectRoot();
    const oauthTool = createTool({
      projectRoot: root,
      resolveOAuthAccount: async () => ({ email: "person@example.test", access: "oauth-test-token" }),
      fetchImpl: async () => oauthSuccess(),
    });
    await assert.rejects(
      oauthTool.execute({ prompt: "draw", out: "oauth.png", size: "1024x1024" }),
      /returned 1x1 PNG for requested 1024x1024; no artifact was written/,
    );

    const apiTool = createTool({
      projectRoot: root,
      readSecret: () => "unit-test-credential-value",
      fetchImpl: async () => Response.json({ data: [{ b64_json: PNG_BASE64 }] }),
    });
    await assert.rejects(
      apiTool.execute({ prompt: "draw", out: "api.png", size: "1024x1024", auth: "api", account: "work" }),
      /returned 1x1 PNG for requested 1024x1024; no artifact was written/,
    );
    await assert.rejects(access(join(root, "oauth.png")), /ENOENT/);
    await assert.rejects(access(join(root, "api.png")), /ENOENT/);
  });

  test("requests and writes a selected native WebP", async () => {
    const root = await projectRoot();
    let requestBody;
    const tool = createTool({
      projectRoot: root,
      resolveOAuthAccount: async () => ({ email: "person@example.test", access: "oauth-test-token" }),
      fetchImpl: async (_url, init) => {
        requestBody = JSON.parse(init.body);
        return oauthSuccess(WEBP_BASE64);
      },
    });
    const output = await tool.execute({ prompt: "draw a test", out: "generated/test.webp", format: "webp" });
    assert.equal(requestBody.tools[0].output_format, "webp");
    assert.match(output, /generated\/test\.webp/);
  });

  test("rejects format and extension mismatches before network access", async () => {
    const root = await projectRoot();
    let calls = 0;
    const tool = createTool({
      projectRoot: root,
      fetchImpl: async () => {
        calls += 1;
        return oauthSuccess();
      },
    });
    await assert.rejects(
      tool.execute({ prompt: "draw a test", out: "generated/test.png", format: "jpeg" }),
      /extension must match jpeg/,
    );
    assert.equal(calls, 0);
  });

  test("rotates once after an unpinned OAuth 429", async () => {
    const root = await projectRoot();
    let calls = 0;
    let rotations = 0;
    const tool = createTool({
      projectRoot: root,
      resolveOAuthAccount: async () => ({ email: "first@example.test", access: "first-oauth-token" }),
      rotateOAuthAccount: async () => {
        rotations += 1;
        return { email: "second@example.test", access: "second-oauth-token" };
      },
      fetchImpl: async () => {
        calls += 1;
        return calls === 1
          ? Response.json({ error: { code: "rate_limit_exceeded" } }, { status: 429 })
          : oauthSuccess();
      },
    });
    await tool.execute({ prompt: "draw a test", out: "rotated.png" });
    assert.equal(calls, 2);
    assert.equal(rotations, 1);
  });

  test("never rotates an explicitly pinned OAuth account", async () => {
    const root = await projectRoot();
    let rotations = 0;
    const tool = createTool({
      projectRoot: root,
      resolveOAuthAccount: async (email) => ({ email, access: "pinned-oauth-token" }),
      rotateOAuthAccount: async () => {
        rotations += 1;
        return null;
      },
      fetchImpl: async () => Response.json({ error: { code: "rate_limit_exceeded" } }, { status: 429 }),
    });
    await assert.rejects(
      tool.execute({ prompt: "draw a test", out: "pinned.png", account: "person@example.test" }),
      /failed \(429\)/,
    );
    assert.equal(rotations, 0);
  });

  test("uses a named API secret and never retries API failures", async () => {
    const root = await projectRoot();
    let requestedSecret = "";
    let calls = 0;
    const tool = createTool({
      projectRoot: root,
      readSecret: (name) => {
        requestedSecret = name;
        return "unit-test-credential-value";
      },
      fetchImpl: async () => {
        calls += 1;
        return Response.json({ error: { code: "rate_limit_exceeded" } }, { status: 429 });
      },
    });
    await assert.rejects(
      tool.execute({ prompt: "draw a test", out: "api.png", auth: "api", account: "work" }),
      /api image request failed \(429\)/,
    );
    assert.equal(requestedSecret, "OPENAI_IMAGE_API_KEY_WORK");
    assert.equal(calls, 1);
  });

  test("fails before network access when API account selection is absent", async () => {
    const root = await projectRoot();
    let calls = 0;
    const tool = createTool({
      projectRoot: root,
      env: {},
      fetchImpl: async () => {
        calls += 1;
        return Response.json({});
      },
    });
    await assert.rejects(
      tool.execute({ prompt: "draw a test", out: "api.png", auth: "api" }),
      /explicit account alias/,
    );
    assert.equal(calls, 0);
  });
});
