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
	if [[ -n "${GH_STUB_REJECT_PR_TOKEN:-}" && "${GH_TOKEN:-}" == "$GH_STUB_REJECT_PR_TOKEN" ]]; then
		printf 'GraphQL: GitHub Actions is not permitted to create pull requests.\n' >&2
		exit 1
	fi
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

write_rejecting_git_shim() {
	local fake_bin="$1"
	local guard_log="$2"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/git" <<'GIT'
#!/usr/bin/env bash
printf 'blocked git invocation:' >>"${GIT_GUARD_LOG:?}"
printf ' %q' "$@" >>"${GIT_GUARD_LOG:?}"
printf '\n' >>"${GIT_GUARD_LOG:?}"
exit 97
GIT
	chmod +x "${fake_bin}/git"
	: >"$guard_log"
	return 0
}

write_sync_race_git_wrapper() {
	local wrapper_path="$1"
	cat >"$wrapper_path" <<'GIT'
#!/usr/bin/env bash
set -u
args=" $* "
case "$args" in
*" fetch -q origin aidevops/issue-sync-todo "*)
	count=0
	[[ ! -f "${SYNC_GIT_COUNTER:?}" ]] || count=$(<"$SYNC_GIT_COUNTER")
	count=$((count + 1))
	printf '%s\n' "$count" >"$SYNC_GIT_COUNTER"
	if [[ "$count" -eq "${SYNC_GIT_TRIGGER_COUNT:?}" ]]; then
		case "${SYNC_GIT_ACTION:?}" in
		advance)
			"${REAL_GIT:?}" --git-dir="${SYNC_GIT_ORIGIN:?}" update-ref \
				refs/heads/aidevops/issue-sync-todo "${SYNC_GIT_ADVANCE_SHA:?}"
			;;
		delete)
			"${REAL_GIT:?}" --git-dir="${SYNC_GIT_ORIGIN:?}" update-ref -d \
				refs/heads/aidevops/issue-sync-todo
			;;
		*) exit 98 ;;
		esac
	fi
	;;
esac
exec "${REAL_GIT:?}" "$@"
GIT
	chmod +x "$wrapper_path"
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
	local primary_token="${9:-fixture-token}"
	local fallback_token="${10:-}"
	local reject_pr_token="${11:-}"
	local trusted_git="${12:-}"
	(
		cd "$work_dir" || exit 1
		PATH="${fake_bin}:$PATH" \
			GITHUB_ACTIONS=true \
			GITHUB_REPOSITORY="example/repo" \
			GH_TOKEN="$primary_token" \
			AIDEVOPS_ISSUE_SYNC_PR_TOKEN="$fallback_token" \
			GH_STUB_LOG="$gh_log" \
			GH_STUB_PR_MARKER="$pr_marker" \
			GH_STUB_HEAD="$head_file" \
			GH_STUB_TITLE="$title_file" \
			GH_STUB_BODY="${title_file}.body" \
			GH_STUB_REJECT_PR_TOKEN="$reject_pr_token" \
			GIT_GUARD_LOG="${output_file}.git-guard" \
			AIDEVOPS_PLANNING_GIT_BIN="$trusted_git" \
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

	if [[ "$remote_todo" != *"t9001 first event"* ||
		"$remote_todo" != *"t9002 second event"* ||
		"$remote_todo" != *"t9003 reviewed main edit"* ]]; then
		fail "protected PR preserves concurrent and unrelated TODO edits"
	elif [[ "$main_todo" == *"first event"* || "$main_todo" == *"second event"* ]]; then
		fail "GH006 never mutates protected main directly"
	elif [[ "$sync_parent" != "$main_sha" ]]; then
		fail "stale deterministic PR branch rebases onto current main"
	elif [[ "$create_count" -ne 1 ]]; then
		printf 'Expected one PR create call, observed %s:\n%s\nFirst run:\n%s\nSecond run:\n%s\n' \
			"$create_count" "$(<"$gh_log")" "$(<"$output_a")" "$(<"$output_b")" >&2
		fail "GH006 retries create exactly one PR"
	elif [[ "$(<"$head_file")" != "aidevops/issue-sync-todo" ]]; then
		fail "issue-sync PR uses deterministic branch identity"
	elif [[ "$(<"$title_file")" != *"[skip ci]"* ]]; then
		fail "issue-sync PR title preserves merge-loop prevention"
	elif [[ "$(<"${title_file}.body")" != *"Ref #9001"* ]]; then
		fail "issue-sync PR body preserves changed-task linkage"
	elif [[ "$branch_message" == *"[skip ci]"* ]]; then
		fail "issue-sync PR branch still runs required checks"
	elif [[ "$(git -C "$work_a" status --short)" != *"TODO.md"* ||
	"$(git -C "$work_b" status --short)" != *"TODO.md"* ]]; then
		fail "PR fallback preserves each caller's local TODO projection"
	else
		pass "GH006 converges through one rebased deterministic PR"
	fi
	return 0
}

test_stale_pr_concurrent_task_addition_deduplicates() {
	local origin_dir="$TMP/duplicate-origin.git"
	local seed_dir="$TMP/duplicate-seed"
	local work_dir="$TMP/duplicate-work"
	local fake_bin="$TMP/duplicate-bin"
	local gh_log="$TMP/duplicate-gh.log"
	local pr_marker="$TMP/duplicate-pr.marker"
	local output_file="$TMP/duplicate-output.log"
	local sync_ref="refs/heads/aidevops/issue-sync-todo"
	local remote_todo=""
	local current_winner_count=0
	local incoming_winner_count=0

	create_origin "$origin_dir" "$seed_dir"
	git -C "$seed_dir" checkout -b aidevops/issue-sync-todo >/dev/null
	cat >>"$seed_dir/TODO.md" <<'EOF'

- [ ] t9004 stale issue projection ref:GH#9004
- [x] t9005 queued completion with proof ref:GH#9005 pr:#9005 completed:2026-08-07
EOF
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "stale issue-sync task addition" >/dev/null
	git -C "$seed_dir" push origin HEAD:"$sync_ref" >/dev/null
	git -C "$seed_dir" checkout main >/dev/null
	perl -0pi -e 's/## First queue\n/## First queue\n\n- [ ] t9004 canonical task with richer metadata #priority:high ref:GH#9004\n/' \
		"$seed_dir/TODO.md"
	printf '\n- [>] t9005 current in-progress task ref:GH#9005\n' >>"$seed_dir/TODO.md"
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "reviewed canonical task addition" >/dev/null
	git -C "$seed_dir" push origin main >/dev/null
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"
	: >"$pr_marker"
	perl -0pi -e 's/t9002 second task/t9002 current runner event/' "$work_dir/TODO.md"
	if ! run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$pr_marker" \
		"$TMP/duplicate-head" "$TMP/duplicate-title" "$output_file" 3; then
		printf 'Concurrent task-addition output:\n%s\n' "$(<"$output_file")" >&2
		fail "stale PR task additions defer to canonical task identity"
		return 0
	fi
	remote_todo=$(git --git-dir="$origin_dir" show "${sync_ref}:TODO.md")
	current_winner_count=$(printf '%s\n' "$remote_todo" |
		grep -cE '^[[:space:]]*- \[[ x-]\][[:space:]]+t9004([[:space:]]|$)' || true)
	incoming_winner_count=$(printf '%s\n' "$remote_todo" |
		grep -cE '^[[:space:]]*- \[[ x>-]\][[:space:]]+t9005([[:space:]]|$)' || true)
	if [[ "$current_winner_count" -ne 1 || "$incoming_winner_count" -ne 1 ||
		"$remote_todo" != *"t9004 canonical task with richer metadata"* ||
		"$remote_todo" == *"t9004 stale issue projection"* ||
		"$remote_todo" != *"t9005 queued completion with proof"* ||
		"$remote_todo" == *"t9005 current in-progress task"* ||
		"$remote_todo" != *"t9002 current runner event"* ]]; then
		fail "stale PR task additions defer to canonical task identity"
	else
		pass "stale PR task additions defer to canonical task identity"
	fi
	return 0
}

test_task_id_snapshot_uses_only_live_rows() {
	local todo_file="$TMP/parser-todo.md"
	local ids_file="$TMP/parser-task-ids"
	cat >"$todo_file" <<'EOF'
- [>] t9010 live in-progress task ref:GH#9010

```text
- [ ] t9011 fenced example ref:GH#9011
```

<!--
- [ ] t9012 commented example ref:GH#9012
-->
EOF
	if ! (
		# shellcheck source=../issue-sync-git-push-helper.sh
		source "$HELPER"
		issue_sync_task_ids "$todo_file" >"$ids_file"
	); then
		fail "task ID snapshots parse live rows with controlled failures"
		return 0
	fi
	if [[ "$(<"$ids_file")" != "t9010" ]]; then
		fail "task ID snapshots parse live rows with controlled failures"
	elif (
		# shellcheck source=../issue-sync-git-push-helper.sh
		source "$HELPER"
		issue_sync_task_ids "$TMP/missing-todo.md" >/dev/null 2>&1
	); then
		fail "task ID snapshots parse live rows with controlled failures"
	else
		pass "task ID snapshots parse live rows with controlled failures"
	fi
	return 0
}

test_same_hunk_pseudo_task_preserves_live_branch_addition() {
	local ancestor_file="$TMP/pseudo-ancestor.md"
	local current_file="$TMP/pseudo-current.md"
	local incoming_file="$TMP/pseudo-incoming.md"
	local state_dir="$TMP/pseudo-state"
	cat >"$ancestor_file" <<'EOF'
## Queue

- [ ] t9013 existing task ref:GH#9013
EOF
	cp "$ancestor_file" "$current_file"
	cp "$ancestor_file" "$incoming_file"
	cat >>"$current_file" <<'EOF'

```text
- [ ] t9014 fenced example ref:GH#9014
```
EOF
	printf '\n- [ ] t9014 live stale-branch task ref:GH#9014\n' >>"$incoming_file"
	mkdir -p "$state_dir"
	if ! (
		# shellcheck source=../issue-sync-git-push-helper.sh
		source "$HELPER"
		issue_sync_find_branch_task_additions "$ancestor_file" "$incoming_file" "$state_dir"
		issue_sync_seed_branch_task_additions "$current_file" "$incoming_file" "$state_dir"
		issue_sync_merge_todo_file "$current_file" "$ancestor_file" "$incoming_file"
		issue_sync_dedupe_concurrent_task_additions "$current_file" "$state_dir"
	); then
		fail "same-hunk pseudo tasks do not replace live branch additions"
	elif [[ "$(<"$current_file")" != *"t9014 fenced example"* ||
	"$(<"$current_file")" != *"t9014 live stale-branch task"* ]]; then
		fail "same-hunk pseudo tasks do not replace live branch additions"
	else
		pass "same-hunk pseudo tasks do not replace live branch additions"
	fi
	return 0
}

test_shallow_checkout_recovers_stale_pr_history() {
	local origin_dir="$TMP/shallow-origin.git"
	local seed_dir="$TMP/shallow-seed"
	local work_dir="$TMP/shallow-work"
	local fake_bin="$TMP/shallow-bin"
	local gh_log="$TMP/shallow-gh.log"
	local pr_marker="$TMP/shallow-pr.marker"
	local output_file="$TMP/shallow-output.log"
	local sync_ref="refs/heads/aidevops/issue-sync-todo"
	local remote_todo=""
	local is_shallow=""
	create_origin "$origin_dir" "$seed_dir"
	git -C "$seed_dir" checkout -b aidevops/issue-sync-todo >/dev/null
	perl -0pi -e 's/t9001 original task/t9001 stale PR event/' "$seed_dir/TODO.md"
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "stale issue-sync PR event" >/dev/null
	git -C "$seed_dir" push origin HEAD:"$sync_ref" >/dev/null
	git -C "$seed_dir" checkout main >/dev/null
	perl -0pi -e 's/t9003 third task/t9003 reviewed main advance/' "$seed_dir/TODO.md"
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "reviewed main advance" >/dev/null
	git -C "$seed_dir" push origin main >/dev/null
	git clone --depth 1 --branch main "file://${origin_dir}" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"
	: >"$pr_marker"
	perl -0pi -e 's/t9002 second task/t9002 shallow runner event/' "$work_dir/TODO.md"
	if ! run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$pr_marker" \
		"$TMP/shallow-head" "$TMP/shallow-title" "$output_file" 3; then
		printf 'Shallow publication output:\n%s\n' "$(<"$output_file")" >&2
		fail "shallow checkout recovers stale issue-sync PR history"
		return 0
	fi
	remote_todo=$(git --git-dir="$origin_dir" show "${sync_ref}:TODO.md")
	is_shallow=$(git -C "$work_dir" rev-parse --is-shallow-repository)
	if [[ "$is_shallow" != "false" ||
		"$remote_todo" != *"t9001 stale PR event"* ||
		"$remote_todo" != *"t9002 shallow runner event"* ||
		"$remote_todo" != *"t9003 reviewed main advance"* ]]; then
		fail "shallow checkout recovers stale issue-sync PR history"
	else
		pass "shallow checkout recovers stale issue-sync PR history"
	fi
	return 0
}

test_concurrent_pr_advance_rebuilds_snapshot() {
	local origin_dir="$TMP/race-origin.git"
	local seed_dir="$TMP/race-seed"
	local work_dir="$TMP/race-work"
	local concurrent_dir="$TMP/race-concurrent"
	local fake_bin="$TMP/race-bin"
	local gh_log="$TMP/race-gh.log"
	local pr_marker="$TMP/race-pr.marker"
	local output_file="$TMP/race-output.log"
	local wrapper="$TMP/race-git"
	local counter="$TMP/race-counter"
	local sync_ref="refs/heads/aidevops/issue-sync-todo"
	local concurrent_sha=""
	local remote_todo=""
	local real_git=""
	real_git=$(command -v git) || return 1
	create_origin "$origin_dir" "$seed_dir"
	git -C "$seed_dir" checkout -b aidevops/issue-sync-todo >/dev/null
	perl -0pi -e 's/t9001 original task/t9001 stale PR event/' "$seed_dir/TODO.md"
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "stale issue-sync PR event" >/dev/null
	git -C "$seed_dir" push origin HEAD:"$sync_ref" >/dev/null
	git -C "$seed_dir" checkout main >/dev/null
	git clone --branch aidevops/issue-sync-todo "$origin_dir" "$concurrent_dir" >/dev/null 2>&1
	git_init_repo "$concurrent_dir"
	perl -0pi -e 's/t9003 third task/t9003 concurrent PR event/' "$concurrent_dir/TODO.md"
	git -C "$concurrent_dir" add TODO.md
	git -C "$concurrent_dir" commit -m "concurrent issue-sync PR event" >/dev/null
	concurrent_sha=$(git -C "$concurrent_dir" rev-parse HEAD)
	git -C "$concurrent_dir" push origin HEAD:refs/heads/concurrent-candidate >/dev/null
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	write_sync_race_git_wrapper "$wrapper"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"
	: >"$pr_marker"
	perl -0pi -e 's/t9002 second task/t9002 current runner event/' "$work_dir/TODO.md"
	if ! (
		export REAL_GIT="$real_git" SYNC_GIT_ORIGIN="$origin_dir" SYNC_GIT_COUNTER="$counter"
		export SYNC_GIT_TRIGGER_COUNT=2 SYNC_GIT_ACTION=advance SYNC_GIT_ADVANCE_SHA="$concurrent_sha"
		run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$pr_marker" \
			"$TMP/race-head" "$TMP/race-title" "$output_file" 3 \
			"fixture-token" "" "" "$wrapper"
	); then
		fail "concurrent issue-sync PR advance rebuilds the snapshot"
		return 0
	fi
	remote_todo=$(git --git-dir="$origin_dir" show "${sync_ref}:TODO.md")
	if [[ "$remote_todo" != *"t9001 stale PR event"* ||
		"$remote_todo" != *"t9002 current runner event"* ||
		"$remote_todo" != *"t9003 concurrent PR event"* ]]; then
		fail "concurrent issue-sync PR advance rebuilds the snapshot"
	elif ! grep -q "branch changed concurrently" "$output_file"; then
		fail "concurrent issue-sync PR advance rebuilds the snapshot"
	else
		pass "concurrent issue-sync PR advance rebuilds the snapshot"
	fi
	return 0
}

test_pr_branch_deletion_during_fetch_rebuilds() {
	local origin_dir="$TMP/fetch-delete-origin.git"
	local seed_dir="$TMP/fetch-delete-seed"
	local work_dir="$TMP/fetch-delete-work"
	local fake_bin="$TMP/fetch-delete-bin"
	local gh_log="$TMP/fetch-delete-gh.log"
	local output_file="$TMP/fetch-delete-output.log"
	local wrapper="$TMP/fetch-delete-git"
	local counter="$TMP/fetch-delete-counter"
	local sync_ref="refs/heads/aidevops/issue-sync-todo"
	local create_count=0
	local real_git=""
	real_git=$(command -v git) || return 1
	create_origin "$origin_dir" "$seed_dir"
	git -C "$seed_dir" checkout -b aidevops/issue-sync-todo >/dev/null
	perl -0pi -e 's/t9001 original task/t9001 deletion race event/' "$seed_dir/TODO.md"
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "deletion race event" >/dev/null
	git -C "$seed_dir" push origin HEAD:"$sync_ref" >/dev/null
	git -C "$seed_dir" checkout main >/dev/null
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	write_sync_race_git_wrapper "$wrapper"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"
	perl -0pi -e 's/t9002 second task/t9002 deletion recovery event/' "$work_dir/TODO.md"
	if ! (
		export REAL_GIT="$real_git" SYNC_GIT_ORIGIN="$origin_dir" SYNC_GIT_COUNTER="$counter"
		export SYNC_GIT_TRIGGER_COUNT=1 SYNC_GIT_ACTION=delete SYNC_GIT_ADVANCE_SHA=unused
		run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$TMP/fetch-delete-pr.marker" \
			"$TMP/fetch-delete-head" "$TMP/fetch-delete-title" "$output_file" 3 \
			"fixture-token" "" "" "$wrapper"
	); then
		fail "issue-sync PR deletion during fetch rebuilds safely"
		return 0
	fi
	create_count=$(grep -c $'gh\tpr\tcreate' "$gh_log" || true)
	if ! git --git-dir="$origin_dir" show-ref --verify --quiet "$sync_ref" ||
		[[ "$create_count" -ne 1 ]]; then
		fail "issue-sync PR deletion during fetch rebuilds safely"
	else
		pass "issue-sync PR deletion during fetch rebuilds safely"
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

test_actions_pr_creation_uses_pat_fallback() {
	local origin_dir="$TMP/token-origin.git"
	local seed_dir="$TMP/token-seed"
	local work_dir="$TMP/token-work"
	local fake_bin="$TMP/token-bin"
	local gh_log="$TMP/token-gh.log"
	local pr_marker="$TMP/token-pr.marker"
	local output_file="$TMP/token-output.log"
	local create_count=0
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"
	perl -0pi -e 's/t9001 original task/t9001 token-fallback event/' "$work_dir/TODO.md"
	if ! run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$pr_marker" \
		"$TMP/token-head" "$TMP/token-title" "$output_file" 3 \
		"actions-token" "sync-pat-token" "actions-token"; then
		fail "disabled Actions PR creation retries with SYNC_PAT"
		return 0
	fi
	create_count=$(grep -c $'gh\tpr\tcreate' "$gh_log" || true)
	if [[ "$create_count" -ne 2 || ! -f "$pr_marker" ]]; then
		fail "disabled Actions PR creation retries with SYNC_PAT"
	elif ! grep -q 'retrying with the configured SYNC_PAT API fallback' "$output_file"; then
		fail "SYNC_PAT PR retry remains observable without exposing the token"
	elif grep -qE 'actions-token|sync-pat-token' "$output_file" "$gh_log"; then
		fail "PR token fallback does not log credential values"
	else
		pass "disabled Actions PR creation retries once with SYNC_PAT"
	fi
	return 0
}

test_runner_git_guard_uses_trusted_git_binary() {
	local origin_dir="$TMP/git-guard-origin.git"
	local seed_dir="$TMP/git-guard-seed"
	local work_dir="$TMP/git-guard-work"
	local fake_bin="$TMP/git-guard-bin"
	local gh_log="$TMP/git-guard-gh.log"
	local pr_marker="$TMP/git-guard-pr.marker"
	local output_file="$TMP/git-guard-output.log"
	local guard_log="${output_file}.git-guard"
	local trusted_git=""
	trusted_git=$(command -v git) || {
		fail "runner Git guard uses the trusted Git binary"
		return 0
	}
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	write_fake_gh "$fake_bin"
	write_rejecting_git_shim "$fake_bin" "$guard_log"
	if PATH="${fake_bin}:$PATH" GIT_GUARD_LOG="$guard_log" git --version >/dev/null 2>&1; then
		fail "runner Git guard fixture rejects PATH Git"
		return 0
	elif [[ ! -s "$guard_log" ]]; then
		fail "runner Git guard fixture rejects PATH Git"
		return 0
	fi
	: >"$guard_log"
	install_main_rejection_hook "$origin_dir" gh006
	: >"$gh_log"
	perl -0pi -e 's/t9001 original task/t9001 guarded runner event/' "$work_dir/TODO.md"
	if ! run_issue_sync_helper "$work_dir" "$fake_bin" "$gh_log" "$pr_marker" \
		"$TMP/git-guard-head" "$TMP/git-guard-title" "$output_file" 3 \
		"fixture-token" "" "" "$trusted_git"; then
		printf 'Guarded publication output:\n%s\n' "$(<"$output_file")" >&2
		fail "runner Git guard uses the trusted Git binary"
	elif ! git --git-dir="$origin_dir" show-ref --verify --quiet refs/heads/aidevops/issue-sync-todo; then
		fail "runner Git guard uses the trusted Git binary"
	else
		pass "runner Git guard uses the trusted Git binary"
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
test_stale_pr_concurrent_task_addition_deduplicates
test_task_id_snapshot_uses_only_live_rows
test_same_hunk_pseudo_task_preserves_live_branch_addition
test_shallow_checkout_recovers_stale_pr_history
test_concurrent_pr_advance_rebuilds_snapshot
test_pr_branch_deletion_during_fetch_rebuilds
test_non_gh006_failure_does_not_open_pr
test_deleted_pr_branch_retries_before_opening_pr
test_actions_pr_creation_uses_pat_fallback
test_runner_git_guard_uses_trusted_git_binary
test_noop_publishes_nothing

printf 'Tests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
