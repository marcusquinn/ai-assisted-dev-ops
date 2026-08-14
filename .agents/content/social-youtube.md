<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# YouTube Account Knowledge Collection

`knowledge-social-helper.sh sync-youtube` collects bounded account-visible
YouTube Data API v3 metadata into the social corpus. It is an OAuth **user**
collector. The service-account flow in `youtube-helper.sh` remains public channel
research tooling and is not evidence that a personal channel was selected.

## Runtime and authorization contract

The collector uses Python's standard-library `urllib.request.Request`,
`urllib.request.urlopen`, and `urllib.parse.urlencode` exports. It does not depend
on or install `google-api-python-client`; the implementation was verified with
Python 3.12.3 and validates the required exports before a live request.

Authorize only the documented read scope:

```text
https://www.googleapis.com/auth/youtube.readonly
```

Store a current user OAuth access token as
`YOUTUBE_<PROFILE>_ACCESS_TOKEN`. Token issuance and refresh happen outside the
collector; refresh tokens and OAuth client secrets never enter its process. Run a
profile through the secret execution context, for example:

```bash
aidevops secret YOUTUBE_PERSONAL_ACCESS_TOKEN -- \
  knowledge-social-helper.sh sync-youtube --alias personal:default \
  --connection-id YOUTUBE_CONNECTION_ID --account-id STABLE_CHANNEL_ID \
  --stream authored_videos --profile personal --budget 11 --page-size 50
```

The child receives only the selected access-token variable plus a small runtime
environment allowlist. It calls `channels.list(mine=true)` before collection and
again before every page. A changed or unowned channel ID fails before evidence or
checkpoint persistence.

## Implemented streams

| Stream | Official route | Coverage |
|---|---|---|
| `authored_videos` | `channels.list(mine=true)` uploads ID, then `playlistItems.list` | Uploaded-video metadata, newest-ID watermark, resumable page tokens. |
| `channel_activity` | `activities.list(mine=true)` | Documented activity resource types only; not a complete account audit log. |
| `owned_playlists` | `playlists.list(mine=true)`, then `playlistItems.list` per playlist | Owned playlists and explicit playlist-to-video membership. Third-party saved playlists are not represented. |
| `subscriptions` | `subscriptions.list(mine=true)` | Outbound direction: selected channel to subscribed channel. |
| `comments` | `commentThreads.list(allThreadsRelatedToChannelId=...)`, then paginated `comments.list(parentId=...)` | Channel-related comments and all API-visible replies. Visibility/moderation gates remain partial coverage. |
| `liked_videos` | `videos.list(myRating=like)` | Videos exposed by the authenticated user's current rating route. |

Every list call costs one documented quota unit. The initial identity request
reserves one unit; each page reserves two units for identity rebinding defence
and its selected list route. `--budget` is a hard 3-1000-unit allowance and
`--page-size` is limited to 1-50. Each stream owns an independent cursor. The
compound playlist and comment cursors commit one API response plus the next phase
atomically under the final lease fence.

Documented 403 quota and rate-limit reasons are normalized to the collector's
sanitized rate-limit state; unrelated 403 responses remain authorization
failures. Initial identity failures finish only the privacy-safe run receipt and
never bind a connection or persist provider evidence before account verification.

The boundary serializes only allowlisted text, IDs, timestamps, direction, count,
position, and privacy-status fields. It never downloads audiovisual media and has
no write endpoint or mutation action.

## Approved outbound video uploads

The approval-bound outbound queue can upload one reviewed private video to an
exactly verified owned channel. It requires a named OAuth profile with the
official `https://www.googleapis.com/auth/youtube.upload` scope, a private media
file bound by SHA-256 before approval, a
non-empty title (at most 100 characters), and a private description. The provider
first calls `channels.list(mine=true)` and fails closed on a different channel or
unready authorization. It initiates the official resumable `videos.insert`
upload route and maps any transport ambiguity to `unknown`; executors never
blindly create a second video. The initial implementation publishes as `private`
only—thumbnail, captions, scheduling, and changing a video's visibility require
separate approved capabilities. Receipts contain only operation and video IDs.

## Explicit gaps and retention

Every successful page also records unavailable coverage for:

- `watch_history`: the Data API explicitly does not expose watch history;
- `watch_later`: the Data API explicitly does not expose Watch Later items;
- `saved_playlists`: `playlists.list(mine=true)` lists owned, not merely saved,
  playlists;
- `authored_comments_elsewhere`: no complete account-wide authored-comment
  history is documented.

These rows use stable unsupported reasons and never turn an empty API response
into successful coverage. A Google account export remains the next candidate,
but no archive importer is enabled until a current private sample validates the
format and category completeness. Browser collection still requires a separate
approved private gap record.

YouTube API Services policy requires most stored authorized API data to be
deleted or refreshed within 30 calendar days and imposes revocation/deletion
obligations. Coverage therefore records
`youtube_api_data_refresh_or_delete_within_30_days`. Operators must keep the
connection authorized and refreshed, and remove data when authorization or the
source ends. Immutable raw batches are evidence for a fetch; immutability does
not override provider deletion obligations.

## Official evidence checked 2026-07-26

- [Authentication and OAuth](https://developers.google.com/youtube/v3/guides/authentication)
- [OAuth server-side scopes](https://developers.google.com/youtube/v3/guides/auth/server-side-web-apps#OAuth2_0_Scopes)
- [Channels list](https://developers.google.com/youtube/v3/docs/channels/list)
- [Channels resource](https://developers.google.com/youtube/v3/docs/channels)
- [Activities list](https://developers.google.com/youtube/v3/docs/activities/list)
- [Activities resource](https://developers.google.com/youtube/v3/docs/activities)
- [Playlists list](https://developers.google.com/youtube/v3/docs/playlists/list)
- [Playlist items list](https://developers.google.com/youtube/v3/docs/playlistItems/list)
- [Subscriptions list](https://developers.google.com/youtube/v3/docs/subscriptions/list)
- [Subscriptions resource](https://developers.google.com/youtube/v3/docs/subscriptions)
- [Comment threads list](https://developers.google.com/youtube/v3/docs/commentThreads/list)
- [Comment threads resource](https://developers.google.com/youtube/v3/docs/commentThreads)
- [Comments list](https://developers.google.com/youtube/v3/docs/comments/list)
- [Videos list](https://developers.google.com/youtube/v3/docs/videos/list)
- [Pagination](https://developers.google.com/youtube/v3/guides/implementation/pagination)
- [Quota costs](https://developers.google.com/youtube/v3/determine_quota_cost)
- [YouTube Data API errors](https://developers.google.com/youtube/v3/docs/errors)
- [Google API global errors](https://developers.google.com/youtube/v3/docs/core_errors)
- [Developer policies](https://developers.google.com/youtube/terms/developer-policies)
- [Google account export](https://support.google.com/accounts/answer/3024190)
