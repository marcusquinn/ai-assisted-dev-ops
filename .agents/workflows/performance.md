---
description: Manage normalized marketing performance data or audit web performance
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance

Use the marketing Performance Plane when `$ARGUMENTS` begins with `init`,
`validate`, `ingest`, `list`, `status`, `reconcile`, or `export`. Run the deployed
`performance-helper.py` with the supplied arguments. In this source repository,
the equivalent entry point is `.agents/scripts/performance-helper.py`.

```bash
performance-helper.py init --repo .
performance-helper.py validate --adapter crm --input export.json --repo .
performance-helper.py ingest --adapter payment --input events.json --repo . --dry-run
performance-helper.py status --repo .
performance-helper.py reconcile --repo .
performance-helper.py export --kind audience --scope outreach --repo .
```

Adapters accept provider-neutral JSON envelopes for `campaign`, `social`,
`analytics`, `crm`, `commerce`, `payment`, `outreach`, and `manual`. Campaign
promotion also accepts the existing `results.md` table. Validation and dry-run do
not mutate the repository. Ingest writes only pseudonymous subjects, normalized
events, source evidence references, checkpoints, and rebuildable projections to
`_performance/marketing/`.

Safety requirements:

- Keep raw contact details, credentials, exports, and private source payloads in
  their authorized source stores. Subjects require a caller-generated SHA-256
  source identifier; the helper rejects raw identifiers.
- Measurement ingest does not authorize outreach, targeting, spend, account
  mutation, or publishing.
- Audience export fails closed: only current marketing consent is eligible, and
  active global or channel suppression always excludes the subject.
- Never merge identities automatically. Merge/split records require explicit
  evidence and `automatic: false`.
- Treat stale, partial, missing-scope, ambiguous-currency, and unverified records
  as unverified evidence. Reconcile quarantines malformed records by safe line or
  event reference without copying source content.

For all other arguments, analyze web performance using Chrome DevTools MCP.
Verify `command -v npx` and `npx chrome-devtools-mcp@latest --version`, then read
`~/.aidevops/agents/tools/performance/performance.md` for CWV thresholds and fix
patterns.

Run: Lighthouse audit → Core Web Vitals (FCP, LCP, CLS, FID, TTFB) → Network analysis (third-party scripts, request chains, bundle sizes) → Accessibility (WCAG).

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--categories=performance,accessibility,network` | all | Specific categories |
| `--device=mobile\|desktop` | mobile | Device emulation |
| `--iterations=N` | 3 | Runs to average |
| `--compare=baseline.json` | — | Compare against baseline |
| `--local` | — | Assume localhost URL |

## Report Format

```markdown
## Performance Report: [URL]

### Core Web Vitals
| Metric | Value | Status | Target |
|--------|-------|--------|--------|
| LCP | X.Xs | GOOD/NEEDS WORK/POOR | <2.5s |
| FID | Xms | GOOD/NEEDS WORK/POOR | <100ms |
| CLS | X.XX | GOOD/NEEDS WORK/POOR | <0.1 |
| TTFB | Xms | GOOD/NEEDS WORK/POOR | <800ms |

### Top Issues (Priority Order)
1. **Issue** — File: `path/to/file` — Fix: specific recommendation

### Network Dependencies
- X third-party scripts; longest chain: X requests; total blocking time: Xms

### Accessibility
- Score: X/100 — X issues found
```

For each issue: **What** (problem), **Where** (file path), **How** (code/config fix), **Impact** (expected improvement).

## Examples

```bash
/performance https://example.com                          # full audit
/performance http://localhost:3000 --local                # local dev
/performance https://example.com --device=mobile          # mobile only
/performance https://example.com --compare=baseline.json  # diff baseline
/performance https://example.com --categories=performance,accessibility
```

## Related

- `tools/performance/performance.md` — full performance subagent
- `tools/browser/pagespeed.md` — PageSpeed Insights integration
- `tools/browser/chrome-devtools.md` — Chrome DevTools MCP
