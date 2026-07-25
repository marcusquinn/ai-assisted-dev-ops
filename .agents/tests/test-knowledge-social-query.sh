#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-query.sh — Authorized federated social query tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
BASE="${TMP_DIR}/knowledge"
PERSONAL_ROOT="${BASE}/_knowledge"
TEAM_ROOT="${BASE}/workspace-alpha"
CATALOG="${BASE}/catalog.db"
PERSONAL_ARCHIVE="${TMP_DIR}/personal.json"
TEAM_ARCHIVE="${TMP_DIR}/team.json"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

expect_failure() {
	local description="$1"
	local expected="$2"
	shift 2
	local output=""
	if output=$("$@" 2>&1); then
		assert_eq "$description" "accepted" "rejected"
	elif [[ "$output" == *"$expected"* ]]; then
		assert_eq "$description" "rejected" "rejected"
	else
		assert_eq "$description" "$output" "error containing: $expected"
	fi
	return 0
}

json_summary() {
	local payload="$1"
	local selector="$2"
	python3 - "$payload" "$selector" <<'PY' || return 1
import json
import sys

data = json.loads(sys.argv[1])
selector = sys.argv[2]
results = data.get("results", [])

def result(remote_id):
    return next(item for item in results if item["remote_id"] == remote_id)

if selector == "scope":
    print(",".join(data["scope"]["aliases"]))
elif selector == "ids":
    print(",".join(item["remote_id"] for item in results))
elif selector == "count":
    print(len(results))
elif selector == "common-citations":
    print(",".join(item["corpus_alias"] for item in result("post-common")["citations"]))
elif selector == "common-labels":
    print(",".join(result("post-common")["opinion_semantics"]["evidence_labels"]))
elif selector == "common-support":
    print(str(result("post-common")["opinion_semantics"]["supports_attributed_opinion"]).lower())
elif selector == "common-private-count":
    print(len(result("post-common")["private_annotations"]))
elif selector == "common-private-body":
    print("|".join(item["body"] for item in result("post-common")["private_annotations"]))
elif selector == "provenance":
    citations = result("post-common")["citations"]
    valid = all(
        citation["batch_id"]
        and citation["batch_stream"]
        and citation["observed_at"]
        and citation["provider"] == "xapi"
        and citation["object_type"] == "post"
        and citation["remote_id"] == "post-common"
        and citation["activities"]
        for citation in citations
    )
    print("complete" if valid else "incomplete")
elif selector == "weak-semantics":
    semantics = result("post-team-weak")["opinion_semantics"]
    print(",".join(semantics["evidence_labels"]) + ":" + str(semantics["supports_attributed_opinion"]).lower())
elif selector == "inferred-semantics":
    inferred = result("post-personal-inferred")
    semantics = inferred["opinion_semantics"]
    labelled = "inference" in semantics["guidance"].lower()
    review = semantics["inference_review"]
    confidence = inferred["citations"][0]["inference_confidence"]
    print(",".join(semantics["evidence_labels"]) + ":" + str(semantics["supports_attributed_opinion"]).lower() + ":" + str(labelled).lower() + ":" + str(review["required"]).lower() + ":" + str(review["confidence_complete"]).lower() + ":" + str(confidence))
elif selector == "annotation":
    print(data["annotation_id"] + ":" + data["visibility"] + ":" + data["remote_id"])
else:
    raise SystemExit(f"unknown selector: {selector}")
PY
	return 0
}

sql_value() {
	local database="$1"
	local query="$2"
	python3 - "$database" "$query" <<'PY' || return 1
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute(sys.argv[2]).fetchone()[0])
PY
	return 0
}

catalog_status() {
	local target="$1"
	local status="$2"
	python3 - "$CATALOG" "$target" "$status" <<'PY' || return 1
import sqlite3
import sys

database, target, status = sys.argv[1:]
with sqlite3.connect(database) as connection:
    if target == "team-membership":
        connection.execute(
            "UPDATE workspace_memberships SET status=? WHERE workspace_id=?",
            (status, "wsp_" + "a" * 32),
        )
    elif target == "team-read":
        connection.execute(
            "UPDATE corpus_grants SET status=? WHERE corpus_id=? AND capability='knowledge.read'",
            (status, "cor_" + "b" * 32),
        )
    elif target == "team-workspace":
        connection.execute(
            "UPDATE workspaces SET status=? WHERE workspace_id=?",
            (status, "wsp_" + "a" * 32),
        )
    elif target == "team-corpus":
        connection.execute(
            "UPDATE corpora SET status=? WHERE corpus_id=?",
            (status, "cor_" + "b" * 32),
        )
    elif target == "personal-write":
        connection.execute(
            "UPDATE corpus_grants SET status=? WHERE corpus_id=(SELECT corpus_id FROM corpus_aliases WHERE alias='personal:default') AND capability='knowledge.write'",
            (status,),
        )
    elif target == "principal":
        connection.execute("UPDATE principals SET status=?", (status,))
    else:
        raise SystemExit(f"unknown catalog target: {target}")
PY
	return 0
}

store_snapshot() {
	local root="$1"
	python3 - "$root" <<'PY' || return 1
import hashlib
import json
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
snapshot = {}
for path in sorted(root.rglob("*")):
    file_stat = path.lstat()
    record = {
        "mode": stat.S_IMODE(file_stat.st_mode),
        "mtime_ns": file_stat.st_mtime_ns,
        "size": file_stat.st_size,
    }
    if path.is_file():
        record["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    snapshot[path.relative_to(root).as_posix()] = record
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
PY
	return 0
}

evidence_matrix() {
	PYTHONPATH="${SCRIPT_DIR}/../scripts" python3 <<'PY' || return 1
from _knowledge_social_query import opinion_semantics

cases = (
    ("bookmark", "observed", "weak_signal"),
    ("follow", "observed", "relationship"),
    ("listed", "observed", "relationship"),
    ("captured", "captured", "observed"),
)
labels = []
for activity_type, evidence_class, expected in cases:
    citation = {
        "evidence_class": evidence_class,
        "activities": [] if activity_type == "captured" else [{"activity_type": activity_type}],
        "inference_confidence": None,
    }
    semantics = opinion_semantics([citation])
    actual = semantics["evidence_labels"][0]
    labels.append(actual if actual == expected else f"unexpected:{actual}")
print(",".join(labels))
PY
	return 0
}

printf 'Authorized federated social query tests\n'
mkdir -p "$PERSONAL_ROOT" "$TEAM_ROOT"
chmod 0700 "$BASE" "$PERSONAL_ROOT" "$TEAM_ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null

python3 - "$CATALOG" "$BASE" "$TEAM_ROOT" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

database, base, team_root = sys.argv[1:]
context = json.loads((Path(base) / "_config" / "principal.json").read_text(encoding="utf-8"))
principal = context["principal_id"]
workspace_id = "wsp_" + "a" * 32
corpus_id = "cor_" + "b" * 32
with sqlite3.connect(database) as connection:
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute(
        "INSERT INTO workspaces(workspace_id,kind,status) VALUES(?,?,?)",
        (workspace_id, "shared", "active"),
    )
    connection.execute(
        "INSERT INTO workspace_memberships(workspace_id,principal_id,role,status) VALUES(?,?,?,?)",
        (workspace_id, principal, "member", "active"),
    )
    connection.execute(
        "INSERT INTO corpora(corpus_id,workspace_id,location_ref,sensitivity,status) VALUES(?,?,?,?,?)",
        (corpus_id, workspace_id, team_root, "internal", "active"),
    )
    connection.execute(
        "INSERT INTO corpus_aliases(alias,corpus_id) VALUES(?,?)",
        ("workspace:alpha", corpus_id),
    )
    for capability in ("knowledge.read", "knowledge.write"):
        connection.execute(
            "INSERT INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) VALUES(?,?,?,?,?,?)",
            (corpus_id, principal, "member", capability, "corpus", "active"),
        )
PY

"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null
"$HELPER" provision --base "$BASE" --alias workspace:alpha >/dev/null

cat >"$PERSONAL_ARCHIVE" <<'JSON'
{
  "provider": "xapi",
  "connection_id": "conn_personal",
  "remote_account_id": "acct-personal",
  "exported_at": "2026-07-25T07:00:00Z",
  "enabled_streams": ["authored"],
  "policy": {"media_hydration": false},
  "accounts": [{"remote_id": "acct-personal", "handle": "private-handle", "display_name": "Personal", "observed_at": "2026-07-25T07:00:00Z"}],
  "objects": [
    {"object_type": "post", "remote_id": "post-common", "account_remote_id": "acct-personal", "text": "federated common evidence", "created_at": "2026-07-24T01:00:00Z", "observed_at": "2026-07-25T07:00:00Z", "evidence_class": "authored"},
    {"object_type": "post", "remote_id": "post-personal-inferred", "account_remote_id": "acct-personal", "text": "federated personal inference", "created_at": "2026-07-24T02:00:00Z", "observed_at": "2026-07-25T07:00:00Z", "evidence_class": "inferred", "provider_json": {"confidence": 0.72}}
  ],
  "activities": [{"activity_type": "authored", "remote_id": "activity-personal-common", "actor_remote_id": "acct-personal", "object_remote_id": "post-common", "occurred_at": "2026-07-24T01:00:00Z", "observed_at": "2026-07-25T07:00:00Z", "state": "active"}],
  "media": [],
  "coverage": [{"stream": "authored", "earliest_at": "2026-07-24T01:00:00Z", "latest_at": "2026-07-24T02:00:00Z", "cursor_exhausted": true, "status": "complete", "observed_at": "2026-07-25T07:00:00Z"}]
}
JSON

cat >"$TEAM_ARCHIVE" <<'JSON'
{
  "provider": "xapi",
  "connection_id": "conn_team",
  "remote_account_id": "acct-team",
  "exported_at": "2026-07-25T07:01:00Z",
  "enabled_streams": ["reposts", "likes"],
  "policy": {"media_hydration": false},
  "accounts": [{"remote_id": "acct-team", "handle": "team-handle", "display_name": "Team", "observed_at": "2026-07-25T07:01:00Z"}],
  "objects": [
    {"object_type": "post", "remote_id": "post-common", "account_remote_id": "acct-team", "text": "federated common team evidence", "created_at": "2026-07-24T01:00:00Z", "observed_at": "2026-07-25T07:01:00Z", "evidence_class": "distributed"},
    {"object_type": "post", "remote_id": "post-team-weak", "account_remote_id": "acct-team", "text": "federated team weak signal", "created_at": "2026-07-24T03:00:00Z", "observed_at": "2026-07-25T07:01:00Z", "evidence_class": "weak_signal"}
  ],
  "activities": [
    {"activity_type": "reposted", "remote_id": "activity-team-common", "actor_remote_id": "acct-team", "object_remote_id": "post-common", "occurred_at": "2026-07-24T01:00:00Z", "observed_at": "2026-07-25T07:01:00Z", "state": "active"},
    {"activity_type": "liked", "remote_id": "activity-team-weak", "actor_remote_id": "acct-team", "object_remote_id": "post-team-weak", "occurred_at": "2026-07-24T03:00:00Z", "observed_at": "2026-07-25T07:01:00Z", "state": "active"}
  ],
  "media": [],
  "coverage": [
    {"stream": "reposts", "earliest_at": "2026-07-24T01:00:00Z", "latest_at": "2026-07-24T01:00:00Z", "cursor_exhausted": true, "status": "complete", "observed_at": "2026-07-25T07:01:00Z"},
    {"stream": "likes", "earliest_at": "2026-07-24T03:00:00Z", "latest_at": "2026-07-24T03:00:00Z", "cursor_exhausted": true, "status": "complete", "observed_at": "2026-07-25T07:01:00Z"}
  ]
}
JSON
chmod 0600 "$PERSONAL_ARCHIVE" "$TEAM_ARCHIVE"

"$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$PERSONAL_ARCHIVE" >/dev/null
"$HELPER" import-archive --base "$BASE" --alias workspace:alpha --archive "$TEAM_ARCHIVE" >/dev/null

query_result=$("$HELPER" query --base "$BASE" --query federated --limit 10)
repeat_result=$("$HELPER" query --base "$BASE" --query federated --limit 10)
assert_eq "default query searches every authorized corpus" \
	"$(json_summary "$query_result" scope)" "personal:default,workspace:alpha"
assert_eq "query output contains no physical corpus path" \
	"$([[ "$query_result" == *"$BASE"* ]] && printf present || printf absent)" "absent"
assert_eq "query output omits mutable account handles" \
	"$([[ "$query_result" == *-handle* ]] && printf present || printf absent)" "absent"
assert_eq "RRF ranks the cross-corpus duplicate ahead of single-source hits" \
	"$(json_summary "$query_result" ids)" "post-common,post-personal-inferred,post-team-weak"
assert_eq "federated ranking and serialization are deterministic" "$repeat_result" "$query_result"
assert_eq "deduplication retains one citation per contributing corpus" \
	"$(json_summary "$query_result" common-citations)" "personal:default,workspace:alpha"
assert_eq "citations retain batch, stream, object, and activity provenance" \
	"$(json_summary "$query_result" provenance)" "complete"
assert_eq "authored and distribution evidence remain explicitly distinct" \
	"$(json_summary "$query_result" common-labels)" "authored,distribution"
assert_eq "authored evidence alone permits attributed opinion semantics" \
	"$(json_summary "$query_result" common-support)" "true"

weak_result=$("$HELPER" query --base "$BASE" --alias workspace:alpha --query "weak signal")
assert_eq "weak activity evidence cannot be presented as opinion" \
	"$(json_summary "$weak_result" weak-semantics)" "weak_signal:false"
inferred_result=$("$HELPER" query --base "$BASE" --alias personal:default --query inference)
assert_eq "inferred evidence stays labelled, reviewable, and non-opinion" \
	"$(json_summary "$inferred_result" inferred-semantics)" "inferred:false:true:true:true:0.72"
assert_eq "bookmark, follow, list, and captured evidence remain non-opinion signals" \
	"$(evidence_matrix)" "weak_signal,relationship,relationship,observed"

python3 - "$PERSONAL_ROOT/index/social.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        "UPDATE objects SET provider_json='{}' WHERE remote_id='post-personal-inferred'"
    )
PY
expect_failure "inferred evidence without confidence fails closed" "valid confidence score" \
	"$HELPER" query --base "$BASE" --alias personal:default --query inference
python3 - "$PERSONAL_ROOT/index/social.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        "UPDATE objects SET provider_json=? WHERE remote_id='post-personal-inferred'",
        ('{"confidence":0.72}',),
    )
PY

body_file="${TMP_DIR}/annotation.txt"
printf 'private personal interpretation\n' >"$body_file"
chmod 0600 "$body_file"
annotation_result=$("$HELPER" annotate --base "$BASE" --provider xapi \
	--object-type post --remote-id post-common --annotation-id ann_common \
	--body-file "$body_file")
assert_eq "annotation writes are owner-only and explicitly private" \
	"$(json_summary "$annotation_result" annotation)" "ann_common:private:post-common"

default_common=$("$HELPER" query --base "$BASE" --query common)
team_common=$("$HELPER" query --base "$BASE" --alias workspace:alpha --query common)
assert_eq "default personal scope overlays private annotations" \
	"$(json_summary "$default_common" common-private-body)" "private personal interpretation"
assert_eq "team-only scope never loads a personal private annotation" \
	"$(json_summary "$team_common" common-private-count)" "0"
assert_eq "team-only output contains no personal citation or account identity" \
	"$([[ "$team_common" == *personal:default* || "$team_common" == *acct-personal* ]] && printf present || printf absent)" "absent"
assert_eq "team corpus stores no private annotation rows" \
	"$(sql_value "$TEAM_ROOT/index/social.db" 'SELECT count(*) FROM annotations')" "0"

printf 'updated private interpretation\n' >"$body_file"
"$HELPER" annotate --base "$BASE" --provider xapi --object-type post \
	--remote-id post-common --annotation-id ann_common --body-file "$body_file" >/dev/null
assert_eq "stable annotation IDs update idempotently in one row" \
	"$(sql_value "$PERSONAL_ROOT/index/social.db" "SELECT count(*) || ':' || body FROM annotations WHERE annotation_id='ann_common'")" \
	"1:updated private interpretation"

chmod 0644 "$body_file"
expect_failure "group-readable annotation input fails closed" "private UTF-8 file" \
	"$HELPER" annotate --base "$BASE" --provider xapi --object-type post \
	--remote-id post-common --body-file "$body_file"
chmod 0600 "$body_file"

query_file="${TMP_DIR}/query.txt"
printf 'common\n' >"$query_file"
chmod 0600 "$query_file"
private_query=$("$HELPER" query --base "$BASE" --query-file "$query_file")
assert_eq "private query files reach the same authorized query path" \
	"$(json_summary "$private_query" common-citations)" "personal:default,workspace:alpha"
chmod 0644 "$query_file"
expect_failure "group-readable query input fails closed" "query file" \
	"$HELPER" query --base "$BASE" --query-file "$query_file"

catalog_status team-membership inactive
membership_result=$("$HELPER" query --base "$BASE" --query common)
assert_eq "inactive workspace membership removes that corpus from default scope" \
	"$(json_summary "$membership_result" scope)" "personal:default"
assert_eq "inactive workspace membership removes team citations" \
	"$(json_summary "$membership_result" common-citations)" "personal:default"
expect_failure "alias narrowing cannot bypass an inactive membership" "access denied" \
	"$HELPER" query --base "$BASE" --alias workspace:alpha --query common
catalog_status team-membership active

catalog_status team-read inactive
grant_result=$("$HELPER" query --base "$BASE" --query common)
assert_eq "inactive read grants remove corpora from default scope" \
	"$(json_summary "$grant_result" scope)" "personal:default"
expect_failure "alias narrowing cannot bypass an inactive read grant" "access denied" \
	"$HELPER" query --base "$BASE" --alias workspace:alpha --query common
catalog_status team-read active

catalog_status team-workspace inactive
workspace_result=$("$HELPER" query --base "$BASE" --query common)
assert_eq "inactive workspaces cannot influence default query results" \
	"$(json_summary "$workspace_result" scope)" "personal:default"
catalog_status team-workspace active

catalog_status team-corpus inactive
corpus_result=$("$HELPER" query --base "$BASE" --query common)
assert_eq "inactive corpora cannot influence default query results" \
	"$(json_summary "$corpus_result" scope)" "personal:default"
catalog_status team-corpus active

catalog_status principal inactive
expect_failure "an inactive authenticated principal has no query scope" "access denied" \
	"$HELPER" query --base "$BASE" --query common
catalog_status principal active

catalog_status personal-write inactive
expect_failure "a revoked personal write grant blocks annotation" "access denied" \
	"$HELPER" annotate --base "$BASE" --provider xapi --object-type post \
	--remote-id post-common --body-file "$body_file"
catalog_status personal-write active

personal_before=$(store_snapshot "$PERSONAL_ROOT")
team_before=$(store_snapshot "$TEAM_ROOT")
"$HELPER" query --base "$BASE" --query federated >/dev/null
assert_eq "query leaves the personal store byte-for-byte unchanged" \
	"$(store_snapshot "$PERSONAL_ROOT")" "$personal_before"
assert_eq "query leaves the team store byte-for-byte unchanged" \
	"$(store_snapshot "$TEAM_ROOT")" "$team_before"

: >"$TEAM_ROOT/index/social.db-wal"
chmod 0600 "$TEAM_ROOT/index/social.db-wal"
expect_failure "federated query rejects uncheckpointed state in any corpus" \
	"uncheckpointed journal state" "$HELPER" query --base "$BASE" --query common
rm "$TEAM_ROOT/index/social.db-wal"

mv "$TEAM_ROOT/index/social.db" "$TEAM_ROOT/index/social.db.saved"
absent_result=$("$HELPER" query --base "$BASE" --query common)
assert_eq "a truly absent social store contributes no candidates" \
	"$(json_summary "$absent_result" common-citations)" "personal:default"
ln -s "social.db.saved" "$TEAM_ROOT/index/social.db"
expect_failure "symlinked social stores fail the federated query closed" \
	"cannot be a symlink" "$HELPER" query --base "$BASE" --query common
rm "$TEAM_ROOT/index/social.db"
mkdir "$TEAM_ROOT/index/social.db"
expect_failure "malformed social stores are not mistaken for absent stores" \
	"not a regular file" "$HELPER" query --base "$BASE" --query common
rmdir "$TEAM_ROOT/index/social.db"
mv "$TEAM_ROOT/index/social.db.saved" "$TEAM_ROOT/index/social.db"

operator_result=$("$HELPER" query --base "$BASE" --query 'federated OR personal')
assert_eq "FTS operators are treated as quoted search terms" \
	"$(json_summary "$operator_result" count)" "0"
expect_failure "query result limits are bounded" "limit must be between 1 and 100" \
	"$HELPER" query --base "$BASE" --query common --limit 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
