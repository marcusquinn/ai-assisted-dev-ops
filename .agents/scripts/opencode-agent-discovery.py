import json
import os
import sys

# Add lib directory to path for shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from discovery_utils import atomic_json_write
from agent_config import (
    discover_primary_agents, validate_subagent_refs,
    apply_disabled_agents, display_to_filename,
)
from mcp_config import (
    apply_mcp_loading_policy, remove_deprecated_mcps,
    register_standard_mcps, EAGER_MCPS, LAZY_MCPS,
)

config_path = os.path.expanduser("~/.config/opencode/opencode.json")
agents_dir = os.path.expanduser("~/.aidevops/agents")

config_loaded = False
try:
    with open(config_path, 'r', encoding='utf-8') as f:
        config = json.load(f)
    config_loaded = True
except FileNotFoundError:
    config = {"$schema": "https://opencode.ai/config.json"}
    config_loaded = True
except (OSError, json.JSONDecodeError) as e:
    print(f"Error: Failed to load {config_path}: {e}", file=sys.stderr)
    sys.exit(1)

# Prevent OpenCode's built-in updater from bypassing the framework-controlled
# runtime version pin and breaking fail-closed headless launches.
config['autoupdate'] = False

# =============================================================================
# DISCOVER PRIMARY AGENTS
# =============================================================================

primary_agents, sorted_agents, subagent_filtered_count = discover_primary_agents(agents_dir)

# Validate subagent references
missing_refs = validate_subagent_refs(primary_agents, agents_dir, display_to_filename)
if missing_refs:
    for agent, ref in missing_refs:
        print(f"  Warning: {agent} references subagent '{ref}' but no {ref}.md found", file=sys.stderr)

# =============================================================================
# APPLY AGENT CONFIG
# =============================================================================

# Guard: skip agent config if no primary agents discovered (avoids fatal OpenCode crash)
if not primary_agents:
    print("  WARNING: No primary agents discovered — skipping agent config update", file=sys.stderr)
    print("  (agents directory may be empty or deploy incomplete)", file=sys.stderr)
else:
    apply_disabled_agents(sorted_agents)
    print("  Disabled default 'build' and 'plan' agents")
    print("  Disabled 'Plan+', 'AI-DevOps', 'Browser-Extension-Dev', 'Mobile-App-Dev' (available as @subagents)")

    config['agent'] = sorted_agents

    # Set Build+ as the default agent (first in Tab cycle, auto-selected on startup)
    config['default_agent'] = "Build+"
    print("  Set Build+ as default agent")

# =============================================================================
# INSTRUCTIONS - Auto-load aidevops AGENTS.md for full framework context
# =============================================================================
instructions_path = os.path.expanduser("~/.aidevops/agents/AGENTS.md")
if os.path.exists(instructions_path):
    config['instructions'] = [instructions_path]
    print("  Added instructions: ~/.aidevops/agents/AGENTS.md (auto-loaded every session)")
else:
    print("  Warning: ~/.aidevops/agents/AGENTS.md not found - run setup.sh first")

print(f"  Auto-discovered {len(sorted_agents)} primary agents from {agents_dir}")
print(f"  Order: {', '.join(list(sorted_agents.keys())[:5])}...")
if subagent_filtered_count > 0:
    print(f"  Subagent filtering: {subagent_filtered_count} agents have permission.task rules")

# Count agents with custom prompts
prompt_count = sum(1 for name, cfg in sorted_agents.items() if "prompt" in cfg)
if prompt_count > 0:
    print(f"  Custom system prompts: {prompt_count} agents use prompts/build.txt")

# Count agents with model routing
model_count = sum(1 for name, cfg in sorted_agents.items() if "model" in cfg)
if model_count > 0:
    print(f"  Model routing: {model_count} agents have model tier assignments")

# =============================================================================
# PROVIDER OPTIONS - Prompt caching and performance
# =============================================================================

if 'provider' not in config:
    config['provider'] = {}

if 'anthropic' not in config['provider']:
    config['provider']['anthropic'] = {}

if 'options' not in config['provider']['anthropic']:
    config['provider']['anthropic']['options'] = {}

config['provider']['anthropic']['options']['setCacheKey'] = True
print("  Enabled prompt caching for Anthropic (setCacheKey: true)")

# =============================================================================
# MCP SERVERS - Apply loading policy and register standard servers
# =============================================================================

if 'mcp' not in config:
    config['mcp'] = {}

if 'tools' not in config:
    config['tools'] = {}

import shutil
bun_path = shutil.which('bun')
npx_path = shutil.which('npx')
if not npx_path and not bun_path:
    print("  Warning: Neither bun nor npx found in PATH", file=sys.stderr)
pkg_runner = f"{bun_path} x" if bun_path else (npx_path or "npx")

# Apply loading policy
uncategorized = apply_mcp_loading_policy(config)
if uncategorized:
    print(f"  Warning: Uncategorized MCPs (add to EAGER_MCPS or LAZY_MCPS): {uncategorized}", file=sys.stderr)

print(f"  Applied MCP loading policy: {len(EAGER_MCPS)} eager, {len(LAZY_MCPS)} lazy")

# Remove deprecated and register standard MCPs
remove_deprecated_mcps(config)
register_standard_mcps(config, bun_path, pkg_runner)

if config_loaded:
    atomic_json_write(config_path, config)
    print(f"  Updated {len(primary_agents)} primary agents in opencode.json")
else:
    print("Error: config was not loaded successfully, skipping write", file=sys.stderr)
    sys.exit(1)
