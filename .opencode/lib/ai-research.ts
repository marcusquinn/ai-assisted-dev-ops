// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Provider-neutral AI research runtime for OpenCode.
 *
 * The parent tool assembles bounded context, then delegates inference to an
 * isolated OpenCode child through the canonical headless runtime. OpenCode owns
 * provider selection and credentials; this module never reads or writes auth
 * files and never calls a provider endpoint directly.
 */

import { randomUUID } from "node:crypto"
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { isAbsolute, join, resolve as resolvePath } from "node:path"

export type CanonicalResearchTier = "simple" | "standard" | "thinking"
export type LegacyResearchModel = "haiku" | "sonnet" | "opus"
export type ResearchModel = CanonicalResearchTier | LegacyResearchModel

export interface ResearchRequest {
  prompt: string
  agents?: string[]
  domain?: string
  files?: string[]
  model?: ResearchModel
  max_tokens?: number
}

export interface ResearchResult {
  content: string
  model: string
  input_tokens: number
  output_tokens: number
  usage_available: boolean
  max_tokens_exact: false
  calls_remaining: number
}

export interface ResearchRuntimeRequest {
  prompt: string
  systemPrompt: string
  tier: CanonicalResearchTier
  maxTokens: number
  cwd: string
  signal?: AbortSignal
}

export interface ResearchRuntimeResult {
  content: string
  model: string
  input_tokens: number
  output_tokens: number
  usage_available: boolean
}

export interface ResearchRuntimeAdapter {
  run(request: ResearchRuntimeRequest): Promise<ResearchRuntimeResult>
}

export interface CommandInvocation {
  command: string[]
  cwd: string
  env: Record<string, string>
  timeoutMs: number
  maxOutputBytes: number
  signal?: AbortSignal
}

export interface CommandResult {
  stdout: string
  stderr: string
  exitCode: number
  timedOut: boolean
  aborted: boolean
  outputLimitExceeded: boolean
  spawnFailed: boolean
}

export type CommandRunner = (invocation: CommandInvocation) => Promise<CommandResult>

export interface OpenCodeRuntimeOptions {
  commandRunner?: CommandRunner
  env?: Record<string, string | undefined>
  helperPath?: string
  tempRoot?: string
  timeoutMs?: number
}

export interface ResearchOptions {
  runtime?: ResearchRuntimeAdapter
  cwd?: string
  agentsBase?: string
  signal?: AbortSignal
  runtimeOptions?: OpenCodeRuntimeOptions
}

export type ResearchRuntimeErrorCode =
  | "RUNTIME_UNAVAILABLE"
  | "MODEL_RESOLUTION_FAILED"
  | "AUTH_FAILED"
  | "PROVIDER_FAILED"
  | "MODEL_FAILED"
  | "RUNTIME_FAILED"
  | "RUNTIME_TIMEOUT"
  | "RUNTIME_CANCELLED"
  | "RUNTIME_PARSE_FAILED"
  | "OUTPUT_LIMIT"

export class ResearchRuntimeError extends Error {
  readonly code: ResearchRuntimeErrorCode

  constructor(code: ResearchRuntimeErrorCode, message: string) {
    super(message)
    this.name = "ResearchRuntimeError"
    this.code = code
  }
}

const MAX_CALLS_PER_SESSION = 10
const DEFAULT_MAX_TOKENS = 500
const MIN_MAX_TOKENS = 50
const MAX_MAX_TOKENS = 4096
const OUTPUT_CHARACTERS_PER_TOKEN_CEILING = 8
const DEFAULT_RUNTIME_TIMEOUT_MS = 120_000
const MIN_TRANSPORT_OUTPUT_BYTES = 64 * 1024
const MAX_TRANSPORT_OUTPUT_BYTES = 1024 * 1024
const ANSI_ESCAPE_PATTERN = new RegExp(
  `${String.fromCharCode(27)}\\[[0-9;?]*[ -/]*[@-~]`,
  "g",
)
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

const MODEL_ALIASES: Record<ResearchModel, CanonicalResearchTier> = {
  simple: "simple",
  standard: "standard",
  thinking: "thinking",
  haiku: "simple",
  sonnet: "standard",
  opus: "thinking",
}

/**
 * Compact domain -> agent file mapping derived from subagent-index.toon.
 */
export const DOMAIN_AGENTS: Record<string, string[]> = {
  git: [
    "workflows/git-workflow.md",
    "tools/git/github-cli.md",
    "tools/git/conflict-resolution.md",
  ],
  planning: ["workflows/plans.md", "tools/task-management/beads.md"],
  code: [
    "tools/code-review/code-standards.md",
    "tools/code-review/code-simplifier.md",
  ],
  seo: ["seo.md", "seo/dataforseo.md", "seo/google-search-console.md"],
  content: [
    "content.md",
    "content/research.md",
    "content/production/writing.md",
  ],
  wordpress: ["tools/wordpress/wp-dev.md", "tools/wordpress/mainwp.md"],
  browser: [
    "tools/browser/browser-automation.md",
    "tools/browser/playwright.md",
  ],
  deploy: [
    "tools/deployment/coolify.md",
    "tools/deployment/coolify-cli.md",
    "tools/deployment/vercel.md",
  ],
  security: [
    "tools/security/tirith.md",
    "tools/credentials/encryption-stack.md",
  ],
  video: [
    "tools/video/video-prompt-design.md",
    "tools/video/remotion.md",
    "tools/video/wavespeed.md",
  ],
  voice: [
    "tools/voice/speech-to-speech.md",
    "tools/voice/voice-bridge.md",
  ],
  mobile: ["tools/mobile/agent-device.md", "tools/mobile/maestro.md"],
  mcp: ["tools/build-mcp/build-mcp.md", "tools/build-mcp/server-patterns.md"],
  agent: [
    "tools/build-agent/build-agent.md",
    "tools/build-agent/agent-review.md",
  ],
  framework: ["aidevops/architecture.md", "aidevops/setup.md"],
  hosting: [
    "services/hosting/hostinger.md",
    "services/hosting/cloudflare.md",
    "services/hosting/hetzner.md",
  ],
  email: [
    "services/email/email-testing.md",
    "services/email/email-delivery-test.md",
  ],
  accessibility: [
    "tools/accessibility/accessibility.md",
    "services/accessibility/accessibility-audit.md",
  ],
  containers: ["tools/containers/orbstack.md"],
  orchestration: ["tools/ai-assistants/headless-dispatch.md"],
  context: [
    "tools/context/model-routing.md",
    "tools/context/toon.md",
    "tools/context/mcp-discovery.md",
  ],
  vision: ["tools/vision/overview.md", "tools/vision/image-generation.md"],
  release: ["workflows/release.md", "workflows/version-bump.md"],
  pr: ["workflows/pr.md", "workflows/preflight.md"],
}

let callCount = 0

function checkRateLimit(): void {
  if (callCount >= MAX_CALLS_PER_SESSION) {
    throw new Error(
      `Rate limit reached: ${MAX_CALLS_PER_SESSION} ai-research calls per session. ` +
        "Consolidate your queries or start a new session.",
    )
  }
  callCount++
}

export function getCallsRemaining(): number {
  return MAX_CALLS_PER_SESSION - callCount
}

export function resetRateLimit(): void {
  callCount = 0
}

export function normalizeResearchTier(model: string | undefined): CanonicalResearchTier {
  const requested = model || "simple"
  const tier = MODEL_ALIASES[requested as ResearchModel]
  if (!tier) {
    throw new Error(
      `Unknown model tier: ${requested}. Use canonical tiers simple, standard, thinking, ` +
        "or the legacy aliases haiku, sonnet, opus.",
    )
  }
  return tier
}

export function normalizeMaxTokens(value: number | undefined): number {
  if (value === undefined) return DEFAULT_MAX_TOKENS
  if (!Number.isFinite(value)) throw new Error("max_tokens must be a finite number")
  return Math.min(Math.max(Math.trunc(value), MIN_MAX_TOKENS), MAX_MAX_TOKENS)
}

/** Extract AI-specific context markers, falling back to the full source. */
export function extractAIContext(content: string): string {
  const startMarker = "<!-- AI-CONTEXT-START -->"
  const endMarker = "<!-- AI-CONTEXT-END -->"
  const startIdx = content.indexOf(startMarker)
  if (startIdx === -1) return content
  const endIdx = content.indexOf(endMarker, startIdx)
  if (endIdx === -1) return content
  return content.slice(startIdx + startMarker.length, endIdx).trim()
}

export function resolveDomain(domain: string): string[] {
  const key = domain.toLowerCase().replace(/[^a-z]/g, "")
  return DOMAIN_AGENTS[key] || []
}

function defaultAgentsBase(env: NodeJS.ProcessEnv = process.env): string {
  if (env.AIDEVOPS_ACTIVE_AGENTS_DIR) return env.AIDEVOPS_ACTIVE_AGENTS_DIR
  const aidevopsDir = env.AIDEVOPS_DIR || join(env.HOME || homedir(), ".aidevops")
  return join(aidevopsDir, "agents")
}

async function loadAgentFile(path: string, agentsBase: string): Promise<string | null> {
  const fullPath = isAbsolute(path) ? path : join(agentsBase, path)
  const file = Bun.file(fullPath)
  if (!(await file.exists())) return null
  return extractAIContext(await file.text())
}

async function loadFileWithRange(spec: string, cwd: string): Promise<string | null> {
  const match = spec.match(/^(.+?)(?::(\d+)(?:-(\d+))?)?$/)
  if (!match) return null

  const [, requestedPath, startLine, endLine] = match
  const fullPath = isAbsolute(requestedPath)
    ? requestedPath
    : resolvePath(cwd, requestedPath)
  const file = Bun.file(fullPath)
  if (!(await file.exists())) return null

  const content = await file.text()
  if (!startLine) return content

  const lines = content.split("\n")
  const start = Math.max(0, Number.parseInt(startLine, 10) - 1)
  const end = endLine ? Number.parseInt(endLine, 10) : start + 1
  return lines.slice(start, end).join("\n")
}

const BASE_INSTRUCTION =
  "You are a focused research sub-worker. Answer the query concisely " +
  "using only the supplied context and your model knowledge. Do not use tools, " +
  "ask follow-up questions, or explain your reasoning process unless asked. " +
  "Return actionable information: file paths, line numbers, function names, " +
  "config values, or brief explanations."

async function buildDomainSection(domain: string, agentsBase: string): Promise<string[]> {
  const parts: string[] = []
  for (const path of resolveDomain(domain)) {
    const content = await loadAgentFile(path, agentsBase)
    if (content) parts.push(`--- ${path} ---\n${content}`)
  }
  return parts
}

async function buildAgentsSection(agents: string[], agentsBase: string): Promise<string[]> {
  const parts: string[] = []
  for (const path of agents) {
    const content = await loadAgentFile(path, agentsBase)
    if (content) parts.push(`--- ${path} ---\n${content}`)
  }
  return parts
}

async function buildFilesSection(files: string[], cwd: string): Promise<string[]> {
  const parts: string[] = []
  for (const spec of files) {
    const content = await loadFileWithRange(spec, cwd)
    if (content) parts.push(`--- ${spec} ---\n${content}`)
  }
  return parts
}

export async function buildSystemPrompt(
  request: Pick<ResearchRequest, "agents" | "domain" | "files">,
  options: Pick<ResearchOptions, "agentsBase" | "cwd"> = {},
): Promise<string> {
  const cwd = options.cwd || process.cwd()
  const agentsBase = options.agentsBase || defaultAgentsBase()
  const parts: string[] = [BASE_INSTRUCTION]

  if (request.domain) parts.push(...await buildDomainSection(request.domain, agentsBase))
  if (request.agents?.length) {
    parts.push(...await buildAgentsSection(request.agents, agentsBase))
  }
  if (request.files?.length) parts.push(...await buildFilesSection(request.files, cwd))
  return parts.join("\n\n")
}

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

async function readLimitedStream(
  stream: ReadableStream<Uint8Array>,
  limit: number,
  onLimit: () => void,
): Promise<string> {
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  let storedBytes = 0

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    const remaining = limit - storedBytes
    if (value.byteLength > remaining) {
      if (remaining > 0) {
        chunks.push(value.slice(0, remaining))
        storedBytes += remaining
      }
      onLimit()
      await reader.cancel()
      break
    }
    chunks.push(value)
    storedBytes += value.byteLength
  }

  const merged = new Uint8Array(storedBytes)
  let offset = 0
  for (const chunk of chunks) {
    merged.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(merged)
}

export const runCommand: CommandRunner = async invocation => {
  if (invocation.signal?.aborted) {
    return {
      stdout: "",
      stderr: "",
      exitCode: 130,
      timedOut: false,
      aborted: true,
      outputLimitExceeded: false,
      spawnFailed: false,
    }
  }

  let child: ReturnType<typeof Bun.spawn>
  try {
    child = Bun.spawn(invocation.command, {
      cwd: invocation.cwd,
      env: invocation.env,
      stdout: "pipe",
      stderr: "pipe",
    })
  } catch {
    return {
      stdout: "",
      stderr: "",
      exitCode: 127,
      timedOut: false,
      aborted: false,
      outputLimitExceeded: false,
      spawnFailed: true,
    }
  }

  let timedOut = false
  let aborted = false
  let outputLimitExceeded = false
  const stop = () => {
    if (child.exitCode === null) child.kill()
  }
  const timeout = setTimeout(() => {
    timedOut = true
    stop()
  }, invocation.timeoutMs)
  const abort = () => {
    aborted = true
    stop()
  }
  invocation.signal?.addEventListener("abort", abort, { once: true })
  const markOutputLimit = () => {
    outputLimitExceeded = true
    stop()
  }

  try {
    const [stdout, stderr, exitCode] = await Promise.all([
      readLimitedStream(
        child.stdout as ReadableStream<Uint8Array>,
        invocation.maxOutputBytes,
        markOutputLimit,
      ),
      readLimitedStream(
        child.stderr as ReadableStream<Uint8Array>,
        invocation.maxOutputBytes,
        markOutputLimit,
      ),
      child.exited,
    ])
    return {
      stdout,
      stderr,
      exitCode,
      timedOut,
      aborted,
      outputLimitExceeded,
      spawnFailed: false,
    }
  } finally {
    clearTimeout(timeout)
    invocation.signal?.removeEventListener("abort", abort)
  }
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

function stripAnsi(value: string): string {
  return value.replace(ANSI_ESCAPE_PATTERN, "")
}

type JsonRecord = Record<string, unknown>

function asRecord(value: unknown): JsonRecord | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonRecord
    : null
}

function stringValue(record: JsonRecord, ...keys: string[]): string {
  for (const key of keys) {
    if (typeof record[key] === "string" && record[key]) return record[key] as string
  }
  return ""
}

function numberValue(record: JsonRecord, ...keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === "number" && Number.isFinite(value)) return value
  }
  return undefined
}

function modelFromRecord(record: JsonRecord): string {
  const nested = asRecord(record.model)
  const provider = stringValue(record, "providerID", "provider") ||
    (nested ? stringValue(nested, "providerID", "provider") : "")
  const model = stringValue(record, "modelID") ||
    (nested ? stringValue(nested, "modelID", "id") : "")
  if (!model) return ""
  return model.includes("/") || !provider ? model : `${provider}/${model}`
}

function usageFromRecord(record: JsonRecord): {
  input: number
  output: number
} | null {
  const tokens = asRecord(record.tokens)
  const usage = asRecord(record.usage)
  const source = tokens || usage
  if (!source) return null
  const input = numberValue(source, "input", "input_tokens", "prompt_tokens")
  const output = numberValue(source, "output", "output_tokens", "completion_tokens")
  if (input === undefined && output === undefined) return null
  return { input: Math.max(0, input || 0), output: Math.max(0, output || 0) }
}

export function parseOpenCodeRuntimeOutput(rawOutput: string): ResearchRuntimeResult {
  const cleanOutput = stripAnsi(rawOutput)
  const texts: string[] = []
  let model = ""
  let inputTokens = 0
  let outputTokens = 0
  let usageAvailable = false

  for (const line of cleanOutput.split("\n")) {
    const selectedModel = line.match(/post_model_select\b[^\n]*\bmodel=([^\s]+)/)?.[1]
    if (selectedModel) model = selectedModel

    const trimmed = line.trim()
    if (!trimmed.startsWith("{")) continue
    let event: JsonRecord
    try {
      const parsed = asRecord(JSON.parse(trimmed))
      if (!parsed) continue
      event = parsed
    } catch {
      continue
    }

    const part = asRecord(event.part)
    const eventType = stringValue(event, "type")
    const partType = part ? stringValue(part, "type") : ""
    const text = part ? stringValue(part, "text") : stringValue(event, "text")
    if (text && (eventType === "text" || partType === "text")) texts.push(text)

    const records = [part, asRecord(event.info), asRecord(event.message), event]
      .filter((record): record is JsonRecord => record !== null)
    for (const record of records) {
      const discoveredModel = modelFromRecord(record)
      if (discoveredModel) model = discoveredModel
      const usage = usageFromRecord(record)
      if (usage) {
        inputTokens = usage.input
        outputTokens = usage.output
        usageAvailable = true
      }
    }
  }

  const content = texts.join("\n").trim()
  if (!content) {
    throw new ResearchRuntimeError(
      "RUNTIME_PARSE_FAILED",
      "OpenCode completed without a parseable research response. Retry the query " +
        "or inspect the OpenCode runtime logs.",
    )
  }

  return {
    content,
    model: model || "runtime-selected",
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    usage_available: usageAvailable,
  }
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

export function createOpenCodeRuntimeAdapter(
  options: OpenCodeRuntimeOptions = {},
): ResearchRuntimeAdapter {
  const runner = options.commandRunner || runCommand

  return {
    async run(request): Promise<ResearchRuntimeResult> {
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
      } finally {
        await rm(requestDir, { recursive: true, force: true })
      }
    },
  }
}

function enforceOutputCeiling(content: string, maxTokens: number): void {
  const maximumCharacters = maxTokens * OUTPUT_CHARACTERS_PER_TOKEN_CEILING
  if (Array.from(content).length <= maximumCharacters) return
  throw new ResearchRuntimeError(
    "OUTPUT_LIMIT",
    `OpenCode returned more than the conservative ${maximumCharacters}-character ` +
      `ceiling for max_tokens=${maxTokens}. Narrow the query or raise max_tokens.`,
  )
}

export async function research(
  request: ResearchRequest,
  options: ResearchOptions = {},
): Promise<ResearchResult> {
  checkRateLimit()
  if (!request.prompt.trim()) throw new Error("Research prompt is required")

  const tier = normalizeResearchTier(request.model)
  const maxTokens = normalizeMaxTokens(request.max_tokens)
  const cwd = options.cwd || process.cwd()
  const systemPrompt = await buildSystemPrompt(request, {
    agentsBase: options.agentsBase,
    cwd,
  })
  const runtime = options.runtime || createOpenCodeRuntimeAdapter(options.runtimeOptions)
  const result = await runtime.run({
    prompt: request.prompt,
    systemPrompt,
    tier,
    maxTokens,
    cwd,
    signal: options.signal,
  })
  enforceOutputCeiling(result.content, maxTokens)

  return {
    ...result,
    input_tokens: Math.max(0, Math.trunc(result.input_tokens || 0)),
    output_tokens: Math.max(0, Math.trunc(result.output_tokens || 0)),
    max_tokens_exact: false,
    calls_remaining: getCallsRemaining(),
  }
}

export function formatResearchResult(result: ResearchResult): string {
  const usage = result.usage_available
    ? `in:${result.input_tokens} out:${result.output_tokens}`
    : "usage:unavailable"
  return (
    `${result.content}\n\n` +
    `--- ai-research: ${result.model} | ${usage} | max_tokens:advisory | ` +
    `${result.calls_remaining} calls remaining ---`
  )
}
