// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { test } from "node:test";
import assert from "node:assert/strict";
import { compactSkillCatalogue, compactSystemContext } from "../context-catalogue.mjs";

function wrapper(name, description = `Run the aidevops ${name} workflow when explicitly requested.`) {
  return `<skill>\n<name>aidevops-${name}</name>\n<description>${description}</description>\n<location>/skills/aidevops-${name}/SKILL.md</location>\n</skill>`;
}

test("compact wrapper advertising retains every name, location, trigger and specialist instruction", () => {
  const names = ["full-loop", "seo", "report-token-use", "release", "review", "vault"];
  const custom = wrapper("custom", "Load when custom domain guidance is relevant. Never publish without consent.");
  const source = `unchanged prefix\n<available_skills>\n${names.map((name) => wrapper(name)).join("\n")}\n${custom}\n</available_skills>\nunchanged suffix`;
  const compact = compactSkillCatalogue(source);
  for (const name of names) {
    assert.ok(compact.includes(`aidevops-${name} (/skills/aidevops-${name}/SKILL.md)`));
  }
  assert.ok(compact.includes(custom));
  assert.match(compact, /ONLY when explicitly requested/);
  assert.ok(compact.startsWith("unchanged prefix\n"));
  assert.ok(compact.endsWith("\nunchanged suffix"));
  assert.ok(compact.length < source.length * 0.8);
  assert.equal(compactSkillCatalogue(compact), compact);
});

test("unknown or enriched formats and isolated wrappers remain untouched", () => {
  for (const source of [wrapper("seo"), `<available_skills>${wrapper("seo")}</available_skills>`,
    `<available_skills>${wrapper("seo").replace("</skill>", "<extra>Keep me</extra></skill>")}</available_skills>`]) {
    assert.equal(compactSkillCatalogue(source), source);
  }
});

test("deduplication preserves differing scope guidance and does not mutate source arrays", () => {
  const body = "All hard-won rules stay intact.\nNever omit verification.";
  const source = [`Instructions from: /global/AGENTS.md\n${body}`, `Instructions from: /repo/AGENTS.md\n${body}`,
    `Instructions from: /repo/nested/AGENTS.md\n${body}\nAn additional rule.`];
  const result = compactSystemContext(source);
  assert.equal(result[0], source[0]);
  assert.match(result[1], /byte-identical/);
  assert.match(result[1], /Apply those instructions here too/);
  assert.equal(result[2], source[2]);
  assert.equal(source[1], `Instructions from: /repo/AGENTS.md\n${body}`);
});
