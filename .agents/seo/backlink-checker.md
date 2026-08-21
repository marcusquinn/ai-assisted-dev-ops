---
description: Backlink monitoring and expired domain discovery for link reclamation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Backlink & Expired Domain Checker

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Monitor backlinks, detect lost/broken links, and flag expired referring domains for manual review
- **Data Sources**: Authorized Ahrefs/DataForSEO exports and registry/registrar expiry evidence
- **Helpers**: `scripts/seo-export-ahrefs.sh`, `scripts/seo-export-dataforseo.sh` (backlink data export)

**Workflow**: Export backlink profile -> Identify lost/broken links -> Verify expiry evidence -> Rank reclamation leads. For current auction inventory and local opportunity reports, use `seo/domain-opportunities.md`.

<!-- AI-CONTEXT-END -->

## Data Sources

### Ahrefs API (Primary)

> See `scripts/seo-export-ahrefs.sh` for the export implementation.

Ahrefs endpoints used:
- `/v3/site-explorer/all-backlinks` - Full backlink list
- `/v3/site-explorer/backlinks-new-lost` - New/lost link changes
- `/v3/site-explorer/referring-domains` - Unique referring domains

### DataForSEO Backlinks API (Alternative)

> See `scripts/seo-export-dataforseo.sh` for the export implementation.

DataForSEO endpoints:
- `/v3/backlinks/backlinks/live` - Live backlink data
- `/v3/backlinks/referring_domains/live` - Referring domains
- `/v3/backlinks/bulk_new_lost_backlinks/live` - Bulk new/lost

## Backlink-expiry detection

This workflow starts from a site's historical referring domains. It does not claim current marketplace availability and does not bid or purchase. Current official auction inventory is a separate evidence stream handled by `seo/domain-opportunities.md`.

### WHOIS Lookup

```bash
# Check if a referring domain has expired
whois example-referrer.com | grep -i "expir"

# Batch check (pipe from backlink export)
seo-helper.sh backlinks example.com --referring-domains-only | while read -r domain; do
    expiry=$(whois "$domain" 2>/dev/null | grep -i "expiry\|expiration" | head -1)
    echo "$domain: $expiry"
done
```

WHOIS/RDAP output varies by registry and can be stale or rate-limited. Preserve source and observation time, treat ambiguity as unknown, and verify availability through an operator-authorized registrar path before any decision.

## Reclamation Workflow

1. **Export referring domains** with DR/DA scores
2. **Filter lost/broken** links from last 90 days
3. **WHOIS check** each lost referring domain
4. **Score candidates** by:
   - Domain Rating (DR) or Domain Authority (DA)
   - Number of backlinks the domain had
   - Traffic estimate (Ahrefs/SimilarWeb)
   - Registration cost vs. link value
5. **Output ranked list** of manual reclamation leads with source, time, and missing/risk flags

## Related

- `seo/ahrefs.md` - Ahrefs API (primary data source)
- `seo/dataforseo.md` - DataForSEO API (alternative data source)
- `seo/domain-research.md` - DNS reconnaissance on candidates
- `seo/domain-opportunities.md` - current official auction inventory and deterministic local reports
- `seo/link-building.md` - Link-building strategies
