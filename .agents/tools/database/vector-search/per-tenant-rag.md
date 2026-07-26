---
description: Per-tenant RAG pipeline architecture for multi-tenant SaaS applications
mode: subagent
model: standard
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Per-Tenant RAG Architecture

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Multi-org schema**: `services/database/multi-org-isolation.md`
- **Tenant context model**: `services/database/schemas/tenant-context.ts`
- **Multi-org schema (Drizzle)**: `services/database/schemas/multi-org.ts`
- **Cloudflare Vectorize**: `services/hosting/cloudflare-platform-skill/vectorize.md`
- **Isolation strategy**: Collection-per-tenant (physical) or namespace/metadata filtering (logical)

**Scope**: SaaS apps where users/organisations upload documents for RAG. NOT for aidevops internal memory (SQLite FTS5) or code search (exact local search plus targeted reads).

<!-- AI-CONTEXT-END -->

## End-to-End Pipeline

1. **Ingest** — Validate MIME/size/malware; store original in R2/S3 keyed by `org_id`
2. **Parse** — PDF: Docling | DOCX: mammoth | HTML: readability | CSV: papaparse | TXT: direct
3. **Chunk** — 512-1024 tokens, 128 overlap, recursive character splitting
4. **Embed** — Batch 32-128 chunks; store model ID with vectors
5. **Store** — One collection/namespace per `org_id`; HNSW index
6. **Query** — Embed query; search ONLY tenant's collection; topK=20 candidates
7. **Rerank** — Cross-encoder or RRF; return top-5 with metadata
8. **Assemble** — System prompt + chunks + query; manage token budget

Critical failure modes: Store wrong collection → **data leak**; Query without tenant filter → **cross-tenant exposure**; Skip rerank → hallucination. Parse/chunk/embed errors corrupt all downstream output.

## Tenant Isolation

| Approach | Isolation | Overhead | Limit | Best for |
|----------|----------|----------|-------|----------|
| Collection-per-tenant | Physical | None | ~10K | **Default** |
| Namespace-per-tenant | Logical (partition) | Filter (fast) | ~50K | Cloudflare Vectorize |
| Metadata filter | Logical (row-level) | Filter on search | Unlimited | Few tenants |
| pgvector + RLS | Logical (DB-level) | RLS check | Unlimited | Already on PostgreSQL |
| Separate DB/index | Physical (full) | None | ~100 | Regulated/enterprise |

**Recommended: Collection-per-tenant.** Queries against tenant A's collection cannot return tenant B's data even with application bugs. **When NOT to use**: >10K tenants, tenants with <100 vectors, or cross-tenant search required.

**Naming convention**: Collection `rag_{org_id}`, object storage `uploads/{org_id}/`. Metadata on every vector: `org_id`, `uploaded_by`, `source_file`, `chunk_index`.

### Cross-Tenant Prevention (Defence in Depth)

- **Layer 1 — Physical**: Collection-per-tenant scopes queries physically.
- **Layer 2 — Application**: Derive collection name from authenticated `req.tenant.orgId`, never from user input or `req.body`.
- **Layer 3 — Validation**: Post-query ownership check — log `CROSS_TENANT_LEAK_DETECTED` and filter results where `metadata.org_id !== requesting_org_id`.
- **Layer 4 — Testing**: Integration test verifying tenant A cannot see tenant B's data after both upload documents.
- **Audit logging**: Log all RAG operations (upload, delete, search) to `audit_log` with `org_id`, `user_id`, `action`, metadata.

## Pipeline Stage Details

### Stages 1-3: Ingest, Parse, Chunk

Validate MIME from magic bytes (not extension), scan for malware, enforce per-tenant quotas. Default max 50MB (`effectiveMaxFileSize = min(globalCap, planCap)`).

**Chunk sizes**: 256-512 (Q&A), **512-1024 (general, default)**, 1024-2048 (summarisation), variable/section-based (structured docs). Default overlap: 128 tokens.

Required chunk metadata: `id` (`{document_id}_{chunk_index}`), `content`, `document_id`, `chunk_index`, `total_chunks`, `source_file`, `org_id`, `uploaded_by`, `uploaded_at`, `embedding_model`.

### Stage 4: Embed

| Model | Dims | Cost | Notes |
|-------|------|------|-------|
| OpenAI text-embedding-3-small | 1536 (Matryoshka→512/256) | $0.02/1M tok | Best quality/cost |
| OpenAI text-embedding-3-large | 3072 (Matryoshka→1024/256) | $0.13/1M tok | Quality-critical |
| Jina v3 | 1024 (Matryoshka→256) | $0.02/1M tok | Multilingual |
| Sentence Transformers (local) | 384 | Free | No API dependency |
| Cloudflare Workers AI bge-base | 768 | Included | Cloudflare-native |
| BM25 (sparse, local) | Vocab-sized | Free | Hybrid complement |

**Critical**: Store embedding model ID with every vector. Model changes make old vectors incompatible — re-embed or maintain separate collections per model version. Matryoshka truncation (1536→512→256) saves storage with ~2-5% recall loss.

### Stage 5: Store

**HNSW tuning**: <10K→M:16/ef_c:100/ef_s:50, 10K-100K→16/200/100, 100K-1M→32/200/150, >1M→48/400/200.

**Vector DBs**: zvec (collection/org, HNSW/IVF), Cloudflare Vectorize (namespace/org, managed), pgvector (RLS on org_id, IVF/HNSW), Qdrant (collection/org, HNSW).

### Stage 6: Query

Pattern: derive `collectionName = rag_${ctx.org_id}`, check collection exists, embed query using the collection's stored model, search dense (and optionally sparse for hybrid), apply `minScore: 0.3` filter.

**Defaults**: `candidateCount: 20`, `minScore: 0.3`, `hybrid: false`, `hybridAlpha: 0.7`. Enable hybrid when users search specific terms/names/codes or documents contain domain jargon.

### Stage 7: Rerank

Highest-ROI improvement — typically 10-30% answer quality gain. Use cross-encoder (highest accuracy, 50-200ms latency) or RRF (<1ms, free). Never skip in production.

RRF: score = `alpha / (k + rank + 1)` (dense) + `(1-alpha) / (k + rank + 1)` (sparse), sum by chunk ID, sort descending. Default `k=60`, `alpha=0.7`.

### Stage 8: LLM Context Assembly

Assemble system prompt + retrieved chunks + user query within token budget. Include source attribution (`[Source: filename, p.N]`) per chunk. Stop adding chunks when budget exhausted.

**Token budget (128K model)**: System prompt 500-2000 | Retrieved chunks 4000-16000 | User query 50-500 | Response reserve 2000-4000.

## Tenant Lifecycle

### Onboarding

1. Create vector collection `rag_{org_id}` with `metric: cosine`, `indexType: hnsw`, `m: 16`, `efConstruction: 100`, dimension from embedding config.
2. Update `organisations.settings` JSONB: set `rag.enabled`, `rag.embeddingModel`, `rag.dimensions`, `rag.createdAt`.
3. Insert `audit_log` row: `action: rag:tenant_onboarded`, `entityType: rag_collection`, include `collectionName` and embedding config in metadata.

### Deletion

1. Delete vector collection `rag_{org_id}`.
2. Delete object storage prefix `uploads/{org_id}/` (paginate for large buckets).
3. Remove `rag` key from `organisations.settings` JSONB.
4. Insert `audit_log` row: `action: rag:tenant_offboarded`.

**Deletion notes**: Qdrant/pgvector/zvec delete synchronously. Cloudflare Vectorize is async — poll or verify before confirming. Audit log persists after deletion (compliance). Trigger RAG cleanup in `beforeDelete` hook if org deletion cascades.

## Storage Sizing and Quotas

| Component | 1536d | 384d |
|-----------|-------|------|
| Embedding (float32) | 6,144 B | 1,536 B |
| Metadata + content + HNSW | ~3-4 KB | ~3-4 KB |
| **Total per vector** | **~9-10 KB** | **~4-5 KB** |

| Tenant profile | Chunks | Storage (1536d) | Storage (384d) |
|---------------|--------|----------------|----------------|
| Small (100 docs) | ~25K | ~250 MB | ~125 MB |
| Medium (1K docs) | ~250K | ~2.5 GB | ~1.25 GB |
| Large (10K docs) | ~2.5M | ~25 GB | ~12.5 GB |

Plan quotas: free (50 docs / 100 MB / 10 MB file / 10K vectors), pro (5K docs / 5 GB / 50 MB file / 500K vectors), enterprise (100K docs / 100 GB / 200 MB file / 10M vectors).

**Cost optimisation**: (1) Matryoshka 512d saves 3x storage, ~3% recall loss. (2) Local models eliminate API costs. (3) Lazy embedding on first query if upload >> query volume. (4) INT8 quantization: 4x storage reduction, ~1% recall loss (zvec, Qdrant). (5) TTL: auto-delete chunks not queried in 90+ days.

## Implementation Checklist

- [ ] **Isolation**: Collection/namespace derived from authenticated tenant context (`org_id`), never user input
- [ ] **Lifecycle**: Onboarding creates collection; deletion destroys it + object storage
- [ ] **Embedding model tracked**: Model ID stored with every vector
- [ ] **Quotas enforced**: Per-plan limits on documents, storage, vectors
- [ ] **Audit logged**: Upload, delete, search with org_id
- [ ] **Cross-tenant test**: Integration test: tenant A cannot see tenant B's data
- [ ] **Reranking enabled**: Cross-encoder or RRF for production
- [ ] **Token budget managed**: Context assembly respects model limits
- [ ] **Source attribution**: Chunks include file name and page/section
- [ ] **Error handling**: Graceful degradation when vector DB unavailable
- [ ] **Monitoring**: Per-tenant vector count, query latency, storage usage
