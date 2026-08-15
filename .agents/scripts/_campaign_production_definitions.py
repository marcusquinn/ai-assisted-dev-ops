"""Shared definitions for campaign production contracts."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from performance_contract import contains_direct_identifier

CHANNELS = {"facebook", "instagram", "linkedin", "twitter", "reddit", "email", "blog", "youtube", "short-form", "social-linkedin", "social-reddit", "social-x", "podcast"}
ASSET_OWNERS = {"writing": "content/production-writing.md", "image": "content/production-image.md", "video": "content/production-video.md", "audio": "content/production-audio.md", "editor": "tools/video/video-editor.md"}
DEFAULT_FORMATS = {
    "facebook": ("image", "1:1", None), "instagram": ("image", "4:5", None),
    "linkedin": ("image", "1.91:1", None), "twitter": ("writing", "text", None),
    "email": ("writing", "text", None), "blog": ("writing", "text", None),
    "youtube": ("video", "16:9", 60), "short-form": ("video", "9:16", 30),
    "social-linkedin": ("image", "1.91:1", None), "social-reddit": ("writing", "text", None),
    "social-x": ("writing", "text", None), "reddit": ("writing", "text", None), "podcast": ("audio", "audio", 300),
}
CAMPAIGN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,127}$")
BRIEF_ID_RE = re.compile(r"^brief:[a-z0-9][a-z0-9-]{0,159}$")
JOB_ID_RE = re.compile(r"^job:[a-z0-9][a-z0-9:-]{0,240}$")
VARIANT_ID_RE = re.compile(r"^v[1-9][0-9]*$")
SHA256_RE = re.compile(r"^sha256:[a-f0-9]{64}$")


class ManifestError(ValueError):
    """Raised when a production contract cannot be created or trusted."""


@dataclass(frozen=True)
class ManifestRequest:
    """Inputs needed to construct one immutable production job."""

    campaign_id: str
    brief: dict[str, Any]
    channel: str
    variant: int
    asset_class: str | None
    capability: str | None


def validate_campaign_id(value: Any) -> str:
    """Require a bounded campaign alias that cannot traverse filesystem paths."""
    if not isinstance(value, str):
        raise ManifestError("campaign_id must be a bounded lowercase alias")
    if not CAMPAIGN_ID_RE.fullmatch(value):
        raise ManifestError("campaign_id must be a bounded lowercase alias")
    if contains_direct_identifier(value):
        raise ManifestError("campaign_id must be a bounded lowercase alias")
    return value
