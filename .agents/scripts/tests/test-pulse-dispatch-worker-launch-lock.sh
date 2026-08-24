#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression test for t3458: stale non-empty node_modules restore lock dirs
# must not spin forever in _dlw_node_modules_restore_acquire_lock.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3458-worker-launch-lock-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

lock_dir="${TEST_TMP}/worktree-node-modules-restore.lock.d"
mkdir -p "$lock_dir" || fail "failed to create lock dir"
printf '999999\n' >"${lock_dir}/pid" || fail "failed to create pid marker"

# Make the directory stale. macOS and GNU touch both support -t.
touch -t 200001010000 "$lock_dir" || fail "failed to age lock dir"

WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=1 \
	_dlw_node_modules_restore_acquire_lock "$lock_dir" || fail "lock acquire returned failure"

if [[ ! -f "${lock_dir}/pid" ]]; then
	fail "lock acquire did not recreate pid marker"
fi

_dlw_node_modules_restore_release_lock "$lock_dir"

if [[ -d "$lock_dir" ]]; then
	fail "lock release left lock dir behind"
fi

repo_dir="${TEST_TMP}/repo"
wt_dir="${TEST_TMP}/worktree"
mkdir -p "${repo_dir}/node_modules/example" "${repo_dir}/node_modules/.bin" "${repo_dir}/node_modules/prettier/bin" "${wt_dir}/node_modules" || fail "failed to create restore fixture dirs"
printf '{}\n' >"${repo_dir}/package.json" || fail "failed to create repo package.json"
printf '{}\n' >"${wt_dir}/package.json" || fail "failed to create worktree package.json"
printf 'fixture\n' >"${repo_dir}/node_modules/example/file.txt" || fail "failed to create node_modules fixture"
printf '#!/usr/bin/env bash\nprintf "fixture-tool\\n"\n' >"${repo_dir}/node_modules/prettier/bin/prettier.cjs" || fail "failed to create prettier fixture"
chmod +x "${repo_dir}/node_modules/prettier/bin/prettier.cjs" || fail "failed to make prettier fixture executable"
ln -s ../prettier/bin/prettier.cjs "${repo_dir}/node_modules/.bin/prettier" || fail "failed to create prettier bin symlink"
ln -s "${repo_dir}/node_modules/.bin" "${wt_dir}/node_modules/.bin" || fail "failed to create stale dispatcher tooling link"

LOGFILE="${TEST_TMP}/pulse.log" \
	AIDEVOPS_WORKSPACE_DIR="$TEST_TMP" \
	WORKTREE_NODE_MODULES_RESTORE_ENABLED=1 \
	WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=0 \
	WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=1 \
	_dlw_restore_worktree_deps "$wt_dir" "$repo_dir"

if [[ -d "${wt_dir}/node_modules/example" ]]; then
	fail "root node_modules payload was copied"
fi

if [[ -e "${wt_dir}/node_modules/.bin" || -L "${wt_dir}/node_modules/.bin" ]]; then
	fail "dispatcher-created canonical node_modules .bin link was not removed"
fi

if ! declare -F _dlw_append_node_tool_env >/dev/null 2>&1; then
	fail "worker launch does not provide a local command path for canonical Node tools"
fi
worker_cmd=(env)
worker_home="${TEST_TMP}/home"
mkdir -p "${worker_home}/.bun/bin" "${worker_home}/.local/bin" \
	"${worker_home}/.aidevops/bin" "${worker_home}/.aidevops/agents/scripts"
HOME="$worker_home" PATH="${worker_home}/.bun/bin:${PATH}" _dlw_append_node_tool_env "$repo_dir"
expected_tool_prefix="PATH=${repo_dir}/node_modules/.bin:${worker_home}/.bun/bin:${worker_home}/.local/bin:${worker_home}/.aidevops/bin:${worker_home}/.aidevops/agents/scripts:"
if [[ "${worker_cmd[1]:-}" != "$expected_tool_prefix"* ]]; then
	fail "worker launch did not prepend canonical Node and stable user tool directories"
fi
bun_path_count=$(printf '%s' "${worker_cmd[1]}" | tr ':' '\n' | grep -Fxc "${worker_home}/.bun/bin" || true)
if [[ "$bun_path_count" -ne 1 ]]; then
	fail "worker launch did not deduplicate the stable Bun directory"
fi
tool_output=$("${worker_cmd[@]}" prettier) || fail "dispatcher-provided Node tool did not execute"
if [[ "$tool_output" != "fixture-tool" ]]; then
	fail "dispatcher-provided Node tool returned unexpected output"
fi

_dlw_zero_output_comment_count() {
	fail "precomputed zero-output evidence count should skip comment API lookup"
	return 1
}

_dlw_zero_output_failure_count() {
	fail "precomputed zero-output evidence count should skip state lookup"
	return 1
}

if [[ "$(_dlw_zero_output_evidence_count 123 owner/repo "" 7)" != "7" ]]; then
	fail "precomputed zero-output evidence count was not returned directly"
fi

if ! grep -Fq "WORKER_GITHUB_LOGIN=\"\$self_login\"" "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"; then
	fail "pulse worker launch does not forward dispatching GitHub login"
fi

mkdir -p "${TEST_TMP}/bin" || fail "failed to create systemctl stub dir"
cat >"${TEST_TMP}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "show" ]]; then
	printf 'ActiveState=active\nSubState=running\nMainPID=4242'
	exit 0
fi
exit 1
EOF
chmod +x "${TEST_TMP}/bin/systemctl" || fail "failed to make systemctl stub executable"

resolved_pid=$(PATH="${TEST_TMP}/bin:${PATH}" LOGFILE="${TEST_TMP}/pulse.log" _dlw_systemd_resolve_main_pid "aidevops-test" "123") || fail "systemd PID resolver returned failure"
if [[ "$resolved_pid" != "4242" ]]; then
	fail "systemd PID resolver skipped final unterminated property"
fi

sleep() {
	local duration="$1"
	printf '%s\n' "$duration" >"${TEST_TMP}/sleep-duration"
	return 0
}

stability_state="${TEST_TMP}/systemd-stability-state"
stability_rc=0
if PATH="${TEST_TMP}/bin:${PATH}" LOGFILE="${TEST_TMP}/pulse.log" \
	DLW_SYSTEMD_STABILITY_ATTEMPTS=1 DLW_SYSTEMD_STABILITY_POLL_SECONDS=invalid \
	_dlw_systemd_wait_stable "aidevops-test" "123" "$stability_state" "9999"; then
	fail "systemd stability check unexpectedly accepted a mismatched PID"
else
	stability_rc=$?
fi
unset -f sleep

if [[ "$stability_rc" -ne 3 ]]; then
	fail "systemd stability check returned unexpected status ${stability_rc}"
fi
if [[ "$(<"${TEST_TMP}/sleep-duration")" != "0.2" ]]; then
	fail "invalid systemd stability poll duration did not fall back to 0.2 seconds"
fi

printf 'Unit=aidevops-test\nLaunchState=startup_failed\n' >"$stability_state"
worker_log="${TEST_TMP}/worker.log"
if LOGFILE="${TEST_TMP}/pulse.log" _dlw_handle_systemd_launch_failure 2 "$stability_state" "$worker_log" 123; then
	fail "classified systemd startup failure did not suppress fallback"
fi
expected_worker_log=$'[systemd-launch] classification=crash_during_startup\nUnit=aidevops-test\nLaunchState=startup_failed'
if [[ "$(<"$worker_log")" != "$expected_worker_log" ]]; then
	fail "systemd launch state file was not streamed intact to the worker log"
fi

is_blocked_by_unresolved() {
	local issue_body="$1"
	local repo_slug="$2"
	local issue_number="$3"
	[[ "$issue_body" == "blocked-body" && "$repo_slug" == "owner/repo" && "$issue_number" == "123" ]] || return 1
	return 0
}

EVIDENCE_LOG="${TEST_TMP}/efficiency-evidence.log"
gh_record_efficiency_evidence() {
	local name="$1"
	local value="${2:-1}"
	printf '%s=%s\n' "$name" "$value" >>"$EVIDENCE_LOG"
	return 0
}

if ! LOGFILE="${TEST_TMP}/pulse.log" _dlw_blocked_by_hard_stop "123" "owner/repo" '{"body":"blocked-body"}'; then
	fail "worker launch hard-stop did not block unresolved blocked-by dependency"
fi

: >"$EVIDENCE_LOG"
if LOGFILE="${TEST_TMP}/pulse.log" _dlw_final_dependency_attestation \
	"123" "owner/repo" '{"body":"blocked-body"}' "$repo_dir"; then
	fail "final dependency attestation accepted a newly unresolved blocker"
fi
if ! grep -q '^guardrails.stale_positive_decisions=1$' "$EVIDENCE_LOG"; then
	fail "final dependency recheck did not record stale-positive evidence"
fi

is_blocked_by_unresolved() {
	local issue_body="$1"
	local repo_slug="$2"
	local issue_number="$3"
	: "$issue_body" "$repo_slug" "$issue_number"
	return 1
}
if ! LOGFILE="${TEST_TMP}/pulse.log" _dlw_final_dependency_attestation \
	"123" "owner/repo" '{"body":"clear-body"}' "$repo_dir"; then
	fail "final dependency attestation rejected a positively clear dependency state"
fi

unset -f is_blocked_by_unresolved
if ! LOGFILE="${TEST_TMP}/pulse.log" _dlw_blocked_by_hard_stop \
	"123" "owner/repo" '{"body":"clear-body"}' "$repo_dir"; then
	fail "missing dependency verifier did not fail closed"
fi
if [[ "${_DLW_HARD_STOP_REASON:-}" != "dependency-verifier-unavailable" ]]; then
	fail "missing dependency verifier did not expose a classified hard-stop reason"
fi

: >"$EVIDENCE_LOG"
if LOGFILE="${TEST_TMP}/pulse.log" _dlw_require_dependency_attestation 0 "123" "owner/repo"; then
	fail "worker action boundary accepted a missing dependency attestation"
fi
if ! grep -q '^guardrails.dispatch_dependency_violations=1$' "$EVIDENCE_LOG"; then
	fail "missing dependency attestation did not emit violation evidence"
fi
if ! LOGFILE="${TEST_TMP}/pulse.log" _dlw_require_dependency_attestation 1 "123" "owner/repo"; then
	fail "worker action boundary rejected a valid dependency attestation"
fi

final_recheck_line=$(grep -n '_dlw_final_worker_spawn_gates.*issue_number' "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" | cut -d: -f1)
worker_spawn_line=$(grep -n 'worker_pid=.*_dlw_nohup_launch' "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" | cut -d: -f1)
if [[ ! "$final_recheck_line" =~ ^[0-9]+$ || ! "$worker_spawn_line" =~ ^[0-9]+$ \
	|| "$final_recheck_line" -ge "$worker_spawn_line" ]]; then
	fail "final dependency attestation is not immediately upstream of worker spawn"
fi

# shellcheck source=../pulse-dep-graph.sh
source "${SCRIPTS_DIR}/pulse-dep-graph.sh"

cat >"${TEST_TMP}/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${TEST_TMP}/bin/gh"

if ! LOGFILE="${TEST_TMP}/pulse-native.log" PATH="${TEST_TMP}/bin:${PATH}" is_blocked_by_unresolved 'This issue has no dependencies.' 'owner/repo' '123'; then
	fail "native blockedBy lookup failure without body markers must still block dispatch"
fi

if grep -q 'blocked_by_native_lookup_unavailable' "${TEST_TMP}/pulse-native.log" && ! grep -q 'unclassified_signal' "${TEST_TMP}/pulse-native.log"; then
	:
else
	fail "native blockedBy lookup failure should emit blocked_by_native_lookup_unavailable"
fi

cat >"${TEST_TMP}/bin/headless-runtime-helper.sh" <<'EOF'
#!/usr/bin/env bash
tier=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--tier)
		tier="${2:-}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
printf 'selected-%s\n' "$tier"
EOF
chmod +x "${TEST_TMP}/bin/headless-runtime-helper.sh" || fail "failed to make headless runtime stub executable"

_resolve_worker_tier() {
	local labels_csv="$1"
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	if [[ "$labels_with_commas" == *",tier:thinking,"* ]]; then
		printf 'tier:thinking'
	elif [[ "$labels_with_commas" == *",tier:standard,"* ]]; then
		printf 'tier:standard'
	elif [[ "$labels_with_commas" == *",tier:simple,"* ]]; then
		printf 'tier:simple'
	else
		printf 'tier:standard'
	fi
	return 0
}

bundle_repo="${TEST_TMP}/content-site"
mkdir -p "$bundle_repo" || fail "failed to create bundle repo fixture"
printf '{"bundle":"content-site"}\n' >"${bundle_repo}/.aidevops.json" || fail "failed to create bundle config fixture"

HEADLESS_RUNTIME_HELPER="${TEST_TMP}/bin/headless-runtime-helper.sh" \
	_dlw_resolve_tier_and_model '{"labels":[]}' "" "$bundle_repo"

if [[ "$_DLW_DISPATCH_TIER" != "bundle" || "$_DLW_DISPATCH_MODEL_TIER" != "simple" || "$_DLW_SELECTED_MODEL" != "selected-simple" ]]; then
	fail "bundle model default was not applied to unlabeled worker dispatch"
fi

HEADLESS_RUNTIME_HELPER="${TEST_TMP}/bin/headless-runtime-helper.sh" \
	_dlw_resolve_tier_and_model '{"labels":[{"name":"tier:thinking"}]}' "" "$bundle_repo"

if [[ "$_DLW_DISPATCH_TIER" != "thinking" || "$_DLW_DISPATCH_MODEL_TIER" != "thinking" || "$_DLW_SELECTED_MODEL" != "selected-thinking" ]]; then
	fail "explicit tier label did not override bundle model default"
fi

seo_agent=$(_dlw_bundle_agent_name "$bundle_repo" "Improve SEO metadata" "Update sitemap and schema") || fail "bundle agent routing lookup failed"
if [[ "$seo_agent" != "SEO" ]]; then
	fail "bundle agent routing did not select SEO for SEO task"
fi

codegraph_scripts_dir="${TEST_TMP}/codegraph-scripts"
codegraph_worktree="${TEST_TMP}/codegraph-worktree"
codegraph_calls="${TEST_TMP}/codegraph-calls.log"
codegraph_pulse_log="${TEST_TMP}/codegraph-pulse.log"
mkdir -p "$codegraph_scripts_dir" "$codegraph_worktree" || fail "failed to create CodeGraph dispatch fixtures"
cat >"${codegraph_scripts_dir}/codegraph-worktree-init-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CODEGRAPH_STUB_CALLS}"
exit "${CODEGRAPH_STUB_RC:-0}"
EOF
chmod +x "${codegraph_scripts_dir}/codegraph-worktree-init-helper.sh" || fail "failed to make CodeGraph dispatch stub executable"
export CODEGRAPH_STUB_CALLS="$codegraph_calls"
export CODEGRAPH_STUB_RC=7
SCRIPT_DIR="$codegraph_scripts_dir" LOGFILE="$codegraph_pulse_log" \
	_dlw_start_codegraph_init 30661 "$codegraph_worktree" || fail "CodeGraph submission failure propagated into worker dispatch"
grep -Fq 'CodeGraph init submission failed open for #30661' "$codegraph_pulse_log" || fail "CodeGraph fail-open submission was not observable"
export CODEGRAPH_STUB_RC=0
SCRIPT_DIR="$codegraph_scripts_dir" LOGFILE="$codegraph_pulse_log" \
	_dlw_start_codegraph_init 30661 "$codegraph_worktree" || fail "CodeGraph submission success returned failure"
grep -Fq "launch ${codegraph_worktree} 30661" "$codegraph_calls" || fail "worker launch did not target its own worktree for CodeGraph init"
unset CODEGRAPH_STUB_CALLS CODEGRAPH_STUB_RC

printf 'PASS: stale non-empty node_modules restore lock is reclaimed\n'
printf 'PASS: root node_modules payload is skipped by default\n'
printf 'PASS: root Node tooling uses PATH without a cross-boundary worktree link\n'
printf 'PASS: precomputed zero-output evidence count skips redundant lookups\n'
printf 'PASS: pulse worker launch forwards dispatching GitHub login\n'
printf 'PASS: systemd PID resolver handles final unterminated property\n'
printf 'PASS: systemd stability poll duration rejects invalid configuration\n'
printf 'PASS: systemd launch state streams intact to the worker log\n'
printf 'PASS: worker launch hard-stops unresolved blocked-by dependencies\n'
printf 'PASS: final dependency recheck records stale-positive evidence\n'
printf 'PASS: final dependency attestation accepts only positively clear state\n'
printf 'PASS: missing dependency verifier fails closed with a classified reason\n'
printf 'PASS: unverified worker action boundary emits dependency-violation evidence\n'
printf 'PASS: final dependency attestation remains upstream of worker spawn\n'
printf 'PASS: native blockedBy lookup failure remains fail-closed with classified reason\n'
printf 'PASS: bundle defaults route unlabeled worker model selection\n'
printf 'PASS: explicit tier labels override bundle model defaults\n'
printf 'PASS: bundle agent_routing selects task-specific worker agents\n'
printf 'PASS: CodeGraph submission is worktree-local and fail-open\n'
exit 0
