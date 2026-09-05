<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Corrected blocked checkpoint recovery

An authorised brief owner may approve continuing a released worker draft after
correcting its brief. This is not permission to take over a live interactive
session, clear a sensitive-scope hold, or replace the existing PR.

## Approval and continuation

1. Read fresh issue/PR metadata and coordination comments. Verify the exact
   original worker attempt has released as `blocked`, no successor owns the
   objective, and the proposed scope correction preserves the authorised outcome.
   Check overlapping work. Revise the issue body first, using the managed wrapper.
2. Generate the exact approval line using the original ready lease's attempt ID
   and the blocked release comment's numeric ID:

   ```bash
   pr-checkpoint-continuation-helper.sh approval-template OWNER/REPO PR ISSUE RELEASE_COMMENT_ID attempt:ORIGINAL_ID
   ```

3. Publish that line as a new issue comment through `gh-write-helper.sh issue
   comment`, using the normal body-file discipline. The approving actor must
   currently have write, maintain or admin permission. Generating the template
   does not grant authority. Do not edit a published approval comment.
4. Pulse discovers it before generic draft/interactive dedup protection consumes
   the candidate. Explicit invocation uses:

   ```bash
   pr-checkpoint-continuation-helper.sh dispatch-approved OWNER/REPO REPO_PATH ISSUE AUTHENTICATED_RUNNER
   ```

The approval binds repository, issue, PR, exact head/ref, original runner and
attempt, release comment and SHA-256 of the complete corrected issue body. It
expires after 24 hours; changed body/head/actor permissions invalidate it. A
legacy release without a lease token is accepted only when its approved attempt
has a unique prior authenticated ready lease with no intervening attempt.

## Ownership guarantees

The revised path acquires the existing distributed claim/consensus lease before
assignment restoration, including an unassigned preserved checkpoint. Its claim
session matches the exact-PR worker session. Worker startup renews prelaunch and
then transitions ready; the producer must not prematurely transition ready.
Worker preparation and pre-push verification re-read the full approval, owner,
lease, brief and head envelope. A `For #N.` partial checkpoint is accepted only
for the approved pair with no conflicting structural closing links.

Failed launches compensate assignment/status only while that same live envelope
still owns the target, then terminate the lease. Newer human/worker evidence stops
compensation as well as takeover. An unchanged consumed approval is not retried;
reassess the new evidence and issue a fresh bounded approval when authorised.
Never forge `worker_draft_checkpoint` releases or remove the generic assignment
guard. A dispatch message proves launch initiation, not model startup or delivery.

## Aged objectives

Pulse check tracks creation age separately from time since linked PR creation,
commits or completed checks. Comments, lease renewals, labels and `updatedAt` do
not refresh durable progress. Bounded/failed evidence reads remain unknown;
persistent dashboards and explicit authority/dependency waits are excluded.

After one hour, the owning AI assesses one recovery action against fresh target
evidence. Preserve live owners, continue the exact approved checkpoint, or send
one evidence-backed scope-revision request to its authorised brief owner. Retain
the action in existing recovery state; do not repeat age comments or redispatch
an unchanged brief. The broader delegated scope-decision and AI-owned handoff
contract is tracked in #31305; this mechanism does not itself grant workers
permission to approve their own authority expansion.
