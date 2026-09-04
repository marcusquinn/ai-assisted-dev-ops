// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  PartStreamSummaryTracker,
  TOOL_METADATA_MAX_BYTES,
  summarizeToolMetadata,
} from "../observability-retention.mjs";

describe("tool metadata retention", () => {
  test("keeps outcome evidence while omitting raw metadata", () => {
    const summary = summarizeToolMetadata({
      bytes: 4096,
      error: "sensitive-value",
      exit: 7,
      filePath: "/private/project/file.txt",
      raw: "x".repeat(100_000),
      status: "failed",
    });
    const encoded = JSON.stringify(summary);

    assert.ok(Buffer.byteLength(encoded, "utf8") <= TOOL_METADATA_MAX_BYTES);
    assert.equal(summary.status, "failed");
    assert.equal(summary.exit_code, 7);
    assert.equal(summary.output_bytes, 4096);
    assert.equal(summary.has_error, true);
    assert.equal(summary.omitted_keys, 2);
    assert.doesNotMatch(encoded, /sensitive-value|private|project|raw/);
  });

  test("stores only bounded intent provenance when host metadata is absent", () => {
    assert.deepEqual(summarizeToolMetadata(undefined, { intentSource: "fallback" }), {
      schema_version: 1,
      original_bytes: 0,
      omitted_keys: 0,
      intent_source: "fallback",
    });
    assert.equal(summarizeToolMetadata(undefined, { intentSource: "untrusted" }), null);
  });
});

describe("part-stream retention", () => {
  test("converges repeated ordinary parts to one bounded summary", () => {
    const tracker = new PartStreamSummaryTracker();
    for (let index = 0; index < 10_000; index++) {
      assert.equal(tracker.observe({
        type: index % 2 === 0 ? "message.part.delta" : "message.part.updated",
        properties: {
          part: { messageID: "message:1", sessionID: "session:1", text: "x".repeat(1000) },
        },
      }), true);
    }

    const summary = tracker.consume({ id: "message:1", sessionID: "session:1" });
    assert.equal(summary.suppressed_part_events, 10_000);
    assert.ok(summary.suppressed_part_bytes > 10_000_000);
    assert.deepEqual(tracker.consume({ id: "message:1", sessionID: "session:1" }), {
      suppressed_part_bytes: 0,
      suppressed_part_events: 0,
    });
  });

  test("never suppresses terminal or error part evidence", () => {
    const tracker = new PartStreamSummaryTracker();
    assert.equal(tracker.observe({
      type: "message.part.updated",
      properties: { part: { state: { status: "completed" } } },
    }), false);
    assert.equal(tracker.observe({
      type: "message.part.delta",
      properties: { part: { error: { name: "Failure" } } },
    }), false);
  });

  test("evicts the least recently observed stream", () => {
    const tracker = new PartStreamSummaryTracker({ maxEntries: 2 });
    const event = (messageID) => ({
      type: "message.part.delta",
      properties: { part: { messageID, sessionID: "session:lru", text: "x" } },
    });

    tracker.observe(event("message:a"));
    tracker.observe(event("message:b"));
    tracker.observe(event("message:a"));
    tracker.observe(event("message:c"));

    assert.equal(
      tracker.consume({ id: "message:a", sessionID: "session:lru" }).suppressed_part_events,
      2,
    );
    assert.equal(
      tracker.consume({ id: "message:b", sessionID: "session:lru" }).suppressed_part_events,
      0,
    );
    assert.equal(
      tracker.consume({ id: "message:c", sessionID: "session:lru" }).suppressed_part_events,
      1,
    );
  });
});
