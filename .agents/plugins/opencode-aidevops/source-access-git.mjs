// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { execFileSync } from "node:child_process";

export function sourceGitArguments(args) {
  return ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", ...args];
}

export function sourceGitEnvironment(environment = process.env) {
  return {
    ...Object.fromEntries(Object.entries(environment).filter(([key]) => !key.startsWith("GIT_"))),
    GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_OPTIONAL_LOCKS: "0",
  };
}

/** Source inspection must not execute repository-configured fsmonitor commands. */
export function sourceAccessGit(program, args, options, run = execFileSync) {
  return run(program, sourceGitArguments(args), {
    ...options, env: sourceGitEnvironment(options?.env),
  });
}
