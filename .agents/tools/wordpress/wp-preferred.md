---
description: WordPress preferred plugins and theme recommendations
mode: subagent
tools: { read: true, write: false, edit: false, bash: false, glob: true, grep: true, webfetch: true, task: true }
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Preferred Plugins & Theme

<!-- AI-CONTEXT-START -->

## Quick Reference

**Theme**: Kadence (`kadence`, <https://wordpress.org/themes/kadence/>) -- Pro: `kadence-pro` (<https://www.kadencewp.com/kadence-theme/pro/>)
**Plugins**: 127+ curated across 19 categories. Selection: speed-first, WP standards, well-documented, non-breaking updates, stack-tested.

```bash
# Minimal stack
wp plugin install antispam-bee compressx fluent-smtp kadence-blocks simple-cloudflare-turnstile --activate
wp theme install kadence --activate
```

**Pro/Premium**: Require license activation via vendor dashboards. Keys in `~/.config/aidevops/credentials.sh` (see `api-key-setup.md`). Git Updater for Git-hosted plugin updates.

**URL convention**: Free plugins at `https://wordpress.org/plugins/{slug}/`. Premium vendor URLs in [Premium Sources](#premium-plugin-sources) below.

<!-- AI-CONTEXT-END -->

## Plugins by Category

### Minimal (Essential Starter Stack)

`antispam-bee` Antispam Bee | `compressx` CompressX | `fluent-smtp` FluentSMTP | `kadence-blocks` Kadence Blocks | `simple-cloudflare-turnstile` Simple Cloudflare Turnstile

### Admin

`admin-bar-dashboard-control` Admin Bar & Dashboard Control | `admin-columns-pro`\* Admin Columns Pro | `admin-menu-editor-pro`\* Admin Menu Editor Pro | `wp-toolbar-editor`\* AME Toolbar Editor | `hide-admin-notices` Hide Admin Notices | `magic-login` Magic Login | `mainwp-child` MainWP Child | `mainwp-child-reports` MainWP Child Reports | `manage-notification-emails` Manage Notification E-mails | `network-plugin-auditor` Network Plugin Auditor | `plugin-groups` Plugin Groups | `plugin-toggle` Plugin Toggle | `user-switching` User Switching

### AI

`ai-engine` AI Engine | `ai-engine-pro`\* AI Engine Pro

### CMS (Content Management)

`auto-post-scheduler` Auto Post Scheduler | `auto-upload-images` Auto Upload Images | `block-options` EditorsKit | `bookmark-card` Bookmark Card | `browser-shots` Browser Shots | `bulk-actions-select-all` Bulk Actions Select All | `carbon-copy` Carbon Copy | `code-block-pro` Code Block Pro | `distributor` Distributor | `iframe-block` iFrame Block | `ics-calendar` ICS Calendar | `mammoth-docx-converter` Mammoth .docx converter | `nav-menu-roles` Nav Menu Roles | `ninja-tables` Ninja Tables | `ninja-tables-pro`\* Ninja Tables Pro | `post-draft-preview` Post Draft Preview | `post-type-switcher` Post Type Switcher | `simple-custom-post-order` Simple Custom Post Order | `simple-icons` Popular Brand SVG Icons | `sticky-posts-switch` Sticky Posts - Switch | `super-speedy-imports` Super Speedy Imports | `term-management-tools` Term Management Tools | `the-paste` The Paste | `wikipedia-preview` Wikipedia Preview

### Compliance (Privacy & Legal)

`avatar-privacy` Avatar Privacy | `complianz-gdpr` Complianz GDPR | `complianz-gdpr-premium`\* Complianz Privacy Suite Premium | `complianz-terms-conditions` Complianz Terms & Conditions | `really-simple-ssl` Really Simple SSL | `really-simple-ssl-pro`\* Really Simple Security Pro

### CRM & Forms (Fluent Ecosystem)

`fluent-boards` Fluent Boards | `fluent-boards-pro`\* Fluent Boards Pro | `fluent-booking` FluentBooking | `fluent-booking-pro`\* FluentBooking Pro | `fluent-community` FluentCommunity | `fluent-community-pro`\* FluentCommunity Pro | `fluent-crm` FluentCRM | `fluentcampaign-pro`\* FluentCRM Pro | `fluent-roadmap` Fluent Roadmap | `fluent-support` Fluent Support | `fluent-support-pro`\* Fluent Support Pro | `fluentform` Fluent Forms | `fluentformpro`\* Fluent Forms Pro | `fluentforms-pdf` Fluent Forms PDF Generator | `fluentform-signature`\* Fluent Forms Signature Addon

### eCommerce (WooCommerce)

`woocommerce` WooCommerce | `kadence-woocommerce-email-designer` Kadence WooCommerce Email Designer | `kadence-woo-extras`\* Kadence Shop Kit | `pymntpl-paypal-woocommerce` Payment Plugins for PayPal | `woo-stripe-payment` Payment Plugins for Stripe

### Kadence Ecosystem

Also listed elsewhere: `kadence`+`kadence-pro` (Theme), `kadence-blocks` (Minimal), `kadence-woo-extras`+`kadence-woocommerce-email-designer` (eCommerce).

`kadence-blocks-pro`\* Kadence Blocks PRO | `kadence-build-child-defaults`\* Kadence Child Theme Builder | `kadence-cloud`\* Kadence Pattern Hub | `kadence-conversions`\* Kadence Conversions | `kadence-simple-share` Kadence Simple Share | `kadence-starter-templates` Starter Templates by Kadence WP

### LMS (Learning Management)

`tutor` Tutor LMS | `tutor-pro`\* Tutor LMS Pro | `tutor-lms-certificate-builder`\* Tutor LMS Certificate Builder

### Media

`easy-watermark` Easy Watermark | `enable-media-replace` Enable Media Replace | `image-copytrack` Image Copytrack | `imsanity` Imsanity | `media-file-renamer` Media File Renamer | `media-file-renamer-pro`\* Media File Renamer Pro | `safe-svg` Safe SVG

### SEO

`burst-statistics` Burst Statistics | `hreflang-manager` Hreflang Manager | `link-insight`\* Link Whisper | `official-facebook-pixel` Meta Pixel for WordPress | `post-to-google-my-business` Post to Google My Business | `pretty-link` PrettyLinks | `seo-by-rank-math` Rank Math SEO | `rank-optimizer-pro`\* Rank Math SEO PRO | `readabler` Readabler | `remove-cpt-base` Remove CPT base | `remove-old-slugspermalinks` Slugs Manager | `syndication-links` Syndication Links | `ultimate-410` Ultimate 410 | `webmention` Webmention

### Speed & Performance

Also see: `compressx` (Minimal), `hreflang-manager`+`performant-translations` (translation support).

`disable-wordpress-updates` Disable All WordPress Updates | `disable-dashboard-for-woocommerce-pro`\* Disable Bloat PRO | `flying-analytics` Flying Analytics | `flying-pages` Flying Pages | `flying-scripts` Flying Scripts | `freesoul-deactivate-plugins` Freesoul Deactivate Plugins | `freesoul-deactivate-plugins-pro`\* Freesoul Deactivate Plugins PRO | `growthboost`\* Scalability Pro | `http-requests-manager` HTTP Requests Manager | `index-wp-mysql-for-speed` Index WP MySQL For Speed | `litespeed-cache` LiteSpeed Cache | `performant-translations` Performant Translations | `wp-widget-disable` Widget Disable

### Advanced (Developer Tools)

`acf-better-search` ACF: Better Search | `secure-custom-fields` Secure Custom Fields | `code-snippets` Code Snippets | `code-snippets-pro`\* Code Snippets Pro | `git-updater` Git Updater | `indieweb` IndieWeb | `waspthemes-yellow-pencil`\* YellowPencil Pro

### Debug & Troubleshooting

Also see: `user-switching` (Admin), `gotmls` (Security).

`advanced-database-cleaner` Advanced Database Cleaner | `advanced-database-cleaner-pro`\* Advanced Database Cleaner PRO | `code-profiler-pro`\* Code Profiler Pro | `debug-log-manager` Debug Log Manager | `query-monitor` Query Monitor | `string-locator` String Locator | `wp-crontrol` WP Crontrol

### Security

Also see: `antispam-bee`+`simple-cloudflare-turnstile` (Minimal), `really-simple-ssl`/`-pro` (Compliance).

`comment_goblin`\* Comment Goblin | `gotmls` Anti-Malware Security

### Setup & Import

`wordpress-importer` WordPress Importer

### Social

`social-engine` Social Engine | `social-engine-pro`\* Social Engine Pro | `wp-social-ninja` WP Social Ninja | `wp-social-ninja-pro`\* WP Social Ninja Pro | `wp-social-reviews` WP Social Reviews

### Migration & Backup

`wp-migrate-db-pro`\* WP Migrate | `wp-migrate-db-pro-compatibility`\* WP Migrate Compatibility

### Multisite

Also see: `network-plugin-auditor` (Admin).

`ultimate-multisite` Ultimate Multisite

### Hosting-Specific

Legacy Closte estates only: `closte-requirements`, `eos-deactivate-plugins` (Closte variant of Freesoul Deactivate Plugins).

## Premium Plugin Sources

Slugs marked \* above. Free plugins: `https://wordpress.org/plugins/{slug}/`.

| Slug | Vendor URL |
|------|-----------|
| `kadence-pro` | <https://www.kadencewp.com/kadence-theme/pro/> |
| `admin-columns-pro` | <https://www.admincolumns.com/> |
| `admin-menu-editor-pro` | <https://adminmenueditor.com/upgrade-to-pro/> |
| `wp-toolbar-editor` | <https://adminmenueditor.com/> |
| `ai-engine-pro` | <https://meowapps.com/plugin/ai-engine/> |
| `ninja-tables-pro` | <https://wpmanageninja.com/ninja-tables/> |
| `complianz-gdpr-premium` | <https://complianz.io/> |
| `really-simple-ssl-pro` | <https://really-simple-ssl.com/pro/> |
| `fluent-boards-pro` | <https://fluentboards.com/> |
| `fluent-booking-pro` | <https://fluentbooking.com/> |
| `fluent-community-pro` | <https://fluentcommunity.co/> |
| `fluentcampaign-pro` | <https://fluentcrm.com/> |
| `fluent-support-pro` | <https://fluentsupport.com/> |
| `fluentformpro` | <https://fluentforms.com/> |
| `fluentform-signature` | <https://fluentforms.com/> |
| `kadence-woo-extras` | <https://www.kadencewp.com/> |
| `kadence-blocks-pro` | <https://www.kadencewp.com/kadence-blocks/pro/> |
| `kadence-build-child-defaults` | <https://www.kadencewp.com/> |
| `kadence-cloud` | <https://www.kadencewp.com/> |
| `kadence-conversions` | <https://www.kadencewp.com/> |
| `tutor-pro` | <https://www.themeum.com/product/tutor-lms/> |
| `tutor-lms-certificate-builder` | <https://www.themeum.com/product/tutor-lms-certificate-builder/> |
| `media-file-renamer-pro` | <https://meowapps.com/plugin/media-file-renamer/> |
| `link-insight` | <https://linkwhisper.com/> |
| `rank-optimizer-pro` | <https://rankmath.com/> |
| `disable-dashboard-for-woocommerce-pro` | <https://disablebloat.com/> |
| `freesoul-deactivate-plugins-pro` | <https://freesoul-deactivate-plugins.com/> |
| `growthboost` | <https://scalability.pro/> |
| `code-snippets-pro` | <https://codesnippets.pro/> |
| `waspthemes-yellow-pencil` | <https://yellowpencil.waspthemes.com/> |
| `advanced-database-cleaner-pro` | <https://sigmaplugin.com/downloads/wordpress-advanced-database-cleaner> |
| `code-profiler-pro` | <https://codeprofiler.io/> |
| `comment_goblin` | <https://commentgoblin.com/> |
| `social-engine-pro` | <https://meowapps.com/plugin/social-engine/> |
| `wp-social-ninja-pro` | <https://wpsocialninja.com/> |
| `wp-migrate-db-pro` | <https://deliciousbrains.com/wp-migrate-db-pro/> |
| `wp-migrate-db-pro-compatibility` | <https://deliciousbrains.com/wp-migrate-db-pro/> |

## WP-CLI Install Stacks

```bash
# Admin
wp plugin install admin-bar-dashboard-control hide-admin-notices manage-notification-emails plugin-toggle user-switching --activate

# Performance
wp plugin install flying-analytics flying-pages flying-scripts freesoul-deactivate-plugins index-wp-mysql-for-speed performant-translations --activate

# SEO
wp plugin install seo-by-rank-math burst-statistics syndication-links webmention --activate

# Forms & CRM
wp plugin install fluentform fluent-crm fluent-smtp fluent-support --activate

# WooCommerce
wp plugin install woocommerce kadence-woocommerce-email-designer pymntpl-paypal-woocommerce woo-stripe-payment --activate

# Debug
wp plugin install query-monitor debug-log-manager string-locator wp-crontrol user-switching --activate
```

## Related Documentation

| Topic | File |
|-------|------|
| WordPress development | `workflows/wp-dev.md` |
| WordPress admin | `workflows/wp-admin.md` |
| LocalWP database access | `localwp.md` |
| MainWP fleet management | `mainwp.md` |
| API key management | `api-key-setup.md` |
