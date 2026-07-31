#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Minimize Gumroad product, sale, and payout API records."""

from __future__ import annotations

import hashlib
import hmac
from typing import Any

from _knowledge_social_gumroad import GumroadAdapterError, provider_id, seller_id

MAX_TEXT_BYTES = 128 * 1024


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GumroadAdapterError(f"Gumroad {field} must be an object")
    return value


def object_list(value: Any, field: str, limit: int) -> list[dict[str, Any]]:
    if (
        not isinstance(value, list)
        or any(not isinstance(item, dict) for item in value)
        or len(value) > limit
    ):
        raise GumroadAdapterError(f"Gumroad {field} exceeds the item safety limit")
    return value


def text_value(value: Any, field: str, *, optional: bool = True) -> str | None:
    if value is None and optional:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode()) > MAX_TEXT_BYTES
    ):
        raise GumroadAdapterError(f"Gumroad {field} is invalid")
    return value


def _number(value: Any, field: str) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GumroadAdapterError(f"Gumroad {field} is invalid")
    return value


def _boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise GumroadAdapterError(f"Gumroad {field} is invalid")
    return value


def _private_ref(pii_key: bytes, kind: str, value: Any) -> str | None:
    text = text_value(value, kind)
    if text is None:
        return None
    digest = hmac.new(
        pii_key,
        f"{kind}\0{text.casefold()}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return f"{kind}_{digest[:32]}"


def _recurrence_prices(value: Any) -> dict[str, dict[str, int | float | None]] | None:
    if value is None:
        return None
    root = object_value(value, "variant recurrence prices")
    if len(root) > 10:
        raise GumroadAdapterError("Gumroad variant recurrence prices exceed the safety limit")
    result = {}
    for recurrence, price in root.items():
        name = text_value(recurrence, "variant recurrence", optional=False)
        details = object_value(price, "variant recurrence price")
        result[name] = {
            "price_cents": _number(details.get("price_cents"), "recurrence price"),
            "suggested_price_cents": _number(
                details.get("suggested_price_cents"), "suggested recurrence price"
            ),
        }
    return result


def _variants(value: Any) -> list[dict[str, Any]]:
    result = []
    for group in object_list(value or [], "product variants", 100):
        options = []
        for option in object_list(
            group.get("options", []), "product variant options", 100
        ):
            options.append(
                {
                    "name": text_value(
                        option.get("name"), "variant option name", optional=False
                    ),
                    "price_difference": _number(
                        option.get("price_difference"), "variant price difference"
                    ),
                    "is_pay_what_you_want": _boolean(
                        option.get("is_pay_what_you_want"), "variant price mode"
                    ),
                    "recurrence_prices": _recurrence_prices(
                        option.get("recurrence_prices")
                    ),
                }
            )
        result.append(
            {
                "title": text_value(
                    group.get("title"), "variant title", optional=False
                ),
                "options": options,
            }
        )
    return result


def product_record(item: dict[str, Any]) -> dict[str, Any]:
    """Keep bounded product metadata and exclude signed file details."""
    tags = item.get("tags", [])
    if (
        not isinstance(tags, list)
        or any(not isinstance(tag, str) or "\x00" in tag for tag in tags)
        or len(tags) > 100
    ):
        raise GumroadAdapterError("Gumroad product tags are invalid")
    return {
        "kind": "product",
        "remote_id": provider_id(item.get("id"), "product ID"),
        "name": text_value(item.get("name"), "product name", optional=False),
        "description": text_value(item.get("description"), "product description"),
        "price_cents": _number(item.get("price"), "product price"),
        "currency": text_value(item.get("currency"), "product currency"),
        "published": _boolean(item.get("published"), "product published state"),
        "deleted": _boolean(item.get("deleted"), "product deleted state"),
        "requires_shipping": _boolean(
            item.get("require_shipping"), "product shipping state"
        ),
        "subscription_duration": text_value(
            item.get("subscription_duration"), "subscription duration"
        ),
        "tags": tags,
        "variants": _variants(item.get("variants")),
        "file_metadata_present": bool(item.get("file_info")),
    }


def sale_record(pii_key: bytes, item: dict[str, Any]) -> dict[str, Any]:
    """Replace customer identifiers and discard payment, address, and license values."""
    affiliate = item.get("affiliate")
    affiliate_data = affiliate if isinstance(affiliate, dict) else {}
    variants = item.get("variants", {})
    if not isinstance(variants, dict) or len(variants) > 100:
        raise GumroadAdapterError("Gumroad sale variants are invalid")
    return {
        "kind": "sale",
        "remote_id": provider_id(item.get("id"), "sale ID"),
        "seller_id": seller_id(item.get("seller_id"), "sale seller ID"),
        "product_id": provider_id(item.get("product_id"), "sale product ID"),
        "product_name": text_value(item.get("product_name"), "sale product name"),
        "customer_ref": _private_ref(
            pii_key, "customer", item.get("purchase_email") or item.get("email")
        ),
        "affiliate_ref": _private_ref(
            pii_key, "affiliate", affiliate_data.get("email")
        ),
        "affiliate_amount": text_value(
            affiliate_data.get("amount"), "affiliate amount"
        ),
        "created_at": text_value(item.get("created_at"), "sale creation time"),
        "order_id": (
            str(item.get("order_id"))
            if isinstance(item.get("order_id"), int)
            and not isinstance(item.get("order_id"), bool)
            else None
        ),
        "price_cents": _number(item.get("price"), "sale price"),
        "fee_cents": _number(item.get("gumroad_fee"), "sale fee"),
        "tax_cents": _number(item.get("tax_cents"), "sale tax"),
        "shipping_cents": _number(item.get("shipping_cents"), "sale shipping"),
        "quantity": _number(item.get("quantity"), "sale quantity"),
        "variants": variants,
        "refunded": _boolean(item.get("refunded"), "sale refund state"),
        "partially_refunded": _boolean(
            item.get("partially_refunded"), "sale partial refund state"
        ),
        "chargedback": _boolean(item.get("chargedback"), "sale chargeback state"),
        "disputed": _boolean(item.get("disputed"), "sale dispute state"),
        "dispute_won": _boolean(item.get("dispute_won"), "sale dispute outcome"),
        "shipped": _boolean(item.get("shipped"), "sale shipping state"),
        "subscription_id": (
            provider_id(item.get("subscription_id"), "subscription ID")
            if item.get("subscription_id")
            else None
        ),
        "subscription_duration": text_value(
            item.get("subscription_duration"), "sale subscription duration"
        ),
        "subscription_cancelled": _boolean(
            item.get("cancelled"), "subscription cancellation state"
        ),
        "subscription_ended": _boolean(
            item.get("ended"), "subscription ended state"
        ),
        "has_license": bool(item.get("license_key") or item.get("license_id")),
    }


def payout_record(item: dict[str, Any]) -> dict[str, Any]:
    """Keep payout totals and state while excluding destination identifiers."""
    amount = text_value(item.get("amount"), "payout amount", optional=False)
    currency = text_value(item.get("currency"), "payout currency", optional=False)
    created = text_value(item.get("created_at"), "payout creation time", optional=False)
    payout_id = item.get("id")
    remote_id = (
        provider_id(payout_id, "payout ID")
        if payout_id
        else "upcoming_"
        + hashlib.sha256(f"{created}|{currency}|{amount}".encode()).hexdigest()[:32]
    )
    return {
        "kind": "payout",
        "remote_id": remote_id,
        "amount": amount,
        "currency": currency,
        "status_label": text_value(item.get("status"), "payout status"),
        "created_at": created,
        "processed_at": text_value(
            item.get("processed_at"), "payout processing time"
        ),
        "payment_processor": text_value(
            item.get("payment_processor"), "payout processor"
        ),
    }
