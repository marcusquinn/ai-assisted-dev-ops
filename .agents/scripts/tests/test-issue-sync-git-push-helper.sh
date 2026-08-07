#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name" >&2
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${SCRIPT_DIR}/issue-sync-git-push-helper.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git_init_repo() {
	local repo_dir="$1"
	git -C "$repo_dir" config user.name "Issue Sync Test"
	git -C "$repo_dir" config user.email "issue-sync-test@example.invalid"
	git -C "$repo_dir" config commit.gpgsign false
	return 0
}

create_origin() {
	local origin_dir="$1"
	local seed_dir="$2"
	git init --bare "$origin_dir" >/dev/null
	git init "$seed_dir" >/dev/null
	git_init_repo "$seed_dir"
	cat >"$seed_dir/TODO.md" <<'EOF'
## First queue

- [ ] t9001 original task ref:GH#9001

First queue notes remain unchanged.

## Second queue

- [ ] t9002 second task ref:GH#9002

Second queue notes remain unchanged.

## Third queue

- [ ] t9003 third task ref:GH#9003
EOF
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "seed TODO" >/dev/null
	git -C "$seed_dir" branch -M main
	git -C "$seed_dir" remote add origin "$origin_dir"
	git -C "$seed_dir" push -u origin main >/dev/null
	git --git-dir="$origin_dir" symbolic-ref HEAD refs/heads/main
	return 0
}

test_successful_push() {
	local origin_dir="$TMP/success-origin.git"
	local seed_dir="$TMP/success-seed"
	local work_dir="$TMP/success-work"
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	printf '\n- [ ] t9002 new task ref:GH#9002\n' >>"$work_dir/TODO.md"
	git -C "$work_dir" add TODO.md
	git -C "$work_dir" commit -m "sync TODO" >/dev/null
	if (cd "$work_dir" && bash "$HELPER" push-todo main 2 >/tmp/issue-sync-success.log 2>&1); then
		pass "push helper pushes clean TODO.md commit"
	else
		fail "push helper pushes clean TODO.md commit"
	fi
	return 0
}

test_rebase_conflict_neutralizes_cleanly() {
	local origin_dir="$TMP/conflict-origin.git"
	local seed_dir="$TMP/conflict-seed"
	local work_dir="$TMP/conflict-work"
	local other_dir="$TMP/conflict-other"
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git clone "$origin_dir" "$other_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	git_init_repo "$other_dir"
	perl -0pi -e 's/original task/original task worker edit/' "$work_dir/TODO.md"
	git -C "$work_dir" add TODO.md
	git -C "$work_dir" commit -m "sync TODO worker" >/dev/null
	perl -0pi -e 's/original task/original task origin edit/' "$other_dir/TODO.md"
	git -C "$other_dir" add TODO.md
	git -C "$other_dir" commit -m "sync TODO origin" >/dev/null
	git -C "$other_dir" push origin main >/dev/null

	if (cd "$work_dir" && bash "$HELPER" push-todo main 2 >/tmp/issue-sync-conflict.log 2>&1); then
		if git -C "$work_dir" diff --quiet && ! git -C "$work_dir" status --porcelain | grep -q '^UU'; then
			pass "rebase conflict exits neutral with clean index"
		else
			fail "rebase conflict exits neutral with clean index"
		fi
	else
		fail "rebase conflict exits neutral with clean index"
	fi
	return 0
}

write_fake_gh() {
	local fake_bin="$1"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<'GH'
#!/usr/bin/env bash
set -u
{
	printf 'gh'
	for arg in "$@"; do
		printf '\t%s' "$arg"
	done
	printf '\n'
} >>"${GH_STUB_LOG:?}"

if [[ "${1:-}" == "label" ]]; then
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	if [[ -f "${GH_STUB_PR_MARKER:?}" ]]; then
		printf 'https://github.com/example/repo/pull/1\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
	shift 2
	head_branch=""
	title_text=""
	body_text=""
	body_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--head)
			head_branch="${2:-}"
			shift 2
			;;
		--head=*)
			head_branch="${1#--head=}"
			shift
			;;
		--title)
			title_text="${2:-}"
			shift 2
			;;
		--title=*)
			title_text="${1#--title=}"
			shift
			;;
		--body)
			body_text="${2:-}"
			shift 2
			;;
		--body=*)
			body_text="${1#--body=}"
			shift
			;;
		--body-file)
			body_file="${2:-}"
			shift 2
			;;
		--body-file=*)
			body_file="${1#--body-file=}"
			shift
			;;
		*) shift ;;
		esac
	done
	if [[ -n "$body_file" ]]; then
		body_text=$(<"$body_file")
	fi
	printf '%s\n' "$body_text" >"${GH_STUB_BODY:?}"
	[[ "$body_text" == *"Ref #"* ]] || exit 3
	printf '%s\n' "$head_branch" >"${GH_STUB_HEAD:?}"
	printf '%s\n' "$title_text" >"${GH_STUB_TITLE:?}"
	: >"${GH_STUB_PR_MARKER:?}"
	printf 'https://github.com/example/repo/pull/1\n'
	exit 0
fi

exit 0
GH
	chmod +x "${fake_bin}/gh"
	return 0
}

install_main_rejection_hook() {
	local origin_dir="$1"
	local mode="$2"
	cat >"${origin_dir}/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
while read -r _old _new ref; do
	if [[ "\$ref" != "refs/heads/main" || -f "${origin_dir}/allow-main" ]]; then
		continue
	fi
	if [[ "${mode}" == "gh006" ]]; then
		printf 'remote: error: GH006: Protected branch update failed for %s.\n' "\$ref" >&2
		printf 'remote: error: Changes must be made through a pull request.\n' >&2
	else
		printf 'remote: terminal publication failure for %s.\n' "\$ref" >&2
	fi
	exit 1
done
exit 0
EOF
	chmod +x "${origin_dir}/hooks/pre-receive"
	return 0
}

install_one_time_sync_branch_delete_hook() {
	local origin_dir="$1"
	cat >"${origin_dir}/hooks/post-receive" <<EOF
#!/usr/bin/env bash
while read -r _old new ref; do
	if [[ "\$ref" != "refs/heads/aidevops/issue-sync-todo" || -f "${origin_dir}/deleted-sync-branch" ]]; then
		continue
	fi
	git --git-dir="${origin_dir}" update-ref -d "\$ref" "\$new" || exit 1
	: >"${origin_dir}/deleted-sync-branch"
done
exit 0
EOF
	chmod +x "${origin_dir}/hooks/post-receive"
	return 0
}

run_issue_sync_helper() {
	local work_dir="$1"
	local fake_bin="$2"
	local gh_log="$3"
	local pr_marker="$4"
	local head_file="$5"
	local title_file="$6"
	local output_file="$7"
	local attempts="${8:-3}"
	(
		cd "$work_dir" || exit 1
		PATH="${fake_bin}:$PATH" \
			GITHUB_ACTIONS=true \
			GITHUB_REPOSITORY="example/repo" \
			GH_TOKEN="fixture-token" \
			GH_STUB_LOG="$gh_log" \
			GH_STUB_PR_MARKER="$pr_marker" \
			GH_STUB_HEAD="$head_file" \
			GH_STUB_TITLE="$title_file" \
			GH_STUB_BODY="${title_file}.body" \
			bash "$HELPER" publish-todo main "$attempts" \
			"chore: sync fixture issue refs to TODO.md [skip ci]" >"$output_file" 2>&1
	)
	return $?
}

test_protected_branch_uses_one_rebased_pr() {
	local origin_dir="$TMP/protected-origin.git"
	local seed_dir="$TMP/protected-seed"
	local work_a="$TMP/protected-work-a"
	local work_b="$TMP/protected-work-b"
	local fake_bin="$TMP/protected-bin"
	local gh_log="$TMP/protected-gh.log"
	local pr_marker="$TMP/protected-pr.marker"
	local head_file="$TMP/protected-head.txt"
	local title_file="$TMP/protected-title.txt"
	local output_a="$TMP/protected-a.log"
	local output_b="$TMP/protected-b.log"
	local sync_ref="refs/heads/aidevops/issue-sync-todo"
	local remote_todo=""
	local main_todo=""
	local main_sha=""
	local sync_parent=""
	local create_count=0
	local branch_message=""

	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_a" >/dev/null 2>&1
	git clone "$origin_dir" "$work_b" >/dev/null 2>&1
	git_init_repo "$work_a"
	git_init_repo "$work_b"
	write_fake_gh "$fake_bin"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"

	perl -0pi -e 's/t9001 original task/t9001 first event/' "$work_a/TODO.md"
	if ! run_issue_sync_helper "$work_a" "$fake_bin" "$gh_log" "$pr_marker" \
		"$head_file" "$title_file" "$output_a" 3; then
		printf 'Protected publication output:\n%s\n' "$(<"$output_a")" >&2
		fail "GH006 creates a deterministic issue-sync PR"
		return 0
	fi

	# Advance protected main with an unrelated TODO edit between events. The
	# fixture bypass file represents a separately merged reviewed change.
	: >"${origin_dir}/allow-main"
	perl -0pi -e 's/t9003 third task/t9003 reviewed main edit/' "$seed_dir/TODO.md"
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "reviewed main TODO edit" >/dev/null
	git -C "$seed_dir" push origin main >/dev/null
	rm -f "${origin_dir}/allow-main"

	perl -0pi -e 's/t9002 second task/t9002 second event/' "$work_b/TODO.md"
	if ! run_issue_sync_helper "$work_b" "$fake_bin" "$gh_log" "$pr_marker" \
		"$head_file" "$title_file" "$output_b" 3; then
		fail "concurrent issue events update the deterministic PR"
		return 0
	fi

	remote_todo=$(git --git-dir="$origin_dir" show "${sync_ref}:TODO.md")
	main_todo=$(git --git-dir="$origin_dir" show main:TODO.md)
	main_sha=$(git --git-dir="$origin_dir" rev-parse main)
	sync_parent=$(git --git-dir="$origin_dir" rev-parse "${sync_ref}^")
	branch_message=$(git --git-dir="$origin_dir" log -1 --pretty=%s "$sync_ref")
	create_count=$(grep -c $'gh\tpr\tcreate' "$gh_log" || true)

	if [[ "$remote_todo" != *"t9001 first event"* || \
		"$remote_todo" != *"t9002 second event"* || \
		"$remote_todo" != *"t9003 reviewed main edit"* ]]; then
		fail "protected PR preserves concurrent and unrelated TODO edits"
	elif [[ "$main_todo" == *"first event"* || "$main_todo" == *"second event"* ]]; then
		fail "GH006 never mutates protected main directly"
	elif [[ "$sync_parent" != "$main_sha" ]]; then
		fail "stale deterministic PR branch rebases onto current main"
	elif [[ "$create_count" -ne 1 ]]; then
		fail "GH006 retries create exactly one PR"
	elif [[ "$(<"$head_file")" != "aidevops/issue-sync-todo" ]]; then
		fail "issue-sync PR uses deterministic branch identity"
	elif [[ "$(<"$title_file")" != *"[skip ci]"* ]]; then
		fail "issue-sync PR title preserves merge-loop prevention"
	elif [[ "$(<"${title_file}.body")" != *"Ref #9001"* ]]; then
		fail "issue-sync PR body preserves changed-task linkage"
	elif [[ "$branch_message" == *"[skip ci]"* ]]; then
		fail "issue-sync PR branch still runs required checks"
	elif [[ "$(git -C "$work_a" status --short)" != *"TODO.md"* || \
		"$(git -C "$work_b" status --short)" != *"TODO.md"* ]]; then
		fail "PR fallback preserves each caller's local TODO projection"
	else
		pass "GH006 converges through one rebased deterministic PR"
	fi
	return 0
}

test_non_gh006_failure_does_not_open_pr() {
	local origin_dir="$TMP/terminal-origin.git"
	local seed_dir="$TMP/terminal-seed"
	local work_dir="$TMP/terminal-work"
	local fake_bin="$TMP/terminal-bin"
	local gh_log="$TMP/terminal-gh.log"
	local output_file="$TMP/terminal-output.log"
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	install_main_rejection_hook "$origin_dir" terminal
	: >"$gh_log"
	perl -0pi -e 's/t9001 original task/t9001 terminal event/' "$work_dir/TODO.md"
	if run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$TMP/terminal-pr.marker" \
		"$TMP/terminal-head" "$TMP/terminal-title" "$output_file" 2; then
		fail "non-GH006 terminal push failure remains terminal"
	elif git --git-dir="$origin_dir" show-ref --verify --quiet refs/heads/aidevops/issue-sync-todo; then
		fail "non-GH006 failure unexpectedly published a PR branch"
	elif grep -q $'gh\tpr\tcreate' "$gh_log"; then
		fail "non-GH006 failure unexpectedly opened a PR"
	else
		pass "non-GH006 terminal failure does not open a PR"
	fi
	return 0
}

test_deleted_pr_branch_retries_before_opening_pr() {
	local origin_dir="$TMP/deleted-origin.git"
	local seed_dir="$TMP/deleted-seed"
	local work_dir="$TMP/deleted-work"
	local fake_bin="$TMP/deleted-bin"
	local gh_log="$TMP/deleted-gh.log"
	local pr_marker="$TMP/deleted-pr.marker"
	local output_file="$TMP/deleted-output.log"
	local create_count=0
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	install_main_rejection_hook "$origin_dir" gh006
	install_one_time_sync_branch_delete_hook "$origin_dir"
	: >"$gh_log"
	perl -0pi -e 's/t9002 second task/t9002 deletion-race event/' "$work_dir/TODO.md"
	if ! run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$pr_marker" \
		"$TMP/deleted-head" "$TMP/deleted-title" "$output_file" 3; then
		fail "deleted issue-sync PR branch is rebuilt"
		return 0
	fi
	create_count=$(grep -c $'gh\tpr\tcreate' "$gh_log" || true)
	if ! git --git-dir="$origin_dir" show-ref --verify --quiet refs/heads/aidevops/issue-sync-todo; then
		fail "deleted issue-sync PR branch is rebuilt"
	elif [[ "$create_count" -ne 1 || ! -f "$pr_marker" ]]; then
		fail "rebuilt issue-sync branch opens exactly one PR"
	else
		pass "deleted issue-sync PR branch is rebuilt before one PR opens"
	fi
	return 0
}

test_noop_publishes_nothing() {
	local origin_dir="$TMP/noop-origin.git"
	local seed_dir="$TMP/noop-seed"
	local work_dir="$TMP/noop-work"
	local fake_bin="$TMP/noop-bin"
	local gh_log="$TMP/noop-gh.log"
	local output_file="$TMP/noop-output.log"
	local before=""
	local after=""
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	: >"$gh_log"
	before=$(git --git-dir="$origin_dir" rev-parse main)
	if ! run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$TMP/noop-pr.marker" \
		"$TMP/noop-head" "$TMP/noop-title" "$output_file" 2; then
		fail "no-op TODO publication succeeds"
		return 0
	fi
	after=$(git --git-dir="$origin_dir" rev-parse main)
	if [[ "$before" != "$after" || -s "$gh_log" ]]; then
		fail "no-op TODO publication creates no commit or PR"
	else
		pass "no-op TODO publication creates no commit or PR"
	fi
	return 0
}

test_successful_push
test_rebase_conflict_neutralizes_cleanly
test_protected_branch_uses_one_rebased_pr
test_non_gh006_failure_does_not_open_pr
test_deleted_pr_branch_retries_before_opening_pr
test_noop_publishes_nothing

printf 'Tests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
