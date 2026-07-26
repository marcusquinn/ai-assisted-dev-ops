---
description: Vector search decision guide for multi-tenant SaaS — zvec, pgvector, Cloudflare Vectorize, PGlite+pgvector, hosted options
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vector Search for Multi-Tenant SaaS

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Choose and implement vector search for per-tenant RAG pipelines in SaaS applications
- **Primary recommendation**: zvec (embedded, collection-per-tenant) or pgvector (if already on Postgres)
- **Scope**: Application-level vector search — NOT for aidevops internal use (which stays on SQLite FTS5)

<!-- AI-CONTEXT-END -->

## Decision Flowchart

```text
Need vector search for SaaS with per-tenant data?
  NO  --> Use exact local search plus targeted reads (code) or SQLite FTS5 (cross-session memory).
  YES --> Already on Postgres?
    YES --> >10M vectors/tenant? → pgvector with partitioning, or Qdrant/Pinecone
            ≤10M vectors/tenant? → pgvector (simplest — one fewer dependency)
    NO  --> Zero external dependencies? → zvec (embedded, in-process, built-in embeddings)
            On Cloudflare Workers?     → Vectorize (native edge integration)
            <100 tenants, predictable  → Qdrant self-hosted
            >100 tenants, variable     → Pinecone or Weaviate Cloud
            Budget-constrained         → zvec (no per-query cost)
```

## Comparison Matrix

| Feature | zvec | pgvector | Vectorize | PGlite+pgvector | Pinecone | Qdrant | Weaviate |
|---------|------|----------|-----------|-----------------|----------|--------|----------|
| Deployment | In-process | Postgres ext. | CF edge | In-process (WASM) | Hosted | Self/cloud | Self/cloud |
| Max vectors | 10M+ | 100M+ | 5M/index | ~500K (WASM) | Billions | 100M+ | 100M+ |
| Hybrid search | Yes (multi-vector) | Manual (2 queries) | No | Manual | Yes | Yes | Yes |
| Built-in embeddings | Yes (local + API) | No | Workers AI | Via ext. | Inference API | FastEmbed | Built-in |
| Built-in rerankers | RRF, weighted, cross-encoder | No | No | No | No | No | Reranker modules |
| Quantization | INT4/INT8/FP16 | Halfvec (FP16) | Automatic | Halfvec | Automatic | Scalar/binary/PQ | PQ, BQ |
| ACID transactions | No | Yes | No | Yes (PGlite) | No | No | No |
| Ops overhead | None | Low | None | None | None | Medium | Medium |
| Network latency | Zero | LAN | Edge <10ms | Zero | 50-200ms | 1-5ms | 1-5ms |
| License | Apache 2.0 | PostgreSQL | Proprietary | Apache 2.0 | Proprietary | Apache 2.0 | BSD-3 |

### Cost Model

| Option | Fixed | Per-query | Notes |
|--------|-------|-----------|-------|
| zvec | $0 | $0 | Cheapest at scale (disk only) |
| pgvector | $0 | $0 | Shares existing Postgres infra |
| Vectorize | $0.01/1M queries | $0.04/1M vectors/mo | Free: 30M queries/mo, 5M vectors |
| PGlite+pgvector | $0 | $0 | Client-side only |
| Pinecone | $0 starter | $0 (2M vectors) | Serverless: pay per read/write unit; $0.33/1M/mo |
| Qdrant Cloud | $0 (1GB free) | Per-node | Self-hosted: $0 |
| Weaviate Cloud | $0 sandbox | Per-node | Self-hosted: $0 |

### Platform Support

| Platform | zvec | pgvector | Vectorize | PGlite+pgvector | Pinecone | Qdrant | Weaviate |
|----------|------|----------|-----------|-----------------|----------|--------|----------|
| Node.js / Bun | Early | Yes | No (Workers only) | Yes (WASM) | Yes | Yes | Yes |
| Python | Full | Yes | No | No | Yes | Yes | Yes |
| CF Workers | No | No (no TCP) | Yes (native) | No (no FS) | Yes (HTTP) | Yes (HTTP) | Yes (HTTP) |
| Electron / Browser ext. | No / No | No / No | No / No | Yes / Yes (IndexedDB) | Yes / Yes | Yes / Yes | Yes / Yes |
| Docker / Linux | Yes | Yes | No | Yes | Yes | Yes | Yes |
| macOS (ARM64) | Yes | Yes | No | Yes | Yes | Yes | Yes |
| Windows | No | Yes | No | Yes | Yes | Yes | Yes |

## Per-Tenant Isolation Patterns

### Pattern 1: Collection-per-tenant (zvec)

```python
import zvec

def create_tenant_collection(org_id: str, data_root: str = "/data/vectors"):
    path = f"{data_root}/{org_id}"
    schema = zvec.Schema()
    schema.add_field("id", zvec.DataType.STRING, primary_key=True)
    schema.add_field("content", zvec.DataType.STRING)
    schema.add_field("dense", zvec.DataType.VECTOR_FP32, dimension=384)
    schema.add_field("sparse", zvec.DataType.SPARSE_VECTOR_FP32)
    schema.add_field("source_file", zvec.DataType.STRING)
    schema.add_field("chunk_index", zvec.DataType.INT64)
    collection = zvec.create_and_open(path=path, schema=schema)
    collection.create_index("dense", zvec.IndexType.HNSW,
                            zvec.HnswIndexParam(quantize_type=zvec.QuantizeType.INT8))
    collection.create_index("sparse", zvec.IndexType.HNSW_SPARSE)
    return collection

def delete_tenant_data(org_id: str, data_root: str = "/data/vectors"):
    import shutil
    shutil.rmtree(f"{data_root}/{org_id}")
```

Physical isolation, simple GDPR deletion (rm -rf), no cross-tenant leakage. Close idle tenants with LRU to manage memory.

### Pattern 2: Schema-per-tenant with RLS (pgvector)

```sql
CREATE TABLE embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organisations(id),
    content TEXT NOT NULL,
    embedding vector(1536) NOT NULL,
    source_file TEXT,
    chunk_index INTEGER,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX ON embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

ALTER TABLE embeddings ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON embeddings
    USING (org_id = current_setting('app.current_org_id')::UUID);
-- SET LOCAL app.current_org_id = '<org-uuid>' per request
```

```typescript
// Drizzle + pgvector
async function searchTenant(db: NodePgDatabase, orgId: string, queryEmbedding: number[], topK = 5) {
  await db.execute(sql`SET LOCAL app.current_org_id = ${orgId}`);
  return db.execute(sql`
    SELECT id, content, source_file, chunk_index,
           1 - (embedding <=> ${sql.raw(`'[${queryEmbedding.join(",")}]'::vector`)}) AS similarity
    FROM embeddings
    ORDER BY embedding <=> ${sql.raw(`'[${queryEmbedding.join(",")}]'::vector`)}
    LIMIT ${topK}
  `);
}
```

ACID transactions, SQL filtering, leverages existing Postgres. RLS adds ~5-15% query overhead.

### Pattern 3: Namespace-per-tenant (Cloudflare Vectorize)

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const orgId = getOrgIdFromAuth(request);
    await env.VECTORIZE_INDEX.upsert([{
      id: "doc-chunk-001",
      values: embeddingVector,
      namespace: orgId,
      metadata: { source_file: "report.pdf", chunk_index: 0 },
    }]);
    const results = await env.VECTORIZE_INDEX.query(queryVector, {
      topK: 5, namespace: orgId, returnMetadata: "all",
    });
    return Response.json(results.matches);
  },
};
```

Zero ops, edge latency, automatic scaling. Cloudflare-only, 5M vectors/index, no hybrid search.

### Pattern 4: Hosted Services (Pinecone, Qdrant)

```typescript
// Pinecone — physical isolation via namespaces
const index = new Pinecone().index("my-app");
await index.namespace(orgId).upsert([{ id: "doc-chunk-001", values: embeddingVector, metadata: {} }]);
const results = await index.namespace(orgId).query({ vector: queryVector, topK: 5, includeMetadata: true });

// Qdrant — logical isolation via payload filtering
await client.search("documents", {
  vector: queryVector, limit: 5,
  filter: { must: [{ key: "org_id", match: { value: orgId } }] },
  with_payload: true,
});
```

Pinecone namespaces = physical isolation. Qdrant/Weaviate payload filters = logical isolation (a missing filter leaks data).

## Per-Tenant RAG Pipeline

```text
Upload → [Chunking] 512-1024 tokens, 128-token overlap
       → [Embedding] same model for store and query (mixing models = meaningless scores)
       → [Store] tenant-scoped collection/namespace/partition
       → [Query] embed → search topK=20 → rerank → return top-5 with metadata
       → [LLM Context] system + retrieved chunks + user query
```

**Embedding models**: zvec built-in: all-MiniLM-L6-v2 (384d, free, local) | OpenAI: text-embedding-3-small (1536d) | Jina v5: jina-embeddings-v5-text-nano (1024d, Matryoshka to 256d)

## zvec Deep Dive

In-process C++ vector database built on Alibaba's Proxima engine. No separate server, no network hop. Apache 2.0.

- **Repo**: https://github.com/alibaba/zvec (~8.4k stars) | Created December 2025 — very new
- **Platforms**: Linux (x86_64, ARM64), macOS (ARM64). No Windows.
- **Bindings**: Python (full), Node.js (core ops only, early stage)
- **Index types**: HNSW, IVF (SOAR), FLAT, HNSW-Sparse, Flat-Sparse, Inverted
- **Quantization**: INT4, INT8 (recommended — ~4x memory reduction, minimal recall loss), FP16

**Built-in embedding functions** (Python only):

| Function | Model | Dimensions | Cost |
|----------|-------|------------|------|
| DefaultLocalDense | all-MiniLM-L6-v2 | 384 | Free (local) |
| DefaultLocalSparse (SPLADE) | splade-cocondenser-ensembledistil | Sparse | Free (local) |
| OpenAIDenseEmbedding | text-embedding-3-small/large | 1536/3072 | API cost |
| JinaDenseEmbedding | jina-embeddings-v5-text-nano | 1024 (Matryoshka to 32) | API cost |
| BM25EmbeddingFunction | DashText | Sparse | Free (local) |

**Built-in rerankers**: RrfReRanker (RRF for dense+sparse), WeightedReRanker, DefaultLocalReRanker (cross-encoder, local), QwenReRanker (API)

### Hybrid Search Example (Python)

```python
import zvec
from zvec.extension import DefaultLocalDenseEmbedding, DefaultLocalSparseEmbedding, RrfReRanker

dense_fn = DefaultLocalDenseEmbedding()
sparse_fn = DefaultLocalSparseEmbedding()
query_text = "How does the billing system handle refunds?"

collection = zvec.open(path=f"/data/vectors/{org_id}")
results = collection.query(
    vector_queries=[
        zvec.VectorQuery(field="dense", vector=dense_fn.embed_query(query_text), topk=20),
        zvec.VectorQuery(field="sparse", vector=sparse_fn.embed_query(query_text), topk=20),
    ],
    reranker=RrfReRanker(rank_constant=60),
    topk=5,
    output_fields=["content", "source_file", "chunk_index"],
)
```

### Node.js Status

`@zvec/zvec` (v0.2.1) provides core database operations via native C++ bindings. The Python extension ecosystem (embedding functions, rerankers) has no Node.js equivalent. For Node.js: use zvec for storage/retrieval, bring your own embedding pipeline (OpenAI SDK, Transformers.js). For production Node.js needing the full pipeline, pgvector or a hosted option is more practical.

### Performance and Platform Gotchas

Published benchmarks (Cohere 10M dataset, 16 vCPU / 64GB, INT8): 1-5ms search latency, ~25% memory vs FP32. The "billions of vectors in milliseconds" README claim refers to Alibaba's internal Proxima deployment — not publicly verified at that scale.

**AMD Zen 2 incompatibility**: Tested with zvec 0.2.0 (`manylinux_2_28_x86_64` wheel), Python 3.12.3 — `Illegal instruction` (exit 132) on AMD Ryzen 9 3900 (Zen 2). Precompiled binary likely requires AVX-512; Zen 2 has AVX2 only. Use pgvector or a hosted alternative on AMD Ryzen/EPYC Zen 2 servers. Intel w/ AVX-512 and macOS ARM64 expected OK.

## Advanced Retrieval Patterns

### Agentic Retrieval (DB-Agnostic)

Naive "embed-query → cosine-topK → return" collapses on multi-domain queries because they carry implicit filters (jurisdiction, date, document type) and require routing across multiple collections. Agentic retrieval replaces the single-vector lookup with a three-stage reasoning loop — this loop is **not Weaviate-specific**: any LLM + any vector store implements it.

1. **Schema inspection** — reasoning layer reads available collections/namespaces and their metadata fields before routing. Example: a legal corpus exposes `contracts_operational`, `caselaw_ca`, `statutes_regulations`.
2. **Sub-query planning** — decomposes a natural-language question into multiple filtered retrievals. Example: "2024 MSA cure periods in California" → sub-queries across `contracts_operational` (type=MSA, field=cure\_period, date≥2024) + `statutes_regulations` (jurisdiction=CA).
3. **Rerank sub-agent** — after parallel retrieval, a second-pass LLM call (often a cheaper/faster model) scores and re-orders candidates before answer synthesis.

| Decision | Guidance |
|----------|----------|
| Default start | zvec + LLM reasoning loop — no managed service, no per-query cost |
| Escalate to Weaviate Query Agent | Only when managed-service ops reduction justifies Cloud pricing and vendor lock-in |
| Single-collection corpus | Agentic routing adds overhead with no recall gain — skip it |
| Cross-collection required | Metadata fields on every chunk are the prerequisite; without them routing degrades to guessing |

Concrete legal application: [`tools/legal/legal-research.md`](../legal/legal-research.md) — multi-collection schema, routing signals, and privilege metadata required to make agentic retrieval audit-safe.

### Multivector Models and Muvera Compression (Visual Documents)

Plain-text embeddings lose signature blocks, stamps, tables, and redaction boxes in legal/financial PDFs. When documents have visual structure that determines the correct answer — form fields, table cells, page stamps — text-only pipelines silently lose recall on those elements.

| Approach | Recall gain | Storage cost | When to use |
|----------|------------|-------------|-------------|
| Single-vector (default) | Baseline | Baseline | Text-dominant docs |
| ColBERT late interaction | +15-30% on phrase/token-level lookups | ~10x (token-per-vector) | Legal discovery, precision-critical lookups |
| ModernVBERT / visual transformer | Captures table cells, signatures, redaction boxes | ~10-15x | Forms, financial filings, stamped PDFs |
| Muvera FDE compression | ColBERT recall, ~3x reduction vs ColBERT | ~3x vs single-vector | ColBERT at production scale |

**Muvera** (Fixed-Dimensional Encoding) compresses multivectors into a single fixed-size vector while preserving late-interaction recall within ~1-2% at ~3x storage cost vs single-vector. This makes ColBERT-scale retrieval feasible at production cost by eliminating most of the ~10x storage premium over single-vector models.

**When to pay the cost**: Legal discovery, financial filings, and forms-heavy corpora where signatures, stamps, or table structure determine the correct answer. Text-dominant corpora (plain contracts, statutes, meeting notes) get negligible recall gain and should stay on single-vector.

Both patterns are backend-agnostic — pgvector, Qdrant, Weaviate, and zvec all support them. The retrieval approach is independent of the vector database. See [`tools/legal/legal-research.md`](../legal/legal-research.md) for a concrete legal-domain application.

## Gotchas

**zvec-specific:**

1. **Very new** (December 2025) — APIs may change, small community
2. **Python-first** — Node.js bindings early stage, no extension ecosystem
3. **No Windows** — Linux and macOS only
4. **Single-process** — only one process can open a collection at a time
5. **No ACID** — use application-level locking for concurrent writes
6. **Memory per collection** — use LRU cache to close idle tenant collections

**All options:**

1. **Embedding model lock-in** — changing models requires re-embedding all vectors. Matryoshka models (Jina v5) offer dimension flexibility without re-embedding.
2. **Dimension mismatch** — inserting 384d vectors into a 1536d index silently pads or fails. Always validate dimensions match.
3. **Recall vs speed** — HNSW `ef_search` and `ef_construction` trade recall for speed. Start with defaults, benchmark with your data.
4. **Stale embeddings** — when source documents update, chunks and embeddings must be re-generated. Track `document_version` in metadata.
5. **Cost surprise with hosted** — Pinecone/Weaviate Cloud costs scale with stored vectors AND queries. A 10M vector index with high QPS can cost $100+/month.
6. **PGlite+pgvector limits** — WASM overhead limits practical dataset to ~500K vectors.
7. **Vectorize lock-in** — only works in Cloudflare Workers. Use pgvector locally for development.

## Related

- `tools/database/pglite-local-first.md` — PGlite (local-first embedded Postgres)
- `services/database/postgres-drizzle-skill.md` — Postgres + Drizzle
- `reference/memory.md` — SQLite FTS5 (aidevops cross-session memory, NOT app vector search)
- https://github.com/alibaba/zvec | https://github.com/pgvector/pgvector
- https://developers.cloudflare.com/vectorize/ | https://www.pinecone.io/ | https://qdrant.tech/ | https://weaviate.io/
