#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../github-runner-broker-health-helper.sh"
SANDBOX="$(mktemp -d -t broker-health-test-XXXXXX)"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$SANDBOX"
	return 0
}
trap cleanup EXIT

result() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS: %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

write_jobs() {
	local path="$1"
	local moving="$2"
	local count="$3"
	if [[ "$count" -eq 0 ]]; then
		printf '{"queue_moving":%s,"jobs":[]}\n' "$moving" >"$path"
	else
		printf '{"queue_moving":%s,"jobs":[{"id":101,"status":"queued","labels":["self-hosted","Linux","X64","dind"],"runner_id":0,"runner_name":"","created_at":"2026-09-04T00:00:00Z"}]}\n' "$moving" >"$path"
	fi
	return 0
}

write_extra_label_job() {
	local path="$1"
	local fixture='{"queue_moving":false,"jobs":[{"id":101,"status":"queued","labels":["self-hosted","Linux","X64","dind","gpu"],"runner_id":0,"runner_name":"","created_at":"2026-09-04T00:00:00Z"}]}'
	printf '%s\n' "$fixture" >"$path"
	return 0
}

write_runners() {
	local path="$1"
	local busy="$2"
	local id="$3"
	printf '{"runners":[{"id":%s,"name":"runner-1","status":"online","busy":%s,"labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"X64"},{"name":"dind"}]}]}\n' "$id" "$busy" >"$path"
	return 0
}

write_local() {
	local path="$1"
	printf '{"runners":[{"name":"runner-1","service":"runner@1.service","active":true,"listener":true}]}\n' >"$path"
	return 0
}

run_finding() {
	local command="$1"
	local output=""
	output=$(bash "$HELPER" "$command" --json 2>/dev/null || true)
	printf '%s' "$output" | jq -r '.finding'
	return 0
}

write_live_command_stubs() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
endpoint=""
saw_slurp=0
saw_jq=0
for argument in "$@"; do
	endpoint="$argument"
	[[ "$argument" == "--slurp" ]] && saw_slurp=1
	[[ "$argument" == "--jq" ]] && saw_jq=1
done
[[ "$saw_slurp" -eq 1 && "$saw_jq" -eq 1 ]] && exit 2
case "$endpoint" in
*status=queued*) printf '%s\n' '[{"workflow_runs":[{"id":7}]},{"workflow_runs":[]}]' ;;
*status=in_progress*) printf '%s\n' '[{"workflow_runs":[]}]' ;;
*/jobs*) printf '%s\n' '[{"jobs":[{"id":101,"status":"queued","labels":["self-hosted","Linux","X64","dind"],"runner_id":0,"runner_name":"","created_at":"2026-09-04T00:00:00Z"}]},{"jobs":[]}]' ;;
*/runners*) printf '%s\n' '[{"runners":[{"id":11,"name":"github-runner-dind-1","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"X64"},{"name":"dind"}]}]},{"runners":[]}]' ;;
*) exit 1 ;;
esac
EOF
	cat >"${bin_dir}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'github-runner-dind@1.service loaded active running runner'
EOF
	chmod +x "${bin_dir}/gh" "${bin_dir}/systemctl"
	return 0
}

export BROKER_HEALTH_TEST_NOW_EPOCH=1788483600
export BROKER_HEALTH_QUEUE_AGE_SECONDS=900
export BROKER_HEALTH_VERIFY_DELAY_SECONDS=0
export BROKER_HEALTH_COOLDOWN_SECONDS=1800
export BROKER_HEALTH_CACHE_DIR="$SANDBOX/cache"
export BROKER_HEALTH_STATE_FILE="$BROKER_HEALTH_CACHE_DIR/state.json"
export BROKER_HEALTH_LOCK_DIR="$BROKER_HEALTH_CACHE_DIR/lock"
export BROKER_HEALTH_JOBS_FILE="$SANDBOX/jobs.json"
export BROKER_HEALTH_RUNNERS_FILE="$SANDBOX/runners.json"
export BROKER_HEALTH_LOCAL_FILE="$SANDBOX/local.json"
export BROKER_HEALTH_POST_JOBS_FILE="$SANDBOX/post-jobs.json"
export BROKER_HEALTH_POST_RUNNERS_FILE="$SANDBOX/post-runners.json"
export BROKER_HEALTH_POST_LOCAL_FILE="$SANDBOX/post-local.json"

write_local "$BROKER_HEALTH_LOCAL_FILE"
write_local "$BROKER_HEALTH_POST_LOCAL_FILE"
write_jobs "$BROKER_HEALTH_JOBS_FILE" false 1
write_jobs "$BROKER_HEALTH_POST_JOBS_FILE" false 0
write_runners "$BROKER_HEALTH_RUNNERS_FILE" false 11
write_runners "$BROKER_HEALTH_POST_RUNNERS_FILE" false 22

result "incident fixture is stale broker" "STALE_BROKER_SUSPECTED" "$(run_finding diagnose)"

write_extra_label_job "$BROKER_HEALTH_JOBS_FILE"
result "extra required job label is not compatible" "NO_MATCHING_RUNNER" "$(run_finding diagnose)"
write_jobs "$BROKER_HEALTH_JOBS_FILE" false 1

STUB_BIN="$SANDBOX/bin"
write_live_command_stubs "$STUB_BIN"
PATH_BACKUP="$PATH"
export PATH="$STUB_BIN:$PATH"
export BROKER_HEALTH_REPO="owner/repo"
unset BROKER_HEALTH_JOBS_FILE BROKER_HEALTH_RUNNERS_FILE BROKER_HEALTH_LOCAL_FILE
result "live paginated CLI response is normalized" "STALE_BROKER_SUSPECTED" "$(run_finding diagnose)"
export PATH="$PATH_BACKUP"
export BROKER_HEALTH_JOBS_FILE="$SANDBOX/jobs.json"
export BROKER_HEALTH_RUNNERS_FILE="$SANDBOX/runners.json"
export BROKER_HEALTH_LOCAL_FILE="$SANDBOX/local.json"

write_runners "$BROKER_HEALTH_RUNNERS_FILE" true 11
result "all busy is capacity pressure" "BUSY_CAPACITY" "$(run_finding diagnose)"
write_runners "$BROKER_HEALTH_RUNNERS_FILE" false 11

printf '{"runners":[]}\n' >"$BROKER_HEALTH_RUNNERS_FILE"
result "empty runner inventory is non-recoverable" "NO_MATCHING_RUNNER" "$(run_finding diagnose)"
write_runners "$BROKER_HEALTH_RUNNERS_FILE" false 11

mkdir -p "$BROKER_HEALTH_LOCK_DIR"
result "lock contention blocks repair" "LOCKED" "$(run_finding repair)"
rmdir "$BROKER_HEALTH_LOCK_DIR"

RESTART_LOG="$SANDBOX/restarts.log"
export RESTART_LOG
RESTART_ADAPTER="$SANDBOX/restart-adapter.sh"
cat >"$RESTART_ADAPTER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate="${1:-}"
printf '%s\n' "$candidate" >>"$RESTART_LOG"
EOF
chmod +x "$RESTART_ADAPTER"
export BROKER_HEALTH_RESTART_ADAPTER="$RESTART_ADAPTER"

result "one-runner canary recovers" "RECOVERED" "$(run_finding repair)"
result "exactly one runner restarted" "1" "$(wc -l <"$RESTART_LOG" | tr -d ' ')"
result "cooldown prevents repeat" "COOLDOWN" "$(run_finding repair)"
result "cooldown does not restart" "1" "$(wc -l <"$RESTART_LOG" | tr -d ' ')"

rm -f "$BROKER_HEALTH_STATE_FILE"
write_runners "$BROKER_HEALTH_POST_RUNNERS_FILE" false 11
result "unchanged registration fails canary" "FAILED_CANARY" "$(run_finding repair)"
result "failed canary stops after one" "2" "$(wc -l <"$RESTART_LOG" | tr -d ' ')"

printf 'Tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
