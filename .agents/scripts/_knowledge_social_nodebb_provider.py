#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only NodeBB account reader subprocess."""

from _knowledge_social_forum_provider import provider_functions

_profile, _dispatch, parse_args, main = provider_functions("nodebb", __doc__)


if __name__ == "__main__":
    raise SystemExit(main())
