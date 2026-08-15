#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hermetic contracts for privacy-safe marketing optimization projections."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from marketing_attribution import _last_touch_key, build_attribution  # noqa: E402
from marketing_attribution_validation import validate_attribution_artifact  # noqa: E402
from growth_recommendations import (  # noqa: E402
    RecommendationPolicy,
    _build_recommendations_from_resolved_report as build_recommendations,
)
from growth_recommendation_validation import validate_recommendation_artifact  # noqa: E402
from marketing_experiment import (  # noqa: E402
    ExperimentAnalysisRequest,
    analyze_experiment,
    record_experiment_decision,
    register_experiment,
)
from marketing_experiment_analysis_registry import registered_analysis  # noqa: E402
from marketing_experiment_evidence import experiment_run_reference  # noqa: E402
from marketing_optimization_artifact_registry import (  # noqa: E402
    build_registered_recommendations,
    build_registered_report,
    registered_attribution,
    registered_recommendation,
    registered_report,
)
from marketing_optimization_test_support import (  # noqa: E402
    ACCOUNT,
    AS_OF,
    CAMPAIGN,
    aggregate_analysis_document,
    aggregate_snapshot_document,
    analysis_document,
    attribution_request,
    experiment_event,
    experiment_fixture,
    future_cli_experiment_fixture,
    hashed_reference,
    load_fixture,
    mark_uncertain_identities,
    normalized_event,
    reference,
    snapshot_document,
    subject,
)
from marketing_optimization_snapshot_test_mixin import SnapshotAttributionMixin  # noqa: E402
from marketing_optimization_contract import (  # noqa: E402
    MINIMUM_AGGREGATE_CELL_SIZE,
    MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT,
    MINIMUM_EXPERIMENT_RUNTIME_SECONDS,
    MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT,
    OptimizationError,
    parse_datetime,
    typed_reference,
)
from marketing_optimization_report import (  # noqa: E402
    _build_report_from_resolved_evidence as build_report,
    render_report_markdown,
)
from marketing_optimization_snapshot_validation import canonical_subject_map  # noqa: E402
from marketing_optimization_registry import (  # noqa: E402
    analysis_slot_reference,
    publish_decision_transition,
    publish_registered_assignment,
    publish_registered_definition,
    publish_successor_transition,
    registered_assignment,
    registered_definition,
    run_transition_slot_reference,
)
import marketing_optimization_storage as optimization_storage  # noqa: E402
from marketing_optimization_io import (  # noqa: E402
    SnapshotRequest,
    assignment_artifact_path,
    artifact_path,
    ensure_layout,
    immutable_json,
    load_policy,
    load_snapshot,
    publish_snapshot,
    report_artifact_path,
    resolve_paths,
    snapshot_from_repo,
    snapshot_from_document,
    snapshot_artifact_path,
    snapshot_document as rendered_snapshot_document,
)
from performance_adapters import AdapterResult  # noqa: E402
from performance_contract import PerformanceContractError  # noqa: E402
from performance_reporting import PerformanceReporting  # noqa: E402
from performance_store import MarketingPerformanceStore  # noqa: E402
from marketing_report_validation import validate_report_artifact  # noqa: E402

ATTRIBUTION_SCHEMA = SCRIPTS.parent / "schemas" / "marketing-attribution.schema.json"
EXPERIMENT_SCHEMA = SCRIPTS.parent / "schemas" / "marketing-experiment.schema.json"
RECOMMENDATION_SCHEMA = SCRIPTS.parent / "schemas" / "growth-recommendation.schema.json"
HELPER = SCRIPTS / "marketing-optimization-helper.py"


class MarketingOptimizationContractTests(SnapshotAttributionMixin, unittest.TestCase):
    """Exercise deterministic snapshots and immutable public-safe output."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, *arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        """Run the local optimization CLI against the temporary repository."""
        completed = subprocess.run(  # nosec B603 -- fixed local helper
            [sys.executable, str(HELPER), *arguments],
            cwd=self.repo,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(expected, completed.returncode, completed.stderr)
        return completed

    def cli_attribution(self, snapshot_path: Path, model: str) -> dict[str, object]:
        """Publish one compact CLI attribution fixture."""
        return json.loads(
            self.command(
                "attribute",
                "--repo",
                str(self.repo),
                "--input",
                str(snapshot_path),
                "--outcome-metric-id",
                "marketing.conversions.total",
                "--model",
                model,
                "--model-version",
                "2",
                "--minimum-cell-size",
                str(MINIMUM_AGGREGATE_CELL_SIZE),
            ).stdout
        )

    def assert_schema(self, schema: Path, document: dict[str, object]) -> None:
        """Validate one generated document with the committed JSON Schema."""
        payload = self.root / "schema-document.json"
        payload.write_text(json.dumps(document), encoding="utf-8")
        script = (
            "const fs=require('fs');"
            "const Ajv=require('ajv/dist/2020').default;"
            "const schema=JSON.parse(fs.readFileSync(process.argv[1]));"
            "const data=JSON.parse(fs.readFileSync(process.argv[2]));"
            "const validate=new Ajv({strict:false}).compile(schema);"
            "if(!validate(data)){console.error(JSON.stringify(validate.errors));process.exit(1)}"
        )
        completed = subprocess.run(  # nosec B603 -- fixed local schema validator
            ["node", "-e", script, str(schema), str(payload)],
            cwd=SCRIPTS.parent,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

    def test_snapshot_filters_future_events_and_unreferenced_subjects(self) -> None:
        document = snapshot_document()
        document["subjects"].append(subject("b"))
        snapshot = snapshot_from_document(document)

        self.assertEqual(2, len(snapshot.events))
        self.assertEqual([reference("mkt-subj-v1", "a")], [item["subject_id"] for item in snapshot.subjects])
        self.assertRegex(snapshot.digest, r"^sha256:[a-f0-9]{64}$")

    def test_snapshot_excludes_events_recorded_after_as_of(self) -> None:
        document = snapshot_document()
        document["events"][0]["source"]["recorded_at"] = "2026-08-16T00:00:00Z"

        snapshot = snapshot_from_document(document)

        self.assertEqual([reference("mkt-record-v1", "2")], [event["record_ref"] for event in snapshot.events])

    def test_snapshot_digest_is_order_stable_after_normalization(self) -> None:
        document = snapshot_document()
        reverse_document = snapshot_document()
        reverse_document["events"].reverse()

        left = snapshot_from_document(document)
        right = snapshot_from_document(reverse_document)

        self.assertEqual(left.digest, right.digest)
        self.assertEqual(left.events, right.events)

    def test_snapshot_detaches_mutable_input_and_rendered_documents(self) -> None:
        document = analysis_document()
        snapshot = snapshot_from_document(document)
        original_value = snapshot.events[0]["measurement"]["value"]
        document["events"][0]["measurement"]["value"] = 999
        rendered = rendered_snapshot_document(snapshot)
        rendered["events"][0]["measurement"]["value"] = 888

        self.assertEqual(original_value, snapshot.events[0]["measurement"]["value"])
        self.assertEqual(snapshot, snapshot_from_document(rendered_snapshot_document(snapshot)))

    def test_snapshot_rejects_duplicate_event_and_record_references(self) -> None:
        duplicate_event = analysis_document()
        duplicate_event["events"].append(json.loads(json.dumps(duplicate_event["events"][0])))
        with self.assertRaisesRegex(OptimizationError, "duplicate event_ref"):
            snapshot_from_document(duplicate_event)

        duplicate_record = analysis_document()
        repeated = json.loads(json.dumps(duplicate_record["events"][0]))
        repeated["event_ref"] = reference("mkt-event-v1", "9")
        duplicate_record["events"].append(repeated)
        with self.assertRaisesRegex(OptimizationError, "duplicate record_ref"):
            snapshot_from_document(duplicate_record)

    def test_snapshot_rejects_contradictory_subject_alias_projections(self) -> None:
        document = analysis_document()
        shared_alias = reference("mkt-subj-v1", "c")
        document["subjects"][0]["aliases"].append(shared_alias)
        contradictory = subject("b")
        contradictory["aliases"].append(shared_alias)
        document["subjects"].append(contradictory)

        with self.assertRaisesRegex(OptimizationError, "conflicting canonical subjects"):
            snapshot_from_document(document)

    def test_snapshot_rejects_subject_references_without_identity_projections(self) -> None:
        document = analysis_document()
        document["events"][0]["subject"]["subject_id"] = reference("mkt-subj-v1", "b")

        with self.assertRaisesRegex(OptimizationError, "lacks a subject projection"):
            snapshot_from_document(document)

    def test_snapshot_subject_coverage_applies_after_time_and_scope_filters(self) -> None:
        future_document = analysis_document()
        future_document["events"].append(
            normalized_event(
                "8",
                "engagement",
                "2026-08-16T00:00:00Z",
                subject_id=reference("mkt-subj-v1", "b"),
            )
        )
        future_snapshot = snapshot_from_document(future_document)
        self.assertEqual(2, len(future_snapshot.events))

        scoped_document = analysis_document()
        out_of_scope = normalized_event(
            "8",
            "engagement",
            "2026-08-03T00:00:00Z",
            subject_id=reference("mkt-subj-v1", "b"),
        )
        out_of_scope["scope"]["campaign_id"] = "concurrent-campaign"
        scoped_document["events"].append(out_of_scope)
        scoped_snapshot = snapshot_from_document(scoped_document, campaign_id=CAMPAIGN)
        self.assertEqual(2, len(scoped_snapshot.events))

    def test_snapshot_resolves_corrections_to_the_target_event_semantics(self) -> None:
        document = analysis_document()
        target = document["events"][1]
        correction = json.loads(json.dumps(target))
        correction["record_ref"] = reference("mkt-record-v1", "4")
        correction["event_ref"] = reference("mkt-event-v1", "4")
        correction["event"] = {
            "type": "correction",
            "occurred_at": "2026-08-03T12:00:00Z",
            "correction_of": target["event_ref"],
        }
        correction["measurement"]["value"] = 3
        document["events"].append(correction)
        snapshot = snapshot_from_document(aggregate_snapshot_document(document))

        conversions = [event for event in snapshot.events if event["event"]["type"] == "conversion"]
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, len(conversions))
        self.assertTrue(all(event["event"]["correction_of"] is None for event in conversions))
        self.assertTrue(
            all(event["event"]["occurred_at"] == target["event"]["occurred_at"] for event in conversions)
        )
        projection = build_attribution(snapshot, attribution_request())
        self.assertEqual(3 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["eligible_count"])
        self.assertEqual(3 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertEqual(snapshot, snapshot_from_document(rendered_snapshot_document(snapshot)))

    def test_refunds_match_corrected_outcomes_by_original_occurrence_time(self) -> None:
        document = analysis_document()
        target = document["events"][1]
        target["event"]["type"] = "revenue"
        target["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        correction = json.loads(json.dumps(target))
        correction["record_ref"] = reference("mkt-record-v1", "4")
        correction["event_ref"] = reference("mkt-event-v1", "4")
        correction["event"] = {
            "type": "correction",
            "occurred_at": "2026-08-03T12:00:00Z",
            "correction_of": target["event_ref"],
        }
        correction["measurement"]["value"] = 120
        refund = normalized_event("5", "conversion", "2026-08-02T18:00:00Z")
        refund["event"]["type"] = "refund"
        refund["scope"]["outcome_id"] = target["scope"]["outcome_id"]
        refund["measurement"].update(
            {
                "metric_id": "marketing.revenue.refunded",
                "value": 25,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].extend((correction, refund))

        projection = build_attribution(
            snapshot_from_document(aggregate_snapshot_document(document)),
            attribution_request(outcome_metric_id="marketing.revenue.gross"),
        )

        self.assertEqual(120 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["gross_value"])
        self.assertEqual(25 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["refund_value"])
        self.assertEqual(95 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertEqual(0, projection["coverage"]["unmatched_refunds"])

    def test_snapshot_rejects_unresolved_correction_targets(self) -> None:
        document = analysis_document()
        correction = json.loads(json.dumps(document["events"][1]))
        correction["record_ref"] = reference("mkt-record-v1", "4")
        correction["event_ref"] = reference("mkt-event-v1", "4")
        correction["event"]["type"] = "correction"
        correction["event"]["correction_of"] = reference("mkt-event-v1", "9")
        document["events"].append(correction)

        with self.assertRaisesRegex(OptimizationError, "correction target is unavailable"):
            snapshot_from_document(document)

    def test_snapshot_rejects_cyclic_correction_chains(self) -> None:
        document = analysis_document()
        first = json.loads(json.dumps(document["events"][1]))
        second = json.loads(json.dumps(document["events"][1]))
        first["record_ref"] = reference("mkt-record-v1", "4")
        first["event_ref"] = reference("mkt-event-v1", "4")
        first["event"]["type"] = "correction"
        first["event"]["correction_of"] = reference("mkt-event-v1", "5")
        second["record_ref"] = reference("mkt-record-v1", "5")
        second["event_ref"] = reference("mkt-event-v1", "5")
        second["event"]["type"] = "correction"
        second["event"]["correction_of"] = reference("mkt-event-v1", "4")
        document["events"].extend((first, second))

        with self.assertRaisesRegex(OptimizationError, "correction chain contains a cycle"):
            snapshot_from_document(document)

    def test_snapshot_filters_source_summaries_with_the_requested_scope(self) -> None:
        document = analysis_document()
        extra_source = json.loads(json.dumps(document["sources"][0]))
        extra_source["source"] = "analytics"
        extra_source["account_ref"] = "other-account"
        document["sources"].append(extra_source)

        snapshot = snapshot_from_document(document, source="normalized", account_ref=ACCOUNT)

        self.assertEqual({("normalized", ACCOUNT)}, {(item["source"], item["account_ref"]) for item in snapshot.sources})

    def test_snapshot_rejects_direct_identifier_fields(self) -> None:
        document = snapshot_document()
        document["events"][0]["scope"]["dimensions"]["email"] = "nobody@example.invalid"

        with self.assertRaisesRegex(OptimizationError, "forbidden identifier"):
            snapshot_from_document(document)

    def test_snapshot_rejects_unsafe_aliases_raw_dimensions_and_extra_fields(self) -> None:
        named_scope = snapshot_document()
        named_scope["events"][0]["scope"]["channel"] = "Jane Doe"
        with self.assertRaisesRegex(OptimizationError, "bounded lowercase alias"):
            snapshot_from_document(named_scope)

        raw_dimension = snapshot_document()
        raw_dimension["events"][0]["scope"]["dimensions"]["custom_segment"] = "unhashed-segment"
        with self.assertRaisesRegex(OptimizationError, "must be pseudonymized"):
            snapshot_from_document(raw_dimension)

        extra_payload = snapshot_document()
        extra_payload["events"][0]["source"]["unexpected"] = "opaque-data"
        with self.assertRaisesRegex(OptimizationError, "fields do not match"):
            snapshot_from_document(extra_payload)

    def test_fixture_as_of_override_must_match(self) -> None:
        path = self.root / "snapshot.json"
        path.write_text(json.dumps(snapshot_document()), encoding="utf-8")

        with self.assertRaisesRegex(OptimizationError, "must match"):
            load_snapshot(
                SnapshotRequest(
                    repo=self.repo,
                    input_path=path,
                    as_of="2026-08-14T00:00:00Z",
                )
            )

    def test_layout_provisions_policy_and_outputs_are_idempotent(self) -> None:
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        policy = load_policy(paths, provision=False)
        document = {"schema": "fixture/v1", "count": 1}
        output = artifact_path(paths, "attribution", reference("mkt-attribution-v1", "a"))

        first = immutable_json(paths, output, document)
        second = immutable_json(paths, output, document)

        self.assertEqual(first, second)
        self.assertEqual("aidevops.marketing-optimization-config/v1", policy["schema"])
        self.assertEqual(0o700, stat.S_IMODE(paths.assignments.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(paths.snapshots.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(paths.work.stat().st_mode))
        snapshot = snapshot_from_document(analysis_document())
        publish_snapshot(paths, snapshot, dry_run=False)
        self.assertEqual(
            0o600,
            stat.S_IMODE(snapshot_artifact_path(paths, snapshot.digest).stat().st_mode),
        )
        with self.assertRaisesRegex(OptimizationError, "conflicts"):
            immutable_json(paths, output, {"schema": "fixture/v1", "count": 2})

    def test_immutable_publication_rejects_symlink_rebinding(self) -> None:
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        pinned_directory = paths.marketing / "attribution-pinned"
        external_directory = self.root / "external"
        external_directory.mkdir()
        output = artifact_path(paths, "attribution", reference("mkt-attribution-v1", "b"))
        original_create = optimization_storage._create_temporary
        swapped = False

        def swap_directory(directory_fd: int, prefix: str) -> tuple[int, str]:
            nonlocal swapped
            if not swapped:
                paths.attribution.rename(pinned_directory)
                paths.attribution.symlink_to(external_directory, target_is_directory=True)
                swapped = True
            return original_create(directory_fd, prefix)

        with mock.patch.object(optimization_storage, "_create_temporary", side_effect=swap_directory):
            with self.assertRaisesRegex(OptimizationError, "changed during publication"):
                immutable_json(paths, output, {"schema": "fixture/v1", "count": 1})

        self.assertEqual([], list(external_directory.iterdir()))
        self.assertFalse((pinned_directory / output.name).exists())

    def test_immutable_publication_rejects_temporary_replacement(self) -> None:
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        output = artifact_path(paths, "attribution", reference("mkt-attribution-v1", "c"))
        original_publish = optimization_storage._publish_temporary

        def replace_temporary(
            directory_fd: int,
            descriptor: int,
            temporary: str,
            destination: str,
            payload: bytes,
        ) -> bool:
            os.unlink(temporary, dir_fd=directory_fd)
            replacement = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=directory_fd,
            )
            try:
                os.write(replacement, b'{"schema":"forged/v1"}\n')
                os.fsync(replacement)
            finally:
                os.close(replacement)
            return original_publish(directory_fd, descriptor, temporary, destination, payload)

        with mock.patch.object(optimization_storage, "_publish_temporary", side_effect=replace_temporary):
            with self.assertRaisesRegex(OptimizationError, "temporary changed"):
                immutable_json(paths, output, {"schema": "fixture/v1", "count": 1})

        self.assertFalse(output.exists())

    def test_live_snapshot_requires_explicit_as_of(self) -> None:
        with self.assertRaisesRegex(OptimizationError, "--as-of is required"):
            load_snapshot(SnapshotRequest(repo=self.repo, input_path=None, as_of=None))

    def test_live_snapshot_pins_governance_to_as_of(self) -> None:
        reporting = mock.Mock()
        reporting.event_records.return_value = []
        reporting.subject_records.return_value = []
        reporting.status.return_value = {"sources": []}
        context = mock.MagicMock()
        context.__enter__.return_value = object()
        fractional_as_of = "2026-08-15T00:00:00.750000Z"
        boundary = datetime.fromisoformat(fractional_as_of.replace("Z", "+00:00")).timestamp()

        with mock.patch("marketing_optimization_io.MarketingPerformanceStore.open", return_value=context):
            with mock.patch("marketing_optimization_io.PerformanceReporting", return_value=reporting):
                snapshot = snapshot_from_repo(
                    self.repo,
                    as_of=fractional_as_of,
                    account_ref=ACCOUNT,
                    campaign_id=CAMPAIGN,
                )

        reporting.event_records.assert_called_once_with(
            source=None,
            account_ref=ACCOUNT,
            campaign_id=CAMPAIGN,
            now_epoch=boundary,
        )
        reporting.subject_records.assert_called_once_with(boundary)
        reporting.status.assert_called_once_with(boundary)
        self.assertEqual(fractional_as_of, snapshot.as_of)
        self.assertEqual(0.75, boundary % 1)

    def test_live_snapshot_rejects_events_without_subject_projections(self) -> None:
        document = analysis_document()
        reporting = mock.Mock()
        reporting.event_records.return_value = [document["events"][0]]
        reporting.subject_records.return_value = []
        reporting.status.return_value = {"sources": document["sources"]}
        context = mock.MagicMock()
        context.__enter__.return_value = object()

        with mock.patch("marketing_optimization_io.MarketingPerformanceStore.open", return_value=context):
            with mock.patch("marketing_optimization_io.PerformanceReporting", return_value=reporting):
                with self.assertRaisesRegex(OptimizationError, "lacks a subject projection"):
                    snapshot_from_repo(
                        self.repo,
                        as_of=AS_OF,
                        account_ref=ACCOUNT,
                        campaign_id=CAMPAIGN,
                    )

    def test_external_attribution_validation_enforces_privacy_invariants(self) -> None:
        suppressed = build_attribution(
            snapshot_from_document(analysis_document()),
            attribution_request(),
        )
        leaked = json.loads(json.dumps(suppressed))
        leaked["coverage"]["late_events"] = 1
        leaked.pop("attribution_ref")
        leaked["attribution_ref"] = typed_reference("mkt-attribution-v1", leaked)
        with self.assertRaisesRegex(OptimizationError, "suppressed coverage counts"):
            validate_attribution_artifact(leaked)

        visible = build_attribution(
            snapshot_from_document(aggregate_analysis_document()),
            attribution_request(),
        )
        relaxed = json.loads(json.dumps(visible))
        relaxed["coverage"]["minimum_cell_size"] = MINIMUM_AGGREGATE_CELL_SIZE - 1
        relaxed.pop("attribution_ref")
        relaxed["attribution_ref"] = typed_reference("mkt-attribution-v1", relaxed)
        with self.assertRaisesRegex(OptimizationError, "outside the supported range"):
            validate_attribution_artifact(relaxed)

        forged = json.loads(json.dumps(visible))
        forged_allocation = forged["allocations"][0]
        forged_allocation.update(
            {
                "outcome_count": 1,
                "credit": 1,
                "value": 1,
                "suppressed": False,
                "suppression_reason": None,
            }
        )
        forged["coverage"]["suppressed_allocations"] -= 1
        forged.pop("attribution_ref")
        forged["attribution_ref"] = typed_reference("mkt-attribution-v1", forged)
        with self.assertRaisesRegex(OptimizationError, "allocation outcome count"):
            validate_attribution_artifact(forged)

    def test_repeated_outcomes_for_one_subject_do_not_bypass_privacy(self) -> None:
        document = analysis_document()
        document["events"][1]["measurement"]["value"] = 10
        snapshot = snapshot_from_document(document)

        projection = build_attribution(snapshot, attribution_request(minimum_cell_size=10))

        self.assertTrue(projection["outcomes"]["suppressed"])
        self.assertIsNone(projection["outcomes"]["eligible_count"])

    def test_linked_identity_aliases_do_not_bypass_privacy(self) -> None:
        document = aggregate_analysis_document()
        canonical = reference("mkt-subj-v1", "f")
        for projected_subject in document["subjects"]:
            projected_subject["canonical_subject_id"] = canonical
            projected_subject["aliases"].append(canonical)
        snapshot = snapshot_from_document(document)

        projection = build_attribution(snapshot, attribution_request())
        report = build_report(snapshot, [], [], MINIMUM_AGGREGATE_CELL_SIZE)

        self.assertTrue(projection["outcomes"]["suppressed"])
        self.assertIsNone(projection["outcomes"]["eligible_count"])
        self.assertTrue(report["performance"]["rows"])
        self.assertTrue(all(row["suppressed"] for row in report["performance"]["rows"]))

    def test_policy_floors_reject_relaxed_privacy_and_sample_plans(self) -> None:
        snapshot = snapshot_from_document(analysis_document())
        with self.assertRaisesRegex(OptimizationError, "outside the supported range"):
            build_attribution(
                snapshot,
                attribution_request(minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE - 1),
            )
        with self.assertRaisesRegex(OptimizationError, "outside the supported range"):
            build_report(snapshot, [], [], minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE - 1)

        definition, _assignment, _document = experiment_fixture()
        checks = (
            ("sample_plan", "required_sample_per_variant", MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT - 1),
            (
                "sample_plan",
                "minimum_conversions_per_variant",
                MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT - 1,
            ),
            ("sample_plan", "minimum_runtime_seconds", MINIMUM_EXPERIMENT_RUNTIME_SECONDS - 1),
            ("privacy", "minimum_cell_size", MINIMUM_AGGREGATE_CELL_SIZE - 1),
            ("privacy", "minimum_subject_count", MINIMUM_AGGREGATE_CELL_SIZE - 1),
        )
        for container, field, value in checks:
            with self.subTest(field=field):
                relaxed = json.loads(json.dumps(definition))
                relaxed[container][field] = value
                with self.assertRaisesRegex(OptimizationError, "outside the supported range"):
                    register_experiment(relaxed)

        snapshot_path = self.root / "privacy-floor-snapshot.json"
        snapshot_path.write_text(json.dumps(analysis_document()), encoding="utf-8")
        self.command("init", "--repo", str(self.repo))
        rejected = self.command(
            "attribute",
            "--repo",
            str(self.repo),
            "--input",
            str(snapshot_path),
            "--outcome-metric-id",
            "marketing.conversions.total",
            "--minimum-cell-size",
            str(MINIMUM_AGGREGATE_CELL_SIZE - 1),
            expected=1,
        )
        self.assertIn("configured privacy floor", rejected.stderr)

    def test_direct_attribution_uses_only_observed_outcome_scope(self) -> None:
        snapshot = snapshot_from_document(aggregate_analysis_document())

        projection = build_attribution(snapshot, attribution_request(model="direct"))

        self.assertEqual("direct_observed", projection["allocations"][0]["bucket"])
        self.assertIsNone(projection["allocations"][0]["touchpoint_ref"])
        self.assertEqual("search", projection["allocations"][0]["channel"])

    def test_last_touch_orders_fractional_timestamps_chronologically(self) -> None:
        document = analysis_document()
        document["events"][0]["event"]["occurred_at"] = "2026-08-01T12:00:00Z"
        document["events"][1]["event"]["occurred_at"] = "2026-08-02T12:00:00.500000Z"
        later_touch = normalized_event(
            "8",
            "engagement",
            "2026-08-01T12:00:00.500000Z",
            subject_id=document["subjects"][0]["subject_id"],
        )
        later_touch["scope"]["channel"] = "social"
        later_touch["scope"]["creative_id"] = "creative-b"
        later_touch["scope"]["touchpoint_id"] = "touch-b"
        earlier_outcome = normalized_event(
            "9",
            "conversion",
            "2026-08-02T12:00:00Z",
            subject_id=document["subjects"][0]["subject_id"],
        )
        earlier_outcome["scope"]["outcome_id"] = "outcome-b"
        document["events"].extend((later_touch, earlier_outcome))
        snapshot = snapshot_from_document(document)
        outcomes = [event for event in snapshot.events if event["event"]["type"] == "conversion"]
        outcome = next(
            event for event in outcomes if event["event"]["occurred_at"].endswith(".500000Z")
        )
        touches = [event for event in snapshot.events if event["event"]["type"] == "engagement"]

        selected = _last_touch_key(
            outcome,
            touches,
            30 * 86400,
            canonical_subject_map(snapshot.subjects),
        )

        self.assertEqual("social", selected[2])
        self.assertEqual("creative-b", selected[3])
        self.assertEqual(
            ["2026-08-02T12:00:00Z", "2026-08-02T12:00:00.500000Z"],
            [event["event"]["occurred_at"] for event in outcomes],
        )
        self.assertEqual(
            "2026-08-02T12:00:00Z",
            build_attribution(snapshot, attribution_request())["window"]["outcome_start"],
        )
        self.assertEqual(
            "2026-08-01T12:00:00Z",
            build_report(snapshot, [], [], MINIMUM_AGGREGATE_CELL_SIZE)["run"]["period_start"],
        )

    def test_last_touch_excludes_ambiguous_touchpoint_identity(self) -> None:
        document = analysis_document()
        touchpoint = document["events"][0]
        outcome = document["events"][1]
        touchpoint["subject"]["identity_state"] = "ambiguous"

        selected = _last_touch_key(
            outcome,
            [touchpoint],
            30 * 86400,
            canonical_subject_map(document["subjects"]),
        )

        self.assertEqual("unattributed", selected[0])
        self.assertIsNone(selected[1])

    def test_snapshot_rejects_event_and_projection_identity_uncertainty_mismatches(self) -> None:
        document = aggregate_analysis_document()
        for item in document["subjects"]:
            item["identity_state"] = "ambiguous"
            item["audience_eligible"] = False
            item["eligibility_reason"] = "identity_ambiguous"

        with self.assertRaisesRegex(OptimizationError, "identity uncertainty conflicts"):
            snapshot_from_document(document)

    def test_unknown_identity_and_missing_touchpoints_remain_unattributed(self) -> None:
        for identity_state in ("ambiguous", "split"):
            for model in ("direct", "last_touch"):
                with self.subTest(identity_state=identity_state, model=model):
                    document = mark_uncertain_identities(
                        aggregate_analysis_document(),
                        identity_state,
                    )
                    uncertain = build_attribution(
                        snapshot_from_document(document),
                        attribution_request(model=model),
                    )

                    self.assertEqual("identity_uncertain", uncertain["allocations"][0]["bucket"])
                    self.assertTrue(uncertain["allocations"][0]["suppressed"])
                    self.assertTrue(uncertain["outcomes"]["suppressed"])
                    self.assertIsNone(uncertain["outcomes"]["identity_uncertain_count"])
                    self.assertIn("identity_ambiguity", uncertain["uncertainty"]["reasons"])

        missing_document = aggregate_analysis_document()
        missing_document["events"] = [
            event for event in missing_document["events"] if event["event"]["type"] == "conversion"
        ]
        missing = build_attribution(
            snapshot_from_document(missing_document),
            attribution_request(),
        )

        self.assertEqual("unattributed", missing["allocations"][0]["bucket"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, missing["outcomes"]["unattributed_count"])

    def test_campaign_scope_excludes_concurrent_campaign_evidence(self) -> None:
        document = aggregate_analysis_document()
        other_subject = reference("mkt-subj-v1", "b")
        other_touch = normalized_event("8", "engagement", "2026-08-01T13:00:00Z", subject_id=other_subject)
        other_outcome = normalized_event("9", "conversion", "2026-08-02T13:00:00Z", subject_id=other_subject)
        for event in (other_touch, other_outcome):
            event["scope"]["campaign_id"] = "concurrent-campaign"
        document["events"].extend([other_touch, other_outcome])
        document["subjects"].append(subject("b"))

        snapshot = snapshot_from_document(document, campaign_id=CAMPAIGN)
        projection = build_attribution(
            snapshot,
            attribution_request(campaign_id=CAMPAIGN),
        )

        self.assertEqual(2 * MINIMUM_AGGREGATE_CELL_SIZE, len(snapshot.events))
        self.assertEqual(CAMPAIGN, projection["scope"]["campaign_id"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["eligible_count"])

        mixed_snapshot = snapshot_from_document(document)
        with self.assertRaisesRegex(OptimizationError, "outside its requested campaign scope"):
            build_attribution(
                mixed_snapshot,
                attribution_request(campaign_id=CAMPAIGN),
            )

    def test_delayed_conversion_and_partial_evidence_cannot_receive_high_confidence(self) -> None:
        document = aggregate_analysis_document()
        document["events"][1]["source"]["observed_at"] = "2026-08-14T12:00:00Z"
        document["events"][1]["source"]["recorded_at"] = "2026-08-14T12:00:00Z"
        snapshot = snapshot_from_document(document)

        projection = build_attribution(snapshot, attribution_request(lookback_seconds=7 * 86400))

        self.assertIn("late_events", projection["uncertainty"]["reasons"])
        self.assertEqual("medium", projection["uncertainty"]["data_confidence"])
        self.assertEqual("partial", projection["run"]["status"])
        report = build_report(snapshot, [projection], [], MINIMUM_AGGREGATE_CELL_SIZE)
        self.assertEqual("partial", report["run"]["status"])
        self.assertIn("late_events", report["quality"]["reasons"])
        self.assertIn("attribution_partial", report["quality"]["reasons"])

        forged = json.loads(json.dumps(report))
        forged["run"]["status"] = "complete"
        forged["quality"]["reasons"] = []
        forged.pop("report_ref")
        forged["report_ref"] = typed_reference("mkt-report-v1", forged)
        with self.assertRaisesRegex(OptimizationError, "nested evidence caveats"):
            validate_report_artifact(forged)

    def test_attribution_model_version_recompute_preserves_lineage(self) -> None:
        snapshot = snapshot_from_document(analysis_document())

        first = build_attribution(snapshot, attribution_request(model_version=1))
        second = build_attribution(
            snapshot,
            attribution_request(model_version=2, supersedes=first["attribution_ref"]),
        )

        self.assertEqual(1, first["model"]["version"])
        self.assertEqual(2, second["model"]["version"])
        self.assertNotEqual(first["attribution_ref"], second["attribution_ref"])
        self.assertIsNone(first["provenance"]["supersedes"])
        self.assertEqual(first["attribution_ref"], second["provenance"]["supersedes"])
        self.assert_schema(ATTRIBUTION_SCHEMA, first)
        self.assert_schema(ATTRIBUTION_SCHEMA, second)

    def test_refunds_costs_and_contradictory_currency_metrics_remain_explicit(self) -> None:
        fixture = load_fixture("revenue-refunds-costs.json")
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = fixture["outcome"]["event_type"]
        outcome["measurement"].update(fixture["outcome"]["measurement"])
        for event_fixture in fixture["events"]:
            event = normalized_event(
                event_fixture["digit"],
                event_fixture["event_type"],
                event_fixture["occurred_at"],
            )
            event["scope"]["outcome_id"] = event_fixture["outcome_id"]
            event["measurement"].update(event_fixture["measurement"])
            document["events"].append(event)
        document["as_of"] = fixture["as_of"]
        document = aggregate_snapshot_document(document)
        snapshot = snapshot_from_document(document)

        projection = build_attribution(
            snapshot,
            attribution_request(
                outcome_metric_id="marketing.revenue.gross",
                refund_maturity_seconds=14 * 86400,
            ),
        )

        expected = fixture["expected"]
        self.assertEqual(
            expected["gross_value"] * MINIMUM_AGGREGATE_CELL_SIZE,
            projection["outcomes"]["gross_value"],
        )
        self.assertEqual(
            expected["refund_value"] * MINIMUM_AGGREGATE_CELL_SIZE,
            projection["outcomes"]["refund_value"],
        )
        self.assertEqual(
            expected["net_value"] * MINIMUM_AGGREGATE_CELL_SIZE,
            projection["outcomes"]["net_value"],
        )
        self.assertEqual(
            expected["cost_value"] * MINIMUM_AGGREGATE_CELL_SIZE,
            projection["costs"]["value"],
        )
        self.assertEqual(expected["roi"], projection["costs"]["roi"])
        self.assertEqual("mature", projection["window"]["maturity"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["coverage"]["unmatched_refunds"])
        self.assertIn("unmatched_refunds", projection["uncertainty"]["reasons"])
        self.assert_schema(ATTRIBUTION_SCHEMA, projection)

        document["events"][2]["measurement"]["currency"] = "EUR"
        mismatch = build_attribution(snapshot_from_document(document), attribution_request(outcome_metric_id="marketing.revenue.gross"))
        self.assertIn("currency_mismatch", mismatch["uncertainty"]["reasons"])
        self.assertIsNone(mismatch["outcomes"]["net_value"])
        self.assertEqual("low", mismatch["uncertainty"]["data_confidence"])

    def test_refunds_cannot_match_outcomes_that_occur_later(self) -> None:
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = "revenue"
        outcome["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        refund = normalized_event("4", "conversion", "2026-08-01T18:00:00Z")
        refund["event"]["type"] = "refund"
        refund["scope"]["outcome_id"] = outcome["scope"]["outcome_id"]
        refund["measurement"].update(
            {
                "metric_id": "marketing.revenue.refunded",
                "value": 25,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].append(refund)

        projection = build_attribution(
            snapshot_from_document(aggregate_snapshot_document(document)),
            attribution_request(outcome_metric_id="marketing.revenue.gross"),
        )

        self.assertEqual(0, projection["outcomes"]["refund_value"])
        self.assertEqual(100 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["coverage"]["unmatched_refunds"])

    def test_refund_matching_rejects_duplicate_outcome_scope_keys(self) -> None:
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = "revenue"
        outcome["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        duplicate = json.loads(json.dumps(outcome))
        duplicate["record_ref"] = hashed_reference("mkt-record-v1", "duplicate-outcome")
        duplicate["event_ref"] = hashed_reference("mkt-event-v1", "duplicate-outcome")
        evidence = hashed_reference("mkt-evidence-v1:sha256", "duplicate-outcome")
        duplicate["source"]["evidence_ref"] = evidence
        duplicate["quality"]["evidence_ref"] = evidence
        document["events"].append(duplicate)

        with self.assertRaisesRegex(OptimizationError, "duplicate refund match keys"):
            build_attribution(
                snapshot_from_document(aggregate_snapshot_document(document)),
                attribution_request(outcome_metric_id="marketing.revenue.gross"),
            )

    def test_currency_refunds_do_not_reduce_count_outcome_values(self) -> None:
        document = analysis_document()
        refund = normalized_event("4", "conversion", "2026-08-03T12:00:00Z")
        refund["event"]["type"] = "refund"
        refund["scope"]["outcome_id"] = document["events"][1]["scope"]["outcome_id"]
        refund["measurement"].update(
            {
                "metric_id": "marketing.revenue.refunded",
                "value": 25,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].append(refund)
        snapshot = snapshot_from_document(aggregate_snapshot_document(document))

        projection = build_attribution(snapshot, attribution_request())

        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["gross_value"])
        self.assertEqual(0, projection["outcomes"]["refund_value"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertNotIn("unmatched_refunds", projection["uncertainty"]["reasons"])

    def test_count_refunds_do_not_reduce_currency_outcome_values(self) -> None:
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = "revenue"
        outcome["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        refund = normalized_event("4", "conversion", "2026-08-03T12:00:00Z")
        refund["event"]["type"] = "refund"
        refund["scope"]["outcome_id"] = outcome["scope"]["outcome_id"]
        refund["measurement"].update(
            {
                "metric_id": "marketing.refunds.total",
                "value": 1,
                "unit": "refund",
                "currency": None,
            }
        )
        document["events"].append(refund)
        snapshot = snapshot_from_document(aggregate_snapshot_document(document))

        projection = build_attribution(
            snapshot,
            attribution_request(outcome_metric_id="marketing.revenue.gross"),
        )

        self.assertEqual(100 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["gross_value"])
        self.assertEqual(0, projection["outcomes"]["refund_value"])
        self.assertEqual(100 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])

    def test_currency_filter_cannot_relabel_count_outcomes_or_enable_roi(self) -> None:
        document = analysis_document()
        cost = normalized_event("4", "conversion", "2026-08-03T12:00:00Z")
        cost["event"]["type"] = "cost"
        cost["measurement"].update(
            {
                "metric_id": "marketing.cost.total",
                "value": 10,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].append(cost)
        snapshot = snapshot_from_document(aggregate_snapshot_document(document))

        with self.assertRaisesRegex(OptimizationError, "non-currency outcomes"):
            build_attribution(snapshot, attribution_request(currency="USD"))

    def test_refunds_do_not_cross_source_account_boundaries(self) -> None:
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = "revenue"
        outcome["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        refund = normalized_event("4", "conversion", "2026-08-03T12:00:00Z")
        refund["event"]["type"] = "refund"
        refund["scope"]["outcome_id"] = outcome["scope"]["outcome_id"]
        refund["measurement"].update(
            {
                "metric_id": "marketing.revenue.refunded",
                "value": 25,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].append(refund)
        aggregate = aggregate_snapshot_document(document)
        for event in aggregate["events"]:
            if event["event"]["type"] == "refund":
                event["source"]["account_ref"] = "other-account"
        other_source = json.loads(json.dumps(aggregate["sources"][0]))
        other_source["account_ref"] = "other-account"
        aggregate["sources"].append(other_source)
        snapshot = snapshot_from_document(aggregate)

        projection = build_attribution(
            snapshot,
            attribution_request(outcome_metric_id="marketing.revenue.gross"),
        )

        self.assertEqual(100 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["gross_value"])
        self.assertEqual(0, projection["outcomes"]["refund_value"])
        self.assertEqual(100 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["coverage"]["unmatched_refunds"])

    def test_refunds_do_not_cross_campaign_boundaries(self) -> None:
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = "revenue"
        outcome["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        refund = normalized_event("4", "conversion", "2026-08-03T12:00:00Z")
        refund["event"]["type"] = "refund"
        refund["scope"]["campaign_id"] = "concurrent-campaign"
        refund["scope"]["outcome_id"] = outcome["scope"]["outcome_id"]
        refund["measurement"].update(
            {
                "metric_id": "marketing.revenue.refunded",
                "value": 25,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].append(refund)
        snapshot = snapshot_from_document(aggregate_snapshot_document(document))

        projection = build_attribution(
            snapshot,
            attribution_request(outcome_metric_id="marketing.revenue.gross"),
        )

        self.assertEqual(0, projection["outcomes"]["refund_value"])
        self.assertEqual(100 * MINIMUM_AGGREGATE_CELL_SIZE, projection["outcomes"]["net_value"])
        self.assertEqual(MINIMUM_AGGREGATE_CELL_SIZE, projection["coverage"]["unmatched_refunds"])

    def test_verified_experiment_supports_causal_owner_gated_decision(self) -> None:
        definition, assignment, document = experiment_fixture()
        registered = register_experiment(definition)
        snapshot = snapshot_from_document(document)

        analysis = analyze_experiment(
            registered,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )

        self.assertEqual("complete", analysis["analysis"]["status"])
        self.assertTrue(analysis["analysis"]["decision_eligible"])
        self.assertEqual("causal_supported", analysis["analysis"]["causal_status"])
        self.assertEqual("treatment", analysis["analysis"]["winner_variant_id"])
        self.assertIsNone(analysis["decision"])
        self.assertEqual(
            analysis,
            analyze_experiment(
                registered,
                snapshot,
                ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
            ),
        )
        self.assert_schema(EXPERIMENT_SCHEMA, analysis)

        decided = record_experiment_decision(
            analysis,
            {
                "status": "winner",
                "winner_variant_id": "treatment",
                "reason": "The preregistered final look crossed statistical and practical thresholds.",
                "decided_at": AS_OF,
                "owner_approval_ref": "owner-approval-1",
            },
        )
        self.assertEqual("decided", decided["lifecycle"])
        self.assert_schema(EXPERIMENT_SCHEMA, decided)

    def test_experiment_analysis_and_decision_reject_undeclared_fields(self) -> None:
        definition, assignment, document = experiment_fixture()
        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        decided = record_experiment_decision(
            analysis,
            {
                "status": "winner",
                "winner_variant_id": "treatment",
                "reason": "Record the eligible treatment through the strict owner-decision contract.",
                "decided_at": AS_OF,
                "owner_approval_ref": "owner-approval-1",
            },
        )
        cases = (
            (analysis, ("analysis",)),
            (analysis, ("analysis", "variant_results", 0)),
            (analysis, ("analysis", "comparisons", 0)),
            (analysis, ("analysis", "guardrails", 0)),
            (decided, ("decision",)),
        )
        for source, path in cases:
            with self.subTest(path=path):
                tampered = json.loads(json.dumps(source))
                target: Any = tampered
                for component in path:
                    target = target[component]
                target["unexpected"] = "opaque-value"
                with self.assertRaisesRegex(OptimizationError, "fields are invalid"):
                    register_experiment(tampered)

        tampered = json.loads(json.dumps(analysis))
        tampered["analysis"]["comparisons"][0]["adjusted_alpha"] = None
        with self.assertRaisesRegex(PerformanceContractError, "adjusted_alpha"):
            register_experiment(tampered)

    def test_experiment_analysis_binds_rows_and_claims_to_its_definition(self) -> None:
        definition, assignment, document = experiment_fixture()
        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        cases = (
            (
                "variant",
                lambda item: item["analysis"]["variant_results"][0].update({"variant_id": "invented"}),
                "variant results do not match",
            ),
            (
                "comparison",
                lambda item: item["analysis"]["comparisons"].clear(),
                "comparisons do not match",
            ),
            (
                "aggregate",
                lambda item: item["analysis"]["variant_results"][0].update({"numerator": None}),
                "incomplete metric values",
            ),
            (
                "winner",
                lambda item: item["analysis"].update({"winner_variant_id": "control"}),
                "winner does not match",
            ),
        )
        for label, mutate, expected in cases:
            with self.subTest(label=label):
                forged = json.loads(json.dumps(analysis))
                mutate(forged)
                forged["analysis"].pop("run_ref")
                forged["analysis"]["run_ref"] = experiment_run_reference(
                    forged["experiment_ref"],
                    forged["analysis"],
                )
                with self.assertRaisesRegex(OptimizationError, expected):
                    register_experiment(forged)

    def test_experiment_approval_and_preregistration_must_predate_exposure(self) -> None:
        definition, _assignment, _document = experiment_fixture()
        definition["approval_ref"] = None
        with self.assertRaisesRegex(PerformanceContractError, "approval_ref"):
            register_experiment(definition)

        definition, _assignment, _document = experiment_fixture()
        definition["hypothesis"]["preregistered_at"] = definition["data_policy"]["started_at"]
        with self.assertRaisesRegex(OptimizationError, "must predate"):
            register_experiment(definition)

    def test_experiment_definitions_reject_undeclared_fields(self) -> None:
        paths = (
            (),
            ("hypothesis",),
            ("variants", 0),
            ("assignment",),
            ("metrics",),
            ("metrics", "primary"),
            ("metrics", "guardrails", 0),
            ("sample_plan",),
            ("stopping_policy",),
            ("privacy",),
            ("data_policy",),
            ("provenance",),
        )
        for path in paths:
            with self.subTest(path=path):
                definition, _assignment, _document = experiment_fixture()
                target: Any = definition
                for component in path:
                    target = target[component]
                target["unexpected"] = "opaque-value"
                with self.assertRaisesRegex(OptimizationError, "fields are invalid"):
                    register_experiment(definition)

        definition, _assignment, _document = experiment_fixture()
        definition["analysis"] = None
        with self.assertRaisesRegex(OptimizationError, "experiment analysis must be an object"):
            register_experiment(definition)

    def test_experiment_primary_metrics_fail_closed_outside_binomial_rates(self) -> None:
        cases = (
            ("currency", None),
            ("conversion", None),
        )
        for unit, denominator in cases:
            with self.subTest(unit=unit):
                definition, _assignment, _document = experiment_fixture()
                definition["metrics"]["primary"]["unit"] = unit
                definition["metrics"]["primary"]["denominator_metric_id"] = denominator
                with self.assertRaisesRegex(OptimizationError, "binomial-rate"):
                    register_experiment(definition)

        definition, _assignment, _document = experiment_fixture()
        definition["metrics"]["primary"]["denominator_metric_id"] = "marketing.custom.denominator"
        with self.assertRaisesRegex(OptimizationError, "match its exposure metric"):
            register_experiment(definition)

    def test_experiment_primary_metrics_suppress_sparse_subject_contributors(self) -> None:
        definition, assignment, document = experiment_fixture({"control_conversions": 9})
        snapshot = snapshot_from_document(document)
        analysis = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        control = next(
            item for item in analysis["analysis"]["variant_results"] if item["variant_id"] == "control"
        )

        self.assertTrue(control["suppressed"])
        self.assertIsNone(control["numerator"])
        self.assertIsNone(control["metric_value"])
        self.assertEqual("insufficient_evidence", analysis["analysis"]["guardrails"][0]["status"])
        self.assertIsNone(analysis["analysis"]["guardrails"][0]["effect"])
        self.assertIn("privacy_threshold_not_met", analysis["analysis"]["insufficient_reasons"])
        report = build_report(snapshot, [], [analysis], MINIMUM_AGGREGATE_CELL_SIZE)
        self.assertEqual(report["report_ref"], validate_report_artifact(report))

    def test_experiment_conversion_floor_ignores_unrelated_conversion_events(self) -> None:
        definition, assignment, document = experiment_fixture()
        definition["sample_plan"]["minimum_conversions_per_variant"] = 20
        control_subjects = [
            row["unit_ref"]
            for row in assignment["assignments"]
            if row["variant_id"] == "control"
        ][:10]
        for subject_id in control_subjects:
            document["events"].append(
                experiment_event(
                    len(document["events"]),
                    {
                        "event_type": "conversion",
                        "metric_id": "marketing.secondary.total",
                        "subject_id": subject_id,
                        "variant_id": "control",
                    },
                )
            )

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertIn("conversion_floor_not_met", analysis["analysis"]["insufficient_reasons"])

    def test_experiment_guardrails_reject_sparse_subject_contributors(self) -> None:
        definition, assignment, document = experiment_fixture()
        observed: set[str] = set()
        retained: list[dict[str, object]] = []
        for event in document["events"]:
            if event["measurement"]["metric_id"] != "marketing.unsubscribes.total":
                retained.append(event)
                continue
            variant_id = str(event["scope"]["dimensions"]["experiment_variant"])
            if variant_id not in observed:
                retained.append(event)
                observed.add(variant_id)
        document["events"] = retained

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertEqual("insufficient_evidence", analysis["analysis"]["guardrails"][0]["status"])
        self.assertIsNone(analysis["analysis"]["guardrails"][0]["effect"])
        self.assertIn("guardrail_evidence_missing", analysis["analysis"]["insufficient_reasons"])

    def test_experiment_binomial_analysis_rejects_currency_components(self) -> None:
        definition, assignment, document = experiment_fixture()
        definition["metrics"]["primary"]["metric_id"] = "marketing.custom.outcome"
        currencies = ("USD", "EUR")
        converted = 0
        for event in document["events"]:
            if event["event"]["type"] != "conversion":
                continue
            event["measurement"].update(
                {
                    "metric_id": "marketing.custom.outcome",
                    "unit": "currency",
                    "currency": currencies[converted % len(currencies)],
                }
            )
            converted += 1

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertIn("unsupported_metric_distribution", analysis["analysis"]["insufficient_reasons"])
        self.assertTrue(
            all(item["metric_value"] is None for item in analysis["analysis"]["variant_results"])
        )

    def test_experiment_binomial_analysis_rejects_repeated_or_nonbinary_subject_outcomes(self) -> None:
        for mode in ("repeated", "nonbinary"):
            with self.subTest(mode=mode):
                definition, assignment, document = experiment_fixture()
                treatment_conversion = next(
                    event
                    for event in document["events"]
                    if event["event"]["type"] == "conversion"
                    and event["scope"]["dimensions"]["experiment_variant"] == "treatment"
                )
                if mode == "nonbinary":
                    treatment_conversion["measurement"]["value"] = 2
                else:
                    duplicate = json.loads(json.dumps(treatment_conversion))
                    duplicate["record_ref"] = hashed_reference("mkt-record-v1", "repeated-conversion")
                    duplicate["event_ref"] = hashed_reference("mkt-event-v1", "repeated-conversion")
                    evidence = hashed_reference("mkt-evidence-v1:sha256", "repeated-conversion")
                    duplicate["source"]["evidence_ref"] = evidence
                    duplicate["quality"]["evidence_ref"] = evidence
                    document["events"].append(duplicate)

                analysis = analyze_experiment(
                    definition,
                    snapshot_from_document(document),
                    ExperimentAnalysisRequest(1, "final", assignment),
                )

                self.assertFalse(analysis["analysis"]["decision_eligible"])
                self.assertIsNone(analysis["analysis"]["winner_variant_id"])
                self.assertIn(
                    "unsupported_metric_distribution",
                    analysis["analysis"]["insufficient_reasons"],
                )

    def test_experiment_assignments_reject_linked_aliases_as_independent_subjects(self) -> None:
        definition, assignment, document = experiment_fixture()
        control_ref = next(
            row["unit_ref"] for row in assignment["assignments"] if row["variant_id"] == "control"
        )
        treatment_ref = next(
            row["unit_ref"] for row in assignment["assignments"] if row["variant_id"] == "treatment"
        )
        treatment_subject = next(
            item for item in document["subjects"] if item["subject_id"] == treatment_ref
        )
        treatment_subject["canonical_subject_id"] = control_ref
        treatment_subject["aliases"].append(control_ref)

        with self.assertRaisesRegex(OptimizationError, "duplicate canonical subjects"):
            analyze_experiment(
                definition,
                snapshot_from_document(document),
                ExperimentAnalysisRequest(1, "final", assignment),
            )

    def test_experiment_analysis_rejects_broader_campaign_and_account_snapshots(self) -> None:
        cases = (
            ("campaign_id", "concurrent-campaign", "campaign"),
            ("account_ref", "other-account", "account"),
        )
        for field, value, scope_label in cases:
            with self.subTest(field=field):
                definition, assignment, document = experiment_fixture()
                extra = json.loads(json.dumps(document["events"][0]))
                extra["record_ref"] = hashed_reference("mkt-record-v1", f"scope-{field}")
                extra["event_ref"] = hashed_reference("mkt-event-v1", f"scope-{field}")
                evidence = hashed_reference("mkt-evidence-v1:sha256", f"scope-{field}")
                extra["source"]["evidence_ref"] = evidence
                extra["quality"]["evidence_ref"] = evidence
                if field == "campaign_id":
                    extra["scope"]["campaign_id"] = value
                else:
                    extra["source"]["account_ref"] = value
                document["events"].append(extra)

                with self.assertRaisesRegex(OptimizationError, f"requested {scope_label} scope"):
                    analyze_experiment(
                        definition,
                        snapshot_from_document(document),
                        ExperimentAnalysisRequest(1, "final", assignment),
                    )

    def test_experiment_refunds_do_not_change_ratio_metric_units(self) -> None:
        definition, assignment, document = experiment_fixture()
        control_subject = assignment["assignments"][0]["unit_ref"]
        refund = experiment_event(
            len(document["events"]),
            {
                "event_type": "conversion",
                "metric_id": "marketing.conversions.total",
                "subject_id": control_subject,
                "variant_id": "control",
            },
        )
        refund["event"]["type"] = "refund"
        refund["measurement"].update(
            {
                "metric_id": "marketing.revenue.refunded",
                "value": 100,
                "unit": "currency",
                "currency": "USD",
            }
        )
        document["events"].append(refund)

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        control = next(
            item for item in analysis["analysis"]["variant_results"] if item["variant_id"] == "control"
        )

        self.assertEqual(0, control["refund_value"])
        self.assertEqual(control["numerator"], control["net_value"])

    def test_registry_receipts_block_posthoc_definition_and_assignment_registration(self) -> None:
        definition, assignment, _document = experiment_fixture()
        paths = resolve_paths(self.repo)
        ensure_layout(paths)

        with mock.patch("marketing_optimization_registry._utc_now", return_value="2026-08-02T00:00:00Z"):
            with self.assertRaisesRegex(OptimizationError, "registration must predate"):
                publish_registered_definition(paths, definition, dry_run=False)

        with mock.patch("marketing_optimization_registry._utc_now", return_value="2026-07-31T12:00:00Z"):
            registered = publish_registered_definition(paths, definition, dry_run=False)
        with mock.patch("marketing_optimization_registry._utc_now", return_value="2026-08-01T00:00:00Z"):
            with self.assertRaisesRegex(OptimizationError, "assignment registration must predate"):
                publish_registered_assignment(paths, registered, assignment, dry_run=False)

        with mock.patch("marketing_optimization_registry._utc_now", return_value="2026-07-31T18:00:00Z"):
            published = publish_registered_assignment(paths, registered, assignment, dry_run=False)
        self.assertEqual(assignment, published)
        assignment_path = assignment_artifact_path(paths, assignment["assignment_ref"])
        self.assertEqual(paths.assignments, assignment_path.parent)
        self.assertEqual(0o600, stat.S_IMODE(assignment_path.stat().st_mode))
        self.assertFalse(artifact_path(paths, "experiment", assignment["assignment_ref"]).exists())
        self.assertEqual(registered, registered_definition(paths, definition))
        self.assertEqual(assignment, registered_assignment(paths, registered, assignment))

    def test_registered_analysis_requires_look_and_assignment_receipts(self) -> None:
        definition, assignment, document = future_cli_experiment_fixture()
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        registered = publish_registered_definition(paths, definition, dry_run=False)
        snapshot = snapshot_from_document(document)
        analysed = analyze_experiment(
            registered,
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        run_ref = analysed["analysis"]["run_ref"]
        slot_ref = analysis_slot_reference(analysed["experiment_ref"], 1)
        run_path = artifact_path(paths, "experiment", run_ref)
        slot_path = artifact_path(paths, "experiment", slot_ref)
        immutable_json(paths, run_path, analysed)
        immutable_json(paths, slot_path, analysed)

        with self.assertRaisesRegex(OptimizationError, "registered optimization artifact is unavailable"):
            registered_analysis(paths, analysed)

        publish_registered_assignment(paths, registered, assignment, dry_run=False)
        publish_snapshot(paths, snapshot, dry_run=False)
        self.assertEqual(analysed, registered_analysis(paths, analysed))
        slot_path.unlink()
        with self.assertRaisesRegex(OptimizationError, "registered optimization artifact is unavailable"):
            registered_analysis(paths, analysed)

    def test_registered_analysis_recomputes_derived_statistics(self) -> None:
        definition, assignment, document = future_cli_experiment_fixture()
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        registered = publish_registered_definition(paths, definition, dry_run=False)
        publish_registered_assignment(paths, registered, assignment, dry_run=False)
        snapshot = snapshot_from_document(document)
        publish_snapshot(paths, snapshot, dry_run=False)
        forged = analyze_experiment(
            registered,
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        forged["analysis"]["variant_results"][0]["exposed_count"] += 1
        forged["analysis"].pop("run_ref")
        forged["analysis"]["run_ref"] = experiment_run_reference(forged["experiment_ref"], forged["analysis"])
        run_ref = forged["analysis"]["run_ref"]
        slot_ref = analysis_slot_reference(forged["experiment_ref"], 1)
        immutable_json(paths, artifact_path(paths, "experiment", run_ref), forged)
        immutable_json(paths, artifact_path(paths, "experiment", slot_ref), forged)

        with self.assertRaisesRegex(OptimizationError, "population counts are inconsistent"):
            registered_analysis(paths, forged)

    def test_registered_analysis_recursively_validates_predecessor_chain(self) -> None:
        definition, assignment, document = future_cli_experiment_fixture()
        definition["stopping_policy"].update(
            {"method": "sequential", "allowed_looks": 2, "alpha_spending": "pocock"}
        )
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        registered = publish_registered_definition(paths, definition, dry_run=False)
        publish_registered_assignment(paths, registered, assignment, dry_run=False)
        first_document = json.loads(json.dumps(document))
        first_as_of = parse_datetime(first_document["as_of"], "first as_of") - timedelta(days=1)
        first_document["as_of"] = first_as_of.isoformat().replace("+00:00", "Z")
        first_snapshot = snapshot_from_document(first_document)
        second_snapshot = snapshot_from_document(document)
        publish_snapshot(paths, first_snapshot, dry_run=False)
        publish_snapshot(paths, second_snapshot, dry_run=False)
        first = analyze_experiment(
            registered,
            first_snapshot,
            ExperimentAnalysisRequest(1, "interim", assignment),
        )
        second = analyze_experiment(
            first,
            second_snapshot,
            ExperimentAnalysisRequest(2, "final", assignment),
        )

        def publish_analysis(value: dict[str, object]) -> None:
            analysis = value["analysis"]
            run_ref = analysis["run_ref"]
            look_number = analysis["look_number"]
            immutable_json(paths, artifact_path(paths, "experiment", run_ref), value)
            immutable_json(
                paths,
                artifact_path(
                    paths,
                    "experiment",
                    analysis_slot_reference(value["experiment_ref"], look_number),
                ),
                value,
            )

        publish_analysis(first)
        publish_analysis(second)
        with self.assertRaisesRegex(OptimizationError, "registered optimization artifact is unavailable"):
            registered_analysis(paths, second)
        publish_successor_transition(paths, first, second, dry_run=False)
        self.assertEqual(second, registered_analysis(paths, second))

        for value in (first, second):
            analysis = value["analysis"]
            artifact_path(paths, "experiment", analysis["run_ref"]).unlink()
            artifact_path(
                paths,
                "experiment",
                analysis_slot_reference(value["experiment_ref"], analysis["look_number"]),
            ).unlink()

        forged_first = json.loads(json.dumps(first))
        forged_first["analysis"]["insufficient_reasons"].append("forged-predecessor")
        forged_first["analysis"].pop("run_ref")
        forged_first["analysis"]["run_ref"] = experiment_run_reference(
            forged_first["experiment_ref"],
            forged_first["analysis"],
        )
        forged_second = analyze_experiment(
            forged_first,
            second_snapshot,
            ExperimentAnalysisRequest(2, "final", assignment),
        )
        publish_analysis(forged_first)
        publish_successor_transition(paths, forged_first, forged_second, dry_run=False)
        publish_analysis(forged_second)

        with self.assertRaisesRegex(
            OptimizationError,
            "does not match recomputed immutable evidence",
        ):
            registered_analysis(paths, forged_second)

    def test_run_transition_slot_serializes_decisions_and_successors(self) -> None:
        def prepare(repo: Path) -> tuple[Any, dict[str, Any], dict[str, Any]]:
            definition, assignment, document = future_cli_experiment_fixture()
            definition["stopping_policy"].update(
                {"method": "sequential", "allowed_looks": 2, "alpha_spending": "pocock"}
            )
            paths = resolve_paths(repo)
            ensure_layout(paths)
            registered = publish_registered_definition(paths, definition, dry_run=False)
            publish_registered_assignment(paths, registered, assignment, dry_run=False)
            first_document = json.loads(json.dumps(document))
            first_as_of = parse_datetime(first_document["as_of"], "first as_of") - timedelta(days=1)
            first_document["as_of"] = first_as_of.isoformat().replace("+00:00", "Z")
            first_snapshot = snapshot_from_document(first_document)
            second_snapshot = snapshot_from_document(document)
            publish_snapshot(paths, first_snapshot, dry_run=False)
            publish_snapshot(paths, second_snapshot, dry_run=False)
            first = analyze_experiment(
                registered,
                first_snapshot,
                ExperimentAnalysisRequest(1, "interim", assignment),
            )
            second = analyze_experiment(
                first,
                second_snapshot,
                ExperimentAnalysisRequest(2, "final", assignment),
            )
            immutable_json(
                paths,
                artifact_path(paths, "experiment", first["analysis"]["run_ref"]),
                first,
            )
            immutable_json(
                paths,
                artifact_path(
                    paths,
                    "experiment",
                    analysis_slot_reference(first["experiment_ref"], 1),
                ),
                first,
            )
            return paths, first, second

        def decide(experiment: dict[str, Any]) -> dict[str, Any]:
            return record_experiment_decision(
                experiment,
                {
                    "status": "invalidated",
                    "winner_variant_id": None,
                    "reason": "The owner closed this run before another sequential look.",
                    "decided_at": experiment["analysis"]["as_of"],
                    "owner_approval_ref": "owner-approval-1",
                },
            )

        paths, first, second = prepare(self.repo)
        decided = decide(first)
        decision_ref = publish_decision_transition(paths, decided, dry_run=False)
        self.assertEqual(decision_ref, publish_decision_transition(paths, decided, dry_run=False))
        with self.assertRaisesRegex(OptimizationError, "already has an owner decision"):
            publish_successor_transition(paths, first, second, dry_run=False)

        reverse_repo = self.root / "successor-first-repo"
        reverse_repo.mkdir()
        reverse_paths, reverse_first, reverse_second = prepare(reverse_repo)
        receipt = publish_successor_transition(
            reverse_paths,
            reverse_first,
            reverse_second,
            dry_run=False,
        )
        self.assertEqual(
            receipt,
            publish_successor_transition(
                reverse_paths,
                reverse_first,
                reverse_second,
                dry_run=False,
            ),
        )
        immutable_json(
            reverse_paths,
            artifact_path(reverse_paths, "experiment", reverse_second["analysis"]["run_ref"]),
            reverse_second,
        )
        immutable_json(
            reverse_paths,
            artifact_path(
                reverse_paths,
                "experiment",
                analysis_slot_reference(reverse_second["experiment_ref"], 2),
            ),
            reverse_second,
        )
        self.assertEqual(reverse_second, registered_analysis(reverse_paths, reverse_second))
        with self.assertRaisesRegex(OptimizationError, "already has a successor analysis"):
            publish_decision_transition(reverse_paths, decide(reverse_first), dry_run=False)

        transition_path = artifact_path(
            reverse_paths,
            "experiment",
            run_transition_slot_reference(
                reverse_first["experiment_ref"],
                reverse_first["analysis"]["run_ref"],
            ),
        )
        transition_path.unlink()
        with self.assertRaisesRegex(OptimizationError, "registered optimization artifact is unavailable"):
            registered_analysis(reverse_paths, reverse_second)

    def test_registered_artifacts_recompute_nested_immutable_evidence(self) -> None:
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        snapshot = snapshot_from_document(aggregate_analysis_document())
        publish_snapshot(paths, snapshot, dry_run=False)

        attribution = build_attribution(snapshot, attribution_request(model="direct"))
        immutable_json(
            paths,
            artifact_path(paths, "attribution", attribution["attribution_ref"]),
            attribution,
        )
        self.assertEqual(attribution, registered_attribution(paths, attribution))

        forged_attribution = json.loads(json.dumps(attribution))
        forged_attribution["allocations"][0]["channel"] = "social"
        forged_attribution.pop("attribution_ref")
        forged_attribution["attribution_ref"] = typed_reference(
            "mkt-attribution-v1",
            forged_attribution,
        )
        immutable_json(
            paths,
            artifact_path(paths, "attribution", forged_attribution["attribution_ref"]),
            forged_attribution,
        )
        with self.assertRaisesRegex(OptimizationError, "attribution does not match recomputed"):
            registered_attribution(paths, forged_attribution)

        report = build_report(
            snapshot,
            [attribution],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        immutable_json(paths, report_artifact_path(paths, report["report_ref"]), report)
        self.assertEqual(report, registered_report(paths, report))

        forged_report = json.loads(json.dumps(report))
        visible_row = next(row for row in forged_report["performance"]["rows"] if not row["suppressed"])
        visible_row["channel"] = "social"
        forged_report.pop("report_ref")
        forged_report["report_ref"] = typed_reference("mkt-report-v1", forged_report)
        immutable_json(
            paths,
            report_artifact_path(paths, forged_report["report_ref"]),
            forged_report,
        )
        with self.assertRaisesRegex(OptimizationError, "report does not match recomputed"):
            registered_report(paths, forged_report)

        policy = RecommendationPolicy(owner="growth-owner", required_approval="owner-approval")
        recommendation = build_recommendations(report, policy)[0]
        immutable_json(
            paths,
            artifact_path(paths, "recommendation", recommendation["recommendation_ref"]),
            recommendation,
        )
        self.assertEqual(recommendation, registered_recommendation(paths, recommendation))

        forged_recommendation = json.loads(json.dumps(recommendation))
        forged_recommendation["finding"]["observation"] = "A forged summary overstates the immutable report evidence."
        forged_recommendation.pop("recommendation_ref")
        forged_recommendation["recommendation_ref"] = typed_reference(
            "mkt-recommendation-v1",
            forged_recommendation,
        )
        immutable_json(
            paths,
            artifact_path(
                paths,
                "recommendation",
                forged_recommendation["recommendation_ref"],
            ),
            forged_recommendation,
        )
        with self.assertRaisesRegex(OptimizationError, "recommendation does not match recomputed"):
            registered_recommendation(paths, forged_recommendation)

        configured = json.loads(paths.config.read_text(encoding="utf-8"))
        configured["default_minimum_cell_size"] = MINIMUM_AGGREGATE_CELL_SIZE + 1
        paths.config.write_text(json.dumps(configured), encoding="utf-8")
        with self.assertRaisesRegex(OptimizationError, "configured privacy floor"):
            registered_attribution(paths, attribution)
        with self.assertRaisesRegex(OptimizationError, "configured privacy floor"):
            registered_report(paths, report)

    def test_registered_attribution_replays_requested_currency_mismatches(self) -> None:
        document = analysis_document()
        outcome = document["events"][1]
        outcome["event"]["type"] = "revenue"
        outcome["measurement"].update(
            {
                "metric_id": "marketing.revenue.gross",
                "value": 100,
                "unit": "currency",
                "currency": "EUR",
            }
        )
        snapshot = snapshot_from_document(aggregate_snapshot_document(document))
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        publish_snapshot(paths, snapshot, dry_run=False)
        attribution = build_attribution(
            snapshot,
            attribution_request(outcome_metric_id="marketing.revenue.gross", currency="USD"),
        )
        self.assertNotIn("requested_currency", attribution["scope"])
        self.assertIsNone(attribution["scope"]["currency"])
        immutable_json(
            paths,
            artifact_path(paths, "attribution", attribution["attribution_ref"]),
            attribution,
        )

        self.assertEqual(attribution, registered_attribution(paths, attribution))

    def test_experiment_identity_versions_are_atomic_and_require_linear_supersession(self) -> None:
        definition, _assignment, _document = experiment_fixture()
        paths = resolve_paths(self.repo)
        ensure_layout(paths)
        before_start = "2026-07-31T12:00:00Z"
        with mock.patch("marketing_optimization_registry._utc_now", return_value=before_start):
            first = publish_registered_definition(paths, definition, dry_run=False)

        changed = json.loads(json.dumps(definition))
        changed["hypothesis"]["rationale"] = "A conflicting rationale must use a new definition version."
        with mock.patch("marketing_optimization_registry._utc_now", return_value=before_start):
            with self.assertRaisesRegex(OptimizationError, "already identify different content"):
                publish_registered_definition(paths, changed, dry_run=False)

        successor = json.loads(json.dumps(definition))
        successor["definition_version"] = 2
        successor["approval_ref"] = "owner-approval-2"
        successor["provenance"]["supersedes"] = first["experiment_ref"]
        successor.pop("experiment_ref", None)
        with mock.patch("marketing_optimization_registry._utc_now", return_value=before_start):
            second = publish_registered_definition(paths, successor, dry_run=False)
        self.assertEqual(2, second["definition_version"])
        self.assertEqual(first["experiment_ref"], second["provenance"]["supersedes"])

        skipped = json.loads(json.dumps(successor))
        skipped["definition_version"] = 3
        skipped["provenance"]["supersedes"] = first["experiment_ref"]
        skipped.pop("experiment_ref", None)
        with mock.patch("marketing_optimization_registry._utc_now", return_value=before_start):
            with self.assertRaisesRegex(OptimizationError, "preceding registered version"):
                publish_registered_definition(paths, skipped, dry_run=False)

        with mock.patch("marketing_optimization_registry._utc_now", return_value="2026-08-20T00:00:00Z"):
            self.assertEqual(first, publish_registered_definition(paths, definition, dry_run=False))

    def test_missing_assignment_and_small_samples_never_produce_winners(self) -> None:
        definition, _assignment, document = experiment_fixture()
        snapshot = snapshot_from_document(document)

        missing = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final"),
        )
        self.assertFalse(missing["analysis"]["decision_eligible"])
        self.assertIsNone(missing["analysis"]["winner_variant_id"])
        self.assertIn("verified_assignment_required", missing["analysis"]["insufficient_reasons"])

        definition["sample_plan"]["required_sample_per_variant"] = 300
        assignment = experiment_fixture()[1]
        undersized = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )
        self.assertFalse(undersized["analysis"]["decision_eligible"])
        self.assertIsNone(undersized["analysis"]["winner_variant_id"])
        self.assertIn("sample_size_not_met", undersized["analysis"]["insufficient_reasons"])

    def test_sample_peeking_and_stale_sources_block_fixed_horizon_winner(self) -> None:
        definition, assignment, document = experiment_fixture()
        document["as_of"] = "2026-08-05T00:00:00Z"
        document["sources"][0]["stale"] = True
        document["sources"][0]["status"] = "stale"
        snapshot = snapshot_from_document(document)

        analysis = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="interim", assignment_document=assignment),
        )

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertIn("fixed_horizon_not_complete", analysis["analysis"]["insufficient_reasons"])
        self.assertIn("stale_source", analysis["analysis"]["insufficient_reasons"])

    def test_source_presence_and_preregistered_quality_gates_fail_closed(self) -> None:
        definition, assignment, document = experiment_fixture()
        missing_sources = json.loads(json.dumps(document))
        missing_sources["sources"] = []

        missing = analyze_experiment(
            definition,
            snapshot_from_document(missing_sources),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertFalse(missing["analysis"]["decision_eligible"])
        self.assertIn("missing_sources", missing["analysis"]["insufficient_reasons"])

        self_described = json.loads(json.dumps(document))
        self_described["sources"][0].update(
            {
                "coverage": "partial",
                "last_observed_at": "2026-08-03T12:00:00Z",
                "stale_after_seconds": 1,
                "lag_seconds": 0,
                "stale": False,
                "status": "ready",
            }
        )
        gated = analyze_experiment(
            definition,
            snapshot_from_document(self_described),
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        self.assertFalse(gated["analysis"]["decision_eligible"])
        self.assertIn("partial_coverage", gated["analysis"]["insufficient_reasons"])
        self.assertIn("stale_source", gated["analysis"]["insufficient_reasons"])

        relaxed = json.loads(json.dumps(definition))
        relaxed["data_policy"]["require_complete_coverage"] = False
        relaxed["data_policy"]["require_fresh_sources"] = False
        preregistered = analyze_experiment(
            relaxed,
            snapshot_from_document(self_described),
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        self.assertTrue(preregistered["analysis"]["decision_eligible"])
        self.assertNotIn("partial_coverage", preregistered["analysis"]["insufficient_reasons"])
        self.assertNotIn("stale_source", preregistered["analysis"]["insufficient_reasons"])

    def test_unknown_source_freshness_cannot_satisfy_required_gate(self) -> None:
        definition, assignment, document = experiment_fixture()
        document["sources"][0]["last_observed_at"] = None
        document["sources"][0]["lag_seconds"] = None

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIn("unknown_source_freshness", analysis["analysis"]["insufficient_reasons"])

    def test_degraded_event_quality_blocks_causality_and_degrades_reports(self) -> None:
        definition, assignment, document = experiment_fixture()
        for event in document["events"]:
            event["quality"]["effective_confidence"] = "medium"
            event["quality"]["completeness"] = "partial"
        snapshot = snapshot_from_document(document)

        analysis = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        report = build_report(snapshot, [], [], MINIMUM_AGGREGATE_CELL_SIZE)

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertNotEqual("causal_supported", analysis["analysis"]["causal_status"])
        self.assertIn("insufficient_event_confidence", analysis["analysis"]["insufficient_reasons"])
        self.assertIn("partial_coverage", analysis["analysis"]["insufficient_reasons"])
        self.assertEqual("partial", report["run"]["status"])
        self.assertEqual("partial", report["quality"]["freshness"])
        self.assertEqual("medium", report["quality"]["data_confidence"])
        self.assertEqual(0, report["quality"]["coverage"])
        self.assertIn("insufficient_event_confidence", report["quality"]["reasons"])

    def test_missing_guardrail_observations_block_decisions(self) -> None:
        definition, assignment, document = experiment_fixture()
        document["events"] = [
            event
            for event in document["events"]
            if event["measurement"]["metric_id"] != "marketing.unsubscribes.total"
        ]

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertEqual("insufficient_evidence", analysis["analysis"]["guardrails"][0]["status"])
        self.assertIn("guardrail_evidence_missing", analysis["analysis"]["insufficient_reasons"])

    def test_sequential_looks_require_a_monotonic_run_chain(self) -> None:
        definition, assignment, document = experiment_fixture(
            {"control_conversions": 1, "treatment_conversions": 1}
        )
        definition["stopping_policy"].update(
            {"method": "sequential", "allowed_looks": 2, "alpha_spending": "pocock"}
        )
        first_document = json.loads(json.dumps(document))
        first_document["as_of"] = "2026-08-05T00:00:00Z"
        first = analyze_experiment(
            definition,
            snapshot_from_document(first_document),
            ExperimentAnalysisRequest(look_number=1, look_type="interim", assignment_document=assignment),
        )

        self.assertIsNone(first["analysis"]["previous_run_ref"])
        with self.assertRaisesRegex(OptimizationError, "must start at one"):
            analyze_experiment(
                definition,
                snapshot_from_document(document),
                ExperimentAnalysisRequest(look_number=2, look_type="final", assignment_document=assignment),
            )

        second = analyze_experiment(
            first,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(look_number=2, look_type="final", assignment_document=assignment),
        )
        self.assertEqual(first["analysis"]["run_ref"], second["analysis"]["previous_run_ref"])
        self.assert_schema(EXPERIMENT_SCHEMA, second)
        with self.assertRaisesRegex(OptimizationError, "advance exactly once"):
            analyze_experiment(
                first,
                snapshot_from_document(document),
                ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
            )

    def test_analysis_run_references_are_namespaced_by_experiment(self) -> None:
        definition, assignment, document = experiment_fixture()
        second_definition = json.loads(json.dumps(definition))
        second_assignment = json.loads(json.dumps(assignment))
        second_definition["experiment_id"] = "landing-page-test-two"
        second_assignment["experiment_id"] = "landing-page-test-two"
        second_assignment.pop("assignment_ref")
        second_assignment["assignment_ref"] = typed_reference("mkt-assignment-v1:sha256", second_assignment)
        second_definition["assignment"]["snapshot_ref"] = second_assignment["assignment_ref"]
        snapshot = snapshot_from_document(document)

        first = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        second = analyze_experiment(
            second_definition,
            snapshot,
            ExperimentAnalysisRequest(1, "final", second_assignment),
        )

        self.assertEqual(first["analysis"]["variant_results"], second["analysis"]["variant_results"])
        self.assertNotEqual(first["experiment_ref"], second["experiment_ref"])
        self.assertNotEqual(first["analysis"]["run_ref"], second["analysis"]["run_ref"])

    def test_pre_exposure_outcomes_cannot_create_a_causal_winner(self) -> None:
        definition, assignment, document = experiment_fixture()
        for event in document["events"]:
            dimensions = event["scope"]["dimensions"]
            if dimensions["experiment_variant"] == "treatment" and event["event"]["type"] == "conversion":
                event["event"]["occurred_at"] = "2026-08-01T12:00:00Z"

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )
        treatment = next(item for item in analysis["analysis"]["variant_results"] if item["variant_id"] == "treatment")

        self.assertTrue(treatment["suppressed"])
        self.assertIsNone(treatment["numerator"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertNotEqual("causal_supported", analysis["analysis"]["causal_status"])
        self.assertIn("pre_exposure_events_excluded", analysis["analysis"]["insufficient_reasons"])

    def test_uncertain_identities_cannot_supply_experiment_samples(self) -> None:
        definition, assignment, document = experiment_fixture()
        mark_uncertain_identities(document, "split")

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "final", assignment),
        )

        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertNotEqual("causal_supported", analysis["analysis"]["causal_status"])
        self.assertIn("identity_ambiguity", analysis["analysis"]["insufficient_reasons"])
        self.assertTrue(all(item["suppressed"] for item in analysis["analysis"]["variant_results"]))

    def test_assignment_imbalance_invalidates_causal_analysis(self) -> None:
        definition, assignment, document = experiment_fixture(
            {"control_subjects": 475, "treatment_subjects": 25, "treatment_conversions": 10}
        )
        snapshot = snapshot_from_document(document)

        analysis = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )

        self.assertEqual("invalid", analysis["analysis"]["status"])
        self.assertEqual("invalid", analysis["analysis"]["causal_status"])
        self.assertIn("assignment_integrity_invalid", analysis["analysis"]["insufficient_reasons"])

    def test_preregistered_safety_look_can_only_stop_on_guardrail_breach(self) -> None:
        definition, assignment, document = experiment_fixture({"treatment_guardrails": 50})
        snapshot = snapshot_from_document(document)

        analysis = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="safety", assignment_document=assignment),
        )

        self.assertEqual("guardrail_breach", analysis["analysis"]["status"])
        self.assertTrue(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertNotEqual("causal_supported", analysis["analysis"]["causal_status"])
        self.assertEqual("breach", analysis["analysis"]["guardrails"][0]["status"])

        final = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )
        self.assertEqual("guardrail_breach", final["analysis"]["status"])
        self.assertIsNone(final["analysis"]["winner_variant_id"])
        self.assertNotEqual("causal_supported", final["analysis"]["causal_status"])
        with self.assertRaisesRegex(OptimizationError, "guardrail-stop"):
            record_experiment_decision(
                final,
                {
                    "status": "no_winner",
                    "winner_variant_id": None,
                    "reason": "Do not continue while the preregistered guardrail is breached.",
                    "decided_at": AS_OF,
                    "owner_approval_ref": "owner-approval-1",
                },
            )
        stopped = record_experiment_decision(
            final,
            {
                "status": "guardrail_stop",
                "winner_variant_id": None,
                "reason": "Stop because the preregistered guardrail is breached.",
                "decided_at": AS_OF,
                "owner_approval_ref": "owner-approval-1",
            },
        )
        self.assertEqual("decided", stopped["lifecycle"])

    def test_safety_look_without_breach_cannot_select_a_winner(self) -> None:
        definition, assignment, document = experiment_fixture()

        analysis = analyze_experiment(
            definition,
            snapshot_from_document(document),
            ExperimentAnalysisRequest(1, "safety", assignment),
        )

        self.assertEqual("insufficient_evidence", analysis["analysis"]["status"])
        self.assertFalse(analysis["analysis"]["decision_eligible"])
        self.assertIsNone(analysis["analysis"]["winner_variant_id"])
        self.assertEqual("insufficient_evidence", analysis["analysis"]["causal_status"])
        self.assertIn("safety_look_without_guardrail_breach", analysis["analysis"]["insufficient_reasons"])

    def test_reports_distinguish_outcomes_and_recommendations_remain_approval_bound(self) -> None:
        definition, assignment, document = experiment_fixture()
        snapshot = snapshot_from_document(document)
        experiment = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )
        attribution = build_attribution(snapshot, attribution_request())

        report = build_report(
            snapshot,
            [attribution],
            [experiment],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        recommendations = build_recommendations(
            report,
            RecommendationPolicy(owner="growth-owner", required_approval="owner-approval"),
        )

        self.assertEqual("complete", report["run"]["status"])
        self.assertIn("reach", report["performance"]["categories"])
        self.assertIn("conversion", report["performance"]["categories"])
        self.assertIn("Observational performance", render_report_markdown(report))
        self.assertEqual("causal_experiment", recommendations[0]["evidence_rank"])
        self.assertEqual("review_required", recommendations[0]["status"])
        self.assertEqual("not_requested", recommendations[0]["authority"]["approval_status"])
        self.assertEqual(
            {"publish", "message", "spend", "retarget", "change_offer", "mutate_account", "export_audience"},
            set(recommendations[0]["authority"]["forbidden_side_effects"]),
        )
        self.assertEqual(
            recommendations,
            build_recommendations(
                report,
                RecommendationPolicy(owner="growth-owner", required_approval="owner-approval"),
            ),
        )
        for recommendation in recommendations:
            expected_operator = {
                "higher_is_better": "less_than",
                "lower_is_better": "greater_than",
                "neutral": "not_applicable",
            }[recommendation["target_metric"]["direction"]]
            self.assertEqual(expected_operator, recommendation["rollback"]["operator"])
            self.assertEqual(
                recommendation["target_metric"]["metric_id"],
                recommendation["rollback"]["trigger_metric"],
            )
            self.assert_schema(RECOMMENDATION_SCHEMA, recommendation)

        forged_attribution = json.loads(json.dumps(attribution))
        forged_attribution["causal_assessment"]["statement"] = "This forged wording claims causal lift."
        forged_attribution.pop("attribution_ref")
        forged_attribution["attribution_ref"] = typed_reference("mkt-attribution-v1", forged_attribution)
        with self.assertRaisesRegex(OptimizationError, "causal statement is not canonical"):
            validate_attribution_artifact(forged_attribution)

        forged_report = json.loads(json.dumps(report))
        forged_report["interpretation"]["causal_statement"] = "This forged report claims causal growth."
        forged_report.pop("report_ref")
        forged_report["report_ref"] = typed_reference("mkt-report-v1", forged_report)
        with self.assertRaisesRegex(OptimizationError, "report causal statement is not canonical"):
            validate_report_artifact(forged_report)

        exposed_suppressed = json.loads(json.dumps(report))
        exposed_suppressed["experiments"][0]["variant_results"][0]["suppressed"] = True
        exposed_suppressed.pop("report_ref")
        exposed_suppressed["report_ref"] = typed_reference("mkt-report-v1", exposed_suppressed)
        with self.assertRaisesRegex(OptimizationError, "exposes a suppressed experiment cell"):
            validate_report_artifact(exposed_suppressed)

        below_floor = json.loads(json.dumps(report))
        below_floor["experiments"][0]["variant_results"][0]["exposed_count"] = 1
        below_floor["experiments"][0]["variant_results"][0]["eligible_count"] = 1
        below_floor.pop("report_ref")
        below_floor["report_ref"] = typed_reference("mkt-report-v1", below_floor)
        with self.assertRaisesRegex(OptimizationError, "visible below the report privacy floor"):
            validate_report_artifact(below_floor)

        forged_recommendation = json.loads(json.dumps(recommendations[0]))
        forged_recommendation["causal_assessment"]["allowed_wording"] = "This forged recommendation overclaims causality."
        forged_recommendation.pop("recommendation_ref")
        forged_recommendation["recommendation_ref"] = typed_reference(
            "mkt-recommendation-v1",
            forged_recommendation,
        )
        with self.assertRaisesRegex(OptimizationError, "causal wording is not canonical"):
            validate_recommendation_artifact(forged_recommendation)

    def test_recommendation_rollback_comparator_is_executable_and_metric_bound(self) -> None:
        definition, assignment, document = experiment_fixture()
        snapshot = snapshot_from_document(document)
        experiment = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        report = build_report(
            snapshot,
            [],
            [experiment],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        recommendation = build_recommendations(
            report,
            RecommendationPolicy(owner="growth-owner", required_approval="owner-approval"),
        )[0]

        contradictory = json.loads(json.dumps(recommendation))
        contradictory["rollback"]["operator"] = "greater_than"
        contradictory.pop("recommendation_ref")
        contradictory["recommendation_ref"] = typed_reference(
            "mkt-recommendation-v1",
            contradictory,
        )
        with self.assertRaisesRegex(OptimizationError, "contradicts its target direction"):
            validate_recommendation_artifact(contradictory)

        mismatched = json.loads(json.dumps(recommendation))
        mismatched["rollback"]["trigger_metric"] = "marketing.revenue.gross"
        mismatched.pop("recommendation_ref")
        mismatched["recommendation_ref"] = typed_reference(
            "mkt-recommendation-v1",
            mismatched,
        )
        with self.assertRaisesRegex(OptimizationError, "must match its target metric"):
            validate_recommendation_artifact(mismatched)

    def test_reports_reject_tampered_cross_snapshot_and_unverified_causal_evidence(self) -> None:
        definition, assignment, document = experiment_fixture()
        snapshot = snapshot_from_document(document)
        experiment = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )
        attribution = build_attribution(snapshot, attribution_request())

        with self.assertRaisesRegex(OptimizationError, "does not match the report snapshot"):
            build_report(
                snapshot_from_document(analysis_document()),
                [attribution],
                [],
                minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
            )

        mismatched_scope = json.loads(json.dumps(attribution))
        mismatched_scope["scope"]["campaign_id"] = "concurrent-campaign"
        mismatched_scope.pop("attribution_ref")
        mismatched_scope["attribution_ref"] = typed_reference("mkt-attribution-v1", mismatched_scope)
        with self.assertRaisesRegex(OptimizationError, "scope does not match"):
            build_report(
                snapshot,
                [mismatched_scope],
                [],
                minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
            )

        tampered_experiment = json.loads(json.dumps(experiment))
        tampered_experiment["analysis"]["winner_variant_id"] = "control"
        with self.assertRaisesRegex(OptimizationError, "winner does not match its strongest comparison"):
            build_report(
                snapshot,
                [],
                [tampered_experiment],
                minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
            )

        report = build_report(
            snapshot,
            [attribution],
            [experiment],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        report["experiments"][0]["assignment"]["verification"] = "unverified"
        report.pop("report_ref")
        report["report_ref"] = typed_reference("mkt-report-v1", report)
        with self.assertRaisesRegex(OptimizationError, "lacks verified randomized assignment"):
            build_recommendations(
                report,
                RecommendationPolicy(owner="growth-owner", required_approval="owner-approval"),
            )

    def test_changed_report_supersedes_matching_recommendation_without_duplicates(self) -> None:
        definition, assignment, document = experiment_fixture()
        snapshot = snapshot_from_document(document)
        experiment = analyze_experiment(
            definition,
            snapshot,
            ExperimentAnalysisRequest(look_number=1, look_type="final", assignment_document=assignment),
        )
        first_attribution = build_attribution(snapshot, attribution_request(model="last_touch"))
        first_report = build_report(
            snapshot,
            [first_attribution],
            [experiment],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        policy = RecommendationPolicy(owner="growth-owner", required_approval="owner-approval")
        first = build_recommendations(first_report, policy)
        second_attribution = build_attribution(snapshot, attribution_request(model="direct"))
        second_report = build_report(
            snapshot,
            [second_attribution],
            [experiment],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )

        second = build_recommendations(second_report, policy, prior_recommendations=first)
        first_causal = next(item for item in first if item["evidence_rank"] == "causal_experiment")
        second_causal = next(item for item in second if item["evidence_rank"] == "causal_experiment")

        self.assertEqual(first_causal["recommendation_key"], second_causal["recommendation_key"])
        self.assertEqual(first_causal["recommendation_ref"], second_causal["provenance"]["supersedes"])
        self.assertNotEqual(first_causal["recommendation_ref"], second_causal["recommendation_ref"])
        self.assertEqual(len(second), len({item["recommendation_key"] for item in second}))

    def test_sparse_report_emits_only_instrumentation_recommendation(self) -> None:
        snapshot = snapshot_from_document(analysis_document())

        report = build_report(snapshot, [], [], minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE)
        recommendations = build_recommendations(
            report,
            RecommendationPolicy(owner="growth-owner", required_approval="owner-approval"),
        )

        self.assertEqual("partial", report["run"]["status"])
        self.assertEqual(1, len(recommendations))
        self.assertEqual("instrument", recommendations[0]["action"]["type"])
        self.assertEqual("insufficient_evidence", recommendations[0]["status"])
        self.assertTrue(recommendations[0]["uncertainty"]["contradictions"])
        self.assert_schema(RECOMMENDATION_SCHEMA, recommendations[0])

    def test_external_report_validation_enforces_privacy_invariants(self) -> None:
        sparse = build_report(
            snapshot_from_document(analysis_document()),
            [],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        leaked = json.loads(json.dumps(sparse))
        leaked_row = next(row for row in leaked["performance"]["rows"] if row["suppressed"])
        leaked_row["value"] = 1
        leaked.pop("report_ref")
        leaked["report_ref"] = typed_reference("mkt-report-v1", leaked)
        with self.assertRaisesRegex(OptimizationError, "suppressed report cell"):
            validate_report_artifact(leaked)

        visible = build_report(
            snapshot_from_document(aggregate_analysis_document()),
            [],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        visible_row = next(
            row for row in visible["performance"]["rows"] if not row["suppressed"]
        )
        self.assertGreaterEqual(
            visible_row["record_count"],
            MINIMUM_AGGREGATE_CELL_SIZE,
        )
        forged = json.loads(json.dumps(visible))
        next(
            row for row in forged["performance"]["rows"] if not row["suppressed"]
        )["record_count"] = 1
        forged.pop("report_ref")
        forged["report_ref"] = typed_reference("mkt-report-v1", forged)
        with self.assertRaisesRegex(OptimizationError, "below the privacy floor"):
            validate_report_artifact(forged)

    def test_uncertain_identity_aliases_do_not_unsuppress_report_cells(self) -> None:
        document = mark_uncertain_identities(aggregate_analysis_document(), "ambiguous")

        report = build_report(
            snapshot_from_document(document),
            [],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )

        self.assertTrue(report["performance"]["rows"])
        self.assertTrue(all(row["suppressed"] for row in report["performance"]["rows"]))
        self.assertTrue(all(row["record_count"] is None for row in report["performance"]["rows"]))

    def test_novelty_and_seasonality_contexts_remain_separate(self) -> None:
        document = analysis_document()
        first_outcome = document["events"][1]
        first_outcome["scope"]["dimensions"] = {"cohort": "novel", "environment": "seasonal"}
        second_outcome = json.loads(json.dumps(first_outcome))
        second_outcome["record_ref"] = reference("mkt-record-v1", "8")
        second_outcome["event_ref"] = reference("mkt-event-v1", "8")
        second_outcome["source"]["evidence_ref"] = reference("mkt-evidence-v1:sha256", "8")
        second_outcome["quality"]["evidence_ref"] = second_outcome["source"]["evidence_ref"]
        second_outcome["scope"]["outcome_id"] = "outcome-b"
        second_outcome["scope"]["dimensions"] = {"cohort": "established", "environment": "baseline"}
        document["events"].append(second_outcome)
        document = aggregate_snapshot_document(document)

        report = build_report(
            snapshot_from_document(document),
            [],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        conversions = [row for row in report["performance"]["rows"] if row["category"] == "conversion"]

        self.assertEqual(2, len(conversions))
        self.assertEqual(
            [
                {"cohort": "established", "environment": "baseline"},
                {"cohort": "novel", "environment": "seasonal"},
            ],
            [row["dimensions"] for row in conversions],
        )
        self.assertEqual(
            [MINIMUM_AGGREGATE_CELL_SIZE, MINIMUM_AGGREGATE_CELL_SIZE],
            [row["value"] for row in conversions],
        )

    def test_no_data_report_fails_closed_to_instrumentation(self) -> None:
        document = analysis_document()
        document["events"] = []
        document["subjects"] = []
        snapshot = snapshot_from_document(document)

        attribution = build_attribution(snapshot, attribution_request())
        report = build_report(
            snapshot,
            [attribution],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        recommendations = build_recommendations(
            report,
            RecommendationPolicy(owner="growth-owner", required_approval="owner-approval"),
        )

        self.assertEqual("insufficient_evidence", attribution["run"]["status"])
        self.assertEqual("insufficient_evidence", report["run"]["status"])
        self.assertEqual("instrument", recommendations[0]["action"]["type"])

    def test_cli_requires_registered_experiment_evidence_and_single_decision(self) -> None:
        definition, assignment, document = future_cli_experiment_fixture()
        definition_path = self.root / "experiment-definition.json"
        assignment_path = self.root / "assignment-snapshot.json"
        snapshot_path = self.root / "experiment-snapshot.json"
        definition_path.write_text(json.dumps(definition), encoding="utf-8")
        assignment_path.write_text(json.dumps(assignment), encoding="utf-8")
        snapshot_path.write_text(json.dumps(document), encoding="utf-8")
        self.command("init", "--repo", str(self.repo))

        analyze_arguments = (
            "experiment-analyze",
            "--repo",
            str(self.repo),
            "--definition",
            str(definition_path),
            "--assignment-snapshot",
            str(assignment_path),
            "--input",
            str(snapshot_path),
            "--look-number",
            "1",
            "--look-type",
            "final",
        )
        self.command(*analyze_arguments, expected=1)
        registered = json.loads(
            self.command(
                "experiment-register",
                "--repo",
                str(self.repo),
                "--definition",
                str(definition_path),
            ).stdout
        )
        self.command(*analyze_arguments, expected=1)
        assignment_registration = self.command(
            "experiment-assignment-register",
            "--repo",
            str(self.repo),
            "--definition",
            str(definition_path),
            "--assignment-snapshot",
            str(assignment_path),
        )
        assignment_receipt = json.loads(assignment_registration.stdout)
        self.assertNotIn("assignments", assignment_receipt)
        self.assertNotIn(assignment["assignments"][0]["unit_ref"], assignment_registration.stdout)
        self.assertEqual(assignment["assignment_ref"], assignment_receipt["assignment_ref"])
        self.command(*analyze_arguments, "--dry-run", expected=1)
        analysed = json.loads(self.command(*analyze_arguments).stdout)
        self.assertEqual(registered["experiment_ref"], analysed["experiment_ref"])
        self.assertEqual(analysed, json.loads(self.command(*analyze_arguments).stdout))

        changed_document = json.loads(json.dumps(document))
        changed_document["sources"][0]["lag_seconds"] = 1
        changed_path = self.root / "changed-experiment-snapshot.json"
        changed_path.write_text(json.dumps(changed_document), encoding="utf-8")
        changed_arguments = list(analyze_arguments)
        changed_arguments[changed_arguments.index(str(snapshot_path))] = str(changed_path)
        self.command(*changed_arguments, expected=1)

        paths = resolve_paths(self.repo)
        analysis_path = artifact_path(paths, "experiment", analysed["analysis"]["run_ref"])
        first_decision = self.root / "decision-one.json"
        second_decision = self.root / "decision-two.json"
        first_decision.write_text(
            json.dumps(
                {
                    "status": "winner",
                    "winner_variant_id": "treatment",
                    "reason": "Approve the eligible treatment for an owner-reviewed handoff.",
                    "decided_at": document["as_of"],
                    "owner_approval_ref": "owner-approval-1",
                }
            ),
            encoding="utf-8",
        )
        second_decision.write_text(
            json.dumps(
                {
                    "status": "winner",
                    "winner_variant_id": "treatment",
                    "reason": "Record a conflicting second rationale for the same run.",
                    "decided_at": document["as_of"],
                    "owner_approval_ref": "owner-approval-2",
                }
            ),
            encoding="utf-8",
        )
        self.command(
            "experiment-decide",
            "--repo",
            str(self.repo),
            "--experiment",
            str(analysis_path),
            "--decision",
            str(first_decision),
        )
        self.command(
            "experiment-decide",
            "--repo",
            str(self.repo),
            "--experiment",
            str(analysis_path),
            "--decision",
            str(second_decision),
            expected=1,
        )

    def test_cli_resolves_only_registered_external_evidence(self) -> None:
        snapshot_document_value = analysis_document()
        snapshot = snapshot_from_document(snapshot_document_value)
        snapshot_path = self.root / "registered-evidence-snapshot.json"
        snapshot_path.write_text(json.dumps(snapshot_document_value), encoding="utf-8")
        self.command("init", "--repo", str(self.repo))

        unregistered_attribution = build_attribution(
            snapshot,
            attribution_request(model="last_touch", model_version=99),
        )
        unregistered_attribution_path = self.root / "unregistered-attribution.json"
        unregistered_attribution_path.write_text(json.dumps(unregistered_attribution), encoding="utf-8")
        missing_attribution = self.command(
            "report",
            "--repo",
            str(self.repo),
            "--input",
            str(snapshot_path),
            "--attribution",
            str(unregistered_attribution_path),
            "--minimum-cell-size",
            str(MINIMUM_AGGREGATE_CELL_SIZE),
            expected=1,
        )
        self.assertIn("registered optimization artifact is unavailable", missing_attribution.stderr)

        attribution = self.cli_attribution(snapshot_path, "direct")
        tampered_attribution = json.loads(json.dumps(attribution))
        tampered_attribution["allocations"][0]["channel"] = "Jane Doe"
        tampered_attribution_path = self.root / "tampered-attribution.json"
        tampered_attribution_path.write_text(json.dumps(tampered_attribution), encoding="utf-8")
        unsafe_attribution = self.command(
            "report",
            "--repo",
            str(self.repo),
            "--input",
            str(snapshot_path),
            "--attribution",
            str(tampered_attribution_path),
            "--minimum-cell-size",
            str(MINIMUM_AGGREGATE_CELL_SIZE),
            expected=1,
        )
        self.assertIn("bounded lowercase alias", unsafe_attribution.stderr)

        paths = resolve_paths(self.repo)
        attribution_path = artifact_path(paths, "attribution", attribution["attribution_ref"])
        report = json.loads(
            self.command(
                "report",
                "--repo",
                str(self.repo),
                "--input",
                str(snapshot_path),
                "--attribution",
                str(attribution_path),
                "--minimum-cell-size",
                str(MINIMUM_AGGREGATE_CELL_SIZE),
            ).stdout
        )
        report_path = paths.report_drafts / report["report_ref"].replace(":", "-") / "report.json"

        unregistered_report = build_report(
            snapshot,
            [],
            [],
            minimum_cell_size=MINIMUM_AGGREGATE_CELL_SIZE,
        )
        unregistered_report_path = self.root / "unregistered-report.json"
        unregistered_report_path.write_text(json.dumps(unregistered_report), encoding="utf-8")
        missing_report = self.command(
            "recommend",
            "--repo",
            str(self.repo),
            "--report",
            str(unregistered_report_path),
            expected=1,
        )
        self.assertIn("unavailable", missing_report.stderr)

        tampered_report = json.loads(json.dumps(report))
        tampered_report["scope"]["campaign_id"] = "Jane Doe"
        tampered_report_path = self.root / "tampered-report.json"
        tampered_report_path.write_text(json.dumps(tampered_report), encoding="utf-8")
        unsafe_report = self.command(
            "recommend",
            "--repo",
            str(self.repo),
            "--report",
            str(tampered_report_path),
            expected=1,
        )
        self.assertIn("bounded lowercase alias", unsafe_report.stderr)

        recommendations = json.loads(
            self.command("recommend", "--repo", str(self.repo), "--report", str(report_path)).stdout
        )["recommendations"]
        fake_prior = json.loads(json.dumps(recommendations[0]))
        fake_prior["finding"]["observation"] += " Unregistered synthetic change."
        fake_prior.pop("recommendation_ref")
        fake_prior["recommendation_ref"] = typed_reference("mkt-recommendation-v1", fake_prior)
        fake_prior_path = self.root / "unregistered-prior-recommendation.json"
        fake_prior_path.write_text(json.dumps(fake_prior), encoding="utf-8")
        missing_prior = self.command(
            "recommend",
            "--repo",
            str(self.repo),
            "--report",
            str(report_path),
            "--prior",
            str(fake_prior_path),
            expected=1,
        )
        self.assertIn("registered optimization artifact is unavailable", missing_prior.stderr)

    def test_public_builders_reject_unregistered_causal_evidence_and_approvals(self) -> None:
        definition, assignment, document = experiment_fixture()
        snapshot = snapshot_from_document(document)
        analysis = analyze_experiment(
            register_experiment(definition),
            snapshot,
            ExperimentAnalysisRequest(1, "final", assignment),
        )
        paths = resolve_paths(self.repo)
        ensure_layout(paths)

        tampered_snapshot = snapshot_from_document(json.loads(json.dumps(document)))
        tampered_snapshot.events[0]["measurement"]["value"] = 999
        with self.assertRaisesRegex(OptimizationError, "canonical digest"):
            build_registered_report(
                paths,
                tampered_snapshot,
                [],
                [],
                MINIMUM_AGGREGATE_CELL_SIZE,
            )

        with self.assertRaisesRegex(OptimizationError, "privacy floor"):
            build_registered_report(
                paths,
                snapshot,
                [],
                [],
                MINIMUM_AGGREGATE_CELL_SIZE - 1,
            )

        with self.assertRaisesRegex(OptimizationError, "unavailable"):
            build_registered_report(
                paths,
                snapshot,
                [],
                [analysis],
                MINIMUM_AGGREGATE_CELL_SIZE,
            )

        report = build_report(snapshot, [], [], MINIMUM_AGGREGATE_CELL_SIZE)
        policy = RecommendationPolicy(owner="growth-owner", required_approval="campaign-owner")
        with self.assertRaisesRegex(OptimizationError, "unavailable"):
            build_registered_recommendations(paths, report, policy)

        forged_status = build_recommendations(report, policy)[0]
        forged_status["status"] = "approved"
        forged_status.pop("recommendation_ref")
        forged_status["recommendation_ref"] = typed_reference("mkt-recommendation-v1", forged_status)
        with self.assertRaisesRegex(OptimizationError, "independent registration"):
            validate_recommendation_artifact(forged_status)

        forged_authority = build_recommendations(report, policy)[0]
        forged_authority["authority"]["approval_status"] = "approved"
        forged_authority["authority"]["approval_ref"] = "self-approved"
        forged_authority.pop("recommendation_ref")
        forged_authority["recommendation_ref"] = typed_reference("mkt-recommendation-v1", forged_authority)
        with self.assertRaisesRegex(OptimizationError, "independent registration"):
            validate_recommendation_artifact(forged_authority)

    def test_cli_publishes_immutable_projection_report_and_recommendation(self) -> None:
        snapshot_path = self.root / "snapshot.json"
        snapshot_path.write_text(json.dumps(analysis_document()), encoding="utf-8")
        self.command("init", "--repo", str(self.repo))

        attribution = self.cli_attribution(snapshot_path, "direct")
        self.assertEqual(2, attribution["model"]["version"])
        paths = resolve_paths(self.repo)
        attribution_path = artifact_path(paths, "attribution", attribution["attribution_ref"])
        self.assertTrue(attribution_path.is_file())

        report = json.loads(
            self.command(
                "report",
                "--repo",
                str(self.repo),
                "--input",
                str(snapshot_path),
                "--attribution",
                str(attribution_path),
                "--minimum-cell-size",
                str(MINIMUM_AGGREGATE_CELL_SIZE),
            ).stdout
        )
        report_directory = paths.report_drafts / report["report_ref"].replace(":", "-")
        self.assertTrue((report_directory / "report.json").is_file())
        self.assertTrue((report_directory / "report.md").is_file())

        recommendations = json.loads(
            self.command(
                "recommend",
                "--repo",
                str(self.repo),
                "--report",
                str(report_directory / "report.json"),
            ).stdout
        )["recommendations"]
        self.assertGreaterEqual(len(recommendations), 1)
        for recommendation in recommendations:
            output = artifact_path(paths, "recommendation", recommendation["recommendation_ref"])
            self.assertTrue(output.is_file())

        second_attribution = self.cli_attribution(snapshot_path, "last_touch")
        second_attribution_path = artifact_path(paths, "attribution", second_attribution["attribution_ref"])
        second_report = json.loads(
            self.command(
                "report",
                "--repo",
                str(self.repo),
                "--input",
                str(snapshot_path),
                "--attribution",
                str(second_attribution_path),
                "--minimum-cell-size",
                str(MINIMUM_AGGREGATE_CELL_SIZE),
            ).stdout
        )
        second_report_directory = paths.report_drafts / second_report["report_ref"].replace(":", "-")
        self.command(
            "recommend",
            "--repo",
            str(self.repo),
            "--report",
            str(second_report_directory / "report.json"),
            expected=1,
        )
        prior_path = artifact_path(paths, "recommendation", recommendations[0]["recommendation_ref"])
        successors = json.loads(
            self.command(
                "recommend",
                "--repo",
                str(self.repo),
                "--report",
                str(second_report_directory / "report.json"),
                "--prior",
                str(prior_path),
            ).stdout
        )["recommendations"]
        self.assertEqual(recommendations[0]["recommendation_ref"], successors[0]["provenance"]["supersedes"])

        status = json.loads(self.command("status", "--repo", str(self.repo)).stdout)
        self.assertEqual(2, status["artifacts"]["attribution"])
        self.assertEqual(len(recommendations) + len(successors), status["artifacts"]["recommendation"])


if __name__ == "__main__":
    unittest.main()
