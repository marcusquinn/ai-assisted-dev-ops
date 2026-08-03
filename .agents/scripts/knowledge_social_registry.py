#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve and execute deterministic read-only social provider adapters."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


class ProviderRegistryError(ValueError):
    """Raised when provider registration or routing is ambiguous."""


@dataclass(frozen=True)
class ProviderSpec:
    """One immutable provider identity and its supported ingestion modes."""

    provider: str
    aliases: tuple[str, ...]
    entrypoint: str | None
    modes: tuple[tuple[str, tuple[str, ...]], ...]


PROVIDER_SPECS = (
    ProviderSpec(
        "bluesky",
        ("at-protocol", "atproto"),
        "knowledge_social_bluesky.py",
        (("live", ()),),
    ),
    ProviderSpec("beehiiv", (), "knowledge_social_beehiiv.py", (("live", ()),)),
    ProviderSpec("binance-square", (), None, (("no-route", ()),)),
    ProviderSpec("discord", (), "knowledge_social_discord.py", (("live", ()),)),
    ProviderSpec(
        "forem",
        ("dev-community", "dev.to"),
        "knowledge_social_forem.py",
        (("live", ()),),
    ),
    ProviderSpec("freshrss", (), "knowledge_social_freshrss.py", (("live", ()),)),
    ProviderSpec(
        "google-business-profile",
        ("gbp",),
        "knowledge_social_google_business_profile.py",
        (("live", ()),),
    ),
    ProviderSpec("gumroad", (), "knowledge_social_gumroad.py", (("live", ()),)),
    ProviderSpec("github", (), "knowledge_social_github.py", (("live", ()),)),
    ProviderSpec("ghost", (), "knowledge_social_ghost.py", (("live", ()),)),
    ProviderSpec(
        "hacker-news",
        ("hn",),
        "knowledge_social_hacker_news.py",
        (("live", ()),),
    ),
    ProviderSpec("hashnode", (), "knowledge_social_hashnode.py", (("live", ()),)),
    ProviderSpec("lemmy", (), "knowledge_social_lemmy.py", (("live", ()),)),
    ProviderSpec("mastodon", (), "knowledge_social_mastodon.py", (("live", ()),)),
    ProviderSpec("miniflux", (), "knowledge_social_miniflux.py", (("live", ()),)),
    ProviderSpec(
        "notion-sites",
        ("notion",),
        "knowledge_social_notion.py",
        (("live", ()),),
    ),
    ProviderSpec(
        "readwise-reader",
        ("reader",),
        "knowledge_social_readwise_reader.py",
        (("live", ()),),
    ),
    ProviderSpec(
        "stack-exchange",
        ("stackexchange",),
        "knowledge_social_stack_exchange.py",
        (("live", ()),),
    ),
    ProviderSpec(
        "nextcloud-talk",
        (),
        "knowledge_social_nextcloud_talk.py",
        (("live", ()),),
    ),
    ProviderSpec("patreon", (), "knowledge_social_patreon.py", (("live", ()),)),
    ProviderSpec(
        "signal",
        (),
        "knowledge_social_signal.py",
        (
            ("status", ("status",)),
            ("inspect", ("inspect",)),
            ("manual-import", ("import-events",)),
        ),
    ),
    ProviderSpec(
        "slack",
        (),
        "knowledge_social_slack.py",
        (("live", ("api",)), ("archive", ("archive",))),
    ),
    ProviderSpec(
        "telegram",
        (),
        "knowledge_social_telegram.py",
        (
            ("archive", ("import-export",)),
            ("event", ("import-updates",)),
            ("status", ("status",)),
        ),
    ),
    ProviderSpec(
        "whatsapp",
        ("whats-app",),
        "knowledge_social_whatsapp.py",
        (("archive", ("export",)), ("event", ("webhook",))),
    ),
)


def normalize_name(value: str) -> str:
    """Return one conservative provider/alias lookup key."""
    normalized = re.sub(r"[\s_]+", "-", value.strip().lower())
    if not normalized or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,63}", normalized):
        raise ProviderRegistryError("provider identity is invalid")
    return normalized


def register_specs(
    specs: Iterable[ProviderSpec],
) -> tuple[dict[str, ProviderSpec], dict[str, str]]:
    """Build an order-independent registry and reject every collision."""
    providers: dict[str, ProviderSpec] = {}
    aliases: dict[str, str] = {}
    for spec in sorted(specs, key=lambda item: normalize_name(item.provider)):
        provider = normalize_name(spec.provider)
        if provider in providers or provider in aliases:
            raise ProviderRegistryError(f"duplicate provider identity: {provider}")
        modes = [normalize_name(mode) for mode, _prefix in spec.modes]
        if not modes or len(modes) != len(set(modes)):
            raise ProviderRegistryError(f"duplicate or absent modes for provider: {provider}")
        providers[provider] = spec
        for raw_alias in spec.aliases:
            alias = normalize_name(raw_alias)
            if alias in providers or alias in aliases:
                raise ProviderRegistryError(f"duplicate provider alias: {alias}")
            aliases[alias] = provider
    return providers, aliases


PROVIDERS, ALIASES = register_specs(PROVIDER_SPECS)


def resolve_provider(value: str) -> ProviderSpec:
    """Resolve one canonical ID or explicit alias without fallback."""
    key = normalize_name(value)
    provider = ALIASES.get(key, key)
    try:
        return PROVIDERS[provider]
    except KeyError as error:
        raise ProviderRegistryError(f"unknown social provider: {key}") from error


def resolve_mode(spec: ProviderSpec, value: str) -> tuple[str, ...]:
    """Resolve one exact supported mode without provider-name branching."""
    mode = normalize_name(value)
    modes = {normalize_name(name): prefix for name, prefix in spec.modes}
    try:
        return modes[mode]
    except KeyError as error:
        raise ProviderRegistryError(
            f"unsupported mode for {spec.provider}: {mode}"
        ) from error


def describe(spec: ProviderSpec) -> dict[str, object]:
    """Return privacy-safe immutable registration metadata."""
    return {
        "aliases": sorted(spec.aliases),
        "available": spec.entrypoint is not None,
        "modes": sorted(mode for mode, _prefix in spec.modes),
        "provider": spec.provider,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    resolve = commands.add_parser("resolve")
    resolve.add_argument("--provider", required=True)
    run = commands.add_parser("run")
    run.add_argument("--provider", required=True)
    run.add_argument("--mode", required=True)
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "list":
            result: object = [describe(PROVIDERS[key]) for key in sorted(PROVIDERS)]
        else:
            spec = resolve_provider(args.provider)
            if args.command == "resolve":
                result = describe(spec)
            else:
                prefix = resolve_mode(spec, args.mode)
                if spec.entrypoint is None:
                    raise ProviderRegistryError(
                        f"provider has no safe ingestion route: {spec.provider}"
                    )
                entrypoint = Path(__file__).with_name(spec.entrypoint)
                if not entrypoint.is_file() or entrypoint.is_symlink():
                    raise ProviderRegistryError(
                        f"registered provider entrypoint is unavailable: {spec.provider}"
                    )
                forwarded = (
                    args.arguments[1:]
                    if args.arguments[:1] == ["--"]
                    else args.arguments
                )
                os.execv(
                    sys.executable,
                    [sys.executable, str(entrypoint), *prefix, *forwarded],
                )
                raise AssertionError("provider execution unexpectedly returned")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ProviderRegistryError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
