import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createQualityHooks } from "../quality-hooks.mjs";
import { rememberBashOutputPolicy } from "../output-compaction.mjs";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "aidevops-output-compaction-"));
  const capture = join(root, "captured.txt");
  const helper = join(root, "output-sandbox-helper.sh");
  const commandPolicy = join(root, "command-policy-helper.py");
  writeFileSync(helper, `#!/usr/bin/env bash\ncat > "${capture}"\nprintf 'bounded receipt\\nfull_log: output-sandbox-helper.sh show out_fixture\\n'\n`);
  writeFileSync(commandPolicy, 'import json\nprint(json.dumps({"decision": "allow"}))\n');
  chmodSync(helper, 0o700);
  return { root, capture };
}

test("live Bash after-hook replaces verbose success with retained receipt", async () => {
  const { root, capture } = fixture();
  const output = { output: "asset line\n".repeat(1000), metadata: { exitCode: 0 }, title: "build" };
  try {
    const hooks = createQualityHooks({ scriptsDir: root, logsDir: root });
    await hooks.toolExecuteBefore(
      { tool: "bash", callID: "call-verbose" },
      { args: { command: "npm test", workdir: root } },
    );
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-verbose" }, output);
    assert.match(output.output, /^bounded receipt/);
    assert.equal(readFileSync(capture, "utf8"), "asset line\n".repeat(1000));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("pre-scrub verbosity still produces a redacted compact receipt", async () => {
  const { root, capture } = fixture();
  const credential = `ghp_${"x".repeat(10000)}`;
  const output = { output: credential, metadata: { exitCode: 0 }, title: "test" };
  try {
    const hooks = createQualityHooks({ scriptsDir: root, logsDir: root });
    rememberBashOutputPolicy("call-redacted", { command: "npm test" });
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-redacted" }, output);
    assert.match(output.output, /^bounded receipt/);
    assert.equal(readFileSync(capture, "utf8"), "[redacted-credential]");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("live hook preserves failures, short output, and exact-output calls", async () => {
  const { root } = fixture();
  const hooks = createQualityHooks({ scriptsDir: root, logsDir: root });
  try {
    const failure = { output: "fatal: failed\n".repeat(1000), metadata: { exitCode: 7 } };
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-failure" }, failure);
    assert.match(failure.output, /^fatal: failed/);

    const short = { output: "short output", metadata: { exitCode: 0 } };
    rememberBashOutputPolicy("call-short", { command: "npm test" });
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-short" }, short);
    assert.equal(short.output, "short output");

    const exact = { output: "diff line\n".repeat(1000), metadata: { exitCode: 0 } };
    rememberBashOutputPolicy("call-exact", { command: "git diff --stat" });
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-exact" }, exact);
    assert.match(exact.output, /^diff line/);

    const arbitraryScript = { output: "deploy line\n".repeat(1000), metadata: { exitCode: 0 } };
    rememberBashOutputPolicy("call-arbitrary-script", { command: "npm run deploy" });
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-arbitrary-script" }, arbitraryScript);
    assert.match(arbitraryScript.output, /^deploy line/);

    const composed = { output: "composed line\n".repeat(1000), metadata: { exitCode: 0 } };
    rememberBashOutputPolicy("call-composed", { command: "npm test && git diff" });
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-composed" }, composed);
    assert.match(composed.output, /^composed line/);

    const unpaired = { output: "unpaired line\n".repeat(1000), metadata: { exitCode: 0 } };
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-unpaired" }, unpaired);
    assert.match(unpaired.output, /^unpaired line/);

    const structured = { output: { result: "x".repeat(10000) }, metadata: { exitCode: 0 } };
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-structured" }, structured);
    assert.equal(typeof structured.output, "object");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("live hook returns native output when retention fails", async () => {
  const { root } = fixture();
  const helper = join(root, "output-sandbox-helper.sh");
  writeFileSync(helper, "#!/usr/bin/env bash\nexit 1\n");
  chmodSync(helper, 0o700);
  const native = "native output\n".repeat(1000);
  const output = { output: native, metadata: { exitCode: 0 } };
  try {
    const hooks = createQualityHooks({ scriptsDir: root, logsDir: root });
    rememberBashOutputPolicy("call-retention-failure", { command: "npm test" });
    await hooks.toolExecuteAfter({ tool: "bash", callID: "call-retention-failure" }, output);
    assert.equal(output.output, native);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
