# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Harbor 0.22.0 OpenCode adapter for a disposable local /app task sandbox.

Use frontier-harness-run.mjs, which owns the bounded OAuth relay. The relay
capability is not an OpenAI API key and no ChatGPT credential enters the task.
"""

import os
from pathlib import Path
from urllib.parse import urlparse

from harbor.agents.installed.opencode import OpenCode


class FrontierOpenCode(OpenCode):
    """Matched profiles using identical setup and the stock runner/scorer."""

    def __init__(self, *args, profile="stock", **kwargs):
        if profile not in ("stock", "aidevops", "aidevops-native-compaction"):
            raise ValueError("Invalid FrontierHarness profile")
        self.profile = profile
        self.archive = Path(os.environ["AIDEVOPS_EVAL_ARCHIVE"])
        if not self.archive.is_file() or self.archive.is_symlink():
            raise ValueError("Expected a regular framework archive")
        relay = os.environ["AIDEVOPS_EVAL_RELAY_URL"]
        parsed = urlparse(relay)
        if parsed.scheme != "http" or parsed.hostname != "host.docker.internal":
            raise ValueError("Only the local Docker-host relay is supported")
        if parsed.path != "/v1" or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("Invalid relay route")
        capability = os.environ["AIDEVOPS_EVAL_RELAY_KEY"]
        if len(capability) != 64 or any(c not in "0123456789abcdef" for c in capability):
            raise ValueError("Invalid relay capability")
        root = "/opt/frontier/framework/.agents"
        config = {
            "$schema": "https://opencode.ai/config.json",
            "autoupdate": False,
            "share": "disabled",
            "enabled_providers": ["openai"],
            "provider": {"openai": {"options": {"baseURL": relay, "apiKey": capability}}},
            "plugin": [[f"file://{root}/scripts/frontier-harness-observer.mjs", {
                "profile": profile, "events": "/logs/agent/frontier-events.jsonl",
            }]],
        }
        if profile != "stock":
            config["instructions"] = [f"{root}/AGENTS.md"]
        super().__init__(*args, opencode_config=config, **kwargs)

    @staticmethod
    def name():
        return "frontier-opencode"

    async def install(self, environment):
        # Local networks may block cleartext package mirrors. Keep TLS
        # verification enabled and make this identical preparation in both arms.
        await self.exec_as_agent(environment, command=(
            "set -eu; if test -f /etc/apt/sources.list.d/ubuntu.sources; then "
            "sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources; "
            "apt-get -o Acquire::Retries=0 -o Acquire::https::Timeout=15 update; fi"
        ))
        await super().install(environment)
        await self.ensure_system_dependencies(environment, ("git", "tar"))
        await environment.upload_file(self.archive, "/opt/frontier-framework.tar")
        # No setup.sh: its machine-wide setup/scheduling belongs outside trials.
        # The clean archive contains only pinned Git-tracked framework files.
        await self.exec_as_agent(environment, command=(
            "set -eu; mkdir -p /opt/frontier/framework; "
            "tar -xf /opt/frontier-framework.tar -C /opt/frontier/framework; "
            "mkdir -p \"$HOME/.aidevops\"; "
            "ln -s /opt/frontier/framework/.agents \"$HOME/.aidevops/agents\"; "
            "[ ! -f \"$HOME/.nvm/nvm.sh\" ] || . \"$HOME/.nvm/nvm.sh\"; "
            "npm ci --ignore-scripts --prefix /opt/frontier/framework/.agents/plugins/opencode-aidevops"
        ))
        # Retain the verifier's exact /app path, but make it a real linked
        # worktree in BOTH arms. Refuse arbitrary task paths and existing Git
        # repositories; support for those requires an explicit adapter contract.
        await self.exec_as_agent(environment, command=(
            "set -eu; test \"$PWD\" = /app; test ! -e /app/.git; "
            "test ! -e /opt/frontier/task-mirror; "
            "mv /app /opt/frontier/task-mirror; "
            "git -C /opt/frontier/task-mirror init -q; "
            "git -C /opt/frontier/task-mirror add --all; "
            "git -C /opt/frontier/task-mirror -c user.name=Benchmark "
            "-c user.email=benchmark@example.invalid commit -q --allow-empty -m seed; "
            "git -C /opt/frontier/task-mirror worktree add -q -b evaluation /app"
        ))

    async def run(self, instruction, environment, context):
        # Hide the user's API-key environment. This value is only a revocable,
        # model-pinned, short-lived local capability, never the OAuth credential.
        key = os.environ["AIDEVOPS_EVAL_RELAY_KEY"]
        os.environ["OPENAI_API_KEY"] = key
        # The isolated task HOME is empty; no host auth/session/config is mounted.
        await self.exec_as_agent(environment, command=(
            "mkdir -p /logs/agent; "
            "test ! -e /logs/agent/frontier-events.jsonl"
        ))
        await super().run(instruction, environment, context)
