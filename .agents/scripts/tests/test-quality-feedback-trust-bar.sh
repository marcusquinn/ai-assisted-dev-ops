#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for quality-feedback dispatch authority in quality-feedback-issues-lib.sh
# (GH#17916 / t2686 / GH#29795).
#
# t2686 background: the pre-fix trust check used strict equality against
# repos.json .maintainer, which missed admin collaborators entirely. On
# exampleorg/examplerepo that stranded 10 quality-debt issues with NMR labels
# because co-admin PRs failed the single-maintainer equality test even
# though pulse-merge.sh auto-merge already trusts the same principals
# (t2411 criterion 2, t2449 criterion 2).
#
# Post-fix semantics:
#   - Trusted code-quality app findings authorize worker triage independently
#     of the merged source PR author
#   - Reviewer identities use an exact, fail-closed allowlist
#   - Stage 1: maintainer fast-path (repos.json .maintainer or slug owner)
#   - Stage 2: collaborator permission probe (admin/maintain/write → trusted)
#   - Fail-closed on API errors, read-only permission, unknown user
#
# This test never hits the real GitHub API — the `gh` CLI is stubbed via a
# shell script on PATH that serves fixture responses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
QF_SCRIPT="${SCRIPT_DIR}/../quality-feedback-issues-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	# Isolated repos.json (so test doesn't read host's real config).
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos":[{"slug":"exampleorg/examplerepo","maintainer":"marcusquinn"}]}\n' >"$REPOS_JSON"

	# Permission fixture: what the gh stub returns for any
	# repos/{slug}/collaborators/{user}/permission call.
	# Format: either a JSON blob, or the literal string "FAIL" to make
	# the gh stub exit non-zero (simulating 404/403/network error).
	export PERMISSION_FIXTURE="${TEST_ROOT}/permission.json"
	printf '{"permission":"none"}\n' >"$PERMISSION_FIXTURE"
	export AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE="${TEST_ROOT}/trusted-code-quality-bots.txt"
	printf '%s\n' 'coderabbitai[bot]' 'codacy-production[bot]' >"$AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE"

	# gh stub — only collaborators/{user}/permission is needed.
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	path="${2:-}"
	if [[ "$path" == "-i" ]]; then
		path="${3:-}"
		if [[ "$path" == */collaborators/*/permission ]]; then
			if [[ "$(cat "$PERMISSION_FIXTURE")" == "FAIL" ]]; then
				printf 'HTTP/2.0 403 Forbidden\n\n{"message":"Forbidden"}\n'
				exit 1
			fi
			printf 'HTTP/2.0 200 OK\n\n'
			cat "$PERMISSION_FIXTURE"
			exit 0
		fi
	fi
	jq_filter=""
	shift 2 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--jq) jq_filter="$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	if [[ "$path" == */collaborators/*/permission ]]; then
		# Contract: if fixture body is literally "FAIL", exit 1
		# so the helper sees a failed API call (fail-closed path).
		if [[ "$(cat "$PERMISSION_FIXTURE")" == "FAIL" ]]; then
			exit 1
		fi
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$PERMISSION_FIXTURE" 2>/dev/null || echo ""
		else
			cat "$PERMISSION_FIXTURE"
		fi
		exit 0
	fi
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	unset AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE
	return 0
}

set_permission_fixture() {
	# $1 — either a JSON blob like '{"permission":"admin"}' or the literal "FAIL"
	printf '%s\n' "$1" >"$PERMISSION_FIXTURE"
}

# Extract just the helper under test from quality-feedback-issues-lib.sh.
# Same awk-extract-and-eval pattern used by
# test-pulse-nmr-automation-signature.sh.
define_helpers_under_test() {
	local trust_src
	trust_src=$(awk '
		/^_quality_findings_are_trusted_automation\(\) \{/,/^}$/ { print }
		/^_is_maintainer_equivalent_author\(\) \{/,/^}$/ { print }
		/^_quality_feedback_dispatch_authorized\(\) \{/,/^}$/ { print }
	' "$QF_SCRIPT")
	if [[ -z "$trust_src" ]]; then
		printf 'ERROR: could not extract _is_maintainer_equivalent_author from %s\n' "$QF_SCRIPT" >&2
		return 1
	fi
	# shellcheck source=../github-app-auth-helper.sh
	source "${SCRIPT_DIR}/../github-app-auth-helper.sh"
	# shellcheck source=../shared-gh-wrappers-rest-fallback.sh
	source "${SCRIPT_DIR}/../shared-gh-wrappers-rest-fallback.sh"
	# shellcheck source=../shared-gh-collaborator-permission.sh
	source "${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"
	# shellcheck disable=SC1090
	eval "$trust_src"
	return 0
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

test_trusted_quality_apps_authorize_findings() {
	local findings='[{"reviewer_login":"coderabbitai[bot]"},{"reviewer_login":"codacy-production[bot]"}]'
	if _quality_findings_are_trusted_automation "$findings"; then
		print_result "trusted quality apps authorize generated worker triage (GH#29795)" 0
		return 0
	fi
	print_result "trusted quality apps authorize generated worker triage (GH#29795)" 1
	return 0
}

test_trusted_quality_app_on_dependency_pr_is_source_independent() {
	local findings='[{"reviewer_login":"coderabbitai[bot]"}]'
	set_permission_fixture '{"permission":"none"}'
	# The gh stub deliberately rejects `gh pr view`, so success proves the
	# trusted audit path never consults the dependency-bot source author.
	if _quality_feedback_dispatch_authorized "$findings" "exampleorg/examplerepo" "42"; then
		print_result "trusted audit authority does not depend on source PR author (GH#29795)" 0
		return 0
	fi
	print_result "trusted audit authority does not depend on source PR author (GH#29795)" 1
	return 0
}

test_mixed_or_lookalike_reviewers_fail_closed() {
	local mixed='[{"reviewer_login":"coderabbitai[bot]"},{"reviewer_login":"external-user"}]'
	local lookalike='[{"reviewer_login":"not-coderabbitai[bot]"}]'
	if ! _quality_findings_are_trusted_automation "$mixed" &&
		! _quality_findings_are_trusted_automation "$lookalike"; then
		print_result "mixed and lookalike reviewer identities fail closed (GH#29795)" 0
		return 0
	fi
	print_result "mixed and lookalike reviewer identities fail closed (GH#29795)" 1
	return 0
}

test_missing_quality_app_allowlist_fails_closed() {
	local findings='[{"reviewer_login":"coderabbitai[bot]"}]'
	local saved_trust_file="$AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE"
	AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE="${TEST_ROOT}/missing-trust-file"
	if ! _quality_findings_are_trusted_automation "$findings"; then
		AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE="$saved_trust_file"
		print_result "missing quality-app allowlist fails closed (GH#29795)" 0
		return 0
	fi
	AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE="$saved_trust_file"
	print_result "missing quality-app allowlist fails closed (GH#29795)" 1
	return 0
}

test_maintainer_fast_path_matches() {
	# Stage 1: PR author matches repos.json .maintainer → trusted, no API call.
	# repos.json already has exampleorg/examplerepo -> maintainer=marcusquinn
	# We also set permission fixture to FAIL so the test confirms we NEVER
	# reach stage 2 (fast path short-circuits).
	set_permission_fixture "FAIL"
	if _is_maintainer_equivalent_author "marcusquinn" "exampleorg/examplerepo"; then
		print_result "maintainer fast-path matches without API call (t2686)" 0
		return 0
	fi
	print_result "maintainer fast-path matches without API call (t2686)" 1 \
		"Expected exit 0 for repos.json .maintainer match"
	return 0
}

test_admin_collaborator_is_trusted() {
	# Stage 2: non-maintainer author, but gh api returns admin permission.
	# This is the canonical t2686 case — alex-solovyev on example-repo.
	set_permission_fixture '{"permission":"admin"}'
	if _is_maintainer_equivalent_author "alex-solovyev" "exampleorg/examplerepo"; then
		print_result "admin collaborator treated as maintainer-equivalent (t2686)" 0
		return 0
	fi
	print_result "admin collaborator treated as maintainer-equivalent (t2686)" 1 \
		"Expected exit 0 — admin permission is maintainer-equivalent"
	return 0
}

test_maintain_collaborator_is_trusted() {
	# Stage 2: non-maintainer author with maintain permission. Matches the
	# pulse-merge.sh auto-merge trust bar (admin OR maintain).
	set_permission_fixture '{"permission":"maintain"}'
	if _is_maintainer_equivalent_author "co-maintainer" "exampleorg/examplerepo"; then
		print_result "maintain collaborator treated as maintainer-equivalent (t2686)" 0
		return 0
	fi
	print_result "maintain collaborator treated as maintainer-equivalent (t2686)" 1 \
		"Expected exit 0 — maintain permission is maintainer-equivalent"
	return 0
}

test_write_collaborator_is_trusted() {
	# Stage 2: write permission is authenticated repository authority. NMR is
	# reserved for external/read-only authors, not a higher maintainer-role bar.
	set_permission_fixture '{"permission":"write"}'
	if _is_maintainer_equivalent_author "contributor-dev" "exampleorg/examplerepo"; then
		print_result "write collaborator treated as repository-authorized (GH#29394)" 0
		return 0
	fi
	print_result "write collaborator treated as repository-authorized (GH#29394)" 1 \
		"Expected exit 0 — write permission satisfies the external-authority gate"
	return 0
}

test_api_failure_is_fail_closed() {
	# Stage 2: gh api call fails (404/403/network). The helper MUST
	# default to NOT trusted so NMR still applies. An unreachable API
	# is not a trust signal.
	set_permission_fixture "FAIL"
	if _is_maintainer_equivalent_author "random-user" "exampleorg/examplerepo"; then
		print_result "API failure fails closed (not trusted) (t2686)" 1 \
			"Expected exit 1 — API failure must default to NOT trusted"
		return 0
	fi
	print_result "API failure fails closed (not trusted) (t2686)" 0
	return 0
}

test_none_permission_is_not_trusted() {
	# Stage 2: user exists but has no permission on the repo.
	# gh api returns {"permission":"none"} — definitely not trusted.
	set_permission_fixture '{"permission":"none"}'
	if _is_maintainer_equivalent_author "stranger" "exampleorg/examplerepo"; then
		print_result "none permission NOT treated as maintainer-equivalent (t2686)" 1 \
			"Expected exit 1 — none permission must not be trusted"
		return 0
	fi
	print_result "none permission NOT treated as maintainer-equivalent (t2686)" 0
	return 0
}

test_empty_author_returns_nonzero() {
	# Defensive: empty pr_author (gh pr view failed upstream) must not
	# trust anyone.
	if _is_maintainer_equivalent_author "" "exampleorg/examplerepo"; then
		print_result "empty pr_author returns not-trusted (t2686)" 1 \
			"Expected exit 1 for empty pr_author"
		return 0
	fi
	print_result "empty pr_author returns not-trusted (t2686)" 0
	return 0
}

test_slug_owner_fallback_when_no_maintainer_field() {
	# When repos.json has no .maintainer field for this slug, the helper
	# falls back to the slug owner (everything before "/"). Confirm the
	# fallback works by pointing to a repo not in repos.json — author
	# matches "other-owner" from other-owner/other-repo.
	set_permission_fixture "FAIL" # prove we stop at stage 1, not stage 2
	if _is_maintainer_equivalent_author "other-owner" "other-owner/other-repo"; then
		print_result "slug-owner fallback when no .maintainer field (t2686)" 0
		return 0
	fi
	print_result "slug-owner fallback when no .maintainer field (t2686)" 1 \
		"Expected exit 0 — slug owner should be the fallback maintainer"
	return 0
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

main() {
	trap teardown_test_env EXIT
	setup_test_env
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_trusted_quality_apps_authorize_findings
	test_trusted_quality_app_on_dependency_pr_is_source_independent
	test_mixed_or_lookalike_reviewers_fail_closed
	test_missing_quality_app_allowlist_fails_closed
	test_maintainer_fast_path_matches
	test_admin_collaborator_is_trusted
	test_maintain_collaborator_is_trusted
	test_write_collaborator_is_trusted
	test_api_failure_is_fail_closed
	test_none_permission_is_not_trusted
	test_empty_author_returns_nonzero
	test_slug_owner_fallback_when_no_maintainer_field

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
