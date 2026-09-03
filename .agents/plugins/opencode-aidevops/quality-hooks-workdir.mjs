// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync, realpathSync, statSync } from "fs";

export function validateBashWorkingDirectory(cwd) {
  if (typeof cwd !== "string" || !cwd.trim()) {
    throw new Error("BLOCKED: Bash workdir must be a non-empty path");
  }

  let lexicalState;
  try {
    lexicalState = lstatSync(cwd);
  } catch (error) {
    const reason = ["ENOENT", "ENOTDIR"].includes(error?.code)
      ? "does not exist"
      : "could not be verified";
    throw new Error(`BLOCKED: Bash workdir ${reason}: ${cwd}`);
  }

  let resolvedCwd;
  try {
    resolvedCwd = realpathSync(cwd);
  } catch (error) {
    const reason = lexicalState.isSymbolicLink() && error?.code === "ENOENT"
      ? "is a broken symlink"
      : "could not be resolved";
    throw new Error(`BLOCKED: Bash workdir ${reason}: ${cwd}`);
  }

  let resolvedState;
  try {
    resolvedState = statSync(resolvedCwd);
  } catch {
    throw new Error(`BLOCKED: Bash workdir could not be verified: ${cwd}`);
  }
  if (!resolvedState.isDirectory()) {
    throw new Error(`BLOCKED: Bash workdir is not a directory: ${cwd}`);
  }
}
