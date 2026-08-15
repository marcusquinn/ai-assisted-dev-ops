# Campaigns Plane — Directory Contract

<!-- AI-CONTEXT-START -->

The `_campaigns/` plane is a peer-level user-data plane for marketing/advertising/outreach
work. It houses brand assets, competitive intel, inspiration swipe files, in-flight
campaign creative, and post-launch performance + learnings. It is opt-in per repo.

For cross-plane routing metadata, use `.agents/configs/data-planes.json` as the
canonical registry. This document owns the `_campaigns/` directory contract; the
registry owns shared facts such as default sensitivity, ingress/egress, helper,
and retrieval surfaces.

## Why a Separate Plane

Marketing/campaign work has a distinct shape from other planes:

- **Different lifecycle:** `concept → research → creative → review → distribution → measure → learn`
  (not the build-test-ship cycle of `_projects/`).
- **Different sensitivity profile:** competitive intel is its own tier (never cloud);
  pre-launch creative is confidential; post-launch creative is public.
- **Asset binary heavy:** logos, video, audio — heavy use of the 30MB blob threshold path.
- **Swipe-file pattern:** "I saved this because [creative reason]" with channel/mood
  metadata — doesn't fit `_knowledge/` reference shape.
- **Different agents:** creative director, copywriter, market researcher, distributor —
  none apply to typical software projects.

Without a dedicated plane, marketing work either bloats `_projects/` (wrong lifecycle)
or scatters across the filesystem unmanaged.

## Directory Layout

```text
_campaigns/
├── .gitignore             # intel/ and active/ ignored by default (see Sensitivity)
├── CAMPAIGNS.md           # User-facing contract overview (written at provision time)
├── _config/
│   └── campaigns.json     # Plane config: sensitivity policy, blob threshold, cross-plane paths
├── lib/                   # Reusable brand assets + swipe files (versioned)
│   ├── brand/             # Logos, colour palette, fonts, voice/tone guides
│   ├── swipe/             # Inspiration: saved ads, landing pages, email examples
│   └── assets/            # Binary asset manifest + preview thumbnails (P4)
├── intel/                 # Competitive research (gitignored — sensitive tier)
│   └── README.md          # Schema for intel entries (written at provision time)
├── active/                # In-flight campaigns (gitignored by default)
│   └── <campaign-id>/     # One directory per active campaign
│       ├── brief.md       # Campaign brief: goal, channels, target, dates
│       ├── creative/      # Approved copy, images, video assets
│       ├── drafts/        # AI-generated drafts (P5) — human review before creative/
│       ├── research/      # Audience research, competitor notes
│       └── schedule.md    # Publication schedule
└── launched/              # Post-launch campaigns (versioned — audit trail)
    └── <campaign-id>/
        ├── brief.md       # Original brief (copied from active/)
        ├── creative/      # Final creative assets
        ├── results.md     # Post-launch metrics (template: campaign-results.md)
        └── learnings.md   # Retrospective insights (template: campaign-learnings.md)
```

**Provision:** `aidevops campaign init`
**Repair:** `aidevops campaign provision` is idempotent — safe to re-run.

## Sub-folder Purposes

| Folder | Versioned | Sensitivity | Purpose |
|--------|-----------|-------------|---------|
| `lib/brand/` | Yes | `internal` | Reusable brand identity files (logos, colours, voice) |
| `lib/swipe/` | Yes | `internal` | Inspiration files: saved ads, landing pages, email examples |
| `lib/assets/` | Yes | `internal` | Schema-v2 binary asset manifest + 640px preview thumbnails (P4) |
| `intel/` | **No** (gitignored) | `sensitive` | Competitive intel — local-LLM-only, never committed |
| `active/<id>/` | **No** (gitignored) | `internal` | In-progress campaign creative (drafts, briefs, schedules) |
| `launched/<id>/` | Yes | varies | Post-launch directory: results + learnings are versioned |
| `_config/` | Yes | `internal` | Plane configuration |

**Why `intel/` is gitignored by default:** competitive intelligence is classified
`sensitive` — local-LLM-only, never cloud. Committing it would expose it to anyone
with repo access. Users who want it versioned can remove `intel/` from `.gitignore`
but must ensure the repo is private and collaborators are trusted.

**Why `active/` is gitignored by default:** pre-launch creative can contain
confidential messaging, pricing strategy, and embargoed product details.
Committed draft creative has leaked campaign strategy in real incidents.
Promoting to `launched/` on campaign go-live is the explicit versioning step.

## .gitignore Rules

The provisioner writes two sets of rules:

1. **`_campaigns/.gitignore`** — ignores `intel/`, `active/`, and `index/` within
   the campaigns root. `lib/`, `launched/`, and `_config/` are NOT ignored.

2. **Repo root `.gitignore`** — appends a `# campaigns-plane-rules` block with
   `_campaigns/intel/`, `_campaigns/active/`, `_campaigns/index/` for belt-and-
   suspenders coverage.

## Campaign ID Scheme

Campaign IDs are human-chosen slugs (kebab-case). Convention: `<YYYY-QQ>-<descriptor>`
or `<channel>-<descriptor>`.

Examples: `2026-q2-brand-awareness`, `instagram-summer-launch`, `email-newsletter-may`

Phase 2 (t2963) adds sequential IDs via counter, analogous to the case ID scheme.
Phase 1 supports free-form slugs provisioned by the user.

## Sensitivity Tiers

| Folder | Default tier | LLM access | Notes |
|--------|-------------|------------|-------|
| `intel/` | `sensitive` | Local only | Competitive intel — hard-fail if no local LLM |
| `active/` | `internal` | Cloud OK | Pre-launch creative — confidential but not privileged |
| `lib/` | `internal` | Cloud OK | Reusable assets |
| `launched/` | `public` | Any | Post-launch work is typically public |
| `_config/` | `internal` | Cloud OK | Plane config |

Sensitivity tiers map to the broader sensitivity layer defined in `knowledge-plane.md`.
When the sensitivity classifier (t2846) is active, it stamps each file's metadata.

## `_config/campaigns.json` Defaults

Written at provision time from `.agents/templates/campaigns-config.json`:

```json
{
  "version": 1,
  "campaign_id_prefix": "camp",
  "sensitivity": {
    "intel": "sensitive",
    "active": "internal",
    "lib": "internal",
    "launched": "public"
  },
  "llm_policy": {
    "intel": "local-only",
    "active": "cloud-ok",
    "lib": "cloud-ok",
    "launched": "cloud-ok"
  },
  "blob_threshold_bytes": 31457280,
  "swipe_auto_tag": true,
  "cross_plane": {
    "feedback_source": "_feedback/",
    "knowledge_promotion_path": "_knowledge/insights/marketing/",
    "performance_path": "_performance/marketing/"
  }
}
```

Override per-repo by editing `_campaigns/_config/campaigns.json` after provisioning.

## CLI Reference

Provisioning commands: `campaigns-provision-helper.sh`. Route via `aidevops campaign <subcommand>`.

```bash
# Provision _campaigns/ in current repo
aidevops campaign init [<repo-path>]

# Re-provision / repair (idempotent)
aidevops campaign provision [<repo-path>]

# Show provisioning state and campaign counts
aidevops campaign status [<repo-path>]

# Show one campaign's detailed lifecycle dossier
aidevops campaign status <campaign-id> [--repo <repo-path>]

# List campaigns (active + launched)
aidevops campaign ls [--active|--launched|--all] [<repo-path>]
```

**Phase 2 CLI (t2963 — shipped):** `campaign new`, `campaign list`,
`campaign launch`, `campaign archive`, and sequential campaign IDs.

### Campaign intake contract (schema v1)

`campaign new <name> --intake <file>` requires a JSON document conforming to
`.agents/schemas/campaign-intake.schema.json`. It records the canonical brand
reference, product, offer, objectives, audience buying roles, positioning,
proof-linked claims, objections, exclusions, channels, dates, KPIs,
disclosures, sensitivity, and approval policy. The rendered `brief.md` keeps a
stable `CAMPAIGN_INTAKE_JSON_V1` block and references brand sources rather than
copying brand identity data.

`campaign update <id> --intake <file>` validates and atomically replaces the
intake and rendered brief. Existing unversioned briefs remain readable by
status, draft, launch, and archive commands; convert them only with explicit
`campaign migrate <id> --intake <file>`. Replaying a normalized intake returns
the existing active campaign instead of creating a duplicate. Claim evidence is
mandatory and its approval status is always explicit; text alone never makes a
claim approved.

**Phase 4 CLI (t2965 — shipped):** `campaign asset` — asset binary management.

```bash
# Ingest a binary asset (routes large files >=30MB to knowledge-blobs store)
aidevops campaign asset add <file> [--target lib-brand|lib-swipe|campaign]
                                   [--campaign <id>] [--sensitivity <tier>]
                                   [--no-preview] [--repo <path>]

# Generate a 640px-wide PNG preview thumbnail for AI review
aidevops campaign asset preview <file> [--size <px>] [--output <path>]

# List all ingested assets from the manifest
aidevops campaign asset list [--type image|video|audio|pdf|all] [--campaign <id>]

# Show full JSON manifest entry for an asset
aidevops campaign asset manifest <asset-id>
```

Asset manifest lives at `_campaigns/lib/assets/manifest.json`. New writes use schema
v2: originals and derivatives record byte hashes, source lineage, recipe/provider,
variant, rights/consent/territory/expiry, synthetic disclosure, review, and output
state. Schema-v1 manifests remain readable; promotion and launch fail closed until
every production manifest has approved review, rights clearance, source/recipe
provenance, and matching output hashes. Preview thumbnails
go to `<target-dir>/.previews/<filename>_preview.png`. Requires ImageMagick (`convert`)
for image/PDF previews and `ffmpeg` for video first-frame extraction. Max preview
size is 640px per side (safe below the 1568px crash limit in `reference/screenshot-limits.md`).

Large files (>=30MB) are stored in `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/campaigns/<asset-id>/`
with a symlink in the target directory. This keeps large binaries out of the repo while
preserving addressability via the manifest.

**Phase 5 CLI (t2967 — shipped):** `campaign draft <id> --channel <ch> [--tone <tone>] [--variant N]`
— AI creative agent for channel-aware content drafting. RAG-grounded in `lib/brand/`
(voice/tone) and `lib/swipe/` (inspiration). Output: `active/<id>/drafts/<channel>-v<N>.md`
with provenance metadata. Human-gated: drafts require manual review before promotion.
Channel specs: `.agents/configs/campaign-channel-specs.json`.

**Phase 6 CLI (t2969 — shipped):** `campaign launch`, `campaign promote`,
`campaign feedback` — cross-plane promotion of results and learnings.

### Campaign growth orchestration

`aidevops campaign grow` is the progressive entry point for a complete growth
campaign. It coordinates evidence from research, creative production/review,
approved distribution receipts, performance, and reporting without becoming a
publisher, provider client, or analytics engine.

```bash
aidevops campaign grow plan --intake intake.json
aidevops campaign grow start <campaign-id> --repo <repo> --evidence owner-evidence.json
aidevops campaign grow status <campaign-id> --repo <repo>
aidevops campaign grow resume <campaign-id> --repo <repo> --evidence owner-evidence.json
```

`plan` is non-mutating and reports channels, capabilities, artifacts, approvals,
and degraded fallbacks. `start` and `resume` write only
`active/<id>/orchestration/campaign-growth-state.json`; each owner remains
authoritative for its own research, assets, queue receipts, performance records,
and recommendations. A distribution stage must carry explicit, current owner
approval. Unknown provider outcomes, partial metrics, missing evidence, expired
approval, suppression, or insufficient experiment evidence remain truthful stage
states and never become success. See `workflows/campaign-growth.md` for evidence
shape, recovery, and specialist routing.

### Campaign research dossier contract (schema v1)

`campaign research <id> --source <evidence.json>` produces
`_campaigns/active/<id>/research/dossier.json` plus `dossier.md`. The dossier is
reference-oriented: it holds structured audience and buying-role refinement,
competitor, creator, trend, channel-fit, opportunity, and contradiction records
with a provenance ledger. Its semantic snapshot hash makes an unchanged source
replay idempotent.

Source packages are bounded supplied files or exports; the command does not
invent a live collector, read authority, or provider configuration. Every source
records type, reference, capture time, freshness, authorization mode, confidence,
sensitivity, and an explicit `complete`, `partial`, `gated`, `absent`, `stale`,
`rate_limited`, or `failed` status. Gated and unavailable evidence is coverage
metadata, never a positive finding. A fully failed refresh preserves a prior
valid dossier.

Keep raw sensitive competitive artifacts in `_campaigns/intel/`; the active
dossier references them without copying private identifiers into its human
summary. Campaign brief and content consumers use `research/dossier.json` and
degrade to `research_unavailable` when its coverage is unavailable.

## CAMPAIGNS.md Contract File

Written to `_campaigns/CAMPAIGNS.md` at provision time. Describes the directory
layout to any collaborator or AI agent encountering the directory for the first time.
It is the user-facing equivalent of this framework doc.

## Cross-Plane Connections

The canonical cross-plane registry is `.agents/configs/data-planes.json`; the
table below is the campaign-specific operational view.

| Direction | Connection |
|-----------|-----------|
| `_feedback/ → _campaigns/active/<id>/research/` | Audience pain/insight pulled into campaign research |
| `_campaigns/launched/<id>/learnings.md → _knowledge/insights/marketing/` | Post-mortem learnings promoted |
| `_campaigns/launched/<id>/results.md → _performance/marketing/` | Metrics pushed to performance plane |
| `_inbox/ → _campaigns/lib/swipe/` | Triage routes campaign-relevant captures (ads, inspiration) |

Promotion is handled by `campaign-helper.sh promote` (t2969). Integration with
`_feedback/` is handled by `campaign-helper.sh feedback` (t2969).

## Dependencies

- **Provisioning:** independent — can provision without t2840 foundation
- **Sensitivity enforcement:** requires t2846 (sensitivity detector) for automatic classification
- **Intel LLM policy:** requires t2848 (Ollama substrate) for local-only enforcement
- **Post-launch promotion:** requires `_knowledge/` and `_performance/` planes (t2843, future)
- **Swipe routing from inbox:** requires `_inbox/` plane (t2866)

## Helper

`.agents/scripts/campaigns-provision-helper.sh` — provisioning and introspection.
`.agents/scripts/campaign-asset-helper.sh` — asset binary management (P4).
`.agents/scripts/campaign-research-helper.py` — bounded dossier normalization (P7).

<!-- AI-CONTEXT-END -->
