// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

test("QuickFile MCP uses the least-privilege secret launcher", (t) => {
  const binDir = mkdtempSync(join(tmpdir(), "aidevops-quickfile-registry-"));
  const originalPath = process.env.PATH;
  const executable = join(
    binDir,
    process.platform === "win32" ? "aidevops.CMD" : "aidevops",
  );
  writeFileSync(
    executable,
    process.platform === "win32" ? "@exit /b 0\r\n" : "#!/bin/sh\nexit 0\n",
    { mode: 0o755 },
  );
  process.env.PATH = `${binDir}${delimiter}${originalPath || ""}`;
  t.after(() => {
    if (originalPath === undefined) delete process.env.PATH;
    else process.env.PATH = originalPath;
    rmSync(binDir, { recursive: true, force: true });
  });

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

test("QuickFile MCP exposes a bounded on-demand activation agent", () => {
  const quickfile = getOnDemandMcpAgents().find(
    (entry) => entry.name === "quickfile",
  );

  assert.deepEqual(quickfile, {
    name: "quickfile",
    agentName: "quickfile",
    agentSource: ["services", "accounting", "quickfile.md"],
    toolPattern: "quickfile_*",
    modelTier: "standard",
    activationGuidance: [],
    description: "Multi-account QuickFile UK accounting",
  });
});
