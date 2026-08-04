<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Team-interface ingress trust and authority

The version-1 contract at
`.agents/schemas/team-interface/trust-v1.schema.json` separates four inputs that
must not be collapsed into one trusted/untrusted flag:

1. verified actor identity and configured role grants;
2. content provenance;
3. attachment risk and extraction evidence; and
4. the requested operation and capability class.

It references `urn:aidevops:team-interface:core:v1` for stable IDs, verified
actors, capability operations, and attachment metadata. Provider adapters must
not duplicate or reinterpret those definitions. This contract defines records
only; it does not grant tools, scan content, extract files, or write a cache.

## Canonical profiles

All profiles enforce signature/provenance, schema, size/type/path, correlation,
idempotency, and output-secret controls. These structural controls are mandatory
even when semantic scanning is not required.

| Profile | Minimum screening | Default capability ceiling |
|---|---|---|
| `owner-local` | Structural controls. Deterministic and semantic scans are conditional for ordinary direct text, but suspicious encoding, forwarded content, unknown provenance, external attachments, findings, or elevated operations trigger stronger policy. | Configured owner operations. Administrator, secret, destructive, billing, publication, and release work requires its own explicit gate. |
| `trusted-team` | Structural controls plus a cached deterministic prompt-pattern scan. Findings, external attachments, and elevated operations trigger semantic escalation. | Configured role operations and non-administrator operations only. |
| `shared-member` | Deterministic scanning before model use, broker-enforced action scope, and sandboxed extraction when content must be read. | Read, answer, and draft by default; explicitly configured non-administrator operations are the maximum. |
| `external-bridged` | Strict deterministic scanning or quarantine, bounded content, isolated attachments, and explicit external provenance. | Read or draft only. Privileged work requires a separate trusted, authorized job. |

`owner-local` may skip semantic scanning only for ordinary direct text. Forwarded
or external content, attachments, suspicious encoding, and elevated operations
re-enter the stronger path. Internal signatures reduce scanning overhead but do
not skip structure, authority, idempotency, or output-secret checks.

## Deterministic evaluation order

An ingress adapter and authority broker evaluate one event in this order:

1. Verify signature and provenance, then validate the core event schema,
   content bounds, paths, media types, correlation ID, and idempotency key.
2. Resolve the verified actor, membership, and configured roles. Display labels
   and membership alone are not grants.
3. Derive exactly one trust profile from verified policy inputs.
4. Calculate required deterministic, semantic, and attachment stages from the
   profile, provenance, findings, attachments, and requested capability.
5. Validate a complete cached verdict key or create a new immutable verdict.
6. Intersect the requested capability with configured role grants and the
   profile/policy ceiling. The decision records immutable policy and role-config
   references; apply an explicit gate for every high-risk class.
7. Emit one deterministic `allow`, `deny`, `review`, or `quarantine` decision
   with reason codes and audit references.
8. Run the output-secret guard before any response or side effect leaves the
   broker.

Scanning supplies content-risk evidence; it never supplies authority. A model
may explain a decision but cannot add roles, grants, ceilings, gate references,
or model-proposed scopes to the authority input.

## Verdict cache and invalidation

A verdict is reusable only when all of these key components match exactly:

- content digest;
- sorted attachment digests;
- provider ID and provenance class;
- trust profile ID;
- scanner engine and scanner version;
- policy version; and
- requested capability class.

Changing any component creates a different key and prevents stale fallback.
Writers must publish the complete key and all stage evidence atomically. Partial
stage results are never visible as `clean`. A policy rollback may reuse older
evidence only when every key component still matches. Scanner errors are not
cacheable terminal success; retries remain fail-closed until a new terminal
verdict is recorded.

Each verdict records structural, deterministic, semantic, and attachment stages
as `not_required`, `not_run`, `clean`, `findings`, `quarantined`, or `error`.
`not_required` is an explicit policy result, not an omitted stage. `not_run`,
`findings`, `quarantined`, and `error` cannot support `allow`.

For `allow`, structural evidence is always `clean`. Deterministic evidence is
also `clean` for every non-owner profile and whenever owner-local provenance is
not direct, an attachment is present, or a high-risk capability is requested.
Semantic evidence is `clean` for forwarded/external provenance, attachments,
external-bridged ingress, and elevated capabilities. Attachment evidence is
`clean` whenever attachment digests are present. A stage may be `not_required`
only when the selected profile and event inputs do not require it.

An ingress decision binds both the immutable verdict reference and the complete
verdict key. Before use, the broker resolves that reference and requires the
stored key and result to match the decision's copied key/result exactly. It also
matches provenance, profile, policy version, requested capability, provider,
content digest, and attachment digests against the event fingerprint copied from
the validated normalized core event. The adapter computes that fingerprint; a
model cannot supply or alter it. An unresolved reference or any mismatch is
stale evidence and cannot authorize the event.

## Attachment handling

Preflight records the core attachment metadata, source provenance, digest match,
path and type checks, active-content, executable, archive, and macro flags.
Extraction occurs only in a referenced sandbox. No profile permits an
owner-trust bypass.

An unsafe attachment is quarantined or rejected; it is never accepted because
the actor is an owner. Active documents, executables, archives, macros, unsafe
paths or types, and mismatched digests force `quarantine` or `reject`. Sandbox,
scanner, or digest failures preserve the original attachment and fail the event
closed without exposing partial extraction as clean evidence.

## Authority ceilings and negative privilege rules

Final authority is the intersection of:

1. a capability granted to one of the verified actor's configured roles;
2. the declared capability ceiling; and
3. an explicit gate when the capability is administrator, secret access,
   destructive, billing, publication, or release.

Membership, display labels, clean scanning, attachment acceptance, and model
suggestions cannot widen that intersection. Shared and external profiles cannot
carry high-risk capability classes in their ceilings. A clean scan for a request
outside configured authority still produces `deny` or `review`.

Every configured grant carries the same immutable role-configuration reference
as its decision. The broker resolves that reference, confirms the grant's role
belongs to the verified actor, confirms every granted capability appears in the
policy's role grant, and rejects copied, membership-derived, or model-derived
grants. The broker also resolves the policy reference, constrains the decision
ceiling to the selected profile ceiling, and accepts high-risk gate evidence
only from the policy's declared gate authority. Schema constraints bind each
`allow` to a matching grant, ceiling entry, clean scan result, accepted
attachments, and required high-risk gate; semantic validation resolves the
referenced records and rejects cross-record drift.

## Failure and compatibility behavior

- Scanner `error` produces `deny`, `review`, or `quarantine`, never clean/allow.
- Unknown provenance produces `deny`, `review`, or `quarantine`, never an owner default.
- An unsafe attachment produces `quarantine` or `deny`, never allow.
- Signature, schema, sandbox, policy lookup, authority resolution, output-secret,
  and malformed-event failures fail closed.
- Capability escalation without a configured grant, ceiling, and required gate
  produces `deny` or `review`.

Legacy or mixed-version records without a verified actor, known profile, policy
version, correlation/idempotency evidence, or verdict reference do not inherit
owner authority. Unknown schema and policy versions fail closed. Existing
prompt-guard, privacy-filter, Matrix, and Buzz behavior remains unchanged until
future adapters explicitly adopt this contract.

## Idempotency, audit, and recovery

The same normalized event, idempotency key, policy version, complete verdict key,
and requested capability reuses one terminal verdict and one authority decision.
Concurrent writers must publish complete immutable records atomically and select
the existing terminal record on an idempotency collision.

Every decision records the verified actor and roles, configured grants, profile,
provenance, requested operation/capability, ceiling, policy and role-config
references, explicit gates, scan verdict reference, bound verdict key/result,
event provider/content/attachment fingerprint, attachment decisions, reason
codes, policy version, correlation ID, idempotency key, timestamp, output-secret
result, and audit reference. Audit records contain references and digests, never
credential values or extracted secret material.
