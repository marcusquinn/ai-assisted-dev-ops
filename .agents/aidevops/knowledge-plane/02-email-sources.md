# Knowledge Plane — Email Sources and Automation

Parent index: `../knowledge-plane.md`.

## Email Kind (`kind=email`) (t2854)

`.eml` and `.emlx` (Apple Mail) files are ingested as first-class `kind=email` sources.
When `knowledge-helper.sh add` receives an `.eml`/`.emlx` file, it delegates to
`email-ingest-helper.sh` which parses headers, body, and attachments into structured
sources.

### Email-Specific Meta Fields

Parent source (`kind=email`) `meta.json` extends the base schema with:

```json
{
  "kind": "email",
  "from": "sender@example.com",
  "to": "recipient@example.com",
  "cc": "cc@example.com",
  "bcc": "",
  "date": "Wed, 23 Apr 2026 10:00:00 +0000",
  "subject": "Email subject line",
  "message_id": "<unique-id@example.com>",
  "in_reply_to": "<parent-id@example.com>",
  "references": "<thread-id@example.com>",
  "body_text_sha": "sha256-of-text.txt",
  "body_html_sha": "sha256-of-body.html",
  "attachments": [
    {"source_id": "child-source-id", "filename": "report.pdf"}
  ]
}
```

Child source (`kind=attachment`) `meta.json` adds:

```json
{
  "kind": "attachment",
  "parent_source": "parent-email-source-id",
  "attachment_filename": "report.pdf",
  "content_type": "application/pdf"
}
```

### Source File Layout

```text
sources/<email-id>/
  meta.json          # kind=email, full email headers + attachment refs
  text.txt           # Plain-text body (or text extracted from HTML-only)
  body.html          # Sanitised HTML body (if present)
sources/<attachment-id>/
  meta.json          # kind=attachment, parent_source linkage
  report.pdf         # Original attachment file
```

### Body Sanitisation

Stored email bodies are sanitised on ingest for privacy and reproducibility:

- **Tracking pixels:** `<img src="https://...">` tags are replaced with
  `<!-- tracker stripped -->` comments.
- **UTM parameters:** `?utm_source=...&utm_medium=...` query strings are stripped
  from URLs in the HTML body.
- **Remote images:** all remote `<img>` sources are stripped (prevents phone-home
  on re-render).

Sanitisation is idempotent — re-ingesting the same `.eml` produces identical
`body.html` output.

### MIME Edge Cases

| Case | Handling |
|------|----------|
| `multipart/alternative` (text + html) | Both extracted; text preferred for `text.txt` |
| `multipart/related` (html + inline images) | Inline images treated as attachments |
| Apple Mail `.emlx` | Length-prefix header stripped before parsing |
| Quoted-printable encoding | Decoded by Python `email` stdlib |
| Base64-encoded bodies | Decoded by Python `email` stdlib |
| Non-UTF-8 charsets | Attempted UTF-8, fallback to latin-1 with warning |

### CLI

```bash
# Direct ingestion via email helper
email-ingest-helper.sh ingest /path/to/email.eml [--repo-path <path>] [--sensitivity <tier>]

# Auto-detected via knowledge add
knowledge-helper.sh add /path/to/email.eml
```

### Sensitivity Classification

Each source (parent email body + each child attachment) is independently classified
by the sensitivity detector (t2846). A benign email body at `tier:internal` can have
a contract attachment at `tier:privileged` — the child's tier is independent of the
parent's.

## IMAP Polling (t2855)

The pulse-driven `r044` routine polls configured IMAP mailboxes every 10 minutes,
drops new messages as `.eml` files into `_knowledge/inbox/`, and the existing
ingestion pipeline (t2854) picks them up from there.

### Setup

**1. Store the mailbox password in gopass:**

```bash
aidevops secret set email/personal-icloud/password
# or directly: gopass insert aidevops/email/personal-icloud/password
```

**2. Register the mailbox interactively:**

```bash
aidevops email mailbox add
```

This prompts for provider (auto-fills IMAP host/port from `email-providers.json.txt`),
username, gopass path, and which folders to poll. It tests the connection before
saving.

**3. Verify the configuration:**

```bash
aidevops email mailbox list       # shows all registered mailboxes + state
aidevops email mailbox test <id>  # dry-run: connect + fetch 1 message, no writes
```

**4. Enable the polling routine:**

The `r044` entry in `TODO.md` is enabled by default (`[x]`). The pulse picks it
up and runs `scripts/email-poll-helper.sh tick` every 10 minutes.

To disable: change `[x] r044` to `[ ] r044` in `TODO.md`.

### Manual Operations

```bash
# Poll all mailboxes immediately (same as the r044 routine)
~/.aidevops/agents/scripts/email-poll-helper.sh tick

# Back-fill historical messages from 2026-01-01 (rate-limited to 100 msg/min)
~/.aidevops/agents/scripts/email-poll-helper.sh backfill <mailbox-id>     --since 2026-01-01     --rate-limit 100

# Show all mailboxes and their last-polled timestamps
~/.aidevops/agents/scripts/email-poll-helper.sh list
```

### mailboxes.json Schema

```json
{
  "mailboxes": [
    {
      "id": "personal-icloud",
      "provider": "icloud",
      "host": "imap.mail.me.com",
      "port": 993,
      "user": "you@icloud.com",
      "password_ref": "gopass:aidevops/email/personal-icloud/password",
      "folders": ["INBOX", "Cases/2026"],
      "since": "2026-01-01"
    }
  ]
}
```

Field reference:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier used in state keys and .eml filenames |
| `provider` | string | Provider slug (matched against `email-providers.json.txt` for host defaults) |
| `host` | string | IMAP server hostname |
| `port` | integer | IMAP port — use 993 (TLS/SSL). Port 143/STARTTLS is not supported; the implementation uses `IMAP4_SSL` exclusively. |
| `user` | string | Login username / email address |
| `password_ref` | string | `gopass:<path>` or environment variable name |
| `folders` | array | IMAP folders to poll — each tracked independently |
| `since` | string | ISO date — only used on first backfill, not by routine ticks |

### Credential Resolution

`password_ref` supports two forms:

1. A `gopass:<path>` reference, which resolves the password from gopass. This is
   strongly preferred because the secret stays in the encrypted password store.
2. An environment variable name containing the password. This is permitted for
   constrained automation, but is less secure and discouraged for production use.

## Email Thread Reconstruction (t2856)

Email sources with `"kind": "email"` support JWZ-style thread reconstruction.
Thread indexes live at `_knowledge/index/email-threads/<thread-id>.json`:

```json
{
  "thread_id": "<msg-001@example.com>",
  "root_subject": "Project kickoff",
  "participants": ["alice@example.com", "bob@example.com"],
  "sources": [
    {"source_id": "src-001", "message_id": "<msg-001@example.com>", "date": "2026-01-10T09:00:00Z", "from": "alice@example.com"},
    {"source_id": "src-002", "message_id": "<msg-002@example.com>", "date": "2026-01-10T10:00:00Z", "from": "bob@example.com"}
  ]
}
```

**Threading algorithm (JWZ):**

1. Parent-link via `in_reply_to` — if the referenced message_id is in the corpus
2. Fall back to last entry in `references` header
3. Subject-merge orphans: emails sharing a normalised subject (strip Re:/Fwd:, lowercase) but lacking In-Reply-To are grouped under the earliest message as root

**Incremental:** re-threads only when source meta.json files change (mtime comparison). Use `--force` to rebuild unconditionally.

**Email meta.json fields used:** `id`, `kind`, `message_id`, `in_reply_to`, `references`, `subject`, `from`, `date`/`ingested_at`.

```bash
aidevops email build   [knowledge-root] [--force]        # Rebuild thread index
aidevops email thread  <message-id> [knowledge-root]     # Look up thread by message-id
```

Helper: `.agents/scripts/email-thread-helper.sh`.
Python module: `.agents/scripts/email_thread.py`.

## Filtered Mailbox Collection and Case Routing

Version 2 rules in `_config/email-filters.json` are shared by mailbox collection
and post-ingest case routing. Copy the sanitized template from
`.agents/templates/email-filters-config.json`; keep real addresses, domains,
references, and phrases in the private working configuration.

### Deterministic match grammar

Each rule has a stable `id`, optional `mailboxes` and `folders` selectors, and a
`match` object containing `all` and/or `any` condition arrays. Every `all`
condition must match and at least one `any` condition must match when `any` is
present.

| Field | Operators | Behavior |
|-------|-----------|----------|
| `from`, `to`, `cc`, available `bcc` | `exact_address`, `exact_domain` | Parsed addr-spec or complete IDNA-normalized domain equality; never suffix matching |
| `direction` | `equals` | `sent`, `received`, or `either`, relative to verified mailbox identities |
| `subject`, `body`, `header`, `attachment_name` | `exact`, `phrase`, `keyword`, `reference` | NFKC Unicode normalization; configurable case sensitivity; deterministic whitespace |
| `reference`, `keyword`, `phrase` | same text operators | Shorthand fields with `target` set to `subject`, `body`, `attachment_name`, or the default subject+body corpus |

`keyword` uses Unicode word boundaries. `reference` additionally treats hyphens
as identifier characters, so `CASE-12` cannot match `CASE-123`. A missing BCC
field is a coverage gap, not a successful negative assertion.

### Collection authority and privacy

- IMAP selects folders read-only and fetches with `BODY.PEEK[]`; JMAP uses read
  methods. Filtered collection never marks, moves, labels, flags, deletes,
  replies to, or sends mail.
- Server search predicates are optional candidate optimizations only.
  `email_match_rules.py` always performs the final local check.
- Only locally confirmed matches enter `_knowledge/inbox/`. Unmatched content
  is not written; state records only counts, field names, timestamps, and rule
  IDs/digests.
- A mailbox keeps legacy unfiltered polling until a collection rule targets it.
  Once targeted, collection is fail-closed across that mailbox: folders without
  a selected rule persist nothing, and disabling every selected rule pauses
  collection rather than reverting to unfiltered reads. Rules with
  `collection: false` remain routing-only and do not enable this gate.
- An unreadable or explicitly unsupported filter-config version stops polling;
  it never silently falls back to unfiltered persistence. Versionless legacy
  routing configs remain post-ingest-only before collection migration. After
  filtered lineage state exists, a missing or versionless config also stops
  polling; an explicit v2 config is required to opt back into unfiltered reads.
- Each mailbox/folder/transport/rule digest has an independent checkpoint in
  `_knowledge/.imap-state.json`. A rule edit creates a new lineage and runs the
  configured bounded `backfill.limit` (default 500, maximum 5000). IMAP and JMAP
  checkpoints record content-free candidate totals, continuation state, and a
  `backfill_truncated` marker when more history existed than the configured bound.
- Overlapping rules write one deterministic staging file plus an adjacent,
  content-free `.collection.json` receipt containing transport, mailbox, folder,
  opaque message key, and matching rule IDs/digests. Canonical ingest merges
  those receipts into `meta.json.collection_refs`, including when the message
  already exists, while preserving one message/attachment graph.

For JMAP provider accounts, `email-mailbox-helper.sh sync <account> --folder
<folder>` auto-detects `_config/email-filters.json`. It gives the provider
account slug to the rule's `mailboxes` selector, downloads raw RFC-822 blobs only
after local matches, and stages those blobs in `_knowledge/inbox/`. The JMAP
collector uses only `Mailbox/get`, `Email/query`, `Email/queryChanges`,
`Email/get`, and authenticated blob downloads; terminal failures retain the
prior checkpoint and remove incomplete staging. Malformed downloaded MIME is a
terminal failure and never enters the inbox.

JMAP callers can also pass `--filter-config`, `--rule-id`, and repeatable
`--account-identity` to `email_jmap_adapter.py fetch_body`. A non-match returns
only a content-free explanation and exit status 3, so callers cannot persist an
unconfirmed body accidentally.

### Case actions and compatibility

`email-filter-helper.sh` uses the same v2 matcher for already-ingested messages.
`attach_to_case` creates a source reference; `set_sensitivity` updates source
metadata. Interactive `filter add` rules default to `collection: false` so a
new routing rule cannot unexpectedly suppress mailbox ingestion. Existing
versionless legacy predicates remain post-ingest compatible but never become
collection authorities. An explicit `collection: true` rule runs actions only
when canonical metadata contains its exact rule ID/digest receipt; routing-only
rules remain global. Routing state includes an enabled-ruleset digest and
per-source collection-reference digests. Match/action edits replay canonical
sources, and a receipt merged into pre-existing evidence replays that source
without reprocessing unchanged evidence.

```bash
aidevops email filter tick   [knowledge-root]
aidevops email filter list   [knowledge-root]
aidevops email filter add    [knowledge-root]
aidevops email filter test   <rule-name> [knowledge-root]
```

Dry-run explanations include only the rule ID, matched field names, and missing
field names. Helpers: `.agents/scripts/email_match_rules.py`,
`.agents/scripts/email-poll-helper.sh`, `.agents/scripts/email_jmap_collection.py`,
`.agents/scripts/email-mailbox-helper.sh`, and
`.agents/scripts/email-filter-helper.sh`.
