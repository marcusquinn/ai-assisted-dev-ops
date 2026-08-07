<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Team-interface core contracts

The team-interface core is the provider-neutral boundary between provider
adapters, policy brokers, and consumers. Version 1 is defined by
`schemas/team-interface/core-v1.schema.json` and supports closed `registry` and
`event` documents. The read-only executable surface is defined by
`schemas/team-interface/runtime-v1.schema.json` and
`reference/team-interface-runtime.md`. The existing Matrix bot now uses the
core event contract and static `adapter.matrix`; direct aidevops and other
provider runtimes remain separate until their own bounded adapter leaves.

## Ownership and configuration

Dedicated versioned team-interface documents are authoritative for providers,
accounts, identities, resources, capabilities, and normalized events. Runtime
selection lives in `~/.config/aidevops/team-interface.json`, using
`configs/team-interface-config.json.txt` as the disabled template. It contains
only enablement, document paths, registered adapter IDs, settings references,
and bounded runtime options. Rich provider or team state does not belong in the
runtime config or `config.jsonc`.

The core owns normalized identifiers, capability declarations, resource
relationships, verified actor context, requested authority, and event
correlation. Adapters own provider-specific extraction and preserve raw source
evidence outside the core. Policy brokers supply verified actor and authority
inputs. Model output cannot mint, widen, or replace either input.

Credentials are references only. `credential_ref` and `secret_ref` identify
values held in approved secret storage; neither adapters nor documents place a
token, password, private key, credential value, or secret value in this
contract.

## Identifiers and labels

- Stable internal IDs survive provider renames and are used for joins,
  authorization, correlation, and ownership.
- A provider's opaque external ID is retained exactly as observed. Consumers
  must not parse it or infer authority from its shape.
- Display labels are non-authoritative presentation fields. A display name
  cannot establish identity, ownership, or permission.
- Provider and adapter versions describe observed software. `schema_version`
  independently selects normalized contract semantics.
- Event retries reuse the provider event ID, stable event ID, correlation ID,
  and idempotency key.

## Capabilities and compatibility

Capability negotiation starts from each provider's declared resource kinds,
operations, availability, and owner-review requirement. An unavailable,
unknown, degraded, or unsupported capability never broadens authority.

Compatibility detail belongs to a separate versioned document. The core carries
only a bounded state, stable reference, and optional human-readable summary so
consumers can fail closed while resolving richer evidence independently.

## Events and extensions

Inbox and outbox events use the same normalized envelope. It records provider
and event lineage, immutable deduplication inputs, a verified actor, explicit
targets, bounded content and attachment metadata, requested operation,
broker-supplied authority scope, trust and scan evidence references, and
occurrence time. Persistence must validate the complete document first.

Every object is closed except the explicitly bounded scalar metadata maps.
Provider-specific fields are not schema extensions: adapters preserve them as
opaque source evidence referenced by stable evidence identifiers. Adding a core
field requires a new compatible schema version or an explicit migration plan;
unknown versions and unknown properties are rejected rather than reinterpreted.
