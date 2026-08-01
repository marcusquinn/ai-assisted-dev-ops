// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for OpenCode 1.14.49's plugin tool registry.
// The registry calls Object.entries(def.args) for every plugin tool, so each
// aidevops tool must expose an `args` object even when arguments are optional.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { createTools } from "../tools.mjs";
import { createPoolTool } from "../oauth-pool-tool.mjs";

describe("aidevops plugin tool schemas", () => {
  test("all registered tools expose args schemas", () => {
    const tools = createTools("/tmp/aidevops-test-scripts", () => "", {
      poolToolFactory: () => createPoolTool({}),
    });

    for (const [name, definition] of Object.entries(tools)) {
      assert.ok(definition.args, `${name} must expose args for OpenCode ToolRegistry`);
      assert.doesNotThrow(() => Object.entries(definition.args), `${name} args must be enumerable`);
    }
  });

  test("schemas use OpenCode-compatible Zod fields", () => {
    const tools = createTools("/tmp/aidevops-test-scripts", () => "");
    const pool = createPoolTool({});

    assert.ok(tools.aidevops.args.command?._zod, "aidevops.command must be Zod");
    assert.ok(tools.aidevops_pre_edit_check.args.task?._zod, "pre-edit task must be Zod");
    assert.ok(tools.aidevops_pre_edit_check.args.workdir?._zod, "pre-edit workdir must be Zod");
    assert.ok(tools.aidevops_hook_status.args.workdir?._zod, "hook-status workdir must be Zod");
    assert.ok(pool.args.action?._zod, "pool action must be Zod");
    assert.ok(pool.args.provider?._zod, "pool provider must be Zod");
  });

  test("public triage exports no plugin tool definitions", () => {
    let poolToolCreated = false;
    const tools = createTools("/tmp/aidevops-test-scripts", () => "", {
      sessionOrigin: "triage",
      poolToolFactory: () => {
        poolToolCreated = true;
        return createPoolTool({});
      },
    });

    assert.deepEqual(tools, {});
    assert.equal(poolToolCreated, false);
  });
});
