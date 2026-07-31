#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Small RFC header-name validator shared by strict email rule parsing."""

from __future__ import annotations

import re
from typing import Any, Mapping


_HEADER_NAME_PATTERN = re.compile(r"[A-Za-z0-9!#$%&'*+.^_`|~-]+")


def header_option_is_valid(
    condition: Mapping[str, Any], field_name: object
) -> bool:
    """Return whether a header condition has a safe RFC field name."""
    if field_name != "header":
        return True
    header_name = condition.get("header")
    return isinstance(header_name, str) and bool(
        _HEADER_NAME_PATTERN.fullmatch(header_name)
    )
