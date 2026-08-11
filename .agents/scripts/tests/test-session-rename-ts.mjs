#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// =============================================================================
// Tests for .opencode/tool/session-rename.ts guard functions (t2252)
//
// These exercise the TypeScript-side mirrors of session-rename-helper.sh's
// _is_meaningful_branch_title and _is_title_overwritable. The OpenCode
// MCP tool path bypasses the shell helper entirely, so it needs its own
// regression coverage to prevent auto-compaction from clobbering the
// session title with "main".
// =============================================================================

import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Import from the extracted guards module — it has no runtime-injected
// dependencies so it loads cleanly under `bun run` without the OpenCode
// plugin runtime. session-rename.ts re-exports these symbols for callers
// that already import from it.
const { isDefaultBranchTitle, isTitleOverwritable, purposePreservingTitle } = await import(
  "../../../.opencode/lib/session-rename-guards.ts"
);
const { getDbPath } = await import("../../../.opencode/lib/opencode-db-path.ts");
const { getAidevopsVersion, sanitizeSessionTitle, withAidevopsTitleSuffix } = await import(
  "../../../.opencode/lib/session-title-suffix.ts"
);
const { emitTerminalTitle, isTerminalTitleEnabled, sanitizeTerminalTitle, terminalTitleSequence } = await import(
  "../../../.opencode/lib/terminal-title.ts"
);

let pass = 0;
let fail = 0;

function assertEq(name, expected, actual) {
  if (expected === actual) {
    console.log(`  PASS: ${name}`);
    pass++;
  } else {
    console.log(`  FAIL: ${name}`);
    console.log(`    expected: ${JSON.stringify(expected)}`);
    console.log(`    actual:   ${JSON.stringify(actual)}`);
    fail++;
  }
}

console.log("=== session-rename.ts guard tests (t2252) ===\n");

// --- isDefaultBranchTitle ---------------------------------------------------
console.log("Group 1: isDefaultBranchTitle");
assertEq("empty string is default", true, isDefaultBranchTitle(""));
assertEq("'HEAD' is default", true, isDefaultBranchTitle("HEAD"));
assertEq("'main' is default", true, isDefaultBranchTitle("main"));
assertEq("'master' is default", true, isDefaultBranchTitle("master"));
assertEq("'feature/x' is NOT default", false, isDefaultBranchTitle("feature/x"));
assertEq("'bugfix/t2252-foo' is NOT default", false, isDefaultBranchTitle("bugfix/t2252-foo"));
assertEq("'develop' is NOT default", false, isDefaultBranchTitle("develop"));
assertEq("'mainline' is NOT default (exact match only)", false, isDefaultBranchTitle("mainline"));
assertEq("' main' is NOT default (whitespace-sensitive)", false, isDefaultBranchTitle(" main"));

// --- isTitleOverwritable ----------------------------------------------------
console.log("\nGroup 2: isTitleOverwritable");

const tmp = mkdtempSync(join(tmpdir(), "t2252-"));
const dbPath = join(tmp, "test.db");

try {
  const db = new Database(dbPath);
  db.run(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY,
      title TEXT,
      directory TEXT,
      time_created INTEGER,
      time_updated INTEGER
    )
  `);

  function seed(id, title) {
    db.run(
      "INSERT OR REPLACE INTO session (id, title, directory, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
      [id, title, "/tmp", 1000, 1000],
    );
  }

  // Missing row — safe to write (session not yet persisted).
  assertEq("missing row is overwritable", true, isTitleOverwritable(db, "ses_missing"));

  // NULL / empty titles.
  seed("ses_empty", "");
  assertEq("empty string title is overwritable", true, isTitleOverwritable(db, "ses_empty"));

  // Default placeholder titles.
  seed("ses_default", "New Session");
  assertEq("'New Session' is overwritable", true, isTitleOverwritable(db, "ses_default"));

  // Stuck-on-default titles (recovery path).
  seed("ses_stuck_main", "main");
  assertEq("'main' title is overwritable (recovery)", true, isTitleOverwritable(db, "ses_stuck_main"));

  seed("ses_stuck_master", "master");
  assertEq("'master' title is overwritable (recovery)", true, isTitleOverwritable(db, "ses_stuck_master"));

  seed("ses_stuck_head", "HEAD");
  assertEq("'HEAD' title is overwritable (recovery)", true, isTitleOverwritable(db, "ses_stuck_head"));

  // Meaningful titles — must be preserved.
  seed("ses_feature", "feature/cool-thing");
  assertEq("feature branch title is PRESERVED", false, isTitleOverwritable(db, "ses_feature"));

  seed("ses_llm", "Investigating auto-compaction bug");
  assertEq("LLM-generated title is PRESERVED", false, isTitleOverwritable(db, "ses_llm"));

  seed("ses_bugfix", "bugfix/t2252-session-title-compaction");
  assertEq("bugfix branch title is PRESERVED", false, isTitleOverwritable(db, "ses_bugfix"));

  seed("ses_weird", "mainline");
  assertEq("'mainline' (close to default) is PRESERVED", false, isTitleOverwritable(db, "ses_weird"));

  db.close();
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

// --- terminal title OSC helpers ---------------------------------------------
console.log("\nGroup 3: terminal title OSC helpers");
assertEq(
  "OSC 0 sequence wraps the title",
  "\u001B]0;Issue #123: fix Tabby title\u0007",
  terminalTitleSequence("Issue #123: fix Tabby title"),
);
assertEq(
  "control characters are stripped from titles",
  "Issue #123 injected title",
  sanitizeTerminalTitle("Issue #123\u0007\u001Binjected\ntitle"),
);
assertEq(
  "consecutive control characters collapse to one space",
  "Issue #123 injected title",
  sanitizeTerminalTitle("Issue #123\u0007\u001B\n\tinjected\u0000\u007Ftitle"),
);
assertEq(
  "OSC 0 sequence uses collapsed sanitized title",
  "\u001B]0;Issue #123 injected title\u0007",
  terminalTitleSequence("Issue #123\u0007\u001B\n\tinjected\u0000\u007Ftitle"),
);
assertEq(
  "C0 and DEL control runs collapse without touching printable punctuation",
  "Issue #123 — injected: title",
  sanitizeTerminalTitle("Issue #123 —\u0000\u0001\u001F\u007Finjected: title"),
);
assertEq("empty sanitized title emits no OSC", "", terminalTitleSequence("\n\t"));
assertEq(
  "TERMINAL_TITLE_ENABLED=false disables title emit",
  false,
  isTerminalTitleEnabled({ TERMINAL_TITLE_ENABLED: "false" }),
);
assertEq(
  "AIDEVOPS_TABBY_ENABLED=false disables title emit",
  false,
  isTerminalTitleEnabled({ AIDEVOPS_TABBY_ENABLED: "false" }),
);
assertEq(
  "native terminal-title ownership disables aidevops OSC",
  false,
  isTerminalTitleEnabled({ AIDEVOPS_TERMINAL_TITLE_OWNER: "native" }),
);
assertEq("terminal title emit defaults to enabled", true, isTerminalTitleEnabled({}));

const titleControllerSymbol = Symbol.for("aidevops.terminal-title-controller.v1");
const previousTitleController = Reflect.get(globalThis, titleControllerSymbol);
let delegatedTitle = "";
try {
  Reflect.set(globalThis, titleControllerSymbol, {
    emit(title) {
      delegatedTitle = title;
      return true;
    },
  });
  assertEq(
    "native session rename delegates to the plugin title controller",
    true,
    emitTerminalTitle("Issue #123: shared controller"),
  );
  assertEq("shared controller receives the undecorated base title", "Issue #123: shared controller", delegatedTitle);
} finally {
  if (previousTitleController === undefined) Reflect.deleteProperty(globalThis, titleControllerSymbol);
  else Reflect.set(globalThis, titleControllerSymbol, previousTitleController);
}

// --- stable session purpose -------------------------------------------------
console.log("\nGroup 4: stable session purpose");
assertEq(
  "default title accepts the requested purpose",
  "Investigate crash restoration",
  purposePreservingTitle("New Session", "Investigate crash restoration"),
);
assertEq(
  "later phase preserves the original purpose",
  "Investigate crash restoration — Current: implement the Tabby marker",
  purposePreservingTitle("Investigate crash restoration · AIDevOps 3.32.243", "implement the Tabby marker"),
);
assertEq(
  "later phase replaces only the prior Current context",
  "Investigate crash restoration — Current: release for testing",
  purposePreservingTitle(
    "Investigate crash restoration — Current: implement the Tabby marker · AIDevOps 3.32.243",
    "release for testing",
  ),
);
assertEq(
  "a requested title already containing the purpose is not duplicated",
  "Investigate crash restoration — verification",
  purposePreservingTitle("Investigate crash restoration", "Investigate crash restoration — verification"),
);
assertEq(
  "explicit repurpose replaces the stable purpose",
  "Review an unrelated deployment",
  purposePreservingTitle("Investigate crash restoration", "Review an unrelated deployment", true),
);

// --- AIDevOps session title suffix helpers ----------------------------------
console.log("\nGroup 5: AIDevOps session title suffix helpers");
assertEq(
  "suffix is appended",
  "Issue #123: concise title · AIDevOps 9.8.7",
  withAidevopsTitleSuffix("Issue #123: concise title", "9.8.7"),
);
assertEq(
  "existing suffix is idempotently replaced",
  "Issue #123: concise title · AIDevOps 9.8.7",
  withAidevopsTitleSuffix("Issue #123: concise title · AIDevOps 1.2.3", "9.8.7"),
);
assertEq(
  "issue prefix remains first",
  "Issue #456: preserve prefix · AIDevOps 9.8.7",
  withAidevopsTitleSuffix("Issue #456: preserve prefix", "9.8.7"),
);
assertEq(
  "missing version leaves title without stale suffix",
  "Issue #123: concise title",
  withAidevopsTitleSuffix("Issue #123: concise title · AIDevOps 1.2.3", ""),
);
assertEq(
  "image placeholders are removed from generated titles",
  "Review the session title rename",
  sanitizeSessionTitle("[Image 1] Review the session [Image 2] title rename"),
);
assertEq(
  "image placeholder matching is case-insensitive",
  "Preserve useful title text",
  sanitizeSessionTitle("Preserve [image 12] useful title text"),
);
assertEq(
  "image placeholders are stripped before suffixing",
  "Fix title renaming · AIDevOps 9.8.7",
  withAidevopsTitleSuffix("[Image 1] Fix title renaming", "9.8.7"),
);
const versionRoot = mkdtempSync(join(tmpdir(), "title-version-"));
try {
  const activeAgentsDir = join(versionRoot, "active-agents");
  const missingAgentsDir = join(versionRoot, "missing-agents");
  const { mkdirSync, writeFileSync } = await import("node:fs");
  mkdirSync(activeAgentsDir);
  writeFileSync(join(activeAgentsDir, "VERSION"), "7.6.6\n");
  assertEq(
    "active deployed version wins over stale env",
    "7.6.6",
    getAidevopsVersion({ AIDEVOPS_ACTIVE_AGENTS_DIR: activeAgentsDir, AIDEVOPS_VERSION: "7.6.5" }),
  );
  assertEq(
    "env version remains a fallback",
    "7.6.5",
    getAidevopsVersion({ AIDEVOPS_ACTIVE_AGENTS_DIR: missingAgentsDir, AIDEVOPS_VERSION: "7.6.5" }),
  );
} finally {
  rmSync(versionRoot, { recursive: true, force: true });
}

// --- OpenCode DB path helpers ------------------------------------------------
console.log("\nGroup 6: OpenCode DB path helpers");
assertEq(
  "XDG_DATA_HOME selects isolated OpenCode DB",
  "/tmp/aidevops-opencode/opencode/opencode.db",
  getDbPath({ XDG_DATA_HOME: "/tmp/aidevops-opencode" }),
);
assertEq(
  "OPENCODE_DB overrides XDG_DATA_HOME",
  "/tmp/custom-opencode.db",
  getDbPath({ OPENCODE_DB: "/tmp/custom-opencode.db", XDG_DATA_HOME: "/tmp/aidevops-opencode" }),
);
assertEq(
  "mock env accepts unrelated variables",
  "/tmp/mock-opencode.db",
  getDbPath({ OPENCODE_DB: "/tmp/mock-opencode.db", NODE_ENV: "test" }),
);

console.log("\n=== Results ===");
console.log(`PASS: ${pass}`);
console.log(`FAIL: ${fail}`);
process.exit(fail > 0 ? 1 : 0);
