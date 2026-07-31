// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto"
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { runCommand } from "./ai-research-command"
import { parseOpenCodeRuntimeOutput } from "./ai-research-output"
import {
  ResearchRuntimeError,
  type CanonicalResearchTier,
  type CommandResult,
  type OpenCodeRuntimeOptions,
  type ResearchRuntimeAdapter,
  type ResearchRuntimeRequest,
} from "./ai-research-runtime-types"

const DEFAULT_RUNTIME_TIMEOUT_MS = 120_000
const MIN_TRANSPORT_OUTPUT_BYTES = 64 * 1024
const MAX_TRANSPORT_OUTPUT_BYTES = 1024 * 1024
const NESTED_LIFECYCLE_ENV_KEYS = [
  "AIDEVOPS_ATTEMPT_ID",
  "AIDEVOPS_ATTEMPT_STARTED_AT",
  "AIDEVOPS_CORRELATION_ID",
  "AIDEVOPS_DISPATCH_LEASE_DEVICE",
  "AIDEVOPS_DISPATCH_LEASE_TOKEN",
  "AIDEVOPS_PARENT_WORKER_ID",
  "AIDEVOPS_PERMISSION_GRANT_FILE",
  "AIDEVOPS_PERMISSION_REQUEST_ID",
  "AIDEVOPS_ROOT_WORKER_ID",
  "AIDEVOPS_RUN_ID",
  "AIDEVOPS_VERBOSE_LIFECYCLE",
  "AIDEVOPS_WORKER_ID",
  "AIDEVOPS_WORKER_PREFLIGHT_SENTINEL",
  "AIDEVOPS_WORKER_PREWARM_DIR",
  "AIDEVOPS_WORKTREE_OWNER_PATH",
  "AIDEVOPS_WORKTREE_OWNER_PID",
  "AIDEVOPS_WORKTREE_OWNER_SESSION",
  "AIDEVOPS_WORKTREE_OWNER_TASK",
  "AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE",
  "DISPATCH_REPO_SLUG",
  "WORKER_ISSUE_NUMBER",
  "WORKER_NO_EXIT_PUSH",
  "WORKER_REPO_SLUG",
  "WORKER_TARGET_BRANCH",
  "WORKER_WORKTREE_PATH",
  "_WORKER_WORKTREE_PATH",
] as const

function createEnvironment(
  overrides: Record<string, string | undefined> = {},
): Record<string, string> {
  const environment: Record<string, string> = {}
  for (const [name, value] of Object.entries(process.env)) {
    if (value !== undefined) environment[name] = value
  }
  for (const [name, value] of Object.entries(overrides)) {
    if (value === undefined) delete environment[name]
    else environment[name] = value
  }
  return environment
}

function nestedRuntimeEnvironment(
  overrides: Record<string, string | undefined>,
): Record<string, string> {
  const environment = createEnvironment(overrides)
  for (const name of NESTED_LIFECYCLE_ENV_KEYS) delete environment[name]
  return environment
}

function runtimeDocument(request: ResearchRuntimeRequest): string {
  return [
    "# Focused AI research request",
    "",
    "The child runtime has no tools. Use only this attached request and model knowledge.",
    "This is a headless nested inference call, not an interactive conversation. " +
      "Do not emit a session greeting, version or status banner, progress update, " +
      "or invitation for follow-up.",
    `Keep the answer within approximately ${request.maxTokens} tokens. ` +
      "The provider-neutral OpenCode adapter treats this as an instruction and " +
      "applies a conservative transport ceiling because exact provider output-token " +
      "controls are not exposed consistently.",
    "",
    "## System context",
    request.systemPrompt,
    "",
    "## Query",
    request.prompt,
  ].join("\n")
}

function defaultRuntimeHelperPath(env: Record<string, string>): string {
  const aidevopsDir = env.AIDEVOPS_DIR || join(env.HOME || homedir(), ".aidevops")
  return join(aidevopsDir, "agents", "scripts", "headless-runtime-helper.sh")
}

function defaultTempRoot(env: Record<string, string>): string {
  return env.AIDEVOPS_TEMP_DIR ||
    join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "tmp")
}

function transportOutputLimit(maxTokens: number): number {
  return Math.min(
    MAX_TRANSPORT_OUTPUT_BYTES,
    Math.max(MIN_TRANSPORT_OUTPUT_BYTES, maxTokens * 64),
  )
}

function runtimeFailure(result: CommandResult, tier: CanonicalResearchTier): ResearchRuntimeError {
  const diagnostic = `${result.stdout}\n${result.stderr}`.toLowerCase()
  if (/no (configured |available )?model|failed to resolve[^\n]*model/.test(diagnostic)) {
    return new ResearchRuntimeError(
      "MODEL_RESOLUTION_FAILED",
      `No configured OpenCode model is available for the ${tier} tier. ` +
        "Authenticate a supported provider or update the canonical routing table.",
    )
  }
  if (/unauthori[sz]ed|authentication|credential|no auth|sign in|http 401|http 403/.test(diagnostic)) {
    return new ResearchRuntimeError(
      "AUTH_FAILED",
      `OpenCode could not authenticate an available provider for the ${tier} tier. ` +
        "Run `opencode auth` for a supported provider and retry.",
    )
  }
  if (/provider[^\n]*(not found|unsupported|unavailable|disabled)|no available provider/.test(diagnostic)) {
    return new ResearchRuntimeError(
      "PROVIDER_FAILED",
      `OpenCode could not run an available provider for the ${tier} tier. ` +
        "Check provider availability and canonical routing, then retry.",
    )
  }
  if (/model[^\n]*(not found|unsupported|unavailable)/.test(diagnostic)) {
    return new ResearchRuntimeError(
      "MODEL_FAILED",
      `OpenCode could not run an available model for the ${tier} tier. ` +
        "Check the canonical routing table and configured provider models.",
    )
  }
  return new ResearchRuntimeError(
    "RUNTIME_FAILED",
    `OpenCode research failed for the ${tier} tier. Retry the query or inspect ` +
      "credential-free OpenCode runtime diagnostics.",
  )
}

function completedRuntimeResult(
  result: CommandResult,
  request: ResearchRuntimeRequest,
  timeoutMs: number,
): ReturnType<typeof parseOpenCodeRuntimeOutput> {
  if (result.spawnFailed) {
    throw new ResearchRuntimeError(
      "RUNTIME_UNAVAILABLE",
      "The canonical OpenCode headless runtime helper is unavailable. " +
        "Deploy aidevops and confirm OpenCode is installed, then retry.",
    )
  }
  if (result.aborted) {
    throw new ResearchRuntimeError(
      "RUNTIME_CANCELLED",
      "The OpenCode research request was cancelled before completion.",
    )
  }
  if (result.timedOut) {
    throw new ResearchRuntimeError(
      "RUNTIME_TIMEOUT",
      `OpenCode research exceeded ${Math.round(timeoutMs / 1000)} seconds. ` +
        "Narrow the query or retry with a lower workload tier.",
    )
  }
  if (result.outputLimitExceeded) {
    throw new ResearchRuntimeError(
      "OUTPUT_LIMIT",
      "OpenCode research exceeded the bounded transport output. Narrow the " +
        "query or raise max_tokens within the 4096-token limit.",
    )
  }
  if (result.exitCode !== 0) throw runtimeFailure(result, request.tier)
  return parseOpenCodeRuntimeOutput(`${result.stderr}\n${result.stdout}`)
}

export function createOpenCodeRuntimeAdapter(
  options: OpenCodeRuntimeOptions = {},
): ResearchRuntimeAdapter {
  const runner = options.commandRunner || runCommand

  return {
    async run(request) {
      const environment = createEnvironment(options.env)
      const helperPath = options.helperPath || defaultRuntimeHelperPath(environment)
      const tempRoot = options.tempRoot || defaultTempRoot(environment)
      const timeoutMs = options.timeoutMs || DEFAULT_RUNTIME_TIMEOUT_MS

      await mkdir(tempRoot, { recursive: true, mode: 0o700 })
      const requestDir = await mkdtemp(join(tempRoot, "ai-research-"))
      const requestFile = join(requestDir, "request.md")

      try {
        await chmod(requestDir, 0o700)
        await writeFile(requestFile, runtimeDocument(request), {
          encoding: "utf8",
          flag: "wx",
          mode: 0o600,
        })
        const sessionKey = `ai-research-${process.pid}-${randomUUID().replaceAll("-", "")}`
        const result = await runner({
          command: [
            helperPath,
            "run",
            "--role",
            "triage",
            "--session-key",
            sessionKey,
            "--dir",
            requestDir,
            "--title",
            `AI research (${request.tier})`,
            "--prompt-file",
            requestFile,
            "--tier",
            request.tier,
            "--agent",
            "research-only",
            "--runtime",
            "opencode",
          ],
          cwd: requestDir,
          env: nestedRuntimeEnvironment({
            ...options.env,
            AIDEVOPS_AI_RESEARCH_TOOL_CEILING: "1",
            AIDEVOPS_HEADLESS: "1",
            AIDEVOPS_HEADLESS_AUTH_ISOLATION: "1",
            AIDEVOPS_SESSION_ORIGIN: "ai-research",
          }),
          timeoutMs,
          maxOutputBytes: transportOutputLimit(request.maxTokens),
          signal: request.signal,
        })
        return completedRuntimeResult(result, request, timeoutMs)
      } finally {
        await rm(requestDir, { recursive: true, force: true })
      }
    },
  }
}
