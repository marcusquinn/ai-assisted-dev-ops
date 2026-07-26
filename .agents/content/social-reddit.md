---
description: Reddit API integration via PRAW for reading and posting
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

# Reddit CLI/API Integration

- **Install**: `pip install praw`
- **Repo**: https://github.com/praw-dev/praw (4k+ stars, Python, BSD-2)
- **Docs**: https://praw.readthedocs.io/
- **Rate limits**: Unauthenticated JSON: 96 req/10min per IP. Authenticated OAuth: 996 req/10min per account. PRAW handles rate limiting automatically; add `time.sleep(1)` for raw JSON endpoints.

## No-Auth (append `.json` to any Reddit URL)

```bash
# Subreddit posts
curl -s "https://www.reddit.com/r/devops/hot.json?limit=10" | jq '.data.children[].data | {title, score, url}'

# Post comments
curl -s "https://www.reddit.com/r/devops/comments/POST_ID.json" | jq '.[1].data.children[].data | {author, body, score}'

# User profile
curl -s "https://www.reddit.com/user/USERNAME/about.json" | jq '.data | {name, link_karma, comment_karma}'

# Search
curl -s "https://www.reddit.com/search.json?q=aidevops&sort=relevance" | jq '.data.children[].data | {title, subreddit, score}'
```

## PRAW (Authenticated)

OAuth app: https://www.reddit.com/prefs/apps → create "script" type. Store a
named profile with `aidevops secret set REDDIT_DEFAULT_CLIENT_ID` and matching
`CLIENT_SECRET`, `USERNAME`, `PASSWORD`, and `USER_AGENT` entries; never put the
values in a command or repository file.

```python
import os

import praw

reddit = praw.Reddit(
    client_id=os.environ["REDDIT_DEFAULT_CLIENT_ID"],
    client_secret=os.environ["REDDIT_DEFAULT_CLIENT_SECRET"],
    user_agent=os.environ["REDDIT_DEFAULT_USER_AGENT"],
    username=os.environ["REDDIT_DEFAULT_USERNAME"],
    password=os.environ["REDDIT_DEFAULT_PASSWORD"],
)

# Read subreddit
for post in reddit.subreddit("devops").hot(limit=10):
    print(f"{post.score}: {post.title}")

# Read one comment
comment = reddit.comment("COMMENT_ID")
print(comment.body)
```

Use direct PRAW calls for reads only. Every automated post, reply, upvote, or
save must use the owner-only queue through `operation-create`; never call PRAW
write methods directly from automation.

## Approval-bound outbound operations

Automated writes use the owner-only social operation queue rather than direct
PRAW snippets. The connection fixes provider `reddit` and its stable account ID;
`--profile default` selects only `REDDIT_DEFAULT_*` environment variables. Every
immutable draft requires a separate owner approval before execution.

```bash
# Self-post: subject and body remain in separate mode-0600 files until execution.
knowledge-social-helper.sh operation-create --alias workspace:example \
  --connection-id REDDIT_CONNECTION_ID --account-id STABLE_REDDIT_ACCOUNT_ID \
  --action post --destination-id SUBREDDIT_NAME --subject-file subject.txt \
  --body-file post.txt --profile default

# Reply targets t1_ comments or t3_ submissions. Like maps to upvote; bookmark to save.
knowledge-social-helper.sh operation-create --alias workspace:example \
  --connection-id REDDIT_CONNECTION_ID --account-id STABLE_REDDIT_ACCOUNT_ID \
  --action reply --target-id t1_COMMENT_ID --body-file reply.txt \
  --profile default
```

Execution verifies `reddit.user.me().id` against the approved stable account
before recording the provider boundary. A timeout or provider failure after that
boundary becomes `unknown` and requires external reconciliation; it is never
blindly retried. Multiple accounts use separate profile slugs and separate
`REDDIT_<PROFILE>_*` secret sets.

## Related

- `scripts/x-helper.sh` - X/Twitter fetching via fxtwitter
- `aidevops/knowledge-plane/05-social-operations.md` - approval, scheduling, receipts, and reconciliation
- `tools/browser/curl-copy.md` - Authenticated scraping workflow
