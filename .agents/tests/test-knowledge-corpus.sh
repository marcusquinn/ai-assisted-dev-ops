#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Focused tests for the private knowledge corpus catalog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR="$(mktemp -d)"
BASE="${TMP_DIR}/knowledge"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf '[PASS] %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	FAIL=$((FAIL + 1))
	printf '[FAIL] %s — %s\n' "$name" "$detail"
	return 0
}

assert_success() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed"; fi
	return 0
}

assert_denied() {
	local name="$1"
	local pattern="$2"
	shift 2
	local output
	if output=$("$@" 2>&1); then
		fail "$name" "command unexpectedly succeeded"
	elif [[ "$output" == *"$pattern"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected error: $output"
	fi
	return 0
}

mkdir -p "${BASE}/_knowledge/sources"
printf 'legacy-data\n' >"${BASE}/_knowledge/sources/existing.txt"
assert_success "provision creates catalog" bash "$HELPER" provision --base "$BASE"

resolved=$(bash "$HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read)
if [[ "$resolved" == "${BASE}/_knowledge" && -f "${resolved}/sources/existing.txt" ]]; then
	pass "legacy personal alias resolves without moving files"
else
	fail "legacy personal alias resolves without moving files" "resolved=$resolved"
fi

first_state=$(
	python3 - "$BASE" <<'PY'
import json, sqlite3, sys
from pathlib import Path
base = Path(sys.argv[1])
context = json.loads((base / "_config/principal.json").read_text())
db = sqlite3.connect(base / "catalog.db")
print(context["principal_id"], db.execute("SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default'").fetchone()[0])
PY
)
assert_success "repeated provision is idempotent" bash "$HELPER" provision --base "$BASE"
second_state=$(
	python3 - "$BASE" <<'PY'
import json, sqlite3, sys
from pathlib import Path
base = Path(sys.argv[1])
context = json.loads((base / "_config/principal.json").read_text())
db = sqlite3.connect(base / "catalog.db")
print(context["principal_id"], db.execute("SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default'").fetchone()[0])
PY
)
if [[ "$first_state" == "$second_state" ]]; then pass "idempotency preserves opaque IDs"; else fail "idempotency preserves opaque IDs" "$first_state != $second_state"; fi

context_mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "${BASE}/_config/principal.json")
catalog_mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "${BASE}/catalog.db")
if [[ "$context_mode" == "0o600" && "$catalog_mode" == "0o600" ]]; then pass "private files use mode 0600"; else fail "private files use mode 0600" "$context_mode $catalog_mode"; fi

python3 - "$BASE" <<'PY'
import json, sqlite3, sys, uuid
from pathlib import Path
base = Path(sys.argv[1])
principal = json.loads((base / "_config/principal.json").read_text())["principal_id"]
db = sqlite3.connect(base / "catalog.db")
workspace = "wsp_" + uuid.uuid4().hex
corpus = "crp_" + uuid.uuid4().hex
db.execute("INSERT INTO workspaces VALUES (?, 'shared', 'active')", (workspace,))
db.execute("INSERT INTO corpora VALUES (?, ?, ?, 'internal', 'active')", (corpus, workspace, str(base / '_knowledge')))
db.execute("INSERT INTO corpus_aliases VALUES ('cross-workspace', ?)", (corpus,))
db.execute("INSERT INTO corpus_grants VALUES (?, ?, 'reader', 'knowledge.read', '*', 'active')", (corpus, principal))
db.commit()
PY
assert_denied "cross-workspace access denied without membership" "access denied" bash "$HELPER" resolve --base "$BASE" --alias cross-workspace
assert_denied "forged alias fails closed" "access denied" bash "$HELPER" resolve --base "$BASE" --alias forged-alias

python3 - "$BASE" "$TMP_DIR" <<'PY'
import json, sqlite3, sys, uuid
from pathlib import Path
base, outside = Path(sys.argv[1]), Path(sys.argv[2]) / "outside"
outside.mkdir()
principal = json.loads((base / "_config/principal.json").read_text())["principal_id"]
db = sqlite3.connect(base / "catalog.db")
workspace = "wsp_" + uuid.uuid4().hex
corpus = "crp_" + uuid.uuid4().hex
db.execute("INSERT INTO workspaces VALUES (?, 'shared', 'active')", (workspace,))
db.execute("INSERT INTO workspace_memberships VALUES (?, ?, 'reader', 'active')", (workspace, principal))
db.execute("INSERT INTO corpora VALUES (?, ?, ?, 'internal', 'active')", (corpus, workspace, str(outside)))
db.execute("INSERT INTO corpus_aliases VALUES ('unsafe-path', ?)", (corpus,))
db.execute("INSERT INTO corpus_grants VALUES (?, ?, 'reader', 'knowledge.read', '*', 'active')", (corpus, principal))
db.commit()
PY
assert_denied "unsafe path outside base fails closed" "unsafe path" bash "$HELPER" resolve --base "$BASE" --alias unsafe-path

python3 - "$BASE" <<'PY'
import json, sqlite3, sys
from pathlib import Path
base = Path(sys.argv[1])
principal = json.loads((base / "_config/principal.json").read_text())["principal_id"]
db = sqlite3.connect(base / "catalog.db")
db.execute("UPDATE corpus_grants SET status='inactive' WHERE principal_id=? AND capability='knowledge.read' AND corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default')", (principal,))
db.commit()
PY
assert_denied "inactive capability grant fails closed" "access denied" bash "$HELPER" resolve --base "$BASE"
assert_success "provision does not reactivate revoked grants" bash "$HELPER" provision --base "$BASE"
assert_denied "revoked grant remains inactive after provision" "access denied" bash "$HELPER" resolve --base "$BASE"
python3 - "$BASE" <<'PY'
import sqlite3, sys
from pathlib import Path
base = Path(sys.argv[1])
db = sqlite3.connect(base / "catalog.db")
db.execute("UPDATE corpus_grants SET status='active' WHERE capability='knowledge.read' AND corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default')")
db.commit()
PY

chmod 0644 "${BASE}/_config/principal.json"
assert_denied "bad context permissions fail closed" "context permissions" bash "$HELPER" resolve --base "$BASE"
chmod 0600 "${BASE}/_config/principal.json"
cp "${BASE}/_config/principal.json" "${BASE}/_config/principal.good"
printf '{bad json\n' >"${BASE}/_config/principal.json"
chmod 0600 "${BASE}/_config/principal.json"
assert_denied "malformed context fails closed" "malformed authentication context" bash "$HELPER" resolve --base "$BASE"
mv "${BASE}/_config/principal.good" "${BASE}/_config/principal.json"

mv "${BASE}/_config/principal.json" "${BASE}/_config/principal.real"
ln -s "${BASE}/_config/principal.real" "${BASE}/_config/principal.json"
assert_denied "symlinked context fails closed" "regular non-symlink" bash "$HELPER" resolve --base "$BASE"
rm "${BASE}/_config/principal.json"
mv "${BASE}/_config/principal.real" "${BASE}/_config/principal.json"

assert_denied "caller-provided principal is rejected" "unrecognized arguments" bash "$HELPER" resolve --base "$BASE" --principal-id prn_forged

INTEGRATION_BASE="${TMP_DIR}/integration-personal"
INTEGRATION_REPO="${TMP_DIR}/integration-repo"
INTEGRATION_REPOS="${TMP_DIR}/repos.json"
mkdir -p "$INTEGRATION_REPO"
cat >"$INTEGRATION_REPOS" <<EOF
{"initialized_repos":[{"path":"${INTEGRATION_REPO}","knowledge":"personal"}]}
EOF
REPOS_FILE="$INTEGRATION_REPOS" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "${SCRIPT_DIR}/../scripts/knowledge-helper.sh" provision "$INTEGRATION_REPO" >/dev/null
printf 'authorized personal search text\n' >"${TMP_DIR}/personal-source.txt"
assert_success "personal add resolves write grant" env REPOS_FILE="$INTEGRATION_REPOS" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "${SCRIPT_DIR}/../scripts/knowledge-helper.sh" add "${TMP_DIR}/personal-source.txt" --repo-path "$INTEGRATION_REPO"
personal_list=$(REPOS_FILE="$INTEGRATION_REPOS" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "${SCRIPT_DIR}/../scripts/knowledge-helper.sh" list --repo-path "$INTEGRATION_REPO")
if [[ "$personal_list" == *"personal-source"* ]]; then pass "personal list resolves read grant"; else fail "personal list resolves read grant" "$personal_list"; fi
cp "${TMP_DIR}/personal-source.txt" "${INTEGRATION_BASE}/_knowledge/sources/personal-source/text.txt"
personal_search=$(REPOS_FILE="$INTEGRATION_REPOS" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "${SCRIPT_DIR}/../scripts/knowledge-helper.sh" search "authorized personal" --repo-path "$INTEGRATION_REPO")
if [[ "$personal_search" == *"personal-source"* ]]; then pass "personal search resolves read grant"; else fail "personal search resolves read grant" "$personal_search"; fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
