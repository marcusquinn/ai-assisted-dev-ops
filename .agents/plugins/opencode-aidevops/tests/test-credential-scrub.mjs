// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression tests for the OpenCode plugin credential transcript scrubber.
// ---------------------------------------------------------------------------
// The JS hook must mirror the Python and shell scrubbers' boundary invariant:
// credential prefixes embedded mid-word are not credentials, but credentials
// at start-of-string or after non-identifier boundaries are redacted.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-credential-scrub.mjs
// ---------------------------------------------------------------------------

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createQualityHooks, scrubCredentials } from "../quality-hooks.mjs";

const REDACTION_TOKEN = "[redacted-credential]";
const PEM_REDACTION_TOKEN = "[redacted-private-key]";

function assertScrub(input, expected, expectedCount) {
  const { scrubbed, count } = scrubCredentials(input);
  assert.equal(scrubbed, expected);
  assert.equal(count, expectedCount);
}

describe("credential transcript scrub boundary", () => {
  test("does not redact credential prefix embedded mid-word", () => {
    assertScrub("module task-syntheticfixture", "module task-syntheticfixture", 0);
  });

  test("does not redact embedded prefix with long suffix past token length gate", () => {
    assertScrub(
      "url https://example.invalid/vendor-ghp_syntheticIdentifierSuffix",
      "url https://example.invalid/vendor-ghp_syntheticIdentifierSuffix",
      0,
    );
  });

  test("redacts credential after whitespace boundary", () => {
    assertScrub(`API key sk-${"a".repeat(10)} invalid`, `API key ${REDACTION_TOKEN} invalid`, 1);
  });

  test("redacts credential at start of string", () => {
    assertScrub(`ghp_${"b".repeat(10)}`, REDACTION_TOKEN, 1);
  });

  test("redacts credential after colon boundary", () => {
    assertScrub(`token:glpat-${"c".repeat(10)}`, `token:${REDACTION_TOKEN}`, 1);
  });

  test("redacts credential after equals boundary", () => {
    assertScrub(`token=xoxb-${"d".repeat(10)}`, `token=${REDACTION_TOKEN}`, 1);
  });

  test("redacts credential after parenthesis boundary", () => {
    assertScrub(`(${"xoxp-"}${"e".repeat(10)})`, `(${REDACTION_TOKEN})`, 1);
  });

  test("redacts Google OAuth client secret after equals boundary", () => {
    const secret = `GOCSPX-${"f".repeat(28)}`;
    assertScrub(`client_secret=${secret}`, `client_secret=${REDACTION_TOKEN}`, 1);
  });

  test("redacts unknown-format values assigned to sensitive field names", () => {
    assertScrub(
      "RESEND_API_KEY=synthetic_unknown_format_1234567890",
      `RESEND_API_KEY=${REDACTION_TOKEN}`,
      1,
    );
  });

  test("redacts quoted sensitive fields in colon-delimited output", () => {
    assertScrub(
      '"RECRAFT_API_KEY": "synthetic_unknown_format_1234567890"',
      `"RECRAFT_API_KEY": "${REDACTION_TOKEN}"`,
      1,
    );
  });

  test("redacts exact and camel-case sensitive field names", () => {
    assertScrub("TOKEN=opaque-value", `TOKEN=${REDACTION_TOKEN}`, 1);
    assertScrub("apiKey: opaque-value", `apiKey: ${REDACTION_TOKEN}`, 1);
    assertScrub("clientSecret='opaque-value'", `clientSecret='${REDACTION_TOKEN}'`, 1);
    assertScrub("userPassword=opaque-value", `userPassword=${REDACTION_TOKEN}`, 1);
    assertScrub("SECRET_KEY=opaque-value", `SECRET_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub("SSH_PRIVATE_KEY=opaque-value", `SSH_PRIVATE_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub("AWS_SECRET_ACCESS_KEY=opaque-value", `AWS_SECRET_ACCESS_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub("AWS_ACCESS_KEY_ID=opaque-value", `AWS_ACCESS_KEY_ID=${REDACTION_TOKEN}`, 1);
    assertScrub("AccessKeyId=opaque-value", `AccessKeyId=${REDACTION_TOKEN}`, 1);
    assertScrub("ARTIFACT_SIGNING_KEY=opaque-value", `ARTIFACT_SIGNING_KEY=${REDACTION_TOKEN}`, 1);
  });

  test("preserves delimiters around unquoted sensitive assignments", () => {
    assertScrub(`(RESEND-API-KEY=opaque-value)`, `(RESEND-API-KEY=${REDACTION_TOKEN})`, 1);
    assertScrub(`API_KEY=opaque-value&other=value`, `API_KEY=${REDACTION_TOKEN}&other=value`, 1);
    assertScrub(`TOKEN=opaque-value|other`, `TOKEN=${REDACTION_TOKEN}|other`, 1);
    assertScrub(`PASSWORD=opaque-value>file`, `PASSWORD=${REDACTION_TOKEN}>file`, 1);
    assertScrub(`(API_KEY=not set)`, `(API_KEY=not set)`, 0);
    assertScrub(`API_KEY=(opaque-value)`, `API_KEY=(${REDACTION_TOKEN})`, 1);
  });

  test("redacts quoted and unquoted sensitive names containing spaces", () => {
    assertScrub(`API KEY=opaque-value`, `API KEY=${REDACTION_TOKEN}`, 1);
    assertScrub(`"PRIVATE KEY": opaque-value`, `"PRIVATE KEY": ${REDACTION_TOKEN}`, 1);
  });

  test("preserves empty and explicit placeholder values", () => {
    assertScrub('API_KEY=""', 'API_KEY=""', 0);
    assertScrub("ACCESS_TOKEN=null", "ACCESS_TOKEN=null", 0);
    assertScrub("CLIENT_SECRET=[redacted]", "CLIENT_SECRET=[redacted]", 0);
    assertScrub("CLIENT_SECRET=[REDACTED]", "CLIENT_SECRET=[REDACTED]", 0);
    assertScrub("CLIENT_SECRET=not set", "CLIENT_SECRET=not set", 0);
    assertScrub("CLIENT_SECRET=(not set)", "CLIENT_SECRET=(not set)", 0);
    assertScrub("PRIVATE_KEY=[redacted-private-key]", "PRIVATE_KEY=[redacted-private-key]", 0);
    assertScrub("API_KEY=[redacted]opaque", `API_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub("API_KEY=<redacted>opaque", `API_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub('API_KEY=""opaque', `API_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub("API_KEY=(not set)opaque", `API_KEY=${REDACTION_TOKEN}`, 1);
    assertScrub("API_KEY=(redacted)opaque", `API_KEY=${REDACTION_TOKEN}`, 1);
  });

  test("does not redact non-sensitive field-name substrings", () => {
    assertScrub("TOKEN_COUNT=3", "TOKEN_COUNT=3", 0);
    assertScrub("PASSWORD_POLICY=strict", "PASSWORD_POLICY=strict", 0);
    assertScrub("MONKEY_TOKENIZER=enabled", "MONKEY_TOKENIZER=enabled", 0);
  });

  test("scans adversarial 10KB named-field input within the performance budget", () => {
    const input = "A ".repeat(5_000);
    const runs = 100;
    scrubCredentials(input);
    const start = process.hrtime.bigint();
    for (let run = 0; run < runs; run++) scrubCredentials(input);
    const averageMs = Number(process.hrtime.bigint() - start) / runs / 1_000_000;
    assert.ok(averageMs < 5, `named-field scan averaged ${averageMs.toFixed(3)}ms per 10KB`);
  });

  test("redacts sensitive field names longer than 128 characters", () => {
    const name = `${"A".repeat(129)}_API_KEY`;
    assertScrub(`${name}=opaque-value`, `${name}=${REDACTION_TOKEN}`, 1);
  });

  test("redacts standalone PEM private keys", () => {
    const privateKey = [
      "-----BEGIN OPENSSH PRIVATE KEY-----",
      "synthetic-material",
      "-----END OPENSSH PRIVATE KEY-----",
    ].join("\n");
    assertScrub(privateKey, PEM_REDACTION_TOKEN, 1);
  });

  test("scans unmatched PEM headers within the performance budget", () => {
    const input = "-----BEGIN OPENSSH PRIVATE KEY-----\n".repeat(250);
    const runs = 100;
    scrubCredentials(input);
    const start = process.hrtime.bigint();
    for (let run = 0; run < runs; run++) scrubCredentials(input);
    const averageMs = Number(process.hrtime.bigint() - start) / runs / 1_000_000;
    assert.ok(averageMs < 5, `PEM scan averaged ${averageMs.toFixed(3)}ms per 10KB`);
  });

  test("does not redact Google OAuth prefix embedded mid-word", () => {
    const embedded = `vendor-GOCSPX-${"g".repeat(28)}`;
    assertScrub(embedded, embedded, 0);
  });

  test("toolExecuteAfter scrubs Google OAuth secrets before returning output", async () => {
    const tempDir = mkdtempSync(join(tmpdir(), "aidevops-google-oauth-scrub-"));
    const secret = `GOCSPX-${"h".repeat(28)}`;
    const output = {
      output: { stdout: `client_secret=${secret}`, exitCode: 0 },
      metadata: {},
    };

    try {
      const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
      await hooks.toolExecuteAfter({ tool: "grep", callID: "" }, output);
      assert.deepEqual(output.output, {
        stdout: `client_secret=${REDACTION_TOKEN}`,
        exitCode: 0,
      });
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  test("toolExecuteAfter scrubs named credential values in structured output", async () => {
    const tempDir = mkdtempSync(join(tmpdir(), "aidevops-named-credential-scrub-"));
    const output = {
      output: {
        environment: {
          RESEND_API_KEY: "synthetic_unknown_format_1234567890",
          TOKEN: 1234567890,
          PRIVATE_KEY: { material: "synthetic_unknown_format_1234567890" },
          SECRET_KEY: null,
        },
      },
      metadata: {},
    };

    try {
      const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
      await hooks.toolExecuteAfter({ tool: "grep", callID: "" }, output);
      assert.deepEqual(output.output, {
        environment: {
          RESEND_API_KEY: REDACTION_TOKEN,
          TOKEN: REDACTION_TOKEN,
          PRIVATE_KEY: REDACTION_TOKEN,
          SECRET_KEY: null,
        },
      });
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  test("structured output preserves sensitive placeholders", async () => {
    const tempDir = mkdtempSync(join(tmpdir(), "aidevops-placeholder-scrub-"));
    const output = {
      output: { environment: { RESEND_API_KEY: "[redacted]", API_TOKEN: "" } },
      metadata: {},
    };

    try {
      const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
      await hooks.toolExecuteAfter({ tool: "grep", callID: "" }, output);
      assert.deepEqual(output.output, {
        environment: { RESEND_API_KEY: "[redacted]", API_TOKEN: "" },
      });
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });
});
