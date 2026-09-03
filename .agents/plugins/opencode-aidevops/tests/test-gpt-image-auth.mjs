// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  imageApiSecretName,
  normalizeImageAccountAlias,
  readImageApiKey,
  resolveGptImageAuth,
} from "../gpt-image-auth.mjs";

describe("GPT image authentication", () => {
  test("maps explicit API account aliases to isolated secret names", () => {
    assert.equal(normalizeImageAccountAlias("personal_2"), "PERSONAL_2");
    assert.equal(imageApiSecretName("work", {}), "OPENAI_IMAGE_API_KEY_WORK");
    assert.throws(() => normalizeImageAccountAlias("work-main"), /letters, numbers, or underscores/);
    assert.throws(() => imageApiSecretName("", {}), /explicit account alias/);
  });

  test("uses only the requested environment secret without invoking a subprocess", () => {
    let called = false;
    const value = readImageApiKey("OPENAI_IMAGE_API_KEY_WORK", {
      env: { OPENAI_IMAGE_API_KEY_WORK: "unit-test-credential-value" },
      execFile: () => {
        called = true;
        return "";
      },
    });
    assert.equal(value, "unit-test-credential-value");
    assert.equal(called, false);
  });

  test("keeps OAuth selection pinned when an account is requested", async () => {
    let requested;
    const auth = await resolveGptImageAuth({ auth: "oauth", account: "person@example.test" }, {
      resolveOAuthAccount: async (email) => {
        requested = email;
        return { email, access: "oauth-test-token", accountId: "account-test" };
      },
    });
    assert.equal(requested, "person@example.test");
    assert.equal(auth.pinned, true);
    assert.equal(auth.mode, "oauth");
  });
});
