// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export type CanonicalResearchTier = "simple" | "standard" | "thinking"

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
