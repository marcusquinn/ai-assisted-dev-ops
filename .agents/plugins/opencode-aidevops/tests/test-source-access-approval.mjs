// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  linkSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  SOURCE_ACCESS_REASON,
  canonicalReceiptPayload,
  checkSecretReadWithApproval,
  createSourceAccessMutationProvenance,
  sourceAccessBrokerMatches,
  verifySourceAccessReceipt,
} from "../source-access-approval.mjs";
import { createQualityHooks } from "../quality-hooks.mjs";

const BASE = {
  tool: "read",
  args: { filePath: "/repo/secret-helper.sh" },
  sessionId: "ses_fixture_123456",
  callId: "call_fixture_123456",
  scriptsDir: "/framework/scripts",
  isReadTool: (tool) => tool.toLowerCase() === "read",
  secretReadBlockReason: () => SOURCE_ACCESS_REASON,
  brokerMatches: () => true,
  checkSecretReadGate: () => {
    throw new Error("[secret-read-guard] blocked read: secret-bearing basename");
  },
};

function mutationFixture() {
  const tempParent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(tempParent, { recursive: true });
  const root = mkdtempSync(join(tempParent, "source-access-mutation-test-"));
  const repo = join(root, "repo");
  const source = join(repo, "secret-helper.sh");
  const snapshot = join(root, "approved.source");
  const sessionId = "ses_mutation_123456";
  mkdirSync(repo);
  execFileSync("git", ["-C", repo, "init", "--quiet"]);
  writeFileSync(source, "one\n");
  writeFileSync(snapshot, "one\n");
  execFileSync("git", ["-C", repo, "add", "secret-helper.sh"]);
  const approval = {
    approvalId: "a".repeat(64),
    approvedPath: snapshot,
    canonicalPath: realpathSync(source),
    contentSha256: createHash("sha256").update("one\n").digest("hex"),
    expiresAt: 2_000_000_000,
    repoRoot: realpathSync(repo),
    relativePath: "secret-helper.sh",
  };
  const verify = ({ sessionId: requestedSession, filePath, authorizedApprovalId }) => {
    if (requestedSession !== sessionId || realpathSync(filePath) !== approval.canonicalPath) return false;
    if (authorizedApprovalId && authorizedApprovalId !== approval.approvalId) return false;
    if (!authorizedApprovalId && readFileSync(filePath, "utf8") !== "one\n") return false;
    return approval;
  };
  const provenance = createSourceAccessMutationProvenance({
    repositoryDir: repo,
    verify,
    now: () => 1_900_000_000,
  });
  provenance.rememberApproval({ sessionId, filePath: source, approval });
  return { approval, provenance, repo, root, sessionId, snapshot, source, verify };
}

function approvedMutationRead(fixture, callId, expected) {
  const args = { filePath: fixture.source };
  const approval = fixture.provenance.authorizeRead({
    sessionId: fixture.sessionId,
    callId,
    filePath: fixture.source,
    reason: SOURCE_ACCESS_REASON,
    args,
  });
  assert.ok(approval);
  const output = { output: "immutable approval snapshot" };
  fixture.provenance.finishRead(fixture.sessionId, callId, output, true);
  assert.equal(output.output, expected);
  assert.equal(output.metadata.sourceAccessContinuation, true);
}

test("a valid verifier result bypasses only the exact basename reason", () => {
  let gateCalls = 0;
  const args = { ...BASE.args };
  assert.doesNotThrow(() =>
    checkSecretReadWithApproval({
      ...BASE,
      args,
      checkSecretReadGate: () => {
        gateCalls += 1;
      },
      verify: ({ sessionId, filePath, reason }) =>
        sessionId === BASE.sessionId &&
        filePath === BASE.args.filePath &&
        reason === SOURCE_ACCESS_REASON
          ? {
              approvedPath: "/tmp/approved-source",
            }
          : false,
      requestRun: () => {
        throw new Error("request helper must not run");
      },
    }),
  );
  assert.equal(gateCalls, 0);
  assert.equal(args.filePath, "/tmp/approved-source");
});

test("an unapproved scope creates a request and preserves the original block", () => {
  const calls = [];
  assert.throws(
    () =>
      checkSecretReadWithApproval({
        ...BASE,
        verify: () => false,
        requestRun: (command, args) => {
          calls.push({ command, args });
          return "0123456789abcdef0123456789abcdef\n";
        },
      }),
    /sudo -k \/usr\/bin\/python3 -I -B \/etc\/aidevops\/source-access\/source-access-helper.py approve 0123456789abcdef0123456789abcdef --ttl 12h/,
  );
  assert.deepEqual(calls, [
    {
      command: "/usr/bin/python3",
      args: [
        "-I",
        "-B",
        "/etc/aidevops/source-access/source-access-helper.py",
        "request",
        "--session",
        BASE.sessionId,
        "--path",
        BASE.args.filePath,
        "--reason",
        SOURCE_ACCESS_REASON,
      ],
    },
  ]);
});

test("malformed request output cannot alter the displayed sudo command", () => {
  let error;
  try {
    checkSecretReadWithApproval({
      ...BASE,
      verify: () => false,
      requestRun: () => "0123456789abcdef0123456789abcdef; sudo attacker-command\n",
    });
  } catch (caught) {
    error = caught;
  }
  assert.ok(error instanceof Error);
  assert.match(error.message, /secret-read-guard/);
  assert.doesNotMatch(error.message, /To approve only this tracked source path/);
  assert.doesNotMatch(error.message, /attacker-command/);
});

test("hard-denial reasons never invoke the approval helper", () => {
  let helperCalls = 0;
  assert.throws(
    () =>
      checkSecretReadWithApproval({
        ...BASE,
        secretReadBlockReason: () => "private key path",
        verify: () => {
          helperCalls += 1;
          return true;
        },
        requestRun: () => {
          helperCalls += 1;
          return "";
        },
      }),
    /secret-read-guard/,
  );
  assert.equal(helperCalls, 0);
});

test("missing session identity preserves the original block without a request", () => {
  let helperCalls = 0;
  assert.throws(
    () =>
      checkSecretReadWithApproval({
        ...BASE,
        sessionId: "",
        verify: () => {
          helperCalls += 1;
          return true;
        },
        requestRun: () => {
          helperCalls += 1;
          return "";
        },
      }),
    /secret-read-guard/,
  );
  assert.equal(helperCalls, 0);
});

test("non-read tools retain the existing guard path", () => {
  let gateCalls = 0;
  checkSecretReadWithApproval({
    ...BASE,
    tool: "grep",
    checkSecretReadGate: () => {
      gateCalls += 1;
    },
    verify: () => {
      throw new Error("verifier must not run");
    },
    requestRun: () => {
      throw new Error("helper must not run");
    },
  });
  assert.equal(gateCalls, 1);
});

test("direct reads of root-managed snapshots are denied", () => {
  assert.throws(
    () =>
      checkSecretReadWithApproval({
        ...BASE,
        args: { filePath: "/var/run/aidevops/source-access/snapshots/501/example.source" },
        verify: () => {
          throw new Error("verifier must not run");
        },
        requestRun: () => {
          throw new Error("request helper must not run");
        },
      }),
    /direct reads of approval snapshots are denied/,
  );
});

test("a stale root broker fails closed without creating an approval request", () => {
  let helperCalls = 0;
  let verifierCalls = 0;
  assert.throws(
    () =>
      checkSecretReadWithApproval({
        ...BASE,
        brokerMatches: () => false,
        verify: () => {
          verifierCalls += 1;
          return true;
        },
        requestRun: () => {
          helperCalls += 1;
          return "";
        },
      }),
    /Run aidevops setup --scope source-access from an interactive terminal to reconcile it/,
  );
  assert.equal(verifierCalls, 0);
  assert.equal(helperCalls, 0);
});

test("broker matching requires exact deployed helper and core bytes", () => {
  const tempParent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(tempParent, { recursive: true });
  const root = mkdtempSync(join(tempParent, "source-access-broker-match-test-"));
  const scriptsDir = join(root, "scripts");
  const brokerDir = join(root, "broker");
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  try {
    mkdirSync(scriptsDir, { mode: 0o700 });
    // The broker matcher correctly rejects group-writable directories. Keep
    // this fixture trusted regardless of the host's collaborative umask.
    mkdirSync(brokerDir, { mode: 0o700 });
    const expectedHelper = join(scriptsDir, "source-access-helper.py");
    const expectedCore = join(scriptsDir, "source_access_core.py");
    const brokerHelper = join(brokerDir, "source-access-helper.py");
    const brokerCore = join(brokerDir, "source_access_core.py");
    writeFileSync(expectedHelper, "helper-v1\n", { mode: 0o644 });
    writeFileSync(expectedCore, "core-v1\n", { mode: 0o644 });
    writeFileSync(brokerHelper, "helper-v1\n", { mode: 0o644 });
    writeFileSync(brokerCore, "core-v1\n", { mode: 0o644 });
    const options = {
      scriptsDir,
      trustUid: uid,
      brokerHelperPath: brokerHelper,
      brokerCorePath: brokerCore,
    };
    assert.equal(sourceAccessBrokerMatches(options), true);
    writeFileSync(brokerCore, "core-v2\n", { mode: 0o644 });
    assert.equal(sourceAccessBrokerMatches(options), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("managed snapshot denial precedes read-tool classification", () => {
  let gateCalls = 0;
  assert.throws(
    () =>
      checkSecretReadWithApproval({
        ...BASE,
        tool: "functions.read",
        args: { filePath: "/var/run/aidevops/source-access/snapshots/501/example.source" },
        isReadTool: () => false,
        checkSecretReadGate: () => {
          gateCalls += 1;
        },
        verify: () => {
          throw new Error("verifier must not run");
        },
        requestRun: () => {
          throw new Error("request helper must not run");
        },
      }),
    /direct reads of approval snapshots are denied/,
  );
  assert.equal(gateCalls, 0);
});

test("composed OpenCode before-tool hook denies the live Read argument shape", async () => {
  const tempParent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(tempParent, { recursive: true });
  const logsDir = mkdtempSync(join(tempParent, "source-access-hook-test-"));
  const scriptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "scripts");

  try {
    const hooks = createQualityHooks({ scriptsDir, logsDir });
    await assert.rejects(
      hooks.toolExecuteBefore(
        { tool: "read", sessionID: BASE.sessionId },
        {
          args: {
            filePath:
              "/var/run/aidevops/source-access/snapshots/501/0123456789abcdef0123456789abcdef.source",
          },
        },
      ),
      /direct reads of approval snapshots are denied/,
    );
  } finally {
    rmSync(logsDir, { recursive: true, force: true });
  }
});

test("the loaded verifier accepts only the exact signed receipt", () => {
  const tempParent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(tempParent, { recursive: true });
  const root = mkdtempSync(join(tempParent, "source-access-node-test-"));
  const repo = join(root, "repo");
  const source = join(repo, "secret-helper.sh");
  const key = join(root, "source-access-key");
  const stateDir = join(root, "state");
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  const sessionId = "ses_fixture_123456";
  const now = 1_800_000_000;

  try {
    mkdirSync(repo);
    execFileSync("git", ["-C", repo, "init", "--quiet"]);
    writeFileSync(source, "#!/usr/bin/env bash\nprintf synthetic\\n\n");
    execFileSync("git", ["-C", repo, "add", "secret-helper.sh"]);
    execFileSync("/usr/bin/ssh-keygen", [
      "-q",
      "-t",
      "ed25519",
      "-N",
      "",
      "-C",
      "source-access@aidevops.sh",
      "-f",
      key,
    ]);

    const approvalId = createHash("sha256")
      .update(`${sessionId}\0${uid}\0${source}\0${SOURCE_ACCESS_REASON}`, "utf8")
      .digest("hex");
    const payload = {
      schema: "aidevops-source-access-approval/v1",
      approval_id: approvalId,
      request_id: "0123456789abcdef0123456789abcdef",
      session_id: sessionId,
      uid,
      path: source,
      reason: SOURCE_ACCESS_REASON,
      content_sha256: createHash("sha256").update(readFileSync(source)).digest("hex"),
      snapshot_path: join(stateDir, "snapshots", String(uid), `${approvalId}.source`),
      issued_at: now,
      expires_at: now + 3600,
    };
    const payloadPath = join(root, "payload.json");
    writeFileSync(payloadPath, canonicalReceiptPayload(payload));
    execFileSync("/usr/bin/ssh-keygen", [
      "-Y",
      "sign",
      "-f",
      key,
      "-n",
      "aidevops-source-access-v1",
      payloadPath,
    ]);
    const signature = readFileSync(`${payloadPath}.sig`, "utf8");
    const receiptDir = join(stateDir, "approvals", String(uid));
    const snapshotDir = join(stateDir, "snapshots", String(uid));
    mkdirSync(receiptDir, { recursive: true, mode: 0o755 });
    mkdirSync(snapshotDir, { recursive: true, mode: 0o755 });
    writeFileSync(payload.snapshot_path, readFileSync(source), { mode: 0o444 });
    writeFileSync(
      join(receiptDir, `${approvalId}.json`),
      JSON.stringify({
        schema: "aidevops-source-access-receipt/v1",
        payload,
        signature,
      }),
      { mode: 0o644 },
    );

    const verifierArgs = {
      sessionId,
      filePath: source,
      reason: SOURCE_ACCESS_REASON,
      now: now + 1,
      uid,
      trustUid: uid,
      stateDir,
      publicKeyPath: `${key}.pub`,
    };
    const approval = verifySourceAccessReceipt(verifierArgs);
    assert.ok(approval);
    assert.equal(readFileSync(approval.approvedPath, "utf8"), "#!/usr/bin/env bash\nprintf synthetic\\n\n");
    assert.equal(
      verifySourceAccessReceipt({ ...verifierArgs, sessionId: "ses_other_123456" }),
      false,
    );
    assert.equal(verifySourceAccessReceipt({ ...verifierArgs, now: now + 3600 }), false);
    writeFileSync(source, "changed\n");
    assert.equal(verifySourceAccessReceipt(verifierArgs), false);
    writeFileSync(source, "#!/usr/bin/env bash\nprintf synthetic\\n\n");
    execFileSync("git", ["-C", repo, "rm", "--cached", "--quiet", "secret-helper.sh"]);
    assert.equal(verifySourceAccessReceipt(verifierArgs), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("one signed manifest authorizes only three exact repository-bound paths", () => {
  const tempParent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(tempParent, { recursive: true });
  const root = mkdtempSync(join(tempParent, "source-access-manifest-node-test-"));
  const repo = join(root, "repo");
  const otherRepo = join(root, "other-repo");
  const key = join(root, "source-access-key");
  const stateDir = join(root, "state");
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  const sessionId = "ses_manifest_123456";
  const now = 1_800_000_000;

  try {
    mkdirSync(repo);
    mkdirSync(otherRepo);
    execFileSync("git", ["-C", repo, "init", "--quiet"]);
    execFileSync("git", ["-C", otherRepo, "init", "--quiet"]);
    const relativePaths = ["secret-helper.sh", "secret-other.sh", "secret-third.sh"];
    const paths = relativePaths.map((name, index) => {
      const filePath = join(repo, name);
      writeFileSync(filePath, `source-${index}\n`);
      return filePath;
    });
    execFileSync("git", ["-C", repo, "add", ...relativePaths]);
    const extraPath = join(repo, "secret-extra.sh");
    writeFileSync(extraPath, "extra\n");
    execFileSync("git", ["-C", repo, "add", "secret-extra.sh"]);
    const foreignPath = join(otherRepo, "secret-helper.sh");
    writeFileSync(foreignPath, "foreign\n");
    execFileSync("git", ["-C", otherRepo, "add", "secret-helper.sh"]);
    execFileSync("/usr/bin/ssh-keygen", [
      "-q", "-t", "ed25519", "-N", "", "-C", "source-access@aidevops.sh", "-f", key,
    ]);

    const approvalId = createHash("sha256")
      .update([sessionId, String(uid), repo, SOURCE_ACCESS_REASON, ...paths].join("\0"), "utf8")
      .digest("hex");
    const snapshotDir = join(stateDir, "snapshots", String(uid));
    const receiptDir = join(stateDir, "approvals", String(uid));
    mkdirSync(snapshotDir, { recursive: true, mode: 0o755 });
    mkdirSync(receiptDir, { recursive: true, mode: 0o755 });
    const entries = paths.map((filePath, index) => {
      const entryId = createHash("sha256").update(filePath, "utf8").digest("hex").slice(0, 32);
      const snapshotPath = join(snapshotDir, `${approvalId}-${entryId}.source`);
      const content = readFileSync(filePath);
      writeFileSync(snapshotPath, content, { mode: 0o444 });
      return {
        path: filePath,
        relative_path: relativePaths[index],
        content_sha256: createHash("sha256").update(content).digest("hex"),
        snapshot_path: snapshotPath,
      };
    });
    const payload = {
      schema: "aidevops-source-access-approval/v2",
      approval_id: approvalId,
      request_id: approvalId,
      session_id: sessionId,
      uid,
      repo_root: repo,
      repository_id: createHash("sha256").update(repo, "utf8").digest("hex"),
      reason: SOURCE_ACCESS_REASON,
      entries,
      issued_at: now,
      expires_at: now + 3600,
    };
    const payloadPath = join(root, "manifest-payload.json");
    writeFileSync(payloadPath, canonicalReceiptPayload(payload));
    execFileSync("/usr/bin/ssh-keygen", [
      "-Y", "sign", "-f", key, "-n", "aidevops-source-access-v1", payloadPath,
    ]);
    const signature = readFileSync(`${payloadPath}.sig`, "utf8");
    const receiptPath = join(receiptDir, `${approvalId}.json`);
    writeFileSync(
      receiptPath,
      JSON.stringify({ schema: "aidevops-source-access-receipt/v2", payload, signature }),
      { mode: 0o644 },
    );
    const baseArgs = {
      sessionId,
      reason: SOURCE_ACCESS_REASON,
      repositoryDir: repo,
      now: now + 1,
      uid,
      trustUid: uid,
      stateDir,
      publicKeyPath: `${key}.pub`,
    };
    for (const filePath of paths) {
      const approval = verifySourceAccessReceipt({ ...baseArgs, filePath });
      assert.ok(approval);
      assert.equal(readFileSync(approval.approvedPath, "utf8"), readFileSync(filePath, "utf8"));
    }
    assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: extraPath }), false);
    assert.equal(
      verifySourceAccessReceipt({ ...baseArgs, filePath: foreignPath, repositoryDir: otherRepo }),
      false,
    );
    assert.equal(
      verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0], now: now + 3600 }),
      false,
    );
    writeFileSync(paths[1], "altered\n");
    assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0] }), false);
    writeFileSync(paths[1], "source-1\n");
    rmSync(receiptPath);
    assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0] }), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("one approval survives verified Write, Edit, and apply_patch cycles", () => {
  const fixture = mutationFixture();
  try {
    fixture.provenance.beginMutation({
      sessionId: fixture.sessionId,
      callId: "write-1",
      mutations: [{ filePath: fixture.source, kind: "write", content: "two\n" }],
    });
    writeFileSync(fixture.source, "two\n");
    fixture.provenance.finishMutation({
      sessionId: fixture.sessionId,
      callId: "write-1",
      succeeded: true,
    });
    approvedMutationRead(fixture, "read-2", "two\n");

    fixture.provenance.beginMutation({
      sessionId: fixture.sessionId,
      callId: "edit-2",
      mutations: [{
        filePath: fixture.source,
        kind: "edit",
        oldString: "two",
        newString: "three",
        replaceAll: false,
      }],
    });
    writeFileSync(fixture.source, "three\n");
    fixture.provenance.finishMutation({
      sessionId: fixture.sessionId,
      callId: "edit-2",
      succeeded: true,
    });
    approvedMutationRead(fixture, "read-3", "three\n");

    fixture.provenance.beginMutation({
      sessionId: fixture.sessionId,
      callId: "patch-3",
      mutations: [{
        filePath: fixture.source,
        kind: "apply_patch",
        patchText: "\n@@\n-three\n+four\n",
      }],
    });
    writeFileSync(fixture.source, "four\n");
    fixture.provenance.finishMutation({
      sessionId: fixture.sessionId,
      callId: "patch-3",
      succeeded: true,
    });
    approvedMutationRead(fixture, "read-4", "four\n");

    const approval = fixture.provenance.authorizeRead({
      sessionId: fixture.sessionId,
      callId: "read-race",
      filePath: fixture.source,
      reason: SOURCE_ACCESS_REASON,
      args: { filePath: fixture.source },
    });
    assert.ok(approval);
    writeFileSync(fixture.source, "unobserved-after-verification\n");
    const output = { output: "stale snapshot" };
    fixture.provenance.finishRead(fixture.sessionId, "read-race", output, true);
    assert.equal(output.output, "four\n", "the returned bytes cannot race the live path");
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("failed, ambiguous, or mismatched mutations never advance authority", () => {
  for (const scenario of ["failed", "ambiguous", "mismatch"]) {
    const fixture = mutationFixture();
    try {
      fixture.provenance.beginMutation({
        sessionId: fixture.sessionId,
        callId: scenario,
        mutations: [{ filePath: fixture.source, kind: "write", content: "expected\n" }],
      });
      writeFileSync(fixture.source, scenario === "mismatch" ? "concurrent\n" : "expected\n");
      fixture.provenance.finishMutation({
        sessionId: fixture.sessionId,
        callId: scenario,
        succeeded: scenario === "mismatch",
      });
      assert.equal(
        fixture.provenance.authorizeRead({
          sessionId: fixture.sessionId,
          callId: `read-${scenario}`,
          filePath: fixture.source,
          reason: SOURCE_ACCESS_REASON,
          args: { filePath: fixture.source },
        }),
        false,
      );
      assert.equal(fixture.provenance.denialReason(fixture.sessionId, fixture.source), "drift");
    } finally {
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }
});

test("unobserved filesystem and identity transitions fail closed", () => {
  for (const scenario of ["external", "untracked", "hardlink", "symlink"]) {
    const fixture = mutationFixture();
    try {
      if (scenario === "external") writeFileSync(fixture.source, "external\n");
      if (scenario === "untracked") {
        execFileSync("git", ["-C", fixture.repo, "rm", "--cached", "--quiet", "secret-helper.sh"]);
      }
      if (scenario === "hardlink") linkSync(fixture.source, join(fixture.root, "linked.source"));
      if (scenario === "symlink") {
        rmSync(fixture.source);
        symlinkSync(fixture.snapshot, fixture.source);
      }
      assert.equal(
        fixture.provenance.authorizeRead({
          sessionId: fixture.sessionId,
          callId: `read-${scenario}`,
          filePath: fixture.source,
          reason: SOURCE_ACCESS_REASON,
          args: { filePath: fixture.source },
        }),
        false,
      );
    } finally {
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }
});

test("expiry, session changes, and plugin restart do not preserve mutation authority", () => {
  const fixture = mutationFixture();
  try {
    assert.equal(
      fixture.provenance.authorizeRead({
        sessionId: "ses_other_123456",
        callId: "wrong-session",
        filePath: fixture.source,
        reason: SOURCE_ACCESS_REASON,
        args: { filePath: fixture.source },
      }),
      false,
    );
    const restarted = createSourceAccessMutationProvenance({
      repositoryDir: fixture.repo,
      verify: fixture.verify,
      now: () => 1_900_000_000,
    });
    assert.equal(
      restarted.authorizeRead({
        sessionId: fixture.sessionId,
        callId: "restart",
        filePath: fixture.source,
        reason: SOURCE_ACCESS_REASON,
        args: { filePath: fixture.source },
      }),
      false,
    );
    const expired = createSourceAccessMutationProvenance({
      repositoryDir: fixture.repo,
      verify: fixture.verify,
      now: () => fixture.approval.expiresAt,
    });
    expired.rememberApproval({
      sessionId: fixture.sessionId,
      filePath: fixture.source,
      approval: fixture.approval,
    });
    assert.equal(
      expired.authorizeRead({
        sessionId: fixture.sessionId,
        callId: "expired",
        filePath: fixture.source,
        reason: SOURCE_ACCESS_REASON,
        args: { filePath: fixture.source },
      }),
      false,
    );
    assert.equal(expired.denialReason(fixture.sessionId, fixture.source), "expired");
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("denial guidance distinguishes missing approval from unobserved drift", () => {
  assert.throws(
    () => checkSecretReadWithApproval({
      ...BASE,
      verify: () => false,
      requestRun: () => "0123456789abcdef0123456789abcdef",
    }),
    /No source-access approval exists for this exact path and session/,
  );
  assert.throws(
    () => checkSecretReadWithApproval({
      ...BASE,
      verify: () => false,
      provenance: { authorizeRead: () => false, denialReason: () => "drift" },
      requestRun: () => "0123456789abcdef0123456789abcdef",
    }),
    /invalidated by an unobserved content transition/,
  );
});

test("pending reads are session-bound, success-bound, and preserve numbered output", () => {
  const fixture = mutationFixture();
  try {
    const args = { filePath: fixture.source, offset: 1, limit: 1 };
    assert.ok(fixture.provenance.authorizeRead({
      sessionId: fixture.sessionId,
      callId: "shared-call",
      filePath: fixture.source,
      reason: SOURCE_ACCESS_REASON,
      args,
    }));
    const wrongSession = { output: "<content>\n1: wrong\n</content>" };
    fixture.provenance.finishRead("ses_other_123456", "shared-call", wrongSession, true);
    assert.equal(wrongSession.output, "<content>\n1: wrong\n</content>");
    const failedRead = { output: "failed to read snapshot" };
    fixture.provenance.finishRead(fixture.sessionId, "shared-call", failedRead, false);
    assert.equal(failedRead.output, "failed to read snapshot");

    assert.ok(fixture.provenance.authorizeRead({
      sessionId: fixture.sessionId,
      callId: "numbered-call",
      filePath: fixture.source,
      reason: SOURCE_ACCESS_REASON,
      args,
    }));
    const numbered = { output: "<content>\n1: stale\n</content>" };
    fixture.provenance.finishRead(fixture.sessionId, "numbered-call", numbered, true);
    assert.equal(numbered.output, "<content>\n1: one\n</content>");
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});
