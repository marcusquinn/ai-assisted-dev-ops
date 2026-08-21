#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Plan or read Google Ads historical keyword metrics into local evidence."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any, Mapping

from domain_opportunity_google_ads import (
    DEFAULT_API_MAJOR,
    GoogleAdsClient,
    GoogleAdsCredentials,
    GoogleAdsError,
    GoogleAdsRequest,
    plan,
    sync,
)
from domain_opportunity_store import DomainOpportunityStore, DomainOpportunityStoreError


def _load_fixture(path: str) -> dict[str, Any]:
    """Load a synthetic response fixture and reject symlinked input."""
    fixture_path = Path(path).expanduser()
    if fixture_path.is_symlink() or not fixture_path.is_file():
        raise GoogleAdsError("fixture must be a regular JSON file")
    try:
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GoogleAdsError("fixture is not valid JSON") from exc
    if not isinstance(fixture, dict) or not isinstance(fixture.get("response"), Mapping):
        raise GoogleAdsError("fixture must contain a response object")
    return fixture


def _fixture_request(fixture: Mapping[str, Any], currency: str) -> GoogleAdsRequest:
    """Read fixture request context without accepting credentials from a file."""
    metadata = fixture.get("request_metadata")
    if not isinstance(metadata, Mapping):
        raise GoogleAdsError("fixture must contain request_metadata")
    geographies = metadata.get("geographies")
    return GoogleAdsRequest(
        api_major=str(metadata.get("api_major", DEFAULT_API_MAJOR)), language=str(metadata.get("language", "")),
        geographies=tuple(item for item in geographies if isinstance(item, str)) if isinstance(geographies, list) else (),
        network=str(metadata.get("network", "")), currency=currency.upper(),
    )


def _request_from_args(args: argparse.Namespace) -> GoogleAdsRequest:
    if args.fixture:
        return _fixture_request(_load_fixture(args.fixture), args.currency)
    return GoogleAdsRequest(
        api_major=args.api_major,
        language=args.language,
        geographies=tuple(args.geography),
        network=args.network,
        currency=args.currency.upper(),
    )


def cmd_plan(args: argparse.Namespace) -> int:
    """Print the local, read-only request plan."""
    request = _request_from_args(args)
    with DomainOpportunityStore(args.db, initialize=True) as store:
        print(json.dumps(plan(store, request), sort_keys=True))
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    """Synchronize either a synthetic fixture or a configured live read request."""
    request = _request_from_args(args)
    fixture = _load_fixture(args.fixture) if args.fixture else None
    if fixture is not None:
        fetch = lambda _phrases: fixture["response"]
    else:
        client = GoogleAdsClient(
            request,
            GoogleAdsCredentials(
                access_token=os.environ.get("GOOGLE_ADS_ACCESS_TOKEN", ""),
                developer_token=os.environ.get("GOOGLE_ADS_DEVELOPER_TOKEN", ""),
                customer_id=args.customer_id,
                login_customer_id=args.login_customer_id,
            ),
        )
        fetch = client.historical_metrics
    with DomainOpportunityStore(args.db, initialize=True) as store:
        print(json.dumps(sync(store, request, fetch), sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the read-only CLI without accepting credentials as arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--db")
    common.add_argument("--fixture")
    common.add_argument("--currency", required=True)
    common.add_argument("--api-major", default=DEFAULT_API_MAJOR)
    common.add_argument("--language", default="")
    common.add_argument("--geography", action="append", default=[])
    common.add_argument("--network", default="GOOGLE_SEARCH_AND_PARTNERS")
    common.add_argument("--customer-id", default="")
    common.add_argument("--login-customer-id")
    subparsers = parser.add_subparsers(dest="command", required=True)
    plan_parser = subparsers.add_parser("plan", parents=[common])
    plan_parser.set_defaults(handler=cmd_plan)
    sync_parser = subparsers.add_parser("sync", parents=[common])
    sync_parser.set_defaults(handler=cmd_sync)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run one deterministic local request plan or sync."""
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except (GoogleAdsError, DomainOpportunityStoreError):
        print("domain-opportunity-google-ads: request could not be completed", file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error):
        print("domain-opportunity-google-ads: local storage operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
