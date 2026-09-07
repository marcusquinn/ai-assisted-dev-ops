#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_UNDER_TEST="${REPO_ROOT}/.agents/scripts/pulse-watchdog-tick.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	exit 1
	return 1
}

make_systemctl_mock() {
	local active_state="$1"
	mkdir -p "$TMP_DIR/bin"
	cat >"$TMP_DIR/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "--user" ]]; then
	exit 1
fi
case "${2:-}" in
show)
	case "${4:-}" in
	--property=LoadState)
		printf 'loaded\n'
		exit 0
		;;
	--property=ActiveState)
		printf '%s\n' "${AIDEVOPS_TEST_SYSTEMD_ACTIVE_STATE:-inactive}"
		exit 0
		;;
	esac
	;;
start)
	printf 'start %s\n' "${3:-}" >>"${AIDEVOPS_TEST_SYSTEMD_START_LOG:?}"
	exit 0
	;;
esac
exit 1
MOCK
	chmod +x "$TMP_DIR/bin/systemctl"
	export AIDEVOPS_TEST_SYSTEMD_ACTIVE_STATE="$active_state"
	return 0
}

make_lifecycle_mock() {
	local is_running_rc="$1"
	mkdir -p "$HOME/.aidevops/agents/scripts"
	cat >"$HOME/.aidevops/agents/scripts/pulse-lifecycle-helper.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
is-running)
	exit "${AIDEVOPS_TEST_LIFECYCLE_IS_RUNNING_RC:-1}"
	;;
start)
	printf 'lifecycle-start\n' >>"${AIDEVOPS_TEST_LIFECYCLE_START_LOG:?}"
	exit 0
	;;
esac
exit 2
MOCK
	chmod +x "$HOME/.aidevops/agents/scripts/pulse-lifecycle-helper.sh"
	export AIDEVOPS_TEST_LIFECYCLE_IS_RUNNING_RC="$is_running_rc"
	return 0
}

run_watchdog_case() {
	local active_state="$1"
	local is_running_rc="$2"
	HOME="$TMP_DIR/home-${active_state}-${is_running_rc}"
	export HOME
	mkdir -p "$HOME/.aidevops/logs" "$HOME/.config/aidevops"
	printf '0\n' >"$HOME/.aidevops/logs/pulse-wrapper-last-run.ts"
	printf '{"orchestration":{"pulse_interval_seconds":30}}\n' >"$HOME/.config/aidevops/settings.json"
	export AIDEVOPS_AGENTS_DIR="$HOME/.aidevops/agents"
	export AIDEVOPS_TEST_SYSTEMD_START_LOG="$HOME/systemd-start.log"
	export AIDEVOPS_TEST_LIFECYCLE_START_LOG="$HOME/lifecycle-start.log"
	: >"$AIDEVOPS_TEST_SYSTEMD_START_LOG"
	: >"$AIDEVOPS_TEST_LIFECYCLE_START_LOG"
	make_systemctl_mock "$active_state"
	make_lifecycle_mock "$is_running_rc"
	PATH="$TMP_DIR/bin:/usr/bin:/bin" AIDEVOPS_PULSE_WATCHDOG_GRACE=0 "$SCRIPT_UNDER_TEST"
	return 0
}

run_watchdog_case inactive 0
if [[ -s "$AIDEVOPS_TEST_SYSTEMD_START_LOG" ]]; then
	fail "inactive systemd unit with live lifecycle Pulse should not trigger systemd start"
fi
if grep -q 'pulse dead' "$HOME/.aidevops/logs/pulse-watchdog.log" 2>/dev/null; then
	fail "inactive systemd unit with live lifecycle Pulse should not log dead Pulse"
fi

run_watchdog_case inactive 1
if ! grep -q '^start aidevops-supervisor-pulse.service$' "$AIDEVOPS_TEST_SYSTEMD_START_LOG"; then
	fail "inactive systemd unit without a live lifecycle Pulse should trigger systemd start"
fi

printf 'PASS %s\n' "pulse watchdog tick honours live Pulse process when systemd is inactive"
