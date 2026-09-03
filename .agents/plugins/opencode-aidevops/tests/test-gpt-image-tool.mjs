// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { createGptImageTool } from "../gpt-image-tool.mjs";

const PNG_BYTES = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const PNG_BASE64 = PNG_BYTES.toString("base64");
const roots = [];
const schemaNode = { _zod: {}, optional() { return this; }, describe() { return this; } };
const z = {
  array: () => schemaNode,
  enum: () => schemaNode,
  string: () => schemaNode,
};

async function projectRoot() {
  const root = await mkdtemp(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "aidevops-gpt-tool-"));
  roots.push(root);
  return root;
}

function oauthSuccess() {
  const event = `data: ${JSON.stringify({
    type: "response.output_item.done",
    item: { type: "image_generation_call", result: PNG_BASE64 },
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
    assert.doesNotMatch(output, new RegExp(root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
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
