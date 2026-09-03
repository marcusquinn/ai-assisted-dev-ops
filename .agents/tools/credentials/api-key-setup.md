---
description: API key setup with secure local storage
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# API Key Setup Guide - Secure Local Storage

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommended**: `aidevops secret set NAME` (gopass encrypted, AI-safe) — see `gopass.md`
- **Plaintext fallback**: `~/.config/aidevops/credentials.sh` (600 permissions)
- **Setup**: `bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh setup`
- **Multi-tenant**: `credential-helper.sh` — see `multi-tenant.md`
- **Common Services**: codacy-project-token, sonar-token, coderabbit-api-key, hcloud-token-*, openai-api-key

**Security**: NEVER accept secret values in AI conversation. Instruct users to run `aidevops secret set NAME` at their terminal.

<!-- AI-CONTEXT-END -->

## Storage Layout

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/credentials.sh` | API keys as shell exports | 600 |
| `~/.config/aidevops/tenants/{tenant}/credentials.sh` | Per-tenant keys (see `multi-tenant.md`) | 600 |
| `~/.config/aidevops/` | Secrets directory | 700 |

Keys stored ONLY here or in gopass — NEVER in repository files. Sourced by shell on startup.

## Setup

### 1. Initialize

```bash
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh setup
```

Creates `~/.config/aidevops/` (700), `credentials.sh` (600), and adds a sourcing line to `~/.zshrc` (and `~/.bashrc`/`~/.bash_profile` if present).

### 2. Store API Keys

```bash
# By service name (auto-converts to UPPER_CASE export)
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh set vercel-token YOUR_TOKEN
# → export VERCEL_TOKEN="YOUR_TOKEN"

# By env var name directly
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh set SUPABASE_KEY abc123
# → export SUPABASE_KEY="abc123"

# Parse an export command from a service dashboard
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh add 'export VERCEL_TOKEN="abc123"'
```

### 3. Common Services

```bash
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh set <service-name> YOUR_TOKEN
```

| Service | Key name | Token URL |
|---------|----------|-----------|
| Codacy | `codacy-project-token` | https://app.codacy.com/account/api-tokens |
| SonarCloud | `sonar-token` | https://sonarcloud.io/account/security |
| CodeRabbit | `coderabbit-api-key` | https://app.coderabbit.ai/settings |
| Hetzner Cloud | `hcloud-token-<project>` | https://console.hetzner.cloud/projects/*/security/tokens |
| OpenAI | `openai-api-key` | https://platform.openai.com/api-keys |
| Daytona | `daytona-api-key` | https://app.daytona.io/settings/api-keys |

**Multi-account naming**: When you hold credentials for several accounts on the same provider at once (personal + work GitHub, multiple OpenAI projects, several Hetzner projects), suffix the bare name with `-<account>` / `_<ACCOUNT>` — e.g. `github-token-personal` and `github-token-work`, or `hcloud-token-project-a` and `hcloud-token-project-b`. The bare provider name remains the default for the single-account case. Full convention: `gopass.md` "Naming with multiple accounts".

**GPT Image 2 accounts**: OpenCode image generation deliberately uses a more
specific key namespace so Platform billing identities cannot be confused with
ChatGPT OAuth pool identities:

```bash
aidevops secret set OPENAI_IMAGE_API_KEY_PERSONAL
aidevops secret set OPENAI_IMAGE_API_KEY_WORK
```

Select the matching alias (`PERSONAL` or `WORK`) with `auth: "api"` in
`gpt_image_generate`. Aliases contain only letters, numbers, and underscores.
The non-secret `AIDEVOPS_OPENAI_IMAGE_ACCOUNT` setting may define a deliberate
default alias, but API billing still requires explicit `auth: "api"`. The tool
never falls back to `OPENAI_API_KEY` or silently chooses among named keys.

**Provider token label + value pairs**: Secure backends (via `aidevops secret set <NAME>`, preferring `gopass` over plaintext) and the plaintext fallback both store only one value per name. If a provider has a non-sensitive local token label and a sensitive access token value, keep them separate: `<PROVIDER>_<ORG>_<PURPOSE>_TOKEN_NAME` for the label and `<PROVIDER>_<ORG>_<PURPOSE>_ACCESS_TOKEN` for the value. Add a developer or device discriminator, such as `_DEV_A` or `_LAPTOP_2`, before `TOKEN_NAME` / `ACCESS_TOKEN` when a shared store or workstation holds tokens for multiple developers or devices. Never document token values; token labels may be documented only when they are non-sensitive.

### 4. Verify

```bash
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh list   # Services (keys redacted)
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh get sonar-token  # Specific key
```

## How It Works

`credentials.sh` contains shell exports (`export SONAR_TOKEN="xxx"`). Shell startup sources it automatically for interactive terminals:

```bash
# Added to ~/.zshrc (and ~/.bashrc/~/.bash_profile if present) by setup:
[[ -f ~/.config/aidevops/credentials.sh ]] && source ~/.config/aidevops/credentials.sh
```

Interactive terminals inherit these env vars after their shell startup file runs. aidevops daemons and scheduled jobs do not source `.bashrc`, `.zshrc`, or `.profile`; they read `~/.config/aidevops/credentials.sh` directly when needed. Put persistent headless routing pins such as `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST` in `credentials.sh`, not only in a shell rc file.

## Permissions

```bash
# Verify
ls -la ~/.config/aidevops/
# drwx------ (700) directory, -rw------- (600) credentials.sh

# Fix if needed
chmod 700 ~/.config/aidevops && chmod 600 ~/.config/aidevops/credentials.sh
```

## Troubleshooting

**Key not found**: Check storage (`setup-local-api-keys.sh get service-name`), check env (`echo $SERVICE_NAME`), re-add if missing.

**Interactive changes not taking effect**: `source ~/.zshrc` (or `~/.bashrc`), or restart terminal. For pulse/systemd/cron behaviour, update `~/.config/aidevops/credentials.sh`; shell rc exports alone are not daemon-visible.

**Shell integration missing**: Re-run `setup-local-api-keys.sh setup` to add sourcing lines.

## Best Practices

1. **Prefer gopass** — `aidevops secret set` for encrypted storage
2. **Single source** — always add keys via `aidevops secret set`, `setup-local-api-keys.sh`, or `credential-helper.sh`
3. **Rotate every 90 days**, use minimal-scope tokens, monitor usage in provider dashboards
4. **Never commit** — API keys must never appear in git history
5. **AI-safe** — never accept secret values in AI conversation context

## Beyond API Keys

- **Encrypted storage (recommended)**: `tools/credentials/gopass.md`
- **Multi-tenant credentials**: `tools/credentials/multi-tenant.md`
- **Config files in git** (YAML/JSON with encrypted values): `tools/credentials/sops.md`
- **Directory encryption at rest**: `tools/credentials/gocryptfs.md`
- **Decision guide**: `tools/credentials/encryption-stack.md`
- **Project setup**: `aidevops init sops` to add SOPS support
