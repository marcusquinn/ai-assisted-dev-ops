// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  appendRuntimeEventSync,
  appendStateSnapshot,
  initialiseRuntimeEventStore,
} from "../../../scripts/runtime-events.mjs";
import {
  archiveRuntimeEvents,
  isProtectedRuntimeEvent,
  maintainRuntimeEvents,
  runtimeEventRetentionInventory,
  verifyRuntimeEventArchive,
} from "../../../scripts/runtime-events-retention.mjs";

const OLD_TIME = "2025-01-01T00:00:00.000Z";
const CUTOFF = "2026-01-01T00:00:00.000Z";

function sqliteAvailable() {
  try {
    execFileSync("sqlite3", ["-version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function scalar(dbPath, sql) {
  return execFileSync("sqlite3", [dbPath, sql], { encoding: "utf8" }).trim();
}

function appendFixture(index, eventType = "message.part.delta", payload = { source: "fixture" }) {
  const event = appendRuntimeEventSync({
    eventId: `fixture:${eventType}:${index}`,
    eventType,
    occurredAt: OLD_TIME,
    payload,
    subjectId: `fixture:${index}`,
  });
  assert.ok(event, `fixture event ${index} should append`);
}

describe("runtime-event protection policy", () => {
  test("protects lifecycle, terminal, failure, security, and recovery evidence", () => {
    for (const eventType of [
      "worker.started", "worker.completed", "session.created", "tool.completed",
      "permission.denied", "security.alert", "release.failed",
    ]) {
      assert.equal(isProtectedRuntimeEvent({ event_type: eventType, payload_json: "{}" }), true);
    }
    assert.equal(isProtectedRuntimeEvent({
      event_type: "provider.updated",
      payload_json: '{"success":false}',
    }), true);
    assert.equal(isProtectedRuntimeEvent({
      event_type: "message.part.delta",
      payload_json: '{"source":"opencode"}',
    }), false);
    assert.equal(isProtectedRuntimeEvent({
      event_type: "state.snapshot",
      payload_json: '{"state":{}}',
      state_version: 1,
    }), true);
  });
});

test("archive is dry-run first, interruption-safe, resumable, and append-only", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-retention-"));
  const dbPath = join(tempDir, "observability.db");
  const archiveDir = join(tempDir, "archives");
  try {
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    for (let index = 0; index < 100; index++) appendFixture(index);
    appendFixture(100, "worker.completed", { result: "success", source: "fixture" });
    appendFixture(101, "tool.completed", { error_type: "Failure", success: false });
    assert.ok(appendStateSnapshot({
      eventId: "fixture:state:1",
      occurredAt: OLD_TIME,
      state: { status: "running" },
      subjectId: "fixture:state",
    }));

    const sourceRows = Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;"));
    const dryRun = archiveRuntimeEvents({ archiveDir, cutoff: CUTOFF, dbPath, maxRows: 1000 });
    assert.equal(dryRun.status, "dry_run");
    assert.equal(dryRun.candidate_rows, 102);
    assert.equal(dryRun.protected_rows, 2);
    assert.equal(dryRun.compacted_rows, 100);
    assert.equal(existsSync(archiveDir), false);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), sourceRows);

    assert.throws(() => archiveRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      maxRows: 1000,
      simulateInterruption: "after_archive",
    }), /simulated interruption/);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), sourceRows);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_event_archives;")), 0);

    const archiveName = readdirSync(archiveDir).find((name) => name.endsWith(".jsonl"));
    assert.ok(archiveName);
    const archivePath = join(archiveDir, archiveName);
    const verifiedBeforeResume = verifyRuntimeEventArchive(archivePath);
    assert.equal(verifiedBeforeResume.ok, true);

    const applied = archiveRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      maxRows: 1000,
    });
    assert.equal(applied.status, "archived");
    assert.equal(applied.partition_id, dryRun.partition_id);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 1);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_event_archives;")), 1);
    assert.equal(scalar(dbPath, "SELECT event_type FROM runtime_events;"), "state.snapshot");

    const archived = readFileSync(archivePath, "utf8");
    assert.match(archived, /worker\.completed/);
    assert.match(archived, /tool\.completed/);
    assert.match(archived, /"event_type":"message\.part\.delta"/);
    assert.match(archived, /"count":100/);
    assert.throws(() => execFileSync("sqlite3", [
      dbPath,
      "DELETE FROM runtime_event_archives;",
    ], { stdio: "pipe" }));
    assert.throws(() => execFileSync("sqlite3", [
      dbPath,
      "DELETE FROM runtime_events;",
    ], { stdio: "pipe" }));

    const inventory = runtimeEventRetentionInventory({ archiveDir, cutoff: CUTOFF, dbPath });
    assert.ok(inventory.active_bytes > 0);
    assert.ok(inventory.archive_bytes > 0);
    assert.ok(inventory.protected_bytes > 0);
    assert.equal(inventory.candidate_bytes, 0);
    assert.equal(inventory.reclaimable_bytes, 0);
    assert.doesNotMatch(JSON.stringify(inventory), /payload_json|fixture:|observability\.db/);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("corrupt interrupted archives fail closed with source rows intact", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-retention-corrupt-"));
  const dbPath = join(tempDir, "observability.db");
  const archiveDir = join(tempDir, "archives");
  try {
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    appendFixture(200, "worker.completed", { result: "success" });
    assert.throws(() => archiveRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      simulateInterruption: "after_archive",
    }), /simulated interruption/);
    const archiveName = readdirSync(archiveDir).find((name) => name.endsWith(".jsonl"));
    const archivePath = join(archiveDir, archiveName);
    chmodSync(archivePath, 0o600);
    writeFileSync(archivePath, `${readFileSync(archivePath, "utf8")}corrupt\n`);
    assert.throws(() => archiveRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
    }), /archive partition verification failed/);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 1);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_event_archives;")), 0);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("synthetic high-volume cycles converge in the active partition", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-retention-growth-"));
  const dbPath = join(tempDir, "observability.db");
  const archiveDir = join(tempDir, "archives");
  try {
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    for (let cycle = 0; cycle < 3; cycle++) {
      for (let index = 0; index < 500; index++) {
        appendFixture((cycle * 1000) + index, "message.part.delta");
      }
      appendFixture((cycle * 1000) + 999, "message.completed", { finish_reason: "stop" });
      const applied = archiveRuntimeEvents({
        apply: true,
        archiveDir,
        cutoff: CUTOFF,
        dbPath,
        maxRows: 1000,
      });
      assert.equal(applied.candidate_rows, 501);
      assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 0);
    }
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_event_archives;")), 3);
    assert.equal(runtimeEventRetentionInventory({ archiveDir, cutoff: CUTOFF, dbPath }).candidate_bytes, 0);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("bounded producer maintenance catches up across scheduled runs", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-maintenance-"));
  const dbPath = join(tempDir, "observability.db");
  const archiveDir = join(tempDir, "archives");
  try {
    assert.equal(initialiseRuntimeEventStore(dbPath), true);
    for (let index = 0; index < 125; index++) appendFixture(5000 + index);

    const dryRun = maintainRuntimeEvents({
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      maxPartitions: 2,
      maxRows: 50,
    });
    assert.equal(dryRun.status, "maintenance_dry_run");
    assert.equal(dryRun.candidate_rows, 50);
    assert.equal(dryRun.more_candidates, true);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 125);

    const clockValues = [0, 0, 1001];
    const durationBounded = maintainRuntimeEvents({
      apply: true,
      archiveDir,
      clock: () => clockValues.shift() ?? 1001,
      cutoff: CUTOFF,
      dbPath,
      maxDurationSeconds: 1,
      maxPartitions: 20,
      maxRows: 50,
    });
    assert.equal(durationBounded.status, "maintained");
    assert.equal(durationBounded.stop_reason, "max_duration");
    assert.equal(durationBounded.partitions_archived, 1);
    assert.equal(durationBounded.source_rows_archived, 50);
    assert.equal(durationBounded.backlog_remaining, true);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 75);

    const bounded = maintainRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      maxPartitions: 1,
      maxRows: 50,
    });
    assert.equal(bounded.status, "maintained");
    assert.equal(bounded.stop_reason, "max_partitions");
    assert.equal(bounded.partitions_archived, 1);
    assert.equal(bounded.source_rows_archived, 50);
    assert.equal(bounded.backlog_remaining, true);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 25);

    const converged = maintainRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      maxPartitions: 2,
      maxRows: 50,
    });
    assert.equal(converged.stop_reason, "no_candidates");
    assert.equal(converged.partitions_archived, 1);
    assert.equal(converged.source_rows_archived, 25);
    assert.equal(converged.backlog_remaining, false);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_events;")), 0);
    assert.equal(Number(scalar(dbPath, "SELECT COUNT(*) FROM runtime_event_archives;")), 3);

    const noOp = maintainRuntimeEvents({
      apply: true,
      archiveDir,
      cutoff: CUTOFF,
      dbPath,
      maxPartitions: 2,
      maxRows: 50,
    });
    assert.equal(noOp.status, "no_candidates");
    assert.equal(noOp.partitions_archived, 0);
    assert.equal(noOp.backlog_remaining, false);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});
