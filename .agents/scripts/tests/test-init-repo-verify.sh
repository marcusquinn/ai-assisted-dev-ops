#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DIR="${INSTALL_DIR}/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

TEST_TMP_DIR=""
passed=0
failed=0

assert_equal() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
		passed=$((passed + 1))
	else
		printf 'FAIL %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
		failed=$((failed + 1))
	fi
	return 0
}

test_beads_hook_integrity() {
	local repo_root="$1"
	local common_dir="$2"
	local hook_file="${repo_root}/${common_dir}/hooks/pre-push"
	local stub_bin="${TEST_TMP_DIR}/bin"
	local beads_args="${TEST_TMP_DIR}/beads-args"
	mkdir -p "$stub_bin"
	cat >"${stub_bin}/bd" <<'BDEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "init" && "${2:-}" == "--help" ]]; then
	[[ "${BEADS_LEGACY:-false}" == "true" ]] || printf '%s\n' '      --skip-hooks   Skip git hooks installation'
	exit 0
fi
printf '%s\n' "$*" >"$BEADS_ARGS"
if [[ "${BEADS_LEGACY:-false}" == "true" ]]; then
	printf '%s\n' '#!/usr/bin/env bash' '# replaced by legacy Beads' 'exit 0' >"$BEADS_HOOK"
	chmod +x "$BEADS_HOOK"
fi
mkdir -p .beads
exit 0
BDEOF
	chmod +x "${stub_bin}/bd"
	local original_path="$PATH" original_agents_dir="$AGENTS_DIR"
	PATH="${stub_bin}:${PATH}"
	AGENTS_DIR="${TEST_TMP_DIR}/empty-agents"
	mkdir -p "$AGENTS_DIR"
	export BEADS_ARGS="$beads_args" BEADS_HOOK="$hook_file"
	local enable_database=false enable_beads=true enable_sops=false
	local project_root="$repo_root"
	_init_sops_support() { return 0; }
	_init_database_and_beads
	assert_equal "init --skip-hooks" "$(<"$beads_args")" "init prevents modern Beads from replacing the managed hook"
	assert_equal "0" "$(
		_init_finalize_repo_verify "$repo_root" >/dev/null 2>&1
		printf '%s' "$?"
	)" "final hook integrity passes after modern Beads setup"

	rm -rf "${repo_root}/.beads"
	BEADS_LEGACY=true _init_database_and_beads
	assert_equal "init" "$(<"$beads_args")" "legacy Beads initializes without unsupported flags"
	assert_equal "true" "$(_init_repo_verify_hook_integrity "$repo_root" && printf true || printf false)" "legacy Beads hook replacement is restored"

	printf '%s\n' '#!/usr/bin/env bash' '# aidevops-pre-push-guards' '# guard:repo-verify' 'exit 0' >"$hook_file"
	chmod +x "$hook_file"
	_init_finalize_repo_verify "$repo_root"
	assert_equal "true" "$(_init_repo_verify_hook_integrity "$repo_root" && printf true || printf false)" "final verification repairs a marker-only no-op hook"

	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$hook_file"
	chmod +x "$hook_file"
	local final_status=0
	_init_finalize_repo_verify "$repo_root" >/dev/null 2>&1 || final_status=$?
	assert_equal "1" "$final_status" "init fails when an unmanaged final hook postcondition is lost"
	AGENTS_DIR="$original_agents_dir"
	PATH="$original_path"
	return 0
}

test_security_completion_status() {
	local repo_root="$1"
	local security_agents="${TEST_TMP_DIR}/security-agents"
	mkdir -p "${security_agents}/scripts"
	cat >"${security_agents}/scripts/security-posture-helper.sh" <<'SECURITYEOF'
#!/usr/bin/env bash
set -euo pipefail
config_file="${2}/.aidevops.json"
jq '.security_posture.status = "partial"' "$config_file" >"${config_file}.tmp"
mv "${config_file}.tmp" "$config_file"
exit 0
SECURITYEOF
	local original_agents_dir="$AGENTS_DIR"
	AGENTS_DIR="$security_agents"
	local project_root="$repo_root" enable_security=true config_migration_deferred=false init_security_posture=unknown
	_init_assess_security_posture
	assert_equal "partial" "$init_security_posture" "successful security helper preserves a stored partial posture"
	AGENTS_DIR="$original_agents_dir"

	print_warning() {
		printf 'WARNING %s\n' "$*"
		return 0
	}
	print_success() {
		printf 'SUCCESS %s\n' "$*"
		return 0
	}
	local init_scope=standard committed=true
	local enable_planning=false enable_git_workflow=false enable_code_quality=false enable_time_tracking=false
	local enable_database=false enable_beads=false enable_sops=false
	local enable_deployment_context=false enable_wordpress_context=false WORKTREE_PATH=""
	local summary_output=""
	summary_output=$(_init_print_summary)
	assert_equal "true" "$([[ "$summary_output" == *"hardening remains incomplete"* ]] && printf true || printf false)" "partial security posture qualifies the init completion message"
	assert_equal "false" "$([[ "$summary_output" == *"SUCCESS AI DevOps initialized!"* ]] && printf true || printf false)" "partial security posture suppresses unconditional success"
	return 0
}

main() {
	TEST_TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP_DIR"' EXIT
	local repo_root="${TEST_TMP_DIR}/repo"
	mkdir -p "$repo_root"
	/usr/bin/git -C "$repo_root" init -q
	printf '%s\n' '{"custom":{"keep":true},"features":{"planning":false}}' >"$repo_root/.aidevops.json"
	printf '%s\n' '{"scripts":{"lint":"eslint .","typecheck":"tsc --noEmit"}}' >"$repo_root/package.json"
	/usr/bin/git -C "$repo_root" add package.json

	_init_write_project_config "$repo_root/.aidevops.json" "9.9.9" "standard" false false true true true false false false false true false false
	assert_equal "true" "$(jq -r '.custom.keep' "$repo_root/.aidevops.json")" "init preserves unknown configuration keys"
	assert_equal "false" "$(jq -r '.features.planning' "$repo_root/.aidevops.json")" "init preserves explicit feature values"
	assert_equal "9.9.9" "$(jq -r '.version' "$repo_root/.aidevops.json")" "init refreshes managed version"

	_init_configure_repo_verify "$repo_root"
	assert_equal "npm run lint" "$(jq -r '.verify.lint' "$repo_root/.aidevops.json")" "init seeds exact lint command"
	assert_equal "npm run typecheck" "$(jq -r '.verify.typecheck' "$repo_root/.aidevops.json")" "init seeds exact typecheck command"
	local common_dir
	common_dir=$(/usr/bin/git -C "$repo_root" rev-parse --git-common-dir)
	assert_equal "1" "$(grep -c '# guard:repo-verify' "${repo_root}/${common_dir}/hooks/pre-push" 2>/dev/null || printf 0)" "init immediately installs repo-verify hook"

	test_beads_hook_integrity "$repo_root" "$common_dir"

	local invalid_config="${TEST_TMP_DIR}/invalid.json"
	printf '{invalid\n' >"$invalid_config"
	local invalid_before invalid_after invalid_status=0
	invalid_before=$(cksum <"$invalid_config")
	_init_write_project_config "$invalid_config" "9.9.9" "standard" false false true true true false false false false true false false >/dev/null 2>&1 || invalid_status=$?
	invalid_after=$(cksum <"$invalid_config")
	assert_equal "1" "$invalid_status" "init refuses to overwrite invalid existing config"
	assert_equal "$invalid_before" "$invalid_after" "invalid existing config remains untouched"

	local opted_out="${TEST_TMP_DIR}/opted-out"
	mkdir -p "$opted_out"
	/usr/bin/git -C "$opted_out" init -q
	printf '%s\n' '{"features":{"code_quality":true},"verify":{"enabled":false}}' >"$opted_out/.aidevops.json"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$opted_out/package.json"
	/usr/bin/git -C "$opted_out" add package.json
	_init_configure_repo_verify "$opted_out"
	_init_finalize_repo_verify "$opted_out"
	common_dir=$(/usr/bin/git -C "$opted_out" rev-parse --git-common-dir)
	if [[ -f "${opted_out}/${common_dir}/hooks/pre-push" ]]; then
		assert_equal "0" "$(grep -c '# guard:repo-verify' "${opted_out}/${common_dir}/hooks/pre-push" 2>/dev/null || printf 0)" "init does not install hook for verify opt-out"
	else
		assert_equal "0" "0" "init does not install hook for verify opt-out"
	fi

	test_security_completion_status "$repo_root"

	printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main "$@"
