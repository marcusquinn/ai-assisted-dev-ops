#!/usr/bin/env python3
"""Create, list, and validate truthful campaign production manifests."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from campaign_production_contract import (
    ASSET_OWNERS, CHANNELS, DEFAULT_FORMATS, ManifestError, ManifestRequest,
    atomic_json_write, digest, read_document, validate_brief,
    validate_distribution_eligibility, validate_manifest,
)

def build_brief(campaign_id: str, intake: dict[str, Any], revision: int) -> dict[str, Any]:
    """Convert validated intake facts to one evidence-linked strategy brief."""
    audience = intake["audiences"][0]
    objective = intake["objectives"][0]
    snapshot = digest({"intake": intake, "revision": revision})
    disclosures = list(intake.get("disclosures", []))
    return {
        "schema_version": 1, "brief_id": f"brief:{campaign_id}", "campaign_id": campaign_id, "revision": revision,
        "source_snapshot_sha256": snapshot, "objective": objective,
        "audience_insight": {"segment": audience["segment"], "pain": audience["pains"][0] if audience["pains"] else "Unspecified pain", "outcome": audience["outcomes"][0] if audience["outcomes"] else "Unspecified outcome"},
        "message": {"positioning": intake["positioning"]["statement"], "hook": intake["positioning"]["differentiators"][0] if intake["positioning"]["differentiators"] else intake["positioning"]["statement"], "story": intake["product"]["description"], "cta": intake["offer"]["summary"]},
        "creative": {"copy_direction": "Use proof-linked, channel-native language without unsupported claims.", "script_direction": "Show the audience problem, evidence-backed resolution, and stated offer.", "shot_direction": "Use supplied brand and product references; do not imply real customer endorsement.", "visual_direction": "Follow the referenced brand identity and retain source provenance.", "audio_direction": "Use licensed or owned audio only; disclose synthetic voice where required."},
        "brand_references": [intake["brand"]["reference"]], "claims": intake["proof"],
        "authenticity": {"synthetic_people_or_voice": False, "testimonial_or_ugc_style": False, "source_requirements": ["Proof claims must retain their evidence reference."], "consent_requirements": ["Obtain documented consent before depicting identifiable people or voices."], "disclosure_requirements": disclosures + ["Disclose synthetic people, voices, testimonials, or UGC-style creative before review."]},
        "review": {"criteria": ["Brand reference followed", "Every claim has evidence", "Rights and disclosure requirements are satisfied"], "owner": intake["approvals"]["owner"], "status": "required"},
        "lifecycle": {"status": "brief_ready", "asset_evidence": []},
    }


def build_manifest(request: ManifestRequest) -> dict[str, Any]:
    """Build an unexecuted job without guessing a provider or asset completion."""
    campaign_id = request.campaign_id
    brief = request.brief
    channel = request.channel
    variant = request.variant
    asset_class = request.asset_class
    capability = request.capability
    default_asset, dimensions, duration = DEFAULT_FORMATS[channel]
    asset_class = asset_class or default_asset
    if asset_class not in ASSET_OWNERS:
        raise ManifestError(f"unsupported asset class: {asset_class}")
    is_supported = capability in (None, "", asset_class)
    execution_status = "capability_required" if is_supported else "blocked"
    status = "brief_ready" if is_supported else "blocked"
    snapshot = digest({"brief": brief["source_snapshot_sha256"], "channel": channel, "variant": variant, "asset_class": asset_class})
    return {
        "schema_version": 1, "job_id": f"job:{campaign_id}:{channel}:v{variant}", "campaign_id": campaign_id, "brief_id": brief["brief_id"], "channel": channel, "variant_id": f"v{variant}", "revision": 1, "input_snapshot_sha256": snapshot,
        "format": {"asset_class": asset_class, "dimensions": dimensions, "duration_seconds": duration},
        "asset_inputs": [{"reference": reference, "required": True} for reference in brief["brand_references"]],
        "execution": {"owner": ASSET_OWNERS[asset_class], "provider_route": None, "capability": asset_class, "fallback": "Route through content/media-generation-providers.md after current capability evidence is available.", "status": execution_status},
        "authenticity": {"disclosure_requirements": brief["authenticity"]["disclosure_requirements"], "rights_requirements": ["Record source, licence, consent, and rights evidence before approving an output."]},
        "review": {"criteria": brief["review"]["criteria"], "status": "required"},
        "experiment": {"experiment_id": f"experiment:{campaign_id}:{channel}:v{variant}", "hypothesis": f"The {brief['message']['hook']} hook improves {brief['objective']['metric']} for {brief['audience_insight']['segment']}."},
        "lifecycle": {"status": status, "status_evidence": ["Creative brief created; no prompt or asset has been executed."] if is_supported else [f"Requested capability {capability} does not satisfy required {asset_class} capability."]}, "outputs": [],
    }


def command_create(arguments: argparse.Namespace) -> int:
    """Create idempotent brief and job records for a selected campaign variant."""
    campaign_dir = Path(arguments.repo).resolve() / "_campaigns" / "active" / arguments.campaign_id
    intake = read_document(campaign_dir / "intake.json", "campaign intake")
    if arguments.channel not in intake.get("channels", []):
        raise ManifestError("channel must be declared by the campaign intake")
    brief_path = campaign_dir / "drafts" / "creative-brief-v1.json"
    brief = build_brief(arguments.campaign_id, intake, 1)
    if brief_path.exists():
        existing = read_document(brief_path, "creative brief")
        validate_brief(existing)
        if existing.get("source_snapshot_sha256") == brief["source_snapshot_sha256"]:
            brief = existing
        else:
            brief["revision"] = int(existing.get("revision", 0)) + 1
            brief["source_snapshot_sha256"] = digest({"intake": intake, "revision": brief["revision"]})
            atomic_json_write(brief_path, brief)
    else:
        atomic_json_write(brief_path, brief)
    manifest = build_manifest(ManifestRequest(
        arguments.campaign_id, brief, arguments.channel, arguments.variant,
        arguments.asset_class, arguments.capability,
    ))
    manifest_path = campaign_dir / "drafts" / "production-manifests" / f"{arguments.channel}-v{arguments.variant}.json"
    if manifest_path.exists():
        existing = read_document(manifest_path, "production manifest")
        validate_manifest(existing)
        if existing.get("input_snapshot_sha256") == manifest["input_snapshot_sha256"]:
            print(f"Campaign production manifest unchanged: {manifest_path}")
            return 0
    atomic_json_write(manifest_path, manifest)
    print(f"Campaign creative brief written: {brief_path}")
    print(f"Campaign production manifest written: {manifest_path}")
    return 0


def command_list(arguments: argparse.Namespace) -> int:
    """List recorded jobs without inferring work from prompt files."""
    directory = Path(arguments.repo).resolve() / "_campaigns" / "active" / arguments.campaign_id / "drafts" / "production-manifests"
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        document = read_document(path, "production manifest")
        validate_manifest(document)
        print(f"{document['job_id']}\t{document['lifecycle']['status']}\t{path}")
    return 0


def command_validate(arguments: argparse.Namespace) -> int:
    """Validate a standalone manifest before a downstream owner consumes it."""
    document = read_document(Path(arguments.manifest), "production manifest")
    validate_manifest(document)
    print(f"Valid production manifest: {arguments.manifest}")
    return 0


def command_eligibility(arguments: argparse.Namespace) -> int:
    """Validate every recorded job before campaign launch or promotion."""
    campaign_dir = Path(arguments.campaign_dir).resolve()
    directory = campaign_dir / "drafts" / "production-manifests"
    manifests = sorted(directory.glob("*.json")) if directory.is_dir() else []
    if not manifests:
        raise ManifestError("no production manifests exist; distribution is fail-closed")
    for path in manifests:
        validate_distribution_eligibility(read_document(path, "production manifest"), campaign_dir)
    print(f"Campaign production eligible: {campaign_dir}")
    return 0


def main() -> int:
    """Parse the narrow campaign production contract CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("campaign_id")
    create.add_argument("--channel", required=True, choices=sorted(CHANNELS))
    create.add_argument("--variant", type=int, default=1)
    create.add_argument("--asset-class", choices=sorted(ASSET_OWNERS))
    create.add_argument("--capability")
    create.add_argument("--repo", default=".")
    create.set_defaults(handler=command_create)
    listing = commands.add_parser("list")
    listing.add_argument("campaign_id")
    listing.add_argument("--repo", default=".")
    listing.set_defaults(handler=command_list)
    validate = commands.add_parser("validate")
    validate.add_argument("manifest")
    validate.set_defaults(handler=command_validate)
    eligibility = commands.add_parser("eligibility")
    eligibility.add_argument("campaign_dir")
    eligibility.set_defaults(handler=command_eligibility)
    arguments = parser.parse_args()
    if getattr(arguments, "variant", 1) < 1:
        raise ManifestError("variant must be a positive integer")
    return arguments.handler(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        print(f"campaign production: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
