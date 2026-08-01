---
description: Signal bot integration via signal-cli — registration, JSON-RPC daemon, messaging, access control, aidevops dispatch, Matterbridge bridging
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Bot Integration (signal-cli)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: E2E encrypted messaging — phone number required, minimal metadata, sealed sender
- **Bot tool**: [signal-cli](https://github.com/AsamK/signal-cli) (Java/GraalVM native) — GPL-3.0
- **Daemon API**: JSON-RPC 2.0 over HTTP (`:8080`), TCP (`:7583`), Unix socket, stdin/stdout, D-Bus; SSE: `GET /api/v1/events`
- **Bot data**: `~/.local/share/signal-cli/data/` (SQLite: `account.db`); never a knowledge-collector input
- **Registration**: SMS/voice + CAPTCHA, or QR code link to existing account
- **Docs**: https://github.com/AsamK/signal-cli/wiki
- **Private knowledge**: offline pre-captured receive notifications only; see `content/social-signal.md`

| Criterion | Signal | SimpleX | Matrix | Telegram |
|-----------|--------|---------|--------|----------|
| User identifiers | Phone number (hidden via usernames) | None | `@user:server` | Phone number |
| E2E encryption | Default, all messages | Default, all messages | Opt-in (rooms) | Opt-in, 1:1 only |
| Server metadata | Minimal (sealed sender) | Stateless (memory only) | Full history stored | Full |
| User base | 1B+ installs, mainstream | Niche, privacy-focused | Technical, federated | 900M+, mainstream |
| Best for | Mainstream secure comms | Maximum privacy | Team collaboration | Large groups, bots |

<!-- AI-CONTEXT-END -->

## Privacy, Security, and Access Control

**Servers store**: phone number (hashed), push tokens, registration/last-connection dates. **Not stored**: message content, contact lists, group memberships, who messages whom (sealed sender). Keys stored locally at `~/.local/share/signal-cli/data/+1234567890/account.db`.

**Bot security**: (1) treat all inbound as untrusted — sanitize before AI/shell; (2) allowlist by E.164/UUID; (3) sandbox commands; (4) isolate credentials; (5) scan with `prompt-guard-helper.sh` before AI dispatch.

Cross-reference: `tools/security/opsec.md`, `tools/credentials/gopass.md`, `tools/security/prompt-injection-defender.md`

### Knowledge collector boundary

Bot operations in this reference are not knowledge-ingestion instructions. The collector
in `scripts/knowledge_social_signal.py` accepts only a bounded, mode-0600 file containing
pre-captured `receive` notifications whose account identity is present and matches a
private config. It has no process, network, socket, account-database, key, send, receipt,
typing, reaction, trust, contact/group, remote-delete, registration, or link route.

As reviewed on 2026-07-31, the supported schema is pinned to unofficial `signal-cli`
0.14.6. Live collection is not exposed because `receive` sends default delivery receipts
even when optional read receipts are disabled. No official third-party message
export/backup contract was validated. Stories and view-once payloads are excluded;
disappearing messages become content-free tombstones; pre-link and identity-change
history remain explicit unavailable coverage. See `content/social-signal.md` for the full
capability and retention table.

**Access control** — no built-in allowlists; filter on sender at the application layer. Identifier types: E.164 (`+XXXXXXXXXXX`), ACI UUID (`a1b2c3d4-...`), PNI (`PNI:a1b2c3d4-...`), username (`u:username.NNN`).

```python
ALLOWED = {"+1234567890", "+0987654321"}
def handle_message(envelope):
    sender = envelope.get("sourceNumber", "")
    if sender not in ALLOWED:
        return  # silently ignore
```

```bash
signal-cli -a +1234567890 block +BLOCKED_NUMBER
signal-cli -a +1234567890 unblock +BLOCKED_NUMBER
signal-cli --trust-new-identities on-first-use   # default (also: never, always)
signal-cli -a +1234567890 trust -v VERIFIED_SAFETY_NUMBER +0987654321
```

## Daemon Mode (JSON-RPC)

### HTTP (recommended for bots)

```bash
signal-cli -a +1234567890 daemon --http [0.0.0.0:8080]  # default: localhost:8080
signal-cli daemon --http                                  # multi-account
```

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/rpc` | POST | JSON-RPC request (single or batch) |
| `/api/v1/events` | GET | Server-Sent Events stream (incoming messages) |
| `/api/v1/check` | GET | Health check (200 OK) |

Other transports: TCP (`:7583`), Unix socket, stdin/stdout (`jsonRpc`), D-Bus. Multiple simultaneous: `daemon --http --socket --dbus`.

Daemon options: `--ignore-attachments`, `--ignore-stories`, `--send-read-receipts`, `--receive-mode` (`on-start`|`on-connection`|`manual`).

### Systemd Service

```ini
[Unit]
Description=signal-cli JSON-RPC daemon
After=network.target
[Service]
Type=simple
User=signal-cli
ExecStart=/usr/local/bin/signal-cli -a +1234567890 daemon --http 127.0.0.1:8080
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now signal-cli
```

### JSON-RPC API

Standard JSON-RPC 2.0. Multi-account mode: include `"account":"+1234567890"` in params.

```json
{"jsonrpc":"2.0","method":"send","params":{"recipient":["+0987654321"],"message":"Hello"},"id":"1"}
{"jsonrpc":"2.0","result":{"timestamp":1631458508784},"id":"1"}
```

Incoming message notification (SSE / stdout): `{"jsonrpc":"2.0","method":"receive","params":{"envelope":{"source":"+1234567890","sourceUuid":"a1b2c3d4-...","sourceName":"Contact Name","timestamp":1631458508784,"dataMessage":{"message":"Hello!","expiresInSeconds":0,"attachments":[]}}}}`

**Key methods**:

- **Messaging**: `send` (recipient/groupId, message, attachments, mention, quoteTimestamp, editTimestamp, sticker, viewOnce, textStyle), `sendReaction`, `sendTyping`, `sendReceipt`, `remoteDelete`, `sendPollCreate`, `sendPollVote`
- **Groups**: `updateGroup` (name, description, members, removeMember, admin, link, expiration), `quitGroup`, `joinGroup`, `listGroups`
- **Account**: `register`/`verify`/`unregister`, `updateAccount`, `updateProfile`, `listContacts`/`listIdentities`/`listDevices`, `getUserStatus`, `block`/`unblock`, `startLink`/`finishLink`

```bash
curl -s -X POST http://localhost:8080/api/v1/rpc -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"send","params":{"recipient":["+0987654321"],"message":"Hello"},"id":"1"}'
curl -N http://localhost:8080/api/v1/events  # SSE stream
curl http://localhost:8080/api/v1/check      # health check
```

## Registration

**QR Code Linking (recommended)** — links signal-cli as secondary device (up to 5 per account):

```bash
signal-cli link -n "aidevops-bot" | tee >(xargs -L 1 qrencode -t utf8)
# Scan QR: Settings > Linked Devices > Link New Device
signal-cli -a +1234567890 receive  # sync contacts/groups
```

**SMS/Voice Verification**:

```bash
signal-cli -a +1234567890 register [--voice]
signal-cli -a +1234567890 verify 123-456 [--pin YOUR_PIN]
```

**CAPTCHA** (almost always required): Open https://signalcaptchas.org/registration/generate.html on the **same external IP** as signal-cli, solve, right-click "Open Signal" link, copy URL:

```bash
signal-cli -a +1234567890 register --captcha "signalcaptcha://signal-recaptcha-v2.somecode.registration.somelongcode"
```

PIN management: `setPin`, `removePin` — see wiki.

## Installation

Docker or JVM install recommended. See [signal-cli wiki](https://github.com/AsamK/signal-cli/wiki).

```bash
# Docker (simplest)
docker pull ghcr.io/asamk/signal-cli
docker run -d --name signal-cli \
  -v signal-cli-data:/home/.local/share/signal-cli \
  -p 8080:8080 \
  ghcr.io/asamk/signal-cli:latest \
  daemon --http 0.0.0.0:8080

# JVM (requires JRE 25+)
VERSION=$(curl -Ls -o /dev/null -w %{url_effective} \
  https://github.com/AsamK/signal-cli/releases/latest | sed -e 's/^.*\/v//')
curl -L -O "https://github.com/AsamK/signal-cli/releases/download/v${VERSION}/signal-cli-${VERSION}.tar.gz"
sudo tar xf "signal-cli-${VERSION}.tar.gz" -C /opt
sudo ln -sf "/opt/signal-cli-${VERSION}/bin/signal-cli" /usr/local/bin/
```

GraalVM native binary (no JRE, experimental) and distro packages also available — see wiki. Native library bundled for x86_64 Linux/Windows/macOS; other architectures must provide `libsignal-client` ([wiki](https://github.com/AsamK/signal-cli/wiki/Provide-native-lib-for-libsignal)).

## CLI Messaging Reference

For bot integration, prefer JSON-RPC equivalents above.

```bash
signal-cli -a +1234567890 send -m "Hello" +0987654321                          # DM by number
signal-cli -a +1234567890 send -m "Hello" u:username.000                       # DM by username
signal-cli -a +1234567890 send -m "Hello group" -g GROUP_ID_BASE64             # group
signal-cli -a +1234567890 send -m "See attached" -a /path/to/file.pdf +DST     # attachment
signal-cli -a +1234567890 sendReaction -e "👍" -a +SRC -t TIMESTAMP +DST
signal-cli -a +1234567890 send -m "Reply" --quote-timestamp TS --quote-author +SRC +DST
signal-cli -a +1234567890 send -m "Hi X!" --mention "3:1:+DST" -g GROUP_ID    # mention
signal-cli -a +1234567890 send -m "BIG!" --text-style "10:3:BOLD"              # text style
signal-cli -a +1234567890 send -m "Corrected" --edit-timestamp ORIG_TS +DST   # edit
signal-cli -a +1234567890 remoteDelete -t TIMESTAMP +DST                       # delete
```

## Group Management

```bash
signal-cli -a +1234567890 updateGroup -n "Group Name" -m +0987654321 +1112223333
signal-cli -a +1234567890 updateGroup -g GROUP_ID -n "New Name" -d "Description" -e 3600
signal-cli -a +1234567890 updateGroup -g GROUP_ID -m +NEW -r +OLD --admin +ADMIN
# Permissions: --set-permission-add-member, --set-permission-send-messages (every-member|only-admins)
# Links: --link enabled/disabled, joinGroup --uri "https://signal.group/#..."
# Leave: quitGroup -g GROUP_ID --delete
# List: listGroups -d -o json
```

## Configuration

```bash
signal-cli --config /custom/path ...                                   # custom data dir
signal-cli --log-file /var/log/signal-cli.log --scrub-log ...          # logging (scrubs sensitive data)
cp ~/.local/share/signal-cli/data/+1234567890/account.db{,.bak.$(date +%Y%m%d)}  # bot maintenance only; never collector input
```

Options: `--service-environment live` (production, default), `--trust-new-identities on-first-use|always|never`, `--disable-send-log`.

## aidevops Bot Example (Shell)

```bash
#!/usr/bin/env bash
# Requires: signal-cli daemon --http on :8080, jq, curl
ALLOWED="+0987654321"

curl -sN http://localhost:8080/api/v1/events | while read -r line; do
  data="${line#data:}"
  [[ -z "$data" || "$data" == "$line" ]] && continue

  sender=$(echo "$data" | jq -r '.params.envelope.sourceNumber // empty')
  message=$(echo "$data" | jq -r '.params.envelope.dataMessage.message // empty')
  [[ -z "$message" || "$sender" != "$ALLOWED" ]] && continue

  curl -s -X POST http://localhost:8080/api/v1/rpc \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"send\",\"params\":{\"recipient\":[\"$sender\"],\"message\":\"Echo: $message\"},\"id\":\"$(date +%s)\"}"
done
```

## Matterbridge Integration

Matterbridge does **not** natively support Signal. Options: (1) [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) wraps signal-cli as REST — connect via [Matterbridge API gateway](https://github.com/42wim/matterbridge/wiki/API) with custom middleware; (2) lightweight middleware subscribing to SSE events and forwarding to Matterbridge API.

**Privacy warning**: Bridging to unencrypted platforms (Discord, Slack, IRC) breaks E2E encryption at the bridge boundary.

## Limitations

| Limitation | Detail |
|------------|--------|
| Phone number required | Must receive SMS or voice call at least once for verification |
| No multi-device as primary | Link signal-cli as secondary device via QR code |
| Version expiry | Releases older than ~3 months may stop working |
| Rate limiting | Registration, sending, and other operations are rate-limited |
| No voice/video calls | Text messaging, attachments, and protocol-level features only |
| Single instance per number | Cannot run two signal-cli instances for the same account simultaneously |
| Database migrations | Upgrading may migrate SQLite DB, preventing downgrade — always backup first |
| Entropy requirement | Cryptographic operations require sufficient random entropy (`haveged` on idle systems) |

**Exit codes**: 1 = user-fixable, 2 = unexpected, 3 = server/IO, 4 = untrusted key, 5 = rate limiting. Rate limit challenge: `submitRateLimitChallenge --challenge TOKEN --captcha "signalcaptcha://..."` (CAPTCHA: https://signalcaptchas.org/challenge/generate.html)

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/matterbridge.md` — Multi-platform chat bridge (40+ platforms)
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection defense for chat bots
- `tools/credentials/gopass.md` — Secure credential storage
- Signal Protocol spec: https://signal.org/docs/
- signal-cli wiki: https://github.com/AsamK/signal-cli/wiki
- signal-cli-rest-api: https://github.com/bbernhard/signal-cli-rest-api
