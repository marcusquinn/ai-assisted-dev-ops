#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, mkdirSync, openSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { getAccounts } from "../plugins/opencode-aidevops/oauth-pool-storage.mjs";
import { createRelay } from "./frontier-harness-oauth-relay.mjs";

const scripts = dirname(fileURLToPath(import.meta.url));
const repo = resolve(scripts, "../..");

async function main() {
  const { values } = parseArgs({ options: {
    task: { type: "string" }, out: { type: "string" },
    model: { type: "string", default: "gpt-6-astra" },
    profile: { type: "string", default: "stock" },
    "opencode-version": { type: "string", default: "1.18.29" },
    "install-only": { type: "boolean", default: false },
    "context-limit": { type: "string" }, "output-limit": { type: "string" },
  } });
  if (!["stock", "aidevops", "aidevops-native-compaction"].includes(values.profile)) {
    throw new Error("Unknown profile");
  }
  if (!isAbsolute(values.task || "") || !isAbsolute(values.out || "")) {
    throw new Error("--task and --out must be absolute paths; --out must not exist");
  }
  if (!/^\d+\.\d+\.\d+$/.test(values["opencode-version"])) throw new Error("Pin an exact OpenCode release");
  const contextLimit = values["context-limit"] === undefined ? null : Number(values["context-limit"]);
  const outputLimit = values["output-limit"] === undefined ? null : Number(values["output-limit"]);
  if ((contextLimit !== null || outputLimit !== null) && (!Number.isInteger(contextLimit)
    || !Number.isInteger(outputLimit) || contextLimit < 4096 || contextLimit > 1000000
    || outputLimit < 1024 || outputLimit >= contextLimit)) throw new Error("Provide valid paired context/output limits");
  const instruction = readFileSync(join(values.task, "instruction.md"));
  const taskConfig = readFileSync(join(values.task, "task.toml"));
  if (!statSync(dirname(values.out)).isDirectory()) throw new Error("Output parent must exist");
  const git = (...args) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
  if (git("status", "--porcelain")) throw new Error("Commit the integration before freezing a trial");
  const commit = git("rev-parse", "HEAD");
  // Select once from the user's existing OAuth pool; never read API-key env vars
  // and never rotate accounts after a failure. OAuth secrets remain host-only.
  const account = getAccounts("openai")
    .filter((a) => a.access && ["active", "idle"].includes(a.status)
      && a.expires > Date.now() + 1860000 && !(a.cooldownUntil > Date.now()))
    .sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  if (!account && !values["install-only"]) throw new Error("No fresh OpenAI OAuth account; no API fallback permitted");
  mkdirSync(values.out, { mode: 0o700 });
  const archive = join(values.out, "framework.tar");
  execFileSync("git", ["-C", repo, "archive", "--format=tar", "-o", archive, commit, ".agents"]);
  const manifest = {
    schema: 1, profile: values.profile, framework_commit: commit,
    opencode_version: values["opencode-version"], harbor_version: "0.22.0",
    model: values.model, inference_route: "chatgpt-pro-oauth-local-relay",
    paid_api_fallback: false, leaderboard_comparable: false,
    task_instruction_sha256: createHash("sha256").update(instruction).digest("hex"),
    task_config_sha256: createHash("sha256").update(taskConfig).digest("hex"),
    max_requests: 64, concurrency: 1, retries: 0, install_only: values["install-only"],
    agent_setup_timeout_multiplier: 2,
    experimental_context_limit: contextLimit, experimental_output_reserve: outputLimit,
    calibration_contract: values["opencode-version"] === "1.18.29"
      ? "opencode-1.18.29-explicit-input-v1" : "unsupported-runtime",
    requested_model_limits: contextLimit === null ? null
      : { context: contextLimit, input: contextLimit - outputLimit, output: outputLimit },
    started_at: new Date().toISOString(),
  };
  const save = () => writeFileSync(join(values.out, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  save();
  let relay;
  let log;
  let child;
  const stop = () => { manifest.interrupted = true; relay?.close(); child?.kill("SIGTERM"); };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    // Install-only receives an inert placeholder, never a live inference capability.
    relay = values["install-only"]
      ? { port: 9, key: "0".repeat(64), stats: () => ({ requests: 0 }), close: () => {} }
      : await createRelay({ model: values.model, account });
    log = openSync(join(values.out, "runner.log"), "wx", 0o600);
    // Explicit allowlist, not a copy of process.env: no real provider key, OAuth
    // token, global OpenCode config or host auth store reaches Harbor's agent.
    const env = {};
    for (const name of ["PATH", "TMPDIR"]) {
      if (process.env[name]) env[name] = process.env[name];
    }
    const home = join(values.out, "runner-home");
    mkdirSync(home, { mode: 0o700 });
    const pluginDir = join(home, ".docker/cli-plugins");
    mkdirSync(pluginDir, { recursive: true, mode: 0o700 });
    const plugins = JSON.parse(execFileSync("docker", ["info", "--format", "{{json .ClientInfo.Plugins}}"], { encoding: "utf8" }));
    for (const plugin of plugins) {
      if (["compose", "buildx"].includes(plugin.Name) && isAbsolute(plugin.Path)) {
        symlinkSync(plugin.Path, join(pluginDir, `docker-${plugin.Name}`));
      }
    }
    const dockerHost = execFileSync("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], { encoding: "utf8" }).trim();
    if (!dockerHost.startsWith("unix://")) throw new Error("Only local Docker sockets are supported");
    Object.assign(env, {
      HOME: home, XDG_CONFIG_HOME: join(home, ".config"), XDG_DATA_HOME: join(home, ".local/share"),
      XDG_CACHE_HOME: join(home, ".cache"), DOCKER_HOST: dockerHost,
      UV_CACHE_DIR: execFileSync("uv", ["cache", "dir"], { encoding: "utf8" }).trim(),
      PYTHONPATH: scripts, AIDEVOPS_EVAL_ARCHIVE: archive,
      AIDEVOPS_EVAL_RELAY_URL: `http://host.docker.internal:${relay.port}/v1`,
      AIDEVOPS_EVAL_RELAY_KEY: relay.key, OPENAI_API_KEY: relay.key,
    });
    const args = ["tool", "run", "--from", "harbor==0.22.0", "harbor", "run",
      "-p", values.task, "-a", "frontier_harness_agent:FrontierOpenCode",
      "-m", `openai/${values.model}`, "--ak", `profile=${values.profile}`,
      "--ak", `version=${values["opencode-version"]}`, "-n", "1", "-r", "0",
      "--agent-setup-timeout-multiplier", "2",
      "--jobs-dir", join(values.out, "jobs"), "--job-name", "pilot"];
    if (values["install-only"]) args.push("--install-only");
    if (contextLimit !== null) args.push("--ak", `context_limit=${contextLimit}`, "--ak", `output_limit=${outputLimit}`);
    child = spawn("uv", args, { cwd: repo, env, stdio: ["ignore", log, log] });
    const code = await new Promise((resolvePromise, reject) => {
      child.once("error", reject);
      child.once("exit", (status) => resolvePromise(status ?? 1));
    });
    manifest.runner_exit_code = code;
    const result = JSON.parse(readFileSync(join(values.out, "jobs/pilot/result.json"), "utf8"));
    manifest.completed_trials = result.stats?.n_completed_trials ?? null;
    manifest.errored_trials = result.stats?.n_errored_trials ?? null;
    const valid = code === 0 && manifest.completed_trials === 1 && manifest.errored_trials === 0;
    manifest.status = valid ? "runner_finished" : "runner_failed";
    console.log(JSON.stringify({ runner_exit_code: code, requests: relay.stats().requests,
      profile: values.profile, note: "Read the verifier result; runner exit zero is not a task pass" }));
    process.exitCode = valid ? 0 : 1;
  } catch {
    manifest.status = "infrastructure_error";
    process.exitCode = 1;
    console.error("Pilot infrastructure error; inspect private runner.log");
  } finally {
    manifest.relay = relay?.stats() ?? null;
    manifest.finished_at = new Date().toISOString();
    if (manifest.interrupted) manifest.status = "interrupted";
    save();
    relay?.close();
    if (log !== undefined) closeSync(log);
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
}

main().catch(() => {
  // Provider/child exceptions can include credential-bearing headers or config.
  console.error("Frontier pilot failed; inspect private local artifacts (never publish raw logs)");
  process.exitCode = 1;
});
