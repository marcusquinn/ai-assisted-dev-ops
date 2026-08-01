#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-self-hosting-detector.sh — Regression tests for the self-hosting
# dispatch-path detector in pre-dispatch-validator-helper.sh (t2819)
#
# Tests:
#   test_positive_detection        — body with pulse-wrapper.sh triggers label
#   test_negative_detection        — docs-only body does not trigger
#   test_mixed_scope               — dispatch file + unrelated file → triggers
#   test_idempotency               — re-run on already-labeled issue is no-op
#   test_bypass_env_var            — AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1
#   test_dry_run_mode              — dry-run emits intent without mutation
#   test_collision_normalization   — lower tier labels are removed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../pre-dispatch-validator-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------
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
	# Prepend stub bin dir so our stubs override real commands
	export PATH="${TEST_ROOT}/bin:${PATH}"
	# Track label mutations and comments posted by the stub
	export GH_LABEL_LOG="${TEST_ROOT}/label_log.txt"
	export GH_COMMENT_LOG="${TEST_ROOT}/comment_log.txt"
	: >"$GH_LABEL_LOG"
	: >"$GH_COMMENT_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	# Unset test-specific env vars
	unset GH_LABEL_LOG GH_COMMENT_LOG 2>/dev/null || true
	unset AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# Stub factories
# ---------------------------------------------------------------------------

# Create a gh stub.
#
# Arguments:
#   $1 - body_file: path to a file containing the issue body text
#   $2 - labels: comma-separated label names (e.g. "tier:thinking,auto-dispatch")
#   $3 - existing_comments: "0" (no prior marker comment) or "1" (marker exists)
create_gh_stub() {
	local body_file="$1"
	local labels="$2"
	local existing_comments="${3:-0}"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

_label_log="${GH_LABEL_LOG}"
_comment_log="${GH_COMMENT_LOG}"

# Collect all args into a single string for pattern matching
_all_args="\$*"
_api_endpoint=""
if [[ "\${1:-}" == "api" ]]; then
	for _arg in "\$@"; do
		case "\$_arg" in
		repos/*) _api_endpoint="\$_arg"; break ;;
		esac
	done
fi

# gh api repos/<slug>/issues/<num>/comments — comment existence check
# (Check this BEFORE the /issues/<num> pattern to avoid false match)
if [[ "\${1:-}" == "api" ]] && printf '%s' "\$_api_endpoint" | grep -qE '/issues/[0-9]+/comments\$'; then
	printf '%s\n' "${existing_comments}"
	exit 0
fi

# gh api repos/<slug>/issues/<num> --jq '...'
if [[ "\${1:-}" == "api" ]] && printf '%s' "\$_api_endpoint" | grep -qE '/issues/[0-9]+\$'; then
	# Distinguish body vs labels call by scanning for the jq expression
	if printf '%s' "\$_all_args" | grep -qF 'labels'; then
		printf '%s\n' "${labels}"
		exit 0
	fi

	# Default: return issue body
	cat "${body_file}" 2>/dev/null || printf ''
	exit 0
fi

# gh issue edit — label application
if [[ "\${1:-}" == "issue" && "\${2:-}" == "edit" ]]; then
	printf '%s\n' "\$*" >> "\$_label_log"
	exit 0
fi

# gh issue comment — comment posting
if [[ "\${1:-}" == "issue" && "\${2:-}" == "comment" ]]; then
	printf '%s\n' "\$*" >> "\$_comment_log"
	exit 0
fi

# Fallback for any other gh invocation
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Create a body file with dispatch-path content
create_body_with_dispatch_path() {
	local body_file="${TEST_ROOT}/issue_body.txt"
	cat >"$body_file" <<'EOF'
## What

Fix the worker dispatch timeout handling.

## How

### Files to modify

- EDIT: `.agents/scripts/pulse-wrapper.sh:200-250` — fix timeout handling
- EDIT: `.agents/scripts/headless-runtime-helper.sh:400-420` — add retry logic

### Verification

```bash
shellcheck .agents/scripts/pulse-wrapper.sh
```
EOF
	printf '%s' "$body_file"
	return 0
}

# Create a body file with docs-only content (no dispatch-path files)
create_body_docs_only() {
	local body_file="${TEST_ROOT}/issue_body.txt"
	cat >"$body_file" <<'EOF'
## What

Update the contribution guide with new setup instructions.

## How

### Files to modify

- EDIT: `CONTRIBUTING.md` — add Docker setup section
- EDIT: `docs/getting-started.md` — update prerequisites
EOF
	printf '%s' "$body_file"
	return 0
}

# Create a mixed-scope body (dispatch file + unrelated file)
create_body_mixed_scope() {
	local body_file="${TEST_ROOT}/issue_body.txt"
	cat >"$body_file" <<'EOF'
## What

Refactor dispatch logging and update docs.

## How

### Files to modify

- EDIT: `docs/architecture.md` — update diagrams
- EDIT: `.agents/scripts/pulse-dispatch-engine.sh:100-150` — add structured logging
- EDIT: `.agents/reference/worker-diagnostics.md` — document new log format
EOF
	printf '%s' "$body_file"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# test_positive_detection — body references pulse-wrapper.sh → label applied
test_positive_detection() {
	setup_test_env
	local body_file
	body_file=$(create_body_with_dispatch_path)
	create_gh_stub "$body_file" "tier:standard,auto-dispatch" "0"

	local rc=0 output=""
	output=$("$HELPER_SCRIPT" validate "100" "marcusquinn/aidevops" 2>&1) || rc=$?

	# Should exit 0 (self-hosting detector is non-blocking)
	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	# Check that the label was applied
	local label_applied=1
	if grep -qF -- "--remove-label tier:standard --add-label tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		label_applied=0
	fi
	local mutation_signaled=1
	if printf '%s' "$output" | grep -qF "[aidevops:tier-labels-mutated]"; then
		mutation_signaled=0
	fi

	# Check that a comment was posted
	local comment_posted=1
	if [[ -s "$GH_COMMENT_LOG" ]]; then
		comment_posted=0
	fi

	if [[ "$exit_ok" -eq 0 && "$label_applied" -eq 0 && "$comment_posted" -eq 0 && "$mutation_signaled" -eq 0 ]]; then
		print_result "positive_detection: label applied + comment posted" 0
	else
		print_result "positive_detection: label applied + comment posted" 1 \
			"exit=${rc}, label=${label_applied}, comment=${comment_posted}, signal=${mutation_signaled} (all want 0)"
	fi

	teardown_test_env
	return 0
}

# test_negative_detection — docs-only body → no label applied
test_negative_detection() {
	setup_test_env
	local body_file
	body_file=$(create_body_docs_only)
	create_gh_stub "$body_file" "tier:standard,auto-dispatch" "0"

	local rc=0
	"$HELPER_SCRIPT" validate "101" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	# Label should NOT have been applied
	local label_not_applied=1
	if ! grep -qF "tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		label_not_applied=0
	fi

	if [[ "$exit_ok" -eq 0 && "$label_not_applied" -eq 0 ]]; then
		print_result "negative_detection: no label for docs-only" 0
	else
		print_result "negative_detection: no label for docs-only" 1 \
			"exit=${rc} (want 0), label_not_applied=${label_not_applied} (want 0)"
	fi

	teardown_test_env
	return 0
}

# test_mixed_scope — dispatch file + unrelated file → still triggers
test_mixed_scope() {
	setup_test_env
	local body_file
	body_file=$(create_body_mixed_scope)
	create_gh_stub "$body_file" "tier:standard,auto-dispatch" "0"

	local rc=0
	"$HELPER_SCRIPT" validate "102" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	local label_applied=1
	if grep -qF "tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		label_applied=0
	fi

	if [[ "$exit_ok" -eq 0 && "$label_applied" -eq 0 ]]; then
		print_result "mixed_scope: dispatch file + docs → label applied" 0
	else
		print_result "mixed_scope: dispatch file + docs → label applied" 1 \
			"exit=${rc} (want 0), label_applied=${label_applied} (want 0)"
	fi

	teardown_test_env
	return 0
}

# test_idempotency — issue already has tier:thinking → no new label or comment
test_idempotency() {
	setup_test_env
	local body_file
	body_file=$(create_body_with_dispatch_path)
	# Labels include tier:thinking already
	create_gh_stub "$body_file" "tier:thinking,auto-dispatch" "1"

	local rc=0
	"$HELPER_SCRIPT" validate "103" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	# No new label application should occur
	local no_label_mutation=1
	if [[ ! -s "$GH_LABEL_LOG" ]]; then
		no_label_mutation=0
	fi

	# No new comment should be posted
	local no_comment=1
	if [[ ! -s "$GH_COMMENT_LOG" ]]; then
		no_comment=0
	fi

	if [[ "$exit_ok" -eq 0 && "$no_label_mutation" -eq 0 && "$no_comment" -eq 0 ]]; then
		print_result "idempotency: already-labeled → no mutation" 0
	else
		print_result "idempotency: already-labeled → no mutation" 1 \
			"exit=${rc} (want 0), no_label=${no_label_mutation} (want 0), no_comment=${no_comment} (want 0)"
	fi

	teardown_test_env
	return 0
}

# test_bypass_env_var — AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1 → skips
test_bypass_env_var() {
	setup_test_env
	local body_file
	body_file=$(create_body_with_dispatch_path)
	create_gh_stub "$body_file" "tier:standard,auto-dispatch" "0"

	export AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1

	local rc=0
	"$HELPER_SCRIPT" validate "104" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	# No label should be applied (bypassed)
	local no_label=1
	if ! grep -qF "tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		no_label=0
	fi

	if [[ "$exit_ok" -eq 0 && "$no_label" -eq 0 ]]; then
		print_result "bypass_env_var: SKIP=1 prevents mutation" 0
	else
		print_result "bypass_env_var: SKIP=1 prevents mutation" 1 \
			"exit=${rc} (want 0), no_label=${no_label} (want 0)"
	fi

	teardown_test_env
	return 0
}

# test_dry_run_mode — emits what-would-be-applied without mutation
test_dry_run_mode() {
	setup_test_env
	local body_file
	body_file=$(create_body_with_dispatch_path)
	create_gh_stub "$body_file" "tier:standard,auto-dispatch" "0"

	export AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN=1

	local rc=0
	local output
	output=$("$HELPER_SCRIPT" validate "105" "marcusquinn/aidevops" 2>&1) || rc=$?

	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	# Should mention DRY-RUN in output
	local dry_run_logged=1
	if printf '%s' "$output" | grep -qF "DRY-RUN"; then
		dry_run_logged=0
	fi

	# No label should be applied
	local no_label=1
	if ! grep -qF "tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		no_label=0
	fi

	if [[ "$exit_ok" -eq 0 && "$dry_run_logged" -eq 0 && "$no_label" -eq 0 ]]; then
		print_result "dry_run_mode: logs intent without mutation" 0
	else
		print_result "dry_run_mode: logs intent without mutation" 1 \
			"exit=${rc} (want 0), dry_run_logged=${dry_run_logged} (want 0), no_label=${no_label} (want 0)"
	fi

	teardown_test_env
	return 0
}

# test_standard_elevates_to_thinking — dispatch-path work is promoted
test_standard_elevates_to_thinking() {
	setup_test_env
	local body_file
	body_file=$(create_body_with_dispatch_path)
	create_gh_stub "$body_file" "tier:standard,auto-dispatch" "0"

	local rc=0
	"$HELPER_SCRIPT" validate "106" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	local exit_ok=1
	[[ "$rc" -eq 0 ]] && exit_ok=0

	local label_applied=1
	if grep -qF -- "--remove-label tier:standard --add-label tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		label_applied=0
	fi

	if [[ "$exit_ok" -eq 0 && "$label_applied" -eq 0 ]]; then
		print_result "standard_elevates: tier:standard → tier:thinking" 0
	else
		print_result "standard_elevates: tier:standard → tier:thinking" 1 \
			"exit=${rc} (want 0), label_applied=${label_applied} (want 0)"
	fi

	teardown_test_env
	return 0
}

test_collision_normalization() {
	setup_test_env
	local body_file
	body_file=$(create_body_with_dispatch_path)
	create_gh_stub "$body_file" "tier:standard,tier:thinking,auto-dispatch" "1"

	local rc=0 output=""
	output=$("$HELPER_SCRIPT" validate "107" "marcusquinn/aidevops" 2>&1) || rc=$?
	local normalized=1 no_comment=1 signaled=1
	if grep -qF -- "--remove-label tier:standard --add-label tier:thinking" "$GH_LABEL_LOG" 2>/dev/null; then
		normalized=0
	fi
	if [[ ! -s "$GH_COMMENT_LOG" ]]; then
		no_comment=0
	fi
	if printf '%s' "$output" | grep -qF "[aidevops:tier-labels-mutated]"; then
		signaled=0
	fi

	if [[ "$rc" -eq 0 && "$normalized" -eq 0 && "$no_comment" -eq 0 && "$signaled" -eq 0 ]]; then
		print_result "collision_normalization: lower tier removed without duplicate comment" 0
	else
		print_result "collision_normalization: lower tier removed without duplicate comment" 1 \
			"exit=${rc}, normalized=${normalized}, no_comment=${no_comment}, signaled=${signaled} (all want 0)"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf 'Running self-hosting detector tests (t2819)...\n\n'

	if [[ ! -x "$HELPER_SCRIPT" ]]; then
		printf '%bERROR%b: Helper script not found or not executable: %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER_SCRIPT" >&2
		exit 1
	fi

	test_positive_detection
	test_negative_detection
	test_mixed_scope
	test_idempotency
	test_bypass_env_var
	test_dry_run_mode
	test_standard_elevates_to_thinking
	test_collision_normalization

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
