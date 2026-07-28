---
description: Skool account and community export evidence with fail-closed no-route disposition
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

# Skool Account Knowledge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Importer**: none; no Skool provider module or social-helper command exists
- **Official surfaces**: Pro-plan Zapier membership events, an admin export of
  membership-question answers, and privacy access or portability requests
- **Current disposition**: **Export/No** for the narrow admin answers export and
  **No** for account or community content, interactions, messages,
  relationships, courses, and calendar data
- **Blocking gap**: no supported public read API or published export schema,
  stable selected-account/community identity, completeness, or replay contract
- **Browser route**: disabled; Skool's current terms and platform policy prohibit
  scraping and automation requests
- **Activation rule**: validate a current private official export and its
  authority, identity, schema, and completeness before adding an importer

No importer, API client, Zapier receiver, or browser route is enabled.

<!-- AI-CONTEXT-END -->

## Evidence boundary

The route and documentation were checked on 2026-07-28. The worker runtime has
Python 3.14.3. No Skool client is declared in the locked requirements, and no
`skool`, `skool_api`, or `skoolkit` Python module is installed. No third-party
client symbols, provider fields, endpoint paths, scopes, or error codes are
mapped.

Skool's official help search for `API` returned five articles, all limited to
the Zapier integration and its two triggers and two actions. It exposed no
developer portal, endpoint reference, OAuth flow, pagination, request limits,
retention contract, or supported general account-read API:
https://help.skool.com/search?query=API.

The official Zapier article says the integration is available only on the Pro
plan. A group admin enables the plugin and supplies a group API key and group URL
to Zapier. The documented triggers send new paid-member details and newly
submitted membership-question answers; the documented actions invite a member
and unlock a course:
https://help.skool.com/article/56-zapier-integration.

The key is documented only for linking a Skool group to Zapier. Skool publishes
no direct-client contract for it, so this implementation does not reverse
engineer or treat that integration credential as a supported API token.

## Narrow admin surfaces

The paid-member trigger sends a recent subscriber's first name, last name, and
subscription email. Test data also shows a unique transaction ID and date, and
Zapier typically checks for new data every 10–15 minutes:
https://help.skool.com/article/162-zapier-new-paid-member-info-to-crm.

The membership-question trigger sends a create date, first and last name, a
unique transaction ID, and up to three questions and answers for a pending
applicant:
https://help.skool.com/article/59-zapier-for-membership-questions.

Those are prospective admin event automations, not a historical account reader.
The docs do not define replay, ordering, delivery guarantees, pagination,
deletion, a stable member ID, or category completeness. Names and email are
personal data, and the documented transaction ID is not stated to be a durable
selected-member identity. No Zapier receiver is therefore enabled.

Admins and moderators can view accepted members' membership-question answers.
Skool also documents an Export button on the Members tab that exports all of
those answers:
https://help.skool.com/article/148-where-can-i-find-members-answers-to-membership-questions.

The page does not document the container type, filename, encoding, schema or
version, group identity, stable member identity, timestamps, answer-history
semantics, generation limits, completeness, download expiry, or retention. The
official help search for `export CSV` returned that answers article and an
invitation article, but no account-wide or community-content export:
https://help.skool.com/search?query=export%20CSV.

Without a current private export, a parser could not prove that the selected
community and administrator authority match the supplied data before persisting
third-party member answers. The narrow export remains **Export/No**.

## Requested coverage

| Requested category | Current official evidence | Disposition |
|---|---|---|
| Authored community posts and comments | No supported API, product export, or documented privacy-archive schema | **No** |
| Reactions, likes, and saved state | No supported route was verified | **No** |
| Notifications and messages | No supported read or export route was verified | **No** |
| Memberships, follows, and joined groups | Zapier exposes two prospective admin events, not the selected member's account state | **No** |
| Courses and progress | Course keys copy a course between Skool groups; they are not a downloadable archive | **No** |
| Calendar and events | No supported read or export route was verified | **No** |
| Admin membership-question answers | An official admin export exists, but its identity and schema contract is unpublished | **Export/No** |
| Other admin-visible member data | Only the two documented Zapier trigger payloads were verified | **No** |

An absent route or undocumented field is not evidence that an account or group
has no records. Every unsupported category remains unavailable rather than
becoming successful empty coverage.

Course owners can share a course key, and owners or admins can import it into
another Skool group as a draft. That server-side duplication mechanism is not a
portable archive and does not expose selected-member course access or progress:
https://help.skool.com/article/199-how-to-duplicate-a-course-to-another-group.

## Privacy, retention, and terms

Skool's privacy policy provides rights that can include access and, for EEA
users, portability. Customer-controlled data requests generally go to the
relevant community, with Skool supporting the customer as needed. The policy
does not publish an archive format, included categories, delivery time, stable
identity field, or download expiry:
https://www.skool.com/legal?t=privacy.

The policy describes purpose- and legal-obligation-based retention but no fixed
account or export retention period. A future private response is evidence only
for its observed schema and authority; it is not a general compatibility
contract.

Skool's terms prohibit accessing the service with robots, crawlers, extraction
software, automated processes, or devices to scrape, copy, or monitor it:
https://www.skool.com/legal?t=terms.

The platform policy separately directs users to refrain from scraping data or
making automation requests:
https://help.skool.com/article/179-platform-policy.

These provider rules exclude browser capture and undocumented network calls as
fallbacks. A private browser-gap approval cannot override provider terms.

## Why ingestion is disabled

The social-store contract requires stable selected-account or selected-community
identity before any raw or normalized persistence. The only documented product
export does not publish such an identity. Privacy access is a legal request
right, not a stable product archive contract. The Zapier key and group slug are
configuration inputs, not documented identity fields inside a replayable data
artifact.

Implementing from screenshots, guessed fields, undocumented endpoints, or a
caller-supplied filename would risk persisting one group's member data under
another connection. Browser collection would additionally conflict with current
provider terms. The fail-closed contract is enforced by
`.agents/tests/test-knowledge-social-skool.sh`.

## Activation checklist

Before enabling a Skool importer:

1. Generate a fresh export through an official Skool workflow and keep every
   original file and personal-data sample private.
2. Record the requesting role, selected account or community, generation time,
   sanitized member-path inventory, container type, encoding, and schema
   markers without committing names, email, answers, content, IDs, or links.
3. Identify an authoritative stable account/community marker in the artifact
   and prove an exact comparison with the operator-selected connection before
   any raw evidence is written.
4. Establish category completeness, omissions, time-zone semantics, duplicate
   behavior, segmentation, and unknown-schema handling. Missing categories stay
   unavailable rather than becoming empty success.
5. Confirm that automated local parsing of the supplied export is permitted and
   record generation limits, download expiry, and retention instructions.
6. Add bounded parsing, path and symlink rejection where applicable,
   credential-shaped payload rejection, immutable original evidence,
   content-addressed replay, independent coverage, and a final lease fence.
7. Test malformed input, account/community mismatch and rebinding, credentials,
   item and byte stops, replay/idempotency, stale leases, terminal failures,
   unknown schemas, and static isolation from network, browser, and mutation
   adapters.
8. Change only categories proven by the validated private sample to **Live**;
   retain explicit **No** coverage for every absent or unsupported category.
