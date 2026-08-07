// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {pathToFileURL, fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const scriptDirectory = path.resolve(testDirectory, "..");
const templatePath = path.join(scriptDirectory, "matrix-session-store.mjs.template");
const botTemplatePath = path.join(scriptDirectory, "matrix-bot.mjs.template");
const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || path.join(os.homedir(), ".aidevops/.agent-workspace/tmp");

const pythonSqliteScript = `
import json
import sqlite3
import sys

database_path, mode, sql = sys.argv[1:4]
parameters = json.load(sys.stdin)
connection = sqlite3.connect(database_path)
connection.row_factory = sqlite3.Row
try:
    if mode == "exec":
        connection.executescript(sql)
        connection.commit()
        output = {}
    else:
        cursor = connection.execute(sql, parameters)
        if mode == "get":
            row = cursor.fetchone()
            output = dict(row) if row is not None else None
        elif mode == "all":
            output = [dict(row) for row in cursor.fetchall()]
        elif mode == "run":
            connection.commit()
            output = {"changes": max(cursor.rowcount, 0), "lastInsertRowid": cursor.lastrowid}
        else:
            raise RuntimeError("unsupported mode")
    print(json.dumps(output))
finally:
    connection.close()
`;

const pythonDatabaseModule = `
import {spawnSync} from "node:child_process";

const PYTHON = ${JSON.stringify(pythonSqliteScript)};

function execute(databasePath, mode, sql, parameters = []) {
  const result = spawnSync("python3", ["-c", PYTHON, databasePath, mode, sql], {
    encoding: "utf8",
    input: JSON.stringify(parameters),
  });
  if (result.status !== 0) throw new Error("Python SQLite fixture failed");
  return JSON.parse(result.stdout || "null");
}

export default class PythonDatabase {
  constructor(databasePath) {
    this.databasePath = databasePath;
  }

  pragma(statement) {
    return execute(this.databasePath, "run", "PRAGMA " + statement);
  }

  exec(sql) {
    return execute(this.databasePath, "exec", sql);
  }

  prepare(sql) {
    const databasePath = this.databasePath;
    return {
      all(...parameters) {
        return execute(databasePath, "all", sql, parameters);
      },
      get(...parameters) {
        return execute(databasePath, "get", sql, parameters);
      },
      run(...parameters) {
        return execute(databasePath, "run", sql, parameters);
      },
    };
  }

  transaction(callback) {
    return (...args) => callback(...args);
  }

  close() {}
}
`;

function ensureDirectory(directoryPath) {
  fs.mkdirSync(directoryPath, {mode: 0o700, recursive: true});
}

function stableId(prefix, value) {
  return `${prefix}.${value.repeat(64)}`;
}

function withoutConsoleErrors(callback) {
  const original = console.error;
  console.error = () => {};
  try {
    return callback();
  } finally {
    console.error = original;
  }
}

ensureDirectory(temporaryParent);
const sandbox = fs.mkdtempSync(path.join(temporaryParent, "matrix-session-store-"));
const memoryDirectory = path.join(sandbox, "memory");
const databasePath = path.join(memoryDirectory, "memory.db");
const databaseModulePath = path.join(sandbox, "python-database.mjs");
const storePath = path.join(sandbox, "session-store.mjs");
const priorHome = process.env.HOME;
const priorMemoryDirectory = process.env.AIDEVOPS_MEMORY_DIR;
let store;

try {
  ensureDirectory(memoryDirectory);
  fs.writeFileSync(databaseModulePath, pythonDatabaseModule, {mode: 0o600});
  const template = fs.readFileSync(templatePath, "utf8");
  assert.equal(template.includes('import Database from "better-sqlite3";'), true);
  fs.writeFileSync(
    storePath,
    template.replace('import Database from "better-sqlite3";', 'import Database from "./python-database.mjs";'),
    {mode: 0o600},
  );

  const {default: PythonDatabase} = await import(pathToFileURL(databaseModulePath).href);
  const fixtureDb = new PythonDatabase(databasePath);
  fixtureDb.exec(`
    CREATE TABLE entities (id TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE entity_channels (entity_id TEXT, channel TEXT, channel_id TEXT);
    CREATE TABLE interactions (
      id TEXT PRIMARY KEY,
      entity_id TEXT NOT NULL,
      channel TEXT NOT NULL,
      channel_id TEXT,
      conversation_id TEXT,
      direction TEXT NOT NULL,
      content TEXT NOT NULL,
      metadata TEXT DEFAULT '{}',
      created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      entity_id TEXT NOT NULL,
      channel TEXT NOT NULL,
      channel_id TEXT,
      summary TEXT DEFAULT '',
      status TEXT DEFAULT 'active',
      updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE matrix_room_sessions (
      room_id TEXT PRIMARY KEY,
      session_id TEXT DEFAULT '',
      entity_id TEXT DEFAULT '',
      conversation_id TEXT DEFAULT '',
      runner_name TEXT DEFAULT '',
      message_count INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      last_active TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    INSERT INTO entities(id, name) VALUES ('entity-a', 'Entity A'), ('entity-b', 'Entity B');
    INSERT INTO matrix_room_sessions(
      room_id, session_id, entity_id, conversation_id, runner_name, message_count
    ) VALUES ('!legacy:fixture.invalid', 'legacy-session', 'entity-a', 'legacy-conversation', 'legacy-runner', 9);
  `);

  process.env.HOME = sandbox;
  process.env.AIDEVOPS_MEMORY_DIR = memoryDirectory;
  store = await import(`${pathToFileURL(storePath).href}?fixture=1`);

  const roomA = "!room-a:fixture.invalid";
  const roomB = "!room-b:fixture.invalid";
  const actorA = stableId("subject.matrix", "a");
  const actorB = stableId("subject.matrix", "b");
  const conversationA = stableId("conversation.matrix", "c");
  const conversationB = stableId("conversation.matrix", "d");
  const eventA = stableId("idempotency.matrix", "e");

  const migratedColumns = fixtureDb.prepare("PRAGMA table_info(matrix_room_sessions)").all();
  assert.equal(migratedColumns.some(({name}) => name === "actor_id"), false, "migration must be lazy");

  let session = store.getSession(roomA, "runner-one", actorA, conversationA);
  assert.equal(session.actor_id, actorA);
  assert.equal(session.conversation_id, conversationA);
  assert.equal(session.runner_name, "runner-one");
  assert.equal(store.claimEvent(eventA, actorA, conversationA), true);
  assert.equal(store.claimEvent(eventA, actorA, conversationA), false);
  store.close();
  assert.equal(store.claimEvent(eventA, actorA, conversationA), false, "receipt must survive store restart");

  const columns = fixtureDb.prepare("PRAGMA table_info(matrix_room_sessions)").all();
  assert.equal(columns.some(({name}) => name === "actor_id"), true);
  assert.equal(fixtureDb.prepare("SELECT COUNT(*) AS count FROM conversations").get().count, 0);
  store.updateSessionEntity(roomA, actorA, "entity-a", conversationA);
  assert.deepEqual(
    fixtureDb.prepare(`
      SELECT entity_id, channel, channel_id, status
      FROM conversations
      WHERE id = ?
    `).get(conversationA),
    {entity_id: "entity-a", channel: "matrix", channel_id: roomA, status: "active"},
  );
  store.setSessionId(roomA, actorA, "upstream-a");

  const insertInteraction = fixtureDb.prepare(`
    INSERT INTO interactions(
      id, entity_id, channel, channel_id, conversation_id, direction, content, created_at
    ) VALUES (?, ?, 'matrix', ?, ?, ?, ?, ?)
  `);
  insertInteraction.run("interaction-safe", "entity-a", roomA, conversationA, "inbound", "safe context", "2026-08-07T00:00:01Z");
  insertInteraction.run("interaction-other-room", "entity-a", roomB, conversationA, "inbound", "ROOM_LEAK_CANARY", "2026-08-07T00:00:02Z");
  insertInteraction.run("interaction-other-conversation", "entity-a", roomA, conversationB, "inbound", "CONVERSATION_LEAK_CANARY", "2026-08-07T00:00:03Z");
  insertInteraction.run("interaction-other-entity", "entity-b", roomA, conversationA, "inbound", "ENTITY_LEAK_CANARY", "2026-08-07T00:00:04Z");
  fixtureDb.prepare("UPDATE conversations SET summary = ? WHERE id = ?")
    .run("isolated summary", conversationA);

  assert.deepEqual(
    store.getRecentMessages(roomA, actorA, 20).map(({content}) => content),
    ["safe context"],
  );
  assert.equal(store.getCompactedContext(roomA, actorA), "isolated summary");

  session = store.getSession(roomA, "runner-one", actorB, conversationB);
  assert.equal(session.actor_id, actorB);
  assert.equal(session.conversation_id, conversationB);
  assert.equal(session.entity_id, "");
  assert.equal(session.session_id, "");
  assert.equal(session.message_count, 0);
  assert.equal(fixtureDb.prepare("SELECT COUNT(*) AS count FROM interactions").get().count, 4);

  store.updateSessionEntity(roomA, actorB, "entity-b", conversationB);
  store.setSessionId(roomA, actorB, "upstream-b");
  insertInteraction.run("interaction-b-safe", "entity-b", roomA, conversationB, "inbound", "actor B context", "2026-08-07T00:00:05Z");
  assert.deepEqual(
    store.getRecentMessages(roomA, actorB, 20).map(({content}) => content),
    ["actor B context"],
  );

  withoutConsoleErrors(() => store.addMessage(roomA, actorB, "user", "new message"));
  assert.equal(store.getSession(roomA, "", actorB, conversationB).message_count, 1);

  session = store.getSession(roomA, "runner-two", actorB, conversationB);
  assert.equal(session.runner_name, "runner-two");
  assert.equal(session.session_id, "", "runner remap must not inherit an upstream session");
  assert.equal(session.entity_id, "entity-b");
  assert.equal(session.message_count, 0);

  fixtureDb.prepare("UPDATE conversations SET summary = ? WHERE id = ?")
    .run("before compaction", conversationB);
  store.setSessionId(roomA, actorB, "upstream-b-two");
  withoutConsoleErrors(() => store.addMessage(roomA, actorB, "assistant", "response"));
  const interactionCount = fixtureDb.prepare("SELECT COUNT(*) AS count FROM interactions").get().count;
  fixtureDb.prepare("DELETE FROM conversations WHERE id = ?").run(conversationB);
  assert.throws(
    () => store.compactSession(roomA, actorB, "must not be discarded"),
    /compaction was not persisted/u,
  );
  assert.equal(store.getSession(roomA, "", actorB, conversationB).session_id, "upstream-b-two");
  store.updateSessionEntity(roomA, actorB, "entity-b", conversationB);
  store.compactSession(roomA, actorB, "after compaction");
  assert.equal(store.getCompactedContext(roomA, actorB), "after compaction");
  assert.equal(store.getSession(roomA, "", actorB, conversationB).session_id, "");
  assert.equal(fixtureDb.prepare("SELECT COUNT(*) AS count FROM interactions").get().count, interactionCount);
  store.close();
  assert.equal(store.getCompactedContext(roomA, actorB), "after compaction");

  const migratedLegacy = store.getSession(
    "!legacy:fixture.invalid",
    "legacy-runner",
    actorA,
    conversationA,
  );
  assert.equal(migratedLegacy.actor_id, actorA);
  assert.equal(migratedLegacy.entity_id, "");
  assert.equal(migratedLegacy.session_id, "");
  assert.equal(migratedLegacy.message_count, 0);

  const botTemplate = fs.readFileSync(botTemplatePath, "utf8");
  const normalizePosition = botTemplate.indexOf("normalizeMatrixIngress(");
  const claimPosition = botTemplate.indexOf("store.claimEvent(");
  const typingPosition = botTemplate.indexOf("client.setTyping(roomId, true");
  const dispatchPosition = botTemplate.indexOf("dispatchToRunner(runnerName, contextualPrompt)");
  assert.equal(normalizePosition > 0, true);
  assert.equal(claimPosition > normalizePosition, true);
  assert.equal(typingPosition > claimPosition, true);
  assert.equal(dispatchPosition > claimPosition, true);
  assert.equal(botTemplate.includes("event.content?.displayname"), false);
  assert.equal(botTemplate.includes("Unable to dispatch this request. Check the local bot logs."), true);
  assert.equal(botTemplate.includes("Error dispatching to runner"), false);
  assert.equal(botTemplate.includes("checkConversationIdle(session.conversation_id"), true);

  console.log("Matrix session store tests passed");
} finally {
  store?.close();
  if (priorHome === undefined) delete process.env.HOME;
  else process.env.HOME = priorHome;
  if (priorMemoryDirectory === undefined) delete process.env.AIDEVOPS_MEMORY_DIR;
  else process.env.AIDEVOPS_MEMORY_DIR = priorMemoryDirectory;
  fs.rmSync(sandbox, {force: true, recursive: true});
}
