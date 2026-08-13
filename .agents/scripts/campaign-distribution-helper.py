#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bridge reviewed campaign outputs to the approval-bound social queue.

This producer validates reviewed campaign evidence, creates one stable queue draft,
and projects queue receipts.  It has no provider implementation or run command.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from campaign_production_contract import ManifestError, read_document, validate_distribution_eligibility

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_QUEUE_HELPER = SCRIPT_DIR / "knowledge-social-helper.sh"
CHANNELS = {
    "x": {"aliases": {"x", "twitter", "social-x"}, "provider": "xapi"},
    "reddit": {"aliases": {"reddit", "social-reddit"}, "provider": "reddit"},
}
PUBLIC_STATES = {"draft", "approved", "claimed", "unknown", "failed", "succeeded", "cancelled"}


class DistributionError(ValueError):
    """Raised when a campaign cannot safely become an outbound intent."""


def _canonical_channel(channel: str) -> str:
    for canonical, values in CHANNELS.items():
        if channel in values["aliases"]:
            return canonical
    raise DistributionError("channel must be x or reddit (aliases: twitter, social-x, social-reddit)")


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _campaign_dir(value: str) -> Path:
    path = Path(value).resolve()
    if not path.is_dir():
        raise DistributionError("campaign directory is unavailable")
    return path


def _safe_output(campaign_dir: Path, manifest: dict[str, Any], requested: str | None) -> Path:
    outputs = manifest["outputs"]
    if requested is None:
        if len(outputs) != 1:
            raise DistributionError("select one reviewed output with --output")
        requested = outputs[0]["path"]
    output = (campaign_dir / requested).resolve()
    if campaign_dir not in output.parents or not output.is_file():
        raise DistributionError("distribution output is missing or outside its campaign")
    matching = next((entry for entry in outputs if entry["path"] == requested), None)
    if matching is None:
        raise DistributionError("selected output is not recorded by the approved manifest")
    digest = "sha256:" + hashlib.sha256(output.read_bytes()).hexdigest()
    if digest != matching["sha256"]:
        raise DistributionError("selected output no longer matches approved evidence")
    return output


def _source(arguments: argparse.Namespace) -> tuple[Path, dict[str, Any], Path, str, str, str]:
    campaign_dir = _campaign_dir(arguments.campaign_dir)
    manifest_path = Path(arguments.manifest).resolve()
    if campaign_dir not in manifest_path.parents:
        raise DistributionError("production manifest must be inside its campaign")
    manifest = read_document(manifest_path, "production manifest")
    validate_distribution_eligibility(manifest, campaign_dir)
    channel = _canonical_channel(arguments.channel or str(manifest["channel"]))
    output = _safe_output(campaign_dir, manifest, arguments.output)
    scheduled_at = int(arguments.scheduled_at)
    if scheduled_at < 0:
        raise DistributionError("scheduled_at must be a non-negative epoch")
    source_id = f"campaign:{manifest['campaign_id']}:{manifest['variant_id']}:{channel}"
    intent_key = _digest({
        "source_id": source_id, "channel": channel, "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "scheduled_at": scheduled_at, "connection_id": arguments.connection_id, "account_id": arguments.account_id,
        "destination_id": getattr(arguments, "destination_id", None),
        "subject_sha256": (
            hashlib.sha256(Path(arguments.subject).read_bytes()).hexdigest()
            if getattr(arguments, "subject", None) and Path(arguments.subject).is_file()
            else None
        ),
    })
    return campaign_dir, manifest, output, channel, source_id, intent_key


def _operation_id(source_id: str, intent_key: str) -> str:
    return "op_campaign_" + hashlib.sha256(f"{source_id}:{intent_key}".encode()).hexdigest()[:32]


def _record_path(campaign_dir: Path, source_id: str) -> Path:
    return campaign_dir / "distribution" / (hashlib.sha256(source_id.encode()).hexdigest() + ".json")


def _write_record(campaign_dir: Path, record: dict[str, Any]) -> None:
    destination = _record_path(campaign_dir, record["source_id"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)


def _queue(arguments: argparse.Namespace, command: list[str]) -> Any:
    helper = Path(arguments.queue_helper).resolve()
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise DistributionError("outbound queue helper is unavailable")
    # The executable is a locally resolved, executable queue helper; command values
    # are passed as a fixed argument vector rather than through a shell.
    result = subprocess.run(  # nosec B603
        [str(helper), *command], text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        raise DistributionError(f"outbound queue rejected operation: {result.stderr.strip() or result.stdout.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DistributionError("outbound queue returned invalid receipt metadata") from error


def _project_calendar(arguments: argparse.Namespace, record: dict[str, Any]) -> None:
    if not arguments.calendar_db:
        return
    if arguments.calendar_schedule_id is None:
        raise DistributionError("--calendar-db requires --calendar-schedule-id")
    database = sqlite3.connect(arguments.calendar_db)
    try:
        database.execute(
            "UPDATE schedule SET distribution_id=?,operation_id=?,operation_state=?,remote_id=? WHERE id=?",
            (record["source_id"], record["operation_id"], record["status"], record.get("provider_remote_id"), arguments.calendar_schedule_id),
        )
        if database.total_changes != 1:
            raise DistributionError("calendar schedule is unavailable")
        database.commit()
    finally:
        database.close()


def _record(arguments: argparse.Namespace, state: str, receipt: dict[str, Any] | None = None) -> dict[str, Any]:
    campaign_dir, manifest, _output, channel, source_id, intent_key = _source(arguments)
    record = {
        "version": 1, "source_id": source_id, "campaign_id": manifest["campaign_id"], "channel": channel,
        "operation_id": _operation_id(source_id, intent_key), "intent_key": intent_key,
        "scheduled_at": int(arguments.scheduled_at), "status": state, "provider_remote_id": None,
        "updated_at": int(time.time()),
    }
    if receipt:
        record["status"] = receipt.get("state", state)
        record["provider_remote_id"] = receipt.get("provider_remote_id")
    if record["status"] not in PUBLIC_STATES | {"preview"}:
        raise DistributionError("outbound queue returned an unsupported operation state")
    _write_record(campaign_dir, record)
    _project_calendar(arguments, record)
    return record


def command_preview(arguments: argparse.Namespace) -> int:
    campaign_dir, manifest, _output, channel, source_id, intent_key = _source(arguments)
    del campaign_dir
    record = {
        "version": 1, "source_id": source_id, "campaign_id": manifest["campaign_id"], "channel": channel,
        "operation_id": _operation_id(source_id, intent_key), "intent_key": intent_key,
        "scheduled_at": int(arguments.scheduled_at), "status": "preview", "provider_remote_id": None,
        "updated_at": int(time.time()),
    }
    # Preview is intentionally non-mutating: it does not write a record, calendar
    # row, queue operation, approval, or invoke a provider.
    print(json.dumps(record, sort_keys=True))
    return 0


def _private_copy(output: Path) -> Path:
    descriptor, name = tempfile.mkstemp(prefix="campaign-distribution-", text=True)
    path = Path(name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(output.read_bytes())
        return path
    except BaseException:
        os.close(descriptor)
        path.unlink(missing_ok=True)
        raise


def command_enqueue(arguments: argparse.Namespace) -> int:
    campaign_dir, _manifest, output, channel, source_id, intent_key = _source(arguments)
    operation_id = _operation_id(source_id, intent_key)
    body = _private_copy(output)
    try:
        command = ["operation-create", "--alias", arguments.alias, "--connection-id", arguments.connection_id,
                   "--account-id", arguments.account_id, "--action", "post", "--body-file", str(body),
                   "--scheduled-at", str(arguments.scheduled_at), "--operation-id", operation_id]
        if arguments.base:
            command.extend(["--base", arguments.base])
        if channel == "reddit":
            if not arguments.destination_id or not arguments.subject:
                raise DistributionError("Reddit distribution requires --destination-id and --subject")
            subject = _private_copy(Path(arguments.subject)) if Path(arguments.subject).is_file() else None
            if subject is None:
                raise DistributionError("Reddit --subject must name a reviewed private subject file")
            try:
                command.extend(["--destination-id", arguments.destination_id, "--subject-file", str(subject)])
                receipt = _queue(arguments, command)
            finally:
                subject.unlink(missing_ok=True)
        else:
            receipt = _queue(arguments, command)
    finally:
        body.unlink(missing_ok=True)
    if arguments.approve_until is not None:
        if arguments.approve_until <= int(time.time()):
            raise DistributionError("--approve-until must be a future epoch")
        approval = ["operation-approve", "--alias", arguments.alias, "--operation-id", operation_id,
                    "--expires-at", str(arguments.approve_until)]
        if arguments.base:
            approval.extend(["--base", arguments.base])
        receipt = _queue(arguments, approval)
    record = _record(arguments, receipt["state"], receipt)
    print(json.dumps(record, sort_keys=True))
    return 0


def command_status(arguments: argparse.Namespace) -> int:
    campaign_dir, _manifest, _output, _channel, source_id, intent_key = _source(arguments)
    operation_id = _operation_id(source_id, intent_key)
    command = ["operations-list", "--alias", arguments.alias, "--operation-id", operation_id]
    if arguments.base:
        command.extend(["--base", arguments.base])
    result = _queue(arguments, command)
    if not result:
        raise DistributionError("outbound operation is unavailable")
    record = _record(arguments, result[0]["state"], result[0])
    print(json.dumps(record, sort_keys=True))
    return 0


def command_reconcile(arguments: argparse.Namespace) -> int:
    _campaign_dir, _manifest, _output, _channel, source_id, intent_key = _source(arguments)
    command = ["operation-reconcile", "--alias", arguments.alias, "--operation-id", _operation_id(source_id, intent_key),
               "--outcome", arguments.outcome]
    if arguments.provider_id:
        command.extend(["--provider-id", arguments.provider_id])
    if arguments.base:
        command.extend(["--base", arguments.base])
    receipt = _queue(arguments, command)
    record = _record(arguments, receipt["state"], receipt)
    print(json.dumps(record, sort_keys=True))
    return 0


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--campaign-dir", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--channel")
    parser.add_argument("--output")
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--scheduled-at", type=int, required=True)
    parser.add_argument("--alias", default="workspace:default")
    parser.add_argument("--base")
    parser.add_argument("--calendar-db")
    parser.add_argument("--calendar-schedule-id", type=int)
    parser.add_argument("--queue-helper", default=str(DEFAULT_QUEUE_HELPER))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preview = commands.add_parser("preview")
    _common(preview)
    preview.set_defaults(handler=command_preview)
    enqueue = commands.add_parser("enqueue")
    _common(enqueue)
    enqueue.add_argument("--destination-id")
    enqueue.add_argument("--subject")
    enqueue.add_argument("--approve-until", type=int)
    enqueue.set_defaults(handler=command_enqueue)
    status = commands.add_parser("status")
    _common(status)
    status.set_defaults(handler=command_status)
    reconcile = commands.add_parser("reconcile")
    _common(reconcile)
    reconcile.add_argument("--outcome", choices=("succeeded", "not-sent"), required=True)
    reconcile.add_argument("--provider-id")
    reconcile.set_defaults(handler=command_reconcile)
    arguments = parser.parse_args()
    return arguments.handler(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DistributionError, ManifestError) as error:
        print(f"campaign distribution: {error}", file=sys.stderr)
        raise SystemExit(1)
