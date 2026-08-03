#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT=""
FAKE_REPO=""
TESTS_RUN=0

print_info() { local message="$1"; : "$message"; return 0; }
print_success() { local message="$1"; : "$message"; return 0; }
print_warning() { local message="$1"; : "$message"; return 0; }
print_error() { local message="$1"; printf 'ERROR: %s\n' "$message" >&2; return 0; }
print_skip() { local message="$1"; : "$message"; return 0; }
setup_track_deferred() { return 0; }
create_backup_with_rotation() { return 0; }

# shellcheck source=../portable-stat.sh
source "$REPO_ROOT/.agents/scripts/portable-stat.sh"
# shellcheck source=../setup/modules/plugins.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/plugins.sh"
# shellcheck source=../setup/modules/agent-deploy.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-deploy.sh"
# shellcheck source=../setup/modules/agent-runtime.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/agent-runtime.sh"
# shellcheck source=../setup/modules/schedulers-pulse.sh
source "$REPO_ROOT/.agents/scripts/setup/modules/schedulers-pulse.sh"
# shellcheck source=../runtime-bundle-lease.sh
source "$REPO_ROOT/.agents/scripts/runtime-bundle-lease.sh"
# shellcheck source=../pulse-runtime-pin.sh
source "$REPO_ROOT/.agents/scripts/pulse-runtime-pin.sh"

assert_output_contains() {
	local output="$1"
	local pattern="$2"
	local message="$3"
	[[ "$output" == *"$pattern"* ]] || fail "$message"
	pass "$message"
	return 0
}

_xml_escape() { local value="$1"; printf '%s' "$value"; return 0; }

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

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	[[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
	pass "$message"
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	local message="$3"
	grep -q "$pattern" "$file" || fail "$message"
	pass "$message"
	return 0
}

write_pinnable_bundle_fixture() {
	local agents_root="$1"
	local bundle_id="$2"
	local entrypoint=""
	mkdir -p "$agents_root/scripts"
	for entrypoint in \
		pulse-runtime-pin.sh \
		pulse-wrapper.sh \
		pulse-lifecycle-helper.sh \
		pulse-merge-routine.sh \
		pulse-merge-webhook-receiver.sh; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$agents_root/scripts/$entrypoint"
		chmod +x "$agents_root/scripts/$entrypoint"
	done
	printf 'schema=1\nstatus=validated\nbundle_id=%s\n' "$bundle_id" >"$agents_root/.bundle-manifest"
	return 0
}

write_fake_revision() {
	local version="$1"
	local marker="$2"
	rm -rf "$FAKE_REPO/.agents/plugins"
	mkdir -p "$FAKE_REPO/.agents/scripts"
	printf '%s\n' "$version" >"$FAKE_REPO/VERSION"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$version" >"$FAKE_REPO/aidevops.sh"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$marker" >"$FAKE_REPO/.agents/scripts/helper.sh"
	printf '#!/usr/bin/env bash\nexec git "$@"\n' >"$FAKE_REPO/.agents/scripts/git"
	printf '# test agents\n' >"$FAKE_REPO/.agents/AGENTS.md"
	chmod +x "$FAKE_REPO/aidevops.sh" "$FAKE_REPO/.agents/scripts/helper.sh" "$FAKE_REPO/.agents/scripts/git"
	return 0
}

write_fake_plugin_manifest() {
	mkdir -p "$FAKE_REPO/.agents/plugins/opencode-aidevops"
	printf '{"name":"opencode-aidevops","type":"module"}\n' >"$FAKE_REPO/.agents/plugins/opencode-aidevops/package.json"
	printf '{"name":"opencode-aidevops","lockfileVersion":3,"packages":{}}\n' >"$FAKE_REPO/.agents/plugins/opencode-aidevops/package-lock.json"
	return 0
}

write_fake_plugin_dependencies() {
	local plugin_dir="$FAKE_REPO/.agents/plugins/opencode-aidevops"
	mkdir -p "$plugin_dir/node_modules/@bufbuild/protobuf" "$plugin_dir/node_modules/@opencode-ai/plugin"
	printf '{"name":"@bufbuild/protobuf","type":"module","exports":"./index.mjs"}\n' >"$plugin_dir/node_modules/@bufbuild/protobuf/package.json"
	printf 'export const fixture = true;\n' >"$plugin_dir/node_modules/@bufbuild/protobuf/index.mjs"
	printf '{"name":"@opencode-ai/plugin","type":"module","exports":"./index.mjs"}\n' >"$plugin_dir/node_modules/@opencode-ai/plugin/package.json"
	printf 'export const tool = Object.assign((definition) => definition, { schema: {} });\n' >"$plugin_dir/node_modules/@opencode-ai/plugin/index.mjs"
	return 0
}

stage_revision() {
	local target_dir="$1"
	_runtime_bundle_stage "$FAKE_REPO" "$FAKE_REPO/.agents" "$target_dir" "$TEST_ROOT/plugins.json" || return 1
	return 0
}

set_bundle_manifest_sha() {
	local bundle_dir="$1"
	local git_sha="$2"
	local manifest_file=""
	local manifest_tmp=""
	local line=""

	for manifest_file in "$bundle_dir/manifest" "$bundle_dir/agents/.bundle-manifest"; do
		manifest_tmp="${manifest_file}.tmp"
		while IFS= read -r line || [[ -n "$line" ]]; do
			if [[ "$line" == git_sha=* ]]; then
				printf 'git_sha=%s\n' "$git_sha"
			else
				printf '%s\n' "$line"
			fi
		done <"$manifest_file" >"$manifest_tmp"
		mv "$manifest_tmp" "$manifest_file"
	done
	return 0
}

install_mock_ancestor_git() {
	git() {
		local first_arg="$1"
		local third_arg="${3:-}"
		local fourth_arg="${4:-}"
		local fifth_arg="${5:-}"
		local sixth_arg="${6:-}"
		if [[ "$first_arg" == "-C" && "$third_arg" == "cat-file" ]]; then
			case "$fifth_arg" in
			"1111111111111111111111111111111111111111^{commit}" | "2222222222222222222222222222222222222222^{commit}") return 0 ;;
			esac
			return 1
		fi
		if [[ "$first_arg" == "-C" && "$third_arg" == "merge-base" ]]; then
			[[ "$fourth_arg" == "--is-ancestor" &&
				"$fifth_arg" == "1111111111111111111111111111111111111111" &&
				"$sixth_arg" == "2222222222222222222222222222222222222222" ]]
			return $?
		fi
		return 1
	}
	return 0
}

test_manifest_value_reads_unterminated_final_line() {
	local manifest_file="$TEST_ROOT/manifest-without-trailing-newline"

	printf 'schema=1\nframework_version=15.0.0' >"$manifest_file"
	assert_eq "15.0.0" "$(_runtime_bundle_manifest_value "$manifest_file" framework_version)" \
		"manifest reader accepts an unterminated final line"
	return 0
}

test_initial_activation_and_manifest() {
	local target_dir="$HOME/.aidevops/agents"
	local active_root=""
	mkdir -p "$target_dir/scripts" "$target_dir/custom"
	printf '1.0.0\n' >"$target_dir/VERSION"
	printf 'old\n' >"$target_dir/scripts/helper.sh"
	printf 'preserved\n' >"$target_dir/custom/user.txt"

	write_fake_revision "2.0.0" "new"
	stage_revision "$target_dir"
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	active_root=$(_runtime_bundle_resolve_root "$target_dir")

	[[ -L "$target_dir" ]] || fail "active agents path is an activation symlink"
	pass "active agents path is an activation symlink"
	assert_eq "$active_root" "$_AIDEVOPS_ACTIVE_BUNDLE_ROOT" "activation returns the validated physical bundle root"
	_verify_deployed_agents_tree "$target_dir" || fail "post-activation verification follows the active bundle symlink"
	pass "post-activation verification follows the active bundle symlink"
	assert_eq "2.0.0" "$(tr -d '[:space:]' <"$active_root/VERSION")" "CLI and agents activate at one version"
	assert_file_contains "$active_root/.bundle-manifest" '^status=validated$' "validated manifest is inside the active bundle"
	assert_file_contains "$active_root/.bundle-manifest" '^cli_compatibility=2.0.0$' "manifest binds CLI compatibility"
	assert_eq "preserved" "$(tr -d '[:space:]' <"$active_root/custom/user.txt")" "user custom content survives bundle migration"
	[[ -L "$HOME/.aidevops/previous-runtime-bundle" ]] || fail "previous validated bundle is retained"
	pass "previous validated bundle is retained"
	return 0
}

test_interrupted_staging_preserves_active() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	local failure_point=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "3.0.0" "interrupted"
	for failure_point in after-stage-copy after-plugin-generation before-activation; do
		if AIDEVOPS_BUNDLE_FAIL_AT="$failure_point" stage_revision "$target_dir"; then
			fail "injected interruption at $failure_point unexpectedly succeeded"
		fi
		active_after=$(_runtime_bundle_resolve_root "$target_dir")
		assert_eq "$active_before" "$active_after" "interruption at $failure_point preserves active bundle"
	done
	return 0
}

test_failed_activation_rolls_back() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "3.1.0" "rollback"
	stage_revision "$target_dir"
	if AIDEVOPS_BUNDLE_FAIL_AT=after-activation _runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"; then
		fail "injected post-activation validation failure unexpectedly succeeded"
	fi
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "failed activation rolls back to previous validated bundle"
	assert_eq "" "${_AIDEVOPS_ACTIVE_BUNDLE_ROOT:-}" "failed activation does not publish a candidate runtime root"
	return 0
}

test_process_pin_survives_activation() {
	local target_dir="$HOME/.aidevops/agents"
	local pinned_root=""
	pin_aidevops_runtime_bundle_root
	pinned_root="$AIDEVOPS_AGENTS_DIR"
	write_fake_revision "4.0.0" "next"
	stage_revision "$target_dir"
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	assert_eq "$pinned_root" "$AIDEVOPS_AGENTS_DIR" "running process remains pinned after activation"
	assert_eq "2.0.0" "$(tr -d '[:space:]' <"$AIDEVOPS_AGENTS_DIR/VERSION")" "pinned process reads its original version"
	assert_eq "4.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "new process path reads the newly active version"
	return 0
}

test_setup_rebinds_stale_process_pin_to_active_bundle() {
	local target_dir="$HOME/.aidevops/agents"
	local stale_root="$AIDEVOPS_AGENTS_DIR"
	local active_root=""
	active_root=$(_runtime_bundle_resolve_root "$target_dir")
	[[ "$stale_root" != "$active_root" ]] || fail "fixture process pin is not stale"
	pin_aidevops_active_runtime_bundle_root || fail "setup could not resolve active bundle"
	assert_eq "$active_root" "$AIDEVOPS_AGENTS_DIR" "setup re-resolves a stale inherited AIDEVOPS_AGENTS_DIR"
	assert_eq "$active_root" "$AGENTS_DIR" "setup re-resolves a stale inherited AGENTS_DIR"
	return 0
}

test_live_bundle_lease_survives_three_updates() {
	local target_dir="$HOME/.aidevops/agents"
	local leased_root=""
	local version=""
	leased_root=$(_runtime_bundle_resolve_root "$target_dir")
	aidevops_runtime_bundle_lease_acquire "$leased_root" || fail "runtime process could not acquire its bundle lease"

	for version in 5.0.0 6.0.0 7.0.0; do
		write_fake_revision "$version" "update-$version"
		stage_revision "$target_dir"
		AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=0 _runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	done
	[[ -x "$leased_root/scripts/helper.sh" ]] || fail "live first bundle helper survives three updates"
	pass "live first bundle helper survives three updates"
	aidevops_runtime_bundle_lease_release || fail "runtime process could not release its bundle lease"
	return 0
}

test_permission_denied_signal_check_preserves_live_lease() {
	local lease_dir="$HOME/.aidevops/runtime-bundles/.leases/permission-denied"
	local lease_file="$lease_dir/$$"
	mkdir -p "$lease_dir"
	printf 'live\n' >"$lease_file"

	(
		kill() { return 1; }
		_runtime_bundle_has_live_lease "$lease_dir"
	) || fail "ps fallback did not recognize the live lease process"
	[[ -f "$lease_file" ]] || fail "permission-denied signal check removed a live lease"
	rm -rf "$lease_dir"
	pass "permission-denied signal check preserves a live lease"
	return 0
}

test_proc_fallback_preserves_live_lease_without_ps() {
	local lease_dir="$HOME/.aidevops/runtime-bundles/.leases/proc-fallback"
	local lease_file="$lease_dir/$$"
	if [[ ! -d "/proc/$$" ]]; then
		print_skip "/proc lease fallback requires Linux"
		return 0
	fi
	mkdir -p "$lease_dir"
	printf 'live\n' >"$lease_file"

	(
		kill() { return 1; }
		ps() { return 127; }
		_runtime_bundle_has_live_lease "$lease_dir"
	) || fail "/proc fallback did not recognize the live lease process"
	[[ -f "$lease_file" ]] || fail "/proc fallback removed a live lease"
	rm -rf "$lease_dir"
	pass "/proc fallback preserves a live lease without ps"
	return 0
}

test_stale_lease_and_old_bundle_are_pruned() {
	local target_dir="$HOME/.aidevops/agents"
	local stale_bundle="$HOME/.aidevops/runtime-bundles/stale-crash"
	local stale_pid="99999999"
	mkdir -p "$stale_bundle/agents/scripts" "$HOME/.aidevops/runtime-bundles/.leases/stale-crash"
	printf '#!/usr/bin/env bash\n' >"$stale_bundle/agents/scripts/helper.sh"
	printf '%s\n' "$stale_bundle/agents" >"$HOME/.aidevops/runtime-bundles/.leases/stale-crash/$stale_pid"
	AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=0 _runtime_bundle_prune \
		"$HOME/.aidevops/runtime-bundles" "$(_runtime_bundle_resolve_root "$target_dir")" ""
	[[ ! -d "$stale_bundle" ]] || fail "crashed process lease does not retain an old bundle"
	pass "crashed process lease does not retain an old bundle"
	return 0
}

test_count_and_byte_pressure_preserve_protected_bundles() {
	local target_dir="$HOME/.aidevops/agents"
	local bundles_dir="$HOME/.aidevops/runtime-bundles"
	local previous_bundle="$bundles_dir/pressure-previous"
	local active_root=""
	local previous_root=""
	local live_bundle="$bundles_dir/pressure-live"
	local pinned_bundle="$bundles_dir/pressure-pinned"
	local before_checksum=""
	local after_checksum=""
	active_root=$(_runtime_bundle_resolve_root "$target_dir")
	mkdir -p "$previous_bundle/agents/scripts"
	printf '#!/usr/bin/env bash\n' >"$previous_bundle/agents/scripts/helper.sh"
	previous_root=$(cd "$previous_bundle/agents" && pwd -P)
	rm -f "$HOME/.aidevops/previous-runtime-bundle"
	ln -s "$previous_root" "$HOME/.aidevops/previous-runtime-bundle"
	mkdir -p "$live_bundle/agents" "$bundles_dir/.leases/pressure-live"
	printf 'live\n' >"$live_bundle/agents/marker"
	printf '%s\n' "$live_bundle/agents" >"$bundles_dir/.leases/pressure-live/$$"
	write_pinnable_bundle_fixture "$pinned_bundle/agents" "pressure-pinned"
	pulse_runtime_pin_set "$pinned_bundle/agents" "$(($(date +%s) + 600))" || fail "pressure fixture could not pin a runtime bundle"
	mkdir -p "$bundles_dir/pressure-count-a/agents" "$bundles_dir/pressure-count-b/agents"
	printf 'candidate-a\n' >"$bundles_dir/pressure-count-a/agents/marker"
	printf 'candidate-b\n' >"$bundles_dir/pressure-count-b/agents/marker"
	before_checksum=$(cksum "$active_root/scripts/helper.sh" "$previous_root/scripts/helper.sh" "$live_bundle/agents/marker" "$pinned_bundle/agents/.bundle-manifest")

	AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=999999999 \
		AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT=3 \
		AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES=999999999999 \
		_runtime_bundle_prune "$bundles_dir" "$active_root" "$previous_root"
	[[ ! -d "$bundles_dir/pressure-count-a" && ! -d "$bundles_dir/pressure-count-b" ]] || fail "count pressure did not converge unprotected bundles"
	[[ -d "$active_root" && -d "$previous_root" && -d "$live_bundle" && -d "$pinned_bundle" ]] || fail "count pressure removed a protected bundle"

	mkdir -p "$bundles_dir/pressure-bytes/agents"
	printf 'byte-pressure-candidate\n' >"$bundles_dir/pressure-bytes/agents/marker"
	AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=999999999 \
		AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT=999 \
		AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES=1 \
		_runtime_bundle_prune "$bundles_dir" "$active_root" "$previous_root"
	[[ ! -d "$bundles_dir/pressure-bytes" ]] || fail "byte pressure did not prune the unprotected candidate"
	after_checksum=$(cksum "$active_root/scripts/helper.sh" "$previous_root/scripts/helper.sh" "$live_bundle/agents/marker" "$pinned_bundle/agents/.bundle-manifest")
	assert_eq "$before_checksum" "$after_checksum" "count and byte pressure preserve protected bundle byte identity"
	pulse_runtime_pin_clear --force
	return 0
}

test_runtime_bundle_inventory_explains_protection() {
	local bundles_dir="$HOME/.aidevops/runtime-bundles"
	local report_candidate="$bundles_dir/report-candidate"
	local report_pinned="$bundles_dir/report-pinned"
	local report=""
	local before_checksum=""
	local after_checksum=""
	mkdir -p "$report_candidate/agents"
	printf 'reclaimable-candidate\n' >"$report_candidate/agents/marker"
	write_pinnable_bundle_fixture "$report_pinned/agents" "report-pinned"
	pulse_runtime_pin_set "$report_pinned/agents" "$(($(date +%s) + 600))" || fail "inventory fixture could not pin a runtime bundle"
	before_checksum=$(cksum "$report_candidate/agents/marker")
	report=$(bash "$REPO_ROOT/.agents/scripts/storage-inventory-helper.sh" json)
	after_checksum=$(cksum "$report_candidate/agents/marker")
	assert_eq "$before_checksum" "$after_checksum" "runtime bundle inventory is read-only"
	[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .protected_bytes > 0')" == "true" ]] || fail "runtime inventory omitted protected bytes"
	[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .reclaimable_bytes > 0')" == "true" ]] || fail "runtime inventory omitted unreferenced reclaimable bytes"
	[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .unknown_bytes')" == "0" ]] || fail "runtime inventory left classified bundles unknown"
	[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "runtime-bundles") | .protection_reasons[]' | grep -c 'active Pulse runtime pin')" -eq 1 ]] || fail "runtime inventory omitted the active Pulse pin reason"
	pulse_runtime_pin_clear --force
	pass "runtime inventory explains protected and reclaimable bundle bytes"
	return 0
}

test_macos_and_linux_link_paths() {
	local os_name=""
	local os_root=""
	local link_path=""
	local resolved=""
	local expected=""
	for os_name in Darwin Linux; do
		os_root="$TEST_ROOT/os-$os_name"
		mkdir -p "$os_root/one" "$os_root/two"
		link_path="$os_root/active"
		ln -s "$os_root/one" "$link_path"
		MOCK_UNAME="$os_name"
		uname() { printf '%s\n' "$MOCK_UNAME"; return 0; }
		mv() {
			local first_arg="$1"
			if [[ "$first_arg" == "-Tf" ]]; then
				command rm -f "$3"
				command mv -f "$2" "$3"
				return $?
			fi
			if [[ "$first_arg" == "-f" && "${2:-}" == "-h" ]]; then
				command rm -f "$4"
				command mv -f "$3" "$4"
				return $?
			fi
			command mv "$@"
			return $?
		}
		_runtime_bundle_switch_link "$link_path" "$os_root/two"
		resolved=$(cd "$link_path" && pwd -P)
		expected=$(cd "$os_root/two" && pwd -P)
		assert_eq "$expected" "$resolved" "$os_name activation uses atomic rename semantics"
		unset -f uname mv
	done
	return 0
}

test_plugin_dependency_smoke_check() {
	local plugin_dir=""
	write_fake_revision "7.1.0" "dependency-smoke-check"
	write_fake_plugin_manifest
	write_fake_plugin_dependencies
	plugin_dir="$FAKE_REPO/.agents/plugins/opencode-aidevops"

	_verify_opencode_plugin_deps "$plugin_dir" || fail "complete plugin dependencies pass the import smoke check"
	pass "complete plugin dependencies pass the import smoke check"
	rm -rf "$plugin_dir/node_modules/@opencode-ai/plugin"
	if _verify_opencode_plugin_deps "$plugin_dir" >/dev/null 2>&1; then
		fail "missing @opencode-ai/plugin unexpectedly passed the import smoke check"
	fi
	pass "missing @opencode-ai/plugin fails the import smoke check"
	return 0
}

install_mock_plugin_dependency_hooks() {
	_verify_opencode_plugin_deps() {
		local plugin_dir="$1"
		: "$plugin_dir"
		case "$MOCK_PLUGIN_VERIFY_MODE" in
		available)
			return 0
			;;
		recover)
			[[ -f "$TEST_ROOT/npm-install-complete" ]] && return 0
			return 1
			;;
		failure)
			return 1
			;;
		esac
		return 1
	}

	npm() {
		printf '%s\n%s\n' "$MOCK_PLUGIN_VERIFY_MODE" "$*" >>"$TEST_ROOT/npm-called"
		if [[ "$MOCK_PLUGIN_VERIFY_MODE" == "recover" ]]; then
			printf 'installed\n' >"$TEST_ROOT/npm-install-complete"
			return 0
		fi
		printf 'mock npm install failure\n' >&2
		return 1
	}
	return 0
}

test_dependency_install_recovery_activates_candidate() {
	local target_dir="$HOME/.aidevops/agents"
	local npm_calls=""
	write_fake_revision "8.0.0" "dependency-recovery"
	write_fake_plugin_manifest
	MOCK_PLUGIN_VERIFY_MODE="recover"
	rm -f "$TEST_ROOT/npm-called" "$TEST_ROOT/npm-install-complete"

	stage_revision "$target_dir"
	[[ -f "$TEST_ROOT/npm-called" ]] || fail "missing dependencies invoke npm install"
	pass "missing dependencies invoke npm install"
	npm_calls=$(tr '\n' ' ' <"$TEST_ROOT/npm-called")
	[[ "$npm_calls" == *"ci --omit=dev --omit=peer --prefer-offline --no-audit --no-fund --prefix "* ]] ||
		fail "dependency recovery did not use the exact lockfile install mode (calls: $npm_calls)"
	pass "dependency recovery uses the exact lockfile install mode"
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
	assert_eq "8.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "dependency-complete candidate activates after install"
	return 0
}

test_missing_dependency_lock_preserves_active_bundle() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "8.1.0" "dependency-lock-missing"
	write_fake_plugin_manifest
	rm -f "$FAKE_REPO/.agents/plugins/opencode-aidevops/package-lock.json"
	MOCK_PLUGIN_VERIFY_MODE="recover"
	rm -f "$TEST_ROOT/npm-called" "$TEST_ROOT/npm-install-complete"

	if stage_revision "$target_dir"; then
		fail "plugin dependency install without a lockfile unexpectedly staged a bundle"
	fi
	[[ ! -f "$TEST_ROOT/npm-called" ]] || fail "missing dependency lockfile unexpectedly invoked npm"
	pass "missing dependency lockfile blocks npm before resolution"
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "missing dependency lockfile preserves active bundle"
	assert_eq "8.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "lockless candidate never becomes active"
	return 0
}

test_dependency_install_failure_preserves_active_bundle() {
	local target_dir="$HOME/.aidevops/agents"
	local active_before=""
	local active_after=""
	active_before=$(_runtime_bundle_resolve_root "$target_dir")
	write_fake_revision "9.0.0" "dependency-failure"
	write_fake_plugin_manifest
	MOCK_PLUGIN_VERIFY_MODE="failure"
	rm -f "$TEST_ROOT/npm-called" "$TEST_ROOT/npm-install-complete"

	if stage_revision "$target_dir"; then
		fail "plugin dependency install failure unexpectedly staged a bundle"
	fi
	[[ -f "$TEST_ROOT/npm-called" ]] || fail "failed dependency recovery invokes npm install"
	pass "failed dependency recovery invokes npm install"
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "plugin dependency install failure preserves active bundle"
	assert_eq "8.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "failed candidate never becomes active"
	return 0
}

test_plist_override_survives_two_bundle_activations() {
	local target_dir="$HOME/.aidevops/agents"
	local label="com.aidevops.aidevops-supervisor-pulse"
	local legacy_file="$target_dir/configs/plist-env-overrides.json"
	local stable_file="$HOME/.config/aidevops/plist-env-overrides.json"
	local active_root=""
	local output=""
	local version=""
	mkdir -p "${legacy_file%/*}"
	printf '{"%s":{"TEST_OVERRIDE":"survives-two-activations"}}\n' "$label" >"$legacy_file"

	for version in 10.0.0 11.0.0; do
		write_fake_revision "$version" "plist-override-$version"
		write_fake_plugin_manifest
		MOCK_PLUGIN_VERIFY_MODE="available"
		stage_revision "$target_dir"
		_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR"
		active_root=$(_runtime_bundle_resolve_root "$target_dir")
		[[ ! -f "$active_root/configs/plist-env-overrides.json" ]] || fail "active $version bundle contains user-owned plist overrides"
		output=$(_build_plist_env_overrides_xml "$label")
		[[ "$output" == *"TEST_OVERRIDE"* && "$output" == *"survives-two-activations"* ]] || fail "override missing after $version activation"
		pass "stable plist override applies after $version activation"
	done
	[[ -f "$stable_file" ]] || fail "legacy plist override was not migrated to stable config"
	pass "legacy plist override migrates outside runtime bundles"
	return 0
}

test_serialized_older_version_refuses_global_activation() {
	local target_dir="$HOME/.aidevops/agents"
	local stale_bundle=""
	local current_bundle=""
	local active_before=""
	local active_after=""

	write_fake_revision "12.0.0" "serialized-stale-version"
	stage_revision "$target_dir"
	stale_bundle="$_AIDEVOPS_STAGED_BUNDLE_DIR"
	write_fake_revision "13.0.0" "serialized-current-version"
	stage_revision "$target_dir"
	current_bundle="$_AIDEVOPS_STAGED_BUNDLE_DIR"
	_runtime_bundle_activate "$target_dir" "$current_bundle"
	active_before=$(_runtime_bundle_resolve_root "$target_dir")

	local output=""
	if output=$(_runtime_bundle_activate "$target_dir" "$stale_bundle" 2>&1); then
		fail "serialized older candidate unexpectedly replaced the active bundle"
	fi
	assert_output_contains "$output" "aidevops runtime-bundle rollback --help" \
		"stale activation diagnostic names the public rollback help path"
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "serialized older candidate preserves the active bundle"
	assert_eq "13.0.0" "$(tr -d '[:space:]' <"$target_dir/VERSION")" "serialized activation cannot move the global version backwards"
	return 0
}

test_same_version_ancestor_refuses_global_activation() {
	local target_dir="$HOME/.aidevops/agents"
	local stale_bundle=""
	local current_bundle=""
	local active_before=""
	local active_after=""

	write_fake_revision "14.0.0" "same-version-ancestor"
	stage_revision "$target_dir"
	stale_bundle="$_AIDEVOPS_STAGED_BUNDLE_DIR"
	set_bundle_manifest_sha "$stale_bundle" "1111111111111111111111111111111111111111"
	write_fake_revision "14.0.0" "same-version-descendant"
	stage_revision "$target_dir"
	current_bundle="$_AIDEVOPS_STAGED_BUNDLE_DIR"
	set_bundle_manifest_sha "$current_bundle" "2222222222222222222222222222222222222222"
	_runtime_bundle_activate "$target_dir" "$current_bundle"
	active_before=$(_runtime_bundle_resolve_root "$target_dir")

	install_mock_ancestor_git
	if _runtime_bundle_activate "$target_dir" "$stale_bundle"; then
		unset -f git
		fail "same-version ancestor unexpectedly replaced its active descendant"
	fi
	unset -f git
	active_after=$(_runtime_bundle_resolve_root "$target_dir")
	assert_eq "$active_before" "$active_after" "same-version ancestor candidate preserves the active descendant"
	assert_file_contains "$target_dir/scripts/helper.sh" 'same-version-descendant' "same-version ancestry guard preserves active source content"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	HOME="$TEST_ROOT/home"
	FAKE_REPO="$TEST_ROOT/repo"
	export HOME
	unset AIDEVOPS_AGENTS_DIR AGENTS_DIR
	mkdir -p "$HOME/.aidevops" "$FAKE_REPO"
	INSTALL_DIR="$FAKE_REPO"
	export INSTALL_DIR
	AIDEVOPS_AGENT_DEPLOY_MIN_FILES=1
	export AIDEVOPS_AGENT_DEPLOY_MIN_FILES

	test_manifest_value_reads_unterminated_final_line
	test_initial_activation_and_manifest
	test_interrupted_staging_preserves_active
	test_failed_activation_rolls_back
	test_process_pin_survives_activation
	test_setup_rebinds_stale_process_pin_to_active_bundle
	test_live_bundle_lease_survives_three_updates
	test_permission_denied_signal_check_preserves_live_lease
	test_proc_fallback_preserves_live_lease_without_ps
	test_stale_lease_and_old_bundle_are_pruned
	test_count_and_byte_pressure_preserve_protected_bundles
	test_runtime_bundle_inventory_explains_protection
	test_macos_and_linux_link_paths
	test_plugin_dependency_smoke_check
	install_mock_plugin_dependency_hooks
	test_dependency_install_recovery_activates_candidate
	test_missing_dependency_lock_preserves_active_bundle
	test_dependency_install_failure_preserves_active_bundle
	test_plist_override_survives_two_bundle_activations
	test_serialized_older_version_refuses_global_activation
	test_same_version_ancestor_refuses_global_activation

	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
