#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# MCP setup functions: install_mcp_packages, resolve_mcp_binary, localwp, seo, analytics, quickfile, browser-tools, opencode-plugins
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

_mcp_package_supported_on_platform() {
	local package="$1"
	local platform="${2:-}"
	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null || printf '%s' "unknown")
	fi
	if [[ "$package" == "@steipete/macos-automator-mcp" && "$platform" != "Darwin" ]]; then
		return 1
	fi
	return 0
}

_install_mcp_packages_node() {
	# Install/update Node.js MCP packages globally.
	# Security note: MCP servers run as persistent processes with access to conversation
	# context, credentials, and network. The packages below are from known/vetted sources.
	# Before adding new MCP packages to this list, verify the source repository and scan
	# dependencies with: npx @socketsecurity/cli npm info <package>
	# See: .agents/tools/mcp-toolkit/mcporter.md "Security Considerations"
	local -a node_mcps=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
	)

	local installer="npm"
	command -v bun &>/dev/null && installer="bun"
	print_info "Using $installer to install/update Node.js MCP packages..."

	# Install reviewed pins where required; keep other MCPs current.
	local updated=0
	local failed=0
	local pkg
	for pkg in "${node_mcps[@]}"; do
		_mcp_package_supported_on_platform "$pkg" || continue
		local short_name="${pkg##*/}" # Strip @scope/ prefix for display
		local package_spec="${pkg}@latest"
		[[ "$pkg" == "playwriter" ]] && package_spec="playwriter@0.5.0"
		if run_with_spinner "Installing $short_name" npm_global_install "$package_spec"; then
			((++updated))
		else
			((++failed))
			print_warning "Failed to install/update $pkg"
		fi
	done

	if [[ $updated -gt 0 ]]; then
		print_success "$updated Node.js MCP packages installed/updated via $installer"
	fi
	if [[ $failed -gt 0 ]]; then
		print_warning "$failed packages failed (check network or package names)"
	fi
	return 0
}

_install_mcp_packages_python() {
	# Install/update Python MCP packages via pipx and uv.
	if command -v pipx &>/dev/null; then
		print_info "Installing/updating analytics-mcp via pipx..."
		if command -v analytics-mcp &>/dev/null; then
			pipx upgrade analytics-mcp >/dev/null 2>&1 || true
		else
			pipx install analytics-mcp >/dev/null 2>&1 || print_warning "Failed to install analytics-mcp"
		fi
	fi

	if command -v uv &>/dev/null && uv tool --help &>/dev/null; then
		print_info "Installing/updating outscraper-mcp-server via uv..."
		if command -v outscraper-mcp-server &>/dev/null; then
			uv tool upgrade outscraper-mcp-server >/dev/null 2>&1 || true
		else
			uv tool install outscraper-mcp-server >/dev/null 2>&1 || print_warning "Failed to install outscraper-mcp-server"
		fi
	elif command -v uv &>/dev/null; then
		print_warning "uv is installed but too old to support 'tool' subcommand — skipping outscraper-mcp-server"
		print_info "Update uv with: curl -LsSf https://astral.sh/uv/install.sh | sh"
	fi
	return 0
}

install_mcp_packages() {
	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v bun &>/dev/null && ! command -v npm &>/dev/null; then
		print_skip "MCP packages" "neither bun nor npm found" "Install bun: brew install oven-sh/bun/bun (or npm via Node.js)"
		setup_track_deferred "MCP packages" "Install bun or npm"
		return 0
	fi

	print_info "Installing MCP server packages globally (eliminates npx startup delay)..."

	_install_mcp_packages_node
	_install_mcp_packages_python

	# Update opencode.json with resolved full paths for all MCP binaries
	update_mcp_paths_in_opencode

	print_info "MCP servers will start instantly (no registry lookups on each launch)"
	return 0
}

resolve_mcp_binary_path() {
	local bin_name
	bin_name="$1"
	local resolved=""

	# Check common locations in priority order
	local search_paths=(
		"$HOME/.bun/bin/$bin_name"
		"/opt/homebrew/bin/$bin_name"
		"/usr/local/bin/$bin_name"
		"$HOME/.local/bin/$bin_name"
		"$HOME/.npm-global/bin/$bin_name"
	)

	for path in "${search_paths[@]}"; do
		if [[ -x "$path" ]]; then
			resolved="$path"
			break
		fi
	done

	# Fallback: use command -v if in PATH (portable, POSIX-compliant)
	if [[ -z "$resolved" ]]; then
		resolved=$(command -v "$bin_name" 2>/dev/null || true)
	fi

	echo "$resolved"
	return 0
}

_update_mcp_paths_resolve_local_cmds() {
	# Resolve local MCP command binaries to full paths. Prints update count.
	local tmp_config="$1"
	local updated=0

	local mcp_keys
	mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | .key' "$tmp_config" 2>/dev/null)

	while IFS= read -r mcp_key; do
		[[ -z "$mcp_key" ]] && continue

		local current_cmd
		current_cmd=$(jq -r --arg k "$mcp_key" '.mcp[$k].command[0]' "$tmp_config" 2>/dev/null)

		# Skip if already a full path
		if [[ "$current_cmd" == /* ]]; then
			# Verify the path still exists; resolve stale paths
			if [[ ! -x "$current_cmd" ]]; then
				local bin_name
				bin_name=$(basename "$current_cmd")
				local new_path
				new_path=$(resolve_mcp_binary_path "$bin_name")
				if [[ -n "$new_path" && "$new_path" != "$current_cmd" ]]; then
					jq --arg k "$mcp_key" --arg p "$new_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
					((++updated))
				fi
			fi
			continue
		fi

		# Skip docker (container runtime) and node (resolved separately)
		case "$current_cmd" in
		docker | node) continue ;;
		esac

		local full_path
		full_path=$(resolve_mcp_binary_path "$current_cmd")

		if [[ -n "$full_path" && "$full_path" != "$current_cmd" ]]; then
			jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((++updated))
		fi
	done <<<"$mcp_keys"

	echo "$updated"
	return 0
}

_update_mcp_paths_resolve_node_cmds() {
	# Resolve 'node' commands to full path (e.g., quickfile, amazon-order-history).
	# These use ["node", "/path/to/index.js"] — node itself should be resolved.
	# Prints update count.
	local tmp_config="$1"
	local updated=0

	local node_path
	node_path=$(resolve_mcp_binary_path "node")
	if [[ -n "$node_path" ]]; then
		local node_mcp_keys
		node_mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | select(.value.command[0] == "node") | .key' "$tmp_config" 2>/dev/null)
		local mcp_key
		while IFS= read -r mcp_key; do
			[[ -z "$mcp_key" ]] && continue
			jq --arg k "$mcp_key" --arg p "$node_path" '.mcp[$k].command[0] = $p' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((++updated))
		done <<<"$node_mcp_keys"
	fi

	echo "$updated"
	return 0
}

update_mcp_paths_in_opencode() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN
	cp "$opencode_config" "$tmp_config"

	local updated=0
	local local_count node_count
	local_count=$(_update_mcp_paths_resolve_local_cmds "$tmp_config")
	node_count=$(_update_mcp_paths_resolve_node_cmds "$tmp_config")
	updated=$((local_count + node_count))

	if [[ $updated -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_success "Updated $updated MCP commands to use full binary paths in opencode.json"
	else
		rm -f "$tmp_config"
	fi

	return 0
}

setup_localwp_mcp() {
	# Check prerequisites before announcing setup (GH#5240)
	local localwp_found=false
	if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
		localwp_found=true
	fi

	if [[ "$localwp_found" != "true" ]]; then
		print_skip "LocalWP MCP" "LocalWP not installed" "Install from https://localwp.com/ then re-run setup"
		setup_track_skipped "LocalWP MCP" "LocalWP not installed"
		return 0
	fi

	if ! command -v npm &>/dev/null; then
		print_skip "LocalWP MCP" "npm not found" "Install Node.js and npm first"
		setup_track_deferred "LocalWP MCP" "Install Node.js/npm, then re-run setup"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up LocalWP MCP server..."

	if command -v mcp-local-wp &>/dev/null; then
		print_success "LocalWP MCP server already installed"
		setup_track_configured "LocalWP MCP"
		return 0
	fi

	print_info "LocalWP MCP server enables AI assistants to query WordPress databases"
	local install_mcp
	setup_prompt install_mcp "Install LocalWP MCP server (@verygoodplugins/mcp-local-wp)? [Y/n]: " "Y"

	if [[ "$install_mcp" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing LocalWP MCP server" npm_global_install "@verygoodplugins/mcp-local-wp"; then
			print_info "Start with: ~/.aidevops/agents/scripts/localhost-helper.sh start-mcp"
			print_info "Or configure in OpenCode MCP settings for auto-start"
			setup_track_configured "LocalWP MCP"
		else
			print_info "Try manually: sudo npm install -g @verygoodplugins/mcp-local-wp"
		fi
	else
		print_info "Skipped LocalWP MCP server installation"
		print_info "Install later: npm install -g @verygoodplugins/mcp-local-wp"
	fi

	return 0
}

_setup_browser_tools_install_bun() {
	# Install Bun and add it to all shell rc files. Sets has_bun in caller scope.
	print_info "Installing Bun (required for dev-browser)..."
	if ! verified_install "Bun" "https://bun.sh/install"; then
		print_warning "Bun installation failed - dev-browser will need manual setup"
		return 0
	fi

	# Source the updated PATH
	export BUN_INSTALL="$HOME/.bun"
	export PATH="$BUN_INSTALL/bin:$PATH"
	if ! command -v bun &>/dev/null; then
		return 0
	fi

	print_success "Bun installed: $(bun --version)"

	# Bun's installer may only write to the running shell's rc file.
	# Ensure Bun PATH is in all shell rc files for cross-shell compat.
	# shellcheck disable=SC2016 # written to rc files; must expand at shell startup, not now
	local bun_path_line='export BUN_INSTALL="$HOME/.bun"'
	# shellcheck disable=SC2016 # written to rc files; must expand at shell startup, not now
	local bun_export_line='export PATH="$BUN_INSTALL/bin:$PATH"'
	local bun_rc
	while IFS= read -r bun_rc; do
		[[ -z "$bun_rc" ]] && continue
		[[ ! -f "$bun_rc" ]] && touch "$bun_rc"
		if ! grep -q '\.bun' "$bun_rc" 2>/dev/null; then
			{
				echo ""
				echo "# Bun (added by aidevops setup)"
				echo "$bun_path_line"
				echo "$bun_export_line"
			} >>"$bun_rc"
			print_info "Added Bun to PATH in $bun_rc"
		fi
	done < <(get_all_shell_rcs)
	return 0
}

_setup_browser_tools_dev_browser() {
	# Install dev-browser (stateful browser automation) using Bun.
	local dev_browser_dir="$HOME/.aidevops/dev-browser"

	if [[ -d "${dev_browser_dir}/skills/dev-browser" ]]; then
		print_success "dev-browser already installed"
		return 0
	fi

	print_info "Installing dev-browser (stateful browser automation)..."
	local dev_browser_output
	if dev_browser_output=$(bash "$HOME/.aidevops/agents/scripts/dev-browser-helper.sh" setup 2>&1); then
		print_success "dev-browser installed"
		print_info "Start server with: bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start"
	else
		print_warning "dev-browser setup failed:"
		# Show last few lines of error output for debugging
		echo "$dev_browser_output" | tail -5 | sed 's/^/  /'
		echo ""
		print_info "Run manually to see full output:"
		print_info "  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup"
	fi
	return 0
}

_setup_browser_tools_playwright() {
	# Install Playwright MCP browsers (chromium, firefox, webkit).
	print_info "Setting up Playwright MCP..."

	# Check if Playwright browsers are installed (--no-install prevents auto-download)
	if npx --no-install playwright --version &>/dev/null 2>&1; then
		print_success "Playwright already installed"
		print_info "Playwright MCP runs via: npx playwright-mcp@latest"
		return 0
	fi

	local install_playwright
	setup_prompt install_playwright "Install Playwright MCP with browsers (chromium, firefox, webkit)? [Y/n]: " "Y"

	if [[ "$install_playwright" =~ ^[Yy]?$ ]]; then
		print_info "Installing Playwright browsers..."
		# Use -y to auto-confirm npx install, suppress the "install without dependencies" warning
		# Use PIPESTATUS to check npx exit code, not grep's exit code
		npx -y playwright@latest install 2>&1 | grep -v "WARNING: It looks like you are running"
		if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
			print_success "Playwright browsers installed"
		else
			print_warning "Playwright browser installation failed"
			print_info "Run manually: npx -y playwright@latest install"
		fi
	else
		print_info "Skipped Playwright installation"
		print_info "Install later with: npx playwright install"
	fi

	print_info "Playwright MCP runs via: npx playwright-mcp@latest"
	return 0
}

setup_browser_tools() {
	print_info "Setting up browser automation tools..."

	local has_bun=false
	local has_node=false

	# Check Bun
	if command -v bun &>/dev/null; then
		has_bun=true
		print_success "Bun $(bun --version) found"
	fi

	# Check Node.js (for Playwriter / Playwright)
	if command -v node &>/dev/null; then
		has_node=true
	fi

	# Install Bun if not present (required for dev-browser)
	if [[ "$has_bun" == "false" ]]; then
		_setup_browser_tools_install_bun
		command -v bun &>/dev/null && has_bun=true
	fi

	# Setup dev-browser if Bun is available
	[[ "$has_bun" == "true" ]] && _setup_browser_tools_dev_browser

	# Playwriter MCP (Node.js based, runs via npx)
	if [[ "$has_node" == "true" ]]; then
		print_success "Playwriter MCP available (runs via npx playwriter@0.5.0)"
		print_info "Install Chrome extension: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe"
	else
		print_warning "Node.js not found - Playwriter MCP unavailable"
	fi

	# Playwright MCP (cross-browser testing automation)
	[[ "$has_node" == "true" ]] && _setup_browser_tools_playwright

	if [[ "$has_node" == "true" ]]; then
		print_info "Browser tools: dev-browser (stateful), Playwriter (extension), Playwright (testing), Stagehand (AI)"
	else
		print_info "Browser tools: dev-browser (stateful), Stagehand (AI)"
	fi
	return 0
}

_setup_opencode_plugins_remove_cursor_oauth() {
	# Remove the broken opencode-cursor-oauth plugin if present.
	# The opencode-cursor-oauth npm plugin crashes during startup and
	# silently prevents ALL plugins from loading (including ours).
	# Filed: https://github.com/ephraimduncan/opencode-cursor/issues/15
	# Re-enable when the upstream fix is released.
	local opencode_config="$1"
	local cursor_plugin="opencode-cursor-oauth"

	local cursor_present
	cursor_present=$(jq --arg p "$cursor_plugin" \
		'(.plugin // []) | map(select(. == $p)) | length' \
		"$opencode_config" 2>/dev/null || echo "0")
	if [[ "$cursor_present" -gt 0 ]]; then
		local tmp_cursor="${opencode_config}.tmp.$$"
		if jq --arg p "$cursor_plugin" \
			'.plugin = [.plugin[] | select(. != $p)]' \
			"$opencode_config" >"$tmp_cursor" 2>/dev/null; then
			mv "$tmp_cursor" "$opencode_config"
			print_warning "Removed opencode-cursor-oauth plugin (crashes all plugin loading)"
			print_info "  Filed: https://github.com/ephraimduncan/opencode-cursor/issues/15"
		else
			rm -f "$tmp_cursor"
			print_warning "Failed to remove opencode-cursor-oauth plugin from opencode.json (file: $opencode_config)"
		fi
	fi
	return 0
}

_setup_opencode_plugins_register_file_url() {
	# Mechanism 1: register aidevops plugin via file:// URL in opencode.json.
	# Also removes the broken opencode-cursor-oauth plugin if present.
	# Prints "true" or "false" to indicate registration status.
	local opencode_config="$1"
	local aidevops_plugin_entrypoint="$2"
	local plugin_url="file://${aidevops_plugin_entrypoint}"

	if ! command -v jq &>/dev/null; then
		print_info "jq not installed — cannot update opencode.json plugin array"
		echo "false"
		return 0
	fi

	# Check if the plugin URL is already in the array
	local already_registered
	already_registered=$(jq --arg url "$plugin_url" \
		'(.plugin // []) | map(select(. == $url)) | length' \
		"$opencode_config" || echo "0")

	if [[ "$already_registered" -eq 0 ]]; then
		local tmp_config="${opencode_config}.tmp.$$"
		if jq --arg url "$plugin_url" \
			'.plugin = ((.plugin // []) + [$url] | unique)' \
			"$opencode_config" >"$tmp_config"; then
			mv "$tmp_config" "$opencode_config"
			print_success "aidevops plugin registered in opencode.json"
		else
			rm -f "$tmp_config"
			print_warning "Failed to update opencode.json plugin array (file: $opencode_config)"
		fi
	else
		print_success "aidevops plugin already registered in opencode.json"
	fi

	_setup_opencode_plugins_remove_cursor_oauth "$opencode_config"

	echo "true"
	return 0
}

_setup_opencode_plugins_register_symlink() {
	# Mechanism 2: symlink in ~/.config/opencode/plugins/ (belt-and-suspenders).
	local plugins_dir="$1"
	local aidevops_plugin_src="$2"
	local aidevops_plugin_dst="$3"

	mkdir -p "$plugins_dir"
	if [[ -L "$aidevops_plugin_dst" ]]; then
		if [[ ! -e "$aidevops_plugin_dst" ]]; then
			print_warning "Broken aidevops plugin symlink detected; recreating"
			ln -sfn "$aidevops_plugin_src" "$aidevops_plugin_dst"
		fi
	elif [[ ! -d "$aidevops_plugin_dst" ]]; then
		ln -sfn "$aidevops_plugin_src" "$aidevops_plugin_dst"
	fi
	return 0
}

_setup_opencode_plugins_print_pool_guidance() {
	# Print OAuth pool authentication instructions for OpenCode v1.2.30+.
	local pool_plugin_registered="$1"

	if [[ "$pool_plugin_registered" == "true" ]]; then
		print_info "Use the aidevops OAuth pool (provided by the aidevops plugin above):"
		print_info "  1. Run: opencode auth login"
		print_info "  2. Select: 'Anthropic Pool' (added by aidevops plugin)"
		print_info "  3. Enter your Claude account email"
		print_info "  4. Complete the OAuth flow in your browser"
		print_info "  5. Repeat to add more accounts for automatic rotation"
		print_info "  6. Switch to 'Anthropic' provider and select a model to start chatting"
		print_info ""
		print_info "For Cursor Pro accounts:"
		print_info "  Run: opencode auth login --provider cursor"
		print_info ""
		print_info "  Health check: /models-pool-check"
		print_info "  Manage accounts: /model-accounts-pool list|status|remove"
	else
		print_warning "aidevops OpenCode plugin was not registered; 'Anthropic Pool' may be unavailable"
		print_info "Re-run aidevops setup to register the plugin, then run: opencode auth login"
	fi
	return 0
}

_setup_opencode_plugins_auth_guidance() {
	# Print version-appropriate authentication instructions.
	# Note: opencode-anthropic-auth is built into OpenCode v1.1.36+
	# Adding it as an external plugin causes TypeError due to double-loading.
	# Removed in v2.90.0 - see PR #230.
	local pool_plugin_registered="$1"

	# Detect OpenCode version to give appropriate auth guidance (t1546, GH#5312)
	# v1.2.30+ removes the built-in anthropic-auth plugin entirely.
	local oc_raw_version
	oc_raw_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")

	local oc_major oc_minor oc_patch
	IFS='.' read -r oc_major oc_minor oc_patch <<<"$oc_raw_version"
	oc_major="${oc_major:-0}"
	oc_minor="${oc_minor:-0}"
	oc_patch="${oc_patch:-0}"

	# Compare against 1.2.30 (where built-in anthropic-auth was removed)
	local builtin_auth_removed="false"
	if [[ "$oc_major" -gt 1 ]] ||
		[[ "$oc_major" -eq 1 && "$oc_minor" -gt 2 ]] ||
		[[ "$oc_major" -eq 1 && "$oc_minor" -eq 2 && "$oc_patch" -ge 30 ]]; then
		builtin_auth_removed="true"
	fi

	if [[ "$builtin_auth_removed" == "true" ]]; then
		print_info "OpenCode v${oc_raw_version}: built-in Anthropic OAuth removed in v1.2.30"
		_setup_opencode_plugins_print_pool_guidance "$pool_plugin_registered"
	else
		print_info "After setup, authenticate with: opencode auth login"
		print_info "  - For Claude OAuth (v1.1.36-v1.2.29): Select 'Anthropic' -> 'Claude Pro/Max' (built-in)"
		print_info "  - Or use the aidevops OAuth pool: Select 'Anthropic Pool' for multi-account rotation"
	fi
	return 0
}

setup_opencode_plugins() {
	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v opencode &>/dev/null; then
		print_skip "OpenCode plugins" "OpenCode not installed" "Install from https://opencode.ai"
		setup_track_skipped "OpenCode plugins" "OpenCode not installed"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up OpenCode plugins..."

	# Register aidevops plugin using two complementary mechanisms:
	#   1. file:// URL in opencode.json "plugin" array (works on all tested versions)
	#   2. Symlink in ~/.config/opencode/plugins/ (newer OpenCode convention)
	# Both are idempotent — the plugin's registerPoolProvider() checks before adding.
	local plugins_dir="$HOME/.config/opencode/plugins"
	local aidevops_plugin_src="$HOME/.aidevops/agents/plugins/opencode-aidevops"
	local aidevops_plugin_dst="$plugins_dir/opencode-aidevops"
	local aidevops_plugin_entrypoint="$aidevops_plugin_src/index.mjs"

	if [[ ! -f "$aidevops_plugin_entrypoint" ]]; then
		print_skip "OpenCode plugins" "aidevops plugin entry point not found: $aidevops_plugin_entrypoint"
		setup_track_deferred "OpenCode plugins" "Install/restore aidevops plugin at $aidevops_plugin_entrypoint"
		return 0
	fi

	# Mechanism 1: file:// URL in opencode.json
	local pool_plugin_registered="false"
	local opencode_config
	if opencode_config=$(find_opencode_config); then
		pool_plugin_registered=$(_setup_opencode_plugins_register_file_url "$opencode_config" "$aidevops_plugin_entrypoint")
	else
		print_info "opencode.json not found — run 'opencode' once to create it, then re-run setup"
	fi

	# Mechanism 2: symlink in plugins directory
	_setup_opencode_plugins_register_symlink "$plugins_dir" "$aidevops_plugin_src" "$aidevops_plugin_dst"

	setup_track_configured "OpenCode plugins"

	# Version-appropriate auth guidance
	_setup_opencode_plugins_auth_guidance "$pool_plugin_registered"

	return 0
}

setup_seo_mcps() {
	print_info "Setting up SEO integrations..."

	# SEO services use curl-based subagents (no MCP needed)
	# Subagents: serper.md, dataforseo.md, ahrefs.md, google-search-console.md
	print_info "SEO uses curl-based subagents (zero context cost until invoked)"

	# Check if credentials are configured
	if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
		# shellcheck source=/dev/null
		source "$HOME/.config/aidevops/credentials.sh"

		if [[ -n "${DATAFORSEO_USERNAME:-}" ]]; then
			print_success "DataForSEO credentials configured"
		else
			print_info "DataForSEO: set DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in credentials.sh"
		fi

		if [[ -n "${SERPER_API_KEY:-}" ]]; then
			print_success "Serper API key configured"
		else
			print_info "Serper: set SERPER_API_KEY in credentials.sh"
		fi

		if [[ -n "${AHREFS_API_KEY:-}" ]]; then
			print_success "Ahrefs API key configured"
		else
			print_info "Ahrefs: set AHREFS_API_KEY in credentials.sh"
		fi
	else
		print_info "Configure SEO API credentials in ~/.config/aidevops/credentials.sh"
	fi

	# GSC uses MCP (OAuth2 complexity warrants it)
	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"
	if [[ -f "$gsc_creds" ]]; then
		print_success "Google Search Console credentials configured"
	else
		print_info "GSC: Create service account JSON at $gsc_creds"
		print_info "  See: ~/.aidevops/agents/seo/google-search-console.md"
	fi

	print_info "SEO documentation: ~/.aidevops/agents/seo/"
	return 0
}

_setup_google_analytics_mcp_detect_creds() {
	# Detect GSC credentials and print three lines: creds_path, project_id, enable_mcp.
	local gsc_creds="$1"
	local creds_path=""
	local project_id=""
	local enable_mcp="false"

	if [[ -f "$gsc_creds" ]]; then
		creds_path="$gsc_creds"
		project_id=$(jq -r '.project_id // empty' "$gsc_creds" 2>/dev/null)
		if [[ -n "$project_id" ]]; then
			enable_mcp="true"
			print_success "Found GSC credentials - sharing with Google Analytics MCP"
			print_info "Project: $project_id"
		fi
	fi

	printf '%s\n%s\n%s\n' "$creds_path" "$project_id" "$enable_mcp"
	return 0
}

_setup_google_analytics_mcp_update_existing() {
	# Update an existing google-analytics-mcp entry in opencode.json.
	local opencode_config="$1"
	local creds_path="$2"
	local project_id="$3"
	local enable_mcp="$4"

	if [[ "$enable_mcp" == "true" ]]; then
		local tmp_config
		tmp_config=$(mktemp)
		trap 'rm -f "${tmp_config:-}"' RETURN
		if jq --arg creds "$creds_path" --arg proj "$project_id" \
			'.mcp["google-analytics-mcp"].environment.GOOGLE_APPLICATION_CREDENTIALS = $creds |
			 .mcp["google-analytics-mcp"].environment.GOOGLE_PROJECT_ID = $proj |
			 .mcp["google-analytics-mcp"].enabled = true' \
			"$opencode_config" >"$tmp_config" 2>/dev/null; then
			mv "$tmp_config" "$opencode_config"
			print_success "Updated Google Analytics MCP with GSC credentials (enabled)"
		else
			rm -f "$tmp_config"
			print_warning "Failed to update Google Analytics MCP config"
		fi
	else
		print_info "Google Analytics MCP already configured in OpenCode"
	fi
	return 0
}

_setup_google_analytics_mcp_add_new() {
	# Add a new google-analytics-mcp entry to opencode.json.
	local opencode_config="$1"
	local creds_path="$2"
	local project_id="$3"
	local enable_mcp="$4"
	local gsc_creds="$5"

	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	if jq --arg creds "$creds_path" --arg proj "$project_id" --argjson enabled "$enable_mcp" \
		'.mcp["google-analytics-mcp"] = {
		"type": "local",
		"command": ["analytics-mcp"],
		"environment": {
			"GOOGLE_APPLICATION_CREDENTIALS": $creds,
			"GOOGLE_PROJECT_ID": $proj
		},
		"enabled": $enabled
	}' "$opencode_config" >"$tmp_config" 2>/dev/null; then
		mv "$tmp_config" "$opencode_config"
		if [[ "$enable_mcp" == "true" ]]; then
			print_success "Added Google Analytics MCP to OpenCode (enabled with GSC credentials)"
		else
			print_success "Added Google Analytics MCP to OpenCode (disabled - no credentials found)"
			print_info "To enable: Create service account JSON at $gsc_creds"
		fi
		print_info "Or use the google-analytics subagent which enables it automatically"
	else
		rm -f "$tmp_config"
		print_warning "Failed to add Google Analytics MCP to config"
	fi
	return 0
}

_setup_google_analytics_mcp_write_config() {
	# Update or add the google-analytics-mcp entry in opencode.json.
	local opencode_config="$1"
	local creds_path="$2"
	local project_id="$3"
	local enable_mcp="$4"
	local gsc_creds="$5"

	# Update existing entry if present
	if jq -e '.mcp["google-analytics-mcp"]' "$opencode_config" >/dev/null 2>&1; then
		_setup_google_analytics_mcp_update_existing "$opencode_config" "$creds_path" "$project_id" "$enable_mcp"
		return 0
	fi

	# Add new entry
	_setup_google_analytics_mcp_add_new "$opencode_config" "$creds_path" "$project_id" "$enable_mcp" "$gsc_creds"
	return 0
}

setup_google_analytics_mcp() {
	local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"

	# Check prerequisites before announcing setup (GH#5240)
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_skip "Google Analytics MCP" "OpenCode config not found" "Run 'opencode' once to create config, then re-run setup"
		setup_track_skipped "Google Analytics MCP" "OpenCode config not found"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_skip "Google Analytics MCP" "jq not installed" "Install jq: brew install jq (macOS) or apt install jq"
		setup_track_deferred "Google Analytics MCP" "Install jq"
		return 0
	fi

	if ! command -v pipx &>/dev/null; then
		print_skip "Google Analytics MCP" "pipx not installed" "Install pipx: brew install pipx (macOS) or pip install pipx"
		setup_track_deferred "Google Analytics MCP" "Install pipx"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up Google Analytics MCP..."

	# Auto-detect credentials from shared GSC service account
	local creds_output
	creds_output=$(_setup_google_analytics_mcp_detect_creds "$gsc_creds")
	local creds_path project_id enable_mcp
	creds_path=$(printf '%s\n' "$creds_output" | sed -n '1p')
	project_id=$(printf '%s\n' "$creds_output" | sed -n '2p')
	enable_mcp=$(printf '%s\n' "$creds_output" | sed -n '3p')

	# Update or add config entry
	_setup_google_analytics_mcp_write_config "$opencode_config" "$creds_path" "$project_id" "$enable_mcp" "$gsc_creds"

	# Show setup instructions
	print_info "Google Analytics MCP setup:"
	print_info "  1. Enable Google Analytics Admin & Data APIs in Google Cloud Console"
	print_info "  2. Configure ADC: gcloud auth application-default login --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform"
	print_info "  3. Update GOOGLE_APPLICATION_CREDENTIALS path in opencode.json"
	print_info "  4. Set GOOGLE_PROJECT_ID in opencode.json"
	print_info "Documentation: ~/.aidevops/agents/services/analytics/google-analytics.md"

	return 0
}

_setup_quickfile_mcp_clone_and_build() {
	# Clone and build the QuickFile MCP server. Returns 1 if user skips or build fails.
	local quickfile_dir="$1"

	if [[ -f "$quickfile_dir/dist/index.js" ]]; then
		print_success "QuickFile MCP already installed at $quickfile_dir"
		return 0
	fi

	print_info "QuickFile MCP provides AI access to UK accounting (invoices, clients, reports)"
	local install_qf
	setup_prompt install_qf "Clone and build QuickFile MCP server? [Y/n]: " "Y"

	if [[ ! "$install_qf" =~ ^[Yy]?$ ]]; then
		print_info "Skipped QuickFile MCP installation"
		print_info "Install later: mkdir -p ~/Git/mcp && git clone https://github.com/marcusquinn/quickfile-mcp.git ~/Git/mcp/quickfile-mcp"
		return 1
	fi

	if [[ ! -d "$quickfile_dir" ]]; then
		mkdir -p "$(dirname "$quickfile_dir")"
		if ! run_with_spinner "Cloning quickfile-mcp" git clone https://github.com/marcusquinn/quickfile-mcp.git "$quickfile_dir"; then
			print_warning "Failed to clone quickfile-mcp"
			return 1
		fi
		print_success "Cloned quickfile-mcp"
	fi

	if ! run_with_spinner "Installing dependencies" npm install --prefix "$quickfile_dir"; then
		print_warning "npm install failed - try manually: cd $quickfile_dir && npm install"
		return 1
	fi

	if ! run_with_spinner "Building QuickFile MCP" npm run build --prefix "$quickfile_dir"; then
		print_warning "Build failed - try manually: cd $quickfile_dir && npm run build"
		return 1
	fi

	print_success "QuickFile MCP built successfully"
	return 0
}

_setup_quickfile_mcp_check_tokens() {
	# Check QuickFile bearer-token names without exposing their values or aliases.
	local inventory=""
	local token_count=0
	if command -v aidevops >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		inventory=$(aidevops secret inventory 2>/dev/null) || inventory=""
		if [[ -n "$inventory" ]]; then
			token_count=$(printf '%s' "$inventory" | jq '[.secrets[]
				| select(.status == "configured")
				| .name
				| select(test("^QUICKFILE_([A-Z0-9_]+_)?(API_KEY|API_TOKEN|BEARER_TOKEN)$"))]
				| unique | length')
		fi
	fi

	if [[ "$token_count" -gt 0 ]]; then
		print_success "QuickFile bearer tokens configured for ${token_count} account(s)"
	else
		print_info "No QuickFile REST bearer tokens found"
		print_info "Create a personal token: Account Settings > Third Party Integration > API"
		print_info "Store one alias at a time: aidevops secret set QUICKFILE_BUSINESS_API_KEY"
	fi
	return 0
}

_setup_quickfile_mcp_update_opencode() {
	# Migrate QuickFile MCP to the least-privilege secret launcher.

	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		return 0
	fi

	print_info "Configuring QuickFile MCP with account-specific secret injection..."
	local launcher_path="$HOME/.aidevops/agents/scripts/quickfile-mcp-launcher.sh"

	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	if jq --arg lp "$launcher_path" \
		'.mcp.quickfile = {"type": "local", "command": [$lp], "enabled": false}' \
		"$opencode_config" >"$tmp_config" 2>/dev/null; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		print_success "QuickFile MCP configured with least-privilege bearer-token injection"
	else
		rm -f "$tmp_config"
		print_warning "Failed to update OpenCode config - add manually"
	fi
	return 0
}

setup_quickfile_mcp() {
	local quickfile_dir="$HOME/Git/mcp/quickfile-mcp"

	# Check prerequisites before announcing setup (GH#5240)
	if ! command -v node &>/dev/null; then
		print_skip "QuickFile MCP" "Node.js not installed" "Install Node.js 18+: brew install node (macOS) or nvm install 18"
		setup_track_deferred "QuickFile MCP" "Install Node.js 18+"
		return 0
	fi

	# Prerequisites met — proceed with setup
	print_info "Setting up QuickFile MCP server..."

	# Clone and build (returns 1 if skipped or failed)
	if ! _setup_quickfile_mcp_clone_and_build "$quickfile_dir"; then
		return 0
	fi

	_setup_quickfile_mcp_check_tokens
	_setup_quickfile_mcp_update_opencode

	print_info "Documentation: ~/.aidevops/agents/services/accounting/quickfile.md"
	return 0
}
