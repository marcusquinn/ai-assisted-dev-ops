/**
 * AI Research Tool for OpenCode Workers
 *
 * Lightweight sub-worker that routes focused research through OpenCode's
 * configured providers without burning the caller's context window. Workers
 * call this to get domain-specific answers using agent files as context.
 *
 * Rate limit: 10 calls per session.
 *
 * Usage examples:
 *   ai_research(prompt: "What branch naming conventions does this project use?", domain: "git")
 *   ai_research(prompt: "Find the dispatch function", files: [".agents/scripts/supervisor-helper.sh:4900-5000"])
 *   ai_research(prompt: "How does TOON encoding work?", agents: ["tools/context/toon.md"])
 */

import { tool } from "@opencode-ai/plugin"
import {
  formatResearchResult,
  research,
  getCallsRemaining,
  DOMAIN_AGENTS,
} from "../lib/ai-research"

export default tool({
  description:
    "Spawn a focused provider-neutral research query through OpenCode without burning your context. " +
    "Inference-only: cannot browse or inspect the repository itself. Supply narrow source excerpts via files and domain guidance via agents; paths mentioned only in the prompt are not loaded. " +
    "Rate limit: 10 calls per session. Default workload tier: simple.",
  args: {
    prompt: tool.schema
      .string()
      .describe("The research question or query (required)"),
    agents: tool.schema
      .string()
      .optional()
      .describe(
        "Comma-separated agent file paths relative to ~/.aidevops/agents/ " +
          "(e.g. 'workflows/git-workflow.md,tools/git/github-cli.md')"
      ),
    domain: tool.schema
      .string()
      .optional()
      .describe(
        "Domain shorthand — auto-resolves to relevant agents. " +
          "Available: " +
          Object.keys(DOMAIN_AGENTS).join(", ")
      ),
    files: tool.schema
      .string()
      .optional()
      .describe(
        "Source files to load into the child context, comma-separated with optional line ranges " +
          "(e.g. 'src/index.ts:10-50,README.md')"
      ),
    model: tool.schema
      .enum(["simple", "standard", "thinking", "haiku", "sonnet", "opus"])
      .optional()
      .describe(
        "Workload tier: simple (default), standard, or thinking. " +
          "Legacy aliases haiku, sonnet, and opus remain supported."
      ),
    max_tokens: tool.schema
      .number()
      .optional()
      .describe(
        "Approximate response-token budget (default: 500, max: 4096). " +
          "OpenCode providers may not expose exact output-token enforcement."
      ),
  },
  async execute(args, context) {
    try {
      // Parse comma-separated lists
      const agents = args.agents
        ? args.agents.split(",").map((s) => s.trim()).filter(Boolean)
        : undefined
      const files = args.files
        ? args.files.split(",").map((s) => s.trim()).filter(Boolean)
        : undefined

      // Clamp max_tokens
      const maxTokens = args.max_tokens
        ? Math.min(Math.max(args.max_tokens, 50), 4096)
        : undefined

      const result = await research({
        prompt: args.prompt,
        agents,
        domain: args.domain,
        files,
        model: args.model,
        max_tokens: maxTokens,
      }, {
        cwd: context.directory,
        signal: context.abort,
      })

      return formatResearchResult(result)
    } catch (error) {
      const remaining = getCallsRemaining()
      const message = error instanceof Error ? error.message : String(error)
      return `Error: ${message}\n(${remaining} calls remaining)`
    }
  },
})
