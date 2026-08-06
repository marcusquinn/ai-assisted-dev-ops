// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {readFileSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import {TeamInterfaceError} from "./team-interface-common.mjs";

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const SCHEMA_DIRECTORY = resolve(SCRIPT_DIRECTORY, "../schemas/team-interface");
const DATE_TIME_PATTERN = /^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|[+-](\d{2}):(\d{2}))$/;

let defaultValidators;

function schemaFile(schemaDirectory, filename) {
  return JSON.parse(readFileSync(join(schemaDirectory, filename), "utf8"));
}

function validDateTime(value) {
  const match = DATE_TIME_PATTERN.exec(value);
  if (!match) return false;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const offsetHour = match[7] ? Number(match[7]) : 0;
  const offsetMinute = match[8] ? Number(match[8]) : 0;
  const maximumDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return [
    month >= 1,
    month <= 12,
    day >= 1,
    day <= maximumDay,
    hour <= 23,
    minute <= 59,
    second <= 59,
    offsetHour <= 23,
    offsetMinute <= 59,
    Number.isFinite(Date.parse(value)),
  ].every(Boolean);
}

export function createRuntimeValidators(schemaDirectory = SCHEMA_DIRECTORY) {
  const coreSchema = schemaFile(schemaDirectory, "core-v1.schema.json");
  const reconciliationSchema = schemaFile(schemaDirectory, "reconciliation-v1.schema.json");
  const appTeamSchema = schemaFile(schemaDirectory, "app-team-v1.schema.json");
  const runtimeSchema = schemaFile(schemaDirectory, "runtime-v1.schema.json");
  const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: true});
  ajv.addFormat("date-time", {type: "string", validate: validDateTime});
  for (const schema of [coreSchema, reconciliationSchema, appTeamSchema, runtimeSchema]) ajv.addSchema(schema);
  const runtimeId = runtimeSchema.$id;
  const reconciliationId = reconciliationSchema.$id;
  return Object.freeze({
    adapterObservation: ajv.compile({$ref: `${runtimeId}#/$defs/adapter_observation_document`}),
    appTeam: ajv.getSchema(appTeamSchema.$id),
    ownershipPolicy: ajv.compile({$ref: `${reconciliationId}#/$defs/ownership_policy_document`}),
    plan: ajv.compile({$ref: `${reconciliationId}#/$defs/reconciliation_plan_document`}),
    planRequest: ajv.compile({$ref: `${runtimeId}#/$defs/plan_request_document`}),
    registry: ajv.compile({$ref: `${coreSchema.$id}#/$defs/registry_document`}),
    runtime: ajv.getSchema(runtimeId),
    runtimeConfig: ajv.compile({$ref: `${runtimeId}#/$defs/runtime_config_document`}),
    runtimeState: ajv.compile({$ref: `${runtimeId}#/$defs/runtime_state_document`}),
  });
}

export function validatorsFor(value) {
  if (value) return value;
  defaultValidators ||= createRuntimeValidators();
  return defaultValidators;
}

function validationMessage(validate) {
  return (validate.errors || [])
    .map((error) => `${error.instancePath || "<root>"} ${error.keyword}: ${error.message}`)
    .join("; ");
}

export function requireValid(validate, value, label) {
  if (!validate(value)) {
    throw new TeamInterfaceError("invalid_document", `${label} failed validation: ${validationMessage(validate)}`);
  }
  return value;
}
