#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-dedup-helper-enumerate-blockers.sh — t2894 regression guard.
#
# Verifies that enumerate_blockers() in dispatch-dedup-helper.sh:
#   - Reports ALL structural label blockers, not just the first
#   - Emits newline-separated tokens for each matched signal
#   - Blocks only CI failure-miner infrastructure advisories at dispatch time
#   - Returns exit 0 when at least one blocker is found, exit 1 when none
#   - Is backward-compatible with the is-assigned API (that contract unchanged)
#
# Modeled on test-dispatch-dedup-helper-is-assigned.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

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
	mkdir -p "${TEST_ROOT}/config/aidevops"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	unset AIDEVOPS_GH_FORCE_REST_READS
	unset AIDEVOPS_GH_REST_FIRST_READS
	unset _GH_SHOULD_FALLBACK_OVERRIDE

	# Minimal repos.json so the helper can resolve owner/maintainer.
	cat >"${TEST_ROOT}/config/aidevops/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "path": "/home/user/Git/aidevops",
      "slug": "marcusquinn/aidevops",
      "pulse": true,
      "maintainer": "marcusquinn-bot"
    }
  ]
}
EOF

	export REPOS_JSON="${TEST_ROOT}/config/aidevops/repos.json"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Create a gh stub that returns issue metadata with the given labels.
# Assignees default to empty (structural label checks don't need assignees).
create_gh_stub() {
	local labels_csv="${1:-}"
	local assignees_csv="${2:-}"
	local state="${3:-OPEN}"
	local assignees_json labels_json recent_ts

	assignees_json=$(
		ASSIGNEES_CSV="$assignees_csv" python3 - <<'PY'
import json, os
items=[i for i in os.environ.get('ASSIGNEES_CSV','').split(',') if i]
print(json.dumps([{"login": i} for i in items]))
PY
	)
	labels_json=$(
		LABELS_CSV="$labels_csv" python3 - <<'PY'
import json, os
items=[i for i in os.environ.get('LABELS_CSV','').split(',') if i]
print(json.dumps([{"name": i} for i in items]))
PY
	)

	recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
	printf '%s\n' '{"state":"${state}","assignees":${assignees_json},"labels":${labels_json},"createdAt":"${recent_ts}"}'
	exit 0
fi

if [[ "\${1:-}" == "api" && "\${2:-}" == "rate_limit" ]]; then
	printf '%s\n' '5000'
	exit 0
fi

if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -q '/comments'; then
	printf '%s\n' '[{"created_at":"${recent_ts}","author":"runner1","body_start":"Dispatching worker (PID 12345)"}]'
	exit 0
fi

if [[ "\${1:-}" == "issue" && ("\${2:-}" == "edit" || "\${2:-}" == "comment") ]]; then
	exit 0
fi

printf 'unsupported gh invocation in test stub: %s\n' "\$*" >&2
exit 1
GHEOF

	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# -------------------------------------------------------------------
# Test: no blockers → exit 1 (safe), empty stdout
# -------------------------------------------------------------------
test_no_blockers_returns_safe() {
	create_gh_stub "bug,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "no structural blockers → exit 1 (safe)" 1 "Expected exit 1 but got exit 0; output: '${output}'"
		return 0
	fi

	if [[ -n "$output" ]]; then
		print_result "no structural blockers → empty stdout" 1 "Expected empty stdout but got: '${output}'"
		return 0
	fi

	print_result "no structural blockers → exit 1 (safe) with empty stdout" 0
	return 0
}

# -------------------------------------------------------------------
# Test: only parent-task → exit 0, PARENT_TASK_BLOCKED emitted
# -------------------------------------------------------------------
test_parent_task_only() {
	create_gh_stub "parent-task,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "parent-task only → exit 0 (blocked)" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if printf '%s\n' "$output" | grep -q 'PARENT_TASK_BLOCKED'; then
		print_result "parent-task only → emits PARENT_TASK_BLOCKED" 0
	else
		print_result "parent-task only → emits PARENT_TASK_BLOCKED" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: publication:pending is an unconditional blocker even when positive
# dispatch labels are already present through a partial API mutation.
# -------------------------------------------------------------------
test_publication_pending_only() {
	create_gh_stub "publication:pending,auto-dispatch,status:available,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "publication:pending blocks positive dispatch labels" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if printf '%s\n' "$output" | grep -q 'PUBLICATION_PENDING_BLOCKED'; then
		print_result "publication:pending emits PUBLICATION_PENDING_BLOCKED" 0
	else
		print_result "publication:pending emits PUBLICATION_PENDING_BLOCKED" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: only no-auto-dispatch → exit 0, NO_AUTO_DISPATCH_BLOCKED emitted
# -------------------------------------------------------------------
test_no_auto_dispatch_only() {
	create_gh_stub "no-auto-dispatch,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "no-auto-dispatch only → exit 0 (blocked)" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if printf '%s\n' "$output" | grep -q 'NO_AUTO_DISPATCH_BLOCKED'; then
		print_result "no-auto-dispatch only → emits NO_AUTO_DISPATCH_BLOCKED" 0
	else
		print_result "no-auto-dispatch only → emits NO_AUTO_DISPATCH_BLOCKED" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: only hold-for-review → exit 0, HOLD_FOR_REVIEW_BLOCKED emitted
# -------------------------------------------------------------------
test_hold_for_review_only() {
	create_gh_stub "hold-for-review,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "hold-for-review only → exit 0 (blocked)" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if printf '%s\n' "$output" | grep -q 'HOLD_FOR_REVIEW_BLOCKED'; then
		print_result "hold-for-review only → emits HOLD_FOR_REVIEW_BLOCKED" 0
	else
		print_result "hold-for-review only → emits HOLD_FOR_REVIEW_BLOCKED" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: generic infrastructure work remains safe to dispatch
# -------------------------------------------------------------------
test_infrastructure_only() {
	create_gh_stub "infrastructure,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 1 ]]; then
		print_result "infrastructure only → exit 1 (safe)" 1 "Expected exit 1 but got exit ${exit_code}"
		return 0
	fi

	if [[ -z "$output" ]]; then
		print_result "infrastructure only → no structural blocker" 0
	else
		print_result "infrastructure only → no structural blocker" 1 "Unexpected output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: CI failure-miner infrastructure advisory remains blocked
# -------------------------------------------------------------------
test_infrastructure_advisory() {
	create_gh_stub "infrastructure,source:ci-failure-miner,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "infrastructure advisory → exit 0 (blocked)" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if [[ "$output" == *'INFRASTRUCTURE_BLOCKED'* && "$output" == *'source=source:ci-failure-miner'* ]]; then
		print_result "infrastructure advisory → stable blocker reason" 0
	else
		print_result "infrastructure advisory → stable blocker reason" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: parent-task, no-auto-dispatch, infrastructure, hold-for-review → all signals emitted
# This is the core multi-blocker regression guard (t2894).
# -------------------------------------------------------------------
test_multi_blocker_both_signals_emitted() {
	create_gh_stub "parent-task,publication:pending,no-auto-dispatch,infrastructure,source:ci-failure-miner,hold-for-review,tier:standard"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "multi-blocker: parent-task + no-auto-dispatch → exit 0 (blocked)" 1 \
			"Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	local parent_found=false publication_found=false nad_found=false infra_found=false hfr_found=false
	if printf '%s\n' "$output" | grep -q 'PARENT_TASK_BLOCKED'; then
		parent_found=true
	fi
	if printf '%s\n' "$output" | grep -q 'PUBLICATION_PENDING_BLOCKED'; then
		publication_found=true
	fi
	if printf '%s\n' "$output" | grep -q 'NO_AUTO_DISPATCH_BLOCKED'; then
		nad_found=true
	fi
	if printf '%s\n' "$output" | grep -q 'INFRASTRUCTURE_BLOCKED'; then
		infra_found=true
	fi
	if printf '%s\n' "$output" | grep -q 'HOLD_FOR_REVIEW_BLOCKED'; then
		hfr_found=true
	fi

	if [[ "$parent_found" == "true" && "$publication_found" == "true" && "$nad_found" == "true" && "$infra_found" == "true" && "$hfr_found" == "true" ]]; then
		print_result "multi-blocker: parent/publication/no-auto/infrastructure/hold signals emitted" 0
	else
		print_result "multi-blocker: parent/publication/no-auto/infrastructure/hold signals emitted" 1 \
			"Missing signals — parent_found=${parent_found} publication_found=${publication_found} nad_found=${nad_found} infra_found=${infra_found} hfr_found=${hfr_found}; output: '${output}'"
	fi

	# Count lines — must be exactly 5
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c '.' 2>/dev/null || true)
	if [[ "$line_count" -eq 5 ]]; then
		print_result "multi-blocker: exactly 5 lines emitted (one per signal)" 0
	else
		print_result "multi-blocker: exactly 5 lines emitted (one per signal)" 1 \
			"Expected 5 lines, got ${line_count}; output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: gh API failure → exit 0, GUARD_UNCERTAIN emitted (fail-closed)
# -------------------------------------------------------------------
test_api_failure_emits_guard_uncertain() {
	# gh stub that fails on issue view
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "gh API failure → exit 0 (fail-closed)" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if printf '%s\n' "$output" | grep -q 'GUARD_UNCERTAIN'; then
		print_result "gh API failure → emits GUARD_UNCERTAIN" 0
	else
		print_result "gh API failure → emits GUARD_UNCERTAIN" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: meta label (alias for parent-task) is also caught
# -------------------------------------------------------------------
test_meta_label_caught() {
	create_gh_stub "meta"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" enumerate-blockers 100 marcusquinn/aidevops 2>/dev/null) || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "meta label → exit 0 (blocked)" 1 "Expected exit 0 but got exit ${exit_code}"
		return 0
	fi

	if printf '%s\n' "$output" | grep -q 'PARENT_TASK_BLOCKED'; then
		print_result "meta label alias → emits PARENT_TASK_BLOCKED" 0
	else
		print_result "meta label alias → emits PARENT_TASK_BLOCKED" 1 "Signal not in output: '${output}'"
	fi
	return 0
}

# -------------------------------------------------------------------
# Test: backward compat — is-assigned API still returns first-match behavior
# -------------------------------------------------------------------
test_is_assigned_still_short_circuits() {
	create_gh_stub "parent-task,no-auto-dispatch"

	local output exit_code=0
	output=$("$HELPER_SCRIPT" is-assigned 100 marcusquinn/aidevops runner1 2>/dev/null) || exit_code=$?

	# is-assigned must still exit 0 (blocked) on first match
	if [[ "$exit_code" -ne 0 ]]; then
		print_result "is-assigned backward compat: still blocks on parent-task" 1 \
			"Expected exit 0 (blocked) but got exit ${exit_code}"
		return 0
	fi
	print_result "is-assigned backward compat: still blocks on parent-task" 0

	# is-assigned should emit exactly ONE signal (short-circuit, not both)
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c '.' 2>/dev/null || true)
	if [[ "$line_count" -le 1 ]]; then
		print_result "is-assigned backward compat: emits at most 1 signal (short-circuit preserved)" 0
	else
		print_result "is-assigned backward compat: emits at most 1 signal (short-circuit preserved)" 1 \
			"Expected ≤1 lines, got ${line_count}; output: '${output}'"
	fi
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_no_blockers_returns_safe
	test_parent_task_only
	test_publication_pending_only
	test_no_auto_dispatch_only
	test_hold_for_review_only
	test_infrastructure_only
	test_infrastructure_advisory
	test_multi_blocker_both_signals_emitted
	test_api_failure_emits_guard_uncertain
	test_meta_label_caught
	test_is_assigned_still_short_circuits

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
