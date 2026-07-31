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

import { homedir } from "node:os"
import { isAbsolute, join, resolve as resolvePath } from "node:path"
import { createOpenCodeRuntimeAdapter } from "./ai-research-runtime"
import {
  ResearchRuntimeError,
  type CanonicalResearchTier,
  type OpenCodeRuntimeOptions,
  type ResearchRuntimeAdapter,
} from "./ai-research-runtime-types"

export { runCommand } from "./ai-research-command"
export { parseOpenCodeRuntimeOutput } from "./ai-research-output"
export { createOpenCodeRuntimeAdapter } from "./ai-research-runtime"
export {
  ResearchRuntimeError,
  type CanonicalResearchTier,
  type CommandInvocation,
  type CommandResult,
  type CommandRunner,
  type OpenCodeRuntimeOptions,
  type ResearchRuntimeAdapter,
  type ResearchRuntimeErrorCode,
  type ResearchRuntimeRequest,
  type ResearchRuntimeResult,
} from "./ai-research-runtime-types"

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

export interface ResearchOptions {
  runtime?: ResearchRuntimeAdapter
  cwd?: string
  agentsBase?: string
  signal?: AbortSignal
  runtimeOptions?: OpenCodeRuntimeOptions
}

const MAX_CALLS_PER_SESSION = 10
const DEFAULT_MAX_TOKENS = 500
const MIN_MAX_TOKENS = 50
const MAX_MAX_TOKENS = 4096
const OUTPUT_CHARACTERS_PER_TOKEN_CEILING = 8

const MODEL_ALIASES: Record<ResearchModel, CanonicalResearchTier> = {
  simple: "simple",
  standard: "standard",
  thinking: "thinking",
  haiku: "simple",
  sonnet: "standard",
  opus: "thinking",
}

/** Compact domain -> agent file mapping derived from subagent-index.toon. */
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
