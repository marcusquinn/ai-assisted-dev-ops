---
description: Quora account export evidence and fail-closed no-route disposition
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Quora Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Importer**: none; no Quora provider module or social-helper command exists
- **Official route**: the account owner requests an archive from Quora support
- **Current disposition**: **Export/No** for observed authored content,
  bookmarks, and user follows; **No** for every category without current evidence
- **Blocking gap**: public content-archive samples contain no authoritative owner
  identity, while the companion account-data archive has no published schema
- **Activation rule**: validate a current private companion archive and a stable
  owner marker before adding parsing, persistence, or CLI wiring

No importer or CLI route is enabled.

<!-- AI-CONTEXT-END -->

## Evidence boundary

The route and documentation were checked on 2026-07-28. The worker runtime has
Python 3.14.3, and no `quora`, `quora_api`, or `quoraapi` Python package is
installed. No third-party client symbols, provider response fields, or error
codes are mapped. No current official general account-read API was accepted as a
collection route.

Quora's official help says it sends an archive of the owner's content and
personal data to the account's primary email address after an owner request. It
says delivery is typically within 72 hours after Quora confirms the request:
https://help.quora.com/hc/en-us/articles/360000839503-Can-I-get-a-copy-of-my-data.

That page does not document the container type, archive count, inner filenames,
schema or version, included categories, stable identity field, download-link
expiry, regeneration limit, or archive-retention period. This implementation
does not infer any of those contracts.

## Current public archive observations

The following is current community evidence, not an official compatibility
guarantee. A parser merged on 2026-07-23 reports two owner-authorized content
exports whose extracted roots contain `index.html`. It recognizes `<h1>`
sections and `<h2>` records with labelled HTML fields:
https://github.com/chargingthefuture/chargingthefuture/blob/5297caf4c3f52bb3ea16c3c047fa861a3a6a2502/ctf/scripts/parseQuoraExportToComicDataset.mjs.

The first sample report and its parser describe `Answers`, `Spaces Items`,
`Answer Comments`, `Question Comments`, `Post Comments`, and
`Space Submissions` as owner-authored content. They exclude inbox messages,
drafts, and profile data:
https://github.com/chargingthefuture/chargingthefuture/pull/1844.

A second sample report confirms the same content shape and describes a separate
account-data archive containing bookmarks, user follows, owner profile data,
blocks, and mutes. It does not publish that archive's inner paths, headings,
field labels, or stable account identifier:
https://github.com/chargingthefuture/chargingthefuture/pull/1907.

| Requested category | Current evidence | Disposition |
|---|---|---|
| Answers | Observed in two current community samples | **Export/No** until owner identity is verifiable |
| Questions | A section was observed but no supported ownership mapping was published | **Export/No** |
| Space posts and submissions | Observed with space, content, and time fields | **Export/No** |
| Answer, question, and post comments | Observed as separate content sections | **Export/No** |
| Bookmarks | Observed only in the unpublished companion account-data shape | **Export/No** |
| Followed people | User follows were observed only in the companion archive | **Export/No** |
| Followed topics and Spaces | No current schema evidence was found | **No** |
| Upvotes, saves other than bookmarks, and other curation | No current schema evidence was found | **No** |
| Inbox messages, drafts, credentials, blocks, and mutes | Sensitive or non-public sections were observed | **No**; never normalize or infer them |
| Lists or custom feeds | No supported export or API route was verified | **No** |

An absent or unrecognized section is not evidence that the account has no items
in that category. It remains unavailable rather than becoming successful empty
coverage.

## Why ingestion is disabled

The public content parser accepts any `index.html` with the recognized headings.
It reads no account ID, owner profile URL, username, or other authoritative
identity marker. Profile links inside authored text can identify third parties,
so they cannot bind the archive to the selected account.

The companion account-data archive reportedly contains the owner's profile URL
and email, but its exact structure is not public. A filename containing a handle
is only caller-controlled metadata and is not identity proof. Guessing headings
or treating content similarity as authentication would permit one account's
archive to be persisted under another account connection.

The authorized social-store contract requires selected-account identity before
any raw or normalized persistence. Because that prerequisite cannot be proved
from the published format, adding a content-only parser, placeholder adapter,
browser route, or legacy/private API route would be unsafe. The negative contract
is enforced by `.agents/tests/test-knowledge-social-quora.sh`.

## Activation checklist

Before enabling a Quora importer:

1. Request a fresh archive through the official owner route and keep all files
   private.
2. Record a sanitized manifest of archive count, member paths, headings, field
   labels, and category presence without committing names, email, profile URLs,
   signed links, messages, or authored text.
3. Identify a stable owner profile identifier in the companion archive and
   prove an exact comparison with the operator-selected account. Email may be
   used only for local comparison and must never be persisted or diagnosed.
4. Confirm how the companion identity archive binds every content archive in a
   multi-archive delivery. Missing, ambiguous, duplicate, or mismatched identity
   must fail before raw evidence is written.
5. Add bounded ZIP/HTML parsing, path and symlink rejection, credential-shaped
   payload rejection, immutable original-archive evidence, independent coverage,
   a final lease fence, and content-addressed replay.
6. Test malformed input, account mismatch and rebinding, credentials, item and
   byte stops, replay/idempotency, stale leases, terminal failures, unknown
   sections, and static isolation from network, browser, and mutation adapters.
7. Change only categories proven by the validated sample to **Live**; retain
   explicit **No** coverage for every absent or unsupported category.

## Retention and privacy

The official help's 72-hour delivery estimate is not a download lifetime or
retention grant. No current official export expiry or retention period was
verified. Future local retention must therefore remain owner-only,
purpose-limited, and deletable when authority or purpose ends.

Quora exports can contain owner and third-party personal data, private messages,
drafts, credentials, and relationship controls. Never paste an archive, signed
download link, account identifier, or private filename into an issue, fixture,
command log, or shared workspace.
