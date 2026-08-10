// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  createSessionRecoveryMarkerHandler,
  currentDirectorySequence,
  resolveSessionRecoveryMarker,
  writeSessionRecoveryMarker,
} from "../../plugins/opencode-aidevops/session-recovery-marker.mjs";

const root = mkdtempSync(join(tmpdir(), "aidevops-session-recovery-"));
const workDir = join(root, "work");
const directory = join(root, "repo");
const dataDir = join(workDir, "opencode-interactive", "project-repo-test");
const databaseDir = join(dataDir, "opencode");
const databasePath = join(databaseDir, "opencode.db");
const sessionID = "ses_0123456789AbCdEf";
mkdirSync(directory, { recursive: true });
mkdirSync(databaseDir, { recursive: true });

const sql = [
  "CREATE TABLE session (id text PRIMARY KEY, parent_id text, directory text NOT NULL);",
  `INSERT INTO session (id, parent_id, directory) VALUES ('${sessionID}', NULL, '${directory}');`,
].join(" ");
const sqlite = spawnSync("sqlite3", [databasePath, sql], { encoding: "utf8" });
assert.equal(sqlite.status, 0, sqlite.stderr);

assert.equal(
  currentDirectorySequence("/safe path"),
  "\u001B]1337;CurrentDir=/safe path\u0007",
  "Tabby CurrentDir sequence should carry the exact marker path",
);
assert.throws(() => currentDirectorySequence("/unsafe\npath"), /Invalid terminal recovery directory/);

const markerDirectory = writeSessionRecoveryMarker({ sessionID, directory, dataDir, workDir });
assert.deepEqual(resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir }), {
  sessionID,
  directory: realpathSync(directory),
  dataDir: realpathSync(dataDir),
  markerDirectory: realpathSync(markerDirectory),
});
assert.equal(resolveSessionRecoveryMarker({ cwd: directory, workDir }), null);

const resolverPath = fileURLToPath(
  new URL("../../plugins/opencode-aidevops/session-recovery-marker.mjs", import.meta.url),
);
const linkedResolverPath = join(root, "session-recovery-marker.mjs");
symlinkSync(resolverPath, linkedResolverPath);
const resolvedCli = spawnSync(
  process.execPath,
  [linkedResolverPath, "resolve", "--cwd", markerDirectory, "--work-dir", workDir],
  { encoding: "utf8" },
);
assert.equal(resolvedCli.status, 0, resolvedCli.stderr);
assert.equal(
  resolvedCli.stdout,
  `${realpathSync(directory)}\t${realpathSync(dataDir)}\t${sessionID}\n`,
  "resolver CLI should execute when invoked through the deployed agents symlink",
);
const missingCli = spawnSync(
  process.execPath,
  [linkedResolverPath, "resolve", "--cwd", directory, "--work-dir", workDir],
  { encoding: "utf8" },
);
assert.equal(missingCli.status, 2, "resolver CLI should preserve the no-marker status through a symlink");

const emitted = [];
const handler = createSessionRecoveryMarkerHandler({
  directory,
  dataDir,
  workDir,
  isEnabled: () => true,
  writeMarker: (marker) => {
    emitted.push(marker);
    return markerDirectory;
  },
  writeDirectory: (path) => emitted.push(path),
});
await handler({ event: { type: "session.created", properties: { info: { id: sessionID } } } });
await handler({ event: { type: "session.updated", properties: { info: { id: sessionID } } } });
await handler({
  event: {
    type: "session.created",
    properties: { info: { id: "ses_AnotherSession123", parentID: sessionID } },
  },
});
assert.equal(emitted.length, 2, "root session marker should be emitted exactly once");
assert.equal(emitted[0].sessionID, sessionID);
assert.equal(emitted[1], markerDirectory);

chmodSync(join(markerDirectory, "recovery.json"), 0o644);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir }),
  /Unsafe recovery marker file/,
);
chmodSync(join(markerDirectory, "recovery.json"), 0o600);

const linkedMarker = join(workDir, "opencode-tabby-recovery", "ses_LinkedMarker123");
symlinkSync(markerDirectory, linkedMarker);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: linkedMarker, workDir }),
  /Invalid recovery marker location|session mismatch/,
);

const linkedWorkDir = join(root, "linked-work");
mkdirSync(linkedWorkDir);
symlinkSync(join(workDir, "opencode-tabby-recovery"), join(linkedWorkDir, "opencode-tabby-recovery"));
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir: linkedWorkDir }),
  /Invalid recovery marker root/,
);

writeFileSync(
  join(markerDirectory, "recovery.json"),
  `${JSON.stringify({
    schema_version: 1,
    session_id: sessionID,
    directory: join(root, "other-repo"),
    data_dir: dataDir,
  })}\n`,
  { mode: 0o600 },
);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir }),
  /ENOENT|does not match/,
);

console.log("All session recovery marker tests passed");
