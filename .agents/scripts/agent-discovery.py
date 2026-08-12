# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
import sys

# Add lib directory to path for shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from discovery_utils import atomic_json_write
from agent_config import (
    discover_primary_agents, validate_subagent_refs,
    apply_disabled_agents, sort_key, display_to_filename,
    managed_external_directories,
)
from mcp_config import (
    apply_mcp_loading_policy, remove_deprecated_mcps,
    register_standard_mcps,
)

output_format = sys.argv[2]

agents_dir = os.path.expanduser("~/.aidevops/agents")

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
# OUTPUT — Runtime-specific
# =============================================================================


def _update_opencode_agents(config, sorted_agents_local, primary_agents_local):
    """Update agent config in opencode.json, guarding against empty discovery."""
    if not primary_agents_local:
        print("  WARNING: No primary agents discovered — skipping agent config update", file=sys.stderr)
        print("  (agents directory may be empty or deploy incomplete)", file=sys.stderr)
        return
    apply_disabled_agents(sorted_agents_local)
    config['agent'] = sorted_agents_local
    config['default_agent'] = "Build+"


def _merge_instructions(config):
    """Merge aidevops AGENTS.md into instructions list, preserving user entries."""
    instructions_path = os.path.expanduser("~/.aidevops/agents/AGENTS.md")
    if not os.path.exists(instructions_path):
        return
    existing = config.get('instructions', [])
    if not isinstance(existing, list):
        existing = [existing] if existing else []
    if instructions_path not in existing:
        existing.append(instructions_path)
    config['instructions'] = existing


def _ensure_plugin_registered(config):
    """Ensure the aidevops plugin is registered in opencode config."""
    aidevops_plugin_url = "file://" + os.path.expanduser(
        "~/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
    )
    plugin_list = config.get('plugin', [])
    if not isinstance(plugin_list, list):
        plugin_list = [plugin_list] if plugin_list else []
    if aidevops_plugin_url not in plugin_list:
        plugin_list.append(aidevops_plugin_url)
        print(f"  Re-registered aidevops plugin (was missing from config)", file=sys.stderr)
    config['plugin'] = plugin_list


def _enable_prompt_caching(config):
    """Enable Anthropic prompt caching in provider config."""
    config.setdefault('provider', {}).setdefault('anthropic', {}).setdefault('options', {})
    config['provider']['anthropic']['options']['setCacheKey'] = True


def _persist_managed_external_directories(config):
    """Persist managed path allows for built-in agents and live config reloads.

    The plugin applies the same rules at startup, including per-agent overrides.
    Persisting the top-level rules also covers OpenCode's built-in delegated
    agents and lets a running process observe updated policy when config reload
    is available. Keep this list aligned with config-hook.mjs.
    """
    permission = config.get('permission')
    if isinstance(permission, str):
        permission = {'*': permission, 'external_directory': {'*': permission}}
        config['permission'] = permission
    elif not isinstance(permission, dict):
        permission = {}
        config['permission'] = permission

    existing = permission.get('external_directory')
    if existing == 'allow':
        return
    rules = {'*': existing} if isinstance(existing, str) else dict(existing or {})
    managed_paths = managed_external_directories()
    worktree_base = managed_paths[6]
    if worktree_base != '~/Git/_worktrees':
        rules.pop('~/Git/_worktrees', None)
        rules.pop('~/Git/_worktrees/**', None)
    for path in managed_paths:
        rules.pop(path, None)
        rules[path] = 'allow'
    permission['external_directory'] = rules


def output_opencode_json():
    """Write agent config to opencode.json."""
    import shutil

    config_path = os.path.expanduser("~/.config/opencode/opencode.json")
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
    except FileNotFoundError:
        config = {"$schema": "https://opencode.ai/config.json"}
    except (OSError, json.JSONDecodeError) as e:
        print(f"Error: Failed to load {config_path}: {e}", file=sys.stderr)
        sys.exit(1)

    # Keep OpenCode updates behind the framework-controlled runtime pin.
    config['autoupdate'] = False
    _update_opencode_agents(config, sorted_agents, primary_agents)
    _merge_instructions(config)
    _ensure_plugin_registered(config)
    _enable_prompt_caching(config)
    _persist_managed_external_directories(config)

    config.setdefault('mcp', {})
    config.setdefault('tools', {})

    bun_path = shutil.which('bun')
    npx_path = shutil.which('npx')
    pkg_runner = f"{bun_path} x" if bun_path else (npx_path or "npx")

    apply_mcp_loading_policy(config)
    remove_deprecated_mcps(config)
    register_standard_mcps(config, bun_path, pkg_runner)

    atomic_json_write(config_path, config)

    print(f"  Updated {len(primary_agents)} primary agents in opencode.json")
    if subagent_filtered_count > 0:
        print(f"  Subagent filtering: {subagent_filtered_count} agents have permission.task rules")
    prompt_count = sum(1 for name, cfg in sorted_agents.items() if "prompt" in cfg)
    if prompt_count > 0:
        print(f"  Custom system prompts: {prompt_count} agents use prompts/build.txt")


def _build_hook_entry():
    """Return the git safety hook entry dict."""
    return {"type": "command", "command": "$HOME/.aidevops/hooks/git_safety_guard.py"}


def _ensure_bash_hook(settings):
    """Ensure command and Edit|Write hook surfaces are registered."""
    hook_command = "$HOME/.aidevops/hooks/git_safety_guard.py"
    hook_entry = _build_hook_entry()
    settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
    changed = False
    for required_matcher in ("Bash", "Edit|Write"):
        for rule in settings["hooks"]["PreToolUse"]:
            if rule.get("matcher") != required_matcher:
                continue
            existing_commands = [h.get("command", "") for h in rule.get("hooks", [])]
            if hook_command not in existing_commands:
                rule.setdefault("hooks", []).append(hook_entry)
                changed = True
            break
        else:
            settings["hooks"]["PreToolUse"].append(
                {"matcher": required_matcher, "hooks": [hook_entry]}
            )
            changed = True
    return changed


def _build_permission_rules():
    """Return (allow_rules, deny_rules, ask_rules) for Claude Code settings."""
    allow_rules = [
        "Read(~/.aidevops/**)", "Bash(~/.aidevops/agents/scripts/*)",
        "Bash(git status)", "Bash(git status *)", "Bash(git log *)",
        "Bash(git diff *)", "Bash(git diff)", "Bash(git branch *)",
        "Bash(git branch)", "Bash(git show *)", "Bash(git rev-parse *)",
        "Bash(git ls-files *)", "Bash(git ls-files)", "Bash(git remote -v)",
        "Bash(git stash list)", "Bash(git tag *)", "Bash(git tag)",
        "Bash(git add *)", "Bash(git add .)", "Bash(git commit *)",
        "Bash(git checkout -b *)", "Bash(git switch -c *)", "Bash(git switch *)",
        "Bash(git push *)", "Bash(git push)", "Bash(git pull *)", "Bash(git pull)",
        "Bash(git fetch *)", "Bash(git fetch)", "Bash(git merge *)",
        "Bash(git rebase *)", "Bash(git stash *)", "Bash(git worktree *)",
        "Bash(git branch -d *)", "Bash(git push --force-with-lease *)",
        "Bash(git push --force-if-includes *)",
        "Bash(gh pr *)", "Bash(gh issue *)", "Bash(gh run *)", "Bash(gh api *)",
        "Bash(gh repo *)", "Bash(gh auth status *)", "Bash(gh auth status)",
        "Bash(npm run *)", "Bash(npm test *)", "Bash(npm test)",
        "Bash(npm install *)", "Bash(npm install)", "Bash(npm ci)",
        "Bash(npx *)", "Bash(bun *)", "Bash(pnpm *)", "Bash(yarn *)",
        "Bash(node *)", "Bash(python3 *)", "Bash(python *)", "Bash(pip *)",
        "Bash(fd *)", "Bash(rg *)", "Bash(find *)", "Bash(grep *)",
        "Bash(wc *)", "Bash(ls *)", "Bash(ls)", "Bash(tree *)",
        "Bash(shellcheck *)", "Bash(eslint *)", "Bash(prettier *)", "Bash(tsc *)",
        "Bash(which *)", "Bash(command -v *)", "Bash(uname *)", "Bash(date *)",
        "Bash(pwd)", "Bash(whoami)", "Bash(cat *)", "Bash(head *)", "Bash(tail *)",
        "Bash(sort *)", "Bash(uniq *)", "Bash(cut *)", "Bash(awk *)", "Bash(sed *)",
        "Bash(jq *)", "Bash(basename *)", "Bash(dirname *)", "Bash(realpath *)",
        "Bash(readlink *)", "Bash(stat *)", "Bash(file *)", "Bash(diff *)",
        "Bash(mkdir *)", "Bash(touch *)", "Bash(cp *)", "Bash(mv *)",
        "Bash(chmod *)", "Bash(echo *)", "Bash(printf *)", "Bash(test *)",
        "Bash([ *)", "Bash(claude *)",
    ]
    deny_rules = [
        "Read(./.env)", "Read(./.env.*)", "Read(./secrets/**)",
        "Read(./**/credentials.json)", "Read(./**/.env)", "Read(./**/.env.*)",
        "Read(~/.config/aidevops/credentials.sh)",
        # Runtime capability/secret layer; command classification is delegated
        # to command-policy-helper.py through the PreToolUse hook.
        "Bash(sudo *)", "Bash(chmod 777 *)",
        "Bash(gopass show *)", "Bash(pass show *)", "Bash(op read *)",
        "Bash(cat ~/.config/aidevops/credentials.sh)",
    ]
    ask_rules = [
        "Bash(rm -r *)",
        "Bash(docker *)", "Bash(docker-compose *)", "Bash(orbctl *)",
    ]
    return allow_rules, deny_rules, ask_rules


def _merge_rules(existing, new_rules):
    """Append new_rules not already in existing. Returns True if any added."""
    added = False
    for rule in new_rules:
        if rule not in existing:
            existing.append(rule)
            added = True
    return added


def _clean_expanded_path_rules(permissions):
    """Remove expanded-path allow rules from prior versions. Returns changed flag."""
    home = os.path.expanduser("~")
    existing_allow = permissions.get("allow", [])
    cleaned = [r for r in existing_allow if not (r.startswith(home + "/") and "(" not in r)]
    if len(cleaned) != len(existing_allow):
        permissions["allow"] = cleaned
        return True
    return False


def _clean_legacy_command_safety_rules(permissions):
    """Remove framework-owned permission decisions migrated to shared policy."""
    legacy = {
        "Bash(git push --force *)", "Bash(git push -f *)",
        "Bash(git reset --hard *)", "Bash(git reset --hard)",
        "Bash(git clean -f *)", "Bash(git clean -f)",
        "Bash(git checkout -- *)", "Bash(git branch -D *)",
        "Bash(rm -rf /)", "Bash(rm -rf /*)", "Bash(rm -rf ~)",
        "Bash(rm -rf ~/*)", "Bash(rm -rf *)",
        "Bash(curl *)", "Bash(wget *)",
    }
    changed = False
    for bucket in ("deny", "ask"):
        existing = permissions.get(bucket, [])
        cleaned = [rule for rule in existing if rule not in legacy]
        if cleaned != existing:
            permissions[bucket] = cleaned
            changed = True
    return changed


def output_claude_settings():
    """Update ~/.claude/settings.json with hooks and permissions."""
    settings_path = os.path.expanduser("~/.claude/settings.json")
    try:
        with open(settings_path, 'r') as f:
            settings = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        settings = {}

    changed = _ensure_bash_hook(settings)

    permissions = settings.setdefault("permissions", {})
    if _clean_expanded_path_rules(permissions):
        changed = True
    if _clean_legacy_command_safety_rules(permissions):
        changed = True

    allow_rules, deny_rules, ask_rules = _build_permission_rules()
    allow_list = permissions.setdefault("allow", [])
    deny_list = permissions.setdefault("deny", [])
    ask_list = permissions.setdefault("ask", [])

    if _merge_rules(allow_list, allow_rules):
        changed = True
    if _merge_rules(deny_list, deny_rules):
        changed = True
    if _merge_rules(ask_list, ask_rules):
        changed = True

    settings["permissions"] = permissions

    if "$schema" not in settings:
        settings["$schema"] = "https://json.schemastore.org/claude-code-settings.json"
        changed = True

    if changed:
        os.makedirs(os.path.dirname(settings_path), exist_ok=True)
        atomic_json_write(settings_path, settings, trailing_newline=True)
        print(f"  Updated {settings_path}")
    else:
        print(f"  {settings_path} (no changes needed)")

    print(f"  Discovered {len(primary_agents)} primary agents")


if output_format == "opencode-json":
    output_opencode_json()
elif output_format == "claude-settings":
    output_claude_settings()
else:
    print(f"Unknown output format: {output_format}", file=sys.stderr)
    sys.exit(1)
