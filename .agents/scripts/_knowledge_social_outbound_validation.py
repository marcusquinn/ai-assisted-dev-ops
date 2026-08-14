#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provider-specific validation for immutable outbound social intents."""

from __future__ import annotations

import re
from dataclasses import dataclass

from knowledge_social_store import SocialStoreError, validate_opaque

MAX_SUBJECT_BYTES = 4 * 1024
MAX_REDDIT_SUBJECT_CHARS = 300
MAX_SELECTOR_BYTES = 256
REDDIT_TARGET_ID = re.compile(r"^t[13]_[A-Za-z0-9]+$")
REDDIT_DESTINATION_ID = re.compile(r"^[A-Za-z0-9_]{3,21}$")


@dataclass(frozen=True)
class SubjectPolicy:
    """Provider-specific title requirements and public validation messages."""

    required_message: str
    line_message: str
    maximum_chars: int
    length_message: str


SUBJECT_POLICIES = {
    "reddit": SubjectPolicy(
        "Reddit posts require a non-empty private subject file",
        "outbound subject must be one non-empty line",
        MAX_REDDIT_SUBJECT_CHARS,
        "Reddit post subject exceeds the 300-character title limit",
    ),
    "youtube": SubjectPolicy(
        "YouTube uploads require a non-empty private title file",
        "YouTube upload title must be one non-empty line",
        100,
        "YouTube upload title exceeds the 100-character limit",
    ),
}


def optional_selector(value: str | None, field: str) -> str | None:
    """Validate one bounded selector without accepting option-shaped input."""
    if value is None:
        return None
    if not value:
        raise SocialStoreError(f"{field} must be one non-empty line")
    if value.startswith("-"):
        raise SocialStoreError(f"{field} must not be option-shaped")
    if any(marker in value for marker in ("\x00", "\n", "\r")):
        raise SocialStoreError(f"{field} must be one non-empty line")
    if len(value.encode("utf-8")) > MAX_SELECTOR_BYTES:
        raise SocialStoreError(f"{field} is too long")
    return value


def _validated_required_subject(
    subject: str | None,
    policy: SubjectPolicy,
) -> str:
    if subject is None or not subject.strip():
        raise SocialStoreError(policy.required_message)
    if any(marker in subject for marker in ("\x00", "\n", "\r")):
        raise SocialStoreError(policy.line_message)
    if len(subject) > policy.maximum_chars:
        raise SocialStoreError(policy.length_message)
    return subject


def _validated_reddit_subject(subject: str | None) -> str:
    subject = _validated_required_subject(subject, SUBJECT_POLICIES["reddit"])
    if len(subject.encode("utf-8")) > MAX_SUBJECT_BYTES:
        raise SocialStoreError("outbound subject exceeds the private subject limit")
    return subject


def _validated_youtube_subject(subject: str | None) -> str:
    return _validated_required_subject(subject, SUBJECT_POLICIES["youtube"])


def validated_subject(provider: str, action: str, subject: str | None) -> str | None:
    """Validate the explicit title field required by selected post providers."""
    subject_validators = {
        ("reddit", "post"): _validated_reddit_subject,
        ("youtube", "post"): _validated_youtube_subject,
    }
    validator = subject_validators.get((provider, action))
    if validator is not None:
        return validator(subject)
    if subject is not None:
        raise SocialStoreError("this outbound operation does not accept a subject")
    return None


def validated_media(
    provider: str, action: str, media_path: str | None, media_sha256: str | None
) -> tuple[str | None, str | None]:
    """Require exactly one hash-bound private file for YouTube uploads."""
    if provider == "youtube" and action == "post":
        if media_path is None or media_sha256 is None:
            raise SocialStoreError("YouTube uploads require a verified private media file")
        media_path = optional_selector(media_path, "media_path")
        if media_path is None or not media_path.startswith("/"):
            raise SocialStoreError("YouTube media path must be an absolute private path")
        if re.fullmatch(r"[0-9a-f]{64}", media_sha256) is None:
            raise SocialStoreError("YouTube media integrity digest is invalid")
        return media_path, media_sha256
    if media_path is not None or media_sha256 is not None:
        raise SocialStoreError("this outbound operation does not accept media")
    return None, None


def validated_destination(
    provider: str, action: str, destination: str | None
) -> str | None:
    """Validate the provider-specific remote destination selector."""
    if provider == "reddit" and action == "post":
        if destination is None:
            raise SocialStoreError("Reddit posts require a destination subreddit ID")
        destination = validate_opaque(destination, "destination_remote_id")
        if REDDIT_DESTINATION_ID.fullmatch(destination) is None:
            raise SocialStoreError("Reddit destination subreddit ID is invalid")
        return destination
    if provider in ("meta_instagram", "tiktok") and action == "post":
        if destination is None:
            raise SocialStoreError("visual outbound posts require an approved opaque media reference")
        return validate_opaque(destination, "destination_remote_id")
    if destination is not None:
        raise SocialStoreError("this outbound operation does not accept a destination")
    return None


def validated_target(provider: str, action: str, target: str | None) -> str | None:
    """Validate the target selector required by engagement actions."""
    if action == "post":
        if target is not None:
            raise SocialStoreError("post does not accept a target")
        return None
    if target is None:
        raise SocialStoreError(f"{action} requires a target post ID")
    target = validate_opaque(target, "target_remote_id")
    if provider == "reddit" and REDDIT_TARGET_ID.fullmatch(target) is None:
        raise SocialStoreError("Reddit targets require a t1_ or t3_ fullname")
    return target
