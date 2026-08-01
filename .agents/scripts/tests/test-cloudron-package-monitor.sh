#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../cloudron-package-monitor-helper.sh"
TEST_ROOT=""
PASSED=0
FAILED=0
PINNED_BASE='cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c'

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
if [[ "${1:-}" == "api" && "${2:-}" == repos/*/releases\?per_page=100 && "${3:-}" == "--paginate" ]]; then
    [[ "${MONITOR_API_FAIL:-false}" != true ]] || exit 1
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

test_monitor_deduplicates_and_preserves_source() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/package"
	local bin_dir="${TEST_ROOT}/bin"
	local log_file="${TEST_ROOT}/issues.log"
	write_fake_commands "$bin_dir"
	write_fixture "$home_dir" "$repo_dir"
	local manifest_before=""
	manifest_before=$(cksum "${repo_dir}/CloudronManifest.json")

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" upstream --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL exampleorg/example-package$' "$log_file")" "new upstream release creates one target-local issue"
	assert_equal 1 "$(grep -c '^TITLE Example Package upstream v2.0.0 is available$' "$log_file")" "upstream issue title uses package manifest title"
	grep -Fq 'upstream-v2.0.0' "$log_file" && assert_equal true true "upstream issue carries stable fingerprint" || assert_equal true false "upstream issue carries stable fingerprint"
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "upstream monitor does not mutate manifest"

	HOME="$home_dir" PATH="${bin_dir}:$PATH" MONITOR_TEST_LOG="$log_file" CLOUDRON_PACKAGE_ISSUE_WRAPPER="${bin_dir}/gh_create_issue" bash "$HELPER" compatibility --apply >/dev/null
	assert_equal 1 "$(grep -c '^CALL ' "$log_file")" "clean compatibility check creates no issue"
	printf 'FROM cloudron/base:5.0.0\n' >"${repo_dir}/Dockerfile"
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
	test_monitor_rejects_blank_package_title
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
