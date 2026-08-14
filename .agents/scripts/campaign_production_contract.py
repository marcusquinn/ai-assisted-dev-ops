"""Campaign production manifest validation and persistence contract."""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Any

from performance_contract import contains_direct_identifier

CHANNELS = {"facebook", "instagram", "linkedin", "twitter", "reddit", "email", "blog", "youtube", "short-form", "social-linkedin", "social-reddit", "social-x", "podcast"}
ASSET_OWNERS = {"writing": "content/production-writing.md", "image": "content/production-image.md", "video": "content/production-video.md", "audio": "content/production-audio.md", "editor": "tools/video/video-editor.md"}
DEFAULT_FORMATS = {
    "facebook": ("image", "1:1", None), "instagram": ("image", "4:5", None),
    "linkedin": ("image", "1.91:1", None), "twitter": ("writing", "text", None),
    "email": ("writing", "text", None), "blog": ("writing", "text", None),
    "youtube": ("video", "16:9", 60), "short-form": ("video", "9:16", 30),
    "social-linkedin": ("image", "1.91:1", None), "social-reddit": ("writing", "text", None),
    "social-x": ("writing", "text", None), "reddit": ("writing", "text", None), "podcast": ("audio", "audio", 300),
}
CAMPAIGN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,127}$")
BRIEF_ID_RE = re.compile(r"^brief:[a-z0-9][a-z0-9-]{0,159}$")
JOB_ID_RE = re.compile(r"^job:[a-z0-9][a-z0-9:-]{0,240}$")
VARIANT_ID_RE = re.compile(r"^v[1-9][0-9]*$")
SHA256_RE = re.compile(r"^sha256:[a-f0-9]{64}$")


class ManifestError(ValueError):
    """Raised when a production contract cannot be created or trusted."""


def validate_campaign_id(value: Any) -> str:
    """Require a bounded campaign alias that cannot traverse filesystem paths."""
    if (
        not isinstance(value, str)
        or not CAMPAIGN_ID_RE.fullmatch(value)
        or contains_direct_identifier(value)
    ):
        raise ManifestError("campaign_id must be a bounded lowercase alias")
    return value


@dataclass(frozen=True)
class ManifestRequest:
    """Inputs needed to construct one immutable production job."""

    campaign_id: str
    brief: dict[str, Any]
    channel: str
    variant: int
    asset_class: str | None
    capability: str | None


def digest(value: Any) -> str:
    """Return a stable SHA-256 reference for JSON-compatible content."""
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def atomic_json_write(path: Path, document: dict[str, Any]) -> None:
    """Atomically write a JSON document without replacing valid state on failure."""
    if path.is_symlink() or path.parent.is_symlink() or (
        path.exists() and not path.is_file()
    ):
        raise ManifestError("production JSON destination must be a regular path")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def read_document(path: Path, label: str) -> dict[str, Any]:
    """Read one object document with a useful contract error."""
    if path.is_symlink() or not path.is_file():
        raise ManifestError(f"invalid {label}: path must be a regular non-symlink file")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise ManifestError(f"invalid {label}: {path}: {error}") from error
    if not isinstance(document, dict):
        raise ManifestError(f"invalid {label}: {path} must contain an object")
    return document


def validate_brief(document: dict[str, Any]) -> None:
    """Validate the complete canonical creative-brief schema."""
    required = {
        "schema_version", "brief_id", "campaign_id", "revision",
        "source_snapshot_sha256", "objective", "audience_insight", "message",
        "creative", "brand_references", "claims", "authenticity", "review",
        "lifecycle",
    }
    if set(document) != required or document.get("schema_version") != 1:
        raise ManifestError("creative brief is missing required schema-v1 fields")
    campaign_id = validate_campaign_id(document["campaign_id"])
    if (
        not isinstance(document["brief_id"], str)
        or not BRIEF_ID_RE.fullmatch(document["brief_id"])
        or document["brief_id"] != f"brief:{campaign_id}"
        or not isinstance(document["source_snapshot_sha256"], str)
        or not SHA256_RE.fullmatch(document["source_snapshot_sha256"])
        or not isinstance(document["revision"], int)
        or isinstance(document["revision"], bool)
        or document["revision"] < 1
    ):
        raise ManifestError("creative brief identity fields are invalid")
    object_fields = {
        "objective": ({"metric", "target"}, True),
        "audience_insight": ({"segment", "pain", "outcome"}, True),
        "message": ({"positioning", "hook", "story", "cta"}, True),
        "creative": (
            {
                "copy_direction", "script_direction", "shot_direction",
                "visual_direction", "audio_direction",
            },
            False,
        ),
    }
    for field, (keys, require_non_empty) in object_fields.items():
        value = document[field]
        if (
            not isinstance(value, dict)
            or set(value) != keys
            or any(not isinstance(item, str) for item in value.values())
            or (require_non_empty and any(not item for item in value.values()))
        ):
            raise ManifestError(f"creative brief {field} is malformed")
    brand_references = document["brand_references"]
    if (
        not isinstance(brand_references, list)
        or not brand_references
        or any(not isinstance(item, str) or not item for item in brand_references)
    ):
        raise ManifestError("creative brief brand references are malformed")
    claims = document["claims"]
    if (
        not isinstance(claims, list)
        or not claims
        or any(
            not isinstance(claim, dict)
            or set(claim) != {"claim", "evidence_reference", "approval_status"}
            or not isinstance(claim.get("claim"), str)
            or not claim.get("claim")
            or not isinstance(claim.get("evidence_reference"), str)
            or not claim.get("evidence_reference")
            or claim.get("approval_status") not in {"approved", "pending", "rejected"}
            for claim in claims
        )
    ):
        raise ManifestError("creative brief claims are malformed")
    authenticity = document["authenticity"]
    authenticity_arrays = {
        "source_requirements", "consent_requirements", "disclosure_requirements"
    }
    if (
        not isinstance(authenticity, dict)
        or set(authenticity)
        != authenticity_arrays | {"synthetic_people_or_voice", "testimonial_or_ugc_style"}
        or not isinstance(authenticity.get("synthetic_people_or_voice"), bool)
        or not isinstance(authenticity.get("testimonial_or_ugc_style"), bool)
        or any(
            not isinstance(authenticity.get(field), list)
            or any(not isinstance(item, str) for item in authenticity[field])
            for field in authenticity_arrays
        )
    ):
        raise ManifestError("creative brief authenticity fields are malformed")
    review = document["review"]
    if (
        not isinstance(review, dict)
        or set(review) != {"criteria", "owner", "status"}
        or not isinstance(review.get("criteria"), list)
        or not review.get("criteria")
        or any(not isinstance(item, str) for item in review["criteria"])
        or not isinstance(review.get("owner"), str)
        or not review.get("owner")
        or review.get("status") not in {"required", "pending", "approved", "rejected"}
    ):
        raise ManifestError("creative brief review fields are malformed")
    lifecycle = document["lifecycle"]
    if (
        not isinstance(lifecycle, dict)
        or set(lifecycle) != {"status", "asset_evidence"}
        or lifecycle.get("status") != "brief_ready"
        or lifecycle.get("asset_evidence") != []
    ):
        raise ManifestError("creative brief lifecycle must be unexecuted brief_ready")


def validate_manifest(document: dict[str, Any]) -> None:
    """Reject invalid status claims and incomplete downstream jobs."""
    required = (
        "schema_version", "job_id", "campaign_id", "brief_id", "channel",
        "variant_id", "revision", "input_snapshot_sha256", "format",
        "asset_inputs", "execution", "authenticity", "review", "experiment",
        "lifecycle", "outputs",
    )
    missing_fields = any(field not in document for field in required)
    if missing_fields or document.get("schema_version") != 1:
        raise ManifestError("manifest is missing required schema-v1 fields")
    if set(document) != set(required):
        raise ManifestError("manifest contains unsupported top-level fields")
    for field in (
        "job_id", "campaign_id", "brief_id", "channel", "variant_id",
        "input_snapshot_sha256",
    ):
        if not isinstance(document[field], str) or not document[field]:
            raise ManifestError(f"manifest {field} must be a non-empty string")
    validate_campaign_id(document["campaign_id"])
    if (
        not JOB_ID_RE.fullmatch(document["job_id"])
        or not BRIEF_ID_RE.fullmatch(document["brief_id"])
        or not VARIANT_ID_RE.fullmatch(document["variant_id"])
    ):
        raise ManifestError("manifest identity fields are invalid")
    revision = document["revision"]
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1:
        raise ManifestError("manifest revision must be a positive integer")
    for field in (
        "format", "execution", "authenticity", "review", "experiment", "lifecycle",
    ):
        if not isinstance(document[field], dict):
            raise ManifestError(f"manifest {field} must be an object")
    exact_keys = {
        "format": {"asset_class", "dimensions", "duration_seconds"},
        "execution": {"owner", "provider_route", "capability", "fallback", "status"},
        "review": {"criteria", "status", "decision_by", "decision_at"},
        "experiment": {"experiment_id", "hypothesis"},
        "lifecycle": {"status", "status_evidence"},
    }
    for field, allowed in exact_keys.items():
        if not set(document[field]) <= allowed:
            raise ManifestError(f"manifest {field} contains unsupported fields")
    if set(document["format"]) != exact_keys["format"]:
        raise ManifestError("manifest format is missing required fields")
    if set(document["execution"]) != exact_keys["execution"]:
        raise ManifestError("manifest execution is missing required fields")
    if set(document["experiment"]) != exact_keys["experiment"]:
        raise ManifestError("manifest experiment is missing required fields")
    if set(document["lifecycle"]) != exact_keys["lifecycle"]:
        raise ManifestError("manifest lifecycle is missing required fields")
    if not {"criteria", "status"} <= set(document["review"]):
        raise ManifestError("manifest review is missing required fields")
    if not set(document["authenticity"]) <= {
        "disclosure_requirements", "rights_requirements", "provenance",
        "rights_clearance",
    } or not {"disclosure_requirements", "rights_requirements"} <= set(
        document["authenticity"]
    ):
        raise ManifestError("manifest authenticity fields are invalid")
    if not isinstance(document["format"].get("asset_class"), str) or document[
        "format"
    ].get("asset_class") not in ASSET_OWNERS:
        raise ManifestError("manifest format requires a supported asset_class")
    if not isinstance(document["format"].get("dimensions"), str) or not document[
        "format"
    ].get("dimensions"):
        raise ManifestError("manifest format requires dimensions")
    duration = document["format"].get("duration_seconds")
    if duration is not None and (
        not isinstance(duration, int) or isinstance(duration, bool) or duration < 1
    ):
        raise ManifestError("manifest duration_seconds must be a positive integer")
    execution = document["execution"]
    if (
        not isinstance(execution.get("owner"), str)
        or not execution.get("owner")
        or not isinstance(execution.get("capability"), str)
        or not execution.get("capability")
        or not isinstance(execution.get("status"), str)
        or execution.get("status") not in {"capability_required", "blocked", "ready"}
        or not all(
            value is None or isinstance(value, str)
            for value in (execution.get("provider_route"), execution.get("fallback"))
        )
    ):
        raise ManifestError("manifest execution fields are invalid")
    if not all(
        isinstance(document["authenticity"].get(field), list)
        and all(isinstance(item, str) for item in document["authenticity"][field])
        for field in ("disclosure_requirements", "rights_requirements")
    ):
        raise ManifestError("manifest authenticity requirements must be arrays")
    provenance = document["authenticity"].get("provenance")
    if provenance is not None and (
        not isinstance(provenance, dict)
        or set(provenance) != {"source", "recipe_sha256"}
        or not isinstance(provenance.get("source"), str)
        or not provenance.get("source")
        or not isinstance(provenance.get("recipe_sha256"), str)
        or not SHA256_RE.fullmatch(provenance["recipe_sha256"])
    ):
        raise ManifestError("manifest provenance fields are invalid")
    clearance = document["authenticity"].get("rights_clearance")
    if clearance is not None and (
        not isinstance(clearance, dict)
        or set(clearance) != {"license", "consent", "territory", "expires_at"}
        or any(
            not isinstance(clearance.get(field), str) or not clearance.get(field)
            for field in ("license", "consent", "territory")
        )
        or (
            clearance.get("expires_at") is not None
            and not isinstance(clearance.get("expires_at"), str)
        )
    ):
        raise ManifestError("manifest rights-clearance fields are invalid")
    if clearance and clearance.get("expires_at"):
        try:
            date.fromisoformat(clearance["expires_at"])
        except ValueError as error:
            raise ManifestError(
                "manifest rights-clearance expiry must be an ISO date"
            ) from error
    if (
        not isinstance(document["review"].get("criteria"), list)
        or not document["review"].get("criteria")
        or not all(isinstance(item, str) for item in document["review"]["criteria"])
        or not isinstance(document["review"].get("status"), str)
        or document["review"].get("status")
        not in {"required", "pending", "approved", "rejected"}
    ):
        raise ManifestError("manifest review fields are invalid")
    decision_by = document["review"].get("decision_by")
    decision_at = document["review"].get("decision_at")
    if decision_by is not None and (
        not isinstance(decision_by, str) or not decision_by
    ):
        raise ManifestError("manifest review decision_by is invalid")
    if decision_at is not None:
        if not isinstance(decision_at, str) or not decision_at:
            raise ManifestError("manifest review decision_at is invalid")
        try:
            parsed_decision = datetime.fromisoformat(decision_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ManifestError("manifest review decision_at is invalid") from error
        if parsed_decision.tzinfo is None:
            raise ManifestError("manifest review decision_at requires a timezone")
    if not all(
        isinstance(document["experiment"].get(field), str)
        and document["experiment"].get(field)
        for field in ("experiment_id", "hypothesis")
    ):
        raise ManifestError("manifest experiment fields are invalid")
    if not isinstance(document["lifecycle"].get("status_evidence"), list) or not all(
        isinstance(item, str) for item in document["lifecycle"]["status_evidence"]
    ):
        raise ManifestError("manifest lifecycle evidence must be an array")
    if not isinstance(document["asset_inputs"], list) or any(
        not isinstance(asset_input, dict)
        or set(asset_input) != {"reference", "required"}
        or not isinstance(asset_input.get("reference"), str)
        or not asset_input.get("reference")
        or not isinstance(asset_input.get("required"), bool)
        for asset_input in document["asset_inputs"]
    ):
        raise ManifestError("manifest asset_inputs must contain reference objects")
    if not isinstance(document["outputs"], list) or any(
        not isinstance(output, dict)
        or set(output) != {"path", "sha256", "media_type"}
        or not isinstance(output.get("path"), str)
        or not output.get("path")
        or not isinstance(output.get("sha256"), str)
        or not output.get("sha256")
        or not isinstance(output.get("media_type"), str)
        or not output.get("media_type")
        for output in document["outputs"]
    ):
        raise ManifestError(
            "manifest outputs must contain path, sha256, and media_type objects"
        )
    if document["channel"] not in CHANNELS:
        raise ManifestError("manifest has an unsupported channel")
    if not SHA256_RE.fullmatch(document["input_snapshot_sha256"]):
        raise ManifestError("manifest input snapshot must be a SHA-256 reference")
    if any(not SHA256_RE.fullmatch(output["sha256"]) for output in document["outputs"]):
        raise ManifestError("manifest output hashes must be SHA-256 references")
    status, outputs = document["lifecycle"].get("status"), document["outputs"]
    completed_statuses = {"generated", "edited", "approved"}
    incomplete_statuses = {"brief_ready", "prompts_ready", "queued", "running", "blocked"}
    valid_statuses = completed_statuses | incomplete_statuses | {
        "review_required", "rejected", "failed"
    }
    if not isinstance(status, str) or status not in valid_statuses:
        raise ManifestError("manifest lifecycle status is unsupported")
    if status in completed_statuses and not outputs:
        raise ManifestError(f"manifest status {status} requires verified outputs")
    if status in incomplete_statuses and outputs:
        raise ManifestError(f"manifest status {status} must not claim completed outputs")
    if status == "blocked" and document["execution"].get("status") != "blocked":
        raise ManifestError("blocked lifecycle requires an explicit blocked execution route")


def _file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def _require_approved_review(document: dict[str, Any]) -> None:
    review = document["review"]
    if (
        review.get("status") != "approved"
        or not isinstance(review.get("decision_by"), str)
        or not review.get("decision_by")
        or not isinstance(review.get("decision_at"), str)
        or not review.get("decision_at")
    ):
        raise ManifestError("production manifest requires an attributed approved review")


def _require_rights_and_provenance(document: dict[str, Any]) -> None:
    authenticity = document["authenticity"]
    provenance, clearance = authenticity.get("provenance"), authenticity.get("rights_clearance")
    if not isinstance(provenance, dict) or not all(
        isinstance(provenance.get(field), str) and provenance.get(field)
        for field in ("source", "recipe_sha256")
    ):
        raise ManifestError("production manifest requires source provenance and a recipe hash")
    if not isinstance(clearance, dict) or any(
        not isinstance(clearance.get(field), str) or not clearance.get(field)
        for field in ("license", "consent", "territory")
    ):
        raise ManifestError("production manifest requires license, consent, and territory clearance")
    expires_at = clearance.get("expires_at")
    if expires_at is not None and not isinstance(expires_at, str):
        raise ManifestError("production manifest rights expiry must be an ISO date")
    try:
        if expires_at and date.fromisoformat(expires_at) < date.today():
            raise ManifestError("production manifest rights clearance has expired")
    except ValueError as error:
        raise ManifestError("production manifest rights expiry must be an ISO date") from error


def _verify_outputs(outputs: list[dict[str, Any]], campaign_dir: Path) -> None:
    root = campaign_dir.resolve()
    for output in outputs:
        relative = Path(output["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ManifestError("production manifest output path is unsafe")
        candidate = root
        for component in relative.parts:
            candidate /= component
            if candidate.is_symlink():
                raise ManifestError(
                    "production manifest output path must not contain symlinks"
                )
        output_path = candidate.resolve()
        if root not in output_path.parents or not output_path.is_file():
            raise ManifestError("production manifest output is missing or outside the campaign directory")
        if _file_digest(output_path) != output["sha256"]:
            raise ManifestError("production manifest output hash does not match recorded evidence")


def validate_distribution_eligibility(document: dict[str, Any], campaign_dir: Path) -> None:
    """Fail closed unless a completed output has review, rights, and provenance evidence."""
    validate_manifest(document)
    if document["campaign_id"] != campaign_dir.name:
        raise ManifestError("production manifest campaign_id does not match its campaign directory")
    if document["brief_id"] != f"brief:{document['campaign_id']}":
        raise ManifestError("production manifest brief_id does not match its campaign")
    if document["job_id"] != (
        f"job:{document['campaign_id']}:{document['channel']}:{document['variant_id']}"
    ):
        raise ManifestError("production manifest job_id does not match its campaign")
    drafts_dir = campaign_dir / "drafts"
    if drafts_dir.is_symlink() or not drafts_dir.is_dir():
        raise ManifestError("campaign drafts directory must be a regular directory")
    brief = read_document(drafts_dir / "creative-brief-v1.json", "creative brief")
    validate_brief(brief)
    if brief["brief_id"] != document["brief_id"]:
        raise ManifestError("production manifest does not match the current creative brief")
    if brief["campaign_id"] != document["campaign_id"]:
        raise ManifestError("creative brief campaign_id does not match its campaign")
    expected_snapshot = digest(
        {
            "brief": digest(brief),
            "channel": document["channel"],
            "variant": int(document["variant_id"][1:]),
            "asset_class": document["format"]["asset_class"],
        }
    )
    if document["input_snapshot_sha256"] != expected_snapshot:
        raise ManifestError("production manifest input snapshot is stale")
    if document["lifecycle"].get("status") != "approved":
        raise ManifestError("production manifest lifecycle must be approved before distribution")
    _require_approved_review(document)
    _require_rights_and_provenance(document)
    _verify_outputs(document["outputs"], campaign_dir)
