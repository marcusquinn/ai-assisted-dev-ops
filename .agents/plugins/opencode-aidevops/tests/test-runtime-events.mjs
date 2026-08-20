// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  RUNTIME_EVENT_PAYLOAD_MAX_BYTES,
  RUNTIME_EVENTS_SCHEMA_SQL,
  appendProjectedState,
  appendRuntimeEvent,
  createMergePatch,
  appendStateSnapshot,
  applyMergePatch,
  buildRuntimeEventInsertSql,
  buildStateEventInsertSql,
  createRuntimeEventEnvelope,
  initialiseRuntimeEventStore,
  prepareRuntimePayload,
  queryRuntimeEvents,
  reconstructRuntimeState,
  resolveRuntimeEventsDbPath,
} from "../../../scripts/runtime-events.mjs";
import { canonicalizeSqliteDbPath } from "../../../scripts/sqlite-process.mjs";

const execFileAsync = promisify(execFile);

function sqliteAvailable() {
  try {
    execFileSync("sqlite3", ["-version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

describe("runtime-event envelopes", () => {
  test("strictly allowlists ordinary payloads and redacts secret fixtures", () => {
    const privateRoot = process.env.AIDEVOPS_PRIVATE_ROOTS;
    process.env.AIDEVOPS_PRIVATE_ROOTS = "/srv/private-root";
    const prepared = prepareRuntimePayload({
      reason: [
        "Bearer test-token-value",
        "Basic dXNlcjpwYXNzd29yZA==",
        `AKIA${"A".repeat(16)}`,
        "A".repeat(40),
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature",
        "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----",
        "file:///private/secret.txt",
        "/single-secret",
        "/Users/example/private-repo/file.txt",
        "/srv/private-root/project/file.txt",
        "owner/private-repo",
      ].join(" "),
      password: "not-for-storage",
      apiKey: "camel-case-secret",
      token: "generic-secret",
      status: `prefix ghp_${"x".repeat(32)}`,
      arbitrary_raw_payload: "must-not-persist",
    });
    if (privateRoot === undefined) delete process.env.AIDEVOPS_PRIVATE_ROOTS;
    else process.env.AIDEVOPS_PRIVATE_ROOTS = privateRoot;

    assert.ok(prepared.bytes <= RUNTIME_EVENT_PAYLOAD_MAX_BYTES);
    assert.ok(prepared.redactionCount >= 10);
    assert.equal(prepared.value.password, undefined);
    assert.equal(prepared.value.arbitrary_raw_payload, undefined);
    assert.doesNotMatch(
      prepared.json,
      /test-token-value|not-for-storage|camel-case-secret|generic-secret|ghp_|dXNlc|AKIA|eyJhb|private-material|Users|srv\/private-root|owner\/private/,
    );
    assert.deepEqual(Object.keys(prepared.value), ["reason", "status"]);
  });

  test("redacts camelCase path and repository keys", () => {
    const prepared = prepareRuntimePayload({
      projectRoot: "/Users/example/private-repo",
      repoSlug: "owner/private-repo",
      worktreePath: "file:///private/worktree",
    }, { strictTopLevel: false });
    assert.deepEqual(prepared.value, {
      projectRoot: "[redacted-path]",
      repoSlug: "[redacted-repository]",
      worktreePath: "[redacted-path]",
    });
  });

  test("state payloads remove private path evidence", () => {
    const built = buildStateEventInsertSql({
      subjectId: "worker:42",
      state: {
        cwd: "/Users/example/private-repo",
        note: "read /home/example/private.txt next",
        status: "running",
      },
    }, "state.snapshot");

    assert.doesNotMatch(built.envelope.payload.json, /Users|private-repo|private\.txt/);
    assert.match(built.envelope.payload.json, /redacted-path/);
    assert.equal(built.envelope.eventType, "state.snapshot");
  });

  test("oversized state remains a reconstructable bounded marker", () => {
    const built = buildStateEventInsertSql({
      subjectId: "worker:large",
      state: { items: Array.from({ length: 128 }, () => "x".repeat(2048)) },
    }, "state.snapshot");
    const row = {
      event_type: "state.snapshot",
      state_version: 1,
      subject_id: "worker:large",
      payload_json: built.envelope.payload.json,
    };

    assert.ok(built.envelope.payload.bytes <= RUNTIME_EVENT_PAYLOAD_MAX_BYTES);
    assert.equal(built.envelope.payload.value.state._truncated, true);
    assert.deepEqual(reconstructRuntimeState([row]), {
      state: built.envelope.payload.value.state,
      stateVersion: 1,
    });
  });

  test("unsafe identifiers are deterministically hashed", () => {
    const first = createRuntimeEventEnvelope({
      eventId: "event 1 with whitespace",
      eventType: "worker.started",
      subjectId: "subject with whitespace",
    });
    const second = createRuntimeEventEnvelope({
      eventId: "event 1 with whitespace",
      eventType: "worker.started",
      subjectId: "subject with whitespace",
    });

    assert.match(first.eventId, /^sha256:[a-f0-9]{64}$/);
    assert.equal(first.eventId, second.eventId);
    assert.equal(first.subjectId, second.subjectId);

    const privatePathId = createRuntimeEventEnvelope({
      eventType: "worker.started",
      subjectId: "/Users/example/private-repo",
    });
    assert.match(privatePathId.subjectId, /^sha256:[a-f0-9]{64}$/);
  });

  test("ordinary and state writes fail open", () => {
    assert.equal(appendRuntimeEvent({
      eventType: "worker.started",
      subjectId: "worker:42",
    }, { execute: () => { throw new Error("disk unavailable"); } }), null);

    assert.equal(appendStateSnapshot({
      subjectId: "worker:42",
      state: { status: "running" },
    }, { executeSync: () => { throw new Error("database locked"); } }), null);
  });

  test("state SQL allocates versions inside an immediate transaction", () => {
    const { sql } = buildStateEventInsertSql({
      subjectId: "worker:42",
      patch: { status: "done" },
    }, "state.delta");

    assert.match(sql, /^BEGIN IMMEDIATE;/);
    assert.match(sql, /SELECT MAX\(state_version\)/);
    assert.match(sql, /RETURNING state_version;/);
    assert.match(sql, /COMMIT;$/);
  });

  test("ordinary event SQL preserves the versioned causal envelope", () => {
    const { sql } = buildRuntimeEventInsertSql({
      eventId: "evt-2",
      eventType: "worker.completed",
      correlationId: "corr-1",
      causationId: "evt-1",
      subjectId: "worker:42",
      sessionId: "session:1",
      workerId: "worker:42",
      parentWorkerId: "worker:parent",
      rootWorkerId: "worker:root",
      rootEventId: "evt-1",
      parentEventId: "evt-1",
      payload: { result: "success" },
    });

    for (const value of ["evt-2", "corr-1", "evt-1", "worker:42", "worker:parent", "worker:root", "session:1"]) {
      assert.match(sql, new RegExp(value));
    }
  });

  test("environment lineage is explicit in the event envelope", () => {
    const previous = {
      correlation: process.env.AIDEVOPS_CORRELATION_ID,
      parent: process.env.AIDEVOPS_PARENT_WORKER_ID,
      root: process.env.AIDEVOPS_ROOT_WORKER_ID,
      worker: process.env.AIDEVOPS_WORKER_ID,
    };
    try {
      process.env.AIDEVOPS_WORKER_ID = "worker:child";
      process.env.AIDEVOPS_PARENT_WORKER_ID = "worker:parent";
      process.env.AIDEVOPS_ROOT_WORKER_ID = "worker:root";
      process.env.AIDEVOPS_CORRELATION_ID = "correlation:root";
      const envelope = createRuntimeEventEnvelope({ eventType: "worker.started", subjectId: "worker:child" });
      assert.equal(envelope.workerId, "worker:child");
      assert.equal(envelope.parentWorkerId, "worker:parent");
      assert.equal(envelope.rootWorkerId, "worker:root");
      assert.equal(envelope.correlationId, "correlation:root");
    } finally {
      for (const [name, value] of Object.entries({
        AIDEVOPS_CORRELATION_ID: previous.correlation,
        AIDEVOPS_PARENT_WORKER_ID: previous.parent,
        AIDEVOPS_ROOT_WORKER_ID: previous.root,
        AIDEVOPS_WORKER_ID: previous.worker,
      })) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
    }
  });
});

describe("deterministic state reconstruction", () => {
  test("builds a bounded RFC 7396 delta", () => {
    assert.deepEqual(createMergePatch(
      { keep: true, remove: true, nested: { before: 1 }, list: [1] },
      { keep: true, nested: { before: 2, after: 3 }, list: [2] },
    ), {
      list: [2],
      nested: { after: 3, before: 2 },
      remove: null,
    });
  });
  test("applies RFC 7396 object deletion and array replacement", () => {
    const result = applyMergePatch(
      { z: 1, nested: { keep: true, remove: true }, list: [1, 2] },
      { nested: { remove: null, add: "yes" }, list: [3], a: 2 },
    );

    assert.deepEqual(result, {
      a: 2,
      list: [3],
      nested: { add: "yes", keep: true },
      z: 1,
    });
    assert.deepEqual(Object.keys(result), ["a", "list", "nested", "z"]);
  });
  test("round-trips equal scalar and array patches", () => {
    assert.equal(applyMergePatch("same", createMergePatch("same", "same")), "same");
    assert.deepEqual(applyMergePatch([1, 2], createMergePatch([1, 2], [1, 2])), [1, 2]);
  });

  test("uses the latest snapshot and ordered contiguous deltas", () => {
    const rows = [
      { subject_id: "w", event_type: "state.delta", state_version: 4, payload_json: '{"patch":{"done":true}}' },
      { subject_id: "w", event_type: "state.snapshot", state_version: 1, payload_json: '{"state":{"old":true}}' },
      { subject_id: "w", event_type: "state.snapshot", state_version: 3, payload_json: '{"state":{"count":2}}' },
      { subject_id: "w", event_type: "state.delta", state_version: 2, payload_json: '{"patch":{"old":false}}' },
    ];

    assert.deepEqual(reconstructRuntimeState(rows, { subjectId: "w" }), {
      state: { count: 2, done: true },
      stateVersion: 4,
    });
    assert.deepEqual(reconstructRuntimeState(rows, { subjectId: "w", targetVersion: 2 }), {
      state: { old: false },
      stateVersion: 2,
    });
  });

  test("rejects gaps after the reconstruction snapshot", () => {
    assert.throws(() => reconstructRuntimeState([
      { subject_id: "w", event_type: "state.snapshot", state_version: 1, payload_json: '{"state":{}}' },
      { subject_id: "w", event_type: "state.delta", state_version: 3, payload_json: '{"patch":{"x":1}}' },
    ]), /not contiguous/);
  });
});

test("appendProjectedState suppresses no-ops and snapshots desired null properties", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-projected-state-"));
  const dbPath = join(tempDir, "observability.db");
  try {
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    assert.equal(appendProjectedState({ subjectId: "state:null", state: { value: 1 } })?.eventType, "state.snapshot");
    assert.equal(appendProjectedState({ subjectId: "state:null", state: { value: 1 } }), null);
    assert.equal(appendProjectedState({ subjectId: "state:null", state: { value: null } })?.eventType, "state.snapshot");
    assert.equal(appendProjectedState({ subjectId: "state:scalar", state: "steady" })?.eventType, "state.snapshot");
    assert.equal(appendProjectedState({ subjectId: "state:scalar", state: "steady" }), null);
    assert.equal(appendProjectedState({ subjectId: "state:array", state: [1, 2] })?.eventType, "state.snapshot");
    assert.equal(appendProjectedState({ subjectId: "state:array", state: [1, 2] }), null);
    const rows = queryRuntimeEvents({ subjectId: "state:null", limit: 10 });
    assert.equal(rows.length, 2);
    assert.deepEqual(reconstructRuntimeState(rows, { subjectId: "state:null" }), {
      state: { value: null },
      stateVersion: 2,
    });
    assert.deepEqual(reconstructRuntimeState(
      queryRuntimeEvents({ subjectId: "state:scalar", limit: 10 }),
      { subjectId: "state:scalar" },
    ), { state: "steady", stateVersion: 1 });
    assert.deepEqual(reconstructRuntimeState(
      queryRuntimeEvents({ subjectId: "state:array", limit: 10 }),
      { subjectId: "state:array" },
    ), { state: [1, 2], stateVersion: 1 });
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("concurrent appendProjectedState writers cannot commit stale-base deltas", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-projected-state-race-"));
  const dbPath = join(tempDir, "observability.db");
  const runtimeUrl = new URL("../../../scripts/runtime-events.mjs", import.meta.url).href;
  try {
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    assert.ok(appendProjectedState({ subjectId: "state:race", state: { winner: -1 } }));
    const writes = Array.from({ length: 8 }, (_unused, index) => execFileAsync(
      process.execPath,
      ["--input-type=module", "-e", `
        const runtime = await import(${JSON.stringify(runtimeUrl)});
        if (!runtime.initialiseRuntimeEventStore(${JSON.stringify(dbPath)})) process.exit(2);
        if (!runtime.appendProjectedState({ subjectId: "state:race", state: { winner: ${index} } })) process.exit(3);
      `],
      { timeout: 30000 },
    ));
    await Promise.all(writes);
    const rows = queryRuntimeEvents({ subjectId: "state:race", limit: 20 });
    assert.equal(rows.length, 9);
    const reconstructed = reconstructRuntimeState(rows, { subjectId: "state:race" });
    assert.equal(reconstructed.stateVersion, 9);
    assert.ok(Number.isInteger(reconstructed.state.winner));
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("database overrides are canonical argv values, never shell input", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-db-path-"));
  const marker = join(tempDir, "injected");
  const dbPath = join(tempDir, `observability.db\"; touch ${marker}; #`);
  try {
    assert.equal(
      resolveRuntimeEventsDbPath({ AIDEVOPS_OBS_DB_OVERRIDE: dbPath }),
      canonicalizeSqliteDbPath(dbPath),
    );
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    assert.equal(existsSync(marker), false);
    assert.throws(() => canonicalizeSqliteDbPath("relative.db"), /absolute filesystem path/);
    assert.throws(() => canonicalizeSqliteDbPath("file:///tmp/events.db"), /absolute filesystem path/);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("runtime-events authority migrates legacy worker lineage columns", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-migration-"));
  const dbPath = join(tempDir, "observability.db");
  try {
    execFileSync("sqlite3", [dbPath], { input: `
      CREATE TABLE runtime_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        envelope_version INTEGER NOT NULL,
        occurred_at TEXT NOT NULL,
        event_id TEXT NOT NULL UNIQUE,
        event_type TEXT NOT NULL,
        correlation_id TEXT NOT NULL,
        causation_id TEXT,
        subject_id TEXT NOT NULL,
        session_id TEXT,
        worker_id TEXT,
        root_event_id TEXT NOT NULL,
        parent_event_id TEXT,
        state_version INTEGER,
        payload_json TEXT NOT NULL,
        payload_bytes INTEGER NOT NULL,
        redaction_count INTEGER NOT NULL DEFAULT 0
      );
    ` });
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    const columns = execFileSync("sqlite3", [dbPath, `
      SELECT group_concat(name, ',') FROM (
        SELECT name FROM pragma_table_info('runtime_events')
        WHERE name IN ('parent_worker_id', 'root_worker_id') ORDER BY name
      );
    `], { encoding: "utf8" }).trim();
    assert.equal(columns, "parent_worker_id,root_worker_id");
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("SQLite enforces append-only rows and concurrent state versions", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-events-"));
  const dbPath = join(tempDir, "observability.db");
  try {
    execFileSync("sqlite3", [dbPath], { input: `PRAGMA journal_mode=WAL;\n${RUNTIME_EVENTS_SCHEMA_SQL}` });
    const ordinary = buildRuntimeEventInsertSql({
      eventType: "session.started",
      subjectId: "session:1",
      payload: { source: "test" },
    });
    execFileSync("sqlite3", [dbPath], { input: ordinary.sql });

    assert.throws(() => execFileSync(
      "sqlite3",
      [dbPath, "UPDATE runtime_events SET event_type='changed';"],
      { stdio: "pipe" },
    ));
    assert.throws(() => execFileSync(
      "sqlite3",
      [dbPath, "DELETE FROM runtime_events;"],
      { stdio: "pipe" },
    ));

    const snapshot = buildStateEventInsertSql({
      subjectId: "worker:42",
      state: { count: 0 },
    }, "state.snapshot");
    execFileSync("sqlite3", ["-cmd", ".timeout 5000", dbPath, snapshot.sql]);

    const writes = Array.from({ length: 8 }, (_unused, index) => {
      const delta = buildStateEventInsertSql({
        subjectId: "worker:42",
        patch: { count: index + 1 },
      }, "state.delta");
      return execFileAsync("sqlite3", ["-cmd", ".timeout 5000", dbPath, delta.sql]);
    });
    await Promise.all(writes);

    const versions = execFileSync("sqlite3", [
      dbPath,
      "SELECT group_concat(state_version, ',') FROM (SELECT state_version FROM runtime_events WHERE subject_id='worker:42' ORDER BY state_version);",
    ], { encoding: "utf8" }).trim();
    assert.equal(versions, "1,2,3,4,5,6,7,8,9");
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("OpenCode observability migrates existing tool-call rows without guessing outcomes", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-observability-migration-"));
  const dbPath = join(tempDir, "llm-requests.db");
  const observabilityUrl = new URL("../observability.mjs", import.meta.url).href;
  const driver = `
    const observability = await import(${JSON.stringify(observabilityUrl)});
    if (!observability.initObservability()) process.exit(2);
    process.exit(0);
  `;

  try {
    execFileSync("sqlite3", [dbPath, `
      CREATE TABLE tool_calls (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        call_id TEXT,
        tool_name TEXT NOT NULL,
        intent TEXT,
        success INTEGER DEFAULT 1,
        duration_ms INTEGER,
        metadata TEXT
      );
      INSERT INTO tool_calls (session_id, call_id, tool_name, success)
      VALUES ('legacy-session', 'legacy-call', 'Bash', 0);
    `]);
    execFileSync(process.execPath, ["--input-type=module", "-e", driver], {
      env: { ...process.env, AIDEVOPS_OBS_DB_OVERRIDE: dbPath },
      stdio: "pipe",
      timeout: 5000,
    });
    const migrated = execFileSync("sqlite3", [dbPath, `
      SELECT
        (SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='outcome_category'),
        (SELECT success FROM tool_calls WHERE call_id='legacy-call'),
        (SELECT outcome_category IS NULL FROM tool_calls WHERE call_id='legacy-call');
    `], { encoding: "utf8" }).trim();
    assert.equal(migrated, "1|0|1");
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("OpenCode observability emits runtime evidence without changing legacy tables", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-events-plugin-"));
  const dbPath = join(tempDir, "llm-requests.db");
  const observabilityUrl = new URL("../observability.mjs", import.meta.url).href;
  const driver = `
    const observability = await import(${JSON.stringify(observabilityUrl)});
    if (!observability.initObservability()) process.exit(2);
    observability.handleEvent({ event: {
      type: "session.created",
      properties: { info: { id: "session:1", sessionID: "session:1" } },
    } });
    for (let index = 0; index < 100; index++) {
      observability.handleEvent({ event: {
        type: "message.part.delta",
        properties: { part: {
          id: "part:1", messageID: "message:1", sessionID: "session:1", text: "stream fragment",
        } },
      } });
    }
    observability.handleEvent({ event: {
      type: "message.part.updated",
      properties: { part: {
        error: { name: "PartFailure" }, id: "part:error", messageID: "message:1",
        sessionID: "session:1", state: { status: "failed" },
      } },
    } });
    observability.handleEvent({ event: {
      type: "message.updated",
      properties: { info: {
        id: "message:1", sessionID: "session:1", role: "assistant",
        providerID: "test", modelID: "test-model", finish: "stop",
        time: { created: 1, completed: 11 },
        tokens: { input: 2, output: 3, total: 5, cache: { read: 0, write: 0 } },
      } },
    } });
    observability.handleEvent({ event: {
      type: "session.error",
      properties: {
        sessionID: "session:1",
        error: {
          name: "APIError",
          data: {
            message: "Forbidden", statusCode: 403, isRetryable: false,
            responseBody: "<!doctype html><title>Forbidden</title>",
            responseHeaders: { authorization: "Bearer private", "x-request-id": "req-safe" },
          },
        },
      },
    } }, { resolveSessionModel: () => "openai/test-model" });
    observability.recordToolCall(
      { tool: "Read", sessionID: "session:1", callID: "call:1" },
      { output: "ok", metadata: { bytes: 1 } },
      "reading a fixture",
      5,
    );
    if (!observability.recordSubagentCancellationReceipt({
      complete: true,
      incomplete_reasons: [],
      ledger: [{ kind: "git", operation: "push", status: "completed", tool: "bash" }],
      reaped: true,
      termination: "confirmed",
      truncated: false,
    }, { childSessionID: "session:child", parentSessionID: "session:1" })) process.exit(3);
    await new Promise((resolve) => setTimeout(resolve, 500));
    process.exit(0);
  `;

  try {
    execFileSync(process.execPath, ["--input-type=module", "-e", driver], {
      env: { ...process.env, AIDEVOPS_OBS_DB_OVERRIDE: dbPath },
      stdio: "pipe",
      timeout: 5000,
    });
    const counts = execFileSync("sqlite3", [dbPath, `
      SELECT
        (SELECT COUNT(*) FROM llm_requests),
        (SELECT COUNT(*) FROM tool_calls),
        (SELECT COUNT(*) FROM runtime_events),
        (SELECT group_concat(event_type, ',') FROM (
          SELECT event_type FROM runtime_events ORDER BY id
        )),
        (SELECT json_extract(payload_json, '$.suppressed_part_events')
          FROM runtime_events WHERE event_type = 'message.completed'),
        (SELECT json_extract(payload_json, '$.error_type')
          FROM runtime_events WHERE event_type = 'message.part.updated'),
        (SELECT json_extract(payload_json, '$.observation.provider_error.classification')
          FROM runtime_events WHERE event_type = 'session.error'),
        (SELECT json_extract(payload_json, '$.observation.provider_error.request_id')
          FROM runtime_events WHERE event_type = 'session.error'),
        (SELECT payload_json NOT LIKE '%private%' AND payload_json NOT LIKE '%doctype%'
          FROM runtime_events WHERE event_type = 'session.error'),
        (SELECT json_extract(payload_json, '$.outcome_category')
          FROM runtime_events WHERE event_type = 'tool.completed'),
        (SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='outcome_category');
    `], { encoding: "utf8" }).trim();
    assert.equal(
      counts,
      "1|1|6|session.created,message.part.updated,message.completed,session.error,tool.completed,subagent.cancellation.receipt|100|PartFailure|gateway_denied|req-safe|1|success|1",
    );
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});
