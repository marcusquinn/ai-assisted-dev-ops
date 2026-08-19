// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Verified partition/archive maintenance for append-only runtime evidence. */

import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  initialiseRuntimeEventStore,
  resolveRuntimeEventsDbPath,
} from "./runtime-events-store.mjs";
import { runRetentionCommand } from "./runtime-events-retention-cli.mjs";
import { buildRuntimeEventRetentionInventory } from "./runtime-events-retention-inventory.mjs";
import { runRuntimeEventMaintenance } from "./runtime-events-retention-maintenance.mjs";
import { verifyArchiveArtifacts } from "./runtime-events-retention-verification.mjs";
import { canonicalizeSqliteDbPath, sqlEscape } from "./sqlite-process.mjs";

export const RUNTIME_EVENT_ARCHIVE_SCHEMA_VERSION = 1;
export const RUNTIME_EVENT_ACTIVE_DAYS_DEFAULT = 30;
export const RUNTIME_EVENT_ARCHIVE_MAX_ROWS_DEFAULT = 5000;
export const RUNTIME_EVENT_MAINTENANCE_MAX_PARTITIONS_DEFAULT = 20;
export const RUNTIME_EVENT_MAINTENANCE_MAX_DURATION_SECONDS_DEFAULT = 120;

const ERROR_STATUS = new Set([
  "blocked", "cancelled", "denied", "error", "failed", "rejected", "timed_out", "timeout",
]);
const PROTECTED_EVENT_TYPE = /^(audit|deploy|full-loop|permission|release|security|session|subagent|worker)\.|(^|\.)(blocked|cancelled|completed|denied|error|failed|rejected|started|stopped|terminated|timeout)(\.|$)/;
const EVENT_COLUMNS = [
  "id", "envelope_version", "occurred_at", "event_id", "event_type", "correlation_id",
  "causation_id", "subject_id", "session_id", "worker_id", "parent_worker_id",
  "root_worker_id", "root_event_id", "parent_event_id", "state_version", "payload_json",
  "payload_bytes", "redaction_count",
];

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}

function normalizedArchiveDir(value, dbPath) {
  const candidate = value || join(dirname(dbPath), "runtime-events-archive");
  if (typeof candidate !== "string" || !isAbsolute(candidate) || candidate.includes("\0")) {
    throw new TypeError("runtime-event archive directory must be an absolute filesystem path");
  }
  return resolve(candidate);
}

function normalizedCutoff(value, { now = new Date(), activeDays = RUNTIME_EVENT_ACTIVE_DAYS_DEFAULT } = {}) {
  let cutoff;
  if (value) {
    cutoff = new Date(value);
  } else {
    const days = Number.parseInt(String(activeDays), 10);
    if (!Number.isSafeInteger(days) || days < 1 || days > 3650) {
      throw new TypeError("active days must be an integer from 1 to 3650");
    }
    cutoff = new Date(now.getTime() - (days * 24 * 60 * 60 * 1000));
  }
  if (Number.isNaN(cutoff.getTime()) || cutoff.getTime() >= now.getTime()) {
    throw new TypeError("archive cutoff must be a valid time in the past");
  }
  return cutoff.toISOString();
}

function normalizedMaxRows(value) {
  const parsed = Number.parseInt(String(value || RUNTIME_EVENT_ARCHIVE_MAX_ROWS_DEFAULT), 10);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 100000) {
    throw new TypeError("archive max rows must be an integer from 1 to 100000");
  }
  return parsed;
}

function sqlite(dbPath, sql, { json = false, readonly = false } = {}) {
  const args = ["-cmd", ".timeout 15000"];
  if (json) args.push("-json");
  if (readonly) args.push("-readonly");
  args.push(dbPath);
  return execFileSync("sqlite3", args, {
    encoding: "utf8",
    input: sql,
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 30000,
  }).trim();
}

function sqliteRows(dbPath, sql, options = {}) {
  const output = sqlite(dbPath, sql, { ...options, json: true });
  if (!output) return [];
  const parsed = JSON.parse(output);
  return Array.isArray(parsed) ? parsed : [];
}

function parsedPayload(row) {
  try {
    const payload = JSON.parse(row.payload_json || "{}");
    return payload && typeof payload === "object" ? payload : {};
  } catch {
    return {};
  }
}

/** True when a row belongs to the minimum terminal/error/lifecycle/security/audit envelope. */
export function isProtectedRuntimeEvent(row) {
  if (row?.state_version !== null && row?.state_version !== undefined) return true;
  const eventType = String(row?.event_type || "").toLowerCase();
  if (PROTECTED_EVENT_TYPE.test(eventType)) return true;
  const payload = parsedPayload(row);
  if (payload.success === false || payload.error_type ||
      (payload.exit_code !== undefined && Number(payload.exit_code) !== 0)) {
    return true;
  }
  return ERROR_STATUS.has(String(payload.status || "").toLowerCase());
}

function normalizedEventRow(row) {
  return Object.fromEntries(EVENT_COLUMNS.map((column) => [column, row[column] ?? null]));
}

function sourceDigest(rows) {
  return sha256(rows.map((row) => canonicalJson(normalizedEventRow(row))).join("\n"));
}

function logicalRowBytes(row) {
  return Buffer.byteLength(canonicalJson(normalizedEventRow(row)), "utf8");
}

function compactedSummaries(rows) {
  const groups = new Map();
  for (const row of rows) {
    const eventType = String(row.event_type || "unknown");
    const group = groups.get(eventType) || {
      count: 0,
      event_type: eventType,
      first_occurred_at: row.occurred_at,
      last_occurred_at: row.occurred_at,
      payload_bytes: 0,
      record_type: "summary",
      redaction_count: 0,
    };
    group.count += 1;
    group.first_occurred_at = group.first_occurred_at < row.occurred_at
      ? group.first_occurred_at
      : row.occurred_at;
    group.last_occurred_at = group.last_occurred_at > row.occurred_at
      ? group.last_occurred_at
      : row.occurred_at;
    group.payload_bytes += Number(row.payload_bytes || 0);
    group.redaction_count += Number(row.redaction_count || 0);
    groups.set(eventType, group);
  }
  return [...groups.values()].sort((left, right) => left.event_type.localeCompare(right.event_type));
}

function buildPartition(rows, cutoffAt, createdAt = new Date().toISOString()) {
  const protectedRows = rows.filter(isProtectedRuntimeEvent);
  const compactedRows = rows.filter((row) => !isProtectedRuntimeEvent(row));
  const digest = sourceDigest(rows);
  const firstId = Number(rows[0].id);
  const lastId = Number(rows.at(-1).id);
  const partitionId = `runtime-events-${firstId}-${lastId}-${digest.slice(0, 12)}`;
  const eventRecords = protectedRows.map((row) => ({
    event: normalizedEventRow(row),
    record_type: "event",
  }));
  const summaryRecords = compactedSummaries(compactedRows);
  const header = {
    archive_record_count: eventRecords.length + summaryRecords.length,
    compacted_row_count: compactedRows.length,
    created_at: createdAt,
    cutoff_at: cutoffAt,
    partition_id: partitionId,
    protected_row_count: protectedRows.length,
    record_type: "manifest",
    schema_version: RUNTIME_EVENT_ARCHIVE_SCHEMA_VERSION,
    source_first_id: firstId,
    source_last_id: lastId,
    source_logical_bytes: rows.reduce((total, row) => total + logicalRowBytes(row), 0),
    source_payload_bytes: rows.reduce((total, row) => total + Number(row.payload_bytes || 0), 0),
    source_row_count: rows.length,
    source_sha256: digest,
  };
  const contents = [header, ...eventRecords, ...summaryRecords]
    .map((record) => canonicalJson(record))
    .join("\n") + "\n";
  return { contents, header };
}

function atomicWrite(filePath, contents) {
  const tempPath = `${filePath}.tmp-${process.pid}-${randomUUID()}`;
  let descriptor;
  try {
    descriptor = openSync(tempPath, "wx", 0o600);
    writeFileSync(descriptor, contents, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(tempPath, filePath);
    chmodSync(filePath, 0o444);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    if (existsSync(tempPath)) unlinkSync(tempPath);
  }
}

function manifestForContents(header, archiveFile, contents) {
  return {
    ...header,
    archive_bytes: Buffer.byteLength(contents, "utf8"),
    archive_file: archiveFile,
    archive_sha256: sha256(contents),
  };
}

/** Verify a partition and its sidecar without trusting filenames or row claims. */
export function verifyRuntimeEventArchive(archivePath, manifestPath = `${archivePath}.manifest.json`) {
  return verifyArchiveArtifacts({
    archivePath,
    digest: sha256,
    manifestPath,
    schemaVersion: RUNTIME_EVENT_ARCHIVE_SCHEMA_VERSION,
  });
}

function persistPartition(archiveDir, partition) {
  mkdirSync(archiveDir, { mode: 0o700, recursive: true });
  if (lstatSync(archiveDir).isSymbolicLink()) throw new Error("archive directory must not be a symbolic link");
  const archiveFile = `${partition.header.partition_id}.jsonl`;
  const archivePath = join(archiveDir, archiveFile);
  const manifestPath = `${archivePath}.manifest.json`;
  const expectedManifest = manifestForContents(partition.header, archiveFile, partition.contents);

  if (!existsSync(archivePath)) atomicWrite(archivePath, partition.contents);
  if (!existsSync(manifestPath)) atomicWrite(manifestPath, `${canonicalJson(expectedManifest)}\n`);

  const verified = verifyRuntimeEventArchive(archivePath, manifestPath);
  if (!verified.ok || verified.manifest?.source_sha256 !== partition.header.source_sha256) {
    throw new Error(`archive partition verification failed: ${verified.errors.join("; ")}`);
  }
  return { archivePath, manifest: verified.manifest, manifestPath };
}

function candidateRows(dbPath, cutoffAt, maxRows, { readonly = false } = {}) {
  return sqliteRows(dbPath, `
    SELECT ${EVENT_COLUMNS.join(", ")}
    FROM runtime_events
    WHERE occurred_at < ${sqlEscape(cutoffAt)} AND state_version IS NULL
    ORDER BY id ASC LIMIT ${maxRows};
  `, { readonly });
}

function archiveManifestInsertSql(manifest) {
  return `INSERT INTO runtime_event_archives (
    partition_id, schema_version, created_at, cutoff_at, source_first_id,
    source_last_id, source_row_count, protected_row_count, compacted_row_count,
    archive_record_count, source_payload_bytes, archive_bytes, source_sha256,
    archive_sha256, archive_file
  ) VALUES (
    ${sqlEscape(manifest.partition_id)}, ${manifest.schema_version},
    ${sqlEscape(manifest.created_at)}, ${sqlEscape(manifest.cutoff_at)},
    ${manifest.source_first_id}, ${manifest.source_last_id}, ${manifest.source_row_count},
    ${manifest.protected_row_count}, ${manifest.compacted_row_count},
    ${manifest.archive_record_count}, ${manifest.source_payload_bytes},
    ${manifest.archive_bytes}, ${sqlEscape(manifest.source_sha256)},
    ${sqlEscape(manifest.archive_sha256)}, ${sqlEscape(manifest.archive_file)}
  );`;
}

function pruneVerifiedSource(dbPath, manifest) {
  const predicate = `id <= ${manifest.source_last_id} AND occurred_at < ${sqlEscape(manifest.cutoff_at)} AND state_version IS NULL`;
  sqlite(dbPath, `.bail on
BEGIN IMMEDIATE;
CREATE TEMP TABLE runtime_retention_assert(ok INTEGER NOT NULL CHECK(ok = 1));
INSERT INTO runtime_retention_assert VALUES ((
  SELECT CASE WHEN COUNT(*) = ${manifest.source_row_count}
    AND COALESCE(MIN(id), 0) = ${manifest.source_first_id}
    AND COALESCE(MAX(id), 0) = ${manifest.source_last_id}
    AND COALESCE(SUM(payload_bytes), 0) = ${manifest.source_payload_bytes}
  THEN 1 ELSE 0 END FROM runtime_events WHERE ${predicate}
));
DROP TRIGGER runtime_events_reject_delete;
DELETE FROM runtime_events WHERE ${predicate};
INSERT INTO runtime_retention_assert VALUES (CASE WHEN changes() = ${manifest.source_row_count} THEN 1 ELSE 0 END);
CREATE TRIGGER runtime_events_reject_delete
BEFORE DELETE ON runtime_events
BEGIN
  SELECT RAISE(ABORT, 'runtime_events is append-only');
END;
${archiveManifestInsertSql(manifest)}
COMMIT;
`);
  const remaining = Number(sqlite(dbPath, `SELECT COUNT(*) FROM runtime_events WHERE ${predicate};`) || 0);
  const manifestRows = Number(sqlite(dbPath, `
    SELECT COUNT(*) FROM runtime_event_archives
    WHERE partition_id = ${sqlEscape(manifest.partition_id)}
      AND archive_sha256 = ${sqlEscape(manifest.archive_sha256)};
  `) || 0);
  if (remaining !== 0 || manifestRows !== 1) throw new Error("archive commit verification failed");
}

/** Plan or apply one bounded archive partition. Apply is always explicit. */
export function archiveRuntimeEvents(options = {}) {
  const dbPath = canonicalizeSqliteDbPath(options.dbPath || resolveRuntimeEventsDbPath());
  const archiveDir = normalizedArchiveDir(options.archiveDir, dbPath);
  const cutoffAt = normalizedCutoff(options.cutoff, options);
  const maxRows = normalizedMaxRows(options.maxRows);
  if (!existsSync(dbPath)) {
    return Object.freeze({
      applied: false,
      candidate_bytes: 0,
      candidate_rows: 0,
      more_candidates: false,
      status: "database_missing",
    });
  }
  if (options.apply && !initialiseRuntimeEventStore(dbPath)) {
    throw new Error("runtime-event store is unavailable");
  }
  const selectedRows = candidateRows(dbPath, cutoffAt, maxRows + 1, { readonly: !options.apply });
  const moreCandidates = selectedRows.length > maxRows;
  const rows = selectedRows.slice(0, maxRows);
  if (rows.length === 0) {
    return Object.freeze({
      applied: false,
      candidate_bytes: 0,
      candidate_rows: 0,
      more_candidates: false,
      status: "no_candidates",
    });
  }
  const partition = buildPartition(rows, cutoffAt, options.createdAt);
  const result = {
    applied: false,
    candidate_bytes: partition.header.source_logical_bytes,
    candidate_rows: partition.header.source_row_count,
    compacted_rows: partition.header.compacted_row_count,
    more_candidates: moreCandidates,
    partition_id: partition.header.partition_id,
    protected_rows: partition.header.protected_row_count,
    status: options.apply ? "prepared" : "dry_run",
  };
  if (!options.apply) return Object.freeze(result);

  const persisted = persistPartition(archiveDir, partition);
  if (options.simulateInterruption === "after_archive") {
    throw new Error("simulated interruption after verified archive");
  }
  pruneVerifiedSource(dbPath, persisted.manifest);
  return Object.freeze({
    ...result,
    applied: true,
    archive_bytes: persisted.manifest.archive_bytes,
    archive_file: persisted.manifest.archive_file,
    status: "archived",
  });
}

/** Apply verified partitions until caught up or an explicit work bound is reached. */
export function maintainRuntimeEvents(options = {}) {
  return runRuntimeEventMaintenance(options, {
    archive: archiveRuntimeEvents,
    maxDurationSecondsDefault: RUNTIME_EVENT_MAINTENANCE_MAX_DURATION_SECONDS_DEFAULT,
    maxPartitionsDefault: RUNTIME_EVENT_MAINTENANCE_MAX_PARTITIONS_DEFAULT,
    normalizeCutoff: normalizedCutoff,
  });
}

/** Conservative physical/logical inventory with no raw payload or private path output. */
export function runtimeEventRetentionInventory(options = {}) {
  return buildRuntimeEventRetentionInventory(options, {
    activeDaysDefault: RUNTIME_EVENT_ACTIVE_DAYS_DEFAULT,
    canonicalizeDbPath: canonicalizeSqliteDbPath,
    normalizedArchiveDir,
    normalizedCutoff,
    resolveDbPath: resolveRuntimeEventsDbPath,
    sqlEscape,
    sqliteRows,
    verifyArchive: verifyRuntimeEventArchive,
  });
}

export function runRetentionCli(argv = process.argv.slice(2)) {
  return runRetentionCommand(argv, {
    archive: archiveRuntimeEvents,
    inventory: runtimeEventRetentionInventory,
    maintain: maintainRuntimeEvents,
  });
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  process.exitCode = runRetentionCli();
}
