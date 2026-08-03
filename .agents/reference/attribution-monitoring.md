<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Attribution Monitoring

> t1883 — GitHub Code Search + canary dashboard for detecting framework copies

MIT-licensed copying is legal; attribution is expected. This system detects distinctive framework patterns in public GitHub repos for adoption visibility, fork discovery, and attribution awareness.

**Tool:** `attribution-detection-helper.sh` — see `scripts/attribution-detection-helper.sh`

**Public attribution guide:** see repository `ATTRIBUTION.md` for the required
MIT notice, preferred derivative credit text, and public list of
provenance-sensitive innovation areas.

## Quick Start

```bash
attribution-detection-helper.sh canary list        # List registered canary patterns
attribution-detection-helper.sh scan --dry-run     # Verify before scanning
attribution-detection-helper.sh scan               # Run scan
attribution-detection-helper.sh dashboard          # View results
attribution-detection-helper.sh install            # Schedule weekly scans
```

## Canary Token Strategy

Distinctive strings embedded in framework files — when found in other public repos, the framework (or a copy) is present.

### Default canaries

| Name | Pattern | Source |
|------|---------|--------|
| `spdx-header` | `SPDX-FileCopyrightText: 2025-2026 Marcus Quinn` | All framework files |
| `aidevops-sh-domain` | `aidevops.sh` | Signature footers, docs |
| `shared-constants-guard` | `_SHARED_CONSTANTS_LOADED` | `shared-constants.sh` |
| `pulse-wrapper-label` | `sh.aidevops.pulse` | `pulse-wrapper.sh` |
| `full-loop-helper-state` | `FULL_LOOP_COMPLETE` | `full-loop-helper.sh` |

### Adding custom canaries

```bash
attribution-detection-helper.sh canary add my-func "my_unique_function_name" "Custom function"
attribution-detection-helper.sh canary add my-comment "# aidevops: my-unique-comment" "Custom comment"
```

### Canary design principles

1. **Distinctive** — unlikely to appear in unrelated code
2. **Stable** — won't change frequently (avoid version numbers)
3. **Searchable** — short enough for GitHub code search (< 256 chars)
4. **Non-sensitive** — safe to search for publicly

### Behavioural fingerprint areas

Keep exact search strings private, but monitor for distinctive aidevops
behaviour clusters as well as literal source strings:

- prompt-injection scanning for issue, PR, web, MCP, and tool-output content;
- external-author `needs-maintainer-review` gates, trusted-author normalization, and cryptographic approvals;
- interactive issue/PR locking through origin labels, active statuses, and claim stamps;
- linked-worktree safety and pre-edit gates;
- review-bot settlement gates before merge;
- parent-task dispatch blockers and decomposition lifecycle controls;
- provenance checks, origin pings, and attribution canaries.

## Private Detection Repo

For comprehensive monitoring (Cloudflare KV canary pings, full attribution manifest), set up a private detection repo. Keep methodology private: custom canary patterns reveal what you consider distinctive, results may contain sensitive repo names, and exposure lets bad actors avoid detection.

```bash
attribution-detection-helper.sh setup-private-repo
```

## Interpreting Results

| Status | Meaning | Action |
|--------|---------|--------|
| `attributed` | Repo is in the known/expected list | None required |
| `unattributed` | Repo not in known list | Review and decide |

### When you find an unattributed detection

1. **Check the repo** — fork/derivative? Tutorial? Copy?
2. **Assess intent** — accidental omission vs deliberate copying
3. **Decide action:**
   - **Fork/derivative**: Open a friendly issue suggesting attribution
   - **Tutorial/example**: Usually fine, consider reaching out positively
   - **Commercial copy**: May warrant a DMCA notice (consult legal advice)
   - **False positive**: Add to `attributed_repos` in the canary config

### Adding a repo to the attributed list

```bash
jq '(.[] | select(.name == "spdx-header") | .attributed_repos) += ["owner/repo"]' \
  ~/.aidevops/cache/attribution-canaries.json > /tmp/canaries.json
mv /tmp/canaries.json ~/.aidevops/cache/attribution-canaries.json
```

## GitHub Code Search Limits

| Tier | Rate limit | Notes |
|------|-----------|-------|
| Authenticated | 30 req/min | Requires `gh auth login` |
| Unauthenticated | 10 req/min | Not recommended |

Script sleeps 3 seconds between requests (20 req/min). Only **public** repos are indexed.

## Scheduling

```bash
attribution-detection-helper.sh install    # Install weekly Monday 03:00 (launchd/cron)
attribution-detection-helper.sh uninstall  # Remove
```

## State Files

All state in `~/.aidevops/cache/` — not committed to the public repo.

| File | Purpose |
|------|---------|
| `~/.aidevops/cache/attribution-canaries.json` | Registered canary patterns |
| `~/.aidevops/cache/attribution-detections.json` | Latest scan results |
| `~/.aidevops/logs/attribution-detection.log` | Operation log |

## Privacy

- Search queries are visible to GitHub — avoid canaries that reveal sensitive internal details
- Results may contain private repo names — store in private detection repo, not public commits
- False positives — common strings match many repos; tune canaries to be distinctive

## Related

- `scripts/attribution-detection-helper.sh` — main tool
- `scripts/contribution-watch-helper.sh` — monitor external contributions
- `scripts/cch-canary.sh` — Claude CLI signing canary
- `reference/contribution-watch.md` — contribution monitoring guide
