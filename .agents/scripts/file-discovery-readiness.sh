#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared readiness contract for the fd command used by agent discovery rules.

aidevops_fd_state() {
	if command -v fd >/dev/null 2>&1; then
		printf 'ready\n'
		return 0
	fi
	if command -v fdfind >/dev/null 2>&1; then
		printf 'compatibility\n'
		return 0
	fi
	printf 'missing\n'
	return 1
}

aidevops_ensure_fd_command() {
	local fdfind_path=""
	local shim_dir="${AIDEVOPS_FD_SHIM_DIR:-${HOME}/.local/bin}"
	local shim_path="${shim_dir}/fd"

	hash -r 2>/dev/null || true
	if command -v fd >/dev/null 2>&1; then
		return 0
	fi
	fdfind_path=$(command -v fdfind 2>/dev/null || true)
	if [[ "$fdfind_path" != /* ]]; then
		return 1
	fi
	mkdir -p "$shim_dir" || return 1
	if [[ -e "$shim_path" || -L "$shim_path" ]]; then
		[[ -x "$shim_path" ]] || return 1
		if [[ ":${PATH}:" != *":${shim_dir}:"* ]]; then
			export PATH="${shim_dir}:${PATH}"
		fi
		command -v fd >/dev/null 2>&1 || return 1
		return 0
	fi
	ln -sfn "$fdfind_path" "$shim_path" || return 1
	if [[ ":${PATH}:" != *":${shim_dir}:"* ]]; then
		export PATH="${shim_dir}:${PATH}"
	fi
	command -v fd >/dev/null 2>&1 || return 1
	return 0
}
