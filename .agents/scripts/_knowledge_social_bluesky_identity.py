#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Independent did:plc document resolution and PDS service verification."""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import quote

from _knowledge_social_bluesky import BlueskyAdapterError
from _knowledge_social_bluesky_http import public_json, service_url

PLC_DID = re.compile(r"^did:plc:[a-z2-7]{24}$")
PLC_DIRECTORY = "https://plc.directory"


def _service_entries(document: dict[str, Any]) -> list[dict[str, Any]]:
    services = document.get("service")
    if not isinstance(services, list) or any(
        not isinstance(entry, dict) for entry in services
    ):
        raise BlueskyAdapterError("Bluesky DID document has no valid services")
    return services


def pds_endpoint(document: dict[str, Any], account_did: str) -> str:
    """Return the exact #atproto_pds endpoint from a verified DID document."""
    if document.get("id") != account_did:
        raise BlueskyAdapterError("Bluesky DID document identity is invalid")
    service_ids = {"#atproto_pds", f"{account_did}#atproto_pds"}
    for entry in _service_entries(document):
        if (
            entry.get("id") in service_ids
            and entry.get("type") == "AtprotoPersonalDataServer"
        ):
            endpoint = entry.get("serviceEndpoint")
            if isinstance(endpoint, str):
                return service_url(endpoint)
    raise BlueskyAdapterError("Bluesky DID document has no authoritative PDS")


def resolve_pds(account_did: str) -> str:
    if PLC_DID.fullmatch(account_did) is None:
        raise BlueskyAdapterError("live Bluesky identity requires a did:plc account")
    encoded = quote(account_did, safe=":")
    return pds_endpoint(public_json(f"{PLC_DIRECTORY}/{encoded}"), account_did)
