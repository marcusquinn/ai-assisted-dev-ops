#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCHEDULERS_PULSE="$REPO_ROOT/.agents/scripts/setup/modules/schedulers-pulse.sh"
SCHEDULERS_PLATFORM="$REPO_ROOT/.agents/scripts/setup/modules/schedulers-platform.sh"
TEST_ROOT=""
TESTS_RUN=0

# shellcheck source=../pulse-runtime-pin.sh
source "$REPO_ROOT/.agents/scripts/pulse-runtime-pin.sh"

cleanup() {
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

write_bundle() {
	local bundle_id="$1"
	local agents_root="$HOME/.aidevops/runtime-bundles/$bundle_id/agents"
	local entrypoint=""
	mkdir -p "$agents_root/scripts"
	for entrypoint in \
		pulse-wrapper.sh \
		pulse-lifecycle-helper.sh \
		pulse-merge-routine.sh \
		pulse-merge-webhook-receiver.sh; do
		cat >"$agents_root/scripts/$entrypoint" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$0" "$*" >>"${PULSE_PIN_EXEC_LOG:?}"
SH
	done
	cat >"$agents_root/scripts/pulse-runtime-pin.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$agents_root/scripts/"*.sh
	printf 'schema=1\nstatus=validated\nbundle_id=%s\n' "$bundle_id" >"$agents_root/.bundle-manifest"
	(cd "$agents_root" && pwd -P)
	return 0
}

test_set_resolve_and_guarded_clear() {
	local agents_root="$1"
	local now=""
	local resolved=""
	local config_path=""
	local clear_output=""
	local rc=0
	now=$(date +%s)
	pulse_runtime_pin_set "$agents_root" "$((now + 600))" || fail "valid runtime pin was rejected"
	resolved=$(pulse_runtime_pin_resolve) || fail "valid runtime pin did not resolve"
	[[ "$resolved" == "$agents_root" ]] || fail "runtime pin resolved the wrong bundle"
	config_path=$(pulse_runtime_pin_config_path)
	[[ "$(_pulse_runtime_pin_stat_value '%Lp' '%a' "$config_path")" == "600" ]] || fail "runtime pin is not mode 600"
	clear_output=$(bash "$REPO_ROOT/.agents/scripts/pulse-runtime-pin.sh" clear 2>&1) || rc=$?
	[[ "$rc" -eq 4 ]] || fail "ordinary clear did not reject an active runtime pin"
	[[ -e "$config_path" ]] || fail "ordinary clear removed an active runtime pin"
	[[ "$clear_output" == *"refusing to clear without --force"* ]] || fail "active-pin refusal omitted the explicit override guidance"
	bash "$REPO_ROOT/.agents/scripts/pulse-runtime-pin.sh" clear --force >/dev/null || fail "forced runtime pin clear failed"
	[[ ! -e "$config_path" ]] || fail "forced runtime pin clear left its config behind"
	pulse_runtime_pin_clear || fail "missing runtime pin clear was not idempotent"
	pass "valid runtime pin resolves privately and requires an explicit clear override"
	return 0
}

test_expired_pin_clears_without_force() {
	local agents_root="$1"
	local config_path=""
	local now=""
	config_path=$(pulse_runtime_pin_config_path)
	now=$(date +%s)
	mkdir -p "${config_path%/*}"
	printf 'schema=1\nagents_root=%s\ncreated_epoch=%s\nexpires_epoch=%s\n' \
		"$agents_root" "$((now - 120))" "$((now - 60))" >"$config_path"
	chmod 600 "$config_path"
	bash "$REPO_ROOT/.agents/scripts/pulse-runtime-pin.sh" clear >/dev/null || fail "expired runtime pin did not clear without force"
	[[ ! -e "$config_path" ]] || fail "expired runtime pin clear left its config behind"
	pass "expired runtime pin cleanup remains idempotent without force"
	return 0
}

test_pin_mutations_respect_live_lock() {
	local agents_root="$1"
	local config_path=""
	local lock_dir=""
	local now=""
	local rc=0
	now=$(date +%s)
	pulse_runtime_pin_set "$agents_root" "$((now + 600))" || fail "lock fixture could not set a runtime pin"
	config_path=$(pulse_runtime_pin_config_path)
	lock_dir="${config_path}.lock.d"
	mkdir "$lock_dir" || fail "could not create the live mutation lock fixture"
	printf '%s\n' "$$" >"$lock_dir/pid"
	(
		AIDEVOPS_PULSE_RUNTIME_PIN_LOCK_WAIT_SECONDS=0
		export AIDEVOPS_PULSE_RUNTIME_PIN_LOCK_WAIT_SECONDS
		pulse_runtime_pin_clear --force
	) >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 1 ]] || fail "forced clear bypassed a live runtime pin mutation lock"
	[[ -e "$config_path" ]] || fail "lock contention removed the protected runtime pin"
	rm -f "$lock_dir/pid"
	rmdir "$lock_dir"
	mkdir "$lock_dir" || fail "could not create the stale mutation lock fixture"
	printf '%s\n' '99999999' >"$lock_dir/pid"
	pulse_runtime_pin_clear --force || fail "runtime pin clear did not reclaim a stale mutation lock"
	[[ ! -e "$config_path" ]] || fail "stale-lock recovery left the runtime pin behind"
	[[ ! -d "$lock_dir" ]] || fail "stale-lock recovery left the mutation lock behind"
	pass "runtime pin mutations serialize across live sessions and reclaim stale locks"
	return 0
}

test_rejects_unsafe_and_expired_configs() {
	local agents_root="$1"
	local outside_root="$TEST_ROOT/outside/agents"
	local config_path=""
	local now=""
	local rc=0
	mkdir -p "$outside_root/scripts"
	printf '#!/usr/bin/env bash\n' >"$outside_root/scripts/pulse-wrapper.sh"
	chmod +x "$outside_root/scripts/pulse-wrapper.sh"
	printf 'status=validated\nbundle_id=outside\n' >"$outside_root/.bundle-manifest"
	now=$(date +%s)
	pulse_runtime_pin_set "$outside_root" "$((now + 600))" >/dev/null 2>&1 && fail "outside runtime root was accepted"
	config_path=$(pulse_runtime_pin_config_path)
	mkdir -p "${config_path%/*}"
	printf 'schema=1\nagents_root=%s\ncreated_epoch=%s\nexpires_epoch=%s\n' \
		"$agents_root" "$((now - 120))" "$((now - 60))" >"$config_path"
	chmod 600 "$config_path"
	pulse_runtime_pin_resolve >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 3 ]] || fail "expired pin did not return the expiry status"
	chmod 644 "$config_path"
	rc=0
	pulse_runtime_pin_resolve >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 2 ]] || fail "publicly readable pin did not fail validation"
	printf 'schema=1\nagents_root=%s\ncreated_epoch=%s\nexpires_epoch=%s\n' \
		"$agents_root" "$now" "$((now + _PULSE_RUNTIME_PIN_MAX_SECONDS + 1))" >"$config_path"
	chmod 600 "$config_path"
	rc=0
	pulse_runtime_pin_resolve >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 2 ]] || fail "overlong pin config bypassed the bounded TTL"
	rm -f "$config_path"
	printf 'schema=1\nagents_root=%s\ncreated_epoch=%s\nexpires_epoch=%s\n' \
		"$agents_root" "$now" "$((now + 600))" >"$TEST_ROOT/pin-target.conf"
	chmod 600 "$TEST_ROOT/pin-target.conf"
	ln -s "$TEST_ROOT/pin-target.conf" "$config_path"
	rc=0
	pulse_runtime_pin_resolve >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 2 ]] || fail "symlinked pin config was accepted"
	pulse_runtime_pin_clear --force
	pass "unsafe and expired runtime pin configs fail closed"
	return 0
}

test_direct_entrypoints_reexec_pinned_bundle() {
	local agents_root="$1"
	local now=""
	local exec_log="$TEST_ROOT/pin-exec.log"
	now=$(date +%s)
	pulse_runtime_pin_set "$agents_root" "$((now + 600))"
	PULSE_PIN_EXEC_LOG="$exec_log" bash "$REPO_ROOT/.agents/scripts/pulse-wrapper.sh" --self-check
	PULSE_PIN_EXEC_LOG="$exec_log" bash "$REPO_ROOT/.agents/scripts/pulse-lifecycle-helper.sh" status
	PULSE_PIN_EXEC_LOG="$exec_log" bash "$REPO_ROOT/.agents/scripts/pulse-merge-routine.sh" --help
	PULSE_PIN_EXEC_LOG="$exec_log" bash "$REPO_ROOT/.agents/scripts/pulse-merge-webhook-receiver.sh" --check
	grep -qF "$agents_root/scripts/pulse-wrapper.sh|--self-check" "$exec_log" || fail "stable wrapper did not re-enter the pinned bundle"
	grep -qF "$agents_root/scripts/pulse-lifecycle-helper.sh|status" "$exec_log" || fail "lifecycle helper did not re-enter the pinned bundle"
	grep -qF "$agents_root/scripts/pulse-merge-routine.sh|--help" "$exec_log" || fail "standalone merge routine did not re-enter the pinned bundle"
	grep -qF "$agents_root/scripts/pulse-merge-webhook-receiver.sh|--check" "$exec_log" || fail "webhook receiver did not re-enter the pinned bundle"
	pulse_runtime_pin_clear --force
	pass "all direct Pulse entrypoints re-enter an active pinned bundle"
	return 0
}

test_invalid_pin_blocks_direct_entrypoint() {
	local agents_root="$1"
	local now=""
	local config_path=""
	local clear_output=""
	local rc=0
	now=$(date +%s)
	config_path=$(pulse_runtime_pin_config_path)
	mkdir -p "${config_path%/*}"
	printf 'schema=1\nagents_root=%s\ncreated_epoch=%s\nexpires_epoch=%s\n' \
		"$agents_root" "$now" "$((now + 600))" >"$config_path"
	chmod 644 "$config_path"
	PULSE_PIN_EXEC_LOG="$TEST_ROOT/invalid-exec.log" bash "$REPO_ROOT/.agents/scripts/pulse-wrapper.sh" --self-check >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 2 ]] || fail "invalid pin did not block the stable Pulse entrypoint"
	[[ ! -e "$TEST_ROOT/invalid-exec.log" ]] || fail "invalid pin executed a Pulse runtime"
	rc=0
	clear_output=$(bash "$REPO_ROOT/.agents/scripts/pulse-runtime-pin.sh" clear 2>&1) || rc=$?
	[[ "$rc" -eq 2 ]] || fail "ordinary clear did not reject an invalid runtime pin"
	[[ -e "$config_path" ]] || fail "ordinary clear removed an invalid runtime pin"
	[[ "$clear_output" == *"invalid; refusing to clear without --force"* ]] || fail "invalid-pin refusal omitted the explicit override guidance"
	pulse_runtime_pin_clear --force
	pass "invalid runtime pin blocks entrypoints and ordinary clear"
	return 0
}

test_set_current_rejects_overlong_ttl() {
	local agents_root="$1"
	if AIDEVOPS_ACTIVE_AGENTS_LINK="$agents_root" pulse_runtime_pin_set_current "$((_PULSE_RUNTIME_PIN_MAX_SECONDS + 1))" >/dev/null 2>&1; then
		fail "set-current accepted a TTL above the hard maximum"
	fi
	pass "set-current enforces the bounded TTL"
	return 0
}

test_active_pin_preserves_installed_scheduler() {
	local rc=0
	# shellcheck source=../setup/modules/schedulers-pulse.sh
	source "$SCHEDULERS_PULSE"
	(
		pulse_runtime_pin_resolve() { printf '%s\n' '/validated/pinned/agents'; return 0; }
		_pulse_runtime_pin_preserves_scheduler true
	) || fail "installed scheduler was not preserved for an active pin"
	if (
		pulse_runtime_pin_resolve() { return 1; }
		_pulse_runtime_pin_preserves_scheduler true
	); then
		fail "scheduler was preserved without an active pin"
	fi
	if (
		pulse_runtime_pin_resolve() { printf '%s\n' '/validated/pinned/agents'; return 0; }
		_pulse_runtime_pin_preserves_scheduler false
	); then
		fail "missing scheduler was treated as preservable"
	fi
	if (
		AIDEVOPS_PULSE_RUNTIME_PIN_REFRESH_SCHEDULERS=1
		export AIDEVOPS_PULSE_RUNTIME_PIN_REFRESH_SCHEDULERS
		pulse_runtime_pin_resolve() { printf '%s\n' '/validated/pinned/agents'; return 0; }
		_pulse_runtime_pin_preserves_scheduler true
	); then
		fail "explicit controlled scheduler refresh was ignored"
	fi
	(
		pulse_runtime_pin_resolve() { return 2; }
		_pulse_runtime_pin_preserves_scheduler true
	) || rc=$?
	[[ "$rc" -eq 2 ]] || fail "invalid pin was treated as an inactive scheduler pin"
	pass "scheduler preservation requires both an installation and an active pin"
	return 0
}

test_active_pin_preserves_merge_scheduler() {
	# shellcheck source=../setup/modules/schedulers-platform.sh
	source "$SCHEDULERS_PLATFORM"
	(
		_launchd_has_agent() { return 0; }
		_pulse_runtime_pin_preserves_scheduler() { local installed="$1"; [[ "$installed" == "true" ]] || return 1; return 0; }
		print_info() { local message="$1"; : "$message"; return 0; }
		print_error() { local message="$1"; : "$message"; return 0; }
		setup_pulse_merge_routine
	) || fail "active pin did not preserve the installed merge scheduler"
	if (
		_launchd_has_agent() { return 0; }
		_pulse_runtime_pin_preserves_scheduler() { local installed="$1"; : "$installed"; return 2; }
		print_info() { local message="$1"; : "$message"; return 0; }
		print_error() { local message="$1"; : "$message"; return 0; }
		setup_pulse_merge_routine
	); then
		fail "invalid pin did not block merge scheduler reconciliation"
	fi
	pass "active pin preserves the standalone merge scheduler"
	return 0
}

main() {
	local agents_root=""
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	HOME="$TEST_ROOT/home"
	export HOME
	agents_root=$(write_bundle "bundle-pinned")
	ln -s "$agents_root" "$HOME/.aidevops/agents"
	test_set_resolve_and_guarded_clear "$agents_root"
	test_expired_pin_clears_without_force "$agents_root"
	test_pin_mutations_respect_live_lock "$agents_root"
	test_rejects_unsafe_and_expired_configs "$agents_root"
	test_direct_entrypoints_reexec_pinned_bundle "$agents_root"
	test_invalid_pin_blocks_direct_entrypoint "$agents_root"
	test_set_current_rejects_overlong_ttl "$agents_root"
	test_active_pin_preserves_installed_scheduler
	test_active_pin_preserves_merge_scheduler
	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
