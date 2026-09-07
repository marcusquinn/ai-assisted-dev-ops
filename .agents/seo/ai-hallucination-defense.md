---
name: ai-hallucination-defense
description: Reduce brand hallucination risk by auditing factual consistency, claim support, and ambiguity across site content
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

# AI Hallucination Defense

Prevent misinformation by fixing contradictions and weakly-supported claims in source content.

**Inputs:** high-risk fact list, claim inventory, key conversion pages
**Outputs:** consistency audit, claim-evidence matrix, remediation priorities

## Workflow

1. **Define critical fact inventory** — track canonical values (pricing, timelines, credentials, policies, service areas, support terms); assign one owner source per value; mark values requiring cross-page sync
2. **Run contradiction scan** — find all mentions per critical fact; label mismatches (critical/moderate/low); prioritize fixes on pages most likely to be retrieved
3. **Validate claim support** — extract explicit marketing claims; attach evidence links and confidence ratings; replace vague superlatives with measurable statements
4. **Remove ambiguity** — rewrite unclear references (pronouns, implied subjects, outdated qualifiers); keep policy/offer language explicit; normalize terminology across product, support, and legal pages
5. **Re-test representative prompts** — ask question sets likely to trigger past confusion; confirm generated answers align with canonical facts; record residual drift for follow-up

For corpus-level identity or apparent cross-domain consensus, load
`entity-evidence-audit.md` before accepting corroboration. Distinguish product,
publisher, and person identities; record source ownership and claim derivation.
Repeated owned or syndicated claims are not independent verification. Use
`seo-geo-experiment-design.md` for repeatable prompt conditions and causal limits.

## Risk Signals

- Conflicting numeric values between key pages
- Unsupported "best"/"leading"/"award-winning" claims
- Old versions of offers still indexable
- Different names for same feature or policy

## Related Subagents

- `geo-strategy.md` — criteria and retrieval planning
- `sro-grounding.md` — snippet survivability
- `ai-agent-discovery.md` — autonomous discoverability checks
- `transcript-seo.md` — video/audio transcripts as canonical fact sources for claim verification
