#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25292.
#
# Protected default branches must publish TODO.md/todo/ planning changes via a
# planning-only PR. The task counter remains CAS-only: this test asserts the PR
# body tells weaker models not to turn .task-counter into a PR-backed lock.

set -u

# Isolate fixture repositories from the developer's global hooksPath and
# signing policy; the test installs its own bare-remote protection hook.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

# Fixture setup uses disposable repositories; helper subprocesses still resolve
# the guarded Git shim from PATH because shell functions are not exported.
git() {
	/usr/bin/git "$@"
	return $?
}

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
PLANNING_HELPER="${REPO_ROOT}/.agents/scripts/planning-commit-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s' "$name"
	[[ -n "$detail" ]] && printf ' — %s' "$detail"
	printf '\n'
	FAIL=$((FAIL + 1))
	return 0
}

setup_repo() {
	local tmpdir="$1"
	local protected_default="$2"
	local work_branch="${3:-fixture-default}"
	local bare_dir="${tmpdir}/remote.git"
	local local_dir="${tmpdir}/local.git"
	local work_dir="${tmpdir}/work"
	local blob_sha tree_sha commit_sha

	git init --bare --initial-branch=fixture-default "$bare_dir" >/dev/null 2>&1 || return 1
	git init --bare --initial-branch=fixture-default "$local_dir" >/dev/null 2>&1 || return 1
	printf '# Tasks\n\n' >"${tmpdir}/TODO.md"
	blob_sha=$(git --git-dir="$local_dir" hash-object -w "${tmpdir}/TODO.md") || return 1
	tree_sha=$(printf '100644 blob %s\tTODO.md\n' "$blob_sha" | git --git-dir="$local_dir" mktree) || return 1
	commit_sha=$(printf 'chore: seed planning files\n' | GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.local" \
		GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.local" \
		git --git-dir="$local_dir" commit-tree "$tree_sha") || return 1
	git --git-dir="$local_dir" update-ref refs/heads/fixture-default "$commit_sha" || return 1
	printf '[remote "origin"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n[user]\n\tname = Test\n\temail = test@test.local\n[commit]\n\tgpgsign = false\n' "$bare_dir" >>"${local_dir}/config" || return 1
	git --git-dir="$local_dir" worktree add "$work_dir" fixture-default >/dev/null 2>&1 || return 1
	mkdir -p "${work_dir}/todo/tasks" || return 1
	git -C "$work_dir" push origin fixture-default >/dev/null 2>&1 || return 1
	git -C "$work_dir" fetch origin fixture-default >/dev/null 2>&1 || return 1
	git -C "$work_dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/fixture-default >/dev/null 2>&1 || return 1
	if [[ "$work_branch" != "fixture-default" ]]; then
		git -C "$work_dir" switch -c "$work_branch" >/dev/null 2>&1 || return 1
	fi

	if [[ "$protected_default" == "true" ]]; then
		mkdir -p "${bare_dir}/hooks" || return 1
		cat >"${bare_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
		if [[ "$ref" == "refs/heads/fixture-default" ]]; then
		printf 'remote: error: GH006: Protected branch update failed for %s.\n' "$ref" >&2
		printf 'remote: error: Changes must be made through a pull request.\n' >&2
		exit 1
	fi
done
exit 0
HOOK
		chmod +x "${bare_dir}/hooks/pre-receive" || return 1
	fi

	printf '%s\n' "$work_dir"
	return 0
}

write_fake_gh() {
	local fake_bin="$1"
	mkdir -p "$fake_bin" || return 1
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

if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo" ]]; then
	printf 'false\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "/repos/example/repo/issues/1" ]]; then
	printf 'origin:interactive\n'
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	exit 1
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
	shift 2
	head_branch=""
	body_text=""
	title_text=""
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
		--body)
			body_text="${2:-}"
			shift 2
			;;
		--body=*)
			body_text="${1#--body=}"
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
		*)
			shift
			;;
		esac
	done
	printf '%s\n' "$head_branch" >"${GH_STUB_HEAD:?}"
	printf '%s\n' "$title_text" >"${GH_STUB_TITLE:?}"
	printf '%s\n' "$body_text" >"${GH_STUB_BODY:?}"
	if [[ -n "${GH_STUB_PR_CREATE_FAIL_ONCE_FILE:-}" && ! -f "$GH_STUB_PR_CREATE_FAIL_ONCE_FILE" ]]; then
		printf 'failed\n' >"$GH_STUB_PR_CREATE_FAIL_ONCE_FILE"
		printf 'fixture PR creation rejected after branch push\n' >&2
		exit 42
	fi
	printf 'https://github.com/example/repo/pull/1\n'
	exit 0
fi

exit 0
GH
	chmod +x "${fake_bin}/gh" || return 1
	return 0
}

append_planning_change() {
	local work_dir="$1"
	local task_id="$2"
	local issue_num="${3:-25292}"
	printf -- '- [ ] %s Protected planning fallback #bug #auto-dispatch ~30m ref:GH#%s\n' \
		"$task_id" "$issue_num" >>"${work_dir}/TODO.md"
	printf 'What: protected planning fallback\nHow: update planning helper\n' >"${work_dir}/todo/tasks/${task_id}-brief.md"
	return 0
}

test_protected_default_creates_planning_pr() {
	local name="protected default branch creates planning PR and cleans source"
	local tmpdir fake_bin work_dir body_file head_file title_file log_file output rc status head_branch remote_todo pr_body pr_title
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	log_file="${tmpdir}/gh.log"
	body_file="${tmpdir}/body.md"
	head_file="${tmpdir}/head.txt"
	title_file="${tmpdir}/title.txt"
	: >"$log_file"
	write_fake_gh "$fake_bin" || {
		fail "$name" "fake gh setup failed"
		return 0
	}
	work_dir=$(setup_repo "$tmpdir" true) || {
		fail "$name" "repo setup failed"
		return 0
	}
	append_planning_change "$work_dir" "t999" || {
		fail "$name" "planning change failed"
		return 0
	}

	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="$log_file" GH_STUB_BODY="$body_file" GH_STUB_HEAD="$head_file" GH_STUB_TITLE="$title_file" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: add t999 protected planning" 2>&1) || rc=$?
	if [[ $rc -ne 0 ]]; then
		fail "$name" "helper failed rc=$rc output=$output"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ -n "$status" ]]; then
		fail "$name" "source worktree dirty after PR fallback: $status"
		return 0
	fi
	if ! grep -q $'gh\tpr\tcreate' "$log_file" 2>/dev/null; then
		fail "$name" "gh pr create was not called"
		return 0
	fi
	head_branch=$(cat "$head_file" 2>/dev/null || true)
	if [[ "$head_branch" != planning/* ]]; then
		fail "$name" "unexpected PR head: ${head_branch:-<empty>}"
		return 0
	fi
	remote_todo=$(git -C "$work_dir" show "origin/fixture-default:TODO.md" 2>/dev/null || true)
	if [[ "$remote_todo" == *"t999"* ]]; then
		fail "$name" "protected default branch was updated directly"
		return 0
	fi
	git -C "$work_dir" fetch origin "$head_branch" >/dev/null 2>&1 || {
		fail "$name" "PR branch not pushed"
		return 0
	}
	remote_todo=$(git -C "$work_dir" show FETCH_HEAD:TODO.md 2>/dev/null || true)
	if [[ "$remote_todo" != *"t999"* ]]; then
		fail "$name" "PR branch does not contain TODO change"
		return 0
	fi
	pr_body=$(cat "$body_file" 2>/dev/null || true)
	if [[ "$pr_body" != *"does not update .task-counter"* ]] || [[ "$pr_body" != *"PR-backed counter update"* ]]; then
		fail "$name" "PR body missing counter safety guidance"
		return 0
	fi
	if printf '%s\n' "$pr_body" | grep -Eiq '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+'; then
		fail "$name" "planning PR body contains a closing keyword"
		return 0
	fi
	if [[ "$pr_body" != *"For #25292"* ||
		"$pr_body" != *"aidevops:planning-task:v1 task=t999 issue=25292"* ||
		"$pr_body" != *"aidevops:planning-publication:v1 id="* ]]; then
		fail "$name" "PR body missing deterministic task/issue publication manifest"
		return 0
	fi
	pr_title=$(<"$title_file")
	if [[ "$pr_title" != "plan(t999): add t999 protected planning" ]]; then
		fail "$name" "single-task PR title is not task-aware: $pr_title"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_multi_task_manifest_is_deterministic() {
	local name="multi-task planning PR links every unique issue without guessing title identity"
	local tmpdir fake_bin work_dir output rc body title for_31_count
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	write_fake_gh "$fake_bin" || {
		fail "$name" "fake gh setup failed"
		return 0
	}
	work_dir=$(setup_repo "$tmpdir" true) || {
		fail "$name" "repo setup failed"
		return 0
	}
	append_planning_change "$work_dir" "t2002" "32"
	append_planning_change "$work_dir" "t2001" "31"
	append_planning_change "$work_dir" "t2003" "31"
	: >"${tmpdir}/gh.log"
	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="${tmpdir}/gh.log" GH_STUB_BODY="${tmpdir}/body" \
		GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: publish planning batch" 2>&1) || rc=$?
	body=$(<"${tmpdir}/body")
	title=$(<"${tmpdir}/title")
	for_31_count=$(printf '%s\n' "$body" | grep -c '^- For #31$' || true)
	if [[ "$rc" -eq 0 && "$title" == "plan: publish planning batch" &&
		"$body" == *"task=t2001 issue=31"* && "$body" == *"task=t2002 issue=32"* &&
		"$body" == *"task=t2003 issue=31"* && "$for_31_count" -eq 1 &&
		"$body" == *$'- For #31\n- For #32'* ]]; then
		pass "$name"
	else
		fail "$name" "rc=$rc title=$title body=$body output=$output"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_ambiguous_task_mapping_fails_before_push() {
	local name="ambiguous task mapping fails before creating a publication branch"
	local tmpdir fake_bin work_dir output rc remote_refs status
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	write_fake_gh "$fake_bin" || return 0
	work_dir=$(setup_repo "$tmpdir" true) || return 0
	printf -- '- [ ] t2100 Missing mapping #bug ~30m\n' >>"${work_dir}/TODO.md"
	printf 'What: ambiguous mapping\n' >"${work_dir}/todo/tasks/t2100-brief.md"
	: >"${tmpdir}/gh.log"
	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="${tmpdir}/gh.log" GH_STUB_BODY="${tmpdir}/body" \
		GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: publish ambiguous task" 2>&1) || rc=$?
	remote_refs=$(git --git-dir="${tmpdir}/remote.git" for-each-ref --format='%(refname)' refs/heads/planning/)
	status=$(git -C "$work_dir" status --short)
	if [[ "$rc" -ne 0 && -z "$remote_refs" && "$status" == *"TODO.md"* &&
		"$output" == *"expected one same-repository ref:GH#NNN field"* ]]; then
		pass "$name"
	else
		fail "$name" "rc=$rc refs=$remote_refs status=$status output=$output"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_post_push_failure_is_recoverable_and_idempotent() {
	local name="post-push PR failure reports recovery, cleans worktree, and reuses branch"
	local tmpdir fake_bin work_dir fail_once output_first output_second rc_first rc_second
	local branch_first branch_second commit_first commit_second planning_ref_count worktree_list status
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	write_fake_gh "$fake_bin" || return 0
	work_dir=$(setup_repo "$tmpdir" true) || return 0
	append_planning_change "$work_dir" "t2200" "2200"
	: >"${tmpdir}/gh.log"
	fail_once="${tmpdir}/pr-create-failed"
	rc_first=0
	output_first=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="${tmpdir}/gh.log" GH_STUB_BODY="${tmpdir}/body" \
		GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		GH_STUB_PR_CREATE_FAIL_ONCE_FILE="$fail_once" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: publish recoverable task" 2>&1) || rc_first=$?
	branch_first=$(printf '%s\n' "$output_first" | sed -n 's/^AIDEVOPS_PLANNING_RECOVERY_BRANCH=//p')
	commit_first=$(printf '%s\n' "$output_first" | sed -n 's/^AIDEVOPS_PLANNING_RECOVERY_COMMIT=//p')
	worktree_list=$(git -C "$work_dir" worktree list --porcelain)
	status=$(git -C "$work_dir" status --short)

	rc_second=0
	output_second=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="${tmpdir}/gh.log" GH_STUB_BODY="${tmpdir}/body" \
		GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		GH_STUB_PR_CREATE_FAIL_ONCE_FILE="$fail_once" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: publish recoverable task" 2>&1) || rc_second=$?
	branch_second=$(<"${tmpdir}/head")
	commit_second=$(git --git-dir="${tmpdir}/remote.git" rev-parse "refs/heads/${branch_second}" 2>/dev/null || true)
	planning_ref_count=$(git --git-dir="${tmpdir}/remote.git" for-each-ref --format='%(refname)' refs/heads/planning/ | wc -l | tr -d ' ')
	if [[ "$rc_first" -ne 0 && "$output_first" == *"fixture PR creation rejected after branch push"* &&
		"$output_first" == *"AIDEVOPS_PLANNING_RECOVERY_REMOTE_STATE=pushed"* &&
		"$output_first" == *"AIDEVOPS_PLANNING_RECOVERY_WORKTREE_STATE=removed"* &&
		"$worktree_list" != *"-planning-"* && "$status" == *"TODO.md"* &&
		"$rc_second" -eq 0 && "$branch_second" == "$branch_first" &&
		"$commit_second" == "$commit_first" && "$planning_ref_count" -eq 1 &&
		"$output_second" == *"AIDEVOPS_PLANNING_COMMIT_RESULT=pr"* ]]; then
		pass "$name"
	else
		fail "$name" "first_rc=$rc_first second_rc=$rc_second first=$output_first second=$output_second refs=$planning_ref_count"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_unprotected_default_keeps_direct_push() {
	local name="unprotected default branch keeps direct planning push"
	local tmpdir fake_bin work_dir log_file output rc status remote_todo
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	log_file="${tmpdir}/gh.log"
	: >"$log_file"
	write_fake_gh "$fake_bin" || {
		fail "$name" "fake gh setup failed"
		return 0
	}
	work_dir=$(setup_repo "$tmpdir" false) || {
		fail "$name" "repo setup failed"
		return 0
	}
	append_planning_change "$work_dir" "t1000" || {
		fail "$name" "planning change failed"
		return 0
	}
	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" GH_STUB_LOG="$log_file" GH_STUB_BODY="${tmpdir}/body" GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		"$PLANNING_HELPER" "plan: add t1000 direct planning" 2>&1) || rc=$?
	if [[ $rc -ne 0 ]]; then
		fail "$name" "helper failed rc=$rc output=$output"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ "$status" != *"TODO.md"* ]] || [[ "$status" != *"todo/"* ]]; then
		fail "$name" "source planning edits were not preserved after checkout-free push: $status"
		return 0
	fi
	git -C "$work_dir" fetch origin fixture-default >/dev/null 2>&1 || true
	remote_todo=$(git -C "$work_dir" show origin/fixture-default:TODO.md 2>/dev/null || true)
	if [[ "$remote_todo" != *"t1000"* ]]; then
		fail "$name" "direct push did not update origin/main"
		return 0
	fi
	if grep -q $'gh\tpr\tcreate' "$log_file" 2>/dev/null; then
		fail "$name" "unexpected PR creation on unprotected default"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_protected_default_from_linked_branch_creates_planning_pr() {
	local name="protected default from linked branch creates planning PR"
	local tmpdir fake_bin work_dir log_file output rc head_branch remote_todo
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	log_file="${tmpdir}/gh.log"
	: >"$log_file"
	write_fake_gh "$fake_bin" || {
		fail "$name" "fake gh setup failed"
		return 0
	}
	work_dir=$(setup_repo "$tmpdir" true fixture-linked) || {
		fail "$name" "repo setup failed"
		return 0
	}
	append_planning_change "$work_dir" "t1002" || {
		fail "$name" "planning change failed"
		return 0
	}

	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="$log_file" GH_STUB_BODY="${tmpdir}/body" GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: add t1002 linked protected planning" 2>&1) || rc=$?
	if [[ $rc -ne 0 || "$output" != *"AIDEVOPS_PLANNING_COMMIT_RESULT=pr"* ]]; then
		fail "$name" "helper failed or omitted PR result rc=$rc output=$output"
		return 0
	fi
	head_branch=$(<"${tmpdir}/head")
	if [[ "$head_branch" != planning/* ]]; then
		fail "$name" "unexpected PR head: ${head_branch:-<empty>}"
		return 0
	fi
	remote_todo=$(git -C "$work_dir" show "origin/fixture-default:TODO.md" 2>/dev/null || true)
	if [[ "$remote_todo" == *"t1002"* ]]; then
		fail "$name" "protected default branch was updated directly"
		return 0
	fi
	if git -C "$work_dir" show-ref --verify --quiet refs/remotes/origin/fixture-linked; then
		fail "$name" "linked source branch was published instead of a planning PR"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_unprotected_default_from_linked_branch_publishes_default() {
	local name="unprotected default from linked branch publishes canonical default"
	local tmpdir fake_bin work_dir log_file output rc status remote_todo
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	fake_bin="${tmpdir}/bin"
	log_file="${tmpdir}/gh.log"
	: >"$log_file"
	write_fake_gh "$fake_bin" || {
		fail "$name" "fake gh setup failed"
		return 0
	}
	work_dir=$(setup_repo "$tmpdir" false fixture-linked) || {
		fail "$name" "repo setup failed"
		return 0
	}
	append_planning_change "$work_dir" "t1003" || {
		fail "$name" "planning change failed"
		return 0
	}

	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="$log_file" GH_STUB_BODY="${tmpdir}/body" GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		"$PLANNING_HELPER" "plan: add t1003 linked direct planning" 2>&1) || rc=$?
	if [[ $rc -ne 0 || "$output" != *"AIDEVOPS_PLANNING_COMMIT_RESULT=direct"* ]]; then
		fail "$name" "helper failed or omitted direct result rc=$rc output=$output"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ "$status" != *"TODO.md"* || "$status" != *"todo/"* ]]; then
		fail "$name" "source planning edits were not preserved: $status"
		return 0
	fi
	git -C "$work_dir" fetch origin fixture-default >/dev/null 2>&1 || true
	remote_todo=$(git -C "$work_dir" show origin/fixture-default:TODO.md 2>/dev/null || true)
	if [[ "$remote_todo" != *"t1003"* ]]; then
		fail "$name" "canonical default did not receive linked planning changes"
		return 0
	fi
	if git -C "$work_dir" show-ref --verify --quiet refs/remotes/origin/fixture-linked; then
		fail "$name" "linked source branch was published instead of canonical default"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_pr_unavailable_fails_before_commit() {
	local name="PR fallback unavailable fails before local commit"
	local tmpdir work_dir before_head after_head output rc status
	tmpdir=$(mktemp -d) || {
		fail "$name" "mktemp failed"
		return 0
	}
	work_dir=$(setup_repo "$tmpdir" true) || {
		fail "$name" "repo setup failed"
		return 0
	}
	append_planning_change "$work_dir" "t1001" || {
		fail "$name" "planning change failed"
		return 0
	}
	before_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || {
		fail "$name" "missing initial HEAD"
		return 0
	}
	rc=0
	output=$(cd "$work_dir" && PATH="${REPO_ROOT}/.agents/scripts:/usr/bin:/bin" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 "$PLANNING_HELPER" "plan: add t1001 unavailable pr" 2>&1) || rc=$?
	if [[ $rc -eq 0 ]]; then
		fail "$name" "helper unexpectedly succeeded: $output"
		return 0
	fi
	after_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || {
		fail "$name" "missing final HEAD"
		return 0
	}
	if [[ "$after_head" != "$before_head" ]]; then
		fail "$name" "local HEAD changed before PR availability was proven"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ "$status" != *"TODO.md"* ]]; then
		fail "$name" "planning edits were not preserved for retry"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

main() {
	if [[ ! -x "$PLANNING_HELPER" ]]; then
		fail "planning helper executable" "$PLANNING_HELPER missing or not executable"
	else
		pass "planning helper executable"
	fi
	test_protected_default_creates_planning_pr
	test_multi_task_manifest_is_deterministic
	test_ambiguous_task_mapping_fails_before_push
	test_post_push_failure_is_recoverable_and_idempotent
	test_unprotected_default_keeps_direct_push
	test_protected_default_from_linked_branch_creates_planning_pr
	test_unprotected_default_from_linked_branch_publishes_default
	test_pr_unavailable_fails_before_commit
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
