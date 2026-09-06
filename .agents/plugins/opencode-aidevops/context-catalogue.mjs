// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

/** Compact advertising, never skill content, permissions, or invocation. */
export function compactSkillCatalogue(text) {
  return text.replace(/<available_skills>([\s\S]*?)<\/available_skills>/g, (block, body) => {
    const wrappers = [];
    const retained = body.replace(/<skill>([\s\S]*?)<\/skill>/g, (entry, fields) => {
      // Fail open for custom descriptions, additional fields, or changed formats.
      const match = fields.match(/^\s*<name>(aidevops-([a-z0-9-]+))<\/name>\s*<description>Run the aidevops \2 workflow when explicitly requested\.<\/description>\s*<location>([^<>\n]+\/\1\/SKILL\.md)<\/location>\s*$/);
      if (!match) return entry;
      wrappers.push(`- ${match[1]} (${match[3]})`);
      return "";
    });
    if (wrappers.length < 2) return block;
    return `<available_skills>${retained.trimEnd()}\n\n` +
      "Generated aidevops workflow skills below all have the same trigger: run the named aidevops workflow ONLY when explicitly requested. " +
      "Load the full instructions with the skill tool using the exact skill name; all remain available.\n" +
      wrappers.join("\n") + "\n</available_skills>";
  });
}

/** Only exact, separately supplied instruction bodies may be shared. No history rewriting. */
export function compactSystemContext(system) {
  const instructions = new Map();
  return system.map((text) => {
    if (typeof text !== "string") return text;
    const match = text.match(/^Instructions from: ([^\n]+)\n([\s\S]+)$/);
    if (match) {
      const [, source, body] = match;
      const previous = instructions.get(body);
      if (previous) {
        return `Instructions from: ${source}\nThe complete instruction body is byte-identical to the already loaded instructions from: ${previous}. Apply those instructions here too.`;
      }
      instructions.set(body, source);
    }
    return compactSkillCatalogue(text);
  });
}

/** Replace only a byte-identical canonical instruction document with its source. */
export function compactExactInstructionDocument(body, source, text) {
  const incoming = typeof text === "string" ? text : "";
  if (!body || !source) return incoming;

  const document = `Instructions from: ${source}\n${body}`;
  const reference = `Instructions from: ${source}\nThe complete instruction body is already supplied by the Claude proxy.`;
  const escapedDocument = document.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return incoming.replace(
    new RegExp(`(^|\\n\\n)${escapedDocument}(?=\\n\\nInstructions from:|$)`, "g"),
    `$1${reference}`,
  );
}
