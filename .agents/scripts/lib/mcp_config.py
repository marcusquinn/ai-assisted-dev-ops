"""MCP server registration and loading policy helpers.

Extracted from agent-discovery.py and opencode-agent-discovery.py as part
of t2130 to reduce file complexity. Provides the MCP configuration logic
shared by both discovery scripts.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import os
import platform
import sys


# =============================================================================
# MCP LOADING POLICY
# =============================================================================

# Eager-loaded (enabled: True): Used by all main agents, start at launch
# No eager MCPs — all start disabled to save context tokens
EAGER_MCPS = set()

# On-demand (enabled: False): remain disabled until an explicit runtime connector
LAZY_MCPS = {
    'MCP_DOCKER', 'ahrefs', 'amazon-order-history',
    'chrome-devtools', 'claude-code-mcp', 'context7', 'dataforseo',
    'google-analytics-mcp', 'grep_app', 'gsc', 'ios-simulator', 'localwp',
    'macos-automator', 'openapi-search', 'outscraper', 'playwriter', 'quickfile',
    'sentry', 'shadcn', 'socket', 'websearch',
}

# Oh-My-OpenCode tool patterns to disable globally
OMO_TOOL_PATTERNS = ['grep_app_*', 'websearch_*']
PLAYWRITER_MCP_PACKAGE = 'playwriter@0.5.0'
LEGACY_PLAYWRITER_MCP_PACKAGE = 'playwriter@latest'


def _is_legacy_generated_playwriter_command(command):
    """Return whether command is an exact prior generated Playwriter launcher."""
    if not isinstance(command, list) or not command:
        return False
    runner = command[0]
    is_runner = isinstance(runner, str) and (
        runner == 'npx' or (os.path.isabs(runner) and os.path.basename(runner) == 'npx')
    )
    is_bun = isinstance(runner, str) and (
        runner == 'bun' or (os.path.isabs(runner) and os.path.basename(runner) == 'bun')
    )
    return (
        is_runner and command[1:] in (
            [LEGACY_PLAYWRITER_MCP_PACKAGE],
            ['-y', LEGACY_PLAYWRITER_MCP_PACKAGE],
        )
    ) or (is_bun and command[1:] == ['x', LEGACY_PLAYWRITER_MCP_PACKAGE])


def apply_mcp_loading_policy(config):
    """Apply EAGER/LAZY loading policy to existing MCPs in config.

    Returns list of uncategorized MCP names.
    """
    uncategorized = []
    for mcp_name in list(config.get('mcp', {}).keys()):
        mcp_cfg = config['mcp'].get(mcp_name, {})
        if not isinstance(mcp_cfg, dict):
            print(f"  Warning: MCP '{mcp_name}' has non-dict config "
                  f"({type(mcp_cfg).__name__}), skipping", file=sys.stderr)
            continue
        if mcp_name in EAGER_MCPS:
            mcp_cfg['enabled'] = True
        elif mcp_name in LAZY_MCPS:
            mcp_cfg['enabled'] = False
        else:
            uncategorized.append(mcp_name)
    return uncategorized


def remove_deprecated_mcps(config):
    """Remove deprecated MCP entries from config."""
    if 'osgrep' in config.get('mcp', {}):
        del config['mcp']['osgrep']
        print("  Removed deprecated osgrep MCP")
    if 'osgrep_*' in config.get('tools', {}):
        del config['tools']['osgrep_*']
    # gh_grep MCP removed — github-search subagent uses rg/bash instead
    if 'gh_grep' in config.get('mcp', {}):
        del config['mcp']['gh_grep']
        print("  Removed deprecated gh_grep MCP")
    if 'gh_grep_*' in config.get('tools', {}):
        del config['tools']['gh_grep_*']


def _register_playwriter(config, bun_path):
    """Register playwriter MCP (browser automation)."""
    if 'playwriter' not in config['mcp']:
        if bun_path:
            config['mcp']['playwriter'] = {
                "type": "local",
                "command": ["bun", "x", PLAYWRITER_MCP_PACKAGE],
                "enabled": False
            }
        else:
            config['mcp']['playwriter'] = {
                "type": "local",
                "command": ["npx", PLAYWRITER_MCP_PACKAGE],
                "enabled": False
            }
        print("  Added playwriter MCP (on demand - @playwriter only)")
    elif isinstance(config['mcp']['playwriter'], dict):
        playwriter_config = config['mcp']['playwriter']
        command = playwriter_config.get('command')
        if _is_legacy_generated_playwriter_command(command):
            command[command.index(LEGACY_PLAYWRITER_MCP_PACKAGE)] = PLAYWRITER_MCP_PACKAGE
            print("  Pinned legacy playwriter MCP command to 0.5.0")
        playwriter_config['enabled'] = False
    config['tools']['playwriter_*'] = False


def _register_outscraper(config):
    """Register outscraper MCP (business intelligence)."""
    if 'outscraper' not in config['mcp']:
        config['mcp']['outscraper'] = {
            "type": "local",
            "command": ["/bin/bash", "-c",
                        "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
            "enabled": False
        }
        print("  Added outscraper MCP (lazy load - @outscraper subagent only)")
    if 'outscraper_*' not in config['tools']:
        config['tools']['outscraper_*'] = False


def _register_dataforseo(config, pkg_runner):
    """Register dataforseo MCP (SEO data)."""
    if 'dataforseo' not in config['mcp']:
        config['mcp']['dataforseo'] = {
            "type": "local",
            "command": ["/bin/bash", "-c",
                        f"source ~/.config/aidevops/credentials.sh && "
                        f"DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME "
                        f"DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD "
                        f"{pkg_runner} dataforseo-mcp-server"],
            "enabled": False
        }
        print("  Added dataforseo MCP (lazy load - SEO agent/@dataforseo subagent)")
    if 'dataforseo_*' not in config['tools']:
        config['tools']['dataforseo_*'] = False


def _register_shadcn(config):
    """Register shadcn MCP (UI component library)."""
    if 'shadcn' not in config['mcp']:
        config['mcp']['shadcn'] = {
            "type": "local",
            "command": ["npx", "shadcn@latest", "mcp"],
            "enabled": False
        }
        print("  Added shadcn MCP (lazy load - @shadcn subagent only)")
    if 'shadcn_*' not in config['tools']:
        config['tools']['shadcn_*'] = False


def _register_claude_code_mcp(config):
    """Register claude-code-mcp (always overwrite for correct fork)."""
    config['mcp']['claude-code-mcp'] = {
        "type": "local",
        "command": ["npx", "-y", "github:marcusquinn/claude-code-mcp"],
        "enabled": False
    }
    print("  Set claude-code-mcp to lazy load (@claude-code subagent only)")
    config['tools']['claude-code-mcp_*'] = False


def _register_macos_mcps(config):
    """Register macOS-only MCP servers (automator + iOS simulator)."""
    if platform.system() != 'Darwin':
        return

    if 'macos-automator' not in config['mcp']:
        config['mcp']['macos-automator'] = {
            "type": "local",
            "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
            "enabled": False
        }
        print("  Added macos-automator MCP (lazy load - @mac subagent only)")
    if 'macos-automator_*' not in config['tools']:
        config['tools']['macos-automator_*'] = False

    if 'ios-simulator' not in config['mcp']:
        config['mcp']['ios-simulator'] = {
            "type": "local",
            "command": ["npx", "-y", "ios-simulator-mcp"],
            "enabled": False
        }
        print("  Added ios-simulator MCP (lazy load - @ios-simulator-mcp subagent only)")
    if 'ios-simulator_*' not in config['tools']:
        config['tools']['ios-simulator_*'] = False


def _register_openapi_search(config):
    """Register openapi-search MCP (remote Cloudflare Worker)."""
    if 'openapi-search' not in config['mcp']:
        config['mcp']['openapi-search'] = {
            "type": "remote",
            "url": "https://openapi-mcp.openapisearch.com/mcp",
            "enabled": False
        }
        print("  Added openapi-search MCP (lazy load - @openapi-search subagent only)")
    if 'openapi-search_*' not in config['tools']:
        config['tools']['openapi-search_*'] = False


def _disable_omo_tools(config):
    """Disable Oh-My-OpenCode MCP tools globally."""
    for tool_pattern in OMO_TOOL_PATTERNS:
        if config['tools'].get(tool_pattern) is not False:
            config['tools'][tool_pattern] = False
            print(f"  Disabled {tool_pattern} tools globally (use matching subagent/CLI workflow)")


def register_standard_mcps(config, bun_path, pkg_runner):
    """Register all standard MCP servers if not already present."""
    _register_playwriter(config, bun_path)
    _register_outscraper(config)
    _register_dataforseo(config, pkg_runner)
    _register_shadcn(config)
    _register_claude_code_mcp(config)
    _register_macos_mcps(config)
    _register_openapi_search(config)
    _disable_omo_tools(config)
