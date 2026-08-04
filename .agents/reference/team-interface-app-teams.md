<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# App-Team Manifests

`.agents/schemas/team-interface/app-team-v1.schema.json` defines portable,
provider-neutral desired state for application teams. It references the stable
identity, capability, resource, and reference primitives in
`urn:aidevops:team-interface:core:v1`; it does not duplicate those records or
provision runtime state.

## Mode selection

| Mode | Select when | Mutable state | Publication identity |
|---|---|---|---|
| `dedicated` | A specialist is a long-lived member of one app team. | Unique identity, memory namespace, registered workspace roots, and approved secret references. | Specialist identity with the initiating actor in audit context. |
| `cloned` | A versioned specialist template is reused as a new long-lived app teammate. | The same isolation as dedicated mode, plus an immutable template-instance reference and `inherited_mutable_state: false`. | New clone identity with the initiating actor; never the source instance identity. |
| `shared` | A team invokes a reusable capability for one request. | Stateless; memory is `none` or request-scoped. Workspaces and credentials are supplied through scoped policies and brokers. | Caller/team identity, capability, and initiating actor. It is not a persistent teammate. |

Choose `shared` only when the result can be owned and published by its caller.
Choose `cloned` rather than `dedicated` when immutable template provenance is
part of the desired state. A runtime must not downgrade a persistent mode to a
shared process or upgrade a shared capability into a persistent teammate.

## Isolation and ownership

Dedicated and cloned specialists own their `identity_ref`,
`memory_namespace_ref`, and every `workspace_root_ref` within one app/team
scope. Those mutable references, manifest IDs, app IDs, team IDs, and instance
IDs must be unique across a validated manifest set. Cloning reuses only
versioned instructions and capabilities; signing identity, conversations,
memory, workspace, credentials, and mutable runtime state are always new.

Shared records prohibit persistent identity, memory namespaces, fixed app
workspace roots, direct team credentials, self-publication, and persistent
teammate representation. Every shared request retains `app`, `team`,
`community`, `project`, `actor`, and `audit` context. The caller owns the
result, while the audit trail also records the invoked capability.

The manifest is desired state, not an authority source. Display labels are
non-authoritative and cannot substitute for IDs, identity verification, actor
context, or policy decisions.

## Reference and discovery boundaries

- Use registered references such as `workspace-root:alpha` and
  `secret-ref:alpha-build`. Secret values and raw private host paths are never
  manifest data.
- Use `simple`, `standard`, or `thinking` workload tiers. Canonical agent
  discovery and runtime routing resolve current instructions, provider models,
  and reasoning variants; manifests must not contain concrete model or
  provider IDs.
- Pin each manifest and specialist template to a source reference, revision,
  and SHA-256 digest. Do not copy unversioned instructions into the manifest.
- Provider, community, resource, workspace, credential, trust, authority, and
  reconciliation references must resolve through their owning registries or
  brokers before mutation begins.
- Existing OpenCode, Matrix, Buzz, memory, and runtime configuration remain the
  canonical implementation surfaces. This schema does not generate agents or
  modify those systems.

## Publication and audit context

Persistent specialists publish as `specialist_with_actor`; the specialist is
accountable for its output and the initiating actor remains visible. Shared
capabilities publish as `caller`; they cannot create an independent signing or
display-name authority. Resource bindings identify registered targets, while
the authority policy decides whether an operation is allowed.

## Validation and failure behavior

Validate the complete manifest revision and all cross-document isolation
claims before provisioning anything. Reject the manifest as a unit when a
schema version is unknown, a stable reference is unresolved, a digest is
invalid, mutable state collides, shared request context is incomplete, or any
unknown property appears. Report the exact invalid reference or collision; do
not infer a display-name identity, global namespace, host path, concrete model,
credential, trust default, or partial fallback.

Validation and retries are side-effect free. Later planners must preserve the
manifest source revision and digest as idempotency inputs and roll back only
resources created by their own atomic operation. Removing this additive
contract never authorizes deletion of provider identities, memory, workspaces,
or credentials.

## Future composition

Trust profiles and authority behavior remain separate contracts referenced by
`trust_policy_ref` and `authority_policy_ref`. Field ownership and desired/live
state reconciliation remain separate and are referenced only by
`reconciliation_policy_ref`. Future roster generation, provider adapters, and
app APIs must compose those contracts and resolve all references before any
identity, team, namespace, workspace, or provider mutation.

Run the contract regression test with:

```bash
node .agents/scripts/tests/test-team-interface-app-team-schema.mjs
```
