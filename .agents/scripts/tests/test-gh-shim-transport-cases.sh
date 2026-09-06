#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by the existing hermetic gh shim harness after legacy-path coverage.

printf '\nTest 27: shared raw transport controls and response-owned quota\n'
for library in gh-transport-controls.sh gh-transport-governor.py gh_transport_budget.py gh_transport_recovery.py shared-gh-secondary-cooldown.sh; do
	cp "${REPO_DIR}/.agents/scripts/${library}" "${TMP}/scripts/${library}"
done
mkdir -p "${TMP}/governor/tmp"
export AIDEVOPS_GH_TRANSPORT_STATE_DIR="${TMP}/governor/state"
export AIDEVOPS_TEMP_DIR="${TMP}/governor/tmp"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${TMP}/governor/cooldown.json"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE="${TMP}/governor/events.jsonl"
export AIDEVOPS_GH_API_LOG="${TMP}/governor/api.tsv"
export AIDEVOPS_GH_READ_RAMP_ENABLED=0
export AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1
unset AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE AIDEVOPS_GH_EXACT_QUOTA_CAPTURE GH_DEBUG
_governor_reset=$(($(date +%s) + 3600))
printf '{"expires_at":%s}\n' "$_governor_reset" >"$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
_reset_log
_governor_rc=0
"$SHIM_RUN" pr view 42 --repo owner/repo --json number >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && ! -s "$STUB_GH_CALL_LOG" ]]; then
	_pass "raw native reads stop during the shared cooldown without a request"
else
	_fail "raw native reads stop during the shared cooldown without a request"
fi
if "$SHIM_RUN" --version >/dev/null 2>/dev/null; then
	_pass "local-only commands remain usable during cooldown"
else
	_fail "local-only commands remain usable during cooldown"
fi
rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"

export STUB_TRANSPORT_RESPONSE_FILE="${TMP}/governor/response"
printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Reset: %s\r\n\r\n{"fixture":true}\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
_reset_log
_governor_output=$("$SHIM_RUN" api user)
if [[ "$_governor_output" == '{"fixture":true}' && "$(_read_attempt_quota "$AIDEVOPS_GH_API_LOG")" == 1 && "$(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 15)" == 200 ]]; then
	_pass "REST transport strips only injected headers and records actual response cost/status"
else
	_fail "REST transport strips only injected headers and records actual response cost/status"
fi
if [[ "$(wc -l <"$STUB_GH_CALL_LOG" | tr -d ' ')" -eq 1 ]]; then
	_pass "quota observation does not probe rate_limit or repeat the REST request"
else
	_fail "quota observation does not probe rate_limit or repeat the REST request"
fi
"$SHIM_RUN" api user --include >"${TMP}/governor/included"
if cmp -s "$STUB_TRANSPORT_RESPONSE_FILE" "${TMP}/governor/included"; then
	_pass "explicit included-response output remains byte-for-byte native"
else
	_fail "explicit included-response output remains byte-for-byte native"
fi

_reset_log
_governor_rc=0
STUB_TRANSPORT_RC=125 "$SHIM_RUN" api user >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 125 && "$(wc -l <"$STUB_GH_CALL_LOG" | tr -d ' ')" -eq 1 ]]; then
	_pass "native exit 125 is preserved without invoking fallback after execution"
else
	_fail "native exit 125 is preserved without invoking fallback after execution"
fi

printf 'HTTP/2.0 304 Not Modified\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Reset: %s\r\n\r\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
_governor_rc=0
STUB_TRANSPORT_RC=1 "$SHIM_RUN" api user -H 'If-None-Match: "fixture"' >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 1 && "$(_read_attempt_quota "$AIDEVOPS_GH_API_LOG")" == 0 ]]; then
	_pass "response-owned conditional zero cost preserves native exit status"
else
	_fail "response-owned conditional zero cost preserves native exit status"
fi

printf 'not an included HTTP response\n' >"$STUB_TRANSPORT_RESPONSE_FILE"
_governor_rc=0
_governor_output=$("$SHIM_RUN" api user 2>/dev/null) || _governor_rc=$?
if [[ "$_governor_rc" -ne 0 && -z "$_governor_output" ]]; then
	_pass "unknown header framing cannot become successful application data"
else
	_fail "unknown header framing cannot become successful application data"
fi

printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: %s\r\n\r\n{}\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
STUB_TRANSPORT_RC=1 "$SHIM_RUN" api user >/dev/null 2>/dev/null || true
_reset_log
_governor_rc=0
"$SHIM_RUN" api user >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && ! -s "$STUB_GH_CALL_LOG" ]]; then
	_pass "authoritative exhaustion suppresses the next raw request locally"
else
	_fail "authoritative exhaustion suppresses the next raw request locally"
fi

# Exact capture owns multi-frame native attempts. The normal final-response
# adapter must never take that route away from an explicitly metered window.
# shellcheck source=/dev/null
source "${TMP}/scripts/gh-transport-controls.sh"
_governor_rc=0
AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 _gh_transport_run_rest \
	"${TMP}/bin/gh" rest gh_api_rest 0 api user >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 125 && "$_GHGT_HANDLED" -eq 0 ]]; then
	_pass "exact multi-response capture retains transport ownership"
else
	_fail "normal REST adapter intercepted exact transport capture"
fi

# shellcheck source=/dev/null
source "${TMP}/scripts/gh-native-transport-lib.sh"
if [[ "$(_shim_classify_endpoint search issues)" == search-rest && "$(_shim_classify_endpoint api graphql)" == graphql ]]; then
	_pass "native search uses the REST search resource, not the GraphQL pool"
else
	_fail "native search quota family is misclassified"
fi

return 0
