# Knowledge Plane — Directory Contract

The knowledge plane is an opt-in file staging area for AI-assisted ingestion of
external documents, data exports, and reference material into aidevops-managed
repos. Each repo can independently enable or disable the plane.

For cross-plane routing metadata, use `.agents/configs/data-planes.json` as the
canonical registry. This document owns the `_knowledge/` directory contract; the
registry owns shared facts such as default sensitivity, ingress/egress, helper,
and retrieval surfaces.

## Quick Contract

- Modes: `repos.json` `knowledge` field supports `off` (default), `repo`, and
  `personal`.
- Repo mode root: `<repo>/_knowledge/`; personal mode root:
  `~/.aidevops/.agent-workspace/knowledge/`.
- Versioned knowledge lives in `sources/` and `collections/`; raw `inbox/`,
  curated `staging/`, and generated `index/` are gitignored by default.
- Contract v1 gives each immutable raw item one corpus-scoped `ev1:` identity.
  `_knowledge` owns that evidence; indexes and cross-plane records retain
  validated `pr1:` projections or pointers rather than copying authority.
- Provision with `aidevops knowledge init repo`, `aidevops knowledge init personal`,
  or idempotently repair with `aidevops knowledge provision`.
- Files ≥30MB are routed to the local blob store and represented by committed
  `meta.json` stubs.
- LLM, email, review, indexing, and enrichment behaviour is detailed in the
  chapter files below.

## Chapter Files

| Chapter | Contents |
|---------|----------|
| [`knowledge-plane/01-core-contract.md`](knowledge-plane/01-core-contract.md) | Modes, canonical evidence/source identity, directory layout, gitignore rules, source `meta.json`, blob threshold, defaults, personal vs repo mode, CLI |
| [`knowledge-plane/02-email-sources.md`](knowledge-plane/02-email-sources.md) | `kind=email` ingestion (t2854), IMAP polling (t2855), thread reconstruction and case filters (t2856) |
| [`knowledge-plane/03-platform-and-policy.md`](knowledge-plane/03-platform-and-policy.md) | Platform abstraction (t2843), sensitivity classification (t2846), LLM routing, Ollama integration (t2848) |
| [`knowledge-plane/04-enrichment-index-review.md`](knowledge-plane/04-enrichment-index-review.md) | Structured enrichment (t2849), corpus index (t2850), review gate (t2845) |

## Representative Commands

```bash
aidevops knowledge init repo
aidevops knowledge init personal
aidevops knowledge provision
aidevops knowledge status
aidevops knowledge add path/to/file.pdf
aidevops knowledge search "invoice 2026"
```

## Implementation Surfaces

| Surface | Location |
|---------|----------|
| Knowledge helper | `.agents/scripts/knowledge-helper.sh` |
| Review gate helper | `.agents/scripts/knowledge-review-helper.sh` |
| Corpus index helper | `.agents/scripts/knowledge-index-helper.sh` |
| Enrichment helper | `.agents/scripts/document-enrich-helper.sh` |
| Email ingest helper | `.agents/scripts/email-ingest-helper.sh` |
| Email thread helper | `.agents/scripts/email-thread-helper.sh` |
| Email filter helper | `.agents/scripts/email-filter-helper.sh` |
| LLM routing helper | `.agents/scripts/llm-routing-helper.sh` |
| Ollama helper | `.agents/scripts/ollama-helper.sh` |
| Knowledge config template | `.agents/templates/knowledge-config.json` |
| Sensitivity config template | `.agents/templates/sensitivity-config.json` |
| LLM routing config template | `.agents/templates/llm-routing-config.json` |
| Ollama bundle template | `.agents/templates/ollama-bundle.json` |

## Preservation Notes

This file is intentionally a slim index. The previous inline sections were moved
without semantic changes into the chapter files above so agents can load only the
matching topic while retaining all command examples, URLs, task IDs, schemas, and
policy rationale.
