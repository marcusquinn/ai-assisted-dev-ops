"""Compatibility facade for campaign production contracts."""

from _campaign_production_brief import validate_brief
from _campaign_production_definitions import (
    ASSET_OWNERS,
    BRIEF_ID_RE,
    CAMPAIGN_ID_RE,
    CHANNELS,
    DEFAULT_FORMATS,
    JOB_ID_RE,
    SHA256_RE,
    VARIANT_ID_RE,
    ManifestError,
    ManifestRequest,
    validate_campaign_id,
)
from _campaign_production_distribution import validate_distribution_eligibility
from _campaign_production_io import atomic_json_write, digest, read_document
from _campaign_production_manifest import validate_manifest

__all__ = [
    "ASSET_OWNERS", "BRIEF_ID_RE", "CAMPAIGN_ID_RE", "CHANNELS",
    "DEFAULT_FORMATS", "JOB_ID_RE", "SHA256_RE", "VARIANT_ID_RE",
    "ManifestError", "ManifestRequest", "atomic_json_write", "digest",
    "read_document", "validate_brief", "validate_campaign_id",
    "validate_distribution_eligibility", "validate_manifest",
]
