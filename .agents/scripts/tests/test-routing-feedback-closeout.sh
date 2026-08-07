#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
export AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/headless-runtime-metrics.jsonl"
export AIDEVOPS_ROUTING_FEEDBACK_HELPER="${SCRIPTS_DIR}/routing-feedback.mjs"
export AGENTS_DIR="${TEST_ROOT}/missing-agents"
PULSE_START_EPOCH="$(date +%s)"
export PULSE_START_EPOCH
mkdir -p "$HOME/.aidevops/logs"

cat >"$AIDEVOPS_HEADLESS_METRICS_FILE" <<'JSONL'
{"role":"worker","session_key":"issue-42","session_id":"ses_a","repo_slug":"owner/repo","issue_number":42,"model":"openai/gpt-5.6-luna","result":"failed","routing_tier":"simple","routing_candidate_index":0,"routing_attempt":1,"routing_reason":"headless_dispatch","routing_escalated":false}
{"role":"worker","session_key":"issue-42","session_id":"ses_a","repo_slug":"owner/repo","issue_number":42,"model":"openai/gpt-5.6-terra","result":"complete","routing_tier":"standard","routing_candidate_index":0,"routing_attempt":2,"routing_reason":"capability_escalation","routing_escalated":true}
JSONL

# shellcheck source=../pulse-merge.sh
source "${SCRIPTS_DIR}/pulse-merge.sh"

body=$(_pm_build_closing_comment 99 "owner/repo" 42 "Delivered the routing change." main)
if [[ "$body" != *"### Routing feedback"* ]]; then
	printf 'FAIL: closeout omitted routing feedback\n%s\n' "$body" >&2
	exit 1
fi
route_pattern="\`simple\` → \`standard\`"
recommendation_pattern="starting at \`standard\`"
if [[ "$body" != *"$route_pattern"* || "$body" != *"$recommendation_pattern"* ]]; then
	printf 'FAIL: closeout routing evidence was incomplete\n%s\n' "$body" >&2
	exit 1
fi

fallback_body=$(_pm_build_closing_comment 99 "owner/repo" 42 "" main)
fallback_marker=$'\n_Merged by deterministic merge pass'
if [[ "$fallback_body" != *"$fallback_marker"* ]]; then
	printf 'FAIL: fallback closeout attribution was indented as a Markdown code block\n%s\n' "$fallback_body" >&2
	exit 1
fi

printf 'PASS: deterministic closeout includes scoped routing feedback\n'
