<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Entity, Evidence, and Internal-Link Audit

Use before recommending corpus expansion, entity markup, or multiple publishing
domains. This reference supports `geo-strategy.md` and
`ai-hallucination-defense.md`; it does not replace technical crawling, schema
validation, or keyword research. Query → topic → entity is a planning model,
not a disclosed search-engine algorithm.

## Entity register

Map priority user questions to concepts, entities, existing pages, and evidence.
For each entity, record:

| Field | Required evidence |
|-------|-------------------|
| Identity | Entity ID, type, canonical name, legitimate aliases, authoritative identity page |
| Relationships | Explicit subject → relationship → object, such as product → published by → organisation |
| Support | Source IDs and sections supporting each relationship; unsupported relationships remain flagged |
| Coverage | Relevant page URLs, visible text, structured-data references, and external profiles |
| Integrity | Contradictions, ambiguous references, fact owner, verification date, and recheck path |

Keep products, organisations, people, categories, and capabilities distinct.
Normalise facts and identity, not every sentence: titles, headings, anchors, FAQs,
and biographies should serve their own reader intent rather than repeat an entity
chain mechanically. Check for misleading superlatives and category assignments.

Structured data describes visible, accurate content; it does not certify authority.
Use a stable `@id` for each actual entity, with separate IDs for its product,
publisher, and people. Use `sameAs` only for identity-equivalent references, not
favourable articles or related concepts. Shared ownership does not make every page
canonical to the brand homepage: citation links and HTML canonical signals serve
different purposes. Validate markup with `schema-validator.md`; FAQ visibility
does not by itself establish rich-result eligibility or GEO benefit.

## Evidence independence

Use the provenance fields in `llm-visibility-source-accrual.md`. Evaluate both
publisher independence and claim derivation; these are separate questions.

- Group commonly owned properties and syndicated/copied material before counting
  corroborating sources. Eight owned domains are not eight independent endorsements.
- An independent publisher quoting a vendor claim establishes that it was quoted,
  not that the publisher verified it. Record the underlying source and method.
- Owned documentation can substantiate product behaviour; ownership does not make
  it useless. It cannot independently establish category leadership.
- Record unknown ownership or derivation as unknown, not independent. Link each
  material claim to its evidence and distinguish observed, verified, inferred,
  benchmark, and unsupported claims using `conversational-search-intent.md`.
- Prefer reproducible product proof and original research: dated datasets,
  sampling, method, limitations, and appropriate privacy safeguards. Never invent
  scans, founders, credentials, product packages, reviews, or third-party mentions.

## Internal-link graph

Start with an existing crawl (`site-crawler.md` or `screaming-frog.md`) and record
its scope, date, rendering mode, and known gaps. Compare crawled URLs with sitemaps
or another available URL inventory; a link-only crawl cannot reveal every orphan.

Inspect orphan candidates, click depth, contextual incoming links to priority
pages, anchor relevance/repetition, duplicate intent, and links through redirects
or to noncanonical/nonindexable destinations. Distinguish navigational boilerplate
from contextual links. Verify important destinations and canonical/index status
before recommending changes.

Give each supporting page a distinct user purpose, useful explanation, or evidence
asset. Link where the relationship helps the reader; do not prescribe a fixed
number of supporting pages or force every page to link to a money page. A
crawl-derived internal PageRank calculation is an optional model of the observed
graph, not Google's PageRank or a ranking forecast. Record its assumptions and
crawl coverage; more pages do not automatically create more authority.

## Publishing decision and handoff

Prefer improving the primary site's documentation, comparisons, research, and
glossary before creating domains. A separate property needs a distinct audience
or publishing purpose, ownership disclosure, original value, and maintenance
capacity. Exact-match wording is not a reliable ranking advantage. Reject networks
whose main purpose is doorway coverage, manipulative links, or manufactured
consensus; review current search spam policies before any network experiment.

Deliver an entity register, claim/provenance ledger, and prioritised graph findings.
Each finding needs affected URLs, source IDs, user/business value, proposed change,
owner, confidence, and verification. Use `seo-geo-experiment-design.md` for causal
hypotheses and `ai-search-kpi-template.md` for observed outcomes. Ranking,
recognition, corroboration, and recommendation are separate outcomes, not a
guaranteed linear progression.
