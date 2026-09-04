---
description: SEO site crawler with Screaming Frog-like capabilities
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

# Site Crawler - SEO Spider Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/site-crawler-helper.sh`
- **Browser Tools**: `tools/browser/crawl4ai.md`, `tools/browser/playwright.md`
- **Output**: `~/Downloads/{domain}/{datestamp}/` with `_latest` symlink
- **Formats**: CSV, XLSX, JSON, HTML reports
- **Config**: `~/.config/aidevops/site-crawler.json`

```bash
site-crawler-helper.sh crawl https://example.com                          # Full crawl
site-crawler-helper.sh crawl https://example.com --depth 3 --max-urls 500
site-crawler-helper.sh crawl https://example.com --render-js              # SPAs
site-crawler-helper.sh crawl https://example.com --format xlsx
site-crawler-helper.sh audit-links https://example.com
site-crawler-helper.sh audit-meta https://example.com
site-crawler-helper.sh audit-redirects https://example.com
site-crawler-helper.sh audit-duplicates https://example.com
site-crawler-helper.sh audit-schema https://example.com
```

<!-- AI-CONTEXT-END -->

## Capabilities

**Core SEO data:** URLs (status, content type, response time, size), titles (text, length, missing/duplicate), meta descriptions (text, length, missing/duplicate), meta robots (index/noindex, follow/nofollow, canonical, directives), headings (H1/H2 content, missing/duplicate/multiple), links (internal/external, follow/nofollow, anchor text, broken), images (URL, alt text, size, missing alt), redirects (301/302/307, chains, loops, destination), canonicals (self-referencing, conflicts), hreflang (language codes, return links, conflicts), structured data (JSON-LD, Microdata, RDFa extraction/validation).

**Advanced:** JS rendering via Chromium (React, Vue, Angular SPAs), custom extraction (XPath, CSS selectors, regex), robots.txt analysis (blocked URLs, directives, crawl delays), XML sitemap analysis (orphan/missing pages), duplicate detection (MD5 hash, similarity scoring), crawl depth tracking, word count analysis.

## Usage

```bash
# Scope limiting
site-crawler-helper.sh crawl https://example.com \
  --depth 3 --max-urls 1000 \
  --include "/blog/*" --exclude "/admin/*,/wp-json/*"

# JavaScript rendering for SPAs
site-crawler-helper.sh crawl https://spa-site.com --render-js

# User agent / robots override
site-crawler-helper.sh crawl https://example.com --user-agent "Googlebot"
site-crawler-helper.sh crawl https://example.com --ignore-robots

# Export format
site-crawler-helper.sh crawl https://example.com --format all   # csv + xlsx
site-crawler-helper.sh crawl https://example.com --output ~/SEO-Audits/

# Authenticated crawl
site-crawler-helper.sh crawl https://example.com \
  --auth-type form \
  --login-url https://example.com/login \
  --username user@example.com \
  --password-env SITE_PASSWORD

# Sitemap generation
site-crawler-helper.sh generate-sitemap https://example.com
site-crawler-helper.sh generate-sitemap https://example.com \
  --changefreq weekly \
  --priority-rules "/blog/*:0.8,/*:0.5" \
  --exclude "/admin/*,/private/*"
# Output: ~/Downloads/example.com/_latest/sitemap.xml

# Crawl comparison
site-crawler-helper.sh compare https://example.com              # latest vs previous
site-crawler-helper.sh compare \
  ~/Downloads/example.com/2025-01-10_091500 \
  ~/Downloads/example.com/2025-01-15_143022
# Output: changes-report.xlsx (new/removed URLs, changed meta, redirect changes)

# Debug
site-crawler-helper.sh crawl https://example.com --verbose
site-crawler-helper.sh crawl https://example.com --save-html
```

See `tools/browser/playwright.md` for browser automation details.

## Output Structure

```text
~/Downloads/example.com/
├── 2025-01-15_143022/
│   ├── crawl-data.xlsx          # Full crawl data (all columns below)
│   ├── crawl-data.csv
│   ├── broken-links.csv         # 4XX/5XX errors
│   ├── redirects.csv            # Redirect chains
│   ├── meta-issues.csv          # Title/description issues
│   ├── duplicate-content.csv
│   ├── images.csv
│   ├── internal-links.csv
│   ├── external-links.csv
│   ├── structured-data.json
│   └── summary.json
└── _latest -> 2025-01-15_143022
```

**crawl-data.xlsx columns:** URL, Status Code, Status (OK/Redirect/Client Error/Server Error), Content Type, Title, Title Length, Meta Description, Description Length, H1, H1 Count, H2, H2 Count, Canonical, Meta Robots, Word Count, Response Time (ms), File Size (bytes), Crawl Depth, Inlinks, Outlinks, External Links, Images, Images Missing Alt.

**broken-links.csv columns:** Broken URL, Status Code, Source URL, Anchor Text, Link Type (Internal/External).

**redirects.csv columns:** Original URL, Status Code (301/302/307/308), Redirect URL, Final URL, Chain Length, Chain (full path).

## Configuration

`~/.config/aidevops/site-crawler.json`:

```json
{
  "default_depth": 10,
  "max_urls": 10000,
  "respect_robots": true,
  "render_js": false,
  "user_agent": "AIDevOps-Crawler/1.0",
  "request_delay": 100,
  "concurrent_requests": 5,
  "timeout": 30,
  "output_format": "xlsx",
  "output_directory": "~/Downloads",
  "exclude_patterns": ["/wp-admin/*", "/wp-json/*", "*.pdf", "*.zip"]
}
```

**Rate limiting:** Robots.txt honored by default (`--ignore-robots` to override). Crawl-delay directive respected. Request delay and concurrent requests configurable above.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Crawl blocked | Check robots.txt, try different user-agent |
| JS not rendering | Use `--render-js` flag |
| Missing pages | Increase `--depth` or check internal linking |
| Slow crawl | Reduce `--concurrent-requests` or increase `--request-delay` |
| Memory issues | Reduce `--max-urls` or use disk storage mode |

## Integration

- **E-E-A-T**: `eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json`
- **PageSpeed**: `site-crawler-helper.sh crawl https://example.com --include-pagespeed`
- **Crawl4AI**: JS rendering, structured data extraction, LLM content analysis, CAPTCHA handling — see `tools/browser/crawl4ai.md`

## Related Agents

- `seo/eeat-score.md` — E-E-A-T content quality scoring
- `tools/browser/crawl4ai.md` — AI-powered web crawling
- `tools/browser/playwright.md` — Browser automation
- `tools/browser/pagespeed.md` — Performance auditing
- `seo/google-search-console.md` — Search performance data
