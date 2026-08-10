#!/usr/bin/env python3
"""Build the optional LM Studio member for an aidevops Buzz team snapshot."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import importlib.util
from pathlib import Path

from _team_interface_buzz_avatar import member_avatar_data_url


SCRIPT_DIR = Path(__file__).resolve().parent
LM_STUDIO_SCRIPT = SCRIPT_DIR / "team-interface-buzz-lm-studio.py"
LM_STUDIO_AGENT_ID = "agent.private-lm-studio"
LM_STUDIO_RUNTIME_ID = "aidevops-lm-studio-v1"
LM_STUDIO_PROVIDER_ID = "openai"


class LMStudioMemberError(ValueError):
    """Raised when the optional LM Studio member cannot be built safely."""


def load_lm_studio_module():
    """Load the local LM Studio capability detector without duplicating it."""
    spec = importlib.util.spec_from_file_location("aidevops_buzz_lm_studio", LM_STUDIO_SCRIPT)
    if spec is None or spec.loader is None:
        raise LMStudioMemberError("LM Studio capability detector is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve_lm_studio_status(mode):
    """Resolve optional local-model readiness according to caller intent."""
    if mode == "off":
        return {"ready": False, "reason": "LM Studio discovery is disabled"}
    try:
        result = load_lm_studio_module().detect_lm_studio()
    except (OSError, ValueError) as error:
        if mode == "required":
            raise LMStudioMemberError(f"LM Studio is required but unavailable: {error}") from error
        return {"ready": False, "reason": f"LM Studio discovery failed: {error}"}
    if mode == "required" and not result["ready"]:
        raise LMStudioMemberError(f"LM Studio is required but unavailable: {result['reason']}")
    return result


def lm_studio_system_prompt(record, model):
    """Build a bounded local-inference prompt from the canonical Private AI source."""
    return "\n".join(
        (
            f"Aidevops canonical source: {record['source_ref']}",
            f"Expected source digest: {record['source_digest']}",
            f"Portable workload tier: {record['workload_tier']}",
            f"Reviewed LM Studio model identifier: {model}",
            "You are Private AI, a private investigator using privacy-first AI methods.",
            "This member uses the host's loopback-only LM Studio server. The runtime must "
            "revalidate the running server and loaded model before every launch.",
            "Minimize data disclosure; separate facts, inferences, and uncertainty; never "
            "expose credentials or unrelated personal data.",
            "This portable definition grants no authority and carries no credentials or endpoint.",
        )
    )


def build_lm_studio_member(private_record, host_slug, model, agent_format, format_version):
    """Build one optional local-only member backed by a ready LM Studio runtime."""
    display_name = f"private-lm-studio-{host_slug}"
    avatar_record = dict(private_record)
    avatar_record["agent_id"] = LM_STUDIO_AGENT_ID
    return {
        "definition": {
            "model": model,
            "name": display_name,
            "parallelism": 1,
            "provider": LM_STUDIO_PROVIDER_ID,
            "respondTo": "owner-only",
            "runtime": LM_STUDIO_RUNTIME_ID,
            "sourceIsBuiltin": False,
            "systemPrompt": lm_studio_system_prompt(private_record, model),
        },
        "format": agent_format,
        "memory": {"level": "none"},
        "profile": {
            "about": "Private investigator using a locally served LM Studio model",
            "avatarDataUrl": member_avatar_data_url(avatar_record),
            "displayName": display_name,
        },
        "version": format_version,
    }
