#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one bounded Facebook, Instagram, or Threads account stream."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from _knowledge_social_meta import PRODUCTS, MetaProductModule, product_spec
from _knowledge_social_meta_normalize import PageContext, normalize_page
from _knowledge_social_meta_reader import FixtureMeta, GuardedMetaOAuth, verified_identity
from _knowledge_social_oauth_collector import OAuthCollectorPolicy, run_oauth_collector


def _select_product(argv: list[str]) -> tuple[str, list[str]]:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--product", required=True, choices=tuple(PRODUCTS))
    args, remaining = parser.parse_known_args(argv)
    return args.product, remaining


def _collector_policy(product: str) -> OAuthCollectorPolicy:
    spec = product_spec(product)
    module = MetaProductModule(product)
    return OAuthCollectorPolicy(
        display_name=f"Meta {product.title()}",
        provider_module=module,
        helper=Path(__file__).with_name("_knowledge_social_meta_provider.py"),
        fixture_reader=lambda path: FixtureMeta(path, product),
        live_reader=lambda helper, profile: GuardedMetaOAuth(helper, profile, product),
        page_context=lambda connection, account, stream, enabled, policy: PageContext(
            product, connection, account, stream, enabled, policy
        ),
        normalize_page=normalize_page,
        verified_identity=lambda payload, expected: verified_identity(
            payload, expected, product
        ),
        budget_unit="request",
        default_budget=11,
        min_budget=3,
        max_page_size=50,
    )


def main() -> int:
    product, remaining = _select_product(sys.argv[1:])
    original = sys.argv
    sys.argv = [original[0], *remaining]
    try:
        description = (
            f"Collect one GET-only {product} stream. Account gate: "
            f"{product_spec(product).account_gate}."
        )
        return run_oauth_collector(_collector_policy(product), description)
    finally:
        sys.argv = original


if __name__ == "__main__":
    raise SystemExit(main())
