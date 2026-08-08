<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference

Full field reference for `CloudronManifest.json`. See the [Cloudron docs](https://docs.cloudron.io/packaging/manifest/) for detailed examples.

## Required fields

| Field | Type | Description |
|-------|------|-------------|
| `manifestVersion` | integer | Always `2` |
| `version` | semver string | Package version (e.g. `"1.0.0"`) |
| `healthCheckPath` | URL path | Path returning 2xx when app is healthy (e.g. `"/"`) |
| `httpPort` | integer | HTTP port the app listens on (e.g. `8000`) |

## Ports

| Field | Type | Description |
|-------|------|-------------|
| `httpPort` | integer | Primary HTTP port |
| `httpPorts` | object | Additional HTTP services on secondary domains. Keys are env var names. Values: `{ title, description, containerPort, defaultValue }` |
| `tcpPorts` | object | Non-HTTP TCP ports. Keys are env var names. Values: `{ title, description, defaultValue, containerPort, portCount, readOnly, enabledByDefault }` |
| `udpPorts` | object | UDP ports. Same structure as `tcpPorts` |

The `containerPort` is the port inside the container. `defaultValue` is the suggested external port shown during install. Disabled ports remove their env var at runtime — apps must handle this.

## Addons

| Field | Type | Description |
|-------|------|-------------|
| `addons` | object | Keys: `email`, `ldap`, `localstorage`, `mongodb`, `mysql`, `oidc`, `postgresql`, `proxyauth`, `recvmail`, `redis`, `sendmail`, `scheduler`, `tls`. Values are option objects (often `{}`) |

## Metadata (for App Store / CloudronVersions.json)

| Field | Type | Description |
|-------|------|-------------|
| `id` | reverse domain string | Unique app ID (e.g. `com.example.myapp`) |
| `title` | string | App name |
| `author` | string | Developer name and email |
| `tagline` | string | One-line description |
| `description` | markdown string | Detailed description. Supports `file://DESCRIPTION.md` |
| `changelog` | markdown string | Changes in this version. Supports `file://CHANGELOG` |
| `website` | URL | App website |
| `contactEmail` | email | Bug report / support email |
| `icon` | local file ref | Square 256x256 icon (e.g. `file://icon.png`) |
| `iconUrl` | URL | Remote icon URL |
| `tags` | string array | Filterable tags: `blog`, `chat`, `git`, `email`, `sync`, `gallery`, `notes`, `project`, `hosting`, `wiki` |
| `mediaLinks` | URL array | Screenshot URLs (3:1 aspect ratio, HTTPS) |
| `packagerName` | string | Name of package maintainer |
| `packagerUrl` | URL | Package maintainer URL |
| `packageUrl` | URL | Package source repository URL. Requires `minBoxVersion: 10.0.0` |
| `documentationUrl` | URL | Link to app docs |
| `forumUrl` | URL | Link to support forum |
| `upstreamVersion` | string | Upstream app version (display only) |

## Behavior

| Field | Type | Description |
|-------|------|-------------|
| `memoryLimit` | integer (bytes) | Max RAM + swap (default 256 MB / `268435456`) |
| `multiDomain` | boolean | Allow alias domains. Sets `CLOUDRON_ALIAS_DOMAINS` env var |
| `optionalSso` | boolean | Allow install without user management. Auth addon env vars are absent when SSO is off |
| `configurePath` | URL path | Admin panel path shown in dashboard (e.g. `/wp-admin/`) |
| `logPaths` | string array | Log file paths when stdout is not possible |
| `capabilities` | string array | Extra Linux capabilities: `net_admin`, `mlock`, `ping`, `vaapi` |
| `runtimeDirs` | string array | Writable subdirs of `/app/code` (not backed up, not persisted across updates) |
| `persistentDirs` | string array | Writable dirs persisted across updates but not in filesystem backup. Use with `backupCommand`. Requires `minBoxVersion: 9.1.0` |
| `backupCommand` | string | Shell command run during backup (app must be running) to dump persistent data into `/app/data`. It shares the app network namespace, so `localhost` works. Requires `minBoxVersion: 9.1.0` |
| `restoreCommand` | string | Shell command run during restore before the app container starts to populate `persistentDirs` from `/app/data`. The app is not running, so `localhost` cannot be used. Requires `minBoxVersion: 9.1.0` |

## Post-install

| Field | Type | Description |
|-------|------|-------------|
| `postInstallMessage` | markdown string | Shown after install. Supports `file://POSTINSTALL.md`. Tags: `<sso>...</sso>`, `<nosso>...</nosso>`. Variables: `$CLOUDRON-APP-DOMAIN`, `$CLOUDRON-APP-FQDN`, `$CLOUDRON-APP-ORIGIN`, `$CLOUDRON-USERNAME`, `$CLOUDRON-APP-ID` |
| `checklist` | object | Post-install todo items. Keys are item IDs. Values: `{ message, sso }`. `sso: true` = shown only with auth, `sso: false` = shown only without auth |

## Versioning

| Field | Type | Description |
|-------|------|-------------|
| `minBoxVersion` | semver | Minimum platform version (default `0.0.1`) |
| `maxBoxVersion` | semver | Maximum platform version (rarely needed) |
| `targetBoxVersion` | semver | Platform version the app was tested on. Enables compatibility behavior for older apps |
