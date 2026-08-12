#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Service setup functions for setup.sh

# Setup SSH key
setup_ssh_key() {
	# TODO: Extract from setup.sh lines 2690-2708
	:
	return 0
}

# Setup configs (credentials, repos, etc.)
setup_configs() {
	# TODO: Extract from setup.sh lines 2711-2732
	:
	return 0
}

# Setup terminal title
setup_terminal_title() {
	# TODO: Extract from setup.sh lines 2951-3020
	:
	return 0
}

# Setup Python environment
setup_python_env() {
	# TODO: Extract from setup.sh lines 3814-3870
	:
	return 0
}

# Setup Node.js environment
setup_nodejs_env() {
	# TODO: Extract from setup.sh lines 3873-3906
	:
	return 0
}

# Setup Node.js
setup_nodejs() {
	# TODO: Extract from setup.sh lines 4650-4768
	:
	return 0
}

# Run a command with a portable timeout. Prefer shared timeout_sec when setup.sh
# has sourced shared-constants.sh; fall back to GNU/BSD timeout variants and a
# small Bash watchdog so direct unit tests of this module stay bounded too.
_setup_opencode_timeout_cmd() {
	local timeout_seconds="$1"
	shift

	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=5
	[[ "$timeout_seconds" -gt 0 ]] || timeout_seconds=5

	if declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec "$timeout_seconds" "$@"
		return $?
	fi

	if command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$timeout_seconds" "$@"
		return $?
	fi

	if command -v timeout >/dev/null 2>&1; then
		timeout "$timeout_seconds" "$@"
		return $?
	fi

	local output_file=""
	output_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-opencode-timeout.XXXXXX" 2>/dev/null || printf '')
	if [[ -z "$output_file" ]]; then
		"$@"
		return $?
	fi

	local pid=""
	"$@" >"$output_file" 2>&1 &
	pid=$!

	local elapsed=0
	while kill -0 "$pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			rm -f "$output_file" 2>/dev/null || true
			return 124
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	local rc=0
	wait "$pid" || rc=$?
	while IFS= read -r line; do
		printf '%s\n' "$line"
	done <"$output_file"
	rm -f "$output_file" 2>/dev/null || true
	return "$rc"
}

_setup_opencode_version_output() {
	local bin="$1"
	local version_timeout="${AIDEVOPS_OPENCODE_VERSION_TIMEOUT:-5}"
	local version_path=""

	version_path=$(_setup_opencode_node_path_for_binary "$bin")
	PATH="${version_path}${PATH:+:${PATH}}" _setup_opencode_timeout_cmd "$version_timeout" "$bin" --version
	return $?
}

_setup_opencode_help_output() {
	local bin="$1"
	local help_timeout="${AIDEVOPS_OPENCODE_VERSION_TIMEOUT:-5}"
	local help_path=""

	help_path=$(_setup_opencode_node_path_for_binary "$bin")
	PATH="${help_path}${PATH:+:${PATH}}" _setup_opencode_timeout_cmd "$help_timeout" "$bin" --help
	return $?
}

_setup_opencode_help_identifies_opencode() {
	local help_output="$1"

	[[ -n "$help_output" ]] || return 1

	# Prefer OpenCode's canonical command synopsis, but accept equivalent
	# spacing/placeholders so small help text formatting changes do not break
	# setup healing.
	if [[ "$help_output" =~ opencode[[:space:]]+run ]] &&
		[[ "$help_output" =~ message ]]; then
		return 0
	fi

	# Fallback for help formats that keep the command description but omit the
	# full synopsis from compact output.
	if [[ "$help_output" =~ run[[:space:]]+opencode[[:space:]]+with[[:space:]]+a[[:space:]]+message ]]; then
		return 0
	fi

	return 1
}

_setup_opencode_first_line() {
	local input="$1"
	local first_line=""

	IFS= read -r first_line <<<"$input" || true
	printf '%s\n' "$first_line"
	return 0
}

_setup_opencode_node_path_for_binary() {
	local bin="$1"
	local bin_dir=""
	local path_value=""

	if [[ -n "$bin" ]]; then
		bin_dir=$(dirname "$bin" || printf '')
		[[ "$bin_dir" == /* ]] || bin_dir=""
	fi
	path_value="${bin_dir:+$bin_dir:}${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts:/usr/local/bin:/usr/bin:/bin"
	printf '%s\n' "$path_value"
	return 0
}

_setup_opencode_binary_is_ephemeral() {
	local bin="$1"
	local temp_root="${TMPDIR:-}"

	while [[ "$temp_root" == */ && "$temp_root" != "/" ]]; do
		temp_root="${temp_root%/}"
	done
	if [[ "$temp_root" == "/" && "$bin" == /* ]]; then
		return 0
	fi
	if [[ -n "$temp_root" && "$bin" == "$temp_root"/* ]]; then
		return 0
	fi

	case "$bin" in
	/tmp/* | /private/tmp/* | /var/tmp/* | /var/folders/*/*/T/* | /private/var/folders/*/*/T/*) return 0 ;;
	esac

	return 1
}

_setup_clear_canary_negative_cache() {
	local state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	rm -f "${state_dir}/canary-last-fail" "${state_dir}/canary-last-fail.reason" 2>/dev/null || true
	return 0
}

_setup_opencode_managed_shim_target() {
	local shim_path="${1:-}"
	local exec_line=""

	[[ -f "$shim_path" ]] || return 1
	grep -Fq '# aidevops:terminal-title-owner' "$shim_path" 2>/dev/null || return 1
	exec_line=$(grep '^exec "' "$shim_path" 2>/dev/null || true)
	if [[ "$exec_line" =~ ^exec[[:space:]]+\"([^\"]+)\" ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 1
}

_setup_ensure_opencode_stable_shim() {
	local real_bin="${1:-}"
	local shim_dir="${HOME}/.local/bin"
	local shim_path="${shim_dir}/opencode"
	local resolved_bin=""
	local wrapper_path=""
	local wrapper_dir=""
	local wrapper_path_value=""
	local temp_shim=""

	[[ -n "$real_bin" ]] || return 1
	resolved_bin=$(command -v "$real_bin" 2>/dev/null || printf '%s' "$real_bin")
	if [[ "$resolved_bin" == "$shim_path" ]]; then
		resolved_bin=$(_setup_find_valid_opencode_binary) || return 1
	fi
	_setup_validate_opencode_binary "$resolved_bin" || return 1
	if _setup_opencode_binary_is_ephemeral "$resolved_bin" && \
		! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
		return 1
	fi

	mkdir -p "$shim_dir" 2>/dev/null || return 1
	wrapper_dir=$(cd "$(dirname "$resolved_bin")" 2>/dev/null && pwd -P) || return 1
	wrapper_path="${wrapper_dir}/$(basename "$resolved_bin")"
	if _setup_opencode_binary_is_ephemeral "$wrapper_path" && \
		! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
		return 1
	fi
	if [[ "$resolved_bin" != "$shim_path" ]] && \
		_setup_validate_opencode_binary "$shim_path" && \
		[[ "$(_setup_opencode_managed_shim_target "$shim_path" 2>/dev/null || true)" == "$wrapper_path" ]]; then
		printf '%s\n' "$shim_path"
		return 0
	fi
	wrapper_path_value=$(_setup_opencode_node_path_for_binary "$wrapper_path")

	temp_shim="${shim_path}.tmp.$$"
	cat >"$temp_shim" <<EOF || { printf 'Failed to write OpenCode shim: %s\n' "$shim_path" >&2; return 1; }
#!/usr/bin/env bash
# Generated by aidevops setup: daemon-safe OpenCode shim.
# aidevops:terminal-title-owner
export PATH="$wrapper_path_value\${PATH:+:\$PATH}"
export AIDEVOPS_TERMINAL_TITLE_OWNER="\${AIDEVOPS_TERMINAL_TITLE_OWNER:-aidevops}"
if [[ "\$AIDEVOPS_TERMINAL_TITLE_OWNER" == "aidevops" ]]; then
	export OPENCODE_DISABLE_TERMINAL_TITLE="\${OPENCODE_DISABLE_TERMINAL_TITLE:-1}"
fi
exec "$wrapper_path" "\$@"
EOF
	chmod +x "$temp_shim" 2>/dev/null || {
		rm -f "$temp_shim" 2>/dev/null || true
		return 1
	}
	mv -f "$temp_shim" "$shim_path" 2>/dev/null || {
		rm -f "$temp_shim" 2>/dev/null || true
		return 1
	}

	_setup_validate_opencode_binary "$shim_path" || return 1
	_setup_clear_canary_negative_cache
	printf '%s\n' "$shim_path"
	return 0
}

_setup_find_valid_opencode_binary() {
	local preferred_bin="${1:-}"
	local candidate=""
	local candidate_path=""
	local shim_path="${HOME}/.local/bin/opencode"
	local managed_shim_target=""

	managed_shim_target=$(_setup_opencode_managed_shim_target "$shim_path" 2>/dev/null || true)

	for candidate in \
		"$preferred_bin" \
		/opt/homebrew/bin/opencode \
		/usr/local/bin/opencode \
		/home/linuxbrew/.linuxbrew/bin/opencode \
		"${HOME}/.npm-global/bin/opencode" \
		"${HOME}/.bun/bin/opencode" \
		"$managed_shim_target" \
		opencode; do
		[[ -n "$candidate" ]] || continue
		[[ "$candidate" == "$shim_path" ]] && continue
		candidate_path=$(command -v "$candidate" 2>/dev/null || printf '%s' "$candidate")
		[[ "$candidate_path" == "$shim_path" ]] && continue
		_setup_opencode_binary_is_ephemeral "$candidate_path" && continue
		if _setup_validate_opencode_binary "$candidate_path"; then
			printf '%s\n' "$candidate_path"
			return 0
		fi
	done

	return 1
}

_setup_record_valid_opencode_binary() {
	local valid_bin="$1"
	local valid_version=""
	local stable_bin=""

	[[ -n "$valid_bin" ]] || return 1
	valid_version=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$valid_bin" 2>/dev/null || printf 'unknown')")
	stable_bin=$(_setup_ensure_opencode_stable_shim "$valid_bin") || {
		print_warning "OpenCode stable shim verification failed for '$valid_bin'"
		return 1
	}
	print_success "OpenCode CLI: $valid_bin ($valid_version)"
	mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
	printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
	return 0
}

_setup_find_valid_opencode_alternative() {
	local current_bin="$1"
	local validate_rc="$2"
	local valid_bin=""

	[[ "$validate_rc" -ne 0 ]] || return 1
	valid_bin=$(_setup_find_valid_opencode_binary "$current_bin" 2>/dev/null || printf '')
	[[ -n "$valid_bin" && "$valid_bin" != "$current_bin" ]] || return 1

	printf '%s\n' "$valid_bin"
	return 0
}

# Validate that an opencode binary is real anomalyco/opencode (t2888, mirrors t2887 validator).
# Returns: 0=valid, 1=wrong package, 2=missing/unrunnable.
# Inlined (not sourced from headless-runtime-lib.sh) so this module stays self-contained
# and runnable from `setup.sh --non-interactive` without sourcing the full runtime stack.
_setup_validate_opencode_binary() {
	local bin="${1:-}"
	[[ -n "$bin" ]] || return 2
	command -v "$bin" >/dev/null 2>&1 || return 2

	local version_output
	version_output=$(_setup_opencode_version_output "$bin" 2>/dev/null || printf '')
	[[ -n "$version_output" ]] || return 2
	local help_output
	help_output=$(_setup_opencode_help_output "$bin" 2>/dev/null || printf '')
	[[ -n "$help_output" ]] || return 2

	# Anthropic claude CLI signature -- highest-confidence rejection
	[[ "$version_output" == *"(Claude Code)"* ]] && return 1

	# opencode is at 1.x; any 2.x+ is wrong (claude CLI is 2.1.x)
	[[ "$version_output" =~ ^[2-9][0-9]*\. ]] && return 1

	# Sanity check: must look like a semver (X.Y.Z)
	[[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1

	# Positive OpenCode identity check. Qwen and other CLIs can return a
	# semver-compatible --version (for example 0.2.1), so version shape alone is
	# not enough. Require OpenCode's command surface before writing/accepting the
	# stable ~/.local/bin/opencode shim used by Tabby and workers.
	_setup_opencode_help_identifies_opencode "$help_output" || return 1

	return 0
}

# Setup OpenCode CLI -- install/heal anomalyco/opencode (t2888).
#
# Why this exists: aidevops is built on opencode/Claude Code; the framework
# is supposed to ensure the CLI is present and correct. This function was
# a no-op stub since PR #20189 (t316.3 module extraction never ported the
# install body), so `aidevops update` never installed or healed opencode.
# Companion to t2887 (canary fail-fast) -- t2887 detects, this one heals.
#
# Behaviour:
#   1. Resolve current binary via $OPENCODE_BIN, then `command -v opencode`.
#   2. Validate via _setup_validate_opencode_binary (semver shape, no Claude
#      Code marker, major <= 1).
#   3. If invalid/missing: install opencode-ai@latest via bun (preferred)
#      or npm. The npm install overwrites whatever currently owns the
#      `opencode` bin symlink, healing wrong-package collisions.
#   4. Re-validate after install. Persist resolved path to
#      ~/.aidevops/.opencode-bin-resolved for diagnostics.
#
# Idempotent: skips install when validator passes. Safe in non-interactive
# (no prompts -- always installs when needed). Fail-open on errors so a
# missing toolchain (no bun/npm) doesn't block the rest of setup.
setup_opencode_cli() {
	local current_bin="${OPENCODE_BIN:-}"
	[[ -z "$current_bin" ]] && current_bin=$(command -v opencode 2>/dev/null || echo "")

	# Validate current state.
	local validate_rc=0
	if [[ -n "$current_bin" ]]; then
		_setup_validate_opencode_binary "$current_bin" || validate_rc=$?
	else
		validate_rc=2
	fi
	local valid_bin=""
	valid_bin=$(_setup_find_valid_opencode_alternative "$current_bin" "$validate_rc" 2>/dev/null || printf '')
	if [[ -n "$valid_bin" ]]; then
		_setup_record_valid_opencode_binary "$valid_bin"
		return $?
	fi

	# Already valid -- record + exit fast.
	if [[ $validate_rc -eq 0 ]]; then
		local v
		v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf 'unknown')")
		local stable_bin
		stable_bin=$(_setup_ensure_opencode_stable_shim "$current_bin") || {
			print_warning "OpenCode stable shim verification failed for '$current_bin'"
			return 1
		}
		print_success "OpenCode CLI: $current_bin ($v)"
		mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
		printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
		return 0
	fi

	# Diagnose what we found.
	if [[ $validate_rc -eq 1 ]]; then
		local wrong_version
		wrong_version=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf '<unknown>')")
		print_warning "OpenCode binary at '$current_bin' is the wrong package ('$wrong_version')"
		print_info "Forcing reinstall of opencode-ai@latest to heal the bin collision (t2888)..."
	else
		print_info "OpenCode CLI not found -- installing opencode-ai@latest..."
	fi

	# Pick installer. Prefer bun (faster), fall back to npm.
	local installer=""
	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found -- cannot install opencode-ai"
		print_info "Install Node.js or Bun first, then re-run 'aidevops update'"
		return 0
	fi

	# Install. opencode-ai@latest, global. npm install -g overwrites the
	# bin symlink even when another package (e.g. @anthropic-ai/claude-code)
	# previously owned the `opencode` name -- last-installed wins.
	local install_timeout="${AIDEVOPS_OPENCODE_INSTALL_TIMEOUT:-180}"
	if _setup_opencode_timeout_cmd "$install_timeout" "$installer" install -g opencode-ai@latest >/dev/null 2>&1; then
		print_success "opencode-ai installed via $installer"
	else
		print_warning "opencode-ai install via $installer failed"
		print_info "Try manually: $installer install -g opencode-ai@latest"
		return 0
	fi

	# Re-resolve and re-validate.
	current_bin=$(_setup_find_valid_opencode_binary "$(command -v opencode 2>/dev/null || echo "")" 2>/dev/null || echo "")
	validate_rc=0
	if [[ -n "$current_bin" ]]; then
		_setup_validate_opencode_binary "$current_bin" || validate_rc=$?
	else
		validate_rc=2
	fi

	if [[ $validate_rc -eq 0 ]]; then
		local v
		v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf 'unknown')")
		local stable_bin
		stable_bin=$(_setup_ensure_opencode_stable_shim "$current_bin") || {
			print_warning "OpenCode stable shim verification failed for '$current_bin'"
			return 1
		}
		print_success "OpenCode CLI: $current_bin ($v)"
		mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
		printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
	else
		# Post-install still wrong -- another `opencode` is earlier on PATH
		# than the npm/bun bin dir. The t2887 fallback path search will pick
		# this up at runtime, but flag it so the user knows.
		local v
		v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf '<missing>')")
		print_warning "Post-install validation still failing: '$current_bin' returns '$v'"
		print_info "Check PATH ordering: 'which -a opencode' and ensure the npm/bun global bin dir is first"
		return 1
	fi

	return 0
}

# Setup OrbStack VM
setup_orbstack_vm() {
	# TODO: Extract from setup.sh lines 4826-4863
	:
	return 0
}

# Setup AI orchestration
setup_ai_orchestration() {
	# TODO: Extract from setup.sh lines 4866-4924
	:
	return 0
}

# Setup safety hooks
setup_safety_hooks() {
	# TODO: Extract from setup.sh lines 4927-4956
	:
	return 0
}

# Setup OpenCode plugins
setup_opencode_plugins() {
	# TODO: Extract from setup.sh lines 5000-5037
	:
	return 0
}

# Setup SEO MCPs
setup_seo_mcps() {
	# TODO: Extract from setup.sh lines 5040-5075
	:
	return 0
}

# Setup Google Analytics MCP
setup_google_analytics_mcp() {
	# TODO: Extract from setup.sh lines 5078-5182
	:
	return 0
}

# Setup QuickFile MCP
setup_quickfile_mcp() {
	# TODO: Extract from setup.sh lines 5185-5280
	:
	return 0
}

# Setup multi-tenant credentials
setup_multi_tenant_credentials() {
	# TODO: Extract from setup.sh lines 5283-5344
	:
	return 0
}

# Setup LocalWP MCP
setup_localwp_mcp() {
	# TODO: Extract from setup.sh lines 4100-4147
	:
	return 0
}

# Setup Beads (task management)
setup_beads() {
	# TODO: Extract from setup.sh lines 4364-4419
	:
	return 0
}

# Setup Beads UI
setup_beads_ui() {
	# TODO: Extract from setup.sh lines 4422-4524
	:
	return 0
}
