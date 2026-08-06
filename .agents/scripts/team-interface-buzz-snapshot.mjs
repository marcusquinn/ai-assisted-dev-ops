// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {constants} from "node:fs";
import {mkdtemp, open, rmdir, unlink} from "node:fs/promises";
import {dirname, join, resolve} from "node:path";
import {
  captureSafePathIdentity,
  verifySafePathIdentity,
} from "./team-interface-buzz-path.mjs";
import {
  buzzReadError,
  throwIfAborted,
  withSafeFile,
} from "./team-interface-buzz-safe-read.mjs";

const COPY_BUFFER_BYTES = 64 * 1024;
const SNAPSHOT_BASENAME = "localstorage.sqlite3";
const SQLITE_SIDECAR_SUFFIXES = ["-wal", "-shm"];

async function assertPrivateSnapshotRoot(snapshotRoot, currentUid) {
  const identity = await captureSafePathIdentity(snapshotRoot);
  const {target: stats} = identity;
  if (!stats.isDirectory()) throw buzzReadError("unsafe_source");
  if (currentUid !== null && stats.uid !== currentUid) throw buzzReadError("unsafe_source");
  if ((stats.mode & 0o077) !== 0) throw buzzReadError("unsafe_source");
  return identity;
}

async function writeAll(destination, buffer, length, position) {
  let offset = 0;
  while (offset < length) {
    const result = await destination.write(buffer, offset, length - offset, position + offset);
    if (result.bytesWritten === 0) throw buzzReadError("malformed_source");
    offset += result.bytesWritten;
  }
}

async function captureCreatedFile(destinationPath, destination, directoryIdentity) {
  await verifySafePathIdentity(directoryIdentity);
  let identity;
  try {
    identity = await captureSafePathIdentity(destinationPath);
  } catch {
    throw buzzReadError("unsafe_source");
  }
  const opened = await destination.stat();
  if (identity.target.dev !== opened.dev || identity.target.ino !== opened.ino) {
    throw buzzReadError("unsafe_source");
  }
  return identity;
}

async function copyOpenedFile(source, stats, destinationPath, directoryIdentity, signal) {
  const destination = await open(
    destinationPath,
    constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
    0o600,
  );
  try {
    const destinationIdentity = await captureCreatedFile(destinationPath, destination, directoryIdentity);
    const buffer = Buffer.allocUnsafe(COPY_BUFFER_BYTES);
    let position = 0;
    while (position < stats.size) {
      throwIfAborted(signal);
      const length = Math.min(buffer.length, stats.size - position);
      const result = await source.read(buffer, 0, length, position);
      if (result.bytesRead === 0) throw buzzReadError("malformed_source");
      await writeAll(destination, buffer, result.bytesRead, position);
      position += result.bytesRead;
    }
    await verifySafePathIdentity(directoryIdentity);
    await verifySafePathIdentity(destinationIdentity);
    return destinationIdentity;
  } finally {
    await destination.close();
  }
}

async function snapshotOptionalSidecar(sourcePath, destinationPath, options, budget) {
  try {
    await withSafeFile(
      sourcePath,
      {...options, maxBytes: budget.remaining},
      async (_sourceFd, source, stats) => {
        const identity = await copyOpenedFile(
          source,
          stats,
          destinationPath,
          options.directoryIdentity,
          options.signal,
        );
        options.snapshotFiles.push(identity);
        budget.remaining -= stats.size;
      },
    );
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

async function removePrivateSnapshot(snapshotDirectory, rootIdentity, snapshotIdentity) {
  await verifySafePathIdentity(rootIdentity);
  await verifySafePathIdentity(snapshotIdentity);
  for (const suffix of ["", ...SQLITE_SIDECAR_SUFFIXES]) {
    try {
      await unlink(join(snapshotDirectory, `${SNAPSHOT_BASENAME}${suffix}`));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  await rmdir(snapshotDirectory);
}

export async function withSqliteSnapshot(databasePath, options, reader) {
  const {currentUid, makeTemporaryDirectory = mkdtemp, maxBytes, policy, signal, snapshotRoot} = options;
  throwIfAborted(signal);
  const rootIdentity = await assertPrivateSnapshotRoot(snapshotRoot, currentUid);
  const snapshotDirectory = await makeTemporaryDirectory(join(snapshotRoot, "buzz-sqlite-"));
  const snapshotPath = join(snapshotDirectory, SNAPSHOT_BASENAME);
  const budget = {remaining: maxBytes};
  const snapshotFiles = [];
  let snapshotIdentity;
  try {
    if (dirname(resolve(snapshotDirectory)) !== resolve(snapshotRoot)) throw buzzReadError("unsafe_source");
    await verifySafePathIdentity(rootIdentity);
    snapshotIdentity = await assertPrivateSnapshotRoot(snapshotDirectory, currentUid);
    return await withSafeFile(
      databasePath,
      {currentUid, maxBytes, policy, signal},
      async (_sourceFd, source, stats) => {
        const mainIdentity = await copyOpenedFile(source, stats, snapshotPath, snapshotIdentity, signal);
        snapshotFiles.push(mainIdentity);
        budget.remaining -= stats.size;
        for (const suffix of SQLITE_SIDECAR_SUFFIXES) {
          await snapshotOptionalSidecar(
            `${databasePath}${suffix}`,
            `${snapshotPath}${suffix}`,
            {currentUid, directoryIdentity: snapshotIdentity, policy, signal, snapshotFiles},
            budget,
          );
        }
        throwIfAborted(signal);
        await verifySafePathIdentity(rootIdentity);
        await verifySafePathIdentity(snapshotIdentity);
        for (const identity of snapshotFiles) await verifySafePathIdentity(identity);
        const value = await reader(snapshotPath, snapshotDirectory);
        await verifySafePathIdentity(rootIdentity);
        await verifySafePathIdentity(snapshotIdentity);
        for (const identity of snapshotFiles) await verifySafePathIdentity(identity);
        return value;
      },
    );
  } finally {
    if (snapshotIdentity) await removePrivateSnapshot(snapshotDirectory, rootIdentity, snapshotIdentity);
  }
}
