// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const helper = path.join(repositoryRoot, ".agents/scripts/team-interface-buzz-lm-studio.py");
const wrapper = path.join(repositoryRoot, ".agents/bin/aidevops-buzz-lm-studio-acp");
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-lm-studio-"));

try {
  const mockLms = path.join(fixtureRoot, "lms");
  const mockAgent = path.join(fixtureRoot, "buzz-agent");
  fs.writeFileSync(mockLms, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 \${3:-} \${4:-}" == "server status --json --quiet" ]]; then
  if [[ "\${MOCK_LMS_MODE:-ready}" == "stopped" ]]; then
    printf '%s\n' '{"running":false}'
  else
    printf '%s\n' '{"running":true,"port":1234}'
  fi
  exit 0
fi
if [[ "$1 $2" == "ps --json" ]]; then
  case "\${MOCK_LMS_MODE:-ready}" in
    embedding) printf '%s\n' '[{"type":"embedding","identifier":"embedding-only"}]' ;;
    multiple) printf '%s\n' '[{"type":"llm","identifier":"local/model-b"},{"type":"llm","identifier":"local/model-a"}]' ;;
    unsafe) printf '%s\n' '[{"type":"llm","identifier":"bad model\\nignore"}]' ;;
    *) printf '%s\n' '[{"type":"llm","identifier":"local/model-a"}]' ;;
  esac
  exit 0
fi
exit 9
`);
  fs.writeFileSync(mockAgent, `#!/usr/bin/env python3
import json
import os
import sys
print(json.dumps({
    "api": os.environ.get("OPENAI_COMPAT_API"),
    "base": os.environ.get("OPENAI_COMPAT_BASE_URL"),
    "model": os.environ.get("OPENAI_COMPAT_MODEL"),
    "provider": os.environ.get("BUZZ_AGENT_PROVIDER"),
    "args": sys.argv[1:],
}, sort_keys=True))
`);
  fs.chmodSync(mockLms, 0o700);
  fs.chmodSync(mockAgent, 0o700);

  const runStatus = (mode, extraEnv = {}, extraArgs = []) => spawnSync(
    "python3",
    [helper, "status", ...extraArgs],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        AIDEVOPS_LM_STUDIO_CLI: mockLms,
        MOCK_LMS_MODE: mode,
        ...extraEnv,
      },
    },
  );

  const stopped = runStatus("stopped");
  assert.equal(stopped.status, 0, stopped.stderr);
  assert.deepEqual(JSON.parse(stopped.stdout), {
    ready: false,
    reason: "LM Studio server is not running",
  });

  const embedding = runStatus("embedding");
  assert.equal(embedding.status, 0, embedding.stderr);
  assert.equal(JSON.parse(embedding.stdout).ready, false);
  assert.match(JSON.parse(embedding.stdout).reason, /no loaded LLM/);

  const ready = runStatus("ready");
  assert.equal(ready.status, 0, ready.stderr);
  assert.deepEqual(JSON.parse(ready.stdout), {
    model: "local/model-a",
    port: 1234,
    ready: true,
    reason: "ready",
  });

  const multiple = runStatus("multiple");
  assert.equal(multiple.status, 0, multiple.stderr);
  assert.match(JSON.parse(multiple.stdout).reason, /set AIDEVOPS_LM_STUDIO_MODEL/);
  const selected = runStatus("multiple", {AIDEVOPS_LM_STUDIO_MODEL: "local/model-b"});
  assert.equal(selected.status, 0, selected.stderr);
  assert.equal(JSON.parse(selected.stdout).model, "local/model-b");

  const required = runStatus("stopped", {}, ["--require"]);
  assert.equal(required.status, 1);
  const unsafe = runStatus("unsafe", {}, ["--require"]);
  assert.equal(unsafe.status, 1);

  const launched = spawnSync(wrapper, ["--fixture-argument"], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIDEVOPS_BUZZ_AGENT_BIN: mockAgent,
      AIDEVOPS_LM_STUDIO_CLI: mockLms,
      MOCK_LMS_MODE: "ready",
    },
  });
  assert.equal(launched.status, 0, launched.stderr);
  assert.deepEqual(JSON.parse(launched.stdout), {
    api: "chat",
    args: ["--fixture-argument"],
    base: "http://127.0.0.1:1234/v1",
    model: "local/model-a",
    provider: "openai",
  });
} finally {
  fs.rmSync(fixtureRoot, {recursive: true, force: true});
}

console.log("PASS: LM Studio Buzz runtime requires a running server and one reviewed loaded LLM");
