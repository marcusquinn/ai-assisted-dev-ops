<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Slack Workspace Knowledge Collection

`knowledge_social_slack.py` collects bounded, allowlisted Slack Web API evidence
or imports one administrator-approved Slack JSON export. Both routes use the
same workspace-scoped account, conversation, message, reaction, file, and
activity identities. A native Slack ID from another workspace therefore cannot
collide, while an API record and export record for the same workspace resource
converge on one canonical identity.

Provider-neutral dispatcher registration is a separate integration phase. Until
that registration is present, invoke the dedicated Python entry point directly.

## Runtime, profile, and identity contract

The live collector uses Python standard-library `urllib.request.Request`,
`urllib.request.build_opener`, `urllib.request.HTTPRedirectHandler`, and
`urllib.parse.urlencode`. No Slack SDK is imported. Redirects are rejected, the
credential is sent only in the `Authorization` header, response bodies are
capped at 8 MiB, each invocation is capped at 17 request units, and only the
exact method-and-HTTP-verb pairs documented below are reachable.

Configure one profile through secure environment injection:

```text
SLACK_<PROFILE>_ACCESS_TOKEN
SLACK_<PROFILE>_WORKSPACE_ID
SLACK_<PROFILE>_ENTERPRISE_ID
SLACK_<PROFILE>_TOKEN_TYPE=bot|user
SLACK_<PROFILE>_CONVERSATIONS={"engineering":{"id":"CWORKSPACE123","kind":"public_channel"}}
```

`ENTERPRISE_ID` is optional unless the selected workspace identity has one.
`CONVERSATIONS` is a JSON object with at most 500 safe aliases. Every entry must
contain exactly `id` and `kind`; duplicate native IDs are rejected. Supported
kinds and required ID prefixes are `public_channel` (`C`), `private_channel`
(`G`), `im` (`D`), and `mpim` (`G`). Changing a configured workspace,
enterprise, account, token type, alias, conversation ID, or conversation kind
fails closed. The collector persists a SHA-256 binding over the complete
allowlist. Use a new connection ID when intentionally changing that identity or
allowlist; an old stream cursor can never be silently reused for a new target.

Use the stable account selector:

```text
slack_<WORKSPACE_ID>_user_<AUTH_TEST_USER_ID>
```

For example, a workspace `TWORKSPACE123` and selected account `UACCOUNT123`
become `slack_TWORKSPACE123_user_UACCOUNT123`. The child calls `auth.test` before
collection and before every page. It compares the returned workspace, optional
enterprise, user, and bot/user token type with the non-secret profile binding.
The access token never enters a request URL, provider output, evidence,
checkpoint, receipt, or error.

Every successful Slack response must include `X-OAuth-Scopes`. The complete
attested set must contain only these reviewed read scopes:

```text
team:read
users:read
channels:read
groups:read
im:read
mpim:read
channels:history
groups:history
im:history
mpim:history
reactions:read
files:read
pins:read
bookmarks:read
```

Grant only scopes needed by enabled streams. A missing scope attestation, an
unknown scope, or any write scope rejects the response. Each stream also checks
its exact required scope, and a changed attested scope set during collection
fails before persistence.

## Implemented Web API streams

| Stream | Exact Slack method and HTTP verb | Coverage |
|---|---|---|
| `workspace` | `GET team.info` | Selected workspace metadata. |
| `users` | `GET users.list` | Token-visible observed workspace-member snapshot; removals are not reconciled. |
| `reactions` | `GET reactions.list` | Selected-account reaction results; messages require an allowlisted channel and files require explicit intersection with an allowlisted channel, group, or DM. Removed reactions are not reconciled. |
| `conversation/<alias>/info` | `GET conversations.info` | Metadata for one exact allowlisted conversation. |
| `conversation/<alias>/members` | `GET conversations.members` | Token-visible observed membership snapshot; removals are not reconciled. |
| `conversation/<alias>/history` | `GET conversations.history` | Retained, token-visible messages with incremental refresh. |
| `conversation/<alias>/thread/<timestamp>` | `GET conversations.replies` | One exact retained thread with incremental refresh. |
| `conversation/<alias>/pins` | `GET pins.list` | Observed pins snapshot; removals are not reconciled. |
| `conversation/<alias>/bookmarks` | `POST bookmarks.list` | Observed bookmarks snapshot; Slack defines this read method as POST and removals are not reconciled. |
| `conversation/<alias>/files` | `GET files.list` | File metadata only; binaries and private URLs are omitted, tombstones are explicit, and absent-file removal is not inferred. |

`POST auth.test` is the only other reachable call. No endpoint string or verb
comes from provider data. Mutation methods, app/admin routes, search, browser
automation, export initiation, file download, and outbound operations are not
wired.

`--page-size` is 1-15. The initial identity check consumes one request unit and
each page reserves two units for identity rebinding plus its selected data
method. `--budget` is a hard 3-17 request-unit allowance, so one invocation can
read at most eight data pages and 17 individually 8 MiB-capped provider
responses. Cursor pagination resumes across invocations; pins and bookmarks are
capped snapshots, and file pages use a validated numeric page cursor. Every
logical stream has an independent durable cursor.

Completed message-history and thread backfills refresh from seven days before
their newest watermark so recent edits and deletions can update a stable message
identity. This overlap is not a complete historical-edit guarantee. Raw page,
normalized rows, coverage, cursor, and run receipt commit atomically under a
final lease fence. Rate limits pause the run without advancing its cursor.

Example direct API collection:

```bash
python3 "$HOME/.aidevops/agents/scripts/knowledge_social_slack.py" api \
  --connection-id conn_slack_personal \
  --account-id slack_TWORKSPACE123_user_UACCOUNT123 \
  --profile personal \
  --stream conversation/engineering/history \
  --budget 11 \
  --page-size 15
```

## Administrator-approved JSON exports

Obtain the ZIP through an authorized Slack export workflow. Never paste a
download URL, token, or exported private content into a command, issue, fixture,
or log. The importer never contacts Slack, initiates an export, follows a link,
extracts members to disk, or reads `SLACK_<PROFILE>_ACCESS_TOKEN`. It uses only
the profile's non-secret identity and conversation binding.

The implemented parser accepts Slack's flat, workspace-scoped JSON layout.
Nested whole-organization exports and single-user JSON or TXT layouts are
explicitly unavailable and fail closed rather than being guessed.

The fail-closed parser recognizes:

| Export member | Interpretation |
|---|---|
| exactly one `users.json` or `org_users.json` | Selected account plus only users referenced by selected evidence |
| optional `team_info.json` | Workspace and enterprise cross-check plus bounded workspace metadata |
| `channels.json` | Allowlisted public-channel references |
| `groups.json` | Allowlisted private-channel references |
| `dms.json` | Allowlisted direct-message references |
| `mpims.json` | Allowlisted multi-person direct-message references |
| `<conversation-folder>/YYYY-MM-DD.json` | Messages, threads, edits/deletions, embedded reactions, and file metadata for an allowlisted conversation |

An allowlist entry must resolve to exactly one reference record and its exact
conversation folder. The importer verifies the selected account, workspace, and
optional enterprise before normalization. API and export messages use the same
workspace, conversation ID, and Slack timestamp identity.

Example direct import:

```bash
python3 "$HOME/.aidevops/agents/scripts/knowledge_social_slack.py" archive \
  --archive "$HOME/private/slack-export.zip" \
  --connection-id conn_slack_personal \
  --account-id slack_TWORKSPACE123_user_UACCOUNT123 \
  --profile personal \
  --exported-at 2026-07-31T19:00:00Z \
  --max-items 25000 \
  --max-bytes 67108864
```

`--exported-at` is the operator-observed export time, requires an explicit
timezone, and cannot exceed the trusted local clock by more than five minutes.
`--max-items` bounds ZIP members and normalized records. `--max-bytes` bounds
both the compressed archive and total uncompressed members. Defaults are 25,000
items and 64 MiB; hard CLI caps are 100,000 items and 128 MiB. Each ZIP member
also has a 16 MiB ceiling. These limits bound the in-memory ZIP index, selected
JSON members, normalized records, and filtered evidence construction.

The archive path must be one unchanged regular non-symlink file. The parser
rejects absolute, traversing, backslash, NUL, duplicate case-folded, symbolic-link,
encrypted, malformed JSON, oversized, identity-conflicting, and unexpected
reference structures before persistence. Credential-shaped keys, Slack token
formats, Slack webhook URLs, and any exact active access token reflected by an
API response are also rejected; ordinary discussion of credential handling is
not treated as a secret.

The private raw evidence blob is deliberately **not** the original ZIP. It is
canonical filtered JSON containing only sanitized records from allowlisted
conversations, the non-secret immutable connection binding, SHA-256 hashes of
selected source members, and the full source ZIP digest. Unselected conversation
bodies and unreferenced user profiles are not persisted. User email fields, file
private URLs, binary content, and unknown provider fields are omitted. This
preserves replay/audit linkage without copying unselected workspace content into
the corpus. Exact filtered-evidence replay is content-addressed and creates no
duplicate canonical identities. Older API or export evidence can be retained as
a separate immutable batch, but timestamp-ordered account, object, activity,
media, coverage, cursor, and connection-policy writes cannot overwrite newer
canonical state. Within one connection, conflicting evidence with an identical
observation timestamp fails closed, while byte-equivalent replay remains
idempotent. Equal-time canonical records shared by separate connections resolve
deterministically by complete account values or content-addressed batch ID.

## Coverage and retention boundaries

API success records explicit partial or unavailable coverage for unallowlisted
conversations, plan/membership/token-bounded retention, deleted or purged
content, disabled file binaries, potentially truncated reaction actors, omitted
blocks/attachments/canvases/huddles, unreconciled reaction/pin/bookmark/member/
file removals, and the seven-day historical-edit window.
At most 100 returned reaction actors per message are accepted; larger nested
expansions fail closed before normalization, while Slack's reported count still
records upstream truncation.

An export proves only what its authorized ZIP contains. Each allowlisted
conversation receives finite archive coverage, while the importer separately
records that:

- unallowlisted conversations are excluded;
- channel bookmarks are not documented export members;
- JSON exports contain file metadata/links rather than imported binaries;
- edit and deletion records depend on workspace retention;
- thread timestamps are preserved without a separate complete thread order.

Public channels, private channels, DMs, and MPDMs remain distinct allowlist
kinds. Message bodies, threads, edits/deletions, reactions, files, users,
workspace metadata, pins, bookmarks, retention, exports, and inaccessible
history therefore each have an implemented route or an explicit coverage gap.
Neither API completion nor archive completion claims all historical workspace
content. Local retention must remain owner-controlled and authorized for the
operator's purpose.

## Official evidence checked 2026-07-31

- [Slack `auth.test`](https://docs.slack.dev/reference/methods/auth.test.md)
- [Slack `conversations.history`](https://docs.slack.dev/reference/methods/conversations.history.md)
- [Slack `conversations.replies`](https://docs.slack.dev/reference/methods/conversations.replies.md)
- [Slack `bookmarks.list`](https://docs.slack.dev/reference/methods/bookmarks.list.md)
- [Slack Web API rate limits](https://docs.slack.dev/apis/web-api/rate-limits.md)
- [How to read Slack data exports](https://slack.com/help/articles/220556107-How-to-read-Slack-data-exports)
