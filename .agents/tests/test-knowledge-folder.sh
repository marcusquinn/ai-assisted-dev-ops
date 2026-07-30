#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Focused tests for bounded recursive mixed-media folder ingestion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-helper.sh"
TMP_DIR="$(mktemp -d)"
REPO_PATH="${TMP_DIR}/repo"
TREE="${TMP_DIR}/mixed-tree"
PASS=0
FAIL=0

pass() {
	local name="$1"
	printf '[PASS] %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf '[FAIL] %s — %s\n' "$name" "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

assert_json() {
	local name="$1"
	local json_value="$2"
	local expression="$3"
	if jq -e "$expression" >/dev/null 2>&1 <<<"$json_value"; then
		pass "$name"
	else
		fail "$name" "expression failed: $expression"
	fi
	return 0
}

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

mkdir -p "$REPO_PATH" "$TREE/sub"
export AIDEVOPS_VAULT_DIR="${TMP_DIR}/vault-disabled"
export REPOS_FILE="${TMP_DIR}/repos.json"
export PERSONAL_PLANE_BASE="${TMP_DIR}/personal-plane"
cat >"$REPOS_FILE" <<EOF
{"initialized_repos":[{"path":"${REPO_PATH}","slug":"test/repo","knowledge":"repo","platform":"local"}],"git_parent_dirs":[]}
EOF
bash "$HELPER" provision "$REPO_PATH" >/dev/null

printf 'already canonical\n' >"${TMP_DIR}/single.txt"
bash "$HELPER" add "${TMP_DIR}/single.txt" --repo-path "$REPO_PATH" >/dev/null
cp "${TMP_DIR}/single.txt" "${TREE}/single-copy.txt"
printf '# Folder evidence\nunique text\n' >"${TREE}/sub/note.md"
printf 'not supported\n' >"${TREE}/unknown.xyz"

python3 - "$TREE" <<'PY'
import base64
import sys
from pathlib import Path

root = Path(sys.argv[1])
(root / "image.png").write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
))
(root / "audio.wav").write_bytes(
    b"RIFF" + (36).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little")
    + (1).to_bytes(2, "little") + (1).to_bytes(2, "little")
    + (8000).to_bytes(4, "little") * 2 + (1).to_bytes(2, "little")
    + (8).to_bytes(2, "little") + b"data" + (0).to_bytes(4, "little")
)
(root / "video.mp4").write_bytes(b"\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isomiso2")
(root / "message.eml").write_bytes(
    b"From: sender@example.test\nTo: receiver@example.test\nSubject: Fixture\n"
    b"Message-ID: <fixture@example.test>\nMIME-Version: 1.0\n"
    b"Content-Type: multipart/mixed; boundary=fixture\n\n"
    b"--fixture\nContent-Type: text/plain; charset=utf-8\n\nHello folder.\n"
    b"--fixture\nContent-Type: application/pdf; name=report.pdf\n"
    b"Content-Disposition: attachment; filename=report.pdf\n"
    b"Content-Transfer-Encoding: base64\n\nJVBERi0xLjQKJSBmaXh0dXJlCg==\n"
    b"--fixture--\n"
)
PY

first_output=$(bash "$HELPER" folder import "$TREE" --repo-path "$REPO_PATH" --json)
assert_json "mixed tree completes" "$first_output" '.status == "complete"'
assert_json "supported files import" "$first_output" '.counts.imported >= 5'
assert_json "existing single-file source is reused" "$first_output" '.counts.unchanged >= 1'
assert_json "unsupported input remains visible" "$first_output" '.counts.unsupported == 1'
if [[ "$first_output" != *"$TMP_DIR"* ]]; then
	pass "summary hides private absolute paths"
else
	fail "summary hides private absolute paths" "temporary path leaked"
fi

KNOWLEDGE_ROOT="${REPO_PATH}/_knowledge"
ROOT_ID=$(jq -r '.root_id' <<<"$first_output")
MANIFEST="${KNOWLEDGE_ROOT}/index/folder-imports/${ROOT_ID}/manifest.json"
if [[ -f "$MANIFEST" ]]; then
	pass "committed manifest exists"
else
	fail "committed manifest exists" "manifest missing"
fi

kind_count=$(jq -s '[.[] | select(.version == 2) | .kind] | unique | length' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if [[ "$kind_count" -ge 6 ]]; then
	pass "text image audio video email and attachment kinds are canonical"
else
	fail "text image audio video email and attachment kinds are canonical" "kind count=$kind_count"
fi
if jq -e 'select(.kind == "email") | .attachments | length == 1' "${KNOWLEDGE_ROOT}"/sources/*/meta.json >/dev/null 2>&1; then
	pass "email attachment relationship is recorded"
else
	fail "email attachment relationship is recorded" "email relation missing"
fi
if jq -e 'select(.kind == "attachment") | .parent_sources | length == 1' "${KNOWLEDGE_ROOT}"/sources/*/meta.json >/dev/null 2>&1; then
	pass "attachment points to its parent"
else
	fail "attachment points to its parent" "parent relation missing"
fi
attachment_source=$(jq -r 'select(.kind == "attachment") | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if jq -e '.jobs[] | select(.processor == "text-extraction" and .status == "queued")' \
	"${KNOWLEDGE_ROOT}/sources/${attachment_source}/enrichment.json" >/dev/null 2>&1; then
	pass "supported attachments schedule type-specific enrichment"
else
	fail "supported attachments schedule type-specific enrichment" "attachment projection missing"
fi

source_count_before=$(printf '%s\n' "${KNOWLEDGE_ROOT}"/sources/*/meta.json | wc -l | tr -d ' ')
replay_output=$(bash "$HELPER" folder "$TREE" --repo-path "$REPO_PATH" --json)
assert_json "unchanged replay is a no-op" "$replay_output" '.counts.imported == 0 and .counts.unchanged >= 6'

mv "${TREE}/sub/note.md" "${TREE}/sub/renamed.md"
rename_output=$(bash "$HELPER" folder import "$TREE" --repo-path "$REPO_PATH" --json)
assert_json "rename resolves existing evidence" "$rename_output" '.counts.imported == 0'
source_count_after=$(printf '%s\n' "${KNOWLEDGE_ROOT}"/sources/*/meta.json | wc -l | tr -d ' ')
if [[ "$source_count_before" == "$source_count_after" ]] &&
	jq -e '.entries["sub/renamed.md"].aliases | index("sub/note.md")' "$MANIFEST" >/dev/null; then
	pass "rename adds an alias without duplicate evidence"
else
	fail "rename adds an alias without duplicate evidence" "source count or alias changed unexpectedly"
fi

PARTIAL_TREE="${TMP_DIR}/partial-tree"
mkdir -p "$PARTIAL_TREE"
printf 'safe sibling\n' >"${PARTIAL_TREE}/safe.txt"
printf 'not a png\n' >"${PARTIAL_TREE}/broken.png"
ln -s "$PARTIAL_TREE" "${PARTIAL_TREE}/loop"
partial_status=0
partial_output=$(bash "$HELPER" folder import "$PARTIAL_TREE" --repo-path "$REPO_PATH" --json) || partial_status=$?
if [[ "$partial_status" -eq 2 ]]; then
	pass "partial failure returns a distinct status"
else
	fail "partial failure returns a distinct status" "exit=$partial_status"
fi
assert_json "malformed media does not lose successful siblings" "$partial_output" '.status == "partial" and .counts.failed == 1 and .counts.imported == 1 and .counts.skipped == 1'

BUDGET_TREE="${TMP_DIR}/budget-tree"
mkdir -p "$BUDGET_TREE"
printf 'one\n' >"${BUDGET_TREE}/one.txt"
printf 'two\n' >"${BUDGET_TREE}/two.txt"
budget_status=0
budget_output=$(bash "$HELPER" folder import "$BUDGET_TREE" --repo-path "$REPO_PATH" --dry-run --max-files 1 --json) || budget_status=$?
if [[ "$budget_status" -eq 2 ]]; then
	pass "dry-run reports a bounded stop"
else
	fail "dry-run reports a bounded stop" "exit=$budget_status"
fi
assert_json "dry-run separates plans from budget stops" "$budget_output" '.counts.planned == 1 and .counts["budget-stopped"] == 1'

DEPTH_TREE="${TMP_DIR}/depth-tree"
mkdir -p "${DEPTH_TREE}/nested"
printf 'too deep\n' >"${DEPTH_TREE}/nested/file.txt"
depth_status=0
depth_output=$(bash "$HELPER" folder import "$DEPTH_TREE" --repo-path "$REPO_PATH" --max-depth 0 --json) || depth_status=$?
if [[ "$depth_status" -eq 2 ]]; then
	pass "depth limit stops descent"
else
	fail "depth limit stops descent" "exit=$depth_status"
fi
assert_json "depth limit imports no hidden descendants" "$depth_output" '.counts.imported == 0 and .counts["budget-stopped"] == 1'

MALICIOUS_TREE="${TMP_DIR}/malicious-tree"
mkdir -p "$MALICIOUS_TREE" "${KNOWLEDGE_ROOT}/sources/untrusted-meta"
printf 'malicious metadata fixture\n' >"${MALICIOUS_TREE}/fixture.txt"
malicious_digest=$(shasum -a 256 "${MALICIOUS_TREE}/fixture.txt" | awk '{print $1}')
cat >"${KNOWLEDGE_ROOT}/sources/untrusted-meta/meta.json" <<EOF
{"version":1,"id":"../../outside","sha256":"${malicious_digest}","content_sha256":"${malicious_digest}"}
EOF
printf 'unchanged\n' >"${TMP_DIR}/outside-sentinel"
malicious_output=$(bash "$HELPER" folder import "$MALICIOUS_TREE" --repo-path "$REPO_PATH" --json)
assert_json "untrusted metadata IDs are not reused" "$malicious_output" '.counts.imported == 1'
if [[ "$(<"${TMP_DIR}/outside-sentinel")" == "unchanged" ]]; then
	pass "untrusted metadata cannot redirect writes"
else
	fail "untrusted metadata cannot redirect writes" "outside sentinel changed"
fi

POISON_TREE="${TMP_DIR}/poison-tree"
mkdir -p "$POISON_TREE" "${KNOWLEDGE_ROOT}/sources/poisoned-valid"
printf 'claimed canonical bytes\n' >"${POISON_TREE}/claimed.txt"
printf 'different stored bytes\n' >"${KNOWLEDGE_ROOT}/sources/poisoned-valid/raw.bin"
python3 - "$POISON_TREE" "${KNOWLEDGE_ROOT}/sources/poisoned-valid/meta.json" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

source = Path(sys.argv[1], "claimed.txt").read_bytes()
digest = hashlib.sha256(source).hexdigest()
source_id = "poisoned-valid"
meta = {
    "version": 2,
    "contract_version": 1,
    "id": source_id,
    "corpus_id": "repo:default",
    "evidence_id": f"ev1:repo:default:local-folder:sha256:{digest}",
    "authority": "raw",
    "plane": "_knowledge",
    "projection": False,
    "kind": "document",
    "source_uri": f"local:{source_id}",
    "sha256": digest,
    "content_sha256": digest,
    "ingested_at": "2026-07-30T00:00:00Z",
    "ingested_by": "local-operator",
    "sensitivity": "internal",
    "trust": "unverified",
    "blob_path": None,
    "raw_path": "raw.bin",
    "size_bytes": len(source),
    "connector": {"id": "local-folder", "native_id": source_id},
    "provenance": {
        "captured_at": "2026-07-30T00:00:00Z",
        "source_uri": f"local:{source_id}",
        "content_sha256": digest,
    },
}
Path(sys.argv[2]).write_text(json.dumps(meta), encoding="utf-8")
PY
poison_output=$(bash "$HELPER" folder import "$POISON_TREE" --repo-path "$REPO_PATH" --json)
assert_json "canonical digest reuse verifies stored bytes" "$poison_output" '.counts.imported == 1'

store_regression_output=$(
	HOME="${TMP_DIR}/store-home" python3 - "${SCRIPT_DIR}/../scripts" "${TMP_DIR}/store-regressions" <<'PY'
import hashlib
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import knowledge_folder_store as store_module
from knowledge_folder_store import ExpansionBudget, SourceStore
from knowledge_folder_manifest import COUNT_KEYS
from knowledge_folder_processor import FileProcessor
from knowledge_folder_walk import InventoryItem
from knowledge_source_contract import SourceMetaInput, build_source_meta

base = Path(sys.argv[2])
home = Path.home()
home.mkdir(parents=True)


def knowledge_root(name: str) -> Path:
    root = base / name / "_knowledge"
    (root / "sources").mkdir(parents=True)
    (root / "index").mkdir()
    return root


def import_bytes(
    store: SourceStore,
    path: Path,
    data: bytes,
    kind: str = "document",
    mime_type: str = "text/plain",
    processors: tuple[str, ...] = (),
):
    path.write_bytes(data)
    descriptor = os.open(path, os.O_RDONLY)
    try:
        return store.import_file(
            path.name,
            descriptor,
            len(data),
            hashlib.sha256(data).hexdigest(),
            kind,
            mime_type,
            processors,
            ExpansionBudget(10, 1024, time.monotonic() + 10),
        )
    finally:
        os.close(descriptor)


legacy_root = knowledge_root("legacy-repo")
legacy_data = b"legacy blob bytes\n"
legacy_digest = hashlib.sha256(legacy_data).hexdigest()
legacy_id = "legacy-large-source"
legacy_source = legacy_root / "sources" / legacy_id
legacy_source.mkdir()
legacy_blob = (
    home / ".aidevops" / ".agent-workspace" / "knowledge-blobs"
    / "legacy-repo" / legacy_id / "original.txt"
)
legacy_blob.parent.mkdir(parents=True)
legacy_blob.write_bytes(legacy_data)
legacy_meta = build_source_meta(
    SourceMetaInput(
        source_id=legacy_id,
        corpus_id="repo:default",
        connector_id="local-file",
        source_uri=f"local:{legacy_id}",
        content_sha256=legacy_digest,
        size_bytes=len(legacy_data),
        kind="document",
        sensitivity="internal",
        trust="unverified",
        ingested_at="2026-07-30T00:00:00Z",
        blob_ref=f"knowledge-blobs:sha256:{legacy_digest}",
    )
)
(legacy_source / "meta.json").write_text(json.dumps(legacy_meta), encoding="utf-8")
legacy_store = SourceStore(legacy_root, "repo:default", Path(sys.argv[1]), blob_threshold=1)
legacy_result = import_bytes(legacy_store, base / "legacy-copy.txt", legacy_data)
legacy_count = len([path for path in (legacy_root / "sources").iterdir() if not path.name.startswith(".")])

orphan_root = knowledge_root("orphan-repo")
orphan_store = SourceStore(orphan_root, "repo:default", Path(sys.argv[1]), blob_threshold=1)
orphan_data = b"orphan candidate\n"
orphan_digest = hashlib.sha256(orphan_data).hexdigest()
orphan_id = f"folder-{orphan_digest[:24]}"
original_atomic_write = store_module.atomic_write_json


def reject_manifest(*_args, **_kwargs):
    raise OSError("injected manifest failure")


store_module.atomic_write_json = reject_manifest
try:
    try:
        import_bytes(orphan_store, base / "orphan.txt", orphan_data)
    except OSError:
        pass
finally:
    store_module.atomic_write_json = original_atomic_write
orphan_blob = (
    home / ".aidevops" / ".agent-workspace" / "knowledge-blobs"
    / orphan_store._blob_namespace() / orphan_id / "raw.bin"
)

refresh_root = knowledge_root("refresh-repo")
refresh_store = SourceStore(refresh_root, "repo:default", Path(sys.argv[1]))
refresh_calls = 0
original_source_index = refresh_store._source_index


def counted_source_index():
    global refresh_calls
    refresh_calls += 1
    return original_source_index()


refresh_store._source_index = counted_source_index
import_bytes(refresh_store, base / "refresh-one.txt", b"refresh one\n")
import_bytes(refresh_store, base / "refresh-two.txt", b"refresh two\n")

concurrent_root = knowledge_root("concurrent-repo")
first_store = SourceStore(concurrent_root, "repo:default", Path(sys.argv[1]))
second_store = SourceStore(concurrent_root, "repo:default", Path(sys.argv[1]))
concurrent_data = b"cross-store convergence\n"
import_bytes(first_store, base / "concurrent-one.txt", concurrent_data)
concurrent_result = import_bytes(second_store, base / "concurrent-two.txt", concurrent_data)

blob_a_root = knowledge_root("blob-a-repo")
blob_b_root = knowledge_root("blob-b-repo")
blob_a_store = SourceStore(blob_a_root, "repo:default", Path(sys.argv[1]), blob_threshold=1)
blob_b_store = SourceStore(blob_b_root, "repo:default", Path(sys.argv[1]), blob_threshold=1)
shared_blob_data = b"cross-repository blob isolation\n"
blob_a_result = import_bytes(blob_a_store, base / "blob-a.txt", shared_blob_data)
blob_b_result = import_bytes(blob_b_store, base / "blob-b.txt", shared_blob_data)
blob_root = home / ".aidevops" / ".agent-workspace" / "knowledge-blobs"
blob_a_path = blob_root / blob_a_store._blob_namespace() / blob_a_result.source_id / "raw.bin"
blob_b_path = blob_root / blob_b_store._blob_namespace() / blob_b_result.source_id / "raw.bin"

stale_root = knowledge_root("stale-repo")
stale_writer = SourceStore(stale_root, "repo:default", Path(sys.argv[1]))
stale_data = b"stale cache fixture\n"
stale_result = import_bytes(stale_writer, base / "stale-first.txt", stale_data)
stale_observer = SourceStore(stale_root, "repo:default", Path(sys.argv[1]))
(stale_root / "sources" / stale_result.source_id / "raw.bin").write_bytes(b"tampered cache bytes\n")
stale_replacement = import_bytes(stale_observer, base / "stale-second.txt", stale_data)

attachment_root = knowledge_root("attachment-repo")
attachment_store = SourceStore(attachment_root, "repo:default", Path(sys.argv[1]))
attachment_data = b"%PDF-1.4\nattachment projection\n"
attachment_result = import_bytes(
    attachment_store,
    base / "report.pdf",
    attachment_data,
    "attachment",
    "application/pdf",
    ("text-extraction",),
)
import_bytes(
    attachment_store,
    base / "report.bin",
    attachment_data,
    "attachment",
    "application/octet-stream",
    (),
)
attachment_projection = json.loads(
    (attachment_root / "sources" / attachment_result.source_id / "enrichment.json").read_text()
)

credential_root = knowledge_root("credential-repo")
credential_data = b"credential-shaped metadata fixture\n"
credential_digest = hashlib.sha256(credential_data).hexdigest()
credential_id = "credential-shaped-source"
credential_source = credential_root / "sources" / credential_id
credential_source.mkdir()
(credential_source / "raw.bin").write_bytes(credential_data)
credential_meta = build_source_meta(
    SourceMetaInput(
        source_id=credential_id,
        corpus_id="repo:default",
        connector_id="local-file",
        source_uri=f"local:{credential_id}",
        content_sha256=credential_digest,
        size_bytes=len(credential_data),
        kind="document",
        sensitivity="internal",
        trust="unverified",
        ingested_at="2026-07-30T00:00:00Z",
        blob_ref=None,
    )
)
credential_meta["raw_path"] = "raw.bin"
credential_meta["api_key"] = "placeholder"
(credential_source / "meta.json").write_text(json.dumps(credential_meta), encoding="utf-8")
credential_store = SourceStore(credential_root, "repo:default", Path(sys.argv[1]))
credential_result = import_bytes(credential_store, base / "credential-copy.txt", credential_data)

unavailable_root = knowledge_root("unavailable-repo")
unavailable_store = SourceStore(unavailable_root, "repo:default", base / "missing-scripts")
png_data = b"\x89PNG\r\n\x1a\n" + b"bounded fixture"
unavailable_result = import_bytes(
    unavailable_store,
    base / "unavailable.png",
    png_data,
    "image",
    "image/png",
    ("metadata", "ocr"),
)
unavailable_jobs = json.loads(
    (unavailable_root / "sources" / unavailable_result.source_id / "enrichment.json").read_text()
)["jobs"]

projection_root = knowledge_root("projection-repo")
projection_data = b"projection symlink fixture\n"
projection_digest = hashlib.sha256(projection_data).hexdigest()
projection_id = "projection-safe-source"
projection_source = projection_root / "sources" / projection_id
projection_source.mkdir()
(projection_source / "raw.bin").write_bytes(projection_data)
projection_meta = build_source_meta(
    SourceMetaInput(
        source_id=projection_id,
        corpus_id="repo:default",
        connector_id="local-file",
        source_uri=f"local:{projection_id}",
        content_sha256=projection_digest,
        size_bytes=len(projection_data),
        kind="document",
        sensitivity="internal",
        trust="unverified",
        ingested_at="2026-07-30T00:00:00Z",
        blob_ref=None,
    )
)
projection_meta["raw_path"] = "raw.bin"
(projection_source / "meta.json").write_text(json.dumps(projection_meta), encoding="utf-8")
projection_sentinel = base / "projection-sentinel"
projection_sentinel.write_text("unchanged\n", encoding="utf-8")
(projection_source / "text.txt").symlink_to(projection_sentinel)
projection_store = SourceStore(projection_root, "repo:default", Path(sys.argv[1]))
projection_failed_closed = False
try:
    import_bytes(projection_store, base / "projection-copy.txt", projection_data)
except store_module.EvidenceProcessingError:
    projection_failed_closed = True

enrichment_failure_root = knowledge_root("enrichment-failure-repo")
enrichment_failure_store = SourceStore(enrichment_failure_root, "repo:default", Path(sys.argv[1]))
enrichment_failure_path = base / "enrichment-failure.eml"
enrichment_failure_data = b"From: sender@example.test\nSubject: Failure\n\nPreserved body.\n"
enrichment_failure_path.write_bytes(enrichment_failure_data)
enrichment_failure_manifest = {
    "entries": {},
    "counts": {key: 0 for key in COUNT_KEYS},
    "updated_at": "",
}
original_ensure_enrichment = enrichment_failure_store._ensure_enrichment
enrichment_calls = 0


def fail_first_enrichment(*args, **kwargs):
    global enrichment_calls
    enrichment_calls += 1
    if enrichment_calls == 1:
        raise OSError("injected final enrichment failure")
    return original_ensure_enrichment(*args, **kwargs)


enrichment_failure_store._ensure_enrichment = fail_first_enrichment
descriptor = os.open(enrichment_failure_path, os.O_RDONLY)
try:
    item = InventoryItem(
        enrichment_failure_path.name,
        enrichment_failure_path.name,
        descriptor,
        os.fstat(descriptor),
    )
    FileProcessor(
        enrichment_failure_manifest,
        {},
        enrichment_failure_store,
        False,
        ExpansionBudget(10, 1024, time.monotonic() + 10),
    ).process(item)
finally:
    os.close(descriptor)
enrichment_failure_entry = enrichment_failure_manifest["entries"][enrichment_failure_path.name]

print(json.dumps({
    "legacy_reused": legacy_result.reused and legacy_count == 1,
    "orphan_removed": not orphan_blob.exists(),
    "refresh_calls": refresh_calls,
    "concurrent_reused": concurrent_result.reused,
    "blob_namespaces_isolated": (
        blob_a_store._blob_namespace() != blob_b_store._blob_namespace()
        and blob_a_path.is_file()
        and blob_b_path.is_file()
    ),
    "stale_cache_rejected": not stale_replacement.reused,
    "attachment_projection_preserved": (
        attachment_projection["kind"] == "attachment"
        and attachment_projection["media_type"] == "application/pdf"
        and attachment_projection["jobs"] == [
            {"processor": "text-extraction", "status": "queued"}
        ]
    ),
    "credential_metadata_rejected": not credential_result.reused,
    "optional_processor_unavailable": unavailable_jobs == [
        {"processor": "metadata", "status": "completed"},
        {"processor": "ocr", "status": "unavailable"},
    ],
    "projection_symlink_rejected": (
        projection_failed_closed
        and projection_sentinel.read_text(encoding="utf-8") == "unchanged\n"
    ),
    "enrichment_failure_preserves_pointer": (
        enrichment_failure_entry["status"] == "failed"
        and enrichment_failure_entry.get("sha256") == hashlib.sha256(enrichment_failure_data).hexdigest()
        and bool(enrichment_failure_entry.get("source_id"))
        and bool(enrichment_failure_entry.get("evidence_id"))
    ),
}))
PY
)
assert_json "folder import reuses legacy opaque blobs" "$store_regression_output" '.legacy_reused == true'
assert_json "failed source publication removes a newly written blob" "$store_regression_output" '.orphan_removed == true'
assert_json "local imports do not rehash the corpus per item" "$store_regression_output" '.refresh_calls == 0'
assert_json "stale store instances discover concurrent publications" "$store_regression_output" '.concurrent_reused == true'
assert_json "large blobs are isolated across knowledge roots" "$store_regression_output" '.blob_namespaces_isolated == true'
assert_json "cached sources are revalidated before reuse" "$store_regression_output" '.stale_cache_rejected == true'
assert_json "attachment aliases cannot erase enrichment jobs" "$store_regression_output" '.attachment_projection_preserved == true'
assert_json "credential-shaped source metadata is never trusted" "$store_regression_output" '.credential_metadata_rejected == true'
assert_json "missing optional processors remain explicit" "$store_regression_output" '.optional_processor_unavailable == true'
assert_json "symlinked text projections fail closed" "$store_regression_output" '.projection_symlink_rejected == true'
assert_json "enrichment write failure retains canonical evidence pointers" "$store_regression_output" '.enrichment_failure_preserves_pointer == true'

EMAIL_TREE="${TMP_DIR}/email-edge-tree"
mkdir -p "$EMAIL_TREE"
python3 - "$EMAIL_TREE" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
nested = (
    b"From: parent@example.test\nTo: receiver@example.test\nSubject: Nested\n"
    b"MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=nested\n\n"
    b"--nested\nContent-Type: text/plain; charset=utf-8\n\nParent body.\n"
    b"--nested\nContent-Type: message/rfc822\nContent-Disposition: attachment; filename=one.eml\n\n"
    b"From: one@example.test\nTo: receiver@example.test\nSubject: One\n\nFirst child.\n"
    b"--nested\nContent-Type: message/rfc822\nContent-Disposition: attachment; filename=two.eml\n\n"
    b"From: two@example.test\nTo: receiver@example.test\nSubject: Two\n\nSecond child.\n"
    b"--nested--\n"
)
(root / "nested.eml").write_bytes(nested)
message = b"From: emlx@example.test\nTo: receiver@example.test\nSubject: EMLX\n\nBounded body.\n"
(root / "bounded.emlx").write_bytes(str(len(message)).encode() + b"\n" + message + b"<plist>private trailing metadata</plist>\n")
(root / "html.eml").write_bytes(
    b"From: html@example.test\nTo: receiver@example.test\nSubject: HTML\nMIME-Version: 1.0\n"
    b"Content-Type: text/html; charset=utf-8\n\n&lt;script&gt;alert(1)&lt;/script&gt;"
    b"<img src=https://tracker.example.test/pixel>\n"
)
(root / "archive.mbox").write_bytes(
    b"From first@example.test Thu Jul 30 00:00:00 2026\n"
    b"From: first@example.test\nTo: receiver@example.test\nSubject: Mbox One\n\nFirst mailbox body.\n"
    b"From second@example.test Thu Jul 30 00:01:00 2026\n"
    b"From: second@example.test\nTo: receiver@example.test\nSubject: Mbox Two\n\nSecond mailbox body.\n"
)
body = (
    b"First content-length line.\n"
    b"From body@example.test Thu Jul 30 00:02:00 2026\n"
    b">From mboxrd escaped line.\n"
)
(root / "archive-content-length.mbox").write_bytes(
    b"From third@example.test Thu Jul 30 00:02:00 2026\n"
    b"From: third@example.test\nTo: receiver@example.test\nSubject: Mbox CL\n"
    + f"Content-Length: {len(body)}\n\n".encode()
    + body
)
PY
email_edge_output=$(bash "$HELPER" folder import "$EMAIL_TREE" --repo-path "$REPO_PATH" --json)
assert_json "email edge fixtures complete" "$email_edge_output" '.status == "complete" and .counts.imported == 5'
nested_parent=$(jq -r 'select(.subject == "Nested") | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if jq -e '.attachments | map(select(.status == "unsupported" and .content_type == "message/rfc822")) | length == 2' \
	"${KNOWLEDGE_ROOT}/sources/${nested_parent}/meta.json" >/dev/null; then
	pass "reserialized nested messages are not presented as raw authority"
else
	fail "reserialized nested messages are not presented as raw authority" "nested messages became canonical evidence"
fi
emlx_source=$(jq -r 'select(.subject == "EMLX") | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if [[ -f "${KNOWLEDGE_ROOT}/sources/${emlx_source}/text.txt" ]] &&
	! grep -q 'private trailing metadata' "${KNOWLEDGE_ROOT}/sources/${emlx_source}/text.txt"; then
	pass "emlx parsing honors the declared message length"
else
	fail "emlx parsing honors the declared message length" "trailing metadata reached the body projection"
fi
html_source=$(jq -r 'select(.subject == "HTML") | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if [[ ! -e "${KNOWLEDGE_ROOT}/sources/${html_source}/body.html" ]]; then
	pass "HTML email stores no active markup projection"
else
	fail "HTML email stores no active markup projection" "body.html exists"
fi
if [[ -f "${KNOWLEDGE_ROOT}/sources/${html_source}/text.txt" ]] &&
	! grep -q 'tracker.example.test' "${KNOWLEDGE_ROOT}/sources/${html_source}/text.txt"; then
	pass "HTML-only email produces a private text projection"
else
	fail "HTML-only email produces a private text projection" "safe text fallback missing"
fi
mbox_source=$(jq -r 'select(.media_type == "application/mbox" and ((.children // []) | length == 2)) | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if jq -e '.children | map(select(.relationship == "mailbox-message")) | length == 2' \
	"${KNOWLEDGE_ROOT}/sources/${mbox_source}/meta.json" >/dev/null; then
	pass "mbox expansion preserves two message children"
else
	fail "mbox expansion preserves two message children" "mailbox children missing"
fi
cl_child=$(jq -r 'select(.subject == "Mbox CL") | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if [[ -n "$cl_child" ]] && grep -q 'From body@example.test Thu Jul 30 00:02:00 2026' \
	"${KNOWLEDGE_ROOT}/sources/${cl_child}/text.txt"; then
	pass "mbox content length prevents false envelope splitting"
else
	fail "mbox content length prevents false envelope splitting" "content-length message was split"
fi

PARSE_TREE="${TMP_DIR}/parse-tree"
mkdir -p "$PARSE_TREE"
printf '999\nFrom: truncated@example.test\nSubject: Truncated\n\nbody\n' >"${PARSE_TREE}/truncated.emlx"
parse_status=0
parse_output=$(bash "$HELPER" folder import "$PARSE_TREE" --repo-path "$REPO_PATH" --json) || parse_status=$?
parse_root=$(jq -r '.root_id' <<<"$parse_output")
parse_manifest="${KNOWLEDGE_ROOT}/index/folder-imports/${parse_root}/manifest.json"
if [[ "$parse_status" -eq 2 ]] && jq -e \
	'.entries["truncated.emlx"] | .status == "failed" and (.source_id | length > 0) and (.evidence_id | length > 0)' \
	"$parse_manifest" >/dev/null; then
	pass "projection failure retains canonical evidence pointers"
else
	fail "projection failure retains canonical evidence pointers" "preserved source pointer missing"
fi
parse_source=$(jq -r '.entries["truncated.emlx"].source_id' "$parse_manifest")
if jq -e '.jobs[] | select(.processor == "email-parse" and .status == "failed")' \
	"${KNOWLEDGE_ROOT}/sources/${parse_source}/enrichment.json" >/dev/null 2>&1; then
	pass "failed parsing is not recorded as completed enrichment"
else
	fail "failed parsing is not recorded as completed enrichment" "email-parse disposition is false"
fi
parse_replay_status=0
parse_replay_output=$(bash "$HELPER" folder import "$PARSE_TREE" --repo-path "$REPO_PATH" --json) || parse_replay_status=$?
if [[ "$parse_replay_status" -eq 2 ]]; then
	pass "failed projection is retried on replay"
else
	fail "failed projection is retried on replay" "exit=$parse_replay_status"
fi
assert_json "failed projection never becomes unchanged" "$parse_replay_output" '.status == "partial" and .counts.failed == 1 and .counts.unchanged == 0'

lease_result=$(
	python3 - "$MANIFEST" "$HELPER" "$TREE" "$REPO_PATH" <<'PY'
import fcntl
import subprocess
import sys
from pathlib import Path

lease = Path(sys.argv[1]).with_name("lease.json")
with lease.open("r+") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    result = subprocess.run(
        ["bash", sys.argv[2], "folder", "import", sys.argv[3], "--repo-path", sys.argv[4], "--json"],
        check=False,
        capture_output=True,
        text=True,
    )
print(result.returncode)
PY
)
if [[ "$lease_result" -eq 1 ]]; then
	pass "active lease rejects a concurrent scan"
else
	fail "active lease rejects a concurrent scan" "exit=$lease_result"
fi

lease_replace_result=$(
	python3 - "${SCRIPT_DIR}/../scripts" "${TMP_DIR}/lease-replace" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from knowledge_folder_walk import FolderWalkError, Lease

state = Path(sys.argv[2])
state.mkdir()
lease_path = state / "lease.json"
with Lease(lease_path) as lease:
    lease_path.unlink()
    lease_path.write_text("replacement\n", encoding="utf-8")
    try:
        lease.assert_owned()
    except FolderWalkError:
        print(0)
    else:
        print(1)
PY
)
if [[ "$lease_replace_result" -eq 0 ]]; then
	pass "replaced lease cannot authorize another checkpoint"
else
	fail "replaced lease cannot authorize another checkpoint" "replacement was not detected"
fi

lease_load_order_result=$(
	python3 - "${SCRIPT_DIR}/../scripts" "${TMP_DIR}/lease-load-order" <<'PY'
import argparse
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import knowledge_folder_import as folder_import

base = Path(sys.argv[2])
folder = base / "folder"
knowledge_root = base / "_knowledge"
folder.mkdir(parents=True)
(knowledge_root / "index").mkdir(parents=True)
(knowledge_root / "sources").mkdir()
state = {"held": False, "loaded_under_lease": False, "token": 0}


class ProbeLease:
    def __init__(self, _path):
        pass

    def __enter__(self):
        state["held"] = True
        return self

    def __exit__(self, _kind, _value, _traceback):
        state["held"] = False


class ProbeRunner:
    def __init__(self, _args, root, _path, _previous, token, _persist, _lease):
        state["token"] = token
        self.root_id = root.root_id

    def run(self):
        return {
            "root_id": self.root_id,
            "status": "complete",
            "fencing_token": state["token"],
            "counts": {},
        }, 0


def checked_load(_path):
    state["loaded_under_lease"] = state["held"]
    return {"fencing_token": 4, "entries": {}}


folder_import.Lease = ProbeLease
folder_import.SnapshotRunner = ProbeRunner
folder_import.load_manifest = checked_load
folder_import.emit = lambda _summary, _as_json: None
args = argparse.Namespace(
    folder=folder,
    allow_root=[base],
    knowledge_root=knowledge_root,
    scripts_dir=Path(sys.argv[1]),
    corpus_id="repo:default",
    dry_run=False,
    json=True,
    exclude=[],
    max_depth=4,
    max_files=10,
    max_nodes=20,
    max_bytes=1024,
    max_item_bytes=512,
    max_seconds=10,
)
result = folder_import.run_import(args)
print(0 if result == 0 and state["loaded_under_lease"] and state["token"] == 5 else 1)
PY
)
if [[ "$lease_load_order_result" -eq 0 ]]; then
	pass "persistent manifest state loads under the folder lease"
else
	fail "persistent manifest state loads under the folder lease" "stale state could be loaded before locking"
fi

root_replace_result=$(
	python3 - "${SCRIPT_DIR}/../scripts" "${TMP_DIR}/root-parent" <<'PY'
import sys
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from knowledge_folder_walk import open_root, walk

parent = Path(sys.argv[2])
root = parent / "root"
root.mkdir(parents=True)
(root / "old.txt").write_text("old\n", encoding="utf-8")
with open_root(root, [parent]) as handle:
    root.rename(parent / "moved")
    root.mkdir()
    (root / "new.txt").write_text("new\n", encoding="utf-8")
    observed = [item.relative for item in walk(handle, [], 4, time.monotonic() + 5, 20)]
print(0 if observed == ["old.txt"] else 1)
PY
)
if [[ "$root_replace_result" -eq 0 ]]; then
	pass "root identity and traversal share one retained descriptor"
else
	fail "root identity and traversal share one retained descriptor" "replacement root was traversed"
fi

RACE_A="${TMP_DIR}/race-a"
RACE_B="${TMP_DIR}/race-b"
mkdir -p "$RACE_A" "$RACE_B"
printf 'cross-root duplicate\n' >"${RACE_A}/same.txt"
cp "${RACE_A}/same.txt" "${RACE_B}/same.txt"
bash "$HELPER" folder import "$RACE_A" --repo-path "$REPO_PATH" --json >"${TMP_DIR}/race-a.json" &
race_a_pid=$!
bash "$HELPER" folder import "$RACE_B" --repo-path "$REPO_PATH" --json >"${TMP_DIR}/race-b.json" &
race_b_pid=$!
wait "$race_a_pid"
wait "$race_b_pid"
race_digest=$(shasum -a 256 "${RACE_A}/same.txt" | awk '{print $1}')
race_sources=$(jq -r --arg digest "$race_digest" 'select(.sha256 == $digest) | .id' "${KNOWLEDGE_ROOT}"/sources/*/meta.json | wc -l | tr -d ' ')
if [[ "$race_sources" -eq 1 ]]; then
	pass "cross-root concurrency creates one canonical source"
else
	fail "cross-root concurrency creates one canonical source" "sources=$race_sources"
fi

RELATION_A="${TMP_DIR}/relation-a"
RELATION_B="${TMP_DIR}/relation-b"
mkdir -p "$RELATION_A" "$RELATION_B"
python3 - "$RELATION_A" "$RELATION_B" <<'PY'
import base64
import sys
from pathlib import Path

payload = base64.b64encode(b"%PDF-1.4\nshared relation bytes\n").decode()
for index, target in enumerate((Path(sys.argv[1]), Path(sys.argv[2])), 1):
    filename = "shared.pdf" if index == 1 else "shared.bin"
    content_type = "application/pdf" if index == 1 else "application/octet-stream"
    message = (
        f"From: sender{index}@example.test\nTo: receiver@example.test\nSubject: Relation {index}\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=relation\n\n"
        "--relation\nContent-Type: text/plain\n\nbody\n"
        f"--relation\nContent-Type: {content_type}\n"
        f"Content-Disposition: attachment; filename={filename}\n"
        "Content-Transfer-Encoding: base64\n\n"
        f"{payload}\n--relation--\n"
    ).encode()
    (target / "message.eml").write_bytes(message)
PY
bash "$HELPER" folder import "$RELATION_A" --repo-path "$REPO_PATH" --json >"${TMP_DIR}/relation-a.json" &
relation_a_pid=$!
bash "$HELPER" folder import "$RELATION_B" --repo-path "$REPO_PATH" --json >"${TMP_DIR}/relation-b.json" &
relation_b_pid=$!
wait "$relation_a_pid"
wait "$relation_b_pid"
relation_digest=$(printf '%s\n' '%PDF-1.4' 'shared relation bytes' | shasum -a 256 | awk '{print $1}')
if jq -e --arg digest "$relation_digest" \
	'select(.sha256 == $digest) | (.parent_sources | length) == 2' \
	"${KNOWLEDGE_ROOT}"/sources/*/meta.json >/dev/null; then
	pass "concurrent relation updates preserve every parent"
else
	fail "concurrent relation updates preserve every parent" "parent relation was lost"
fi
relation_source=$(jq -r --arg digest "$relation_digest" 'select(.sha256 == $digest) | .id' \
	"${KNOWLEDGE_ROOT}"/sources/*/meta.json)
if jq -e '.jobs[] | select(.processor == "text-extraction" and .status == "queued")' \
	"${KNOWLEDGE_ROOT}/sources/${relation_source}/enrichment.json" >/dev/null 2>&1; then
	pass "concurrent attachment aliases preserve every enrichment job"
else
	fail "concurrent attachment aliases preserve every enrichment job" "text extraction job was lost"
fi

SAFETY_TREE="${TMP_DIR}/safety-tree"
mkdir -p "$SAFETY_TREE"
printf 'safe manifest fixture\n' >"${SAFETY_TREE}/safe.txt"
safety_plan=$(bash "$HELPER" folder import "$SAFETY_TREE" --repo-path "$REPO_PATH" --dry-run --json)
safety_root=$(jq -r '.root_id' <<<"$safety_plan")
safety_state="${KNOWLEDGE_ROOT}/index/folder-imports/${safety_root}"
mkdir -p "$safety_state"
printf 'manifest sentinel\n' >"${TMP_DIR}/manifest-sentinel"
ln -s "${TMP_DIR}/manifest-sentinel" "${safety_state}/manifest.json"
safety_status=0
bash "$HELPER" folder import "$SAFETY_TREE" --repo-path "$REPO_PATH" --json >/dev/null 2>&1 || safety_status=$?
if [[ "$safety_status" -eq 1 ]] && [[ "$(<"${TMP_DIR}/manifest-sentinel")" == "manifest sentinel" ]]; then
	pass "symlinked checkpoint paths fail closed"
else
	fail "symlinked checkpoint paths fail closed" "exit=$safety_status or sentinel changed"
fi

ANCESTOR_TREE="${TMP_DIR}/ancestor-tree"
mkdir -p "$ANCESTOR_TREE" "${TMP_DIR}/ancestor-target"
printf 'safe ancestor fixture\n' >"${ANCESTOR_TREE}/safe.txt"
ancestor_plan=$(bash "$HELPER" folder import "$ANCESTOR_TREE" --repo-path "$REPO_PATH" --dry-run --json)
ancestor_root=$(jq -r '.root_id' <<<"$ancestor_plan")
ln -s "${TMP_DIR}/ancestor-target" "${KNOWLEDGE_ROOT}/index/folder-imports/${ancestor_root}"
ancestor_status=0
bash "$HELPER" folder import "$ANCESTOR_TREE" --repo-path "$REPO_PATH" --json >/dev/null 2>&1 || ancestor_status=$?
if [[ "$ancestor_status" -eq 1 ]] && [[ ! -e "${TMP_DIR}/ancestor-target/lease.json" ]]; then
	pass "symlinked checkpoint ancestors fail closed"
else
	fail "symlinked checkpoint ancestors fail closed" "unsafe ancestor accepted"
fi

blob_ancestor_result=$(
	python3 - "${SCRIPT_DIR}/../scripts" "${TMP_DIR}/blob-home" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from knowledge_folder_store import EvidenceProcessingError, _secure_directory

home = Path(sys.argv[2])
outside = home.parent / "blob-outside"
home.mkdir()
outside.mkdir()
(home / ".aidevops").symlink_to(outside, target_is_directory=True)
try:
    _secure_directory(home, ".aidevops", ".agent-workspace", "knowledge-blobs")
except EvidenceProcessingError:
    print(0)
else:
    print(1)
PY
)
if [[ "$blob_ancestor_result" -eq 0 ]]; then
	pass "symlinked blob ancestors fail closed"
else
	fail "symlinked blob ancestors fail closed" "unsafe blob ancestor accepted"
fi

COVERAGE_TREE="${TMP_DIR}/coverage-tree"
mkdir -p "${COVERAGE_TREE}/hidden"
printf 'hidden evidence\n' >"${COVERAGE_TREE}/hidden/old.txt"
printf 'visible evidence\n' >"${COVERAGE_TREE}/visible.txt"
coverage_output=$(bash "$HELPER" folder import "$COVERAGE_TREE" --repo-path "$REPO_PATH" --json)
coverage_root=$(jq -r '.root_id' <<<"$coverage_output")
coverage_manifest="${KNOWLEDGE_ROOT}/index/folder-imports/${coverage_root}/manifest.json"
rm "${COVERAGE_TREE}/hidden/old.txt"
bash "$HELPER" folder import "$COVERAGE_TREE" --repo-path "$REPO_PATH" --exclude hidden --json >/dev/null
if ! jq -e '.observations[] | select(.observation == "source-deleted" and .path == "hidden/old.txt")' \
	"$coverage_manifest" >/dev/null; then
	pass "excluded coverage suppresses deletion inference"
else
	fail "excluded coverage suppresses deletion inference" "excluded source was marked deleted"
fi
node_status=0
node_output=$(bash "$HELPER" folder import "$COVERAGE_TREE" --repo-path "$REPO_PATH" --max-nodes 1 --json) || node_status=$?
if [[ "$node_status" -eq 2 ]] && jq -e '.counts["budget-stopped"] == 1' <<<"$node_output" >/dev/null &&
	! jq -e '.observations[] | select(.observation == "source-deleted" and .path == "hidden/old.txt")' \
		"$coverage_manifest" >/dev/null; then
	pass "node-bounded incomplete coverage suppresses deletion inference"
else
	fail "node-bounded incomplete coverage suppresses deletion inference" "budget stop inferred deletion"
fi

rm "${TREE}/sub/renamed.md"
bash "$HELPER" folder import "$TREE" --repo-path "$REPO_PATH" --json >/dev/null
if jq -e '.observations[] | select(.observation == "source-deleted" and .path == "sub/renamed.md")' "$MANIFEST" >/dev/null; then
	pass "source deletion is an observation, not a purge"
else
	fail "source deletion is an observation, not a purge" "deletion observation missing"
fi
status_output=$(bash "$HELPER" folder status "$TREE" --repo-path "$REPO_PATH" --json)
assert_json "status reads the latest committed snapshot" "$status_output" '.status == "complete" and .fencing_token >= 4'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
