"""Shared synthetic campaign production fixtures."""

from __future__ import annotations

from typing import Any


def approved_manifest(
    campaign_id: str,
    input_snapshot: str,
    output_digest: str,
    **options: str,
) -> dict[str, Any]:
    """Build one reviewed writing manifest for contract tests."""
    decision_at = options.get("decision_at", "2026-08-08T00:00:00Z")
    experiment_id = options.get("experiment_id", "experiment-1")
    hypothesis = options.get("hypothesis", "synthetic fixture")
    return {
        "schema_version": 1,
        "job_id": f"job:{campaign_id}:twitter:v1",
        "campaign_id": campaign_id,
        "brief_id": f"brief:{campaign_id}",
        "channel": "twitter",
        "variant_id": "v1",
        "revision": 1,
        "input_snapshot_sha256": input_snapshot,
        "format": {"asset_class": "writing", "dimensions": "text", "duration_seconds": None},
        "asset_inputs": [],
        "execution": {"owner": "content", "provider_route": None, "capability": "writing", "fallback": None, "status": "ready"},
        "authenticity": {
            "disclosure_requirements": [],
            "rights_requirements": [],
            "provenance": {"source": "owned", "recipe_sha256": "sha256:" + "b" * 64},
            "rights_clearance": {"license": "owned", "consent": "documented", "territory": "global", "expires_at": None},
        },
        "review": {"criteria": ["reviewed"], "status": "approved", "decision_by": "owner", "decision_at": decision_at},
        "experiment": {"experiment_id": experiment_id, "hypothesis": hypothesis},
        "lifecycle": {"status": "approved", "status_evidence": ["reviewed"]},
        "outputs": [{"path": "creative/post.txt", "sha256": output_digest, "media_type": "text/plain"}],
    }
