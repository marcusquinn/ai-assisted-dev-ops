#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export XDG_CONFIG_HOME="${TEST_ROOT}/config"
export AIDEVOPS_RUNNERS_DIR="${TEST_ROOT}/runners"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

(
	# shellcheck source=../cron-helper.sh
	source "${SCRIPTS_DIR}/cron-helper.sh"
	sync_crontab() { return 0; }
	cmd_add --schedule "0 9 * * *" --task "Review reports" --name "reports" \
		--model standard --provider anthropic --workdir "$TEST_ROOT" >/dev/null
	config_file="${XDG_CONFIG_HOME}/aidevops/cron-jobs.json"
	jq -e '.jobs[0] | .model == "standard" and .model_tier == "standard" and .provider == "anthropic"' \
		"$config_file" >/dev/null
)

job=$(jq -c '.jobs[0]' "${XDG_CONFIG_HOME}/aidevops/cron-jobs.json")
(
	# shellcheck source=../cron-dispatch.sh
	source "${SCRIPTS_DIR}/cron-dispatch.sh"
	resolve_job_config "$job"
	[[ "$JOB_TIER" == "standard" ]]
	[[ "$JOB_MODEL" == "anthropic/claude-sonnet-4-6" ]]
)

(
	# shellcheck source=../runner-helper.sh
	source "${SCRIPTS_DIR}/runner-helper.sh"
	cmd_create "report-runner" --model thinking --provider anthropic >/dev/null
	jq -e '.model == "thinking" and .model_tier == "thinking" and .provider == "anthropic"' \
		"${AIDEVOPS_RUNNERS_DIR}/report-runner/config.json" >/dev/null
	resolve_runner_route thinking anthropic
	[[ "$RUNNER_ROUTE_TIER" == "thinking" ]]
	[[ "$RUNNER_ROUTE_MODEL" == "anthropic/claude-opus-4-6" ]]
	[[ "$RUNNER_ROUTE_CANDIDATE_INDEX" == "1" ]]
	AIDEVOPS_DISPATCH_BACKEND=claude resolve_runner_route standard ""
	[[ "$RUNNER_ROUTE_MODEL" == "anthropic/claude-sonnet-4-6" ]]
)

printf 'PASS: scheduled jobs preserve tier intent and resolve current provider candidates at execution\n'
