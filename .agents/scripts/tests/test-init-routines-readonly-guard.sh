#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1090
#
# Regression test: GH#18702 — init-routines-helper.sh must not fail with
# `readonly variable` when sourced from a shell where shared-constants.sh
# has already been sourced (which declares RED/GREEN/YELLOW/BLUE/NC as
# readonly). Before the fix, setup.sh was being killed by this collision,
# blocking auto-update deploys since 2026-04-09 and causing the 18693/18702
# stale-recovery cascade.

set -euo pipefail
# Fixture repositories are disposable; bypass interactive canonical-repo guards.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_SCRIPTS="${SCRIPT_DIR}/.."
SHARED_CONSTANTS="${REPO_SCRIPTS}/shared-constants.sh"
INIT_ROUTINES="${REPO_SCRIPTS}/init-routines-helper.sh"
COMMON_HELPER="${REPO_SCRIPTS}/setup/_common.sh"
ROUTINES_MODULE="${REPO_SCRIPTS}/setup/_routines.sh"
ROUTINE_LOG="${REPO_SCRIPTS}/routine-log-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

configure_test_git_identity() {
	local repo_path="$1"
	git -C "$repo_path" config user.email "test@example.invalid"
	git -C "$repo_path" config user.name "Test User"
	git -C "$repo_path" config commit.gpgsign false
	return 0
}

# The original bug: setup.sh sources shared-constants.sh (readonly colors),
# then sources _routines.sh which sources init-routines-helper.sh. The helper
# previously did unconditional `GREEN='\033[0;32m'` which failed under
# `set -Eeuo pipefail` and killed the whole setup.sh run.
test_init_routines_sources_after_shared_constants() {
	local output=""
	local exit_code=0

	output=$(
		bash -c "
			set -Eeuo pipefail
			source '${SHARED_CONSTANTS}'
			source '${INIT_ROUTINES}'
			echo 'INIT_OK'
		" 2>&1
	) || exit_code=$?

	if [[ "$exit_code" -eq 0 && "$output" == *"INIT_OK"* ]]; then
		print_result "init-routines-helper.sh sources cleanly after shared-constants.sh (GH#18702)" 0
		return 0
	fi

	print_result "init-routines-helper.sh sources cleanly after shared-constants.sh (GH#18702)" 1 \
		"exit=${exit_code} output=${output}"
	return 0
}

# Belt-and-braces: _common.sh should also tolerate pre-existing readonly colors,
# so reordering the setup.sh sourcing sequence can't regress the bug.
test_common_tolerates_readonly_colors() {
	local output=""
	local exit_code=0

	output=$(
		bash -c "
			set -Eeuo pipefail
			source '${SHARED_CONSTANTS}'
			source '${COMMON_HELPER}'
			echo 'COMMON_OK'
		" 2>&1
	) || exit_code=$?

	if [[ "$exit_code" -eq 0 && "$output" == *"COMMON_OK"* ]]; then
		print_result "setup/_common.sh tolerates pre-existing readonly colors (GH#18702)" 0
		return 0
	fi

	print_result "setup/_common.sh tolerates pre-existing readonly colors (GH#18702)" 1 \
		"exit=${exit_code} output=${output}"
	return 0
}

# End-to-end defensive check: _routines.sh's _load_init_routines_helper must
# isolate errors so any future helper-level failure cannot propagate and
# kill setup.sh. This is the second line of defense from GH#18702.
test_routines_loader_isolates_errors() {
	local output=""
	local exit_code=0

	output=$(
		bash -c "
			set -Eeuo pipefail
			source '${COMMON_HELPER}'
			source '${SHARED_CONSTANTS}'
			source '${ROUTINES_MODULE}'
			if _load_init_routines_helper; then
				echo 'LOADER_OK'
			else
				echo 'LOADER_FAILED_BUT_DID_NOT_KILL_SETUP'
			fi
		" 2>&1
	) || exit_code=$?

	if [[ "$exit_code" -eq 0 && ("$output" == *"LOADER_OK"* || "$output" == *"LOADER_FAILED_BUT_DID_NOT_KILL_SETUP"*) ]]; then
		print_result "_load_init_routines_helper isolates source errors (GH#18702)" 0
		return 0
	fi

	print_result "_load_init_routines_helper isolates source errors (GH#18702)" 1 \
		"exit=${exit_code} output=${output}"
	return 0
}

# Captures all operator-visible canonical checkout state without updating refs.
canonical_fingerprint() {
	local repo_path="$1"
	local untracked=""
	{
		git -C "$repo_path" rev-parse HEAD
		git -C "$repo_path" ls-files --stage
		git -C "$repo_path" status --porcelain=v1 -uall
		git -C "$repo_path" diff --binary
		git -C "$repo_path" diff --cached --binary
		git -C "$repo_path" stash list
		while IFS= read -r untracked; do
			[[ -n "$untracked" ]] || continue
			printf '%s %s\n' "$untracked" "$(git -C "$repo_path" hash-object -- "$untracked")"
		done < <(git -C "$repo_path" ls-files --others --exclude-standard)
		for untracked in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
			local state_path=""
			state_path=$(git -C "$repo_path" rev-parse --git-path "$untracked")
			[[ ! -e "$state_path" ]] || printf 'state:%s\n' "$untracked"
		done
	} | git hash-object --stdin
	return 0
}

create_remote_fixture() {
	local remote_repo="$1"
	local canonical_repo="$2"
	git -c init.defaultBranch=main init --bare "$remote_repo" >/dev/null
	git -c init.defaultBranch=main init "$canonical_repo" >/dev/null
	git -C "$canonical_repo" remote add origin "$remote_repo"
	configure_test_git_identity "$canonical_repo"
	printf 'base\n' >"${canonical_repo}/operator.txt"
	git -C "$canonical_repo" add operator.txt
	git -C "$canonical_repo" commit -m "initial" >/dev/null
	git -C "$canonical_repo" push -u origin main >/dev/null 2>&1
	return 0
}

test_isolated_publication_preserves_canonical_checkout() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local canonical_repo="${tmp_dir}/mirror"
	create_remote_fixture "$remote_repo" "$canonical_repo"
	printf 'operator edit\n' >>"${canonical_repo}/operator.txt"
	printf 'untracked\n' >"${canonical_repo}/notes.txt"
	local before=""
	before=$(canonical_fingerprint "$canonical_repo")

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	_publish_routines_scaffold "$canonical_repo"
	local after=""
	after=$(canonical_fingerprint "$canonical_repo")
	local remote_todo=""
	remote_todo=$(git --git-dir="$remote_repo" show main:TODO.md 2>/dev/null || true)
	rm -rf "$tmp_dir"

	if [[ "$before" == "$after" && "$remote_todo" == "# Routines"* ]]; then
		print_result "isolated publication preserves canonical HEAD/index/worktree/stash/rebase state (GH#28640)" 0
		return 0
	fi
	print_result "isolated publication preserves canonical HEAD/index/worktree/stash/rebase state (GH#28640)" 1 \
		"before=${before} after=${after} remote_todo_present=$([[ -n "$remote_todo" ]] && printf yes || printf no)"
	return 0
}

test_isolated_publication_uses_guard_aware_clone_context() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local canonical_repo="${tmp_dir}/mirror"
	create_remote_fixture "$remote_repo" "$canonical_repo"
	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	local before=""
	before=$(canonical_fingerprint "$canonical_repo")

	# Keep the production Git shim active and enter a canonical checkout. The
	# publisher must move clone execution into its disposable directory rather
	# than bypassing the guard.
	local rc=0
	local output=""
	output=$(
		cd "$canonical_repo" || exit 1
		PATH="${REPO_SCRIPTS}:/usr/bin:/bin:/usr/sbin:/sbin" _publish_routines_scaffold "$canonical_repo"
	) 2>&1 || rc=$?
	local after=""
	after=$(canonical_fingerprint "$canonical_repo")
	local remote_todo=""
	remote_todo=$(git --git-dir="$remote_repo" show main:TODO.md 2>/dev/null || true)
	rm -rf "$tmp_dir"

	if [[ "$rc" -eq 0 && "$before" == "$after" && "$remote_todo" == "# Routines"* ]]; then
		print_result "isolated publication succeeds through canonical Git guard (GH#28935)" 0
		return 0
	fi
	print_result "isolated publication succeeds through canonical Git guard (GH#28935)" 1 \
		"rc=${rc} canonical_unchanged=$([[ "$before" == "$after" ]] && printf yes || printf no) remote_todo_present=$([[ -n "$remote_todo" ]] && printf yes || printf no) output=${output}"
	return 0
}

test_isolated_publication_uses_remote_ahead_tip() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local canonical_repo="${tmp_dir}/mirror"
	local advancer_repo="${tmp_dir}/advancer"
	create_remote_fixture "$remote_repo" "$canonical_repo"
	git clone -q "$remote_repo" "$advancer_repo"
	configure_test_git_identity "$advancer_repo"
	printf 'remote ahead\n' >"${advancer_repo}/remote-only.txt"
	git -C "$advancer_repo" add remote-only.txt
	git -C "$advancer_repo" commit -m "remote ahead" >/dev/null
	git -C "$advancer_repo" push -q origin main
	local before=""
	before=$(canonical_fingerprint "$canonical_repo")

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	_publish_routines_scaffold "$canonical_repo"
	local after=""
	after=$(canonical_fingerprint "$canonical_repo")
	local remote_has_both=1
	git --git-dir="$remote_repo" cat-file -e main:remote-only.txt &&
		git --git-dir="$remote_repo" cat-file -e main:TODO.md && remote_has_both=0
	rm -rf "$tmp_dir"

	if [[ "$before" == "$after" && "$remote_has_both" -eq 0 ]]; then
		print_result "isolated publication builds on the remote-ahead tip without syncing canonical refs (GH#22199)" 0
		return 0
	fi
	print_result "isolated publication builds on the remote-ahead tip without syncing canonical refs (GH#22199)" 1 \
		"before=${before} after=${after} remote_has_both=${remote_has_both}"
	return 0
}

test_isolated_publication_fails_closed_on_validation() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local canonical_repo="${tmp_dir}/mirror"
	local validator="${tmp_dir}/reject.sh"
	create_remote_fixture "$remote_repo" "$canonical_repo"
	printf '#!/usr/bin/env bash\nexit 1\n' >"$validator"
	chmod +x "$validator"
	local canonical_before=""
	local remote_before=""
	canonical_before=$(canonical_fingerprint "$canonical_repo")
	remote_before=$(git --git-dir="$remote_repo" rev-parse main)

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	local rc=0
	AIDEVOPS_ROUTINES_PUBLISH_VALIDATOR="$validator" _publish_routines_scaffold "$canonical_repo" >/dev/null 2>&1 || rc=$?
	local canonical_after=""
	local remote_after=""
	canonical_after=$(canonical_fingerprint "$canonical_repo")
	remote_after=$(git --git-dir="$remote_repo" rev-parse main)
	rm -rf "$tmp_dir"

	if [[ "$rc" -eq 1 && "$canonical_before" == "$canonical_after" && "$remote_before" == "$remote_after" ]]; then
		print_result "validation failure leaves canonical checkout and remote unchanged (GH#28640)" 0
		return 0
	fi
	print_result "validation failure leaves canonical checkout and remote unchanged (GH#28640)" 1 \
		"rc=${rc} canonical_unchanged=$([[ "$canonical_before" == "$canonical_after" ]] && printf yes || printf no) remote_unchanged=$([[ "$remote_before" == "$remote_after" ]] && printf yes || printf no)"
	return 0
}

test_isolated_publication_retries_nonconflicting_race() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local canonical_repo="${tmp_dir}/mirror"
	local hook="${tmp_dir}/advance-once.sh"
	create_remote_fixture "$remote_repo" "$canonical_repo"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
remote_repo="$1"
branch="$2"
attempt="$3"
[[ "$attempt" == "1" ]] || exit 0
temp_repo=$(mktemp -d)
git clone -q --branch "$branch" "$remote_repo" "$temp_repo"
git -C "$temp_repo" config user.email test@example.invalid
git -C "$temp_repo" config user.name "Concurrent Writer"
git -C "$temp_repo" config commit.gpgsign false
printf 'concurrent non-generated change\n' >"${temp_repo}/remote-only.txt"
git -C "$temp_repo" add remote-only.txt
git -C "$temp_repo" commit -q -m "concurrent unrelated update"
git -C "$temp_repo" push -q origin "HEAD:refs/heads/${branch}"
rm -rf "$temp_repo"
HOOK
	chmod +x "$hook"
	local before=""
	before=$(canonical_fingerprint "$canonical_repo")

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	AIDEVOPS_ROUTINES_PUBLISH_MAX_RETRIES=2 AIDEVOPS_ROUTINES_BEFORE_PUSH_HOOK="$hook" \
		_publish_routines_scaffold "$canonical_repo" >/dev/null
	local after=""
	after=$(canonical_fingerprint "$canonical_repo")
	local remote_has_both=1
	git --git-dir="$remote_repo" cat-file -e main:remote-only.txt &&
		git --git-dir="$remote_repo" cat-file -e main:TODO.md && remote_has_both=0
	rm -rf "$tmp_dir"

	if [[ "$before" == "$after" && "$remote_has_both" -eq 0 ]]; then
		print_result "lease rejection retries when concurrent changes do not touch generated paths (GH#28640)" 0
		return 0
	fi
	print_result "lease rejection retries when concurrent changes do not touch generated paths (GH#28640)" 1 \
		"canonical_unchanged=$([[ "$before" == "$after" ]] && printf yes || printf no) remote_has_both=${remote_has_both}"
	return 0
}

test_isolated_publication_refuses_push_conflict() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local canonical_repo="${tmp_dir}/mirror"
	local hook="${tmp_dir}/advance.sh"
	create_remote_fixture "$remote_repo" "$canonical_repo"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
remote_repo="$1"
branch="$2"
attempt="$3"
temp_repo=$(mktemp -d)
git clone -q --branch "$branch" "$remote_repo" "$temp_repo"
git -C "$temp_repo" config user.email test@example.invalid
git -C "$temp_repo" config user.name "Conflict Writer"
git -C "$temp_repo" config commit.gpgsign false
printf 'concurrent %s\n' "$attempt" >"${temp_repo}/TODO.md"
git -C "$temp_repo" add TODO.md
git -C "$temp_repo" commit -q -m "concurrent generated-path update"
git -C "$temp_repo" push -q origin "HEAD:refs/heads/${branch}"
rm -rf "$temp_repo"
HOOK
	chmod +x "$hook"
	local before=""
	before=$(canonical_fingerprint "$canonical_repo")

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	local rc=0
	AIDEVOPS_ROUTINES_PUBLISH_MAX_RETRIES=1 AIDEVOPS_ROUTINES_BEFORE_PUSH_HOOK="$hook" \
		_publish_routines_scaffold "$canonical_repo" >/dev/null 2>&1 || rc=$?
	local after=""
	after=$(canonical_fingerprint "$canonical_repo")
	local remote_todo=""
	remote_todo=$(git --git-dir="$remote_repo" show main:TODO.md)
	rm -rf "$tmp_dir"

	if [[ "$rc" -eq 2 && "$before" == "$after" && "$remote_todo" == "concurrent 1" ]]; then
		print_result "lease rejection fails closed without overwriting concurrent generated paths (GH#28640)" 0
		return 0
	fi
	print_result "lease rejection fails closed without overwriting concurrent generated paths (GH#28640)" 1 \
		"rc=${rc} canonical_unchanged=$([[ "$before" == "$after" ]] && printf yes || printf no) remote_todo=${remote_todo}"
	return 0
}

test_first_clone_initialization_remains_functional() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local remote_repo="${tmp_dir}/remote.git"
	local new_clone="${tmp_dir}/new-clone"
	git -c init.defaultBranch=main init --bare "$remote_repo" >/dev/null
	git -c init.defaultBranch=main init "$new_clone" >/dev/null
	git -C "$new_clone" remote add origin "$remote_repo"
	configure_test_git_identity "$new_clone"

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	scaffold_repo "$new_clone" >/dev/null
	_commit_and_push "$new_clone" >/dev/null
	local remote_todo=""
	remote_todo=$(git --git-dir="$remote_repo" show main:TODO.md 2>/dev/null || true)
	rm -rf "$tmp_dir"

	if [[ "$remote_todo" == "# Routines"* ]]; then
		print_result "first-clone initialization still scaffolds and pushes its checkout" 0
		return 0
	fi
	print_result "first-clone initialization still scaffolds and pushes its checkout" 1
	return 0
}

test_scaffold_refresh_preserves_user_owned_sections() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local fixture_repo="${tmp_dir}/routines"
	mkdir -p "$fixture_repo"

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	cat >"${fixture_repo}/TODO.md" <<'TODO'
# Routines

## Core Routines (framework-managed)

- [x] r999 Stale generated core entry repeat:daily(@00:00) run:scripts/stale.sh

## User Routines

- [x] r123 User-owned routine repeat:daily(@09:00) run:custom/scripts/user.sh

## Tasks

- [ ] User-owned one-off task
TODO

	_write_todo_md "$fixture_repo"
	local user_heading_count=0 task_heading_count=0
	user_heading_count=$(grep -c '^## User Routines$' "${fixture_repo}/TODO.md" || true)
	task_heading_count=$(grep -c '^## Tasks$' "${fixture_repo}/TODO.md" || true)
	local passed=1
	if grep -Fqx -- '- [x] r123 User-owned routine repeat:daily(@09:00) run:custom/scripts/user.sh' "${fixture_repo}/TODO.md" &&
		grep -Fqx -- '- [ ] User-owned one-off task' "${fixture_repo}/TODO.md" &&
		grep -Fq -- '- [x] r918 Observability retention' "${fixture_repo}/TODO.md" &&
		! grep -Fq -- 'r999 Stale generated core entry' "${fixture_repo}/TODO.md" &&
		[[ "$user_heading_count" -eq 1 && "$task_heading_count" -eq 1 ]]; then
		passed=0
	fi
	rm -rf "$tmp_dir"

	if [[ "$passed" -eq 0 ]]; then
		print_result "scaffold refresh preserves user routines/tasks and regenerates core entries (GH#30592)" 0
		return 0
	fi
	print_result "scaffold refresh preserves user routines/tasks and regenerates core entries (GH#30592)" 1 \
		"user_headings=${user_heading_count} task_headings=${task_heading_count}"
	return 0
}

test_existing_routine_refreshes_metadata_without_metrics_mutation() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	local old_home="${HOME}"
	HOME="$tmp_dir"
	export HOME

	# shellcheck disable=SC1090
	source "$INIT_ROUTINES"
	# shellcheck disable=SC1090
	source "$ROUTINE_LOG"
	describe_r999() {
		printf '%s\n' '## What it does' 'Keeps the test routine healthy.' '## How it works'
		return 0
	}

	local state_dir="${HOME}/.aidevops/.agent-workspace/cron/r999"
	mkdir -p "$state_dir"
	cat >"${state_dir}/routine-state.json" <<'JSON'
{"issue_number":"123","repo_slug":"example/routines","title":"r999: Old title","schedule":"Daily at 07:10 (Europe/Jersey)","routine_type":"old type","streak_count":7,"streak_type":"success","last_duration":42,"total_cost":"1.23","last_status":"success","last_run":"2026-08-07T07:10:00Z"}
JSON

	_store_routine_description "r999" "r999: New title" "Daily at 01:30 (UTC)" "scripts/test.sh" "script (scripts/test.sh)"
	local state=""
	state=$(jq -c . "${state_dir}/routine-state.json")
	local body=""
	body=$(_build_issue_body "r999" "r999: New title" "Daily at 01:30 (UTC)" "script (scripts/test.sh)" "active" "2026-08-07T07:10:00Z" "success" "42" "pending" "7" "success" "1.23" '{"total":1,"successes":1,"failures":0,"total_cost":"1.23","avg_duration":42,"period_start":"2026-08-01","period_end":"2026-08-08"}')
	HOME="$old_home"
	export HOME
	rm -rf "$tmp_dir"

	if [[ "$(jq -r '.title,.schedule,.routine_type,.streak_count,.last_duration,.total_cost' <<<"$state")" == $'r999: New title\nDaily at 01:30 (UTC)\nscript (scripts/test.sh)\n7\n42\n1.23' && "$body" == *'| Schedule | Daily at 01:30 (UTC) |'* && "$body" == *'| Streak | 7 consecutive successes |'* ]]; then
		print_result "existing routine refresh updates metadata while preserving execution metrics" 0
		return 0
	fi
	print_result "existing routine refresh updates metadata while preserving execution metrics" 1 "state=${state} body=${body}"
	return 0
}

main() {
	test_init_routines_sources_after_shared_constants
	test_common_tolerates_readonly_colors
	test_routines_loader_isolates_errors
	test_isolated_publication_preserves_canonical_checkout
	test_isolated_publication_uses_guard_aware_clone_context
	test_isolated_publication_uses_remote_ahead_tip
	test_isolated_publication_fails_closed_on_validation
	test_isolated_publication_retries_nonconflicting_race
	test_isolated_publication_refuses_push_conflict
	test_first_clone_initialization_remains_functional
	test_scaffold_refresh_preserves_user_owned_sections
	test_existing_routine_refreshes_metadata_without_metrics_mutation

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
