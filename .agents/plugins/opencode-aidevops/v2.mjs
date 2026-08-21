// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export const OPENCODE_V2_MIGRATION_MESSAGE =
  "aidevops OpenCode V2 support is staged but not enabled; load the /v1 entrypoint until explicit V2 domain-hook adapters are complete";

/** Define the stable descriptor shape expected by OpenCode's V2 Promise API. */
export function defineAidevopsV2Adapter(setup) {
  if (typeof setup !== "function") throw new TypeError("OpenCode V2 adapter setup must be a function");
  return Object.freeze({ id: "aidevops", setup });
}

async function unavailableV2Setup() {
  throw new Error(OPENCODE_V2_MIGRATION_MESSAGE);
}

export const AidevopsV2Plugin = defineAidevopsV2Adapter(unavailableV2Setup);

export default AidevopsV2Plugin;
