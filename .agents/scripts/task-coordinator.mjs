#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalizeSqliteDbPath, sqlEscape } from "./sqlite-process.mjs";

const SCHEMA_VERSION = 8;
const PAYLOAD_MAX_BYTES = 64 * 1024;
const EVIDENCE_MAX_BYTES = 64 * 1024;
const CROCKFORD = "0123456789abcdefghjkmnpqrstvwxyz";
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const LEGACY_ID = /^t[1-9][0-9]{0,17}$/;
const LEGACY_TASK_ID = /^t[1-9][0-9]{0,17}(?:\.[1-9][0-9]{0,17}){0,8}$/;
const TASK_ID = /^(?:t[1-9][0-9]{0,17}(?:\.[1-9][0-9]{0,17})*|to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17}(?:\.[1-9][0-9]{0,17})*)$/;
const STATES = new Set(["active", "read-only", "redirected", "retired", "quarantined"]);
const RESULTS = new Set(["published", "retryable", "indeterminate", "terminal", "conflict"]);
const MAPPING_ROLES = new Set(["home", "implementation", "upstream"]);
const FORGE_EVENT_KINDS = new Set(["issue", "pull_request", "push", "manual"]);
const FORGE_EVENT_ACTIONS = new Set(["opened", "edited", "assigned", "closed", "reopened", "merged", "pushed", "requested"]);

const SCHEMA = `
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS coordinator_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS origins (
  origin_id TEXT PRIMARY KEY, state TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0 CHECK(sequence >= 0),
  ownership_epoch INTEGER NOT NULL DEFAULT 1 CHECK(ownership_epoch > 0), fencing_token TEXT NOT NULL,
  created_at TEXT NOT NULL, CHECK(state IN ('active','read-only','redirected','retired','quarantined'))
);
CREATE TABLE IF NOT EXISTS origin_transitions (
  id INTEGER PRIMARY KEY, origin_id TEXT NOT NULL REFERENCES origins(origin_id),
  from_state TEXT, to_state TEXT NOT NULL, ownership_epoch INTEGER NOT NULL,
  fencing_token TEXT NOT NULL, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)), occurred_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY, origin_id TEXT NOT NULL REFERENCES origins(origin_id),
  sequence INTEGER NOT NULL CHECK(sequence > 0), parent_task_id TEXT REFERENCES tasks(task_id),
  created_operation_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), created_at TEXT NOT NULL, UNIQUE(origin_id, sequence)
);
CREATE TABLE IF NOT EXISTS operations (
  operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL, task_id TEXT,
  payload_hash TEXT NOT NULL, payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), status TEXT NOT NULL,
  result_json TEXT NOT NULL CHECK(json_valid(result_json)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK(status IN ('published','retryable','indeterminate','terminal','conflict'))
);
CREATE TABLE IF NOT EXISTS publication_intents (
  intent_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(operation_id),
  task_id TEXT NOT NULL REFERENCES tasks(task_id), payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), status TEXT NOT NULL DEFAULT 'retryable', created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS publication_queue (
  intent_id TEXT PRIMARY KEY REFERENCES publication_intents(intent_id), repository_id TEXT NOT NULL,
  repository_path TEXT NOT NULL, remote_name TEXT NOT NULL, branch_name TEXT NOT NULL,
  coalesce_key TEXT NOT NULL, sequence INTEGER NOT NULL UNIQUE, available_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 5,
  lease_token INTEGER, CHECK(attempt_count >= 0), CHECK(max_attempts > 0)
);
CREATE TABLE IF NOT EXISTS publication_leases (
  repository_id TEXT PRIMARY KEY, fencing_token INTEGER NOT NULL CHECK(fencing_token > 0),
  owner_id TEXT NOT NULL, expires_at INTEGER NOT NULL, acquired_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS publication_attempts (
  id INTEGER PRIMARY KEY, intent_id TEXT NOT NULL REFERENCES publication_intents(intent_id),
  attempt_number INTEGER NOT NULL, status TEXT NOT NULL, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)),
  occurred_at TEXT NOT NULL, UNIQUE(intent_id, attempt_number)
);
CREATE TABLE IF NOT EXISTS terminal_evidence (
  id INTEGER PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(operation_id),
  result_state TEXT NOT NULL, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)), occurred_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS migration_history (
  version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL, backup_path TEXT, integrity_result TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS restore_controls (
  id INTEGER PRIMARY KEY, origin_id TEXT NOT NULL, prior_epoch INTEGER NOT NULL,
  new_epoch INTEGER NOT NULL, fencing_token TEXT NOT NULL UNIQUE,
  registry_evidence_json TEXT NOT NULL CHECK(json_valid(registry_evidence_json)), backup_integrity TEXT NOT NULL,
  backup_high_water INTEGER NOT NULL, published_high_water INTEGER NOT NULL, restored_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS issue_mappings (
  task_id TEXT NOT NULL, forge TEXT NOT NULL, repository_id TEXT NOT NULL,
  repository_slug TEXT NOT NULL, role TEXT NOT NULL, issue_id TEXT NOT NULL,
  project_id TEXT, display_number INTEGER NOT NULL CHECK(display_number > 0),
  state_cursor TEXT, sync_metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(sync_metadata_json)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY(task_id, forge, repository_id),
  UNIQUE(forge, repository_id, issue_id),
  UNIQUE(forge, repository_id, display_number),
  CHECK(forge IN ('github')), CHECK(role IN ('home','implementation','upstream'))
);
CREATE TABLE IF NOT EXISTS legacy_task_adoptions (
  task_id TEXT PRIMARY KEY REFERENCES tasks(task_id), repository_id TEXT NOT NULL,
  adopted_operation_id TEXT NOT NULL REFERENCES operations(operation_id), adopted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS repository_task_aliases (
  local_task_id TEXT NOT NULL, forge TEXT NOT NULL, repository_id TEXT NOT NULL, task_id TEXT NOT NULL,
  PRIMARY KEY(local_task_id,forge,repository_id), UNIQUE(task_id,forge,repository_id),
  FOREIGN KEY(task_id,forge,repository_id) REFERENCES issue_mappings(task_id,forge,repository_id)
);
CREATE TABLE IF NOT EXISTS forge_event_cursors (
  forge TEXT NOT NULL, repository_id TEXT NOT NULL, subject_kind TEXT NOT NULL, subject_id TEXT NOT NULL,
  cursor_timestamp TEXT NOT NULL, cursor_tiebreaker TEXT NOT NULL, payload_hash TEXT NOT NULL,
  operation_id TEXT NOT NULL REFERENCES operations(operation_id), transition_kind TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  PRIMARY KEY(forge, repository_id, subject_kind, subject_id)
);
CREATE TRIGGER IF NOT EXISTS tasks_immutable_update BEFORE UPDATE ON tasks BEGIN SELECT RAISE(ABORT, 'tasks are immutable'); END;
CREATE TRIGGER IF NOT EXISTS tasks_immutable_delete BEFORE DELETE ON tasks BEGIN SELECT RAISE(ABORT, 'tasks are immutable'); END;
CREATE TRIGGER IF NOT EXISTS origin_transitions_append_only_update BEFORE UPDATE ON origin_transitions BEGIN SELECT RAISE(ABORT, 'origin transitions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS origin_transitions_append_only_delete BEFORE DELETE ON origin_transitions BEGIN SELECT RAISE(ABORT, 'origin transitions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS terminal_evidence_append_only_update BEFORE UPDATE ON terminal_evidence BEGIN SELECT RAISE(ABORT, 'terminal evidence is append-only'); END;
CREATE TRIGGER IF NOT EXISTS terminal_evidence_append_only_delete BEFORE DELETE ON terminal_evidence BEGIN SELECT RAISE(ABORT, 'terminal evidence is append-only'); END;
`;

function now() { return new Date().toISOString(); }
function jsonText(value, label, maxBytes = PAYLOAD_MAX_BYTES) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${label} must be a JSON object`);
  const text = JSON.stringify(value);
  if (Buffer.byteLength(text) > maxBytes) throw new TypeError(`${label} exceeds ${maxBytes} bytes`);
  return text;
}
function hashText(text) { return `sha256:${createHash("sha256").update(text).digest("hex")}`; }
function hashPayload(payload) { return hashText(jsonText(payload, "payload")); }
function validId(value, label) {
  if (typeof value !== "string" || !SAFE_ID.test(value)) throw new TypeError(`${label} is not a canonical opaque identifier`);
  return value;
}
function canonicalRfc3339(value, label) {
  const match = typeof value === "string" ? /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{3}))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value) : null;
  if (!match) throw new TypeError(`${label} must be a valid RFC3339 timestamp`);
  const [, year, month, day, hour, minute, second, , zone, sign, rawOffsetHours, rawOffsetMinutes] = match;
  const offsetHours = zone === "Z" ? 0 : Number(rawOffsetHours);
  const offsetMinutes = zone === "Z" ? 0 : Number(rawOffsetMinutes);
  const epoch = Date.parse(value);
  if (!Number.isFinite(epoch) || offsetHours > 23 || offsetMinutes > 59) {
    throw new TypeError(`${label} must be a valid RFC3339 timestamp`);
  }
  const offsetDirection = sign === "-" ? -1 : 1;
  const localEpoch = epoch + offsetDirection * (offsetHours * 60 + offsetMinutes) * 60_000;
  const expectedLocal = `${year}-${month}-${day}T${hour}:${minute}:${second}`;
  if (!new Date(localEpoch).toISOString().startsWith(expectedLocal)) {
    throw new TypeError(`${label} must be a valid RFC3339 timestamp`);
  }
  return new Date(epoch).toISOString();
}
function originId() {
  let value = BigInt(`0x${randomBytes(16).toString("hex")}`);
  let encoded = "";
  for (let index = 0; index < 26; index += 1) {
    encoded = CROCKFORD[Number(value & 31n)] + encoded;
    value >>= 5n;
  }
  return `o${encoded}`;
}
function dbPath(env = process.env) {
  return canonicalizeSqliteDbPath(resolve(env.AIDEVOPS_TASK_COORDINATOR_DB ||
    join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "coordinator", "tasks.db")));
}
function sqlite(path, input, { json = false } = {}) {
  const args = ["-batch", "-bail", "-cmd", ".timeout 15000"];
  if (json) args.push("-json");
  args.push(path);
  return execFileSync("sqlite3", args, { input, encoding: "utf8", timeout: 30000 }).trim();
}
function rows(path, query) {
  const raw = sqlite(path, query, { json: true });
  return raw ? JSON.parse(raw) : [];
}
function secureFile(path) {
  chmodSync(path, 0o600);
  return path;
}
function backup(path, reason) {
  if (!existsSync(path)) return "";
  if (!/^[a-z0-9-]{1,48}$/.test(reason)) throw new TypeError("invalid backup reason");
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("source database failed integrity verification");
  const target = `${path}-backup-${Date.now()}-${reason}.db`;
  sqlite(path, `.backup ${sqlEscape(target)}\n`);
  secureFile(target);
  if (sqlite(target, "PRAGMA integrity_check;\n") !== "ok") throw new Error("backup integrity verification failed");
  return target;
}
function migrateV1ToV2(path) {
  const copy = backup(path, "pre-migrate-v2");
  sqlite(path, `BEGIN IMMEDIATE;
ALTER TABLE operations ADD COLUMN result_hash TEXT NOT NULL DEFAULT 'unchecked';
ALTER TABLE restore_controls ADD COLUMN backup_high_water INTEGER NOT NULL DEFAULT 0;
UPDATE coordinator_meta SET value='2' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (2,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV2ToV3(path) {
  const copy = backup(path, "pre-migrate-v3");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='3' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (3,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV3ToV4(path) {
  const copy = backup(path, "pre-migrate-v4");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='4' WHERE key='schema_version';
INSERT OR IGNORE INTO coordinator_meta VALUES ('publication_fence','0');
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (4,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV4ToV5(path) {
  const copy = backup(path, "pre-migrate-v5");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='5' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (5,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV5ToV6(path) {
  const copy = backup(path, "pre-migrate-v6");
  sqlite(path, `BEGIN IMMEDIATE;
ALTER TABLE operations DROP COLUMN result_hash;
UPDATE coordinator_meta SET value='6' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (6,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV6ToV7(path) {
  const copy = backup(path, "pre-migrate-v7");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='7' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (7,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV7ToV8(path) {
  const copy = backup(path, "pre-migrate-v8");
  sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
${SCHEMA}
INSERT OR IGNORE INTO repository_task_aliases(local_task_id,forge,repository_id,task_id)
SELECT task_id,forge,repository_id,task_id FROM issue_mappings WHERE task_id GLOB 't[0-9]*';
UPDATE coordinator_meta SET value='8' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (8,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok" || rows(path, "PRAGMA foreign_key_check;").length) throw new Error("migration integrity verification failed");
}
function migrate(path, version) {
  if (version === 1) {
    migrateV1ToV2(path);
    migrateV2ToV3(path);
    migrateV3ToV4(path);
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 2) {
    migrateV2ToV3(path);
    migrateV3ToV4(path);
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 3) {
    migrateV3ToV4(path);
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 4) {
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 5) {
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 6) migrateV6ToV7(path);
  else if (version !== 7 && version !== SCHEMA_VERSION) throw new Error(`unsupported coordinator schema ${version}`);
  if (version < 8) migrateV7ToV8(path);
}
function bootstrap(path) {
  const origin = originId();
  const token = randomUUID();
  const timestamp = now();
  sqlite(path, `PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE; ${SCHEMA}
INSERT OR IGNORE INTO coordinator_meta VALUES ('schema_version','${SCHEMA_VERSION}');
INSERT OR IGNORE INTO coordinator_meta VALUES ('namespaced_emitted','0');
INSERT OR IGNORE INTO coordinator_meta VALUES ('publication_fence','0');
INSERT INTO origins SELECT ${sqlEscape(origin)},'active',0,1,${sqlEscape(token)},${sqlEscape(timestamp)} WHERE NOT EXISTS (SELECT 1 FROM origins);
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at)
SELECT origin_id,NULL,'active',ownership_epoch,fencing_token,'{}',${sqlEscape(timestamp)} FROM origins WHERE NOT EXISTS (SELECT 1 FROM origin_transitions);
INSERT INTO migration_history SELECT ${SCHEMA_VERSION},${sqlEscape(timestamp)},NULL,'ok' WHERE NOT EXISTS (SELECT 1 FROM migration_history); COMMIT;`);
}
function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    if (error.code === "EPERM") return true;
    throw error;
  }
}
function orphanedLockIsOldEnough(lock, orphanGrace) {
  try {
    return Date.now() - statSync(lock).mtimeMs >= orphanGrace;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}
function lockCanBeReclaimed(lock, orphanGrace) {
  try {
    const owner = JSON.parse(readFileSync(join(lock, "owner.json"), "utf8"));
    if (!owner || typeof owner.ownerToken !== "string" || !Number.isSafeInteger(Number(owner.pid)) || Number(owner.pid) < 1) throw new TypeError("malformed initialization lock owner");
    return !processIsAlive(Number(owner.pid));
  } catch (error) {
    if (error.code !== "ENOENT" && !(error instanceof SyntaxError) && !(error instanceof TypeError)) throw error;
    return orphanedLockIsOldEnough(lock, orphanGrace);
  }
}
function reclaimLock(lock) {
  const stale = `${lock}.stale-${randomUUID()}`;
  try {
    renameSync(lock, stale);
    rmSync(stale, { recursive: true, force: true });
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}
function acquireInitializationLock(lock, ownerToken) {
  const deadline = Date.now() + Number(process.env.AIDEVOPS_COORDINATOR_INIT_LOCK_TIMEOUT_MS || 30000);
  const orphanGrace = Number(process.env.AIDEVOPS_COORDINATOR_INIT_LOCK_ORPHAN_GRACE_MS || 1000);
  while (true) {
    try {
      mkdirSync(lock, { mode: 0o700 });
      writeFileSync(join(lock, "owner.json"), JSON.stringify({ ownerToken, pid: process.pid }), { mode: 0o600 });
      return;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (lockCanBeReclaimed(lock, orphanGrace)) reclaimLock(lock);
      if (Date.now() >= deadline) throw new Error("coordinator initialization lock timed out");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    }
  }
}
function releaseInitializationLock(lock, ownerToken) {
  try {
    const owner = JSON.parse(readFileSync(join(lock, "owner.json"), "utf8"));
    if (owner.ownerToken === ownerToken) rmSync(lock, { recursive: true, force: true });
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}
function bootstrapLocked(path) {
  const lock = `${path}.init-lock`;
  const ownerToken = randomUUID();
  acquireInitializationLock(lock, ownerToken);
  try {
    if (!existsSync(path)) bootstrap(path);
    secureFile(path);
    const version = Number(sqlite(path, "SELECT value FROM coordinator_meta WHERE key='schema_version';\n"));
    if (!Number.isSafeInteger(version) || version < 1 || version > SCHEMA_VERSION) throw new Error(`unsupported coordinator schema ${version}`);
    migrate(path, version);
    secureFile(path);
  } finally {
    releaseInitializationLock(lock, ownerToken);
  }
}
function initialise(path = dbPath()) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  bootstrapLocked(path);
  return path;
}
function activeOrigin(path) {
  const found = rows(path, "SELECT * FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1;")[0];
  if (!found) throw new Error("no active allocation origin");
  return found;
}
function operationResult(path, operationId, payloadHash) {
  const existing = rows(path, `SELECT payload_hash,result_json FROM operations WHERE operation_id=${sqlEscape(operationId)};`)[0];
  if (!existing) return null;
  if (existing.payload_hash !== payloadHash) throw new Error("operation_id payload conflict");
  if (!existing.result_json || existing.result_json === "{}" || existing.result_json === "null") {
    throw new Error("operation result is incomplete or failed integrity verification");
  }
  return JSON.parse(existing.result_json);
}
function maybeCrash(phase) {
  if (process.env.AIDEVOPS_TASK_COORDINATOR_TEST_CRASH === phase) process.kill(process.pid, "SIGKILL");
}
function allocate({ operationId = randomUUID(), payload = {}, count = 1, legacyId = "" } = {}, path = initialise()) {
  validId(operationId, "operation_id");
  if (!Number.isSafeInteger(count) || count < 1 || count > 1000) throw new TypeError("count must be 1..1000");
  if (legacyId && !LEGACY_ID.test(legacyId)) throw new TypeError("legacy_id is not canonical");
  const legacyStart = legacyId ? Number(legacyId.slice(1)) : 0;
  if (legacyStart && legacyStart + count - 1 > 999999999999999999) throw new TypeError("legacy allocation exceeds lexical limit");
  const payloadText = jsonText(payload, "payload");
  const payloadHash = hashText(payloadText);
  const prior = operationResult(path, operationId, payloadHash);
  if (prior) return prior;
  const timestamp = now();
  maybeCrash("before-commit");
  try {
    sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO operations(operation_id,kind,task_id,payload_hash,payload_json,status,result_json,created_at,updated_at)
VALUES (${sqlEscape(operationId)},'task.create',NULL,${sqlEscape(payloadHash)},${sqlEscape(payloadText)},'terminal','null',${sqlEscape(timestamp)},${sqlEscape(timestamp)});
UPDATE origins SET sequence=sequence+${count} WHERE origin_id=(SELECT origin_id FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1);
WITH RECURSIVE offsets(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM offsets WHERE n+1<${count})
INSERT INTO tasks(task_id,origin_id,sequence,parent_task_id,created_operation_id,payload_hash,payload_json,created_at)
SELECT CASE WHEN ${legacyStart}>0 THEN 't'||(${legacyStart}+n) ELSE 't'||o.origin_id||'-'||(o.sequence-${count}+1+n) END,
o.origin_id,o.sequence-${count}+1+n,NULL,${sqlEscape(operationId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},${sqlEscape(timestamp)}
FROM origins o,offsets WHERE o.state='active';
UPDATE operations SET task_id=(SELECT task_id FROM tasks WHERE created_operation_id=${sqlEscape(operationId)} ORDER BY sequence LIMIT 1),
result_json=(SELECT json_object('operationId',${sqlEscape(operationId)},'tasks',json_group_array(json_object('taskId',task_id,'originId',origin_id,'sequence',sequence))) FROM (SELECT * FROM tasks WHERE created_operation_id=${sqlEscape(operationId)} ORDER BY sequence))
WHERE operation_id=${sqlEscape(operationId)};
UPDATE coordinator_meta SET value='1' WHERE key='namespaced_emitted' AND ${legacyStart}=0;
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at) VALUES (${sqlEscape(operationId)},'terminal','{"allocation":"committed"}',${sqlEscape(timestamp)}); COMMIT;`);
  } catch (error) {
    const raced = operationResult(path, operationId, payloadHash);
    if (!raced) throw error;
    return raced;
  }
  maybeCrash("after-commit");
  return operationResult(path, operationId, payloadHash);
}
function durableAdoptionResult(path, operationId, payloadHash) {
  const result = operationResult(path, operationId, payloadHash);
  return result ? { ...result, ok: result.status !== "conflict" } : null;
}
function adoptLegacyTask(input = {}, path = initialise()) {
  const value = issueMappingInput({ ...input, role: "home" });
  const taskId = value.taskId;
  if (!LEGACY_TASK_ID.test(taskId)) throw new TypeError("task_id is not a canonical legacy identity");
  const identityText = jsonText({ displayNumber: value.displayNumber, forge: value.forge, issueId: value.issueId, repositoryId: value.repositoryId, role: value.role, taskId }, "legacy adoption identity");
  const operationId = input.operationId || `legacy-adopt-${createHash("sha256").update(identityText).digest("hex")}`;
  validId(operationId, "operation_id");
  const payloadText = identityText;
  const payloadHash = hashText(payloadText);
  const prior = durableAdoptionResult(path, operationId, payloadHash);
  if (prior) return prior;
  const timestamp = now();
  try {
    sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
CREATE TEMP TABLE adoption_identity(task_id TEXT NOT NULL);
INSERT INTO adoption_identity SELECT COALESCE(
  (SELECT task_id FROM repository_task_aliases WHERE local_task_id=${sqlEscape(taskId)} AND forge=${sqlEscape(value.forge)} AND repository_id=${sqlEscape(value.repositoryId)}),
  CASE WHEN EXISTS (SELECT 1 FROM legacy_task_adoptions WHERE task_id=${sqlEscape(taskId)} AND repository_id<>${sqlEscape(value.repositoryId)})
    OR EXISTS (SELECT 1 FROM issue_mappings WHERE task_id=${sqlEscape(taskId)} AND role='home' AND repository_id<>${sqlEscape(value.repositoryId)})
  THEN (SELECT 't'||origin_id||'-'||(sequence+1) FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1)
  ELSE ${sqlEscape(taskId)} END);
CREATE TEMP TABLE adoption_decision(status TEXT NOT NULL CHECK(status IN ('accepted','conflict')));
INSERT INTO adoption_decision SELECT CASE
  WHEN EXISTS (SELECT 1 FROM legacy_task_adoptions WHERE task_id=(SELECT task_id FROM adoption_identity) AND repository_id<>${sqlEscape(value.repositoryId)}) THEN 'conflict'
  WHEN EXISTS (SELECT 1 FROM issue_mappings WHERE task_id=(SELECT task_id FROM adoption_identity) AND role='home'
    AND (forge<>${sqlEscape(value.forge)} OR repository_id<>${sqlEscape(value.repositoryId)} OR issue_id<>${sqlEscape(value.issueId)} OR display_number<>${value.displayNumber})) THEN 'conflict'
  WHEN EXISTS (SELECT 1 FROM issue_mappings WHERE task_id=(SELECT task_id FROM adoption_identity) AND forge=${sqlEscape(value.forge)} AND repository_id=${sqlEscape(value.repositoryId)}
    AND (role<>'home' OR issue_id<>${sqlEscape(value.issueId)} OR display_number<>${value.displayNumber})) THEN 'conflict'
  WHEN EXISTS (SELECT 1 FROM issue_mappings WHERE forge=${sqlEscape(value.forge)} AND repository_id=${sqlEscape(value.repositoryId)}
    AND (issue_id=${sqlEscape(value.issueId)} OR display_number=${value.displayNumber}) AND task_id<>(SELECT task_id FROM adoption_identity)) THEN 'conflict'
  ELSE 'accepted' END;
INSERT INTO operations(operation_id,kind,task_id,payload_hash,payload_json,status,result_json,created_at,updated_at)
SELECT ${sqlEscape(operationId)},'task.adopt',(SELECT task_id FROM adoption_identity),${sqlEscape(payloadHash)},${sqlEscape(payloadText)},CASE WHEN status='accepted' THEN 'terminal' ELSE 'conflict' END,'null',${sqlEscape(timestamp)},${sqlEscape(timestamp)} FROM adoption_decision;
UPDATE origins SET sequence=sequence+1 WHERE origin_id=(SELECT origin_id FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1)
AND NOT EXISTS (SELECT 1 FROM tasks WHERE task_id=(SELECT task_id FROM adoption_identity)) AND (SELECT status FROM adoption_decision)='accepted';
INSERT INTO tasks(task_id,origin_id,sequence,parent_task_id,created_operation_id,payload_hash,payload_json,created_at)
SELECT (SELECT task_id FROM adoption_identity),origin_id,sequence,NULL,${sqlEscape(operationId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},${sqlEscape(timestamp)}
FROM origins WHERE state='active' AND NOT EXISTS (SELECT 1 FROM tasks WHERE task_id=(SELECT task_id FROM adoption_identity))
AND (SELECT status FROM adoption_decision)='accepted' ORDER BY created_at DESC LIMIT 1;
INSERT INTO legacy_task_adoptions(task_id,repository_id,adopted_operation_id,adopted_at)
SELECT (SELECT task_id FROM adoption_identity),${sqlEscape(value.repositoryId)},${sqlEscape(operationId)},${sqlEscape(timestamp)} FROM adoption_decision WHERE status='accepted' ON CONFLICT(task_id) DO NOTHING;
INSERT INTO issue_mappings(task_id,forge,repository_id,repository_slug,role,issue_id,project_id,display_number,state_cursor,sync_metadata_json,created_at,updated_at)
SELECT (SELECT task_id FROM adoption_identity),${sqlEscape(value.forge)},${sqlEscape(value.repositoryId)},${sqlEscape(value.repositorySlug)},'home',${sqlEscape(value.issueId)},${sqlEscape(value.projectId)},${value.displayNumber},${sqlEscape(value.stateCursor)},${sqlEscape(value.syncMetadataText)},${sqlEscape(timestamp)},${sqlEscape(timestamp)}
FROM adoption_decision WHERE status='accepted' ON CONFLICT(task_id,forge,repository_id) DO NOTHING;
INSERT INTO repository_task_aliases(local_task_id,forge,repository_id,task_id)
SELECT ${sqlEscape(taskId)},${sqlEscape(value.forge)},${sqlEscape(value.repositoryId)},(SELECT task_id FROM adoption_identity) FROM adoption_decision WHERE status='accepted'
ON CONFLICT(local_task_id,forge,repository_id) DO NOTHING;
UPDATE coordinator_meta SET value='1' WHERE key='namespaced_emitted' AND (SELECT task_id FROM adoption_identity) LIKE 'to%' AND (SELECT status FROM adoption_decision)='accepted';
UPDATE operations SET result_json=(SELECT json_object('adopted',status='accepted','operationId',${sqlEscape(operationId)},'repositoryId',${sqlEscape(value.repositoryId)},'status',status,'taskId',${sqlEscape(taskId)},'coordinatorTaskId',(SELECT task_id FROM adoption_identity)) FROM adoption_decision) WHERE operation_id=${sqlEscape(operationId)};
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at)
SELECT ${sqlEscape(operationId)},CASE WHEN status='accepted' THEN 'terminal' ELSE 'conflict' END,json_object('adoption',status,'issueId',${sqlEscape(value.issueId)},'repositoryId',${sqlEscape(value.repositoryId)}),${sqlEscape(timestamp)} FROM adoption_decision;
DROP TABLE adoption_decision; DROP TABLE adoption_identity; COMMIT;`);
  } catch (error) {
    const raced = durableAdoptionResult(path, operationId, payloadHash);
    if (!raced) throw new Error("legacy task adoption conflict", { cause: error });
    return raced;
  }
  return durableAdoptionResult(path, operationId, payloadHash);
}
function publicationTaskIdentity(taskId, repositoryId, path) {
  if (!LEGACY_TASK_ID.test(taskId)) return taskId;
  if (!repositoryId) throw new Error("legacy publication requires verified repository context");
  return resolveIssue({ taskId, repositoryId }, path).coordinatorTaskId;
}
function publication({ operationId, taskId, repositoryId, repositoryPath, remoteName = "origin", branchName = "main", coalesceKey = "planning", maxAttempts = 5, payload = {} }, path = initialise()) {
  validId(operationId, "operation_id");
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  if (repositoryId) validId(repositoryId, "repository_id");
  if (repositoryId && (typeof repositoryPath !== "string" || !repositoryPath.startsWith("/") || repositoryPath.includes("\0"))) throw new TypeError("repository_path must be absolute");
  if (repositoryId) validId(coalesceKey, "coalesce_key");
  if (repositoryId && (!/^[A-Za-z0-9._-]+$/.test(remoteName) || !/^[A-Za-z0-9._/-]+$/.test(branchName) || branchName.includes(".."))) throw new TypeError("invalid Git publication target");
  if (!Number.isSafeInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 20) throw new TypeError("max_attempts must be 1..20");
  const behavior = { branchName, coalesceKey, maxAttempts, payload, remoteName, repositoryId: repositoryId || null, repositoryPath: repositoryPath || null, taskId };
  const payloadText = jsonText(behavior, "publication behavior");
  const payloadHash = hashText(payloadText);
  const prior = operationResult(path, operationId, payloadHash);
  if (prior) return prior;
  taskId = publicationTaskIdentity(taskId, repositoryId, path);
  const intentId = randomUUID();
  const timestamp = now();
  const result = { intentId, operationId, status: "retryable", taskId };
  const resultText = JSON.stringify(result);
  const queueInsert = repositoryId ? `INSERT INTO publication_queue(intent_id,repository_id,repository_path,remote_name,branch_name,coalesce_key,sequence,available_at,max_attempts)
SELECT ${sqlEscape(intentId)},${sqlEscape(repositoryId)},${sqlEscape(repositoryPath)},${sqlEscape(remoteName)},${sqlEscape(branchName)},${sqlEscape(coalesceKey)},COALESCE(MAX(sequence),0)+1,unixepoch(),${maxAttempts} FROM publication_queue;` : "";
  try {
    sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO operations VALUES (${sqlEscape(operationId)},'publication.intent',${sqlEscape(taskId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},'retryable',${sqlEscape(resultText)},${sqlEscape(timestamp)},${sqlEscape(timestamp)});
INSERT INTO publication_intents VALUES (${sqlEscape(intentId)},${sqlEscape(operationId)},${sqlEscape(taskId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},'retryable',${sqlEscape(timestamp)});
${queueInsert} COMMIT;`);
  } catch (error) {
    const raced = operationResult(path, operationId, payloadHash);
    if (!raced) throw error;
    return raced;
  }
  return result;
}
function leaseNext({ ownerId, leaseSeconds = 60, maxActive = 4 }, path = initialise()) {
  validId(ownerId, "owner_id");
  if (!Number.isSafeInteger(leaseSeconds) || leaseSeconds < 5 || leaseSeconds > 3600) throw new TypeError("lease_seconds must be 5..3600");
  if (!Number.isSafeInteger(maxActive) || maxActive < 1 || maxActive > 32) throw new TypeError("max_active must be 1..32");
  const clock = Math.floor(Date.now() / 1000);
  const expires = clock + leaseSeconds;
  sqlite(path, `BEGIN IMMEDIATE;
DELETE FROM publication_leases WHERE expires_at<=${clock};
CREATE TEMP TABLE lease_candidate(repository_id TEXT PRIMARY KEY);
INSERT INTO lease_candidate SELECT q.repository_id FROM publication_queue q JOIN publication_intents i USING(intent_id)
WHERE i.status='retryable' AND q.available_at<=${clock}
AND q.sequence=(SELECT MIN(qh.sequence) FROM publication_queue qh JOIN publication_intents ih USING(intent_id) WHERE qh.repository_id=q.repository_id AND ih.status='retryable')
AND NOT EXISTS (SELECT 1 FROM publication_leases l WHERE l.repository_id=q.repository_id)
AND (SELECT COUNT(*) FROM publication_leases)<${maxActive} ORDER BY q.sequence LIMIT 1;
UPDATE coordinator_meta SET value=CAST(value AS INTEGER)+1 WHERE key='publication_fence' AND EXISTS (SELECT 1 FROM lease_candidate);
INSERT INTO publication_leases(repository_id,fencing_token,owner_id,expires_at,acquired_at)
SELECT repository_id,(SELECT CAST(value AS INTEGER) FROM coordinator_meta WHERE key='publication_fence'),${sqlEscape(ownerId)},${expires},${clock} FROM lease_candidate;
DROP TABLE lease_candidate; COMMIT;`);
  const lease = rows(path, `SELECT repository_id AS repositoryId,fencing_token AS fencingToken,owner_id AS ownerId,expires_at AS expiresAt FROM publication_leases WHERE owner_id=${sqlEscape(ownerId)} ORDER BY acquired_at DESC LIMIT 1;`)[0];
  if (!lease) return { batch: [], leased: false };
  const first = rows(path, `SELECT q.coalesce_key,q.repository_path,q.remote_name,q.branch_name FROM publication_queue q JOIN publication_intents i USING(intent_id) WHERE q.repository_id=${sqlEscape(lease.repositoryId)} AND i.status='retryable' AND q.available_at<=${clock} ORDER BY q.sequence LIMIT 1;`)[0];
  if (!first) return { batch: [], leased: false };
  sqlite(path, `BEGIN IMMEDIATE; UPDATE publication_queue SET lease_token=${lease.fencingToken},attempt_count=attempt_count+1 WHERE intent_id IN (
SELECT q.intent_id FROM publication_queue q JOIN publication_intents i USING(intent_id) WHERE q.repository_id=${sqlEscape(lease.repositoryId)} AND q.coalesce_key=${sqlEscape(first.coalesce_key)} AND q.repository_path=${sqlEscape(first.repository_path)} AND q.remote_name=${sqlEscape(first.remote_name)} AND q.branch_name=${sqlEscape(first.branch_name)} AND i.status='retryable' AND q.available_at<=${clock} AND q.sequence<COALESCE((SELECT MIN(q2.sequence) FROM publication_queue q2 JOIN publication_intents i2 USING(intent_id) WHERE q2.repository_id=q.repository_id AND i2.status='retryable' AND q2.available_at<=${clock} AND (q2.coalesce_key<>q.coalesce_key OR q2.repository_path<>q.repository_path OR q2.remote_name<>q.remote_name OR q2.branch_name<>q.branch_name)),9223372036854775807)); COMMIT;`);
  const batch = rows(path, `SELECT q.intent_id AS intentId,q.sequence,q.repository_path AS repositoryPath,q.remote_name AS remoteName,q.branch_name AS branchName,q.attempt_count AS attemptCount,q.max_attempts AS maxAttempts,i.payload_json AS payloadJson FROM publication_queue q JOIN publication_intents i USING(intent_id) WHERE q.repository_id=${sqlEscape(lease.repositoryId)} AND q.lease_token=${lease.fencingToken} ORDER BY q.sequence;`).map((row) => { const behavior = JSON.parse(row.payloadJson); return { ...row, payload: behavior.payload ?? behavior }; });
  return { ...lease, batch, leased: batch.length > 0 };
}
function checkLease({ ownerId, repositoryId, fencingToken }, path = initialise()) {
  validId(ownerId, "owner_id"); validId(repositoryId, "repository_id");
  const token = Number(fencingToken);
  const owned = Number(sqlite(path, `SELECT COUNT(*) FROM publication_leases WHERE repository_id=${sqlEscape(repositoryId)} AND owner_id=${sqlEscape(ownerId)} AND fencing_token=${token} AND expires_at>unixepoch();`));
  if (owned !== 1) throw new Error("stale publication fencing token");
  return { fencingToken: token, owned: true, repositoryId };
}
function renewLease({ ownerId, repositoryId, fencingToken, leaseSeconds = 60 }, path = initialise()) {
  validId(ownerId, "owner_id"); validId(repositoryId, "repository_id");
  const clock = Math.floor(Date.now() / 1000);
  const expires = clock + Number(leaseSeconds);
  sqlite(path, `BEGIN IMMEDIATE; UPDATE publication_leases SET expires_at=${expires} WHERE repository_id=${sqlEscape(repositoryId)} AND owner_id=${sqlEscape(ownerId)} AND fencing_token=${Number(fencingToken)} AND expires_at>${clock}; CREATE TEMP TABLE assert_renew(value INTEGER CHECK(value=1)); INSERT INTO assert_renew VALUES(changes()); DROP TABLE assert_renew; COMMIT;`);
  return { expiresAt: expires, fencingToken: Number(fencingToken), repositoryId };
}
function finishLease({ ownerId, repositoryId, fencingToken, status, evidence = {}, retryAfter = 0 }, path = initialise()) {
  validId(ownerId, "owner_id"); validId(repositoryId, "repository_id");
  if (!["published", "retryable", "terminal"].includes(status)) throw new TypeError("invalid worker result state");
  const evidenceText = jsonText(evidence, "evidence", EVIDENCE_MAX_BYTES);
  const token = Number(fencingToken);
  if (status === "published" && (typeof evidence.commitSha !== "string" || !/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/.test(evidence.commitSha))) throw new TypeError("published evidence requires the exact commit SHA");
  const durableEvidence = jsonText({ ...evidence, fencingToken: token, ownerId }, "evidence", EVIDENCE_MAX_BYTES);
  const timestamp = now();
  const clock = Math.floor(Date.now() / 1000);
  const retryAt = clock + Math.max(1, Number(retryAfter));
  const count = Number(sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
CREATE TEMP TABLE assert_owner(value INTEGER CHECK(value=1));
INSERT INTO assert_owner SELECT COUNT(*) FROM publication_leases WHERE repository_id=${sqlEscape(repositoryId)} AND owner_id=${sqlEscape(ownerId)} AND fencing_token=${token} AND expires_at>${clock};
CREATE TEMP TABLE finishing AS SELECT q.intent_id,q.attempt_count,q.max_attempts,i.operation_id,i.task_id,
CASE WHEN ${sqlEscape(status)}='retryable' AND q.attempt_count>=q.max_attempts THEN 'terminal' ELSE ${sqlEscape(status)} END final_status
FROM publication_queue q JOIN publication_intents i USING(intent_id) WHERE q.repository_id=${sqlEscape(repositoryId)} AND q.lease_token=${token};
CREATE TEMP TABLE assert_batch(value INTEGER CHECK(value>0)); INSERT INTO assert_batch SELECT COUNT(*) FROM finishing;
INSERT INTO publication_attempts(intent_id,attempt_number,status,evidence_json,occurred_at)
SELECT f.intent_id,COALESCE((SELECT MAX(pa.attempt_number) FROM publication_attempts pa WHERE pa.intent_id=f.intent_id),0)+1,f.final_status,${sqlEscape(durableEvidence)},${sqlEscape(timestamp)} FROM finishing f;
UPDATE publication_intents SET status=(SELECT final_status FROM finishing f WHERE f.intent_id=publication_intents.intent_id) WHERE intent_id IN (SELECT intent_id FROM finishing);
UPDATE operations SET status=(SELECT final_status FROM finishing f WHERE f.operation_id=operations.operation_id),updated_at=${sqlEscape(timestamp)},
result_json=(SELECT json_object('intentId',f.intent_id,'operationId',f.operation_id,'status',f.final_status,'taskId',f.task_id,'evidence',json(${sqlEscape(durableEvidence)})) FROM finishing f WHERE f.operation_id=operations.operation_id)
WHERE operation_id IN (SELECT operation_id FROM finishing);
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at)
SELECT operation_id,final_status,${sqlEscape(durableEvidence)},${sqlEscape(timestamp)} FROM finishing WHERE final_status IN ('published','terminal','conflict');
UPDATE publication_queue SET available_at=${retryAt},lease_token=NULL WHERE intent_id IN (SELECT intent_id FROM finishing WHERE final_status='retryable');
DELETE FROM publication_leases WHERE repository_id=${sqlEscape(repositoryId)} AND owner_id=${sqlEscape(ownerId)} AND fencing_token=${token};
SELECT COUNT(*) FROM finishing; COMMIT;`));
  return { count, repositoryId, status };
}
function publicationMetrics(path = initialise()) {
  const states = rows(path, "SELECT i.status,COUNT(*) AS count FROM publication_intents i GROUP BY i.status;");
  return { activeLeases: Number(sqlite(path, "SELECT COUNT(*) FROM publication_leases WHERE expires_at>unixepoch();")), queueDepth: Number(sqlite(path, "SELECT COUNT(*) FROM publication_queue q JOIN publication_intents i USING(intent_id) WHERE i.status='retryable';")), states };
}
function attempt({ intentId, status, evidence = {} }, path = initialise()) {
  validId(intentId, "intent_id");
  if (!RESULTS.has(status)) throw new TypeError("invalid durable result state");
  const evidenceText = jsonText(evidence, "evidence", EVIDENCE_MAX_BYTES);
  const timestamp = now();
  sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO publication_attempts(intent_id,attempt_number,status,evidence_json,occurred_at)
SELECT ${sqlEscape(intentId)},COALESCE(MAX(attempt_number),0)+1,${sqlEscape(status)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)} FROM publication_attempts WHERE intent_id=${sqlEscape(intentId)} HAVING EXISTS (SELECT 1 FROM publication_intents WHERE intent_id=${sqlEscape(intentId)});
CREATE TEMP TABLE assert_change(value INTEGER CHECK(value=1)); INSERT INTO assert_change VALUES(changes()); DROP TABLE assert_change;
UPDATE publication_intents SET status=${sqlEscape(status)} WHERE intent_id=${sqlEscape(intentId)};
UPDATE operations SET status=${sqlEscape(status)},updated_at=${sqlEscape(timestamp)},
result_json=json_object('intentId',${sqlEscape(intentId)},'operationId',operation_id,'status',${sqlEscape(status)},'taskId',task_id,'evidence',json(${sqlEscape(evidenceText)}))
WHERE operation_id=(SELECT operation_id FROM publication_intents WHERE intent_id=${sqlEscape(intentId)});
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at)
SELECT operation_id,${sqlEscape(status)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)} FROM publication_intents WHERE intent_id=${sqlEscape(intentId)} AND ${sqlEscape(status)} IN ('published','terminal','conflict'); COMMIT;`);
  return { intentId, status };
}
function transition({ state, evidence = {}, fencingToken }, path = initialise()) {
  if (!STATES.has(state)) throw new TypeError("invalid origin state");
  validId(fencingToken, "fencing_token");
  const evidenceText = jsonText(evidence, "evidence", EVIDENCE_MAX_BYTES);
  const origin = activeOrigin(path);
  if (fencingToken !== origin.fencing_token) throw new Error("stale fencing token");
  const timestamp = now();
  sqlite(path, `BEGIN IMMEDIATE; UPDATE origins SET state=${sqlEscape(state)} WHERE origin_id=${sqlEscape(origin.origin_id)} AND fencing_token=${sqlEscape(fencingToken)} AND state='active';
CREATE TEMP TABLE assert_change(value INTEGER CHECK(value=1)); INSERT INTO assert_change VALUES(changes()); DROP TABLE assert_change;
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at) VALUES (${sqlEscape(origin.origin_id)},${sqlEscape(origin.state)},${sqlEscape(state)},${origin.ownership_epoch},${sqlEscape(fencingToken)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)}); COMMIT;`);
  return { originId: origin.origin_id, state };
}
function issueMappingInput(input) {
  const taskId = input.taskId;
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  const forge = input.forge || "github";
  if (forge !== "github") throw new TypeError("unsupported forge");
  const repositoryId = validId(input.repositoryId, "repository_id");
  const repositorySlug = input.repositorySlug;
  if (typeof repositorySlug !== "string" || !/^[^/\s]+\/[^/\s]+$/.test(repositorySlug)) throw new TypeError("repository_slug is not canonical");
  const role = input.role || "home";
  if (!MAPPING_ROLES.has(role)) throw new TypeError("invalid issue mapping role");
  const issueId = validId(input.issueId, "issue_id");
  const projectId = input.projectId ? validId(input.projectId, "project_id") : null;
  const displayNumber = Number(input.displayNumber);
  if (!Number.isSafeInteger(displayNumber) || displayNumber < 1) throw new TypeError("display_number must be a positive integer");
  const rawStateCursor = input.stateCursor || null;
  const stateCursor = rawStateCursor ? canonicalRfc3339(rawStateCursor, "state_cursor") : null;
  const syncMetadataText = jsonText(input.syncMetadata || {}, "sync_metadata");
  return { taskId, forge, repositoryId, repositorySlug, role, issueId, projectId, displayNumber, stateCursor, syncMetadataText };
}
function bindIssue(input, path = initialise()) {
  const value = issueMappingInput(input);
  if (LEGACY_TASK_ID.test(value.taskId) && value.role === "home") {
    const adopted = adoptLegacyTask(input, path);
    if (!adopted.ok) throw new Error("legacy home mapping conflict");
    value.taskId = adopted.coordinatorTaskId || adopted.taskId;
  } else if (LEGACY_TASK_ID.test(value.taskId)) {
    const identities = rows(path, `SELECT DISTINCT task_id FROM repository_task_aliases WHERE local_task_id=${sqlEscape(value.taskId)};`);
    if (identities.some((identity) => identity.task_id !== value.taskId)) throw new Error("ambiguous legacy non-home mapping; use an internal task identity");
  }
  const timestamp = now();
  try {
    sqlite(path, `BEGIN IMMEDIATE;
CREATE TEMP TABLE assert_home_repository(value INTEGER CHECK(value=1));
INSERT INTO assert_home_repository SELECT CASE WHEN ${sqlEscape(value.role)}<>'home' THEN 1
  WHEN EXISTS (SELECT 1 FROM legacy_task_adoptions WHERE task_id=${sqlEscape(value.taskId)} AND repository_id<>${sqlEscape(value.repositoryId)}) THEN 0
  WHEN EXISTS (SELECT 1 FROM issue_mappings WHERE task_id=${sqlEscape(value.taskId)} AND role='home' AND repository_id<>${sqlEscape(value.repositoryId)}) THEN 0
  ELSE 1 END;
DROP TABLE assert_home_repository;
INSERT INTO issue_mappings(task_id,forge,repository_id,repository_slug,role,issue_id,project_id,display_number,state_cursor,sync_metadata_json,created_at,updated_at)
VALUES (${sqlEscape(value.taskId)},${sqlEscape(value.forge)},${sqlEscape(value.repositoryId)},${sqlEscape(value.repositorySlug)},${sqlEscape(value.role)},${sqlEscape(value.issueId)},${sqlEscape(value.projectId)},${value.displayNumber},${sqlEscape(value.stateCursor)},${sqlEscape(value.syncMetadataText)},${sqlEscape(timestamp)},${sqlEscape(timestamp)})
ON CONFLICT(task_id,forge,repository_id) DO UPDATE SET repository_slug=excluded.repository_slug,project_id=COALESCE(excluded.project_id,issue_mappings.project_id),state_cursor=COALESCE(excluded.state_cursor,issue_mappings.state_cursor),sync_metadata_json=CASE WHEN excluded.state_cursor>issue_mappings.state_cursor OR issue_mappings.state_cursor IS NULL THEN excluded.sync_metadata_json ELSE issue_mappings.sync_metadata_json END,updated_at=excluded.updated_at
WHERE issue_mappings.issue_id=excluded.issue_id AND issue_mappings.display_number=excluded.display_number AND issue_mappings.role=excluded.role
AND ((issue_mappings.state_cursor IS NULL AND excluded.state_cursor IS NULL AND issue_mappings.sync_metadata_json=excluded.sync_metadata_json)
  OR excluded.state_cursor>issue_mappings.state_cursor
  OR (excluded.state_cursor=issue_mappings.state_cursor AND issue_mappings.sync_metadata_json=excluded.sync_metadata_json));
CREATE TEMP TABLE assert_mapping_change(value INTEGER CHECK(value=1)); INSERT INTO assert_mapping_change VALUES(changes()); DROP TABLE assert_mapping_change;
COMMIT;`);
  } catch (error) {
    throw new Error("issue mapping conflict or stale state cursor", { cause: error });
  }
  return resolveIssue({ taskId: value.taskId, forge: value.forge, repositoryId: value.repositoryId }, path);
}
function resolveIssue({ taskId, forge = "github", repositoryId }, path = initialise()) {
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  validId(repositoryId, "repository_id");
  const matches = rows(path, `SELECT COALESCE(a.local_task_id,m.task_id) AS taskId,m.task_id AS coordinatorTaskId,m.forge,m.repository_id AS repositoryId,m.repository_slug AS repositorySlug,m.role,m.issue_id AS issueId,m.project_id AS projectId,m.display_number AS displayNumber,m.state_cursor AS stateCursor,m.sync_metadata_json AS syncMetadataJson FROM issue_mappings m LEFT JOIN repository_task_aliases a USING(task_id,forge,repository_id) WHERE (m.task_id=${sqlEscape(taskId)} OR a.local_task_id=${sqlEscape(taskId)}) AND m.forge=${sqlEscape(forge)} AND m.repository_id=${sqlEscape(repositoryId)};`);
  if (matches.length !== 1) throw new Error("issue mapping not found");
  return { ...matches[0], syncMetadata: JSON.parse(matches[0].syncMetadataJson) };
}
function reconciliationTargets({ repositoryId, limit = 100 }, path = initialise()) {
  validId(repositoryId, "repository_id");
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) throw new TypeError("limit must be 1..500");
  const targets = rows(path, `SELECT COALESCE(a.local_task_id,m.task_id) AS taskId,m.task_id AS coordinatorTaskId,m.issue_id AS subjectId,m.display_number AS displayNumber,m.state_cursor AS stateCursor FROM issue_mappings m JOIN tasks t ON t.task_id=m.task_id LEFT JOIN repository_task_aliases a USING(task_id,forge,repository_id) WHERE m.forge='github' AND m.repository_id=${sqlEscape(repositoryId)} ORDER BY COALESCE(m.state_cursor,'') ASC,m.display_number ASC LIMIT ${limit};`);
  return { bounded: true, repositoryId, targets };
}
function forgeEventInput(input) {
  const operationId = validId(input.operationId, "operation_id");
  const repositoryId = validId(input.repositoryId, "repository_id");
  const repositorySlug = input.repositorySlug;
  if (typeof repositorySlug !== "string" || !/^[^/\s]+\/[^/\s]+$/.test(repositorySlug)) throw new TypeError("repository_slug is not canonical");
  const eventKind = input.eventKind;
  const action = input.action;
  if (!FORGE_EVENT_KINDS.has(eventKind)) throw new TypeError("unsupported forge event kind");
  if (!FORGE_EVENT_ACTIONS.has(action)) throw new TypeError("unsupported forge event action");
  const subjectId = validId(input.subjectId, "subject_id");
  const deliveryId = validId(input.deliveryId, "delivery_id");
  const cursorTiebreaker = validId(input.cursorTiebreaker, "cursor_tiebreaker");
  const cursor = canonicalRfc3339(input.cursor, "cursor");
  const repositoryPath = input.repositoryPath;
  if (repositoryPath && (typeof repositoryPath !== "string" || !repositoryPath.startsWith("/") || repositoryPath.includes("\0"))) throw new TypeError("repository_path must be absolute");
  const taskId = input.taskId || null;
  if (taskId && !TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  if (eventKind === "manual" && !taskId) throw new TypeError("manual events require an explicit trusted task mapping");
  return { operationId, repositoryId, repositorySlug, eventKind, action, subjectId, deliveryId, cursorTiebreaker, repositoryPath, taskId, cursor };
}
function transitionForEvent(eventKind, action) {
  if (eventKind === "push") return "repository.projection_changed";
  if (eventKind === "manual") return "task.reconcile_requested";
  const transitions = {
    assigned: "task.claimed",
    closed: "task.completed",
    edited: "task.metadata_changed",
    merged: "task.completed",
    opened: "task.available",
    reopened: "task.available",
  };
  return transitions[action] || "task.metadata_changed";
}
function forgeEventMapping(path, value) {
  if (value.eventKind === "push") return null;
  const selector = value.taskId ? `(m.task_id=${sqlEscape(value.taskId)} OR a.local_task_id=${sqlEscape(value.taskId)})` : `m.issue_id=${sqlEscape(value.subjectId)}`;
  const matches = rows(path, `SELECT m.task_id AS taskId,COALESCE(a.local_task_id,m.task_id) AS localTaskId FROM issue_mappings m JOIN tasks t ON t.task_id=m.task_id LEFT JOIN repository_task_aliases a USING(task_id,forge,repository_id) WHERE m.forge='github' AND m.repository_id=${sqlEscape(value.repositoryId)} AND ${selector};`);
  if (matches.length > 1) throw new Error("ambiguous event task mapping");
  return matches[0];
}
function forgeEventCursor(path, value) {
  return rows(path, `SELECT cursor_timestamp AS cursorTimestamp,cursor_tiebreaker AS cursorTiebreaker,payload_hash AS payloadHash FROM forge_event_cursors WHERE forge='github' AND repository_id=${sqlEscape(value.repositoryId)} AND subject_kind=${sqlEscape(value.eventKind)} AND subject_id=${sqlEscape(value.subjectId)};`)[0];
}
function prepareForgeEvent(value, path, transitionKind, payloadText, payloadHash) {
  const mapping = forgeEventMapping(path, value);
  const priorCursor = forgeEventCursor(path, value);
  const timestamp = now();
  const ordering = priorCursor ? value.cursor.localeCompare(priorCursor.cursorTimestamp) || value.cursorTiebreaker.localeCompare(priorCursor.cursorTiebreaker) : 1;
  const stale = ordering < 0 || (ordering === 0 && priorCursor?.payloadHash === payloadHash);
  const conflict = ordering === 0 && priorCursor?.payloadHash !== payloadHash;
  const repositoryOnly = value.eventKind === "push";
  const status = conflict ? "conflict" : stale ? "stale" : (!mapping && !repositoryOnly) ? "unmapped" : "accepted";
  const shouldPublish = status === "accepted" && Boolean(mapping && value.repositoryPath);
  const intentId = shouldPublish ? randomUUID() : null;
  const result = { action: value.action, deliveryId: value.deliveryId, eventKind: value.eventKind, mappingMode: repositoryOnly ? "trusted-repository" : value.taskId ? "explicit-task" : "immutable-subject", operationId: value.operationId, repositoryId: value.repositoryId, status, taskId: mapping?.taskId || null, transitionKind };
  const resultText = JSON.stringify(result);
  const projection = shouldPublish ? jsonText({ branchName: "main", coalesceKey: "forge-event", maxAttempts: 5, payload: { paths: ["TODO.md"], projection: "forge-event", transition: { kind: transitionKind, taskId: mapping.localTaskId } }, remoteName: "origin", repositoryId: value.repositoryId, repositoryPath: value.repositoryPath, taskId: mapping.taskId }, "projection") : null;
  return { conflict, intentId, mapping, payloadHash, payloadText, projection, result, resultText, shouldPublish, status, timestamp, transitionKind, value };
}
function forgeEventTransactionSql(event) {
  const { conflict, intentId, mapping, payloadHash, payloadText, projection, resultText, shouldPublish, status, timestamp, transitionKind, value } = event;
  const cursorSql = status === "accepted" ? `INSERT INTO forge_event_cursors(forge,repository_id,subject_kind,subject_id,cursor_timestamp,cursor_tiebreaker,payload_hash,operation_id,transition_kind,accepted_at)
VALUES ('github',${sqlEscape(value.repositoryId)},${sqlEscape(value.eventKind)},${sqlEscape(value.subjectId)},${sqlEscape(value.cursor)},${sqlEscape(value.cursorTiebreaker)},${sqlEscape(payloadHash)},${sqlEscape(value.operationId)},${sqlEscape(transitionKind)},${sqlEscape(timestamp)})
ON CONFLICT(forge,repository_id,subject_kind,subject_id) DO UPDATE SET cursor_timestamp=excluded.cursor_timestamp,cursor_tiebreaker=excluded.cursor_tiebreaker,payload_hash=excluded.payload_hash,operation_id=excluded.operation_id,transition_kind=excluded.transition_kind,accepted_at=excluded.accepted_at;` : "";
  const publicationSql = shouldPublish ? `INSERT INTO publication_intents(intent_id,operation_id,task_id,payload_hash,payload_json,status,created_at) VALUES (${sqlEscape(intentId)},${sqlEscape(value.operationId)},${sqlEscape(mapping.taskId)},${sqlEscape(hashText(projection))},${sqlEscape(projection)},'retryable',${sqlEscape(timestamp)});
INSERT INTO publication_queue(intent_id,repository_id,repository_path,remote_name,branch_name,coalesce_key,sequence,available_at,max_attempts) SELECT ${sqlEscape(intentId)},${sqlEscape(value.repositoryId)},${sqlEscape(value.repositoryPath)},'origin','main','forge-event',COALESCE(MAX(sequence),0)+1,unixepoch(),5 FROM publication_queue;` : "";
  const terminalState = conflict ? "conflict" : "terminal";
  return `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO operations(operation_id,kind,task_id,payload_hash,payload_json,status,result_json,created_at,updated_at)
VALUES (${sqlEscape(value.operationId)},'forge.event',${sqlEscape(mapping?.taskId || null)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},${sqlEscape(terminalState)},${sqlEscape(resultText)},${sqlEscape(timestamp)},${sqlEscape(timestamp)});
${cursorSql}
${publicationSql}
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at) VALUES (${sqlEscape(value.operationId)},${sqlEscape(terminalState)},${sqlEscape(JSON.stringify({ status, transitionKind }))},${sqlEscape(timestamp)}); COMMIT;`;
}
function forgeEvent(input, path = initialise()) {
  const value = forgeEventInput(input);
  const transitionKind = transitionForEvent(value.eventKind, value.action);
  const payloadText = jsonText({ action: value.action, cursor: value.cursor, cursorTiebreaker: value.cursorTiebreaker, deliveryId: value.deliveryId, eventKind: value.eventKind, repositoryId: value.repositoryId, subjectId: value.subjectId, taskId: value.taskId, transitionKind }, "forge event");
  const payloadHash = hashText(payloadText);
  const prior = operationResult(path, value.operationId, payloadHash);
  if (prior) return prior;
  const event = prepareForgeEvent(value, path, transitionKind, payloadText, payloadHash);
  try {
    sqlite(path, forgeEventTransactionSql(event));
  } catch (error) {
    const raced = operationResult(path, value.operationId, payloadHash);
    if (!raced) throw error;
    return raced;
  }
  return event.result;
}
function validateRestoreEvidence(evidence, fencingToken) {
  const text = jsonText(evidence, "registry_evidence", EVIDENCE_MAX_BYTES);
  if (evidence.cas !== "winner" || evidence.prior_revoked !== true || evidence.fencing_token !== fencingToken || !validId(evidence.transfer_record_id, "transfer_record_id")) {
    throw new TypeError("registry evidence must prove CAS winner, prior revocation, transfer record, and returned fencing token");
  }
  return text;
}
function restore({ backupPath, registryEvidence, priorEpoch, newEpoch, fencingToken, publishedHighWater = 0 }, target = dbPath()) {
  validId(fencingToken, "fencing_token");
  if (!Number.isSafeInteger(priorEpoch) || priorEpoch < 1 || !Number.isSafeInteger(newEpoch) || newEpoch !== priorEpoch + 1) throw new TypeError("restore epoch must advance exactly once");
  if (!Number.isSafeInteger(publishedHighWater) || publishedHighWater < 0) throw new TypeError("published high-water must be a non-negative integer");
  const evidenceText = validateRestoreEvidence(registryEvidence, fencingToken);
  const canonicalBackup = canonicalizeSqliteDbPath(backupPath);
  if (!existsSync(canonicalBackup) || sqlite(canonicalBackup, "PRAGMA integrity_check;\n") !== "ok") throw new Error("restore backup failed integrity verification");
  const backupVersion = Number(sqlite(canonicalBackup, "SELECT value FROM coordinator_meta WHERE key='schema_version';\n"));
  if (backupVersion !== SCHEMA_VERSION) throw new Error("restore backup schema is not current");
  const restoredOrigin = rows(canonicalBackup, "SELECT * FROM origins ORDER BY created_at DESC LIMIT 1;")[0];
  if (!restoredOrigin || Number(restoredOrigin.ownership_epoch) !== priorEpoch) throw new Error("restore ownership epoch mismatch");
  const localHighWater = Number(sqlite(canonicalBackup, `SELECT MAX(v) FROM (SELECT sequence v FROM origins WHERE origin_id=${sqlEscape(restoredOrigin.origin_id)} UNION ALL SELECT COALESCE(MAX(sequence),0) FROM tasks WHERE origin_id=${sqlEscape(restoredOrigin.origin_id)});`));
  const highWater = Math.max(localHighWater, publishedHighWater);
  if (existsSync(target)) backup(target, "pre-restore");
  const staged = `${target}.restore-${process.pid}`;
  rmSync(staged, { force: true });
  sqlite(canonicalBackup, `.backup ${sqlEscape(staged)}\n`);
  secureFile(staged);
  const timestamp = now();
  sqlite(staged, `BEGIN IMMEDIATE; UPDATE origins SET state='active',sequence=${highWater},ownership_epoch=${newEpoch},fencing_token=${sqlEscape(fencingToken)} WHERE origin_id=${sqlEscape(restoredOrigin.origin_id)} AND ownership_epoch=${priorEpoch};
CREATE TEMP TABLE assert_change(value INTEGER CHECK(value=1)); INSERT INTO assert_change VALUES(changes()); DROP TABLE assert_change;
INSERT INTO restore_controls(origin_id,prior_epoch,new_epoch,fencing_token,registry_evidence_json,backup_integrity,backup_high_water,published_high_water,restored_at) VALUES (${sqlEscape(restoredOrigin.origin_id)},${priorEpoch},${newEpoch},${sqlEscape(fencingToken)},${sqlEscape(evidenceText)},'ok',${localHighWater},${publishedHighWater},${sqlEscape(timestamp)});
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at) VALUES (${sqlEscape(restoredOrigin.origin_id)},${sqlEscape(restoredOrigin.state)},'active',${newEpoch},${sqlEscape(fencingToken)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)}); COMMIT;`);
  if (sqlite(staged, "PRAGMA integrity_check;\n") !== "ok") throw new Error("staged restore failed integrity verification");
  sqlite(target, `.restore ${sqlEscape(staged)}\n`);
  rmSync(staged, { force: true });
  secureFile(target);
  return { originId: restoredOrigin.origin_id, sequence: highWater, ownershipEpoch: newEpoch };
}
function verify(path = initialise()) {
  const quickCheck = sqlite(path, "PRAGMA quick_check;\n");
  const foreignKeys = rows(path, "PRAGMA foreign_key_check;");
  const duplicateTasks = Number(sqlite(path, "SELECT COUNT(*) FROM (SELECT origin_id,sequence FROM tasks GROUP BY origin_id,sequence HAVING COUNT(*)>1);\n"));
  const incompleteOperations = Number(sqlite(path, "SELECT COUNT(*) FROM operations WHERE result_json IN ('{}','null');\n"));
  const result = { duplicateTasks, foreignKeyErrors: foreignKeys.length, incompleteOperations, quickCheck, schemaVersion: SCHEMA_VERSION };
  return { ...result, ok: quickCheck === "ok" && foreignKeys.length === 0 && duplicateTasks === 0 && incompleteOperations === 0 };
}
function checkpoint(path = initialise()) {
  const result = process.env.AIDEVOPS_TASK_COORDINATOR_TEST_CHECKPOINT_RESULT || sqlite(path, "PRAGMA wal_checkpoint(TRUNCATE);\n");
  const checkpointed = result === "0|0|0" || result === "0|0|0\n";
  return { checkpointed, result, ok: checkpointed };
}

function parseJson(value = "{}") { return JSON.parse(value); }
function option(args, name, fallback = "") { const index = args.indexOf(name); return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback; }
const COMMAND_HANDLERS = {
  allocate: (args, path) => allocate({ operationId: option(args, "--operation-id") || randomUUID(), count: Number(option(args, "--count", "1")), legacyId: option(args, "--legacy-id"), payload: parseJson(option(args, "--payload", "{}")) }, path),
  "adopt-legacy-task": (args, path) => adoptLegacyTask({ operationId: option(args, "--operation-id"), taskId: option(args, "--task-id"), forge: option(args, "--forge", "github"), repositoryId: option(args, "--repository-id"), repositorySlug: option(args, "--repository-slug"), issueId: option(args, "--issue-id"), projectId: option(args, "--project-id"), displayNumber: option(args, "--display-number"), stateCursor: option(args, "--state-cursor"), syncMetadata: parseJson(option(args, "--sync-metadata", "{}")) }, path),
  "publication-intent": (args, path) => publication({ operationId: option(args, "--operation-id"), taskId: option(args, "--task-id"), repositoryId: option(args, "--repository-id"), repositoryPath: option(args, "--repository-path"), remoteName: option(args, "--remote", "origin"), branchName: option(args, "--branch", "main"), coalesceKey: option(args, "--coalesce-key", "planning"), maxAttempts: Number(option(args, "--max-attempts", "5")), payload: parseJson(option(args, "--payload", "{}")) }, path),
  "lease-next": (args, path) => leaseNext({ ownerId: option(args, "--owner-id"), leaseSeconds: Number(option(args, "--lease-seconds", "60")), maxActive: Number(option(args, "--max-active", "4")) }, path),
  "lease-check": (args, path) => checkLease({ ownerId: option(args, "--owner-id"), repositoryId: option(args, "--repository-id"), fencingToken: Number(option(args, "--fencing-token")) }, path),
  "lease-renew": (args, path) => renewLease({ ownerId: option(args, "--owner-id"), repositoryId: option(args, "--repository-id"), fencingToken: Number(option(args, "--fencing-token")), leaseSeconds: Number(option(args, "--lease-seconds", "60")) }, path),
  "lease-finish": (args, path) => finishLease({ ownerId: option(args, "--owner-id"), repositoryId: option(args, "--repository-id"), fencingToken: Number(option(args, "--fencing-token")), status: option(args, "--status"), retryAfter: Number(option(args, "--retry-after", "0")), evidence: parseJson(option(args, "--evidence", "{}")) }, path),
  "publication-metrics": (_args, path) => publicationMetrics(path),
  attempt: (args, path) => attempt({ intentId: option(args, "--intent-id"), status: option(args, "--status"), evidence: parseJson(option(args, "--evidence", "{}")) }, path),
  transition: (args, path) => transition({ state: option(args, "--state"), fencingToken: option(args, "--fencing-token"), evidence: parseJson(option(args, "--evidence", "{}")) }, path),
  "bind-issue": (args, path) => bindIssue({ taskId: option(args, "--task-id"), forge: option(args, "--forge", "github"), repositoryId: option(args, "--repository-id"), repositorySlug: option(args, "--repository-slug"), role: option(args, "--role", "home"), issueId: option(args, "--issue-id"), projectId: option(args, "--project-id"), displayNumber: option(args, "--display-number"), stateCursor: option(args, "--state-cursor"), syncMetadata: parseJson(option(args, "--sync-metadata", "{}")) }, path),
  "resolve-issue": (args, path) => resolveIssue({ taskId: option(args, "--task-id"), forge: option(args, "--forge", "github"), repositoryId: option(args, "--repository-id") }, path),
  "reconciliation-targets": (args, path) => reconciliationTargets({ repositoryId: option(args, "--repository-id"), limit: Number(option(args, "--limit", "100")) }, path),
  "forge-event": (args, path) => forgeEvent({ operationId: option(args, "--operation-id"), deliveryId: option(args, "--delivery-id"), cursorTiebreaker: option(args, "--cursor-tiebreaker"), repositoryId: option(args, "--repository-id"), repositorySlug: option(args, "--repository-slug"), repositoryPath: option(args, "--repository-path"), taskId: option(args, "--task-id"), eventKind: option(args, "--event-kind"), action: option(args, "--action"), subjectId: option(args, "--subject-id"), cursor: option(args, "--cursor") }, path),
  restore: (args, path) => restore({ backupPath: option(args, "--backup"), registryEvidence: parseJson(option(args, "--registry-evidence", "{}")), priorEpoch: Number(option(args, "--prior-epoch")), newEpoch: Number(option(args, "--new-epoch")), fencingToken: option(args, "--fencing-token"), publishedHighWater: Number(option(args, "--published-high-water", "0")) }, path),
  verify: (_args, path) => verify(path),
  checkpoint: (_args, path) => checkpoint(path),
  status: (_args, path) => ({ ...activeOrigin(path), dbPath: path }),
};
export function run(args = process.argv.slice(2)) {
  const command = args[0] || "help";
  if (["help", "--help", "-h"].includes(command)) { process.stdout.write("Usage: task-coordinator.mjs allocate|adopt-legacy-task|publication-intent|lease-next|lease-check|lease-renew|lease-finish|publication-metrics|attempt|transition|bind-issue|resolve-issue|forge-event|restore|verify|status\n"); return 0; }
  const handler = COMMAND_HANDLERS[command];
  const path = initialise();
  if (!handler) throw new TypeError(`unknown task-coordinator command: ${command}`);
  const result = handler(args, path);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result.ok === false ? 1 : 0;
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  try { process.exitCode = run(); } catch (error) { process.stderr.write(`task-coordinator: ${error.message}\n`); process.exitCode = 1; }
}

export { adoptLegacyTask, allocate, backup, bindIssue, forgeEvent, hashPayload, initialise, leaseNext, publicationMetrics, resolveIssue, restore, verify };
