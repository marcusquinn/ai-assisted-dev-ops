#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim core test cases -- signing, pass-through, and basic read routing
# =============================================================================
# Sourced by test-gh-shim.sh after the shared hermetic harness is initialized.
#
# Usage: source "${SCRIPT_DIR}/test-gh-shim-core-cases.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_GH_SHIM_CORE_CASES_LOADED:-}" ]] && return 0
_TEST_GH_SHIM_CORE_CASES_LOADED=1

# Resolve SCRIPT_DIR defensively when sourced outside the orchestrator.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_module_path" == "${BASH_SOURCE[0]}" ]] && _module_path="."
	SCRIPT_DIR="$(cd "$_module_path" && pwd)"
	unset _module_path
fi

# =============================================================================
# Test 1: Non-write subcommand passes through unchanged (fast path)
# =============================================================================
echo "Test 1: non-write subcommand pass-through"
_reset_log
"$SHIM_RUN" --version 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == "--version" ]]; then
	_pass "gh --version passes through unchanged"
else
	_fail "gh --version pass-through" "got argv: $argv"
fi

# =============================================================================
# Test 2: gh issue comment --body without marker gets sig appended
# =============================================================================
echo ""
echo "Test 2: --body without marker gets sig appended"
_reset_log
"$SHIM_RUN" issue comment 123 --repo owner/repo --body "plain body text" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "sig marker appended to --body value"
else
	_fail "--body sig injection" "argv: $argv"
fi
if [[ "$argv" == *"plain body text"* ]]; then
	_pass "original body preserved"
else
	_fail "--body original content preservation" "argv: $argv"
fi

# =============================================================================
# Test 2b: issue-close comments use the same one-shot signature injection
# =============================================================================
echo ""
echo "Test 2b: issue-close comments are signed without splitting close"
for close_form in long equals short; do
	_reset_log
	case "$close_form" in
	long) "$SHIM_RUN" issue close 123 --repo owner/repo --reason completed --comment "close evidence" 2>/dev/null ;;
	equals) "$SHIM_RUN" issue close 123 --repo owner/repo --reason completed --comment="close evidence" 2>/dev/null ;;
	short) "$SHIM_RUN" issue close 123 --repo owner/repo --reason completed -c "close evidence" 2>/dev/null ;;
	esac
	argv=$(_read_argv)
	close_count=$(grep -c '^close$' "$STUB_GH_LOG" 2>/dev/null || true)
	if [[ "$argv" == *"<!-- aidevops:sig -->"* && "$argv" == *"--reason"* &&
		"$argv" == *"completed"* && "$close_count" -eq 1 ]]; then
		_pass "${close_form} issue-close comment signs exactly one close mutation"
	else
		_fail "${close_form} issue-close comment signing" "argv: $argv"
	fi
done

_reset_log
"$SHIM_RUN" issue close 124 --repo owner/repo --reason completed 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == $'issue\nclose\n124\n--repo\nowner/repo\n--reason\ncompleted' ]] &&
	[[ ! -s "$STUB_SIG_LOG" ]]; then
	_pass "comment-free issue close passes through unchanged"
else
	_fail "comment-free issue close pass-through" "argv: $argv"
fi

# Inline marker prose is not a completed signature footer.
echo ""
echo "Test 2a: inline marker prose gets a standalone signature"
_reset_log
"$SHIM_RUN" issue comment 123 --repo owner/repo \
	--body "Documentation mentions <!-- aidevops:sig --> inline" 2>/dev/null
marker_count=$(grep -Fxc '<!-- aidevops:sig -->' "$STUB_GH_LOG" 2>/dev/null || true)
if [[ "$marker_count" -eq 1 ]]; then
	_pass "inline marker prose receives one standalone marker"
else
	_fail "inline marker prose signing" "standalone marker appeared $marker_count times, expected 1"
fi

# =============================================================================
# Test 3: gh issue comment --body with marker passes through unchanged
# =============================================================================
echo ""
echo "Test 3: --body already signed is idempotent"
_reset_log
signed_body="already signed

<!-- aidevops:sig -->
---
prior sig"
"$SHIM_RUN" issue comment 123 --repo owner/repo --body "$signed_body" 2>/dev/null
argv=$(_read_argv)
# Count marker occurrences — should be exactly 1 (not doubled)
marker_count=$(grep -c "<!-- aidevops:sig -->" "$STUB_GH_LOG" 2>/dev/null || true)
if [[ "$marker_count" -eq 1 ]]; then
	_pass "signed --body not double-injected"
else
	_fail "--body idempotency" "marker appeared $marker_count times, expected 1"
fi

# =============================================================================
# Test 4: gh issue comment --body-file without marker gets sig appended to file
# =============================================================================
echo ""
echo "Test 4: --body-file without marker gets sig appended"
body_file="$TMP/body.md"
printf 'unsigned body cites aidevops.sh:1715\n' >"$body_file"
_reset_log
"$SHIM_RUN" issue comment 456 --repo owner/repo --body-file "$body_file" 2>/dev/null
argv=$(_read_argv)
resolved_body_file=$(printf '%s\n' "$argv" | awk 'prev { print; exit } $0 == "--body-file" { prev=1 }')
if [[ -n "$resolved_body_file" && -f "$resolved_body_file" ]] && grep -q "<!-- aidevops:sig -->" "$resolved_body_file"; then
	_pass "sig marker appended to temporary --body-file"
else
	_fail "--body-file sig injection" "argv: $argv"
fi
if grep -q "aidevops.sh:1715" "$body_file" && ! grep -q "<!-- aidevops:sig -->" "$body_file"; then
	_pass "original --body-file content preserved without mutation"
else
	_fail "--body-file original preservation" ""
fi

# =============================================================================
# Test 5: gh issue comment --body-file with marker is idempotent
# =============================================================================
echo ""
echo "Test 5: --body-file already signed is idempotent"
signed_file="$TMP/signed.md"
printf 'already signed\n\n<!-- aidevops:sig -->\n---\nprior sig\n' >"$signed_file"
size_before=$(wc -c <"$signed_file" | tr -d ' ')
_reset_log
"$SHIM_RUN" issue comment 789 --repo owner/repo --body-file "$signed_file" 2>/dev/null
size_after=$(wc -c <"$signed_file" | tr -d ' ')
if [[ "$size_before" == "$size_after" ]]; then
	_pass "signed --body-file not modified (idempotent)"
else
	_fail "--body-file idempotency" "size changed $size_before -> $size_after"
fi

# =============================================================================
# Test 5a: managed ephemeral body is unlinked before native transport
# =============================================================================
echo ""
echo "Test 5a: managed ephemeral body is unlinked before native transport"
managed_root="$TMP/managed-temp"
ephemeral_parent="${managed_root}/aidevops-triage-comment.Ab12Cd"
ephemeral_body="${ephemeral_parent}/comment.md"
mkdir -p "$ephemeral_parent"
printf 'validated review body\n\n<!-- aidevops:sig -->\n---\nfixture\n' >"$ephemeral_body"
_reset_log
STUB_GH_EPHEMERAL_SOURCE="$ephemeral_body" \
	STUB_GH_EPHEMERAL_PARENT="$ephemeral_parent" \
	AIDEVOPS_TEMP_DIR="$managed_root" \
	AIDEVOPS_GH_EPHEMERAL_BODY_FILE="$ephemeral_body" \
	"$SHIM_RUN" issue comment 790 --repo owner/repo --body-file "$ephemeral_body" \
	2>"$TMP/ephemeral.err"
argv=$(_read_argv)
captured_body=$(<"$STUB_GH_BODY_LOG")
if [[ "$argv" == *$'--body-file\n/dev/fd/9'* &&
	"$captured_body" == *"validated review body"* &&
	"$captured_body" == *"<!-- aidevops:sig -->"* &&
	! -e "$ephemeral_body" && ! -L "$ephemeral_body" &&
	! -e "$ephemeral_parent" && ! -L "$ephemeral_parent" ]]; then
	_pass "ephemeral body reaches native gh only after verified unlink"
else
	_fail "ephemeral body transport" "argv=${argv}, captured=${captured_body}"
fi
if [[ "$argv" != *"validated review body"* ]]; then
	_pass "ephemeral body content is absent from native gh argv"
else
	_fail "ephemeral body argv isolation" "argv contained review content"
fi

blocked_parent="${managed_root}/aidevops-triage-comment.Ef34Gh"
blocked_body="${blocked_parent}/comment.md"
mkdir -p "$blocked_parent"
printf 'validated blocked body\n\n<!-- aidevops:sig -->\n---\nfixture\n' >"$blocked_body"
printf 'unexpected\n' >"${blocked_parent}/unexpected"
_reset_log
if STUB_GH_EPHEMERAL_SOURCE="$blocked_body" \
	STUB_GH_EPHEMERAL_PARENT="$blocked_parent" \
	AIDEVOPS_TEMP_DIR="$managed_root" \
	AIDEVOPS_GH_EPHEMERAL_BODY_FILE="$blocked_body" \
	"$SHIM_RUN" issue comment 791 --repo owner/repo --body-file "$blocked_body" \
	2>"$TMP/ephemeral-cleanup.err"; then
	_fail "ephemeral cleanup failure gate" "shim returned success"
elif [[ ! -s "$STUB_GH_MAIN_CALL_LOG" ]] &&
	grep -q 'cleanup could not be verified before transport' "$TMP/ephemeral-cleanup.err"; then
	_pass "ephemeral cleanup failure blocks native transport"
else
	_fail "ephemeral cleanup failure gate" "native call log or diagnostic mismatch"
fi
rm -rf "$blocked_parent"

bypass_parent="${managed_root}/aidevops-triage-comment.Ij56Kl"
bypass_body="${bypass_parent}/comment.md"
mkdir -p "$bypass_parent"
printf 'validated bypass body\n\n<!-- aidevops:sig -->\n---\nfixture\n' >"$bypass_body"
_reset_log
if AIDEVOPS_GH_SHIM_DISABLE=1 \
	AIDEVOPS_TEMP_DIR="$managed_root" \
	AIDEVOPS_GH_EPHEMERAL_BODY_FILE="$bypass_body" \
	"$SHIM_RUN" issue comment 792 --repo owner/repo --body-file "$bypass_body" \
	2>"$TMP/ephemeral-bypass.err"; then
	_fail "ephemeral shim bypass gate" "shim returned success"
elif [[ ! -s "$STUB_GH_MAIN_CALL_LOG" && -f "$bypass_body" ]] &&
	grep -q 'cannot bypass the aidevops gh shim' "$TMP/ephemeral-bypass.err"; then
	_pass "ephemeral transport blocks shim bypass before native gh"
else
	_fail "ephemeral shim bypass gate" "native call, artifact, or diagnostic mismatch"
fi
rm -rf "$bypass_parent"

# =============================================================================
# Test 6: gh pr create --body without marker gets sig appended
# =============================================================================
echo ""
echo "Test 6: gh pr create --body injection"
_reset_log
"$SHIM_RUN" pr create --repo owner/repo --title "test" --body "PR body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "gh pr create --body sig injected"
else
	_fail "gh pr create injection" "argv: $argv"
fi
if [[ "$argv" == *$'--label\norigin:interactive'* ]]; then
	_pass "interactive raw pr create gets one origin label"
else
	_fail "interactive raw pr create origin normalization" "argv: $argv"
fi

_reset_log
AIDEVOPS_HEADLESS=1 AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE=owner/repo \
	"$SHIM_RUN" pr create --repo owner/repo --title "worker" --body "For #25901" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'--label\norigin:worker'* ]] && [[ "$argv" != *"origin:interactive"* ]]; then
	_pass "headless raw pr create gets worker origin label"
else
	_fail "headless raw pr create origin normalization" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" pr create --repo owner/repo --title "explicit" --label "origin:worker" --body "For #25901" 2>/dev/null
argv=$(_read_argv)
origin_count=$(printf '%s\n' "$argv" | grep -c '^origin:' || true)
if [[ "$origin_count" -eq 1 ]] && [[ "$argv" == *"origin:worker"* ]]; then
	_pass "explicit raw pr origin remains immutable and singular"
else
	_fail "explicit raw pr origin normalization" "count=${origin_count} argv: $argv"
fi

echo ""
echo "Test 6a: issue-first repos block PR creation without linked issue"
_reset_log
if "$SHIM_RUN" pr create --repo marcusquinn/aidevops --title "fix: missing issue" --body "PR body" 2>"$TMP/pr-linked-issue.err"; then
	_fail "missing linked issue PR guard" "write unexpectedly passed"
else
	argv=$(_read_argv)
	if [[ -z "$argv" ]] && grep -q "pr-linked-issue" "$TMP/pr-linked-issue.err"; then
		_pass "missing linked issue is blocked before gh exec"
	else
		_fail "missing linked issue PR guard" "argv: $argv err: $(cat "$TMP/pr-linked-issue.err" 2>/dev/null || true)"
	fi
fi

_reset_log
"$SHIM_RUN" pr create --repo marcusquinn/aidevops --title "fix: linked issue" --body "Resolves #25901" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"Resolves #25901"* ]] && [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "linked issue PR body passes and remains signed"
else
	_fail "linked issue PR body pass-through" "argv: $argv"
fi

linked_pr_body="$TMP/pr-linked-body.md"
printf '## Summary\n\nFor #25901\n' >"$linked_pr_body"
_reset_log
"$SHIM_RUN" pr create --repo marcusquinn/aidevops --title "fix: linked body-file" --body-file "$linked_pr_body" 2>/dev/null
argv=$(_read_argv)
resolved_pr_body_file=$(printf '%s\n' "$argv" | awk 'prev { print; exit } $0 == "--body-file" { prev=1 }')
if [[ -n "$resolved_pr_body_file" && -f "$resolved_pr_body_file" ]] && grep -q "<!-- aidevops:sig -->" "$resolved_pr_body_file"; then
	_pass "linked issue PR body-file passes and receives signature"
else
	_fail "linked issue PR body-file pass-through" "argv: $argv"
fi

# =============================================================================
# Test 7: AIDEVOPS_GH_SHIM_DISABLE=1 bypasses the shim
# =============================================================================
echo ""
echo "Test 7: AIDEVOPS_GH_SHIM_DISABLE=1 bypass"
_reset_log
AIDEVOPS_GH_SHIM_DISABLE=1 "$SHIM_RUN" issue comment 999 --repo owner/repo --body "unsigned" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" != *"<!-- aidevops:sig -->"* ]]; then
	_pass "AIDEVOPS_GH_SHIM_DISABLE=1 skips sig injection"
else
	_fail "bypass env var" "sig was still injected; argv: $argv"
fi

# =============================================================================
# Test 8: Recursion guard
# =============================================================================
echo ""
echo "Test 8: recursion guard"
_reset_log
if _AIDEVOPS_GH_SHIM_ACTIVE=1 "$SHIM_RUN" issue comment 111 --repo owner/repo --body "recursive" 2>"$TMP/recursive.err"; then
	_fail "recursion guard" "recursive invocation unexpectedly passed"
else
	rc=$?
	argv=$(_read_argv)
	if [[ $rc -eq 126 && -z "$argv" ]] && grep -q "recursive aidevops gh shim invocation blocked" "$TMP/recursive.err"; then
		_pass "recursion guard fails closed before native gh exec"
	else
		_fail "recursion guard" "rc=$rc argv: $argv err: $(cat "$TMP/recursive.err" 2>/dev/null || true)"
	fi
fi

# =============================================================================
# Test 9: --body=value equals form
# =============================================================================
echo ""
echo "Test 9: --body=value equals form"
_reset_log
"$SHIM_RUN" issue comment 222 --repo owner/repo "--body=equals form body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "--body=value equals form gets sig"
else
	_fail "--body=value injection" "argv: $argv"
fi

# =============================================================================
# Test 9a: pr merge bodies preserve terminal Git trailers byte-for-byte
# =============================================================================
echo ""
echo "Test 9a: pr merge bodies preserve terminal trailers"
merge_body='Preserve release provenance.

Aidevops-Release-Aggregator-PR: #29629
Aidevops-Release-Aggregates: #29629
Aidevops-Release-Aggregates: #29630'
for merge_body_form in separated equals; do
	_reset_log
	if [[ "$merge_body_form" == "separated" ]]; then
		"$SHIM_RUN" pr merge 123 --repo owner/repo --squash --body "$merge_body" 2>/dev/null
	else
		"$SHIM_RUN" pr merge 123 --repo owner/repo --squash "--body=${merge_body}" 2>/dev/null
	fi
	argv=$(_read_argv)
	merge_native_body=$(printf '%s\n' "$argv" | awk 'seen { print } $0 == "--body" { seen = 1 }')
	if [[ "$merge_body_form" == "equals" ]]; then
		merge_native_body="${argv##*--body=}"
	fi
	merge_trailers=$(printf '%s\n' "$merge_native_body" | git interpret-trailers --parse)
	if [[ "$argv" != *"<!-- aidevops:sig -->"* &&
		"$merge_native_body" == "$merge_body" &&
		"$merge_trailers" == *"Aidevops-Release-Aggregator-PR: #29629"* &&
		"$merge_trailers" == *"Aidevops-Release-Aggregates: #29629"* &&
		"$merge_trailers" == *"Aidevops-Release-Aggregates: #29630"* ]]; then
		_pass "${merge_body_form} pr merge body remains unsigned and trailer-parseable"
	else
		_fail "${merge_body_form} pr merge body preservation" "argv: $argv trailers: $merge_trailers"
	fi
done

# =============================================================================
# Test 10: gh api (arbitrary subcommand) passes through
# =============================================================================
echo ""
echo "Test 10: gh api passes through"
_reset_log
"$SHIM_RUN" api /user 2>/dev/null
argv=$(_read_argv)
expected=$'api\n/user'
if [[ "$argv" == "$expected" ]]; then
	_pass "gh api pass-through"
else
	_fail "gh api pass-through" "argv: $argv"
fi

# =============================================================================
# Test 11: gh shim records operation-specific instrumentation labels
# =============================================================================
echo ""
echo "Test 11: operation-specific instrumentation labels"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls.log"
rm -f "$AIDEVOPS_GH_API_LOG"
"$SHIM_RUN" issue list --repo owner/repo 2>/dev/null
"$SHIM_RUN" pr view 123 --repo owner/repo 2>/dev/null
if grep -q $'\tgh_issue_list\tgraphql' "$AIDEVOPS_GH_API_LOG" && grep -q $'\tgh_pr_view\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "read/list calls use operation-specific labels"
else
	_fail "operation-specific instrumentation labels" "log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

# =============================================================================
# Test 12: --json view calls stay on GraphQL to preserve gh-shaped fields
# =============================================================================
echo ""
echo "Test 12: --json view calls do not REST rewrite"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-json.log"
rm -f "$AIDEVOPS_GH_API_LOG"
_GH_SHOULD_FALLBACK_OVERRIDE=1 "$SHIM_RUN" pr view 123 --repo owner/repo --json number,statusCheckRollup 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == $'pr\nview\n123\n--repo\nowner/repo\n--json\nnumber,statusCheckRollup' ]] && grep -q $'\tgh_pr_view\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "--json read stays on GraphQL with operation label"
else
	_fail "--json read GraphQL preservation" "argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

# =============================================================================
# Test 13: gh pr list --json can REST rewrite while preserving head and JSON shape
# =============================================================================
echo ""
echo "Test 13: gh pr list --json REST rewrite preserves --head"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-json-pr-list.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(STUB_RATE_LIMIT_REMAINING=0 "$SHIM_RUN" pr list --repo owner/repo \
	--head feature/auto-20260502-135611-gh22289 --state all \
	--json number,state,mergedAt,url --jq '.[].number' 2>/dev/null || true)
argv=$(_read_argv)
if [[ "$output" == "22337" ]] &&
	[[ "$argv" == *"head=owner%3Afeature%2Fauto-20260502-135611-gh22289"* ]] &&
	grep -q $'\tgh_pr_list\trest' "$AIDEVOPS_GH_API_LOG"; then
	_pass "gh pr list --json uses REST fallback with qualified --head"
else
	_fail "gh pr list --json REST fallback" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi

# =============================================================================
# Test 14: gh issue list --json can REST rewrite while preserving JSON shape
# =============================================================================
echo ""
echo "Test 14: gh issue list --json REST rewrite preserves compact output"
_reset_log
export AIDEVOPS_GH_API_LOG="$TMP/gh-api-calls-json-issue-list.log"
rm -f "$AIDEVOPS_GH_API_LOG"
output=$(STUB_RATE_LIMIT_REMAINING=0 "$SHIM_RUN" issue list --repo owner/repo \
	--state open --json number,title,url,assignees,labels,updatedAt --jq '.[0].title' 2>/dev/null || true)
argv=$(_read_argv)
if [[ "$output" == "Reduce GraphQL list-call pressure" ]] &&
	[[ "$argv" == *"/repos/owner/repo/issues?state=open&per_page=30"* ]] &&
	grep -q $'\tgh_issue_list\trest' "$AIDEVOPS_GH_API_LOG"; then
	_pass "gh issue list --json uses REST fallback with compact issue fields"
else
	_fail "gh issue list --json REST fallback" "output: $output argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
fi
