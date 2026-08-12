#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Descriptor-safe logging for helpers that optionally append to LOGFILE.

[[ -n "${_AIDEVOPS_DESCRIPTOR_SAFE_LOG_LOADED:-}" ]] && return 0
_AIDEVOPS_DESCRIPTOR_SAFE_LOG_LOADED=1

aidevops_log_line() {
	local message="$1"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '%s\n' "$message" >>"$LOGFILE"
		return $?
	fi
	printf '%s\n' "$message" >&2
	return $?
}

aidevops_run_with_log_stderr() {
	if [[ -n "${LOGFILE:-}" ]]; then
		"$@" 2>>"$LOGFILE"
		return $?
	fi
	"$@" 2>&2
	return $?
}
