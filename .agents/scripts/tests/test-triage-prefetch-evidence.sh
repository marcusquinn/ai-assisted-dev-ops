#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2886: Unit tests for evidence-verification prefetch sections added to
# pulse-ancillary-dispatch.sh (_triage_fetch_evidence_sections +
# the three new sections in _triage_write_prompt_file).
#
# What this guards:
#   - _triage_fetch_evidence_sections populates merged-PRs without placing
#     public issue-title keywords in process arguments.
#   - _triage_fetch_evidence_sections populates recent-commits variable
#     from the same pinned revision used for cited-file content.
#   - _triage_fetch_evidence_sections populates file-contents variable
#     from an immutable committed blob at the cited line (±5-line window).
#   - _triage_write_prompt_file includes the canonical review fields and all
#     three <!-- prefetch:section=NAME --> markers in the output file.
#   - Empty repo_path is handled gracefully (fallback messages used).
#   - Traversal, final symlinks, and symlinked parent directories cannot read
#     files outside the repository revision.
#   - Worktree replacement after revision capture cannot alter cited evidence.
#
# Harness style: mocked gh/git, isolated HOME, fixture files.
# Pattern from test-triage-output-shape.sh.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
LOGFILE=""
readonly PUBLIC_REVISION_PLACEHOLDER="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_PAD_TRIAGE_MAX_PROMPT_COMMENT_BYTES=8192
_PAD_TRIAGE_MAX_CITED_BLOB_BYTES=1048576
_PAD_TRIAGE_MAX_CITED_SNIPPET_BYTES=16384
_PAD_TRIAGE_MAX_FILE_EVIDENCE_BYTES=65536
_PAD_TRIAGE_MAX_PUBLIC_HISTORY_BYTES=65536
_PAD_TRIAGE_MAX_PR_FILES_BYTES=65536
_PAD_TRIAGE_MAX_PROMPT_BYTES=2097152

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
	unset -f gh git 2>/dev/null || true
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	: >"$LOGFILE"
	return 0
}

teardown_test_env() {
	unset -f gh git 2>/dev/null || true
	export HOME="${ORIGINAL_HOME}"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

create_git_fixture_repo() {
	local repo_path="$1"
	mkdir -p "$repo_path"
	/usr/bin/git -C "$repo_path" init -q
	/usr/bin/git -C "$repo_path" config user.name "Triage Test"
	/usr/bin/git -C "$repo_path" config user.email "triage-test@example.invalid"
	return 0
}

commit_git_fixture() {
	local repo_path="$1"
	local commit_message="$2"
	/usr/bin/git -C "$repo_path" add -A
	/usr/bin/git -C "$repo_path" -c commit.gpgSign=false commit -q -m "$commit_message"
	return 0
}

# Load evidence helpers from the focused production libraries and retain a
# narrow extraction for the complexity-identity function in the orchestrator.
load_evidence_helpers() {
	local core_src evidence_src orchestrator_src
	local here
	here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	orchestrator_src="${AIDEVOPS_SOURCE:-${here}/../pulse-ancillary-dispatch.sh}"
	core_src="$(dirname "$orchestrator_src")/pulse-ancillary-dispatch-core.sh"
	evidence_src="$(dirname "$orchestrator_src")/pulse-ancillary-dispatch-evidence.sh"
	if [[ ! -f "$orchestrator_src" || ! -f "$core_src" || ! -f "$evidence_src" ]]; then
		printf 'ERROR: cannot locate pulse-ancillary-dispatch.sh (tried %s)\n' \
			"$orchestrator_src" >&2
		exit 2
	fi
	# Load managed-temp primitives and the focused helper modules, then extract
	# only the retained prompt-writer function from the orchestrator.
	# shellcheck source=../sensitive-temp-helper.sh
	source "${here}/../sensitive-temp-helper.sh"
	# shellcheck source=../pulse-ancillary-dispatch-core.sh
	source "$core_src"
	# shellcheck source=../pulse-ancillary-dispatch-evidence.sh
	source "$evidence_src"
	# Keep this focused harness isolated from scanner and retry side effects that
	# are covered by test-triage-security-gate.sh.
	_triage_untrusted_content_is_safe() { return 0; }
	_triage_mark_infrastructure_retry() { return 0; }
	local tmp
	tmp=$(mktemp)
	awk '/^_triage_write_prompt_file\(\) \{/{flag=1} flag{print} flag && /^}$/{exit}' \
		"$orchestrator_src" >"$tmp"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	return 0
}

# Stub gh_issue_list so _triage_write_prompt_file can fetch recent_closed
# without real network access.
# shellcheck disable=SC2317
gh_issue_list() { printf 'Stub closed issue 1\nStub closed issue 2\n'; return 0; }
export -f gh_issue_list

# Public-content scanning is covered adversarially in
# test-triage-security-gate.sh. This focused extraction harness does not load
# the scanner helpers that precede the evidence cluster.
_triage_untrusted_content_is_safe() { return 0; }
export -f _triage_untrusted_content_is_safe

_triage_mark_infrastructure_retry() { return 0; }
export -f _triage_mark_infrastructure_retry

run_cited_evidence_status() {
	local fixture_kind="$1"
	local issue_body="$2"
	local cited_history=""
	setup_test_env
	gh() {
		[[ "$*" != *"path=scripts/large.sh"* ]] || \
			printf '%s\n' "$cited_history"
		return 0
	}
	export -f gh

	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	case "$fixture_kind" in
	oversized-blob) python3 -c 'print("x" * 1048577, end="")' >"${fake_repo}/scripts/large.sh" ;;
	oversized-history)
		printf '%s\n' 'safe content' >"${fake_repo}/scripts/large.sh"
		cited_history=$(python3 -c 'print("x" * 65537, end="")')
		;;
	multibyte-line) python3 -c 'print("é" * 9000, end="")' >"${fake_repo}/scripts/large.sh" ;;
	repeated-citation) python3 -c 'print("x" * 8000, end="")' >"${fake_repo}/scripts/large.sh" ;;
	*) teardown_test_env; return 1 ;;
	esac
	commit_git_fixture "$fake_repo" "test: add bounded evidence fixture"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')
	load_evidence_helpers

	local issue_json='{"title":"bounded evidence","createdAt":"2000-01-01T00:00:00Z"}'
	local merged_prs="" recent_commits="" file_contents=""
	local fetch_status=0
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents" || fetch_status=$?
	teardown_test_env
	printf '%s\n' "$fetch_status"
	return 0
}

# ------------------------------ Tests ------------------------------

test_fetch_evidence_populates_merged_prs() {
	setup_test_env

	local gh_call_log="${TEST_ROOT}/gh-calls.log"
	: >"$gh_call_log"
	# Mock gh to return one recent merged PR and retain argv for inspection.
	gh() {
		printf '%s\n' "$*" >>"${TEST_ROOT}/gh-calls.log"
		case "${1:-}" in
		pr)
			case "${2:-}" in
			list)
				printf '#9001 fix: correct line count (merged: 2026-04-20T10:00:00Z)\n'
				return 0
				;;
			esac
			;;
		esac
		return 0
	}
	export -f gh

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"PUBLIC_TITLE_ARGV_SENTINEL fix line count logic","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="See scripts/foo.sh:42 for the problem."

	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "" "$PUBLIC_REVISION_PLACEHOLDER" \
		"merged_prs" "recent_commits" "file_contents"

	if grep -qE -- '--search|PUBLIC_TITLE_ARGV_SENTINEL' "$gh_call_log"; then
		print_result \
			"_triage_fetch_evidence_sections populates merged-PRs without public title argv" 1 \
			"public title entered argv: $(<"$gh_call_log")"
	elif [[ "$merged_prs" == *"#9001"* && "$merged_prs" == *"fix: correct line count"* ]]; then
		print_result \
			"_triage_fetch_evidence_sections populates merged-PRs without public title argv" 0
	else
		print_result \
			"_triage_fetch_evidence_sections populates merged-PRs without public title argv" 1 \
			"merged_prs='$merged_prs'"
	fi
	teardown_test_env
}

test_fetch_evidence_populates_recent_commits() {
	setup_test_env

	local gh_call_log="${TEST_ROOT}/gh-calls.log"
	: >"$gh_call_log"
	gh() {
		printf '%s\n' "$*" >>"${TEST_ROOT}/gh-calls.log"
		if [[ "$*" == *"repos/owner/repo/commits"* && \
			"$*" == *"path=scripts/foo.sh"* ]]; then
			printf '%s\n' 'abc1234 fix: update foo.sh logic'
		fi
		return 0
	}
	export -f gh

	# Create a committed fixture so file content and API history share one SHA.
	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\n' \
		>"${fake_repo}/scripts/foo.sh"
	commit_git_fixture "$fake_repo" "fix: update foo.sh logic"

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"update foo logic","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="Issue at scripts/foo.sh:5"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')

	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$recent_commits" == *"fix: update foo.sh logic"* && \
		"$recent_commits" == *" @ "* ]] && \
		grep -qF -- "sha=${public_revision} -f path=scripts/foo.sh" "$gh_call_log"; then
		print_result \
			"_triage_fetch_evidence_sections populates recent-commits from GitHub" 0
	else
		print_result \
			"_triage_fetch_evidence_sections populates recent-commits from GitHub" 1 \
			"recent_commits='$recent_commits'"
	fi
	teardown_test_env
}

test_fetch_evidence_populates_file_contents() {
	setup_test_env

	gh() { return 0; }
	export -f gh

	# Create a committed fixture containing known content at line 5.
	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\n' \
		>"${fake_repo}/scripts/fixture.sh"
	commit_git_fixture "$fake_repo" "test: add immutable fixture"

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"check fixture content","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="Problem at scripts/fixture.sh:5"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')

	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents"

	# Line 5 is "epsilon"; the ±5 window (lines 1-10) should include it.
	if [[ "$file_contents" == *"epsilon"* && \
		"$file_contents" == *"scripts/fixture.sh @ "* ]]; then
		print_result \
			"_triage_fetch_evidence_sections populates file-contents from fixture" 0
	else
		print_result \
			"_triage_fetch_evidence_sections populates file-contents from fixture" 1 \
			"file_contents='$file_contents'"
	fi
	teardown_test_env
}

test_prompt_file_contains_prefetch_markers() {
	setup_test_env

	# Stub all external calls needed by _triage_write_prompt_file
	gh() { return 0; }
	export -f gh

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"test markers","createdAt":"2026-04-01T00:00:00Z","number":1}'
	local issue_body="Test issue body with no file refs."
	local canonical_review_file
	canonical_review_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../workflows/triage-review.md"
	local canonical_pr_disposition
	canonical_pr_disposition=$(grep '^- \*\*PR disposition:\*\*' "$canonical_review_file")
	local canonical_guidance
	canonical_guidance=$(grep '^- \*\*Implementation guidance:\*\*' "$canonical_review_file")

	local prompt_file
	prompt_file=$(_triage_write_prompt_file \
		"1" "owner/repo" "" "$issue_json" "$issue_body" "[]" "" "[]" "" \
		"" "" "$PUBLIC_REVISION_PLACEHOLDER")

	local ok=0
	grep -q '<!-- prefetch:section=recent-merged-prs -->' \
		"$prompt_file" || ok=1
	grep -q '<!-- prefetch:section=recent-commits-on-cited-files -->' \
		"$prompt_file" || ok=1
	grep -q '<!-- prefetch:section=cited-file-contents -->' \
		"$prompt_file" || ok=1
	grep -qF -- "$canonical_pr_disposition" "$prompt_file" || ok=1
	grep -qF -- "$canonical_guidance" "$prompt_file" || ok=1

	_triage_cleanup_sensitive_artifact_dir "${prompt_file%/*}" || ok=1

	if [[ "$ok" -eq 0 ]]; then
		print_result \
			"_triage_write_prompt_file includes canonical fields and prefetch markers" 0
	else
		print_result \
			"_triage_write_prompt_file includes canonical fields and prefetch markers" 1 \
			"one or more canonical fields or prefetch markers missing from prompt file"
	fi
	teardown_test_env
}

test_fetch_evidence_no_repo_path_graceful() {
	setup_test_env

	gh() { return 0; }
	export -f gh

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"no repo path test","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="See scripts/foo.sh:10 for details."

	local merged_prs="" recent_commits="" file_contents=""
	# repo_path is empty — git and file operations must be skipped gracefully
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "" "$PUBLIC_REVISION_PLACEHOLDER" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$recent_commits" == *"No recent commits"* && \
		"$file_contents" == *"not available locally"* ]]; then
		print_result \
			"_triage_fetch_evidence_sections handles empty repo_path gracefully" 0
	else
		print_result \
			"_triage_fetch_evidence_sections handles empty repo_path gracefully" 1 \
			"recent_commits='$recent_commits' file_contents='$file_contents'"
	fi
	teardown_test_env
}

test_fetch_evidence_rejects_traversal_and_symlinks() {
	setup_test_env

	gh() { return 0; }
	export -f gh

	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	local outside_file="${TEST_ROOT}/outside-secret.txt"
	printf '%s\n' 'OUTSIDE_SECRET_SENTINEL' >"$outside_file"
	ln -s "$outside_file" "${fake_repo}/linked-secret.txt"
	local outside_dir="${TEST_ROOT}/outside-dir"
	mkdir -p "$outside_dir"
	printf '%s\n' 'PARENT_SYMLINK_SECRET_SENTINEL' >"${outside_dir}/nested.txt"
	ln -s "$outside_dir" "${fake_repo}/linked-dir"
	commit_git_fixture "$fake_repo" "test: add symlink fixtures"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')

	load_evidence_helpers

	local issue_json='{"title":"unsafe citations","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="See ../outside-secret.txt:1, linked-secret.txt:1, and linked-dir/nested.txt:1"
	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$file_contents" != *"OUTSIDE_SECRET_SENTINEL"* && \
		"$file_contents" != *"PARENT_SYMLINK_SECRET_SENTINEL"* && \
		"$file_contents" == *"not available locally"* ]]; then
		print_result "evidence prefetch rejects traversal and symlink citations" 0
	else
		print_result "evidence prefetch rejects traversal and symlink citations" 1 \
			"file_contents='$file_contents'"
	fi
	teardown_test_env
}

test_fetch_evidence_excludes_unpublished_head() {
	setup_test_env

	gh() { return 0; }
	export -f gh

	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	printf '%s\n' 'SAFE_PUBLIC_CONTENT' >"${fake_repo}/scripts/public.sh"
	commit_git_fixture "$fake_repo" "test: public commit"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')
	local public_blob=""
	public_blob=$(/usr/bin/git -C "$fake_repo" rev-parse \
		"${public_revision}:scripts/public.sh")
	printf '%s\n' 'UNPUBLISHED_LOCAL_CONTENT_SENTINEL' >"${fake_repo}/scripts/public.sh"
	commit_git_fixture "$fake_repo" "UNPUBLISHED_LOCAL_COMMIT_SENTINEL"
	local unpublished_revision=""
	unpublished_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')
	local unpublished_blob=""
	unpublished_blob=$(/usr/bin/git -C "$fake_repo" rev-parse \
		"${unpublished_revision}:scripts/public.sh")
	/usr/bin/git -C "$fake_repo" replace "$public_revision" "$unpublished_revision"
	/usr/bin/git -C "$fake_repo" replace "$public_blob" "$unpublished_blob"

	load_evidence_helpers
	local issue_json='{"title":"public revision pin","createdAt":"2000-01-01T00:00:00Z"}'
	local issue_body="Inspect scripts/public.sh:1"
	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$file_contents" == *"SAFE_PUBLIC_CONTENT"* && \
		"$file_contents" != *"UNPUBLISHED_LOCAL_CONTENT_SENTINEL"* && \
		"$recent_commits" != *"UNPUBLISHED_LOCAL_COMMIT_SENTINEL"* ]]; then
		print_result "evidence prefetch excludes unpublished HEAD and replacement objects" 0
	else
		print_result "evidence prefetch excludes unpublished HEAD and replacement objects" 1 \
			"recent_commits='$recent_commits' file_contents='$file_contents'"
	fi
	teardown_test_env
}

test_fetch_evidence_ignores_local_grafts() {
	setup_test_env
	gh() {
		[[ "$*" != *"path=scripts/public.sh"* ]] || \
			printf '%s\n' 'abc1234 GITHUB_PUBLIC_HISTORY_SENTINEL'
		return 0
	}
	export -f gh
	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	printf '%s\n' 'SAFE_PUBLIC_CONTENT' >"${fake_repo}/scripts/public.sh"
	commit_git_fixture "$fake_repo" "test: public graft anchor"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')
	printf '%s\n' 'UNPUBLISHED_GRAFT_CONTENT_SENTINEL' >"${fake_repo}/scripts/public.sh"
	/usr/bin/git -C "$fake_repo" add -A
	local graft_tree="" graft_revision=""
	graft_tree=$(/usr/bin/git -C "$fake_repo" write-tree)
	graft_revision=$(printf '%s\n' 'UNPUBLISHED_GRAFT_HISTORY_SENTINEL' \
		| /usr/bin/git -C "$fake_repo" commit-tree "$graft_tree")
	mkdir -p "${fake_repo}/.git/info"
	printf '%s %s\n' "$public_revision" "$graft_revision" \
		>"${fake_repo}/.git/info/grafts"

	load_evidence_helpers
	local issue_json='{"title":"graft isolation","createdAt":"2000-01-01T00:00:00Z"}'
	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"Inspect scripts/public.sh:1" "$issue_json" "owner/repo" \
		"$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents"
	if [[ "$recent_commits" == *"GITHUB_PUBLIC_HISTORY_SENTINEL"* && \
		"$recent_commits" != *"UNPUBLISHED_GRAFT_HISTORY_SENTINEL"* && \
		"$file_contents" == *"SAFE_PUBLIC_CONTENT"* && \
		"$file_contents" != *"UNPUBLISHED_GRAFT_CONTENT_SENTINEL"* ]]; then
		print_result "evidence prefetch ignores local graft ancestry" 0
	else
		print_result "evidence prefetch ignores local graft ancestry" 1 \
			"recent_commits='$recent_commits' file_contents='$file_contents'"
	fi
	teardown_test_env
	return 0
}

test_fetch_evidence_ignores_shallow_boundaries() {
	setup_test_env
	gh() {
		[[ "$*" != *"path=scripts/public.sh"* ]] || \
			printf '%s\n' 'abc1234 PUBLIC_OLDER_HISTORY_SENTINEL'
		return 0
	}
	export -f gh
	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	printf '%s\n' 'SAFE_OLDER_CONTENT' >"${fake_repo}/scripts/public.sh"
	commit_git_fixture "$fake_repo" "PUBLIC_OLDER_HISTORY_SENTINEL"
	printf '%s\n' 'SAFE_CURRENT_CONTENT' >"${fake_repo}/scripts/public.sh"
	commit_git_fixture "$fake_repo" "test: current public revision"
	local public_revision=""
	public_revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')
	printf '%s\n' "$public_revision" >"${fake_repo}/.git/shallow"

	load_evidence_helpers
	local issue_json='{"title":"shallow isolation","createdAt":"2000-01-01T00:00:00Z"}'
	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"Inspect scripts/public.sh:1" "$issue_json" "owner/repo" \
		"$fake_repo" "$public_revision" \
		"merged_prs" "recent_commits" "file_contents"
	if [[ "$recent_commits" == *"PUBLIC_OLDER_HISTORY_SENTINEL"* && \
		"$file_contents" == *"SAFE_CURRENT_CONTENT"* ]]; then
		print_result "evidence prefetch ignores shallow history boundaries" 0
	else
		print_result "evidence prefetch ignores shallow history boundaries" 1 \
			"recent_commits='$recent_commits' file_contents='$file_contents'"
	fi
	teardown_test_env
	return 0
}

test_cited_evidence_byte_bounds() {
	local status=""
	status=$(run_cited_evidence_status \
		"oversized-blob" "Inspect scripts/large.sh:1")
	if [[ "$status" == "2" ]]; then
		print_result "oversized cited blobs fail closed" 0
	else
		print_result "oversized cited blobs fail closed" 1 "status=${status}"
	fi
	status=$(run_cited_evidence_status \
		"oversized-history" "Inspect scripts/large.sh:1")
	if [[ "$status" == "2" ]]; then
		print_result "oversized cited-file public history fails closed" 0
	else
		print_result "oversized cited-file public history fails closed" 1 \
			"status=${status}"
	fi
	status=$(run_cited_evidence_status \
		"multibyte-line" "Inspect scripts/large.sh:1")
	if [[ "$status" == "2" ]]; then
		print_result "multibyte cited snippets use byte bounds" 0
	else
		print_result "multibyte cited snippets use byte bounds" 1 "status=${status}"
	fi
	local repeated_body=""
	local index
	for index in 1 2 3 4 5 6 7 8 9 10; do
		repeated_body+=" Inspect scripts/large.sh:1"
	done
	status=$(run_cited_evidence_status "repeated-citation" "$repeated_body")
	if [[ "$status" == "2" ]]; then
		print_result "repeated citations respect aggregate evidence bounds" 0
	else
		print_result "repeated citations respect aggregate evidence bounds" 1 \
			"status=${status}"
	fi
	return 0
}

test_fetch_evidence_rejects_post_validation_symlink_swap() {
	setup_test_env

	local fake_repo="${TEST_ROOT}/repo"
	create_git_fixture_repo "$fake_repo"
	mkdir -p "${fake_repo}/scripts"
	local race_target="${fake_repo}/scripts/race.sh"
	local outside_file="${TEST_ROOT}/race-secret.txt"
	printf '%s\n' 'SAFE_TRACKED_CONTENT' >"$race_target"
	printf '%s\n' 'RACE_SECRET_SENTINEL' >"$outside_file"
	commit_git_fixture "$fake_repo" "test: add race fixture"

	load_evidence_helpers
	local revision=""
	revision=$(/usr/bin/git -C "$fake_repo" rev-parse --verify 'HEAD^{commit}')
	rm -f "$race_target"
	ln -s "$outside_file" "$race_target"
	local file_contents=""
	file_contents=$(_triage_read_cited_file_window \
		"$fake_repo" "$revision" "scripts/race.sh" "1" "1")

	if [[ "$file_contents" == *"SAFE_TRACKED_CONTENT"* && \
		"$file_contents" != *"RACE_SECRET_SENTINEL"* ]]; then
		print_result "evidence prefetch reads the captured revision after worktree replacement" 0
	else
		print_result "evidence prefetch reads the captured revision after worktree replacement" 1 \
			"file_contents='$file_contents'"
	fi
	teardown_test_env
}

# ------------------------------ Main ------------------------------

main() {
	test_fetch_evidence_populates_merged_prs
	test_fetch_evidence_populates_recent_commits
	test_fetch_evidence_populates_file_contents
	test_prompt_file_contains_prefetch_markers
	test_fetch_evidence_no_repo_path_graceful
	test_fetch_evidence_rejects_traversal_and_symlinks
	test_fetch_evidence_rejects_post_validation_symlink_swap
	test_fetch_evidence_excludes_unpublished_head
	test_fetch_evidence_ignores_local_grafts
	test_fetch_evidence_ignores_shallow_boundaries
	test_cited_evidence_byte_bounds

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
