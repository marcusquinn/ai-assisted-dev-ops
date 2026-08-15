---
description: WordPress admin - content management, plugins, maintenance, WP-CLI and MainWP integration
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  webfetch: true
  wordpress-mcp_*: true
  context7_*: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Admin Subagent

<!-- AI-CONTEXT-START -->
## Quick Reference

- **Sites Config**: `~/.config/aidevops/wordpress-sites.json`
- **Sites Template**: `configs/wordpress-sites.json.txt`
- **MainWP Config**: `configs/mainwp-config.json`
- **Working Dir**: `~/.aidevops/.agent-workspace/work/wordpress/`
- **WP-CLI Commands**: See `wp-cli-reference.md`
- **Preferred Plugins**: See `wp-preferred.md`

**Site Management Options**:

| Method | When to Use |
|--------|-------------|
| wp-helper.sh | Multi-site WP-CLI via wordpress-sites.json |
| WP-CLI (SSH) | Direct access, any site |
| MainWP | Fleet operations, connected sites |
| WordPress MCP | AI-powered admin actions |

**Shared-host credential rule:** Before requesting SSH access for several sites, identify hosting account/server boundaries. Configure one entry under `servers`, reference it from each site with `server_ref`, and store/inject one password or key per account—not one credential set per domain. Hostinger websites with the same account username share SSH access.

**wp-helper.sh Commands**:

```bash
wp-helper.sh --list                          # List all sites
wp-helper.sh production plugin list          # Run on specific site
wp-helper.sh --category client core version  # Run on category
wp-helper.sh --all plugin update --all       # Run on ALL sites
```

**SSH Access by Hosting Type**:

| Hosting | Auth Method | Access Pattern |
|---------|-------------|----------------|
| LocalWP | N/A | `cd ~/Local Sites/site/app/public && wp ...` |
| Hostinger | sshpass | `sshpass -f ~/.ssh/hostinger_password ssh user@host "wp ..."` |
| Closte | sshpass | `sshpass -f ~/.ssh/closte_password ssh user@host "wp ..."` |
| Hetzner | SSH key | `ssh root@server "wp ..."` |
| Cloudron | SSH key | Via Cloudron CLI or SSH |

**Related Subagents**:
- `@mainwp` — Fleet management (sites with MainWP Child)
- `@wp-dev` — Code changes, debugging
- `@hostinger` — Hostinger-hosted site operations
- `@hetzner` — Hetzner server management
- `@dns-providers`, `@cloudflare` — DNS/SSL issues
- `@ses` — Email delivery issues

**Always use Context7** for latest WP-CLI command syntax.
<!-- AI-CONTEXT-END -->

## Site Configuration

```bash
mkdir -p ~/.config/aidevops
cp ~/.aidevops/agents/configs/wordpress-sites.json.txt ~/.config/aidevops/wordpress-sites.json
```

```json
{
  "sites": {
    "local-dev": {
      "name": "Local Development",
      "type": "localwp",
      "path": "~/Local Sites/my-site/app/public",
      "multisite": false,
      "mainwp_connected": false
    },
    "production": {
      "name": "Production Site",
      "type": "hostinger",
      "url": "https://example.com",
      "ssh_host": "ssh.example.com",
      "mainwp_connected": true,
      "mainwp_site_id": 123
    }
  }
}
```

## WP-CLI Commands

Full command reference: `wp-cli-reference.md`. Covers content management, plugins, core, users, backup/restore, security, site health, multisite, and SEO.

## MainWP Integration

Use `@mainwp` for fleet operations (bulk updates, security scans, centralized backups, monitoring).

```bash
./.agents/scripts/mainwp-helper.sh sites production
./.agents/scripts/mainwp-helper.sh bulk-update-plugins production 123 124 125
./.agents/scripts/mainwp-helper.sh security-scan production 123
```

```bash
# Store MainWP API credentials
setup-local-api-keys.sh set mainwp-consumer-key-production YOUR_KEY
setup-local-api-keys.sh set mainwp-consumer-secret-production YOUR_SECRET
```

## Common Workflows

### Plugin Update Workflow

1. `wp plugin update --all --dry-run` — check what will change
2. `wp db export backup.sql` — backup first
3. `wp plugin update --all`
4. Test site, then `wp cache flush`

### Content Migration

1. `wp export --post_type=post`
2. `wp import export.xml --authors=create`
3. `wp search-replace 'old.com' 'new.com'`
4. `wp media regenerate`

### Site Cloning

1. `wp db export` + `tar -czf site.tar.gz .`
2. Transfer, extract, import database
3. `wp search-replace` + update `wp-config.php`

## Security Checklist

Before bulk operations:
1. **Backup first** — `wp db export`
2. **Staging test** — test on staging before production
3. **Security scan** — run `@mainwp` security scan after changes
4. **Audit log** — document significant changes
