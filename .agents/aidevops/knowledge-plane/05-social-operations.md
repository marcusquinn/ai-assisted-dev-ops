<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Social Corpus Operations

Social collection is read-only and follows a fixed order: official API, account
archive, then browser-gap capture. A browser artifact is not accepted merely
because it is available; an explicit private gap record must first identify a
provider stream whose API/archive coverage is partial or unavailable.

## Provider extension contract

Each provider manifest is private mode-0600 JSON. Contract version 1 requires:

- an opaque `provider` ID and unique provider-neutral `streams`;
- `collection_routes` exactly `api`, `archive`, `browser_gap` in that order;
- an empty `write_operations` array;
- `browser_gap.read_only` and `browser_gap.checkpointed` set to `true`.

Validate a manifest before implementation or collection:

```bash
knowledge-social-helper.sh provider-validate --manifest provider.json
```

Provider adapters normalize records into the existing account, object, activity,
media, coverage, and raw-batch schema. Provider-only fields remain inside
`provider_json`. New adapters must preserve opaque local connection IDs, reject
credential-shaped fields, use independent stream checkpoints, expose hard cost
budgets, and add pagination, terminal-failure, replay, and write-reachability
tests. No provider may add engagement or other platform mutations.

## Approval-bound account operations

Outbound account operations are a separate owner-only subsystem; they do not
expand the read-only collector or provider-manifest contract. The authenticated
alias must grant `knowledge.manage`, which encrypted sharing reserves for the
workspace owner. Recipient `knowledge.read` and `knowledge.write` grants never
become posting authority.

Create a draft from a mode-0600 UTF-8 body file, then approve its exact immutable
intent. Omit `--scheduled-at` for an immediately due operation:

```bash
knowledge-social-helper.sh operation-create --alias workspace:example \
  --connection-id CONNECTION_ID --account-id ACCOUNT_ID --action post \
  --body-file approved-post.txt --scheduled-at EPOCH \
  --app PROFILE --username HANDLE

knowledge-social-helper.sh operation-approve --alias workspace:example \
  --operation-id OPERATION_ID --expires-at EPOCH
```

The intent binds the operation ID, connection, stable account ID, action, target,
body digest, local app/account selectors, schedule, creator, and provider. Reply
uses `--target-id POST_ID --body-file FILE`; like and bookmark use only
`--target-id POST_ID`. Revoke approval or cancel before a claim with
`operation-revoke` or `operation-cancel`.

A private routine may invoke the bounded due runner:

```bash
knowledge-social-helper.sh operations-run-due --alias workspace:example \
  --executor-id EXECUTOR_ID --claim-seconds 300 --limit 10
```

Each runner atomically claims an operation, verifies `xurl whoami` against the
approved stable account immediately before execution, records a durable provider
boundary, and invokes only mapped `post`, `reply`, `like`, or `bookmark` helper
commands. Competing runners cannot create another local attempt. Any timeout,
non-zero exit, malformed receipt, or executor loss after the provider boundary is
`unknown`, never retryable. Resolve it only after external verification:

```bash
knowledge-social-helper.sh operation-reconcile --alias workspace:example \
  --operation-id OPERATION_ID --outcome succeeded --provider-id POST_ID
```

Use `--outcome not-sent` without a provider ID only when verification proves the
write was not accepted. `operations-list` returns bounded, content-free receipt
metadata; it never returns body text, handles, profile names, or raw provider
responses.

## Mention and reply workflow

Notification projection is a mutable local overlay on immutable mention/reply
evidence. Refreshing is idempotent and never resets an existing workflow state:

```bash
knowledge-social-helper.sh notifications-refresh --alias workspace:example
knowledge-social-helper.sh notifications-list --alias workspace:example \
  --status action-required --limit 100
knowledge-social-helper.sh notification-set --alias workspace:example \
  --notification-id NOTIFICATION_ID --status responded
```

Supported states are `unread`, `seen`, `action-required`, `responded`, and
`dismissed`. Listings contain only opaque notification metadata. Drafts,
approvals, attempts, local profile selectors, receipts, and notification workflow
state remain owner-local: shared snapshots neither export nor erase them during a
restore.

## Bounded browser-gap capture

Browser execution remains outside the corpus helper and uses an approved private
profile through the Reach contract. Export only a sanitized mode-0600 JSON
artifact. The importer cannot launch a browser, submit a form, or reuse cookies.

The private gap record identifies `provider`, `stream`, `status` (`partial` or
`unavailable`), `official_routes_exhausted: true`, a sanitized `reason`, and
`observed_at`, and the tested `selector_version`. The capture identifies the same
scope and selector version, opaque connection/account IDs, `read_only: true`,
`checkpoint`, `observed_at`, completion state, and provider-neutral records.

```bash
knowledge-social-helper.sh capture-browser-gap \
  --manifest provider.json --gap gap.json --capture capture.json \
  --max-items 100 --max-bytes 1048576
```

The limits are hard stops. Interrupted captures retain their external checkpoint
and record paused coverage. Replaying the same canonical artifact returns the
same content-addressed batch and does not duplicate objects. Selector drift,
authentication loss, CAPTCHA, or a changed account scope stops that route; it
does not authorize a profile, proxy, or identity change.

## Operator verification

Before enabling a routine:

1. Confirm the corpus alias resolves only for the authenticated principal.
2. Run API/archive coverage and record the exact remaining stream gap.
3. Validate the provider manifest and dry-run the browser extraction manually.
4. Import one bounded artifact, then replay it to prove idempotency.
5. Inspect coverage, receipts, and citations without printing handles, paths, or
   raw private content.
6. Verify request budgets and terminal rate-limit state remain unchanged by the
   browser route; browser capture never disguises provider API cost.
7. For outbound use, verify exact approval expiry, X stable-account identity, and
   the private due routine before enabling it.
8. Run corpus, social-store, operation, query, sync, sharing, provider, and
   browser-gap tests.

Shared deployments remain limited to the tested encrypted grant/distribution
contract. Revocation must be verified before cached results are served. Combined
personal/workspace retrieval runs on the authorized user device, and public
diagnostics contain neither private content nor local paths.
