#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/headless-runtime-metrics.jsonl"
export AIDEVOPS_ROUTING_FEEDBACK_HELPER="${SCRIPTS_DIR}/routing-feedback.mjs"
mkdir -p "$HOME/.aidevops/.agent-workspace/cron/r777"

cat >"$AIDEVOPS_HEADLESS_METRICS_FILE" <<'JSONL'
{"role":"worker","session_key":"routine-r777","model":"openai/gpt-5.6-terra","result":"complete","routing_tier":"standard","routing_candidate_index":0,"routing_attempt":1,"routing_reason":"headless_dispatch","routing_escalated":false}
JSONL

# shellcheck source=../routine-log-helper.sh
source "${SCRIPTS_DIR}/routine-log-helper.sh"

feedback=$(_routing_feedback_for_session "routine-r777")
period='{"total":1,"successes":1,"total_cost":"0.01","avg_duration":12,"period_start":"2026-08-01","period_end":"2026-08-07"}'
body=$(_build_issue_body "r777" "Agent routine" "daily(@06:00)" "agent" "active" \
	"2026-08-07T06:00:00Z" "success" 12 "2026-08-08T06:00:00Z" 1 success "0.01" "$period" "$feedback")

if [[ "$body" != *"### Routing feedback"* || "$body" != *'1 attempt'* || "$body" != *'No routing change is recommended'* ]]; then
	printf 'FAIL: routine body omitted completion routing feedback\n%s\n' "$body" >&2
	exit 1
fi

printf 'PASS: routine tracking body includes scoped routing feedback\n'
