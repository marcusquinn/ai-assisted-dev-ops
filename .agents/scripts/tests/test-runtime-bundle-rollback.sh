#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ROLLBACK_HELPER="$REPO_ROOT/.agents/scripts/runtime-bundle-rollback-helper.sh"
AUDIT_HELPER="$REPO_ROOT/.agents/scripts/audit-log-helper.sh"
TEST_ROOT=""
FAKE_REPO=""
TARGET_ID=""
TARGET_SHA=""
CURRENT_ID=""
CURRENT_SHA=""
TESTS_RUN=0

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

assert_contains() {
	local value="$1"
	local expected="$2"
	local message="$3"
	[[ "$value" == *"$expected"* ]] || fail "$message"
	pass "$message"
	return 0
}

sha256_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | cut -d' ' -f1
	else
		shasum -a 256 "$file" | cut -d' ' -f1
	fi
	return 0
}

resolved_link() {
	local link_path="$1"
	(cd "$link_path" && pwd -P) || return 1
	return 0
}

write_revision() {
	local version="$1"
	local marker="$2"
	local path=""
	mkdir -p "$FAKE_REPO/.agents/scripts/setup/modules"
	printf '%s\n' "$version" >"$FAKE_REPO/VERSION"
	printf '#!/usr/bin/env bash\nprintf %s\\n "%s"\n' '%s' "$marker" >"$FAKE_REPO/aidevops.sh"
	chmod +x "$FAKE_REPO/aidevops.sh"
	for path in \
		version-manager-release.sh \
		deploy-agents-on-merge.sh \
		runtime-bundle-manifest.sh \
		runtime-bundle-verifier.sh; do
		printf '%s %s\n' "$marker" "$path" >"$FAKE_REPO/.agents/scripts/$path"
	done
	printf '%s agent-deploy\n' "$marker" >"$FAKE_REPO/.agents/scripts/setup/modules/agent-deploy.sh"
	git -C "$FAKE_REPO" add VERSION aidevops.sh .agents
	git -C "$FAKE_REPO" -c user.name='Rollback Test' -c user.email='rollback-test@example.invalid' \
		commit -q -m "fixture: $marker"
	return 0
}

create_bundle() {
	local version="$1"
	local git_sha="$2"
	local bundle_id="${version}-${git_sha:0:12}-fixture"
	local bundle_dir="$HOME/.aidevops/runtime-bundles/$bundle_id"
	local agents_root="$bundle_dir/agents"
	local source_path=""
	local active_path=""
	local cli_sha=""

	mkdir -p "$agents_root/scripts/setup/modules"
	git -C "$FAKE_REPO" show "${git_sha}:VERSION" >"$agents_root/VERSION"
	git -C "$FAKE_REPO" show "${git_sha}:aidevops.sh" >"$agents_root/aidevops.sh"
	chmod +x "$agents_root/aidevops.sh"
	for source_path in \
		.agents/scripts/version-manager-release.sh \
		.agents/scripts/deploy-agents-on-merge.sh \
		.agents/scripts/runtime-bundle-manifest.sh \
		.agents/scripts/runtime-bundle-verifier.sh \
		.agents/scripts/setup/modules/agent-deploy.sh; do
		active_path="${source_path#.agents/}"
		git -C "$FAKE_REPO" show "${git_sha}:${source_path}" >"$agents_root/$active_path"
	done
	cli_sha=$(sha256_file "$agents_root/aidevops.sh")
	{
		printf 'schema=1\n'
		printf 'status=validated\n'
		printf 'bundle_id=%s\n' "$bundle_id"
		printf 'framework_version=%s\n' "$version"
		printf 'cli_compatibility=%s\n' "$version"
		printf 'git_sha=%s\n' "$git_sha"
		printf 'agents_file_count=7\n'
		printf 'cli_sha256=%s\n' "$cli_sha"
		printf 'plugin_entry_sha256=missing\n'
	} >"$bundle_dir/manifest"
	cp "$bundle_dir/manifest" "$agents_root/.bundle-manifest"
	printf '%s\n' "$bundle_id"
	return 0
}

reset_runtime_links() {
	local previous_target="${1:-$TARGET_ID}"
	ln -sfn "$HOME/.aidevops/runtime-bundles/$CURRENT_ID/agents" "$HOME/.aidevops/agents"
	if [[ "$previous_target" == "absent" ]]; then
		rm -f "$HOME/.aidevops/previous-runtime-bundle"
	else
		ln -sfn "$HOME/.aidevops/runtime-bundles/$previous_target/agents" \
			"$HOME/.aidevops/previous-runtime-bundle"
	fi
	printf '%s\n' "$CURRENT_SHA" >"$HOME/.aidevops/.deployed-sha"
	return 0
}

run_rollback() {
	AIDEVOPS_INSTALL_DIR="$FAKE_REPO" bash "$ROLLBACK_HELPER" rollback "$@"
	return $?
}

test_inventory_and_help() {
	local output=""
	output=$(AIDEVOPS_INSTALL_DIR="$FAKE_REPO" bash "$ROLLBACK_HELPER" list)
	assert_contains "$output" "$TARGET_ID" "inventory lists the retained rollback target"
	assert_contains "$output" "$CURRENT_ID" "inventory lists the active validated bundle"
	[[ "$output" != *"invalid-${TARGET_SHA:0:12}-fixture"* ]] || fail "inventory listed a mismatched manifest"
	pass "inventory excludes invalid retained directories"
	output=$(bash "$ROLLBACK_HELPER" rollback --help)
	assert_contains "$output" "--bundle-id <id> --reason <text>" "rollback help documents explicit ID and reason inputs"
	assert_contains "$output" "never a filesystem path" "rollback help rejects raw target paths"
	return 0
}

test_invalid_attempts_are_audited() {
	local audit_file="$HOME/.aidevops/logs/runtime-bundle-rollback-audit.jsonl"
	local blocked_count=""
	if run_rollback --bundle-id "$TARGET_ID" >/dev/null 2>&1; then
		fail "rollback without a reason unexpectedly succeeded"
	fi
	if run_rollback --bundle-id ../outside --reason "invalid path target" >/dev/null 2>&1; then
		fail "rollback accepted a path-like bundle ID"
	fi
	if run_rollback --bundle-id "invalid-${TARGET_SHA:0:12}-fixture" --reason "mismatched manifest" >/dev/null 2>&1; then
		fail "rollback accepted a mismatched manifest bundle"
	fi
	blocked_count=$(jq -s '[.[] | select(.detail.outcome == "blocked")] | length' "$audit_file")
	assert_eq "3" "$blocked_count" "invalid attempts append one blocked audit event each"
	jq -e -s 'all(.[];
		.detail.operation == "runtime-bundle-rollback" and
		(.detail | has("reason") and has("source_bundle_id") and has("source_version") and
		 has("source_git_sha") and has("target_bundle_id") and has("target_version") and
		 has("target_git_sha")))' "$audit_file" >/dev/null || fail "blocked audit events omitted required metadata"
	pass "blocked audit events include source, target, reason, and outcome metadata"
	assert_eq "$HOME/.aidevops/runtime-bundles/$CURRENT_ID/agents" \
		"$(resolved_link "$HOME/.aidevops/agents")" "invalid attempts preserve the active runtime"
	return 0
}

test_lock_contention_is_terminal_and_audited() {
	local lock_dir="$TEST_ROOT/runtime-transition.lock.d"
	local last_outcome=""
	mkdir -p "$lock_dir"
	printf '%s\n' "$$" >"$lock_dir/pid"
	if AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR="$lock_dir" \
		AIDEVOPS_RUNTIME_TRANSITION_LOCK_WAIT_SECONDS=0 \
		run_rollback --bundle-id "$TARGET_ID" --reason "lock contention fixture" >/dev/null 2>&1; then
		fail "rollback ignored runtime transition lock contention"
	fi
	rm -f "$lock_dir/pid"
	rmdir "$lock_dir"
	last_outcome=$(jq -r -s '.[-1].detail.outcome' "$HOME/.aidevops/logs/runtime-bundle-rollback-audit.jsonl")
	assert_eq "blocked" "$last_outcome" "lock contention writes a blocked audit outcome"
	assert_eq "$HOME/.aidevops/runtime-bundles/$CURRENT_ID/agents" \
		"$(resolved_link "$HOME/.aidevops/agents")" "lock contention preserves the active runtime"
	return 0
}

test_verification_failure_restores_all_state() {
	local lease_file="$HOME/.aidevops/runtime-bundles/.leases/$TARGET_ID/4242"
	local pin_file="$HOME/.config/aidevops/pulse-runtime-pin.conf"
	local lease_before=""
	local pin_before=""
	local previous_before=""
	local stamp_after=""
	reset_runtime_links "$TARGET_ID"
	previous_before=$(resolved_link "$HOME/.aidevops/previous-runtime-bundle")
	lease_before=$(sha256_file "$lease_file")
	pin_before=$(sha256_file "$pin_file")
	if AIDEVOPS_RUNTIME_BUNDLE_ROLLBACK_FAIL_AT=post-switch-verification \
		run_rollback --bundle-id "$TARGET_ID" --reason "forced verification failure" >/dev/null 2>&1; then
		fail "injected post-switch verification failure unexpectedly succeeded"
	fi
	assert_eq "$HOME/.aidevops/runtime-bundles/$CURRENT_ID/agents" \
		"$(resolved_link "$HOME/.aidevops/agents")" "verification failure restores the captured active root"
	assert_eq "$previous_before" "$(resolved_link "$HOME/.aidevops/previous-runtime-bundle")" \
		"verification failure restores the prior previous-runtime link"
	IFS= read -r stamp_after <"$HOME/.aidevops/.deployed-sha"
	assert_eq "$CURRENT_SHA" "$stamp_after" "verification failure restores the deployed SHA stamp"
	assert_eq "$lease_before" "$(sha256_file "$lease_file")" "failed rollback leaves process leases unchanged"
	assert_eq "$pin_before" "$(sha256_file "$pin_file")" "failed rollback leaves the Pulse runtime pin unchanged"
	return 0
}

test_success_updates_links_and_audit() {
	local lease_file="$HOME/.aidevops/runtime-bundles/.leases/$TARGET_ID/4242"
	local pin_file="$HOME/.config/aidevops/pulse-runtime-pin.conf"
	local lease_before=""
	local pin_before=""
	local stamp_after=""
	local audit_file="$HOME/.aidevops/logs/runtime-bundle-rollback-audit.jsonl"
	local output=""
	reset_runtime_links absent
	lease_before=$(sha256_file "$lease_file")
	pin_before=$(sha256_file "$pin_file")
	output=$(run_rollback --bundle-id "$TARGET_ID" --reason "operator regression recovery")
	assert_contains "$output" "Rolled back the active runtime bundle" "successful rollback reports the atomic transition"
	assert_eq "$HOME/.aidevops/runtime-bundles/$TARGET_ID/agents" \
		"$(resolved_link "$HOME/.aidevops/agents")" "successful rollback activates the selected retained bundle"
	assert_eq "$HOME/.aidevops/runtime-bundles/$CURRENT_ID/agents" \
		"$(resolved_link "$HOME/.aidevops/previous-runtime-bundle")" "successful rollback records the former active bundle as previous"
	IFS= read -r stamp_after <"$HOME/.aidevops/.deployed-sha"
	assert_eq "$TARGET_SHA" "$stamp_after" "successful rollback binds the deployed SHA to the target"
	assert_eq "$lease_before" "$(sha256_file "$lease_file")" "successful rollback leaves process leases unchanged"
	assert_eq "$pin_before" "$(sha256_file "$pin_file")" "successful rollback leaves the Pulse runtime pin unchanged"
	jq -e -s --arg source "$CURRENT_ID" --arg target "$TARGET_ID" \
		--arg source_sha "$CURRENT_SHA" --arg target_sha "$TARGET_SHA" '
		.[-1].type == "operation.verify" and
		.[-1].detail.outcome == "allowed" and
		.[-1].detail.reason == "operator regression recovery" and
		.[-1].detail.source_bundle_id == $source and
		.[-1].detail.target_bundle_id == $target and
		.[-1].detail.source_git_sha == $source_sha and
		.[-1].detail.target_git_sha == $target_sha
	' "$audit_file" >/dev/null || fail "successful rollback audit evidence is incomplete"
	pass "successful rollback writes complete tamper-evident audit metadata"
	AUDIT_LOG_FILE="$audit_file" bash "$AUDIT_HELPER" verify --quiet >/dev/null || fail "rollback audit chain verification failed"
	pass "rollback audit hash chain verifies"
	return 0
}

main() {
	local invalid_id=""
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	HOME="$TEST_ROOT/home"
	FAKE_REPO="$TEST_ROOT/repo"
	export HOME
	mkdir -p "$HOME/.aidevops/runtime-bundles" "$HOME/.config/aidevops" "$FAKE_REPO"
	HOME=$(cd "$HOME" && pwd -P)
	export HOME
	git -C "$FAKE_REPO" init -q
	write_revision "1.0.0" "retained-target"
	TARGET_SHA=$(git -C "$FAKE_REPO" rev-parse HEAD)
	TARGET_ID=$(create_bundle "1.0.0" "$TARGET_SHA")
	write_revision "2.0.0" "current-active"
	CURRENT_SHA=$(git -C "$FAKE_REPO" rev-parse HEAD)
	CURRENT_ID=$(create_bundle "2.0.0" "$CURRENT_SHA")
	invalid_id="invalid-${TARGET_SHA:0:12}-fixture"
	cp -a "$HOME/.aidevops/runtime-bundles/$TARGET_ID" "$HOME/.aidevops/runtime-bundles/$invalid_id"
	reset_runtime_links "$TARGET_ID"
	mkdir -p "$HOME/.aidevops/runtime-bundles/.leases/$TARGET_ID"
	printf '%s\n' "$HOME/.aidevops/runtime-bundles/$TARGET_ID/agents" \
		>"$HOME/.aidevops/runtime-bundles/.leases/$TARGET_ID/4242"
	printf 'agents_root=%s\nexpires_epoch=4102444800\n' \
		"$HOME/.aidevops/runtime-bundles/$TARGET_ID/agents" \
		>"$HOME/.config/aidevops/pulse-runtime-pin.conf"

	test_inventory_and_help
	test_invalid_attempts_are_audited
	test_lock_contention_is_terminal_and_audited
	test_verification_failure_restores_all_state
	test_success_updates_links_and_audit

	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
