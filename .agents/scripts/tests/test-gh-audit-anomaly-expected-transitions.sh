#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28997: expected signed approval transitions remain
# audited without generating daily anomaly issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../gh-audit-anomaly-helper.sh"
TEST_ROOT=""

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

TEST_ROOT="$(mktemp -d -t aidevops-gh-anomaly-XXXXXX)"
LOG_FILE="${TEST_ROOT}/gh-audit.log"

cat >"$LOG_FILE" <<'EOF'
{"ts":"2026-07-31T00:00:00Z","op":"issue_edit","repo":"example/repo","number":1,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","before":{"labels":["needs-maintainer-review"]},"after":{"labels":["auto-dispatch"]},"delta":{"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:01:00Z","op":"issue_edit","repo":"example/repo","number":2,"caller_script":"/workspace/.agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","before":{"labels":["needs-maintainer-review"]},"after":{"labels":[]},"delta":{"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:02:00Z","op":"issue_edit","repo":"example/repo","number":3,"caller_script":"/tmp/close-issue.sh","caller_function":"main","before":{"labels":["status:in-review"]},"after":{"labels":["status:done"]},"delta":{"labels_removed":["status:in-review"],"labels_added":["status:done"]},"suspicious":["protected_label_removed:status:in-review"]}
{"ts":"2026-07-31T00:03:00Z","op":"issue_edit","repo":"example/repo","number":4,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","before":{"labels":["needs-maintainer-review"]},"after":{"labels":["auto-dispatch"]},"delta":{"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review","body_delta_pct=-100"]}
EOF

output=$(GH_AUDIT_LOG_FILE="$LOG_FILE" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run)

[[ "$output" == *"**Anomalies found:** 2"* ]] || fail "expected transitions were not excluded exactly"
[[ "$output" == *"| #3 |"* ]] || fail "unexpected lifecycle transition was hidden"
[[ "$output" == *"| #4 |"* ]] || fail "approval transition with an additional signal was hidden"
[[ "$output" != *"| #1 |"* && "$output" != *"| #2 |"* ]] || fail "expected approval transition remained actionable"

printf 'PASS: expected approval transitions are retained in the log but excluded from alerts\n'
