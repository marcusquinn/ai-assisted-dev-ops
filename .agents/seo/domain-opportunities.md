---
description: Ranked local domain-auction research with explicit evidence provenance
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Local Domain Opportunities

Use this workflow to rank auction inventory locally without a web interface. SQLite is canonical; CSV, JSON, and Markdown are deterministic read-only projections. It does not bid, purchase, scrape marketplaces, or provide legal/trademark clearance.

## Data and permission model

| Source | Role | Permission/credential | Missing behavior |
|---|---|---|---|
| Namecheap Market | Current official auction listings | Read-only API credentials | Import step is skipped; existing evidence remains usable |
| Provider bulk files | GoDaddy/SnapNames inventory | Operator-authorized local download | File is inspected and archived locally; never commit it |
| Google Ads | Primary quantitative demand metrics | Read-only Ads account access; `GOOGLE_ADS_ACCESS_TOKEN` and `GOOGLE_ADS_DEVELOPER_TOKEN` via `aidevops secret set` | `google_ads` missing flag; no zero is invented |
| Google Trends | Optional relative direction/seasonality | Visible operator browser session | `trends_optional` flag; scoring remains valid without it |
| Provider/history evidence | Appraisal, comparable, backlink/history observations | Provider-specific permission | Corresponding score component stays unknown with zero weight |

Trends values are relative only within their exported comparison batch. Google Ads historical metrics retain language, geography, network, account currency, retrieval month, source, and observation time.

## Setup and local paths

Copy `configs/domain-opportunities-config.json.txt` to the ignored working file `configs/domain-opportunities-config.json`, replace placeholders, and keep all runtime data under:

```text
~/.aidevops/.agent-workspace/work/domain-opportunities/
  evidence.sqlite
  imports/
  exports/
  trends/
```

Templates contain aliases and resource placeholders only. Never commit the working config, SQLite store, provider files, exports, account/customer IDs, tokens, bids, purchases, or browser download paths.

## Operating sequence

Choose the appropriate official inventory importer; the commands below show the stable local sequence after an inventory file has been obtained with permission.

```bash
DB="$HOME/.aidevops/.agent-workspace/work/domain-opportunities/evidence.sqlite"
OUT="$HOME/.aidevops/.agent-workspace/work/domain-opportunities/exports"

python3 .agents/scripts/domain-opportunity-helper.py init --db "$DB"
python3 .agents/scripts/domain-opportunity-files.py import --db "$DB" --provider godaddy --input "$HOME/Downloads/authorized-inventory.csv"
python3 .agents/scripts/domain-opportunity-google-ads.py plan --db "$DB" --currency USD --language languageConstants/REPLACE_ME --geography geoTargetConstants/REPLACE_ME
python3 .agents/scripts/domain-opportunity-google-ads.py sync --db "$DB" --currency USD --language languageConstants/REPLACE_ME --geography geoTargetConstants/REPLACE_ME --customer-id LOCAL_ACCOUNT_ID
python3 .agents/scripts/domain-opportunity-score.py score --db "$DB"
python3 .agents/scripts/domain-opportunity-helper.py pipeline-status --db "$DB" --json
python3 .agents/scripts/domain-opportunity-helper.py report --db "$DB" --format csv --output "$OUT/opportunities.csv" --as-of 2026-08-21T12:00:00Z --active-only
python3 .agents/scripts/domain-opportunity-helper.py report --db "$DB" --format json --output "$OUT/opportunities.json" --as-of 2026-08-21T12:00:00Z --active-only
python3 .agents/scripts/domain-opportunity-helper.py analysis-packet --db "$DB" --output "$OUT/opportunities.md" --as-of 2026-08-21T12:00:00Z --active-only --limit 25
```

Use the actual current UTC `--as-of` value for an operating run. Holding the SQLite snapshot, policy, filters, and `--as-of` constant produces the same order and evidence. Without `--as-of`, the newest stored observation is used so offline reruns remain deterministic.

### Optional Trends handoff

```bash
python3 .agents/scripts/domain-opportunity-trends.py queue --db "$DB" --output "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/trends"
python3 .agents/scripts/domain-opportunity-trends.py inspect --manifest MANIFEST.json --input multiTimeline.csv
python3 .agents/scripts/domain-opportunity-trends.py import --manifest MANIFEST.json --input multiTimeline.csv --db "$DB"
```

Follow each generated manifest in a visible browser, use the official Trends site, retain the share URL/export time, and inspect before import. No automated Trends browser scraping is provided.

## Reading a report

- `score_micros` and every component come from the persisted versioned scoring policy; reports never create a second composite.
- Current price uses currency micros and retains provider and observation time. Deadline is the provider auction deadline.
- `fresh`, `stale`, `future`, and `missing` are explicit evidence states. The report defaults are 7 days for inventory, 35 for Ads, and 14 for Trends.
- `missing_flags` identifies absent/invalid optional evidence. Unknown values remain null/blank and are never presented as measured zero.
- `risk_flags` combines scoring hard-filter and review flags. A clear flag is not legal clearance.
- Markdown embeds the complete JSON evidence packet after its concise ranking table. Any business model, audience, monetization, or positioning ideas derived from it are generated hypotheses—not measured evidence—and must cite candidate fields and list assumptions/risks.

## Recovery and scheduling

- Run `pipeline-status --json` first. Missing Ads credentials/providers/Trends are non-fatal readiness states.
- If a provider sync fails, keep the prior completed evidence and retry only that adapter. Reporting never migrates or rewrites the database.
- An unsupported future SQLite schema fails with an actionable compatibility error. Upgrade the runtime; do not edit the store manually.
- Atomic publication preserves the last complete export if rendering or replacement fails.
- For scheduled research, run official inventory sync/enrichment/scoring first, then report with one recorded UTC `--as-of`. Keep schedules local and respect provider quotas and terms.

Before acting on a candidate, review evidence freshness, source permissions, score components, phrase ambiguity, trademark/legal risk, historical/backlink quality, current price/deadline, and all missing flags. Human authorization is always required for bids or purchases.
