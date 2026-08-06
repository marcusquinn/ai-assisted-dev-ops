<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Team-interface read-only runtime

The version 1 runtime loads provider-neutral documents, invokes only trusted
in-tree read adapters, persists validated local observations, and generates
deterministic reconciliation plans. It does not install providers or expose an
apply, create, update, delete, send, invite, moderation, or publication route.

The initial static registry is intentionally empty. The Buzz and Matrix feature
leaves add adapters after this core contract merges.

## Commands

Run the deployed helper or its repository source:

```bash
~/.aidevops/agents/scripts/team-interface-helper.sh providers
~/.aidevops/agents/scripts/team-interface-helper.sh detect
~/.aidevops/agents/scripts/team-interface-helper.sh status
~/.aidevops/agents/scripts/team-interface-helper.sh doctor
~/.aidevops/agents/scripts/team-interface-helper.sh plan --request plan-request.json
```

| Command | Reads | Writes |
|---|---|---|
| `providers` | Static registry and runtime selection | Nothing |
| `detect` | Configured documents and adapter `detect()` methods | Validated local observation state only |
| `status` | Persisted state and adapter `status()` methods | Nothing |
| `doctor` | Config, documents, registry, and persisted-state validity | Nothing |
| `plan` | Explicit plan request and configured ownership policy | Nothing; emits a reconciliation plan |

Output is canonical JSON. The helper rejects every command outside this set
before invoking Node.

## Configuration and documents

The default working config is `~/.config/aidevops/team-interface.json`.
`AIDEVOPS_TEAM_INTERFACE_CONFIG` overrides it. Copy
`configs/team-interface-config.json.txt` to start from a valid disabled config.

The closed `runtime_config` document contains:

- an explicit `enabled` flag;
- paths to one core registry, ownership policy, and app-team manifest;
- registered adapter IDs paired with `settings:` references; and
- bounded document, plan, observation, adapter-read, and lock options.

Relative document paths resolve from the config directory; `~/` paths resolve
from the current home directory. Inputs are opened once without following a
final symlink, checked by descriptor identity and type, read to one byte beyond
their configured limit, and validated before use. Unknown fields, executable
module paths, dynamic adapter imports, non-`settings:` adapter references, and
inline credential values fail closed. Provider inventory output omits settings
references. A missing config is reported as a diagnosed disabled runtime rather
than inferred configuration.

The deployed runtime imports Ajv from `.agents/package.json`. Setup installs the
exact version and transitive integrity set in `.agents/package-lock.json`, then
compiles the runtime validators before a candidate runtime bundle can activate.

## Adapter contract

`.agents/scripts/team-interface-adapters.mjs` is the only adapter registry. The
core entrypoint composes focused config, validation, adapter, state/lock,
planning, and command modules from the same scripts directory; those modules do
not add another registry or executable loading path. Each tracked adapter
supplies:

- stable `adapter_id` and `provider_id` values;
- an `adapter_version`;
- bounded read-only capability declarations; and
- asynchronous `detect(context)` and `status(context)` methods.

The registry rejects unknown properties, duplicate adapter or capability IDs,
missing methods, undeclared executable methods, and mutation-shaped exports.
Capabilities are closed declarations and may contain only `discover`, `read`,
and `receive` operations. Validated definitions and their nested capability
values are frozen before registration. Runtime config selects a registered ID;
it cannot supply a path to executable code.

Adapter context is deeply frozen and contains validated documents, a settings
reference, and `read_only: true`. It provides no filesystem writer, credential
resolver, provider client, or mutation callback. Returned observations must
validate as closed `adapter_observation` documents and must retain the adapter's
registered identity and complete unique capability-ID set, including capability
operations, resource kinds, and review policy. Every adapter read has a bounded
timeout and receives an abort signal that trusted adapters must pass to their
underlying I/O. A pre-frozen adapter definition is still recursively frozen so
a mutable nested capability cannot bypass registration-time validation.

## Local state and locking

`AIDEVOPS_STATE_DIR` defaults to `~/.aidevops/state`. Runtime state is stored at
`team-interface/state-v1.json` below that root. The directory is mode `0700` and
the JSON state plus lock are mode `0600`.

`detect` is the only command that writes state. It validates the complete next
document before locking, then:

1. acquires an exclusive bounded lock;
2. verifies the expected generation under the lock;
3. writes and fsyncs a private temporary file;
4. atomically renames it and fsyncs the directory; and
5. releases only the lock token it owns.

A stale lock is reclaimed only after both its configured age threshold and
same-host process-liveness evidence prove the recorded owner is gone. Reclaimers
serialize through a separate marker and re-read the exact owner token before
renaming, so a delayed contender cannot remove a replacement owner's lock. A
live, remote-host, malformed, ambiguous, or concurrently reclaimed owner is
never deleted. Generation drift is a conflict and preserves the prior state.

When one adapter fails, a successful peer observation may advance state while
the failing adapter's prior valid observation is preserved only when its
adapter/provider/version and capability declaration still match the registered
definition. An upgraded or changed definition never inherits stale capability
evidence. If every adapter fails, no state write occurs. `status`, `doctor`, and
`plan` never create or modify state. An explicit empty adapter selection clears
stale persisted observations on the next `detect`; status output never exposes
observations for adapters that are no longer selected.

## Deterministic planning

A `plan_request` embeds one version 1 reconciliation input plus capability,
precondition, actor, authorization, creation, expiry, and redacted audit
evidence. The planner binds the resource identity and management owner to the
configured provider registry, binds the policy to the registered resource kind,
and requires every configured policy field to appear in the input. It then
derives exactly one decision per field using
`reference/team-interface-reconciliation.md`. JSON Schema `date-time` fields
receive strict calendar validation rather than being treated as unchecked
strings.

Set-like field and evidence arrays are normalized with locale-independent code
unit ordering before hashing. The canonical request SHA-256 determines plan,
operation, correlation, and idempotency IDs.
Request-supplied evidence times and actor, authorization, and audit references
are preserved. Capability evidence must cover the full plan lifetime, field and
audit observations cannot postdate plan creation, and managed or
security-required fields must include a present last-applied snapshot. Missing
required evidence fails closed rather than inferring a baseline. Capability gaps
produce `owner_reviewed_draft` or `unsupported`; security drift may produce
`disable`; unmanaged or unknown fields produce `review`; applicable managed
changes produce `update`; otherwise the outcome is `no_change`.

`plan_hash` is SHA-256 over recursively key-sorted canonical JSON after removing
only `plan_hash`. Identical semantic requests replay byte-for-byte. Any material
request change produces different stable IDs and a different hash.

The request supplies capability, actor, authorization, audit, and management
marker evidence because this version is a non-mutating planner, not an authority
broker. Its output is a dry-run artifact, never apply authorization. A future
provider-write implementation must re-read the provider and verify every
identity, capability, authority, CAS, expiry, and plan-hash binding required by
`reference/team-interface-reconciliation.md` before any effect.

## Diagnostics and recovery

Errors expose bounded codes and messages, never file contents or unrestricted
provider payloads. Adapter/provider exceptions become fixed runtime-owned
messages; only runtime validation categories are retained. Other diagnostics
redact home-directory prefixes and credential-shaped assignments, replace
control characters, and limit messages to 500 characters. Diagnostic codes are
limited to stable 1-100 character identifiers. Invalid config, schema, lock,
adapter, state, policy, or planning input leaves the last valid state untouched.

Repair the specific diagnosed input and rerun the read or plan command. Unknown
schema versions and malformed historical state require explicit operator repair;
version 1 performs no inferred migration or provider cleanup.

## Verification

```bash
node .agents/scripts/tests/test-team-interface-runtime.mjs
node .agents/scripts/tests/test-team-interface-core-schema.mjs
node .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs
.agents/scripts/tests/test-team-interface-runtime-deps.sh
bash -n .agents/scripts/team-interface-helper.sh
shellcheck .agents/scripts/team-interface-helper.sh
.agents/scripts/linters-local.sh --changed
```
