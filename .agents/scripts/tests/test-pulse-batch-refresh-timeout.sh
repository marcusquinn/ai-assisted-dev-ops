#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
PREFETCH_PARENT_PID_FILE="${TEST_ROOT}/parent.pid"
PREFETCH_CHILD_PID_FILE="${TEST_ROOT}/child.pid"
export PREFETCH_PARENT_PID_FILE PREFETCH_CHILD_PID_FILE
export LOGFILE="${TEST_ROOT}/pulse.log"

cleanup() {
	local pid=""
	for pid_file in "$PREFETCH_PARENT_PID_FILE" "$PREFETCH_CHILD_PID_FILE"; do
		if [[ -f "$pid_file" ]]; then
			pid=$(<"$pid_file")
			[[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
		fi
	done
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

cat >"${TEST_ROOT}/pulse-batch-prefetch-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$PREFETCH_PARENT_PID_FILE"
sleep 300 &
child_pid=$!
printf '%s\n' "$child_pid" >"$PREFETCH_CHILD_PID_FILE"
wait "$child_pid"
STUB
chmod +x "${TEST_ROOT}/pulse-batch-prefetch-helper.sh"

# shellcheck source=../worker-lifecycle-common.sh
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=../pulse-watchdog.sh
source "${SCRIPTS_DIR}/pulse-watchdog.sh"
SCRIPT_DIR="$TEST_ROOT"
# shellcheck source=../pulse-prefetch-workers.sh
source "${SCRIPTS_DIR}/pulse-prefetch-workers.sh"

export PULSE_BATCH_PREFETCH_TIMEOUT_SECONDS=1
started_at=$SECONDS
_prefetch_batch_refresh
elapsed=$((SECONDS - started_at))
[[ "$elapsed" -le 5 ]] || {
	printf 'batch refresh exceeded its bounded timeout: %ss\n' "$elapsed" >&2
	exit 1
}
[[ -s "$PREFETCH_PARENT_PID_FILE" && -s "$PREFETCH_CHILD_PID_FILE" ]]
parent_pid=$(<"$PREFETCH_PARENT_PID_FILE")
child_pid=$(<"$PREFETCH_CHILD_PID_FILE")
if kill -0 "$parent_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
	printf 'batch refresh timeout left a descendant alive: parent=%s child=%s\n' "$parent_pid" "$child_pid" >&2
	exit 1
fi
grep -q 'prefetch_batch_refresh timed out after 1s' "$LOGFILE"

unset -f run_cmd_with_timeout
rm -f "$PREFETCH_PARENT_PID_FILE" "$PREFETCH_CHILD_PID_FILE"
_prefetch_batch_refresh
[[ ! -e "$PREFETCH_PARENT_PID_FILE" && ! -e "$PREFETCH_CHILD_PID_FILE" ]]
grep -q 'prefetch_batch_refresh skipped: timeout helper unavailable' "$LOGFILE"

printf 'pulse batch refresh timeout test passed\n'
