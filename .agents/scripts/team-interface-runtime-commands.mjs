// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {adapterMetadata, builtInAdapterRegistry, selectConfiguredAdapters} from "./team-interface-adapters.mjs";
import {invokeAdapterRead, observationMatchesAdapterDefinition} from "./team-interface-adapter-runtime.mjs";
import {canonicalJson, compareCanonicalText, expandRuntimePath, readBoundedJson, TeamInterfaceError} from "./team-interface-common.mjs";
import {loadRuntimeConfig, loadRuntimeDocuments} from "./team-interface-config.mjs";
import {diagnostic} from "./team-interface-diagnostics.mjs";
import {generatePlan} from "./team-interface-planner.mjs";
import {readRuntimeState, runtimeStatePaths, writeRuntimeState} from "./team-interface-state.mjs";
import {validatorsFor} from "./team-interface-validators.mjs";

function disabledResult(command, configLoad) {
  return {
    command,
    config_status: configLoad.configStatus,
    enabled: false,
    state_changed: false,
  };
}

function runtimeInputs(options) {
  const validators = validatorsFor(options.validators);
  const configLoad = loadRuntimeConfig({...options, validators});
  if (!configLoad.enabled) return {configLoad, validators};
  const registry = options.registry || builtInAdapterRegistry;
  const selections = selectConfiguredAdapters(configLoad.config, registry);
  const documents = loadRuntimeDocuments(configLoad, {validators});
  return {configLoad, documents, registry, selections, validators};
}

export function runProviders(options = {}) {
  const validators = validatorsFor(options.validators);
  const configLoad = loadRuntimeConfig({...options, validators});
  const registry = options.registry || builtInAdapterRegistry;
  const selections = configLoad.config ? selectConfiguredAdapters(configLoad.config, registry) : [];
  return {
    command: "providers",
    config_status: configLoad.configStatus,
    enabled: configLoad.enabled,
    registered: registry.values().map(adapterMetadata),
    selected: selections.map(({adapter}) => ({
      adapter_id: adapter.adapter_id,
      provider_id: adapter.provider_id,
    })),
  };
}

function selectedPriorObservations(priorState, selections) {
  const selectedAdapters = new Map(selections.map(({adapter}) => [adapter.adapter_id, adapter]));
  return new Map(
    (priorState?.observations || [])
      .filter((observation) => {
        const adapter = selectedAdapters.get(observation.adapter_id);
        return adapter && observationMatchesAdapterDefinition(observation, adapter);
      })
      .map((observation) => [observation.adapter_id, observation]),
  );
}

function sortedSelectedObservations(state, selections) {
  return [...selectedPriorObservations(state, selections).values()]
    .sort((left, right) => compareCanonicalText(left.adapter_id, right.adapter_id));
}

async function detectAdapterObservations(priorState, selections, documents, validators, timeoutMs) {
  const observations = selectedPriorObservations(priorState, selections);
  const errors = [];
  let successfulReads = 0;
  for (const selection of selections) {
    try {
      const observation = await invokeAdapterRead("detect", selection, documents, validators, {timeoutMs});
      observations.set(observation.adapter_id, observation);
      successfulReads += 1;
    } catch (error) {
      errors.push(diagnostic(error, selection.adapter.adapter_id));
    }
  }
  return {
    errors,
    observations: [...observations.values()].sort((left, right) => compareCanonicalText(left.adapter_id, right.adapter_id)),
    successfulReads,
  };
}

function persistDetectedObservations({observations, successfulReads, priorState, selections, inputs, paths, options}) {
  const {configLoad, validators} = inputs;
  const unchanged = canonicalJson(observations) === canonicalJson(priorState?.observations || []);
  const writeAllowed = successfulReads > 0 || selections.length === 0;
  if (!writeAllowed || unchanged) return {state: priorState, stateChanged: false};
  const expectedGeneration = priorState?.generation || 0;
  const nextState = {
    document_type: "runtime_state",
    generation: expectedGeneration + 1,
    observations,
    schema_version: 1,
    updated_at: options.now?.() || new Date().toISOString(),
  };
  const state = writeRuntimeState(nextState, {
    expectedGeneration,
    lockStaleMs: configLoad.config.options.lock_stale_ms,
    lockTimeoutMs: configLoad.config.options.lock_timeout_ms,
    paths,
    validators,
  });
  return {state, stateChanged: true};
}

export async function runDetect(options = {}) {
  const inputs = runtimeInputs(options);
  if (!inputs.configLoad.enabled) return disabledResult("detect", inputs.configLoad);
  const {configLoad, documents, selections, validators} = inputs;
  const paths = runtimeStatePaths(options.stateRoot);
  const priorState = readRuntimeState({paths, validators});
  const detected = await detectAdapterObservations(
    priorState,
    selections,
    documents,
    validators,
    configLoad.config.options.adapter_timeout_ms,
  );
  if (detected.observations.length > configLoad.config.options.max_state_observations) {
    throw new TeamInterfaceError("state_too_large", "adapter observations exceed configured state limit");
  }
  const persisted = persistDetectedObservations({
    observations: detected.observations,
    successfulReads: detected.successfulReads,
    priorState,
    selections,
    inputs,
    paths,
    options,
  });
  return {
    command: "detect",
    enabled: true,
    errors: detected.errors,
    generation: persisted.state?.generation || 0,
    observations: sortedSelectedObservations(persisted.state, selections),
    state_changed: persisted.stateChanged,
  };
}

export async function runStatus(options = {}) {
  const inputs = runtimeInputs(options);
  if (!inputs.configLoad.enabled) return disabledResult("status", inputs.configLoad);
  const {documents, selections, validators} = inputs;
  const paths = runtimeStatePaths(options.stateRoot);
  const priorState = readRuntimeState({paths, validators});
  const live = [];
  const errors = [];
  for (const selection of selections) {
    try {
      live.push(await invokeAdapterRead("status", selection, documents, validators, {
        timeoutMs: inputs.configLoad.config.options.adapter_timeout_ms,
      }));
    } catch (error) {
      errors.push(diagnostic(error, selection.adapter.adapter_id));
    }
  }
  live.sort((left, right) => compareCanonicalText(left.adapter_id, right.adapter_id));
  return {
    command: "status",
    enabled: true,
    errors,
    generation: priorState?.generation || 0,
    live,
    persisted: sortedSelectedObservations(priorState, selections),
    state_changed: false,
  };
}

export function runDoctor(options = {}) {
  try {
    const inputs = runtimeInputs(options);
    if (!inputs.configLoad.enabled) {
      return {
        ...disabledResult("doctor", inputs.configLoad),
        diagnostics: [{code: `config_${inputs.configLoad.configStatus}`, message: "team-interface runtime is disabled"}],
        ok: true,
      };
    }
    const state = readRuntimeState({stateRoot: options.stateRoot, validators: inputs.validators});
    return {
      command: "doctor",
      diagnostics: [],
      enabled: true,
      generation: state?.generation || 0,
      ok: true,
      selected_adapters: inputs.selections.map(({adapter}) => adapter.adapter_id),
      state_changed: false,
    };
  } catch (error) {
    return {
      command: "doctor",
      diagnostics: [diagnostic(error)],
      enabled: false,
      ok: false,
      state_changed: false,
    };
  }
}

export function runPlan(options = {}) {
  const inputs = runtimeInputs(options);
  if (!inputs.configLoad.enabled) throw new TeamInterfaceError("runtime_disabled", "team-interface runtime is disabled");
  if (!options.requestPath) throw new TeamInterfaceError("missing_request", "plan requires --request PATH");
  const requestPath = expandRuntimePath(options.requestPath);
  const request = readBoundedJson(
    requestPath,
    inputs.configLoad.config.options.max_document_bytes,
    "team-interface plan request",
  );
  return generatePlan(request, {
    maxPlanFields: inputs.configLoad.config.options.max_plan_fields,
    policy: inputs.documents.policy,
    registry: inputs.documents.registry,
    validators: inputs.validators,
  });
}
