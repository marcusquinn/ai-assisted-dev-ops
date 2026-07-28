#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
POSTFLIGHT_SCRIPT="${REPO_ROOT}/.agents/scripts/postflight-check.sh"
STUB_DIR=$(mktemp -d)

cleanup() {
	rm -rf "$STUB_DIR"
	return 0
}
trap cleanup EXIT

cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	if [[ "${GH_AUTH_STUB_RESULT:-authenticated}" == "failure" ]]; then
		exit 1
	fi
	exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
	if [[ "$*" == *"--limit=1"* || "$*" == *"--limit 1"* ]]; then
		printf '[{"databaseId":1,"status":"completed","conclusion":"%s","name":"Stub CI"}]\n' "${CI_STUB_CONCLUSION:-success}"
	else
		printf '[{"name":"Stub CI","status":"completed","conclusion":"%s"}]\n' "${CI_STUB_CONCLUSION:-success}"
	fi
	exit 0
fi
if [[ "${1:-}" == "api" && "$*" == *"/check-runs?per_page=100"* ]]; then
	printf '[{"check_runs":[{"id":1,"name":"Stub CI","status":"completed","conclusion":"%s","check_suite":{"id":1},"app":{"slug":"github-actions"}}]}]\n' "${CI_STUB_CONCLUSION:-success}"
	exit 0
fi
if [[ "${1:-}" == "api" && "$*" == *"/actions/runs?head_sha="* ]]; then
	request="$*"
	release_sha="${request#*head_sha=}"
	release_sha="${release_sha%%&*}"
	printf '{"workflow_runs":[{"id":1,"name":"Stub CI","event":"push","head_sha":"%s","check_suite_id":1}]}\n' "$release_sha"
	exit 0
fi
exit 1
EOF

cat >"${STUB_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
*qualitygates/project_status*)
	if [[ "${SONAR_STUB_STATUS:-}" == "UNAVAILABLE" ]]; then
		exit 1
	fi
	printf '{"projectStatus":{"status":"%s","conditions":[{"status":"%s","metricKey":"new_security_rating","actualValue":"4","errorThreshold":"1"}]}}\n' \
		"${SONAR_STUB_STATUS:-UNKNOWN}" "${SONAR_STUB_STATUS:-UNKNOWN}"
	;;
*measures/component*)
	printf '%s\n' '{"component":{"measures":[]}}'
	;;
*issues/search*)
	printf '%s\n' '{"total":0,"issues":[]}'
	;;
*) exit 1 ;;
esac
EOF

cat >"${STUB_DIR}/snyk" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "check" ]]; then
	exit 0
fi
if [[ "${1:-}" == "test" ]]; then
	if [[ "${SNYK_STUB_RESULT:-clean}" == "vulnerable" ]]; then
		printf '%s\n' '{"vulnerabilities":[{"severity":"high","title":"Stub vulnerability","packageName":"stub-package"}]}'
		exit 1
	fi
	printf '%s\n' '{"vulnerabilities":[]}'
	exit 0
fi
exit 1
EOF

cat >"${STUB_DIR}/secretlint" <<'EOF'
#!/usr/bin/env bash
if [[ "${SECRETLINT_STUB_RESULT:-clean}" == "detected" ]]; then
	exit 1
fi
exit 0
EOF

chmod +x "${STUB_DIR}/gh" "${STUB_DIR}/curl" "${STUB_DIR}/snyk" "${STUB_DIR}/secretlint"

run_case() {
	local mode="$1"
	local status="$2"
	local expected_exit="$3"
	local expected_text="$4"
	local forbidden_text="$5"
	local output
	local plain_output
	local actual_exit=0

	output=$(PATH="${STUB_DIR}:$PATH" SONAR_STUB_STATUS="$status" bash "$POSTFLIGHT_SCRIPT" "$mode" 2>&1) || actual_exit=$?
	plain_output=$(printf '%s' "$output" | sed $'s/\033\[[0-9;]*m//g')

	if [[ "$actual_exit" -ne "$expected_exit" ]]; then
		printf 'FAIL: status %s exited %s, expected %s\n%s\n' "$status" "$actual_exit" "$expected_exit" "$output" >&2
		return 1
	fi
	if [[ "$plain_output" != *"$expected_text"* ]]; then
		printf 'FAIL: status %s missing expected output %s\n%s\n' "$status" "$expected_text" "$output" >&2
		return 1
	fi
	if [[ -n "$forbidden_text" && "$plain_output" == *"$forbidden_text"* ]]; then
		printf 'FAIL: status %s contained forbidden output %s\n%s\n' "$status" "$forbidden_text" "$output" >&2
		return 1
	fi
	return 0
}

run_case "--quick" "ERROR" 1 "Failed:   1" "POSTFLIGHT VERIFICATION PASSED"
run_case "--quick" "OK" 0 "POSTFLIGHT VERIFICATION PASSED" "POSTFLIGHT VERIFICATION FAILED"
run_case "--quick" "WARN" 0 "POSTFLIGHT VERIFICATION PASSED WITH WARNINGS" "POSTFLIGHT VERIFICATION FAILED"
run_case "--quick" "UNKNOWN" 0 "SonarCloud quality gate status: UNKNOWN" "POSTFLIGHT VERIFICATION FAILED"
run_case "--quick" "UNAVAILABLE" 0 "SKIPPED Could not reach SonarCloud API" "POSTFLIGHT VERIFICATION FAILED"

(
	export CI_STUB_CONCLUSION="failure"
	run_case "--ci-only" "OK" 1 "Stub CI: failure" "POSTFLIGHT VERIFICATION PASSED"
)
(
	export GH_AUTH_STUB_RESULT="failure"
	run_case "--ci-only" "OK" 1 "Failed:   1" "POSTFLIGHT VERIFICATION PASSED"
)
(
	export SNYK_STUB_RESULT="vulnerable"
	run_case "--security-only" "OK" 1 "Snyk: 1 vulnerabilities found" "POSTFLIGHT VERIFICATION PASSED"
)
(
	export SECRETLINT_STUB_RESULT="detected"
	run_case "--security-only" "OK" 1 "Secretlint: Potential secrets found" "POSTFLIGHT VERIFICATION PASSED"
)

printf 'PASS: postflight propagates critical check results\n'
