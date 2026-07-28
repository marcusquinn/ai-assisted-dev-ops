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
#   9. Framework-bug validation advises without blocking issue publication
#  10. Conflicting dispatch-intent labels are normalized before transport
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
unset AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE
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
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" && \
	-n "${STUB_GH_EPHEMERAL_SOURCE:-}" ]]; then
	printf 'called\n' >>"${STUB_GH_MAIN_CALL_LOG}"
	if [[ -n "${AIDEVOPS_GH_EPHEMERAL_BODY_FILE:-}" ]]; then
		printf 'removed ephemeral pathname leaked into native environment\n' >&2
		exit 94
	fi
	if [[ -e "$STUB_GH_EPHEMERAL_SOURCE" || -L "$STUB_GH_EPHEMERAL_SOURCE" || \
		-e "${STUB_GH_EPHEMERAL_PARENT:-}" || -L "${STUB_GH_EPHEMERAL_PARENT:-}" ]]; then
		printf 'ephemeral source still exists at native transport\n' >&2
		exit 91
	fi
	body_path=""
	previous_arg=""
	for candidate_arg in "$@"; do
		if [[ "$previous_arg" == "--body-file" ]]; then
			body_path="$candidate_arg"
			break
		fi
		case "$candidate_arg" in
		--body-file=*) body_path="${candidate_arg#--body-file=}"; break ;;
		esac
		previous_arg="$candidate_arg"
	done
	printf '%s\n' "$body_path" >"${STUB_GH_BODY_PATH_LOG}"
	[[ "$body_path" == "/dev/fd/9" ]] || exit 92
	cat "$body_path" >"${STUB_GH_BODY_LOG}" || exit 93
fi
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
	if [[ "${STUB_GH_DEBUG_REQUEST_ONLY:-0}" != "1" ]]; then
		printf '< HTTP/2.0 %s Fixture\n' "${STUB_GH_DEBUG_STATUS:-200}" >&2
		printf '< X-Ratelimit-Resource: %s\n' "${STUB_GH_DEBUG_RESOURCE:-graphql}" >&2
		printf '< X-Ratelimit-Used: %s\n' "${STUB_GH_DEBUG_USED:-201}" >&2
		printf '< X-Ratelimit-Remaining: %s\n' "${STUB_GH_DEBUG_REMAINING:-4799}" >&2
		printf '< X-Ratelimit-Reset: %s\n\n' "${STUB_GH_DEBUG_RESET:-2000}" >&2
		if [[ -n "${STUB_GH_DEBUG_BODY:-}" ]]; then
			printf '%s\n' "$STUB_GH_DEBUG_BODY" >&2
		else
			printf '{"private":"response-body-fixture"}\n' >&2
		fi
		if [[ "${STUB_GH_DEBUG_TRAILING_RESPONSE:-0}" == "1" ]]; then
			printf '< HTTP/2.0 200 Redirected\n\n' >&2
			printf '{"private":"redirected-response-fixture"}\n' >&2
		fi
	fi
	printf '* Request took 12.5ms\n' >&2
	[[ -z "${STUB_GH_DIAGNOSTIC:-}" ]] || printf '%s\n' "$STUB_GH_DIAGNOSTIC" >&2
elif [[ -n "${STUB_GH_UNFRAMED_PRIVATE_STDERR:-}" ]]; then
	printf '%s\n' "$STUB_GH_UNFRAMED_PRIVATE_STDERR" >&2
fi
if [[ "${STUB_GH_EXIT_CODE:-0}" =~ ^[1-9][0-9]*$ ]]; then
	exit "$STUB_GH_EXIT_CODE"
fi
if [[ "$1" == "api" && "$2" == "graphql" && -n "${STUB_GRAPHQL_RESPONSE_JSON:-}" ]]; then
	printf '%s\n' "$STUB_GRAPHQL_RESPONSE_JSON"
	exit 0
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
cp "$REPO_DIR/.agents/scripts/log-issue-helper.sh" "$TMP/scripts/log-issue-helper.sh"
mkdir -p "$TMP/scripts/lib"
cp "$REPO_DIR/.agents/scripts/lib/version.sh" "$TMP/scripts/lib/version.sh"
cp "$REPO_DIR/.agents/scripts/lib/issue-fingerprint.sh" "$TMP/scripts/lib/issue-fingerprint.sh"

# Put stub gh in PATH (for shim's REAL_GH discovery) and the shim in
# $TMP/scripts (for direct invocation in tests).
export PATH="$TMP/bin:$PATH"
export STUB_GH_LOG="$TMP/gh-argv.log"
export STUB_SIG_LOG="$TMP/sig-argv.log"
export STUB_GH_BODY_LOG="$TMP/gh-body.log"
export STUB_GH_BODY_PATH_LOG="$TMP/gh-body-path.log"
export STUB_GH_MAIN_CALL_LOG="$TMP/gh-main-call.log"

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
	: >"$STUB_GH_BODY_LOG"
	: >"$STUB_GH_BODY_PATH_LOG"
	: >"$STUB_GH_MAIN_CALL_LOG"
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

_argv_has_pair() {
	local flag="$1"
	local value="$2"
	if awk -v flag="$flag" -v value="$value" '
		previous == flag && $0 == value { found = 1 }
		{ previous = $0 }
		END { exit found ? 0 : 1 }
	' "$STUB_GH_LOG"; then
		return 0
	fi
	return 1
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
if [[ "$argv" == *$'--body-file\n/dev/fd/9'* && \
	"$captured_body" == *"validated review body"* && \
	"$captured_body" == *"<!-- aidevops:sig -->"* && \
	! -e "$ephemeral_body" && ! -L "$ephemeral_body" && \
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
elif [[ ! -s "$STUB_GH_MAIN_CALL_LOG" ]] && \
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
elif [[ ! -s "$STUB_GH_MAIN_CALL_LOG" && -f "$bypass_body" ]] && \
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

zero_cost_log="$TMP/exact-zero-cost-rest.log"
zero_cost_state="$TMP/exact-zero-cost-rest-state"
: >"$zero_cost_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$zero_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$zero_cost_log" STUB_GH_DEBUG_RESPONSE=1 STUB_GH_EXIT_CODE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core \
	STUB_GH_DEBUG_STATUS=403 STUB_GH_DEBUG_USED=100 STUB_GH_DEBUG_REMAINING=4900 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>/dev/null; then
	_fail "zero-cost REST response status" "stub failure unexpectedly succeeded"
fi
if [[ "$(_read_attempt_quota "$zero_cost_log")" == "0" \
	&& "$(_read_last_attempt_field "$zero_cost_log" 14)" == "error" \
	&& "$(_read_last_attempt_field "$zero_cost_log" 15)" == "403" ]]; then
	_pass "counter-proven zero-cost REST failure records exact zero quota"
else
	_fail "zero-cost REST response attribution" "log: $(cat "$zero_cost_log" 2>/dev/null || true)"
fi

successful_zero_log="$TMP/exact-successful-zero-delta.log"
successful_zero_state="$TMP/exact-successful-zero-delta-state"
: >"$successful_zero_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$successful_zero_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$successful_zero_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=100 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_STATUS=200 STUB_GH_DEBUG_USED=100 STUB_GH_DEBUG_REMAINING=4900 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$successful_zero_log")" == "unknown" \
	&& "$(_read_last_attempt_field "$successful_zero_log" 15)" == "200" ]]; then
	_pass "successful zero-delta response remains unknown instead of shifting quota cost"
else
	_fail "successful zero-delta fail-closed behavior" "log: $(cat "$successful_zero_log" 2>/dev/null || true)"
fi

redirect_log="$TMP/exact-redirect-rest.log"
redirect_state="$TMP/exact-redirect-rest-state"
: >"$redirect_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$redirect_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$redirect_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_TRAILING_RESPONSE=1 STUB_BOOTSTRAP_CORE_USED=100 \
	STUB_GH_DEBUG_RESOURCE=core STUB_GH_DEBUG_STATUS=302 STUB_GH_DEBUG_USED=101 \
	STUB_GH_DEBUG_REMAINING=4899 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" api /repos/owner/repo/actions/jobs/1/logs >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$redirect_log")" == "1" \
	&& "$(_read_last_attempt_field "$redirect_log" 12)" == "1" \
	&& "$(_read_last_attempt_field "$redirect_log" 15)" == "302" ]]; then
	_pass "redirect frames select the single complete GitHub quota response"
else
	_fail "redirect response attribution" "log: $(cat "$redirect_log" 2>/dev/null || true)"
fi

incomplete_log="$TMP/exact-incomplete-rest.log"
incomplete_state="$TMP/exact-incomplete-rest-state"
: >"$incomplete_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$incomplete_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$incomplete_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_REQUEST_ONLY=1 STUB_GH_EXIT_CODE=1 \
	"$SHIM_RUN" api /repos/owner/repo >/dev/null 2>/dev/null; then
	_fail "incomplete REST response status" "stub failure unexpectedly succeeded"
fi
if [[ "$(_read_attempt_quota "$incomplete_log")" == "unknown" \
	&& "$(_read_last_attempt_field "$incomplete_log" 12)" == "1" \
	&& "$(_read_last_attempt_field "$incomplete_log" 14)" == "error" ]]; then
	_pass "one incomplete request frame preserves exact caller-owned page"
else
	_fail "incomplete request page attribution" "log: $(cat "$incomplete_log" 2>/dev/null || true)"
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

zero_frame_log="$TMP/exact-zero-frame.log"
zero_frame_state="$TMP/exact-zero-frame-state"
: >"$zero_frame_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$zero_frame_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$zero_frame_log" "$SHIM_RUN" auth status >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tgh-quota-bootstrap\t.*\tattempt\t' "$zero_frame_log" || true)" == "1" \
	&& "$(grep -c $'\tgh_auth_status\t.*\tattempt\t' "$zero_frame_log" || true)" == "0" ]]; then
	_pass "valid zero-response capture adds no synthetic transport attempt"
else
	_fail "zero-response exact capture" "log: $(cat "$zero_frame_log" 2>/dev/null || true)"
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
# Test 24: response-owned GraphQL cost is recorded after reading the response
# =============================================================================
echo ""
echo "Test 24: response-metered GraphQL quota attribution"
response_cost_log="$TMP/response-cost-graphql.log"
response_cost_out="$TMP/response-cost-graphql.out"
response_cost_state="$TMP/response-cost-graphql-state"
: >"$response_cost_log"
GH_TOKEN=fixture-token STUB_GRAPHQL_RESPONSE_JSON='{"data":{"rateLimit":{"cost":2},"viewer":{"login":"fixture"}}}' \
	AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$response_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$response_cost_log" "$SHIM_RUN" api graphql \
	-f 'query={viewer{login} rateLimit{cost}}' >"$response_cost_out"
if [[ "$(_read_attempt_quota "$response_cost_log")" == "2" \
	&& "$(_read_last_attempt_field "$response_cost_log" 12)" == "1" \
	&& "$(jq -r '.data.rateLimit.cost' "$response_cost_out")" == "2" ]]; then
	_pass "GraphQL response-owned cost records the returned value on page one"
else
	_fail "response-metered GraphQL attribution" "log: $(cat "$response_cost_log" 2>/dev/null || true) output: $(cat "$response_cost_out" 2>/dev/null || true)"
fi

response_followup_log="$TMP/response-cost-followup.log"
: >"$response_followup_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$response_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$response_followup_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=300 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=301 STUB_GH_DEBUG_REMAINING=4699 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$response_followup_log")" == "1" ]]; then
	_pass "response-metered GraphQL invalidates cumulative state before exact follow-up"
else
	_fail "response-metered state invalidation" "log: $(cat "$response_followup_log" 2>/dev/null || true)"
fi

transformed_cost_log="$TMP/response-cost-transformed.log"
transformed_cost_state="$TMP/response-cost-transformed-state"
: >"$transformed_cost_log"
GH_TOKEN=fixture-token STUB_GRAPHQL_RESPONSE_JSON='{"data":{"rateLimit":{"cost":1}}}' \
	AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$transformed_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$transformed_cost_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_BODY='{"data":{"rateLimit":{"cost":1}}}' \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=200 STUB_GH_DEBUG_REMAINING=4800 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" api graphql -f 'query={rateLimit{cost}}' --jq '.data.rateLimit.cost' >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$transformed_cost_log")" == "1" \
	&& "$(_read_last_attempt_field "$transformed_cost_log" 6)" != "graphql-response-metered" ]]; then
	_pass "output-transformed GraphQL queries use response-owned exact transport cost"
else
	_fail "transformed GraphQL response-meter guard" "log: $(cat "$transformed_cost_log" 2>/dev/null || true)"
fi

response_missing_log="$TMP/response-cost-missing.log"
response_missing_out="$TMP/response-cost-missing.out"
response_missing_state="$TMP/response-cost-missing-state"
: >"$response_missing_log"
GH_TOKEN=fixture-token STUB_GRAPHQL_RESPONSE_JSON='{"data":{"viewer":{"login":"fixture"}}}' \
	AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$response_missing_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$response_missing_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" api graphql -f 'query={viewer{login}}' >"$response_missing_out" 2>/dev/null
if [[ "$(_read_attempt_quota "$response_missing_log")" == "1" \
	&& "$(_read_last_attempt_field "$response_missing_log" 6)" != "graphql-response-metered" \
	&& "$(jq -r '.data.viewer.login' "$response_missing_out")" == "fixture" ]]; then
	_pass "GraphQL queries without rateLimit.cost use exact transport capture"
else
	_fail "missing response-cost transport fallback" "log: $(cat "$response_missing_log" 2>/dev/null || true) output: $(cat "$response_missing_out" 2>/dev/null || true)"
fi

native_meter_log="$TMP/response-cost-native-command.log"
native_meter_state="$TMP/response-cost-native-command-state"
: >"$native_meter_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
	AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 AIDEVOPS_GH_QUOTA_STATE_DIR="$native_meter_state" \
	AIDEVOPS_TEMP_DIR="$exact_temp" AIDEVOPS_GH_API_LOG="$native_meter_log" \
	STUB_GH_DEBUG_RESPONSE=1 STUB_BOOTSTRAP_GRAPHQL_USED=200 \
	STUB_GH_DEBUG_RESOURCE=graphql STUB_GH_DEBUG_USED=201 \
	STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$native_meter_log")" == "1" \
	&& "$(_read_last_attempt_field "$native_meter_log" 6)" != "graphql-response-metered" ]]; then
	_pass "global response-meter flag cannot intercept native GraphQL commands"
else
	_fail "native GraphQL response-meter guard" "log: $(cat "$native_meter_log" 2>/dev/null || true)"
fi

# =============================================================================
# Test 25: framework-bug validation advises without blocking publication
# =============================================================================
echo ""
echo "Test 25: advisory framework-bug brief validation"

malformed_brief="$TMP/malformed-framework-bug.md"
cat >"$malformed_brief" <<'EOF'
## Description

The review reported a cleanup bug.

## Reproducer

The session inferred a cause but omitted exact evidence fields.
EOF
cp "$malformed_brief" "$TMP/malformed-framework-bug.original"

_reset_log
if "$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(cleanup): malformed report" --label bug \
	--body-file "$malformed_brief" 2>"$TMP/malformed-file.err"; then
	if [[ -s "$STUB_GH_LOG" ]] && cmp -s "$malformed_brief" "$TMP/malformed-framework-bug.original" &&
		grep -q '\[aidevops\]\[issue-brief\]\[WARN\]' "$TMP/malformed-file.err" &&
		grep -q 'Reproducer requires' "$TMP/malformed-file.err"; then
		_pass "malformed body-file warns and reaches transport without source mutation"
	else
		_fail "malformed framework-bug body-file advisory" "argv: $(_read_argv) err: $(cat "$TMP/malformed-file.err" 2>/dev/null || true)"
	fi
else
	_fail "malformed framework-bug body-file advisory" "write was blocked"
fi

_reset_log
malformed_inline=$(<"$malformed_brief")
if "$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(shim): malformed inline report" --body "$malformed_inline" \
	2>"$TMP/malformed-inline.err"; then
	if [[ -s "$STUB_GH_LOG" ]] && grep -q '\[aidevops\]\[issue-brief\]\[WARN\]' "$TMP/malformed-inline.err" &&
		grep -q 'Reproducer requires' "$TMP/malformed-inline.err"; then
		_pass "malformed inline body warns and reaches transport"
	else
		_fail "malformed inline framework-bug advisory" "argv: $(_read_argv) err: $(cat "$TMP/malformed-inline.err" 2>/dev/null || true)"
	fi
else
	_fail "malformed inline framework-bug advisory" "write was blocked"
fi

valid_investigation="$TMP/valid-framework-investigation.md"
cat >"$valid_investigation" <<'EOF'
## Description

The issue-create guard accepts a substantive investigation.

## Reproducer

**Symptom command**: `aidevops status`

**Actual output**: `status was inconsistent`

**Expected output**: `status was consistent`

**Causal status**: unconfirmed investigation
EOF
cp "$valid_investigation" "$TMP/valid-framework-investigation.original"

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(status): valid investigation" --label bug \
	--body-file "$valid_investigation" 2>"$TMP/valid-investigation.err"
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]] && cmp -s "$valid_investigation" "$TMP/valid-framework-investigation.original"; then
	_pass "valid unconfirmed body-file passes normal signing and transport unchanged"
else
	_fail "valid unconfirmed body-file pass-through" "argv: $argv err: $(cat "$TMP/valid-investigation.err" 2>/dev/null || true)"
fi

valid_confirmed_file="$TMP/valid-confirmed-framework-bug.md"
cat >"$valid_confirmed_file" <<'EOF'
## Description

The issue-create guard accepts a proven bug report.

## Reproducer

**Symptom command**: `gh issue create --repo marcusquinn/aidevops`

**Actual output**: `the issue write reached the transport stub`

**Expected output**: `validated reports and incomplete reports can both be published`

**Causal status**: confirmed

**Production entry point**: `.agents/scripts/gh` receives the issue-create command

**Call chain**: issue creation enters the shim and validates advisorially before the native CLI

**Integrated verification**: this hermetic command reaches the transport stub after advisory validation
EOF
valid_confirmed=$(<"$valid_confirmed_file")
_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(guard): valid confirmed report" --label bug --body "$valid_confirmed" \
	2>"$TMP/valid-confirmed.err"
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]] && [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "valid confirmed inline report passes normal signing and transport"
else
	_fail "valid confirmed inline pass-through" "argv: $argv err: $(cat "$TMP/valid-confirmed.err" 2>/dev/null || true)"
fi

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "t28710: internal tracking brief" --label bug --body "$malformed_inline" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "tNNN internal tracking issue remains exempt"
else
	_fail "tNNN internal tracking exemption" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "GH#28710: internal follow-up" --label bug --body "$malformed_inline" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "GH#NNN internal tracking issue remains exempt"
else
	_fail "GH#NNN internal tracking exemption" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo owner/repo \
	--title "bug(external): malformed report" --label bug --body "$malformed_inline" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "non-aidevops issue creation remains exempt"
else
	_fail "non-aidevops issue exemption" "argv: $argv"
fi

_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "Request a new capability" --label enhancement --body "## Description

Add a supported capability." 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "canonical non-bug issue shape remains exempt"
else
	_fail "canonical non-bug issue exemption" "argv: $argv"
fi

mv "$TMP/scripts/log-issue-helper.sh" "$TMP/scripts/log-issue-helper.sh.disabled"
_reset_log
"$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(helper): unavailable validator" --label bug --body "$malformed_inline" 2>/dev/null
mv "$TMP/scripts/log-issue-helper.sh.disabled" "$TMP/scripts/log-issue-helper.sh"
argv=$(_read_argv)
if [[ "$argv" == *$'issue\ncreate'* ]]; then
	_pass "missing adjacent validator preserves fail-open shim behavior"
else
	_fail "missing validator fail-open behavior" "argv: $argv"
fi

_reset_log
if "$SHIM_RUN" api /repos/marcusquinn/aidevops/issues -X POST \
	-f "title=bug(rest): malformed fallback report" -F "body=@$malformed_brief" \
	-f 'labels[]=bug' 2>"$TMP/malformed-rest.err"; then
	if [[ -s "$STUB_GH_LOG" ]] && grep -q '\[aidevops\]\[issue-brief\]\[WARN\]' "$TMP/malformed-rest.err" &&
		grep -q 'Reproducer requires' "$TMP/malformed-rest.err"; then
		_pass "malformed REST fallback body warns and reaches transport"
	else
		_fail "malformed REST fallback advisory" "argv: $(_read_argv) err: $(cat "$TMP/malformed-rest.err" 2>/dev/null || true)"
	fi
else
	_fail "malformed REST fallback advisory" "write was blocked"
fi

_reset_log
resolved_output=$(SHIM_TEST_MODE=1 "$SHIM_RUN" issue create --repo marcusquinn/aidevops \
	--title "bug(test-mode): valid report" --label bug --body-file "$valid_investigation" 2>/dev/null)
if [[ "$resolved_output" == resolved_body_file=* ]] &&
	cmp -s "$valid_investigation" "$TMP/valid-framework-investigation.original"; then
	_pass "valid SHIM_TEST_MODE path remains available and source-safe"
else
	_fail "SHIM_TEST_MODE compatibility" "output: $resolved_output"
fi

# =============================================================================
# Test 26: dispatch-intent labels are mutually exclusive at transport
# =============================================================================
echo ""
echo "Test 26: dispatch-intent label normalization"

_reset_log
"$SHIM_RUN" issue create --repo owner/repo --title "Dispatch intent conflict" \
	--body "Capture the issue." --label "bug,auto-dispatch" --label no-auto-dispatch \
	2>"$TMP/dispatch-create.err"
if grep -Fxq 'no-auto-dispatch' "$STUB_GH_LOG" &&
	! grep -Eq '(^|,)auto-dispatch(,|$)' "$STUB_GH_LOG" &&
	grep -q '\[aidevops\]\[dispatch-labels\]\[NORMALIZE\]' "$TMP/dispatch-create.err"; then
	_pass "issue creation keeps the manual hold when both dispatch labels are requested"
else
	_fail "issue-create dispatch conflict normalization" "argv: $(_read_argv) err: $(cat "$TMP/dispatch-create.err" 2>/dev/null || true)"
fi

_reset_log
"$SHIM_RUN" issue edit 42 --repo owner/repo --add-label no-auto-dispatch \
	--remove-label no-auto-dispatch 2>/dev/null
if _argv_has_pair "--add-label" "no-auto-dispatch" &&
	_argv_has_pair "--remove-label" "auto-dispatch" &&
	! _argv_has_pair "--remove-label" "no-auto-dispatch"; then
	_pass "adding no-auto-dispatch removes auto-dispatch and preserves the requested hold"
else
	_fail "manual dispatch-intent issue edit" "argv: $(_read_argv)"
fi

_reset_log
"$SHIM_RUN" issue edit 42 --repo owner/repo --add-label auto-dispatch \
	--remove-label auto-dispatch 2>/dev/null
if _argv_has_pair "--add-label" "auto-dispatch" &&
	_argv_has_pair "--remove-label" "no-auto-dispatch" &&
	! _argv_has_pair "--remove-label" "auto-dispatch"; then
	_pass "adding auto-dispatch removes no-auto-dispatch and preserves automation intent"
else
	_fail "automatic dispatch-intent issue edit" "argv: $(_read_argv)"
fi

_reset_log
"$SHIM_RUN" issue edit 42 --repo owner/repo --add-label auto-dispatch \
	--add-label no-auto-dispatch 2>"$TMP/dispatch-edit.err"
if _argv_has_pair "--add-label" "no-auto-dispatch" &&
	! _argv_has_pair "--add-label" "auto-dispatch" &&
	_argv_has_pair "--remove-label" "auto-dispatch" &&
	grep -q '\[aidevops\]\[dispatch-labels\]\[NORMALIZE\]' "$TMP/dispatch-edit.err"; then
	_pass "same-command issue-edit conflict fails safe to no-auto-dispatch"
else
	_fail "issue-edit dispatch conflict normalization" "argv: $(_read_argv) err: $(cat "$TMP/dispatch-edit.err" 2>/dev/null || true)"
fi

_reset_log
"$SHIM_RUN" api /repos/owner/repo/issues -f 'title=REST dispatch conflict' \
	-f 'body=Capture the issue.' -f 'labels[]=auto-dispatch' -f 'labels[]=no-auto-dispatch' \
	2>"$TMP/dispatch-rest.err"
if _argv_has_pair "-f" "labels[]=no-auto-dispatch" &&
	! _argv_has_pair "-f" "labels[]=auto-dispatch" &&
	grep -q '\[aidevops\]\[dispatch-labels\]\[NORMALIZE\]' "$TMP/dispatch-rest.err"; then
	_pass "REST issue creation cannot transport both dispatch-intent labels"
else
	_fail "REST dispatch conflict normalization" "argv: $(_read_argv) err: $(cat "$TMP/dispatch-rest.err" 2>/dev/null || true)"
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
