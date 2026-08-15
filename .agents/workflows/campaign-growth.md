<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Campaign Growth Workflow

Use this workflow when a user needs one evidence-backed campaign lifecycle across
research, content, approved distribution, performance, and recommendations.

## Start with a safe plan

```bash
aidevops campaign grow plan --intake intake.json
```

The plan accepts the existing schema-v1 intake and is dry-run only. It names the
channels, required approvals, expected owner artifacts, capability fallbacks, and
metrics path. It does not create a campaign, draft content, contact a provider, or
change a budget, audience, offer, or account.

## Owner evidence and checkpoint

After `campaign new` has created an active campaign, owners may supply bounded
evidence to the orchestrator:

```json
{
  "version": 1,
  "stages": {
    "research": {"status": "succeeded", "evidence": ["research/dossier.json"]},
    "production": {"status": "succeeded", "evidence": ["creative/x-v1.md"]},
    "review": {"status": "succeeded", "evidence": ["review/approved.json"]},
    "distribution": {"status": "succeeded", "approval": "approved", "evidence": ["distribution/x-receipt.json"], "operation_ids": ["op_example"]},
    "performance": {"status": "partial", "evidence": ["metrics/funnel.json"]}
  }
}
```

Run `aidevops campaign grow start <id> --repo <repo> --evidence <file>` to write
only the atomic orchestration checkpoint. `status` derives state without writing;
`resume` recomputes from the supplied owner evidence and preserves the generation
when its evidence hash and operation IDs are unchanged.

## Approval and recovery boundaries

- Claims, creative, publishing/outreach, budgets, audiences, offers, and provider
  accounts remain separately approved by their owners.
- Missing or expired distribution approval produces `review_required`; no queue or
  provider action is attempted.
- `unknown` provider outcomes retain their stable operation IDs for owner
  reconciliation. Never retry an unknown remote action as a new action.
- `partial`, suppressed, stale, or insufficient performance evidence remains
  partial and cannot create a recommendation success.
- Unsupported capability and unhealthy provider states use the reported fallback:
  evidence-only/manual handoff or gated-no-mutation.

## Specialist ownership

- Research: `campaign research` and the research dossier contract.
- Creative: `campaign production` and Content review evidence.
- Distribution: `campaign distribution` and social provider health/queue receipts.
- Metrics: `aidevops performance ingest-campaign`.
- Reports and recommendations: `marketing-optimization-helper.py` and
  `reports/marketing.md`.
