<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MCP Integrations

Complete guide to Model Context Protocol (MCP) integrations in the AI DevOps Framework.

## Overview

The framework includes 10 MCP servers that provide real-time integration between AI assistants and various development tools, services, and documentation.

**Benefits**:

- Real-time access to documentation and APIs
- Browser automation and testing capabilities
- SEO analysis and research tools
- Performance monitoring and debugging
- Direct database access for development

## Available MCP Servers

### Web & Browser Automation (3 servers)

#### Chrome DevTools MCP

Browser automation, debugging, and performance analysis.

**Installation**:

```bash
# Add to Claude Desktop
claude mcp add chrome-devtools npx chrome-devtools-mcp@latest

# Or install globally
npm install -g chrome-devtools-mcp
```

**Configuration**:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--viewport=1920x1080"
      ]
    }
  }
}
```

**Use Cases**:

- Performance debugging
- Core Web Vitals analysis
- JavaScript debugging
- Network monitoring
- DOM manipulation

---

#### Playwright MCP

Cross-browser testing and automation.

**Installation**:

```bash
npx -y playwright@latest install
```

**Configuration**:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@0.0.79", "--headless", "--isolated"]
    }
  }
}
```

**Use Cases**:

- E2E testing
- Cross-browser compatibility
- Visual regression testing
- Screenshot automation
- Form testing

---

#### Cloudflare Browser Rendering

Server-side web scraping and rendering.

**Installation**:

```bash
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
```

**Configuration**:

```json
{
  "mcpServers": {
    "cloudflare-browser": {
      "command": "npx",
      "args": [
        "cloudflare-browser-rendering-mcp@latest",
        "--account-id=${CLOUDFLARE_ACCOUNT_ID}",
        "--api-token=${CLOUDFLARE_API_TOKEN}"
      ]
    }
  }
}
```

**Use Cases**:

- Server-side web scraping
- JavaScript-heavy page rendering
- Content extraction
- Distributed testing

---

### SEO & Research Tools (3 servers)

#### Ahrefs MCP

SEO analysis, backlink research, and keyword data.

**Installation**:

```bash
# Get standard 40-char API key from https://ahrefs.com/api
# Note: JWT-style tokens do NOT work - use the standard API key
export AHREFS_API_KEY="your_40_char_api_key"

# For Claude Desktop:
claude mcp add ahrefs npx @ahrefs/mcp@latest
```

**API Key**: Get standard 40-char key from [Ahrefs API Dashboard](https://ahrefs.com/api) (JWT tokens don't work)

**For OpenCode**: Use bash wrapper pattern (environment blocks don't expand variables):

```json
{
  "ahrefs": {
    "type": "local",
    "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
    "enabled": true
  }
}
```

**Important**: The `@ahrefs/mcp` package expects `API_KEY` env var, not `AHREFS_API_KEY`.

**Use Cases**:

- Keyword research
- Backlink analysis
- Competitor analysis
- Domain rating checks
- Content gap analysis

---

#### Perplexity MCP

AI-powered web search and research.

**Installation**:

```bash
export PERPLEXITY_API_KEY="your_api_key"
claude mcp add perplexity npx perplexity-mcp@latest
```

**API Key**: Get from [Perplexity API](https://docs.perplexity.ai/)

**Use Cases**:

- Research automation
- Content ideation
- Fact-checking
- Topic exploration
- Competitive intelligence

---

#### Google Search Console MCP

Search performance data and insights.

**Installation**:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
claude mcp add google-search-console npx mcp-server-gsc@latest
```

**Setup**: Requires Google Cloud service account with Search Console API access

**Use Cases**:

- Search performance tracking
- Query analysis
- Click-through rate optimization
- Index status monitoring
- Search appearance insights

---

### Performance & Analytics (1 server)

#### PageSpeed Insights MCP

Website performance auditing and optimization.

**Installation**:

```bash
bash .agents/scripts/setup-mcp-integrations.sh pagespeed
```

**Use Cases**:

- Performance scoring
- Core Web Vitals
- Mobile optimization
- Speed optimization recommendations
- Competitive benchmarking

---

### Development Tools (4 servers)

#### Claude Code MCP (Fork)

Run Claude Code as an MCP server for automation.

**Installation**:

```bash
claude mcp add claude-code-mcp "npx -y github:marcusquinn/claude-code-mcp"
```

**Upstream**: https://github.com/steipete/claude-code-mcp (revert if merged).
**Local dev (optional)**: clone the fork and edit your MCP configuration (for example `~/.cursor/mcp.json` or `~/.config/opencode/opencode.json`) to replace the `npx` command with the local `./start.sh` script.

**One-time setup**: run `claude --dangerously-skip-permissions` and accept prompts.

**Use Cases**:

- Run Claude Code workflows from MCP clients
- Multi-step code edits via Claude Code CLI
- Reuse Claude Code toolchain in Cursor/Windsurf

---

#### Next.js DevTools MCP

Next.js development and debugging assistance.

**Installation**:

```bash
npm install -g nextjs-devtools-mcp
```

**Use Cases**:

- Route debugging
- SSR/SSG optimization
- Build analysis
- Performance profiling
- API route testing

---

#### Context7 MCP

Real-time documentation access for thousands of libraries.

**Installation**:

```bash
bash .agents/scripts/setup-mcp-integrations.sh context7
```

**Supported Libraries**: React, Vue, Angular, Node.js, Python, and 1000+ more

**Use Cases**:

- API reference lookup
- Code examples
- Best practices
- Migration guides
- Version compatibility

---

#### LocalWP MCP

Direct WordPress database access for local development.

**Installation**:

```bash
bash .agents/scripts/setup-mcp-integrations.sh localwp
```

**Requirements**: Local by Flywheel or similar WordPress environment

**Use Cases**:

- Database queries
- Content management
- Plugin development
- Theme customization
- Debug logging

---

## Quick Setup

### Install All MCP Servers

```bash
# Run comprehensive setup
bash .agents/scripts/setup-mcp-integrations.sh all

# Validate installation
bash .agents/scripts/validate-mcp-integrations.sh
```

### Install Specific Server

```bash
# Chrome DevTools
bash .agents/scripts/setup-mcp-integrations.sh chrome-devtools

# Playwright
bash .agents/scripts/setup-mcp-integrations.sh playwright

# Ahrefs
bash .agents/scripts/setup-mcp-integrations.sh ahrefs

# Claude Code MCP (fork)
bash .agents/scripts/setup-mcp-integrations.sh claude-code-mcp

# Context7
bash .agents/scripts/setup-mcp-integrations.sh context7
```

## Configuration

### Directory Structure

| Location | Purpose |
|----------|---------|
| `~/.config/aidevops/` | **Secrets only** - `mcp-env.sh` (600 perms) |
| `~/.aidevops/` | **Working directories** - agno, stagehand, reports |

### API Keys Setup

Store API keys securely using the helper script:

```bash
# Initialize (creates mcp-env.sh, adds shell integration)
bash ~/git/aidevops/.agents/scripts/setup-local-api-keys.sh setup

# Add keys using service names (converted to UPPER_CASE)
bash .agents/scripts/setup-local-api-keys.sh set ahrefs-api-key your_key
bash .agents/scripts/setup-local-api-keys.sh set perplexity-api-key your_key
bash .agents/scripts/setup-local-api-keys.sh set cloudflare-account-id your_id
bash .agents/scripts/setup-local-api-keys.sh set cloudflare-api-token your_token

# Or paste export commands from services directly
bash .agents/scripts/setup-local-api-keys.sh add 'export VERCEL_TOKEN="xxx"'

# List configured keys
bash .agents/scripts/setup-local-api-keys.sh list
```

### Environment Variables

Keys are automatically available in all shells via `~/.config/aidevops/mcp-env.sh`:

```bash
# File is sourced automatically by ~/.zshrc and ~/.bashrc
# To reload after adding keys:
source ~/.zshrc  # or ~/.bashrc

# Verify keys are loaded
echo $AHREFS_API_KEY
```

### Claude Desktop Configuration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest", "--headless=true"]
    },
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@0.0.79", "--headless", "--isolated"]
    },
    "ahrefs": {
      "command": "npx",
      "args": ["-y", "@ahrefs/mcp@latest"],
      "env": {
        "API_KEY": "${AHREFS_API_KEY}"
      }
    },
    "perplexity": {
      "command": "npx",
      "args": ["perplexity-mcp@latest"],
      "env": {
        "PERPLEXITY_API_KEY": "${PERPLEXITY_API_KEY}"
      }
    },
    "context7": {
      "command": "npx",
      "args": ["context7-mcp@latest"]
    }
  }
}
```

## Usage Examples

### Web Development Workflow

```bash
# 1. Debug performance with Chrome DevTools
# AI: "Analyze performance of https://example.com"

# 2. Run cross-browser tests with Playwright
# AI: "Test login flow across Chrome, Firefox, and Safari"

# 3. Audit with PageSpeed
./.agents/scripts/pagespeed-helper.sh lighthouse https://example.com

# 4. Look up Next.js best practices
# AI: "Show me Next.js SSR optimization techniques"
```

### SEO Analysis Workflow

```bash
# 1. Research keywords with Ahrefs
# AI: "Find top keywords for 'cloud hosting'"

# 2. Analyze search performance with GSC
# AI: "Show top queries for example.com last 30 days"

# 3. Research with Perplexity
# AI: "Research competitor content strategies for SaaS"

# 4. Scrape competitor pages
# AI: "Extract pricing data from competitor.com"
```

### WordPress Development Workflow

```bash
# 1. Create local site
./.agents/scripts/localhost-helper.sh create-site mysite.local

# 2. Query database via MCP
# AI: "Show all published posts from last week"

# 3. Look up WordPress hooks
# AI: "Find Context7 documentation for wp_enqueue_scripts"

# 4. Test performance
./.agents/scripts/pagespeed-helper.sh wordpress https://mysite.local
```

## Real-World Use Cases

### 1. Performance Optimization

**Scenario**: Website is slow, need to identify bottlenecks

**Tools**:

- Chrome DevTools MCP: Analyze runtime performance
- PageSpeed MCP: Get optimization recommendations
- Lighthouse: Comprehensive audit

**Workflow**:

```text
AI: "Analyze performance of https://example.com"
→ Chrome DevTools runs performance profile
→ PageSpeed generates audit
→ AI provides prioritized optimization list
```

---

### 2. SEO Competitive Analysis

**Scenario**: Improve search rankings for target keywords

**Tools**:

- Ahrefs MCP: Keyword and backlink research
- Google Search Console MCP: Current performance data
- Perplexity MCP: Content research

**Workflow**:

```text
AI: "Analyze SEO competition for 'cloud hosting'"
→ Ahrefs finds top-ranking pages
→ GSC shows current ranking position
→ Perplexity researches content gaps
→ AI generates optimization strategy
```

---

### 3. Automated Testing

**Scenario**: Need comprehensive cross-browser testing

**Tools**:

- Playwright MCP: Multi-browser automation
- Chrome DevTools MCP: Debugging
- Visual regression testing

**Workflow**:

```text
AI: "Test checkout flow across all browsers"
→ Playwright runs tests on Chrome, Firefox, Safari
→ Screenshots captured for comparison
→ Chrome DevTools debugs any failures
→ AI reports results with fixes
```

---

### 4. Development Assistance

**Scenario**: Building Next.js app, need real-time help

**Tools**:

- Context7 MCP: Documentation lookup
- Next.js DevTools MCP: Debugging
- Chrome DevTools MCP: Performance

**Workflow**:

```text
AI: "How do I optimize this Next.js page?"
→ Context7 provides Next.js best practices
→ Next.js DevTools analyzes current setup
→ Chrome DevTools profiles performance
→ AI suggests specific improvements
```

## Validation & Testing

### Check Installation Status

```bash
bash .agents/scripts/validate-mcp-integrations.sh
```

**Expected Output**:

```text
✅ Chrome DevTools MCP: Installed
✅ Playwright MCP: Installed
✅ Ahrefs MCP: Configured
✅ Perplexity MCP: Configured
✅ Context7 MCP: Installed
✅ PageSpeed MCP: Installed
✅ LocalWP MCP: Installed

✅ Overall status: EXCELLENT (100% success rate)
✅ All MCP integrations are ready to use!
```

### Test Individual Integration

```bash
# Test Chrome DevTools
npx chrome-devtools-mcp@latest --help

# Test Playwright
npx -y @playwright/mcp@0.0.79 --version

# Test Context7
npx context7-mcp@latest search "React useState"
```

## Troubleshooting

### Ahrefs MCP "Connection Closed" Error

This is a common issue with multiple potential causes:

**Cause 1: Wrong API key type**
- JWT-style tokens (long strings with dots) do NOT work
- Use standard 40-character API key from https://ahrefs.com/api
- Verify: `echo $AHREFS_API_KEY | wc -c` should be ~40-45

**Cause 2: Wrong environment variable name**
- The `@ahrefs/mcp` package expects `API_KEY`, not `AHREFS_API_KEY`
- Store as `AHREFS_API_KEY` in your env, pass as `API_KEY` to the MCP

**Cause 3: OpenCode environment blocks don't expand variables**

```bash
# This does NOT work in OpenCode - treats ${AHREFS_API_KEY} as literal:
# "env": { "API_KEY": "${AHREFS_API_KEY}" }

# Solution: Use bash wrapper pattern:
# "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY npx -y @ahrefs/mcp@latest"]
```

**Working OpenCode configuration:**

```json
{
  "ahrefs": {
    "type": "local",
    "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
    "enabled": true
  }
}
```

**Verify API key works:**

```bash
curl -H "Authorization: Bearer $AHREFS_API_KEY" https://apiv2.ahrefs.com/v2/subscription_info
# Should return JSON with subscription info
```

---

### Common Issues

**Problem**: MCP server not starting

**Solution**:

```bash
# Check if port is already in use
lsof -i :port_number

# Restart with debug logging
npx chrome-devtools-mcp@latest --logFile=/tmp/chrome-mcp.log
tail -f /tmp/chrome-mcp.log
```

---

**Problem**: API key not recognized

**Solution**:

```bash
# Verify environment variable is set
echo $AHREFS_API_KEY

# Reload environment (keys are in mcp-env.sh, sourced by shell config)
source ~/.zshrc  # or ~/.bashrc

# Test API connection
curl -H "Authorization: Bearer $AHREFS_API_KEY" https://apiv2.ahrefs.com/v2/subscription_info
```

---

**Problem**: Chrome not found

**Solution**:

```bash
# Install Chrome Canary
brew install --cask google-chrome-canary

# Or specify Chrome path
npx chrome-devtools-mcp@latest --chromePath=/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome
```

## Best Practices

### Security

- Store API keys in secure files with 600 permissions
- Never commit API keys to repositories
- Use environment variables for sensitive data
- Rotate API keys regularly

### Performance

- Use headless mode for Chrome when possible
- Cache Context7 documentation locally
- Limit concurrent browser instances
- Close MCP servers when not in use

### Development

- Test MCP integrations in isolation first
- Use validation script after configuration changes
- Keep MCP servers updated to latest versions
- Monitor logs for errors and warnings

## Advanced Configuration

### Custom Chrome DevTools Setup

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--isolated=true",
        "--viewport=1920x1080",
        "--userDataDir=/tmp/chrome-mcp-profile",
        "--logFile=/tmp/chrome-mcp.log",
        "--debugPort=9222"
      ]
    }
  }
}
```

### Playwright with Custom Browsers

```bash
# Install specific browsers
npx -y playwright@latest install chromium firefox webkit

# Configure custom browser paths
export PLAYWRIGHT_BROWSERS_PATH=/custom/path
```

## Resources

### Official Documentation

- [MCP Protocol Specification](https://modelcontextprotocol.io/)
- [Chrome DevTools MCP](https://github.com/modelcontextprotocol/servers/tree/main/chrome-devtools)
- [Playwright Documentation](https://playwright.dev/)
- [Ahrefs API Docs](https://ahrefs.com/api/documentation)
- [Perplexity API Docs](https://docs.perplexity.ai/)

### Internal Documentation

- [MCP Integration Setup Script](../.agents/scripts/setup-mcp-integrations.sh)
- [MCP Validation Script](../.agents/scripts/validate-mcp-integrations.sh)
- [API Integrations Guide](../.agents/api-integrations.md)
- [Browser Automation Guide](../.agents/browser-automation.md)

---

**Next**: [Configuration Guide →](Configuration.md)
