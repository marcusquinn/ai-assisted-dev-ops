<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Team-interface reconciliation

`schemas/team-interface/reconciliation-v1.schema.json` defines the provider-neutral
ownership, three-way reconciliation, concurrency, receipt, retirement, and
rollback contract. It is a record format, not an apply implementation. Provider
adapters, desired-state planners, and review UIs must validate records against
the schema before using them to authorize a mutation.

## Identity and non-adoption

Resources bind the core contract's canonical `resource_id`, `provider_id`,
`community_id`, and opaque `provider_external_id`. `match_basis` is always
`stable_ids`. A display label may be shown to an owner, but it never identifies,
matches, creates ownership for, or adopts a provider record.

An existing record without a verified management owner and manager marker is
unmanaged even when its label or content resembles desired state. The planner
emits `review_required` with `unmanaged_resource` drift evidence. It must not
infer ownership, manufacture last-applied state, or backfill a marker from a
name match.

## Ownership policy

Each versioned policy maps a normalized JSON Pointer to one ownership class:

- `user_owned`: preserve the freshly observed value. Show desired differences,
  but do not mutate the field.
- `managed`: apply desired state only while actual still equals last-applied.
  A difference means the user or provider modified the field, so preserve actual
  and record drift evidence.
- `security_required`: apply a safe desired change only while actual equals
  last-applied. Drift requires review or execution disablement; preserving or
  overwriting the drift silently is forbidden.

Unknown fields always require review. A desired document does not grant
ownership of unlisted provider fields. Policy versions are immutable inputs to
a plan; changing policy produces a new observation and plan. Policy rules,
observed fields, decisions, receipt effects, and rollback fields each contain at
most one record per JSON Pointer. The planner rejects duplicate paths rather
than allowing order or map conversion to choose an owner.

Sensitive fields carry approved secret references and digests only. Values,
tokens, passwords, private keys, and credential material are never valid
reconciliation data or audit evidence.

## Three-way decision algorithm

For every field, the planner binds desired, last-applied, and freshly observed
actual snapshots to a policy rule. It then makes exactly one deterministic
decision:

| Ownership and state | Decision | Reason |
|---|---|---|
| User-owned | `preserve_actual` | `user_owned` |
| Managed; actual equals last-applied; desired differs | `apply_desired` | `managed_unchanged` |
| Managed; desired already equals actual | `no_change` | `already_desired` |
| Managed; actual differs from last-applied | `preserve_actual` | `user_modified` |
| Security-required drift | `review_required` or `disable_execution` | `security_drift` |
| Missing ownership or last-applied identity | `review_required` | `unmanaged_resource` |

The plan references the exact reconciliation input. Resource identity,
management owner and marker, policy/adapter versions, observation hash/time,
field ownership, sensitivity, and all three digests must match that input. The
two equality flags are derived from the digests and cannot be trusted as caller
assertions. Every observed field has exactly one decision, including unknown and
security-required fields; omission cannot bypass review or disablement. An
adapter receives the resulting decision; it does not reinterpret ownership or
move security policy into the provider-specific implementation. Future review
UIs expose these decisions, reason codes, and redacted evidence but cannot turn
a review/disable decision into apply authority.

## Capability negotiation

Capability evidence covers stable external IDs, managed metadata, supported
apply semantics, and provider revision/ETag compare-and-swap. Every unattended
`create`, `update`, `disable`, `retire`, or `rollback` plan requires all four,
`compatible` status, and evidence whose observation/expiry interval includes
the apply time.

If any capability is absent, stale, unknown, or incompatible, the only safe
outcomes are `owner_reviewed_draft` or `unsupported`. A draft is an artifact for
an owner to review in the provider's supported workflow; it is not simulated
unattended apply. Unknown schema, policy, adapter, or provider versions fail the
same way.

## Concurrency and replay

Before apply, re-read the resource by stable identity. Verify all of these
bindings against the exact plan:

1. immutable `plan_hash` and `operation_id`;
2. canonical resource, provider, community, and external IDs;
3. desired, policy, and adapter versions;
4. expected revision or ETag, observation hash, and observation time;
5. verified actor and authorization references;
6. correlation and idempotency keys; and
7. plan expiry.

Any mismatch or expiry is `conflict` with no side effect. Re-observe and create
a new plan. Never refresh only the expected revision on an old payload.

The same operation ID and plan hash may return its recorded receipt. Reusing an
operation ID or idempotency key with a different plan hash is a hard conflict.
`plan_hash` is SHA-256 over canonical JSON for the complete plan after removing
only the `plan_hash` member: object keys are recursively sorted, array order is
preserved, and JSON scalar encoding is unchanged. Any payload change therefore
requires a new hash. Do not blindly retry timeouts, transport failures, partial
writes, or ambiguous provider responses. Read after write by stable identity,
record the observed outcome, and replan.

Providers without atomic apply may produce per-field effects. `partial` and
`indeterminate` receipts are non-success states and require read-after-write
reconciliation. They must not be relabelled published because some fields
changed. Atomicity boundaries are per provider and community; a receipt cannot
claim a cross-provider transaction.

## Receipts and failure states

Every apply attempt records before/after revisions and digests, exact field
outcomes, provider receipt and evidence references, timestamps, and redacted
audit evidence. Durable states are:

- `published`: the effect and evidence are verified;
- `retryable`: no contradictory effect is known and bounded retry metadata can
  authorize a later attempt;
- `indeterminate`: an effect may exist; read-after-write is mandatory;
- `terminal`: rejected with evidence and no silent partial success;
- `conflict`: a CAS, expiry, identity, or replay binding failed; and
- `partial`: at least one field effect is incomplete or unknown.

A `published` receipt cannot contain an unknown field effect. `partial` and
`indeterminate` receipts contain at least one unknown effect and explicitly
require read-after-write reconciliation. Each planned field decision permits
only its corresponding effect (applied, preserved, unchanged, or disabled) or
an unknown ambiguous effect. `retryable`, `terminal`, and `conflict` receipts
use `not_applied` for every field and cannot claim a side effect. Receipt field
paths are unique so rollback never resolves contradictory evidence by order.

Recovery begins from a fresh observation. It never assumes that an error rolled
back provider state, repeats a create without stable-ID reconciliation, or
overwrites preserved user fields.

## Retirement

Removal from desired state produces a reviewed `disable`, `archive`, or `detach`
directive. Stable internal and external identity, receipts, and audit history
remain attached to the retired record. Automatic delete is not an outcome or
retirement action and cannot be represented by the schema.

An adapter may expose a provider-native delete operation for unrelated manual
work, but a reconciliation plan never authorizes it. Retirement requires the
same fresh observation, expected revision/ETag, capability evidence, owner
review reference, and immutable plan binding as other mutations.

## Rollback

Rollback is a new CAS-guarded plan, not a blind rewind. It references a verified
`published` receipt and before-state snapshot, binds the receipt's plan hash and
after revision, and restores only fields that are still `managed` under the
current policy. User-owned, user-modified, unknown, and security-drift fields
are excluded and require a new reconciliation decision.

Before rollback, re-read the same stable resource and verify that current state
still matches the receipt-bound precondition. A mismatch is conflict and replan.
Rollback retains identity and cannot delete, recreate, or resurrect an ambiguous
record. Provider/community rollback boundaries are explicit: successful work in
one boundary does not imply rollback or success in another.

## Audit and redaction

Plans and receipts carry verified actor, authorization, operation, correlation,
provider evidence, and audit references. Evidence is append-only and redacted;
it records digests and approved references instead of secret or unrestricted
provider payloads. Audit views may resolve display labels for presentation only
after stable identity is established.

Security drift, capability fallback, conflict, partial, indeterminate,
retirement, and rollback all remain visible terminal or recovery states. UI
code presents those facts and requests owner decisions; it does not duplicate
or weaken the schema and planner's security rules.

## Validation

Run the focused contract test before integrating a planner or adapter:

```bash
node .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs
```

The fixtures cover every field decision, missing capabilities, stable-ID-only
matching, stale/expired plans, operation-hash conflicts, ambiguous receipts,
reviewed retirement, receipt-bound rollback, automatic-delete rejection, and
redacted audit evidence.
