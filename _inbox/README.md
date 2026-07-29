# _inbox/ — Transit Zone

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

This directory is a **transit zone**, not permanent storage.

Items here are unclassified: they have not yet been routed to a plane,
assigned a sensitivity level, or deduplicated. Nothing in `_inbox/` is
authoritative until triaged.

Routing promotes canonical raw bytes into `_knowledge/` and records the resulting
corpus-scoped `evidence_id`. Inbox paths, filenames, triage rows, and temporary
copies never become authority and may be removed after a verified promotion.

## Tracked seed surface

- `README.md` — this policy.
- `.gitignore` — keeps raw captures out of git.
- `triage.log` — append-only JSONL audit trail, committed here as an empty seed.

## Sub-folders

| Folder | Purpose |
|--------|---------|
| `_drop/` | Watch folder for raw drops |
| `email/` | Email captures (`.eml`, `.msg`) |
| `web/` | Web snapshots and extracted text |
| `scan/` | Document scans and images |
| `voice/` | Voice memos and recordings |
| `import/` | Bulk imports from other systems |
| `_needs-review/` | Items that failed auto-routing |

All raw capture sub-folders are gitignored. Promote reviewed material into the
appropriate destination plane.
