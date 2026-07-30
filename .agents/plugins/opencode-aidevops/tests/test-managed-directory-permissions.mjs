// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";

import { registerManagedDirectoryPermissions } from "../config-hook.mjs";

const tempDirectories = new Set();
function addTempDirectory(path) {
  const normalized = path.replace(/\/+$/, "");
  tempDirectories.add(normalized);
  tempDirectories.add(realpathSync(normalized));
}
addTempDirectory(tmpdir());
if (process.platform === "darwin") {
  const darwinTemp = execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
  addTempDirectory(darwinTemp);
}
const managedRules = {
  "~/.aidevops": "allow",
  "~/.aidevops/**": "allow",
  "~/.config/aidevops": "allow",
  "~/.config/aidevops/**": "allow",
  "~/.config/opencode/command": "allow",
  "~/.config/opencode/command/**": "allow",
  "~/.config/opencode/skills": "allow",
  "~/.config/opencode/skills/**": "allow",
  "~/Git/_worktrees": "allow",
  "~/Git/_worktrees/**": "allow",
  ...Object.fromEntries([...tempDirectories].sort().flatMap((path) => [
    [path, "allow"],
    [`${path}/**`, "allow"],
  ])),
};
const managedRuleCount = Object.keys(managedRules).length;

test("adds narrow managed-directory exceptions after a broad ask rule", () => {
  const config = {
    permission: {
      external_directory: {
        "*": "ask",
        "~/Documents/**": "deny",
      },
    },
  };

  assert.equal(registerManagedDirectoryPermissions(config), managedRuleCount);
  assert.deepEqual(config.permission.external_directory, {
    "*": "ask",
    "~/Documents/**": "deny",
    ...managedRules,
  });
  assert.equal(config.permission.external_directory["~/.config/opencode/agent"], undefined);
  assert.equal(config.permission.external_directory["~/.config/opencode/agent/**"], undefined);
});

test("converts a top-level default without allowing unrelated directories", () => {
  const config = { permission: "ask" };

  assert.equal(registerManagedDirectoryPermissions(config), managedRuleCount);
  assert.equal(config.permission["*"], "ask");
  assert.deepEqual(config.permission.external_directory, {
    "*": "ask",
    ...managedRules,
  });
});

test("leaves an existing global external-directory allow unchanged", () => {
  const config = { permission: { external_directory: "allow", read: "ask" } };

  assert.equal(registerManagedDirectoryPermissions(config), 0);
  assert.deepEqual(config.permission, { external_directory: "allow", read: "ask" });
});

test("is idempotent and keeps managed rules last", () => {
  const config = { permission: { external_directory: { "*": "ask" } } };

  assert.equal(registerManagedDirectoryPermissions(config), managedRuleCount);
  assert.equal(registerManagedDirectoryPermissions(config), 0);
  assert.deepEqual(Object.keys(config.permission.external_directory).slice(-managedRuleCount), Object.keys(managedRules));
});

test("adds managed rules to per-agent permissions that override top-level defaults", () => {
  const config = {
    permission: { external_directory: { "*": "ask" } },
    agent: {
      "Build+": { permission: { external_directory: "ask", bash: "allow" } },
      review: { permission: { read: "allow" } },
    },
  };

  assert.equal(registerManagedDirectoryPermissions(config), managedRuleCount * 3);
  assert.deepEqual(config.agent["Build+"].permission.external_directory, {
    "*": "ask",
    ...managedRules,
  });
  assert.deepEqual(config.agent.review.permission.external_directory, managedRules);
});
