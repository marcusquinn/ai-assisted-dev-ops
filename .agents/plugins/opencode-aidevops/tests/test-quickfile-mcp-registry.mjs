// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import { registerMcpServers } from "../mcp-registry.mjs";

test("QuickFile MCP uses the least-privilege secret launcher", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);

  assert.deepEqual(config.mcp.quickfile, {
    type: "local",
    command: [
      join(
        homedir(),
        ".aidevops",
        "agents",
        "scripts",
        "quickfile-mcp-launcher.sh",
      ),
    ],
    enabled: false,
  });
  assert.equal(config.tools["quickfile_*"], false);
});
