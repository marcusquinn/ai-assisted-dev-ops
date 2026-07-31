#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#21063 regression tests — follow-up fixes for the t2906 atomic plist install.
# Covers the four priorities addressed by this PR:
#   (a) mv exit status checked — mv-failure path returns 1 and cleans up tmp file
#   (b) legacy plist cleanup restored and idempotent
#   (c) empty content rejected before write
#
# Usage: bash .agents/scripts/tests/test-launchd-install-if-changed.sh
# Platform: macOS only (launchd is macOS-specific; test skips on Linux)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SCHEDULERS_SH="$REPO_ROOT/.agents/scripts/setup/modules/schedulers.sh"
SCHEDULERS_PLATFORM_SH="$REPO_ROOT/.agents/scripts/setup/modules/schedulers-platform.sh"
SHARED_CONSTANTS_SH="$REPO_ROOT/.agents/scripts/shared-constants.sh"
AUTO_UPDATE_SH="$REPO_ROOT/.agents/scripts/auto-update-helper.sh"
AUTO_UPDATE_SCHEDULER_SH="$REPO_ROOT/.agents/scripts/auto-update-helper-scheduler.sh"
REPO_SYNC_SH="$REPO_ROOT/.agents/scripts/repo-sync-helper.sh"
REPO_HEALTH_SH="$REPO_ROOT/.agents/scripts/repo-aidevops-health-helper.sh"

# shellcheck source=../shared-constants.sh
source "$SHARED_CONSTANTS_SH"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Inline _launchd_install_if_changed from setup.sh for isolated testing.
# This is a COPY of the function as fixed by GH#21063; if setup.sh changes,
# update this copy and add/adjust tests accordingly.
# We cannot source setup.sh directly because it runs `main "$@"` at the
# bottom and sources many .agents/scripts/setup/modules at the top level.
# ---------------------------------------------------------------------------

_define_launchd_install_stubs() {
	# Minimal stubs required by _launchd_install_if_changed
	print_warning() { echo "[WARN] $*" >&2; return 0; }
	print_info()    { return 0; }

	_launchd_has_agent() {
		# Default stub: agent not loaded
		return 1
	}

	# launchctl stub — no-op unless overridden by individual tests
	launchctl() { return 0; }
	return 0
}

_define_launchd_state_helpers() {
	_launchd_agent_state() {
		local label="$1"
		local state=""
		state=$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | awk -F'= ' '/state =/ { print $2; exit }' || true)
		printf '%s\n' "$state"
		return 0
	}

	_launchd_agent_pid() {
		local label="$1"
		local pid=""
		pid=$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | awk -F'= ' '/pid =/ { print $2; exit }' || true)
		printf '%s\n' "$pid"
		return 0
	}

	_launchd_process_args() {
		local pid="$1"
		if [[ -z "$pid" ]]; then
			return 0
		fi
		ps -p "$pid" -o args= 2>/dev/null || true
		return 0
	}

	_launchd_bootout_bootstrap() {
		local label="$1"
		local plist_path="$2"
		local domain
		domain="gui/$(id -u)"

		launchctl bootout "${domain}/${label}" 2>/dev/null || true
		launchctl bootstrap "$domain" "$plist_path" 2>/dev/null
		return $?
	}
	return 0
}

_define_launchd_xpcproxy_recovery() {
	_launchd_recover_xpcproxy_if_stuck() {
		local label="$1"
		local plist_path="$2"
		local state pid process_args
		state=$(_launchd_agent_state "$label")
		if [[ "$state" != "xpcproxy" ]]; then
			return 0
		fi
		pid=$(_launchd_agent_pid "$label")
		process_args=$(_launchd_process_args "$pid")
		if [[ -n "$process_args" && "$process_args" != *xpcproxy* ]]; then
			print_info "LaunchAgent $label reports xpcproxy but pid $pid is running: $process_args"
			return 0
		fi

		print_info "LaunchAgent $label reports xpcproxy; reloading with bootout/bootstrap"
		if ! _launchd_bootout_bootstrap "$label" "$plist_path"; then
			return 1
		fi
		local domain
		domain="gui/$(id -u)"
		launchctl kickstart -k "${domain}/${label}" 2>/dev/null || true

		local attempts interval attempt
		attempts="${AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_ATTEMPTS:-5}"
		interval="${AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS:-1}"
		[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=5
		[[ "$interval" =~ ^[0-9]+$ ]] || interval=1
		[[ "$attempts" -gt 0 ]] || attempts=1
		attempt=0
		while [[ "$attempt" -lt "$attempts" ]]; do
			state=$(_launchd_agent_state "$label")
			if [[ "$state" != "xpcproxy" ]]; then
				return 0
			fi
			pid=$(_launchd_agent_pid "$label")
			process_args=$(_launchd_process_args "$pid")
			if [[ -n "$process_args" && "$process_args" != *xpcproxy* ]]; then
				print_info "LaunchAgent $label reports xpcproxy after recovery but pid $pid is running: $process_args"
				return 0
			fi
			attempt=$((attempt + 1))
			if [[ "$attempt" -lt "$attempts" && "$interval" -gt 0 ]]; then
				sleep "$interval"
			fi
		done

		print_warning "LaunchAgent $label still stuck in xpcproxy after recovery (pid=${pid:-none}, args=${process_args:-none})"
		return 1
	}
	return 0
}

_define_launchd_loader_helpers() {
	_launchd_load_agent() {
		local label="$1"
		local plist_path="$2"

		if launchctl load "$plist_path" 2>/dev/null; then
			_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path" || return 1
			return 0
		fi

		if _launchd_bootout_bootstrap "$label" "$plist_path"; then
			_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path" || return 1
			return 0
		fi
		return 1
	}

	_launchd_kickstart_and_recover() {
		local label="$1"
		local plist_path="$2"
		local domain
		domain="gui/$(id -u)"

		launchctl kickstart -k "${domain}/${label}" 2>/dev/null || return 1
		_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path"
		return $?
	}
	return 0
}

_define_launchd_installer_helper() {
	_launchd_install_if_changed() {
		local label="$1"
		local plist_path="$2"
		local new_content="$3"

		if [[ -f "$plist_path" ]]; then
			local existing_content
			existing_content=$(cat "$plist_path")
			if [[ "$existing_content" == "$new_content" ]]; then
				if ! _launchd_has_agent "$label"; then
					_launchd_load_agent "$label" "$plist_path" || return 1
				else
					_launchd_recover_xpcproxy_if_stuck "$label" "$plist_path" || return 1
				fi
				return 0
			fi
			if _launchd_has_agent "$label"; then
				launchctl unload "$plist_path" 2>/dev/null || true
			fi
		fi

		# Atomic write: build at sibling tmp path, then rename into place.
		local tmp_plist
		tmp_plist=$(mktemp "${plist_path}.XXXXXX") || return 1
		# Guard: refuse to write empty content
		if [[ -z "$new_content" ]]; then
			rm -f "$tmp_plist"
			return 1
		fi
		if ! printf '%s\n' "$new_content" >"$tmp_plist"; then
			rm -f "$tmp_plist"
			return 1
		fi
		if [[ ! -s "$tmp_plist" ]]; then
			rm -f "$tmp_plist"
			return 1
		fi
		if ! mv -f "$tmp_plist" "$plist_path"; then
			rm -f "$tmp_plist"
			return 1
		fi
		_launchd_load_agent "$label" "$plist_path" || return 1
		return 0
	}
	return 0
}

_define_launchd_install_if_changed() {
	_define_launchd_install_stubs
	# _launchd_install_if_changed — inline from setup.sh (GH#21063 fixes)
	_define_launchd_state_helpers
	_define_launchd_xpcproxy_recovery
	_define_launchd_loader_helpers
	_define_launchd_installer_helper
	return 0
}

# ---------------------------------------------------------------------------
# Load schedulers.sh functions (needed for legacy-cleanup test)
# ---------------------------------------------------------------------------

_load_schedulers_functions() {
	# Define stubs before sourcing so schedulers.sh function bodies find them
	print_info()              { return 0; }
	print_warning()           { echo "[WARN] $*" >&2; return 0; }
	print_error()             { echo "[ERROR] $*" >&2; return 0; }
	_log_plist_env_overrides() { return 0; }
	_read_pulse_interval_seconds() { echo 60; return 0; }
	# Stub _launchd_install_if_changed — schedulers.sh calls this but doesn't define it;
	# we want to isolate the legacy-cleanup logic without running the real install.
	_launchd_install_if_changed() { return 0; }
	_launchd_has_agent()           { return 1; }

	# shellcheck source=/dev/null
	source "$SCHEDULERS_SH" 2>/dev/null || {
		echo "SKIP: could not source $SCHEDULERS_SH (missing dependencies?)"
		exit 0
	}
	return 0
}

_load_schedulers_platform_functions() {
	print_info()              { return 0; }
	print_warning()           { echo "[WARN] $*" >&2; return 0; }
	print_error()             { echo "[ERROR] $*" >&2; return 0; }
	_resolve_log_dir()        { printf '%s\n' "$TEST_DIR/logs"; return 0; }
	_install_scheduler_linux() { return 0; }
	_uninstall_scheduler()    { return 0; }
	_resolve_modern_bash()    { printf '%s\n' "/bin/bash"; return 0; }
	_xml_escape() {
		local value="$1"
		value="${value//&/\&amp;}"
		value="${value//</\&lt;}"
		value="${value//>/\&gt;}"
		value="${value//\"/\&quot;}"
		value="${value//\'/\&apos;}"
		printf '%s' "$value"
		return 0
	}
	aidevops_launchd_sanitized_path() { printf '%s\n' "/usr/bin:/bin"; return 0; }
	_launchd_install_if_changed() { return 0; }
	_launchd_kickstart_and_recover() { return 1; }

	# shellcheck source=/dev/null
	source "$SCHEDULERS_PLATFORM_SH" 2>/dev/null || {
		echo "SKIP: could not source $SCHEDULERS_PLATFORM_SH (missing dependencies?)"
		exit 0
	}
	return 0
}

# ---------------------------------------------------------------------------
# (a) mv-failure path returns 1 and cleans up the tmp file (Priority 1 + 3)
# ---------------------------------------------------------------------------

test_mv_failure_returns_1() {
	local plist_dir="$TEST_DIR/la_mv"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"

	# Override mv to simulate failure
	mv() { return 1; }

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" || rc=$?

	unset -f mv

	if [[ "$rc" -eq 0 ]]; then
		print_result "mv_failure_returns_1" 1 "expected non-zero return when mv fails, got 0"
		return 0
	fi

	# No tmp files should remain after cleanup
	local tmp_count
	tmp_count=$(find "$plist_dir" -name "test.plist.*" 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$tmp_count" -ne 0 ]]; then
		print_result "mv_failure_returns_1" 1 \
			"tmp file not cleaned up after mv failure ($tmp_count file(s) remain)"
		return 0
	fi

	print_result "mv_failure_returns_1" 0
	return 0
}

# ---------------------------------------------------------------------------
# (b) Legacy plist cleanup runs once and is idempotent (Priority 2)
# ---------------------------------------------------------------------------

test_legacy_cleanup_idempotent() {
	local fake_home="$TEST_DIR/home_legacy"
	mkdir -p "$fake_home/Library/LaunchAgents"

	# Create legacy plist
	local legacy_plist="$fake_home/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist"
	printf 'fake legacy plist\n' >"$legacy_plist"

	# Track launchctl unload calls
	local unload_count=0
	launchctl() {
		if [[ "${1:-}" == "unload" ]]; then
			unload_count=$((unload_count + 1))
		fi
		return 0
	}
	# Override generate to return fake content (avoids real script path checks)
	_generate_pulse_plist_content() { printf 'fake plist content\n'; return 0; }

	local orig_home="$HOME"
	HOME="$fake_home"

	local rc=0
	_install_pulse_launchd \
		"com.aidevops.aidevops-supervisor-pulse" "/fake/wrapper.sh" "" "false" || rc=$?

	HOME="$orig_home"
	unset -f launchctl _generate_pulse_plist_content

	if [[ "$rc" -ne 0 ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"first call returned $rc (expected 0)"
		return 0
	fi

	if [[ -f "$legacy_plist" ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"legacy plist still present after first call"
		return 0
	fi

	if [[ "$unload_count" -lt 1 ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"launchctl unload was not called for legacy plist (unload_count=$unload_count)"
		return 0
	fi

	# Second call — idempotent: legacy file is gone, should not error
	launchctl() { return 0; }
	_generate_pulse_plist_content() { printf 'fake plist content\n'; return 0; }
	HOME="$fake_home"

	rc=0
	_install_pulse_launchd \
		"com.aidevops.aidevops-supervisor-pulse" "/fake/wrapper.sh" "" "true" || rc=$?

	HOME="$orig_home"
	unset -f launchctl _generate_pulse_plist_content

	if [[ "$rc" -ne 0 ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"second call (idempotent) returned $rc (expected 0)"
		return 0
	fi

	print_result "legacy_cleanup_first_call_rc" 0
	return 0
}

# ---------------------------------------------------------------------------
# (c) Empty content is rejected before write (Priority 4)
# ---------------------------------------------------------------------------

test_empty_content_rejected() {
	local plist_dir="$TEST_DIR/la_empty"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "empty_content_rejected" 1 \
			"expected non-zero return for empty content, got 0"
		return 0
	fi

	# No tmp files should remain
	local tmp_count
	tmp_count=$(find "$plist_dir" -name "test.plist.*" 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$tmp_count" -ne 0 ]]; then
		print_result "empty_content_rejected" 1 \
			"tmp file not cleaned up after empty-content rejection ($tmp_count file(s))"
		return 0
	fi

	# Destination plist must not have been created
	if [[ -f "$plist_path" ]]; then
		print_result "empty_content_rejected" 1 \
			"plist was created despite empty content"
		return 0
	fi

	print_result "empty_content_rejected" 0
	return 0
}

# ---------------------------------------------------------------------------
# (d) Background-item display links are unchanged when already correct
# ---------------------------------------------------------------------------

test_display_link_install_is_idempotent() {
	local link_dir="$TEST_DIR/display-link"
	local first_target="$link_dir/first-target"
	local second_target="$link_dir/second-target"
	local display_link="$link_dir/aidevops-background-job"
	local inode_before inode_after
	local expected_call="aidevops_ensure_symlink_target \"\$script_path\" \"\$display_link\""
	mkdir -p "$link_dir"
	printf 'first\n' >"$first_target"
	printf 'second\n' >"$second_target"
	ln -s "$first_target" "$display_link"
	inode_before=$(stat -f '%i' "$display_link")

	aidevops_ensure_symlink_target "$first_target" "$display_link"
	inode_after=$(stat -f '%i' "$display_link")
	if [[ "$inode_before" != "$inode_after" ]]; then
		print_result "display_link_install_is_idempotent" 1 "unchanged symlink inode was replaced"
		return 0
	fi

	aidevops_ensure_symlink_target "$second_target" "$display_link"
	if [[ "$(readlink "$display_link")" != "$second_target" ]]; then
		print_result "display_link_install_is_idempotent" 1 "changed target was not installed"
		return 0
	fi

	if ! grep -qF "$expected_call" "$AUTO_UPDATE_SH" ||
		! grep -qF "$expected_call" "$AUTO_UPDATE_SCHEDULER_SH" ||
		! grep -qF "$expected_call" "$REPO_SYNC_SH" ||
		! grep -qF "$expected_call" "$REPO_HEALTH_SH"; then
		print_result "display_link_install_is_idempotent" 1 "one or more LaunchAgent installers bypass the idempotent helper"
		return 0
	fi

	print_result "display_link_install_is_idempotent" 0
	return 0
}

# ---------------------------------------------------------------------------
# (e) Loaded-but-stuck xpcproxy agents are recovered without content changes
# ---------------------------------------------------------------------------

test_xpcproxy_recovered_when_content_unchanged() {
	local plist_dir="$TEST_DIR/la_xpcproxy"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"
	local recovered_marker="$plist_dir/recovered"
	printf 'some plist content\n' >"$plist_path"

	_launchd_has_agent() { return 0; }

	local bootout_count=0
	local bootstrap_count=0
	launchctl() {
		case "${1:-}" in
		print)
			if [[ -f "$recovered_marker" ]]; then
				printf 'state = running\n'
			else
				printf 'state = xpcproxy\n'
			fi
			return 0
			;;
		bootout)
			bootout_count=$((bootout_count + 1))
			return 0
			;;
		bootstrap)
			bootstrap_count=$((bootstrap_count + 1))
			: >"$recovered_marker"
			return 0
			;;
		esac
		return 0
	}

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" || rc=$?

	unset -f launchctl _launchd_has_agent

	if [[ "$rc" -ne 0 ]]; then
		print_result "xpcproxy_recovered_when_content_unchanged" 1 "expected recovery return 0, got $rc"
		return 0
	fi
	if [[ "$bootout_count" -lt 1 || "$bootstrap_count" -lt 1 ]]; then
		print_result "xpcproxy_recovered_when_content_unchanged" 1 \
			"expected bootout/bootstrap recovery (bootout=$bootout_count bootstrap=$bootstrap_count)"
		return 0
	fi

	print_result "xpcproxy_recovered_when_content_unchanged" 0
	return 0
}

test_xpcproxy_successful_recovery_does_not_warn() {
	local plist_dir="$TEST_DIR/la_xpcproxy_no_warn"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"
	local recovered_marker="$plist_dir/recovered"
	local stderr_file="$plist_dir/stderr.log"
	printf 'some plist content\n' >"$plist_path"

	_launchd_has_agent() { return 0; }

	launchctl() {
		case "${1:-}" in
		print)
			if [[ -f "$recovered_marker" ]]; then
				printf 'state = not running\nlast exit code = 0\n'
			else
				printf 'pid = 12345\nstate = xpcproxy\n'
			fi
			return 0
			;;
		bootout)
			return 0
			;;
		bootstrap)
			: >"$recovered_marker"
			return 0
			;;
		kickstart)
			return 0
			;;
		esac
		return 0
	}

	local old_interval="${AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS:-}"
	export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS=0

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" 2>"$stderr_file" || rc=$?

	if [[ -n "$old_interval" ]]; then
		export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS="$old_interval"
	else
		unset AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS
	fi
	unset -f launchctl _launchd_has_agent

	if [[ "$rc" -ne 0 ]]; then
		print_result "xpcproxy_successful_recovery_does_not_warn" 1 "expected recovery return 0, got $rc"
		return 0
	fi
	if grep -q '\[WARN\]' "$stderr_file"; then
		print_result "xpcproxy_successful_recovery_does_not_warn" 1 \
			"successful recovery emitted warning: $(tr '\n' ' ' <"$stderr_file")"
		return 0
	fi

	print_result "xpcproxy_successful_recovery_does_not_warn" 0
	return 0
}

test_xpcproxy_recovery_waits_for_transient_state() {
	local plist_dir="$TEST_DIR/la_xpcproxy_transient"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"
	local print_count_file="$plist_dir/print-count"
	printf 'some plist content\n' >"$plist_path"
	printf '0\n' >"$print_count_file"

	_launchd_has_agent() { return 0; }

	local bootout_count=0
	local bootstrap_count=0
	launchctl() {
		case "${1:-}" in
		print)
			local print_count
			print_count=$(<"$print_count_file")
			print_count=$((print_count + 1))
			printf '%s\n' "$print_count" >"$print_count_file"
			if [[ "$print_count" -lt 4 ]]; then
				printf 'state = xpcproxy\n'
			else
				printf 'state = not running\nlast exit code = 0\n'
			fi
			return 0
			;;
		kickstart)
			return 0
			;;
		bootout)
			bootout_count=$((bootout_count + 1))
			return 0
			;;
		bootstrap)
			bootstrap_count=$((bootstrap_count + 1))
			return 0
			;;
		esac
		return 0
	}

	local old_attempts="${AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_ATTEMPTS:-}"
	local old_interval="${AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS:-}"
	export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_ATTEMPTS=3
	export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS=0

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" || rc=$?

	if [[ -n "$old_attempts" ]]; then
		export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_ATTEMPTS="$old_attempts"
	else
		unset AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_ATTEMPTS
	fi
	if [[ -n "$old_interval" ]]; then
		export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS="$old_interval"
	else
		unset AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS
	fi
	unset -f launchctl _launchd_has_agent

	if [[ "$rc" -ne 0 ]]; then
		print_result "xpcproxy_recovery_waits_for_transient_state" 1 "expected recovery return 0, got $rc"
		return 0
	fi
	local print_count
	print_count=$(<"$print_count_file")
	if [[ "$bootout_count" -lt 1 || "$bootstrap_count" -lt 1 || "$print_count" -lt 4 ]]; then
		print_result "xpcproxy_recovery_waits_for_transient_state" 1 \
			"expected bootout/bootstrap and settle polling (bootout=$bootout_count bootstrap=$bootstrap_count print=$print_count)"
		return 0
	fi

	print_result "xpcproxy_recovery_waits_for_transient_state" 0
	return 0
}

test_generic_recovery_kickstarts_after_bootstrap() {
	local plist_dir="$TEST_DIR/la_xpcproxy_generic_kickstart"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"
	local recovered_marker="$plist_dir/recovered"
	printf 'some plist content\n' >"$plist_path"

	_launchd_has_agent() { return 0; }

	local kickstart_count=0
	launchctl() {
		case "${1:-}" in
		print)
			if [[ -f "$recovered_marker" ]]; then
				printf 'state = not running\nlast exit code = 0\n'
			else
				printf 'pid = 12345\nstate = xpcproxy\n'
			fi
			return 0
			;;
		kickstart)
			kickstart_count=$((kickstart_count + 1))
			: >"$recovered_marker"
			return 0
			;;
		bootout | bootstrap)
			return 0
			;;
		esac
		return 0
	}

	local old_interval="${AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS:-}"
	export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS=0

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" || rc=$?

	if [[ -n "$old_interval" ]]; then
		export AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS="$old_interval"
	else
		unset AIDEVOPS_LAUNCHD_XPCPROXY_SETTLE_SECONDS
	fi
	unset -f launchctl _launchd_has_agent

	if [[ "$rc" -ne 0 ]]; then
		print_result "generic_recovery_kickstarts_after_bootstrap" 1 "expected recovery return 0, got $rc"
		return 0
	fi
	if [[ "$kickstart_count" -ne 1 ]]; then
		print_result "generic_recovery_kickstarts_after_bootstrap" 1 "expected one kickstart, got $kickstart_count"
		return 0
	fi

	print_result "generic_recovery_kickstarts_after_bootstrap" 0
	return 0
}

test_kickstart_recovers_xpcproxy() {
	local plist_dir="$TEST_DIR/la_kickstart"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"
	local recovered_marker="$plist_dir/recovered"
	printf 'some plist content\n' >"$plist_path"

	local kickstart_count=0
	local bootstrap_count=0
	launchctl() {
		case "${1:-}" in
		print)
			if [[ -f "$recovered_marker" ]]; then
				printf 'state = running\n'
			else
				printf 'state = xpcproxy\n'
			fi
			return 0
			;;
		kickstart)
			kickstart_count=$((kickstart_count + 1))
			return 0
			;;
		bootout)
			return 0
			;;
		bootstrap)
			bootstrap_count=$((bootstrap_count + 1))
			: >"$recovered_marker"
			return 0
			;;
		esac
		return 0
	}

	local rc=0
	_launchd_kickstart_and_recover "test-label" "$plist_path" || rc=$?

	unset -f launchctl

	if [[ "$rc" -ne 0 ]]; then
		print_result "kickstart_recovers_xpcproxy" 1 "expected recovery return 0, got $rc"
		return 0
	fi
	if [[ "$kickstart_count" -lt 1 || "$bootstrap_count" -lt 1 ]]; then
		print_result "kickstart_recovers_xpcproxy" 1 \
			"expected kickstart and bootstrap recovery (kickstart=$kickstart_count bootstrap=$bootstrap_count)"
		return 0
	fi

	print_result "kickstart_recovers_xpcproxy" 0
	return 0
}

test_xpcproxy_state_with_helper_process_not_recovered() {
	local plist_dir="$TEST_DIR/la_xpcproxy_active"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"
	printf 'some plist content\n' >"$plist_path"

	_launchd_has_agent() { return 0; }
	_launchd_process_args() { printf '/opt/homebrew/bin/bash /Users/test/.aidevops/agents/scripts/profile-readme-helper.sh update\n'; return 0; }

	local bootout_count=0
	local bootstrap_count=0
	launchctl() {
		case "${1:-}" in
		print)
			printf 'pid = 12345\nstate = xpcproxy\n'
			return 0
			;;
		bootout)
			bootout_count=$((bootout_count + 1))
			return 0
			;;
		bootstrap)
			bootstrap_count=$((bootstrap_count + 1))
			return 0
			;;
		esac
		return 0
	}

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" || rc=$?

	unset -f launchctl _launchd_has_agent _launchd_process_args

	if [[ "$rc" -ne 0 ]]; then
		print_result "xpcproxy_state_with_helper_process_not_recovered" 1 "expected no-op return 0, got $rc"
		return 0
	fi
	if [[ "$bootout_count" -ne 0 || "$bootstrap_count" -ne 0 ]]; then
		print_result "xpcproxy_state_with_helper_process_not_recovered" 1 \
			"expected no reload for active helper process (bootout=$bootout_count bootstrap=$bootstrap_count)"
		return 0
	fi

	print_result "xpcproxy_state_with_helper_process_not_recovered" 0
	return 0
}

test_profile_readme_install_does_not_kickstart() {
	local fake_home="$TEST_DIR/home_profile"
	mkdir -p "$fake_home/Library/LaunchAgents"
	local plist_path="$fake_home/Library/LaunchAgents/sh.aidevops.profile-readme-update.plist"
	local stderr_file="$TEST_DIR/profile-stderr.log"
	local install_count=0
	local kickstart_count=0
	local expected_plist_content
	expected_plist_content=$(cat <<'PROFILE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>sh.aidevops.profile-readme-update</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>-lc</string>
		<string>start_epoch=$(date +%s); status=success; &apos;/fake/profile-readme-helper.sh&apos; update; rc=$?; end_epoch=$(date +%s); duration=$(( ${end_epoch:-0} - ${start_epoch:-0} )); if [ &quot;$rc&quot; -ne 0 ]; then status=failure; fi; if [ -x &quot;$HOME/.aidevops/agents/scripts/routine-log-helper.sh&quot; ]; then &quot;$HOME/.aidevops/agents/scripts/routine-log-helper.sh&quot; update &quot;r908&quot; --status &quot;$status&quot; --duration &quot;$duration&quot; &gt;/dev/null 2&gt;&amp;1 || true; fi; exit &quot;$rc&quot;</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>__FAKE_HOME__/.aidevops/.agent-workspace/logs/profile-readme-update.log</string>
	<key>StandardErrorPath</key>
	<string>__FAKE_HOME__/.aidevops/.agent-workspace/logs/profile-readme-update.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin</string>
		<key>HOME</key>
		<string>__FAKE_HOME__</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
PROFILE_PLIST
)
	expected_plist_content=${expected_plist_content//__FAKE_HOME__/$fake_home}
	printf '%s\n' "$expected_plist_content" >"$plist_path"

	_launchd_has_agent() { return 0; }
	_launchd_install_if_changed() { install_count=$((install_count + 1)); return 1; }
	_launchd_kickstart_and_recover() { kickstart_count=$((kickstart_count + 1)); return 1; }

	local orig_home="$HOME"
	HOME="$fake_home"

	local rc=0
	_install_profile_readme_launchd "sh.aidevops.profile-readme-update" "/fake/profile-readme-helper.sh" 2>"$stderr_file" || rc=$?

	HOME="$orig_home"
	unset -f _launchd_has_agent _launchd_install_if_changed _launchd_kickstart_and_recover

	if [[ "$rc" -ne 0 ]]; then
		print_result "profile_readme_install_does_not_kickstart" 1 "expected install return 0, got $rc"
		return 0
	fi
	if [[ "$kickstart_count" -ne 0 ]]; then
		print_result "profile_readme_install_does_not_kickstart" 1 "expected no kickstart during setup, got $kickstart_count"
		return 0
	fi
	if [[ "$install_count" -ne 0 ]]; then
		print_result "profile_readme_install_does_not_kickstart" 1 "expected existing loaded profile job to skip install, got $install_count"
		return 0
	fi
	if grep -q '\[WARN\]' "$stderr_file"; then
		print_result "profile_readme_install_does_not_kickstart" 1 \
			"profile launchd install emitted warning: $(tr '\n' ' ' <"$stderr_file")"
		return 0
	fi

	print_result "profile_readme_install_does_not_kickstart" 0
	return 0
}

test_interval_jobs_skip_unchanged_loaded_recovery() {
	local fake_home="$TEST_DIR/home_interval_jobs"
	mkdir -p "$fake_home/Library/LaunchAgents" "$fake_home/logs"
	local complexity_plist="$fake_home/Library/LaunchAgents/sh.aidevops.complexity-scan.plist"
	local peer_plist="$fake_home/Library/LaunchAgents/sh.aidevops.peer-productivity-monitor.plist"
	local stderr_file="$TEST_DIR/interval-jobs-stderr.log"
	local install_count=0

	_launchd_has_agent() { return 0; }
	_launchd_install_if_changed() { install_count=$((install_count + 1)); return 1; }

	local orig_home="$HOME"
	HOME="$fake_home"

	local complexity_content peer_content
	complexity_content=$(_install_complexity_scan_launchd_render_fixture "sh.aidevops.complexity-scan" "/fake/complexity-scan-runner.sh" "$fake_home/logs")
	peer_content=$(_install_peer_productivity_monitor_launchd_render_fixture "sh.aidevops.peer-productivity-monitor" "/fake/peer-productivity-monitor.sh" "$fake_home/logs")
	printf '%s\n' "$complexity_content" >"$complexity_plist"
	printf '%s\n' "$peer_content" >"$peer_plist"

	local rc=0
	_install_complexity_scan_launchd "sh.aidevops.complexity-scan" "/fake/complexity-scan-runner.sh" "$fake_home/logs" 2>"$stderr_file" || rc=$?
	_install_peer_productivity_monitor_launchd "sh.aidevops.peer-productivity-monitor" "/fake/peer-productivity-monitor.sh" "$fake_home/logs" 2>>"$stderr_file" || rc=$?

	HOME="$orig_home"
	unset -f _launchd_has_agent _launchd_install_if_changed

	if [[ "$rc" -ne 0 ]]; then
		print_result "interval_jobs_skip_unchanged_loaded_recovery" 1 "expected install return 0, got $rc"
		return 0
	fi
	if [[ "$install_count" -ne 0 ]]; then
		print_result "interval_jobs_skip_unchanged_loaded_recovery" 1 "expected unchanged loaded jobs to skip install, got $install_count"
		return 0
	fi
	if grep -q '\[WARN\]' "$stderr_file"; then
		print_result "interval_jobs_skip_unchanged_loaded_recovery" 1 \
			"interval launchd install emitted warning: $(tr '\n' ' ' <"$stderr_file")"
		return 0
	fi

	print_result "interval_jobs_skip_unchanged_loaded_recovery" 0
	return 0
}

test_token_refresh_launchd_lifecycle() {
	local fake_home="$TEST_DIR/home_token_refresh"
	local plist="$fake_home/Library/LaunchAgents/sh.aidevops.token-refresh.plist"
	local stderr_file="$TEST_DIR/token-refresh-stderr.log"
	local install_count=0
	local captured_content=""
	mkdir -p "$fake_home/Library/LaunchAgents"

	_launchd_has_agent() { return 0; }
	_launchd_install_if_changed() {
		local _label="$1"
		local _path="$2"
		local content="$3"
		install_count=$((install_count + 1))
		captured_content="$content"
		return 0
	}

	local orig_home="$HOME"
	HOME="$fake_home"
	_install_token_refresh_launchd "sh.aidevops.token-refresh" "/fake/oauth-pool-helper.sh" 2>"$stderr_file"
	printf '%s\n' "$captured_content" >"$plist"
	_install_token_refresh_launchd "sh.aidevops.token-refresh" "/fake/oauth-pool-helper.sh" 2>>"$stderr_file"
	HOME="$orig_home"
	unset -f _launchd_has_agent _launchd_install_if_changed

	if [[ "$install_count" -ne 1 ]]; then
		print_result "token_refresh_launchd_lifecycle" 1 "expected one install and an idempotent second run, got $install_count installs"
		return 0
	fi
	if grep -q '\[WARN\]' "$stderr_file"; then
		print_result "token_refresh_launchd_lifecycle" 1 "healthy token refresh install emitted a warning"
		return 0
	fi
	if [[ "$captured_content" != *"$(_resolve_modern_bash)"* ]] ||
		[[ "$captured_content" != *"refresh anthropic;"* ]] ||
		[[ "$captured_content" != *"refresh openai"* ]] ||
		[[ "$captured_content" != *"<key>HOME</key>"* ]] ||
		[[ "$captured_content" != *"<key>PATH</key>"* ]]; then
		print_result "token_refresh_launchd_lifecycle" 1 "rendered plist is missing the expected runtime or refresh commands"
		return 0
	fi

	print_result "token_refresh_launchd_lifecycle" 0
	return 0
}

test_token_refresh_failure_is_actionable() {
	local fake_home="$TEST_DIR/home_token_refresh_failure"
	local stderr_file="$TEST_DIR/token-refresh-failure-stderr.log"
	mkdir -p "$fake_home/Library/LaunchAgents"

	_launchd_has_agent() { return 1; }
	_launchd_install_if_changed() { return 1; }
	local orig_home="$HOME"
	HOME="$fake_home"
	_install_token_refresh_launchd "sh.aidevops.token-refresh" "/fake/oauth-pool-helper.sh" 2>"$stderr_file"
	HOME="$orig_home"
	unset -f _launchd_has_agent _launchd_install_if_changed

	if ! grep -q 'launchctl bootstrap gui/' "$stderr_file" || ! grep -q 'sh.aidevops.token-refresh.plist' "$stderr_file"; then
		print_result "token_refresh_failure_is_actionable" 1 "failure warning omitted the recovery command"
		return 0
	fi
	print_result "token_refresh_failure_is_actionable" 0
	return 0
}

_install_complexity_scan_launchd_render_fixture() {
	local cs_label="$1"
	local cs_script="$2"
	local _cs_log_dir="$3"
	local _xml_cs_script _xml_cs_home _xml_cs_log_dir
	_xml_cs_script=$(_xml_escape "$cs_script")
	_xml_cs_home=$(_xml_escape "$HOME")
	_xml_cs_log_dir=$(_xml_escape "$_cs_log_dir")
	cat <<CS_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${cs_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_cs_script}</string>
		<string>run</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_cs_log_dir}/complexity-scan-runner.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_cs_log_dir}/complexity-scan-runner.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_cs_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
CS_PLIST
	return 0
}

_install_peer_productivity_monitor_launchd_render_fixture() {
	local ppm_label="$1"
	local ppm_script="$2"
	local _ppm_log_dir="$3"
	local _xml_ppm_script _xml_ppm_home _xml_ppm_log_dir
	_xml_ppm_script=$(_xml_escape "$ppm_script")
	_xml_ppm_home=$(_xml_escape "$HOME")
	_xml_ppm_log_dir=$(_xml_escape "$_ppm_log_dir")
	cat <<PPM_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${ppm_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_ppm_script}</string>
		<string>observe</string>
	</array>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>StandardOutPath</key>
	<string>${_xml_ppm_log_dir}/peer-productivity-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_ppm_log_dir}/peer-productivity-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_ppm_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
PPM_PLIST
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	# macOS-only: launchd/launchctl is not available on Linux
	if [[ "$(uname -s)" != "Darwin" ]]; then
		echo "SKIP: launchd tests are macOS-only (current: $(uname -s))"
		exit 0
	fi

	setup

	# Tests (a) and (c) use the inline _launchd_install_if_changed definition
	_define_launchd_install_if_changed

	test_mv_failure_returns_1
	test_empty_content_rejected
	test_display_link_install_is_idempotent
	test_xpcproxy_recovered_when_content_unchanged
	test_xpcproxy_successful_recovery_does_not_warn
	test_xpcproxy_recovery_waits_for_transient_state
	test_generic_recovery_kickstarts_after_bootstrap
	test_kickstart_recovers_xpcproxy
	test_xpcproxy_state_with_helper_process_not_recovered

	_load_schedulers_platform_functions
	test_profile_readme_install_does_not_kickstart
	test_interval_jobs_skip_unchanged_loaded_recovery
	test_token_refresh_launchd_lifecycle
	test_token_refresh_failure_is_actionable

	# Test (b) needs _install_pulse_launchd from schedulers.sh
	_load_schedulers_functions

	test_legacy_cleanup_idempotent

	echo ""
	echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
