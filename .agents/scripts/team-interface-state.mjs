// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {chmodSync, closeSync, fsyncSync, openSync, renameSync, rmSync, writeFileSync} from "node:fs";
import {randomUUID} from "node:crypto";
import {homedir} from "node:os";
import {join} from "node:path";
import {assertUniqueIds, canonicalJson, expandRuntimePath, readBoundedJson, TeamInterfaceError} from "./team-interface-common.mjs";
import {acquireStateLock, assertDirectoryIdentity, ensurePrivateStateDirectory, releaseStateLock} from "./team-interface-lock.mjs";
import {requireValid, validatorsFor} from "./team-interface-validators.mjs";

const DEFAULT_STATE_ROOT = join(homedir(), ".aidevops/state");
const STATE_MAX_BYTES = 10 * 1024 * 1024;

export function runtimeStatePaths(stateRoot = process.env.AIDEVOPS_STATE_DIR || DEFAULT_STATE_ROOT) {
  const root = expandRuntimePath(stateRoot);
  const directory = join(root, "team-interface");
  return Object.freeze({
    directory,
    lockPath: join(directory, "state-v1.lock"),
    statePath: join(directory, "state-v1.json"),
  });
}

function validateStateSemantics(state) {
  assertUniqueIds(state.observations, "adapter_id", "runtime state");
  return state;
}

export function readRuntimeState(options = {}) {
  const validators = validatorsFor(options.validators);
  const paths = options.paths || runtimeStatePaths(options.stateRoot);
  const state = (() => {
    try {
      return readBoundedJson(paths.statePath, options.maxBytes || STATE_MAX_BYTES, "team-interface runtime state");
    } catch (error) {
      if (error?.code === "missing_document") return null;
      throw error;
    }
  })();
  if (!state) return null;
  requireValid(validators.runtimeState, state, "team-interface runtime state");
  return validateStateSemantics(state);
}

function fsyncDirectory(directory) {
  const descriptor = openSync(directory, "r");
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

function atomicWriteState(paths, state, directoryIdentity) {
  assertDirectoryIdentity(paths.directory, directoryIdentity);
  const temporary = `${paths.statePath}.tmp-${process.pid}-${randomUUID()}`;
  let descriptor;
  try {
    descriptor = openSync(temporary, "wx", 0o600);
    writeFileSync(descriptor, `${canonicalJson(state)}\n`, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    assertDirectoryIdentity(paths.directory, directoryIdentity);
    renameSync(temporary, paths.statePath);
    chmodSync(paths.statePath, 0o600);
    fsyncDirectory(paths.directory);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporary, {force: true});
  }
}

export function writeRuntimeState(nextState, options = {}) {
  const validators = validatorsFor(options.validators);
  requireValid(validators.runtimeState, nextState, "next team-interface runtime state");
  validateStateSemantics(nextState);
  const expectedGeneration = options.expectedGeneration;
  if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 0) {
    throw new TeamInterfaceError("invalid_generation", "expected state generation is invalid");
  }
  if (nextState.generation !== expectedGeneration + 1) {
    throw new TeamInterfaceError("invalid_generation", "next state generation must increment expected generation once");
  }
  const paths = options.paths || runtimeStatePaths(options.stateRoot);
  const directoryIdentity = ensurePrivateStateDirectory(paths.directory);
  const lock = acquireStateLock(paths, {
    directoryIdentity,
    staleMs: options.lockStaleMs,
    timeoutMs: options.lockTimeoutMs,
  });
  try {
    const current = readRuntimeState({paths, validators});
    const currentGeneration = current?.generation || 0;
    if (currentGeneration !== expectedGeneration) {
      throw new TeamInterfaceError("generation_conflict", "team-interface runtime state generation changed");
    }
    atomicWriteState(paths, nextState, directoryIdentity);
    return structuredClone(nextState);
  } finally {
    releaseStateLock(lock);
  }
}
