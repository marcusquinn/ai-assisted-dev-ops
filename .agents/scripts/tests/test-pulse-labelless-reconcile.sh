#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-labelless-reconcile.sh — coverage for the t2112 labelless
# aidevops issue backfill pass in pulse-issue-reconcile.sh, extended by
# t2450 to gate the backfill on `author_association`.
#
# Strategy: stub `gh` as a bash function (PATH-shadow won't work because the
# reconcile module runs with the pulse's prepended PATH) so we can intercept
# every call. Eight fixture issues:
#   #500 — aidevops-shaped + labelless + MEMBER author          (MUST be blessed internal)
#   #501 — non-aidevops shape (random bug title)                (MUST be ignored)
#   #502 — aidevops-shaped + already has origin:worker          (MUST be ignored)
#   #503 — aidevops-shaped + labelless + CONTRIBUTOR author     (MUST be gated external, t2450)
#   #504 — aidevops-shaped + labelless + NONE author, no tags   (MUST be gated external, t2450)
#   #505 — aidevops-shaped + labelless + read collaborator       (MUST be gated external)
#   #506 — aidevops-shaped + labelless + write collaborator      (MUST be blessed internal)
#   #507 — aidevops-shaped + labelless + trusted bot             (MUST be blessed internal)
#
# Assertions — internal path (unchanged from t2112):
#   - #500 edit adds origin:worker, tier:standard, and body tags (ai, security)
#   - #500 comment contains the INTERNAL sentinel (<!-- aidevops:labelless-backfill -->)
#   - #501/#502 neither edited nor commented
#
# Assertions — external path (t2450):
#   - #503/#504 edits add needs-maintainer-review; body tags still applied (#503)
#   - #503/#504 edits DO NOT add origin:worker, tier:simple, tier:standard, tier:thinking
#   - #503/#504 comments contain the EXTERNAL sentinel (labelless-backfill-external)

set -u

# shellcheck disable=SC2155
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly TEST_REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
readonly RECONCILE_SRC="${TEST_REPO_ROOT}/.agents/scripts/pulse-issue-reconcile.sh"

TEST_TMPDIR=$(mktemp -d /tmp/test-pulse-labelless.XXXXXX)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

TRACE_FILE="${TEST_TMPDIR}/gh-trace.log"
LOGFILE="${TEST_TMPDIR}/pulse-wrapper.log"
: >"$TRACE_FILE"
: >"$LOGFILE"
export TRACE_FILE LOGFILE

# -----------------------------------------------------------------------------
# Fake repos.json — one test/repo
# -----------------------------------------------------------------------------
REPOS_JSON="${TEST_TMPDIR}/repos.json"
cat >"$REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {"slug": "test/repo", "pulse": true, "local_only": false}
  ],
  "git_parent_dirs": []
}
JSON
export REPOS_JSON

# -----------------------------------------------------------------------------
# Fixture issues for the gh stub
# -----------------------------------------------------------------------------
FIXTURE_ISSUES_JSON=$(
	cat <<'JSON'
[
  {
    "number": 500,
    "title": "t325.2: feat: types + anonymizer",
    "body": "Shared types and LLM-based text anonymization module.\n\nBrief: `todo/tasks/t325.2-brief.md`\nParent: t325\n\n## Tags inline: #ai #security\n",
    "labels": []
  },
  {
    "number": 501,
    "title": "Flaky test in anonymizer suite",
    "body": "Sometimes fails on CI. Not aidevops-shaped.",
    "labels": []
  },
  {
    "number": 502,
    "title": "t325.3: feat: analyzer module",
    "body": "Already-blessed issue.",
    "labels": [{"name": "origin:worker"}, {"name": "tier:standard"}]
  },
  {
    "number": 503,
    "title": "t2548: Fix orphan-task-id bug",
    "body": "External CONTRIBUTOR-authored labelless aidevops-shaped issue.\n\n## Tags inline: #ai #security\n",
    "labels": []
  },
  {
    "number": 504,
    "title": "GH#9999: propose additional dedup layer",
    "body": "External NONE-authored labelless aidevops-shaped issue with no body tags.",
    "labels": []
  },
  {
    "number": 505,
    "title": "t2550: read collaborator proposal",
    "body": "Read-only collaborator issue.",
    "labels": []
  },
  {
    "number": 506,
    "title": "t2551: write collaborator task",
    "body": "Write-authorized collaborator issue.",
    "labels": []
  },
  {
    "number": 507,
    "title": "t2552: trusted automation task",
    "body": "Trusted bot issue.",
    "labels": []
  }
]
JSON
)
export FIXTURE_ISSUES_JSON

# -----------------------------------------------------------------------------
# Source the reconcile module. It has an include guard and expects certain
# functions from shared-constants.sh to exist (run_stage_with_timeout, etc.).
# For this unit test we don't need run_stage_with_timeout — we call the
# function directly. We do need a few stubs so the module sources cleanly.
# -----------------------------------------------------------------------------
# Minimal stubs for sourced module dependencies.
set_issue_status() { return 0; }
export -f set_issue_status

# shellcheck disable=SC1090
source "$RECONCILE_SRC"

_gh_actor_has_repo_write_authority() {
	local repo_slug="$1"
	local author_login="$2"
	local association="$3"
	[[ -n "$repo_slug" && "$association" == "COLLABORATOR" ]] || return 2
	case "$author_login" in
	write-collab) return 0 ;;
	read-collab) return 1 ;;
	*) return 2 ;;
	esac
}

# Stub the t2393 comment wrappers so reconcile_labelless_aidevops_issues's
# `gh_issue_comment` call reaches the test's gh mock. The real wrappers live
# in shared-constants.sh, which this test doesn't source (it deliberately
# minimises dependencies). Delegating to `gh issue comment` preserves the
# pre-t2393 test contract — the mock still records the same trace lines.
# shellcheck disable=SC2317
gh_issue_comment() { gh issue comment "$@" && return 0 || return 1; }
# shellcheck disable=SC2317
gh_pr_comment() { gh pr comment "$@" && return 0 || return 1; }
# Keep the test independent of any live pulse prefetch cache and route the
# fallback list wrapper through the controlled gh function below.
# shellcheck disable=SC2317
_read_cache_issues_for_slug() { return 1; }
# shellcheck disable=SC2317
gh_issue_list() { gh issue list "$@"; return $?; }
export -f gh_issue_comment gh_pr_comment _read_cache_issues_for_slug gh_issue_list

# Override `gh` as a shell function AFTER sourcing.
# shellcheck disable=SC2317
gh() {
	printf 'gh %s\n' "$*" >>"$TRACE_FILE"

	local cmd="${1:-}" sub="${2:-}"

	# gh issue list --repo test/repo --state open --json number,title,body,labels --limit 50
	if [[ "$cmd" == "issue" && "$sub" == "list" ]]; then
		printf '%s' "$FIXTURE_ISSUES_JSON"
		return 0
	fi

	# gh api repos/test/repo/issues/NNN — return the REST issue object fields
	# consumed by the reconcile action.
	# (t2450: reconcile_labelless_aidevops_issues fetches author_association
	# per candidate because gh issue list --json doesn't expose it.)
	if [[ "$cmd" == "api" ]]; then
		case "$sub" in
			*/issues/*/comments\?per_page=100)
				# Empty paginated comments — no sentinel present, so backfill proceeds.
				printf '%s' '[[]]'
				return 0
				;;
			*/issues/*)
				local num="${sub##*/}"
				case "$num" in
					500 | 501 | 502) printf '%s' '{"author_association":"MEMBER","user":{"login":"member","type":"User"}}' ;;
					503) printf '%s' '{"author_association":"CONTRIBUTOR","user":{"login":"external","type":"User"}}' ;;
					504) printf '%s' '{"author_association":"NONE","user":{"login":"unknown","type":"User"}}' ;;
					505) printf '%s' '{"author_association":"COLLABORATOR","user":{"login":"read-collab","type":"User"}}' ;;
					506) printf '%s' '{"author_association":"COLLABORATOR","user":{"login":"write-collab","type":"User"}}' ;;
					507) printf '%s' '{"author_association":"NONE","user":{"login":"github-actions[bot]","type":"Bot"}}' ;;
					*) printf '%s' '{"author_association":"NONE"}' ;;
				esac
				return 0
				;;
		esac
		return 0
	fi

	# gh issue comment N --repo test/repo --body "..."
	# Capture the --body arg to a per-issue file so assertions can inspect
	# which sentinel template was used (internal vs external, t2450).
	if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
		local cnum="${3:-}"
		local body="" prev=""
		local arg
		for arg in "$@"; do
			if [[ "$prev" == "--body" ]]; then
				body="$arg"
				break
			fi
			prev="$arg"
		done
		if [[ -n "$cnum" && -n "$body" ]]; then
			printf '%s' "$body" >"${TEST_TMPDIR}/comment-${cnum}.body"
		fi
		return 0
	fi

	# gh issue edit / label create — record and return success
	if [[ "$cmd" == "issue" && "$sub" == "edit" ]]; then
		return 0
	fi
	if [[ "$cmd" == "label" && "$sub" == "create" ]]; then
		return 0
	fi

	return 0
}
export -f gh

# -----------------------------------------------------------------------------
# Run the function under test
# -----------------------------------------------------------------------------
if ! reconcile_labelless_aidevops_issues >"${TEST_TMPDIR}/cmd.out" 2>&1; then
	printf 'FAIL: reconcile_labelless_aidevops_issues exited non-zero\n'
	cat "${TEST_TMPDIR}/cmd.out"
	exit 1
fi

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
failed=0

# The function should have scanned #500, applied labels, posted a comment.
# Extract gh issue edit and comment calls targeted at each number.
edit_500=$(grep -c '^gh issue edit 500 --repo test/repo' "$TRACE_FILE" || true)
edit_501=$(grep -c '^gh issue edit 501 --repo test/repo' "$TRACE_FILE" || true)
edit_502=$(grep -c '^gh issue edit 502 --repo test/repo' "$TRACE_FILE" || true)
comment_500=$(grep -c '^gh issue comment 500 --repo test/repo' "$TRACE_FILE" || true)
comment_501=$(grep -c '^gh issue comment 501 --repo test/repo' "$TRACE_FILE" || true)
rest_comment_reads=$(grep -cE '^gh api repos/test/repo/issues/(500|503|504|505|506|507)/comments\?per_page=100 --paginate --slurp$' "$TRACE_FILE" || true)
native_comment_reads=$(grep -cE '^gh issue view .*--json comments' "$TRACE_FILE" || true)

if [[ "$rest_comment_reads" -ne 6 || "$native_comment_reads" -ne 0 ]]; then
	printf 'FAIL: expected 6 paginated REST comment reads and 0 native comment views; got REST=%d native=%d\n' \
		"$rest_comment_reads" "$native_comment_reads"
	failed=1
fi

# GH#29394: COLLABORATOR must be live permission-checked, while trusted bots
# retain the automation fast path.
edit_line_505=$(grep '^gh issue edit 505 --repo test/repo' "$TRACE_FILE" | head -1)
if [[ "$edit_line_505" != *"--add-label needs-maintainer-review"* || "$edit_line_505" == *"--add-label origin:worker"* ]]; then
	printf 'FAIL: #505 read collaborator did not retain the external-authority gate\n'
	printf '  got: %s\n' "$edit_line_505"
	failed=1
fi
for trusted_num in 506 507; do
	trusted_line=$(grep "^gh issue edit ${trusted_num} --repo test/repo" "$TRACE_FILE" | head -1)
	if [[ "$trusted_line" != *"--add-label origin:worker"* || "$trusted_line" != *"--add-label tier:standard"* || "$trusted_line" == *"needs-maintainer-review"* ]]; then
		printf 'FAIL: #%s trusted author did not receive internal backfill labels\n' "$trusted_num"
		printf '  got: %s\n' "$trusted_line"
		failed=1
	fi
done

# #500 MUST be edited at least once
if [[ "$edit_500" -lt 1 ]]; then
	printf 'FAIL: expected gh issue edit on #500, got %d\n' "$edit_500"
	failed=1
fi
# Extract the edit line for #500 and check each required label substring.
edit_line=$(grep '^gh issue edit 500 --repo test/repo' "$TRACE_FILE" | head -1)
if [[ -z "$edit_line" ]]; then
	printf 'FAIL: no gh issue edit 500 line in trace\n'
	failed=1
else
	for required in "origin:worker" "tier:standard" "ai" "security"; do
		if [[ "$edit_line" != *"--add-label $required"* ]]; then
			printf 'FAIL: #500 edit missing --add-label %s\n' "$required"
			printf '  got: %s\n' "$edit_line"
			failed=1
		fi
	done
fi

# #500 MUST get a comment (exactly one)
if [[ "$comment_500" -ne 1 ]]; then
	printf 'FAIL: expected exactly 1 gh issue comment on #500, got %d\n' "$comment_500"
	failed=1
fi

# #501 must NOT be edited or commented — it's not aidevops-shaped
if [[ "$edit_501" -ne 0 ]]; then
	printf 'FAIL: #501 should not be edited (non-aidevops shape), got %d edits\n' "$edit_501"
	failed=1
fi
if [[ "$comment_501" -ne 0 ]]; then
	printf 'FAIL: #501 should not be commented, got %d comments\n' "$comment_501"
	failed=1
fi

# #502 must NOT be edited — it already has origin + tier labels
if [[ "$edit_502" -ne 0 ]]; then
	printf 'FAIL: #502 should not be edited (already blessed), got %d edits\n' "$edit_502"
	failed=1
fi

# -----------------------------------------------------------------------------
# t2450: external-contributor gating assertions
# -----------------------------------------------------------------------------
edit_503=$(grep -c '^gh issue edit 503 --repo test/repo' "$TRACE_FILE" || true)
edit_504=$(grep -c '^gh issue edit 504 --repo test/repo' "$TRACE_FILE" || true)
comment_503=$(grep -c '^gh issue comment 503 --repo test/repo' "$TRACE_FILE" || true)
comment_504=$(grep -c '^gh issue comment 504 --repo test/repo' "$TRACE_FILE" || true)

# #503 (external CONTRIBUTOR) — MUST be edited (gated, not rejected outright)
if [[ "$edit_503" -lt 1 ]]; then
	printf 'FAIL: expected gh issue edit on #503 (external CONTRIBUTOR), got %d\n' "$edit_503"
	failed=1
fi
edit_line_503=$(grep '^gh issue edit 503 --repo test/repo' "$TRACE_FILE" | head -1)
if [[ -z "$edit_line_503" ]]; then
	printf 'FAIL: no gh issue edit 503 line in trace\n'
	failed=1
else
	# MUST apply needs-maintainer-review
	if [[ "$edit_line_503" != *"--add-label needs-maintainer-review"* ]]; then
		printf 'FAIL: #503 edit missing --add-label needs-maintainer-review\n'
		printf '  got: %s\n' "$edit_line_503"
		failed=1
	fi
	# MUST NOT apply maintainer-trust labels for an external author
	for forbidden in "origin:worker" "tier:simple" "tier:standard" "tier:thinking"; do
		if [[ "$edit_line_503" == *"--add-label $forbidden"* ]]; then
			printf 'FAIL: #503 edit added forbidden label %s for external author\n' "$forbidden"
			printf '  got: %s\n' "$edit_line_503"
			failed=1
		fi
	done
	# Body tags are intent signals, not trust signals — they should still be applied
	for required in "ai" "security"; do
		if [[ "$edit_line_503" != *"--add-label $required"* ]]; then
			printf 'FAIL: #503 edit missing body-tag label %s\n' "$required"
			printf '  got: %s\n' "$edit_line_503"
			failed=1
		fi
	done
fi

# #503 MUST get exactly one comment with the EXTERNAL sentinel
if [[ "$comment_503" -ne 1 ]]; then
	printf 'FAIL: expected exactly 1 gh issue comment on #503, got %d\n' "$comment_503"
	failed=1
fi
body_file_503="${TEST_TMPDIR}/comment-503.body"
if [[ ! -f "$body_file_503" ]]; then
	printf 'FAIL: no comment body captured for #503\n'
	failed=1
else
	if ! grep -q 'aidevops:labelless-backfill-external' "$body_file_503"; then
		printf 'FAIL: #503 comment body missing external sentinel\n'
		failed=1
	fi
fi

# #504 (external NONE) — same gating as #503 but no body tags to apply
if [[ "$edit_504" -lt 1 ]]; then
	printf 'FAIL: expected gh issue edit on #504 (external NONE), got %d\n' "$edit_504"
	failed=1
fi
edit_line_504=$(grep '^gh issue edit 504 --repo test/repo' "$TRACE_FILE" | head -1)
if [[ -z "$edit_line_504" ]]; then
	printf 'FAIL: no gh issue edit 504 line in trace\n'
	failed=1
else
	if [[ "$edit_line_504" != *"--add-label needs-maintainer-review"* ]]; then
		printf 'FAIL: #504 edit missing --add-label needs-maintainer-review\n'
		printf '  got: %s\n' "$edit_line_504"
		failed=1
	fi
	for forbidden in "origin:worker" "tier:simple" "tier:standard" "tier:thinking"; do
		if [[ "$edit_line_504" == *"--add-label $forbidden"* ]]; then
			printf 'FAIL: #504 edit added forbidden label %s for external author\n' "$forbidden"
			printf '  got: %s\n' "$edit_line_504"
			failed=1
		fi
	done
fi
if [[ "$comment_504" -ne 1 ]]; then
	printf 'FAIL: expected exactly 1 gh issue comment on #504, got %d\n' "$comment_504"
	failed=1
fi
body_file_504="${TEST_TMPDIR}/comment-504.body"
if [[ ! -f "$body_file_504" ]]; then
	printf 'FAIL: no comment body captured for #504\n'
	failed=1
elif ! grep -q 'aidevops:labelless-backfill-external' "$body_file_504"; then
	printf 'FAIL: #504 comment body missing external sentinel\n'
	failed=1
fi

# Regression: #500 (internal MEMBER) must get the INTERNAL sentinel, not external.
body_file_500="${TEST_TMPDIR}/comment-500.body"
if [[ -f "$body_file_500" ]]; then
	if grep -q 'aidevops:labelless-backfill-external' "$body_file_500"; then
		printf 'FAIL: #500 comment body contains EXTERNAL sentinel (should be internal)\n'
		failed=1
	fi
	if ! grep -q 'aidevops:labelless-backfill -->' "$body_file_500"; then
		printf 'FAIL: #500 comment body missing INTERNAL sentinel marker\n'
		failed=1
	fi
fi

if [[ "$failed" -eq 0 ]]; then
	printf 'PASS: test-pulse-labelless-reconcile — all assertions green\n'
	exit 0
fi
printf '\nFAIL: test-pulse-labelless-reconcile — see diagnostics above\n'
printf '\n--- gh trace ---\n'
cat "$TRACE_FILE"
printf '\n--- cmd out ---\n'
cat "${TEST_TMPDIR}/cmd.out"
exit 1
