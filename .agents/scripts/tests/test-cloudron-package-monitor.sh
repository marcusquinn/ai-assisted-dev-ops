#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../cloudron-package-monitor-helper.sh"
PULSE_ROUTINES="${SCRIPT_DIR}/../pulse-routines.sh"
GH_COOLDOWN="${SCRIPT_DIR}/../shared-gh-secondary-cooldown.sh"
TEST_ROOT=""
PASSED=0
FAILED=0
PINNED_BASE='cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e'

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

write_fake_commands() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" && "$*" == *releases\?per_page=100* ]]; then
    endpoint=""
    for arg in "$@"; do
        [[ "$arg" == /repos/*/releases\?per_page=100 ]] && endpoint="$arg"
    done
    printf 'API %s\n' "$endpoint" >>"${MONITOR_API_LOG:-/dev/null}"
    printf 'ARGS %s\n' "$*" >>"${MONITOR_API_LOG:-/dev/null}"
    case "${MONITOR_RATE_FIXTURE:-}" in
        primary-403-reset)
            printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 9999999999\r\n\r\n{"message":"API rate limit exceeded"}\n'
            exit 1
            ;;
        secondary-403-retry)
            printf 'HTTP/2 403\r\nRetry-After: 45\r\nX-RateLimit-Remaining: 50\r\n\r\n{"message":"You have exceeded a secondary rate limit"}\n'
            exit 1
            ;;
        primary-429-retry)
            printf 'HTTP/2 429\r\nRetry-After: 30\r\nX-RateLimit-Remaining: 0\r\n\r\n{"message":"rate limit exceeded"}\n'
            exit 1
            ;;
        primary-429-reset)
            printf 'HTTP/2 429\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 9999999999\r\n\r\n{"message":"rate limit exceeded"}\n'
            exit 1
            ;;
    esac
    if [[ "${MONITOR_API_FAIL:-false}" == true ]]; then
        printf 'HTTP/2 500\r\n\r\n{"message":"temporary server error"}\n'
        exit 1
    fi
    printf 'HTTP/2 200\r\nX-RateLimit-Remaining: 100\r\n\r\n'
    if [[ -n "${MONITOR_RELEASES_FILE:-}" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line"
        done <"${MONITOR_RELEASES_FILE}"
    else
        cat <<'JSON'
[
  {"tag_name":"v1.10.0","draft":false,"prerelease":false},
  {"tag_name":"v9.0.0","draft":true,"prerelease":false},
  {"tag_name":"desktop-v99.0.0","draft":false,"prerelease":false}
]
[
  {"tag_name":"v8.0.0","draft":false,"prerelease":true},
  {"tag_name":"2.0.0","draft":false,"prerelease":false},
  {"tag_name":99,"draft":false,"prerelease":false}
]
JSON
    fi
    exit 0
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    printf '%s\n' 'ADMIN'
    exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
    search=""
    shift 2
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--search" ]]; then
            search="${2:-}"
            break
        fi
        shift
    done
    marker="${search% in:body}"
    if [[ -n "$marker" && -f "${MONITOR_TEST_LOG}" ]] && grep -Fq -- "$marker" "${MONITOR_TEST_LOG}"; then
        printf '%s\n' '101'
    fi
    exit 0
fi
exit 1
GH
	cat >"${bin_dir}/gh_create_issue" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
repo=""
body_file=""
title=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'CALL %s\n' "$repo" >>"${MONITOR_TEST_LOG}"
printf 'TITLE %s\n' "$title" >>"${MONITOR_TEST_LOG}"
while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >>"${MONITOR_TEST_LOG}"
done <"$body_file"
WRAPPER
	chmod +x "${bin_dir}/gh" "${bin_dir}/gh_create_issue"
	return 0
}

write_fixture() {
	local home_dir="$1"
	local repo_dir="$2"
	mkdir -p "${home_dir}/.config/aidevops" "$repo_dir"
	cat >"${repo_dir}/CloudronManifest.json" <<'JSON'
{
  "id": "com.example.package",
  "title": "Example Package",
  "version": "1.0.0",
  "upstreamVersion": "1.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "manifestVersion": 2,
  "addons": {"localstorage": {}}
}
JSON
	printf 'FROM %s\n' "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	cat >"${home_dir}/.config/aidevops/repos.json" <<JSON
{
  "initialized_repos": [{
    "slug": "exampleorg/example-package",
    "path": "${repo_dir}",
    "app_type": "cloudron-package",
    "cloudron_package": {
      "manifest": "CloudronManifest.json",
      "upstream_slug": "exampleorg/upstream",
      "monitor_upstream": true,
      "monitor_compatibility": true
    }
  }]
}
JSON
	return 0
}

write_two_package_fixture() {
	local home_dir="$1"
	local repo_dir="$2"
	local second_repo_dir="${repo_dir}-two"
	local repos_tmp="${home_dir}/.config/aidevops/repos.tmp.json"
	write_fixture "$home_dir" "$repo_dir"
	mkdir -p "$second_repo_dir"
	cp "${repo_dir}/CloudronManifest.json" "${second_repo_dir}/CloudronManifest.json"
	jq --arg path "$second_repo_dir" '
		.initialized_repos += [(.initialized_repos[0]
			| .slug = "exampleorg/example-package-two"
			| .path = $path
			| .cloudron_package.upstream_slug = "exampleorg/upstream-two")]
	' "${home_dir}/.config/aidevops/repos.json" >"$repos_tmp"
	mv "$repos_tmp" "${home_dir}/.config/aidevops/repos.json"
	return 0
}

test_monitor_deduplicates_and_preserves_source() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/package"
	local bin_dir="${TEST_ROOT}/bin"
	local log_file="${TEST_ROOT}/issues.log"
	local api_log="${TEST_ROOT}/api.log"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	local manifest_before=""
	manifest_before=$(cksum "${repo_dir}/CloudronManifest.json")

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_LOG="$api_log" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "new upstream release creates one target-local issue"
	assert_equal 1 "$(grep -c '^TITLE Example Package upstream v2.0.0 is available$' "$log_file")" "upstream issue title uses package manifest title"
	grep -Fq 'upstream-v2.0.0' "$log_file" && assert_equal true true "upstream issue carries stable fingerprint" || assert_equal true false "upstream issue carries stable fingerprint"
	grep -Fq -- '--paginate --jq .' "$api_log" && assert_equal true true "paginated release reads request page-delimited JSON" || assert_equal true false "paginated release reads request page-delimited JSON"
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "upstream monitor does not mutate manifest"

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL ' "$log_file")" "clean compatibility check creates no issue"
	printf 'FROM cloudron/base:5.1.0\n' >"${repo_dir}/Dockerfile"
	local docker_before=""
	docker_before=$(cksum "${repo_dir}/Dockerfile")
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 2 "$(grep -c '^CALL ' "$log_file")" "compatibility finding is deduplicated"
	assert_equal "$docker_before" "$(cksum "${repo_dir}/Dockerfile")" "compatibility monitor does not mutate package source"
	return 0
}

test_monitor_selects_configured_stream() {
	local home_dir="${TEST_ROOT}/stream-home"
	local repo_dir="${TEST_ROOT}/stream-package"
	local bin_dir="${TEST_ROOT}/stream-bin"
	local log_file="${TEST_ROOT}/stream-issues.log"
	local releases_file="${TEST_ROOT}/stream-releases.json"
	local config_tmp="${TEST_ROOT}/stream-repos.json"
	local manifest_tmp="${TEST_ROOT}/stream-manifest.json"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_tag_prefixes = ["desktop-v"]' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"
	jq '.upstreamVersion = "0.5.0"' "${repo_dir}/CloudronManifest.json" >"$manifest_tmp"
	mv "$manifest_tmp" "${repo_dir}/CloudronManifest.json"
	cat >"$releases_file" <<'JSON'
[
  {"tag_name":"desktop-v0.5.2","draft":false,"prerelease":false},
  {"tag_name":"v99.0.0","draft":false,"prerelease":false},
  {"tag_name":"desktop-v0.5.3","draft":false,"prerelease":false},
  {"tag_name":"desktop-v9.0.0","draft":true,"prerelease":false},
  {"tag_name":"desktop-v8.0.0","draft":false,"prerelease":true}
]
JSON

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		MONITOR_RELEASES_FILE="$releases_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "configured stream creates one issue"
	assert_equal 1 "$(grep -c '^TITLE Example Package upstream v0.5.3 is available$' "$log_file")" "configured prefix selects highest matching stable tag"
	assert_equal 0 "$(grep -c '^TITLE Example Package upstream v99.0.0 is available$' "$log_file" || true)" "configured prefix rejects numerically larger unrelated stream"
	return 0
}

test_monitor_rejects_malformed_prefixes() {
	local home_dir="${TEST_ROOT}/prefix-home"
	local repo_dir="${TEST_ROOT}/prefix-package"
	local bin_dir="${TEST_ROOT}/prefix-bin"
	local log_file="${TEST_ROOT}/prefix-issues.log"
	local config_tmp="${TEST_ROOT}/prefix-repos.json"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_tag_prefixes = []' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"

	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "empty upstream tag-prefix array fails closed"
	[[ "$output" == *"upstream_tag_prefixes for exampleorg/example-package must be a non-empty array of strings"* ]] &&
		assert_equal true true "malformed tag prefixes report actionable error" ||
		assert_equal true false "malformed tag prefixes report actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "malformed tag prefixes create no issue" || assert_equal true false "malformed tag prefixes create no issue"
	return 0
}

test_monitor_rejects_control_characters_in_prefixes() {
	local home_dir="${TEST_ROOT}/control-prefix-home"
	local repo_dir="${TEST_ROOT}/control-prefix-package"
	local bin_dir="${TEST_ROOT}/control-prefix-bin"
	local log_file="${TEST_ROOT}/control-prefix-issues.log"
	local config_tmp="${TEST_ROOT}/control-prefix-repos.json"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.initialized_repos[0].cloudron_package.upstream_tag_prefixes = ["desktop-v\nv"]' \
		"${home_dir}/.config/aidevops/repos.json" >"$config_tmp"
	mv "$config_tmp" "${home_dir}/.config/aidevops/repos.json"

	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "control character in upstream tag prefix fails closed"
	[[ "$output" == *"upstream_tag_prefixes for exampleorg/example-package must be a non-empty array of strings; control characters are forbidden"* ]] &&
		assert_equal true true "control character prefix reports actionable error" ||
		assert_equal true false "control character prefix reports actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "control character prefix creates no issue" || assert_equal true false "control character prefix creates no issue"
	return 0
}

test_monitor_fails_closed_on_release_api_error() {
	local home_dir="${TEST_ROOT}/api-home"
	local repo_dir="${TEST_ROOT}/api-package"
	local bin_dir="${TEST_ROOT}/api-bin"
	local log_file="${TEST_ROOT}/api-issues.log"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" MONITOR_API_FAIL=true \
		CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "paginated release API failure fails closed"
	[[ "$output" == *"Could not fetch paginated GitHub releases for exampleorg/upstream"* ]] &&
		assert_equal true true "release API failure reports actionable error" ||
		assert_equal true false "release API failure reports actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "release API failure creates no issue" || assert_equal true false "release API failure creates no issue"
	return 0
}

assert_rate_limit_fixture() {
	local fixture="$1"
	local expected_status="$2"
	local expected_classification="$3"
	local case_root="${TEST_ROOT}/${fixture}"
	local home_dir="${case_root}/home"
	local repo_dir="${case_root}/package"
	local bin_dir="${case_root}/bin"
	local issue_log="${case_root}/issues.log"
	local api_log="${case_root}/api.log"
	local output=""
	local rc=0
	write_fake_commands "$bin_dir"
	write_two_package_fixture "$home_dir" "$repo_dir"
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$issue_log" MONITOR_API_LOG="$api_log" \
		MONITOR_RATE_FIXTURE="$fixture" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" \
		bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 75 "$rc" "${fixture} returns EX_TEMPFAIL"
	assert_equal 1 "$(grep -c '^API ' "$api_log")" "${fixture} stops before the second registration"
	[[ ! -f "$issue_log" ]] && assert_equal true true "${fixture} creates no issue" || assert_equal true false "${fixture} creates no issue"
	local cooldown_file="${home_dir}/.aidevops/cache/gh-secondary-cooldown.json"
	local state_shape=""
	state_shape=$(jq -r '[.diagnostic.http_status, .diagnostic.body_classification] | @tsv' "$cooldown_file")
	assert_equal "${expected_status}"$'\t'"${expected_classification}" "$state_shape" "${fixture} records shared cooldown evidence"
	[[ "$output" == *"DEFERRED: GitHub API cooldown active until epoch"* ]] &&
		assert_equal true true "${fixture} emits a machine-distinguishable safe status" ||
		assert_equal true false "${fixture} emits a machine-distinguishable safe status"
	return 0
}

test_monitor_rate_limit_fixtures() {
	assert_rate_limit_fixture primary-403-reset 403 primary-rate-limit
	assert_rate_limit_fixture secondary-403-retry 403 secondary-rate-limit
	assert_rate_limit_fixture primary-429-retry 429 rate-limit-message
	assert_rate_limit_fixture primary-429-reset 429 rate-limit-message
	return 0
}

test_monitor_scheduler_cooldown_integration() {
	local case_root="${TEST_ROOT}/scheduler-integration"
	local home_dir="${case_root}/home"
	local repo_dir="${case_root}/package"
	local bin_dir="${case_root}/bin"
	local issue_log="${case_root}/issues.log"
	local api_log="${case_root}/api.log"
	local state_file="${case_root}/routine-state.json"
	local pulse_log="${case_root}/pulse.log"
	local old_home="$HOME"
	local old_path="$PATH"
	local deferred_until=0
	local blocked_rc=0
	local eligible_count=0
	local iteration=0
	write_fake_commands "$bin_dir"
	write_two_package_fixture "$home_dir" "$repo_dir"
	mkdir -p "${home_dir}/.aidevops/agents/scripts"
	cat >"${home_dir}/.aidevops/agents/scripts/rate-monitor.sh" <<WRAPPER
#!/usr/bin/env bash
exec bash "$HELPER" upstream --apply
WRAPPER
	chmod +x "${home_dir}/.aidevops/agents/scripts/rate-monitor.sh"

	export HOME="$home_dir"
	export PATH="${bin_dir}:${old_path}"
	export MONITOR_TEST_LOG="$issue_log"
	export MONITOR_API_LOG="$api_log"
	export MONITOR_RATE_FIXTURE=primary-403-reset
	export CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue"
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${home_dir}/.aidevops/cache/gh-secondary-cooldown.json"
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE="${home_dir}/.aidevops/cache/gh-cooldown-events.jsonl"
	export AIDEVOPS_ROUTINE_NOW_EPOCH=9999999900
	export AIDEVOPS_ROUTINE_COOLDOWN_JITTER_MAX_SECONDS=7
	unset _SHARED_GH_SECONDARY_COOLDOWN_LOADED _PULSE_ROUTINES_LOADED
	# shellcheck source=../shared-gh-secondary-cooldown.sh
	source "$GH_COOLDOWN"
	ROUTINE_STATE_FILE="$state_file"
	LOGFILE="$pulse_log"
	ROUTINE_LOG_HELPER="${case_root}/missing-routine-log-helper"
	# shellcheck source=../pulse-routines.sh
	source "$PULSE_ROUTINES"

	_routine_execute r916 "Cloudron packages" scripts/rate-monitor.sh "" "$case_root"
	deferred_until=$(jq -r '.r916.deferred_until' "$state_file")
	assert_equal deferred "$(jq -r '.r916.last_status' "$state_file")" "rate-limited monitor is classified as deferred"
	[[ "$deferred_until" -ge 9999999999 && "$deferred_until" -le 10000000006 ]] &&
		assert_equal true true "scheduler persists reset plus bounded jitter" ||
		assert_equal true false "scheduler persists reset plus bounded jitter"
	assert_equal 1 "$(grep -c '^API ' "$api_log")" "integrated monitor touches only the first registration"

	AIDEVOPS_ROUTINE_NOW_EPOCH=$((deferred_until - 1))
	blocked_rc=0
	_routine_retry_blocked r916 || blocked_rc=$?
	assert_equal 0 "$blocked_rc" "deferred routine remains blocked before eligibility"
	AIDEVOPS_ROUTINE_NOW_EPOCH="$deferred_until"
	for iteration in 1 2; do
		blocked_rc=0
		_routine_retry_blocked r916 || blocked_rc=$?
		if [[ "$blocked_rc" -ne 0 ]]; then
			eligible_count=$((eligible_count + 1))
			_routine_update_state r916 running
		fi
	done
	assert_equal 1 "$eligible_count" "exactly one retry becomes eligible after cooldown expiry"

	export HOME="$old_home"
	export PATH="$old_path"
	unset MONITOR_TEST_LOG MONITOR_API_LOG MONITOR_RATE_FIXTURE CLOUDRON_PACKAGE_ISSUE_WRAPPER \
		AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE \
		AIDEVOPS_ROUTINE_NOW_EPOCH AIDEVOPS_ROUTINE_COOLDOWN_JITTER_MAX_SECONDS
	return 0
}

test_monitor_rejects_blank_package_title() {
	local home_dir="${TEST_ROOT}/blank-title-home"
	local repo_dir="${TEST_ROOT}/blank-title-package"
	local bin_dir="${TEST_ROOT}/blank-title-bin"
	local log_file="${TEST_ROOT}/blank-title-issues.log"
	local manifest_tmp="${TEST_ROOT}/blank-title-manifest.json"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	jq '.title = ""' "${repo_dir}/CloudronManifest.json" >"$manifest_tmp"
	mv "$manifest_tmp" "${repo_dir}/CloudronManifest.json"
	local output=""
	local rc=0
	if output=$(HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply 2>&1); then
		rc=0
	else
		rc=$?
	fi
	assert_equal 1 "$rc" "blank package title fails closed"
	[[ "$output" == *"Manifest title is missing or blank for registered Cloudron package exampleorg/example-package."* ]] && assert_equal true true "blank package title reports actionable error" || assert_equal true false "blank package title reports actionable error"
	[[ ! -f "$log_file" ]] && assert_equal true true "blank package title creates no issue" || assert_equal true false "blank package title creates no issue"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_monitor_deduplicates_and_preserves_source
	test_monitor_selects_configured_stream
	test_monitor_rejects_malformed_prefixes
	test_monitor_rejects_control_characters_in_prefixes
	test_monitor_fails_closed_on_release_api_error
	test_monitor_rate_limit_fixtures
	test_monitor_scheduler_cooldown_integration
	test_monitor_rejects_blank_package_title
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
