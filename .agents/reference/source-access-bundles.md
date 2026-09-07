<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Issue and source approval bundles

A bundle combines one human decision with **two independent signatures**: the
existing development approval for an exact issue snapshot, and a V3 source-read
capability for an exact user, live runtime/session, linked worktree and file set.
An issue approval alone never permits protected-source reads.

## Prepare before asking for approval

From the intended OpenCode session, prepare metadata without signing, invoking
sudo, claiming the issue, or starting implementation:

```bash
interactive-start-helper.sh --issue <number> --repo <owner/repo> \
  --task "Implementation description" \
  --source-path .agents/scripts/example-helper.sh \
  --source-path .agents/scripts/tests/test-example-helper.sh
```

This validates/creates the intended linked worktree through the normal pre-edit
check. The runtime must independently recognize its owner and session. Explicitly
list the foreseeable source and regression-test set, not directories. Conventional
existing `tests/test-<source-basename>` files are also included by proposal
preparation. Other test naming conventions require explicit paths.

For an already established linked worktree, the metadata-only command is:

```bash
aidevops source-access propose --repo <owner/repo> --issue <number> \
  --session <session-id> --reason 'secret-bearing basename' \
  --path <exact-source-path> --path <exact-regression-test-path>
```

The runtime supplies `AIDEVOPS_SOURCE_CONTEXT_SOCKET`; it is only an endpoint
locator, not authority. The broker challenges its native peer and checks the
runtime instance, session creation/project identity and worktree ownership.
GitHub issue reads are read-only, bounded and authenticated as the owning user.
Neither proposal command prints source contents or authentication data.

## One human-owned ceremony

In an attached human terminal, **without prefixing the user-managed CLI with sudo**:

```bash
aidevops approve issue <number> <owner/repo> --source-proposal <proposal-id> --ttl 12h
```

Equivalent explicit command:

```bash
aidevops source-access approve-bundle <proposal-id> --repo <owner/repo> --issue <number> --ttl 12h
```

The user-space bridge invalidates inherited sudo and invokes only the installed
root-owned broker. The broker displays the issue snapshot digest, exact paths and
hashes, user/session/runtime, worktree/commit and lifetime. Type
`APPROVE ISSUE AND SOURCE` only after reviewing both scopes, including source files
for credential material. UTF-8/control and credential-indicator screening is
conservative; it is not proof that arbitrary text contains no secret. A content
finding cannot be overridden as a basename false positive.

Pending proposals contain metadata, not source contents or permission. Elapsed
age alone does not invalidate one. At attendance the broker revalidates the live
context and prepares the exact current scope for that confirmation. Changed bytes
or HEAD before confirmation are displayed with refreshed hashes; a different
runtime/session/worktree is not silently substituted. Changes after confirmation
fail closed. Grant lifetime starts at confirmation and is never renewed by retry.

The issue signature is posted once through the unprivileged GitHub wrapper and
then independently checked against trusted TLS issue reads and the issue key.
Only afterward may the separately signed source receipt and all immutable
snapshots become visible in one atomic directory publication.

## Recovery and withdrawal

- Retry the **same** approval command after a transport failure. A journaled
  uncertain comment publication is verified, never blindly posted again. If
  publication cannot be proven, source access stays withheld.
- A crash after atomic directory publication can reconcile the journal only
  after checking the exact receipt, signature, snapshots, consent and context.
- Cancellation or revocation wins over stale in-flight journal writers. A
  successful cancellation does not undo a separately published issue signature.
- A dead session, replaced runtime, removed worktree, changed identity or expired
  consent is non-actionable. Prepare a genuinely new context and obtain explicit
  consent; do not repeatedly regenerate short-lived legacy requests.
- The pending store is bounded to 128 records, 256 KiB each. Manifests contain at
  most 32 files and 10 MiB total. Withdraw unused metadata to free capacity.

```bash
aidevops source-access withdraw-proposal <proposal-id> # metadata only; preserves grants
aidevops source-access cancel-proposal <proposal-id>   # human terminal; cancels and withdraws its grant
aidevops source-access status
```

Cancellation is durable for that proposal ID. Withdrawal and a fresh proposal
are explicit new intent, not renewal of cancelled consent. Existing independent
approval commands and receipt schemas retain their original semantics.

## Deployment boundary and verification

The broker closure remains the two installed Python files provisioned from a
verified signed release. Never copy development files into the root installation
or execute user-writable helpers as root. Mixed/unsupported versions fail closed;
use existing separate approvals until compatible released components are
installed. Routine update never invokes sudo. Scoped broker setup remains an
explicit human operation, separate from feature implementation or merge.

Coverage: `tests/test-source-access-helper.py` exercises the transaction and
recovery with generated keys and fake GitHub data; the existing atomic V3 Node
fixture now calls the real issuer and native context IPC, then consumes that
receipt through both CLI verification and the composed Read hook. Existing
direct-edit provenance fixtures remain separate checks. Independent security
review and configured CI are required before merge.
