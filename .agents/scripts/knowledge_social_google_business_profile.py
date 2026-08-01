#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one identity-bound Google Business Profile location read stream."""

from __future__ import annotations

import _knowledge_social_google_business_profile as gbp


def main() -> int:
    return gbp.run_collector(__doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
