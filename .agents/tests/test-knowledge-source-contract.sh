#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-source-contract.sh — Canonical evidence identity and routing tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
TMP_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

run_contract_tests() {
	PYTHONPATH="$SCRIPTS_DIR" python3 - "$TMP_DIR" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

from knowledge_source_contract import (
    SourceContractError,
    SourceMetaInput,
    build_source_meta,
    canonical_evidence_id,
    validate_checkpoint_transition,
    validate_pointer,
    validate_source_meta,
)
from knowledge_social_store import migrate

digest = "a" * 64
first = canonical_evidence_id("repo:alpha", "local-file", digest)
assert first == canonical_evidence_id("repo:alpha", "local-file", digest)
assert first != canonical_evidence_id("repo:beta", "local-file", digest)

meta = build_source_meta(
    SourceMetaInput(
        source_id="example-source",
        corpus_id="repo:alpha",
        connector_id="local-file",
        source_uri="file:///private/operator/path/example.txt",
        content_sha256=digest,
        size_bytes=12,
        kind="document",
        sensitivity="internal",
        trust="reviewed",
        ingested_at="2026-07-29T00:00:00Z",
        blob_ref=None,
    )
)
assert meta["evidence_id"] == first
assert meta["source_uri"] == "local:example-source"
assert "/private/" not in json.dumps(meta)
validate_source_meta(meta)
for tampered in (
    {**meta, "evidence_id": canonical_evidence_id("repo:beta", "local-file", digest)},
    {**meta, "sha256": "b" * 64},
    {**meta, "source_uri": "file:///private/operator/path/example.txt"},
):
    try:
        validate_source_meta(tampered)
    except SourceContractError:
        continue
    raise AssertionError(f"tampered source manifest was accepted: {tampered}")

pointer = {
    "contract_version": 1,
    "corpus_id": "repo:alpha",
    "evidence_id": first,
    "canonical_plane": "_knowledge",
    "authority": "projection",
}
validate_pointer(pointer, "repo:alpha")
try:
    validate_pointer(pointer, "repo:beta")
except SourceContractError:
    pass
else:
    raise AssertionError("cross-corpus pointer was accepted without a grant")

checkpoint = {
    "connector_id": "connector-1",
    "fencing_token": 8,
    "commit_state": "committed",
}
validate_checkpoint_transition(
    None, checkpoint, expected_connector_id="connector-1", minimum_fencing_token=8
)
for mutation in (
    {**checkpoint, "connector_id": "connector-2"},
    {**checkpoint, "fencing_token": 7},
    {**checkpoint, "commit_state": "prepared"},
    {**checkpoint, "api_token": "forbidden"},
):
    try:
        validate_checkpoint_transition(
            None, mutation, expected_connector_id="connector-1", minimum_fencing_token=8
        )
    except SourceContractError:
        continue
    raise AssertionError(f"unsafe checkpoint accepted: {mutation}")

database_path = Path(sys.argv[1]) / "legacy-social.db"
database = sqlite3.connect(database_path, isolation_level=None)
database.row_factory = sqlite3.Row
database.execute("PRAGMA foreign_keys=ON")
database.execute(
    """CREATE TABLE fetch_batches (
       batch_id TEXT PRIMARY KEY, provider TEXT NOT NULL, connection_id TEXT NOT NULL,
       stream TEXT NOT NULL, request_hash TEXT, response_hash TEXT NOT NULL UNIQUE,
       blob_ref TEXT NOT NULL, resource_count INTEGER NOT NULL,
       budget_units INTEGER NOT NULL DEFAULT 0, started_at TEXT,
       completed_at TEXT NOT NULL, terminal_status TEXT NOT NULL)"""
)
database.execute(
    """CREATE TABLE objects (
       object_id INTEGER PRIMARY KEY, provider TEXT NOT NULL, object_type TEXT NOT NULL,
       remote_id TEXT NOT NULL, account_remote_id TEXT, text_content TEXT,
       created_at TEXT, observed_at TEXT NOT NULL, evidence_class TEXT NOT NULL,
       provider_json TEXT NOT NULL DEFAULT '{}', batch_id TEXT NOT NULL,
       UNIQUE(provider,object_type,remote_id))"""
)
database.execute(
    "INSERT INTO fetch_batches VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        digest, "provider-1", "connector-1", "authored", None, digest,
        "sources/raw.json.gz", 1, 0, None, "2026-07-29T00:00:00Z", "success",
    ),
)
database.execute(
    "INSERT INTO objects VALUES(NULL,?,?,?,?,?,?,?,?,?,?)",
    (
        "provider-1", "post", "remote-1", None, "evidence", None,
        "2026-07-29T00:00:00Z", "authored", "{}", digest,
    ),
)
database.execute("PRAGMA user_version=4")
migrate(database)
corpus_id = database.execute("SELECT corpus_id FROM corpus_contract").fetchone()[0]
evidence_id = database.execute("SELECT evidence_id FROM fetch_batches").fetchone()[0]
assert evidence_id == f"ev1:{corpus_id}:connector-1:sha256:{digest}"
assert database.execute("SELECT count(*) FROM evidence_sources").fetchone()[0] == 1
assert database.execute(
    "SELECT count(*) FROM canonical_evidence_projections"
).fetchone()[0] == 1
migrate(database)
assert database.execute("SELECT corpus_id FROM corpus_contract").fetchone()[0] == corpus_id
database.close()
PY
	return 0
}

printf 'Canonical knowledge source contract tests\n'
if run_contract_tests; then
	PASS=$((PASS + 1))
	printf '  PASS  identity, routing, checkpoint, privacy, and migration contract\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL  identity, routing, checkpoint, privacy, and migration contract\n'
fi

if ! grep -Eq 'urllib\.request|requests\.|subprocess\.|http\.client' \
	"${SCRIPTS_DIR}/knowledge_source_contract.py"; then
	PASS=$((PASS + 1))
	printf '  PASS  contract primitive has no provider mutation reachability\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL  contract primitive reaches a provider transport\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
