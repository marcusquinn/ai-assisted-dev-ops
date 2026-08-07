#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-dispatch-validator.sh — Test harness for pre-dispatch-validator-helper.sh (GH#19118)
#
# Tests:
#   test_ratchet_down_falsified     — validator returns exit 10 when scan reports no proposals
#   test_ratchet_down_legitimate    — validator returns exit 0 when scan reports proposals
#   test_unregistered_generator     — issue without marker returns exit 0
#   test_validator_error            — scan fails unexpectedly → exit 20
#   test_bypass_env_var             — AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 → exit 0
#   test_zero_progress_meta_recovered_blocks_dispatch — recovered meta issue → exit 10
#   test_zero_progress_meta_active_allows_dispatch    — active meta issue → exit 0
#   test_complexity_stall_recovered_blocks_dispatch   — resumed throughput → exit 10
#   test_complexity_stall_active_allows_dispatch      — zero throughput → exit 0

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
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${TEST_ROOT}/gh-secondary-cooldown.json"
	return 0
}

teardown_test_env() {
	unset PULSE_STATS_FILE
	unset AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Stub factories
# ---------------------------------------------------------------------------

# Create a `gh` stub that returns a specific issue body.
create_gh_stub_with_body() {
	local issue_body_file="$1"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

# gh api repos/<slug>/issues/<num> --jq '.body // ""'
if [[ "${1:-}" == "api" ]] && printf '%s' "${2:-}" | grep -qE '/issues/[0-9]+$'; then
	# Output a JSON object with the body from the file
	body_file="BODY_FILE_PLACEHOLDER"
	body=$(cat "$body_file" 2>/dev/null || echo "")
	printf '{"body": "%s"}\n' "$(printf '%s' "$body" | sed 's/"/\\"/g; s/\n/\\n/g')"
	exit 0
fi

# gh issue comment / gh issue close — succeed silently
if [[ "${1:-}" == "issue" ]]; then
	exit 0
fi

printf 'unsupported gh invocation in test stub: %s\n' "$*" >&2
exit 1
GHEOF

	# Replace the placeholder with the actual path
	sed -i "s|BODY_FILE_PLACEHOLDER|${issue_body_file}|g" "${TEST_ROOT}/bin/gh"
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Create a `gh` stub that returns a body with a ratchet-down generator marker.
# Uses a Python-based stub for reliable JSON escaping.
create_gh_stub_ratchet_body() {
	local marker_present="${1:-true}"

	local body_file="${TEST_ROOT}/issue_body.txt"
	if [[ "$marker_present" == "true" ]]; then
		printf '<!-- aidevops:generator=ratchet-down -->\n## Automated ratchet-down (t1913)\n' >"$body_file"
	else
		printf '## Some issue without a generator marker\n' >"$body_file"
	fi

	# Create a gh stub that uses python3 to safely JSON-encode the body
	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

# gh api repos/<slug>/issues/<num> with --jq '.body // ""'
if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	# Use --jq style: the helper calls gh api ... --jq '.body // ""'
	# so our stub must handle both "output the raw json" and "output the jq result"
	# We output the body directly as a JSON-encoded string
	body_file="${body_file}"
	python3 -c "
import json, sys
body = open('${body_file}').read()
# When --jq is used, gh outputs the jq result directly (unquoted string)
# Simulate that by printing the raw body
sys.stdout.write(body)
" 2>/dev/null
	exit 0
fi

# gh issue comment / gh issue close — succeed silently
if [[ "\${1:-}" == "issue" ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

create_gh_stub_zero_progress_body() {
	local permission_value="${1:-write}"
	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- merge-stuck:zero-progress -->\n## What\nZero-progress meta issue.\n' >"$body_file"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	python3 -c "import sys; sys.stdout.write(open('${body_file}').read())" 2>/dev/null
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && [[ "\${2:-}" == "user" ]]; then
	printf 'marcusquinn\n'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$*" | grep -qE '/repos/.*/collaborators/marcusquinn/permission'; then
	printf 'HTTP/2.0 200 OK\n\n{"permission":"${permission_value}"}\n'
	exit 0
fi

if [[ "\${1:-}" == "issue" ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

create_gh_stub_complexity_stall_body() {
	local recent_closures="$1"
	local permission_value="${2:-write}"
	local body_file="${TEST_ROOT}/issue_body.txt"
	local actions_file="${TEST_ROOT}/gh-actions.log"
	printf '<!-- aidevops:generator=complexity-stall-sweep stall_hours=6 -->\n## Simplification debt stall\n' >"$body_file"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	python3 -c "import sys; sys.stdout.write(open('${body_file}').read())" 2>/dev/null
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && [[ "\${2:-}" == "graphql" ]]; then
	printf '%s\n' '${recent_closures}'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && [[ "\${2:-}" == "user" ]]; then
	printf 'marcusquinn\n'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$*" | grep -qE '/repos/.*/collaborators/marcusquinn/permission'; then
	printf 'HTTP/2.0 200 OK\n\n{"permission":"${permission_value}"}\n'
	exit 0
fi

if [[ "\${1:-}" == "issue" ]]; then
	printf '%s\n' "\$*" >>'${actions_file}'
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

write_zero_progress_stats() {
	local gauge_value="$1"
	export PULSE_STATS_FILE="${TEST_ROOT}/pulse-stats.json"
	printf '{"gauges":{"pulse_merge_zero_progress_cycles":{"value":%s}}}\n' "$gauge_value" >"$PULSE_STATS_FILE"
	return 0
}

# Create a `complexity-scan-helper.sh` stub with configurable ratchet-check output.
create_scan_stub() {
	local mode="$1" # "no-proposals", "proposals", "error"

	cat >"${TEST_ROOT}/bin/complexity-scan-helper.sh" <<SCANEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "ratchet-check" ]]; then
	case "${mode}" in
		no-proposals)
			printf 'No ratchet-down available: all thresholds within gap of 5\n'
			exit 1
			;;
		proposals)
			printf 'FUNCTION_COMPLEXITY_THRESHOLD 120 → 110\n'
			exit 0
			;;
		error)
			printf '' >&2
			exit 2
			;;
	esac
fi

printf 'unsupported subcommand: %s\n' "\$*" >&2
exit 1
SCANEOF
	chmod +x "${TEST_ROOT}/bin/complexity-scan-helper.sh"
	return 0
}

# Create a `git` stub that simulates a successful shallow clone.
create_git_stub() {
	local mode="${1:-success}"

	cat >"${TEST_ROOT}/bin/git" <<GITEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "clone" ]]; then
	# Find the target directory (last non-flag argument)
	_target=""
	for _arg in "\$@"; do
		[[ "\$_arg" == --* ]] && continue
		_target="\$_arg"
	done
	if [[ "${mode}" == "success" ]]; then
		mkdir -p "\$_target"
		exit 0
	else
		printf 'fatal: repository not found\n' >&2
		exit 128
	fi
fi

# Pass-through for other git commands
/usr/bin/git "\$@"
GITEOF
	chmod +x "${TEST_ROOT}/bin/git"
	return 0
}

# Create a stub complexity-scan-helper.sh and export COMPLEXITY_SCAN_HELPER
# so the validator function uses it (via the env-override path).
setup_scan_stub_at_helper_path() {
	local mode="$1"
	create_scan_stub "$mode"
	export COMPLEXITY_SCAN_HELPER="${TEST_ROOT}/bin/complexity-scan-helper.sh"
	return 0
}

create_gh_stub_review_feedback() {
	local mode="$1"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

args="\$*"
mode="${mode}"

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	if printf '%s' "\$args" | grep -qF '.body // ""'; then
		case "\$mode" in
			extended-extension) printf 'quality debt kotlin coroutine MainActivity.kt\n' ;;
			review-followup-label) printf 'review followup changelog fixed \`CHANGELOG.md:18\`\n' ;;
			source-review-scanner-label) printf 'review scanner changelog fixed \`CHANGELOG.md:18\`\n' ;;
			whole-word) printf 'quality debt rate cache worker.sh\n' ;;
			version-directory) printf 'quality debt setup rollout v3.14.93/setup.sh\n' ;;
			*) printf 'unsupported review-feedback mode: %s\n' "\$mode" >&2; exit 1 ;;
		esac
		exit 0
	fi
	case "\$mode" in
		review-followup-label) printf '2026-05-07T00:00:00Z\tReview followup supersession test\treview-followup,source:review-scanner\n' ;;
		source-review-scanner-label) printf '2026-05-07T00:00:00Z\tReview followup supersession test\tsource:review-scanner\n' ;;
		*) printf '2026-05-07T00:00:00Z\tquality-debt supersession test\tquality-debt,source:review-feedback\n' ;;
	esac
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$args" | grep -qF 'search/issues'; then
	printf '99\n'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$args" | grep -qE 'pulls/99/files'; then
	if printf '%s' "\$args" | grep -qF '.[].filename'; then
		case "\$mode" in
			extended-extension) printf 'app/src/MainActivity.kt\n' ;;
			review-followup-label|source-review-scanner-label) printf 'CHANGELOG.md\n' ;;
			whole-word) printf 'worker.sh\n' ;;
			version-directory) printf 'v3.14.93/setup.sh\n' ;;
			*) printf 'unsupported review-feedback mode: %s\n' "\$mode" >&2; exit 1 ;;
		esac
	else
		case "\$mode" in
		extended-extension)
			printf 'app/src/MainActivity.kt\nfix kotlin coroutine reliability\n'
			;;
		review-followup-label|source-review-scanner-label)
			printf 'CHANGELOG.md\nmove changelog entries to fixed section\n'
			;;
		whole-word)
			printf 'worker.sh\ngenerate cache output\n'
			;;
		version-directory)
			printf 'v3.14.93/setup.sh\nfix setup rollout quality debt\n'
			;;
		*)
			printf 'unsupported review-feedback mode: %s\n' "\$mode" >&2
			exit 1
			;;
		esac
	fi
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/pulls/99\$'; then
	case "\$mode" in
		extended-extension)
			printf '2026-05-08T00:00:00Z\tfix kotlin coroutine reliability\tUpdates mobile handling\n'
			;;
		review-followup-label|source-review-scanner-label)
			printf '2026-05-08T00:00:00Z\tdocs: clean up changelog duplicates\tMoves changelog fixes under Fixed. Refs #50 #51\n'
			;;
		whole-word)
			printf '2026-05-08T00:00:00Z\tgenerate cache output\tUpdates cache handling\n'
			;;
		version-directory)
			printf '2026-05-08T00:00:00Z\tfix setup rollout quality debt\tUpdates setup handling\n'
			;;
		*)
			printf 'unsupported review-feedback mode: %s\n' "\$mode" >&2
			exit 1
			;;
	esac
	exit 0
fi

if [[ "\${1:-}" == "issue" ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

create_gh_stub_routed_review_feedback() {
	local candidate_merged_at="$1"
	local candidate_file="$2"
	local issue_metadata_mode="${3:-normal}"
	local actions_file="${TEST_ROOT}/review-actions.log"
	: >"$actions_file"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

args="\$*"
actions_file="${actions_file}"

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/47\$'; then
	if printf '%s' "\$args" | grep -qF '.body // ""'; then
		if [[ '${issue_metadata_mode}' == "empty-payload" ]]; then
			cat <<'BODYEOF'
Original implementation task.
<!-- feedback-route:start:review:PR73:SHAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:EVIDENCEfixture -->
<!-- feedback-route:complete:review:PR73:SHAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:EVIDENCEfixture -->
BODYEOF
		else
			cat <<'BODYEOF'
Original implementation task mentions broad overlay config work in TODO.md and todo/missions/example/mission.md.
<!-- feedback-route:start:review:PR73:SHAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:EVIDENCEfixture -->
## Review Feedback routed from PR #73 (t2093)

### Finding

The permission boundary escape remains in src/runtime-guard.sh:42; enforce the restricted capability guard.
<!-- feedback-route:complete:review:PR73:SHAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:EVIDENCEfixture -->
BODYEOF
		fi
	else
		case '${issue_metadata_mode}' in
		metadata-failure)
			exit 1
			;;
		missing-created)
			printf '\tOriginal implementation task\t\n'
			;;
		*)
			printf '2026-05-07T00:00:00Z\tOriginal implementation task\t\n'
			;;
		esac
	fi
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/pulls/73\$'; then
	if [[ '${issue_metadata_mode}' == "source-metadata-failure" ]]; then
		exit 1
	fi
	printf 'closed||2026-05-09T00:00:00Z\n'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$args" | grep -qE 'pulls/73/reviews'; then
	printf 'CHANGES_REQUESTED\t2026-05-08T12:00:00Z\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$args" | grep -qF 'search/issues'; then
	printf '99\n'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\$args" | grep -qE 'pulls/99/files'; then
	if printf '%s' "\$args" | grep -qF '.[].filename'; then
		printf '%s\n' '${candidate_file}'
	else
		printf '%s\npermission boundary escape restricted capability guard\n' '${candidate_file}'
	fi
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/pulls/99\$'; then
	printf '%s\tfix permission boundary escape\tenforce restricted capability guard\n' '${candidate_merged_at}'
	exit 0
fi

if [[ "\${1:-}" == "issue" ]]; then
	printf '%s\n' "\$args" >>"\$actions_file"
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

create_gh_stub_function_complexity_duplicate() {
	local body_file="${TEST_ROOT}/issue_body.txt"
	local actions_file="${TEST_ROOT}/gh-actions.log"
	printf '<!-- aidevops:generator=function-complexity-sweep cited_file=packages/gui-web/src/InventorySurfaces.tsx smell_count=3 -->\n## Qlty Maintainability\n' >"$body_file"
	: >"$actions_file"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

args="\$*"

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	python3 -c "import sys; sys.stdout.write(open('${body_file}').read())" 2>/dev/null
	exit 0
fi

if [[ "\${1:-}" == "issue" && "\${2:-}" == "list" ]] && printf '%s' "\$args" | grep -qF 'cited_file=packages/gui-web/src/InventorySurfaces.tsx'; then
	printf '25757\tstatus:available,function-complexity-debt\n25778\tstatus:available,function-complexity-debt\n'
	exit 0
fi

if [[ "\${1:-}" == "issue" && ( "\${2:-}" == "comment" || "\${2:-}" == "close" ) ]]; then
	printf '%s\n' "\$args" >>'${actions_file}'
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

create_gh_stub_function_complexity_missing_cited_file() {
	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=function-complexity-sweep smell_count=3 -->\n## Qlty Maintainability\n' >"$body_file"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	python3 -c "import sys; sys.stdout.write(open('${body_file}').read())" 2>/dev/null
	exit 0
fi

printf 'unexpected gh invocation for missing cited_file test: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# test_ratchet_down_falsified — stub scan returns "No ratchet-down available"
# Expected: validator exits 10
test_ratchet_down_falsified() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "no-proposals"

	local rc=0
	"$HELPER_SCRIPT" validate "42" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "ratchet_down_falsified exits 10" 0
	else
		print_result "ratchet_down_falsified exits 10" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_ratchet_down_legitimate — stub scan returns real proposals
# Expected: validator exits 0
test_ratchet_down_legitimate() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "proposals"

	local rc=0
	"$HELPER_SCRIPT" validate "43" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "ratchet_down_legitimate exits 0" 0
	else
		print_result "ratchet_down_legitimate exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_unregistered_generator — issue body without any generator marker
# Expected: validator exits 0 (unregistered generator fallback)
test_unregistered_generator() {
	setup_test_env
	create_gh_stub_ratchet_body "false"

	local rc=0
	"$HELPER_SCRIPT" validate "44" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "unregistered_generator exits 0" 0
	else
		print_result "unregistered_generator exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_validator_error — stub scan fails with non-zero and empty output
# Expected: validator exits 20
test_validator_error() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "error"

	local rc=0
	"$HELPER_SCRIPT" validate "45" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 20 ]]; then
		print_result "validator_error exits 20" 0
	else
		print_result "validator_error exits 20" 1 "Expected exit 20, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_bypass_env_var — AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1
# Expected: exits 0 regardless of issue content
test_bypass_env_var() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "no-proposals"

	local rc=0
	AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 "$HELPER_SCRIPT" validate "46" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "bypass_env_var exits 0" 0
	else
		print_result "bypass_env_var exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_zero_progress_meta_recovered_blocks_dispatch() {
	setup_test_env
	create_gh_stub_zero_progress_body "write"
	write_zero_progress_stats "0"

	local rc=0 output=""
	output=$("$HELPER_SCRIPT" validate "52" "marcusquinn/aidevops" 2>&1) || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "zero_progress meta recovered exits 10" 0
	else
		print_result "zero_progress meta recovered exits 10" 1 "Expected exit 10, got ${rc}: ${output}"
	fi

	teardown_test_env
	return 0
}

test_zero_progress_meta_recovered_readonly_allows_dispatch_without_write() {
	setup_test_env
	create_gh_stub_zero_progress_body "read"
	write_zero_progress_stats "0"

	local rc=0
	"$HELPER_SCRIPT" validate "54" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "zero_progress meta recovered read-only exits 0 without write" 0
	else
		print_result "zero_progress meta recovered read-only exits 0 without write" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_zero_progress_meta_active_allows_dispatch() {
	setup_test_env
	create_gh_stub_zero_progress_body "write"
	write_zero_progress_stats "5"

	local rc=0
	"$HELPER_SCRIPT" validate "53" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "zero_progress meta active exits 0" 0
	else
		print_result "zero_progress meta active exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_review_feedback_extended_extensions() {
	setup_test_env
	create_gh_stub_review_feedback "extended-extension"

	local rc=0
	"$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "review_feedback detects extended file extensions" 0
	else
		print_result "review_feedback detects extended file extensions" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_review_feedback_keyword_scoring_whole_words() {
	setup_test_env
	create_gh_stub_review_feedback "whole-word"

	local rc=0
	"$HELPER_SCRIPT" validate "48" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "review_feedback keyword scoring uses whole words" 0
	else
		print_result "review_feedback keyword scoring uses whole words" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_review_feedback_preserves_version_directory_paths() {
	setup_test_env
	create_gh_stub_review_feedback "version-directory"

	local rc=0
	"$HELPER_SCRIPT" validate "49" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "review_feedback preserves version-directory file paths" 0
	else
		print_result "review_feedback preserves version-directory file paths" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_review_followup_label_enters_supersession_scope() {
	setup_test_env
	create_gh_stub_review_feedback "review-followup-label"

	local rc=0
	"$HELPER_SCRIPT" validate "50" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "review_followup label enters supersession scope" 0
	else
		print_result "review_followup label enters supersession scope" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_source_review_scanner_label_enters_supersession_scope() {
	setup_test_env
	create_gh_stub_review_feedback "source-review-scanner-label"

	local rc=0
	"$HELPER_SCRIPT" validate "51" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "source_review_scanner label enters supersession scope" 0
	else
		print_result "source_review_scanner label enters supersession scope" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_routed_review_ignores_merge_before_requested_changes() {
	setup_test_env
	create_gh_stub_routed_review_feedback "2026-05-08T11:00:00Z" "TODO.md"

	local output=""
	local rc=0
	output=$("$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" 2>&1) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "routed_review ignores merge before requested changes" 0
	else
		print_result "routed_review ignores merge before requested changes" 1 "Expected exit 0, got ${rc}"
	fi
	if [[ "$output" == *"source=73 window=routed review window for closed unmerged source PR #73 after 2026-05-08T12:00:00Z"* ]]; then
		print_result "routed_review reports exact source and bounded window" 0
	else
		print_result "routed_review reports exact source and bounded window" 1 "Expected source PR and requested-change timestamp in rationale"
	fi
	if [[ ! -s "${TEST_ROOT}/review-actions.log" ]]; then
		print_result "routed_review leaves valid repair issue open" 0
	else
		print_result "routed_review leaves valid repair issue open" 1 "Unexpected issue mutation"
	fi

	teardown_test_env
	return 0
}

test_routed_review_closes_for_matching_post_review_merge() {
	setup_test_env
	create_gh_stub_routed_review_feedback "2026-05-08T13:00:00Z" "src/runtime-guard.sh"

	local rc=0
	"$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "routed_review closes for matching post-review merge" 0
	else
		print_result "routed_review closes for matching post-review merge" 1 "Expected exit 10, got ${rc}"
	fi
	if grep -qF 'Source PR:** #73' "${TEST_ROOT}/review-actions.log" &&
		grep -qF 'routed review window for closed unmerged source PR #73 after 2026-05-08T12:00:00Z' "${TEST_ROOT}/review-actions.log"; then
		print_result "routed_review close rationale identifies bounded source window" 0
	else
		print_result "routed_review close rationale identifies bounded source window" 1 "Expected exact source PR and bounded window in close rationale"
	fi

	teardown_test_env
	return 0
}

test_routed_review_metadata_failure_blocks_dispatch() {
	setup_test_env
	create_gh_stub_routed_review_feedback "2026-05-08T13:00:00Z" "src/runtime-guard.sh" "metadata-failure"

	local rc=0
	"$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 30 && ! -s "${TEST_ROOT}/review-actions.log" ]]; then
		print_result "routed_review metadata failure blocks dispatch without mutation" 0
	else
		print_result "routed_review metadata failure blocks dispatch without mutation" 1 "Expected exit 30 without issue mutation, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_routed_review_missing_created_at_blocks_dispatch() {
	setup_test_env
	create_gh_stub_routed_review_feedback "2026-05-08T13:00:00Z" "src/runtime-guard.sh" "missing-created"

	local rc=0
	"$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 30 && ! -s "${TEST_ROOT}/review-actions.log" ]]; then
		print_result "routed_review missing created_at blocks dispatch without mutation" 0
	else
		print_result "routed_review missing created_at blocks dispatch without mutation" 1 "Expected exit 30 without issue mutation, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_routed_review_source_metadata_failure_blocks_dispatch() {
	setup_test_env
	create_gh_stub_routed_review_feedback "2026-05-08T13:00:00Z" "src/runtime-guard.sh" "source-metadata-failure"

	local rc=0
	"$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 30 && ! -s "${TEST_ROOT}/review-actions.log" ]]; then
		print_result "routed_review source metadata failure blocks dispatch without mutation" 0
	else
		print_result "routed_review source metadata failure blocks dispatch without mutation" 1 "Expected exit 30 without issue mutation, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_routed_review_empty_payload_blocks_dispatch() {
	setup_test_env
	create_gh_stub_routed_review_feedback "2026-05-08T13:00:00Z" "src/runtime-guard.sh" "empty-payload"

	local rc=0
	"$HELPER_SCRIPT" validate "47" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 30 && ! -s "${TEST_ROOT}/review-actions.log" ]]; then
		print_result "routed_review empty payload blocks dispatch without mutation" 0
	else
		print_result "routed_review empty payload blocks dispatch without mutation" 1 "Expected exit 30 without issue mutation, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_function_complexity_sweep_duplicate_closes_later_issue() {
	setup_test_env
	create_gh_stub_function_complexity_duplicate

	local rc=0
	"$HELPER_SCRIPT" validate "25778" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "function_complexity_sweep duplicate later issue exits 10" 0
	else
		print_result "function_complexity_sweep duplicate later issue exits 10" 1 "Expected exit 10, got ${rc}"
	fi

	if grep -q "close 25778" "${TEST_ROOT}/gh-actions.log" 2>/dev/null; then
		print_result "function_complexity_sweep duplicate closes current issue" 0
	else
		print_result "function_complexity_sweep duplicate closes current issue" 1 "Expected close action for #25778"
	fi

	teardown_test_env
	return 0
}

test_function_complexity_sweep_missing_cited_file_allows_dispatch() {
	setup_test_env
	create_gh_stub_function_complexity_missing_cited_file

	local rc=0
	"$HELPER_SCRIPT" validate "25778" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "function_complexity_sweep missing cited_file allows dispatch" 0
	else
		print_result "function_complexity_sweep missing cited_file allows dispatch" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_complexity_stall_recovered_blocks_dispatch() {
	setup_test_env
	create_gh_stub_complexity_stall_body "2"

	local rc=0 output=""
	output=$("$HELPER_SCRIPT" validate "29393" "marcusquinn/aidevops" 2>&1) || rc=$?

	if [[ "$rc" -eq 10 ]] && grep -q "close 29393" "${TEST_ROOT}/gh-actions.log" 2>/dev/null; then
		print_result "complexity stall recovery closes stale meta issue" 0
	else
		print_result "complexity stall recovery closes stale meta issue" 1 "Expected exit 10 and close action, got ${rc}: ${output}"
	fi

	teardown_test_env
	return 0
}

test_complexity_stall_active_allows_dispatch() {
	setup_test_env
	create_gh_stub_complexity_stall_body "0"

	local rc=0
	"$HELPER_SCRIPT" validate "29393" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]] && [[ ! -s "${TEST_ROOT}/gh-actions.log" ]]; then
		print_result "active complexity stall remains dispatchable" 0
	else
		print_result "active complexity stall remains dispatchable" 1 "Expected exit 0 without close action, got ${rc}"
	fi

	teardown_test_env
	return 0
}

test_complexity_stall_recovered_readonly_fails_open() {
	setup_test_env
	create_gh_stub_complexity_stall_body "2" "read"

	local rc=0
	"$HELPER_SCRIPT" validate "29393" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 20 ]] && [[ ! -s "${TEST_ROOT}/gh-actions.log" ]]; then
		print_result "complexity stall recovery requires live write authority" 0
	else
		print_result "complexity stall recovery requires live write authority" 1 "Expected exit 20 without close action, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf 'Running pre-dispatch-validator tests (GH#19118)...\n\n'

	if [[ ! -x "$HELPER_SCRIPT" ]]; then
		printf '%bERROR%b: Helper script not found or not executable: %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER_SCRIPT" >&2
		exit 1
	fi

	test_ratchet_down_falsified
	test_ratchet_down_legitimate
	test_unregistered_generator
	test_validator_error
	test_bypass_env_var
	test_zero_progress_meta_recovered_blocks_dispatch
	test_zero_progress_meta_recovered_readonly_allows_dispatch_without_write
	test_zero_progress_meta_active_allows_dispatch
	test_complexity_stall_recovered_blocks_dispatch
	test_complexity_stall_active_allows_dispatch
	test_complexity_stall_recovered_readonly_fails_open
	test_review_feedback_extended_extensions
	test_review_feedback_keyword_scoring_whole_words
	test_review_feedback_preserves_version_directory_paths
	test_review_followup_label_enters_supersession_scope
	test_source_review_scanner_label_enters_supersession_scope
	test_routed_review_ignores_merge_before_requested_changes
	test_routed_review_closes_for_matching_post_review_merge
	test_routed_review_metadata_failure_blocks_dispatch
	test_routed_review_missing_created_at_blocks_dispatch
	test_routed_review_source_metadata_failure_blocks_dispatch
	test_routed_review_empty_payload_blocks_dispatch
	test_function_complexity_sweep_duplicate_closes_later_issue
	test_function_complexity_sweep_missing_cited_file_allows_dispatch

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
