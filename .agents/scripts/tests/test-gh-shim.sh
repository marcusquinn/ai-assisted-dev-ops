#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for the gh PATH shim (t2685)
# =============================================================================
# Thin orchestrator for the hermetic gh shim harness. Focused cases live in:
#   - test-gh-shim-core-cases.sh: signing, pass-through, and basic read routing
#   - test-gh-shim-routing-cases.sh: REST fallback and repository write policy
#   - test-gh-shim-quota-cases.sh: exact REST and GraphQL quota attribution
#   - test-gh-shim-policy-cases.sh: issue brief advice and dispatch label safety
#
# Strategy: run the shim against a stub `gh` binary that logs its args, and
# a stub `gh-signature-helper.sh` that emits a predictable footer. Each sourced
# case module asserts the captured, potentially modified argument list.

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
if [[ "${1:-}" == api && -n "${STUB_TRANSPORT_RESPONSE_FILE:-}" ]]; then
	printf '%s\n' "$*" >>"$STUB_GH_CALL_LOG"
	cat "$STUB_TRANSPORT_RESPONSE_FILE"
	exit "${STUB_TRANSPORT_RC:-0}"
fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
	printf '%s\n' "${STUB_GH_USER:-managed}"
	exit 0
fi
if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/collaborators/[^/]+/permission$ ]]; then
	[[ "${STUB_GH_PERMISSION_FAIL:-0}" != "1" ]] || exit 44
	printf '%s\n' "${STUB_GH_PERMISSION:-none}"
	exit 0
fi
if [[ "$1" == "auth" && "$2" == "token" ]]; then
	printf '%s\n' 'fixture-token'
	exit 0
fi
if [[ -n "${STUB_GH_CALL_LOG:-}" ]]; then
	printf '%s\t%s\n' "${1:-}" "${2:-}" >>"$STUB_GH_CALL_LOG"
fi
if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/labels\?per_page=100$ ]]; then
	[[ "${STUB_MANAGED_LABEL_INVENTORY_FAIL:-0}" != "1" ]] || exit 42
	managed_labels="${STUB_MANAGED_LABELS-}"
	if [[ -z "${STUB_MANAGED_LABELS+x}" ]]; then
		managed_labels=$'origin:worker\norigin:interactive\norigin:worker-takeover\nstatus:in-review\nbug'
	fi
	printf '%s\n' "$managed_labels"
	exit 0
fi
if [[ "$1" == "label" && "$2" == "create" ]]; then
	[[ -z "${STUB_GH_LABEL_LOG:-}" ]] || printf '%s\n' "$*" >>"$STUB_GH_LABEL_LOG"
	[[ "${STUB_MANAGED_LABEL_CREATE_FAIL:-0}" != "1" ]] || exit 43
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
	[[ -z "${STUB_GH_DEBUG_PREFIX:-}" ]] || printf '%s\n' "$STUB_GH_DEBUG_PREFIX" >&2
	_stub_frame=1
	_stub_frame_total=1
	[[ "${STUB_GH_DEBUG_MULTI_FRAME:-0}" == "1" ]] && _stub_frame_total=3
	while [[ "$_stub_frame" -le "$_stub_frame_total" ]]; do
		_stub_used="${STUB_GH_DEBUG_USED:-201}"
		_stub_remaining="${STUB_GH_DEBUG_REMAINING:-4799}"
		if [[ "$_stub_frame_total" -gt 1 ]]; then
			_stub_used=$((${STUB_GH_DEBUG_MULTI_USED_BASE:-100} + _stub_frame - 1))
			_stub_remaining=$((${STUB_GH_DEBUG_MULTI_REMAINING_BASE:-4900} - _stub_frame + 1))
		fi
		printf '* Request at 2026-07-24 00:00:00 +0000 UTC\n' >&2
		[[ -z "${STUB_GH_DEBUG_HOST:-}" ]] || printf '> Host: %s\n' "$STUB_GH_DEBUG_HOST" >&2
		[[ -z "${STUB_GH_DEBUG_CACHE_TTL:-}" ]] || printf '> X-Gh-Cache-Ttl: %s\n' "$STUB_GH_DEBUG_CACHE_TTL" >&2
		printf '> Authorization: token private-fixture-token\n\n' >&2
		if [[ "${STUB_GH_DEBUG_REQUEST_ONLY:-0}" != "1" ]]; then
			printf '< HTTP/2.0 %s Fixture\n' "${STUB_GH_DEBUG_STATUS:-200}" >&2
			[[ -z "${STUB_GH_DEBUG_DATE:-}" ]] || printf '< Date: %s\n' "$STUB_GH_DEBUG_DATE" >&2
			printf '< X-Ratelimit-Resource: %s\n' "${STUB_GH_DEBUG_RESOURCE:-graphql}" >&2
			printf '< X-Ratelimit-Used: %s\n' "$_stub_used" >&2
			printf '< X-Ratelimit-Remaining: %s\n' "$_stub_remaining" >&2
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
		printf '* Request took %s\n' "${STUB_GH_DEBUG_DURATION:-12.5ms}" >&2
		_stub_frame=$((_stub_frame + 1))
	done
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
if [[ "${STUB_REST_READ_FAIL:-0}" == "1" && "$1" == "api" && \
	"$2" =~ ^/repos/[^/]+/[^/]+/(issues|pulls)(\?|/|$) ]]; then
	exit "${STUB_REST_READ_EXIT_CODE:-42}"
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
if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/issues/[0-9]+$ ]]; then
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
	fixture="${STUB_REST_ISSUE_VIEW_JSON:-}"
	if [[ -z "$fixture" ]]; then
		fixture='{"node_id":"I_kwDOFixture42","number":42,"state":"open","updated_at":"2026-07-28T19:38:58Z"}'
	fi
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$fixture" | jq -r -c "$jq_filter" || exit 1
	else
		printf '%s\n' "$fixture"
	fi
	exit 0
fi
if [[ "$1" == "issue" && "$2" == "view" && -n "${STUB_NATIVE_ISSUE_VIEW_JSON:-}" ]]; then
	printf '%s\n' "$STUB_NATIVE_ISSUE_VIEW_JSON"
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
cp "$REPO_DIR/.agents/scripts/gh-native-transport-lib.sh" "$TMP/scripts/gh-native-transport-lib.sh"
cp "$REPO_DIR/.agents/scripts/gh-api-guards-lib.sh" "$TMP/scripts/gh-api-guards-lib.sh"
cp "$REPO_DIR/.agents/scripts/managed-label-provisioning-lib.sh" "$TMP/scripts/managed-label-provisioning-lib.sh"
cp "$REPO_DIR/.agents/scripts/gh-write-policy-lib.sh" "$TMP/scripts/gh-write-policy-lib.sh"
cp "$REPO_DIR/.agents/scripts/gh-api-instrument.sh" "$TMP/scripts/gh-api-instrument.sh"
cp "$REPO_DIR/.agents/scripts/gh-quota-attribution-lib.sh" "$TMP/scripts/gh-quota-attribution-lib.sh"
cp "$REPO_DIR/.agents/scripts/gh-quota-debug-filter.py" "$TMP/scripts/gh-quota-debug-filter.py"
cp "$REPO_DIR/.agents/scripts/gh_quota_debug_response.py" "$TMP/scripts/gh_quota_debug_response.py"
cp "$REPO_DIR/.agents/scripts/shared-gh-wrappers-rest-fallback.sh" "$TMP/scripts/shared-gh-wrappers-rest-fallback.sh"
cp "$REPO_DIR/.agents/scripts/shared-gh-wrappers-rest-read-semantics.sh" "$TMP/scripts/shared-gh-wrappers-rest-read-semantics.sh"
cp "$REPO_DIR/.agents/scripts/log-issue-helper.sh" "$TMP/scripts/log-issue-helper.sh"
# Caller attribution accepts only verified framework script basenames that are
# present beside the shim. A zero-byte fixture is sufficient for that identity
# check; it is never executed by this harness.
: >"$TMP/scripts/pulse-wrapper.sh"
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
export STUB_GH_CALL_LOG="$TMP/gh-call.log"
export STUB_GH_LABEL_LOG="$TMP/gh-label.log"

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
	: >"$STUB_GH_CALL_LOG"
	: >"$STUB_GH_LABEL_LOG"
	unset STUB_MANAGED_LABELS
	unset STUB_MANAGED_LABEL_INVENTORY_FAIL
	unset STUB_MANAGED_LABEL_CREATE_FAIL
	unset STUB_GH_PERMISSION
	unset STUB_GH_PERMISSION_FAIL
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

# --- Focused test modules ---

# shellcheck source=./test-gh-shim-core-cases.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-gh-shim-core-cases.sh"

# shellcheck source=./test-gh-shim-routing-cases.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-gh-shim-routing-cases.sh"

# shellcheck source=./test-gh-shim-quota-cases.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-gh-shim-quota-cases.sh"

# shellcheck source=./test-gh-shim-policy-cases.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-gh-shim-policy-cases.sh"

# shellcheck source=./test-gh-shim-transport-cases.sh
source "${SCRIPT_DIR}/test-gh-shim-transport-cases.sh"

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
