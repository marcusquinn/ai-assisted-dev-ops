# `_performance/` — Performance Plane

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Canonical local plane for operational, product, marketing, and engineering
outcomes that should be analysed over time.

Marketing ingest is provisioned with `aidevops performance init`. Versioned
configuration and explicitly generated summaries live under `marketing/`; raw
exports, the local SQLite index, quarantine evidence, and ad-hoc exports remain
gitignored.

Never put credentials or direct customer/contact identifiers in normalized
records. Marketing subjects and source events use per-plane HMAC-pseudonymous
references. Consent, suppression, identity links, corrections, and refunds are
append-only so reports can be rebuilt without rewriting source history.

Contract: `.agents/aidevops/performance.md`.
