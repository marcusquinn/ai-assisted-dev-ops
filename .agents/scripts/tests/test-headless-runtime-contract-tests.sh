#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Contract, private-workload, timeout, and model-routing tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_CONTRACT_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_CONTRACT_TESTS_LOADED=1

test_appends_escalation_contract() {
	local prompt='/full-loop Implement issue #14964'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'HEADLESS_CONTINUATION_CONTRACT_V9'* ]] &&
		[[ "$output" == *'Read the issue body FIRST'* ]] &&
		[[ "$output" == *'Look for a "Worker Guidance" or "How" section'* ]] &&
		[[ "$output" == *'do bounded discovery instead of stopping'* ]] &&
		[[ "$output" == *'Auto-generated "Unactioned Review Feedback" / quality-debt issues are not missing context solely because they lack file paths'* ]] &&
		[[ "$output" == *'Exit BLOCKED with reason "missing implementation context" only after bounded discovery'* ]] &&
		[[ "$output" == *'Worktree edit verification (GH#22816)'* ]] &&
		[[ "$output" == *'Incremental WIP commits (GH#23677)'* ]] &&
		[[ "$output" == *'A first WIP commit makes the worktree cleanup-visible as active real work even before a PR exists'* ]] &&
		[[ "$output" == *'Progressive context loading'* ]] &&
		[[ "$output" == *'Load only referenced workflow/reference docs'* ]] &&
		[[ "$output" == *'Stop reading once target files, reference pattern, constraints, and verification are clear.'* ]] &&
		[[ "$output" == *'Never ask for user confirmation, approval, or next steps. No user will respond.'* ]] &&
		[[ "$output" == *'emit POST_PR_HANDOFF on its own line'* ]] &&
		[[ "$output" == *'Valid exit states are FULL_LOOP_COMPLETE, POST_PR_HANDOFF'* ]]; then
		print_result "appends escalation-before-blocked contract to full-loop prompts" 0
		return 0
	fi

	print_result "appends escalation-before-blocked contract to full-loop prompts" 1 "Output missing required contract clauses"
	return 0
}

test_non_full_loop_prompt_unchanged() {
	local prompt='Review this file only'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "leaves non-full-loop prompt unchanged" 0
		return 0
	fi

	print_result "leaves non-full-loop prompt unchanged" 1 "Prompt was unexpectedly modified"
	return 0
}

test_headless_contract_uses_deployed_framework_paths() {
	local AIDEVOPS_HEADLESS_APPEND_CONTRACT
	AIDEVOPS_HEADLESS_APPEND_CONTRACT=1
	local prompt
	prompt='/full-loop Implement issue #24354'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'Normal project repos: full-loop workflow is deployed at ~/.aidevops/agents/scripts/commands/full-loop.md'* ]] &&
		[[ "$output" == *'Normal project repos: aidevops framework scripts live under ~/.aidevops/agents/scripts/ (not project-local .agents/scripts/)'* ]] &&
		[[ "$output" == *'Aidevops source repo only: the same files are edited at .agents/scripts/commands/full-loop.md and under .agents/scripts/'* ]] &&
		[[ "$output" != *'- Full-loop workflow: .agents/scripts/commands/full-loop.md'* ]] &&
		[[ "$output" != *'- All agent scripts live under .agents/scripts/ (not scripts/ at root)'* ]]; then
		print_result "headless contract uses deployed framework paths for project repos" 0
		return 0
	fi

	print_result "headless contract uses deployed framework paths for project repos" 1 \
		"Output still contains ambiguous source-repo framework path guidance"
	return 0
}

test_parse_initial_model_does_not_set_explicit_override() {
	local role="worker" session_key="issue-22862" work_dir="$TEST_ROOT" title="Issue #22862" prompt="/full-loop test" prompt_file=""
	local model_override="" initial_model="" tier_override="" variant_override="" agent_name="" headless_runtime="" detach=0
	local -a extra_args=()

	_parse_run_args --initial-model openai/gpt-5.5 --tier standard --opencode-arg --print-logs

	if [[ "$initial_model" == "openai/gpt-5.5" && -z "$model_override" && "$tier_override" == "standard" ]]; then
		print_result "--initial-model does not set explicit model override" 0
		return 0
	fi

	print_result "--initial-model does not set explicit model override" 1 \
		"initial_model=${initial_model:-<empty>} model_override=${model_override:-<empty>} tier=${tier_override:-<empty>}"
	return 0
}

test_launch_helpers_tolerate_unset_state_under_nounset() {
	local status=0
	(
		unset _HEADLESS_RUNTIME_TEMP_PATHS
		_cleanup_headless_runtime_temp_paths
	) || status=$?

	if [[ "$status" -eq 0 ]]; then
		print_result "launch temp cleanup tolerates unset state under nounset" 0
	else
		print_result "launch temp cleanup tolerates unset state under nounset" 1 "status=$status"
	fi

	local err_out=""
	status=0
	err_out=$(
		unset session_key work_dir title prompt prompt_file
		_validate_run_args 2>&1
	) || status=$?

	if [[ "$status" -eq 1 && "$err_out" == *"run requires --session-key"* ]]; then
		print_result "launch argument validation reports missing caller state under nounset" 0
		return 0
	fi

	print_result "launch argument validation reports missing caller state under nounset" 1 \
		"status=$status output=${err_out:-<empty>}"
	return 0
}

runtime_temp_test_mode() {
	local path="$1"
	if stat -f '%Lp' "$path" >/dev/null 2>&1; then
		stat -f '%Lp' "$path"
		return 0
	fi
	stat -c '%a' "$path"
	return 0
}

test_runtime_temp_files_bypass_group_writable_workspace() {
	local workspace_root="${HOME}/.aidevops/.agent-workspace"
	local detail=""
	mkdir -p "${workspace_root}/tmp"
	chmod 775 "$workspace_root"
	chmod 700 "${workspace_root}/tmp"

	if detail=$(
		unset AIDEVOPS_SENSITIVE_TEMP_DIR
		export AIDEVOPS_TEMP_DIR="${workspace_root}/tmp"
		local temp_file="" sensitive_root=""
		temp_file=$(_create_headless_runtime_temp_file) || exit 1
		sensitive_root=$(aidevops_sensitive_temp_root) || exit 1
		[[ "$temp_file" == "${sensitive_root}/"* && -f "$temp_file" ]] || exit 2
		[[ "$sensitive_root" != "${workspace_root}/"* ]] || exit 3
		[[ "$(runtime_temp_test_mode "$sensitive_root")" == "700" ]] || exit 4
		[[ "$(runtime_temp_test_mode "$temp_file")" == "600" ]] || exit 5
		rm -f "$temp_file"
		printf 'root=%s workspace_mode=%s\n' "$sensitive_root" "$(runtime_temp_test_mode "$workspace_root")"
	); then
		print_result "runtime temp creation bypasses a group-writable aidevops workspace" 0
		return 0
	fi

	print_result "runtime temp creation bypasses a group-writable aidevops workspace" 1 \
		"${detail:-Could not create a private runtime temp file}"
	return 0
}

test_sensitive_temp_preflight_aborts_before_worker_ownership() {
	local unsafe_parent="${TEST_ROOT}/unsafe-sensitive-parent"
	local ownership_marker="${TEST_ROOT}/ownership-called"
	local detail=""
	mkdir -p "$unsafe_parent"
	chmod 777 "$unsafe_parent"

	detail=$(
		exec 2>&1
		export AIDEVOPS_SENSITIVE_TEMP_DIR="${unsafe_parent}/nested"
		_acquire_session_lock() { return 0; }
		_exit_trap_handler() { return 0; }
		aidevops_runtime_bundle_lease_release() { return 0; }
		_hrw_verify_dispatch_ownership() {
			: >"$ownership_marker"
			return 0
		}
		_hrw_claim_worker_worktree() {
			: >"$ownership_marker"
			return 0
		}
		local prepare_status=0
		_cmd_run_prepare "issue-28796" "$TEST_ROOT" "worker" || prepare_status=$?
		printf 'status=%s reason=%s launch_started=%s\n' \
			"$prepare_status" "${_WORKER_PRELAUNCH_FAILURE_REASON:-}" \
			"${_WORKER_RUNTIME_LAUNCH_STARTED:-}"
	)

	if [[ "$detail" == *"status=86 reason=worker_sensitive_temp_preflight_failed launch_started=0"* && \
		"$detail" == *"[sensitive-temp] rejected component="* && \
		"$detail" == *" owner_uid="* && "$detail" == *" mode="* && \
		! -e "$ownership_marker" ]]; then
		print_result "sensitive-temp preflight aborts before worker ownership or runtime launch" 0
		return 0
	fi

	print_result "sensitive-temp preflight aborts before worker ownership or runtime launch" 1 \
		"detail=${detail:-<empty>} ownership_called=$([[ -e "$ownership_marker" ]] && printf yes || printf no)"
	return 0
}

test_headless_temp_initialization_preserves_process_scratch() {
	local TMPDIR="/host/tmpdir"
	local TMP="/host/tmp"
	local TEMP="/host/temp"
	local AIDEVOPS_WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace"
	local expected=""

	aidevops_init_temp_workspace || {
		print_result "headless initialization preserves process scratch" 1 "Could not initialize managed temp workspace"
		return 0
	}
	expected=$(cd "$AIDEVOPS_WORKSPACE_DIR/tmp" && pwd -P)

	if [[ "$TMPDIR" == "/host/tmpdir" && "$TMP" == "/host/tmp" && "$TEMP" == "/host/temp" ]] &&
		[[ "$AIDEVOPS_TEMP_DIR" == "$expected" ]] &&
		grep -q 'aidevops_init_temp_workspace' "$HELPER_SCRIPT"; then
		print_result "headless initialization preserves process scratch" 0
		return 0
	fi

	print_result "headless initialization preserves process scratch" 1 \
		"TMPDIR=$TMPDIR TMP=$TMP TEMP=$TEMP AIDEVOPS_TEMP_DIR=${AIDEVOPS_TEMP_DIR:-<unset>}"
	return 0
}

setup_private_workload_profile_fixture() {
	local work_dir="$1"
	mkdir -p "${work_dir}/.opencode/tool"
	chmod 700 "$work_dir" "${work_dir}/.opencode" "${work_dir}/.opencode/tool"
	printf '%s\n' '{}' >"${work_dir}/jobs.jsonl"
	: >"${work_dir}/fetch-audit.jsonl"
	: >"${work_dir}/results.pending.jsonl"
	printf '%s\n' 'Private workload instructions.' >"${work_dir}/instructions.md"
	printf '%s\n' 'export default {};' >"${work_dir}/.opencode/tool/provisional_fetch.ts"
	printf '%s\n' 'export default {};' >"${work_dir}/.opencode/tool/provisional_submit.ts"
	cat >"${work_dir}/.opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "default_agent": "provisional-adjudicator",
  "enabled_providers": ["openai"],
  "formatter": false,
  "instructions": ["instructions.md"],
  "lsp": false,
  "model": "openai/gpt-5.6-sol",
  "share": "disabled",
  "snapshot": false,
  "agent": {
    "provisional-adjudicator": {
      "description": "Adjudicates one protected award batch through fixed, capability-restricted tools.",
      "mode": "primary",
      "model": "openai/gpt-5.6-sol",
      "permission": {
        "*": "deny",
        "bash": "deny",
        "edit": "deny",
        "external_directory": "deny",
        "glob": "deny",
        "grep": "deny",
        "list": "deny",
        "lsp": "deny",
        "provisional_fetch": "allow",
        "provisional_submit": "allow",
        "question": "deny",
        "read": "deny",
        "skill": "deny",
        "task": "deny",
        "todowrite": "deny",
        "webfetch": "deny",
        "websearch": "deny"
      },
      "steps": 12
    }
  }
}
EOF
	chmod 600 "${work_dir}/fetch-audit.jsonl" \
		"${work_dir}/instructions.md" \
		"${work_dir}/jobs.jsonl" \
		"${work_dir}/results.pending.jsonl" \
		"${work_dir}/.opencode/opencode.json" \
		"${work_dir}/.opencode/tool/provisional_fetch.ts" \
		"${work_dir}/.opencode/tool/provisional_submit.ts"
	return 0
}

private_workload_profile_sha256() {
	local work_dir="$1"
	python3 - "$work_dir" <<'PY' || return 1
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = (
    ".opencode/opencode.json",
    ".opencode/tool/provisional_fetch.ts",
    ".opencode/tool/provisional_submit.ts",
    "instructions.md",
    "jobs.jsonl",
)
digest = hashlib.sha256()
for relative_path in paths:
    contents = (root / relative_path).read_bytes()
    digest.update(relative_path.encode("utf-8"))
    digest.update(b"\0")
    digest.update(str(len(contents)).encode("ascii"))
    digest.update(b"\0")
    digest.update(contents)
print(digest.hexdigest())
PY
	return 0
}

_private_profile_fixture_statuses() {
	local work_dir="$1"
	local model_override="$2"
	local agent_name="$3"
	local profile_sha256="$4"
	local generated_profile_status=0 generated_profile_removed=0
	local unexpected_profile_entry_status=0 unexpected_instruction_status=0
	mkdir "${work_dir}/.opencode/node_modules"
	printf '%s\n' '*' >"${work_dir}/.opencode/.gitignore"
	printf '%s\n' '{}' >"${work_dir}/.opencode/package.json"
	printf '%s\n' '{}' >"${work_dir}/.opencode/package-lock.json"
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$profile_sha256" \
		>/dev/null 2>&1 || generated_profile_status=$?
	if [[ ! -e "${work_dir}/.opencode/node_modules" && \
		! -e "${work_dir}/.opencode/.gitignore" && \
		! -e "${work_dir}/.opencode/package.json" && \
		! -e "${work_dir}/.opencode/package-lock.json" ]]; then
		generated_profile_removed=1
	fi

	mkdir "${work_dir}/.opencode/plugin"
	printf '%s\n' 'export default {};' >"${work_dir}/.opencode/plugin/untrusted.ts"
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$profile_sha256" \
		>/dev/null 2>&1 || unexpected_profile_entry_status=$?
	rm -rf "${work_dir}/.opencode/plugin"

	printf '%s\n' 'Unapproved instructions.' >"${work_dir}/AGENTS.md"
	chmod 600 "${work_dir}/AGENTS.md"
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$profile_sha256" \
		>/dev/null 2>&1 || unexpected_instruction_status=$?
	rm -f "${work_dir}/AGENTS.md"
	printf '%s|%s|%s|%s\n' "$generated_profile_status" "$generated_profile_removed" \
		"$unexpected_profile_entry_status" "$unexpected_instruction_status"
	return 0
}

_private_profile_rejection_statuses() {
	local work_dir="$1"
	local model_override="$2"
	local agent_name="$3"
	local unsafe_profile_status=0 unexpected_permission_status=0 unexpected_config_status=0
	local description_status=0 steps_status=0 current_profile_sha256=""
	jq '.agent["provisional-adjudicator"].permission.read = "allow"' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || unsafe_profile_status=$?

	jq '.agent["provisional-adjudicator"].permission.read = "deny" | .agent["provisional-adjudicator"].permission.exfiltrate = "allow"' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || unexpected_permission_status=$?

	jq 'del(.agent["provisional-adjudicator"].permission.exfiltrate) | .plugin = ["untrusted-plugin"]' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || unexpected_config_status=$?

	jq 'del(.plugin) | .agent["provisional-adjudicator"].description = "Unapproved description"' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || description_status=$?

	jq '.agent["provisional-adjudicator"].description = "Adjudicates one protected award batch through fixed, capability-restricted tools." | .agent["provisional-adjudicator"].steps = 13' \
		"${work_dir}/.opencode/opencode.json" >"${work_dir}/.opencode/opencode.json.tmp"
	mv "${work_dir}/.opencode/opencode.json.tmp" "${work_dir}/.opencode/opencode.json"
	chmod 600 "${work_dir}/.opencode/opencode.json"
	current_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"$current_profile_sha256" \
		>/dev/null 2>&1 || steps_status=$?
	printf '%s|%s|%s|%s|%s\n' "$unsafe_profile_status" "$unexpected_permission_status" \
		"$unexpected_config_status" "$description_status" "$steps_status"
	return 0
}

test_private_workload_arguments_are_fail_closed() {
	local AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"
	local role="triage" session_key="private-0123456789abcdef0123456789abcdef" work_dir="${TEST_ROOT}/private-profile"
	local title="Private workload" prompt="$PRIVATE_WORKLOAD_PROMPT" prompt_file=""
	local model_override="openai/gpt-5.6-sol" initial_model="" tier_override=""
	local variant_override="" agent_name="provisional-adjudicator" headless_runtime="opencode"
	local detach=0 private_workload=0
	local private_profile_sha256=""
	local -a extra_args=("--pure")
	local helper_source=""
	local launch_source=""
	setup_private_workload_profile_fixture "$work_dir"
	private_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	helper_source=$(<"$HELPER_SCRIPT")
	launch_source=$(<"${HELPER_SCRIPT%/*}/headless-runtime-launch.sh")

	_parse_run_args --private-workload --private-profile-sha256 "$private_profile_sha256"
	local valid_status=0
	local valid_output=""
	valid_output=$(_validate_private_workload_args 2>&1) || valid_status=$?
	local descriptive_session_status=0
	session_key="private-client-case"
	_validate_private_workload_args >/dev/null 2>&1 || descriptive_session_status=$?
	session_key="private-0123456789abcdef0123456789abcdef"

	local fixture_statuses=""
	local generated_profile_status=0 generated_profile_removed=0
	local unexpected_profile_entry_status=0 unexpected_instruction_status=0
	fixture_statuses=$(_private_profile_fixture_statuses \
		"$work_dir" "$model_override" "$agent_name" "$private_profile_sha256")
	IFS='|' read -r generated_profile_status generated_profile_removed \
		unexpected_profile_entry_status unexpected_instruction_status <<<"$fixture_statuses"

	local invalid_extra_status=0
	extra_args=("--pure" "--print-logs")
	_validate_private_workload_args >/dev/null 2>&1 || invalid_extra_status=$?

	local missing_profile_hash_status=0
	private_profile_sha256=""
	_validate_private_workload_args >/dev/null 2>&1 || missing_profile_hash_status=$?
	private_profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1
	local mismatched_profile_hash_status=0
	_validate_private_workload_profile "$work_dir" "$model_override" "$agent_name" \
		"0000000000000000000000000000000000000000000000000000000000000000" \
		>/dev/null 2>&1 || mismatched_profile_hash_status=$?

	local invalid_prompt_status=0
	extra_args=("--pure")
	prompt="Confidential candidate details"
	_validate_private_workload_args >/dev/null 2>&1 || invalid_prompt_status=$?

	local invalid_provider_status=0
	prompt="$PRIVATE_WORKLOAD_PROMPT"
	model_override="anthropic/claude-sonnet-4-6"
	_validate_private_workload_args >/dev/null 2>&1 || invalid_provider_status=$?

	local missing_allowlist_status=0
	model_override="openai/gpt-5.6-sol"
	AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=""
	_validate_private_workload_args >/dev/null 2>&1 || missing_allowlist_status=$?
	AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"

	local rejection_statuses=""
	local unsafe_profile_status=0 unexpected_permission_status=0 unexpected_config_status=0
	local description_status=0 steps_status=0
	rejection_statuses=$(_private_profile_rejection_statuses "$work_dir" "$model_override" "$agent_name")
	IFS='|' read -r unsafe_profile_status unexpected_permission_status \
		unexpected_config_status description_status steps_status <<<"$rejection_statuses"

	if [[ "$private_workload" -eq 1 && "$valid_status" -eq 0 && "$descriptive_session_status" -eq 1 && \
		"$generated_profile_status" -eq 0 && "$generated_profile_removed" -eq 1 && \
		"$unexpected_profile_entry_status" -eq 1 && "$unexpected_instruction_status" -eq 1 && \
		"$invalid_extra_status" -eq 1 && "$missing_profile_hash_status" -eq 1 && \
		"$mismatched_profile_hash_status" -eq 1 && "$invalid_prompt_status" -eq 1 && \
		"$invalid_provider_status" -eq 1 && "$missing_allowlist_status" -eq 1 && \
		"$unsafe_profile_status" -eq 1 && \
		"$unexpected_permission_status" -eq 1 && "$unexpected_config_status" -eq 1 && \
		"$description_status" -eq 1 && "$steps_status" -eq 1 && \
		"$helper_source" == *'lifecycle_work_dir="[private]"'* && \
		"$launch_source" == *'display_work_dir="[private]"'* && \
		"$launch_source" == *'display_recovery_dir="[private]"'* && \
		"$helper_source" == *'metric_work_dir=""'* && \
		"$helper_source" == *'unset WORKER_WORKTREE_PATH _WORKER_WORKTREE_PATH'* ]]; then
		print_result "private workload arguments enforce the non-content boundary" 0
		return 0
	fi

	print_result "private workload arguments enforce the non-content boundary" 1 \
		"private=${private_workload} valid=${valid_status} descriptive_session=${descriptive_session_status} generated=${generated_profile_status}:${generated_profile_removed} profile_entry=${unexpected_profile_entry_status} instruction=${unexpected_instruction_status} extra=${invalid_extra_status} hash=${missing_profile_hash_status}:${mismatched_profile_hash_status} prompt=${invalid_prompt_status} provider=${invalid_provider_status}:${missing_allowlist_status} profile=${unsafe_profile_status} permission=${unexpected_permission_status} unexpected=${unexpected_config_status} exact=${description_status}:${steps_status} output=${valid_output:-<empty>}"
	return 0
}

test_private_workload_uses_minimal_lifecycle() {
	local lifecycle_state=""
	lifecycle_state=$(
		local AIDEVOPS_PRIVATE_WORKLOAD=1
		local model_override="openai/gpt-5.6-sol"
		local agent_name="provisional-adjudicator"
		local private_profile_sha256="0000000000000000000000000000000000000000000000000000000000000000"
		local _WORKER_WORKTREE_PATH="/private/path-must-not-persist"
		local WORKER_TARGET_BRANCH="private-branch-must-not-persist"
		local WORKER_NO_EXIT_PUSH=0
		local acquired=0 released=0 workload_acquired=0 workload_released=0
		local cleaned=0 lease_released=0 registered=0 updated=0 claimed=0
		local lifecycle_order=""
		_acquire_session_lock() { acquired=$((acquired + 1)); return 0; }
		_release_session_lock() { released=$((released + 1)); lifecycle_order="${lifecycle_order}session,"; return 0; }
		_acquire_private_workload_lock() { workload_acquired=$((workload_acquired + 1)); return 0; }
		_release_private_workload_lock() { workload_released=$((workload_released + 1)); lifecycle_order="${lifecycle_order}workload,"; return 0; }
		_validate_private_workload_profile() { return 0; }
		_cleanup_headless_runtime_temp_paths() { cleaned=$((cleaned + 1)); lifecycle_order="${lifecycle_order}cleanup,"; return 0; }
		aidevops_runtime_bundle_lease_release() { lease_released=$((lease_released + 1)); lifecycle_order="${lifecycle_order}lease,"; return 0; }
		_register_dispatch_ledger() { registered=$((registered + 1)); return 0; }
		_update_dispatch_ledger() { updated=$((updated + 1)); return 0; }
		_hrw_claim_worker_worktree() { claimed=$((claimed + 1)); return 0; }

		local invalid_prepare_status=0
		_cmd_run_prepare "private-client-case" "$TEST_ROOT" || invalid_prepare_status=$?
		local prepare_status=0
		_cmd_run_prepare "private-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$TEST_ROOT" || prepare_status=$?
		local prepared_path="${_WORKER_WORKTREE_PATH:-}"
		local prepared_branch="${WORKER_TARGET_BRANCH:-}"
		local finish_status=0
		_cmd_run_finish "private-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "complete" "$TEST_ROOT" || finish_status=$?
		printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
			"$invalid_prepare_status" "$prepare_status" "$finish_status" "$prepared_path" "$prepared_branch" \
			"$WORKER_NO_EXIT_PUSH" "$acquired" "$released" "$workload_acquired" \
			"$workload_released" "$cleaned" "$lease_released" "$registered" "$updated:$claimed" \
			"$lifecycle_order"
	)

	if [[ "$lifecycle_state" == "1|0|0|||1|1|1|1|1|1|1|0|0:0|cleanup,session,workload,lease," ]]; then
		print_result "private workloads bypass persistent worker lifecycle state" 0
		return 0
	fi

	print_result "private workloads bypass persistent worker lifecycle state" 1 \
		"state=${lifecycle_state:-<empty>}"
	return 0
}

test_private_workload_lock_is_cross_process_atomic() {
	local work_dir="${TEST_ROOT}/private-cross-process-lock"
	local child_script="${TEST_ROOT}/headless-runtime-private-lock-child.sh"
	local ready_file="${TEST_ROOT}/private-lock-ready"
	local release_file="${TEST_ROOT}/private-lock-release"
	local lock_key=""
	local child_pid=""
	local child_status=0 second_status=0 third_status=0
	local remaining_lock_count=""
	mkdir -p "$work_dir"
	init_state_db
	lock_key=$(_private_workload_directory_lock_key "$work_dir") || lock_key=""
	cat >"$child_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
helper_script="$1"
lock_key="$2"
ready_file="$3"
release_file="$4"
set --
# shellcheck source=/dev/null
source "$helper_script" >/dev/null
_acquire_private_workload_lock "$lock_key" || exit 2
printf 'ready\n' >"$ready_file"
while [[ ! -f "$release_file" ]]; do
	sleep 0.05
done
_release_private_workload_lock "$lock_key" || exit 3
EOF
	chmod 700 "$child_script"
	bash "$child_script" "$HELPER_SCRIPT" "$lock_key" "$ready_file" "$release_file" &
	child_pid=$!
	local attempt=0
	while [[ ! -f "$ready_file" && "$attempt" -lt 100 ]]; do
		kill -0 "$child_pid" 2>/dev/null || break
		sleep 0.05
		attempt=$((attempt + 1))
	done
	_acquire_private_workload_lock "$lock_key" >/dev/null 2>&1 || second_status=$?
	printf 'release\n' >"$release_file"
	wait "$child_pid" || child_status=$?
	_acquire_private_workload_lock "$lock_key" >/dev/null 2>&1 || third_status=$?
	_release_private_workload_lock "$lock_key" >/dev/null 2>&1 || true
	remaining_lock_count=$(sqlite3_with_timeout "$STATE_DB" \
		"SELECT COUNT(*) FROM private_workload_locks WHERE lock_key = '${lock_key}';" \
		2>/dev/null) || remaining_lock_count="query-failed"

	if [[ -f "$ready_file" && "$child_status" -eq 0 && "$second_status" -eq 1 && \
		"$third_status" -eq 0 && "$remaining_lock_count" == "0" ]]; then
		print_result "private workload lock acquisition is atomic across processes" 0
		return 0
	fi

	print_result "private workload lock acquisition is atomic across processes" 1 \
		"ready=$([[ -f "$ready_file" ]] && printf yes || printf no) child=${child_status} second=${second_status} third=${third_status} remaining=${remaining_lock_count}"
	return 0
}

test_private_workload_directory_lock_blocks_distinct_sessions() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local work_dir="${TEST_ROOT}/private-directory-lock"
	local model="openai/gpt-5.6-sol"
	local agent="provisional-adjudicator"
	local profile_sha256=""
	local first_session="private-11111111111111111111111111111111"
	local second_session="private-22222222222222222222222222222222"
	local third_session="private-33333333333333333333333333333333"
	init_state_db
	setup_private_workload_profile_fixture "$work_dir"
	profile_sha256=$(private_workload_profile_sha256 "$work_dir") || return 1

	local first_status=0 second_status=0 third_status=0
	_hrw_prepare_private_workload "$first_session" "$work_dir" "$model" "$agent" \
		"$profile_sha256" \
		>/dev/null 2>&1 || first_status=$?
	local workload_lock_key="${_PRIVATE_WORKLOAD_LOCK_KEY:-}"
	_hrw_prepare_private_workload "$second_session" "$work_dir" "$model" "$agent" \
		"$profile_sha256" \
		>/dev/null 2>&1 || second_status=$?
	_cmd_run_finish "$first_session" "complete" "$work_dir" >/dev/null 2>&1
	_hrw_prepare_private_workload "$third_session" "$work_dir" "$model" "$agent" \
		"$profile_sha256" \
		>/dev/null 2>&1 || third_status=$?
	_cmd_run_finish "$third_session" "complete" "$work_dir" >/dev/null 2>&1
	local remaining_lock_count=""
	remaining_lock_count=$(sqlite3_with_timeout "$STATE_DB" \
		"SELECT COUNT(*) FROM private_workload_locks WHERE lock_key = '${workload_lock_key}';" \
		2>/dev/null) || remaining_lock_count="query-failed"

	if [[ "$first_status" -eq 0 && "$second_status" -eq 2 && "$third_status" -eq 0 && \
		"$workload_lock_key" == private-workload-dir-* && \
		"$remaining_lock_count" == "0" ]]; then
		print_result "private workload directory locks span distinct session keys" 0
		return 0
	fi

	print_result "private workload directory locks span distinct session keys" 1 \
		"first=${first_status} second=${second_status} third=${third_status} lock=${workload_lock_key:-<empty>} remaining=${remaining_lock_count}"
	return 0
}

test_private_output_filter_removes_content() {
	local input_file="${TEST_ROOT}/private-filter-input.jsonl"
	local output_file="${TEST_ROOT}/private-filter-output.jsonl"
	local secret_marker="CLIENT_SECRET_AWARD_28491"
	cat >"$input_file" <<EOF
{"type":"step_start","sessionID":"ses_private","part":{"type":"step-start"}}
{"type":"tool_use","sessionID":"ses_private","part":{"tool":"provisional_submit","state":{"status":"completed","input":{"groupId":"${secret_marker}","decision":{"canonicalName":"${secret_marker}"}},"output":"${secret_marker}"}}}
{"type":"text","sessionID":"ses_private","part":{"text":"${secret_marker}"}}
{"type":"text","sessionID":"ses_private","part":{"text":"TASK_COMPLETE"}}
HTTP 429 rate limit for ${secret_marker}
EOF

	python3 "$PRIVATE_OUTPUT_FILTER" <"$input_file" >"$output_file"
	local filtered_output
	filtered_output=$(<"$output_file")
	if [[ "$filtered_output" == *'"type":"step_start"'* && \
		"$filtered_output" == *'"status":"completed"'* && \
		"$filtered_output" == *'"text":"TASK_COMPLETE"'* && \
		"$filtered_output" == *'HTTP 429 rate limit exceeded'* && \
		"$filtered_output" != *"$secret_marker"* && \
		"$filtered_output" != *'provisional_submit'* && \
		"$filtered_output" != *'ses_private'* ]]; then
		print_result "private output filter emits lifecycle evidence without content" 0
		return 0
	fi

	print_result "private output filter emits lifecycle evidence without content" 1 \
		"Filtered output retained content or omitted safe lifecycle evidence"
	return 0
}

test_private_workload_requires_task_complete() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local incomplete_output="${TEST_ROOT}/private-incomplete-output.jsonl"
	local complete_output="${TEST_ROOT}/private-complete-output.jsonl"
	printf '%s\n' '{"type":"step_start"}' >"$incomplete_output"
	printf '%s\n' '{"type":"step_start"}' '{"text":"TASK_COMPLETE","type":"text"}' >"$complete_output"

	local incomplete_status=0
	local complete_status=0
	_handle_run_result 0 "$incomplete_output" "triage" "openai" "private-incomplete" "openai/gpt-5.6-sol" >/dev/null 2>&1 || incomplete_status=$?
	_handle_run_result 0 "$complete_output" "triage" "openai" "private-complete" "openai/gpt-5.6-sol" >/dev/null 2>&1 || complete_status=$?

	if [[ "$incomplete_status" -eq 77 && "$complete_status" -eq 0 && \
		! -f "$incomplete_output" && ! -f "$complete_output" ]]; then
		print_result "private workloads require an exact TASK_COMPLETE marker" 0
		return 0
	fi

	print_result "private workloads require an exact TASK_COMPLETE marker" 1 \
		"incomplete=${incomplete_status} complete=${complete_status}"
	return 0
}

test_private_workload_skips_persistent_failure_output() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local output_file="${TEST_ROOT}/private-worker-output.jsonl"
	local details_file="${TEST_ROOT}/private-provider-details.log"
	local secret_marker="PRIVATE_FAILURE_DETAIL_39182"
	printf '%s\n' "$secret_marker" >"$output_file"
	printf 'HTTP 503 service unavailable: %s\n' "$secret_marker" >"$details_file"

	local candidate_path excerpt_path
	candidate_path=$(_metric_failure_excerpt_candidate_path "$output_file" "private-test")
	excerpt_path=$(_metric_failure_excerpt_path "$output_file" "private-test")
	_preserve_no_activity_output "$output_file" "private-test" "openai/gpt-5.6-sol"
	record_provider_backoff "openai" "provider_error" "$details_file" "openai/private-test"
	local stored_details
	stored_details=$(db_query "SELECT details FROM provider_backoff WHERE provider = 'openai/private-test';")
	clear_provider_backoff "openai/private-test"

	if [[ -z "$candidate_path" && -z "$excerpt_path" && ! -f "$output_file" && \
		"$stored_details" == "ephemeral workload details suppressed" && \
		! -d "${HOME}/.aidevops/logs/worker-failure-excerpts" && \
		! -d "${HOME}/.aidevops/logs/worker-no-activity" ]]; then
		print_result "private workloads do not persist transcript-derived diagnostics" 0
		return 0
	fi

	print_result "private workloads do not persist transcript-derived diagnostics" 1 \
		"candidate=${candidate_path:-<empty>} excerpt=${excerpt_path:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no) details=${stored_details:-<empty>}"
	return 0
}

test_sandbox_private_output_avoids_raw_capture() {
	local sandbox_helper="${HELPER_SCRIPT%/*}/sandbox-exec-helper.sh"
	local sandbox_home="${TEST_ROOT}/private-sandbox-home"
	local payload_script="${TEST_ROOT}/private-sandbox-payload.sh"
	local caller_output="${TEST_ROOT}/private-sandbox-caller.log"
	local secret_marker="SANDBOX_PRIVATE_CONTENT_78213"
	mkdir -p "$sandbox_home"
	cat >"$payload_script" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${secret_marker}'
printf '%s\n' '${secret_marker}' >&2
EOF
	chmod +x "$payload_script"

	local unauthorized_status=0 sandbox_status=0
	HOME="$sandbox_home" "$sandbox_helper" run --private-output --allow-secret-io \
		--timeout 10 -- bash "$payload_script" >/dev/null 2>&1 || unauthorized_status=$?
	AIDEVOPS_PRIVATE_WORKLOAD=1 HOME="$sandbox_home" \
		"$sandbox_helper" run --private-output --allow-secret-io \
		--timeout 10 -- bash "$payload_script" >"$caller_output" 2>&1 || sandbox_status=$?
	local persisted_secret=0
	if grep -R -Fq "$secret_marker" "${sandbox_home}/.aidevops/.agent-workspace/sandbox" 2>/dev/null; then
		persisted_secret=1
	fi
	local audit_output=""
	if [[ -f "${sandbox_home}/.aidevops/.agent-workspace/sandbox/executions.jsonl" ]]; then
		audit_output=$(<"${sandbox_home}/.aidevops/.agent-workspace/sandbox/executions.jsonl")
	fi

	if [[ "$unauthorized_status" -eq 2 && "$sandbox_status" -eq 0 && \
		"$persisted_secret" -eq 0 && \
		"$(<"$caller_output")" == *"$secret_marker"* && \
		"$audit_output" == *'[private workload command suppressed]'* ]]; then
		print_result "sandbox private output streams without raw temp or audit capture" 0
		return 0
	fi

	print_result "sandbox private output streams without raw temp or audit capture" 1 \
		"unauthorized=${unauthorized_status} status=${sandbox_status} persisted_secret=${persisted_secret} audit=${audit_output:-<empty>}"
	return 0
}

test_startup_no_activity_timeout_returns_watchdog_continue() {
	local output_file="${TEST_ROOT}/startup-stall.log"
	printf '%s\n' 'sqlite-migration:done' >"$output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local status=0
	_handle_run_result 124 "$output_file" "worker" "openai" "issue-22862" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "watchdog_startup_continue" && "$_run_failure_reason" == "startup_no_model_activity" && ! -f "$output_file" ]]; then
		print_result "startup no-activity timeout attempts bounded continuation" 0
		return 0
	fi

	print_result "startup no-activity timeout attempts bounded continuation" 1 \
		"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_startup_no_activity_can_rotate_after_continuation_budget() {
	local result status action next_model
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="startup_no_model_activity"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		choose_model() { printf '%s' 'anthropic/claude-sonnet-4-6'; return 0; }
		_cmd_run_finish() { return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-24949" "" 1 3 "openai/gpt-5.5" 78 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$cmd_run_action" "$cmd_run_next_model"
	)
	IFS='|' read -r status action next_model <<<"$result"

	if [[ "$status" -eq 0 && "$action" == "switch" && "$next_model" == "anthropic/claude-sonnet-4-6" ]]; then
		print_result "startup no-activity can rotate after continuation budget" 0
		return 0
	fi

	print_result "startup no-activity can rotate after continuation budget" 1 \
		"status=$status action=${action:-<empty>} next=${next_model:-<empty>}"
	return 0
}

test_sigkill_with_activity_attempts_continuation() {
	local output_file="${TEST_ROOT}/sigkill-with-activity.jsonl"
	cat >"$output_file" <<'EOF'
{"type":"text","text":"I made a change after reading docs that mention rate limit."}
[WORKER_EXIT_DIAGNOSTICS] exit_code=137 model=openai/gpt-5.5 role=worker session_key=issue-23036
[WORKER_EXIT_DIAGNOSTICS] cause=SIGKILL (OOM or external kill)
EOF
	_run_result_label=""
	_run_failure_reason=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""

	local status=0
	_handle_run_result 137 "$output_file" "worker" "openai" "issue-23036" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "signal_killed_continue" && "$_run_runtime_error_type" == "sigkill" && ! -f "$output_file" ]]; then
		print_result "SIGKILL with activity attempts continuation" 0
		return 0
	fi

	print_result "SIGKILL with activity attempts continuation" 1 \
		"status=$status label=${_run_result_label:-<empty>} runtime=${_run_runtime_error_type:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_sigterm_with_local_kill_reason_does_not_resume_as_provider_drop() {
	local output_file="${TEST_ROOT}/sigterm-local-kill.jsonl"
	cat >"$output_file" <<'EOF'
{"type":"text","text":"I was working before the local watchdog killed me."}
[WORKER_EXIT_DIAGNOSTICS] exit_code=143 model=openai/gpt-5.5 role=worker session_key=issue-25394
EOF
	_run_result_label=""
	_run_failure_reason=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""
	_metric_kill_reason="no_output_stall"

	local status=0
	_handle_run_result 143 "$output_file" "worker" "openai" "issue-25394" "openai/gpt-5.5" || status=$?
	unset _metric_kill_reason 2>/dev/null || true

	if [[ "$status" -eq 83 && "$_run_result_label" == "local_kill" && "$_run_failure_reason" == "no_output_stall" && "$_run_runtime_error_type" == "sigterm" && "$_run_classification_source" == "worker_kill_reason_sentinel" && ! -f "$output_file" ]]; then
		print_result "SIGTERM with local kill reason is not treated as provider/runtime drop" 0
		return 0
	fi

	print_result "SIGTERM with local kill reason is not treated as provider/runtime drop" 1 \
		"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} runtime=${_run_runtime_error_type:-<empty>} source=${_run_classification_source:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_handle_run_result_tolerates_empty_or_non_numeric_exit_code() {
	local empty_output_file="${TEST_ROOT}/empty-exit-code.jsonl"
	local text_output_file="${TEST_ROOT}/text-exit-code.jsonl"
	printf '%s\n' 'runtime exited before writing a numeric status' >"$empty_output_file"
	printf '%s\n' 'runtime wrote a non-numeric status' >"$text_output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local empty_status=0 empty_error=""
	set +e
	empty_error=$(_handle_run_result "" "$empty_output_file" "worker" "openai" "issue-25437" "openai/gpt-5.5" 2>&1)
	empty_status=$?
	set -e

	local text_status=0 text_error=""
	set +e
	text_error=$(_handle_run_result "not-a-number" "$text_output_file" "worker" "openai" "issue-25437" "openai/gpt-5.5" 2>&1)
	text_status=$?
	set -e

	if [[ "$empty_status" -eq 1 && "$text_status" -eq 1 ]] && \
		[[ "$empty_error" != *"syntax error"* && "$empty_error" != *"numeric argument"* ]] && \
		[[ "$text_error" != *"syntax error"* && "$text_error" != *"numeric argument"* ]]; then
		print_result "_handle_run_result tolerates empty or non-numeric exit code" 0
		return 0
	fi

	print_result "_handle_run_result tolerates empty or non-numeric exit code" 1 \
		"empty_status=$empty_status empty_error=${empty_error:-<empty>} text_status=$text_status text_error=${text_error:-<empty>}"
	return 0
}

test_dispatcher_initial_model_can_rotate_after_rate_limit() {
	local result status action next_model
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="rate_limit"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		choose_model() { printf '%s' 'anthropic/claude-sonnet-4-6'; return 0; }
		_cmd_run_finish() { return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-22862" "" 1 3 "openai/gpt-5.5" 124 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$cmd_run_action" "$cmd_run_next_model"
	)
	IFS='|' read -r status action next_model <<<"$result"

	if [[ "$status" -eq 0 && "$action" == "switch" && "$next_model" == "anthropic/claude-sonnet-4-6" ]]; then
		print_result "dispatcher-selected initial model can rotate after rate limit" 0
		return 0
	fi

	print_result "dispatcher-selected initial model can rotate after rate limit" 1 \
		"status=$status action=${action:-<empty>} next=${next_model:-<empty>}"
	return 0
}

test_explicit_model_override_remains_pinned_on_rate_limit() {
	local result status finished_status action
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="rate_limit"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		local finished_inner=""
		_cmd_run_finish() { local status_arg="$2"; finished_inner="$status_arg"; return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-22862" "openai/gpt-5.5" 1 3 "openai/gpt-5.5" 124 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$finished_inner" "$cmd_run_action"
	)
	IFS='|' read -r status finished_status action <<<"$result"

	if [[ "$status" -eq 124 && "$finished_status" == "fail" && "$action" == "retry" ]]; then
		print_result "explicit model override remains pinned on rate limit" 0
		return 0
	fi

	print_result "explicit model override remains pinned on rate limit" 1 \
		"status=$status finish=${finished_status:-<empty>} action=${action:-<empty>}"
	return 0
}
