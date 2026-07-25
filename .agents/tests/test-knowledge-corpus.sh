#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-corpus.sh — Corpus catalog and authorization regression tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
KNOWLEDGE_HELPER="${SCRIPT_DIR}/../scripts/knowledge-helper.sh"

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
export AIDEVOPS_VAULT_DIR="${TMP_DIR}/vault-disabled"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

pass() {
	local description="$1"
	PASS=$((PASS + 1))
	printf '  PASS  %s\n' "$description"
	return 0
}

fail() {
	local description="$1"
	local reason="${2:-}"
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$description"
	[[ -n "$reason" ]] && printf '        %s\n' "$reason"
	return 0
}

assert_eq() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$description"
	else
		fail "$description" "expected='$expected' actual='$actual'"
	fi
	return 0
}

assert_file() {
	local description="$1"
	local path="$2"
	if [[ -f "$path" && ! -L "$path" ]]; then
		pass "$description"
	else
		fail "$description" "expected regular non-symlink file: $path"
	fi
	return 0
}

assert_not_exists() {
	local description="$1"
	local path="$2"
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		pass "$description"
	else
		fail "$description" "expected path to remain absent: $path"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local value="$2"
	local expected="$3"
	if [[ "$value" == *"$expected"* ]]; then
		pass "$description"
	else
		fail "$description" "expected output to contain '$expected': $value"
	fi
	return 0
}

assert_matches() {
	local description="$1"
	local value="$2"
	local pattern="$3"
	if [[ "$value" =~ $pattern ]]; then
		pass "$description"
	else
		fail "$description" "value '$value' does not match '$pattern'"
	fi
	return 0
}

expect_failure() {
	local description="$1"
	local expected="$2"
	shift 2
	local output=""
	local rc=0
	set +e
	output=$("$@" 2>&1)
	rc=$?
	set -e
	if [[ $rc -ne 0 && "$output" == *"$expected"* ]]; then
		pass "$description"
	else
		fail "$description" "rc=$rc expected='$expected' output='$output'"
	fi
	return 0
}

path_mode() {
	local path="$1"
	if stat -f '%Lp' "$path" >/dev/null 2>&1; then
		stat -f '%Lp' "$path"
	else
		stat -c '%a' "$path"
	fi
	return 0
}

db_query() {
	local db_path="$1"
	local query="$2"
	python3 - "$db_path" "$query" <<'PY' || return 1
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(sys.argv[2]).fetchone()
print("" if row is None else "|".join(str(value) for value in row))
PY
	return 0
}

db_exec() {
	local db_path="$1"
	local query="$2"
	python3 - "$db_path" "$query" <<'PY' || return 1
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute(sys.argv[2])
PY
	return 0
}

context_principal() {
	local context_path="$1"
	python3 - "$context_path" <<'PY' || return 1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["principal_id"])
PY
	return 0
}

create_legacy_tree() {
	local base_path="$1"
	mkdir -p "$base_path/_knowledge/inbox"
	mkdir -p "$base_path/_knowledge/staging"
	mkdir -p "$base_path/_knowledge/sources"
	mkdir -p "$base_path/_knowledge/index"
	mkdir -p "$base_path/_knowledge/collections"
	mkdir -p "$base_path/_knowledge/_config"
	return 0
}

printf 'Test 1: private schema bootstrap and legacy alias\n'
BASE="${TMP_DIR}/personal"
create_legacy_tree "$BASE"
BASE="$(cd "$BASE" && pwd -P)"
LEGACY_ROOT="${BASE}/_knowledge"
CATALOG="${BASE}/catalog.db"
CONTEXT="${BASE}/_config/principal.json"
printf 'legacy-data\n' >"${LEGACY_ROOT}/sources/existing.txt"

bash "$CORPUS_HELPER" provision --base "$BASE"

assert_file "1.1 catalog.db created" "$CATALOG"
assert_file "1.2 principal context created" "$CONTEXT"
assert_eq "1.3 catalog mode is 0600" "$(path_mode "$CATALOG")" "600"
assert_eq "1.4 context mode is 0600" "$(path_mode "$CONTEXT")" "600"
assert_eq "1.5 config directory mode is 0700" "$(path_mode "${BASE}/_config")" "700"
assert_eq "1.6 legacy root mode is 0700" "$(path_mode "$LEGACY_ROOT")" "700"
assert_file "1.7 legacy content remains in place" "${LEGACY_ROOT}/sources/existing.txt"

resolved=$(bash "$CORPUS_HELPER" resolve --base "$BASE" \
	--alias personal:default --capability knowledge.read)
assert_eq "1.8 read grant resolves legacy root" "$resolved" "$LEGACY_ROOT"

listed=$(bash "$CORPUS_HELPER" list --base "$BASE" --capability knowledge.read)
assert_contains "1.9 authorized list includes personal alias" "$listed" "personal:default"
assert_contains "1.10 authorized list includes legacy path" "$listed" "$LEGACY_ROOT"
assert_eq "1.11 schema version is 2" \
	"$(db_query "$CATALOG" "SELECT value FROM schema_meta WHERE key='schema_version'")" "2"
assert_eq "1.12 bootstrap graph has one row per ownership edge" \
	"$(db_query "$CATALOG" "SELECT (SELECT count(*) FROM principals),(SELECT count(*) FROM workspaces),(SELECT count(*) FROM workspace_memberships),(SELECT count(*) FROM corpora),(SELECT count(*) FROM corpus_aliases)")" \
	"1|1|1|1|1"
assert_eq "1.13 bootstrap graph has three explicit grants" \
	"$(db_query "$CATALOG" "SELECT count(*) FROM corpus_grants")" "3"
workspace_and_corpus=$(db_query "$CATALOG" \
	"SELECT c.workspace_id,c.corpus_id FROM corpora c JOIN corpus_aliases a ON a.corpus_id=c.corpus_id WHERE a.alias='personal:default'")
assert_matches "1.14 workspace and corpus IDs are opaque" "$workspace_and_corpus" \
	'^wsp_[0-9a-f]{32}\|cor_[0-9a-f]{32}$'

principal_before=$(context_principal "$CONTEXT")
counts_before=$(db_query "$CATALOG" \
	"SELECT (SELECT count(*) FROM principals),(SELECT count(*) FROM workspaces),(SELECT count(*) FROM workspace_memberships),(SELECT count(*) FROM corpora),(SELECT count(*) FROM corpus_aliases),(SELECT count(*) FROM corpus_grants)")
assert_matches "1.15 principal ID is opaque" "$principal_before" '^prn_[0-9a-f]{32}$'

bash "$CORPUS_HELPER" provision --base "$BASE"
assert_eq "1.16 repeated provision preserves principal" \
	"$(context_principal "$CONTEXT")" "$principal_before"
assert_eq "1.17 repeated provision creates no duplicate graph rows" \
	"$(db_query "$CATALOG" "SELECT (SELECT count(*) FROM principals),(SELECT count(*) FROM workspaces),(SELECT count(*) FROM workspace_memberships),(SELECT count(*) FROM corpora),(SELECT count(*) FROM corpus_aliases),(SELECT count(*) FROM corpus_grants)")" \
	"$counts_before"

MISSING_CATALOG_BASE="${TMP_DIR}/missing-catalog"
mkdir -p "${MISSING_CATALOG_BASE}/_config"
chmod 0700 "$MISSING_CATALOG_BASE" "${MISSING_CATALOG_BASE}/_config"
cp "$CONTEXT" "${MISSING_CATALOG_BASE}/_config/principal.json"
chmod 0600 "${MISSING_CATALOG_BASE}/_config/principal.json"
expect_failure "1.18 resolve rejects a missing catalog without creating it" "catalog missing" \
	bash "$CORPUS_HELPER" resolve --base "$MISSING_CATALOG_BASE"
expect_failure "1.19 list rejects a missing catalog without creating it" "catalog missing" \
	bash "$CORPUS_HELPER" list --base "$MISSING_CATALOG_BASE"
assert_not_exists "1.20 read commands leave a missing catalog absent" \
	"${MISSING_CATALOG_BASE}/catalog.db"

printf 'Test 2: default-deny authorization edges\n'
db_exec "$CATALOG" "UPDATE workspace_memberships SET status='inactive'"
expect_failure "2.1 inactive membership denies resolution" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE workspace_memberships SET status='active'"

db_exec "$CATALOG" "UPDATE corpus_grants SET status='inactive' WHERE capability='knowledge.read'"
expect_failure "2.2 inactive capability grant denies resolution" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
bash "$CORPUS_HELPER" provision --base "$BASE"
expect_failure "2.2a provision does not reactivate a revoked grant" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE corpus_grants SET status='active' WHERE capability='knowledge.read'"

db_exec "$CATALOG" "UPDATE corpus_grants SET scope='none' WHERE capability='knowledge.read'"
expect_failure "2.3 non-corpus capability scope denies resolution" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE corpus_grants SET scope='corpus' WHERE capability='knowledge.read'"

db_exec "$CATALOG" "UPDATE principals SET status='inactive'"
expect_failure "2.4 inactive principal denies resolution" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE principals SET status='active'"

db_exec "$CATALOG" "UPDATE workspaces SET status='inactive'"
expect_failure "2.5 inactive workspace denies resolution" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE workspaces SET status='active'"

db_exec "$CATALOG" "UPDATE corpora SET status='inactive'"
expect_failure "2.6 inactive corpus denies resolution" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE corpora SET status='active'"

python3 - "$CATALOG" "$BASE" "$principal_before" <<'PY'
import sqlite3
import sys

database, base, principal = sys.argv[1:]
with sqlite3.connect(database) as connection:
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute(
        "INSERT INTO workspaces(workspace_id,kind,status) VALUES(?,?,?)",
        ("wsp_" + "a" * 32, "shared", "active"),
    )
    connection.execute(
        "INSERT INTO corpora(corpus_id,workspace_id,location_ref,sensitivity,status) "
        "VALUES(?,?,?,?,?)",
        ("cor_" + "b" * 32, "wsp_" + "a" * 32, base + "/_knowledge", "internal", "active"),
    )
    connection.execute(
        "INSERT INTO corpus_aliases(alias,corpus_id) VALUES(?,?)",
        ("workspace:forged", "cor_" + "b" * 32),
    )
    connection.execute(
        "INSERT INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) "
        "VALUES(?,?,?,?,?,?)",
        ("cor_" + "b" * 32, principal, "reader", "knowledge.read", "corpus", "active"),
    )
PY
expect_failure "2.7 grant without workspace membership denies cross-workspace access" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias workspace:forged --capability knowledge.read
expect_failure "2.8 unknown alias fails closed" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:unknown --capability knowledge.read

OUTSIDE="${TMP_DIR}/outside"
mkdir -p "$OUTSIDE"
db_exec "$CATALOG" "UPDATE corpora SET location_ref='${OUTSIDE}' WHERE corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default')"
expect_failure "2.9 out-of-base catalog path is rejected" "unsafe path" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE corpora SET location_ref='${LEGACY_ROOT}' WHERE corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default')"

ln -s "$OUTSIDE" "${BASE}/linked-outside"
db_exec "$CATALOG" "UPDATE corpora SET location_ref='${BASE}/linked-outside' WHERE corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default')"
expect_failure "2.10 symlinked catalog path is rejected" "unsafe path" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
db_exec "$CATALOG" "UPDATE corpora SET location_ref='${LEGACY_ROOT}' WHERE corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default')"
rm "${BASE}/linked-outside"

expect_failure "2.11 unsupported capabilities fail closed" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.admin

printf 'Test 3: authentication context validation\n'
cp "$CONTEXT" "${CONTEXT}.backup"
chmod 0644 "$CONTEXT"
expect_failure "3.1 group/world-readable context fails closed" "context permissions" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
mv "${CONTEXT}.backup" "$CONTEXT"
chmod 0600 "$CONTEXT"

cp "$CONTEXT" "${CONTEXT}.backup"
printf '{invalid-json\n' >"$CONTEXT"
chmod 0600 "$CONTEXT"
expect_failure "3.2 malformed context fails closed" "malformed context" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
mv "${CONTEXT}.backup" "$CONTEXT"

mv "$CONTEXT" "${CONTEXT}.real"
ln -s "principal.json.real" "$CONTEXT"
expect_failure "3.3 symlinked context fails closed" "context symlink" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
rm "$CONTEXT"
mv "${CONTEXT}.real" "$CONTEXT"

cp "$CONTEXT" "${CONTEXT}.backup"
python3 - "$CONTEXT" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"version": 1, "principal_id": "prn_" + "f" * 32}, handle)
    handle.write("\n")
os.chmod(path, 0o600)
PY
expect_failure "3.4 unknown authenticated principal fails closed" "access denied" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
mv "${CONTEXT}.backup" "$CONTEXT"

chmod 0644 "$CATALOG"
expect_failure "3.5 group/world-readable catalog fails closed" "catalog permissions" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
chmod 0600 "$CATALOG"

chmod 0755 "${BASE}/_config"
expect_failure "3.6 non-private config directory fails closed" "config directory permissions" \
	bash "$CORPUS_HELPER" resolve --base "$BASE" --alias personal:default --capability knowledge.read
chmod 0700 "${BASE}/_config"

printf 'Test 4: personal-mode integration preserves existing CLI behavior\n'
INTEGRATION_BASE="${TMP_DIR}/integration-personal"
INTEGRATION_REPO="${TMP_DIR}/integration-repo"
REPOS_FILE="${TMP_DIR}/repos.json"
mkdir -p "$INTEGRATION_REPO"
cat >"$REPOS_FILE" <<EOF
{
  "initialized_repos": [
    {
      "path": "${INTEGRATION_REPO}",
      "slug": "test/personal-repo",
      "knowledge": "personal"
    }
  ],
  "git_parent_dirs": []
}
EOF

REPOS_FILE="$REPOS_FILE" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "$KNOWLEDGE_HELPER" provision "$INTEGRATION_REPO" >/dev/null
assert_file "4.1 personal provision creates catalog" "${INTEGRATION_BASE}/catalog.db"
assert_file "4.2 personal provision creates authenticated context" \
	"${INTEGRATION_BASE}/_config/principal.json"
if [[ ! -e "${INTEGRATION_REPO}/_knowledge" ]]; then
	pass "4.3 personal mode does not create repo knowledge root"
else
	fail "4.3 personal mode does not create repo knowledge root"
fi

INPUT_FILE="${TMP_DIR}/personal-sample.txt"
printf 'Personal catalog integration\n' >"$INPUT_FILE"
REPOS_FILE="$REPOS_FILE" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "$KNOWLEDGE_HELPER" add "$INPUT_FILE" --id personal-sample \
	--repo-path "$INTEGRATION_REPO" >/dev/null
assert_file "4.4 personal add writes through authorized legacy alias" \
	"${INTEGRATION_BASE}/_knowledge/sources/personal-sample/meta.json"

list_output=$(REPOS_FILE="$REPOS_FILE" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "$KNOWLEDGE_HELPER" list --repo-path "$INTEGRATION_REPO")
assert_contains "4.5 personal list reads through authorized legacy alias" \
	"$list_output" "personal-sample"

printf 'authorized searchable corpus text\n' \
	>"${INTEGRATION_BASE}/_knowledge/sources/personal-sample/text.txt"
search_output=$(REPOS_FILE="$REPOS_FILE" PERSONAL_PLANE_BASE="$INTEGRATION_BASE" \
	bash "$KNOWLEDGE_HELPER" search "searchable corpus" --repo-path "$INTEGRATION_REPO")
assert_contains "4.6 personal search reads through authorized legacy alias" \
	"$search_output" "personal-sample"
assert_eq "4.7 repos.json mode remains personal" \
	"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["initialized_repos"][0]["knowledge"])' "$REPOS_FILE")" \
	"personal"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
