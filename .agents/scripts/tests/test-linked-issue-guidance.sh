#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-linked-issue-guidance.sh — GH#23906 contributor guidance regression guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

assert_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if ! grep -Eq "$pattern" "${REPO_ROOT}/${file}"; then
		printf 'FAIL: %s missing expected pattern in %s\n' "$label" "$file" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$label"
	return 0
}

assert_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -Eq "$pattern" "${REPO_ROOT}/${file}"; then
		printf 'FAIL: %s found unexpected pattern in %s\n' "$label" "$file" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$label"
	return 0
}

assert_contains "CONTRIBUTING.md" 'Issue-first pull requests' "CONTRIBUTING issue-first section"
assert_contains "CONTRIBUTING.md" 'monitor the issue queue more frequently' "CONTRIBUTING explains issue visibility"
assert_contains "CONTRIBUTING.md" 'not a repository owner, member, or collaborator' "CONTRIBUTING scopes external contributors"
assert_contains "CONTRIBUTING.md" 'Closes #NNN' "CONTRIBUTING closing keyword"
assert_contains "CONTRIBUTING.md" 'Ref #NNN' "CONTRIBUTING reference keyword"
assert_contains ".agents/templates/issue-first-pr-contributing.md" 'aidevops:issue-first-pr:start' "managed CONTRIBUTING block start marker"
assert_contains ".agents/templates/issue-first-pr-contributing.md" 'aidevops:issue-first-pr:scope=external' "managed CONTRIBUTING policy scope marker"
assert_contains ".agents/templates/issue-first-pr-contributing.md" 'aidevops:issue-first-pr:end' "managed CONTRIBUTING block end marker"
assert_contains ".github/PULL_REQUEST_TEMPLATE.md" 'Linked issue' "PR template linked issue field"
assert_contains ".github/PULL_REQUEST_TEMPLATE.md" 'Closes #NNN' "PR template closing keyword"
assert_contains ".github/PULL_REQUEST_TEMPLATE.md" 'Ref #NNN' "PR template reference keyword"
assert_contains ".agents/scripts/commands/log-issue-aidevops.md" 'For #NNN.*Ref #NNN' "command log issue PR reference guidance"
assert_contains ".agents/workflows/log-issue-aidevops.md" 'For #NNN.*Ref #NNN' "workflow log issue PR reference guidance"
assert_contains ".github/workflows/linked-issue-check.yml" 'uses: \./\.github/workflows/linked-issue-check-reusable\.yml' "repository workflow is a thin self-caller"
assert_contains ".agents/templates/workflows/linked-issue-check-caller.yml" 'linked-issue-check-reusable\.yml@main' "downstream linked issue caller delegates centrally"
assert_contains ".agents/templates/workflows/linked-issue-check-caller.yml" 'pull_request_target:' "downstream caller preserves fork-safe trigger"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" "publishStatus\('failure'" "linked issue status gate remains blocking"
assert_not_contains ".github/workflows/linked-issue-check-reusable.yml" 'core\.setFailed' "linked issue policy gate avoids workflow failure"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" "state === 'success' && exhausted" "positive linked issue result tolerates exhausted API quota"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" 'throw error' "negative linked issue result still fails closed"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" 'const hasTaskPrefix = .*t\\d.*GH#\\d' "linked issue recognizes both tNNN and GH#NNN prefixes"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" "const trustedRoles = \\['OWNER', 'MEMBER', 'COLLABORATOR'\\]" "linked issue preserves trusted author controls"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" "pr.user.type === 'Bot'" "linked issue preserves bot control"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" 'if \(trustedRoles\.includes\(pr\.author_association\)\)' "linked issue exempts trusted repository authors"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" 'github\.rest\.issues\.get' "linked issue verifies referenced issue through GitHub metadata"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" 'if \(!issue\.pull_request\)' "linked issue rejects pull request numbers as issue references"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" 'body\.matchAll\(issueRefPattern\)' "linked issue validates every candidate reference"
assert_contains ".github/workflows/linked-issue-check-reusable.yml" '#aidevops:trust-boundary GH#17671/GH#28567' "linked issue trust check carries boundary marker"
assert_not_contains ".github/workflows/linked-issue-check-reusable.yml" 'if \(/\^\(t\\d' "untrusted linked issue path has no title-only exemption"

assert_contains ".github/workflows/pr-triage-gate.yml" "const trustedRoles = \\['OWNER', 'MEMBER'\\]" "PR triage preserves owner and member trust controls"
assert_contains ".github/workflows/pr-triage-gate.yml" "association === 'COLLABORATOR'" "PR triage verifies collaborator authority"
assert_contains ".github/workflows/pr-triage-gate.yml" "\\['admin', 'maintain', 'write'\\]\\.includes" "PR triage requires collaborator write authority"
assert_contains ".github/workflows/pr-triage-gate.yml" "pr.user.type === 'Bot'" "PR triage preserves bot control"
assert_contains ".github/workflows/pr-triage-gate.yml" '#aidevops:trust-boundary GH#17671/GH#28567' "PR triage trust check carries boundary marker"
assert_not_contains ".github/workflows/pr-triage-gate.yml" 'const title = pr\.title|/\^t\\d|/\^GH#\\d' "PR triage gives tNNN and GH#NNN titles no trust"

assert_contains ".github/workflows/bounty-spam-auto-close.yml" "user.type != 'Bot'" "bounty detector preserves bot control"
assert_contains ".github/workflows/bounty-spam-auto-close.yml" "author_association != 'OWNER'" "bounty detector preserves trusted author control"
assert_contains ".github/workflows/bounty-spam-auto-close.yml" "author_association != 'MEMBER'" "bounty detector preserves member control"
assert_contains ".github/workflows/bounty-spam-auto-close.yml" "author_association != 'COLLABORATOR'" "bounty detector preserves collaborator control"
assert_contains ".github/workflows/bounty-spam-auto-close.yml" '#aidevops:trust-boundary GH#17671/GH#28567' "bounty detector trust check carries boundary marker"
assert_not_contains ".github/workflows/bounty-spam-auto-close.yml" 'PR_TITLE|task ID prefix|\^t\[0-9\]|\^GH#\[0-9\]' "bounty detector gives tNNN and GH#NNN titles no trust"

assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'classify-infra-rate-limit' "review gate classifies API exhaustion from immutable trust evidence"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'RESULT.*PASS_ADVISORY' "trusted advisory default defers unavailable review API"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'SKIP\|PASS_ADVISORY\|PASS_RATE_LIMITED' "external authors cannot use advisory review outcomes"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'Unexpected review helper result' "malformed review helper output fails closed"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" "result != 'INFRA_RATE_LIMITED'" "review gate avoids follow-up API label lookup during exhaustion"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'skipping immediate status retry' "review gate avoids retry loop during exhaustion"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'infrastructure wait — GitHub API quota exhausted' "review status reports infrastructure wait truthfully"
assert_not_contains ".github/workflows/review-bot-gate-reusable.yml" 'sleep 5 && gh api' "review gate removed blind status retry"

exit 0
