# _knowledge/ — Repository Knowledge Plane

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

This is the repository-local knowledge plane: curated source material that AI
DevOps can ingest, classify, index, and reference for project work.

This plane is the canonical evidence authority. Contract-v1 raw sources use a
stable corpus/connector/content identity (`ev1:`); normalized data, indexes,
embeddings, and cross-plane views are rebuildable projections. Replay must reuse
the same evidence ID instead of creating another authoritative source.

## Tracked seed surface

- `_config/knowledge.json` — default policy for sensitivity, trust, ingest rules,
  and blob thresholds.
- `sources/.gitkeep` — promoted, reviewed source directories belong under
  `sources/<source-id>/`.
- `collections/.gitkeep` — curated subsets of promoted sources.

## Git policy

Raw and generated material is intentionally ignored by default:

- `inbox/` — unreviewed drops.
- `staging/` — curated-before-commit workspace.
- `index/` — generated search/index artifacts.

Version only reviewed, non-sensitive examples or metadata. Store files larger
than 30 MB outside git and reference them with `blob_path` in `meta.json`.

See `.agents/aidevops/knowledge-plane.md` for the full contract.
