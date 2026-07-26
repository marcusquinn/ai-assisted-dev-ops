---
description: On-demand MCP tool discovery - find and enable MCPs as needed
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MCP On-Demand Discovery

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Discover MCP tools without loading all definitions upfront
- **Pattern**: Search -> Find MCP -> Enable -> Use
- **Script**: `~/.aidevops/agents/scripts/mcp-index-helper.sh`
- **Alternative**: MCPorter (`npx mcporter list`) -- ad-hoc discovery across all configured MCP clients

```bash
# Search for tools by capability
mcp-index-helper.sh search "screenshot web"
mcp-index-helper.sh search "seo keyword"

# List all MCPs or a specific one
mcp-index-helper.sh list
mcp-index-helper.sh list context7

# Find which MCP provides a tool
mcp-index-helper.sh get-mcp "query-docs"

# Sync / rebuild index
mcp-index-helper.sh sync
mcp-index-helper.sh rebuild   # force full rebuild
mcp-index-helper.sh status    # show DB path, last sync, tool counts

# MCPorter alternative (reads all configured MCP clients live)
npx mcporter list                          # all servers
npx mcporter list context7 --schema        # one server with schemas
npx mcporter call context7.resolve-library-id libraryName=react
npx mcporter generate-cli --command https://mcp.context7.com/mcp --compile
```

**Disabled MCPs** (enabled via subagents):

| MCP | Tokens | Subagent | When to enable |
|-----|--------|----------|----------------|
| `playwriter` | ~3K | `@playwriter` | Browser automation needed |
| `google-analytics-mcp` | ~800 | `@google-analytics` | Analytics reporting |
| `context7` | ~800 | `@context7` | Library docs lookup |

**Not installed by aidevops** (use subagent instead):

| MCP | Subagent | Notes |
|-----|----------|-------|
| `grep_app` | `@github-search` | GitHub code search (no MCP used) |

**Primary search**: use `git grep`/`rg` for exact content search and `git ls-files`/`fd` for file discovery, then read likely files directly for model comprehension.

<!-- AI-CONTEXT-END -->

## Architecture

MCP tool definitions consume context tokens (e.g. `context7` ~2K, `repomix` ~5K, `chrome-devtools` ~17K for 50+ tools). Loading all MCPs globally means every conversation pays this cost even when most tools go unused.

**Lazy-load pattern** (inspired by [Amp's approach](https://ampcode.com/news/lazy-load-mcp-with-skills)):

1. **Index**: Tool descriptions extracted into SQLite FTS5 (`~/.aidevops/.agent-workspace/mcp-index/mcp-tools.db`)
2. **Search**: Agent queries index for needed capability
3. **Discover**: Index returns which MCP provides the tool
4. **Enable**: Agent enables that specific MCP
5. **Use**: Tool available with minimal token overhead

**Auto-sync triggers**: `opencode.json` modified, index >24h old, or index missing.

**Token savings** (on-demand vs all-MCPs-loaded):

| Scenario | All Loaded | On-Demand | Savings |
|----------|------------|-----------|---------|
| Simple code task | ~50K | ~5K | 90% |
| SEO analysis | ~50K | ~12K | 76% |
| Browser automation | ~50K | ~20K | 60% |

## MCPorter

[MCPorter](https://mcporter.dev) (`steipete/mcporter`, MIT) is a TypeScript runtime/CLI that reads directly from all configured MCP clients (Claude Code, Claude Desktop, Cursor, Codex, Windsurf, OpenCode, VS Code) and queries live servers -- unlike `mcp-index-helper.sh` which queries a local SQLite index.

| Scenario | Use |
|----------|-----|
| Searching local index for a capability | `mcp-index-helper.sh search "capability"` |
| Discovering tools across all MCP clients | `npx mcporter list` |
| Calling a tool ad-hoc without config changes | `npx mcporter call server.tool arg=value` |
| Generating a typed CLI or TypeScript client | `npx mcporter generate-cli` / `mcporter emit-ts` |
| Keeping stateful servers warm between calls | `mcporter daemon start` |

See `tools/mcp-toolkit/mcporter.md` for full docs and `aidevops/mcp-integrations.md` for setup.

## Integration with Agents

### Subagent Frontmatter

Subagents declare MCP requirements via the `mcp:` field:

```yaml
---
description: Browser automation via Chrome extension
mode: subagent
tools:
  read: true
  bash: true
mcp:
  - playwriter
---
```

The `mcp:` field is declarative -- it documents which MCP the subagent requires. Actual enabling happens in `generate-opencode-agents.sh` (per-agent tool permissions).

### Main Agent Pattern

Main agents don't enable MCPs directly. They reference subagents that have MCP access, or use the discovery pattern:

```markdown
# Good: Main agent references subagent
For keyword research, invoke `@dataforseo` subagent.

# Bad: Main agent enables MCP directly
tools:
  dataforseo_*: true  # DON'T DO THIS in main agents
```

### Runtime Configuration

In `opencode.json`, MCPs are disabled globally and enabled per-agent:

```json
{
  "tools": {
    "dataforseo_*": false,
    "serper_*": false
  },
  "agent": {
    "SEO": {
      "tools": {
        "dataforseo_*": true,
        "serper_*": true
      }
    }
  }
}
```

## Future: includeTools Filtering

When OpenCode implements `includeTools` ([#7399](https://github.com/anomalyco/opencode/issues/7399)), agents can specify exact tools needed -- e.g. reducing chrome-devtools from ~17K to ~1.5K tokens by requesting only 2 of 50+ tools. The current index prepares for this by tracking tool-level metadata.

## Security

MCP servers are a trust boundary. Before enabling or installing a new MCP server discovered through `mcp-index-helper.sh` or MCPorter, verify the source and scan dependencies. See `tools/mcp-toolkit/mcporter.md` "Security Considerations" for the full risk model and pre-install checklist.

## Related

- `tools/build-agent/build-agent.md` - MCP placement rules
- `aidevops/architecture.md` - Agent design patterns
- `generate-opencode-agents.sh` - Agent generation with MCP config
- `tools/mcp-toolkit/mcporter.md` - MCP security considerations
