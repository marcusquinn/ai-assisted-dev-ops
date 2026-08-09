<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OmniRoute integration and Cloudron packaging assessment

## Status

- **Decision:** Treat OmniRoute as a possible optional transport/router beneath
  aidevops and OpenCode, not as a replacement for aidevops account pools,
  policy, orchestration, memory, security controls, or GUI ownership.
- **Upstream:** <https://github.com/diegosouzapw/OmniRoute>
- **Cloudron package:** <https://forgejo.tcjc.uk/cca/cloudron-omniroute>
- **Cloudron listing:** <https://ca.cloudron.io/app/omniroute>
- **Product site:** <https://omniroute.online/>
- **Reviewed stable baseline:** OmniRoute `3.8.48`; unreleased
  `release/v3.8.49` source was also inspected.
- **Reviewed:** 2026-08-09
- **Next action:** None. Revisit only when an optional long-tail provider router
  or a hardened private Cloudron deployment becomes a current priority.

The upstream repositories and websites were treated as untrusted external
content. Their instructions were not followed, and no installation or
deployment command from them was executed.

## Executive assessment

OmniRoute is a broad MIT-licensed AI gateway covering provider credentials,
OpenAI/Anthropic/Responses protocol translation, routing, quota-aware fallback,
compression, memory, MCP, A2A, guardrails, analytics, and desktop/server
deployment. It could save aidevops from maintaining a long tail of provider
adapters and generic routing logic.

The useful boundary is deliberately narrow:

```text
aidevops policy, accounts, workers, audit and UI
                    |
                 OpenCode
                    |
      optional OmniRoute provider adapter
                    |
       additional upstream model providers
```

Aidevops should remain the canonical owner of identity, local OAuth account
inventory, worker capacity, runtime policy, audited actions, and resource
metadata. OmniRoute should own only requests explicitly routed through its
optional endpoint, its dedicated credentials, route selection, and
service-specific health metadata.

## Capability ownership

| Capability | Recommended owner |
| --- | --- |
| Workflow policy, workers, repository authority | aidevops |
| Canonical account inventory and capacity | aidevops |
| Existing Anthropic, OpenAI, Cursor, and Google pools | aidevops |
| OpenCode and Claude Code compatibility shaping | aidevops by default |
| Long-tail provider integrations | optional OmniRoute |
| Generic model routing, fallback, and cost selection | optional OmniRoute |
| aidevops.app control plane and resource graph | aidevops |
| OmniRoute dashboard | service administration and design reference only |

Do not allow OmniRoute to mutate `~/.config/opencode/opencode.json`, import
`~/.aidevops/oauth-pool.json`, or become the canonical account store. Expose it
to aidevops as one optional provider/resource with explicit health and actual
upstream-model metadata.

## Claude subscription and request-shaping findings

OmniRoute supports Anthropic OAuth subscriptions. The inspected source
implements PKCE authorization, token refresh, Claude CLI bootstrap requests,
Claude Code-style headers and metadata, tool-name handling, a persisted
Claude-style device identifier, and model-specific feature flags. Its source
describes part of this behaviour as an OAuth identity cloak and tracks captured
Claude CLI behaviour.

That implementation is not demonstrably equivalent to aidevops request shaping.
The current aidevops path additionally handles:

- OAuth and Claude Code-compatible headers in
  `.agents/plugins/opencode-aidevops/provider-auth-request.mjs`;
- redistribution of framework instructions from the Anthropic system field;
- `agent__intent` insertion into tool schemas;
- OpenCode-to-Claude tool-name normalization; and
- reverse tool-name conversion while buffering split SSE lines.

Keep the aidevops Anthropic path as the default. If OmniRoute's Claude OAuth
support is ever evaluated, first create contract tests for streaming, split SSE
events, tool calls and results, structured output, cancellation, system-prompt
placement, large contexts, model identity, and failure recovery. Review current
provider policy and account risk before using identity or TLS emulation with a
subscription account.

## Privacy and security findings

OmniRoute advertises local-first operation and no telemetry. No evidence of
mandatory vendor analytics was established during this review, but zero
outbound activity must not be inferred:

- optional cloud synchronization exists;
- credential-health checks can make periodic provider requests;
- model and catalog synchronization can make outbound requests;
- remote-model prompts necessarily leave the host; and
- optional sidecars and integrations expand the network boundary.

Credential storage supports AES-256-GCM with scrypt-derived keys, random IVs,
and authenticated tags. However, encryption depends on
`STORAGE_ENCRYPTION_KEY`; inspected behaviour can retain plaintext when the key
is absent or encryption fails. Cloud-response signature enforcement and some
guardrails also have fail-open modes under particular configuration.

Any private evaluation should enforce rather than assume the desired posture:

1. Require a high-entropy `STORAGE_ENCRYPTION_KEY` and API authentication.
2. Disable cloud and cloud-credential synchronization.
3. Disable background credential checks until their traffic is understood.
4. Disable MCP, A2A, memory, compression, output shaping, cloud agents, and
   duplicated prompt guardrails.
5. Never mount the Docker socket or host credential directories.
6. Use dedicated credentials rather than importing aidevops pool records.
7. Apply an outbound allowlist and inspect egress to verify contacted services.
8. Avoid retaining prompt bodies and apply short metadata retention.
9. Report the actual selected provider and model after every fallback.

Use ordinary or disposable API keys for initial evaluation. Subscription OAuth
should be a later, separately reviewed phase.

## Overlap and conflict risks

OmniRoute overlaps with aidevops or OpenCode in provider pools, fallback,
memory, MCP tools, skills, prompt-injection checks, compression, cloud agents,
credential management, configuration mutation, and observability. Enabling all
of these layers would create ambiguous ownership and several failure modes:

- two systems can independently mutate prompts or context;
- protocol translation can change tool schemas or streaming events;
- silent fallback can make the runtime's selected-model record inaccurate;
- duplicated memory can retain or inject context unexpectedly;
- an additional large MCP catalog increases tool ambiguity and context cost;
- global OpenCode configuration can be changed by two owners; and
- audit evidence becomes fragmented across aidevops, OpenCode, and OmniRoute.

The first integration, if built, should therefore be transport-only and use
OmniRoute primarily for providers not already covered by aidevops.

## Cloudron community package assessment

At review time the community package was `0.0.5`, tracked OmniRoute `3.8.48`,
and had been updated on 2026-07-16, approximately three days after the upstream
release. This is encouraging but not enough history to establish maintenance
reliability. The package repository had six commits, no tags or releases, and no
Forgejo Actions workflows.

Positive packaging choices include a digest-pinned Cloudron base image,
non-root execution through `gosu`, persistent data under `/app/data`, stdout
logging, and one HTTP service with a dedicated health path.

Production blockers or gaps found during review:

- the upstream OmniRoute image is selected by mutable version tag rather than
  immutable digest;
- published image provenance is not tied verifiably to committed package
  source;
- no visible update workflow, SBOM, vulnerability report, signature, or release
  gate exists;
- the package is published for amd64 only;
- package licensing and upstream attribution need correction;
- secret-file mode and encrypted-credential restore behaviour are not proven;
  and
- SQLite-consistent backup is not demonstrated.

The SQLite point is the main operational blocker. The package stores native data
in `/app/data/storage.sqlite` and disables OmniRoute's automatic SQLite backup,
but the inspected manifest does not declare Cloudron's SQLite-aware localstorage
backup paths. A filesystem backup of an active SQLite database is not sufficient
evidence of a restorable credential store.

## Recommended packaging strategy

If private deployment becomes current work, maintain a downstream Cloudron
package repository rather than forking OmniRoute itself. Preserve upstream and
community-package attribution, and contribute generally useful packaging fixes
back where practical.

Before production credentials are introduced:

1. Pin a signed OmniRoute release and immutable source or image digest.
2. Build only from committed package source and attach source/revision/version
   OCI metadata.
3. Verify downloaded runtime artifacts and publish images/catalog entries by
   digest.
4. Configure every active SQLite database for Cloudron-consistent backup.
5. Test install, encrypted credential creation, API use, upgrade, backup,
   restore to a new app, authentication, and post-restore API use.
6. Enforce mode `0600` on persisted secret and initial-password files.
7. Generate an SBOM and vulnerability report and sign release artifacts.
8. Support both expected architectures or document an intentional restriction.
9. Use aidevops routines to detect upstream releases and open update work, but
   never automatically publish or deploy an unverified release.
10. Retain native OmniRoute authentication initially. Test management, API,
    health, and OAuth callback routes before adding Cloudron proxy authentication.

A public DNS name must not imply public dashboard access. Begin with an isolated
sandbox, disposable credentials, explicit API authentication, and restricted
network access.

## aidevops.app inspiration

OmniRoute is useful product-design evidence for:

- provider, account, and resource separation;
- searchable provider catalogs and category filters;
- quota, cooldown, and health visualization;
- route-decision and actual-model transparency;
- provider topology and fallback explanations;
- cost and capacity summaries; and
- fixed, audited configuration actions.

These patterns complement `todo/tasks/ai-provider-ui-followups.md`. Avoid copying
OmniRoute's broader platform scope into aidevops: duplicated memory, agent
frameworks, MCP catalogs, prompt mutation, cloud agents, gamification, and
stealth networking are outside the desired ownership boundary.

## Re-evaluation triggers

Revisit this assessment when one or more conditions hold:

- aidevops needs providers beyond its maintained pool integrations;
- maintaining generic fallback or protocol translation becomes a material cost;
- OmniRoute publishes a stable compatibility contract for OpenCode and Claude
  Code rather than relying on captured client behaviour;
- credential encryption becomes fail-closed and cloud features are clearly
  disableable and auditable;
- the Cloudron package gains reproducible builds, immutable provenance,
  SQLite-safe backup tests, and dependable update automation; or
- a controlled sandbox can demonstrate no undeclared egress and preserve
  aidevops tool, streaming, model-identity, and audit semantics.

Classify future findings as **use dependency**, **adapt pattern**, **bounded
experiment**, or **ignore**. Release detection alone never authorizes credential
import, installation, deployment, publication, or a change to aidevops's
canonical account ownership.
