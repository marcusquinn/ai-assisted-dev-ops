// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {spawn} from "node:child_process";
import {once} from "node:events";

const CREDENTIAL_ENV_PATTERN =
  /(?:^|_)(?:API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|TOKEN|PASSWORD|PASSWD|SECRET|CREDENTIALS?|AUTHORIZATION|COOKIE)(?:$|_)/iu;
const CREDENTIAL_BROKER_VARIABLES = new Set([
  "DOCKER_CONFIG",
  "GPG_AGENT_INFO",
  "KUBECONFIG",
  "NPM_CONFIG_USERCONFIG",
  "SSH_AGENT_PID",
  "SSH_AUTH_SOCK",
]);

function publicationEnvironment() {
  const environment = {};
  for (const name of ["BUZZ_RELAY_URL", "BUZZ_PRIVATE_KEY", "BUZZ_AUTH_TAG"]) {
    if (typeof process.env[name] === "string" && process.env[name].length > 0) {
      environment[name] = process.env[name];
    }
  }
  if (!environment.BUZZ_RELAY_URL || !environment.BUZZ_PRIVATE_KEY) {
    throw new Error("Buzz reply credentials are unavailable");
  }
  return environment;
}

function childVariableIsBlocked(name) {
  if (name.startsWith("BUZZ_") || name.startsWith("AIDEVOPS_BUZZ_")) {
    return true;
  }
  if (name === "NOSTR_PRIVATE_KEY" || CREDENTIAL_BROKER_VARIABLES.has(name)) {
    return true;
  }
  return CREDENTIAL_ENV_PATTERN.test(name);
}

export function childEnvironment() {
  const environment = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (!childVariableIsBlocked(name) && typeof value === "string") {
      environment[name] = value;
    }
  }
  return environment;
}

export async function publishReply(buzzCli, turn) {
  const publisher = spawn(
    buzzCli,
    [
      "messages",
      "send",
      "--channel",
      turn.channel,
      "--content",
      "-",
      "--reply-to",
      turn.replyTo,
    ],
    {
      env: publicationEnvironment(),
      shell: false,
      stdio: ["pipe", "ignore", "ignore"],
    },
  );
  const timeout = setTimeout(() => publisher.kill("SIGTERM"), 30_000);
  publisher.stdin.end(turn.text, "utf8");
  const [code, signal] = await once(publisher, "exit");
  clearTimeout(timeout);
  if (signal) {
    throw new Error(`Buzz reply publication ended from signal ${signal}`);
  }
  if (code !== 0) {
    throw new Error(`Buzz reply publication failed with exit ${code ?? 1}`);
  }
}
