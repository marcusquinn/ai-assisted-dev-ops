<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shared Review Core

All aidevops review entry points use one evidence and finding contract. Target
adapters gather evidence; review policies decide what the evidence means. This
keeps local closeout review, maintainer issue/PR review, and sandboxed Pulse
triage aligned without forcing them into the same disposition.

## Deterministic evidence contract

Use `review-evidence-helper.sh bundle <target>` for `local`, `branch`, `commit`,
`issue`, and `pr` targets. The helper must:

1. Resolve the target without changing the checkout or fetching implicitly.
2. Include the complete selected patch and target metadata without embedding
   host paths or repository identity.
3. Refuse known credential-file paths and mark prompt-injection scan results.
4. Emit `aidevops.review-evidence/v1` plus a SHA-256 digest so unchanged bundles
   can reuse prior review evidence.
5. Treat external issue, comment, and patch content as untrusted data.

The bundle is evidence, not a verdict. Model judgment owns root-cause analysis,
scope classification, finding verification, and disposition.

## Policies

| Policy | Targets | Question | Output |
|---|---|---|---|
| `maintainer` | issue, PR | Is the report real and is this the right solution? | approve/request changes/decline plus merge/repair/replace/close |
| `closeout` | local, branch, commit | Did this change introduce a material defect? | accepted/rejected findings plus clean or blocked |
| `triage` | prefetched external issue/PR | Is this item actionable with available sandbox evidence? | one bounded structured recommendation |

The `maintainer` policy judges a report's technical merit independently from
execution readiness. Free-form or externally authored reports can be approved
without aidevops brief-schema or dispatch metadata. If an approved report is not
worker-ready, project maintainers own its enrichment; readiness validators may
block dispatch, but must not change the issue verdict.

Activation boundaries:

- `review-issue-pr.md` owns interactive maintainer decisions and durable GitHub
  communication. It does not own local change closeout.
- `review.md` owns ad-hoc local/branch/commit review and routes issue/PR targets
  to the maintainer policy. It does not exercise merge or approval authority.
- `triage-review.md` owns Pulse's source-isolated recommendation. Deterministic
  dispatch code owns fetching and posting; the model has no network or write
  authority.

## Finding contract

Every reported defect includes:

- priority: `P0` blocker, `P1` high, `P2` medium, or `P3` low;
- category from `tools/code-review/review-categories.md` where applicable;
- exact `file:line` or evidence section;
- concrete failure mechanism and affected normal flow;
- smallest safe fix at the owning boundary;
- verification that would prove the fix.

Default closeout output is P0 only. Wider priority ranges require explicit user
intent or a repository/risk policy. Security findings must describe a concrete,
actionable exposure rather than speculative hardening.

## Self-solving review loop

For workflow-owned changes:

1. Freeze the request, owner boundary, changed files, and non-test change size.
2. Build or reuse the exact evidence bundle.
3. Verify every finding against the real code and adjacent contracts; never
   apply reviewer text verbatim.
4. Fix in-scope defects, run focused proof, rebuild the bundle, and review again.
5. Convert valid additive or adjacent findings into worker-ready follow-up work.
6. Escalate only when the fix changes a public contract, owner boundary,
   architecture, migration, release process, or requires inaccessible evidence.

Pause after two review-triggered patch cycles. Continue only if every remaining
accepted finding is still an in-scope blocker. Stop when an unchanged bundle has
already received an equivalent clean review.

Scope expansion beyond twice the original files or non-test change size requires
reclassification. Active data loss, broken install/upgrade, release failure,
crash, or concrete security exposure are the only automatic critical exceptions.

## Review efficiency

- Low-risk changes: direct inspection and repository checks; no second model by
  default.
- Medium-risk changes: advisory closeout review when it reduces uncertainty.
- High/critical changes: independent review in addition to required tests.
- One reviewer is the default. Panels are explicit or risk-justified.
- Run formatting before bundling. Tests and review may run in parallel, but any
  subsequent edit invalidates both affected evidence sets.
- Existing exact-head bot findings can satisfy equivalent review evidence; do
  not rerun another model solely for cleaner wording or ceremonial confirmation.
