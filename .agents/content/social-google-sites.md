---
description: Modern and classic Google Sites API, Drive, and export no-route disposition
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

# Google Sites Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Importer**: none; no Google Sites provider module, registry entry, helper
  command, Drive client, Takeout importer, or browser route exists
- **Modern Sites**: Drive documents a Google Sites MIME type and file metadata,
  but no supported Sites content, page, revision-history, or export MIME contract
- **Classic Sites**: the deprecated Sites API is classic-only and cannot access
  rebuilt Sites; Google's migration program is complete
- **Export surfaces**: user Google Takeout includes Sites content, while Workspace
  Data Export is administrator-gated; neither publishes a stable Sites archive
  identity or versioned schema suitable for ingestion
- **Current disposition**: **API/No** for Drive metadata, **Export/No** for user
  Sites archives, **Gate/No** for organization exports, and **No** for live site
  content, revisions, interactions, subscriptions, or lists
- **Activation rule**: accept only an explicitly selected, user-owned site ID and
  a documented content format or identity-bearing private export before adding
  parsing, persistence, or CLI wiring

No API client, metadata collector, export importer, or browser route is enabled.

<!-- AI-CONTEXT-END -->

## Evidence boundary

The official product, Drive, Takeout, Data Portability, identity, quota, and
policy surfaces were checked on 2026-08-02. No third-party endpoint, private
network call, response field, error code, or client symbol is mapped. Metadata
availability is not represented as site-content availability.

Google's Sites developer page is explicit that the Sites API is deprecated, may
stop working at any time, can access only classic Sites, and cannot access the
rebuilt Sites product launched in 2016:
https://developers.google.com/workspace/sites.

The separate official migration notice set January 30, 2023 as the deadline for
remaining classic Sites, and Google's January 2025 Workspace recap says the
migration from classic Sites is complete:
http://workspaceupdates.googleblog.com/2022/11/migrate-classic-google-sites-by-january-30-2023.html
and
http://workspaceupdates.googleblog.com/2025/01/release-notes-01-24-2025.html.

The classic API's historical page, content, comment, attachment, ACL, and
revision methods therefore do not authorize a modern Sites collector. This route
does not send requests to that deprecated API or infer that migrated content
retains classic resource IDs.

## Drive metadata is not Sites content

Drive's supported-MIME reference lists `application/vnd.google-apps.site` as
Google Sites and says MIME types can filter query results:
https://developers.google.com/workspace/drive/api/guides/mime-types.

The reference does not distinguish modern from classic Sites or claim that the
MIME resource exposes pages, rendered content, embeds, attachments, comments, or
revision history. `files.list` lists all files, including trashed files by
default, and supports query filters and page tokens:
https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list.

The Drive `File` resource exposes metadata such as `id`, `mimeType`, `name`,
`createdTime`, `modifiedTime`, `ownedByMe`, `owners`, `permissions`, `driveId`,
`resourceKey`, and `webViewLink`:
https://developers.google.com/workspace/drive/api/reference/rest/v3/files.

That reference also says `driveId` is populated for shared-drive items, while
`owners` is not populated for those items. A future user-owned route must reject
shared-drive resources rather than weakening the owner binding. A browser
`webViewLink`, thumbnail link, resource key, or export link is metadata, not
authority to crawl, redirect, or download arbitrary content.

`files.get` can retrieve one exact file's metadata by ID. Its `alt=media` content
path applies to files stored in Drive, while the page directs Google Workspace
documents to `files.export`:
https://developers.google.com/workspace/drive/api/reference/rest/v3/files/get.

Metadata methods accept `drive.metadata.readonly`, but Google classifies that
all-file metadata scope as sensitive. Google recommends the non-sensitive
`drive.file` scope for files explicitly opened or shared with an app and says to
request the narrowest scope possible:
https://developers.google.com/workspace/drive/api/guides/api-specific-auth.

Drive `about.get(fields=user)` can return the current user's `permissionId` and
email address:
https://developers.google.com/workspace/drive/api/guides/user-info.

For account identity, Google OpenID Connect says the `sub` claim is unique,
never reused, and unchanged when email changes; email must not be the primary
identifier:
https://developers.google.com/identity/protocols/oauth2/openid-connect.

These primitives could bind an explicitly selected file's metadata to an
expected Google account, but they expose no documented site corpus. A metadata-
only adapter would advertise collection without collecting the requested site
content or history, so no Drive OAuth scope or collector is enabled.

## No documented Drive content or revision route

`files.export` requires a requested MIME type from Drive's supported export
table and limits exported content to 10 MB:
https://developers.google.com/workspace/drive/api/reference/rest/v3/files/export.

The current export table lists Documents, Spreadsheets, Presentations, Drawings,
Apps Script, and Google Vids, but no Google Sites document type or export MIME
type:
https://developers.google.com/workspace/drive/api/guides/ref-export-formats.

This is a documented omission, not permission to guess an HTML, ZIP, PDF, or
other target. The newer `files.download` method accepts only supported Workspace
document MIME types, says its unspecified default may change, and does not add a
Sites format:
https://developers.google.com/workspace/drive/api/reference/rest/v3/files/download.

The Drive `File.headRevisionId` field is documented only for binary Drive files,
and `files.download.revisionId` supports blob files, Docs, and Sheets. Neither is
a documented modern Sites revision-history route. No export request, default
download, browser render, published-site crawl, or revision inference is made.

## Takeout and administrator export gates

Google's product-specific export help says a Drive download includes Sites and
lists draft and published sites, embedded URLs and pages, navigation, themes,
site content, attachments, lists, page templates, and site owners:
https://support.google.com/docs/answer/9759608.

The general Takeout workflow is user-initiated, may omit changes made between
request and archive creation, and can delay risky requests:
https://support.google.com/accounts/answer/3024190.

Neither page publishes a Sites container layout, schema version, immutable site
resource ID, account identity field, modern-versus-classic marker, revision
semantics, segmentation contract, generation quota, or per-file expiry. The
category is therefore **Export/No** until a current private owner archive proves
identity, format, completeness, and replay behavior.

Google does expose a programmatic Data Portability API, but its page says the
published scope list contains every supported scope. The current list contains
no Google Sites or Google Drive scope:
https://developers.google.com/data-portability/user-guide/scopes.

The archive-job API cannot widen that product allowlist:
https://developers.google.com/data-portability/reference/rest.

Workspace's Data Export tool exports organization data to Cloud Storage and can
include the same Drive/Sites data available through Takeout. It requires a
super-administrator account at least 30 days old and 2-Step Verification, has a
security delay, can take up to 14 days, and places broad organization data into
an archive:
https://support.google.com/a/answer/100458.

That is an administrator-controlled **Gate/No** route, not authority for a
personal site collector. This implementation does not request super-admin
access, enumerate organization users, fetch Cloud Storage archive objects, or
ingest organization-wide data.

## Requested coverage

| Requested category | Current official evidence | Disposition |
|---|---|---|
| Modern site pages and authored content | Manual Takeout includes Sites content; no Drive/Sites content API or published archive schema | **Export/No** |
| Modern site resource metadata | Drive exposes a Sites MIME type and file metadata, but metadata alone is not a site corpus | **API/No** |
| Modern page or site revision history | No modern Sites API or documented Drive revision/export route | **No** |
| Classic Sites content and revisions | Deprecated classic-only API; migration program is complete | **No** |
| Embeds, attachments, navigation, themes, and templates | Named by Takeout help without a versioned artifact contract | **Export/No** |
| Site owners, editors, and permissions | Drive metadata and Takeout owner data exist, but no enabled identity-bound collection route | **API/No** |
| Comments, mentions, messages, notifications, and interaction history | No supported modern Sites account-history route was verified | **No** |
| Site subscriptions, relationships, lists, or custom feeds | No supported route was verified | **No** |
| User-requested Sites archive | Manual Google Takeout workflow with unpublished Sites schema and resource binding | **Export/No** |
| Organization-wide Sites export | Workspace super-admin Data Export workflow | **Gate/No** |

An unavailable category is not a successful empty result. Drive metadata cannot
fill a site-content category, and organization exports cannot be reclassified as
ordinary user authority.

## Pagination, quotas, and failure boundary

Although no route is enabled, the future activation contract is explicit.
`files.list` and `permissions.list` use opaque `nextPageToken` values; rejected
tokens restart from the first page, and `incompleteSearch=true` means results are
missing. Permissions can also be paginated:
https://developers.google.com/workspace/drive/api/reference/rest/v3/permissions/list.

Drive's current quota model charges reads, lists, and downloads differently and
uses `403` and `429` for rate-limit failures. It requires bounded exponential
backoff rather than indefinite retries:
https://developers.google.com/workspace/drive/api/guides/limits.

A future collector must keep independent account, resource, permission, content,
and export checkpoints. Any missing page, rejected token, incomplete search,
quota stop, malformed response, account or site mismatch, redirect, unsupported
format, or stale lease must leave prior evidence and checkpoints unchanged.

## Why ingestion is disabled

The social-store contract requires both authoritative selected-account/resource
identity and supported content semantics before raw persistence. Drive can prove
that an exact file is Sites-shaped and expose ownership metadata, but the
official export table provides no Sites content format or revision route.
Takeout exposes content through an interactive, schema-free artifact; the Data
Portability API has no Sites scope; administrator export is over-broad.

Implementing from filenames, site names, public URLs, `webViewLink`, guessed
export MIME types, default downloads, published-site crawling, redirects,
screenshots, or caller-supplied account labels would permit wrong-site or
cross-account persistence. No placeholder adapter, registry entry, helper
command, OAuth request, browser selector, or persistence path is added.
`.agents/tests/test-knowledge-social-google-sites.sh` enforces that negative
contract.

## Activation checklist

Before enabling any Google Sites route:

1. Revalidate modern and classic Sites, Drive, Takeout, Data Portability, Admin
   export, OAuth, quota, retention, and User Data Policy documentation.
2. Use OpenID Connect `sub` plus the expected Drive `permissionId` to bind the
   selected Google account; treat email only as local corroboration.
3. Require explicit user-selected site resource IDs. Prefer `drive.file`; do not
   enumerate unrelated Drive content or silently widen to all-file scopes.
4. For every resource, require exact ID, `application/vnd.google-apps.site`,
   `ownedByMe=true`, the expected owner permission ID, `trashed=false`, and no
   shared-drive `driveId` before any evidence write.
5. Use only an officially documented Sites content/export format. Reject default
   MIME selection, browser/view/thumbnail/export URLs, redirects, resource-key
   substitution, and cross-site responses.
6. For a private Takeout artifact, prove the selected account and site ID inside
   the artifact before raw persistence; reject traversal, links, duplicate paths,
   malformed members, credentials, unknown schemas, and unexplained categories.
7. Add hard request, item, page, permission, byte, and retry budgets; preserve
   opaque page tokens, reject incomplete searches, stop on quota/terminal errors,
   and commit each independent checkpoint atomically behind a final lease fence.
8. Test account and site rebinding, ownership changes, shared-drive responses,
   pagination restart, malformed exports, schema drift, quota stops, redirects,
   content-addressed replay, stale leases, and static isolation from every write
   or mutation path.
9. Register and advertise only fixture-proven categories; retain explicit
   **Export**, **Gate**, or **No** coverage for all unsupported surfaces.

Google's User Data Policy requires minimum relevant permissions, prominent data
disclosures, secure handling, and Limited Use of sensitive or restricted data:
https://developers.google.com/terms/api-services-user-data-policy.

OAuth policy additionally requires the smallest necessary scope and permanent
token deletion after revocation:
https://developers.google.com/identity/protocols/oauth2/policies.
