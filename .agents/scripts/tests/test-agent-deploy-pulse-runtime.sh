#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT=""
PULSE_PATTERN=""
TESTS_RUN=0

print_info() {
	local message="$1"
	printf '%s\n' "$message"
	return 0
}
print_success() {
	local message="$1"
	printf '%s\n' "$message"
	return 0
}
print_warning() {
	local message="$1"
	printf 'WARN: %s\n' "$message" >&2
	return 0
}
print_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 0
}

# shellcheck source=../setup/modules/agent-deploy.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-deploy.sh"
# shellcheck source=../setup/modules/agent-runtime.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-runtime.sh"

cleanup() {
	if [[ -n "$PULSE_PATTERN" ]]; then
		pkill -TERM -f "$PULSE_PATTERN" 2>/dev/null || true
		sleep 1
		pkill -KILL -f "$PULSE_PATTERN" 2>/dev/null || true
	fi
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		fail "$message (expected=$expected actual=$actual)"
		return 1
	fi
	pass "$message"
	return 0
}

write_runtime_bundle() {
	local bundle_root="$1"
	local bundle_id="$2"
	mkdir -p "$bundle_root/agents/scripts/setup/modules"
	cp "$REPO_ROOT/.agents/scripts/pulse-lifecycle-helper.sh" \
		"$bundle_root/agents/scripts/pulse-lifecycle-helper.sh"
	cp "$REPO_ROOT/.agents/scripts/setup/modules/agent-runtime.sh" \
		"$bundle_root/agents/scripts/setup/modules/agent-runtime.sh"
	cat >"$bundle_root/agents/scripts/pulse-wrapper.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0" >>"${PULSE_START_LOG:?}"
trap 'exit 0' TERM INT
while :; do
	sleep 1
done
SH
	printf 'bundle_id=%s\nstatus=validated\n' "$bundle_id" >"$bundle_root/agents/.bundle-manifest"
	chmod +x "$bundle_root/agents/scripts/pulse-lifecycle-helper.sh" \
		"$bundle_root/agents/scripts/pulse-wrapper.sh"
	return 0
}

assert_only_active_bundle_runs() {
	local active_script="$1"
	local stale_script="$2"
	local running_commands=""
	running_commands=$(pgrep -f "$PULSE_PATTERN" | while IFS= read -r pulse_pid; do
		ps -p "$pulse_pid" -o command=
	done)
	[[ "$running_commands" == *"$active_script"* ]] || fail "active bundle Pulse is not running"
	[[ "$running_commands" != *"$stale_script"* ]] || fail "stale bundle Pulse is running"
	pass "Pulse command resolves to the active bundle, never the caller bundle"
	return 0
}

test_stale_install_dir_uses_active_bundle() {
	local stale_root="$1"
	local active_root="$2"
	local active_link="$3"
	local output=""
	local output_file="$TEST_ROOT/stale-restart.out"

	INSTALL_DIR="$TEST_ROOT/caller-worktree"
	export INSTALL_DIR
	mkdir -p "$INSTALL_DIR/.agents/scripts"
	cat >"$INSTALL_DIR/.agents/scripts/pulse-wrapper.sh" <<'SH'
#!/usr/bin/env bash
printf 'caller-worktree\n' >>"${PULSE_START_LOG:?}"
SH
	chmod +x "$INSTALL_DIR/.agents/scripts/pulse-wrapper.sh"

	_restart_pulse_if_running "$stale_root/agents" true "$active_link" >"$output_file"
	output=$(<"$output_file")
	[[ "$output" == *"bundle-b"* ]] || fail "restart diagnostics omit the selected active bundle"
	[[ "$output" != *"$TEST_ROOT"* ]] || fail "restart diagnostics expose a private local path"
	grep -qF "$active_root/agents/scripts/pulse-wrapper.sh" "$PULSE_START_LOG" ||
		fail "active bundle Pulse path was not launched"
	if grep -qF "caller-worktree" "$PULSE_START_LOG"; then
		fail "stale INSTALL_DIR Pulse path was launched"
	fi
	assert_only_active_bundle_runs \
		"$active_root/agents/scripts/pulse-wrapper.sh" \
		"$stale_root/agents/scripts/pulse-wrapper.sh"
	pass "stale INSTALL_DIR cannot select the restarted Pulse revision"
	return 0
}

test_disabled_supervisor_stays_stopped() {
	local active_root="$1"
	local active_link="$2"
	local starts_before=""
	local starts_after=""
	starts_before=$(wc -l <"$PULSE_START_LOG" | tr -d ' ')
	_restart_pulse_if_running "$active_root/agents" false "$active_link" >/dev/null
	starts_after=$(wc -l <"$PULSE_START_LOG" | tr -d ' ')
	[[ "$starts_after" == "$starts_before" ]] || fail "disabled reconciliation started a new Pulse"
	if pgrep -f "$PULSE_PATTERN" >/dev/null 2>&1; then
		fail "disabled supervisor reconciliation left Pulse running"
	fi
	pass "disabled supervisor remains stopped without a manual fallback"
	return 0
}

test_concurrent_transition_converges_on_active_bundle() {
	local stale_root="$1"
	local active_root="$2"
	local active_link="$3"
	local transition_pid=""
	local transition_ready="$TEST_ROOT/transition-ready"
	local wait_attempts=20
	local pulse_count=""

	rm -f "$active_link"
	ln -s "$stale_root/agents" "$active_link"
	(
		aidevops_runtime_transition_lock_acquire
		: >"$transition_ready"
		sleep 1
		rm -f "$active_link"
		ln -s "$active_root/agents" "$active_link"
		aidevops_runtime_transition_lock_release
	) &
	transition_pid=$!
	while [[ ! -f "$transition_ready" && "$wait_attempts" -gt 0 ]]; do
		sleep 0.1
		wait_attempts=$((wait_attempts - 1))
	done
	[[ -f "$transition_ready" ]] || fail "concurrent activation fixture did not acquire the transition lock"
	_restart_pulse_if_running "$stale_root/agents" true "$active_link" >/dev/null
	wait "$transition_pid"

	pulse_count=$(pgrep -f "$PULSE_PATTERN" | wc -l | tr -d ' ')
	[[ "$pulse_count" == "1" ]] || fail "concurrent transition left $pulse_count Pulse processes"
	assert_only_active_bundle_runs \
		"$active_root/agents/scripts/pulse-wrapper.sh" \
		"$stale_root/agents/scripts/pulse-wrapper.sh"
	pass "concurrent activation and restart converge on one active Pulse revision"
	return 0
}

test_launchd_disabled_service_stays_stopped() {
	local active_root="$1"
	local active_link="$2"
	local fake_bin="$TEST_ROOT/fake-bin"
	local starts_before=""
	local starts_after=""
	mkdir -p "$fake_bin"
	cat >"$fake_bin/launchctl" <<'SH'
#!/usr/bin/env bash
command_name="${1:-}"
if [[ "$command_name" == "print-disabled" ]]; then
	printf '%s\n' '    "com.aidevops.aidevops-supervisor-pulse" => true'
	exit 0
fi
exit 1
SH
	chmod +x "$fake_bin/launchctl"
	starts_before=$(wc -l <"$PULSE_START_LOG" | tr -d ' ')
	(
		export PATH="$fake_bin:$PATH"
		export AIDEVOPS_PULSE_OS_NAME=Darwin
		_restart_pulse_if_running "$active_root/agents" true "$active_link" >/dev/null
	)
	starts_after=$(wc -l <"$PULSE_START_LOG" | tr -d ' ')
	[[ "$starts_after" == "$starts_before" ]] || fail "disabled launchd reconciliation started a new Pulse"
	if pgrep -f "$PULSE_PATTERN" >/dev/null 2>&1; then
		fail "disabled launchd service reconciliation left Pulse running"
	fi
	pass "disabled launchd service remains authoritative without a manual fallback"
	return 0
}

test_launchd_enabled_service_owns_restart() {
	local active_root="$1"
	local active_link="$2"
	local fake_bin="$TEST_ROOT/fake-bin"
	local launchctl_log="$TEST_ROOT/launchctl.log"
	local output_file="$TEST_ROOT/launchd-restart.out"
	cat >"$fake_bin/launchctl" <<'SH'
#!/usr/bin/env bash
command_name="${1:-}"
case "$command_name" in
print-disabled)
	printf '%s\n' '    "com.aidevops.aidevops-supervisor-pulse" => false'
	exit 0
	;;
print)
	exit 0
	;;
kickstart)
	printf '%s\n' "$*" >>"${LAUNCHCTL_LOG:?}"
	active_root=$(cd "${AIDEVOPS_ACTIVE_AGENTS_LINK:?}" && pwd -P)
	nohup "$active_root/scripts/pulse-wrapper.sh" >/dev/null 2>&1 &
	exit 0
	;;
esac
exit 1
SH
	chmod +x "$fake_bin/launchctl"
	: >"$launchctl_log"
	(
		export PATH="$fake_bin:$PATH"
		export AIDEVOPS_PULSE_OS_NAME=Darwin
		export LAUNCHCTL_LOG="$launchctl_log"
		_restart_pulse_if_running "$active_root/agents" true "$active_link" >"$output_file"
	)
	grep -q '^kickstart -k gui/' "$launchctl_log" || fail "enabled launchd service did not receive the restart request"
	grep -qF "$active_root/agents/scripts/pulse-wrapper.sh" "$PULSE_START_LOG" ||
		fail "launchd fixture did not start Pulse from the active bundle"
	assert_only_active_bundle_runs \
		"$active_root/agents/scripts/pulse-wrapper.sh" \
		"$TEST_ROOT/caller-worktree/.agents/scripts/pulse-wrapper.sh"
	pass "enabled launchd service remains authoritative for Pulse restart"
	return 0
}

runtime_freshness_output() {
	local manifest_file="$1"
	local update_state_file="$2"
	local canonical_repo="$3"
	local log_dir="$4"
	AIDEVOPS_RUNTIME_MANIFEST_FILE="$manifest_file" \
		AIDEVOPS_DEPLOYED_SHA_FILE="$TEST_ROOT/missing-deployed-sha" \
		AIDEVOPS_AUTO_UPDATE_STATE_FILE="$update_state_file" \
		"$REPO_ROOT/.agents/scripts/pulse-current-state-helper.sh" \
		--repo-path "$canonical_repo" --log-dir "$log_dir" --json
	return 0
}

test_protected_release_merge_freshness() {
	local remote_repo="$TEST_ROOT/protected-release-origin.git"
	local canonical_repo="$TEST_ROOT/protected-release-canonical"
	local log_dir="$TEST_ROOT/protected-release-logs"
	local manifest_file="$TEST_ROOT/protected-release-manifest"
	local update_state_file="$TEST_ROOT/protected-release-update-state.json"
	local base_sha="" release_sha="" release_tree="" merge_sha="" output=""

	git init -q --bare -b main "$remote_repo"
	git init -q -b main "$canonical_repo"
	git -C "$canonical_repo" config user.name Test
	git -C "$canonical_repo" config user.email test@example.invalid
	printf 'base\n' >"$canonical_repo/runtime.txt"
	git -C "$canonical_repo" add runtime.txt
	git -C "$canonical_repo" commit -qm base
	git -C "$canonical_repo" remote add origin "$remote_repo"
	git -C "$canonical_repo" push -qu origin main
	base_sha=$(git -C "$canonical_repo" rev-parse HEAD)
	printf 'release\n' >>"$canonical_repo/runtime.txt"
	git -C "$canonical_repo" commit -am release -q
	release_sha=$(git -C "$canonical_repo" rev-parse HEAD)
	release_tree=$(git -C "$canonical_repo" rev-parse 'HEAD^{tree}')
	merge_sha=$(printf 'protected release merge\n' | git -C "$canonical_repo" commit-tree "$release_tree" -p "$base_sha" -p "$release_sha")
	git -C "$canonical_repo" update-ref refs/heads/main "$merge_sha"
	git -C "$canonical_repo" push -q origin main
	mkdir -p "$log_dir"
	printf 'schema=1\nstatus=validated\ngit_sha=%s\n' "$release_sha" >"$manifest_file"
	printf '%s\n' '{"last_status":"up_to_date","last_timestamp":"2026-09-01T00:00:00Z"}' >"$update_state_file"

	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "current" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"signed release parent with protected-merge tree reports current"
	assert_eq "false" "$(printf '%s' "$output" | jq -r '.runtime_freshness.deployed_behind_upstream')" \
		"tree-equivalent signed release is not reported behind upstream"
	return 0
}

test_runtime_freshness_diagnostics() {
	local remote_repo="$TEST_ROOT/runtime-origin.git"
	local canonical_repo="$TEST_ROOT/runtime-canonical"
	local peer_repo="$TEST_ROOT/runtime-peer"
	local log_dir="$TEST_ROOT/runtime-logs"
	local manifest_file="$TEST_ROOT/runtime-manifest"
	local update_state_file="$TEST_ROOT/auto-update-state.json"
	local base_sha="" upstream_sha="" second_upstream_sha="" output=""

	git init -q --bare -b main "$remote_repo"
	git init -q -b main "$canonical_repo"
	git -C "$canonical_repo" config user.name Test
	git -C "$canonical_repo" config user.email test@example.invalid
	printf 'base\n' >"$canonical_repo/runtime.txt"
	git -C "$canonical_repo" add runtime.txt
	git -C "$canonical_repo" commit -qm base
	git -C "$canonical_repo" remote add origin "$remote_repo"
	git -C "$canonical_repo" push -qu origin main
	base_sha=$(git -C "$canonical_repo" rev-parse HEAD)
	git clone -q "$remote_repo" "$peer_repo"
	git -C "$peer_repo" config user.name Test
	git -C "$peer_repo" config user.email test@example.invalid
	printf 'upstream\n' >>"$peer_repo/runtime.txt"
	git -C "$peer_repo" commit -am upstream -q
	git -C "$peer_repo" push -q origin main
	upstream_sha=$(git -C "$peer_repo" rev-parse HEAD)
	git -C "$canonical_repo" fetch -q origin main
	mkdir -p "$log_dir"
	printf 'schema=1\nstatus=validated\ngit_sha=%s\n' "$base_sha" >"$manifest_file"
	printf '%s\n' '{"last_status":"up_to_date","last_timestamp":"2026-09-01T00:00:00Z"}' >"$update_state_file"

	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "canonical_behind_upstream" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"current-state reports a stale canonical checkout"

	printf 'local diagnostic\n' >>"$canonical_repo/runtime.txt"
	printf '%s\n' '{"last_status":"runtime_stale_local_changes","last_timestamp":"2026-09-01T00:01:00Z"}' >"$update_state_file"
	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "blocked_dirty_canonical" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"dirty canonical state is preserved and classified"
	git -C "$canonical_repo" checkout -q -- runtime.txt
	git -C "$canonical_repo" merge -q --ff-only "$upstream_sha"

	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "deployed_behind_canonical" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"current-state distinguishes a stale deployed bundle"
	printf 'schema=1\nstatus=validated\ngit_sha=%s\n' "$upstream_sha" >"$manifest_file"
	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "current" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"clean fast-forward and deployment report current runtime"

	local active_manifest_file="$TEST_ROOT/active-runtime-manifest"
	local deployed_sha_file="$TEST_ROOT/deployed-sha"
	printf 'schema=1\nstatus=validated\ngit_sha=%s\n' "$base_sha" >"$manifest_file"
	printf 'schema=1\nstatus=validated\ngit_sha=%s\n' "$upstream_sha" >"$active_manifest_file"
	printf '%s\n' "$upstream_sha" >"$deployed_sha_file"
	output=$(AIDEVOPS_RUNTIME_MANIFEST_FILE="$manifest_file" \
		AIDEVOPS_ACTIVE_RUNTIME_MANIFEST_FILE="$active_manifest_file" \
		AIDEVOPS_DEPLOYED_SHA_FILE="$deployed_sha_file" \
		AIDEVOPS_AUTO_UPDATE_STATE_FILE="$update_state_file" \
		"$REPO_ROOT/.agents/scripts/pulse-current-state-helper.sh" \
		--repo-path "$canonical_repo" --log-dir "$log_dir" --json)
	assert_eq "current" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"active runtime manifest plus deployed stamp overrides stale inherited manifest path"
	assert_eq "$upstream_sha" "$(printf '%s' "$output" | jq -r '.runtime_freshness.deployed_sha')" \
		"runtime freshness reports the activated deployment SHA"

	printf 'dirty at upstream tip\n' >>"$canonical_repo/runtime.txt"
	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "blocked_dirty_canonical" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"dirty upstream-tip canonical state remains blocked"
	git -C "$canonical_repo" checkout -q -- runtime.txt

	printf 'local ahead\n' >>"$canonical_repo/runtime.txt"
	git -C "$canonical_repo" commit -am local-ahead -q
	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "canonical_ahead_upstream" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"local-ahead canonical history remains stale"

	printf 'second upstream\n' >>"$peer_repo/runtime.txt"
	git -C "$peer_repo" commit -am second-upstream -q
	git -C "$peer_repo" push -q origin main
	second_upstream_sha=$(git -C "$peer_repo" rev-parse HEAD)
	git -C "$canonical_repo" fetch -q origin main
	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "canonical_diverged_upstream" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"divergent canonical history remains stale"

	git -C "$canonical_repo" checkout -q --detach "$second_upstream_sha"
	printf 'schema=1\nstatus=validated\ngit_sha=%s\n' "$second_upstream_sha" >"$manifest_file"
	output=$(runtime_freshness_output "$manifest_file" "$update_state_file" "$canonical_repo" "$log_dir")
	assert_eq "canonical_non_main" "$(printf '%s' "$output" | jq -r '.runtime_freshness.status')" \
		"detached exact-SHA canonical checkout remains stale"
	return 0
}

main() {
	local stale_root=""
	local active_root=""
	local active_link=""
	local escaped_root=""

	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	HOME="$TEST_ROOT/home"
	export HOME
	mkdir -p "$HOME/.aidevops/logs" "$TEST_ROOT/runtime-bundles"
	stale_root="$TEST_ROOT/runtime-bundles/bundle-a"
	active_root="$TEST_ROOT/runtime-bundles/bundle-b"
	write_runtime_bundle "$stale_root" "bundle-a"
	write_runtime_bundle "$active_root" "bundle-b"
	active_link="$HOME/.aidevops/agents"
	ln -s "$active_root/agents" "$active_link"

	escaped_root=$(printf '%s' "$TEST_ROOT" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
	PULSE_PATTERN="${escaped_root}/runtime-bundles/.*/agents/scripts/pulse-wrapper\\.sh"
	PULSE_START_LOG="$TEST_ROOT/pulse-starts.log"
	: >"$PULSE_START_LOG"
	export PULSE_START_LOG
	export AIDEVOPS_PULSE_PROCESS_PATTERN="$PULSE_PATTERN"
	export AIDEVOPS_PULSE_MERGE_PROCESS_PATTERN="${escaped_root}/runtime-bundles/.*/agents/scripts/pulse-merge-routine\\.sh"
	export AIDEVOPS_PULSE_RESTART_WAIT=0
	export AIDEVOPS_PULSE_SIGTERM_WAIT=1
	export AIDEVOPS_PULSE_OS_NAME=Linux
	export AIDEVOPS_RUNTIME_TRANSITION_LOCK_WAIT_SECONDS=10

	test_stale_install_dir_uses_active_bundle "$stale_root" "$active_root" "$active_link"
	test_disabled_supervisor_stays_stopped "$active_root" "$active_link"
	test_concurrent_transition_converges_on_active_bundle "$stale_root" "$active_root" "$active_link"
	test_launchd_disabled_service_stays_stopped "$active_root" "$active_link"
	test_launchd_enabled_service_owns_restart "$active_root" "$active_link"
	test_protected_release_merge_freshness
	test_runtime_freshness_diagnostics

	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
