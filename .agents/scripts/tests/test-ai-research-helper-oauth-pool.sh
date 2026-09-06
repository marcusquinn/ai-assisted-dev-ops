#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23594:
# - ai-research-helper.sh keeps OAuth pool credential resolution available for
#   explicit Anthropic calls while the default auto provider prefers OpenCode.
# - pulse-fix-the-fixer-detector.sh treats ai-research-helper rc=2 as an auth
#   class signal even when stderr prose does not match API error substrings.

set -euo pipefail

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

record_result() {
	local name="$1"
	local failed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export TEST_ROOT
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${TEST_ROOT}/bin"
	unset ANTHROPIC_API_KEY || true
	printf '#!/usr/bin/env bash\nexit 1\n' >"${TEST_ROOT}/bin/gopass"
	chmod +x "${TEST_ROOT}/bin/gopass"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	return 0
}

write_curl_capture_stub() {
	cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
: >"${TEST_ROOT}/curl.args"
for arg in "$@"; do
	printf '%s\n' "$arg" >>"${TEST_ROOT}/curl.args"
done
printf '{"content":[{"text":"OK"}]}\n'
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/curl"
	return 0
}

teardown_sandbox() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

write_pool() {
	local provider="anthropic"
	local token="$1"
	local expires_ms="$2"
	local status="${3:-active}"
	local cooldown="${4:-null}"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	cat >"$pool_file" <<EOF
{
  "${provider}": [
    {
      "email": "test@example.com",
      "access": "${token}",
      "refresh": "rt_test",
      "expires": ${expires_ms},
      "status": "${status}",
      "cooldownUntil": ${cooldown}
    }
  ]
}
EOF
	chmod 600 "$pool_file"
	return 0
}

probe_resolver() {
	local env_token="${1:-}"
	(
		set +e
		[[ -n "$env_token" ]] && export ANTHROPIC_API_KEY="$env_token"
		# shellcheck source=/dev/null
		source "${REPO_ROOT}/.agents/scripts/ai-research-helper.sh" 2>/dev/null
		local actual=""
		actual=$(resolve_api_key 2>/dev/null)
		local rc=$?
		printf 'rc=%s\ntoken=%s\n' "$rc" "$actual"
	) >"${TEST_ROOT}/probe.out" 2>/dev/null || true
	return 0
}

probe_value() {
	local key="$1"
	grep "^${key}=" "${TEST_ROOT}/probe.out" 2>/dev/null | head -1 | cut -d= -f2- || true
	return 0
}

assert_probe() {
	local name="$1"
	local expected_rc="$2"
	local expected_token="$3"
	local actual_rc actual_token
	actual_rc=$(probe_value rc)
	actual_token=$(probe_value token)
	if [[ "$actual_rc" == "$expected_rc" && "$actual_token" == "$expected_token" ]]; then
		record_result "$name" 0
		return 0
	fi
	record_result "$name" 1 "rc=${actual_rc} token=${actual_token}"
	return 0
}

test_oauth_pool_fallbacks() {
	local pool_token="[redacted-pool-token]"
	local env_token="[redacted-env-token]"
	local future_ms=$((($(date +%s) + 3600) * 1000))

	write_pool "$pool_token" "$future_ms"
	probe_resolver
	assert_probe "OAuth pool token is returned when static sources miss" 0 "$pool_token"

	write_pool "$pool_token" 1
	probe_resolver
	assert_probe "expired OAuth pool entries are skipped" 1 ""

	write_pool "$pool_token" "$future_ms"
	probe_resolver "$env_token"
	assert_probe "env var wins over OAuth pool" 0 "$env_token"

	return 0
}

probe_anthropic_request() {
	local kind="$1"
	local credential="$2"
	local future_ms=$((($(date +%s) + 3600) * 1000))
	local rc=0
	write_curl_capture_stub
	if [[ "$kind" == "oauth-pool" ]]; then
		unset ANTHROPIC_API_KEY || true
		write_pool "$credential" "$future_ms"
	else
		export ANTHROPIC_API_KEY="$credential"
		rm -f "${HOME}/.aidevops/oauth-pool.json"
	fi
	set +e
	(
		# shellcheck source=/dev/null
		source "${REPO_ROOT}/.agents/scripts/ai-research-helper.sh"
		call_anthropic "ping" simple 5
	) >"${TEST_ROOT}/anthropic-call.out" 2>"${TEST_ROOT}/anthropic-call.err"
	rc=$?
	set -e
	unset ANTHROPIC_API_KEY || true
	printf '%s\n' "$rc" >"${TEST_ROOT}/anthropic-call.rc"
	return 0
}

test_anthropic_credential_header_shapes() {
	local pool_token="[redacted-pool-token]"
	local api_key="[redacted-api-key]"
	local rc=""

	probe_anthropic_request oauth-pool "$pool_token"
	rc=$(<"${TEST_ROOT}/anthropic-call.rc")
	if [[ "$rc" == "0" ]] &&
		grep -Fxq "Authorization: Bearer ${pool_token}" "${TEST_ROOT}/curl.args" &&
		grep -Fxq 'anthropic-beta: oauth-2025-04-20' "${TEST_ROOT}/curl.args" &&
		! grep -Fq 'x-api-key:' "${TEST_ROOT}/curl.args"; then
		record_result "OAuth pool credential uses Bearer and OAuth beta headers only" 0
	else
		record_result "OAuth pool credential uses Bearer and OAuth beta headers only" 1 "rc=${rc}"
	fi
	if ! grep -Fq "$pool_token" "${TEST_ROOT}/anthropic-call.out" "${TEST_ROOT}/anthropic-call.err"; then
		record_result "OAuth pool credential is absent from helper output and diagnostics" 0
	else
		record_result "OAuth pool credential is absent from helper output and diagnostics" 1
	fi

	probe_anthropic_request api-key "$api_key"
	rc=$(<"${TEST_ROOT}/anthropic-call.rc")
	if [[ "$rc" == "0" ]] &&
		grep -Fxq "x-api-key: ${api_key}" "${TEST_ROOT}/curl.args" &&
		! grep -Fq 'Authorization: Bearer' "${TEST_ROOT}/curl.args" &&
		! grep -Fq 'anthropic-beta: oauth-2025-04-20' "${TEST_ROOT}/curl.args"; then
		record_result "static API key keeps x-api-key authentication only" 0
	else
		record_result "static API key keeps x-api-key authentication only" 1 "rc=${rc}"
	fi
	if ! grep -Fq "$api_key" "${TEST_ROOT}/anthropic-call.out" "${TEST_ROOT}/anthropic-call.err"; then
		record_result "static API key is absent from helper output and diagnostics" 0
	else
		record_result "static API key is absent from helper output and diagnostics" 1
	fi
	return 0
}

test_auto_provider_prefers_opencode() {
	rm -f "${HOME}/.aidevops/oauth-pool.json"
	cat >"${TEST_ROOT}/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${AIDEVOPS_HEADLESS:-}" != "1" ]]; then
	printf 'missing AIDEVOPS_HEADLESS=1\n' >&2
	exit 43
fi
for arg in "$@"; do
	if [[ "$arg" == "--pure" ]]; then
		printf 'unexpected --pure flag\n' >&2
		exit 44
	fi
done
printf '%s\n' '> Build+ · gpt-5.4-mini'
printf '%s\n' 'VERDICT: YES - opencode primary works'
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/opencode"
	cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected direct Anthropic call in auto provider\n' >&2
exit 42
STUB
	chmod +x "${TEST_ROOT}/bin/curl"
	trap 'rm -f "${TEST_ROOT}/bin/curl"' RETURN

	local output rc
	set +e
	export ANTHROPIC_API_KEY="[redacted-env-token]"
	output=$("${REPO_ROOT}/.agents/scripts/ai-research-helper.sh" --prompt "ping" --max-tokens 5 2>"${TEST_ROOT}/auto-provider.err")
	rc=$?
	unset ANTHROPIC_API_KEY
	set -e
	if [[ "$rc" -eq 0 && "$output" == "VERDICT: YES - opencode primary works" ]]; then
		record_result "auto provider uses OpenCode headless without pure mode" 0
		return 0
	fi
	record_result "auto provider uses OpenCode headless without pure mode" 1 \
		"rc=${rc} output=${output} err=$(tr '\n' ' ' <"${TEST_ROOT}/auto-provider.err")"
	return 0
}

test_opencode_tier_models() {
	local standard_model=""
	local standard_variant=""
	local thinking_model=""
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/.agents/scripts/ai-research-helper.sh"
	standard_model=$(resolve_opencode_model_id standard)
	standard_variant=$(resolve_opencode_variant standard)
	thinking_model=$(resolve_opencode_model_id thinking)
	if [[ "$standard_model" == "openai/gpt-5.6-terra" && "$standard_variant" == "low" && "$thinking_model" == "openai/gpt-5.6-sol" ]] &&
		[[ "$(resolve_opencode_variant thinking)" == "medium" ]] &&
		[[ -z "$(resolve_opencode_variant thinking openai/unmapped-model)" ]]; then
		record_result "OpenCode research tiers follow canonical model and effort defaults" 0
		return 0
	fi
	record_result "OpenCode research tiers follow canonical model and effort defaults" 1 \
		"standard=${standard_model:-<empty>} variant=${standard_variant:-<empty>} thinking=${thinking_model:-<empty>}"
	return 0
}

write_detector_stubs() {
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"issue list") printf '[{"number":1,"labels":[{"name":"auto-dispatch"}]}]\n' ;;
"issue view") printf '{"title":"fix dispatch path","body":"Touches pulse-wrapper.sh dispatch behaviour.","labels":[{"name":"auto-dispatch"}],"state":"OPEN"}\n' ;;
*) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
	chmod +x "${TEST_ROOT}/bin/gh"

	mkdir -p "${TEST_ROOT}/helper-shim"
	cat >"${TEST_ROOT}/helper-shim/ai-research-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '[AI-RESEARCH] No Anthropic API key found (env, gopass, credentials.sh, or OAuth pool)\n' >&2
exit 2
STUB
	chmod +x "${TEST_ROOT}/helper-shim/ai-research-helper.sh"
	return 0
}

test_detector_rc2_records_cooldown() {
	write_detector_stubs
	(
		set +e
		export PULSE_AI_RESEARCH_HELPER_OVERRIDE="${TEST_ROOT}/helper-shim/ai-research-helper.sh"
		export AIDEVOPS_FIX_THE_FIXER_DETECTOR_AUTH_COOLDOWN_SECONDS=3600
		"${REPO_ROOT}/.agents/scripts/pulse-fix-the-fixer-detector.sh" run \
			--repo example/repo --limit 1 >"${TEST_ROOT}/detector.log" 2>&1
	)

	local cooldown_file="${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown"
	if [[ -f "$cooldown_file" ]]; then
		record_result "rc=2 records auth cooldown state file" 0
	else
		record_result "rc=2 records auth cooldown state file" 1 \
			"cooldown file missing; log=$(tr '\n' ' ' <"${TEST_ROOT}/detector.log" | head -c 400)"
	fi
	if grep -q 'skipped:auth-error=1' "${TEST_ROOT}/detector.log"; then
		record_result "rc=2 surfaces as skipped:auth-error in run summary" 0
	else
		record_result "rc=2 surfaces as skipped:auth-error in run summary" 1 \
			"summary missing; log=$(tr '\n' ' ' <"${TEST_ROOT}/detector.log" | tail -c 400)"
	fi
	return 0
}

main() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
	setup_sandbox
	trap teardown_sandbox EXIT
	test_oauth_pool_fallbacks
	test_anthropic_credential_header_shapes
	test_auto_provider_prefers_opencode
	test_opencode_tier_models
	test_detector_rc2_records_cooldown
	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
