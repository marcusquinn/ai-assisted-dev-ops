// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {existsSync} from "node:fs";
import {homedir} from "node:os";
import {dirname, join} from "node:path";
import {assertUniqueIds, expandRuntimePath, readBoundedJson} from "./team-interface-common.mjs";
import {requireValid, validatorsFor} from "./team-interface-validators.mjs";

const DEFAULT_CONFIG_PATH = join(homedir(), ".config/aidevops/team-interface.json");
const CONFIG_MAX_BYTES = 1024 * 1024;

export function loadRuntimeConfig(options = {}) {
  const validators = validatorsFor(options.validators);
  const requestedPath = options.configPath || process.env.AIDEVOPS_TEAM_INTERFACE_CONFIG || DEFAULT_CONFIG_PATH;
  const configPath = expandRuntimePath(requestedPath);
  if (!existsSync(configPath)) {
    return Object.freeze({
      config: null,
      configPath,
      configStatus: "missing",
      documentPaths: null,
      enabled: false,
    });
  }
  const config = readBoundedJson(configPath, CONFIG_MAX_BYTES, "team-interface configuration");
  requireValid(validators.runtimeConfig, config, "team-interface configuration");
  assertUniqueIds(config.adapters, "adapter_id", "team-interface configuration");
  const configDirectory = dirname(configPath);
  const documentPaths = Object.fromEntries(
    Object.entries(config.documents).map(([key, value]) => [key, expandRuntimePath(value, configDirectory)]),
  );
  return Object.freeze({
    config,
    configPath,
    configStatus: "loaded",
    documentPaths: Object.freeze(documentPaths),
    enabled: config.enabled,
  });
}

export function loadRuntimeDocuments(configLoad, options = {}) {
  if (!configLoad.config || !configLoad.enabled) return null;
  const validators = validatorsFor(options.validators);
  const maxBytes = configLoad.config.options.max_document_bytes;
  const registry = readBoundedJson(configLoad.documentPaths.registry_path, maxBytes, "provider registry");
  const policy = readBoundedJson(configLoad.documentPaths.policy_path, maxBytes, "ownership policy");
  const appTeam = readBoundedJson(configLoad.documentPaths.app_team_path, maxBytes, "app-team manifest");
  requireValid(validators.registry, registry, "provider registry");
  requireValid(validators.ownershipPolicy, policy, "ownership policy");
  requireValid(validators.appTeam, appTeam, "app-team manifest");
  return Object.freeze({appTeam, policy, registry});
}
