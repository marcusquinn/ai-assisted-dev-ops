---
description: Hostinger hosting management via REST API and SSH
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hostinger Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Shared/VPS/Cloud hosting, budget-friendly
- **API**: REST at `https://developers.hostinger.com`
- **Auth**: Bearer token in `~/.config/aidevops/credentials.sh` as `HOSTINGER_API_TOKEN`
- **SSH**: Port 65002, key auth (recommended) or password auth; framework prefers key when `ssh_identity_file` is configured
- **Credential scope**: Hostinger SSH access is hosting-account scoped, not domain scoped; inventory and group sites before requesting credentials
- **Panel**: Custom hPanel
- **No MCP required** — uses curl for API, ssh for key auth or sshpass for password auth

<!-- AI-CONTEXT-END -->

## Configuration

### Discover account boundaries first

Before asking for SSH credentials, use the Hostinger API token to inventory websites and group them by account `username`. Domains with the same username share one SSH login and must reuse one server/account configuration. Do not request or store duplicate credentials per domain.

Connection metadata (`ssh_host`, `ssh_port`, `ssh_user`, and domain paths) belongs in configuration and is not a password. Store only the shared password or private key securely. For WordPress fleets, prefer `wordpress-sites.json` `servers` plus per-site `server_ref`; `wp-helper.sh` supports an account-level `ssh_password_env` reference.

Name secrets by account alias rather than site, for example `HOSTINGER_SSH_PASSWORD_ACCOUNT_1`. Run commands with the referenced secret injected:

```bash
aidevops secret set HOSTINGER_SSH_PASSWORD_ACCOUNT_1
aidevops secret HOSTINGER_SSH_PASSWORD_ACCOUNT_1 -- \
  wp-helper.sh example-site plugin list
```

Only request another SSH credential when API inventory, the hosting panel, or a failed authenticated probe shows a genuinely different account/server.

### Legacy Hostinger helper

Copy template and edit with server details:

```bash
cp configs/hostinger-config.json.txt configs/hostinger-config.json
```

Config structure:

```json
{
  "sites": {
    "example.com": {
      "server": "server-hostname-or-ip",
      "port": 65002,
      "username": "u123456789",
      "ssh_identity_file": "~/.ssh/hostinger_ed25519",
      "domain_path": "/domains/example.com/public_html",
      "description": "Main website"
    }
  },
  "default_settings": {
    "port": 65002,
    "username_pattern": "u[0-9]+"
  }
}
```

SSH key setup (recommended):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hostinger_ed25519
# Upload ~/.ssh/hostinger_ed25519.pub via hPanel → SSH Keys
```

Password file setup (fallback):

```bash
echo 'your-hostinger-password' > ~/.ssh/hostinger_password
chmod 600 ~/.ssh/hostinger_password
brew install sshpass   # macOS
sudo apt-get install sshpass  # Linux
```

## Commands

```bash
# Site management
./.agents/scripts/hostinger-helper.sh list
./.agents/scripts/hostinger-helper.sh connect example.com
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la'

# File transfer
./.agents/scripts/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/
./.agents/scripts/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backup/

# Database
./.agents/scripts/hostinger-helper.sh exec example.com 'mysqldump -u username -p database_name > backup.sql'
```

## Security

- SSH key auth is recommended; set `ssh_identity_file` in site config (e.g. `~/.ssh/hostinger_ed25519`)
- Keep one credential per hosting account/server and reference it from every site on that account
- Do not put non-secret host, port, username, or domain-path metadata in the secret store
- Store passwords in files with 600 permissions; never commit them
- Port 65002 (non-standard); be aware of concurrent connection limits

Set web file permissions:

```bash
./.agents/scripts/hostinger-helper.sh exec example.com 'chmod 644 /domains/example.com/public_html/*.html'
./.agents/scripts/hostinger-helper.sh exec example.com 'chmod 755 /domains/example.com/public_html/scripts/'
```

## Troubleshooting

**Connection refused**: Verify SSH is enabled on your plan, check hostname and port 65002, confirm password.

**Permission denied**: Username format is `u` followed by numbers (e.g. `u123456789`). Check password file has 600 perms and sshpass is installed.

**File upload issues**:

```bash
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/'
./.agents/scripts/hostinger-helper.sh exec example.com 'df -h'
```

## Deployment

```bash
# Build and deploy
npm run build
./.agents/scripts/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/

# Verify
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/public_html/'
```

Backup before major changes:

```bash
DATE=$(date +%Y%m%d_%H%M%S)
./.agents/scripts/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backups/example.com_$DATE/
```
