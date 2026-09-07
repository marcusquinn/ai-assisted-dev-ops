// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
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
import { promisify } from "node:util";

import {
  SOURCE_ACCESS_REASON,
  canonicalReceiptPayload,
  checkSecretReadWithApproval,
  createSourceAccessMutationProvenance,
  sourceAccessBrokerMatches,
  verifySourceAccessReceipt,
} from "../source-access-approval.mjs";
import { createQualityHooks } from "../quality-hooks.mjs";
import { createSourceAccessRuntime } from "../source-access-runtime.mjs";

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

test("canonical source payload matches the Python broker for Unicode paths", () => {
  const payload = { path: "/repo/secret-\u00e9.py", marker: "\u007f", astral: "\ud834\udd1e" };
  const expected = execFileSync("python3", ["-I", "-B", "-c",
    'import json,sys; print(json.dumps(json.loads(sys.argv[1]),sort_keys=True,separators=(",",":")),end="")',
    JSON.stringify(payload)], { encoding: "utf8" });
  assert.equal(canonicalReceiptPayload(payload), expected);
});

function manifestFixtureProtocol(bound) {
  const version = bound ? "v3" : "v2";
  return {
    payloadSchema: `aidevops-source-access-approval/${version}`,
    receiptSchema: `aidevops-source-access-receipt/${version}`,
    thirdPath: bound ? "secret-third-\u00e9.sh" : "secret-third.sh",
  };
}

function manifestCliVerifier({ root, stateDir, key, sessionId, now, socketPath }) {
  const configDir = join(root, "cli-config");
  mkdirSync(configDir, { mode: 0o700 });
  writeFileSync(join(configDir, "source-access.pub"), readFileSync(`${key}.pub`), { mode: 0o644 });
  const helper = fileURLToPath(new URL("../../../scripts/source-access-helper.py", import.meta.url));
  const script = 'import runpy,sys,json,os; from pathlib import Path; from unittest.mock import patch; '
    + 'h=runpy.run_path(sys.argv[1]); '
    + 'cfg=h["Config"](config_dir=Path(sys.argv[2]),state_dir=Path(sys.argv[3]),trust_uid=os.getuid()); '
    + 'patch.object(h["time"],"time",return_value=int(sys.argv[4])).start(); '
    + 'args=h["build_parser"]().parse_args(json.loads(sys.argv[5])); '
    + 'sys.exit(h["_run_verify"](args,cfg,os.getuid(),Path.home()))';
  return async (filePath, options = {}) => {
    const argv = ["verify", "--session", options.sessionId ?? sessionId, "--path", filePath,
      "--reason", SOURCE_ACCESS_REASON, "--context-socket", options.socketPath ?? socketPath];
    const { stdout } = await promisify(execFile)("python3", ["-I", "-B", "-c", script,
      helper, configDir, stateDir, String(options.now ?? now), JSON.stringify(argv)], { timeout: 15000 });
    assert.equal(stdout.trim(), "VERIFIED");
  };
}

function revokeManifestFixture(stateDir, approvalId) {
  const helper = fileURLToPath(new URL("../../../scripts/source-access-helper.py", import.meta.url));
  const script = 'import runpy,sys,os; from pathlib import Path; h=runpy.run_path(sys.argv[1]); '
    + 'cfg=h["Config"](config_dir=Path(sys.argv[2]).parent/"cli-config",state_dir=Path(sys.argv[2]),trust_uid=os.getuid()); '
    + 'h["revoke_approval"](cfg,approval_id=sys.argv[3],uid=os.getuid())';
  execFileSync("python3", ["-I", "-B", "-c", script, helper, stateDir, approvalId], { timeout: 15000 });
}

function manifestFixtureStorage(stateDir, uid, approvalId, atomic) {
  const bundle = join(stateDir, "bundles", String(uid), approvalId);
  const layout = {
    false: { snapshots: join(stateDir, "snapshots", String(uid)), receipts: join(stateDir, "approvals", String(uid)),
      name: `${approvalId}.json`, prefix: `${approvalId}-`, fields: {} },
    true: { snapshots: bundle, receipts: bundle, name: "receipt.json", prefix: "",
      fields: { snapshot_layout: "atomic-directory/v1" } },
  }[String(atomic)];
  mkdirSync(layout.snapshots, { recursive: true, mode: 0o755 });
  mkdirSync(layout.receipts, { recursive: true, mode: 0o755 });
  if (atomic) mkdirSync(join(stateDir, "revocations", String(uid)), { recursive: true, mode: 0o755 });
  return {
    fields: layout.fields,
    receiptPath: join(layout.receipts, layout.name),
    snapshotPath: (entryId) => join(layout.snapshots, `${layout.prefix}${entryId}.source`),
  };
}

async function issueBundleFixture(root, key, stateDir, proposalId) {
  const helper = fileURLToPath(new URL("../../../scripts/source-access-helper.py", import.meta.url));
  // Real issuer, signatures, journals and native runtime IPC; only GitHub and
  // root ownership are synthetic. No installed broker or actual credential is used.
  const script = `import runpy,sys,json,os,shutil,subprocess
from pathlib import Path
from unittest.mock import patch
h=runpy.run_path(sys.argv[1]); c=h['_SOURCE_CORE']; root=Path(sys.argv[2]); uid=os.getuid()
cfg=c.Config(config_dir=root/'issuer-config',state_dir=Path(sys.argv[4]),request_root=root/'requests',trust_uid=uid)
cfg.private_key.parent.mkdir(parents=True,mode=0o700)
shutil.copyfile(sys.argv[3],cfg.private_key); cfg.private_key.chmod(0o600); h['setup_key_material'](cfg)
home=root/'fixture-home'; key=home/'.aidevops'/'approval-keys'/'private'/'approval.key'
key.parent.mkdir(parents=True,mode=0o700)
subprocess.run([h['SSH_KEYGEN'],'-q','-t','ed25519','-N','','-f',str(key)],check=True)
actor={'id':7,'node_id':'U_fixture','login':'fixture','type':'User'}; created='2026-09-01T12:00:00Z'
issue={'id':1234,'node_id':'I_fixture','number':123,'user':actor,'author_association':'OWNER','created_at':created,
       'title':'Fixture scope','body':'Synthetic issue acceptance','state':'open','locked':True,
       'active_lock_reason':'resolved','labels':[],'assignees':[actor],'milestone':None}
comments=[]; timeline=[{'id':20,'event':'locked','created_at':created,'actor':actor}]
def action(uid,reader,operation,body=b''):
    if operation=='publish': comments.append({'id':99,'node_id':'C_fixture','user':actor,'author_association':'OWNER',
                                              'created_at':created,'body':body.decode('utf-8')})
confirmed=[]; spec=h['ApprovalSpec'](sys.argv[5],home,uid,3600,1800000000,lambda scope: confirmed.append(scope) is None)
with patch.object(c,'github_credential_for_user',return_value='synthetic-fixture'), \\
     patch.object(c.GitHubIssueReader,'issue',return_value=issue), \\
     patch.object(c.GitHubIssueReader,'collection',side_effect=lambda kind: comments if kind=='comments' else timeline), \\
     patch.object(c,'github_issue_action',side_effect=action):
    payload=h['approve_bundle'](cfg,spec,'fixture/repo',123)
assert len(confirmed)==1 and len(comments)==1
receipt=c.manifest_receipt_paths(cfg,uid)[0]; result=json.loads(receipt.read_text()); result['receiptPath']=str(receipt)
print(json.dumps(result))
`;
  const { stdout } = await promisify(execFile)("python3", ["-I", "-B", "-c", script,
    helper, root, key, stateDir, proposalId], { timeout: 20000 });
  return JSON.parse(stdout);
}

async function checkSignedManifest(inLinkedWorktree, bound = false, atomic = false) {
  const protocol = manifestFixtureProtocol(bound);
  const tempParent = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(tempParent, { recursive: true });
  const root = mkdtempSync(join(tempParent, "source-access-manifest-node-test-"));
  const repo = join(root, "repo");
  const canonicalRepo = inLinkedWorktree ? join(root, "canonical") : repo;
  const otherRepo = join(root, "other-repo");
  const key = join(root, "source-access-key");
  const stateDir = join(root, "state");
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  const sessionId = "ses_manifest_123456";
  const now = 1_800_000_000;
  let runtime;
  let runtimeRoot;
  const session = { id: sessionId, directory: canonicalRepo, projectID: "fixture", time: { created: 1000 } };

  try {
    mkdirSync(canonicalRepo);
    mkdirSync(otherRepo);
    execFileSync("/usr/bin/git", ["-C", canonicalRepo, "init", "--quiet"]);
    if (inLinkedWorktree) {
      execFileSync("/usr/bin/git", [
        "-C", canonicalRepo, "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
        "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture",
      ]);
      execFileSync("/usr/bin/git", ["-C", canonicalRepo, "worktree", "add", "--detach", "--quiet", repo]);
    }
    execFileSync("git", ["-C", otherRepo, "init", "--quiet"]);
    const relativePaths = ["secret-helper.sh", "secret-other.sh", protocol.thirdPath];
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

    const fsmonitor = join(root, "fsmonitor-fixture");
    writeFileSync(fsmonitor, "#!/bin/sh\ntouch fsmonitor-ran\nprintf 'fixture\\0'\n", { mode: 0o700 });
    const gitConfig = join(canonicalRepo, ".git", "config");
    writeFileSync(gitConfig, `${readFileSync(gitConfig, "utf8")}\n[core]\n\tfsmonitor = ${fsmonitor}\n`);
    let proposal;
    let proposalId;
    if (bound) {
      runtimeRoot = mkdtempSync(join(tempParent, "b"));
      const ownerScripts = join(root, "owner-scripts");
      mkdirSync(ownerScripts);
      writeFileSync(join(ownerScripts, "worktree-helper.sh"), '#!/bin/sh\nprintf "VERIFIED\\n"\n', { mode: 0o700 });
      runtime = createSourceAccessRuntime({ directory: canonicalRepo, scriptsDir: ownerScripts,
        tempDir: runtimeRoot, client: { session: { get: async () => ({ data: session }) } } });
      const env = await runtime.environment(sessionId);
      const helper = fileURLToPath(new URL("../../../scripts/source-access-helper.py", import.meta.url));
      const script = 'import runpy,sys,json,os,io; from pathlib import Path; '
        + 'from contextlib import redirect_stdout; from unittest.mock import patch; '
        + 'h=runpy.run_path(sys.argv[1]); c=h["_SOURCE_CORE"]; '
        + 'cfg=c.Config(request_root=Path(sys.argv[2])); '
        + 'a=h["build_parser"]().parse_args(["propose","--session",sys.argv[3],"--reason",c.OVERRIDABLE_REASON,'
        + '"--issue-snapshot-sha256","a"*64,"--context-socket",sys.argv[5]]'
        + '+[arg for path in json.loads(sys.argv[4]) for arg in ("--path",path)]); out=io.StringIO()\n'
        + 'with redirect_stdout(out),patch("time.time",return_value=1800000000): h["_run_propose"](a,cfg,os.getuid(),Path.home())\n'
        + 'i=out.getvalue().strip(); b=c.load_source_proposal(cfg,Path.home(),i,os.getuid()); '
        + 'c.revalidate_source_proposal_context(b,os.getuid()); '
        + 'print(json.dumps({"id":i,"body":b}))';
      const result = await promisify(execFile)("python3", ["-I", "-B", "-c", script, helper,
        join(root, "requests"), sessionId, JSON.stringify(paths), env.AIDEVOPS_SOURCE_CONTEXT_SOCKET], { timeout: 15000 });
      ({ id: proposalId, body: proposal } = JSON.parse(result.stdout));
    }
    let approvalId = bound ? proposalId : createHash("sha256")
      .update([sessionId, String(uid), repo, SOURCE_ACCESS_REASON, ...paths].join("\0"), "utf8")
      .digest("hex");
    const storage = manifestFixtureStorage(stateDir, uid, approvalId, atomic);
    let entries = paths.map((filePath, index) => {
      const entryId = createHash("sha256").update(filePath, "utf8").digest("hex").slice(0, 32);
      const snapshotPath = storage.snapshotPath(entryId);
      const content = readFileSync(filePath);
      writeFileSync(snapshotPath, content, { mode: 0o444 });
      return {
        path: filePath,
        relative_path: relativePaths[index],
        content_sha256: createHash("sha256").update(content).digest("hex"),
        snapshot_path: snapshotPath,
      };
    });
    let payload = {
      schema: protocol.payloadSchema,
      ...storage.fields,
      ...(bound ? { proposal, proposal_id: proposalId, issue_snapshot_sha256: proposal.issue_snapshot_sha256 } : {}),
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
    let signature = readFileSync(`${payloadPath}.sig`, "utf8");
    let receiptPath = storage.receiptPath;
    writeFileSync(
      receiptPath,
      JSON.stringify({ schema: protocol.receiptSchema, payload, signature }),
      { mode: 0o644 },
    );
    if (atomic) {
      // Remove the synthetic grant first: it must not mask an invalid issuer
      // receipt or let either consumer succeed through a second capability.
      rmSync(dirname(receiptPath), { recursive: true, force: true });
      ({ payload, signature, receiptPath } = await issueBundleFixture(root, key, stateDir, proposalId));
      approvalId = payload.approval_id;
      entries = payload.entries;
      proposal = payload.proposal;
    }
    const baseArgs = {
      sessionId,
      reason: SOURCE_ACCESS_REASON,
      repositoryDir: canonicalRepo,
      now: now + 1,
      uid,
      trustUid: uid,
      stateDir,
      publicKeyPath: `${key}.pub`,
      sourceContext: await runtime?.resolve(sessionId, repo),
    };
    const verifyCli = manifestCliVerifier({ root, stateDir, key, sessionId, now: now + 1,
      socketPath: proposal?.runtime_context.socket_path ?? "" });
    const scriptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "scripts");
    const logsDir = join(root, "logs");
    mkdirSync(logsDir);
    const hooks = createQualityHooks({
      scriptsDir,
      logsDir,
      repositoryDir: canonicalRepo,
      verifySourceAccessReceipt: (options) => verifySourceAccessReceipt({ ...baseArgs, ...options }),
      sourceAccessBrokerMatches: () => true,
      sourceAccessRuntime: runtime,
      sourceAccessRequestRun: () => {
        throw new Error("an exact signed manifest must not generate a per-path request");
      },
    });
    for (const filePath of paths) {
      await verifyCli(filePath);
      const approval = verifySourceAccessReceipt({ ...baseArgs, filePath });
      assert.ok(approval);
      assert.equal(readFileSync(approval.approvedPath, "utf8"), readFileSync(filePath, "utf8"));
      const output = { args: { filePath } };
      await hooks.toolExecuteBefore({ tool: "read", sessionID: sessionId, callID: filePath }, output);
      assert.equal(output.args.filePath, approval.approvedPath);
    }
    assert.equal(existsSync(join(repo, "fsmonitor-ran")), false, "source verification must not execute repository commands");
    assert.equal(existsSync(join(canonicalRepo, "fsmonitor-ran")), false, "runtime queries must not execute repository commands");
    if (bound) {
      await assert.rejects(verifyCli(paths[0], { socketPath: "" }));
      await assert.rejects(verifyCli(paths[0], { sessionId: "ses_other_manifest" }));
      await assert.rejects(verifyCli(paths[0], { now: now + 3600 }));
      await assert.rejects(verifyCli(extraPath));
      for (const [field, value] of [["runtime_instance_id", "f".repeat(32)], ["runtime_pid", process.pid + 1],
        ["session_created_at", 2000], ["project_id", "other"]]) {
        assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0],
          sourceContext: { ...baseArgs.sourceContext, [field]: value } }), false, field);
      }
      assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0], sourceContext: undefined }), false);
      session.time.created = 2000;
      await assert.rejects(verifyCli(paths[0]));
      await assert.rejects(hooks.toolExecuteBefore({ tool: "read", sessionID: sessionId, callID: "new-generation" },
        { args: { filePath: paths[0] } }), /secret-read-guard/);
      const helper = fileURLToPath(new URL("../../../scripts/source-access-helper.py", import.meta.url));
      const recheck = 'import runpy,sys,json,os; c=runpy.run_path(sys.argv[1])["_SOURCE_CORE"]; '
        + 'c.revalidate_source_proposal_context(json.loads(sys.argv[2]),os.getuid())';
      await assert.rejects(promisify(execFile)("python3", ["-I", "-B", "-c", recheck,
        helper, JSON.stringify(proposal)], { timeout: 10000 }), /proposal runtime changed/);
      session.time.created = 1000;
      const provenance = createSourceAccessMutationProvenance({ repositoryDir: canonicalRepo,
        now: () => now + 1, verify: (options) => verifySourceAccessReceipt({ ...baseArgs, ...options }) });
      provenance.rememberApproval({ sessionId, filePath: paths[0],
        approval: verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0] }) });
      const before = await runtime.resolve(sessionId, repo);
      provenance.beginMutation({ sessionId, callId: "bound-write", sourceContextForPath: () => before,
        mutations: [{ filePath: paths[0], kind: "write", content: "observed update\n" }] });
      writeFileSync(paths[0], "observed update\n");
      const after = await runtime.resolve(sessionId, repo);
      provenance.finishMutation({ sessionId, callId: "bound-write", succeeded: true, sourceContextForPath: () => after });
      const read = { sessionId, callId: "bound-read", filePath: paths[0], reason: SOURCE_ACCESS_REASON,
        args: { filePath: paths[0] }, sourceContext: await runtime.resolve(sessionId, repo) };
      assert.ok(provenance.authorizeRead(read));
      const output = { output: "original snapshot" };
      provenance.finishRead(sessionId, "bound-read", output, true);
      assert.equal(output.output, "observed update\n");
      assert.equal(provenance.authorizeRead({ ...read, callId: "no-context", sourceContext: undefined }), false);
      writeFileSync(paths[0], "source-0\n");
    }
    if (inLinkedWorktree) {
      const sibling = join(root, "unapproved-sibling");
      execFileSync("/usr/bin/git", ["-C", canonicalRepo, "worktree", "add", "--detach", "--quiet", sibling]);
      const siblingPath = join(sibling, relativePaths[0]);
      writeFileSync(siblingPath, "source-0\n");
      execFileSync("/usr/bin/git", ["-C", sibling, "add", relativePaths[0]]);
      assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: siblingPath }), false);
      assert.equal(verifySourceAccessReceipt({
        ...baseArgs,
        filePath: paths[0],
        gitRun: () => { throw new Error("Git identity unavailable"); },
      }), false);
      assert.equal(verifySourceAccessReceipt({
        ...baseArgs,
        filePath: paths[0],
        gitRun: (git, args, options) => args.includes("--porcelain")
          ? `worktree ${canonicalRepo}\0\0`
          : execFileSync(git, args, options),
      }), false);
    }
    assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0], repositoryDir: otherRepo }), false);
    assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0], sessionId: "ses_other_123456" }), false);
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
    revokeManifestFixture(stateDir, approvalId);
    assert.equal(existsSync(receiptPath), false);
    assert.ok(entries.every((entry) => !existsSync(entry.snapshot_path)));
    await assert.rejects(verifyCli(paths[0]));
    assert.equal(verifySourceAccessReceipt({ ...baseArgs, filePath: paths[0] }), false);
  } finally {
    runtime?.close();
    if (runtimeRoot) rmSync(runtimeRoot, { recursive: true, force: true });
    rmSync(root, { recursive: true, force: true });
  }
}

test("one signed manifest authorizes only three exact repository-bound paths", () => checkSignedManifest(false));
test("a canonical app context consumes its exact linked-worktree manifest without per-path requests", () => checkSignedManifest(true));
test("a V3 manifest binds native proposal context to the consuming runtime and fresh session generation", () => checkSignedManifest(true, true));
test("an atomic V3 manifest is consumed by CLI and Read and withdrawn as one bundle", () => checkSignedManifest(true, true, true));

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
