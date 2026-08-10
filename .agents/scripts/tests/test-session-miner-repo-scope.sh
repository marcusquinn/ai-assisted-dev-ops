#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

DB_PATH="${TMP_DIR}/opencode.db"
TARGET_REPO="${TMP_DIR}/target-repo"
OTHER_REPO="${TMP_DIR}/other-project"
OUTPUT_DIR="${TMP_DIR}/out"

mkdir -p "${TARGET_REPO}/subdir" "${OTHER_REPO}" "${OUTPUT_DIR}"

sqlite3 "${DB_PATH}" <<SQL
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  title TEXT,
  directory TEXT,
  time_created INTEGER,
  time_updated INTEGER
);
CREATE TABLE message (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  data TEXT,
  time_created INTEGER
);
CREATE TABLE part (
  id TEXT PRIMARY KEY,
  session_id TEXT,
  message_id TEXT,
  data TEXT,
  time_created INTEGER
);
INSERT INTO session VALUES ('s-target', 'target session', '${TARGET_REPO}/subdir', 1000, 2000);
INSERT INTO session VALUES ('s-other', 'other session', '${OTHER_REPO}', 3000, 4000);
INSERT INTO message VALUES ('m-target', 's-target', '{"role":"user","modelID":"test-model"}', 1100);
INSERT INTO message VALUES ('m-other', 's-other', '{"role":"user","modelID":"test-model"}', 3100);
INSERT INTO message VALUES ('m-target-new', 's-target', '{"role":"user","modelID":"test-model"}', 2100);
INSERT INTO part VALUES ('p-target', 's-target', 'm-target', '{"type":"text","text":"Always use target repo scoped insights for contributor reports."}', 1100);
INSERT INTO part VALUES ('p-other', 's-other', 'm-other', '{"type":"text","text":"Always use unrelated other project insights for contributor reports."}', 3100);
INSERT INTO part VALUES ('p-target-new', 's-target', 'm-target-new', '{"type":"text","text":"Always use newly observed target repo insights for contributor reports."}', 2100);
SQL

python3 "${REPO_ROOT}/.agents/scripts/session-miner/extract.py" \
	--db "${DB_PATH}" \
	--format jsonl \
	--output "${OUTPUT_DIR}" \
	--repo-dir "${TARGET_REPO}" \
	--no-git >/dev/null

extraction_file=$(printf '%s\n' "${OUTPUT_DIR}"/extraction_*.jsonl)

python3 - "${extraction_file}" "${TARGET_REPO}" "${OTHER_REPO}" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
target_repo = Path(sys.argv[2]).name
other_repo = Path(sys.argv[3]).name
payload = json.dumps(records)

assert target_repo in payload, payload
assert other_repo not in payload, payload
assert "target repo scoped insights" in payload, payload
assert "unrelated other project insights" not in payload, payload
PY

rm -f "${OUTPUT_DIR}"/*

python3 "${REPO_ROOT}/.agents/scripts/session-miner/extract.py" \
	--db "${DB_PATH}" \
	--format jsonl \
	--output "${OUTPUT_DIR}" \
	--repo-dir "${TARGET_REPO}" \
	--since-ms 1500 \
	--no-git >/dev/null

extraction_file=$(printf '%s\n' "${OUTPUT_DIR}"/extraction_*.jsonl)

python3 - "${extraction_file}" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
payload = json.dumps(records)
assert "newly observed target repo insights" in payload, payload
assert "target repo scoped insights" not in payload, payload
stats = next(record for record in records if record.get("type") == "stats")
assert stats["extraction_metadata"] == {
    "window_start_ms": 1500,
    "window_end_ms": 2100,
    "source_high_water_ms": 2100,
}, stats
PY

printf 'session-miner repo scope test passed\n'
