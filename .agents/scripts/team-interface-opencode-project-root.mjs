// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {execFileSync} from "node:child_process";
import {existsSync, lstatSync, realpathSync, statSync} from "node:fs";
import {homedir} from "node:os";
import {isAbsolute, join, parse, relative, resolve, sep} from "node:path";

import {readBoundedJson} from "./team-interface-common.mjs";

const GIT_BINARY = "/usr/bin/git";
const MAX_REPOSITORY_METADATA_BYTES = 1024 * 1024;

export class ProjectRootValidationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ProjectRootValidationError";
    this.code = code;
  }
}

function hasSymlinkComponent(filePath) {
  const absolutePath = resolve(filePath);
  const root = parse(absolutePath).root;
  let current = root;
  for (const part of absolutePath.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, part);
    if (lstatSync(current).isSymbolicLink()) return true;
  }
  return false;
}

function isPathWithin(base, candidate) {
  const remainder = relative(base, candidate);
  return remainder === ""
    || (!isAbsolute(remainder) && remainder !== ".." && !remainder.startsWith(`..${sep}`));
}

function gitProjectMetadata(projectRoot) {
  try {
    const topLevel = realpathSync(execFileSync(
      GIT_BINARY,
      ["-C", projectRoot, "rev-parse", "--show-toplevel"],
      {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10000},
    ).trim());
    if (topLevel !== projectRoot) return null;
    const commonDirectory = realpathSync(execFileSync(
      GIT_BINARY,
      ["-C", projectRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"],
      {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10000},
    ).trim());
    return {commonDirectory, topLevel};
  } catch {
    return null;
  }
}

function expandedRegisteredPath(value, homeDirectory) {
  if (typeof value !== "string" || !value) return "";
  const expanded = value === "~"
    ? homeDirectory
    : value.startsWith("~/") ? join(homeDirectory, value.slice(2)) : value;
  if (!isAbsolute(expanded) || !existsSync(expanded)) return "";
  try {
    return realpathSync(expanded);
  } catch {
    return "";
  }
}

function rejectSensitiveProjectRoot(candidate, homeDirectory) {
  const sensitiveRoots = [
    join(homeDirectory, ".aws"),
    join(homeDirectory, ".azure"),
    join(homeDirectory, ".config"),
    join(homeDirectory, ".docker"),
    join(homeDirectory, ".gnupg"),
    join(homeDirectory, ".kube"),
    join(homeDirectory, ".local", "share", "opencode"),
    join(homeDirectory, ".ssh"),
  ].map((sensitiveRoot) => resolve(sensitiveRoot));
  const unsafeRoot = [
    candidate === parse(candidate).root,
    candidate === homeDirectory,
    isPathWithin(candidate, homeDirectory),
    sensitiveRoots.some((sensitiveRoot) => isPathWithin(sensitiveRoot, candidate)),
  ].some(Boolean);
  if (unsafeRoot) {
    throw new ProjectRootValidationError("unsafe_path", "restricted conversation cwd is not a bounded project root");
  }
}

function isLinkedToRegisteredRoot(candidate, registeredRoots) {
  const candidateGit = gitProjectMetadata(candidate);
  if (!candidateGit) return false;
  return registeredRoots.some((registeredRoot) => {
    const registeredGit = gitProjectMetadata(registeredRoot);
    return registeredGit?.commonDirectory === candidateGit.commonDirectory;
  });
}

export function validateRegisteredProjectRoot({requestedDirectory, reposPath}) {
  if (!isAbsolute(requestedDirectory) || hasSymlinkComponent(requestedDirectory)) {
    throw new ProjectRootValidationError("unsafe_path", "restricted conversation cwd must be an absolute non-symlink project root");
  }
  const candidate = realpathSync(requestedDirectory);
  if (!statSync(candidate).isDirectory()) {
    throw new ProjectRootValidationError("unsafe_path", "restricted conversation cwd is not a directory");
  }
  const homeDirectory = realpathSync(homedir());
  rejectSensitiveProjectRoot(candidate, homeDirectory);

  const repos = readBoundedJson(resolve(reposPath), MAX_REPOSITORY_METADATA_BYTES, "registered repositories");
  if (!Array.isArray(repos?.initialized_repos)) {
    throw new ProjectRootValidationError("invalid_document", "registered repository metadata is invalid");
  }
  const registeredRoots = repos.initialized_repos
    .map((entry) => expandedRegisteredPath(entry?.path, homeDirectory))
    .filter(Boolean);
  if (registeredRoots.includes(candidate) || isLinkedToRegisteredRoot(candidate, registeredRoots)) {
    return candidate;
  }
  throw new ProjectRootValidationError("unsafe_path", "restricted conversation cwd is not a registered canonical project or linked worktree root");
}
