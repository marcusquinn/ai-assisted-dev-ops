#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Post-setup functions: auto-update enablement, final instructions, onboarding prompt.
# Part of aidevops setup.sh modularization (GH#5793)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Enable auto-update if not already enabled.
# Check both launchd (macOS) and cron (Linux) for existing installation.
# Respects config: aidevops config set updates.auto_update false
setup_auto_update() {
	local auto_update_script="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
	if ! [[ -x "$auto_update_script" ]] || ! is_feature_enabled auto_update 2>/dev/null; then
		return 0
	fi

	local _auto_update_installed=false
	if _scheduler_detect_installed \
		"Auto-update" \
		"com.aidevops.aidevops-auto-update" \
		"com.aidevops.auto-update" \
		"aidevops-auto-update" \
		"$auto_update_script" \
		"enable" \
		"aidevops auto-update enable" \
		"aidevops-auto-update"; then
		_auto_update_installed=true
	fi
	# t2898: ALWAYS run idempotent re-install + health-check after the
	# detection above, so every release self-heals broken installs (daemon
	# unloaded by an OS update, scrubbed by a cron cleanup, etc.). The
	# detection helper already handled the "freshly install if missing"
	# interactive prompt; this loop ensures that even when the detection
	# said "yes installed" the daemon is actually loaded right now and
	# running on schedule.
	if [[ "$_auto_update_installed" == "true" ]]; then
		# Idempotent: no-op when daemon already loaded; re-installs only on drift.
		bash "$auto_update_script" enable --idempotent >/dev/null 2>&1 || true
		# Verify it's actually healthy. Surface any degradation so the
		# operator sees it on every release deploy.
		local _hc_rc=0
		bash "$auto_update_script" health-check --quiet >/dev/null 2>&1 || _hc_rc=$?
		if [[ "$_hc_rc" -eq 0 ]]; then
			:
		elif [[ "$_hc_rc" -eq 1 ]]; then
			print_warning "Auto-update daemon installed but stalled — run: aidevops auto-update check"
		elif [[ "$_hc_rc" -eq 2 ]]; then
			print_warning "Auto-update daemon not loaded — run: aidevops auto-update enable"
		fi
	fi
	if [[ "$_auto_update_installed" == "false" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			# Non-interactive: enable silently
			bash "$auto_update_script" enable >/dev/null 2>&1 || true
			print_info "Auto-update enabled (every 10 min). Disable: aidevops auto-update disable"
			# On Linux systemd, advise about linger without running sudo automatically.
			if [[ "$(uname -s)" == "Linux" ]] && [[ "${USER:-}" != "root" ]] \
				&& command -v loginctl &>/dev/null; then
				local _linger_state
				_linger_state=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)
				if [[ "$_linger_state" != "yes" ]]; then
					echo "[INFO] Linux systemd: enable linger so auto-update runs when logged out:" >&2
					echo "[INFO]   sudo loginctl enable-linger $USER" >&2
				fi
			fi
		else
			echo ""
			echo "Auto-update keeps aidevops current by checking every 10 minutes."
			echo "Safe to run while AI sessions are active."
			echo ""
			local enable_auto=""
			setup_prompt enable_auto "Enable auto-update? [Y/n]: " "Y"
			if [[ "$enable_auto" =~ ^[Yy]?$ ]]; then
				bash "$auto_update_script" enable
				# On Linux systemd hosts, offer to enable linger so the timer survives logout.
				# Skip for root (irrelevant), WSL/container (loginctl may be absent or stub),
				# and when the backend didn't resolve to systemd.
				if [[ "$(uname -s)" == "Linux" ]] \
					&& [[ "${USER:-}" != "root" ]] \
					&& command -v loginctl &>/dev/null \
					&& systemctl --user is-enabled aidevops-auto-update.timer &>/dev/null 2>&1; then
					local _linger_state
					_linger_state=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)
					if [[ "$_linger_state" != "yes" ]]; then
						echo ""
						echo "Without linger, the auto-update timer stops when you log out."
						echo "On servers and headless hosts, linger is almost always required."
						local enable_linger=""
					setup_prompt enable_linger "Enable linger so auto-update runs when logged out? Requires sudo. [Y/n]: " "Y"
						if [[ "$enable_linger" =~ ^[Yy]?$ ]]; then
							sudo loginctl enable-linger "$USER"
							print_success "Linger enabled for $USER"
						else
							print_info "Skipped. Enable later: sudo loginctl enable-linger $USER"
						fi
					fi
				fi
			else
				print_info "Skipped. Enable later: aidevops auto-update enable"
			fi
		fi
	fi
	return 0
}

# Print final setup instructions and feature summary.
print_final_instructions() {
	echo ""
	echo "CLI Command:"
	echo "  aidevops init         - Initialize aidevops in a project"
	echo "  aidevops features     - List available features"
	echo "  aidevops status       - Check installation status"
	echo "  aidevops update       - Update to latest version"
	echo "  aidevops update-tools - Check for and update installed tools"
	echo "  aidevops uninstall    - Remove aidevops"
	echo ""
	echo "Deployed to:"
	echo "  ~/.aidevops/agents/     - Agent files (main agents, subagents, scripts)"
	echo "  ~/.aidevops/*-backups/  - Rollback backups (count/age/byte retention; newest protected)"
	echo ""
	echo "Next steps:"
	echo "1. Review config templates in configs/ (keep as placeholders — never store real credentials there)"
	echo "2. Setup Git CLI tools and authentication (shown during setup)"
	echo "3. Setup API keys: bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh setup"
	echo "4. Test access: bash ~/.aidevops/agents/scripts/servers-helper.sh list"
	echo "5. Enable orchestration: see runners.md 'Pulse Scheduler Setup' (autonomous task dispatch)"
	echo "6. Read documentation: ~/.aidevops/agents/AGENTS.md"
	echo ""
	echo "For development on aidevops framework itself:"
	echo "  See ~/Git/aidevops/AGENTS.md"
	echo ""
	echo "OpenCode Primary Agents (12 total, Tab to switch):"
	echo "• Plan+      - Enhanced planning with context tools (read-only)"
	echo "• Build+     - Enhanced build with context tools (full access)"
	echo "• Accounts, AI-DevOps, Content, Health, Legal, Marketing,"
	echo "  Research, Sales, SEO, WordPress"
	echo ""
	echo "Agent Skills (SKILL.md):"
	echo "• 21 SKILL.md files generated in ~/.aidevops/agents/"
	echo "• Skills include: wordpress, seo, aidevops, build-mcp, and more"
	echo ""
	echo "MCP Integrations (OpenCode):"
	echo "• Context7               - Real-time library documentation"
	echo "• GSC                    - Google Search Console (MCP + OAuth2)"
	echo "• Google Analytics       - Analytics data (shared GSC credentials)"
	echo ""
	echo "SEO Integrations (curl subagents - no MCP overhead):"
	echo "• DataForSEO             - Comprehensive SEO data APIs"
	echo "• Serper                 - Google Search API"
	echo "• Ahrefs                 - Backlink and keyword data"
	echo ""
	echo "DSPy & DSPyGround Integration:"
	echo "• ./.agents/scripts/dspy-helper.sh        - DSPy prompt optimization toolkit"
	echo "• ./.agents/scripts/dspyground-helper.sh  - DSPyGround playground interface"
	echo "• python-env/dspy-env/              - Python virtual environment for DSPy"
	echo "• data/dspy/                        - DSPy projects and datasets"
	echo "• data/dspyground/                  - DSPyGround projects and configurations"
	echo ""
	echo "Task Management:"
	echo "• Beads CLI (bd)                    - Task graph visualization"
	echo "• beads-sync-helper.sh              - Sync TODO.md/PLANS.md with Beads"
	echo "• todo-ready.sh                     - Show tasks with no open blockers"
	echo "• Run: aidevops init beads          - Initialize Beads in a project"
	echo ""
	echo "Autonomous Orchestration:"
	echo "• Supervisor pulse         - Dispatches workers, merges PRs, evaluates results"
	echo "• Auto-pickup              - Workers claim #auto-dispatch tasks from TODO.md"
	echo "• Cross-repo visibility    - Manages tasks across all repos in repos.json"
	echo "• Strategic review (opus)  - 4-hourly queue health, root cause analysis"
	echo "• Model routing            - Cost-aware: local>haiku>flash>sonnet>pro>opus"
	echo "• Budget tracking          - Per-provider spend limits, subscription-aware"
	echo "• Session miner            - Extracts learning from past sessions"
	echo "• Circuit breaker          - Pauses dispatch on consecutive failures"
	echo ""
	echo "  Supervisor pulse (autonomous orchestration) requires explicit consent."
	echo "  Enable: aidevops config set orchestration.supervisor_pulse true && ./setup.sh"
	echo ""
	echo "  Run /onboarding in your AI assistant to configure services interactively."
	echo ""
	echo "Security reminders:"
	echo "- Never commit configuration files with real credentials"
	echo "- Use strong passwords and enable MFA on all accounts"
	echo "- Regularly rotate API tokens and SSH keys"
	echo ""
	echo "Happy server managing! 🚀"
	echo ""
	return 0
}

# Setup Tabby terminal profiles from repos.json and detected workspaces.
# Creates a profile per registered repo plus a Buzz profile when ~/.buzz exists,
# with colour-matched themes and direct split-arg OpenCode launch settings.
# Skipped if Tabby is not installed.
setup_tabby() {
	local tabby_helper="$HOME/.aidevops/agents/scripts/tabby-helper.sh"
	local tabby_config

	# Skip if helper not deployed yet
	if [[ ! -x "$tabby_helper" ]]; then
		return 0
	fi

	# Keep setup and the standalone helper on one config-resolution contract.
	tabby_config="$(bash "$tabby_helper" config-path)"

	# Skip if Tabby not installed
	if [[ ! -f "$tabby_config" ]]; then
		return 0
	fi

	print_info "Tabby terminal detected"

	# Ensure default local profile uses /bin/zsh (macOS).
	# After macOS updates, Tabby can fall back to bash when this is unset.
	bash "$tabby_helper" fix-shell || true

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		# Non-interactive: sync silently, warn on failure
		if ! bash "$tabby_helper" sync; then
			print_warning "Tabby profile sync failed — run manually: aidevops tabby sync"
		fi
		return 0
	fi

	# Show status and offer to sync
	echo ""
	bash "$tabby_helper" status || true
	echo ""
	local sync_tabby=""
	setup_prompt sync_tabby "Sync Tabby profiles and detected workspaces? [Y/n]: " "Y"
	if [[ "$sync_tabby" =~ ^[Yy]?$ ]]; then
		bash "$tabby_helper" sync
	else
		print_info "Skipped. Run later: aidevops tabby sync"
	fi

	return 0
}

# Offer to launch onboarding for new users (only if not running inside an AI
# runtime session and not non-interactive). (t1665.5 — registry-driven)
# Respects config: aidevops config set ui.onboarding_prompt false
setup_onboarding_prompt() {
	# Skip if non-interactive or already inside a runtime session
	[[ "$NON_INTERACTIVE" == "true" ]] && return 0
	[[ -n "${OPENCODE_SESSION:-}" || -n "${CLAUDE_SESSION:-}" ]] && return 0
	is_feature_enabled onboarding_prompt 2>/dev/null || return 0

	# Find first available headless runtime for onboarding dispatch
	local _onb_bin="" _onb_name=""
	if type rt_list_headless &>/dev/null; then
		local _onb_rt_id
		while IFS= read -r _onb_rt_id; do
			_onb_bin=$(rt_binary "$_onb_rt_id") || continue
			if [[ -n "$_onb_bin" ]] && command -v "$_onb_bin" &>/dev/null; then
				_onb_name=$(rt_display_name "$_onb_rt_id") || _onb_name="$_onb_bin"
				break
			fi
			_onb_bin=""
		done < <(rt_list_headless)
	fi
	# Fallback
	if [[ -z "$_onb_bin" ]] && command -v opencode &>/dev/null; then
		_onb_bin="opencode"
		_onb_name="OpenCode"
	fi
	[[ -z "$_onb_bin" ]] && return 0

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""
	echo "Ready to configure your services?"
	echo ""
	echo "Launch ${_onb_name} with the onboarding wizard to:"
	echo "  - See which services are already configured"
	echo "  - Get personalized recommendations based on your work"
	echo "  - Set up API keys and credentials interactively"
	echo ""
	local launch_onboarding=""
	setup_prompt launch_onboarding "Launch ${_onb_name} with /onboarding now? [Y/n]: " "Y"
	if [[ "$launch_onboarding" =~ ^[Yy]?$ ]]; then
		echo ""
		echo "Starting ${_onb_name} with onboarding wizard..."
		"$_onb_bin" --prompt "/onboarding"
	else
		echo ""
		echo "You can run /onboarding anytime in ${_onb_name} to configure services."
	fi
	return 0
}
