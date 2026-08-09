"""Deterministic reviewed avatar rendering for aidevops Buzz members."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import base64
import colorsys
from pathlib import Path


AVATAR_TEMPLATE = Path(__file__).resolve().parent.parent / "configs" / "buzz-agent-avatar-v1.svg"
MAX_AVATAR_DATA_URL_BYTES = 64 * 1024
CANONICAL_AVATAR_ACCENT = "#66d9f2"
BASE_AVATAR_COLORS = {
    "{{ACCENT}}": CANONICAL_AVATAR_ACCENT,
    "{{ACCENT_DARK}}": "#0d6f84",
    "{{ACCENT_LIGHT}}": "#8ce8ff",
    "{{ACCENT_MID}}": "#42c8e8",
    "{{BACKGROUND_TINT}}": "#071013",
}
AVATAR_HUE_BY_AGENT_ID = {
    "agent.aidevops-guide": None,
    "agent.automate": 318,
    "agent.build-plus": 87,
    "agent.business": 216,
    "agent.content": 344,
    "agent.health": 113,
    "agent.legal": 242,
    "agent.marketing-sales": 10,
    "agent.pr": 139,
    "agent.private-local-ai": 190,
    "agent.product": 268,
    "agent.reports": 36,
    "agent.research": 165,
    "agent.seo": 293,
    "agent.vault": 62,
}


class AvatarError(ValueError):
    """Raised when a reviewed Buzz avatar cannot be rendered safely."""


def rgb_from_hex(value):
    """Parse one fixed six-digit avatar colour."""
    if len(value) != 7 or not value.startswith("#"):
        raise AvatarError("avatar palette contains an invalid colour")
    try:
        return tuple(int(value[index : index + 2], 16) / 255 for index in (1, 3, 5))
    except ValueError as error:
        raise AvatarError("avatar palette contains an invalid colour") from error


def rotate_avatar_colour(value, target_hue):
    """Rotate a canonical avatar colour while preserving saturation and lightness."""
    if target_hue is None:
        return value
    red, green, blue = rgb_from_hex(value)
    hue, lightness, saturation = colorsys.rgb_to_hls(red, green, blue)
    canonical_hue = colorsys.rgb_to_hls(*rgb_from_hex(CANONICAL_AVATAR_ACCENT))[0]
    rotated_hue = (hue + (target_hue / 360) - canonical_hue) % 1
    rotated = colorsys.hls_to_rgb(rotated_hue, lightness, saturation)
    return "#" + "".join(f"{round(component * 255):02x}" for component in rotated)


def member_avatar_data_url(record):
    """Build one bounded SVG avatar keyed only by the stable agent ID."""
    agent_id = record["agent_id"]
    if agent_id not in AVATAR_HUE_BY_AGENT_ID:
        raise AvatarError(f"agent is missing a reviewed avatar hue: {agent_id}")
    try:
        svg = AVATAR_TEMPLATE.read_text(encoding="utf-8")
    except OSError as error:
        raise AvatarError("Buzz agent avatar template is unavailable") from error
    target_hue = AVATAR_HUE_BY_AGENT_ID[agent_id]
    for placeholder, colour in BASE_AVATAR_COLORS.items():
        svg = svg.replace(placeholder, rotate_avatar_colour(colour, target_hue))
    if "{{" in svg or "}}" in svg:
        raise AvatarError("Buzz agent avatar template contains an unresolved placeholder")
    encoded = base64.b64encode(svg.encode("utf-8")).decode("ascii")
    data_url = f"data:image/svg+xml;base64,{encoded}"
    if len(data_url.encode("ascii")) > MAX_AVATAR_DATA_URL_BYTES:
        raise AvatarError("generated Buzz agent avatar exceeds the inline size limit")
    return data_url
