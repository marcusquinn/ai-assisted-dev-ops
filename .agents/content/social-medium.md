---
description: Identity-verified Medium account export ingestion
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

# Medium Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Importer**: `knowledge-social-helper.sh import-medium-archive`
- **Input**: a native Medium HTML ZIP requested by the account owner
- **Identity**: explicit `Medium user ID` from exactly one
  `profile/profile.html`, matched to `--account-id`; `--username` adds a second
  check
- **Implemented evidence**: authored posts, explicit responses, publication
  membership, bookmarks, lists, highlights, claps, and followed users,
  publications, or topics only when their validated archive category is present
- **Isolation**: no provider request, browser, extraction, media hydration, API
  token, or outbound operation is reachable
- **Replay**: the original ZIP is content-addressed; normalized rows, coverage,
  archive checkpoint, and run receipt commit under one final lease fence

<!-- AI-CONTEXT-END -->

## Evidence boundary

The route and documentation were checked on 2026-07-28. The worker runtime has
Python 3.14.3 with standard-library `zipfile.ZipFile` and
`html.parser.HTMLParser`. Neither a `medium` nor `medium_api` Python package is
installed. The importer intentionally has no third-party client and maps no
provider API responses or error symbols.

Medium's current export help says the owner requests **Download your
information** under **Settings → Security and apps** and receives an email when
the export is ready. It documents HTML files in a ZIP, but it does not publish a
normative directory schema, manifest/version, filename grammar, HTML contract,
or download-link expiry:
https://help.medium.com/hc/en-us/articles/115004745787-Export-your-account-data.

The current API/import help says Medium issues no new integration tokens and
permits no new integrations, while existing tokens may continue to work:
https://help.medium.com/hc/en-us/articles/213480228-API-Importing. The official
API documentation is archived and explicitly unsupported:
https://github.com/Medium/medium-api-docs. Its historical surface covers profile,
publication listing, publishing, and image upload—not account-history reads for
posts, responses, bookmarks, lists, highlights, claps, or follows. Legacy
integration access is therefore not a live collector route.

Medium's API terms constrain automated activity, rate-sensitive access, and
storage to the reasonable period needed for a service:
https://help.medium.com/hc/en-us/articles/214151487-Medium-API-Terms-of-Use.
The Medium Rules prohibit unsupported scraping and scripted copying through
interfaces other than those Medium publishes:
https://help.medium.com/hc/en-us/articles/213477928-Medium-Rules. This importer
uses only the owner-requested export and never contacts Medium.

The published privacy policy says account-associated personal data is generally
held while an account is active and account data is deleted within 14 days of
closure, subject to stated legal and operational exceptions:
https://policy.medium.com/medium-privacy-policy-f03bf92035c9. That policy is not
an export-email download-link lifetime and the importer does not infer one.

## Validated archive contract

Medium does not publish the ZIP's inner schema. The fail-closed contract is
documented by `.agents/tests/fixtures/medium-archive-fixture.py` and the focused
assertions in `.agents/tests/test-knowledge-social-medium.sh`. The sanitized
fixture reproduces microformat markers observed by the public `valueof/meh`
parser and fixtures at
https://github.com/valueof/meh/tree/main/parser and
https://github.com/valueof/meh/tree/main/testdata. Those sources are community
observations, not a Medium compatibility guarantee. A current owner export may
add categories or change HTML; unknown members remain immutable raw evidence and
receive partial coverage instead of being guessed.

| Archive path | Required markers | Normalized evidence |
|---|---|---|
| `profile/profile.html` | Exactly one `Medium user ID`; optional `h-card`, `p-name`, `u-url`, and `@username` cross-check | Verified owner account; email and connected-account fields are not normalized |
| `posts/*.html` | `data-field="body"` or `e-content`; canonical URL or explicit post ID when available | Authored post object plus `content_author`; an explicit `u-in-reply-to` or response ID records response classification |
| `bookmarks/*.html` | `h-cite` URL; optional `dt-published` | Curated story reference plus bookmark activity |
| `claps/*.html` | `u-like-of`/`h-cite` URL; optional bounded `+1`–`+50` count | Curated story reference plus clap activity |
| `highlights/*.html` | `markup--highlight` selection, with source URL when present | Curated highlight object and activity |
| `lists/*.html` | `p-name`; `li[data-field="post"]` URLs; canonical list URL when present | Owned curated list, referenced stories, and membership activities |
| `profile/publications.html` | Publication links | Publication relationship and membership activity; role remains `member` unless an unambiguous supported marker is added |
| `users-following/*.html` | Profile links | Followed account plus `follow_user` activity |
| `pubs-following/*.html` | Publication links | Publication reference plus `follow_publication` activity |
| `topics-following/*.html` | Topic links | Topic reference plus `follow_topic` activity |

Post authoring and curation never share an evidence class. A post without an
explicit response marker remains `unclassified_authored`; the `responses`
coverage record stays `partial` because the archive does not guarantee a
response discriminator. Timezone-free bookmark, clap, and highlight timestamps
remain in provenance with `timestamp_timezone_known=false`; no UTC instant is
invented.

Security/session history, blocks, interests, memberships, charges, IPs, Twitter
suggestions, binaries, and unknown paths are not interpreted as social evidence.
They remain inside the immutable private ZIP and produce
`unmapped_archive_members=partial`. Mentions/messages and local media remain
explicitly unavailable. No remote media URL is fetched.

## Import

Record the export observation time from the owner's request/email context with
an explicit timezone. Never paste a signed download URL or account data into a
command, issue, fixture, or log.

```bash
knowledge-social-helper.sh import-medium-archive \
  --archive "$HOME/private/medium-export.zip" \
  --connection-id conn_medium_personal \
  --account-id MEDIUM_USER_ID \
  --username MEDIUM_HANDLE \
  --exported-at 2026-07-28T08:00:00Z \
  --max-items 50000 \
  --max-bytes 536870912
```

`--max-items` bounds both ZIP members and unique normalized records.
`--max-bytes` bounds compressed and total uncompressed input; each member also
has a 32 MiB ceiling. Defaults are 50,000 items and 512 MiB, with hard CLI caps
of 1,000,000 and 1 GiB. The route consumes zero provider-request units.

The parser reads members directly without extracting them. It rejects absolute
or traversing paths, duplicate case-folded names, symlinks, encrypted members,
NULs, oversized members, malformed required markers, conflicting canonical IDs,
account mismatch/rebinding, and credential-shaped HTML attributes or URL query
fields—including signed-URL credentials—before raw evidence is written. The
selected connection owns one expiring archive lease; the final transaction
rechecks its fencing generation before writing.

The raw ZIP is gzip-wrapped by the shared content-addressed evidence store. Its
`blob_ref` is opaque even though the shared store currently uses a `.json.gz`
suffix. Decompressing the blob returns the exact original ZIP bytes. Exact replay
reuses its SHA-256 fetch batch and updates no duplicate normalized identities.

## Coverage and retention

`complete` means every recognized member of that category in this finite ZIP was
parsed; it does not claim that Medium exported every historical account event.
An absent category records `unavailable:category_not_present_in_archive` rather
than an empty success. Unknown HTML and unsupported native categories remain
`partial` raw evidence.

The ZIP can contain personal data about the owner and third parties. Keep the
corpus owner-only, preserve a lawful purpose, do not share the raw blob by
default, and delete it when authority or purpose ends. The importer records the
conservative boundary
`private_export_under_operator_control_and_lawful_purpose`; it does not convert
Medium's server-retention policy into a local indefinite-storage grant.
