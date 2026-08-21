<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WP-CLI Command Reference

Quick-reference for common WP-CLI commands, organized by domain. For site configuration, access patterns, and workflows, see `wp-admin.md`.

## Content Management

### Posts & Pages

```bash
wp post list --post_type=post --post_status=publish
wp post create --post_type=post --post_title="New Post" --post_status=draft
wp post update 123 --post_title="Updated Title"
wp post delete 123 --force
wp post meta get 123 _thumbnail_id
wp post meta update 123 custom_field "value"
```

### Custom Post Types

```bash
wp post-type list
wp post list --post_type=product --post_status=any
wp post create --post_type=product --post_title="New Product" --post_status=publish
```

### Media

```bash
wp media list
wp media import https://example.com/image.jpg
wp media regenerate --yes
wp post list --post_type=attachment --post_status=inherit --meta_key=_wp_attached_file --format=ids | xargs wp post delete
```

### Taxonomies

```bash
wp term list category
wp term create category "New Category" --description="Description"
wp term list post_tag
wp post term add 123 category "Category Name"
```

### Menus

```bash
wp menu list
wp menu create "Main Menu"
wp menu item add-post main-menu 123
wp menu item add-custom main-menu "Custom Link" https://example.com
wp menu location assign main-menu primary
```

## Plugin Management

```bash
wp plugin list [--status=active]
wp plugin install kadence-blocks --activate
wp plugin install antispam-bee fluent-smtp query-monitor --activate
wp plugin update kadence-blocks
wp plugin update --all [--dry-run]
wp plugin deactivate plugin-name [--all]
wp plugin delete plugin-name
wp plugin search "seo" --fields=name,slug,rating
```

## WordPress Core

```bash
wp core version
wp core check-update
wp core update && wp core update-db
wp option get siteurl
wp option update blogname "My Site"
```

## User Management

```bash
wp user list [--role=administrator]
wp user create john john@example.com --role=editor --user_pass=password
wp user update john --display_name="John Doe"
wp user delete john --reassign=1
wp user reset-password john
wp role list
wp cap add custom_role edit_posts
wp user list-caps john
```

## Backup & Restore

```bash
# Backup
wp db export backup-$(date +%Y%m%d).sql
tar -czf ~/backups/$(date +%Y%m%d)/wp-content.tar.gz wp-content/

# Restore
wp db import backup.sql
wp search-replace 'https://old.com' 'https://new.com' [--dry-run]
wp cache flush && wp rewrite flush
```

## Security

```bash
# Checks
wp core verify-checksums
wp plugin verify-checksums --all
wp user list --role=administrator
find . -type f -perm 777

# Hardening
wp config shuffle-salts
wp config set DISALLOW_FILE_EDIT true --raw
wp config set WP_DEBUG false --raw

# Spam
wp comment delete $(wp comment list --status=spam --format=ids) --force
wp comment list --status=hold
```

## Site Health & Performance

```bash
# Diagnostics
wp site health status
wp cron event list
wp cron event run --due-now
wp transient delete --expired

# Performance
wp db optimize
wp db repair
wp post delete $(wp post list --post_type=revision --format=ids) --force
wp post delete $(wp post list --post_type=post --post_status=auto-draft --format=ids) --force

# Cache
wp cache flush
wp rewrite flush
# Legacy Closte estates only: use the closte.md Mutation Guard, not these independently
wp closte devmode enable   # Before changes
wp closte devmode disable  # After changes
```

## Multisite

```bash
# Sites
wp site list
wp site create --slug=newsite --title="New Site"
wp site activate 2

# Network plugins
wp plugin list --network
wp plugin activate plugin-name --network

# Always use --url for per-site commands
wp post list --url=https://subsite.example.com
wp option get blogname --url=https://subsite.example.com
```

## SEO

```bash
wp plugin list | grep -E "seo|rank-math"
wp option get blogname
wp option update blogname "New Site Title"
wp rewrite structure && wp rewrite flush
wp option update rank_math_sitemap_last_modified $(date +%s)
```
