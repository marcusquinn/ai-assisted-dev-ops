import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("OAuth refreshes serialize and preserve an omitted rotating refresh token", () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-oauth-state-"));
  const script = String.raw`
    import assert from "node:assert/strict";
    import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const home = process.env.HOME;
    const aidevopsDir = join(home, ".aidevops");
    const poolPath = join(aidevopsDir, "oauth-pool.json");
    const counterPath = join(home, "refresh-count");
    const binPath = join(home, "bin");
    mkdirSync(aidevopsDir, { recursive: true });
    mkdirSync(binPath, { recursive: true });
    writeFileSync(poolPath, JSON.stringify({ openai: [{
      email: "fixture@example.com",
      access: "old-access",
      refresh: "rotating-refresh",
      expires: 1,
      status: "active",
      cooldownUntil: 0,
    }] }), { mode: 0o600 });

    const curlPath = join(binPath, "curl");
    writeFileSync(curlPath, [
      "#!/usr/bin/env node",
      "const fs = require('node:fs');",
      "fs.appendFileSync(process.env.AIDEVOPS_TEST_REFRESH_COUNT, '1\\n');",
      "process.stdout.write('HTTP/1.1 200 OK\\r\\ncontent-type: application/json\\r\\n\\r\\n' +",
      "  JSON.stringify({ access_token: 'new-access', expires_in: 3600 }) + '\\n200');",
    ].join("\n"));
    chmodSync(curlPath, 0o755);
    process.env.PATH = binPath + ":" + process.env.PATH;
    process.env.AIDEVOPS_TEST_REFRESH_COUNT = counterPath;

    const { forceRefreshOpenAIToken } = await import("./oauth-pool-refresh.mjs?state=" + Math.random());
    const original = JSON.parse(readFileSync(poolPath, "utf-8")).openai[0];
    const first = { ...original };
    const second = { ...original };
    const results = await Promise.all([
      forceRefreshOpenAIToken(first),
      forceRefreshOpenAIToken(second),
    ]);

    const saved = JSON.parse(readFileSync(poolPath, "utf-8")).openai[0];
    assert.deepEqual(results, ["new-access", "new-access"]);
    assert.equal(readFileSync(counterPath, "utf-8").trim().split("\n").length, 1);
    assert.equal(saved.access, "new-access");
    assert.equal(saved.refresh, "rotating-refresh");
    assert.equal(first.refresh, "rotating-refresh");
    assert.equal(second.refresh, "rotating-refresh");
    assert.equal(statSync(aidevopsDir).mode & 0o777, 0o700);
    assert.equal(statSync(poolPath).mode & 0o777, 0o600);
    assert.equal(existsSync(poolPath + ".lock.d"), false);
  `;

  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home },
    stdio: "pipe",
  });
});

test("an in-flight refresh cannot overwrite newer durable credentials", () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-oauth-stale-response-"));
  const script = String.raw`
    import assert from "node:assert/strict";
    import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const aidevopsDir = join(process.env.HOME, ".aidevops");
    const poolPath = join(aidevopsDir, "oauth-pool.json");
    const binPath = join(process.env.HOME, "bin");
    mkdirSync(aidevopsDir, { recursive: true });
    mkdirSync(binPath, { recursive: true });
    writeFileSync(poolPath, JSON.stringify({ openai: [{
      email: "fixture@example.com",
      access: "old-access",
      refresh: "old-refresh",
      expires: 1,
      status: "active",
      cooldownUntil: 0,
    }] }), { mode: 0o600 });

    const curlPath = join(binPath, "curl");
    writeFileSync(curlPath, [
      "#!/usr/bin/env node",
      "const fs = require('node:fs');",
      "const path = process.env.AIDEVOPS_TEST_POOL_PATH;",
      "const pool = JSON.parse(fs.readFileSync(path, 'utf-8'));",
      "Object.assign(pool.openai[0], { access: 'reauth-access', refresh: 'reauth-refresh', expires: Date.now() + 7200000 });",
      "fs.writeFileSync(path + '.reauth', JSON.stringify(pool), { mode: 0o600 });",
      "fs.renameSync(path + '.reauth', path);",
      "process.stdout.write('HTTP/1.1 200 OK\\r\\ncontent-type: application/json\\r\\n\\r\\n' +",
      "  JSON.stringify({ access_token: 'stale-access', refresh_token: 'stale-refresh', expires_in: 3600 }) + '\\n200');",
    ].join("\n"));
    chmodSync(curlPath, 0o755);
    process.env.PATH = binPath + ":" + process.env.PATH;
    process.env.AIDEVOPS_TEST_POOL_PATH = poolPath;

    const { forceRefreshOpenAIToken } = await import("./oauth-pool-refresh.mjs?stale=" + Math.random());
    const account = { ...JSON.parse(readFileSync(poolPath, "utf-8")).openai[0] };
    const result = await forceRefreshOpenAIToken(account);
    const saved = JSON.parse(readFileSync(poolPath, "utf-8")).openai[0];

    assert.equal(result, "reauth-access");
    assert.equal(saved.access, "reauth-access");
    assert.equal(saved.refresh, "reauth-refresh");
    assert.equal(account.access, "reauth-access");
  `;

  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home },
    stdio: "pipe",
  });
});

test("JavaScript waits for the live Python owner of the shared lock", () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-oauth-cross-runtime-"));
  const commonPath = join(import.meta.dirname, "../../../scripts/oauth-pool-lib/_common.py");
  const script = String.raw`
    import assert from "node:assert/strict";
    import { spawn } from "node:child_process";
    import { existsSync, mkdirSync } from "node:fs";
    import { join } from "node:path";

    const poolPath = join(process.env.HOME, ".aidevops", "oauth-pool.json");
    mkdirSync(join(process.env.HOME, ".aidevops"), { recursive: true });
    const python = [
      "import importlib.util,json,os,time",
      "spec=importlib.util.spec_from_file_location('oauth_common',os.environ['AIDEVOPS_TEST_COMMON_PATH'])",
      "module=importlib.util.module_from_spec(spec)",
      "spec.loader.exec_module(module)",
      "lock=open(os.environ['AIDEVOPS_TEST_POOL_PATH']+'.lock','w')",
      "module.acquire_lock(lock)",
      "owner_path=lock.name+'.d/owner'",
      "owner=json.load(open(owner_path))",
      "owner['createdAt']=0",
      "json.dump(owner,open(owner_path,'w'))",
      "print('LOCKED',flush=True)",
      "time.sleep(0.35)",
      "module.release_lock(lock)",
      "lock.close()",
    ].join(";");
    const child = spawn("python3", ["-c", python], {
      env: { ...process.env, AIDEVOPS_TEST_POOL_PATH: poolPath },
      stdio: ["ignore", "pipe", "pipe"],
    });
    await new Promise((resolve, reject) => {
      child.stdout.once("data", resolve);
      child.once("error", reject);
      child.once("exit", (code) => { if (code !== 0) reject(new Error("python lock holder exited " + code)); });
    });

    const { withPoolLockAsync } = await import("./oauth-pool-storage.mjs?cross=" + Math.random());
    const started = Date.now();
    await withPoolLockAsync(async () => true);
    assert.ok(Date.now() - started >= 250);
    assert.equal(existsSync(poolPath + ".lock.d"), false);
  `;

  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home, AIDEVOPS_TEST_COMMON_PATH: commonPath },
    stdio: "pipe",
  });
});
