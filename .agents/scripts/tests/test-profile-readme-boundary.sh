#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

export GIT_AUTHOR_NAME="Fixture"
export GIT_AUTHOR_EMAIL="fixture@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false
REAL_GIT=$(command -p -v git 2>/dev/null || command -v git)
export REAL_GIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SOURCE_HELPER="${SCRIPT_DIR}/../profile-readme-helper.sh"
SOURCE_DATA_LIB="${SCRIPT_DIR}/../profile-readme-data-lib.sh"
SOURCE_RENDER_LIB="${SCRIPT_DIR}/../profile-readme-render-lib.sh"
# shellcheck source=./lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${RESET} ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${TEST_RED}FAIL${RESET} ${test_name}"
		if [[ -n "$message" ]]; then
			echo "       ${message}"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	return 0
}

print_helper_failure() {
	local test_name="$1"
	local message="$2"
	local output_file="$3"

	print_result "$test_name" 1 "$message"
	if [[ ! -s "$output_file" ]]; then
		echo "       Captured helper output: <empty>"
		return 0
	fi

	echo "       Captured helper output:"
	sed -E \
		-e "s#${TEST_DIR}#<fixture>#g" \
		-e 's#(https?://)[^/@[:space:]]+@#\1<redacted>@#g' \
		"$output_file" |
		while IFS= read -r output_line; do
			printf '       | %s\n' "$output_line"
		done
	return 0
}

install_helper_with_libs() {
	local helper_dir="$1"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	cp "${SOURCE_HELPER}" "${helper_path}"
	chmod +x "${helper_path}"
	cp "${SOURCE_DATA_LIB}" "${helper_dir}/profile-readme-data-lib.sh"
	cp "${SOURCE_RENDER_LIB}" "${helper_dir}/profile-readme-render-lib.sh"
	_test_copy_shared_deps "${SOURCE_HELPER%/*}" "${helper_dir}" || return 1
	cp "${SOURCE_HELPER%/*}/audit-worktree-removal-helper.sh" \
		"${SOURCE_HELPER%/*}/shared-sqlite-backup.sh" \
		"${SOURCE_HELPER%/*}/shared-worktree-registry.sh" \
		"${SOURCE_HELPER%/*}/portable-stat.sh" \
		"${SOURCE_HELPER%/*}/screen-time-interval-engine.py" \
		"${SOURCE_HELPER%/*}/screen_time_interval_common.py" \
		"${SOURCE_HELPER%/*}/screen_time_macos.py" \
		"${SOURCE_HELPER%/*}/screen_time_macos_apps.py" \
		"${SOURCE_HELPER%/*}/screen_time_linux.py" \
		"${SOURCE_HELPER%/*}/screen_time_linux_logind.py" \
		"${SOURCE_HELPER%/*}/screen_time_linux_wtmp.py" \
		"${SOURCE_HELPER%/*}/screen_time_history.py" \
		"${SOURCE_HELPER%/*}/worktree-recovery-cache-policy.py" \
		"${SOURCE_HELPER%/*}/worktree_recovery_cache_policy_common.py" \
		"${SOURCE_HELPER%/*}/worktree_recovery_cache_policy_operations.py" "$helper_dir/"
	# Keep this profile-boundary fixture independent of host /proc visibility.
	# Shared worktree-removal guard behaviour has dedicated tests; this stub proves
	# the profile helper invokes cleanup from the canonical checkout after its
	# publication child exits.
	cat >"${helper_dir}/worktree-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

operation="${1:-}"
target="${2:-}"
[[ "$operation" == "remove" && -n "$target" ]] || exit 1
"${REAL_GIT:?}" worktree remove --force "$target"
exit 0
EOF
	chmod +x "${helper_dir}/worktree-helper.sh"
	return 0
}

write_stub_dependencies() {
	local stub_dir="$1"

	cat >"${stub_dir}/screen-time-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "profile-stats" ]]; then
	printf '%s\n' '{"today_hours":1.0,"week_hours":2.0,"month_hours":3.0,"year_hours":4.0}'
else
	printf '%s\n' '{}'
fi
return 0 2>/dev/null || exit 0
EOF

	cat >"${stub_dir}/contributor-activity-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "session-time" ]]; then
	if [[ " $* " == *" --period profile "* ]]; then
		printf '%s\n' '{"day":{"interactive_human_hours":1.0,"interactive_machine_hours":1.0,"worker_human_hours":2.0,"worker_machine_hours":3.0,"total_human_hours":3.0,"total_machine_hours":4.0,"interactive_sessions":6,"worker_sessions":7},"week":{"interactive_human_hours":1.0,"interactive_machine_hours":1.0,"worker_human_hours":2.0,"worker_machine_hours":3.0,"total_human_hours":3.0,"total_machine_hours":4.0,"interactive_sessions":6,"worker_sessions":7},"28d":{"interactive_human_hours":1.0,"interactive_machine_hours":1.0,"worker_human_hours":2.0,"worker_machine_hours":3.0,"total_human_hours":3.0,"total_machine_hours":4.0,"interactive_sessions":6,"worker_sessions":7},"year":{"interactive_human_hours":1.0,"interactive_machine_hours":1.0,"worker_human_hours":2.0,"worker_machine_hours":3.0,"total_human_hours":3.0,"total_machine_hours":4.0,"interactive_sessions":6,"worker_sessions":7}}'
	else
		printf '%s\n' '{"interactive_human_hours":1.0,"interactive_machine_hours":1.0,"worker_human_hours":2.0,"worker_machine_hours":3.0,"total_human_hours":3.0,"total_machine_hours":4.0,"interactive_sessions":6,"worker_sessions":7}'
	fi
else
	printf '%s\n' '{}'
fi
return 0 2>/dev/null || exit 0
EOF

	chmod +x "${stub_dir}/screen-time-helper.sh" "${stub_dir}/contributor-activity-helper.sh"
	return 0
}

create_profile_repo_fixture() {
	local fixture_home="$1"
	local profile_repo="$2"
	local remote_repo="$3"

	mkdir -p "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"

	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${profile_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	git init --bare --initial-branch=main "${remote_repo}" >/dev/null
	git init -b main "${profile_repo}" >/dev/null
	git -C "${profile_repo}" remote add origin "${remote_repo}"

	cat >"${profile_repo}/README.md" <<'EOF'
# Fixture Profile

![ManualBadgeA](https://example.com/a.svg)
![ManualBadgeB](https://example.com/b.svg)

Manual preface block that must not be rewritten.

<!-- STATS-START -->
Old stats block
<!-- STATS-END -->

Manual suffix block that must not be rewritten.

## Connect

- Stay in touch

<!-- UPDATED-START -->
Old timestamp
<!-- UPDATED-END -->
EOF

	git -C "${profile_repo}" add README.md
	git -C "${profile_repo}" commit -m "feat: seed fixture readme" >/dev/null
	git -C "${profile_repo}" push -u origin main >/dev/null

	return 0
}

read_remote_readme() {
	local remote_repo="$1"
	local output_file="$2"
	git --git-dir="$remote_repo" show main:README.md >"$output_file"
	return $?
}

strip_dynamic_sections() {
	local file_path="$1"
	awk '
		/<!-- STATS-START -->/ { print; skip_stats = 1; next }
		/<!-- STATS-END -->/ { skip_stats = 0; print; next }
		/<!-- UPDATED-START -->/ { print; skip_updated = 1; next }
		/<!-- UPDATED-END -->/ { skip_updated = 0; print; next }
		!skip_stats && !skip_updated { print }
	' "$file_path"
	return 0
}

test_update_preserves_manual_sections() {
	local test_name="profile update publishes once from a linked worktree and preserves the canonical checkout"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}"
	install_helper_with_libs "${helper_dir}"

	write_stub_dependencies "${helper_dir}"
	create_profile_repo_fixture "${fixture_home}" "${fixture_repo}" "${fixture_remote}"

	local before_file="${TEST_DIR}/before.md"
	local after_file="${TEST_DIR}/after.md"
	local update_output="${TEST_DIR}/update-output"
	cp "${fixture_repo}/README.md" "${before_file}"
	local canonical_head_before=""
	local remote_head_before=""
	canonical_head_before=$(git -C "$fixture_repo" rev-parse HEAD)
	remote_head_before=$(git --git-dir="$fixture_remote" rev-parse main)

	if ! HOME="${fixture_home}" \
		PATH="${SOURCE_HELPER%/*}:${PATH}" \
		AIDEVOPS_REPOS_FILE="${fixture_home}/.config/aidevops/repos.json" \
		AIDEVOPS_WORKTREE_BASE_DIR="${TEST_DIR}/worktrees" \
		bash "${helper_path}" update >"$update_output" 2>&1; then
		print_helper_failure "${test_name}" "helper update command failed" "$update_output"
		return 0
	fi

	read_remote_readme "$fixture_remote" "$after_file"

	local before_static
	local after_static
	before_static="$(strip_dynamic_sections "${before_file}")"
	after_static="$(strip_dynamic_sections "${after_file}")"

	if [[ "${before_static}" != "${after_static}" ]]; then
		print_result "${test_name}" 1 "content outside STATS/UPDATED markers changed"
		return 0
	fi

	if ! grep -q 'ManualBadgeA' "${after_file}" || ! grep -q 'ManualBadgeB' "${after_file}"; then
		print_result "${test_name}" 1 "manual badge lines missing after update"
		return 0
	fi
	if [[ "$canonical_head_before" != "$(git -C "$fixture_repo" rev-parse HEAD)" ]] ||
		[[ -n "$(git -C "$fixture_repo" status --porcelain --untracked-files=all)" ]] ||
		! cmp -s "$before_file" "${fixture_repo}/README.md"; then
		print_result "${test_name}" 1 "canonical profile checkout changed"
		return 0
	fi
	if [[ "$(git --git-dir="$fixture_remote" rev-list --count "${remote_head_before}..main")" != "1" ]]; then
		print_result "${test_name}" 1 "remote did not receive exactly one generated README commit"
		return 0
	fi
	if [[ "$(git -C "$fixture_repo" worktree list --porcelain | grep -c '^worktree ' || true)" != "1" ]] ||
		grep -q 'BLOCKED by canonical Git guard' "$update_output"; then
		print_result "${test_name}" 1 "publication worktree was not cleaned or canonical guard blocked publication"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_update_recovers_dirty_profile_publication_worktree() {
	local test_name="profile update recoverably removes its dirty scratch worktree after guarded cleanup refusal"
	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local refusing_helper="${helper_dir}/refusing-worktree-helper.sh"
	local recovery_root="${TEST_DIR}/recovery"
	local output_file="${TEST_DIR}/update-output"

	mkdir -p "$helper_dir" "$fixture_home"
	install_helper_with_libs "$helper_dir"
	write_stub_dependencies "$helper_dir"
	create_profile_repo_fixture "$fixture_home" "$fixture_repo" "$fixture_remote"
	cat >"$refusing_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${2:-}"
[[ -n "$target" ]] || exit 1
printf '%s\n' "recoverable fixture state" >"${target}/.profile-publication-fixture"
exit 1
EOF
	chmod +x "$refusing_helper"

	if ! HOME="$fixture_home" \
		PATH="${SOURCE_HELPER%/*}:${PATH}" \
		AIDEVOPS_REPOS_FILE="${fixture_home}/.config/aidevops/repos.json" \
		AIDEVOPS_WORKTREE_BASE_DIR="${TEST_DIR}/worktrees" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		AIDEVOPS_PROFILE_WORKTREE_HELPER="$refusing_helper" \
		bash "$helper_path" update >"$output_file" 2>&1; then
		print_helper_failure "$test_name" "helper update command failed" "$output_file"
		return 0
	fi

	if [[ "$(git -C "$fixture_repo" worktree list --porcelain | grep -c '^worktree ' || true)" != "1" ]] ||
		[[ ! -d "$recovery_root" ]] ||
		[[ -n "$(git -C "$fixture_repo" status --porcelain --untracked-files=all)" ]]; then
		print_helper_failure "$test_name" "scratch worktree leaked, recovery archive missing, or canonical checkout changed" "$output_file"
		return 0
	fi

	print_result "$test_name" 0
	return 0
}

test_update_dry_run_is_canonical_safe() {
	local test_name="profile update dry-run leaves canonical checkout and remote unchanged"
	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local output_file="${TEST_DIR}/dry-run-output"
	mkdir -p "$helper_dir" "$fixture_home"
	install_helper_with_libs "$helper_dir"
	write_stub_dependencies "$helper_dir"
	create_profile_repo_fixture "$fixture_home" "$fixture_repo" "$fixture_remote"

	local canonical_head_before=""
	local remote_head_before=""
	canonical_head_before=$(git -C "$fixture_repo" rev-parse HEAD)
	remote_head_before=$(git --git-dir="$fixture_remote" rev-parse main)
	if ! HOME="$fixture_home" \
		PATH="${SOURCE_HELPER%/*}:${PATH}" \
		AIDEVOPS_REPOS_FILE="${fixture_home}/.config/aidevops/repos.json" \
		AIDEVOPS_WORKTREE_BASE_DIR="${TEST_DIR}/worktrees" \
		bash "$helper_path" update --dry-run >"$output_file" 2>&1; then
		print_helper_failure "$test_name" "dry-run command failed" "$output_file"
		return 0
	fi
	if ! grep -q 'DRY RUN' "$output_file" ||
		[[ "$canonical_head_before" != "$(git -C "$fixture_repo" rev-parse HEAD)" ]] ||
		[[ "$remote_head_before" != "$(git --git-dir="$fixture_remote" rev-parse main)" ]] ||
		[[ -n "$(git -C "$fixture_repo" status --porcelain --untracked-files=all)" ]] ||
		[[ "$(git -C "$fixture_repo" worktree list --porcelain | grep -c '^worktree ' || true)" != "1" ]]; then
		print_result "$test_name" 1 "dry-run mutated state or left a publication worktree"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_update_prepublication_failure_is_canonical_safe() {
	local test_name="profile update pre-publication failure leaves canonical checkout unchanged"
	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local before_file="${TEST_DIR}/before.md"
	local output_file="${TEST_DIR}/failed-update-output"
	mkdir -p "$helper_dir" "$fixture_home"
	install_helper_with_libs "$helper_dir"
	write_stub_dependencies "$helper_dir"
	create_profile_repo_fixture "$fixture_home" "$fixture_repo" "$fixture_remote"
	git -C "$fixture_repo" remote set-url origin "${TEST_DIR}/missing-remote.git"
	cp "${fixture_repo}/README.md" "$before_file"
	local canonical_head_before=""
	canonical_head_before=$(git -C "$fixture_repo" rev-parse HEAD)

	if HOME="$fixture_home" \
		AIDEVOPS_WORKTREE_BASE_DIR="${TEST_DIR}/worktrees" \
		bash "$helper_path" update >"$output_file" 2>&1; then
		print_helper_failure "$test_name" "update unexpectedly succeeded with an unavailable remote" "$output_file"
		return 0
	fi
	if [[ "$canonical_head_before" != "$(git -C "$fixture_repo" rev-parse HEAD)" ]] ||
		[[ -n "$(git -C "$fixture_repo" status --porcelain --untracked-files=all)" ]] ||
		! cmp -s "$before_file" "${fixture_repo}/README.md" ||
		[[ "$(git -C "$fixture_repo" worktree list --porcelain | grep -c '^worktree ' || true)" != "1" ]]; then
		print_helper_failure "$test_name" "failed update changed canonical state or leaked a worktree" "$output_file"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_internal_override_rejects_canonical_checkout() {
	local test_name="profile publication override rejects a canonical checkout target"
	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	mkdir -p "$helper_dir" "$fixture_home"
	install_helper_with_libs "$helper_dir"
	write_stub_dependencies "$helper_dir"
	create_profile_repo_fixture "$fixture_home" "$fixture_repo" "$fixture_remote"
	local canonical_head_before=""
	canonical_head_before=$(git -C "$fixture_repo" rev-parse HEAD)

	if HOME="$fixture_home" \
		AIDEVOPS_PROFILE_PUBLICATION_WORKTREE=1 \
		AIDEVOPS_PROFILE_REPO_OVERRIDE="$fixture_repo" \
		AIDEVOPS_PROFILE_CANONICAL_REPO="$fixture_repo" \
		AIDEVOPS_PROFILE_UPDATE_LOCK_HELD=1 \
		bash "$helper_path" update >/dev/null 2>&1; then
		print_result "$test_name" 1 "internal override accepted the canonical checkout"
		return 0
	fi
	if [[ "$canonical_head_before" != "$(git -C "$fixture_repo" rev-parse HEAD)" ]] ||
		[[ -n "$(git -C "$fixture_repo" status --porcelain --untracked-files=all)" ]]; then
		print_result "$test_name" 1 "rejected override still changed canonical state"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_canonical_cleanliness_ignores_untracked_files() {
	local test_name="profile publication ignores untracked canonical files but rejects tracked changes"
	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	mkdir -p "$fixture_home"
	create_profile_repo_fixture "$fixture_home" "$fixture_repo" "$fixture_remote"

	local result
	result=$(
		set -- help
		# shellcheck source=../profile-readme-helper.sh
		source "$SOURCE_HELPER" >/dev/null
		printf '%s\n' harmless >"${fixture_repo}/.DS_Store"
		if ! _profile_assert_canonical_clean "$fixture_repo"; then
			printf '%s\n' untracked-rejected
			return 0
		fi
		printf '%s\n' mutation >>"${fixture_repo}/README.md"
		if _profile_assert_canonical_clean "$fixture_repo" 2>/dev/null; then
			printf '%s\n' tracked-accepted
			return 0
		fi
		printf '%s\n' ok
	)
	if [[ "$result" != "ok" ]]; then
		print_result "$test_name" 1 "unexpected cleanliness result: ${result}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_update_migrates_generated_readme_with_commit_history_chart() {
	local test_name="profile update adds commit-history chart to older generated README"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local update_output="${TEST_DIR}/update-output"

	mkdir -p "${helper_dir}" "${fixture_home}"
	install_helper_with_libs "${helper_dir}"
	write_stub_dependencies "${helper_dir}"
	create_profile_repo_fixture "${fixture_home}" "${fixture_repo}" "${fixture_remote}"
	cat >>"${fixture_repo}/README.md" <<'EOF'

> Stats auto-updated by [aidevops](https://aidevops.sh).

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://commit-history.com/embed/profile-repo?theme=dark" />
    <img alt="profile-repo's commit history" src="https://commit-history.com/embed/profile-repo" />
  </picture>
</div>
EOF
	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "test: mark fixture as generated" >/dev/null
	git -C "${fixture_repo}" push >/dev/null

	if ! HOME="${fixture_home}" bash "${helper_path}" update >"$update_output" 2>&1; then
		print_helper_failure "${test_name}" "first helper update command failed" "$update_output"
		return 0
	fi
	if ! HOME="${fixture_home}" bash "${helper_path}" update >"$update_output" 2>&1; then
		print_helper_failure "${test_name}" "second helper update command failed" "$update_output"
		return 0
	fi

	local readme="${TEST_DIR}/remote-readme.md"
	read_remote_readme "$fixture_remote" "$readme"
	if [[ "$(grep -c '<picture>' "$readme")" -ne 1 ]] ||
		! grep -Fq 'srcset="https://commit-history.com/embed/profile-repo?theme=dark"' "$readme" ||
		! grep -Fq 'src="https://commit-history.com/embed/profile-repo"' "$readme"; then
		print_result "${test_name}" 1 "migration did not add one username-specific chart"
		return 0
	fi
	if [[ "$(grep -c '<a href="https://commit-history.com/profile-repo">' "$readme")" -ne 1 ]]; then
		print_result "${test_name}" 1 "migrated chart is not linked to the username activity profile"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

teardown() {
	if [[ -n "${TEST_DIR}" && -d "${TEST_DIR}" ]]; then
		rm -rf "${TEST_DIR}"
	fi
	TEST_DIR=""
	return 0
}

test_inject_markers_into_existing_readme() {
	local test_name="inject markers into README without markers"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local update_output="${TEST_DIR}/update-output"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	install_helper_with_libs "${helper_dir}"
	write_stub_dependencies "${helper_dir}"

	# Create a bare remote and local clone with NO markers
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	# Write a user-authored README without any aidevops markers
	cat >"${fixture_repo}/README.md" <<'EOF'
# Hi there

I'm a developer who likes building things.

## My Projects

- Project A
- Project B
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "Initial commit" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	# Set up repos.json pointing to this repo
	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should inject markers and then update stats
	if ! HOME="${fixture_home}" bash "${helper_path}" update >"$update_output" 2>&1; then
		print_helper_failure "${test_name}" "helper update command failed" "$update_output"
		return 0
	fi

	local readme="${TEST_DIR}/remote-readme.md"
	read_remote_readme "$fixture_remote" "$readme"

	# Verify markers were injected
	if ! grep -q '<!-- STATS-START -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-START marker not found after update"
		return 0
	fi
	if ! grep -q '<!-- STATS-END -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-END marker not found after update"
		return 0
	fi

	# Verify original content was preserved
	if ! grep -q 'Hi there' "$readme"; then
		print_result "${test_name}" 1 "original heading lost after marker injection"
		return 0
	fi
	if ! grep -q 'Project A' "$readme"; then
		print_result "${test_name}" 1 "original content lost after marker injection"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_diverged_history_recovery() {
	local test_name="recover from diverged git history"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	install_helper_with_libs "${helper_dir}"
	write_stub_dependencies "${helper_dir}"

	# Create initial remote and local clone with markers
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	cat >"${fixture_repo}/README.md" <<'EOF'
# Profile

<!-- STATS-START -->
Old stats
<!-- STATS-END -->

<!-- UPDATED-START -->
<!-- UPDATED-END -->
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "feat: seed readme" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	# Simulate repo deletion and recreation: create a NEW remote with different history
	rm -rf "${fixture_remote}"
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null

	# Push a different initial commit to the new remote (simulating GitHub "Initial commit")
	local tmp_clone="${TEST_DIR}/tmp-clone"
	git clone "${fixture_remote}" "${tmp_clone}" 2>/dev/null
	echo "# fixture" >"${tmp_clone}/README.md"
	git -C "${tmp_clone}" add README.md
	git -C "${tmp_clone}" commit -m "Initial commit" >/dev/null
	git -C "${tmp_clone}" push -u origin main >/dev/null
	rm -rf "${tmp_clone}"

	# Set up repos.json
	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should detect diverged history and recover
	HOME="${fixture_home}" bash "${helper_path}" update >/dev/null 2>&1 || true

	local readme="${TEST_DIR}/remote-readme.md"
	read_remote_readme "$fixture_remote" "$readme"

	# After recovery, the README should have markers (either injected or from re-seed)
	if ! grep -q '<!-- STATS-START -->' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "STATS-START marker not found after recovery"
		return 0
	fi

	# Verify the local repo can now push to the remote (histories are aligned)
	if ! git -C "${fixture_repo}" push origin main 2>/dev/null; then
		# Try with --force since recovery may have created a new commit
		if ! git -C "${fixture_repo}" push --force origin main 2>/dev/null; then
			print_result "${test_name}" 1 "still cannot push after recovery"
			return 0
		fi
	fi

	print_result "${test_name}" 0
	return 0
}

test_default_template_replaced_with_rich_readme() {
	local test_name="default GitHub template replaced with rich profile README"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local update_output="${TEST_DIR}/update-output"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	mkdir -p "${fixture_home}/.aidevops/cache"
	install_helper_with_libs "${helper_dir}"
	write_stub_dependencies "${helper_dir}"

	# Create a bare remote and local clone with the default GitHub template
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	# Write the exact default GitHub profile template
	cat >"${fixture_repo}/README.md" <<'EOF'
## Hi there 👋

<!--
**fixture/fixture** is a ✨ _special_ ✨ repository because its `README.md` (this file) appears on your GitHub profile.

Here are some ideas to get you started:

- 🔭 I'm currently working on ...
- 🌱 I'm currently learning ...
- 👯 I'm looking to collaborate on ...
- 🤔 I'm looking for help with ...
- 💬 Ask me about ...
- 📫 How to reach me: ...
- 😄 Pronouns: ...
- ⚡ Fun fact: ...
-->
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "Initial commit" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	# Set up repos.json
	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should detect default template and replace with rich README
	if ! HOME="${fixture_home}" bash "${helper_path}" update >"$update_output" 2>&1; then
		print_helper_failure "${test_name}" "helper update command failed" "$update_output"
		return 0
	fi

	local readme="${TEST_DIR}/remote-readme.md"
	read_remote_readme "$fixture_remote" "$readme"

	# Verify the default template is gone
	if grep -q 'is a.*special.*repository' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "default GitHub template still present after update"
		return 0
	fi

	# Verify markers were added
	if ! grep -q '<!-- STATS-START -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-START marker not found after update"
		return 0
	fi

	# Verify it's a rich README (has the aidevops tagline)
	if ! grep -q 'aidevops' "$readme"; then
		print_result "${test_name}" 1 "aidevops reference not found — not a rich README"
		return 0
	fi

	# Verify the final generated block is theme-aware and links to the activity profile.
	if ! grep -Fq 'srcset="https://commit-history.com/embed/profile-repo?theme=dark"' "$readme" ||
		! grep -Fq 'src="https://commit-history.com/embed/profile-repo"' "$readme"; then
		print_result "${test_name}" 1 "commit-history light/dark image URLs missing"
		return 0
	fi
	if ! grep -Fq '<a href="https://commit-history.com/profile-repo">' "$readme"; then
		print_result "${test_name}" 1 "commit-history chart does not link to the username activity profile"
		return 0
	fi
	if [[ "$(tail -n 1 "$readme")" != "</div>" ]]; then
		print_result "${test_name}" 1 "commit-history chart is not the final README block"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_default_template_with_existing_markers_replaced() {
	local test_name="default template with existing markers gets replaced"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"
	local update_output="${TEST_DIR}/update-output"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	mkdir -p "${fixture_home}/.aidevops/cache"
	install_helper_with_libs "${helper_dir}"
	write_stub_dependencies "${helper_dir}"

	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	# Simulate Alex's exact case: default GitHub template with markers already
	# injected at the bottom (by v3.1.87 _inject_markers_into_readme)
	cat >"${fixture_repo}/README.md" <<'EOF'
## Hi there 👋

<!--
**fixture/fixture** is a ✨ _special_ ✨ repository because its `README.md` (this file) appears on your GitHub profile.

Here are some ideas to get you started:

- 🔭 I'm currently working on ...
- 🌱 I'm currently learning ...
-->

<!-- STATS-START -->
Old stats content
<!-- STATS-END -->

<!-- CONTRIBUTIONS-START -->
<!-- CONTRIBUTIONS-END -->

---

<!-- UPDATED-START -->
<!-- UPDATED-END -->
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "feat: markers injected into default template" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should detect default template despite markers and replace it
	if ! HOME="${fixture_home}" bash "${helper_path}" update >"$update_output" 2>&1; then
		print_helper_failure "${test_name}" "helper update command failed" "$update_output"
		return 0
	fi

	local readme="${TEST_DIR}/remote-readme.md"
	read_remote_readme "$fixture_remote" "$readme"

	# Verify the default template is gone
	if grep -q 'is a.*special.*repository' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "default GitHub template still present after update"
		return 0
	fi

	# Verify the "Hi there" heading is gone (replaced with rich profile heading)
	if grep -q 'Hi there' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "'Hi there' heading still present — template not replaced"
		return 0
	fi

	# Verify markers still exist
	if ! grep -q '<!-- STATS-START -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-START marker missing after replacement"
		return 0
	fi

	# Verify it's a rich README
	if ! grep -q 'aidevops' "$readme"; then
		print_result "${test_name}" 1 "aidevops reference not found — not a rich README"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_session_time_vars_default_missing_null_values() {
	local test_name="session time vars default missing and null values"

	TEST_DIR=$(mktemp -d)
	local stdout_file="${TEST_DIR}/stdout"
	local stderr_file="${TEST_DIR}/stderr"

	# shellcheck source=../profile-readme-data-lib.sh
	source "${SOURCE_DATA_LIB}"
	# shellcheck source=../profile-readme-render-lib.sh
	source "${SOURCE_RENDER_LIB}"

	local valid_json null_json empty_json assignments
	valid_json='{"interactive_human_hours":1.2,"interactive_machine_hours":0.3,"worker_human_hours":2,"worker_machine_hours":3,"total_human_hours":4,"total_machine_hours":5,"interactive_sessions":6,"worker_sessions":7}'
	null_json='{"interactive_human_hours":null,"interactive_machine_hours":null,"worker_human_hours":null,"worker_machine_hours":null,"total_human_hours":null,"total_machine_hours":null,"interactive_sessions":null,"worker_sessions":null}'
	empty_json='{}'

	if ! _generate_session_time_vars "${empty_json}" "${null_json}" "${valid_json}" "${valid_json}" >"${stdout_file}" 2>"${stderr_file}"; then
		print_result "${test_name}" 1 "session time var generation failed"
		return 0
	fi

	assignments=$(<"${stdout_file}")
	if grep -q 'printf: null' "${stderr_file}"; then
		print_result "${test_name}" 1 "printf emitted null numeric warning"
		return 0
	fi
	if grep -q 'null' "${stdout_file}"; then
		print_result "${test_name}" 1 "rendered shell assignments contain raw null"
		return 0
	fi

	local day_human day_interactive_machine day_worker_human day_worker day_total day_interactive day_workers
	local week_human week_interactive_machine week_worker_human week_worker week_total week_interactive week_workers
	local month_human month_interactive_machine month_worker_human month_worker month_total month_interactive month_workers
	local year_human year_interactive_machine year_worker_human year_worker year_total year_interactive year_workers
	eval "${assignments}"
	if [[ "${day_human}" != "0.0" || "${day_worker}" != "0.0" || "${day_total}" != "0.0" ]]; then
		print_result "${test_name}" 1 "missing day hour fields did not default to 0.0"
		return 0
	fi
	if [[ "${day_interactive}" != "0" || "${day_workers}" != "0" || "${week_interactive}" != "0" || "${week_workers}" != "0" ]]; then
		print_result "${test_name}" 1 "missing/null count fields did not default to 0"
		return 0
	fi
	if [[ "${month_human}" != "1.2" || "${month_worker_human}" != "2.0" || "${month_worker}" != "3.0" || "${month_total}" != "9.0" || "${month_interactive}" != "6" || "${month_workers}" != "7" ]]; then
		print_result "${test_name}" 1 "valid session data rendering changed"
		return 0
	fi
	if [[ "${year_human}" != "1.2" ]]; then
		print_result "${test_name}" 1 "user AI session hours were not limited to attended interactive time"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_work_with_ai_worker_counts_above_thousand() {
	local test_name="work with AI worker counts above one thousand render"

	TEST_DIR=$(mktemp -d)
	mkdir -p "${TEST_DIR}/home"

	# shellcheck source=../profile-readme-data-lib.sh
	source "${SOURCE_DATA_LIB}"
	# shellcheck source=../profile-readme-render-lib.sh
	source "${SOURCE_RENDER_LIB}"

	local screen_json day_json week_json month_json year_json output_file
	screen_json='{"today_hours":1,"week_hours":2,"month_hours":3,"year_hours":4}'
	day_json='{"interactive_human_hours":1,"interactive_machine_hours":0.5,"worker_human_hours":2,"worker_machine_hours":3,"total_human_hours":4,"total_machine_hours":5,"interactive_sessions":22,"worker_sessions":55}'
	week_json='{"interactive_human_hours":10,"interactive_machine_hours":1.5,"worker_human_hours":20,"worker_machine_hours":30,"total_human_hours":40,"total_machine_hours":50,"interactive_sessions":183,"worker_sessions":1080}'
	month_json='{"interactive_human_hours":100,"interactive_machine_hours":23.4,"worker_human_hours":200,"worker_machine_hours":300,"total_human_hours":400,"total_machine_hours":500,"interactive_sessions":497,"worker_sessions":1518}'
	year_json="${month_json}"
	output_file="${TEST_DIR}/work-with-ai.md"

	if ! HOME="${TEST_DIR}/home" _generate_work_with_ai_table \
		"${screen_json}" "${day_json}" "${week_json}" "${month_json}" "${year_json}" >"${output_file}"; then
		print_result "${test_name}" 1 "Work with AI table generation failed"
		return 0
	fi

	if ! grep -qF '| Worker sessions | 55 | 1,080 | 1,518 | 1,518 |' "${output_file}"; then
		print_result "${test_name}" 1 "four-digit worker session counts were not preserved and comma-formatted"
		return 0
	fi
	if ! grep -qF '| Metric | Yesterday | Prior 7 Days | Prior 28 Days | Prior 365 Days |' "${output_file}" ||
		! grep -qF 'Periods are completed local calendar days ending at midnight; today is excluded.' "${output_file}"; then
		print_result "${test_name}" 1 "completed-calendar-day labels or disclosure were not rendered"
		return 0
	fi

	if grep -qF '| Worker sessions | 55 | 0 | 0 | 0 |' "${output_file}"; then
		print_result "${test_name}" 1 "worker session counts regressed to zero after double-formatting"
		return 0
	fi

	if ! grep -qF '| Interactive human attention | 1.0h | 10.0h | 100.0h | 100.0h |' "${output_file}"; then
		print_result "${test_name}" 1 "user AI session hours were not limited to attended interactive time"
		return 0
	fi

	if grep -qF '| Interactive human attention | 1.5h | 11.5h | 123.4h | 123.4h |' "${output_file}"; then
		print_result "${test_name}" 1 "user AI session hours still include AI generation time"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_work_with_ai_unavailable_is_not_zero() {
	local test_name="work with AI renders collector failures as unavailable"
	TEST_DIR=$(mktemp -d)
	mkdir -p "${TEST_DIR}/home"
	# shellcheck source=../profile-readme-data-lib.sh
	source "${SOURCE_DATA_LIB}"
	# shellcheck source=../profile-readme-render-lib.sh
	source "${SOURCE_RENDER_LIB}"
	local screen_json unavailable_json output_file
	screen_json='{"today_hours":null,"week_hours":null,"month_hours":null,"year_hours":null,"periods":{"day":{"status":"unavailable"},"week":{"status":"unavailable"},"month":{"status":"unavailable"},"year":{"status":"unavailable"}}}'
	unavailable_json='{"status":"unavailable"}'
	output_file="${TEST_DIR}/unavailable.md"
	HOME="${TEST_DIR}/home" _generate_work_with_ai_table "$screen_json" "$unavailable_json" "$unavailable_json" "$unavailable_json" "$unavailable_json" >"$output_file"
	if ! grep -qF '| Screen time' "$output_file" || ! grep -qF '| unavailable | unavailable | unavailable | unavailable |' "$output_file"; then
		print_result "$test_name" 1 "unavailable cells were not visibly rendered"
		return 0
	fi
	if grep -qF 'unavailableh' "$output_file"; then
		print_result "$test_name" 1 "unavailable status was formatted as a numeric hour value"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_model_usage_renders_activity_metrics_without_costs() {
	local test_name="model usage renders cache and session activity without cost or savings claims"
	TEST_DIR=$(mktemp -d)
	# shellcheck source=../profile-readme-data-lib.sh
	source "$SOURCE_DATA_LIB"
	# shellcheck source=../profile-readme-render-lib.sh
	source "$SOURCE_RENDER_LIB"
	local model_json token_totals output_file
	model_json='[{"model":"model-a","requests":2,"input_tokens":100,"output_tokens":900,"cache_read_tokens":900,"cache_write_tokens":100,"session_count":2,"total_session_count":2,"session_hours":1.5,"cost_total":0}]'
	token_totals=$(_token_totals_from_model_usage "$model_json")
	output_file="${TEST_DIR}/model-usage.md"
	_render_model_usage_table "AI Model Usage" "$model_json" "$token_totals" >"$output_file"

	if ! grep -Fq '| Model | Requests | Input | Output | Cache read | Cache Hit-Rate % | Session Count | Session Hours |' "$output_file" ||
		! grep -Fq '| model-a | 2 | 100 | 900 | 900 | 90.0% | 2 | 1.5h |' "$output_file" ||
		! grep -Fq '| **Total** | **2** | **100** | **900** | **900** | **90%** | **2** | **1.5h** |' "$output_file"; then
		print_result "$test_name" 1 "activity metric columns or values are missing"
		return 0
	fi
	if grep -Eq 'API Cost|Cache savings|Model savings|total saved|all-Opus' "$output_file"; then
		print_result "$test_name" 1 "obsolete cost or savings output remains"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_observability_model_usage_calculates_sessions_and_hours() {
	local test_name="observability model usage calculates distinct sessions and generation hours"
	TEST_DIR=$(mktemp -d)
	# shellcheck source=../profile-readme-data-lib.sh
	source "$SOURCE_DATA_LIB"
	OBS_DB_FILE="${TEST_DIR}/llm-requests.db"
	sqlite3 "$OBS_DB_FILE" '
		CREATE TABLE llm_requests (
			timestamp TEXT, session_id TEXT, model_id TEXT, duration_ms INTEGER,
			tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER,
			tokens_cache_write INTEGER, cost REAL
		);
		INSERT INTO llm_requests VALUES
			("2026-09-01T00:00:00Z", "session-1", "model-a", 3600000, 10, 1, 100, 0, 1.0),
			("2026-09-01T01:00:00Z", "session-1", "model-a", 1800000, 20, 2, 200, 0, 1.0),
			("2026-09-01T02:00:00Z", "session-2", "model-a", 1800000, 30, 3, 300, 0, 1.0),
			("2026-09-01T03:00:00Z", "session-2", "model-b", 3600000, 40, 4, 400, 0, 1.0),
			("2026-09-01T04:00:00Z", "session-2", "model-c", "corrupt", 50, 5, 500, 0, 1.0);'

	local result
	result=$(_get_model_usage_from_obs_db "")
	if ! printf '%s' "$result" | jq -e '
		(INDEX(.model)) as $models
		| ($models["model-a"].requests == 3)
		and ($models["model-a"].session_count == 2)
		and ($models["model-a"].total_session_count == 2)
		and ($models["model-a"].session_hours == 2)
		and ($models["model-b"].session_count == 1)
		and ($models["model-b"].session_hours == 1)
		and ($models["model-c"].session_hours == null)
	' >/dev/null; then
		print_result "$test_name" 1 "unexpected observability aggregation: ${result}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_opencode_model_usage_deduplicates_variants_and_rejects_partial_duration() {
	local test_name="OpenCode model usage deduplicates normalized sessions and leaves incomplete duration unavailable"
	TEST_DIR=$(mktemp -d)
	# shellcheck source=../profile-readme-data-lib.sh
	source "$SOURCE_DATA_LIB"
	OPENCODE_DB_FILE="${TEST_DIR}/opencode.db"
	OPENCODE_ARCHIVE_DB_FILE="${TEST_DIR}/missing-archive.db"
	sqlite3 "$OPENCODE_DB_FILE" "
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
		INSERT INTO message VALUES
			('message-1', 'session-1', 0, 0, json_object('role', 'assistant', 'modelID', 'model-a-20260101', 'tokens', json_object('input', 10, 'output', 1, 'cache', json_object('read', 100, 'write', 0)), 'time', json_object('created', 0, 'completed', 3600000))),
			('message-2', 'session-1', 0, 0, json_object('role', 'assistant', 'modelID', 'model-a-20260202', 'tokens', json_object('input', 20, 'output', 2, 'cache', json_object('read', 200, 'write', 0)), 'time', json_object('created', 3600000, 'completed', 7200000))),
			('message-3', 'session-1', 0, 0, json_object('role', 'assistant', 'modelID', 'model-b', 'tokens', json_object('input', 30, 'output', 3, 'cache', json_object('read', 300, 'write', 0)), 'time', json_object('created', 7200000))),
			('message-4', 'session-1', 0, 0, json_object('role', 'assistant', 'modelID', 'model-c', 'tokens', json_object('input', 40, 'output', 4, 'cache', json_object('read', 400, 'write', 0)), 'time', json_object('created', 'corrupt', 'completed', 'corrupt')));"

	local result
	result=$(_get_model_usage_from_opencode)
	if ! printf '%s' "$result" | jq -e '
		(INDEX(.model)) as $models
		| ($models["model-a"].requests == 2)
		and ($models["model-a"].session_count == 1)
		and ($models["model-a"].total_session_count == 1)
		and ($models["model-a"].session_hours == 2)
		and ($models["model-b"].session_hours == null)
		and ($models["model-c"].session_hours == null)
	' >/dev/null; then
		print_result "$test_name" 1 "unexpected OpenCode aggregation: ${result}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_jsonl_model_usage_rejects_partial_duration() {
	local test_name="JSONL model usage leaves partial duration unavailable"
	TEST_DIR=$(mktemp -d)
	# shellcheck source=../profile-readme-data-lib.sh
	source "$SOURCE_DATA_LIB"
	METRICS_FILE="${TEST_DIR}/metrics.jsonl"
	cat >"$METRICS_FILE" <<'EOF'
{"model":"model-a","session_id":"session-1","duration_ms":3600000,"input_tokens":10,"output_tokens":1,"cache_read_tokens":100,"cache_write_tokens":0,"cost_total":1,"recorded_at":"2026-09-01T00:00:00Z"}
{"model":"model-a","session_id":"session-2","input_tokens":20,"output_tokens":2,"cache_read_tokens":200,"cache_write_tokens":0,"cost_total":1,"recorded_at":"2026-09-01T01:00:00Z"}
EOF

	local result
	result=$(_get_model_usage_from_jsonl all)
	if ! printf '%s' "$result" | jq -e '.[0].session_count == 2 and .[0].total_session_count == 2 and .[0].session_hours == null' >/dev/null; then
		print_result "$test_name" 1 "unexpected JSONL aggregation: ${result}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_screen_json_paths_are_optional_and_fail_visibly() {
	local test_name="screen JSON paths are optional and invalid payloads remain visibly unavailable"
	TEST_DIR=$(mktemp -d)
	# shellcheck source=../profile-readme-render-lib.sh
	source "$SOURCE_RENDER_LIB"
	local assignments screen_today screen_status screen_source
	assignments=$(_generate_screen_time_vars '{}')
	eval "$assignments"
	if [[ "$screen_today" != "$PROFILE_STATUS_UNAVAILABLE" || "$screen_status" != "$PROFILE_STATUS_UNAVAILABLE" || "$screen_source" != "$PROFILE_STATUS_UNAVAILABLE" ]]; then
		print_result "$test_name" 1 "missing paths were not rendered unavailable: ${assignments}"
		return 0
	fi
	local warning_file="${TEST_DIR}/screen-warning"
	assignments=$(_generate_screen_time_vars '' 2>"$warning_file")
	eval "$assignments"
	if [[ "$screen_today" != "$PROFILE_STATUS_UNAVAILABLE" || "$screen_status" != "$PROFILE_STATUS_UNAVAILABLE" || "$screen_source" != "$PROFILE_STATUS_UNAVAILABLE" ]] ||
		! grep -qF 'screen-time payload is invalid' "$warning_file"; then
		print_result "$test_name" 1 "empty screen payload failure was not visible"
		return 0
	fi
	assignments=$(_generate_screen_time_vars 'not-json' 2>"$warning_file")
	eval "$assignments"
	if [[ "$screen_status" != "$PROFILE_STATUS_UNAVAILABLE" || "$screen_source" != "$PROFILE_STATUS_UNAVAILABLE" ]] ||
		! grep -qF 'screen-time payload is invalid' "$warning_file"; then
		print_result "$test_name" 1 "malformed screen payload failure was not visible"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_top_apps_batches_jq_processing() {
	local test_name="top-app rendering batches jq processing"
	TEST_DIR=$(mktemp -d)
	# shellcheck source=../profile-readme-render-lib.sh
	source "$SOURCE_RENDER_LIB"
	local db_path="${TEST_DIR}/knowledgeC.db"
	local now core_now
	now=$(date +%s)
	# Production reports completed calendar days and excludes today. Place the
	# fixture one day back so it remains inside the prior-day windows.
	core_now=$((now - 978307200 - 86400))
	sqlite3 "$db_path" "
		CREATE TABLE ZOBJECT (ZSTREAMNAME TEXT,ZCREATIONDATE REAL,ZVALUEINTEGER INTEGER,ZSTARTDATE REAL,ZENDDATE REAL,ZVALUESTRING TEXT);
		WITH RECURSIVE rows(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM rows WHERE i < 10)
		INSERT INTO ZOBJECT (ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING)
		SELECT '/app/usage', ${core_now} - 86400 - i*600, ${core_now} - 86400 - i*600 + 300, 'fixture.app.' || i FROM rows;"
	local real_jq wrapper_dir count_file
	real_jq=$(command -v jq)
	wrapper_dir="${TEST_DIR}/bin"
	count_file="${TEST_DIR}/jq-count"
	mkdir -p "$wrapper_dir"
	cat >"${wrapper_dir}/jq" <<EOF
#!/usr/bin/env bash
printf '1\n' >>"${count_file}"
exec "${real_jq}" "\$@"
EOF
	chmod +x "${wrapper_dir}/jq"
	local result
	result=$(
		uname() { printf '%s\n' Darwin; }
		SCRIPT_DIR="${SOURCE_RENDER_LIB%/*}"
		PATH="${wrapper_dir}:${PATH}"
		export SCRIPT_DIR PATH
		AIDEVOPS_KNOWLEDGE_DB="$db_path" AIDEVOPS_SCREEN_TIME_NOW_EPOCH="$now" _get_top_apps
	)
	local jq_calls app_count
	jq_calls=$(wc -l <"$count_file" | tr -d ' ')
	app_count=$(printf '%s' "$result" | "$real_jq" -r 'length')
	if [[ "$jq_calls" -gt 2 || "$app_count" != "10" ]]; then
		print_result "$test_name" 1 "expected 10 apps with at most two jq processes, apps=${app_count} jq_calls=${jq_calls}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_profile_update_lock_is_bounded() {
	local test_name="profile update lock uses portable mtime and remains token-owned, race-safe, and stale-recoverable"
	TEST_DIR=$(mktemp -d)
	local result
	result=$(
		set -- help
		# shellcheck source=../profile-readme-helper.sh
		source "$SOURCE_HELPER" >/dev/null
		HOME="${TEST_DIR}/home"
		export HOME
		local delegated_mtime
		delegated_mtime=$(
			_file_mtime_epoch() { printf '%s\n' 1234567890; }
			_profile_lock_mtime "${TEST_DIR}/delegation-probe"
		)
		if [[ "$delegated_mtime" != "1234567890" ]]; then
			printf '%s\n' portable-mtime-not-used
			return 0
		fi
		_acquire_profile_update_lock
		local owner_token="$PROFILE_UPDATE_LOCK_TOKEN"
		if HOME="$HOME" bash -c 'set -- help; source "$1" >/dev/null; _acquire_profile_update_lock' _ "$SOURCE_HELPER" 2>/dev/null; then
			printf '%s\n' overlap-accepted
			return 0
		fi
		PROFILE_UPDATE_LOCK_TOKEN="not-the-owner"
		if _release_profile_update_lock 2>/dev/null; then
			printf '%s\n' non-owner-released
			return 0
		fi
		local lock_dir
		lock_dir=$(_profile_update_lock_dir)
		[[ -d "$lock_dir" ]] || {
			printf '%s\n' lock-lost
			return 0
		}
		PROFILE_UPDATE_LOCK_TOKEN="$owner_token"
		_release_profile_update_lock

		# A fresh PID-less directory receives a grace period rather than deletion.
		mkdir -p "$lock_dir"
		PROFILE_UPDATE_LOCK_GRACE_SECONDS=60
		if _acquire_profile_update_lock 2>/dev/null; then
			printf '%s\n' pidless-grace-bypassed
			return 0
		fi
		PROFILE_UPDATE_LOCK_GRACE_SECONDS=0
		_acquire_profile_update_lock
		local recovered_token="$PROFILE_UPDATE_LOCK_TOKEN"
		[[ -n "$recovered_token" && "$recovered_token" != "$owner_token" ]] || {
			printf '%s\n' token-not-unique
			return 0
		}
		printf '%s\n' stale-recovered
		_release_profile_update_lock
	)
	if [[ "$result" != "stale-recovered" ]]; then
		print_result "$test_name" 1 "unexpected lock result: ${result}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_all_time_model_usage_prefers_larger_complete_source() {
	local test_name="all-time model usage prefers larger complete source"

	# Simulate the OpenCode-schema drift case where message JSON all-time data is
	# stale for one current model even though its older aggregate request count is
	# larger than observability's complete current population.
	_get_model_usage_from_obs_db() {
		local date_filter="${1:-}"
		if [[ -n "${date_filter}" ]]; then
			printf '%s\n' '[{"model":"obs-model","requests":20,"input_tokens":200,"output_tokens":20,"cache_read_tokens":2000,"cache_write_tokens":0,"cost_total":2}]'
			return 0
		fi
		printf '%s\n' '[{"model":"obs-model","requests":30,"input_tokens":300,"output_tokens":30,"cache_read_tokens":3000,"cache_write_tokens":0,"cost_total":3}]'
		return 0
	}

	_get_model_usage_from_opencode() {
		printf '%s\n' '[{"model":"obs-model","requests":10,"input_tokens":100,"output_tokens":10,"cache_read_tokens":1000,"cache_write_tokens":0,"cost_total":1},{"model":"old-model","requests":100,"input_tokens":1000,"output_tokens":100,"cache_read_tokens":10000,"cache_write_tokens":0,"cost_total":10}]'
		return 0
	}

	local result model
	result=$(_get_model_usage all)
	model=$(printf '%s' "${result}" | jq -r '.[0].model')

	if [[ "${model}" != "obs-model" ]]; then
		print_result "${test_name}" 1 "expected obs-model, got ${model}"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_model_usage_undercut_handles_missing_candidate_model() {
	local test_name="model usage undercut handles missing candidate model"
	local candidate_json reference_json

	# shellcheck source=../profile-readme-data-lib.sh
	source "${SOURCE_DATA_LIB}"

	candidate_json='[{"model":"other-model","requests":5,"input_tokens":50,"output_tokens":5,"cache_read_tokens":500}]'
	reference_json='[{"model":"missing-model","requests":1,"input_tokens":10,"output_tokens":1,"cache_read_tokens":100}]'

	if ! _model_usage_undercuts_reference "${candidate_json}" "${reference_json}"; then
		print_result "${test_name}" 1 "missing candidate model did not undercut reference"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_all_time_token_totals_prefers_largest_population() {
	local test_name="all-time token totals prefer largest population"

	_token_totals_from_obs_db() {
		local period="${1:-30d}"
		[[ "${period}" == "all" ]] || return 1
		printf '%s\n' '{"total_input":20,"total_output":20,"total_cache_read":20,"total_cache_write":0}'
		return 0
	}

	_token_totals_from_opencode_db() {
		printf '%s\n' '{"total_input":10,"total_output":10,"total_cache_read":10,"total_cache_write":0}'
		return 0
	}

	_token_totals_from_jsonl() {
		local period="${1:-30d}"
		[[ "${period}" == "all" ]] || return 1
		printf '%s\n' '{"total_input":5,"total_output":5,"total_cache_read":5,"total_cache_write":0}'
		return 0
	}

	local result total_all
	result=$(_get_token_totals all)
	total_all=$(printf '%s' "${result}" | jq -r '.total_all')

	if [[ "${total_all}" != "60" ]]; then
		print_result "${test_name}" 1 "expected total_all=60, got ${total_all}"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_token_totals_from_selected_model_population_are_equivalent() {
	local test_name="selected model population derives equivalent token totals"
	local model_json expected actual
	model_json='[
		{"model":"one","requests":2,"input_tokens":100,"output_tokens":20,"cache_read_tokens":300,"cache_write_tokens":10,"cost_total":1},
		{"model":"two","requests":3,"input_tokens":50,"output_tokens":30,"cache_read_tokens":100,"cache_write_tokens":5,"cost_total":2}
	]'
	expected=$(_token_totals_enrich '{"total_input":150,"total_output":50,"total_cache_read":400,"total_cache_write":15}')
	actual=$(_token_totals_from_model_usage "$model_json")
	if [[ "$(printf '%s' "$actual" | jq -S -c .)" != "$(printf '%s' "$expected" | jq -S -c .)" ]]; then
		print_result "$test_name" 1 "expected=${expected} actual=${actual}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_profile_model_bundle_scans_each_population_once() {
	local test_name="profile model bundle scans each required population once"
	TEST_DIR=$(mktemp -d)
	local calls_file="${TEST_DIR}/model-source-calls"
	_get_model_usage_from_obs_db() {
		local date_filter="${1:-}"
		if [[ -n "$date_filter" ]]; then
			printf '%s\n' recent >>"$calls_file"
			printf '%s\n' '[{"model":"obs","requests":2,"input_tokens":20,"output_tokens":2,"cache_read_tokens":200,"cache_write_tokens":1,"cost_total":1}]'
		else
			printf '%s\n' all >>"$calls_file"
			printf '%s\n' '[{"model":"obs","requests":5,"input_tokens":50,"output_tokens":5,"cache_read_tokens":500,"cache_write_tokens":2,"cost_total":2}]'
		fi
		return 0
	}
	_get_model_usage_from_opencode() {
		printf '%s\n' opencode >>"$calls_file"
		printf '%s\n' '[{"model":"obs","requests":4,"input_tokens":40,"output_tokens":4,"cache_read_tokens":400,"cache_write_tokens":2,"cost_total":2}]'
		return 0
	}
	_get_model_usage_from_jsonl() {
		local period="$1"
		printf 'jsonl-%s\n' "$period" >>"$calls_file"
		printf '%s\n' '[]'
		return 0
	}

	local bundle recent_total all_total
	bundle=$(_get_profile_model_usage_bundle)
	recent_total=$(_token_totals_from_model_usage "$(printf '%s' "$bundle" | jq -c '.recent')")
	all_total=$(_token_totals_from_model_usage "$(printf '%s' "$bundle" | jq -c '.all')")
	if [[ "$(grep -c '^recent$' "$calls_file" || true)" != "1" ||
	"$(grep -c '^all$' "$calls_file" || true)" != "1" ||
	"$(grep -c '^opencode$' "$calls_file" || true)" != "1" ||
	"$(grep -c '^jsonl-' "$calls_file" || true)" != "0" ]]; then
		print_result "$test_name" 1 "unexpected source calls: $(tr '\n' ' ' <"$calls_file")"
		return 0
	fi
	if [[ "$(printf '%s' "$recent_total" | jq -r '.total_all')" != "223" ||
	"$(printf '%s' "$all_total" | jq -r '.total_all')" != "557" ]]; then
		print_result "$test_name" 1 "derived totals mismatch recent=${recent_total} all=${all_total}"
		return 0
	fi
	: >"$calls_file"
	_get_model_usage_from_obs_db() {
		local date_filter="${1:-}"
		[[ -n "$date_filter" ]] && printf '%s\n' recent-empty >>"$calls_file" || printf '%s\n' all-empty >>"$calls_file"
		printf '%s\n' '[]'
		return 0
	}
	_get_model_usage_from_opencode() {
		printf '%s\n' opencode-empty >>"$calls_file"
		printf '%s\n' '[]'
		return 0
	}
	_get_model_usage_from_jsonl() {
		local period="$1"
		printf 'jsonl-%s\n' "$period" >>"$calls_file"
		printf '[{"model":"fallback-%s","requests":1,"input_tokens":1,"output_tokens":1,"cache_read_tokens":1,"cache_write_tokens":0,"cost_total":1}]\n' "$period"
		return 0
	}
	bundle=$(_get_profile_model_usage_bundle)
	if [[ "$(printf '%s' "$bundle" | jq -r '.recent[0].model')" != "fallback-30d" ||
	"$(printf '%s' "$bundle" | jq -r '.all[0].model')" != "fallback-all" ||
	"$(grep -c '^jsonl-' "$calls_file" || true)" != "2" ]]; then
		print_result "$test_name" 1 "fallback selection changed: calls=$(tr '\n' ' ' <"$calls_file") bundle=${bundle}"
		return 0
	fi
	: >"$calls_file"
	_get_model_usage_from_jsonl() {
		local period="$1"
		printf 'jsonl-empty-%s\n' "$period" >>"$calls_file"
		printf '%s\n' '[]'
		return 0
	}
	bundle=$(_get_profile_model_usage_bundle)
	if [[ "$(printf '%s' "$bundle" | jq -r '.recent | length')" != "0" ||
	"$(printf '%s' "$bundle" | jq -r '.all | length')" != "0" ||
	"$(grep -c '^jsonl-empty-' "$calls_file" || true)" != "2" ]]; then
		print_result "$test_name" 1 "empty fallback should remain empty only after JSONL check: calls=$(tr '\n' ' ' <"$calls_file") bundle=${bundle}"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

main() {
	local mode="${1:-all}"
	if [[ ! -x "${SOURCE_HELPER}" ]]; then
		echo "Helper script not found or not executable: ${SOURCE_HELPER}" >&2
		return 1
	fi

	if [[ "$mode" != "--unit-only" ]]; then
		test_update_preserves_manual_sections
		teardown
		test_update_recovers_dirty_profile_publication_worktree
		teardown
		test_update_dry_run_is_canonical_safe
		teardown
		test_update_prepublication_failure_is_canonical_safe
		teardown
		test_internal_override_rejects_canonical_checkout
		teardown
		test_canonical_cleanliness_ignores_untracked_files
		teardown
		test_update_migrates_generated_readme_with_commit_history_chart
		teardown
		test_inject_markers_into_existing_readme
		teardown
		test_diverged_history_recovery
		teardown
		test_default_template_replaced_with_rich_readme
		teardown
		test_default_template_with_existing_markers_replaced
		teardown
	fi
	test_session_time_vars_default_missing_null_values
	teardown
	test_work_with_ai_worker_counts_above_thousand
	teardown
	test_work_with_ai_unavailable_is_not_zero
	teardown
	test_model_usage_renders_activity_metrics_without_costs
	teardown
	test_observability_model_usage_calculates_sessions_and_hours
	teardown
	test_opencode_model_usage_deduplicates_variants_and_rejects_partial_duration
	teardown
	test_jsonl_model_usage_rejects_partial_duration
	teardown
	test_screen_json_paths_are_optional_and_fail_visibly
	teardown
	test_top_apps_batches_jq_processing
	teardown
	test_profile_update_lock_is_bounded
	teardown
	test_all_time_model_usage_prefers_larger_complete_source
	teardown
	test_model_usage_undercut_handles_missing_candidate_model
	teardown
	test_all_time_token_totals_prefers_largest_population
	teardown
	test_token_totals_from_selected_model_population_are_equivalent
	teardown
	test_profile_model_bundle_scans_each_population_once
	teardown

	echo ""
	echo "Tests run: ${TESTS_RUN}"
	echo "Passed:    ${TESTS_PASSED}"
	echo "Failed:    ${TESTS_FAILED}"

	if [[ "${TESTS_FAILED}" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
