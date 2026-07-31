#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

[[ -n "${_FAST_FAIL_RELEASE_POLICY_LOADED:-}" ]] && return 0
_FAST_FAIL_RELEASE_POLICY_LOADED=1

# Classify whether installing newer aidevops code can plausibly repair a failure.
# Unknown and source-state failures fail closed so new reason strings cannot
# silently acquire release-reset eligibility.
_fast_fail_release_reset_policy() {
	local reason="$1"
	local crash_type="${2:-}"
	if [[ "$crash_type" == "no_work" ]]; then
		printf '%s\n' "source-state-required"
		return 0
	fi
	case "$reason" in
	worker_launch_failed | no_worker_process | cli_usage_output | local_error | runtime | runtime_* | canary_failed | prelaunch_contract_failure)
		printf '%s\n' "release-sensitive"
		;;
	*)
		printf '%s\n' "source-state-required"
		;;
	esac
	return 0
}
