// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Test suite for the signature footer gate (t2685)
// ---------------------------------------------------------------------------
// Validates that checkSignatureFooterGate (and its helpers) correctly:
//   • detects gh write commands vs unrelated commands
//   • exempts machine-protocol comments (DISPATCH_CLAIM et al)
//   • accepts trusted signals (marker, helper call, footer variable)
//   • auto-repairs simple --body and --body-file commands by mutating args
//   • throws a mentoring error for unparseable commands
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-signature-footer-gate.mjs
// ---------------------------------------------------------------------------

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "child_process";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, symlinkSync, rmSync, mkdirSync } from "fs";
import { tmpdir, homedir } from "os";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

import {
  SIG_MARKER,
  isGhWriteCommand,
  isMachineProtocolCommand,
  hasTrustedSignatureSignal,
  tryRepairSignature,
  checkSignatureFooterGate,
  createQualityHooks,
} from "../quality-hooks.mjs";
import { FAIL_REASON } from "../quality-hooks-signature.mjs";

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

function setupStubHelper() {
  const dir = mkdtempSync(join(tmpdir(), "t2685-"));
  const helper = join(dir, "gh-signature-helper.sh");
  writeFileSync(
    helper,
    `#!/usr/bin/env bash
# Stub emits a canonical footer with the sig marker.
printf '\\n\\n${SIG_MARKER}\\n---\\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub\\n'
`,
  );
  chmodSync(helper, 0o755);
  return dir;
}

function makeLogger() {
  const entries = [];
  return {
    log: (level, msg) => entries.push({ level, msg }),
    entries,
  };
}

// ---------------------------------------------------------------------------
// isGhWriteCommand
// ---------------------------------------------------------------------------

describe("isGhWriteCommand", () => {
  test("detects gh issue comment", () => {
    assert.equal(isGhWriteCommand('gh issue comment 1 --body "x"'), true);
  });

  test("detects gh issue create", () => {
    assert.equal(isGhWriteCommand('gh issue create --title "t" --body "x"'), true);
  });

  test("detects gh pr create", () => {
    assert.equal(isGhWriteCommand('gh pr create --title "t" --body "x"'), true);
  });

  test("detects gh pr comment", () => {
    assert.equal(isGhWriteCommand('gh pr comment 1 --body "x"'), true);
  });

  test("ignores non-string input", () => {
    assert.equal(isGhWriteCommand(undefined), false);
    assert.equal(isGhWriteCommand({ command: 'gh issue comment 1 --body "x"' }), false);
  });

  test("ignores gh issue view (read)", () => {
    assert.equal(isGhWriteCommand("gh issue view 1"), false);
  });

  test("ignores gh api", () => {
    assert.equal(isGhWriteCommand("gh api /user"), false);
  });

  test("ignores git commit (not gh)", () => {
    assert.equal(isGhWriteCommand('git commit -m "fix"'), false);
  });

  test("ignores commented-out line", () => {
    assert.equal(isGhWriteCommand('# gh issue comment 1 --body "x"'), false);
  });

  test("detects one write line in multi-line command", () => {
    const cmd = `echo hello
gh issue comment 1 --body "x"
echo done`;
    assert.equal(isGhWriteCommand(cmd), true);
  });

  // GH#20735 — false-positive regression tests
  // These cases must NOT be treated as gh write commands.

  test("FP1: heredoc body containing gh issue create prose → ALLOW", () => {
    const cmd = `cat > /tmp/body.md <<'BODY'\nsome prose about gh issue create invocations\nBODY`;
    assert.equal(isGhWriteCommand(cmd), false);
  });

  test("FP1: multi-line heredoc body with gh issue create line → ALLOW", () => {
    const cmd = [
      "cat > /tmp/body.md <<'EOF'",
      "gh issue create --title X --body Y",
      "EOF",
    ].join("\n");
    assert.equal(isGhWriteCommand(cmd), false);
  });

  test("FP2: memory-helper.sh --content quoting gh issue create → ALLOW", () => {
    const cmd =
      'memory-helper.sh store --content "the gh create step fails on label validation"';
    assert.equal(isGhWriteCommand(cmd), false);
  });

  test("FP2: any non-gh tool with quoted gh issue create arg → ALLOW", () => {
    assert.equal(
      isGhWriteCommand('echo "to file a comment, run gh issue comment N"'),
      false,
    );
  });

  test("FP3: rg pattern containing gh issue create → ALLOW", () => {
    assert.equal(isGhWriteCommand('rg "gh issue create" src/'), false);
  });

  test("FP3: grep pattern containing gh pr create → ALLOW", () => {
    assert.equal(
      isGhWriteCommand('grep -n "gh pr create" --include="*.md"'),
      false,
    );
  });

  // Legitimate chained gh invocations must still be detected.

  test("chained: foo && gh issue create → BLOCK", () => {
    assert.equal(
      isGhWriteCommand('foo && gh issue create --title X --body Y'),
      true,
    );
  });

  test("command substitution: $(gh issue comment N) → BLOCK", () => {
    assert.equal(
      isGhWriteCommand('result=$(gh issue comment 123 --body "x")'),
      true,
    );
  });

  test("semicolon chain: setup; gh pr create → BLOCK", () => {
    assert.equal(
      isGhWriteCommand('git add .; gh pr create --title t --body b'),
      true,
    );
  });
});

// ---------------------------------------------------------------------------
// isMachineProtocolCommand
// ---------------------------------------------------------------------------

describe("isMachineProtocolCommand", () => {
  test("detects DISPATCH_CLAIM", () => {
    assert.equal(
      isMachineProtocolCommand(
        'gh issue comment 1 --body "DISPATCH_CLAIM pid=123"',
      ),
      true,
    );
  });

  test("detects KILL_WORKER", () => {
    assert.equal(
      isMachineProtocolCommand('gh issue comment 1 --body "KILL_WORKER reason=foo"'),
      true,
    );
  });

  test("detects MERGE_SUMMARY marker", () => {
    assert.equal(
      isMachineProtocolCommand(
        'gh issue comment 1 --body "<!-- MERGE_SUMMARY -->\\nsummary"',
      ),
      true,
    );
  });

  test("ignores plain prose", () => {
    assert.equal(
      isMachineProtocolCommand('gh issue comment 1 --body "thanks for the fix"'),
      false,
    );
  });

  test("ignores non-string input", () => {
    assert.equal(isMachineProtocolCommand(undefined), false);
    assert.equal(isMachineProtocolCommand({ body: "DISPATCH_ACK" }), false);
  });
});

// ---------------------------------------------------------------------------
// hasTrustedSignatureSignal
// ---------------------------------------------------------------------------

describe("hasTrustedSignatureSignal", () => {
  test("accepts gh-signature-helper.sh invocation", () => {
    assert.equal(
      hasTrustedSignatureSignal(
        'gh issue comment 1 --body "x $(gh-signature-helper.sh footer)"',
      ),
      true,
    );
  });

  test("accepts inline canonical marker", () => {
    assert.equal(
      hasTrustedSignatureSignal(
        `gh issue comment 1 --body "body\\n\\n${SIG_MARKER}\\n---\\nfooter"`,
      ),
      true,
    );
  });

  test("accepts $FOOTER variable interpolation", () => {
    assert.equal(
      hasTrustedSignatureSignal('gh issue comment 1 --body "msg $FOOTER"'),
      true,
    );
  });

  test("accepts ${SIGNATURE} interpolation", () => {
    assert.equal(
      hasTrustedSignatureSignal('gh issue comment 1 --body "msg ${SIGNATURE}"'),
      true,
    );
  });

  test("REJECTS bare 'aidevops.sh' literal (t2685 regression)", () => {
    // This is the precise failure mode that t2685 fixes.
    // Prior implementation accepted any command containing "aidevops.sh",
    // so a hallucinated human-readable footer passed the gate.
    assert.equal(
      hasTrustedSignatureSignal(
        'gh issue comment 1 --body "... from aidevops.sh interactive session."',
      ),
      false,
    );
  });

  test("rejects plain prose", () => {
    assert.equal(
      hasTrustedSignatureSignal('gh issue comment 1 --body "thanks"'),
      false,
    );
  });

  test("ignores non-string input", () => {
    assert.equal(hasTrustedSignatureSignal(undefined), false);
    assert.equal(hasTrustedSignatureSignal({ body: SIG_MARKER }), false);
  });
});

// ---------------------------------------------------------------------------
// tryRepairSignature
// ---------------------------------------------------------------------------

describe("tryRepairSignature", () => {
  test("repairs --body \"...\" by appending sig before closing quote", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "ok");
    assert.ok(out.cmd.includes(SIG_MARKER), `expected marker in repaired cmd: ${out.cmd}`);
    assert.ok(out.cmd.includes("hello"), "original body preserved");
  });

  test("repairs --body=value equals form", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body="hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "ok");
    assert.ok(out.cmd.includes(SIG_MARKER));
    assert.ok(out.cmd.includes("hello"));
  });

  test("appends sig to --body-file on disk", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "body.md");
    writeFileSync(bodyFile, "unsigned content\n");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "ok", "repair should succeed on body-file");
    const fileContent = readFileSync(bodyFile, "utf-8");
    assert.ok(
      fileContent.includes(SIG_MARKER),
      `sig should be appended to file: ${fileContent}`,
    );
    assert.ok(fileContent.includes("unsigned content"), "original preserved");
  });

  test("resolves relative --body-file from Bash tool workdir", () => {
    const dir = setupStubHelper();
    const workdir = join(dir, "linked-worktree-cwd");
    mkdirSync(workdir);
    const bodyFile = join(workdir, "relative-body.md");
    writeFileSync(bodyFile, "relative unsigned content\n");
    const { log } = makeLogger();
    const cmd = "gh pr create --repo o/r --title test --body-file relative-body.md";
    const out = tryRepairSignature(cmd, dir, log, { commandWorkdir: workdir });
    assert.equal(out.status, "ok", "relative body-file should resolve from command workdir");
    assert.ok(readFileSync(bodyFile, "utf-8").includes(SIG_MARKER));
  });

  test("allows absolute --body-file from a linked worktree for the same repo", () => {
    const dir = setupStubHelper();
    const repo = join(dir, "repo");
    const linked = join(dir, "repo-linked");
    mkdirSync(repo);
    execFileSync("/usr/bin/git", ["init"], { cwd: repo, stdio: "ignore" });
    execFileSync("/usr/bin/git", ["config", "user.email", "test@example.invalid"], { cwd: repo });
    execFileSync("/usr/bin/git", ["config", "user.name", "Test"], { cwd: repo });
    execFileSync("/usr/bin/git", ["config", "commit.gpgsign", "false"], { cwd: repo });
    writeFileSync(join(repo, "README.md"), "fixture\n");
    execFileSync("/usr/bin/git", ["add", "README.md"], { cwd: repo, stdio: "ignore" });
    execFileSync("/usr/bin/git", ["commit", "--no-gpg-sign", "-m", "init"], { cwd: repo, stdio: "ignore" });
    execFileSync("/usr/bin/git", ["worktree", "add", "-b", "linked-fixture", linked], {
      cwd: repo,
      stdio: "ignore",
    });
    const bodyFile = join(linked, "linked-body.md");
    writeFileSync(bodyFile, "linked unsigned content\n");
    const { log } = makeLogger();
    const cmd = `gh pr create --repo o/r --title test --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log, { commandWorkdir: repo });
    assert.equal(out.status, "ok", "same-repo linked worktree body-file should be allowed");
    assert.ok(readFileSync(bodyFile, "utf-8").includes(SIG_MARKER));
  });

  test("allows --body-file under configured AIDEVOPS_TEMP_DIR", () => {
    const dir = setupStubHelper();
    const customRoot = mkdtempSync(join(homedir(), ".t27910-custom-temp-"));
    const bodyFile = join(customRoot, "body.md");
    const priorTempDir = process.env.AIDEVOPS_TEMP_DIR;
    try {
      process.env.AIDEVOPS_TEMP_DIR = customRoot;
      writeFileSync(bodyFile, "configured temp content\n");
      const { log } = makeLogger();
      const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
      const out = tryRepairSignature(cmd, dir, log);
      assert.equal(out.status, "ok");
      assert.ok(readFileSync(bodyFile, "utf-8").includes(SIG_MARKER));
    } finally {
      if (priorTempDir === undefined) delete process.env.AIDEVOPS_TEMP_DIR;
      else process.env.AIDEVOPS_TEMP_DIR = priorTempDir;
      rmSync(customRoot, { recursive: true, force: true });
    }
  });

  test("allows --body-file under the default aidevops temp root", () => {
    const dir = setupStubHelper();
    const defaultRoot = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
    mkdirSync(defaultRoot, { recursive: true });
    const fixtureRoot = mkdtempSync(join(defaultRoot, "t27910-default-temp-"));
    const bodyFile = join(fixtureRoot, "body.md");
    const priorTempDir = process.env.AIDEVOPS_TEMP_DIR;
    try {
      delete process.env.AIDEVOPS_TEMP_DIR;
      writeFileSync(bodyFile, "default temp content\n");
      const { log } = makeLogger();
      const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
      const out = tryRepairSignature(cmd, dir, log);
      assert.equal(out.status, "ok");
      assert.ok(readFileSync(bodyFile, "utf-8").includes(SIG_MARKER));
    } finally {
      if (priorTempDir === undefined) delete process.env.AIDEVOPS_TEMP_DIR;
      else process.env.AIDEVOPS_TEMP_DIR = priorTempDir;
      rmSync(fixtureRoot, { recursive: true, force: true });
    }
  });

  test("uses cheap no-session helper path when repairing body-file", () => {
    const dir = mkdtempSync(join(tmpdir(), "t24374-fast-helper-"));
    const helper = join(dir, "gh-signature-helper.sh");
    const argvLog = join(dir, "helper-argv.log");
    const bodyFile = join(dir, "body.md");
    writeFileSync(bodyFile, "unsigned content\n");
    writeFileSync(
      helper,
      `#!/usr/bin/env bash
printf '%s\n' "$*" >"${argvLog}"
printf '\n\n${SIG_MARKER}\n---\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub\n'
`,
    );
    chmodSync(helper, 0o755);
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "ok");
    assert.match(readFileSync(argvLog, "utf-8"), /footer --no-session --body/);
  });

  test("does not invent a model when no signature model env is available", () => {
    const priorSigModel = process.env.AIDEVOPS_SIG_MODEL;
    const priorOpenCodeModel = process.env.OPENCODE_MODEL;
    delete process.env.AIDEVOPS_SIG_MODEL;
    delete process.env.OPENCODE_MODEL;

    try {
      const dir = mkdtempSync(join(tmpdir(), "t25903-no-model-fallback-"));
      const helper = join(dir, "gh-signature-helper.sh");
      const envLog = join(dir, "helper-env.log");
      writeFileSync(
        helper,
        `#!/usr/bin/env bash
printf '%s' "\${AIDEVOPS_SIG_MODEL-}" >"${envLog}"
printf '\n\n${SIG_MARKER}\n---\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub\n'
`,
      );
      chmodSync(helper, 0o755);
      const { log } = makeLogger();
      const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
      const out = tryRepairSignature(cmd, dir, log);
      assert.equal(out.status, "ok");
      assert.equal(readFileSync(envLog, "utf-8"), "");
      assert.doesNotMatch(out.cmd, /openai\/gpt-5\.5/);
    } finally {
      if (priorSigModel === undefined) {
        delete process.env.AIDEVOPS_SIG_MODEL;
      } else {
        process.env.AIDEVOPS_SIG_MODEL = priorSigModel;
      }
      if (priorOpenCodeModel === undefined) {
        delete process.env.OPENCODE_MODEL;
      } else {
        process.env.OPENCODE_MODEL = priorOpenCodeModel;
      }
    }
  });

  test("forwards OPENCODE_MODEL to the no-session signature helper", () => {
    const priorSigModel = process.env.AIDEVOPS_SIG_MODEL;
    const priorOpenCodeModel = process.env.OPENCODE_MODEL;
    delete process.env.AIDEVOPS_SIG_MODEL;
    process.env.OPENCODE_MODEL = "openai/example-model";

    try {
      const dir = mkdtempSync(join(tmpdir(), "t25903-opencode-model-"));
      const helper = join(dir, "gh-signature-helper.sh");
      const envLog = join(dir, "helper-env.log");
      writeFileSync(
        helper,
        `#!/usr/bin/env bash
printf '%s' "\${AIDEVOPS_SIG_MODEL-}" >"${envLog}"
printf '\n\n${SIG_MARKER}\n---\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub\n'
`,
      );
      chmodSync(helper, 0o755);
      const { log } = makeLogger();
      const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
      const out = tryRepairSignature(cmd, dir, log);
      assert.equal(out.status, "ok");
      assert.equal(readFileSync(envLog, "utf-8"), "openai/example-model");
    } finally {
      if (priorSigModel === undefined) {
        delete process.env.AIDEVOPS_SIG_MODEL;
      } else {
        process.env.AIDEVOPS_SIG_MODEL = priorSigModel;
      }
      if (priorOpenCodeModel === undefined) {
        delete process.env.OPENCODE_MODEL;
      } else {
        process.env.OPENCODE_MODEL = priorOpenCodeModel;
      }
    }
  });

  test("explicit session model overrides plugin-process model", () => {
    const priorSigModel = process.env.AIDEVOPS_SIG_MODEL;
    process.env.AIDEVOPS_SIG_MODEL = "openai/wrong-session";
    const dir = mkdtempSync(join(tmpdir(), "session-model-"));
    try {
      const helper = join(dir, "gh-signature-helper.sh");
      const envLog = join(dir, "helper-env.log");
      writeFileSync(
        helper,
        `#!/usr/bin/env bash
printf '%s' "\${AIDEVOPS_SIG_MODEL-}" >"${envLog}"
printf '\n\n${SIG_MARKER}\n---\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub\n'
`,
      );
      chmodSync(helper, 0o755);
      const { log } = makeLogger();
      const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
      const out = tryRepairSignature(cmd, dir, log, { model: "anthropic/correct-session" });
      assert.equal(out.status, "ok");
      assert.equal(readFileSync(envLog, "utf-8"), "anthropic/correct-session");
    } finally {
      if (priorSigModel === undefined) delete process.env.AIDEVOPS_SIG_MODEL;
      else process.env.AIDEVOPS_SIG_MODEL = priorSigModel;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("pre-execution hook resolves model by session without process-env leakage", async () => {
    const priorSigModel = process.env.AIDEVOPS_SIG_MODEL;
    process.env.AIDEVOPS_SIG_MODEL = "openai/stale-global";
    const dir = mkdtempSync(join(tmpdir(), "session-hook-model-"));
    try {
      const scriptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "scripts");
      const hooks = createQualityHooks({
        scriptsDir,
        logsDir: dir,
        resolveSessionModel: (sessionId) =>
          sessionId === "session-a" ? "anthropic/session-a" : "",
      });

      const sessionAOutput = {
        args: { command: 'gh issue comment 1 --repo o/r --body "one"', workdir: process.cwd() },
      };
      await hooks.toolExecuteBefore(
        { tool: "bash", sessionID: "session-a" },
        sessionAOutput,
      );
      const sessionBOutput = {
        args: { command: 'gh issue comment 1 --repo o/r --body "two"', workdir: process.cwd() },
      };
      await hooks.toolExecuteBefore(
        { tool: "bash", sessionID: "session-b" },
        sessionBOutput,
      );

      assert.match(sessionAOutput.args.command, / with session-a/);
      assert.doesNotMatch(sessionBOutput.args.command, / with stale-global/);
    } finally {
      if (priorSigModel === undefined) delete process.env.AIDEVOPS_SIG_MODEL;
      else process.env.AIDEVOPS_SIG_MODEL = priorSigModel;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("allows same-command body-file creation for exec-time shim repair", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "created-later.md");
    const { log, entries } = makeLogger();
    const cmd = `printf 'body\\n' > ${bodyFile} && gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.deepEqual(out, { status: "ok", cmd });
    assert.ok(
      entries.some((entry) => /deferring signature injection to PATH shim/.test(entry.msg)),
      "same-command creation should be explicitly delegated to shim",
    );
  });

  test("allows same-command body-file creation with echo for exec-time shim repair", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "created-later-echo.md");
    const { log, entries } = makeLogger();
    const cmd = `echo 'body' > ${bodyFile} && gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.deepEqual(out, { status: "ok", cmd });
    assert.ok(
      entries.some((entry) => /deferring signature injection to PATH shim/.test(entry.msg)),
      "same-command creation with echo should be explicitly delegated to shim",
    );
  });

  test("allows same-command body-file creation after earlier gh command text", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "created-after-gh.md");
    const { log, entries } = makeLogger();
    const cmd = `gh auth status >/dev/null && echo 'body' > ${bodyFile} && gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.deepEqual(out, { status: "ok", cmd });
    assert.ok(
      entries.some((entry) => /deferring signature injection to PATH shim/.test(entry.msg)),
      "same-command creation after earlier gh command text should be delegated to shim",
    );
  });

  test("is idempotent on already-signed --body-file", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "signed.md");
    writeFileSync(bodyFile, `already\n\n${SIG_MARKER}\n---\nsig\n`);
    const before = readFileSync(bodyFile, "utf-8");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "ok", "signed file repair returns ok");
    const after = readFileSync(bodyFile, "utf-8");
    assert.equal(before, after, "signed file should not be modified");
  });

  test("no-ops on signed command-substitution --body without reparsing", () => {
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "$(make-body && gh-signature-helper.sh footer)"';
    const out = tryRepairSignature(cmd, "/nonexistent/aidevops-helper-path", log);
    assert.deepEqual(out, { status: "ok", cmd });
  });

  test("no-ops on signed process-substitution --body-file without reparsing", () => {
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body-file <(make-body && gh-signature-helper.sh footer)';
    const out = tryRepairSignature(cmd, "/nonexistent/aidevops-helper-path", log);
    assert.deepEqual(out, { status: "ok", cmd });
  });

  test("no-ops on machine-protocol commands without requiring helper", () => {
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "<!-- MERGE_SUMMARY -->\\nsummary"';
    const out = tryRepairSignature(cmd, "/nonexistent/aidevops-helper-path", log);
    assert.deepEqual(out, { status: "ok", cmd });
  });

  test("no-ops on machine-protocol --body-file content", () => {
    const dir = mkdtempSync(join(tmpdir(), "t2685-machine-file-"));
    const bodyFile = join(dir, "machine-protocol.md");
    writeFileSync(bodyFile, "<!-- MERGE_SUMMARY -->\nsummary\n");
    const before = readFileSync(bodyFile, "utf-8");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    const after = readFileSync(bodyFile, "utf-8");
    assert.deepEqual(out, { status: "ok", cmd });
    assert.equal(after, before, "machine-protocol file should not be signed");
  });

  test("refuses to repair --body-file symlinks outside allowed directories", () => {
    const dir = setupStubHelper();
    const outsideDir = mkdtempSync(join(homedir(), ".t2685-outside-"));
    const outsideBodyFile = join(outsideDir, "body.md");
    const bodyFile = join(dir, "linked-body.md");
    try {
      writeFileSync(outsideBodyFile, "unsigned external content\n");
      symlinkSync(outsideBodyFile, bodyFile);
      const { log } = makeLogger();
      const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
      const out = tryRepairSignature(cmd, dir, log);
      const after = readFileSync(outsideBodyFile, "utf-8");
      assert.equal(out.status, "fail");
      assert.equal(out.reason, FAIL_REASON.BODY_FILE_OUTSIDE_ALLOWED_ROOT);
      assert.match(out.detail, /body\.md/);
      assert.equal(after, "unsigned external content\n", "outside target must not be modified");
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
    }
  });

  test("refuses to repair heredoc-sourced body (UNPARSEABLE_BODY)", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "$(cat <<EOF\nhello\nEOF\n)"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail", "heredoc body should not be auto-repaired");
    assert.match(out.reason, /heredoc|process substitution|command substitution/);
  });

  test("returns HELPER_MISSING when helper is missing", () => {
    const missingDir = "/nonexistent/path/aidevops-t2685";
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "x"';
    const out = tryRepairSignature(cmd, missingDir, log);
    assert.equal(out.status, "fail");
    assert.match(out.reason, /not found/);
  });
});

// ---------------------------------------------------------------------------
// checkSignatureFooterGate (end-to-end)
// ---------------------------------------------------------------------------

describe("checkSignatureFooterGate", () => {
  test("no-ops on non-gh-write commands", () => {
    const { log } = makeLogger();
    const output = { args: { command: "ls -la" } };
    // Should not throw, should not mutate
    checkSignatureFooterGate("ls -la", log, "/nonexistent", output);
    assert.equal(output.args.command, "ls -la");
  });

  test("no-ops on machine-protocol commands", () => {
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "DISPATCH_CLAIM pid=123"';
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, "/nonexistent", output);
    assert.equal(output.args.command, cmd);
  });

  test("no-ops on commands with canonical marker in body", () => {
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --body "x\\n${SIG_MARKER}\\nfooter"`;
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, "/nonexistent", output);
    assert.equal(output.args.command, cmd);
  });

  test("no-ops on commands calling gh-signature-helper", () => {
    const { log } = makeLogger();
    const cmd =
      'gh issue comment 1 --body "body $(gh-signature-helper.sh footer)"';
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, "/nonexistent", output);
    assert.equal(output.args.command, cmd);
  });

  test("REPAIRS simple --body command in place (t2685)", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, dir, output);
    assert.notEqual(output.args.command, cmd, "command should be mutated");
    assert.ok(
      output.args.command.includes(SIG_MARKER),
      `repaired command should have marker: ${output.args.command}`,
    );
  });

  test("BLOCKS unparseable body (heredoc) with mentoring error", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd =
      'gh issue comment 1 --body-file <(echo "dynamic body via process subst")';
    const output = { args: { command: cmd } };
    assert.throws(
      () => checkSignatureFooterGate(cmd, log, dir, output),
      /blocked at signature gate/,
    );
  });

  test("BLOCKS bare 'aidevops.sh' prose (t2685 regression test)", () => {
    // The canonical t2685 failure mode: a command where the body prose
    // contains the literal "aidevops.sh" but no sig marker and no helper
    // invocation. Prior hook accepted this; the tightened hook blocks.
    const dir = setupStubHelper();
    const { log } = makeLogger();
    // Use a body form the repair path cannot safely rewrite (heredoc)
    // so we exercise the block path specifically.
    const cmd =
      'gh issue comment 1 --body <<(cat <<EOF\n... from aidevops.sh session\nEOF\n)';
    const output = { args: { command: cmd } };
    assert.throws(
      () => checkSignatureFooterGate(cmd, log, dir, output),
      /blocked at signature gate/,
    );
  });
});

// ---------------------------------------------------------------------------
// t2893: Structured failure causes
// ---------------------------------------------------------------------------
// Each FAIL_REASON value must surface as a distinct, named cause so the
// throw-site error message can mentor the next attempt with the correct
// hypothesis instead of the pre-t2893 generic "likely heredoc/cmd-sub/quoting"
// guess. These tests exercise tryRepairSignature directly (asserting the
// structured return) and the end-to-end gate (asserting the throw message
// contains the specific reason and, for FILE_NOT_FOUND, the same-bash-call
// hint).
// ---------------------------------------------------------------------------

describe("FAIL_REASON enum (t2893)", () => {
  test("exposes the canonical failure reasons", () => {
    const expected = [
      "FILE_NOT_FOUND",
      "FILE_UNREADABLE",
      "BODY_FILE_OUTSIDE_ALLOWED_ROOT",
      "HELPER_MISSING",
      "HELPER_FAILED",
      "UNPARSEABLE_BODY",
      "BODY_ARG_QUOTING",
      "BODY_ARG_NO_MATCH",
    ];
    for (const key of expected) {
      assert.ok(
        typeof FAIL_REASON[key] === "string" && FAIL_REASON[key].length > 0,
        `FAIL_REASON.${key} must be a non-empty string`,
      );
    }
  });
});

describe("tryRepairSignature structured failures (t2893)", () => {
  test("FILE_NOT_FOUND: --body-file pointing at a path that does not exist", () => {
    const dir = setupStubHelper();
    const missingFile = join(dir, "does-not-exist-yet.md");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${missingFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.FILE_NOT_FOUND);
    assert.ok(out.detail.includes(missingFile), "detail should name the missing path");
  });

  test("HELPER_MISSING: scriptsDir contains no gh-signature-helper.sh", () => {
    const missingDir = "/nonexistent/aidevops-helper-path-t2893";
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const out = tryRepairSignature(cmd, missingDir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.HELPER_MISSING);
    assert.ok(out.detail.includes(missingDir), "detail should name the missing helper path");
  });

  test("UNPARSEABLE_BODY: heredoc-sourced --body", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "$(cat <<EOF\nhello\nEOF\n)"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.UNPARSEABLE_BODY);
  });

  test("UNPARSEABLE_BODY: process substitution --body-file", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body-file <(echo "dynamic")';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.UNPARSEABLE_BODY);
  });

  test("BODY_ARG_NO_MATCH: gh write with no --body / --body-file at all", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    // gh issue create with only --title — the body-arg parser finds nothing
    // to rewrite; the gate would block this on the tier-5 throw path.
    const cmd = 'gh issue create --title "x" --label bug';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.BODY_ARG_NO_MATCH);
  });

  test("HELPER_FAILED: helper exits non-zero", () => {
    // Stub a broken helper that exits 1 with no output.
    const dir = mkdtempSync(join(tmpdir(), "t2893-broken-"));
    const helper = join(dir, "gh-signature-helper.sh");
    writeFileSync(helper, "#!/usr/bin/env bash\nexit 1\n");
    chmodSync(helper, 0o755);
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.HELPER_FAILED);
  });

  test("HELPER_FAILED: helper output missing canonical marker", () => {
    // Stub a helper that emits text without the marker.
    const dir = mkdtempSync(join(tmpdir(), "t2893-nomarker-"));
    const helper = join(dir, "gh-signature-helper.sh");
    writeFileSync(helper, "#!/usr/bin/env bash\necho 'fake footer no marker'\n");
    chmodSync(helper, 0o755);
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.HELPER_FAILED);
    assert.match(out.detail, /missing canonical marker/);
  });

  test("BODY_ARG_QUOTING: signature contains the body's delimiter quote", () => {
    // Stub a helper that emits a sig containing a double quote.
    // The repair path uses the body's own delimiter to wrap the result;
    // if the sig contains that delimiter, escaping breaks and we must fail
    // with BODY_ARG_QUOTING rather than producing a malformed command.
    const dir = mkdtempSync(join(tmpdir(), "t2893-quoteclash-"));
    const helper = join(dir, "gh-signature-helper.sh");
    writeFileSync(
      helper,
      `#!/usr/bin/env bash\nprintf '\\n\\n${SIG_MARKER}\\n---\\nthis sig has a \\"quote\\" in it\\n'\n`,
    );
    chmodSync(helper, 0o755);
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out.status, "fail");
    assert.equal(out.reason, FAIL_REASON.BODY_ARG_QUOTING);
  });
});

describe("checkSignatureFooterGate throw message (t2893)", () => {
  test("FILE_NOT_FOUND throw includes same-bash-call hint", () => {
    const dir = setupStubHelper();
    const missingFile = join(dir, "race-condition.md");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${missingFile}`;
    const output = { args: { command: cmd } };
    let thrown;
    try {
      checkSignatureFooterGate(cmd, log, dir, output);
    } catch (e) {
      thrown = e;
    }
    assert.ok(thrown, "gate should throw");
    assert.match(thrown.message, /body-file not found/);
    assert.match(thrown.message, /same bash call/);
    assert.match(thrown.message, /shared-gh-wrappers\.sh/);
    assert.match(thrown.message, /two bash tool calls/i);
  });

  test("UNPARSEABLE_BODY throw names heredoc/process-sub/cmd-sub specifically", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body-file <(echo dynamic)';
    const output = { args: { command: cmd } };
    let thrown;
    try {
      checkSignatureFooterGate(cmd, log, dir, output);
    } catch (e) {
      thrown = e;
    }
    assert.ok(thrown);
    assert.match(thrown.message, /heredoc|process substitution|command substitution/);
    // Must NOT include the FILE_NOT_FOUND-specific hint
    assert.equal(/same bash call/.test(thrown.message), false);
  });

  test("HELPER_MISSING throw names the missing helper path specifically", () => {
    const missingDir = "/nonexistent/aidevops-helper-t2893-throw";
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "hello"';
    const output = { args: { command: cmd } };
    let thrown;
    try {
      checkSignatureFooterGate(cmd, log, missingDir, output);
    } catch (e) {
      thrown = e;
    }
    assert.ok(thrown);
    assert.match(thrown.message, /gh-signature-helper\.sh not found/);
  });

  test("throw message always includes Standard fixes section", () => {
    // Every failure reason should still surface the three canonical fix
    // patterns so the next attempt has actionable guidance regardless of
    // which specific cause fired.
    const dir = setupStubHelper();
    const missingFile = join(dir, "any-cause.md");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --body-file ${missingFile}`;
    const output = { args: { command: cmd } };
    let thrown;
    try {
      checkSignatureFooterGate(cmd, log, dir, output);
    } catch (e) {
      thrown = e;
    }
    assert.ok(thrown);
    assert.match(thrown.message, /Standard fixes/);
    assert.match(thrown.message, /Append to --body directly/);
    assert.match(thrown.message, /two-step pattern/);
    assert.match(thrown.message, /Source the wrapper/);
  });
});
