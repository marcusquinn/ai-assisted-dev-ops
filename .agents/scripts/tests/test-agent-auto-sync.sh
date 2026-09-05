#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
GITHUB_HELPER="$REPO_ROOT/.agents/scripts/github-cli-helper.sh"
VERSION_HELPER="$REPO_ROOT/.agents/scripts/version-manager.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""
TEST_HOME=""
TEST_REPO_SHA=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

write_mock_deploy_helper() {
	local deploy_path="$1"

	cat >"$deploy_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'AIDEVOPS_AGENTS_DIR=%s\n' "${AIDEVOPS_AGENTS_DIR-unset}" >>"${SYNC_ENV_LOG_PATH:?SYNC_ENV_LOG_PATH must be set}"
printf 'AGENTS_DIR=%s\n' "${AGENTS_DIR-unset}" >>"$SYNC_ENV_LOG_PATH"
printf '%s\n' "$*" >>"${SYNC_LOG_PATH:?SYNC_LOG_PATH must be set}"
if [[ "${MOCK_REQUIRE_OUTER_LOCK:-0}" == "1" &&
	! -d "$HOME/.aidevops/locks/runtime-transition.lock.d" ]]; then
	exit 91
fi
if [[ "${MOCK_DEPLOY_EXIT_CODE:-0}" -ne 0 ]]; then
	exit "$MOCK_DEPLOY_EXIT_CODE"
fi
if [[ "${MOCK_DEPLOY_SKIP_ACTIVATION:-0}" == "1" ]]; then
	exit 0
fi

repo_root=""
expected_sha=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		repo_root="$2"
		shift 2
		;;
	--expected-sha)
		expected_sha="$2"
		shift 2
		;;
	*) shift ;;
	esac
done
[[ -n "$repo_root" && -n "$expected_sha" ]]
source_sha=$(git -C "$repo_root" rev-parse HEAD)
[[ "$source_sha" == "$expected_sha" ]]
bundle_sha="$source_sha"
stamp_sha="$source_sha"
if [[ "${MOCK_DEPLOY_MODE:-current}" == "stale-active" ]]; then
	bundle_sha="1111111111111111111111111111111111111111"
elif [[ "${MOCK_DEPLOY_MODE:-current}" == "stale-stamp" ]]; then
	stamp_sha="1111111111111111111111111111111111111111"
fi
framework_version=""
IFS= read -r framework_version <"$repo_root/VERSION" || [[ -n "$framework_version" ]]
bundle_id="${framework_version}-${bundle_sha:0:12}-fixture"
bundle_root="$HOME/.aidevops/runtime-bundles/$bundle_id/agents"
rm -rf "${bundle_root%/agents}"
mkdir -p "$bundle_root/scripts/setup/modules"

for sentinel_pair in \
	"aidevops.sh|aidevops.sh" \
	".agents/scripts/version-manager-release.sh|scripts/version-manager-release.sh" \
	".agents/scripts/deploy-agents-on-merge.sh|scripts/deploy-agents-on-merge.sh" \
	".agents/scripts/runtime-bundle-manifest.sh|scripts/runtime-bundle-manifest.sh" \
	".agents/scripts/runtime-bundle-verifier.sh|scripts/runtime-bundle-verifier.sh" \
	".agents/scripts/setup/modules/agent-deploy.sh|scripts/setup/modules/agent-deploy.sh"; do
	source_rel="${sentinel_pair%%|*}"
	active_rel="${sentinel_pair#*|}"
	mkdir -p "$(dirname "$bundle_root/$active_rel")"
	cp "$repo_root/$source_rel" "$bundle_root/$active_rel"
done
if [[ "${MOCK_DEPLOY_MODE:-current}" == "stale-sentinel" ]]; then
	printf '%s\n' 'stale release helper' >"$bundle_root/scripts/version-manager-release.sh"
fi
cp "$repo_root/VERSION" "$bundle_root/VERSION"
if command -v sha256sum >/dev/null 2>&1; then
	cli_sha=$(sha256sum "$bundle_root/aidevops.sh" | cut -d' ' -f1)
else
	cli_sha=$(shasum -a 256 "$bundle_root/aidevops.sh" | cut -d' ' -f1)
fi
cat >"$bundle_root/.bundle-manifest" <<EOF_MANIFEST
schema=1
status=validated
bundle_id=$bundle_id
framework_version=$framework_version
git_sha=$bundle_sha
cli_sha256=$cli_sha
EOF_MANIFEST

active_link="$HOME/.aidevops/agents"
link_tmp="${active_link}.tmp.$$"
rm -f "$link_tmp"
ln -s "$bundle_root" "$link_tmp"
if [[ "$(uname -s)" == "Darwin" ]]; then
	mv -f -h "$link_tmp" "$active_link"
else
	mv -Tf "$link_tmp" "$active_link"
fi
printf '%s\n' "$stamp_sha" >"$HOME/.aidevops/.deployed-sha"
exit 0
EOF
	chmod +x "$deploy_path"
	return 0
}

create_sync_fixture_repo() {
	local repo_root="$1"

	mkdir -p "$repo_root/.agents/scripts/setup/modules"
	write_mock_deploy_helper "$repo_root/.agents/scripts/deploy-agents-on-merge.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$repo_root/setup.sh"
	printf '#!/usr/bin/env bash\nprintf \"fixture cli\\n\"\n' >"$repo_root/aidevops.sh"
	printf '9.9.9\n' >"$repo_root/VERSION"
	printf 'release fixture\n' >"$repo_root/.agents/scripts/version-manager-release.sh"
	printf 'manifest fixture\n' >"$repo_root/.agents/scripts/runtime-bundle-manifest.sh"
	printf 'verifier fixture\n' >"$repo_root/.agents/scripts/runtime-bundle-verifier.sh"
	printf 'agent deploy fixture\n' >"$repo_root/.agents/scripts/setup/modules/agent-deploy.sh"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git init -q "$repo_root"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_root" config user.email test@example.invalid
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_root" config user.name Test
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_root" config commit.gpgsign false
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_root" add .
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_root" commit -qm fixture
	TEST_REPO_SHA=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_root" rev-parse HEAD)
	return 0
}

write_mock_recovery_helper() {
	local helper_path="$1"

	cat >"$helper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SYNC_RECOVERY_LOG_PATH:?SYNC_RECOVERY_LOG_PATH must be set}"
if [[ "${MOCK_RECOVERY_EXIT_CODE:-0}" -ne 0 ]]; then
	exit "$MOCK_RECOVERY_EXIT_CODE"
fi
repo_root=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		repo_root="$2"
		shift 2
		;;
	*) shift ;;
	esac
done
[[ -n "$repo_root" ]]
printf 'SYNCHRONIZED_CANONICAL_MIRROR=true\n'
printf 'NEW_SHA=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
exit 0
EOF
	chmod +x "$helper_path"
	return 0
}

write_mock_git_wrapper() {
	local git_path="$1"

	cat >"$git_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo_root=""
if [[ "${1:-}" == "-C" ]]; then
	repo_root="${2:-}"
fi
if [[ "${MOCK_GIT_STATUS_FAIL:-0}" == "1" && "$repo_root" == "${SYNC_FIXTURE_REPO:-}" && "$*" == *" status "* ]]; then
	exit 128
fi
exec /usr/bin/git "$@"
EOF
	chmod +x "$git_path"
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	TEST_HOME="$TEST_DIR/home"
	trap teardown EXIT
	mkdir -p "$TEST_HOME/.aidevops" "$TEST_DIR/bin"
	create_sync_fixture_repo "$TEST_DIR/repo"
	write_mock_recovery_helper "$TEST_DIR/canonical-recovery-helper.sh"
	write_mock_git_wrapper "$TEST_DIR/bin/git"
	: >"$TEST_DIR/sync.log"
	: >"$TEST_DIR/sync-env.log"
	: >"$TEST_DIR/recovery.log"
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

invoke_github_sync() {
	local repo_slug="$1"
	local expected_sha="${2:-$TEST_REPO_SHA}"
	local pr_number="${3:-28665}"
	AIDEVOPS_SYNC_REPO_PATH="$TEST_DIR/repo" \
		AIDEVOPS_SYNC_DEPLOY_SCRIPT="$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" \
		AIDEVOPS_SYNC_RECOVERY_HELPER="$TEST_DIR/canonical-recovery-helper.sh" \
		HOME="$TEST_HOME" \
		PATH="$TEST_DIR/bin:$PATH" \
		SYNC_LOG_PATH="$TEST_DIR/sync.log" \
		SYNC_ENV_LOG_PATH="$TEST_DIR/sync-env.log" \
		SYNC_RECOVERY_LOG_PATH="$TEST_DIR/recovery.log" \
		SYNC_FIXTURE_REPO="$TEST_DIR/repo" \
		MOCK_GIT_STATUS_FAIL="${MOCK_GIT_STATUS_FAIL:-0}" \
		MOCK_RECOVERY_EXIT_CODE="${MOCK_RECOVERY_EXIT_CODE:-0}" \
		MOCK_DEPLOY_EXIT_CODE="${MOCK_DEPLOY_EXIT_CODE:-0}" \
		bash -c 'source "$1" && trigger_aidevops_post_merge_sync "$2" "$3" "$4"' _ \
		"$GITHUB_HELPER" "$repo_slug" "$expected_sha" "$pr_number"
	return 0
}

invoke_release_sync() {
	local repo_root="$1"
	local deployment_scope="${2:-incremental}"
	local mock_lane_source_pr="${MOCK_RELEASE_LANE_SOURCE_PR:-${AIDEVOPS_RELEASE_LANE_SOURCE_PR:-}}"
	local mock_lane_tag="${MOCK_RELEASE_LANE_TAG:-${AIDEVOPS_RELEASE_LANE_TAG:-}}"
	AIDEVOPS_SYNC_REPO_ROOT="$repo_root" \
		AIDEVOPS_RELEASE_DEPLOY_SCOPE="$deployment_scope" \
		AIDEVOPS_SYNC_DEPLOY_SCRIPT="$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" \
		HOME="$TEST_HOME" \
		SYNC_LOG_PATH="$TEST_DIR/sync.log" \
		SYNC_ENV_LOG_PATH="$TEST_DIR/sync-env.log" \
		MOCK_DEPLOY_EXIT_CODE="${MOCK_DEPLOY_EXIT_CODE:-0}" \
		MOCK_DEPLOY_MODE="${MOCK_DEPLOY_MODE:-current}" \
		AIDEVOPS_RELEASE_SQUASH_RECOVERY="${AIDEVOPS_RELEASE_SQUASH_RECOVERY:-0}" \
		AIDEVOPS_RELEASE_LANE_SOURCE_PR="${AIDEVOPS_RELEASE_LANE_SOURCE_PR:-}" \
		AIDEVOPS_RELEASE_LANE_TAG="${AIDEVOPS_RELEASE_LANE_TAG:-}" \
		MOCK_RELEASE_LANE_SOURCE_PR="$mock_lane_source_pr" \
		MOCK_RELEASE_LANE_TAG="$mock_lane_tag" \
		bash -c '
			source "$1"
			release_lane_setup_guard() {
				local repo_slug="$1"
				[[ -n "$repo_slug" ]] || return 1
				_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn \
					--argjson source_pr "${MOCK_RELEASE_LANE_SOURCE_PR:-0}" \
					--arg tag "${MOCK_RELEASE_LANE_TAG:-}" \
					"{active:true,source_pr:\$source_pr,tag:\$tag,phase:\"exact-tag-deployment\",terminal_receipt:null}") || return 1
				return 0
			}
			run_post_release_agent_sync
		' _ "$VERSION_HELPER"
	return $?
}

prepare_squash_integrated_release() {
	local repo_path="$1"
	local mode="${2:-complete}"
	local base_sha=""
	local active_sha=""
	local release_sha=""
	local special_path=$'active\nspecial.txt'

	base_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD) || return 1
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" checkout -qb active-branch
	printf 'active one\n' >"$repo_path/active-one.txt"
	printf 'active two\n' >"$repo_path/active-two.txt"
	if [[ "$mode" == "newline-changed" ]]; then
		printf 'active special\n' >"$repo_path/$special_path"
	fi
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add -A
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm "active branch changes"
	active_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD) || return 1
	invoke_release_sync "$repo_path" >/dev/null 2>&1 || return 1
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" checkout -q --detach "$base_sha"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" checkout active-branch -- active-one.txt active-two.txt
	if [[ "$mode" == "newline-changed" ]]; then
		PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" checkout active-branch -- "$special_path"
	fi
	case "$mode" in
	omitted) rm -f "$repo_path/active-two.txt" ;;
	changed) printf 'different release value\n' >"$repo_path/active-two.txt" ;;
	newline-changed) printf 'different special value\n' >"$repo_path/$special_path" ;;
	complete) ;;
	*) return 1 ;;
	esac
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add -A
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm "squash active branch"
	printf '9.9.10\n' >"$repo_path/VERSION"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add VERSION
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm "publish descendant release"
	release_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD) || return 1
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" -c tag.gpgSign=false tag v9.9.10 "$release_sha"
	printf '%s|%s\n' "$active_sha" "$release_sha"
	return 0
}

create_fake_repo() {
	local repo_name="$1"
	local remote_url="$2"
	local repo_path="$TEST_DIR/$repo_name"

	rm -f "$TEST_HOME/.aidevops/agents" "$TEST_HOME/.aidevops/.deployed-sha"
	mkdir -p "$repo_path/.agents/scripts/setup/modules"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git init -q "$repo_path"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" config user.email test@example.invalid
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" config user.name Test
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" config commit.gpgsign false
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" remote add origin "$remote_url"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$repo_path/setup.sh"
	printf '#!/usr/bin/env bash\nprintf "fixture cli\\n"\n' >"$repo_path/aidevops.sh"
	printf '9.9.9\n' >"$repo_path/VERSION"
	printf 'release fixture\n' >"$repo_path/.agents/scripts/version-manager-release.sh"
	printf 'deploy fixture\n' >"$repo_path/.agents/scripts/deploy-agents-on-merge.sh"
	printf 'manifest fixture\n' >"$repo_path/.agents/scripts/runtime-bundle-manifest.sh"
	printf 'verifier fixture\n' >"$repo_path/.agents/scripts/runtime-bundle-verifier.sh"
	printf 'agent deploy fixture\n' >"$repo_path/.agents/scripts/setup/modules/agent-deploy.sh"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add .
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm fixture
	printf '%s\n' "$repo_path"
	return 0
}

prepare_active_release_preservation() {
	local repo_path="$1"
	local topology="$2"
	local release_sha=""
	local active_sha=""
	local release_tree=""

	release_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD) || return 1
	case "$topology" in
	same-tree)
		PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit --allow-empty -qm "preserve release"
		active_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD) || return 1
		;;
	changed-tree)
		printf 'post-release change\n' >"$repo_path/preservation-change.txt"
		PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add preservation-change.txt
		PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm "change release tree"
		active_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD) || return 1
		;;
	unrelated)
		release_tree=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse 'HEAD^{tree}') || return 1
		active_sha=$(printf 'unrelated active bundle\n' | PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit-tree "$release_tree") || return 1
		PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" checkout -q --detach "$active_sha"
		;;
	*) return 1 ;;
	esac
	invoke_release_sync "$repo_path" >/dev/null 2>&1 || return 1
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" checkout -q --detach "$release_sha"
	printf '%s\n' "$active_sha"
	return 0
}

test_merge_sync_triggers_for_aidevops() {
	: >"$TEST_DIR/sync.log"
	: >"$TEST_DIR/recovery.log"
	invoke_github_sync "marcusquinn/aidevops"

	if grep -q -- "--repo $TEST_DIR/repo --expected-sha $TEST_REPO_SHA --quiet" "$TEST_DIR/sync.log" &&
		grep -q -- "fast-forward-current --repo $TEST_DIR/repo --branch" "$TEST_DIR/recovery.log" &&
		grep -q -- "--issue 28665 --confirm FAST_FORWARD_CANONICAL_BRANCH" "$TEST_DIR/recovery.log"; then
		print_result "merge sync propagates exact SHA through audited canonical fast-forward and deployment" 0
	else
		print_result "merge sync propagates exact SHA through audited canonical fast-forward and deployment" 1 "Expected recovery or deployment arguments were not recorded"
	fi
	return 0
}

test_merge_pr_resolves_and_propagates_merge_sha() {
	local propagation_log="$TEST_DIR/merge-propagation.log"
	local full_loop_log="$TEST_DIR/full-loop-merge.log"
	local output=""
	: >"$propagation_log"
	if ! output=$(MERGE_PROPAGATION_LOG="$propagation_log" MERGED_SHA="$TEST_REPO_SHA" \
		FULL_LOOP_LOG="$full_loop_log" \
		bash -c '
			source "$1"
			get_account_config() {
				local account_name="$1"
				[[ -n "$account_name" ]] || return 1
				printf "%s\n" "{\"owner\":\"marcusquinn\"}"
				return 0
			}
			gh() {
				local command_name="$1"
				local subcommand_name="$2"
				if [[ "$command_name" == "pr" && "$subcommand_name" == "view" ]]; then
					printf "{\"state\":\"MERGED\",\"mergedAt\":\"2026-07-27T00:00:00Z\",\"mergeCommit\":{\"oid\":\"%s\"}}\n" "$MERGED_SHA"
					return 0
				fi
				return 1
			}
			_run_full_loop_merge() {
				local pr_number="$1"
				local repo_slug="$2"
				local merge_method="$3"
				printf "merge %s %s --%s\n" "$pr_number" "$repo_slug" "$merge_method" >"$FULL_LOOP_LOG"
				return 0
			}
			trigger_aidevops_post_merge_sync() {
				local repo_slug="$1"
				local expected_sha="$2"
				local pr_number="$3"
				printf "%s|%s|%s\n" "$repo_slug" "$expected_sha" "$pr_number" >"$MERGE_PROPAGATION_LOG"
				return 0
			}
			merge_pr fixture aidevops 77 squash
		' _ "$GITHUB_HELPER" 2>&1); then
		print_result "merge helper resolves the observed merge commit before post-merge sync" 1 "$output"
		return 0
	fi

	local propagated=""
	local lifecycle_call=""
	propagated=$(<"$propagation_log")
	lifecycle_call=$(<"$full_loop_log")
	if [[ "$propagated" == "marcusquinn/aidevops|$TEST_REPO_SHA|77" &&
		"$lifecycle_call" == "merge 77 marcusquinn/aidevops --squash" ]]; then
		print_result "merge helper resolves the observed merge commit before post-merge sync" 0
	else
		print_result "merge helper resolves the observed merge commit before post-merge sync" 1 "Lifecycle: $lifecycle_call; propagated: $propagated"
	fi
	return 0
}

test_merge_pr_preserves_workflow_scope_guidance() {
	local output=""
	local status=0

	output=$(bash -c '
		source "$1"
		get_account_config() {
			local account_name="$1"
			[[ -n "$account_name" ]] || return 1
			printf "%s\n" "{\"owner\":\"marcusquinn\"}"
			return 0
		}
		_run_full_loop_merge() {
			local pr_number="$1"
			local repo_slug="$2"
			local merge_method="$3"
			[[ -n "$pr_number" && -n "$repo_slug" && -n "$merge_method" ]] || return 1
			printf "%s\n" "workflow scope is required"
			return 1
		}
		merge_pr fixture aidevops 77 squash
	' _ "$GITHUB_HELPER" 2>&1) || status=$?
	if [[ "$status" -ne 0 && "$output" == *"gh auth refresh -s workflow"* ]]; then
		print_result "lifecycle merge preserves workflow-scope remediation" 0
	else
		print_result "lifecycle merge preserves workflow-scope remediation" 1 "Status: $status; output: $output"
	fi
	return 0
}

test_merge_sync_accepts_verified_noop() {
	: >"$TEST_DIR/sync.log"
	local output=""
	output=$(MOCK_DEPLOY_EXIT_CODE=2 invoke_github_sync "marcusquinn/aidevops" 2>&1)

	if [[ "$output" == *"verified no-op"* ]] &&
		grep -q -- "--expected-sha $TEST_REPO_SHA" "$TEST_DIR/sync.log"; then
		print_result "merge sync distinguishes a verified no-op from deployment failure" 0
	else
		print_result "merge sync distinguishes a verified no-op from deployment failure" 1 "$output"
	fi
	return 0
}

test_merge_sync_skips_after_failed_recovery() {
	: >"$TEST_DIR/sync.log"
	local active_before=""
	local active_after=""
	local output=""
	active_before=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)
	output=$(MOCK_RECOVERY_EXIT_CODE=1 invoke_github_sync "marcusquinn/aidevops" 2>&1)
	active_after=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)

	if [[ ! -s "$TEST_DIR/sync.log" && "$active_before" == "$active_after" &&
		"$output" == *"canonical fast-forward failed"* ]]; then
		print_result "failed audited synchronization preserves the active bundle and skips deployment" 0
	else
		print_result "failed audited synchronization preserves the active bundle and skips deployment" 1 "$output"
	fi
	return 0
}

test_merge_sync_skips_dirty_canonical_mirror() {
	: >"$TEST_DIR/sync.log"
	: >"$TEST_DIR/recovery.log"
	local active_before=""
	local active_after=""
	local dirty_blob_before=""
	local dirty_blob_after=""
	local output=""
	active_before=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)
	printf '%s\n' '# unexpected canonical edit' >>"$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh"
	dirty_blob_before=$(/usr/bin/git hash-object "$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh")
	output=$(invoke_github_sync "marcusquinn/aidevops" 2>&1)
	active_after=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)
	dirty_blob_after=$(/usr/bin/git hash-object "$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh")
	/usr/bin/git -C "$TEST_DIR/repo" checkout -- .agents/scripts/deploy-agents-on-merge.sh

	if [[ ! -s "$TEST_DIR/sync.log" && ! -s "$TEST_DIR/recovery.log" &&
		"$active_before" == "$active_after" && "$dirty_blob_before" == "$dirty_blob_after" &&
		"$output" == *"detached or dirty"* ]]; then
		print_result "dirty canonical mirror remains byte-preserved and never reaches synchronization or deployment" 0
	else
		print_result "dirty canonical mirror remains byte-preserved and never reaches synchronization or deployment" 1 "$output"
	fi
	return 0
}

test_merge_sync_fails_closed_when_status_is_unreadable() {
	: >"$TEST_DIR/sync.log"
	: >"$TEST_DIR/recovery.log"
	local active_before=""
	local active_after=""
	local output=""
	active_before=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)
	output=$(MOCK_GIT_STATUS_FAIL=1 invoke_github_sync "marcusquinn/aidevops" 2>&1)
	active_after=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)

	if [[ ! -s "$TEST_DIR/sync.log" && ! -s "$TEST_DIR/recovery.log" &&
		"$active_before" == "$active_after" && "$output" == *"status could not be inspected safely"* ]]; then
		print_result "unreadable canonical status fails closed before synchronization or deployment" 0
	else
		print_result "unreadable canonical status fails closed before synchronization or deployment" 1 "$output"
	fi
	return 0
}

test_merge_sync_skips_concurrent_sha_mismatch() {
	: >"$TEST_DIR/sync.log"
	local active_before=""
	local active_after=""
	local output=""
	local concurrent_sha="1111111111111111111111111111111111111111"
	active_before=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)
	output=$(invoke_github_sync "marcusquinn/aidevops" "$concurrent_sha" 28666 2>&1)
	active_after=$(cd "$TEST_HOME/.aidevops/agents" && pwd -P)

	if [[ ! -s "$TEST_DIR/sync.log" && "$active_before" == "$active_after" &&
		"$output" == *"did not converge cleanly to expected commit"* ]]; then
		print_result "post-sync SHA mismatch fails closed instead of deploying whichever commit is present" 0
	else
		print_result "post-sync SHA mismatch fails closed instead of deploying whichever commit is present" 1 "$output"
	fi
	return 0
}

test_merge_sync_skips_other_repos() {
	: >"$TEST_DIR/sync.log"
	invoke_github_sync "marcusquinn/another-repo"

	if [[ ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "merge sync skips non-aidevops repos" 0
	else
		print_result "merge sync skips non-aidevops repos" 1 "Unexpected sync invocation recorded"
	fi
	return 0
}

test_release_sync_triggers_for_aidevops_remote() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-aidevops" "https://github.com/marcusquinn/aidevops.git")
	invoke_release_sync "$repo_path"

	if grep -q -- "--repo $repo_path --quiet --expected-sha" "$TEST_DIR/sync.log" && ! grep -q -- "--full" "$TEST_DIR/sync.log"; then
		print_result "release sync defaults to incremental for aidevops remote" 0
	else
		print_result "release sync triggers for aidevops remote" 1 "Release sync command was not recorded"
	fi
	return 0
}

test_release_sync_explicit_full() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-full" "https://github.com/marcusquinn/aidevops.git")
	invoke_release_sync "$repo_path" full
	if grep -q -- "--repo $repo_path --quiet --full --expected-sha" "$TEST_DIR/sync.log"; then
		print_result "release sync supports explicit full deployment" 0
	else
		print_result "release sync supports explicit full deployment" 1 "Full sync command was not recorded"
	fi
	return 0
}

test_release_sync_skips_other_remotes() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-other" "https://github.com/marcusquinn/other.git")
	invoke_release_sync "$repo_path"

	if [[ ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync skips non-aidevops remotes" 0
	else
		print_result "release sync skips non-aidevops remotes" 1 "Unexpected release sync invocation recorded"
	fi
	return 0
}

test_release_sync_propagates_deploy_failure() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-failure" "https://github.com/marcusquinn/aidevops.git")
	if MOCK_DEPLOY_EXIT_CODE=1 invoke_release_sync "$repo_path" >/dev/null 2>&1; then
		print_result "release sync propagates full deployment failure" 1 "Failure was reported as success"
	else
		print_result "release sync propagates full deployment failure" 0
	fi
	return 0
}

test_release_sync_accepts_version_without_trailing_newline() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-version-no-newline" "https://github.com/marcusquinn/aidevops.git")
	printf '9.9.9' >"$repo_path/VERSION"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add VERSION
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm "remove version trailing newline"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync accepts VERSION without a trailing newline" 0
	else
		print_result "release sync accepts VERSION without a trailing newline" 1 "Unterminated VERSION was rejected: $output"
	fi
	return 0
}

test_release_sync_rejects_stale_active_bundle() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-stale-active" "https://github.com/marcusquinn/aidevops.git")
	if output=$(MOCK_DEPLOY_MODE=stale-active invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a stale active bundle" 1 "Stale deployment was reported as converged"
	elif [[ "$output" == *"does not identify release commit"* && "$output" == *"provenance did not converge"* ]]; then
		print_result "release sync rejects a stale active bundle" 0
	else
		print_result "release sync rejects a stale active bundle" 1 "Missing actionable stale-active evidence: $output"
	fi
	return 0
}

test_release_sync_rejects_stale_deployed_sha() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-stale-stamp" "https://github.com/marcusquinn/aidevops.git")
	if output=$(MOCK_DEPLOY_MODE=stale-stamp invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a stale deployed SHA" 1 "Stale deployment stamp was reported as converged"
	elif [[ "$output" == *"deployed SHA"* && "$output" == *"does not match release commit"* ]]; then
		print_result "release sync rejects a stale deployed SHA" 0
	else
		print_result "release sync rejects a stale deployed SHA" 1 "Missing actionable stale-stamp evidence: $output"
	fi
	return 0
}

test_release_sync_rejects_stale_sentinel() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-stale-sentinel" "https://github.com/marcusquinn/aidevops.git")
	if output=$(MOCK_DEPLOY_MODE=stale-sentinel invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a stale sentinel hash" 1 "Stale release sentinel was reported as converged"
	elif [[ "$output" == *"active sentinel scripts/version-manager-release.sh"* && "$output" == *"does not match release commit"* ]]; then
		print_result "release sync rejects a stale sentinel hash" 0
	else
		print_result "release sync rejects a stale sentinel hash" 1 "Missing actionable stale-sentinel evidence: $output"
	fi
	return 0
}

test_release_sync_deploys_validated_active_ancestor() {
	local repo_path
	local active_sha=""
	local release_sha=""
	local deployed_sha=""
	local output=""
	repo_path=$(create_fake_repo "release-active-ancestor" "https://github.com/marcusquinn/aidevops.git")
	active_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD)
	if ! invoke_release_sync "$repo_path" >/dev/null 2>&1; then
		print_result "release sync deploys over a validated active ancestor" 1 "Could not prepare active ancestor $active_sha"
		return 0
	fi

	printf '9.9.10\n' >"$repo_path/VERSION"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add VERSION
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm "bump release version"
	release_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD)
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		IFS= read -r deployed_sha <"$TEST_HOME/.aidevops/.deployed-sha" || deployed_sha=""
	fi
	if [[ "$deployed_sha" == "$release_sha" ]] &&
		grep -q -- "--repo $repo_path --quiet --expected-sha $release_sha" "$TEST_DIR/sync.log" &&
		[[ "$output" == *"deployment and CLI convergence completed"* ]]; then
		print_result "release sync deploys over a validated active ancestor" 0
	else
		print_result "release sync deploys over a validated active ancestor" 1 "Expected deployment from active $active_sha to release $release_sha: $output"
	fi
	return 0
}

test_release_sync_accepts_validated_same_tree_descendant() {
	local repo_path
	local release_sha=""
	local active_sha=""
	local output=""
	repo_path=$(create_fake_repo "release-same-tree-descendant" "https://github.com/marcusquinn/aidevops.git")
	release_sha=$(PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" rev-parse HEAD)
	active_sha=$(prepare_active_release_preservation "$repo_path" same-tree)
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1) &&
		[[ ! -s "$TEST_DIR/sync.log" ]] &&
		[[ "$output" == *"release ${release_sha:0:12}"* ]] &&
		[[ "$output" == *"preservation merge ${active_sha:0:12}"* ]] &&
		[[ "$output" == *"verified no-op"* ]]; then
		print_result "release sync accepts an exact-verified same-tree preservation descendant without deployment" 0
	else
		print_result "release sync accepts an exact-verified same-tree preservation descendant without deployment" 1 "Expected verified no-op evidence without a deploy invocation: $output"
	fi
	return 0
}

test_release_sync_rejects_changed_tree_descendant() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-changed-tree-descendant" "https://github.com/marcusquinn/aidevops.git")
	prepare_active_release_preservation "$repo_path" changed-tree >/dev/null
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a changed-tree preservation descendant" 1 "Changed-tree descendant was reported as converged"
	elif [[ "$output" == *"tree differs from release"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync rejects a changed-tree preservation descendant" 0
	else
		print_result "release sync rejects a changed-tree preservation descendant" 1 "Missing fail-closed changed-tree evidence: $output"
	fi
	return 0
}

test_release_sync_rejects_unrelated_active_commit() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-unrelated-active" "https://github.com/marcusquinn/aidevops.git")
	prepare_active_release_preservation "$repo_path" unrelated >/dev/null
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects an unrelated active commit" 1 "Unrelated active commit was reported as converged"
	elif [[ "$output" == *"neither ancestry-related nor a lane-authorized squash-integrated source"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync rejects an unrelated active commit" 0
	else
		print_result "release sync rejects an unrelated active commit" 1 "Missing fail-closed ancestry evidence: $output"
	fi
	return 0
}

test_release_sync_recovers_verified_squash_integration() {
	local repo_path
	local release_sha=""
	local deployed_sha=""
	local evidence=""
	local output=""
	repo_path=$(create_fake_repo "release-squash-complete" "https://github.com/marcusquinn/aidevops.git")
	evidence=$(prepare_squash_integrated_release "$repo_path" complete) || {
		print_result "release sync recovers a verified squash-integrated active bundle" 1 "Could not prepare squash topology"
		return 0
	}
	release_sha="${evidence#*|}"
	: >"$TEST_DIR/sync.log"
	if output=$(AIDEVOPS_RELEASE_SQUASH_RECOVERY=1 AIDEVOPS_RELEASE_LANE_SOURCE_PR=90 \
		MOCK_REQUIRE_OUTER_LOCK=1 \
		AIDEVOPS_RELEASE_LANE_TAG=v9.9.10 invoke_release_sync "$repo_path" 2>&1); then
		IFS= read -r deployed_sha <"$TEST_HOME/.aidevops/.deployed-sha" || deployed_sha=""
	fi
	if [[ "$deployed_sha" == "$release_sha" && "$output" == *"verified squash integration"* ]] &&
		grep -q -- "--expected-sha $release_sha" "$TEST_DIR/sync.log"; then
		print_result "release sync recovers a verified squash-integrated active bundle" 0
	else
		print_result "release sync recovers a verified squash-integrated active bundle" 1 "$output"
	fi
	return 0
}

test_release_sync_rejects_incomplete_squash_evidence() {
	local mode=""
	local repo_path=""
	local output=""
	for mode in omitted changed newline-changed; do
		repo_path=$(create_fake_repo "release-squash-$mode" "https://github.com/marcusquinn/aidevops.git")
		prepare_squash_integrated_release "$repo_path" "$mode" >/dev/null || {
			print_result "release sync rejects $mode squash integration" 1 "Could not prepare squash topology"
			continue
		}
		: >"$TEST_DIR/sync.log"
		if output=$(AIDEVOPS_RELEASE_SQUASH_RECOVERY=1 AIDEVOPS_RELEASE_LANE_SOURCE_PR=90 \
			AIDEVOPS_RELEASE_LANE_TAG=v9.9.10 invoke_release_sync "$repo_path" 2>&1); then
			print_result "release sync rejects $mode squash integration" 1 "Incomplete evidence was accepted"
		elif [[ "$output" == *"changed path is not identical"* && ! -s "$TEST_DIR/sync.log" ]]; then
			print_result "release sync rejects $mode squash integration" 0
		else
			print_result "release sync rejects $mode squash integration" 1 "$output"
		fi
	done
	return 0
}

test_release_sync_requires_matching_squash_lane() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-squash-lane" "https://github.com/marcusquinn/aidevops.git")
	prepare_squash_integrated_release "$repo_path" complete >/dev/null
	: >"$TEST_DIR/sync.log"
	if output=$(AIDEVOPS_RELEASE_SQUASH_RECOVERY=1 AIDEVOPS_RELEASE_LANE_SOURCE_PR=90 \
		AIDEVOPS_RELEASE_LANE_TAG=v9.9.9 invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync requires matching squash-recovery lane tag" 1 "Mismatched lane tag was accepted"
	elif [[ "$output" == *"lane-authorized squash-integrated source"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync requires matching squash-recovery lane tag" 0
	else
		print_result "release sync requires matching squash-recovery lane tag" 1 "$output"
	fi
	: >"$TEST_DIR/sync.log"
	if output=$(AIDEVOPS_RELEASE_SQUASH_RECOVERY=1 AIDEVOPS_RELEASE_LANE_SOURCE_PR=91 \
		AIDEVOPS_RELEASE_LANE_TAG=v9.9.10 MOCK_RELEASE_LANE_SOURCE_PR=90 \
		invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync requires matching squash-recovery lane owner" 1 "Mismatched lane owner was accepted"
	elif [[ "$output" == *"lane-authorized squash-integrated source"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync requires matching squash-recovery lane owner" 0
	else
		print_result "release sync requires matching squash-recovery lane owner" 1 "$output"
	fi
	return 0
}

test_release_sync_rejects_dirty_exact_tag_source() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-squash-dirty" "https://github.com/marcusquinn/aidevops.git")
	prepare_squash_integrated_release "$repo_path" complete >/dev/null
	printf 'concurrent source change\n' >"$repo_path/concurrent-change.txt"
	: >"$TEST_DIR/sync.log"
	if output=$(AIDEVOPS_RELEASE_SQUASH_RECOVERY=1 AIDEVOPS_RELEASE_LANE_SOURCE_PR=90 \
		AIDEVOPS_RELEASE_LANE_TAG=v9.9.10 invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects concurrent exact-tag source changes" 1 "Dirty source was deployed"
	elif [[ "$output" == *"dirty, changed, or concurrently replaced exact-tag source"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync rejects concurrent exact-tag source changes" 0
	else
		print_result "release sync rejects concurrent exact-tag source changes" 1 "$output"
	fi
	return 0
}

test_release_sync_rejects_malformed_active_manifest() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-malformed-active" "https://github.com/marcusquinn/aidevops.git")
	prepare_active_release_preservation "$repo_path" same-tree >/dev/null
	printf 'schema=1\nstatus=validated\n' >"$TEST_HOME/.aidevops/agents/.bundle-manifest"
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a malformed active manifest before deployment" 1 "Malformed active manifest was replaced or reported as converged"
	elif [[ "$output" == *"manifest git SHA is missing or invalid"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync rejects a malformed active manifest before deployment" 0
	else
		print_result "release sync rejects a malformed active manifest before deployment" 1 "Missing fail-closed manifest evidence: $output"
	fi
	return 0
}

test_release_sync_rejects_same_tree_descendant_with_stale_stamp() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-same-tree-stale-stamp" "https://github.com/marcusquinn/aidevops.git")
	prepare_active_release_preservation "$repo_path" same-tree >/dev/null
	printf '1111111111111111111111111111111111111111\n' >"$TEST_HOME/.aidevops/.deployed-sha"
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a same-tree descendant with a stale deployment stamp" 1 "Stale stamp was reported as converged"
	elif [[ "$output" == *"deployed SHA"* && "$output" == *"does not match release commit"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync rejects a same-tree descendant with a stale deployment stamp" 0
	else
		print_result "release sync rejects a same-tree descendant with a stale deployment stamp" 1 "Missing exact-verifier stamp evidence: $output"
	fi
	return 0
}

test_release_sync_rejects_same_tree_descendant_with_stale_sentinel() {
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-same-tree-stale-sentinel" "https://github.com/marcusquinn/aidevops.git")
	prepare_active_release_preservation "$repo_path" same-tree >/dev/null
	printf 'stale release helper\n' >"$TEST_HOME/.aidevops/agents/scripts/version-manager-release.sh"
	: >"$TEST_DIR/sync.log"

	if output=$(invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects a same-tree descendant with a stale sentinel" 1 "Stale sentinel was reported as converged"
	elif [[ "$output" == *"active sentinel scripts/version-manager-release.sh"* && "$output" == *"does not match release commit"* && ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync rejects a same-tree descendant with a stale sentinel" 0
	else
		print_result "release sync rejects a same-tree descendant with a stale sentinel" 1 "Missing exact-verifier sentinel evidence: $output"
	fi
	return 0
}

test_release_sync_unsets_session_pins() {
	: >"$TEST_DIR/sync-env.log"
	local repo_path
	repo_path=$(create_fake_repo "release-pinned" "https://github.com/marcusquinn/aidevops.git")
	AIDEVOPS_AGENTS_DIR="$TEST_DIR/.aidevops/runtime-bundles/old/agents" \
		AGENTS_DIR="$TEST_DIR/.aidevops/runtime-bundles/old/agents" \
		invoke_release_sync "$repo_path"

	if grep -q '^AIDEVOPS_AGENTS_DIR=unset$' "$TEST_DIR/sync-env.log" &&
		grep -q '^AGENTS_DIR=unset$' "$TEST_DIR/sync-env.log"; then
		print_result "release sync isolates inherited runtime pins" 0
	else
		print_result "release sync isolates inherited runtime pins" 1 "Deployment child inherited a session pin"
	fi
	return 0
}

main() {
	echo "Running agent auto-sync regression tests"
	setup

	test_merge_pr_resolves_and_propagates_merge_sha
	test_merge_pr_preserves_workflow_scope_guidance
	test_merge_sync_triggers_for_aidevops
	test_merge_sync_accepts_verified_noop
	test_merge_sync_skips_after_failed_recovery
	test_merge_sync_skips_dirty_canonical_mirror
	test_merge_sync_fails_closed_when_status_is_unreadable
	test_merge_sync_skips_concurrent_sha_mismatch
	test_merge_sync_skips_other_repos
	test_release_sync_triggers_for_aidevops_remote
	test_release_sync_explicit_full
	test_release_sync_skips_other_remotes
	test_release_sync_propagates_deploy_failure
	test_release_sync_accepts_version_without_trailing_newline
	test_release_sync_rejects_stale_active_bundle
	test_release_sync_rejects_stale_deployed_sha
	test_release_sync_rejects_stale_sentinel
	test_release_sync_deploys_validated_active_ancestor
	test_release_sync_accepts_validated_same_tree_descendant
	test_release_sync_rejects_changed_tree_descendant
	test_release_sync_rejects_unrelated_active_commit
	test_release_sync_recovers_verified_squash_integration
	test_release_sync_rejects_incomplete_squash_evidence
	test_release_sync_requires_matching_squash_lane
	test_release_sync_rejects_dirty_exact_tag_source
	test_release_sync_rejects_malformed_active_manifest
	test_release_sync_rejects_same_tree_descendant_with_stale_stamp
	test_release_sync_rejects_same_tree_descendant_with_stale_sentinel
	test_release_sync_unsets_session_pins

	teardown
	trap - EXIT
	echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
