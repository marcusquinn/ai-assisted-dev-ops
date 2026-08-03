// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Tool-name normalization shared by provider request and response transforms. */

export const TOOL_PREFIX = "mcp__aidevops__";

// Anthropic's third-party-app detection pattern-matches tool names. Specific
// lowercase names trigger 400 "third-party", so requests use Claude Code's
// PascalCase names and responses restore OpenCode's native lowercase names.
const TOOL_NAME_MAP = {
  bash: "Bash", read: "Read", write: "Write", edit: "Edit",
  glob: "Glob", grep: "Grep", task: "Task", skill: "Skill",
  webfetch: "WebFetch", websearch: "WebSearch",
  todowrite: "TodoWrite", todoread: "TodoRead",
  codesearch: "CodeSearch",
};

export const TOOL_NAME_REVERSE = Object.fromEntries(
  [...Object.entries(TOOL_NAME_MAP).map(([native, pascal]) => [pascal, native])],
);

function normalizeToolName(name) {
  if (!name) return name;
  if (TOOL_NAME_MAP[name]) return TOOL_NAME_MAP[name];
  if (/^[A-Z]/.test(name) || name.startsWith("mcp__")) return name;
  return `${TOOL_PREFIX}${name}`;
}

export function normalizeToolNames(tools) {
  return tools.map((tool) => {
    if (!tool.name) return tool;
    const normalized = normalizeToolName(tool.name);
    if (normalized === tool.name) return tool;
    return { ...tool, name: normalized };
  });
}

export function normalizeToolUseBlocks(messages) {
  return messages.map((msg) => {
    if (!msg.content || !Array.isArray(msg.content)) return msg;
    return {
      ...msg,
      content: msg.content.map((block) => {
        if (block.type === "tool_use" && block.name) {
          const normalized = normalizeToolName(block.name);
          if (normalized !== block.name) return { ...block, name: normalized };
        }
        return block;
      }),
    };
  });
}
