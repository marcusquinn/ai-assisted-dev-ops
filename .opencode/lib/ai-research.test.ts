// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { access, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  buildSystemPrompt,
  createOpenCodeRuntimeAdapter,
  extractAIContext,
  formatResearchResult,
  getCallsRemaining,
  normalizeMaxTokens,
  normalizeResearchTier,
  parseOpenCodeRuntimeOutput,
  research,
  ResearchRuntimeError,
  resetRateLimit,
  type CommandResult,
  type ResearchRuntimeAdapter,
  type ResearchRuntimeErrorCode,
  type ResearchRuntimeRequest,
} from "./ai-research"

const temporaryDirectories: string[] = []

async function temporaryDirectory(prefix: string): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), prefix))
  temporaryDirectories.push(directory)
  return directory
}

function commandResult(overrides: Partial<CommandResult> = {}): CommandResult {
  return {
    stdout: "",
    stderr: "",
    exitCode: 0,
    timedOut: false,
    aborted: false,
    outputLimitExceeded: false,
    spawnFailed: false,
    ...overrides,
  }
}

function runtimeRequest(overrides: Partial<ResearchRuntimeRequest> = {}): ResearchRuntimeRequest {
  return {
    prompt: "Return the key fact.",
    systemPrompt: "Use the supplied fixture context.",
    tier: "simple",
    maxTokens: 100,
    cwd: process.cwd(),
    ...overrides,
  }
}

function fixedRuntime(content = "Focused answer"): ResearchRuntimeAdapter {
  return {
    async run() {
      return {
        content,
        model: "openai/test-model",
        input_tokens: 12,
        output_tokens: 3,
        usage_available: true,
      }
    },
  }
}

async function expectRuntimeError(
  operation: Promise<unknown>,
  code: ResearchRuntimeErrorCode,
): Promise<ResearchRuntimeError> {
  try {
    await operation
  } catch (error) {
    expect(error).toBeInstanceOf(ResearchRuntimeError)
    expect((error as ResearchRuntimeError).code).toBe(code)
    return error as ResearchRuntimeError
  }
  throw new Error(`Expected ResearchRuntimeError(${code})`)
}

beforeEach(() => {
  resetRateLimit()
})

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(directory =>
    rm(directory, { recursive: true, force: true })
  ))
})

describe("canonical workload routing", () => {
  test("uses canonical tiers and preserves every legacy alias", () => {
    expect(normalizeResearchTier(undefined)).toBe("simple")
    expect(normalizeResearchTier("simple")).toBe("simple")
    expect(normalizeResearchTier("standard")).toBe("standard")
    expect(normalizeResearchTier("thinking")).toBe("thinking")
    expect(normalizeResearchTier("haiku")).toBe("simple")
    expect(normalizeResearchTier("sonnet")).toBe("standard")
    expect(normalizeResearchTier("opus")).toBe("thinking")
    expect(() => normalizeResearchTier("provider/model")).toThrow("canonical")
  })

  test("clamps the provider-neutral response budget", () => {
    expect(normalizeMaxTokens(undefined)).toBe(500)
    expect(normalizeMaxTokens(1)).toBe(50)
    expect(normalizeMaxTokens(123.9)).toBe(123)
    expect(normalizeMaxTokens(10_000)).toBe(4096)
    expect(() => normalizeMaxTokens(Number.NaN)).toThrow("finite")
  })
})

describe("context assembly", () => {
  test("extracts marked agent context and requested file line ranges", async () => {
    const root = await temporaryDirectory("aidevops-ai-research-context-")
    const agentsBase = join(root, "agents")
    const project = join(root, "project")
    await mkdir(agentsBase, { recursive: true })
    await mkdir(join(agentsBase, "workflows"), { recursive: true })
    await mkdir(project, { recursive: true })
    await writeFile(join(agentsBase, "fixture.md"), [
      "outside-before",
      "<!-- AI-CONTEXT-START -->",
      "inside-agent-context",
      "<!-- AI-CONTEXT-END -->",
      "outside-after",
    ].join("\n"))
    await writeFile(join(agentsBase, "workflows", "git-workflow.md"), "domain-context")
    await writeFile(join(project, "source.txt"), "line-one\nline-two\nline-three\nline-four\n")

    const prompt = await buildSystemPrompt({
      agents: ["fixture.md"],
      domain: "git",
      files: ["source.txt:2-3"],
    }, { agentsBase, cwd: project })

    expect(prompt).toContain("inside-agent-context")
    expect(prompt).not.toContain("outside-before")
    expect(prompt).toContain("domain-context")
    expect(prompt).toContain("line-two\nline-three")
    expect(prompt).not.toContain("line-one")
  })

  test("falls back to complete content when markers are incomplete", () => {
    const source = "before\n<!-- AI-CONTEXT-START -->\nafter"
    expect(extractAIContext(source)).toBe(source)
  })
})

describe("OpenCode event parsing", () => {
  test("parses response text, selected model, and provider-neutral usage", () => {
    const output = [
      "[lifecycle] post_model_select session=test model=openai/fallback-model pid=1",
      JSON.stringify({ type: "text", part: { type: "text", text: "First fact." } }),
      JSON.stringify({ type: "text", part: { type: "text", text: "Second fact." } }),
      JSON.stringify({
        type: "step_finish",
        part: {
          providerID: "openai",
          modelID: "gpt-test",
          tokens: { input: 42, output: 9 },
        },
      }),
    ].join("\n")

    expect(parseOpenCodeRuntimeOutput(output)).toEqual({
      content: "First fact.\nSecond fact.",
      model: "openai/gpt-test",
      input_tokens: 42,
      output_tokens: 9,
      usage_available: true,
    })
  })

  test("reports unavailable usage honestly when events omit it", () => {
    const ansiEscape = String.fromCharCode(27)
    const output = [
      `${ansiEscape}[32m[lifecycle] post_model_select ` +
        `session=test model=zai-coding-plan/glm-test pid=1${ansiEscape}[0m`,
      JSON.stringify({ type: "text", part: { text: "Provider-neutral answer" } }),
    ].join("\n")
    const result = parseOpenCodeRuntimeOutput(output)

    expect(result.model).toBe("zai-coding-plan/glm-test")
    expect(result.input_tokens).toBe(0)
    expect(result.output_tokens).toBe(0)
    expect(result.usage_available).toBe(false)
  })

  test("fails with an actionable parse diagnostic when text is absent", () => {
    expect(() => parseOpenCodeRuntimeOutput('{"type":"step_start"}')).toThrow(
      "parseable research response",
    )
  })
})

describe("research API compatibility", () => {
  test("maps aliases before invoking an injectable runtime and preserves the footer", async () => {
    let observed: ResearchRuntimeRequest | undefined
    const runtime: ResearchRuntimeAdapter = {
      async run(request) {
        observed = request
        return fixedRuntime().run(request)
      },
    }

    const result = await research({
      prompt: "Summarise the fixture.",
      model: "sonnet",
      max_tokens: 12,
    }, { runtime, cwd: "/fixture/project" })

    expect(observed?.tier).toBe("standard")
    expect(observed?.maxTokens).toBe(50)
    expect(observed?.cwd).toBe("/fixture/project")
    expect(result.calls_remaining).toBe(9)
    expect(formatResearchResult(result)).toBe(
      "Focused answer\n\n" +
      "--- ai-research: openai/test-model | in:12 out:3 | " +
      "max_tokens:advisory | 9 calls remaining ---",
    )
  })

  test("keeps the ten-call session limiter", async () => {
    const runtime = fixedRuntime()
    for (let call = 0; call < 10; call++) {
      await research({ prompt: `query-${call}` }, { runtime })
    }
    expect(getCallsRemaining()).toBe(0)
    await expect(research({ prompt: "query-11" }, { runtime })).rejects.toThrow(
      "Rate limit reached",
    )
  })

  test("fails closed when provider output exceeds the conservative ceiling", async () => {
    const error = await expectRuntimeError(
      research(
        { prompt: "large response", max_tokens: 50 },
        { runtime: fixedRuntime("x".repeat(401)) },
      ),
      "OUTPUT_LIMIT",
    )
    expect(error.message).toContain("max_tokens=50")
  })

  test("marks unavailable usage in the footer instead of inventing counts", async () => {
    const runtime: ResearchRuntimeAdapter = {
      async run() {
        return {
          content: "Answer",
          model: "google/test-model",
          input_tokens: 0,
          output_tokens: 0,
          usage_available: false,
        }
      },
    }
    const result = await research({ prompt: "query" }, { runtime })
    expect(formatResearchResult(result)).toContain("usage:unavailable")
  })
})

describe("isolated OpenCode runtime adapter", () => {
  test("uses canonical tier routing, a private prompt artifact, and the no-tools profile", async () => {
    const root = await temporaryDirectory("aidevops-ai-research-runtime-")
    const project = join(root, "project")
    const tempRoot = join(root, "managed-temp")
    await mkdir(project, { recursive: true })
    let requestFile = ""

    const adapter = createOpenCodeRuntimeAdapter({
      helperPath: "/fixture/headless-runtime-helper.sh",
      tempRoot,
      env: {
        AIDEVOPS_DISPATCH_LEASE_TOKEN: "parent-lease",
        AIDEVOPS_PERMISSION_GRANT_FILE: "/parent/grant.json",
        AIDEVOPS_WORKTREE_OWNER_SESSION: "issue-28661",
        WORKER_ISSUE_NUMBER: "28661",
        WORKER_WORKTREE_PATH: project,
      },
      commandRunner: async invocation => {
        expect(invocation.command.slice(0, 2)).toEqual([
          "/fixture/headless-runtime-helper.sh",
          "run",
        ])
        expect(invocation.command).toContain("triage")
        expect(invocation.command).toContain("simple")
        expect(invocation.command).toContain("research-only")
        expect(invocation.command).not.toContain("anthropic")
        expect(invocation.env.AIDEVOPS_AI_RESEARCH_TOOL_CEILING).toBe("1")
        expect(invocation.env.AIDEVOPS_HEADLESS_AUTH_ISOLATION).toBe("1")
        expect(invocation.env.AIDEVOPS_SESSION_ORIGIN).toBe("ai-research")
        for (const lifecycleKey of [
          "AIDEVOPS_DISPATCH_LEASE_TOKEN",
          "AIDEVOPS_PERMISSION_GRANT_FILE",
          "AIDEVOPS_WORKTREE_OWNER_SESSION",
          "WORKER_ISSUE_NUMBER",
          "WORKER_WORKTREE_PATH",
        ]) {
          expect(invocation.env[lifecycleKey]).toBeUndefined()
        }

        requestFile = invocation.command[invocation.command.indexOf("--prompt-file") + 1]
        const isolatedDirectory = invocation.command[invocation.command.indexOf("--dir") + 1]
        expect(isolatedDirectory).toBe(invocation.cwd)
        expect(isolatedDirectory).not.toBe(project)
        expect(requestFile.startsWith(`${isolatedDirectory}/`)).toBe(true)
        const requestStat = await stat(requestFile)
        expect(requestStat.mode & 0o777).toBe(0o600)
        const document = await readFile(requestFile, "utf8")
        expect(document).toContain("Use the supplied fixture context.")
        expect(document).toContain("Return the key fact.")
        expect(document).toContain("headless nested inference call")
        expect(document).toContain("approximately 100 tokens")

        return commandResult({
          stderr: "[lifecycle] post_model_select session=test model=openai/gpt-test pid=1",
          stdout: JSON.stringify({ type: "text", part: { text: "OpenAI-only answer" } }),
        })
      },
    })

    const result = await adapter.run(runtimeRequest({ cwd: project }))
    expect(result.content).toBe("OpenAI-only answer")
    expect(result.model).toBe("openai/gpt-test")
    await expect(access(requestFile)).rejects.toThrow()
  })

  test("maps auth failures without returning credential-bearing output", async () => {
    const root = await temporaryDirectory("aidevops-ai-research-auth-")
    const adapter = createOpenCodeRuntimeAdapter({
      tempRoot: root,
      commandRunner: async () => commandResult({
        exitCode: 1,
        stderr: "Unauthorized credential secret-value-must-not-escape",
      }),
    })
    const error = await expectRuntimeError(adapter.run(runtimeRequest()), "AUTH_FAILED")
    expect(error.message).toContain("opencode auth")
    expect(error.message).not.toContain("secret-value-must-not-escape")
  })

  test("distinguishes model resolution, provider, and model failures", async () => {
    const resolutionRoot = await temporaryDirectory("aidevops-ai-research-resolution-")
    const resolutionAdapter = createOpenCodeRuntimeAdapter({
      tempRoot: resolutionRoot,
      commandRunner: async () => commandResult({ exitCode: 1, stderr: "No available model" }),
    })
    await expectRuntimeError(resolutionAdapter.run(runtimeRequest()), "MODEL_RESOLUTION_FAILED")

    const providerRoot = await temporaryDirectory("aidevops-ai-research-provider-")
    const providerAdapter = createOpenCodeRuntimeAdapter({
      tempRoot: providerRoot,
      commandRunner: async () => commandResult({ exitCode: 1, stderr: "Provider unavailable" }),
    })
    await expectRuntimeError(providerAdapter.run(runtimeRequest()), "PROVIDER_FAILED")

    const modelRoot = await temporaryDirectory("aidevops-ai-research-model-")
    const modelAdapter = createOpenCodeRuntimeAdapter({
      tempRoot: modelRoot,
      commandRunner: async () => commandResult({ exitCode: 1, stderr: "Model not found" }),
    })
    await expectRuntimeError(modelAdapter.run(runtimeRequest()), "MODEL_FAILED")
  })

  test("returns bounded timeout and transport-limit diagnostics", async () => {
    const timeoutRoot = await temporaryDirectory("aidevops-ai-research-timeout-")
    const timeoutAdapter = createOpenCodeRuntimeAdapter({
      tempRoot: timeoutRoot,
      timeoutMs: 1234,
      commandRunner: async () => commandResult({ timedOut: true, exitCode: 143 }),
    })
    const timeoutError = await expectRuntimeError(
      timeoutAdapter.run(runtimeRequest()),
      "RUNTIME_TIMEOUT",
    )
    expect(timeoutError.message).toContain("1 seconds")

    const outputRoot = await temporaryDirectory("aidevops-ai-research-output-")
    const outputAdapter = createOpenCodeRuntimeAdapter({
      tempRoot: outputRoot,
      commandRunner: async () => commandResult({
        outputLimitExceeded: true,
        exitCode: 143,
      }),
    })
    await expectRuntimeError(outputAdapter.run(runtimeRequest()), "OUTPUT_LIMIT")
  })

  test("reports a missing runtime helper without leaking spawn details", async () => {
    const root = await temporaryDirectory("aidevops-ai-research-missing-")
    const adapter = createOpenCodeRuntimeAdapter({
      tempRoot: root,
      commandRunner: async () => commandResult({ spawnFailed: true, exitCode: 127 }),
    })
    const error = await expectRuntimeError(
      adapter.run(runtimeRequest()),
      "RUNTIME_UNAVAILABLE",
    )
    expect(error.message).toContain("headless runtime helper")
  })
})
