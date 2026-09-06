// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { test } from "node:test";
import assert from "node:assert/strict";
import { assembleClaudeSystemPrompt, buildClaudeArgs } from "../claude-proxy-context.mjs";

const framework = "Keep safeguards intact.\nNever omit verification.";
const agent = "Selected domain knowledge remains available.";
const frameworkPath = "/home/test/.aidevops/agents/AGENTS.md";
const frameworkDocument = `Instructions from: ${frameworkPath}\n${framework}`;

function occurrences(text, value) {
  return text.split(value).length - 1;
}

test("Claude proxy compacts only an exact canonical framework document", () => {
  const incoming = `${frameworkDocument}\n\nInstructions from: /repo/AGENTS.md\nRequest context.`;
  const result = assembleClaudeSystemPrompt(framework, agent, incoming, frameworkPath);

  assert.equal(occurrences(result, framework), 1);
  assert.match(result, /already supplied by the Claude proxy/);
  assert.match(result, /Selected domain knowledge remains available/);
  assert.match(result, /Request context/);
  assert.equal(result, assembleClaudeSystemPrompt(framework, agent, incoming, frameworkPath));
});

test("Claude proxy preserves absent, unknown, similar, and different-authority input", () => {
  const cases = [
    "Request context.",
    `<framework>${framework}</framework>`,
    `Instructions from: ${frameworkPath}\n${framework}\nAn additional instruction.`,
    `Instructions from: /repo/AGENTS.md\n${framework}`,
  ];

  for (const incoming of cases) {
    const result = assembleClaudeSystemPrompt(framework, agent, incoming, frameworkPath);
    assert.match(result, /Selected domain knowledge remains available/);
    assert.ok(result.endsWith(incoming));
    assert.equal(occurrences(result, framework), incoming.includes(framework) ? 2 : 1);
  }
});

test("Claude proxy builder retains the expected Claude argv shape", () => {
  const args = buildClaudeArgs({ model: "claude-sonnet-4-6", agentName: "legal", prompt: "Continue." }, "", false);

  assert.deepEqual(args.slice(0, 3), ["-p", "--model", "claude-sonnet-4-6"]);
  assert.ok(args.includes("--permission-mode"));
  assert.ok(args.includes("--append-system-prompt"));
  assert.deepEqual(args.slice(-3), ["--output-format", "json", "Continue."]);
});
