// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  SOURCE_ACCESS_REASON,
  canonicalReceiptPayload,
  checkSecretReadWithApproval,
  sourceAccessBrokerMatches,
  verifySourceAccessReceipt,
} from "../source-access-approval.mjs";

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
    /Run aidevops update from an interactive terminal to reconcile it/,
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
