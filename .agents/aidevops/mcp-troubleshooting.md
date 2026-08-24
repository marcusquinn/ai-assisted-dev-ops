---
description: Quick troubleshooting for MCP connection issues
mode: subagent
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MCP Troubleshooting Quick Reference

<!-- AI-CONTEXT-START -->

- **Scripts**: `mcp-diagnose.sh check-all`, `tool-version-check.sh`
- **Primary cause**: version mismatch (outdated tool, changed MCP command)
- **Config**: `~/.config/opencode/opencode.json`
- **On-demand activation**: `failed`/`error` status gets one automatic disconnect/reconnect; a second failure is terminal
- **Dead schemas (t1682)**: MCP tools can remain listed after startup failure; treat that server as unavailable for the session

## Bounded On-Demand Recovery

When the registry-approved `aidevops_mcp` activation tool observes `failed` or `error` status, it makes exactly one automatic reset: disconnect the same MCP, reconnect it, and poll for readiness again. The allowlist remains unchanged and the tool never loops.

If the reset API is unavailable or the second attempt fails, run `mcp-diagnose.sh <mcp-name>` and restart OpenCode after fixing the cause. Timeouts, authentication requirements, direct API errors, and dead tool-schema errors do not trigger this reset.

## Errored Servers — Dead Tool Schemas (t1682)

When an MCP server fails to start, its tool schemas can remain in the tool list. Calls then fail with `MCP error -32000: Connection closed`, wasting context tokens.

```bash
# Detect errored servers
~/.aidevops/agents/scripts/mcp-diagnose.sh check-all

# Disable persistently errored server in ~/.config/opencode/opencode.json
{ "playwright": { "enabled": false } }
# Restart runtime to reload tool list.
```

**Agent rule:** On `MCP error -32000`, `Connection closed`, `spawn ENOENT`, or similar startup failures, mark that server unavailable for the session and do not retry it. See `AGENTS.md` "Errored MCP Server Guard".

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| "Config file is invalid" | Unsupported key (`workdir`, `cwd`, `env`) | Remove key; use `environment` instead of `env`; wrap `cwd` as `["/bin/bash", "-c", "cd /path && cmd"]` |
| "Connection closed" | Wrong command or outdated version | Update tool, check command syntax |
| "Command not found" | Tool not installed | `npm install -g {package}` |
| "Permission denied" | Missing credentials | Check `~/.config/aidevops/credentials.sh` |
| "Timeout" | Server not starting | Check Node.js version, run command manually |
| "unauthorized" | HTTP server instead of MCP | Use correct MCP command (not `serve`) |

## Diagnostic Commands

```bash
~/.aidevops/agents/scripts/mcp-diagnose.sh check-all   # scan all servers (t1682)
~/.aidevops/agents/scripts/mcp-diagnose.sh <mcp-name>  # diagnose specific MCP
~/.aidevops/agents/scripts/tool-version-check.sh        # check versions
~/.aidevops/agents/scripts/tool-version-check.sh --update  # update outdated tools
opencode mcp list                                        # verify MCP status
```

<!-- AI-CONTEXT-END -->

## Version-Specific Issues

### context7

Remote MCP; no local installation needed.

```json
{ "context7": { "type": "remote", "url": "https://mcp.context7.com/mcp", "enabled": true } }
```

## Manual MCP Testing

Run the configured MCP command directly. Expect JSON-RPC startup output, not an HTTP server banner:

```bash
<configured MCP command>
```

## Related

- [add-new-mcp-to-aidevops.md](add-new-mcp-to-aidevops.md) — MCP setup workflow
- [tools/opencode/opencode.md](../tools/opencode/opencode.md) — OpenCode configuration
- [troubleshooting.md](troubleshooting.md) — General troubleshooting
