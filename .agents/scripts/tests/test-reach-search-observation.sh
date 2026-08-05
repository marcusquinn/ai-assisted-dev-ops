#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-search-observation.sh - Search observation contract tests.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../reach-helper.sh"
PASS=0
FAIL=0
TEST_WORKSPACE=""

cleanup() {
	if [[ -n "$TEST_WORKSPACE" && -d "$TEST_WORKSPACE" ]]; then
		rm -rf "$TEST_WORKSPACE"
	fi
	return 0
}
trap cleanup EXIT

assert_contains() {
	local output="$1"
	local expected="$2"
	local description="$3"
	if grep -Fq -- "$expected" <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Expected output to contain: %s\n' "$expected"
		printf '    Output: %s\n' "$output"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local description="$3"
	if grep -Fq -- "$unexpected" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Unexpected output: %s\n' "$unexpected"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_json_valid() {
	local output="$1"
	local description="$2"
	if python3 -m json.tool >/dev/null 2>&1 <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Invalid JSON: %s\n' "$output"
	fi
	return 0
}

assert_command_fails() {
	local description="$1"
	shift
	local output=""
	if output="$(run_helper "$@" 2>&1)"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Output: %s\n' "$output"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_command_fails_without() {
	local description="$1"
	local forbidden="$2"
	shift 2
	local output=""
	if output="$(run_helper "$@" 2>&1)"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (command succeeded)\n' "$description"
	elif grep -Fq -- "$forbidden" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (forbidden value was printed)\n' "$description"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_private_mode() {
	local file_path="$1"
	local description="$2"
	local mode=""
	mode="$(python3 - "$file_path" <<'PY'
import os
import stat
import sys

print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
	if [[ "$mode" == "0o600" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (mode %s)\n' "$description" "$mode"
	fi
	return 0
}

run_helper() {
	if AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" "$@"; then
		return 0
	fi
	return 1
}

write_observation_input() {
	local output_file="$1"
	local egress_profile="$2"
	local engine="$3"
	local method="$4"
	local signed_in="$5"
	local authorization_basis="$6"
	local evidence_class="${7:-search_result_observation}"
	local extra_field="${8:-false}"
	local query_text="${9:-private sample query}"
	local evidence_media_type="${10:-text/html}"
	local observed_at="${11:-}"
	local storage_authorization_basis="${12:-}"
	OUTPUT_FILE="$output_file" \
		EVIDENCE_FILE="$EVIDENCE_FILE" \
		EGRESS_PROFILE="$egress_profile" \
		ENGINE="$engine" \
		METHOD="$method" \
		SIGNED_IN="$signed_in" \
		AUTHORIZATION_BASIS="$authorization_basis" \
		EVIDENCE_CLASS="$evidence_class" \
		EXTRA_FIELD="$extra_field" \
		QUERY_TEXT="$query_text" \
		EVIDENCE_MEDIA_TYPE="$evidence_media_type" \
		OBSERVED_AT="$observed_at" \
		STORAGE_AUTHORIZATION_BASIS="$storage_authorization_basis" \
		python3 - <<'PY'
import datetime
import json
import os

observed_at = os.environ["OBSERVED_AT"] or datetime.datetime.now(
    datetime.timezone.utc
).replace(microsecond=0).isoformat().replace("+00:00", "Z")
payload = {
    "schema_version": 1,
    "evidence_class": os.environ["EVIDENCE_CLASS"],
    "engine": os.environ["ENGINE"],
    "collection_method": os.environ["METHOD"],
    "query": os.environ["QUERY_TEXT"],
    "observed_at": observed_at,
    "egress_profile": os.environ["EGRESS_PROFILE"],
    "device_class": "desktop",
    "signed_in": os.environ["SIGNED_IN"] == "true",
    "authorization_basis": os.environ["AUTHORIZATION_BASIS"],
    "result_surface": "web",
    "evidence_path": os.environ["EVIDENCE_FILE"],
    "evidence_media_type": os.environ["EVIDENCE_MEDIA_TYPE"],
}
if os.environ["EXTRA_FIELD"] == "true":
    payload["unexpected"] = "blocked"
if os.environ["STORAGE_AUTHORIZATION_BASIS"]:
    payload["storage_authorization_basis"] = os.environ["STORAGE_AUTHORIZATION_BASIS"]
with open(os.environ["OUTPUT_FILE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
    handle.write("\n")
os.chmod(os.environ["OUTPUT_FILE"], 0o600)
PY
	return $?
}

printf '=== Reach Search Observation Tests ===\n\n'

test_temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$test_temp_root"
TEST_WORKSPACE="$(mktemp -d "${test_temp_root}/reach-observation-test.XXXXXX")"
EVIDENCE_FILE="${TEST_WORKSPACE}/private-evidence.html"
printf '<html><body>sample search evidence</body></html>\n' >"$EVIDENCE_FILE"
chmod 600 "$EVIDENCE_FILE"

run_helper egress register --name public-us --browser brave --class direct \
	--scope public --session-mode stable --country US --timezone America/New_York \
	--locale en-US --format json >/dev/null
run_helper egress register --name account-us --browser brave --class direct \
	--scope account --session-mode stable --country US --timezone America/New_York \
	--locale en-US --format json >/dev/null
run_helper egress register --name rotating-mobile --browser brave --class mobile \
	--scope public --session-mode rotating --country US --timezone America/New_York \
	--locale en-US --credential-ref REACH_MOBILE_TEST --format json >/dev/null

INPUT_FILE="${TEST_WORKSPACE}/observation.json"
write_observation_input "$INPUT_FILE" public-us brave browser false public_data
record_output="$(run_helper observation record --input "$INPUT_FILE" --format json)"
assert_json_valid "$record_output" "observation record emits valid JSON"
assert_contains "$record_output" '"record_status": "recorded"' "observation is recorded"
assert_contains "$record_output" '"evidence_class": "search_result_observation"' "search-result observation class is explicit"
assert_contains "$record_output" '"engine": "brave"' "Brave engine is recorded"
assert_contains "$record_output" '"browser_class": "brave"' "Brave browser context is derived"
assert_contains "$record_output" '"egress_claim_status": "configured_unverified"' "location claim remains unverified"
assert_contains "$record_output" '"query_printed": false' "output declares query redaction"
assert_not_contains "$record_output" "private sample query" "query is omitted from output"
assert_not_contains "$record_output" "$TEST_WORKSPACE" "private paths are omitted from output"
private_path_canary="${TEST_WORKSPACE}/transcript-private-input.json"
assert_command_fails_without "unknown observation options redact attached paths" \
	"$private_path_canary" observation record "--input=$private_path_canary"

observation_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["observation_id"])' <<<"$record_output")"
record_file="${TEST_WORKSPACE}/observations/records/${observation_id}.json"
assert_private_mode "$record_file" "observation record uses mode 600"
assert_private_mode "${TEST_WORKSPACE}/.observation-id-key" "observation ID key uses mode 600"
record_text="$(<"$record_file")"
assert_contains "$record_text" '"query": "private sample query"' "private record preserves the query"
assert_not_contains "$record_text" "$EVIDENCE_FILE" "record omits original evidence path"
legacy_observation_id="$(python3 - "$record_file" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    record = json.load(handle)
record.pop("observation_id")
record.pop("recorded_at")
payload = json.dumps(
    record, ensure_ascii=False, sort_keys=True, separators=(",", ":")
).encode("utf-8")
print("obs-" + hashlib.sha256(payload).hexdigest()[:24])
PY
)"
assert_not_contains "$record_output" "$legacy_observation_id" "observation ID is not an unkeyed query digest"
evidence_ref="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["evidence"]["storage_ref"])' "$record_file")"
assert_private_mode "${TEST_WORKSPACE}/observations/${evidence_ref}" "copied evidence uses mode 600"

repeat_output="$(run_helper observation record --input "$INPUT_FILE" --format json)"
assert_contains "$repeat_output" '"record_status": "existing"' "replay is idempotent"

CONCURRENT_INPUT="${TEST_WORKSPACE}/concurrent-observation.json"
write_observation_input "$CONCURRENT_INPUT" public-us brave browser false \
	public_data search_result_observation false "concurrent sample query"
concurrent_output_one="${TEST_WORKSPACE}/concurrent-one.json"
concurrent_output_two="${TEST_WORKSPACE}/concurrent-two.json"
AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" observation record \
	--input "$CONCURRENT_INPUT" --format json >"$concurrent_output_one" &
concurrent_pid_one=$!
AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" observation record \
	--input "$CONCURRENT_INPUT" --format json >"$concurrent_output_two" &
concurrent_pid_two=$!
wait "$concurrent_pid_one"
wait "$concurrent_pid_two"
concurrent_output="$(<"$concurrent_output_one")$(<"$concurrent_output_two")"
assert_contains "$concurrent_output" '"record_status": "recorded"' "parallel replay records one immutable observation"
assert_contains "$concurrent_output" '"record_status": "existing"' "parallel replay reuses the immutable observation"

SIGNED_INPUT="${TEST_WORKSPACE}/signed-observation.json"
write_observation_input "$SIGNED_INPUT" account-us google browser true owned_account
signed_output="$(run_helper observation record --input "$SIGNED_INPUT" --format json)"
assert_contains "$signed_output" '"signed_in": true' "owned signed-in browser observation is accepted"

INVALID_INPUT="${TEST_WORKSPACE}/invalid-observation.json"
write_observation_input "$INVALID_INPUT" rotating-mobile google browser true owned_account
assert_command_fails "signed-in observation rejects rotating public egress" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" account-us google browser true public_data
assert_command_fails "signed-in observation requires account authorization" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" public-us google search_api false public_data
assert_command_fails "search API observations currently reject Google" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" public-us brave search_api false public_data
assert_command_fails "Brave API persistence requires an explicit storage basis" \
	observation record --input "$INVALID_INPUT" --format json
API_INPUT="${TEST_WORKSPACE}/brave-api-observation.json"
write_observation_input "$API_INPUT" public-us brave search_api false public_data \
	search_result_observation false "private API query" text/html "" personal_use
api_output="$(run_helper observation record --input "$API_INPUT" --format json)"
assert_contains "$api_output" '"record_status": "recorded"' "personal-use Brave API evidence is accepted"
assert_contains "$api_output" '"storage_authorization_basis": "personal_use"' "API output records the storage basis"
write_observation_input "$INVALID_INPUT" account-us brave search_api true owned_account
assert_command_fails "search API observations reject signed-in sessions" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" public-us brave browser false public_data \
	search_result_observation false "private browser query" text/html "" personal_use
assert_command_fails "browser observations reject an API storage basis" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" public-us brave search_api false public_data \
	search_result_observation false "private API query" text/html "" unsupported_basis
assert_command_fails "unsupported API storage bases fail closed" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" public-us brave browser false public_data llm_derived_answer
assert_command_fails "LLM-derived answers cannot masquerade as search observations" \
	observation record --input "$INVALID_INPUT" --format json
write_observation_input "$INVALID_INPUT" public-us brave browser false public_data search_result_observation true
assert_command_fails "unknown observation fields fail closed" \
	observation record --input "$INVALID_INPUT" --format json

PRIVATE_INPUT="${TEST_WORKSPACE}/world-readable-input.json"
write_observation_input "$PRIVATE_INPUT" public-us brave browser false public_data
chmod 644 "$PRIVATE_INPUT"
assert_command_fails "world-readable observation input fails closed" \
	observation record --input "$PRIVATE_INPUT" --format json

write_observation_input "$INVALID_INPUT" public-us brave browser false public_data
chmod 644 "$EVIDENCE_FILE"
assert_command_fails "world-readable evidence fails closed" \
	observation record --input "$INVALID_INPUT" --format json
chmod 600 "$EVIDENCE_FILE"

ORIGINAL_EVIDENCE_FILE="$EVIDENCE_FILE"
SYMLINK_EVIDENCE="${TEST_WORKSPACE}/symlink-evidence.html"
ln -s "$ORIGINAL_EVIDENCE_FILE" "$SYMLINK_EVIDENCE"
EVIDENCE_FILE="$SYMLINK_EVIDENCE"
write_observation_input "$INVALID_INPUT" public-us brave browser false public_data
assert_command_fails "symlinked evidence fails closed" \
	observation record --input "$INVALID_INPUT" --format json

JSON_EVIDENCE="${TEST_WORKSPACE}/credential-shaped-evidence.json"
credential_keys=(api_key apiKey accessToken clientSecret refreshToken secretAccessKey x-api-key)
for credential_key in "${credential_keys[@]}"; do
	python3 - "$JSON_EVIDENCE" "$credential_key" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"nested": {sys.argv[2]: "placeholder-only"}}, handle)
    handle.write("\n")
os.chmod(sys.argv[1], 0o600)
PY
	EVIDENCE_FILE="$JSON_EVIDENCE"
	write_observation_input "$INVALID_INPUT" public-us brave browser false public_data \
		search_result_observation false "private JSON query" application/json
	assert_command_fails "credential-shaped JSON key ${credential_key} fails closed" \
		observation record --input "$INVALID_INPUT" --format json
done

SWAP_EVIDENCE="${TEST_WORKSPACE}/swap-evidence.html"
printf '<html><body>validated evidence</body></html>\n' >"$SWAP_EVIDENCE"
chmod 600 "$SWAP_EVIDENCE"
EVIDENCE_FILE="$SWAP_EVIDENCE"
SWAP_INPUT="${TEST_WORKSPACE}/swap-observation.json"
write_observation_input "$SWAP_INPUT" public-us brave browser false public_data \
	search_result_observation false "private swap query"
if python3 - "${SCRIPT_DIR}/../reach-search-observation.py" "$SWAP_INPUT" \
	"$TEST_WORKSPACE" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

script_path = Path(sys.argv[1])
sys.path.insert(0, str(script_path.parent))
spec = importlib.util.spec_from_file_location("reach_search_observation", script_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original_read = module._read_private_file

def swap_after_read(path, label, maximum, directory_fd=None):
    payload = original_read(path, label, maximum, directory_fd)
    if label == "evidence file":
        replacement = path.with_name("replacement-secret.html")
        replacement.write_bytes(b"must-not-persist\n")
        os.chmod(replacement, 0o600)
        os.replace(replacement, path)
    return payload

module._read_private_file = swap_after_read
result = module._record(Path(sys.argv[2]), Path(sys.argv[3]))
stored = Path(sys.argv[3]) / "observations" / "evidence" / (
    result["evidence_sha256"] + ".html"
)
if stored.read_bytes() != b"<html><body>validated evidence</body></html>\n":
    raise SystemExit(1)
PY
then
	PASS=$((PASS + 1))
	printf '  PASS: evidence path replacement cannot change persisted bytes\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: evidence path replacement changed persisted bytes\n'
fi

PIN_WORKSPACE="${TEST_WORKSPACE}/pin-workspace"
AIDEVOPS_REACH_WORKSPACE="$PIN_WORKSPACE" "$HELPER" egress register \
	--name pinned-public --browser brave --class direct --scope public \
	--session-mode stable --country US --timezone America/New_York \
	--locale en-US --format json >/dev/null
PIN_EVIDENCE="${TEST_WORKSPACE}/pin-evidence.html"
printf '<html><body>pinned directory evidence</body></html>\n' >"$PIN_EVIDENCE"
chmod 600 "$PIN_EVIDENCE"
EVIDENCE_FILE="$PIN_EVIDENCE"
PIN_INPUT="${TEST_WORKSPACE}/pin-observation.json"
write_observation_input "$PIN_INPUT" pinned-public brave browser false public_data \
	search_result_observation false "private pinned query"
PIN_EXTERNAL="${TEST_WORKSPACE}/pin-external"
mkdir -m 700 "$PIN_EXTERNAL"
printf 'sentinel\n' >"${PIN_EXTERNAL}/sentinel.txt"
chmod 600 "${PIN_EXTERNAL}/sentinel.txt"
if python3 - "${SCRIPT_DIR}/../reach-search-observation.py" "$PIN_INPUT" \
	"$PIN_WORKSPACE" "$PIN_EXTERNAL" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

script_path = Path(sys.argv[1])
sys.path.insert(0, str(script_path.parent))
spec = importlib.util.spec_from_file_location("reach_search_observation", script_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
workspace = Path(sys.argv[3])
pinned = workspace.with_name("pin-workspace-pinned")
external = Path(sys.argv[4])
original_load = module._load_egress

def replace_workspace_after_open(workspace_fd, profile_name):
    os.rename(workspace, pinned)
    os.symlink(external, workspace)
    return original_load(workspace_fd, profile_name)

module._load_egress = replace_workspace_after_open
result = module._record(Path(sys.argv[2]), workspace)
if sorted(path.name for path in external.iterdir()) != ["sentinel.txt"]:
    raise SystemExit(1)
if not (pinned / "observations" / "records" / (result["observation_id"] + ".json")).is_file():
    raise SystemExit(1)
PY
then
	PASS=$((PASS + 1))
	printf '  PASS: pinned workspace descriptors prevent redirected persistence\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: workspace replacement redirected private persistence\n'
fi

OVERSIZED_EVIDENCE="${TEST_WORKSPACE}/oversized-evidence.txt"
python3 - "$OVERSIZED_EVIDENCE" <<'PY'
import os
import sys

with open(sys.argv[1], "wb") as handle:
    handle.seek(25 * 1024 * 1024)
    handle.write(b"x")
os.chmod(sys.argv[1], 0o600)
PY
EVIDENCE_FILE="$OVERSIZED_EVIDENCE"
write_observation_input "$INVALID_INPUT" public-us brave browser false public_data \
	search_result_observation false "private oversized query" text/plain
assert_command_fails "oversized evidence fails closed" \
	observation record --input "$INVALID_INPUT" --format json

EVIDENCE_FILE="$ORIGINAL_EVIDENCE_FILE"
write_observation_input "$INVALID_INPUT" public-us brave browser false public_data \
	search_result_observation false "private future query" text/html "2999-01-01T00:00:00Z"
assert_command_fails "future observation timestamps fail closed" \
	observation record --input "$INVALID_INPUT" --format json

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
