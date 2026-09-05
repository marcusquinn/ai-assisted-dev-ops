#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim routing test cases -- REST fallback and repository write policy
# =============================================================================
# Sourced by test-gh-shim.sh after the shared hermetic harness is initialized.
#
# Usage: source "${SCRIPT_DIR}/test-gh-shim-routing-cases.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_GH_SHIM_ROUTING_CASES_LOADED:-}" ]] && return 0
_TEST_GH_SHIM_ROUTING_CASES_LOADED=1

# Resolve SCRIPT_DIR defensively when sourced outside the orchestrator.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_module_path" == "${BASH_SOURCE[0]}" ]] && _module_path="."
	SCRIPT_DIR="$(cd "$_module_path" && pwd)"
	unset _module_path
fi

# =============================================================================
# Test 15: REST-first mode rewrites safe reads without low GraphQL budget
# =============================================================================
echo ""
echo "Test 15: REST-first read routing"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-rest-first.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(AIDEVOPS_GH_REST_FIRST_READS=1 STUB_RATE_LIMIT_REMAINING=5000 "$SHIM_RUN" issue list --repo owner/repo \
	--state open --json number,title --jq '.[0].number' 2>/dev/null || true)
argv=$(_read_argv)
if [[ "$output" == "22430" ]] &&
	[[ "$argv" == *"/repos/owner/repo/issues?state=open&per_page=30"* ]] &&
	grep -q $'\tgh_issue_list\trest' "$AIDEVOPS_GH_API_LOG" &&
	! grep -q $'\tgh_issue_list\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "REST-first rewrites equivalent issue list without GraphQL"
else
	_fail "REST-first equivalent issue list rewrite" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-rest-first-unsafe.log"
rm -f "$AIDEVOPS_GH_API_LOG"
AIDEVOPS_GH_REST_FIRST_READS=1 "$SHIM_RUN" pr list --repo owner/repo \
	--state open --json number,reviewDecision,headRefOid 2>/dev/null || true
argv=$(_read_argv)
if [[ "$argv" == $'pr\nlist\n--repo\nowner/repo\n--state\nopen\n--json\nnumber,reviewDecision,headRefOid' ]] &&
	awk -F '\t' '$2 == "gh_pr_list" && $3 == "graphql" && $6 ~ /^graphql-selected:shape-[[:xdigit:]]+$/ { found = 1 } END { exit found ? 0 : 1 }' \
		"$AIDEVOPS_GH_API_LOG"; then
	_pass "REST-first leaves GraphQL-only pr list fields on GraphQL"
else
	_fail "REST-first GraphQL-only pr list preservation" "argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

_reset_log
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_REST_FALLBACK_DISABLE_CACHE=1 \
	STUB_RATE_LIMIT_REMAINING=5000 "$SHIM_RUN" pr list --repo owner/repo \
	--state closed --json number >/dev/null 2>/dev/null || true
argv=$(_read_argv)
if [[ "$argv" == $'pr\nlist\n--repo\nowner/repo\n--state\nclosed\n--json\nnumber' ]]; then
	_pass "healthy closed-unmerged reads use the server-side GraphQL filter despite REST-first mode"
else
	_fail "closed-unmerged query scanned merged REST history instead of using native filtering" "$argv"
fi

_reset_log
AIDEVOPS_GH_REST_FIRST_READS=1 _GH_SHOULD_FALLBACK_OVERRIDE=1 \
	"$SHIM_RUN" pr list --repo owner/repo --state closed --json number >/dev/null 2>/dev/null || true
argv=$(_read_argv)
if [[ "$argv" == *'/repos/owner/repo/pulls?state=closed'* ]]; then
	_pass "closed-unmerged reads retain the semantically correct low-GraphQL REST fallback"
else
	_fail "closed-unmerged low-budget fallback was lost" "$argv"
fi

echo ""
echo "Test 15g: native read attribution is caller-aware and privacy-safe"
_reset_log
native_shape_log_one="$TMP/gh-api-native-shape-one.log"
native_shape_log_two="$TMP/gh-api-native-shape-two.log"
rm -f "$native_shape_log_one" "$native_shape_log_two"
AIDEVOPS_GH_CALLER=pulse-wrapper.sh AIDEVOPS_GH_REST_FIRST_READS=1 \
	AIDEVOPS_GH_API_LOG="$native_shape_log_one" "$SHIM_RUN" issue view 111 \
	--repo private-owner/private-repo --json state,labels,assignees,comments \
	--jq '.comments[] | select(.body == "private-one")' >/dev/null 2>&1 || true
AIDEVOPS_GH_CALLER=pulse-wrapper.sh AIDEVOPS_GH_REST_FIRST_READS=1 \
	AIDEVOPS_GH_API_LOG="$native_shape_log_two" "$SHIM_RUN" issue view 999 \
	--repo other-private/other-private --json state,labels,assignees,comments \
	--jq '.comments[] | select(.body == "private-two")' >/dev/null 2>&1 || true
native_shape_one=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_shape_log_one")
native_shape_two=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_shape_log_two")
if [[ "$native_shape_one" == "$native_shape_two" && "$native_shape_one" =~ ^graphql-selected:shape-[[:xdigit:]]{12}$ ]] &&
	awk -F '\t' '$2 == "pulse-wrapper.sh" && $9 == "logical" { found = 1 } END { exit found ? 0 : 1 }' "$native_shape_log_one" &&
	! grep -Eq 'private-owner|private-repo|private-one|other-private|private-two|comments\[\]' "$native_shape_log_one" "$native_shape_log_two"; then
	_pass "native read telemetry records framework caller and value-free stable shape"
else
	_fail "native read privacy-safe attribution" \
		"shape_one=$native_shape_one shape_two=$native_shape_two log_one=$(cat "$native_shape_log_one" 2>/dev/null || true)"
fi

native_dynamic_log_one="$TMP/gh-api-native-dynamic-one.log"
native_dynamic_log_two="$TMP/gh-api-native-dynamic-two.log"
native_oversized_log="$TMP/gh-api-native-oversized.log"
oversized_json_fields="state"
while [[ ${#oversized_json_fields} -le 1024 ]]; do
	oversized_json_fields="${oversized_json_fields},state"
done
rm -f "$native_dynamic_log_one" "$native_dynamic_log_two" "$native_oversized_log"
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_API_LOG="$native_dynamic_log_one" \
	"$SHIM_RUN" issue view 111 --repo owner/repo --json PrivateIdentifierOne >/dev/null 2>&1 || true
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_API_LOG="$native_dynamic_log_two" \
	"$SHIM_RUN" issue view 999 --repo other/repo --json OtherSensitiveIdentifier999 >/dev/null 2>&1 || true
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_API_LOG="$native_oversized_log" \
	"$SHIM_RUN" issue view 111 --repo owner/repo --json "$oversized_json_fields" >/dev/null 2>&1 || true
native_dynamic_one=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_dynamic_log_one")
native_dynamic_two=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_dynamic_log_two")
native_oversized=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_oversized_log")
if [[ "$native_dynamic_one" == "$native_dynamic_two" && "$native_oversized" == "$native_dynamic_one" ]] &&
	[[ "$native_dynamic_one" =~ ^graphql-bypass:shape-[[:xdigit:]]{12}$ ]] &&
	[[ "$native_shape_one" != "$native_dynamic_one" ]] &&
	! grep -Eq 'PrivateIdentifierOne|OtherSensitiveIdentifier999' \
		"$native_dynamic_log_one" "$native_dynamic_log_two" "$native_oversized_log"; then
	_pass "native read shape admits only bounded documented JSON fields"
else
	_fail "native read JSON field privacy boundary" \
		"valid=$native_shape_one dynamic_one=$native_dynamic_one dynamic_two=$native_dynamic_two oversized=$native_oversized"
fi

native_alias_long_log="$TMP/gh-api-native-alias-long.log"
native_alias_short_log="$TMP/gh-api-native-alias-short.log"
native_bypass_long_log="$TMP/gh-api-native-bypass-long.log"
native_bypass_short_log="$TMP/gh-api-native-bypass-short.log"
rm -f "$native_alias_long_log" "$native_alias_short_log" "$native_bypass_long_log" "$native_bypass_short_log"
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_API_LOG="$native_alias_long_log" \
	"$SHIM_RUN" issue view 111 --repo owner/repo --comments --web >/dev/null 2>&1 || true
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_API_LOG="$native_alias_short_log" \
	"$SHIM_RUN" issue view 999 --repo other/repo -c -w >/dev/null 2>&1 || true
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_API_LOG="$native_bypass_long_log" \
	"$SHIM_RUN" issue view 111 --repo owner/repo --comments --web >/dev/null 2>&1 || true
AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_API_LOG="$native_bypass_short_log" \
	"$SHIM_RUN" issue view 999 --repo other/repo -c -w >/dev/null 2>&1 || true
native_alias_long=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_alias_long_log")
native_alias_short=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_alias_short_log")
native_bypass_long=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_bypass_long_log")
native_bypass_short=$(awk -F '\t' '$9 == "logical" && $3 == "graphql" { print $6; exit }' "$native_bypass_short_log")
if [[ "$native_alias_long" == "$native_alias_short" && "$native_alias_long" =~ ^graphql-selected:shape-[[:xdigit:]]{12}$ ]] &&
	[[ "$native_bypass_long" == "$native_bypass_short" && "$native_bypass_long" =~ ^graphql-bypass:shape-[[:xdigit:]]{12}$ ]]; then
	_pass "native read shape treats short and long flag aliases identically"
else
	_fail "native read flag alias attribution" \
		"fallback_long=$native_alias_long fallback_short=$native_alias_short bypass_long=$native_bypass_long bypass_short=$native_bypass_short"
fi

hash_shasum_dir="$TMP/hash-shasum"
hash_sha256sum_dir="$TMP/hash-sha256sum"
hash_openssl_dir="$TMP/hash-openssl"
hash_empty_dir="$TMP/hash-empty"
mkdir -p "$hash_shasum_dir" "$hash_sha256sum_dir" "$hash_openssl_dir" "$hash_empty_dir"
cat >"$hash_shasum_dir/shasum" <<'EOF'
#!/bin/bash
IFS= read -r _input || true
printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  -\n'
EOF
cat >"$hash_sha256sum_dir/sha256sum" <<'EOF'
#!/bin/bash
IFS= read -r _input || true
printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  -\n'
EOF
cat >"$hash_openssl_dir/openssl" <<'EOF'
#!/bin/bash
IFS= read -r _input || true
printf 'SHA2-256(stdin)= 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
EOF
chmod +x "$hash_shasum_dir/shasum" "$hash_sha256sum_dir/sha256sum" "$hash_openssl_dir/openssl"
hash_shape_shasum=$(PATH="$hash_shasum_dir" "$BASH" -c "source \"\$1\"; _shim_read_shape_digest issue view 1 --repo private/repo --json state" _ "$TMP/scripts/gh-native-transport-lib.sh")
hash_shape_sha256sum=$(PATH="$hash_sha256sum_dir" "$BASH" -c "source \"\$1\"; _shim_read_shape_digest issue view 1 --repo private/repo --json state" _ "$TMP/scripts/gh-native-transport-lib.sh")
hash_shape_openssl=$(PATH="$hash_openssl_dir" "$BASH" -c "source \"\$1\"; _shim_read_shape_digest issue view 1 --repo private/repo --json state" _ "$TMP/scripts/gh-native-transport-lib.sh")
if [[ "$hash_shape_shasum" == "shape-0123456789ab" && "$hash_shape_sha256sum" == "$hash_shape_shasum" &&
	"$hash_shape_openssl" == "$hash_shape_shasum" ]] &&
	PATH="$hash_empty_dir" "$BASH" -c "source \"\$1\"; ! _shim_read_shape_digest issue view 1 --repo private/repo --json state" _ \
		"$TMP/scripts/gh-native-transport-lib.sh"; then
	_pass "native read shape is stable across SHA-256 backends and fails closed without one"
else
	_fail "native read SHA-256 backend stability" \
		"shasum=$hash_shape_shasum sha256sum=$hash_shape_sha256sum openssl=$hash_shape_openssl"
fi

echo ""
echo "Test 15f: failed REST rewrite uses default telemetry and does not retry through GraphQL"
_reset_log
default_log_home="$TMP/default-log-home"
default_api_log="$default_log_home/.aidevops/logs/gh-api-calls.log"
mkdir -p "$default_log_home/.aidevops/logs"
rm -f "$default_api_log"
rest_failure_rc=0
env -u AIDEVOPS_GH_API_LOG HOME="$default_log_home" GH_TOKEN=fixture-token \
	AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$TMP/rest-rewrite-failure-state" AIDEVOPS_TEMP_DIR="$TMP" \
	STUB_REST_READ_FAIL=1 STUB_REST_READ_EXIT_CODE=42 STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core STUB_GH_DEBUG_STATUS=403 \
	STUB_GH_DEBUG_USED=101 STUB_GH_DEBUG_REMAINING=4899 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" issue list --repo owner/repo --state open --json number,title \
	>/dev/null 2>/dev/null || rest_failure_rc=$?
rest_api_calls=$(awk -F '\t' '$1 == "api" && $2 ~ /^\/repos\// { count++ } END { print count + 0 }' "$STUB_GH_CALL_LOG")
native_issue_calls=$(awk -F '\t' '$1 == "issue" && $2 == "list" { count++ } END { print count + 0 }' "$STUB_GH_CALL_LOG")
if [[ "$rest_failure_rc" -ne 0 && "$rest_api_calls" -eq 1 && "$native_issue_calls" -eq 0 ]] &&
	awk -F '\t' '$9 == "attempt" && $15 == "403" { found = 1 } END { exit found ? 0 : 1 }' \
		"$default_api_log" &&
	! awk -F '\t' '$2 == "gh_issue_list" && $3 == "graphql" { found = 1 } END { exit found ? 0 : 1 }' \
		"$default_api_log"; then
	_pass "attempted REST failure propagates without duplicate GraphQL request"
else
	_fail "failed REST rewrite propagation" \
		"rc: $rest_failure_rc REST calls: $rest_api_calls native calls: $native_issue_calls log: $(cat "$default_api_log" 2>/dev/null || true)"
fi

_reset_log
rest_failure_without_log_rc=0
AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1 AIDEVOPS_GH_API_LOG=/dev/null \
	AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$TMP/rest-rewrite-no-log-state" AIDEVOPS_TEMP_DIR="$TMP" \
	STUB_REST_READ_FAIL=1 STUB_REST_READ_EXIT_CODE=42 STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core STUB_GH_DEBUG_STATUS=403 \
	STUB_GH_DEBUG_USED=101 STUB_GH_DEBUG_REMAINING=4899 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" issue list --repo owner/repo --state open --json number,title \
	>/dev/null 2>/dev/null || rest_failure_without_log_rc=$?
rest_api_calls=$(awk -F '\t' '$1 == "api" && $2 ~ /^\/repos\// { count++ } END { print count + 0 }' "$STUB_GH_CALL_LOG")
native_issue_calls=$(awk -F '\t' '$1 == "issue" && $2 == "list" { count++ } END { print count + 0 }' "$STUB_GH_CALL_LOG")
if [[ "$rest_failure_without_log_rc" -ne 0 && "$rest_api_calls" -eq 1 && "$native_issue_calls" -eq 0 ]]; then
	_pass "attempted REST failure remains authoritative without a historical API log"
else
	_fail "request-local REST failure propagation" \
		"rc: $rest_failure_without_log_rc REST calls: $rest_api_calls native calls: $native_issue_calls"
fi

echo ""
echo "Test 15a: issue --author @me maps to REST creator"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-issue-author.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(AIDEVOPS_GH_FORCE_REST_READS=1 STUB_GH_USER=managed "$SHIM_RUN" issue list --repo owner/repo \
	--author @me --state all --json number,author --jq '.[0].author.login' 2>/dev/null || true)
argv=$(_read_argv)
if [[ "$output" == "managed" ]] && [[ "$argv" == *"creator=managed"* ]] &&
	grep -q $'\tgh_issue_list\trest' "$AIDEVOPS_GH_API_LOG"; then
	_pass "forced REST issue author preserves @me through creator filtering"
else
	_fail "forced REST issue author filtering" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

echo ""
echo "Test 15b: PR --author uses Search API qualifiers"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-pr-author.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(AIDEVOPS_GH_FORCE_REST_READS=1 "$SHIM_RUN" pr list --repo owner/repo \
	--author managed --state all --json number,author --jq '.[0].author.login' 2>/dev/null || true)
argv=$(_read_argv)
if [[ "$output" == "managed" ]] && [[ "$argv" == *$'api\n-i\n/search/issues?'* ]] &&
	[[ "$argv" == *"author%3Amanaged"* ]] && grep -q $'\tgh_pr_list\tsearch-rest' "$AIDEVOPS_GH_API_LOG"; then
	_pass "forced REST PR author routes through exact Search qualifiers"
else
	_fail "forced REST PR author filtering" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

echo ""
echo "Test 15c: unsupported issue filters stay on native gh"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-unsupported-issue-list.log"
rm -f "$AIDEVOPS_GH_API_LOG"
AIDEVOPS_GH_FORCE_REST_READS=1 "$SHIM_RUN" issue list --repo owner/repo \
	--milestone future --state open --json number 2>/dev/null || true
argv=$(_read_argv)
if [[ "$argv" == $'issue\nlist\n--repo\nowner/repo\n--milestone\nfuture\n--state\nopen\n--json\nnumber' ]] &&
	grep -q $'\tgh_issue_list\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "unsupported issue filter is never silently dropped by REST rewrite"
else
	_fail "unsupported issue filter GraphQL preservation" "argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

echo ""
echo "Test 15d: unsupported view flags stay on native gh"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-unsupported-issue-view.log"
rm -f "$AIDEVOPS_GH_API_LOG"
AIDEVOPS_GH_FORCE_REST_READS=1 "$SHIM_RUN" issue view 42 --repo owner/repo \
	--comments --json number 2>/dev/null || true
argv=$(_read_argv)
if [[ "$argv" == $'issue\nview\n42\n--repo\nowner/repo\n--comments\n--json\nnumber' ]] &&
	grep -q $'\tgh_issue_view\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "unsupported issue view flag is never silently dropped by REST rewrite"
else
	_fail "unsupported issue view GraphQL preservation" "argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

echo ""
echo "Test 15e: issue view node IDs preserve exact REST output"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-issue-view-id.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(AIDEVOPS_GH_FORCE_REST_READS=1 "$SHIM_RUN" issue view 42 --repo owner/repo \
	--json id,number,state,updatedAt 2>/dev/null || true)
argv=$(_read_argv)
if jq -e '.id == "I_kwDOFixture42" and .number == 42 and .state == "OPEN" and .updatedAt == "2026-07-28T19:38:58Z"' \
	>/dev/null 2>&1 <<<"$output" &&
	[[ "$argv" == *$'api\n/repos/owner/repo/issues/42'* ]] &&
	grep -q $'\tgh_issue_view\trest' "$AIDEVOPS_GH_API_LOG" &&
	! grep -q $'\tgh_issue_view\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "issue view id maps exactly from REST node_id"
else
	_fail "issue view id REST projection" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-issue-view-id-scalar.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(AIDEVOPS_GH_FORCE_REST_READS=1 "$SHIM_RUN" issue view 42 --repo owner/repo \
	--json id --jq '.id' 2>/dev/null || true)
if [[ "$output" == "I_kwDOFixture42" ]] && grep -q $'\tgh_issue_view\trest' "$AIDEVOPS_GH_API_LOG"; then
	_pass "issue view id preserves scalar jq output"
else
	_fail "issue view id scalar REST projection" "output: $output log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-issue-view-id-malformed.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(STUB_REST_ISSUE_VIEW_JSON='{"node_id":null,"number":42,"state":"open"}' \
	STUB_NATIVE_ISSUE_VIEW_JSON='{"id":"I_nativeFallback","number":42,"state":"OPEN"}' \
	AIDEVOPS_GH_FORCE_REST_READS=1 "$SHIM_RUN" issue view 42 --repo owner/repo \
	--json id,number,state 2>/dev/null || true)
argv=$(_read_argv)
if [[ "$output" == '{"id":"I_nativeFallback","number":42,"state":"OPEN"}' ]] &&
	[[ "$argv" == $'issue\nview\n42\n--repo\nowner/repo\n--json\nid,number,state' ]] &&
	grep -q $'\tgh_issue_view\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "malformed REST node_id fails open to unchanged native issue view"
else
	_fail "malformed issue node_id native fallback" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

# =============================================================================
# Test 16: raw interactive aidevops tracking issue creation is normalized
# =============================================================================
echo ""
echo "Test 16: raw interactive tracking issue label normalization"
_reset_log
"$SHIM_RUN" issue create --repo owner/repo --title "t3565: Harden issue labels" --body "tracking body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'--label\norigin:interactive'* ]] &&
	[[ "$argv" == *$'--label\nstatus:in-review'* ]] &&
	[[ "$argv" == *$'--label\nbug'* ]]; then
	_pass "tracking issue gets origin/status/type labels"
else
	_fail "tracking issue label normalization" "argv: $argv"
fi

_reset_log
STUB_MANAGED_LABELS="origin:worker" \
	"$SHIM_RUN" issue create --repo owner/repo --title "t3565: Fresh labels" \
	--body "tracking body" 2>/dev/null
argv=$(_read_argv)
if grep -q '^label create origin:interactive ' "$STUB_GH_LABEL_LOG" &&
	grep -q '^label create status:in-review ' "$STUB_GH_LABEL_LOG" &&
	grep -q '^label create bug ' "$STUB_GH_LABEL_LOG" &&
	[[ "$argv" == *$'--label\norigin:interactive'* ]]; then
	_pass "fresh repo provisions every shim-injected tracking label"
else
	_fail "fresh tracking-label provisioning" "argv: $argv creates: $(cat "$STUB_GH_LABEL_LOG") calls: $(cat "$STUB_GH_CALL_LOG")"
fi

# =============================================================================
# Test 17: raw issue normalization respects explicit labels and headless mode
# =============================================================================
echo ""
echo "Test 17: label normalization respects explicit and headless contexts"
_reset_log
"$SHIM_RUN" issue create --repo owner/repo --title "t3565: Explicit labels" --label "origin:worker,status:available,enhancement" --body "tracking body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" != *"origin:interactive"* ]] && [[ "$argv" != *"status:in-review"* ]] && [[ "$argv" != *$'--label\nbug'* ]]; then
	_pass "explicit labels are not duplicated or overwritten"
else
	_fail "explicit label preservation" "argv: $argv"
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE=owner/repo "$SHIM_RUN" issue create --repo owner/repo --title "t3565: Headless labels" --body "tracking body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" != *"origin:interactive"* ]] && [[ "$argv" != *"status:in-review"* ]]; then
	_pass "headless issue creation is not normalized as interactive"
else
	_fail "headless label normalization bypass" "argv: $argv"
fi

_reset_log
touch "$TMP/literal-status-star"
"$SHIM_RUN" issue create --repo owner/repo -t "t3565: Short title flag" --label "status:*, origin:worker" --body "tracking body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" != *"literal-status-star"* ]] && [[ "$argv" != *"status:in-review"* ]] && [[ "$argv" == *$'--label\nbug'* ]]; then
	_pass "label parsing avoids globbing and short title flag normalizes"
else
	_fail "label glob safety and short title handling" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo owner/repo --title "not-a-task" -t "GH#23049: Follow-up labels" --body "tracking body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'--label\norigin:interactive'* ]] && [[ "$argv" == *$'--label\nstatus:in-review'* ]]; then
	_pass "last title flag wins during normalization"
else
	_fail "multiple title flag handling" "argv: $argv"
fi

# =============================================================================
# Test 18: headless external contributor write guard blocks raw comments
# =============================================================================
echo ""
echo "Test 18: headless external write guard blocks raw comments"
_reset_log
if AIDEVOPS_HEADLESS=1 "$SHIM_RUN" pr create --repo external/repo \
	--title "blocked create" --body "For #123" 2>"$TMP/guard-create.err"; then
	_fail "headless pr create guard" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && [[ ! -s "$STUB_GH_LABEL_LOG" ]] &&
		grep -q "external-write-guard" "$TMP/guard-create.err"; then
		_pass "blocked headless pr create performs no label writes"
	else
		_fail "headless pr create label-write guard" \
			"argv: $argv creates: $(cat "$STUB_GH_LABEL_LOG") err: $(cat "$TMP/guard-create.err")"
	fi
fi

_reset_log
if AIDEVOPS_HEADLESS=1 "$SHIM_RUN" issue comment 123 --repo external/repo --body "uninstigated" 2>"$TMP/guard-issue.err"; then
	_fail "headless issue comment guard" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-issue.err"; then
		_pass "headless issue comment to contributor repo is blocked before gh exec"
	else
		_fail "headless issue comment guard" "argv: $argv err: $(cat "$TMP/guard-issue.err" 2>/dev/null || true)"
	fi
fi

_reset_log
if AIDEVOPS_HEADLESS=1 "$SHIM_RUN" pr merge 789 --repo external/repo --squash --body "uninstigated" 2>"$TMP/guard-merge.err"; then
	_fail "headless pr merge guard" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-merge.err"; then
		_pass "headless pr merge to contributor repo is blocked before gh exec"
	else
		_fail "headless pr merge guard" "argv: $argv err: $(cat "$TMP/guard-merge.err" 2>/dev/null || true)"
	fi
fi

_reset_log
if AIDEVOPS_SESSION_ORIGIN=pulse "$SHIM_RUN" pr comment 456 --repo external/repo --body "uninstigated" 2>"$TMP/guard-pr.err"; then
	_fail "headless pr comment guard" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-pr.err"; then
		_pass "headless pr comment to contributor repo is blocked before gh exec"
	else
		_fail "headless pr comment guard" "argv: $argv err: $(cat "$TMP/guard-pr.err" 2>/dev/null || true)"
	fi
fi

# =============================================================================
# Test 19: headless external write guard blocks REST write endpoints
# =============================================================================
echo ""
echo "Test 19: headless external write guard blocks REST writes"
_reset_log
if FULL_LOOP_HEADLESS=1 "$SHIM_RUN" api /repos/external/repo/issues/123/comments -X POST -f body="uninstigated" 2>"$TMP/guard-api.err"; then
	_fail "headless REST comment guard" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-api.err"; then
		_pass "headless REST issue comment endpoint is blocked before gh exec"
	else
		_fail "headless REST comment guard" "argv: $argv err: $(cat "$TMP/guard-api.err" 2>/dev/null || true)"
	fi
fi

# =============================================================================
# Test 20: interactive or explicitly instigated writes still pass through
# =============================================================================
echo ""
echo "Test 20: interactive and explicit external writes pass"
_reset_log
"$SHIM_RUN" issue comment 123 --repo external/repo --body "interactive" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "interactive external comment still receives normal signature handling"
else
	_fail "interactive external comment pass-through" "argv: $argv"
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE=external/repo "$SHIM_RUN" pr comment 456 --repo external/repo --body "explicit" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "explicit per-repo headless allowance permits normal signature handling"
else
	_fail "explicit headless external allowance" "argv: $argv"
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE=external/repo "$SHIM_RUN" \
	pr merge 456 --repo external/repo --squash --body "allowed merge" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'pr\nmerge\n456'* && "$argv" == *"allowed merge"* &&
	"$argv" != *"<!-- aidevops:sig -->"* ]]; then
	_pass "explicit headless allowance permits unsigned pr merge transport"
else
	_fail "explicit headless pr merge allowance" "argv: $argv"
fi

# =============================================================================
# Test 21: managed maintainer repos are not blocked in headless mode
# =============================================================================
echo ""
echo "Test 21: maintainer repo metadata permits headless writes"
repos_json="$TMP/repos.json"
printf '{"initialized_repos":[{"slug":"managed/repo","role":"maintainer"}]}' >"$repos_json"
_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" issue comment 789 --repo managed/repo --body "managed" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "headless write to maintainer-managed repo proceeds normally"
else
	_fail "maintainer repo headless write" "argv: $argv"
fi

_reset_log
ops_body='<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Dispatching worker (deterministic).
- **Worker PID**: 123
<!-- ops:end -->'
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" api /repos/managed/repo/issues/789/comments -X POST -f body="$ops_body" 2>/dev/null
sig_argv=$(_read_sig_argv)
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]] && [[ "$sig_argv" == *$'--no-session'* ]]; then
	_pass "deterministic ops REST comments sign without session metrics"
else
	_fail "ops REST no-session signature" "argv: $argv sig argv: $sig_argv"
fi

_reset_log
inline_api_body='Documentation mentions <!-- aidevops:sig --> inline'
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" \
	api /repos/managed/repo/issues/789/comments -X POST -f body="$inline_api_body" 2>/dev/null
marker_count=$(grep -Fxc '<!-- aidevops:sig -->' "$STUB_GH_LOG" 2>/dev/null || true)
if [[ "$marker_count" -eq 1 ]]; then
	_pass "direct REST body with inline marker prose receives a standalone marker"
else
	_fail "direct REST inline marker signing" "standalone marker appeared $marker_count times, expected 1"
fi

repos_json_missing_role="$TMP/repos-missing-role.json"
printf '{"initialized_repos":[{"slug":"managed/repo","maintainer":"managed","pulse":true}]}' >"$repos_json_missing_role"
_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json_missing_role" "$SHIM_RUN" api /repos/managed/repo/issues/789/comments -X POST -f body="managed" 2>"$TMP/guard-api-missing-role.err"
argv=$(_read_argv)
if [[ "$argv" == *$'api\n/repos/managed/repo/issues/789/comments'* ]]; then
	_pass "omitted role on owned managed repo is derived as maintainer"
else
	_fail "missing role maintainer fallback" "argv: $argv err: $(cat "$TMP/guard-api-missing-role.err" 2>/dev/null || true)"
fi

repos_json_org_maintainer="$TMP/repos-org-maintainer.json"
printf '{"initialized_repos":[{"slug":"org/repo","maintainer":"managed","pulse":true}]}' >"$repos_json_org_maintainer"
_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json_org_maintainer" "$SHIM_RUN" api /repos/org/repo/issues/789/comments -X POST -f body="managed" 2>"$TMP/guard-api-org-maintainer.err"
argv=$(_read_argv)
if [[ "$argv" == *$'api\n/repos/org/repo/issues/789/comments'* ]]; then
	_pass "configured maintainer on non-owned repo is derived as maintainer"
else
	_fail "configured maintainer fallback" "argv: $argv err: $(cat "$TMP/guard-api-org-maintainer.err" 2>/dev/null || true)"
fi

repos_json_org_nonmaintainer="$TMP/repos-org-nonmaintainer.json"
printf '{"initialized_repos":[{"slug":"org/repo","maintainer":"other","pulse":true}]}' >"$repos_json_org_nonmaintainer"
_reset_log
if AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json_org_nonmaintainer" "$SHIM_RUN" api /repos/org/repo/issues/789/comments -X POST -f body="managed" 2>"$TMP/guard-api-org-nonmaintainer.err"; then
	_fail "non-owner non-maintainer remains blocked" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-api-org-nonmaintainer.err"; then
		_pass "non-owner non-maintainer remains blocked"
	else
		_fail "non-owner non-maintainer guard" "argv: $argv err: $(cat "$TMP/guard-api-org-nonmaintainer.err" 2>/dev/null || true)"
	fi
fi

repos_json_contributor="$TMP/repos-contributor-role.json"
printf '{"initialized_repos":[{"slug":"managed/repo","role":"contributor","maintainer":"managed","pulse":true}]}' >"$repos_json_contributor"
_reset_log
if AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json_contributor" "$SHIM_RUN" api /repos/managed/repo/issues/789/comments -X POST -f body="managed" 2>"$TMP/guard-api-explicit-contributor.err"; then
	_fail "explicit contributor role overrides owner fallback" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-api-explicit-contributor.err"; then
		_pass "explicit contributor role remains blocked for owned slug"
	else
		_fail "explicit contributor role guard" "argv: $argv err: $(cat "$TMP/guard-api-explicit-contributor.err" 2>/dev/null || true)"
	fi
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" issue comment 789 --repo ssh://git@github.com/managed/repo.git --body "managed" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "headless write guard normalizes ssh github repo URLs"
else
	_fail "ssh github repo URL normalization" "argv: $argv"
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" issue comment 789 --repo https://token@github.com/managed/repo.git --body "managed" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "headless write guard normalizes credentialed github repo URLs"
else
	_fail "credentialed github repo URL normalization" "argv: $argv"
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" issue comment 789 --repo git://github.com/managed/repo.git --body "managed" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "headless write guard normalizes git protocol github repo URLs"
else
	_fail "git protocol github repo URL normalization" "argv: $argv"
fi

_reset_log
if FULL_LOOP_HEADLESS=1 "$SHIM_RUN" api --jq . /repos/external/repo/issues/123/comments -X POST -f body="uninstigated" 2>"$TMP/guard-api-positional.err"; then
	_fail "headless REST guard ignores non-path positionals" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-api-positional.err"; then
		_pass "headless REST guard finds repo path after query positional"
	else
		_fail "headless REST guard path extraction after query positional" "argv: $argv err: $(cat "$TMP/guard-api-positional.err" || true)"
	fi
fi

_reset_log
if FULL_LOOP_HEADLESS=1 "$SHIM_RUN" api -q . /repos/external/repo/issues/123/comments -X POST -f body="uninstigated" 2>"$TMP/guard-api-positional-short.err"; then
	_fail "headless REST guard ignores non-path positionals with short flag" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-api-positional-short.err"; then
		_pass "headless REST guard finds repo path after short query positional"
	else
		_fail "headless REST guard path extraction after short query positional" "argv: $argv err: $(cat "$TMP/guard-api-positional-short.err" || true)"
	fi
fi

for short_opt in -q -p -t; do
	_reset_log
	if FULL_LOOP_HEADLESS=1 AIDEVOPS_REPOS_JSON="$repos_json" "$SHIM_RUN" api "$short_opt" /repos/managed/repo/issues/1/comments /repos/external/repo/issues/123/comments -X POST -f body="uninstigated" 2>"$TMP/guard-api-$short_opt-injection.err"; then
		_fail "headless REST guard skips $short_opt argument" "write unexpectedly passed"
	else
		argv=$(_read_argv)
		if [[ -z "$argv" ]] && grep -q "external-write-guard" "$TMP/guard-api-$short_opt-injection.err"; then
			_pass "headless REST guard skips $short_opt argument before repo extraction"
		else
			_fail "headless REST guard skips $short_opt argument" "argv: $argv err: $(cat "$TMP/guard-api-$short_opt-injection.err" || true)"
		fi
	fi
done
