// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";

import { managedExternalDirectories, registerManagedDirectoryPermissions } from "../config-hook.mjs";

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
const managedRules = Object.fromEntries(
  managedExternalDirectories({}).map((path) => [path, "allow"]),
);
const managedRuleCount = Object.keys(managedRules).length;
const defaultManagedEnvironment = {};

test("uses the configured worktree base instead of hardcoding ~/Git", () => {
  assert.deepEqual(
    managedExternalDirectories({ AIDEVOPS_WORKTREE_BASE_DIR: "/Users/test/Projects/.worktrees/" })
      .filter((path) => path.includes("worktrees")),
    ["/Users/test/Projects/.worktrees", "/Users/test/Projects/.worktrees/**"],
  );
});

test("rejects unsafe configured worktree bases", () => {
  for (const value of ["", "/", "///", "relative/worktrees", "~"]) {
    assert.throws(
      () => managedExternalDirectories({ AIDEVOPS_WORKTREE_BASE_DIR: value }),
      /must be a non-root absolute path/,
    );
  }
});

test("registers the configured worktree base for global and agent permissions", () => {
  const config = {
    permission: { external_directory: { "*": "ask", "~/Git/_worktrees": "allow", "~/Git/_worktrees/**": "allow" } },
    agent: { "Build+": { permission: { external_directory: "ask" } } },
  };
  const env = { AIDEVOPS_WORKTREE_BASE_DIR: "/Users/test/Projects/.worktrees" };

  assert.ok(registerManagedDirectoryPermissions(config, env) > 0);
  for (const target of [config, config.agent["Build+"]]) {
    assert.equal(target.permission.external_directory["/Users/test/Projects/.worktrees"], "allow");
    assert.equal(target.permission.external_directory["/Users/test/Projects/.worktrees/**"], "allow");
    assert.equal(target.permission.external_directory["~/Git/_worktrees"], undefined);
    assert.equal(target.permission.external_directory["~/Git/_worktrees/**"], undefined);
  }
});

test("adds narrow managed-directory exceptions after a broad ask rule", () => {
  const config = {
    permission: {
      external_directory: {
        "*": "ask",
        "~/Documents/**": "deny",
      },
    },
  };

  assert.equal(registerManagedDirectoryPermissions(config, defaultManagedEnvironment), managedRuleCount);
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

  assert.equal(registerManagedDirectoryPermissions(config, defaultManagedEnvironment), managedRuleCount);
  assert.equal(config.permission["*"], "ask");
  assert.deepEqual(config.permission.external_directory, {
    "*": "ask",
    ...managedRules,
  });
});

test("leaves an existing global external-directory allow unchanged", () => {
  const config = { permission: { external_directory: "allow", read: "ask" } };

  assert.equal(registerManagedDirectoryPermissions(config, defaultManagedEnvironment), 0);
  assert.deepEqual(config.permission, { external_directory: "allow", read: "ask" });
});

test("is idempotent and keeps managed rules last", () => {
  const config = { permission: { external_directory: { "*": "ask" } } };

  assert.equal(registerManagedDirectoryPermissions(config, defaultManagedEnvironment), managedRuleCount);
  assert.equal(registerManagedDirectoryPermissions(config, defaultManagedEnvironment), 0);
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

  assert.equal(registerManagedDirectoryPermissions(config, defaultManagedEnvironment), managedRuleCount * 3);
  assert.deepEqual(config.agent["Build+"].permission.external_directory, {
    "*": "ask",
    ...managedRules,
  });
  assert.deepEqual(config.agent.review.permission.external_directory, managedRules);
});
