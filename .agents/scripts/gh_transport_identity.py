# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Trusted GitHub quota-owner attribution."""

import os


def quota_owner() -> tuple[str, bool]:
    """Return a validated configured owner and whether it is authoritative."""
    owner = os.environ.get("AIDEVOPS_GH_QUOTA_OWNER", "")
    if not owner or owner == "unresolved":
        return "unresolved", False
    if "\0" in owner or len(owner) > 256:
        raise ValueError("invalid GitHub quota owner")
    return owner, True
