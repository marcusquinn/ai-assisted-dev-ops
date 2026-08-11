#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tool installation functions: git-clis, fd, ripgrep, shellcheck, shfmt, rosetta, worktrunk, minisim, serve-sim, recommended-tools, nodejs, python, orbstack
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

_print_gh_slurp_manual_upgrade() {
	echo ""
	echo "📋 GitHub CLI upgrade guidance:"
	echo "  Required: gh >= ${AIDEVOPS_GH_MIN_SLURP_VERSION:-2.51.0} for gh api --paginate --slurp"
	echo "  Linux: install or upgrade gh from the official GitHub CLI package source for your distribution; on Ubuntu/Debian avoid the older Ubuntu universe gh package"
	echo "  macOS: brew update && brew upgrade gh"
	echo "  Verify: gh --version && aidevops status"
	return 0
}

_offer_gh_slurp_upgrade() {
	local pkg_manager="$1"
	local os_name=""
	os_name=$(uname -s 2>/dev/null || printf 'unknown')

	if [[ "$os_name" != "Linux" ]]; then
		_print_gh_slurp_manual_upgrade
		return 1
	fi

	echo ""
	print_warning "Linux GitHub CLI is below the aidevops minimum. Old distro packages can break pulse dispatch."
	if [[ "$pkg_manager" == "unknown" ]]; then
		print_warning "No supported package manager detected for an automatic gh upgrade attempt"
		_print_gh_slurp_manual_upgrade
		return 1
	fi
	setup_prompt upgrade_gh_cli "Try to upgrade GitHub CLI (gh) using ${pkg_manager}? [y/N]: " "N"
	# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
	if [[ "$upgrade_gh_cli" =~ ^[Yy]$ ]]; then
		print_info "Attempting to upgrade gh using ${pkg_manager}..."
		if install_packages "$pkg_manager" gh; then
			if declare -F aidevops_gh_slurp_supported >/dev/null 2>&1 && aidevops_gh_slurp_supported; then
				print_success "GitHub CLI now satisfies the aidevops prerequisite"
				return 0
			else
				print_warning "gh still does not satisfy the aidevops prerequisite after package-manager upgrade"
				_print_gh_slurp_manual_upgrade
			fi
		else
			print_warning "Package-manager gh upgrade failed or was unavailable"
			_print_gh_slurp_manual_upgrade
		fi
	else
		print_info "Skipped GitHub CLI upgrade"
		_print_gh_slurp_manual_upgrade
	fi
	return 1
}

setup_git_clis() {
	print_info "Setting up Git CLI tools..."

	local cli_tools=()
	local missing_packages=()
	local missing_names=()
	local gh_needs_slurp_upgrade="false"

	# Check for GitHub CLI
	if ! command -v gh >/dev/null 2>&1; then
		missing_packages+=("gh")
		missing_names+=("GitHub CLI")
	elif declare -F aidevops_gh_slurp_supported >/dev/null 2>&1 && ! aidevops_gh_slurp_supported; then
		local gh_slurp_message
		gh_slurp_message=$(aidevops_gh_slurp_status_message)
		print_warning "$gh_slurp_message"
		gh_needs_slurp_upgrade="true"
	else
		cli_tools+=("GitHub CLI")
	fi

	# Check for GitLab CLI
	if ! command -v glab >/dev/null 2>&1; then
		missing_packages+=("glab")
		missing_names+=("GitLab CLI")
	else
		cli_tools+=("GitLab CLI")
	fi

	# Report found tools
	if [[ ${#cli_tools[@]} -gt 0 ]]; then
		print_success "Found Git CLI tools: ${cli_tools[*]}"
	fi

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$gh_needs_slurp_upgrade" == "true" ]]; then
		if _offer_gh_slurp_upgrade "$pkg_manager"; then
			gh_needs_slurp_upgrade="false"
		fi
	fi

	# Offer to install missing tools
	if [[ ${#missing_packages[@]} -gt 0 ]]; then
		print_warning "Missing Git CLI tools: ${missing_names[*]}"
		echo "  These provide enhanced Git platform integration (repos, PRs, issues)"

		if [[ "$pkg_manager" != "unknown" ]]; then
			echo ""
			setup_prompt install_git_clis "Install Git CLI tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " "Y"

			# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
			if [[ "$install_git_clis" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."
				if install_packages "$pkg_manager" "${missing_packages[@]}"; then
					print_success "Git CLI tools installed"
					echo ""
					echo "📋 Next steps - authenticate each CLI:"
					for pkg in "${missing_packages[@]}"; do
						case "$pkg" in
						gh) echo "  • gh auth login -s workflow  (workflow scope required for CI PRs)" ;;
						glab) echo "  • glab auth login" ;;
						esac
					done
				else
					print_warning "Failed to install some Git CLI tools (non-critical)"
				fi
			else
				print_info "Skipped Git CLI tools installation"
				echo ""
				echo "📋 Manual installation:"
				echo "  macOS: brew install ${missing_packages[*]}"
				echo "  Ubuntu: sudo apt install ${missing_packages[*]} (Note: for gh >= 2.51.0, use the GitHub CLI apt repository)"
				echo "  Fedora: sudo dnf install ${missing_packages[*]}"
			fi
		else
			echo ""
			echo "📋 Manual installation:"
			echo "  macOS: brew install ${missing_packages[*]}"
			echo "  Ubuntu: sudo apt install ${missing_packages[*]} (Note: for gh >= 2.51.0, use the GitHub CLI apt repository)"
			echo "  Fedora: sudo dnf install ${missing_packages[*]}"
		fi
	elif [[ "$gh_needs_slurp_upgrade" != "true" ]]; then
		print_success "All Git CLI tools installed and ready!"
	fi

	# Check for Gitea CLI separately (not in standard package managers)
	if ! command -v tea >/dev/null 2>&1; then
		print_info "Gitea CLI (tea) not found - install manually if needed:"
		echo "  go install code.gitea.io/tea/cmd/tea@latest"
		echo "  Or download from: https://dl.gitea.io/tea/"
	else
		print_success "Gitea CLI (tea) found"
	fi

	return 0
}

_print_file_discovery_manual_install() {
	echo ""
	echo "  Manual installation:"
	echo "    macOS:        brew install fd ripgrep ripgrep-all"
	echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep  # rga: cargo install ripgrep_all"
	echo "    Fedora:       sudo dnf install fd-find ripgrep   # rga: cargo install ripgrep_all"
	echo "    Arch:         sudo pacman -S fd ripgrep ripgrep-all"
	return 0
}

# Add fd=fdfind alias to shell rc files on Debian/Ubuntu after apt install.
_add_fd_alias_debian() {
	local rc_files=("$HOME/.bashrc" "$HOME/.zshrc")
	local added_to=""
	local rc_file

	for rc_file in "${rc_files[@]}"; do
		[[ ! -f "$rc_file" ]] && continue

		if ! grep -q 'alias fd="fdfind"' "$rc_file" 2>/dev/null; then
			if { echo '' >>"$rc_file" &&
				echo '# fd-find alias for Debian/Ubuntu (added by aidevops)' >>"$rc_file" &&
				echo 'alias fd="fdfind"' >>"$rc_file"; }; then
				added_to="${added_to:+$added_to, }$rc_file"
			fi
		fi
	done

	if [[ -n "$added_to" ]]; then
		print_success "Added alias fd=fdfind to: $added_to"
		echo "  Restart your shell to activate"
	else
		print_success "fd alias already configured"
	fi
	return 0
}

# Resolve apt package names (fd→fd-find on Debian/Ubuntu) and install.
_install_file_discovery_packages() {
	local pkg_manager="$1"
	shift
	local missing_packages=("$@")

	print_info "Installing ${missing_packages[*]}..."

	local actual_packages=()
	local pkg
	for pkg in "${missing_packages[@]}"; do
		case "$pkg_manager" in
		apt)
			# Debian/Ubuntu uses fd-find instead of fd
			if [[ "$pkg" == "fd" ]]; then
				actual_packages+=("fd-find")
			else
				actual_packages+=("$pkg")
			fi
			;;
		*)
			actual_packages+=("$pkg")
			;;
		esac
	done

	if install_packages "$pkg_manager" "${actual_packages[@]}"; then
		print_success "File discovery tools installed"
		# On Debian/Ubuntu, fd is installed as fdfind — create alias in shell rc files
		if [[ "$pkg_manager" == "apt" ]] && command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
			_add_fd_alias_debian
		fi
	else
		print_warning "Failed to install some file discovery tools (non-critical)"
	fi
	return 0
}

setup_file_discovery_tools() {
	print_info "Setting up file discovery tools..."

	local missing_tools=()
	local missing_packages=()
	local missing_names=()

	local fd_version
	if command -v fd >/dev/null 2>&1; then
		fd_version=$(fd --version 2>/dev/null | head -1 || echo "unknown")
		print_success "fd found: $fd_version"
	elif command -v fdfind >/dev/null 2>&1; then
		fd_version=$(fdfind --version 2>/dev/null | head -1 || echo "unknown")
		print_success "fd found (as fdfind): $fd_version"
		print_warning "Note: 'fd' alias not active in current shell. Restart shell or run: alias fd=fdfind"
	else
		missing_tools+=("fd")
		missing_packages+=("fd")
		missing_names+=("fd (fast file finder)")
	fi

	# Check for ripgrep
	if ! command -v rg >/dev/null 2>&1; then
		missing_tools+=("rg")
		missing_packages+=("ripgrep")
		missing_names+=("ripgrep (fast content search)")
	else
		local rg_version
		rg_version=$(rg --version 2>/dev/null | head -1 || echo "unknown")
		print_success "ripgrep found: $rg_version"
	fi

	# Check for ripgrep-all (searches inside PDFs, DOCX, SQLite, archives)
	if ! command -v rga >/dev/null 2>&1; then
		missing_tools+=("rga")
		missing_packages+=("ripgrep-all")
		missing_names+=("ripgrep-all (search inside PDFs/docs/archives)")
	else
		local rga_version
		rga_version=$(rga --version 2>/dev/null | head -1 || echo "unknown")
		print_success "ripgrep-all found: $rga_version"
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing file discovery tools: ${missing_names[*]}"
		echo ""
		echo "  These tools provide 10x faster file discovery than built-in glob:"
		echo "    fd          - Fast alternative to 'find', respects .gitignore"
		echo "    ripgrep     - Fast alternative to 'grep', respects .gitignore"
		echo "    ripgrep-all - Extends ripgrep to search inside PDFs, DOCX, SQLite, archives"
		echo ""
		echo "  AI agents use these for efficient codebase navigation."
		echo ""

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			setup_prompt install_fd_tools "Install file discovery tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " "Y"

			# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
			if [[ "$install_fd_tools" =~ ^[Yy]?$ ]]; then
				_install_file_discovery_packages "$pkg_manager" "${missing_packages[@]}"
			else
				print_info "Skipped file discovery tools installation"
				_print_file_discovery_manual_install
			fi
		else
			_print_file_discovery_manual_install
		fi
	else
		print_success "All file discovery tools installed!"
	fi

	return 0
}

_setup_rtk_installed_version() {
	local rtk_version="unknown"
	rtk_version=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || printf 'unknown')
	printf '%s\n' "$rtk_version"
	return 0
}

_setup_rtk_install_supported_version() {
	local rtk_installer_url="$1"
	local rtk_supported_version="$2"
	VERIFIED_INSTALL_SHELL="sh"

	if command -v brew >/dev/null 2>&1; then
		if run_with_spinner "Upgrading rtk via Homebrew" brew upgrade rtk; then
			print_success "rtk upgraded via Homebrew"
			return 0
		fi
		print_warning "Homebrew upgrade failed, trying pinned installer..."
	fi

	if verified_install "rtk" "$rtk_installer_url"; then
		print_success "rtk installed to ~/.local/bin/rtk (v${rtk_supported_version})"
		return 0
	fi

	print_warning "rtk upgrade failed (non-critical, optional tool)"
	_setup_rtk_print_manual_install "$rtk_installer_url" "upgrade"
	return 1
}

_setup_rtk_print_manual_install() {
	local rtk_installer_url="$1"
	local brew_cmd="${2:-upgrade}"
	echo "  Manual install: brew $brew_cmd rtk  OR  curl -fsSL $rtk_installer_url | sh"
	return 0
}

_setup_rtk_offer_supported_upgrade() {
	local rtk_version="$1"
	local rtk_supported_version="$2"
	local rtk_installer_url="$3"

	print_warning "rtk version mismatch: found v${rtk_version}, aidevops supports v${rtk_supported_version}"
	setup_prompt upgrade_rtk "Upgrade rtk to the aidevops-tested v${rtk_supported_version}? [Y/n]: " "Y"
	# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
	if [[ "$upgrade_rtk" =~ ^[Yy]?$ ]]; then
		_setup_rtk_install_supported_version "$rtk_installer_url" "$rtk_supported_version"
		return $?
	fi

	print_info "Skipped rtk upgrade"
	_setup_rtk_print_manual_install "$rtk_installer_url"
	return 1
}

setup_rtk() {
	# rtk — CLI proxy that reduces LLM token consumption by 60-90% (t1430)
	# Opinionated default optimization: compresses git/gh/test outputs before they reach LLM context
	# Single Rust binary, zero dependencies, <10ms overhead
	# https://github.com/rtk-ai/rtk

	# Pin to a tagged release for stability and auditability (Gemini review feedback).
	# Update the tag when upstream-watch detects a new release.
	local rtk_supported_version="0.41.0"
	local rtk_installer_url="https://raw.githubusercontent.com/rtk-ai/rtk/v${rtk_supported_version}/install.sh"

	if command -v rtk >/dev/null 2>&1; then
		local rtk_version
		rtk_version=$(_setup_rtk_installed_version)
		print_success "rtk found: v$rtk_version (token optimization proxy)"
		if [[ "$rtk_version" != "$rtk_supported_version" ]]; then
			if _setup_rtk_offer_supported_upgrade "$rtk_version" "$rtk_supported_version" "$rtk_installer_url"; then
				rtk_version=$(_setup_rtk_installed_version)
				if [[ "$rtk_version" == "$rtk_supported_version" ]]; then
					print_success "rtk now matches the aidevops-tested version"
				else
					print_warning "rtk still reports v${rtk_version}; aidevops supports v${rtk_supported_version}"
					_setup_rtk_print_manual_install "$rtk_installer_url"
				fi
			fi
		fi
		# Fall through to ensure config is applied (telemetry, tee)
	else
		print_info "rtk (Rust Token Killer) reduces LLM token usage by 60-90% on CLI commands"
		echo "  Compresses git, gh, test runner, and linter outputs before they reach the AI context."
		echo "  Single binary, zero dependencies, <10ms overhead. Installed by default; answer 'n' to skip."
		echo ""

		setup_prompt install_rtk "Install rtk for token-optimized CLI output? [Y/n]: " "y"

		# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
		if [[ "$install_rtk" =~ ^[Yy]$ ]]; then
			VERIFIED_INSTALL_SHELL="sh"
			if command -v brew >/dev/null 2>&1; then
				if run_with_spinner "Installing rtk via Homebrew" brew install rtk; then
					print_success "rtk installed via Homebrew"
				else
					print_warning "Homebrew install failed, trying curl installer..."
					if verified_install "rtk" "$rtk_installer_url"; then
						print_success "rtk installed to ~/.local/bin/rtk"
					else
						print_warning "rtk installation failed (non-critical, optional tool)"
					fi
				fi
			else
				# Linux or macOS without brew — use verified_install for secure execution
				if verified_install "rtk" "$rtk_installer_url"; then
					print_success "rtk installed to ~/.local/bin/rtk"
				else
					print_warning "rtk installation failed (non-critical, optional tool)"
					echo "  Manual install: https://github.com/rtk-ai/rtk#installation"
				fi
			fi
		else
			print_info "Skipped rtk installation"
			_setup_rtk_print_manual_install "$rtk_installer_url" "install"
		fi
	fi

	# Configure rtk (telemetry off, tee for failure capture) — only if binary is present
	if command -v rtk >/dev/null 2>&1; then
		local rtk_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rtk"
		if [[ ! -f "$rtk_config_dir/config.toml" ]]; then
			mkdir -p "$rtk_config_dir"
			cat >"$rtk_config_dir/config.toml" <<-'RTKEOF'
				# rtk configuration (created by aidevops setup.sh)
				# https://github.com/rtk-ai/rtk

				[telemetry]
				enabled = false

				[tee]
				enabled = true
				mode = "failures"
				max_files = 20
			RTKEOF
			print_success "rtk config created (telemetry disabled)"
		fi
	fi

	return 0
}

setup_shell_linting_tools() {
	print_info "Setting up shell linting tools..."

	local missing_tools=()
	local pkg_manager
	pkg_manager=$(detect_package_manager)

	# Check shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		local sc_version sc_rosetta=false
		sc_version=$(shellcheck --version 2>/dev/null | grep 'version:' | awk '{print $2}' || echo "unknown")
		# Rosetta detection (macOS Apple Silicon only, requires `file` command)
		if [[ "$PLATFORM_MACOS" == "true" ]] && [[ "$PLATFORM_ARM64" == "true" ]] && command -v file >/dev/null 2>&1; then
			local sc_file_output
			sc_file_output=$(file "$(command -v shellcheck)" 2>/dev/null || echo "")
			if [[ "$sc_file_output" == *"x86_64"* ]] && [[ "$sc_file_output" != *"arm64"* ]]; then
				sc_rosetta=true
			fi
		fi
		if [[ "$sc_rosetta" == "true" ]]; then
			print_warning "shellcheck found but running under Rosetta (x86_64)"
			print_info "  Run 'rosetta-audit-helper.sh migrate' to fix"
		else
			print_success "shellcheck found ($sc_version)"
		fi
	else
		missing_tools+=("shellcheck")
	fi

	# Check shfmt
	if command -v shfmt >/dev/null 2>&1; then
		print_success "shfmt found ($(shfmt --version 2>/dev/null))"
	else
		missing_tools+=("shfmt")
	fi

	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing shell linting tools: ${missing_tools[*]}"
		echo "  shellcheck - static analysis for shell scripts"
		echo "  shfmt      - shell script formatter (fast syntax checks)"

		if [[ "$pkg_manager" != "unknown" ]]; then
			local install_linters
			setup_prompt install_linters "Install missing shell linting tools using $pkg_manager? [Y/n]: " "Y"

			if [[ "$install_linters" =~ ^[Yy]?$ ]]; then
				if install_packages "$pkg_manager" "${missing_tools[@]}"; then
					print_success "Shell linting tools installed"
				else
					print_warning "Failed to install some shell linting tools"
				fi
			else
				print_info "Skipped shell linting tools"
			fi
		else
			echo "  Install manually:"
			echo "    macOS: brew install ${missing_tools[*]}"
			echo "    Linux: apt install ${missing_tools[*]}"
		fi
	fi

	return 0
}

setup_setsid_advisory() {
	# setsid is required to detach pulse workers into their own process group
	# (t2757, GH#20561, GH#21102). Without it, workers inherit pulse's PGID and
	# are killed by any PG-scoped signal (launchd unload, restart chain).
	#
	# Linux: setsid ships with util-linux (present on all mainstream distros).
	# macOS: available from macOS 12+ at /usr/bin/setsid. Older macOS or systems
	#        where /usr/bin/setsid is absent need util-linux via Homebrew.
	#        util-linux is keg-only on Homebrew — binary is not linked into PATH
	#        automatically, so we create a symlink after install.
	if command -v setsid >/dev/null 2>&1; then
		local setsid_path
		setsid_path="$(command -v setsid)"
		print_success "setsid found at $setsid_path (worker process-group isolation enabled)"
		return 0
	fi

	# setsid missing — on macOS with Homebrew, auto-install util-linux and
	# symlink setsid into PATH (GH#21102 / t2926). On Linux and macOS without
	# Homebrew, emit an actionable error with install instructions.
	if [[ "$(uname)" == "Darwin" ]]; then
		if command -v brew >/dev/null 2>&1; then
			print_info "setsid not found — installing util-linux for worker PGID isolation (GH#21102)"
			if brew install util-linux 2>&1 | tail -3; then
				# util-linux is keg-only: binary lives under the keg, not in /opt/homebrew/bin.
				# Symlink setsid into a standard PATH directory so 'command -v setsid' works.
				local brew_prefix
				brew_prefix="$(brew --prefix 2>/dev/null || echo "")"
				local keg_setsid="${brew_prefix}/opt/util-linux/bin/setsid"
				local link_target="${brew_prefix}/bin/setsid"
				if [[ -x "$keg_setsid" && ! -e "$link_target" ]]; then
					ln -s "$keg_setsid" "$link_target" && \
						print_success "Symlinked setsid: $keg_setsid → $link_target"
				fi
				# Verify setsid is now reachable
				if command -v setsid >/dev/null 2>&1; then
					print_success "setsid installed at $(command -v setsid) (worker PGID isolation enabled)"
				else
					print_error "util-linux installed but setsid still not in PATH — check brew --prefix"
				fi
			else
				print_error "brew install util-linux failed — workers will share pulse PGID until resolved"
				echo "  Manual fix: brew install util-linux"
			fi
		else
			print_error "setsid not found — worker isolation broken; install util-linux"
			echo "  Impact: every pulse restart sends SIGHUP to workers in its PGID,"
			echo "          killing in-flight workers before they can finish (GH#21102)"
			echo "  Fix:    install Homebrew, then run: brew install util-linux"
			echo "  Or upgrade to macOS 12+ where /usr/bin/setsid ships by default"
		fi
	else
		# Linux: setsid should be present on all mainstream distros via util-linux.
		# If it is missing, emit an error rather than a warning — workers will be
		# killed on every pulse cycle restart without it.
		print_error "setsid not found — worker isolation broken; install util-linux"
		echo "  Impact: every pulse restart sends SIGHUP to workers in its PGID,"
		echo "          killing in-flight workers before they can finish (GH#21102)"
		echo "  Fix:    sudo apt install util-linux     # Debian/Ubuntu"
		echo "          sudo dnf install util-linux     # Fedora/RHEL"
		echo "          sudo pacman -S util-linux       # Arch"
		echo "          sudo apk add util-linux         # Alpine"
	fi
	echo ""

	return 0
}

setup_shellcheck_wrapper() {
	# Replace the real shellcheck binary with our wrapper script to prevent
	# --external-sources from causing exponential memory growth (GH#2915).
	# This intercepts ALL callers including compiled binaries (e.g., OpenCode)
	# that invoke shellcheck by absolute path rather than via PATH.

	local wrapper_src="${INSTALL_DIR:-.}/.agents/scripts/shellcheck-wrapper.sh"
	if [[ ! -f "$wrapper_src" ]]; then
		print_info "shellcheck-wrapper.sh not found — skipping binary replacement"
		return 0
	fi

	# Find the real shellcheck binary
	local sc_path
	sc_path="$(command -v shellcheck 2>/dev/null || true)"
	if [[ -z "$sc_path" ]]; then
		print_info "shellcheck not installed — wrapper not needed yet"
		return 0
	fi

	# Resolve symlinks to get the actual binary path
	local sc_resolved
	sc_resolved="$(realpath "$sc_path" 2>/dev/null || readlink -f "$sc_path" 2>/dev/null || echo "$sc_path")"

	# Check if the binary is already our wrapper (idempotent)
	if head -5 "$sc_resolved" 2>/dev/null | grep -q "shellcheck-wrapper" 2>/dev/null; then
		# Already replaced — check that .real exists
		local real_path="${sc_resolved}.real"
		if [[ ! -x "$real_path" ]]; then
			print_warning "shellcheck wrapper installed but .real binary missing at $real_path"
			print_info "Reinstall shellcheck (brew reinstall shellcheck) then re-run setup"
			return 0
		fi

		# Check if the installed wrapper is outdated vs the source
		if ! diff -q "$wrapper_src" "$sc_resolved" >/dev/null 2>&1; then
			print_info "Updating shellcheck wrapper at $sc_resolved (source is newer)"
			if cp "$wrapper_src" "$sc_resolved" 2>/dev/null || sudo cp "$wrapper_src" "$sc_resolved" 2>/dev/null; then
				chmod +x "$sc_resolved" 2>/dev/null || sudo chmod +x "$sc_resolved" 2>/dev/null || true
				print_success "shellcheck wrapper updated at $sc_resolved"
			else
				print_warning "Cannot update wrapper — insufficient permissions"
			fi
		else
			print_success "shellcheck wrapper already installed at $sc_resolved"
		fi
		return 0
	fi

	# The binary at sc_resolved is the real shellcheck — replace it
	local real_dest="${sc_resolved}.real"

	print_info "Installing shellcheck wrapper at $sc_resolved"
	print_info "  Real binary will be moved to $real_dest"

	# Move real binary to .real suffix
	if ! mv "$sc_resolved" "$real_dest" 2>/dev/null; then
		# May need sudo (e.g., /usr/local/bin on some systems)
		if ! sudo mv "$sc_resolved" "$real_dest" 2>/dev/null; then
			print_warning "Cannot move shellcheck binary — insufficient permissions"
			print_info "Run manually: sudo mv '$sc_resolved' '$real_dest'"
			return 0
		fi
	fi

	# Copy wrapper to the original path
	if ! cp "$wrapper_src" "$sc_resolved" 2>/dev/null; then
		if ! sudo cp "$wrapper_src" "$sc_resolved" 2>/dev/null; then
			# Rollback
			mv "$real_dest" "$sc_resolved" 2>/dev/null || sudo mv "$real_dest" "$sc_resolved" 2>/dev/null || true
			print_warning "Cannot install wrapper — insufficient permissions"
			return 0
		fi
	fi

	# Ensure wrapper is executable
	chmod +x "$sc_resolved" 2>/dev/null || sudo chmod +x "$sc_resolved" 2>/dev/null || true

	print_success "shellcheck wrapper installed — --external-sources will be stripped"
	print_info "  Real binary: $real_dest"
	print_info "  Wrapper:     $sc_resolved"

	return 0
}

setup_qlty_cli() {
	print_info "Setting up Qlty CLI (multi-linter code quality)..."

	local qlty_bin="${HOME}/.qlty/bin/qlty"

	# Check if already installed
	if [[ -x "$qlty_bin" ]]; then
		local qlty_version
		qlty_version=$("$qlty_bin" --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Qlty CLI already installed: $qlty_version"
		return 0
	fi

	# Also check PATH in case it's installed elsewhere
	if command -v qlty >/dev/null 2>&1; then
		local qlty_version
		qlty_version=$(qlty --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Qlty CLI found in PATH: $qlty_version"
		return 0
	fi

	print_info "Qlty provides universal code quality analysis for 40+ languages"
	echo "  - Runs 70+ static analysis tools (ShellCheck, ESLint, etc.)"
	echo "  - Detects code smells and maintainability issues"
	echo "  - Used by the daily code quality sweep (pulse-wrapper.sh)"
	echo ""

	local install_qlty
	setup_prompt install_qlty "Install Qlty CLI? [Y/n]: " "Y"

	if [[ "$install_qlty" =~ ^[Yy]?$ ]]; then
		if command -v curl >/dev/null 2>&1; then
			if verified_install "Qlty CLI" "https://qlty.sh"; then
				# Verify installation
				if [[ -x "$qlty_bin" ]]; then
					local qlty_version
					qlty_version=$("$qlty_bin" --version 2>/dev/null | head -1 || echo "unknown")
					print_success "Qlty CLI installed: $qlty_version"
					print_info "Ensure ~/.qlty/bin is in your PATH"
					print_info "Documentation: ~/.aidevops/agents/tools/code-review/qlty.md"
				elif command -v qlty >/dev/null 2>&1; then
					print_success "Qlty CLI installed: $(qlty --version 2>/dev/null | head -1)"
				else
					print_warning "Qlty CLI install script ran but binary not found at $qlty_bin"
					print_info "Try restarting your shell or check ~/.qlty/bin/"
				fi
			else
				print_warning "Qlty CLI installation failed"
				print_info "Install manually: curl -fsSL https://qlty.sh | bash"
			fi
		else
			print_warning "curl not found — cannot install Qlty CLI"
			print_info "Install manually: curl -fsSL https://qlty.sh | bash"
		fi
	else
		print_info "Skipped Qlty CLI installation"
		print_info "Install later: curl -fsSL https://qlty.sh | bash"
	fi

	return 0
}

setup_rosetta_audit() {
	# Skip on non-Apple-Silicon or non-macOS
	if [[ "$(uname)" != "Darwin" ]] || [[ "$(uname -m)" != "arm64" ]]; then
		print_info "Rosetta audit: not applicable (Intel Mac or non-macOS)"
		return 0
	fi

	# Skip if no dual-brew setup
	if [[ ! -x "/usr/local/bin/brew" ]] || [[ ! -x "/opt/homebrew/bin/brew" ]]; then
		print_success "Rosetta audit: clean Homebrew setup (no x86 brew detected)"
		return 0
	fi

	print_info "Detected dual Homebrew (x86 + ARM) — checking for Rosetta overhead..."

	local x86_only_count dup_count
	dup_count=$(comm -12 \
		<(/usr/local/bin/brew list --formula 2>/dev/null | sort) \
		<(/opt/homebrew/bin/brew list --formula 2>/dev/null | sort) | wc -l | tr -d ' ')
	x86_only_count=$(comm -23 \
		<(/usr/local/bin/brew list --formula 2>/dev/null | sort) \
		<(/opt/homebrew/bin/brew list --formula 2>/dev/null | sort) | wc -l | tr -d ' ')

	local total=$((x86_only_count + dup_count))

	if [[ "$total" -eq 0 ]]; then
		print_success "No x86 Homebrew packages found — clean ARM setup"
		return 0
	fi

	print_warning "Found $total x86 Homebrew packages ($x86_only_count x86-only, $dup_count duplicates)"
	echo "  These run under Rosetta 2 emulation with ~30% performance overhead"
	echo ""
	echo "  To audit:   rosetta-audit-helper.sh scan"
	echo "  To migrate: rosetta-audit-helper.sh migrate --dry-run"
	echo "  To fix:     rosetta-audit-helper.sh migrate"

	return 0
}

# Install Worktrunk shell integration (enables 'wt switch' to change directories).
_setup_worktrunk_shell_integration() {
	print_info "Installing shell integration..."
	if wt config shell install; then
		print_success "Shell integration installed"
		print_info "Restart your terminal or source your shell config"
	else
		print_warning "Shell integration failed - run manually: wt config shell install"
	fi
	return 0
}

# Check and optionally install Worktrunk shell integration when wt is already present.
_check_worktrunk_shell_integration() {
	local wt_integrated=false
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if [[ -f "$rc_file" ]] && grep -q "worktrunk" "$rc_file" 2>/dev/null; then
			wt_integrated=true
			break
		fi
	done < <(get_all_shell_rcs)

	if [[ "$wt_integrated" == "false" ]]; then
		print_info "Shell integration not detected"
		local install_shell
		setup_prompt install_shell "Install Worktrunk shell integration (enables 'wt switch' to change directories)? [Y/n]: " "Y"
		if [[ "$install_shell" =~ ^[Yy]?$ ]]; then
			_setup_worktrunk_shell_integration
		fi
	else
		print_success "Shell integration already configured"
	fi
	return 0
}

# Install Worktrunk via Homebrew and set up shell integration.
_install_worktrunk_brew() {
	local install_wt
	setup_prompt install_wt "Install Worktrunk via Homebrew? [Y/n]: " "Y"

	if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Worktrunk via Homebrew" brew install max-sixty/worktrunk/wt; then
			_setup_worktrunk_shell_integration
			echo ""
			print_info "Quick start:"
			echo "  wt switch feature/my-feature  # Create/switch to worktree"
			echo "  wt list                       # List all worktrees"
			echo "  wt merge                      # Merge and cleanup"
			echo ""
			print_info "Documentation: ~/.aidevops/agents/tools/git/worktrunk.md"
		else
			print_warning "Homebrew installation failed"
			echo "  Try: cargo install worktrunk && wt config shell install"
		fi
	else
		print_info "Skipped Worktrunk installation"
		print_info "Install later: brew install max-sixty/worktrunk/wt"
		print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
	fi
	return 0
}

# Install Worktrunk via Cargo and set up shell integration.
_install_worktrunk_cargo() {
	local install_wt
	setup_prompt install_wt "Install Worktrunk via Cargo? [Y/n]: " "Y"

	if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Worktrunk via Cargo" cargo install worktrunk; then
			_setup_worktrunk_shell_integration
		else
			print_warning "Cargo installation failed"
		fi
	else
		print_info "Skipped Worktrunk installation"
	fi
	return 0
}

setup_worktrunk() {
	print_info "Setting up Worktrunk (git worktree management)..."

	# Check if worktrunk (wt) is already installed
	if command -v wt >/dev/null 2>&1; then
		local wt_version
		wt_version=$(wt --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Worktrunk already installed: $wt_version"
		_check_worktrunk_shell_integration
		return 0
	fi

	# Worktrunk not installed - offer to install
	print_info "Worktrunk makes git worktrees as easy as branches"
	echo "  • wt switch feat     - Switch/create worktree (with cd)"
	echo "  • wt list            - List worktrees with CI status"
	echo "  • wt merge           - Squash/rebase/merge + cleanup"
	echo "  • Hooks for automated setup (npm install, etc.)"
	echo ""
	echo "  Note: aidevops also includes worktree-helper.sh as a fallback"
	echo ""

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$pkg_manager" == "brew" ]]; then
		_install_worktrunk_brew
	elif command -v cargo >/dev/null 2>&1; then
		_install_worktrunk_cargo
	else
		print_warning "Worktrunk not installed"
		echo ""
		echo "  Install options:"
		echo "    macOS/Linux (Homebrew): brew install max-sixty/worktrunk/wt"
		echo "    Cargo:                  cargo install worktrunk"
		echo "    Windows:                winget install max-sixty.worktrunk"
		echo ""
		echo "  After install: wt config shell install"
		echo ""
		print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
	fi

	return 0
}

# Trigger OpenCode extension install in Zed via the zed:// URI scheme.
_install_opencode_ext_for_zed() {
	local install_opencode_ext
	setup_prompt install_opencode_ext "Install OpenCode extension for Zed? [Y/n]: " "Y"
	if [[ "$install_opencode_ext" =~ ^[Yy]?$ ]]; then
		print_info "Installing OpenCode extension..."
		if [[ "$(uname)" == "Darwin" ]]; then
			open "zed://extension/opencode" 2>/dev/null
			print_success "OpenCode extension install triggered"
			print_info "Zed will open and prompt to install the extension"
		elif [[ "$(uname)" == "Linux" ]]; then
			xdg-open "zed://extension/opencode" 2>/dev/null ||
				print_info "Open Zed and install 'opencode' from Extensions (Cmd+Shift+X)"
		fi
	fi
	return 0
}

# Install Tabby terminal on Linux (x86_64 only via packagecloud; ARM64 manual).
_install_tabby_linux() {
	local arch
	arch=$(uname -m)
	# Tabby packagecloud repo only has x86_64 packages
	# ARM64 (aarch64) must use .deb from GitHub releases or skip
	if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
		# Clean up stale Tabby packagecloud repo if it exists from a previous run
		# (it causes apt-get update failures on ARM64)
		if [[ -f /etc/apt/sources.list.d/eugeny_tabby.list ]]; then
			print_info "Removing stale Tabby packagecloud repo (not available for ARM64)..."
			sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.list
			sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.sources
			sudo apt-get update -qq 2>/dev/null || true
		fi
		print_warning "Tabby packages are not available for ARM64 Linux via package manager"
		echo "  Download ARM64 .deb from: https://github.com/Eugeny/tabby/releases/latest"
		echo "  Or skip Tabby - it's optional (a modern terminal emulator)"
		return 0
	fi

	local pkg_manager
	pkg_manager=$(detect_package_manager)
	case "$pkg_manager" in
	apt)
		# Add packagecloud repo for Tabby (verified download, not piped to sudo)
		# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
		VERIFIED_INSTALL_SUDO="true"
		if verified_install "Tabby repository (apt)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.deb.sh"; then
			if ! sudo apt-get install -y tabby-terminal; then
				print_warning "Tabby package not found for this architecture"
				echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
			fi
		fi
		;;
	dnf | yum)
		# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
		VERIFIED_INSTALL_SUDO="true"
		if verified_install "Tabby repository (rpm)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.rpm.sh"; then
			if ! sudo "$pkg_manager" install -y tabby-terminal; then
				print_warning "Tabby package not found for this architecture"
				echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
			fi
		fi
		;;
	pacman)
		# AUR package
		print_info "Tabby available in AUR as 'tabby-bin'"
		echo "  Install with: yay -S tabby-bin"
		;;
	*)
		echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
		;;
	esac
	return 0
}

# Offer and perform Tabby terminal installation.
_install_tabby() {
	local install_tabby
	setup_prompt install_tabby "Install Tabby terminal? [Y/n]: " "Y"

	if [[ "$install_tabby" =~ ^[Yy]?$ ]]; then
		if [[ "$(uname)" == "Darwin" ]]; then
			if command -v brew >/dev/null 2>&1; then
				if run_with_spinner "Installing Tabby" brew install --cask tabby; then
					: # Success message handled by spinner
				else
					print_warning "Failed to install Tabby via Homebrew"
					echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
				fi
			else
				print_warning "Homebrew not found"
				echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
			fi
		elif [[ "$(uname)" == "Linux" ]]; then
			_install_tabby_linux
		fi
	else
		print_info "Skipped Tabby installation"
	fi
	return 0
}

# Offer and perform Zed editor installation, then optionally install OpenCode extension.
_install_zed_and_opencode_ext() {
	local install_zed
	setup_prompt install_zed "Install Zed editor? [Y/n]: " "Y"

	if [[ "$install_zed" =~ ^[Yy]?$ ]]; then
		local zed_installed=false
		if [[ "$(uname)" == "Darwin" ]]; then
			if command -v brew >/dev/null 2>&1; then
				if run_with_spinner "Installing Zed" brew install --cask zed; then
					zed_installed=true
				else
					print_warning "Failed to install Zed via Homebrew"
					echo "  Download manually: https://zed.dev/download"
				fi
			else
				print_warning "Homebrew not found"
				echo "  Download manually: https://zed.dev/download"
			fi
		elif [[ "$(uname)" == "Linux" ]]; then
			# Zed provides an install script for Linux (verified download)
			# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
			VERIFIED_INSTALL_SHELL="sh"
			if verified_install "Zed" "https://zed.dev/install.sh"; then
				zed_installed=true
			else
				print_warning "Failed to install Zed"
				echo "  See: https://zed.dev/docs/linux"
			fi
		fi

		if [[ "$zed_installed" == "true" ]]; then
			_install_opencode_ext_for_zed
		fi
	else
		print_info "Skipped Zed installation"
	fi
	return 0
}

# Check for OpenCode extension in an existing Zed installation and offer to install.
_check_opencode_ext_existing_zed() {
	local zed_extensions_dir=""
	if [[ "$(uname)" == "Darwin" ]]; then
		zed_extensions_dir="$HOME/Library/Application Support/Zed/extensions/installed"
	elif [[ "$(uname)" == "Linux" ]]; then
		zed_extensions_dir="$HOME/.local/share/zed/extensions/installed"
	fi

	if [[ -d "$zed_extensions_dir" ]]; then
		if [[ ! -d "$zed_extensions_dir/opencode" ]]; then
			_install_opencode_ext_for_zed
		else
			print_success "OpenCode extension already installed in Zed"
		fi
	fi
	return 0
}

setup_recommended_tools() {
	print_info "Checking recommended development tools..."

	local missing_tools=()
	local missing_names=()

	# Check for Tabby terminal
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS - check Applications folder
		if [[ ! -d "/Applications/Tabby.app" ]]; then
			missing_tools+=("tabby")
			missing_names+=("Tabby (modern terminal)")
		else
			print_success "Tabby terminal found"
		fi
	elif [[ "$(uname)" == "Linux" ]]; then
		# Linux - check if tabby command exists
		if ! command -v tabby >/dev/null 2>&1; then
			missing_tools+=("tabby")
			missing_names+=("Tabby (modern terminal)")
		else
			print_success "Tabby terminal found"
		fi
	fi

	# Check for Zed editor
	local zed_exists=false
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS - check Applications folder
		if [[ ! -d "/Applications/Zed.app" ]]; then
			missing_tools+=("zed")
			missing_names+=("Zed (AI-native editor)")
		else
			print_success "Zed editor found"
			zed_exists=true
		fi
	elif [[ "$(uname)" == "Linux" ]]; then
		# Linux - check if zed command exists
		if ! command -v zed >/dev/null 2>&1; then
			missing_tools+=("zed")
			missing_names+=("Zed (AI-native editor)")
		else
			print_success "Zed editor found"
			zed_exists=true
		fi
	fi

	# Check for OpenCode extension in existing Zed installation
	if [[ "$zed_exists" == "true" ]]; then
		_check_opencode_ext_existing_zed
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing recommended tools: ${missing_names[*]}"
		echo "  Tabby - Modern terminal with profiles, SSH manager, split panes"
		echo "  Zed   - High-performance AI-native code editor"
		echo ""

		# Install Tabby if missing
		if [[ " ${missing_tools[*]} " =~ " tabby " ]]; then
			_install_tabby
		fi

		# Install Zed if missing
		if [[ " ${missing_tools[*]} " =~ " zed " ]]; then
			_install_zed_and_opencode_ext
		fi
	else
		print_success "All recommended tools installed!"
	fi

	# Check for Cursor CLI (agent) — independent of the missing_tools flow
	# since it uses a curl installer, not brew
	setup_cursor_cli

	return 0
}

setup_cursor_cli() {
	print_info "Checking Cursor CLI (agent)..."

	if command -v agent >/dev/null 2>&1; then
		local cursor_version
		cursor_version=$(agent --version 2>/dev/null || echo "unknown")
		print_success "Cursor CLI found: $cursor_version"
		return 0
	fi

	# Check ~/.local/bin specifically (may not be in PATH yet)
	if [[ -x "$HOME/.local/bin/agent" ]]; then
		local cursor_version
		cursor_version=$("$HOME/.local/bin/agent" --version 2>/dev/null || echo "unknown")
		print_success "Cursor CLI found at ~/.local/bin/agent: $cursor_version"
		print_info "Ensure ~/.local/bin is in your PATH"
		return 0
	fi

	echo "  Cursor CLI provides access to Cursor's AI models (including Composer 2)"
	echo "  from the terminal. Also usable as an OpenCode provider via the"
	echo "  opencode-cursor plugin for OAuth-based model access."
	echo ""

	local install_cursor
	setup_prompt install_cursor "Install Cursor CLI? [Y/n]: " "Y"

	if [[ "$install_cursor" =~ ^[Yy]?$ ]]; then
		print_info "Installing Cursor CLI..."
		if verified_install "Cursor CLI" "https://cursor.com/install"; then
			# Ensure ~/.local/bin is in PATH for this session
			if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
				export PATH="$HOME/.local/bin:$PATH"
				print_info "Added ~/.local/bin to PATH for this session"
			fi
			print_success "Cursor CLI installed"
			echo ""
			echo "  Next steps:"
			echo "    agent login     # Authenticate with your Cursor account"
			echo "    agent models    # List available models"
			echo "    agent status    # Check auth status"
		else
			print_warning "Failed to install Cursor CLI"
			echo "  Install manually: curl https://cursor.com/install -fsS | bash"
		fi
	else
		print_info "Skipped Cursor CLI installation"
		echo "  Install later: curl https://cursor.com/install -fsS | bash"
	fi

	return 0
}

setup_minisim() {
	# Only available on macOS
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	print_info "Setting up MiniSim (iOS/Android emulator launcher)..."

	# Check if MiniSim is already installed
	if [[ -d "/Applications/MiniSim.app" ]]; then
		print_success "MiniSim already installed"
		print_info "Global shortcut: Option + Shift + E"
		return 0
	fi

	# Check if Xcode or Android Studio is installed (MiniSim needs at least one)
	local has_xcode=false
	local has_android=false

	if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1; then
		has_xcode=true
	fi

	if [[ -n "${ANDROID_HOME:-}" ]] || [[ -n "${ANDROID_SDK_ROOT:-}" ]] || [[ -d "$HOME/Library/Android/sdk" ]]; then
		has_android=true
	fi

	if [[ "$has_xcode" == "false" && "$has_android" == "false" ]]; then
		print_info "MiniSim requires Xcode (iOS) or Android Studio (Android)"
		print_info "Install one of these first, then re-run setup to install MiniSim"
		return 0
	fi

	# Show what's available
	local available_for=""
	if [[ "$has_xcode" == "true" ]]; then
		available_for="iOS simulators"
	fi
	if [[ "$has_android" == "true" ]]; then
		if [[ -n "$available_for" ]]; then
			available_for="$available_for and Android emulators"
		else
			available_for="Android emulators"
		fi
	fi

	print_info "MiniSim is a menu bar app for launching $available_for"
	echo "  Features:"
	echo "    - Global shortcut: Option + Shift + E"
	echo "    - Launch/manage iOS simulators and Android emulators"
	echo "    - Copy device UDID/ADB ID"
	echo "    - Cold boot Android emulators"
	echo "    - Run Android emulators without audio (saves Bluetooth battery)"
	echo ""

	# Check if Homebrew is available
	if ! command -v brew >/dev/null 2>&1; then
		print_warning "Homebrew not found - cannot install MiniSim automatically"
		echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
		return 0
	fi

	local install_minisim
	setup_prompt install_minisim "Install MiniSim? [Y/n]: " "Y"

	if [[ "$install_minisim" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing MiniSim" brew install --cask minisim; then
			print_info "Global shortcut: Option + Shift + E"
			print_info "Documentation: ~/.aidevops/agents/tools/mobile/minisim.md"
		else
			print_warning "Failed to install MiniSim via Homebrew"
			echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
		fi
	else
		print_info "Skipped MiniSim installation"
		print_info "Install later: brew install --cask minisim"
	fi

	return 0
}

_setup_serve_sim_node_version_ok() {
	local node_version="$1"
	local version="${node_version#v}"
	local major="${version%%.*}"

	if [[ "$major" =~ ^[0-9]+$ ]] && ((10#$major >= 20)); then
		return 0
	fi
	return 1
}

_setup_serve_sim_cli_version() {
	if serve-sim --version >/dev/null 2>&1; then
		serve-sim --version 2>/dev/null
	else
		printf '%s\n' 'installed'
	fi
	return 0
}

_setup_serve_sim_swiftpm_ok() {
	if ! command -v xcrun >/dev/null 2>&1; then
		return 1
	fi

	if ! xcrun simctl list devices >/dev/null 2>&1; then
		return 1
	fi

	if ! xcrun swift build --version >/dev/null 2>&1; then
		return 1
	fi

	return 0
}

setup_serve_sim() {
	# serve-sim currently ships an arm64 native Apple Simulator addon.
	if [[ "$(uname -s)" != "Darwin" ]]; then
		return 0
	fi

	if [[ "$(uname -m)" != "arm64" ]]; then
		print_info "serve-sim requires Apple Silicon (arm64); skipping on this Mac"
		return 0
	fi

	print_info "Setting up serve-sim (Apple Simulator browser preview)..."

	if command -v serve-sim >/dev/null 2>&1; then
		local serve_sim_version
		serve_sim_version=$(_setup_serve_sim_cli_version)
		print_success "serve-sim already installed: ${serve_sim_version}"
		print_info "Documentation: ~/.aidevops/agents/tools/mobile/serve-sim.md"
		return 0
	fi

	if ! _setup_serve_sim_swiftpm_ok; then
		print_info "serve-sim requires Xcode command-line tools, SwiftPM swiftbuild support, and simulator support"
		print_info "Install Xcode/Command Line Tools, then re-run setup"
		return 0
	fi

	if ! command -v node >/dev/null 2>&1; then
		print_info "serve-sim requires Node.js 20+"
		print_info "Install Node.js, then re-run setup"
		return 0
	fi

	local node_version
	node_version=$(node --version 2>/dev/null || printf '%s\n' 'unknown')
	if ! _setup_serve_sim_node_version_ok "$node_version"; then
		print_warning "serve-sim requires Node.js 20+, found ${node_version}"
		print_info "Upgrade Node.js, then re-run setup"
		return 0
	fi

	if ! command -v npm >/dev/null 2>&1; then
		print_info "serve-sim installs via npm; install Node.js/npm first"
		return 0
	fi

	print_info "serve-sim streams booted Apple Simulators to a browser for agent/user review"
	printf '%s\n' "  Features:"
	printf '%s\n' "    - Browser preview at http://localhost:3200"
	printf '%s\n' "    - In-process native capture/HID with H.264/MJPEG stream control"
	printf '%s\n' "    - SwiftPM swiftbuild-backed native addon on current Xcode toolchains"
	printf '%s\n' "    - Gestures, hardware buttons, typing, rotation, memory warnings"
	printf '%s\n' "    - Camera feed injection for simulator apps"
	printf '%s\n' ""

	local install_serve_sim
	setup_prompt install_serve_sim "Install serve-sim globally? [Y/n]: " "Y" || install_serve_sim="N"

	if [[ "${install_serve_sim:-}" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing serve-sim" npm_global_install "serve-sim@latest"; then
			print_success "serve-sim installed"
			print_info "Start a booted simulator preview: serve-sim"
			print_info "Documentation: ~/.aidevops/agents/tools/mobile/serve-sim.md"
		else
			print_warning "Failed to install serve-sim"
			printf '%s\n' "  Try manually: npm install -g serve-sim"
		fi
	else
		print_info "Skipped serve-sim installation"
		print_info "Install later: npm install -g serve-sim"
	fi

	return 0
}

setup_mobile_simulator_tools() {
	setup_minisim
	setup_serve_sim
	return 0
}

setup_claudebar_needs_upgrade() {
	local installed_version="$1"
	local target_version="$2"
	local installed_major="" installed_minor="" installed_patch=""
	local target_major="" target_minor="" target_patch=""

	installed_version="${installed_version#v}"
	target_version="${target_version#v}"

	if [[ ! "$installed_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		return 0
	fi
	installed_major="${BASH_REMATCH[1]}"
	installed_minor="${BASH_REMATCH[2]}"
	installed_patch="${BASH_REMATCH[3]}"

	if [[ ! "$target_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		return 0
	fi
	target_major="${BASH_REMATCH[1]}"
	target_minor="${BASH_REMATCH[2]}"
	target_patch="${BASH_REMATCH[3]}"

	if ((10#$installed_major > 10#$target_major)); then
		return 1
	fi
	if ((10#$installed_major == 10#$target_major && 10#$installed_minor > 10#$target_minor)); then
		return 1
	fi
	if ((10#$installed_major == 10#$target_major && 10#$installed_minor == 10#$target_minor && 10#$installed_patch >= 10#$target_patch)); then
		return 1
	fi

	return 0
}

setup_claudebar() {
	local claudebar_release_url="https://github.com/tddworks/ClaudeBar/releases/latest"
	local claudebar_target_version="0.4.66"
	# Only available on macOS (native Swift menu bar app)
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	print_info "Setting up ClaudeBar (AI quota monitor)..."

	# Check if ClaudeBar is already installed
	if [[ -d "/Applications/ClaudeBar.app" ]]; then
		local claudebar_info_plist="/Applications/ClaudeBar.app/Contents/Info.plist"
		local installed_version=""

		if [[ -f "$claudebar_info_plist" ]]; then
			installed_version="$(defaults read "$claudebar_info_plist" CFBundleShortVersionString 2>/dev/null || true)"
		fi

		print_success "ClaudeBar already installed"
		if ! setup_claudebar_needs_upgrade "$installed_version" "$claudebar_target_version"; then
			print_info "ClaudeBar ${installed_version} already includes the v${claudebar_target_version} setup upgrade"
			return 0
		fi

		print_info "ClaudeBar v0.4.66 adds live background menu-bar refresh and suppresses its own quota probe events"
		if command -v brew >/dev/null 2>&1; then
			local upgrade_claudebar
			setup_prompt upgrade_claudebar "Upgrade ClaudeBar via Homebrew cask? [y/N]: " "N"
			if [[ "$upgrade_claudebar" =~ ^[Yy]$ ]]; then
				if run_with_spinner "Upgrading ClaudeBar" brew upgrade --cask claudebar; then
					print_success "ClaudeBar upgraded"
				else
					print_warning "Failed to upgrade ClaudeBar via Homebrew"
					print_info "Manual ClaudeBar download: $claudebar_release_url"
				fi
			else
				print_info "Upgrade later: brew upgrade --cask claudebar"
			fi
		else
			print_info "Update manually: $claudebar_release_url"
		fi
		return 0
	fi

	# Check if Homebrew is available (required for cask install)
	if ! command -v brew >/dev/null 2>&1; then
		print_warning "Homebrew not found - cannot install ClaudeBar automatically"
		echo "  Download manually: $claudebar_release_url"
		return 0
	fi

	print_info "ClaudeBar monitors AI coding assistant usage quotas in your menu bar"
	echo "  Supports: Claude, Codex, Gemini, Copilot, Antigravity, Kimi, Kiro, Amp"
	echo "  Features: live menu-bar refresh, quota probe suppression, real-time quota tracking, provider process detection, status notifications, multiple themes"
	echo "  Requires: macOS 15+, CLI tools for providers you want to monitor"
	echo ""

	local install_claudebar
	setup_prompt install_claudebar "Install ClaudeBar? [Y/n]: " "Y"

	if [[ "$install_claudebar" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing ClaudeBar" brew install --cask claudebar; then
			print_success "ClaudeBar installed"
			print_info "Launch from Applications or Spotlight to start monitoring quotas"
		else
			print_warning "Failed to install ClaudeBar via Homebrew"
			echo "  Download manually: $claudebar_release_url"
		fi
	else
		print_info "Skipped ClaudeBar installation"
		print_info "Install later: brew install --cask claudebar"
	fi

	return 0
}

setup_ssh_key() {
	print_info "Checking SSH key setup..."

	if [[ ! -f ~/.ssh/id_ed25519 ]]; then
		print_warning "Ed25519 SSH key not found"

		# SSH key generation requires email input — skip in non-interactive mode
		if [[ "${NON_INTERACTIVE:-false}" == "true" ]] || [[ ! -t 0 ]]; then
			print_info "Skipping SSH key generation (non-interactive mode)"
			return 0
		fi

		local generate_key
		setup_prompt generate_key "Generate new Ed25519 SSH key? [Y/n]: " "Y"

		if [[ "$generate_key" =~ ^[Yy]?$ ]]; then
			local email
			setup_prompt email "Enter your email address: " ""
			if [[ -z "$email" ]]; then
				print_warning "No email provided — skipping SSH key generation"
				return 0
			fi
			install -d -m 700 ~/.ssh
			ssh-keygen -t ed25519 -C "$email" -f ~/.ssh/id_ed25519
			print_success "SSH key generated"
		else
			print_info "Skipping SSH key generation"
		fi
	else
		print_success "Ed25519 SSH key found"
	fi
	return 0
}

# Check installed Python version against latest stable available from package manager.
# Warns if an upgrade is available but never auto-upgrades (GH#5237).
# Works on macOS (Homebrew) and Linux (apt/dnf).
# Named check_python_upgrade_available() to avoid collision with the shared
# check_python_version() in _common.sh (which validates minimum required version).
check_python_upgrade_available() {
	print_info "Checking Python version..."

	# 1. Check currently installed Python
	local python3_bin
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found"
		echo ""
		echo "  Install options:"
		if [[ "$PLATFORM_MACOS" == "true" ]]; then
			echo "    brew install python3"
		elif command -v apt-get >/dev/null 2>&1; then
			echo "    sudo apt install python3"
		elif command -v dnf >/dev/null 2>&1; then
			echo "    sudo dnf install python3"
		else
			echo "    Install Python 3 via your system package manager"
		fi
		echo ""
		return 0
	fi

	local installed_version
	installed_version=$("$python3_bin" --version 2>&1 | cut -d' ' -f2)
	local installed_major installed_minor
	installed_major=$(echo "$installed_version" | cut -d. -f1)
	installed_minor=$(echo "$installed_version" | cut -d. -f2)

	# 2. Determine latest stable version from package manager
	local latest_version=""

	if [[ "$PLATFORM_MACOS" == "true" ]] && command -v brew >/dev/null 2>&1; then
		# Homebrew: `brew info python3` outputs "python@3.X: 3.X.Y" on the first line
		latest_version=$(brew info --json=v2 python3 2>/dev/null |
			python3 -c "import sys,json; d=json.load(sys.stdin); print(d['formulae'][0]['versions']['stable'])" 2>/dev/null) || latest_version=""
	elif command -v apt-cache >/dev/null 2>&1; then
		# Debian/Ubuntu: get candidate version from apt-cache
		latest_version=$(apt-cache policy python3 2>/dev/null |
			awk '/Candidate:/{print $2}' |
			grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || latest_version=""
	elif command -v dnf >/dev/null 2>&1; then
		# Fedora/RHEL: get available version from dnf
		latest_version=$(dnf info python3 2>/dev/null |
			awk '/^Version/{print $3}') || latest_version=""
	fi

	# 3. Compare versions and advise
	if [[ -z "$latest_version" ]]; then
		# Could not determine latest — just report installed version
		print_success "Python $installed_version found"
		return 0
	fi

	local latest_major latest_minor
	latest_major=$(echo "$latest_version" | cut -d. -f1)
	latest_minor=$(echo "$latest_version" | cut -d. -f2)

	# Compare major.minor (patch differences are not worth warning about)
	if [[ "$installed_major" -lt "$latest_major" ]] ||
		{ [[ "$installed_major" -eq "$latest_major" ]] && [[ "$installed_minor" -lt "$latest_minor" ]]; }; then
		print_warning "Python $installed_version installed, but $latest_version is available"
		echo ""
		echo "  Some tools and skills require Python 3.10+."
		echo "  Upgrade is recommended but not required."
		echo ""
		if [[ "$PLATFORM_MACOS" == "true" ]]; then
			echo "  Upgrade command:"
			echo "    brew upgrade python3"
		elif command -v apt-get >/dev/null 2>&1; then
			echo "  Upgrade command:"
			echo "    sudo apt update && sudo apt install python3"
		elif command -v dnf >/dev/null 2>&1; then
			echo "  Upgrade command:"
			echo "    sudo dnf upgrade python3"
		fi
		echo ""
	else
		print_success "Python $installed_version found (latest stable: $latest_version)"
	fi

	return 0
}

_vault_runtime_path_safe() {
	local env_dir="$1"
	local expected_dir="${HOME}/.aidevops/.agent-workspace/python-env/vault"
	[[ "$env_dir" == "$expected_dir" ]] || return 1
	local component=""
	for component in \
		"${HOME}/.aidevops" \
		"${HOME}/.aidevops/.agent-workspace" \
		"${HOME}/.aidevops/.agent-workspace/python-env" \
		"$env_dir"; do
		[[ -L "$component" ]] && return 1
	done
	return 0
}

_vault_runtime_marker_valid() {
	local marker_path="$1"
	[[ -f "$marker_path" && ! -L "$marker_path" && -O "$marker_path" ]] || return 1
	local marker_value=""
	marker_value=$(<"$marker_path")
	[[ "$marker_value" == "aidevops-vault-runtime-v1" || "$marker_value" == "managed by aidevops setup" ]]
	return $?
}

setup_vault_python_env() {
	print_info "Setting up isolated Python crypto runtime for Vault..."
	local python3_bin=""
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found - Vault crypto runtime unavailable"
		return 1
	fi
	local module_dir=""
	module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
	local source_root="${INSTALL_DIR:-}"
	[[ -z "$source_root" ]] && source_root="$(cd "${module_dir}/../../../.." && pwd)"
	local requirements_file="${source_root}/.agents/configs/vault-requirements.txt"
	local runtime_check="${source_root}/.agents/scripts/vault-runtime-check.py"
	local env_dir="${HOME}/.aidevops/.agent-workspace/python-env/vault"
	local env_python="${env_dir}/bin/python3"
	local managed_marker="${env_dir}/.aidevops-managed-runtime"
	local marker_value="aidevops-vault-runtime-v1"

	if ! _vault_runtime_path_safe "$env_dir"; then
		print_warning "Refusing unsafe Vault runtime path: $env_dir"
		return 1
	fi
	if [[ ! -f "$requirements_file" || ! -f "$runtime_check" ]]; then
		print_warning "Vault runtime requirements or readiness check is missing"
		return 1
	fi
	if [[ -e "$env_dir" ]]; then
		if ! _vault_runtime_marker_valid "$managed_marker" || ! "$python3_bin" "$runtime_check" --check-ancestors "$HOME" "$env_dir"; then
			print_warning "Refusing to execute or replace an unowned Vault runtime: $env_dir"
			return 1
		fi
		if "$python3_bin" "$runtime_check" --check-path "$env_dir" "$managed_marker" && [[ -x "$env_python" ]] && "$env_python" "$runtime_check" 2>/dev/null; then
			printf '%s\n' "$marker_value" >"$managed_marker"
			chmod 600 "$managed_marker"
			print_success "Vault crypto runtime is ready"
			return 0
		fi
	fi
	if ! (umask 077 && mkdir -p "${env_dir%/*}"); then
		print_warning "Failed to create the protected Vault runtime parent"
		return 1
	fi
	if ! _vault_runtime_path_safe "$env_dir"; then
		print_warning "Refusing unsafe Vault runtime path after parent creation: $env_dir"
		return 1
	fi
	if ! "$python3_bin" "$runtime_check" --check-ancestors "$HOME" "$env_dir"; then
		print_warning "Refusing writable or unowned Vault runtime ancestors"
		return 1
	fi
	if [[ -d "$env_dir" ]]; then
		rm -rf "$env_dir"
	fi
	if ! (umask 077 && "$python3_bin" -m venv --copies "$env_dir"); then
		print_warning "Failed to create isolated Vault Python environment"
		rm -rf "$env_dir"
		return 1
	fi
	chmod 755 "$env_dir"
	if ! "$python3_bin" "$runtime_check" --check-path "$env_dir"; then
		print_warning "Fresh Vault runtime ownership verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	if ! (umask 077 && "$env_python" -m pip install --disable-pip-version-check --no-input --only-binary=:all: -r "$requirements_file"); then
		print_warning "Failed to install the pinned Vault crypto runtime"
		rm -rf "$env_dir"
		return 1
	fi
	if ! "$python3_bin" "$runtime_check" --check-path "$env_dir"; then
		print_warning "Vault crypto runtime ownership verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	if ! "$env_python" "$runtime_check"; then
		print_warning "Vault crypto runtime verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	if ! (umask 077 && printf '%s\n' "$marker_value" >"$managed_marker"); then
		print_warning "Failed to publish the verified Vault runtime marker"
		rm -rf "$env_dir"
		return 1
	fi
	chmod 600 "$managed_marker"
	if ! "$python3_bin" "$runtime_check" --check-path "$env_dir" "$managed_marker"; then
		print_warning "Published Vault runtime verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	print_success "Vault crypto runtime is ready"
	return 0
}

setup_python_env() {
	print_info "Setting up Python environment for DSPy..."

	# Check if Python 3 is available
	local python3_bin
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found - DSPy setup skipped"
		print_info "Install Python 3.8+ to enable DSPy integration"
		return
	fi

	local python_version
	python_version=$("$python3_bin" --version | cut -d' ' -f2 | cut -d'.' -f1-2)
	local version_check
	version_check=$("$python3_bin" -c "import sys; print(1 if sys.version_info >= (3, 8) else 0)")

	if [[ "$version_check" != "1" ]]; then
		print_warning "Python 3.8+ required for DSPy, found $python_version - DSPy setup skipped"
		return
	fi

	# Create Python virtual environment
	if [[ ! -d "python-env/dspy-env" ]] || [[ ! -f "python-env/dspy-env/bin/activate" ]]; then
		print_info "Creating Python virtual environment for DSPy..."
		mkdir -p python-env
		# Remove corrupted venv if directory exists but activate script is missing
		if [[ -d "python-env/dspy-env" ]] && [[ ! -f "python-env/dspy-env/bin/activate" ]]; then
			rm -rf python-env/dspy-env
		fi
		if "$python3_bin" -m venv python-env/dspy-env; then
			print_success "Python virtual environment created"
		else
			print_warning "Failed to create Python virtual environment - DSPy setup skipped"
			return
		fi
	else
		print_info "Python virtual environment already exists"
	fi

	if ! declare -F aidevops_secure_dspy_cache >/dev/null 2>&1; then
		print_warning "DSPy cache security helper unavailable - DSPy setup skipped"
		return 0
	fi
	if ! aidevops_secure_dspy_cache; then
		print_warning "DSPy cache could not be restricted to an owner-only directory - DSPy setup skipped"
		return 0
	fi
	if ! aidevops_persist_dspy_cache_env "python-env/dspy-env/bin/activate"; then
		print_warning "DSPy cache environment could not be persisted - DSPy setup skipped"
		return 0
	fi

	# Install DSPy dependencies
	print_info "Installing DSPy dependencies..."
	# shellcheck source=/dev/null
	if [[ -f "python-env/dspy-env/bin/activate" ]]; then
		source python-env/dspy-env/bin/activate
	else
		print_warning "Python venv activate script not found - DSPy setup skipped"
		return
	fi
	pip install --upgrade pip >/dev/null 2>&1

	if run_with_spinner "Installing DSPy dependencies" pip install -r requirements.txt; then
		: # Success message handled by spinner
	else
		print_info "Check requirements.txt or run manually:"
		print_info "  source python-env/dspy-env/bin/activate && pip install -r requirements.txt"
	fi
	return 0
}

setup_nodejs_env() {
	print_info "Setting up Node.js environment for DSPyGround..."

	# Check if Node.js is available
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - DSPyGround setup skipped"
		print_info "Install Node.js 18+ to enable DSPyGround integration"
		return
	fi

	local node_version
	node_version=$(node --version 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ -z "$node_version" ]] || ! [[ "$node_version" =~ ^[0-9]+$ ]]; then
		print_warning "Could not determine Node.js version - DSPyGround setup skipped"
		return
	fi
	if [[ "$node_version" -lt 18 ]]; then
		print_warning "Node.js 18+ required for DSPyGround, found v$node_version - DSPyGround setup skipped"
		return
	fi

	# Check if npm is available
	if ! command -v npm &>/dev/null; then
		print_warning "npm not found - DSPyGround setup skipped"
		return
	fi

	# Install DSPyGround globally if not already installed
	if ! command -v dspyground &>/dev/null; then
		if run_with_spinner "Installing DSPyGround" npm_global_install dspyground; then
			: # Success message handled by spinner
		else
			print_warning "Try manually: sudo npm install -g dspyground"
		fi
	else
		print_success "DSPyGround already installed"
	fi
}

# Install Node.js via apt, preferring NodeSource LTS over the distro package.
_install_nodejs_apt() {
	# Clean up stale Tabby packagecloud repo if present (causes apt-get update failures)
	if [[ -f /etc/apt/sources.list.d/eugeny_tabby.list ]]; then
		local arch
		arch=$(uname -m)
		if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
			print_info "Removing stale Tabby repo (not available for ARM64)..."
			sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.list
			sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.sources
		fi
	fi

	# Use NodeSource for a recent version (apt default may be old)
	print_info "Installing Node.js (via NodeSource for latest LTS)..."
	if command -v curl >/dev/null 2>&1; then
		# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
		VERIFIED_INSTALL_SUDO="true"
		if verified_install "NodeSource repository" "https://deb.nodesource.com/setup_22.x"; then
			# Install nodejs (NodeSource bundles npm, but distro fallback may not)
			# Include npm explicitly in case NodeSource setup failed silently
			# and apt falls back to the distro nodejs package (which lacks npm)
			if sudo apt-get install -y nodejs npm 2>/dev/null || sudo apt-get install -y nodejs; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		else
			# Fallback to distro package
			print_info "Falling back to distro Node.js package..."
			if sudo apt-get install -y nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
	else
		if sudo apt-get install -y nodejs npm; then
			print_success "Node.js installed: $(node --version)"
		else
			print_warning "Node.js installation failed"
		fi
	fi
	return 0
}

# Ensure npm is present when Node.js is already installed (distro packages may omit it).
_ensure_npm_installed() {
	if command -v npm >/dev/null 2>&1; then
		return 0
	fi
	print_info "npm not found (distro nodejs package may omit it) — installing..."
	local pkg_manager
	pkg_manager=$(detect_package_manager)
	case "$pkg_manager" in
	apt) sudo apt-get install -y npm 2>/dev/null || print_warning "Failed to install npm via apt" ;;
	dnf | yum) sudo "$pkg_manager" install -y npm 2>/dev/null || print_warning "Failed to install npm via $pkg_manager" ;;
	brew) brew install npm 2>/dev/null || print_warning "Failed to install npm via brew" ;;
	*) print_warning "Cannot auto-install npm — install manually" ;;
	esac
	return 0
}

setup_nodejs() {
	# Check if Node.js is already installed
	if command -v node >/dev/null 2>&1; then
		local node_version
		node_version=$(node --version 2>/dev/null || echo "unknown")
		print_success "Node.js already installed: $node_version"
		_ensure_npm_installed
		return 0
	fi

	print_info "Node.js is required for OpenCode, MCP servers, and many tools"

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	local install_node
	case "$pkg_manager" in
	brew)
		setup_prompt install_node "Install Node.js via Homebrew? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Node.js" brew install node; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apt)
		setup_prompt install_node "Install Node.js via apt? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			_install_nodejs_apt
		fi
		;;
	dnf | yum)
		setup_prompt install_node "Install Node.js via $pkg_manager? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo "$pkg_manager" install -y nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	pacman)
		setup_prompt install_node "Install Node.js via pacman? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo pacman -S --noconfirm nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apk)
		setup_prompt install_node "Install Node.js via apk? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo apk add nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	*)
		print_warning "No supported package manager found for Node.js installation"
		echo "  Install manually: https://nodejs.org/"
		;;
	esac

	return 0
}

# Bound OpenCode setup probes/installers so non-interactive setup cannot hang
# indefinitely when an opencode shim or package manager blocks.
_setup_opencode_timeout_cmd() {
	local timeout_seconds="$1"
	shift

	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=5
	[[ "$timeout_seconds" -gt 0 ]] || timeout_seconds=5

	local command_name="${1:-}"
	if [[ -n "$command_name" ]] && ! declare -F "$command_name" >/dev/null 2>&1; then
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

_setup_opencode_homebrew_owner_action() {
	local bin="${1:-}"
	local brew_bin=""
	local brew_prefix=""
	local bin_real=""
	local prefix_real=""

	[[ -n "$bin" ]] || return 1
	command -v brew >/dev/null 2>&1 || return 1
	brew_bin=$(command -v brew 2>/dev/null || printf '')
	[[ -n "$brew_bin" ]] || return 1
	brew_prefix=$(brew --prefix opencode 2>/dev/null || printf '')
	[[ -n "$brew_prefix" ]] || brew_prefix=$(brew --prefix 2>/dev/null || printf '')
	[[ -n "$brew_prefix" ]] || return 1

	bin_real=$(cd "$(dirname "$bin")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$bin")") || return 1
	prefix_real=$(cd "$brew_prefix" 2>/dev/null && pwd -P) || return 1

	case "$bin_real" in
		"$prefix_real"/*)
			printf '%s\n' "brew reinstall opencode"
			return 0
			;;
	esac

	return 1
}

_setup_opencode_print_manual_install_hint() {
	local installer="${1:-}"
	local install_pkg="${2:-opencode-ai@latest}"
	local current_bin="${3:-}"
	local brew_action=""
	local manual_cmd=""

	if brew_action=$(_setup_opencode_homebrew_owner_action "$current_bin" 2>/dev/null); then
		print_info "OpenCode appears to be managed by Homebrew; try manually: $brew_action"
		return 0
	fi

	case "$installer" in
		bun) manual_cmd="bun install -g $install_pkg" ;;
		npm | *) manual_cmd="npm install -g $install_pkg" ;;
	esac
	print_info "Try manually: $manual_cmd"
	return 0
}

_setup_opencode_node_path_for_binary() {
	local bin="$1"
	local bin_dir=""
	local path_value=""

	bin_dir=$(dirname "$bin" 2>/dev/null || printf '')
	if [[ -n "$bin_dir" && "$bin_dir" == /* ]]; then
		path_value="${bin_dir}:"
	fi
	path_value="${path_value}${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts:/usr/local/bin:/usr/bin:/bin"
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

_setup_ensure_opencode_stable_shim() {
	local real_bin="${1:-}"
	local shim_dir="${HOME}/.local/bin"
	local shim_path="${shim_dir}/opencode"
	local resolved_bin=""
	local wrapper_path=""
	local wrapper_dir=""
	local wrapper_path_value=""

	[[ -n "$real_bin" ]] || return 1
	resolved_bin=$(command -v "$real_bin" 2>/dev/null || printf '%s' "$real_bin")
	_setup_validate_opencode_binary "$resolved_bin" || return 1
	if [[ "$resolved_bin" == "$shim_path" ]] && ! grep -Fq '# aidevops:terminal-title-owner' "$shim_path" 2>/dev/null; then
		resolved_bin=$(_setup_find_valid_opencode_binary) || return 1
	fi
	if _setup_opencode_binary_is_ephemeral "$resolved_bin" && \
		! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
		return 1
	fi

	# Valid older shims still need regeneration so OpenCode's native writer cannot
	# race the aidevops status-decorated terminal title.
	if [[ -x "$shim_path" ]] && _setup_validate_opencode_binary "$shim_path" && \
		grep -Fq '# aidevops:terminal-title-owner' "$shim_path" 2>/dev/null; then
		printf '%s\n' "$shim_path"
		return 0
	fi

	mkdir -p "$shim_dir" 2>/dev/null || return 1
	wrapper_dir=$(cd "$(dirname "$resolved_bin")" 2>/dev/null && pwd -P) || return 1
	wrapper_path="${wrapper_dir}/$(basename "$resolved_bin")"
	if _setup_opencode_binary_is_ephemeral "$wrapper_path" && \
		! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
		return 1
	fi
	wrapper_path_value=$(_setup_opencode_node_path_for_binary "$wrapper_path")

	cat >"$shim_path" <<EOF
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
	chmod +x "$shim_path" 2>/dev/null || return 1

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

	for candidate in \
		"$preferred_bin" \
		/opt/homebrew/bin/opencode \
		/usr/local/bin/opencode \
		/home/linuxbrew/.linuxbrew/bin/opencode \
		"${HOME}/.npm-global/bin/opencode" \
		"${HOME}/.bun/bin/opencode" \
		opencode; do
		[[ -n "$candidate" ]] || continue
		[[ "$candidate" == "$shim_path" ]] && continue
		candidate_path=$(command -v "$candidate" 2>/dev/null || printf '%s' "$candidate")
		[[ "$candidate_path" == "$shim_path" ]] && continue
		if _setup_opencode_binary_is_ephemeral "$candidate_path" && \
			! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
			continue
		fi
		if _setup_validate_opencode_binary "$candidate_path"; then
			printf '%s\n' "$candidate_path"
			return 0
		fi
	done

	return 1
}

# t2891: Validate that an opencode binary is real anomalyco/opencode.
# Mirrors the t2887 runtime canary validator (headless-runtime-lib.sh) and
# the t2888 setup module validator (.agents/scripts/setup/_services.sh).
# Inlined to keep tool-install.sh self-contained — sourced from setup.sh
# during early bootstrap before headless-runtime-lib.sh is on the path.
# Returns: 0=valid, 1=wrong package (e.g. claude CLI), 2=missing/unrunnable.
_setup_validate_opencode_binary() {
	local bin="${1:-}"
	[[ -n "$bin" ]] || return 2
	command -v "$bin" >/dev/null 2>&1 || return 2

	local v
	v=$(_setup_opencode_version_output "$bin" 2>/dev/null || printf '')
	[[ -n "$v" ]] || return 2
	local help_output
	help_output=$(_setup_opencode_help_output "$bin" 2>/dev/null || printf '')
	[[ -n "$help_output" ]] || return 2

	# Anthropic claude CLI signature — highest-confidence rejection.
	[[ "$v" == *"(Claude Code)"* ]] && return 1

	# opencode is at 1.x; any 2.x+ is wrong (claude CLI is 2.1.x).
	[[ "$v" =~ ^([2-9]|[1-9][[:digit:]]+)\. ]] && return 1

	# Sanity: must look like a semver (X.Y.Z).
	[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1

	# Positive OpenCode identity check. Qwen and other CLIs can return a
	# semver-compatible --version (for example 0.2.1), so version shape alone is
	# not enough. Require OpenCode's command surface before writing/accepting the
	# stable ~/.local/bin/opencode shim used by Tabby and workers.
	_setup_opencode_help_identifies_opencode "$help_output" || return 1

	return 0
}

# t2891: detect-and-heal when 'opencode' bin name is owned by a wrong
# package (canonical case: @anthropic-ai/claude-code shadowing
# anomalyco/opencode after a npm install collision). Auto-installs
# without prompt because:
#   1) it's healing a broken state, not first-time setup
#   2) non-interactive runners (the canonical victim) would auto-Y anyway
# Idempotent. Fail-open if no installer available.
_setup_opencode_force_heal() {
	local install_pkg="$1" wrong_bin="$2" wrong_v="$3"
	print_warning "OpenCode binary at '$wrong_bin' is the wrong package ('$wrong_v')"
	print_info "Forcing reinstall of $install_pkg to heal bin collision (t2891)..."

	local installer=""
	if command -v npm >/dev/null 2>&1; then
		installer="npm"
	elif command -v bun >/dev/null 2>&1; then
		installer="bun"
	else
		print_warning "Neither bun nor npm found — cannot heal OpenCode binary"
		print_info "Install Node.js or Bun first, then re-run 'aidevops update'"
		return 0
	fi

	local install_timeout="${AIDEVOPS_OPENCODE_INSTALL_TIMEOUT:-180}"
	# npm_global_install intentionally uses npm first for opencode-ai when npm is
	# available, falling back to bun only for bun-only systems.
	if run_with_spinner "Reinstalling OpenCode via $installer (heal)" _setup_opencode_timeout_cmd "$install_timeout" npm_global_install "$install_pkg"; then
		print_success "OpenCode reinstalled via $installer"
	else
		print_warning "Heal install failed via $installer"
		_setup_opencode_print_manual_install_hint "$installer" "$install_pkg" "$wrong_bin"
	fi

	# Re-validate post-heal.
	local new_bin
	new_bin=$(_setup_find_valid_opencode_binary "$(command -v opencode 2>/dev/null || echo "")" 2>/dev/null || echo "")
	if [[ -n "$new_bin" ]] && _setup_validate_opencode_binary "$new_bin"; then
		local new_v
		new_v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$new_bin" 2>/dev/null || printf 'unknown')")
		local stable_bin
		stable_bin=$(_setup_ensure_opencode_stable_shim "$new_bin" 2>/dev/null || printf '%s' "$new_bin")
		print_success "OpenCode CLI: $new_bin ($new_v)"
		mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
		printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
	else
		local v_after
		v_after="<missing>"
		if [[ -n "$new_bin" ]] && [[ -x "$new_bin" ]]; then
			v_after=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$new_bin" 2>/dev/null || printf 'unknown')")
		fi
		print_warning "Post-heal validation still failing: '${new_bin:-opencode}' returns '$v_after'"
		print_info "Check PATH: 'which -a opencode' — npm/bun global bin dir must come first"
	fi
	return 0
}

setup_opencode_cli() {
	print_info "Setting up OpenCode CLI..."

	# The compatibility pin is scoped to Linux headless dispatch. General setup
	# tracks upstream; the headless launch guard restores its approved version.
	local install_pkg="opencode-ai@latest"

	# t2891: validate the resolved binary is anomalyco/opencode, not a
	# wrong package (claude CLI etc) that took the 'opencode' bin name.
	# Without this, alex-solovyev's runner — where command -v opencode
	# resolves to @anthropic-ai/claude-code — silently passes through
	# this function, leaving t2887's runtime canary to throttle the spam
	# without ever healing the binary.
	local current_bin
	current_bin=$(command -v opencode 2>/dev/null || echo "")
	local validate_rc=0
	_setup_validate_opencode_binary "$current_bin" || validate_rc=$?

	# Already valid → record + early return.
	if [[ $validate_rc -eq 0 ]]; then
		local oc_version
		oc_version=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf 'unknown')")
		local stable_bin
		stable_bin=$(_setup_ensure_opencode_stable_shim "$current_bin" 2>/dev/null || printf '%s' "$current_bin")
		print_success "OpenCode already installed: $oc_version"
		mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
		printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
		return 0
	fi

	# Wrong package → auto-heal (no prompt).
	if [[ $validate_rc -eq 1 ]]; then
		local valid_bin
		valid_bin=$(_setup_find_valid_opencode_binary "$current_bin" 2>/dev/null || echo "")
		if [[ -n "$valid_bin" ]]; then
			local valid_version
			valid_version=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$valid_bin" 2>/dev/null || printf 'unknown')")
			local stable_bin
			stable_bin=$(_setup_ensure_opencode_stable_shim "$valid_bin" 2>/dev/null || printf '%s' "$valid_bin")
			print_success "OpenCode CLI: $valid_bin ($valid_version)"
			mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
			printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
			return 0
		fi
		local wrong_v
		wrong_v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf '<unknown>')")
		_setup_opencode_force_heal "$install_pkg" "$current_bin" "$wrong_v"
		return 0
	fi

	# Missing → first-time install path (preserves prompt for interactive UX).
	local installer=""
	if command -v npm >/dev/null 2>&1; then
		installer="npm"
	elif command -v bun >/dev/null 2>&1; then
		installer="bun"
	else
		print_warning "Neither bun nor npm found - cannot install OpenCode"
		print_info "Install Node.js or Bun first, then re-run setup"
		return 0
	fi

	print_info "OpenCode is the AI coding tool that aidevops is built for"
	echo "  It provides an AI-powered terminal interface for development tasks."
	echo ""

	local install_oc
	setup_prompt install_oc "Install OpenCode via $installer? [Y/n]: " "Y"
	if [[ "$install_oc" =~ ^[Yy]?$ ]]; then
		local install_timeout="${AIDEVOPS_OPENCODE_INSTALL_TIMEOUT:-180}"
		if run_with_spinner "Installing OpenCode" _setup_opencode_timeout_cmd "$install_timeout" npm_global_install "$install_pkg"; then
			print_success "OpenCode installed"

			# Persist resolved path on first-time success too (t2891).
			local new_bin
			new_bin=$(_setup_find_valid_opencode_binary "$(command -v opencode 2>/dev/null || echo "")" 2>/dev/null || echo "")
			if [[ -n "$new_bin" ]] && _setup_validate_opencode_binary "$new_bin"; then
				local stable_bin
				stable_bin=$(_setup_ensure_opencode_stable_shim "$new_bin" 2>/dev/null || printf '%s' "$new_bin")
				mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
				printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
			fi

			# Offer authentication
			echo ""
			print_info "OpenCode needs authentication to use AI models."
			print_info "Run 'opencode auth login' to authenticate."
			echo ""
		else
			print_warning "OpenCode installation failed"
			_setup_opencode_print_manual_install_hint "$installer" "$install_pkg" "$current_bin"
		fi
	else
		print_info "Skipped OpenCode installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

setup_opencode_desktop_launcher() {
	if [[ "$(uname -s)" != "Darwin" ]]; then
		return 0
	fi

	local launcher_script="${HOME}/.aidevops/agents/scripts/opencode-launcher-helper.sh"
	if ! [[ -x "$launcher_script" ]]; then
		return 0
	fi

	local install_rc=0
	bash "$launcher_script" desktop install-shortcut >/dev/null 2>&1 || install_rc=$?
	case "$install_rc" in
	0)
		print_success "OpenCode AIDevOps Desktop app installed in ~/Applications"
		;;
	3)
		# OpenCode Desktop is optional; do not warn on systems that only use the CLI.
		return 0
		;;
	*)
		print_warning "Failed to install OpenCode AIDevOps Desktop app wrapper"
		;;
	esac
	return 0
}

setup_codex_cli() {
	print_info "Setting up OpenAI Codex CLI..."

	# Check if Codex is already installed
	if command -v codex >/dev/null 2>&1; then
		local codex_version
		codex_version=$(codex --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Codex already installed: $codex_version"
		# Fix broken MCP_DOCKER if present
		_fix_codex_docker_mcp
		return 0
	fi

	# Need either bun or npm to install
	local installer=""
	local install_pkg="@openai/codex@latest"

	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found - cannot install Codex"
		print_info "Install Node.js first, then re-run setup"
		return 0
	fi

	print_info "Codex is OpenAI's AI coding CLI (terminal-based, agentic)"
	echo "  It provides an AI-powered terminal interface using OpenAI models."
	echo ""

	local install_codex
	setup_prompt install_codex "Install Codex via $installer? [Y/n]: " "Y"
	if [[ "$install_codex" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Codex" npm_global_install "$install_pkg"; then
			print_success "Codex installed"
			echo ""
			print_info "Codex needs OpenAI authentication."
			print_info "Run 'codex' and follow the auth prompts."
			echo ""
			# Fix broken MCP_DOCKER if Codex created a default config
			_fix_codex_docker_mcp
		else
			print_warning "Codex installation failed"
			print_info "Try manually: npm install -g $install_pkg"
		fi
	else
		print_info "Skipped Codex installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

# P0 fix: Remove broken MCP_DOCKER from Codex config.toml
# Docker Desktop 4.40+ with MCP Toolkit extension is required for `docker mcp`.
# OrbStack, Colima, Rancher Desktop do not support it.
_fix_codex_docker_mcp() {
	local config="$HOME/.codex/config.toml"
	[[ -f "$config" ]] || return 0

	# Check if MCP_DOCKER section exists
	if ! grep -q '^\[mcp_servers\.MCP_DOCKER\]' "$config" 2>/dev/null; then
		return 0
	fi

	# Check if `docker mcp` subcommand is actually available
	if docker mcp --help >/dev/null 2>&1; then
		return 0
	fi

	# Comment out the MCP_DOCKER section (from header to next section or EOF)
	# Use sed to comment out lines from [mcp_servers.MCP_DOCKER] to the next
	# section header or end of file. Portable sed (no -i on macOS without ext).
	local tmp_config
	tmp_config=$(mktemp)
	local in_mcp_docker=false
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "[mcp_servers.MCP_DOCKER]" ]]; then
			in_mcp_docker=true
			printf '# %s  # Disabled by aidevops: docker mcp not available\n' "$line" >>"$tmp_config"
			continue
		fi
		# If we hit another section header, stop commenting
		if [[ "$in_mcp_docker" == "true" ]] && [[ "$line" == "["* ]]; then
			in_mcp_docker=false
		fi
		if [[ "$in_mcp_docker" == "true" ]]; then
			printf '# %s\n' "$line" >>"$tmp_config"
		else
			printf '%s\n' "$line" >>"$tmp_config"
		fi
	done <"$config"
	mv "$tmp_config" "$config"
	print_info "Disabled MCP_DOCKER in Codex config (docker mcp not available on this system)"
	return 0
}

setup_droid_cli() {
	print_info "Setting up Factory.AI Droid CLI..."

	# Check if Droid is already installed
	if command -v droid >/dev/null 2>&1; then
		local droid_version
		droid_version=$(droid --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Droid already installed: $droid_version"
		return 0
	fi

	# Droid uses its own installer — not available via npm/brew
	print_info "Droid (Factory.AI) is an AI coding agent CLI"
	echo "  It provides autonomous coding capabilities with Factory.AI models."
	echo ""

	local install_droid
	setup_prompt install_droid "Install Droid CLI? [Y/n]: " "Y"
	if [[ "$install_droid" =~ ^[Yy]?$ ]]; then
		print_info "Installing Droid CLI..."
		if command -v curl >/dev/null 2>&1; then
			if curl -fsSL https://app.factory.ai/install.sh | bash 2>/dev/null; then
				print_success "Droid installed"
				echo ""
				print_info "Run 'droid auth login' to authenticate with Factory.AI."
				echo ""
			else
				print_warning "Droid installation failed"
				print_info "Install manually from: https://docs.factory.ai/cli/installation"
			fi
		else
			print_warning "curl not found - cannot install Droid"
			print_info "Install manually from: https://docs.factory.ai/cli/installation"
		fi
	else
		print_info "Skipped Droid installation"
		print_info "Install later: curl -fsSL https://app.factory.ai/install.sh | bash"
	fi

	return 0
}

setup_google_workspace_cli() {
	print_info "Setting up Google Workspace CLI (gws)..."

	# Check if gws is already installed
	if command -v gws >/dev/null 2>&1; then
		local gws_version
		gws_version=$(gws --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Google Workspace CLI already installed: $gws_version"
		return 0
	fi

	# Need either bun or npm to install
	local installer=""
	local install_pkg="@googleworkspace/cli@latest"

	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found - cannot install gws"
		print_info "Install Node.js first, then re-run setup"
		return 0
	fi

	print_info "Google Workspace CLI provides Gmail, Calendar, Drive, and all Workspace APIs"
	echo "  Used by Email, Business, and Accounts agents for Google Workspace integration."
	echo ""

	local install_gws
	setup_prompt install_gws "Install Google Workspace CLI via $installer? [Y/n]: " "Y"
	if [[ "$install_gws" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Google Workspace CLI" npm_global_install "$install_pkg"; then
			print_success "Google Workspace CLI installed"

			echo ""
			print_info "Authentication required before use."
			print_info "Run 'gws auth setup' to authenticate with your Google account."
			print_info "For headless use: set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"
			echo ""
		else
			print_warning "Google Workspace CLI installation failed"
			print_info "Try manually: sudo npm install -g $install_pkg"
		fi
	else
		print_info "Skipped Google Workspace CLI installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

setup_orbstack_vm() {
	# Only available on macOS
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	# Check if OrbStack is already installed
	if [[ -d "/Applications/OrbStack.app" ]] || command -v orb >/dev/null 2>&1; then
		print_success "OrbStack already installed"
		return 0
	fi

	print_info "OrbStack provides fast, lightweight Linux VMs on macOS"
	echo "  You can run aidevops in an isolated Linux environment."
	echo "  This is optional - aidevops works natively on macOS too."
	echo ""

	if ! command -v brew >/dev/null 2>&1; then
		print_info "OrbStack available at: https://orbstack.dev/"
		return 0
	fi

	setup_prompt install_orb "Install OrbStack? [y/N]: " "n"
	# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
	if [[ "$install_orb" =~ ^[Yy]$ ]]; then
		if run_with_spinner "Installing OrbStack" brew install --cask orbstack; then
			print_success "OrbStack installed"
			print_info "Create a VM: orb create ubuntu aidevops"
			print_info "Then install aidevops inside: orb run aidevops bash <(curl -fsSL https://aidevops.sh/install)"
		else
			print_warning "OrbStack installation failed"
			print_info "Download manually: https://orbstack.dev/"
		fi
	else
		print_info "Skipped OrbStack installation"
	fi

	return 0
}

setup_ai_orchestration() {
	print_info "Setting up AI orchestration frameworks..."

	# Check Python — uses check_python_version from _common.sh to avoid
	# duplicating find_python3 → parse → compare → offer_python_brew_install logic.
	if ! check_python_version "" "AI orchestration" >/dev/null; then
		return 0
	fi

	# Create orchestration directory
	mkdir -p "$HOME/.aidevops/orchestration"

	# Info about available frameworks
	print_info "AI Orchestration Frameworks available:"
	echo "  - Langflow: Visual flow builder (localhost:7860)"
	echo "  - CrewAI: Multi-agent teams (localhost:8501)"
	echo "  - AutoGen: Microsoft agentic AI (localhost:8081)"
	echo ""
	print_info "Setup individual frameworks with:"
	echo "  bash .agents/scripts/langflow-helper.sh setup"
	echo "  bash .agents/scripts/crewai-helper.sh setup"
	echo "  bash .agents/scripts/autogen-helper.sh setup"
	echo ""
	print_info "See .agents/tools/ai-orchestration/overview.md for comparison"

	return 0
}

# Prompt to install Ollama when the knowledge plane is enabled.
# Called from _setup_run_interactive when the user opts in.
# Installs Ollama and pulls the recommended fast model (llama3.1:8b).
# The reasoning model (llama3.1:70b) and embed model are suggested but not
# pulled automatically due to their large size (39 GB and 274 MB respectively).
setup_ollama_for_knowledge() {
	print_info "Ollama — local LLM for knowledge plane (pii/sensitive/privileged tiers)"
	print_info "Required for: tier:pii, tier:sensitive, tier:privileged routing."

	# Check if Ollama is already installed
	if command -v ollama >/dev/null 2>&1; then
		local version
		version=$(ollama --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1) || version="unknown"
		print_success "Ollama already installed (version: ${version})"
	else
		print_info "Ollama not found."
		if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
			print_info "Installing Ollama via Homebrew..."
			if brew install ollama 2>/dev/null; then
				print_success "Ollama installed via Homebrew"
			else
				print_warning "Homebrew install failed. Download from https://ollama.com"
				return 0
			fi
		else
			print_info "Install Ollama manually from https://ollama.com"
			print_info "Then re-run this setup to pull the recommended models."
			return 0
		fi
	fi

	# Deploy the bundle config template
	local bundle_dir="$HOME/.aidevops/configs"
	local bundle_dest="${bundle_dir}/ollama-bundle.json"
	local bundle_src
	bundle_src="${INSTALL_DIR}/.agents/templates/ollama-bundle.json"
	if [[ ! -f "$bundle_src" ]]; then
		bundle_src="$HOME/.aidevops/agents/templates/ollama-bundle.json"
	fi
	if [[ -f "$bundle_src" ]] && [[ ! -f "$bundle_dest" ]]; then
		mkdir -p "$bundle_dir"
		cp "$bundle_src" "$bundle_dest"
		print_success "Ollama bundle config deployed: ${bundle_dest}"
	fi

	# Start Ollama service if not running
	if ! curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
		print_info "Starting Ollama service..."
		ollama serve >/dev/null 2>&1 &
		local i=0
		while [[ $i -lt 10 ]]; do
			if curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
				break
			fi
			sleep 1
			i=$((i + 1))
		done
	fi

	# Pull the fast model (minimum required for pii/sensitive tiers)
	print_info "Pulling minimum required model: llama3.1:8b (~4.9 GB)"
	print_info "This is required for tier:pii and tier:sensitive routing."
	if ollama pull llama3.1:8b 2>/dev/null; then
		print_success "llama3.1:8b pulled successfully"
	else
		print_warning "Failed to pull llama3.1:8b. Run manually: ollama pull llama3.1:8b"
	fi

	# Pull the embed model (small — pull automatically)
	print_info "Pulling embed model: nomic-embed-text (~274 MB)"
	if ollama pull nomic-embed-text 2>/dev/null; then
		print_success "nomic-embed-text pulled successfully"
	else
		print_warning "Failed to pull nomic-embed-text. Run manually: ollama pull nomic-embed-text"
	fi

	print_info ""
	print_info "Optional: pull the reasoning model for tier:privileged (~39 GB, requires 48+ GB RAM):"
	print_info "  ollama pull llama3.1:70b"
	print_info ""
	print_info "Verify: ollama-helper.sh health"

	return 0
}
