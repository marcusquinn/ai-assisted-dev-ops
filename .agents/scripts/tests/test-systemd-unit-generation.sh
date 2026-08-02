#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Test systemd unit file generation (GH#18789)
#
# Verifies that generated service files use bare (unquoted) values for
# StandardOutput= and StandardError= directives. systemd does NOT strip
# outer quotes from those values — "append:/path" is treated as a literal
# filename with quote characters, causing the directive to be silently
# ignored. See GH#18789 for the investigation and fix.
#
# Requires: systemd-analyze (available on Linux with systemd)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
REPO_SCRIPTS_DIR="${REPO_ROOT}/.agents/scripts"

# shellcheck source=../setup/modules/schedulers-linux.sh
source "${REPO_SCRIPTS_DIR}/setup/modules/schedulers-linux.sh"
# shellcheck source=../pulse-dispatch-preflight-lib.sh
source "${REPO_SCRIPTS_DIR}/pulse-dispatch-preflight-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

systemd_analyze_available() {
	if ! command -v systemd-analyze >/dev/null 2>&1; then
		printf 'SKIP: systemd-analyze not available; parse checks omitted\n'
		return 1
	fi
	return 0
}

# --- Unit generation helpers (mirrors the real generators) ---

generate_scheduler_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops test-service
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc 'echo hello'
TimeoutStartSec=60
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

generate_autoupdate_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops auto-update-test
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc 'echo check'
TimeoutStartSec=120
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

generate_reposync_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops repo-sync-test
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc 'echo sync'
TimeoutStartSec=300
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

generate_supervisor_pulse_unit() {
	local log_file="$1"
	local service_file="$2"
	printf '%s' "[Unit]
Description=aidevops aidevops-supervisor-pulse
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc 'echo pulse'
TimeoutStartSec=3600
TimeoutStopSec=30
SendSIGKILL=yes
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
" >"$service_file"
	return 0
}

test_real_scheduler_unit_uses_control_group() {
	local tmpdir=""
	local service_name="aidevops-killmode-test-$$"
	local service_file=""
	local kill_mode=""
	tmpdir=$(mktemp -d)
	service_file="${tmpdir}/home/.config/systemd/user/${service_name}.service"
	mkdir -p "${tmpdir}/bin" "${tmpdir}/home"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${tmpdir}/bin/systemctl"
	chmod +x "${tmpdir}/bin/systemctl"

	(
		export HOME="${tmpdir}/home"
		export PATH="${tmpdir}/bin:${PATH}"
		_install_scheduler_systemd "$service_name" "true" "60" \
			"${tmpdir}/scheduler.log" "" "false" "false" "" "60" >/dev/null 2>&1 || true
	)
	kill_mode=$(grep -E '^KillMode=' "$service_file" 2>/dev/null || true)
	rm -rf "$tmpdir"

	if [[ "$kill_mode" == "KillMode=control-group" ]]; then
		print_result "real shared scheduler unit uses control-group cleanup" 0
	else
		print_result "real shared scheduler unit uses control-group cleanup" 1 \
			"Expected KillMode=control-group, got: ${kill_mode:-missing}"
	fi
	return 0
}

test_standalone_templates_use_control_group() {
	local relative_path=""
	local template_path=""
	local failures=""
	local -a templates=(
		"auto-update-helper.sh"
		"auto-update-helper-scheduler.sh"
		"routine-helper.sh"
		"repo-aidevops-health-helper.sh"
		"repo-sync-helper.sh"
		"worker-watchdog-cmd.sh"
		"setup/modules/schedulers-linux.sh"
	)

	for relative_path in "${templates[@]}"; do
		template_path="${REPO_SCRIPTS_DIR}/${relative_path}"
		if ! grep -q '^KillMode=control-group$' "$template_path" || grep -q '^KillMode=process$' "$template_path"; then
			failures+="${relative_path} "
		fi
	done

	if [[ -z "$failures" ]]; then
		print_result "synchronous systemd templates use control-group cleanup" 0
	else
		print_result "synchronous systemd templates use control-group cleanup" 1 \
			"Unexpected KillMode policy in: ${failures% }"
	fi
	return 0
}

# --- Tests ---

test_quoted_stdout_fails_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/test-quoted.service"
	local log_file="/tmp/test.log"

	printf '%s' "[Unit]
Description=test quoted stdout

[Service]
Type=oneshot
ExecStart=/usr/bin/true
StandardOutput=\"append:${log_file}\"
" >"$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "quoted StandardOutput= fails systemd-analyze verify" 0
	else
		print_result "quoted StandardOutput= fails systemd-analyze verify" 1 \
			"Expected 'Failed to parse output specifier' but got: $output"
	fi
	return 0
}

test_bare_stdout_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/test-bare.service"
	local log_file="/tmp/test.log"

	printf '%s' "[Unit]
Description=test bare stdout

[Service]
Type=oneshot
ExecStart=/usr/bin/true
StandardOutput=append:${log_file}
" >"$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "bare StandardOutput= passes systemd-analyze verify" 1 \
			"Unexpected parse failure: $output"
	else
		print_result "bare StandardOutput= passes systemd-analyze verify" 0
	fi
	return 0
}

test_scheduler_unit_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/scheduler.service"
	local log_file="/tmp/aidevops-scheduler.log"

	generate_scheduler_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "scheduler generator: StandardOutput= passes verify" 1 \
			"Parse failure in generated unit: $output"
	else
		print_result "scheduler generator: StandardOutput= passes verify" 0
	fi
	return 0
}

test_autoupdate_unit_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/autoupdate.service"
	local log_file="/tmp/aidevops-update.log"

	generate_autoupdate_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "auto-update generator: StandardOutput= passes verify" 1 \
			"Parse failure in generated unit: $output"
	else
		print_result "auto-update generator: StandardOutput= passes verify" 0
	fi
	return 0
}

test_reposync_unit_passes_verify() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/reposync.service"
	local log_file="/tmp/aidevops-repo-sync.log"

	generate_reposync_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse output specifier"; then
		print_result "repo-sync generator: StandardOutput= passes verify" 1 \
			"Parse failure in generated unit: $output"
	else
		print_result "repo-sync generator: StandardOutput= passes verify" 0
	fi
	return 0
}

test_supervisor_pulse_unit_uses_control_group_kill() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/aidevops-supervisor-pulse.service"
	local log_file="/tmp/aidevops-supervisor-pulse.log"

	generate_supervisor_pulse_unit "$log_file" "$service_file"

	local output
	output=$(systemd-analyze verify "$service_file" 2>&1 || true)

	local kill_mode
	kill_mode=$(grep -E '^KillMode=' "$service_file" || true)
	local timeout_stop
	timeout_stop=$(grep -E '^TimeoutStopSec=30$' "$service_file" || true)
	local sigkill
	sigkill=$(grep -E '^SendSIGKILL=yes$' "$service_file" || true)

	rm -rf "$tmpdir"

	if echo "$output" | grep -q "Failed to parse"; then
		print_result "supervisor pulse unit verifies with control-group kill" 1 \
			"Parse failure in generated unit: $output"
	elif [[ "$kill_mode" != "KillMode=control-group" || -z "$timeout_stop" || -z "$sigkill" ]]; then
		print_result "supervisor pulse unit verifies with control-group kill" 1 \
			"Expected KillMode=control-group, TimeoutStopSec=30, SendSIGKILL=yes"
	else
		print_result "supervisor pulse unit verifies with control-group kill" 0
	fi
	return 0
}

test_no_literal_quotes_in_scheduler_unit() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/scheduler.service"
	local log_file="/tmp/aidevops-scheduler.log"

	generate_scheduler_unit "$log_file" "$service_file"

	# StandardOutput= and StandardError= values must not contain literal "
	local bad_lines
	bad_lines=$(grep -E '^(StandardOutput|StandardError)=.*"' "$service_file" || true)

	rm -rf "$tmpdir"

	if [[ -n "$bad_lines" ]]; then
		print_result "scheduler unit has no quoted StandardOutput/StandardError" 1 \
			"Found literal quotes: $bad_lines"
	else
		print_result "scheduler unit has no quoted StandardOutput/StandardError" 0
	fi
	return 0
}

test_no_literal_quotes_in_autoupdate_unit() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/autoupdate.service"
	local log_file="/tmp/aidevops-update.log"

	generate_autoupdate_unit "$log_file" "$service_file"

	local bad_lines
	bad_lines=$(grep -E '^(StandardOutput|StandardError)=.*"' "$service_file" || true)

	rm -rf "$tmpdir"

	if [[ -n "$bad_lines" ]]; then
		print_result "auto-update unit has no quoted StandardOutput/StandardError" 1 \
			"Found literal quotes: $bad_lines"
	else
		print_result "auto-update unit has no quoted StandardOutput/StandardError" 0
	fi
	return 0
}

test_no_literal_quotes_in_reposync_unit() {
	local tmpdir
	tmpdir=$(mktemp -d)
	local service_file="${tmpdir}/reposync.service"
	local log_file="/tmp/aidevops-repo-sync.log"

	generate_reposync_unit "$log_file" "$service_file"

	local bad_lines
	bad_lines=$(grep -E '^(StandardOutput|StandardError)=.*"' "$service_file" || true)

	rm -rf "$tmpdir"

	if [[ -n "$bad_lines" ]]; then
		print_result "repo-sync unit has no quoted StandardOutput/StandardError" 1 \
			"Found literal quotes: $bad_lines"
	else
		print_result "repo-sync unit has no quoted StandardOutput/StandardError" 0
	fi
	return 0
}

write_cleanup_launcher_stubs() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/uname" <<'STUB'
#!/usr/bin/env bash
printf 'Linux\n'
exit 0
STUB
	cat >"${bin_dir}/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	cat >"${bin_dir}/systemd-run" <<'STUB'
#!/usr/bin/env bash
{
	printf 'CALL'
	for arg in "$@"; do
		printf '\t%s' "$arg"
	done
	printf '\n'
} >>"$SYSTEMD_RUN_CAPTURE"
[[ "${SYSTEMD_RUN_FAIL:-0}" == "1" ]] && exit 1
exit 0
STUB
	cat >"${bin_dir}/nohup" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NOHUP_CAPTURE"
exit 0
STUB
	chmod +x "${bin_dir}/uname" "${bin_dir}/systemctl" \
		"${bin_dir}/systemd-run" "${bin_dir}/nohup"
	return 0
}

write_cleanup_launcher_helpers() {
	local helper_dir="$1"
	local helper_name=""
	mkdir -p "$helper_dir"
	for helper_name in worktrees stashes remote-branches; do
		cat >"${helper_dir}/${helper_name}.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
		chmod +x "${helper_dir}/${helper_name}.sh"
	done
	return 0
}

test_cleanup_helpers_use_transient_systemd_units() {
	local tmpdir=""
	local capture="" fallback_capture="" parent_log=""
	local calls=0 unit_count=0 launch_call_count=0 rc=0
	local merge_first_source="" cleanup_source=""
	tmpdir=$(mktemp -d)
	capture="${tmpdir}/systemd-run.log"
	fallback_capture="${tmpdir}/nohup.log"
	parent_log="${tmpdir}/pulse.log"
	write_cleanup_launcher_stubs "${tmpdir}/bin"
	write_cleanup_launcher_helpers "${tmpdir}/helpers"

	(
		export HOME="${tmpdir}/home"
		export PATH="${tmpdir}/bin:${PATH}"
		export XDG_CONFIG_HOME="${tmpdir}/xdg-config"
		export CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=23
		export AIDEVOPS_DIRTY_BACKUP_MAX_UNTRACKED_FILES=1234
		export AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY=1
		export SYSTEMD_RUN_CAPTURE="$capture"
		export NOHUP_CAPTURE="$fallback_capture"
		export UNRELATED_ENV_SENTINEL="must-not-cross-boundary"
		export GH_TOKEN="must-not-cross-boundary"
		LOGFILE="$parent_log"
		_preflight_launch_async_cleanup "${tmpdir}/helpers/worktrees.sh" "${tmpdir}/worktrees.log" "worktrees"
		_preflight_launch_async_cleanup "${tmpdir}/helpers/stashes.sh" "${tmpdir}/stashes.log" "stashes"
		_preflight_launch_async_cleanup "${tmpdir}/helpers/remote-branches.sh" "${tmpdir}/remote-branches.log" "remote-branches"
	)

	calls=$(wc -l <"$capture" | tr -d ' ')
	unit_count=$(grep -oE -- '--unit=[^[:space:]]+' "$capture" | sort -u | wc -l | tr -d ' ')
	[[ "$calls" == "3" && "$unit_count" == "3" ]] || rc=1
	for required in \
		'--collect' '--no-block' '--property=Type=exec' '--property=RuntimeMaxSec=3600' \
		'--property=TimeoutStopSec=30' '--property=KillMode=control-group' \
		'--property=SendSIGKILL=yes' '--property=Nice=10' \
		'--property=IOSchedulingClass=idle' $'\t-i\t' \
		"HOME=${tmpdir}/home" "PATH=${tmpdir}/bin:" \
		"XDG_CONFIG_HOME=${tmpdir}/xdg-config" \
		'CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=23' \
		'AIDEVOPS_DIRTY_BACKUP_MAX_UNTRACKED_FILES=1234' \
		'AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY=1'; do
		grep -qF -- "$required" "$capture" || rc=1
	done
	for unit_prefix in worktrees stashes remote-branches; do
		grep -qE -- "--unit=aidevops-cleanup-${unit_prefix}-[0-9]+-[0-9]+" "$capture" || rc=1
		grep -qF -- "--property=StandardOutput=append:${tmpdir}/${unit_prefix}.log" "$capture" || rc=1
		grep -qF -- "--property=StandardError=append:${tmpdir}/${unit_prefix}.log" "$capture" || rc=1
		grep -qF -- "${tmpdir}/helpers/${unit_prefix}.sh" "$capture" || rc=1
	done
	if grep -qE 'UNRELATED_ENV_SENTINEL=|GH_TOKEN=' "$capture"; then
		rc=1
	fi
	[[ ! -s "$fallback_capture" ]] || rc=1
	merge_first_source=$(declare -f _preflight_start_merge_first)
	[[ "$merge_first_source" == *"nohup"* ]] || rc=1
	[[ "$merge_first_source" != *"_preflight_launch_async_cleanup"* ]] || rc=1
	cleanup_source=$(declare -f _preflight_cleanup_and_ledger)
	launch_call_count=$(printf '%s\n' "$cleanup_source" | grep -c '_preflight_launch_async_cleanup')
	[[ "$launch_call_count" == "3" && "$cleanup_source" != *"nohup"* ]] || rc=1

	rm -rf "$tmpdir"
	print_result "cleanup helpers use isolated transient units with an environment allowlist" "$rc"
	return 0
}

test_cleanup_transient_failure_falls_back_once() {
	local tmpdir=""
	local capture="" fallback_capture="" parent_log=""
	local attempts=0 systemd_calls=0 fallback_calls=0 rc=0
	tmpdir=$(mktemp -d)
	capture="${tmpdir}/systemd-run.log"
	fallback_capture="${tmpdir}/nohup.log"
	parent_log="${tmpdir}/pulse.log"
	write_cleanup_launcher_stubs "${tmpdir}/bin"
	write_cleanup_launcher_helpers "${tmpdir}/helpers"

	(
		export HOME="${tmpdir}/home"
		export PATH="${tmpdir}/bin:${PATH}"
		export SYSTEMD_RUN_CAPTURE="$capture"
		export SYSTEMD_RUN_FAIL=1
		export NOHUP_CAPTURE="$fallback_capture"
		export AIDEVOPS_CLEANUP_SYSTEMD_RUNTIME_MAX_SEC="invalid"
		LOGFILE="$parent_log"
		_preflight_launch_async_cleanup "${tmpdir}/helpers/worktrees.sh" "${tmpdir}/worktrees.log" "worktrees"
		while [[ ! -s "$fallback_capture" && "$attempts" -lt 20 ]]; do
			sleep 0.05
			attempts=$((attempts + 1))
		done
	)

	systemd_calls=$(wc -l <"$capture" | tr -d ' ')
	fallback_calls=$(wc -l <"$fallback_capture" | tr -d ' ')
	[[ "$systemd_calls" == "1" && "$fallback_calls" == "1" ]] || rc=1
	grep -qF -- '--property=RuntimeMaxSec=3600' "$capture" || rc=1
	grep -qF -- "${tmpdir}/helpers/worktrees.sh" "$fallback_capture" || rc=1

	rm -rf "$tmpdir"
	print_result "failed transient cleanup submission uses exactly one nohup fallback" "$rc"
	return 0
}

# --- Main ---

main() {
	printf 'Running systemd unit generation tests...\n\n'
	test_real_scheduler_unit_uses_control_group
	test_standalone_templates_use_control_group

	if systemd_analyze_available; then
		# Confirm the bug exists with quoted values (regression anchor)
		test_quoted_stdout_fails_verify

		# Confirm bare values work
		test_bare_stdout_passes_verify

		# Test each generator produces valid units
		test_scheduler_unit_passes_verify
		test_autoupdate_unit_passes_verify
		test_reposync_unit_passes_verify
		test_supervisor_pulse_unit_uses_control_group_kill
	fi

	# Test no literal quotes appear in generated output
	test_no_literal_quotes_in_scheduler_unit
	test_no_literal_quotes_in_autoupdate_unit
	test_no_literal_quotes_in_reposync_unit
	test_cleanup_helpers_use_transient_systemd_units
	test_cleanup_transient_failure_falls_back_once

	printf '\n%s/%s tests passed.\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
