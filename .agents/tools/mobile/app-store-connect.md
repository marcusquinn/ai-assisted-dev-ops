---
description: App Store Connect CLI (asc) - manage iOS/macOS apps, builds, TestFlight, metadata, subscriptions, screenshots, and submissions from terminal
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# App Store Connect CLI — asc

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `brew install asccli` (NOT `brew install asc` — different package)
- **Auth**: `asc auth login --key-id KEY --issuer-id ISSUER --private-key-path ~/.asc/AuthKey.p8`
- **API key**: Create at https://appstoreconnect.apple.com/access/integrations/api
- **Project pin**: `asc init --app-id <id>` (saves `.asc/project.json`, auto-used by all commands)
- **Verify**: `asc auth check` | **Multi-account**: `asc auth use <name>`
- **Context resolution**: explicit `--app-id` > `.asc/project.json` > prompt user to `asc init` (CI must use `--app-id` or pre-run `asc init`)
- **GitHub**: https://github.com/tddworks/asc-cli (MIT, Swift, 130+ commands; v0.18.2 adds Resolution Center rejection details and attachment downloads through cookie-authenticated iris APIs; checked at release commit `97a60af`)
- **Website**: https://asccli.app | **Web apps**: [Command Center](https://asccli.app/command-center), [Console](https://asccli.app/console), [Screenshot Studio](https://asccli.app/editor)
- **Skills**: [Official](https://github.com/tddworks/asc-cli-skills) (27 command-group skills, checked at `6465c10feb89`) | [Community](https://github.com/rorkai/app-store-connect-cli-skills) (23 workflow skills for the separate community CLI, checked at `53c60a4945e5`)
- **Requirements**: macOS 13+, App Store Connect API key, `jq` (workflow scripts use `jq -r`)

**Dependency check**: Before any `asc` command:

```bash
command -v asc >/dev/null || { brew install asccli || exit 1; }
command -v jq >/dev/null || { brew install jq || exit 1; }
```

**Credential security**: `asc auth login` stores the private key PEM in `~/.asc/credentials.json`. Never commit this file. Use `--private-key-path` — never pass key content as an argument.

**CAEOAS**: Every JSON response includes an `affordances` field with state-aware next commands. Always follow affordances instead of constructing commands manually — they encode business rules the CLI enforces. Example: `submitForReview` only appears when `isEditable == true`.

<!-- AI-CONTEXT-END -->

## Command Groups

| Group | Commands | Purpose |
|-------|----------|---------|
| **versions** / **review-submissions** | `list`, `create`, `set-build`, `check-readiness`, `submit`; `review-submissions get`, `review-submissions items list` | Versions, submissions, and per-item review-state inspection; rejected items expose a `getResolutionDetails` affordance in v0.18.2+ |
| **builds** | `list`, `archive`, `upload`, `add-beta-group`, `update-beta-notes` | Build management |
| **testflight** | `groups list`, `testers add/remove/import/export` | Beta distribution |
| **version-localizations** | `list`, `create`, `update` | What's New, description, keywords per locale |
| **app-infos** / **app-info-localizations** | `list`, `update`, `create`, `delete` | App name, subtitle, categories, per-locale metadata |
| **screenshot-sets** / **screenshots** / **app-preview-sets** / **app-previews** | `list`, `create`, `upload`, `plan`, `apply` | Screenshots and video previews |
| **app-shots** | `config`, `generate`, `translate` | AI screenshot generation (Gemini) |
| **iap** | `list`, `create`, `submit`, `price-points`, `prices` | In-app purchases |
| **subscriptions** / **subscription-groups** / **subscription-offers** | `list`, `create`, `submit` | Auto-renewable subscriptions, groups, offers |
| **bundle-ids** / **certificates** / **profiles** / **devices** | `list`, `create`, `delete`, `register`, `revoke`, `inspect`, `local` | Code signing and provisioning |
| **reviews** / **review-responses** | `list`, `get`, `create`, `delete` | Customer reviews and responses |
| **reports** | `sales-reports download`, `sales-reports summary`, `finance-reports`, `analytics-reports` | Sales, financial, analytics; use `--version <schema>` on sales downloads when Apple requires a non-default report schema |
| **users** / **user-invitations** | `list`, `update`, `remove`, `invite`, `cancel` | Team management |
| **xcode-cloud** | `products`, `workflows`, `builds` | Xcode Cloud CI/CD |
| **Apple Ads** | `ads auth`, `ads me`, `ads acls`, `ads campaigns`, `ads ad-groups`, `ads reports`, `ads api request` | Apple Ads auth, user profile, org lookup, campaign/ad-group management, reports, and raw v5 API calls |
| **Other** | `apps list`, `app-tags`, `game-center`, `perf-metrics`, `diagnostics`, `iris resolution-center`, `plugins`, `search`, `schema`, `capabilities`, `tui`, `web` | Apps, discoverability tags, Game Center, performance, private API, plugins, discovery, TUI, web-session gaps |

**Discover**: `asc --help`, `asc <cmd> --help`, `asc search "upload build"`, `asc schema --pretty "GET /v1/apps"`, `asc capabilities --area release --output table` | **Output**: `--output json` (default), `--output table`, `--output markdown`, `--pretty`

## Key Workflows

### Release Flow

```bash
# 1. Archive and upload (or upload pre-built IPA)
asc builds archive --scheme MyApp --upload --app-id APP_ID --version 1.2.0 --build-number 55
# OR: asc builds upload --app-id APP_ID --file MyApp.ipa --version 1.2.0 --build-number 55
# If export compliance is missing, answer it before external TestFlight review
asc builds set-encryption-compliance --build-id BUILD_ID --uses-non-exempt-encryption false

# 2. TestFlight distribution
GROUP_ID=$(asc testflight groups list --app-id APP_ID | jq -r '.data[0].id')
BUILD_ID=$(asc builds list --app-id APP_ID | jq -r '.data[0].id')
asc builds add-beta-group --build-id "$BUILD_ID" --beta-group-id "$GROUP_ID"

# 3. Link build to version, update What's New, submit
VERSION_ID=$(asc versions list --app-id APP_ID | jq -r '.data[0].id')
asc versions set-build --version-id "$VERSION_ID" --build-id "$BUILD_ID"
asc versions update --version-id "$VERSION_ID" --copyright "© 2026 Example" --release-type AFTER_APPROVAL
LOC_ID=$(asc version-localizations list --version-id "$VERSION_ID" | jq -r '.data[0].id')
asc version-localizations update --localization-id "$LOC_ID" --whats-new "Bug fixes and improvements"
# Optional ASO signal: inspect Apple-generated app tags as context only
asc app-tags list --app-id APP_ID --output json
asc versions check-readiness --version-id "$VERSION_ID"
asc versions submit --version-id "$VERSION_ID"

# If Apple returns unresolved issues, inspect the rejected submission item and linked resource
SUBMISSION_ID=$(asc review-submissions list --app-id APP_ID | jq -r '.data[0].id // ""')
asc review-submissions get --submission-id "$SUBMISSION_ID" --output json
asc review-submissions items list --submission-id "$SUBMISSION_ID" --state REJECTED --output json
# v0.18.2+: read App Review's message and structured rejection reasons via iris cookie auth
asc iris resolution-center get --submission-id "$SUBMISSION_ID" --plain-text --output json
# Optionally download message attachments after inspecting their Apple/CDN URLs
asc iris resolution-center get --submission-id "$SUBMISSION_ID" --plain-text --out ./resolution-center

# Web-only gap: attach non-renewing IAPs to next app version review when the public API rejects review items
asc web review iaps attach --app-id APP_ID --iap-id IAP_ID --confirm
```

### Other Workflows

```bash
# TestFlight — add testers, import CSV, set beta notes
asc testflight testers add --beta-group-id GROUP_ID --email user@example.com
asc testflight testers import --beta-group-id GROUP_ID --file testers.csv
asc builds update-beta-notes --build-id BUILD_ID --locale en-US --notes "What's new in beta"
# Code signing — bundle ID, certificate, provisioning profile
asc bundle-ids create --name "My App" --identifier com.example.app --platform ios
asc certificates create --certificate-type IOS_DISTRIBUTION --csr ./MyApp.certSigningRequest
asc certificates create --certificate-type IOS_DISTRIBUTION --generate-csr --key-out ./signing/dist.key --csr-out ./signing/dist.csr
asc profiles create --name "App Store Profile" --type IOS_APP_STORE --bundle-id-id BID --certificate-ids CERT_ID
asc profiles list --profile-state ACTIVE,INVALID --paginate --output json
asc profiles inspect --path ./profiles/AppStore.mobileprovision --entitlements --output markdown
asc profiles local install --path ./profiles/AppStore.mobileprovision
# Metadata and AI screenshots
asc app-info-localizations update --localization-id LOC_ID --name "My App" --subtitle "Do things faster"
asc metadata plan --app-id APP_ID --version 1.2.3 --platform IOS --dir ./metadata --review-dir .asc/metadata/review
asc metadata approve --review-dir .asc/metadata/review --all
asc metadata status --review-dir .asc/metadata/review --output table
asc metadata apply --app-id APP_ID --version 1.2.3 --platform IOS --dir ./metadata --review-dir .asc/metadata/review --confirm
asc app-shots config --gemini-api-key KEY && asc app-shots generate
asc app-shots translate --to zh --to ja
# Reviewed screenshot batches — include existing remote counts before upload
asc screenshots plan --app-id APP_ID --version 1.2.3 --review-output-dir ./screenshots/review --output json
asc screenshots apply --app-id APP_ID --version 1.2.3 --review-output-dir ./screenshots/review --confirm --output json
# Reports — choose the Apple schema version when needed and aggregate daily sales reports
asc sales-reports download --vendor-number VENDOR --frequency DAILY --report-type SALES --report-sub-type SUMMARY --date 2026-05-01 --version 1_1
asc sales-reports summary --from 2026-05-01 --to 2026-05-31 --output json
# App availability now fetches the full territory list without hitting Apple's 50-item include cap
asc app-availability get --app-id APP_ID --output json
```

### Apple Ads Workflows

Apple Ads auth is separate from App Store Connect API-key auth. Resolve the org first, use JSON output for automation, and keep live-account mutations read-first and approval-gated.

```bash
# Auth/status: stored Apple Ads profile or ASC_ADS_* environment variables
asc ads auth status --validate --output json
asc ads auth doctor --output json
asc ads me view --output json

# Org resolution and read-only discovery
asc ads acls --output json
asc ads campaigns --org ORG_ID --limit 100 --output json
asc ads campaigns --org ORG_ID --paginate --output json
asc ads ad-groups --org ORG_ID --campaign CAMPAIGN_ID --output json

# Reports and mutations take Apple Ads JSON request files; destructive commands require --confirm
asc ads reports campaigns --org ORG_ID --file reporting-request.json --output json
asc ads campaigns create --org ORG_ID --file campaign.json --output json
asc ads campaigns delete --org ORG_ID --campaign CAMPAIGN_ID --confirm
```

When using `asc ads api request`, pass only Apple Ads v5 paths or `https://api.searchads.apple.com/api/v5/...` URLs. For live tests, create paused or future-dated resources with a unique test name, save IDs from JSON output, and clean up only the parent campaign or ad group created during the test.

## Web Apps and Local API Bridge

Run `asc web-server` to start the local API bridge (ports 8420 HTTP, 8421 HTTPS). Web apps at asccli.app connect to it for CLI execution. `--port N` binds **two** ports (N and N+1) — leave a gap of 2+.

## Agent Skills

Install on-demand (not pre-loaded): **Official** `asc skills install --all` (per-command reference) | **Community** `asc install-skills` or `npx skills add rorkai/app-store-connect-cli-skills` (workflow orchestration: releases, ASO, localization, RevenueCat, crash triage, Apple Ads). The community pack targets the separate [rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI), not the primary `tddworks/asc-cli` documented above, so verify its CLI version before following its commands. These upstream skill packs remain on-demand rather than being imported into aidevops. Latest reviewed official skill change adds build export-compliance handling. Latest community refresh (`d42cdfe983d0`) synchronizes the skills with community CLI 3.3.0, where file-driven batch mutations require explicit confirmation: metadata migration imports and subscription price imports must include `--confirm` for live application. The pack also separates healthy release execution from submission diagnosis and repair: release workflows use explicit readiness, staging, dry-run, confirmation, and multi-item submission phases, while submission-health workflows preserve and reuse matching review drafts instead of creating duplicates. It packages the 23 skills as Claude Code and Codex plugins; direct installation remains on-demand.

## Blitz MCP Server (Optional)

[Blitz](https://github.com/blitzdotdev/blitz-mac) — native macOS app with 30+ MCP tools for iOS dev. Overlaps with XcodeBuildMCP/ios-simulator-mcp but adds ASC submission. v1.0.35 auto-imports existing App Store Connect apps into the dashboard and simplifies screenshots. MCP config: `{ "mcpServers": { "blitz": { "command": "npx", "args": ["-y", "@blitzdev/blitz-mcp"] } } }`

## Mobile Stack Integration

| Tool | Role |
|------|------|
| **asc CLI** | App Store Connect API — publishing, metadata, TestFlight, subscriptions, reports |
| **XcodeBuildMCP** | Xcode build/test/deploy (76 tools) |
| **ios-simulator-mcp** | Simulator UI testing, screenshots, accessibility |
| **Maestro** | Repeatable E2E test flows |
| **RevenueCat** | Server-side subscription tracking, analytics |

## Related

- `tools/mobile/app-dev.md` — Mobile dev lifecycle | `tools/mobile/app-dev-publishing.md` — Submission checklists
- `tools/mobile/xcodebuild-mcp.md` — Xcode MCP | `tools/mobile/ios-simulator-mcp.md` — Simulator MCP
- `services/payments/revenuecat.md` — Subscriptions | `services/hosting/local-hosting.md` — asc-web hosting
