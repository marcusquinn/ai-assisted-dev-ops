#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Deterministic transport-level coverage for kie-helper.sh. No paid API calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../kie-helper.sh"
TEMP_ROOT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
SANDBOX=""
OUTPUT=""
ALL_OUTPUT=""
REAL_JQ=""
RC=0
SCENARIO="success"
TEST_KEY="test-only-kie-key"
AUTH_FILE=""
BODY_FILE=""
CLOCK_FILE=""
FORM_FILE=""
STATE_FILE=""
TIMEOUT_FILE=""
URL_FILE=""

cleanup() {
	if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then
		rm -rf "$SANDBOX"
	fi
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

reset_fixture() {
	: >"$AUTH_FILE"
	: >"$BODY_FILE"
	: >"$FORM_FILE"
	: >"$TIMEOUT_FILE"
	: >"$URL_FILE"
	printf '100\n' >"$CLOCK_FILE"
	printf '0\n' >"$STATE_FILE"
	return 0
}

run_helper() {
	RC=0
	OUTPUT=$(PATH="${SANDBOX}/bin:${PATH}" \
		KIE_API_KEY="$TEST_KEY" \
		KIE_API_BASE="https://api.kie.test" \
		KIE_UPLOAD_BASE="https://upload.kie.test" \
		KIE_TEST_SCENARIO="$SCENARIO" \
		KIE_TEST_AUTH_FILE="$AUTH_FILE" \
		KIE_TEST_BODY_FILE="$BODY_FILE" \
		KIE_TEST_CLOCK_FILE="$CLOCK_FILE" \
		KIE_TEST_FORM_FILE="$FORM_FILE" \
		KIE_TEST_REAL_JQ="$REAL_JQ" \
		KIE_TEST_STATE_FILE="$STATE_FILE" \
		KIE_TEST_TIMEOUT_FILE="$TIMEOUT_FILE" \
		KIE_TEST_URL_FILE="$URL_FILE" \
		bash "$HELPER" "$@" 2>&1) || RC=$?
	ALL_OUTPUT="${ALL_OUTPUT}${OUTPUT}"
	return 0
}

assert_success() {
	local description="$1"
	if [[ "$RC" -ne 0 ]]; then
		fail "${description} (exit ${RC}: ${OUTPUT})"
		return 1
	fi
	pass "$description"
	return 0
}

assert_failure() {
	local description="$1"
	if [[ "$RC" -eq 0 ]]; then
		fail "${description} (unexpected success: ${OUTPUT})"
		return 1
	fi
	pass "$description"
	return 0
}

assert_contains() {
	local description="$1"
	local expected="$2"
	if [[ "$OUTPUT" != *"$expected"* ]]; then
		fail "${description} (missing: ${expected}; output: ${OUTPUT})"
		return 1
	fi
	pass "$description"
	return 0
}

assert_body() {
	local description="$1"
	local filter="$2"
	if ! jq -e "$filter" "$BODY_FILE" >/dev/null 2>&1; then
		fail "${description} (body: $(<"$BODY_FILE"))"
		return 1
	fi
	pass "$description"
	return 0
}

mkdir -p "$TEMP_ROOT"
REAL_JQ=$(command -v jq)
SANDBOX=$(mktemp -d "${TEMP_ROOT%/}/kie-helper-test.XXXXXX")
mkdir -p "${SANDBOX}/bin"
AUTH_FILE="${SANDBOX}/auth-source.txt"
BODY_FILE="${SANDBOX}/body.json"
CLOCK_FILE="${SANDBOX}/clock.txt"
FORM_FILE="${SANDBOX}/forms.txt"
STATE_FILE="${SANDBOX}/state.txt"
TIMEOUT_FILE="${SANDBOX}/timeouts.txt"
URL_FILE="${SANDBOX}/url.txt"

cat >"${SANDBOX}/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${KIE_API_KEY:-}" ]]; then
	printf 'test authorization was forwarded through the child environment\n' >&2
	exit 90
fi

url=""
body=""
forms=""
auth_seen=0
auth_source=""
while [[ $# -gt 0 ]]; do
	argument="$1"
	if [[ "$argument" == *"test-only-kie-key"* ]]; then
		printf 'test authorization appeared in the curl argument vector\n' >&2
		exit 90
	fi
	shift
	case "$argument" in
	--request | -X)
		[[ $# -gt 0 ]] && shift
		;;
	--header | -H)
		header_argument="$1"
		shift
		value="$header_argument"
		if [[ "$header_argument" == "@-" ]]; then
			IFS= read -r value || true
			auth_source="stdin"
		elif [[ "$value" == *"test-only-kie-key"* ]]; then
			printf 'test authorization appeared in a curl header argument\n' >&2
			exit 90
		fi
		[[ "$value" == "Authorization: Bearer test-only-kie-key" ]] && auth_seen=1
		;;
	--connect-timeout)
		[[ $# -gt 0 ]] && shift
		;;
	--max-time)
		printf '%s\n' "$1" >>"$KIE_TEST_TIMEOUT_FILE"
		shift
		;;
	--data | -d)
		body="$1"
		shift
		;;
	--form | -F)
		forms="${forms}form:${1}"$'\n'
		shift
		;;
	--form-string)
		forms="${forms}form-string:${1}"$'\n'
		shift
		;;
	http://* | https://*) url="$argument" ;;
	esac
done

if [[ "$auth_seen" -ne 1 ]]; then
	printf '%s\n' '{"code":401,"msg":"missing test authorization"}'
	exit 0
fi
if [[ "$auth_source" != "stdin" ]]; then
	printf '%s\n' '{"code":401,"msg":"authorization did not use stdin"}'
	exit 0
fi
printf '%s\n' "$auth_source" >"$KIE_TEST_AUTH_FILE"
printf '%s' "$body" >"$KIE_TEST_BODY_FILE"
printf '%s' "$forms" >"$KIE_TEST_FORM_FILE"
printf '%s' "$url" >"$KIE_TEST_URL_FILE"

case "$url" in
*/api/v1/jobs/createTask)
	if [[ "$KIE_TEST_SCENARIO" == "api-error" ]]; then
		printf '%s\n' '{"code":402,"msg":"insufficient test credits","data":null}'
	else
		printf '%s\n' '{"code":200,"msg":"success","data":{"taskId":"task_kie_test"}}'
	fi
	;;
*/api/v1/jobs/recordInfo*)
	count=$(<"$KIE_TEST_STATE_FILE")
	count=$((count + 1))
	printf '%s\n' "$count" >"$KIE_TEST_STATE_FILE"
	if [[ "$KIE_TEST_SCENARIO" == "request-timeout" ]]; then
		clock=$(<"$KIE_TEST_CLOCK_FILE")
		printf '%s\n' "$((clock + 4))" >"$KIE_TEST_CLOCK_FILE"
	fi
	if [[ "$KIE_TEST_SCENARIO" == "task-fail" ]]; then
		printf '%s\n' '{"code":200,"msg":"success","data":{"taskId":"task_kie_test","state":"fail","failCode":"POLICY","failMsg":"blocked test content"}}'
	elif [[ "$KIE_TEST_SCENARIO" == "never" || "$KIE_TEST_SCENARIO" == "request-timeout" || ("$KIE_TEST_SCENARIO" == "transition" && "$count" -eq 1) ]]; then
		printf '%s\n' '{"code":200,"msg":"success","data":{"taskId":"task_kie_test","state":"generating","resultJson":""}}'
	else
		printf '%s\n' '{"code":200,"msg":"success","data":{"taskId":"task_kie_test","state":"success","resultJson":"{\"resultUrls\":[\"https://example.com/generated.png\"]}","creditsConsumed":12}}'
	fi
	;;
*/api/v1/chat/credit)
	printf '%s\n' '{"code":200,"msg":"success","data":321}'
	;;
*/api/file-stream-upload)
	if [[ "$KIE_TEST_SCENARIO" == "missing-upload-url" ]]; then
		printf '%s\n' '{"success":true,"code":200,"msg":"uploaded","data":{}}'
	else
		printf '%s\n' '{"success":true,"code":200,"msg":"uploaded","data":{"downloadUrl":"https://example.com/local-upload.png"}}'
	fi
	;;
*/api/file-url-upload)
	if [[ "$KIE_TEST_SCENARIO" == "missing-upload-url" ]]; then
		printf '%s\n' '{"success":true,"code":200,"msg":"uploaded","data":{}}'
	else
		printf '%s\n' '{"success":true,"code":200,"msg":"uploaded","data":{"downloadUrl":"https://example.com/url-upload.png"}}'
	fi
	;;
*)
	printf '%s\n' '{"code":404,"msg":"unexpected test URL"}'
	;;
esac
exit 0
EOF_CURL

cat >"${SANDBOX}/bin/jq" <<'EOF_JQ'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${KIE_API_KEY:-}" ]]; then
	printf 'test authorization was forwarded to jq through the child environment\n' >&2
	exit 90
fi
exec "$KIE_TEST_REAL_JQ" "$@"
EOF_JQ

cat >"${SANDBOX}/bin/date" <<'EOF_DATE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "+%s" ]]; then
	value=$(<"$KIE_TEST_CLOCK_FILE")
	printf '%s\n' "$value"
	exit 0
fi
exec /bin/date "$@"
EOF_DATE

cat >"${SANDBOX}/bin/sleep" <<'EOF_SLEEP'
#!/usr/bin/env bash
exit 0
EOF_SLEEP

chmod +x "${SANDBOX}/bin/curl" "${SANDBOX}/bin/date" "${SANDBOX}/bin/jq" "${SANDBOX}/bin/sleep"
printf 'fixture\n' >"${SANDBOX}/fixture.txt"
printf '%s\n' '{"prompt":"Input file prompt","resolution":"4K"}' >"${SANDBOX}/input.json"
reset_fixture

run_helper create --model "nano-banana-2" \
	--params '{"prompt":"Editorial product photo","aspect_ratio":"1:1"}' \
	--callback "https://example.com/callback"
assert_success "generic create succeeds"
assert_contains "generic create prints task ID" "task_kie_test"
assert_body "generic create preserves model-specific input" \
	'.model == "nano-banana-2" and .callBackUrl == "https://example.com/callback" and .input.aspect_ratio == "1:1"'
if [[ "$(<"$AUTH_FILE")" != "stdin" ]]; then
	fail "generic create did not keep authorization out of the child environment and argument vector"
	exit 1
fi
pass "API key reaches curl through stdin only"

reset_fixture
run_helper image --model "nano-banana-2" --prompt "Image prompt" --params '{"resolution":"2K"}'
assert_success "image convenience command succeeds"
assert_body "image command merges prompt with parameters" \
	'.model == "nano-banana-2" and .input.prompt == "Image prompt" and .input.resolution == "2K"'

reset_fixture
run_helper video --model "kling-3.0/video" --prompt "Video prompt" \
	--params '{"duration":"5","multi_shots":false}'
assert_success "video convenience command succeeds"
assert_body "video command preserves model-specific parameters" \
	'.model == "kling-3.0/video" and .input.prompt == "Video prompt" and .input.duration == "5" and .input.multi_shots == false'

reset_fixture
run_helper audio --model "elevenlabs/text-to-speech-turbo-2-5" --text "Audio text" \
	--params '{"voice":"Rachel"}'
assert_success "audio convenience command succeeds"
assert_body "audio command uses text field" \
	'.model == "elevenlabs/text-to-speech-turbo-2-5" and .input.text == "Audio text" and .input.voice == "Rachel"'

reset_fixture
SCENARIO="transition"
run_helper create --model "nano-banana-2" --input-file "${SANDBOX}/input.json" \
	--wait --interval 1 --timeout 5
assert_success "submit-and-wait handles generating-to-success transition"
assert_contains "submit-and-wait prints generated result URL" "https://example.com/generated.png"
if [[ "$(<"$STATE_FILE")" -ne 2 ]]; then
	fail "submit-and-wait did not poll exactly twice"
	exit 1
fi
pass "submit-and-wait uses bounded polling state machine"

reset_fixture
SCENARIO="success"
run_helper status "task_kie_test"
assert_success "status succeeds"
assert_contains "status prints task state" '"state": "success"'

reset_fixture
run_helper credits
assert_success "credits succeeds"
assert_contains "credits prints numeric balance" "321"

reset_fixture
run_helper upload "${SANDBOX}/fixture.txt" --path "aidevops/tests" --name "fixture.txt"
assert_success "local file upload succeeds"
assert_contains "local upload prints temporary URL" "https://example.com/local-upload.png"
if [[ "$(<"$FORM_FILE")" != *"form-string:uploadPath=aidevops/tests"* || "$(<"$FORM_FILE")" != *"form-string:fileName=fixture.txt"* ]]; then
	fail "local upload omitted multipart metadata"
	exit 1
fi
pass "local upload sends path and file name"

reset_fixture
printf 'must-not-be-read-as-form-data\n' >"${SANDBOX}/metadata.txt"
run_helper upload "${SANDBOX}/fixture.txt" --path "@${SANDBOX}/metadata.txt"
assert_success "local upload accepts literal at-prefixed metadata"
if [[ "$(<"$FORM_FILE")" != *"form-string:uploadPath=@${SANDBOX}/metadata.txt"* ]]; then
	fail "local upload did not force user-controlled metadata to a literal form string"
	exit 1
fi
pass "local upload cannot reinterpret metadata as a local file"

reset_fixture
run_helper upload-url "https://example.com/source.png" --path "aidevops/tests"
assert_success "URL upload succeeds"
assert_contains "URL upload prints temporary URL" "https://example.com/url-upload.png"
assert_body "URL upload sends structured JSON" \
	'.fileUrl == "https://example.com/source.png" and .uploadPath == "aidevops/tests"'

reset_fixture
SCENARIO="missing-upload-url"
run_helper upload "${SANDBOX}/fixture.txt"
assert_failure "upload rejects a success response without a download URL"
assert_contains "missing upload URL reports a useful error" "did not include a download URL"

reset_fixture
SCENARIO="task-fail"
run_helper wait "task_kie_test" --interval 1 --timeout 5
assert_failure "terminal task failure returns non-zero"
assert_contains "terminal task failure reports provider detail" "blocked test content"

reset_fixture
SCENARIO="never"
run_helper wait "task_kie_test" --interval 1 --timeout 1
assert_failure "wait timeout returns non-zero"
assert_contains "wait timeout preserves recovery context" "Check later with: kie-helper.sh status task_kie_test"

reset_fixture
SCENARIO="request-timeout"
run_helper wait "task_kie_test" --interval 1 --timeout 3
assert_failure "wait timeout includes status request duration"
assert_contains "request-duration timeout preserves recovery context" "Timed out after 3s"
if [[ "$(<"$STATE_FILE")" -ne 1 ]]; then
	fail "wait started another status request after its wall-clock deadline"
	exit 1
fi
if [[ "$(<"$TIMEOUT_FILE")" != "3" ]]; then
	fail "wait did not cap the status request to the remaining deadline"
	exit 1
fi
pass "wait caps requests and stops at the wall-clock deadline"

reset_fixture
SCENARIO="api-error"
run_helper create --model "nano-banana-2" --params '{"prompt":"test"}'
assert_failure "API-level failure returns non-zero"
assert_contains "API-level failure reports response code" "Kie.ai API error (402)"

reset_fixture
SCENARIO="success"
run_helper create --model "nano-banana-2" --params '[]'
assert_failure "non-object input is rejected"
assert_contains "invalid input reports a useful error" "valid JSON object"
if [[ -s "$URL_FILE" ]]; then
	fail "invalid input reached the API transport"
	exit 1
fi
pass "invalid input fails before transport"

if [[ "$ALL_OUTPUT" == *"$TEST_KEY"* ]]; then
	fail "test API key leaked into command output"
	exit 1
fi
pass "API key stays out of command output"

printf 'All Kie.ai helper tests passed.\n'
exit 0
