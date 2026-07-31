// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  ResearchRuntimeError,
  type ResearchRuntimeResult,
} from "./ai-research-runtime-types"

const ANSI_ESCAPE_PATTERN = new RegExp(
  `${String.fromCharCode(27)}\\[[0-9;?]*[ -/]*[@-~]`,
  "g",
)

type JsonRecord = Record<string, unknown>

interface ParsedOutput {
  texts: string[]
  model: string
  inputTokens: number
  outputTokens: number
  usageAvailable: boolean
}

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

function usageFromRecord(record: JsonRecord): { input: number; output: number } | null {
  const source = asRecord(record.tokens) || asRecord(record.usage)
  if (!source) return null
  const input = numberValue(source, "input", "input_tokens", "prompt_tokens")
  const output = numberValue(source, "output", "output_tokens", "completion_tokens")
  if (input === undefined && output === undefined) return null
  return { input: Math.max(0, input || 0), output: Math.max(0, output || 0) }
}

function eventFromLine(line: string): JsonRecord | null {
  const trimmed = line.trim()
  if (!trimmed.startsWith("{")) return null
  try {
    return asRecord(JSON.parse(trimmed))
  } catch {
    return null
  }
}

function appendEventText(event: JsonRecord, parsed: ParsedOutput): void {
  const part = asRecord(event.part)
  const eventType = stringValue(event, "type")
  const partType = part ? stringValue(part, "type") : ""
  const text = part ? stringValue(part, "text") : stringValue(event, "text")
  if (text && (eventType === "text" || partType === "text")) parsed.texts.push(text)
}

function mergeEventMetadata(event: JsonRecord, parsed: ParsedOutput): void {
  const part = asRecord(event.part)
  const records = [part, asRecord(event.info), asRecord(event.message), event]
    .filter((record): record is JsonRecord => record !== null)
  for (const record of records) {
    const model = modelFromRecord(record)
    if (model) parsed.model = model
    const usage = usageFromRecord(record)
    if (!usage) continue
    parsed.inputTokens = usage.input
    parsed.outputTokens = usage.output
    parsed.usageAvailable = true
  }
}

function parseOutputLine(line: string, parsed: ParsedOutput): void {
  const selectedModel = line.match(/post_model_select\b[^\n]*\bmodel=([^\s]+)/)?.[1]
  if (selectedModel) parsed.model = selectedModel
  const event = eventFromLine(line)
  if (!event) return
  appendEventText(event, parsed)
  mergeEventMetadata(event, parsed)
}

export function parseOpenCodeRuntimeOutput(rawOutput: string): ResearchRuntimeResult {
  const parsed: ParsedOutput = {
    texts: [],
    model: "",
    inputTokens: 0,
    outputTokens: 0,
    usageAvailable: false,
  }
  const cleanOutput = rawOutput.replace(ANSI_ESCAPE_PATTERN, "")
  for (const line of cleanOutput.split("\n")) parseOutputLine(line, parsed)

  const content = parsed.texts.join("\n").trim()
  if (!content) {
    throw new ResearchRuntimeError(
      "RUNTIME_PARSE_FAILED",
      "OpenCode completed without a parseable research response. Retry the query " +
        "or inspect the OpenCode runtime logs.",
    )
  }

  return {
    content,
    model: parsed.model || "runtime-selected",
    input_tokens: parsed.inputTokens,
    output_tokens: parsed.outputTokens,
    usage_available: parsed.usageAvailable,
  }
}
