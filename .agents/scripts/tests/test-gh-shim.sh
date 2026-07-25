#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for the gh PATH shim (t2685)
# =============================================================================
# Verifies:
#   1. Non-write subcommands pass through unchanged (fast path)
#   2. `gh issue comment --body` without marker gets sig appended
#   3. `gh issue comment --body` with marker passes through unchanged
#   4. `gh issue comment --body-file` without marker gets sig appended to file
#   5. `gh issue comment --body-file` with marker passes through
#   6. `gh pr create --body` without marker gets sig appended
#   7. `AIDEVOPS_GH_SHIM_DISABLE=1` bypasses the shim entirely
#   8. Recursion guard: `_AIDEVOPS_GH_SHIM_ACTIVE=1` fails closed immediately
#
# Strategy: run the shim against a stub `gh` binary that logs its args, and
# a stub `gh-signature-helper.sh` that emits a predictable footer. Assert
# the stub captured the expected (possibly modified) arg list.

set -euo pipefail

# Keep the harness hermetic: production pulse sessions may export REST-first
# routing globally, but tests opt into that per scenario below.
unset AIDEVOPS_GH_REST_FIRST_READS
unset AIDEVOPS_GH_FORCE_REST_READS
unset HEADLESS
unset FULL_LOOP_HEADLESS
unset AIDEVOPS_HEADLESS
unset OPENCODE_HEADLESS
unset GITHUB_ACTIONS
unset AIDEVOPS_SESSION_ORIGIN
unset AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE
unset AIDEVOPS_EXTERNAL_GH_WRITE_ALLOWLIST
unset AIDEVOPS_GH_QUOTA_COST
unset AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS
unset GH_HOST

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
SHIM="${REPO_DIR}/.agents/scripts/gh"

if [[ ! -x "$SHIM" ]]; then
	echo "FAIL: $SHIM not executable (expected at .agents/scripts/gh)"
	exit 1
fi

PASS=0
FAIL=0

_pass() {
	echo "  PASS: $1"
	PASS=$((PASS + 1))
	return 0
}

_fail() {
	echo "  FAIL: $1"
	[[ -n "${2:-}" ]] && echo "    $2"
	FAIL=$((FAIL + 1))
	return 0
}

# -----------------------------------------------------------------------------
# Test harness: build a tmp dir with stub gh + stub sig helper, point shim at them
# -----------------------------------------------------------------------------

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gh-shim-test)
trap 'rm -rf "$TMP"' EXIT

# Stub real gh — writes its argv (one per line) to $STUB_GH_LOG and
# exits 0. The shim will exec this when forwarding.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh that logs argv
if [[ "$1" == "api" && "$2" == "user" ]]; then
	printf '%s\n' "${STUB_GH_USER:-managed}"
	exit 0
fi
if [[ "$1" == "auth" && "$2" == "token" ]]; then
	printf '%s\n' 'fixture-token'
	exit 0
fi
: >"$STUB_GH_LOG"
for arg in "$@"; do
	printf '%s\n' "$arg" >>"$STUB_GH_LOG"
done
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
	if [[ "$*" == *'.resources.core.used'* ]]; then
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"${STUB_BOOTSTRAP_CORE_USED:-100}" "${STUB_BOOTSTRAP_CORE_REMAINING:-4900}" "${STUB_BOOTSTRAP_CORE_RESET:-2000}" \
			"${STUB_BOOTSTRAP_GRAPHQL_USED:-200}" "${STUB_BOOTSTRAP_GRAPHQL_REMAINING:-4800}" "${STUB_BOOTSTRAP_GRAPHQL_RESET:-2000}" \
			"${STUB_BOOTSTRAP_SEARCH_USED:-0}" "${STUB_BOOTSTRAP_SEARCH_REMAINING:-30}" "${STUB_BOOTSTRAP_SEARCH_RESET:-2000}"
		exit 0
	fi
	printf '%s\n' "${STUB_RATE_LIMIT_REMAINING:-5000}"
	exit 0
fi
if [[ "${GH_DEBUG:-}" == "api" && "${STUB_GH_DEBUG_RESPONSE:-0}" == "1" ]]; then
	printf '* Request at 2026-07-24 00:00:00 +0000 UTC\n' >&2
	printf '> Authorization: token private-fixture-token\n\n' >&2
	printf '< HTTP/2.0 %s Fixture\n' "${STUB_GH_DEBUG_STATUS:-200}" >&2
	printf '< X-Ratelimit-Resource: %s\n' "${STUB_GH_DEBUG_RESOURCE:-graphql}" >&2
	printf '< X-Ratelimit-Used: %s\n' "${STUB_GH_DEBUG_USED:-201}" >&2
	printf '< X-Ratelimit-Remaining: %s\n' "${STUB_GH_DEBUG_REMAINING:-4799}" >&2
	printf '< X-Ratelimit-Reset: %s\n\n' "${STUB_GH_DEBUG_RESET:-2000}" >&2
	printf '{"private":"response-body-fixture"}\n' >&2
	printf '* Request took 12.5ms\n' >&2
	[[ -z "${STUB_GH_DIAGNOSTIC:-}" ]] || printf '%s\n' "$STUB_GH_DIAGNOSTIC" >&2
elif [[ -n "${STUB_GH_UNFRAMED_PRIVATE_STDERR:-}" ]]; then
	printf '%s\n' "$STUB_GH_UNFRAMED_PRIVATE_STDERR" >&2
fi
if [[ "${STUB_GH_EXIT_CODE:-0}" =~ ^[1-9][0-9]*$ ]]; then
	exit "$STUB_GH_EXIT_CODE"
fi
if [[ "$1" == "api" && "$2" == "-i" && "$3" =~ ^/search/issues\? ]]; then
	fixture='{"items":[{"number":22350,"state":"open","title":"Authored PR","html_url":"https://github.com/owner/repo/pull/22350","user":{"login":"managed"},"pull_request":{"merged_at":null}}]}'
	printf 'HTTP/2 200\r\nX-RateLimit-Resource: search\r\n\r\n%s\n' "$fixture"
	exit 0
fi
if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/pulls\? ]]; then
	jq_filter=""
	i=3
	while [[ $i -le $# ]]; do
		if [[ "${!i}" == "--jq" ]]; then
			next=$((i + 1))
			jq_filter="${!next:-}"
			break
		fi
		i=$((i + 1))
	done
	fixture='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337"},{"number":22343,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22343"}]'
	if [[ "$2" == *"head=owner%3Afeature%2Fauto-20260502-135611-gh22289"* ]]; then
		fixture='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337"}]'
	fi
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$fixture" | jq -c "$jq_filter"
	else
		printf '%s\n' "$fixture"
	fi
	exit 0
fi
if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/issues\? ]]; then
	jq_filter=""
	i=3
	while [[ $i -le $# ]]; do
		if [[ "${!i}" == "--jq" ]]; then
			next=$((i + 1))
			jq_filter="${!next:-}"
			break
		fi
		i=$((i + 1))
	done
	fixture='[{"number":22430,"state":"open","title":"Reduce GraphQL list-call pressure","html_url":"https://github.com/owner/repo/issues/22430","updated_at":"2026-05-02T17:52:48Z","labels":[{"name":"auto-dispatch"}],"assignees":[{"login":"worker"}],"user":{"login":"managed"}}]'
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$fixture" | jq -c "$jq_filter"
	else
		printf '%s\n' "$fixture"
	fi
	exit 0
fi
EOF
chmod +x "$TMP/bin/gh"

# Stub sig helper — emits a predictable footer with the canonical marker
mkdir -p "$TMP/scripts"
cat >"$TMP/scripts/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
# Stub emits fixed footer so tests are deterministic.
if [[ -n "${STUB_SIG_LOG:-}" ]]; then
	: >"$STUB_SIG_LOG"
	for arg in "$@"; do
		printf '%s\n' "$arg" >>"$STUB_SIG_LOG"
	done
fi
printf '\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub footer\n'
EOF
chmod +x "$TMP/scripts/gh-signature-helper.sh"

# Copy the shim next to the stub helper so the shim's relative lookup
# (first candidate: $_SHIM_DIR/gh-signature-helper.sh) picks up OUR stub
# instead of the real one installed in ~/.aidevops/agents/scripts/.
cp "$SHIM" "$TMP/scripts/gh"
chmod +x "$TMP/scripts/gh"
cp "$REPO_DIR/.agents/scripts/gh-api-instrument.sh" "$TMP/scripts/gh-api-instrument.sh"
cp "$REPO_DIR/.agents/scripts/gh-quota-attribution-lib.sh" "$TMP/scripts/gh-quota-attribution-lib.sh"
cp "$REPO_DIR/.agents/scripts/gh-quota-debug-filter.py" "$TMP/scripts/gh-quota-debug-filter.py"
cp "$REPO_DIR/.agents/scripts/shared-gh-wrappers-rest-fallback.sh" "$TMP/scripts/shared-gh-wrappers-rest-fallback.sh"
cp "$REPO_DIR/.agents/scripts/shared-gh-wrappers-rest-read-semantics.sh" "$TMP/scripts/shared-gh-wrappers-rest-read-semantics.sh"

# Put stub gh in PATH (for shim's REAL_GH discovery) and the shim in
# $TMP/scripts (for direct invocation in tests).
export PATH="$TMP/bin:$PATH"
export STUB_GH_LOG="$TMP/gh-argv.log"
export STUB_SIG_LOG="$TMP/sig-argv.log"

SHIM_RUN="$TMP/scripts/gh"

# Convenience: read the stub gh log into a single string
_read_argv() {
	[[ -f "$STUB_GH_LOG" ]] || {
		echo "(no log)"
		return 0
	}
	cat "$STUB_GH_LOG"
	return 0
}

_reset_log() {
	: >"$STUB_GH_LOG"
	[[ -n "${STUB_SIG_LOG:-}" ]] && : >"$STUB_SIG_LOG"
	return 0
}

_read_attempt_quota() {
	local log_file="$1"
	awk -F '\t' '
		$9 == "attempt" {
			quota = ($17 == "" ? "unknown" : $17)
		}
		END { print quota }
	' "$log_file"
	return 0
}

_read_last_attempt_field() {
	local log_file="$1"
	local field_number="$2"
	awk -F '\t' -v field_number="$field_number" '
		$9 == "attempt" { value = $field_number }
		END { print value }
	' "$log_file"
	return 0
}

_read_sig_argv() {
	[[ -f "${STUB_SIG_LOG:-}" ]] || {
		echo "(no sig log)"
		return 0
	}
	cat "${STUB_SIG_LOG:-}"
	return 0
}

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
printf 'unsigned body content\n' >"$body_file"
_reset_log
"$SHIM_RUN" issue comment 456 --repo owner/repo --body-file "$body_file" 2>/dev/null
argv=$(_read_argv)
resolved_body_file=$(printf '%s\n' "$argv" | awk 'prev { print; exit } $0 == "--body-file" { prev=1 }')
if [[ -n "$resolved_body_file" && -f "$resolved_body_file" ]] && grep -q "<!-- aidevops:sig -->" "$resolved_body_file"; then
	_pass "sig marker appended to temporary --body-file"
else
	_fail "--body-file sig injection" "argv: $argv"
fi
if grep -q "unsigned body content" "$body_file" && ! grep -q "<!-- aidevops:sig -->" "$body_file"; then
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
	grep -q $'\tgh_pr_list\tgraphql' "$AIDEVOPS_GH_API_LOG"; then
	_pass "REST-first leaves GraphQL-only pr list fields on GraphQL"
else
	_fail "REST-first GraphQL-only pr list preservation" "argv: $argv log: $(cat "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)"
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

# =============================================================================
# Test 22: exact quota cost is limited to unambiguous successful REST requests
# =============================================================================
echo ""
echo "Test 22: conservative direct REST quota attribution"
quota_log="$TMP/quota-attribution.log"

: >"$quota_log"
AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api --jq . /repos/owner/repo >/dev/null 2>&1
if [[ "$(_read_attempt_quota "$quota_log")" == "1" ]]; then
	_pass "successful direct REST request records documented cost one"
else
	_fail "direct REST cost attribution" "quota: $(_read_attempt_quota "$quota_log")"
fi

: >"$quota_log"
AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo/labels -f name=fixture >/dev/null 2>&1
if [[ "$(_read_attempt_quota "$quota_log")" == "1" ]]; then
	_pass "successful direct REST write records documented cost one"
else
	_fail "direct REST write cost attribution" "quota: $(_read_attempt_quota "$quota_log")"
fi

: >"$quota_log"
AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api rate_limit >/dev/null 2>&1
if [[ "$(_read_attempt_quota "$quota_log")" == "0" ]]; then
	_pass "successful GET /rate_limit records documented cost zero"
else
	_fail "rate-limit endpoint cost attribution" "quota: $(_read_attempt_quota "$quota_log")"
fi

for ambiguous_case in conditional cache pagination enterprise graphql unknown-option failure; do
	: >"$quota_log"
	case "$ambiguous_case" in
	conditional)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo -H 'If-None-Match: fixture' >/dev/null 2>&1
		;;
	cache)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo --cache 1h >/dev/null 2>&1
		;;
	pagination)
		AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 AIDEVOPS_GH_API_LOG="$quota_log" \
			"$SHIM_RUN" api /repos/owner/repo --paginate >/dev/null 2>&1
		;;
	enterprise)
		GH_HOST=enterprise.example AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>&1
		;;
	graphql)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api graphql -f 'query={viewer{login}}' >/dev/null 2>&1
		;;
	unknown-option)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo --future-option >/dev/null 2>&1
		;;
	failure)
		if STUB_GH_EXIT_CODE=1 AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>&1; then
			_fail "failed REST command status" "stub failure unexpectedly succeeded"
		fi
		;;
	esac
	if [[ "$(_read_attempt_quota "$quota_log")" == "unknown" ]]; then
		_pass "$ambiguous_case request keeps quota cost unknown"
	else
		_fail "$ambiguous_case quota fail-closed behavior" "quota: $(_read_attempt_quota "$quota_log")"
	fi
done

# =============================================================================
# Test 23: response-framed capture proves unit costs without leaking GH_DEBUG
# =============================================================================
echo ""
echo "Test 23: response-framed exact quota capture"
exact_temp="$TMP/exact-quota-temp"
mkdir -p "$exact_temp"

exact_log="$TMP/exact-graphql.log"
exact_err="$TMP/exact-graphql.err"
exact_state="$TMP/exact-graphql-state"
: >"$exact_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$exact_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$exact_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	STUB_GH_DIAGNOSTIC='sanitized native diagnostic' \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>"$exact_err"
if [[ "$(_read_attempt_quota "$exact_log")" == "1" \
	&& "$(_read_last_attempt_field "$exact_log" 15)" == "200" \
	&& "$(grep -c $'\tattempt\t' "$exact_log")" == "2" ]]; then
	_pass "GraphQL unit delta records exact cost after zero-cost bootstrap"
else
	_fail "GraphQL exact quota capture" "log: $(cat "$exact_log" 2>/dev/null || true)"
fi
if grep -Eq 'private-fixture-token|response-body-fixture' "$exact_err"; then
	_fail "GH_DEBUG privacy filtering" "stderr exposed private debug content"
elif grep -q '^sanitized native diagnostic$' "$exact_err"; then
	_pass "GH_DEBUG request and response bodies are suppressed while native diagnostics survive"
else
	_fail "GH_DEBUG sanitized diagnostic preservation" "stderr: $(cat "$exact_err" 2>/dev/null || true)"
fi

failed_log="$TMP/exact-failed-rest.log"
failed_err="$TMP/exact-failed-rest.err"
failed_state="$TMP/exact-failed-rest-state"
: >"$failed_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$failed_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$failed_log" STUB_GH_DEBUG_RESPONSE=1 STUB_GH_EXIT_CODE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core \
	STUB_GH_DEBUG_STATUS=403 STUB_GH_DEBUG_USED=101 STUB_GH_DEBUG_REMAINING=4899 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>"$failed_err"; then
	_fail "failed REST exact capture status" "stub failure unexpectedly succeeded"
fi
if [[ "$(_read_attempt_quota "$failed_log")" == "1" \
	&& "$(_read_last_attempt_field "$failed_log" 14)" == "error" \
	&& "$(_read_last_attempt_field "$failed_log" 15)" == "403" ]]; then
	_pass "counter-proven failed REST response records exact unit cost and status"
else
	_fail "failed REST exact quota capture" "log: $(cat "$failed_log" 2>/dev/null || true)"
fi

gap_log="$TMP/exact-counter-gap.log"
gap_state="$TMP/exact-counter-gap-state"
: >"$gap_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$gap_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$gap_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=202 STUB_GH_DEBUG_REMAINING=4798 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$gap_log")" == "unknown" ]]; then
	_pass "counter gaps and higher-cost ambiguity remain fail-closed"
else
	_fail "counter-gap fail-closed behavior" "quota: $(_read_attempt_quota "$gap_log")"
fi

drift_log="$TMP/exact-format-drift.log"
drift_err="$TMP/exact-format-drift.err"
drift_state="$TMP/exact-format-drift-state"
: >"$drift_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$drift_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$drift_log" \
	STUB_GH_UNFRAMED_PRIVATE_STDERR='unframed-private-response-fixture' \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>"$drift_err"
if [[ "$(_read_attempt_quota "$drift_log")" == "unknown" \
	&& "$(_read_last_attempt_field "$drift_log" 12)" == "0" \
	&& ! -s "$drift_err" ]]; then
	_pass "debug framing drift stays private and makes attempt exactness fail closed"
else
	_fail "debug framing drift handling" "log: $(cat "$drift_log" 2>/dev/null || true) stderr: $(cat "$drift_err" 2>/dev/null || true)"
fi

local_log="$TMP/exact-local-command.log"
local_state="$TMP/exact-local-command-state"
: >"$local_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$local_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$local_log" "$SHIM_RUN" --version >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tattempt\t' "$local_log" || true)" == "0" && ! -e "$local_state" ]]; then
	_pass "known local-only gh commands avoid quota bootstrap and transport attempts"
else
	_fail "local-only exact-capture bypass" "log: $(cat "$local_log" 2>/dev/null || true)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================================"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
