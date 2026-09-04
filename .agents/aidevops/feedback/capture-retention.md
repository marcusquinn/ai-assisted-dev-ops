<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feedback Plane: Capture, Retention, and Sensitivity

Detailed contract chapter for `.agents/aidevops/feedback.md`.

## Capture Contract

`_feedback/captures/` stores normalized metadata and privacy-safe summaries for
retained qualitative feedback. Raw correspondence, exports, and personal data
belong in gitignored `_feedback/raw/` or `_feedback/pii/` only when retention is
authorized. A capture is evidence, not interpretation: store enough normalized
metadata to re-check provenance, consent, sensitivity, and context before mining
or promotion.

Each capture SHOULD be a markdown file with YAML frontmatter plus the original
quote or privacy-safe summary in the body. Repos may generate sidecar JSON later,
but the markdown contract is the human-readable baseline.

### Required Metadata Fields

| Field | Purpose |
|-------|---------|
| `id` | Stable capture ID, unique within `_feedback/captures/`. |
| `source` | Origin label or pointer: meeting note, issue/PR, survey export, support ticket, social thread, sales note, retrospective, or local file. |
| `timestamp` | When the feedback was observed or captured, preferably ISO 8601 UTC. |
| `actor` / `segment` | Speaker identity when safe, otherwise a privacy-safe role or audience segment such as `trial-user`, `client-admin`, or `internal-maintainer`. |
| `context` | Product, project, campaign, case, feature, workflow, or decision surface the feedback refers to. |
| `channel` | Collection channel such as `client`, `support`, `survey`, `social`, `sales`, `product`, or `retrospective`. |
| `raw_quote` / `summary` | Verbatim quote when retention and consent allow it; otherwise a faithful privacy-safe summary. |
| `sentiment` | `positive`, `negative`, `neutral`, `mixed`, or `unknown`. |
| `sensitivity` | `public`, `internal`, `client-scoped`, `privileged`, `personal`, or `delete-after-review` according to the policy below. |
| `consent` | Capture/mining permission such as `explicit`, `implied`, `internal-use`, `anonymized-only`, or `none`. |
| `retention_hint` | Suggested retention action or horizon: `keep`, `review-by:<date>`, `delete-after:<date>`, `anonymize`, or `case-bound`. |
| `provenance` | Pointer that lets an authorized reviewer find the source again: capture import ID, file path, issue/PR reference, case ID, message hash, or redacted excerpt hash. |

`raw_quote` and `summary` are alternatives: one of them is required. Prefer
`summary` when the source contains personal, client, privileged, or private repo
details that must not be copied into versioned docs or public GitHub surfaces.

### Minimal Capture Example

```markdown
---
id: feedback-2026-05-03-001
source: "demo-call-notes:2026-05-03"
timestamp: "2026-05-03T09:30:00Z"
actor: "anonymous trial user"
segment: "solo-founder"
context: "onboarding checklist"
channel: "client"
summary: "The user said the setup checklist was clear but wanted a shorter recovery path after a failed token setup."
sentiment: "mixed"
sensitivity: "internal"
consent: "anonymized-only"
retention_hint: "review-by:2026-08-03"
provenance: "local-note-hash:sha256:example-redacted-hash"
---

Privacy-safe summary only. No personal names, client identifiers, credentials,
private repo names, or raw call transcript are stored in this capture.
```

Capture files MAY add optional routing fields (`case`, `project`, `campaign`,
`tags`, `language`, `import_batch`) when known. Optional fields must not replace
the required provenance, consent, sensitivity, and retention metadata above.

## Retention and Sensitivity Policy

Raw feedback is evidence, not durable knowledge. Every retained capture MUST have
a sensitivity tier, consent/provenance note, and retention outcome before mining
or promotion. When Markdoc-style tags become available, stamp the capture or
region with `{% sensitivity tier="..." /%}` and keep the metadata value aligned
until the tag schema becomes canonical.

### Sensitivity Tiers

| Tier | Use for | Default handling |
|------|---------|------------------|
| `public` | Already-public comments, public issues, public reviews, or quoted material cleared for reuse. | May be retained long-lived and summarized publicly when provenance allows. |
| `internal` | Operator notes, private team observations, internal support summaries, or non-public product feedback without client identifiers. | Retain locally; promote only summarized, provenance-backed excerpts. |
| `client-scoped` | Feedback tied to a named client, account, project, private engagement, or case. | Keep scoped to that client/project/case; public surfaces receive anonymized summaries only. |
| `privileged` | Legal, HR, finance, contract, security-response, or other privileged case notes. | Keep local and access-restricted; promotion requires explicit approval and usually targets `_cases/` only. |
| `personal` | Personal data, private contact details, health/family/employment details, or unique actor identifiers. | Anonymize before mining or promotion; delete raw details when no longer needed. |
| `delete-after-review` | Accidental captures, unsupported consent, sensitive one-off reports, or content the source revoked. | Review once, record a non-sensitive disposition, then delete or retire raw content. |

### Retention Outcomes

| Outcome | Meaning | Allowed promotion |
|---------|---------|-------------------|
| `long-lived` | Capture may remain as evidence with provenance and a stable ID. | `_knowledge/`, `_campaigns/`, `_projects/`, `_performance/`, or tasks when review gates pass. |
| `anonymized` | Raw identifying details are removed or replaced with placeholders before reuse. | Durable planes receive only redacted excerpts, actor segments, counts, hashes, and source IDs. |
| `client-scoped` | Capture remains inside the relevant client/project/case boundary. | `_cases/` or `_projects/` for that scope; public TODO/GitHub tasks get privacy-safe summaries. |
| `privileged-local` | Raw content is retained only in local/private storage for privileged review. | `_cases/` only after approval; never public issues, PRs, TODO entries, or shared docs. |
| `deleted` / `retired` | Raw feedback is removed, revoked, obsolete, duplicate, or consent-expired. | No raw promotion; keep only a minimal audit note with capture ID, reason, and date when safe. |

### Consent, Provenance, and Promotion Constraints

- Promotion into `_knowledge/` requires `public`, `internal`, or already
  `anonymized` evidence with enough provenance to recheck the source. Personal,
  client-scoped, and privileged captures must be summarized before they become
  reusable knowledge.
- Promotion into `_campaigns/` may use public language, anonymized themes, or
  aggregated objections. Do not copy client names, private competitive notes, or
  personal details into campaign research unless the campaign plane is scoped to
  the same authorized audience.
- Promotion into `_projects/` may preserve client/project context only when the
  project scope matches the feedback scope. Cross-project requirements use
  anonymized segments, not actor names.
- Promotion into `_cases/` can retain client-scoped and privileged context, but
  must keep provenance, access scope, and approval state visible to authorized
  reviewers.
- TODO/GitHub tasks receive the smallest privacy-safe summary: problem, segment,
  evidence count, severity, affected files or decision surface, and verification.
  Raw captures, private repo names, personal details, and privileged notes stay in
  `_feedback/` or the scoped case/project store.

### Placeholder Examples

- `public + long-lived`: a public issue comment reports confusion in a setup step;
  promote a summarized theme with the public issue reference.
- `client-scoped + client-scoped`: `<client>` asks for clearer report labels in a
  private delivery call; keep the raw note under that case and create only a
  public-safe task summary.
- `personal + anonymized`: `<user-segment>` mentions a personal circumstance while
  describing onboarding friction; remove the personal detail and retain only the
  onboarding theme.
- `privileged + privileged-local`: `<case-id>` includes legal advice about a
  contract dispute; keep it local to `_cases/` and do not mine it for general
  knowledge without explicit approval.
- `delete-after-review + deleted`: a capture has revoked consent; record the
  deletion reason and do not promote the raw content.
