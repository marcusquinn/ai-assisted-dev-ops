#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Safe missing-workflow rollout tests for sync-workflows-helper.sh (GH#28844).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../sync-workflows-helper.sh"
CHECK_HELPER="$SCRIPT_DIR/../check-workflows-helper.sh"
BLOCK_HELPER="$SCRIPT_DIR/../managed-markdown-block-helper.py"
CALLER_TEMPLATE="$SCRIPT_DIR/../../templates/workflows/linked-issue-check-caller.yml"
POLICY_TEMPLATE="$SCRIPT_DIR/../../templates/issue-first-pr-contributing.md"

PASS=0
FAIL=0

assert_contains() {
	local description="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASS=$((PASS + 1))
	else
		printf 'FAIL %s: missing %s\n' "$description" "$needle" >&2
		printf '       output: %s\n' "$haystack" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local description="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASS=$((PASS + 1))
	else
		printf 'FAIL %s: unexpectedly contained %s\n' "$description" "$needle" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" -eq "$expected" ]]; then
		printf 'PASS %s\n' "$description"
		PASS=$((PASS + 1))
	else
		printf 'FAIL %s: expected %s, got %s\n' "$description" "$expected" "$actual" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

test_root=$(mktemp -d) || exit 1
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/.config/aidevops" "$test_root/bin"
for repo_name in admin maintain upstream local archived read inaccessible; do
	mkdir -p "$test_root/repos/$repo_name"
done

cat >"$test_root/.config/aidevops/repos.json" <<EOF
{"initialized_repos":[
  {"path":"$test_root/repos/admin","slug":"fake/admin"},
  {"path":"$test_root/repos/maintain","slug":"fake/maintain"},
  {"path":"$test_root/repos/upstream","slug":"fake/upstream","contributed":true},
  {"path":"$test_root/repos/local","local_only":true},
  {"path":"$test_root/repos/archived","slug":"fake/archived"},
  {"path":"$test_root/repos/read","slug":"fake/read"},
  {"path":"$test_root/repos/inaccessible","slug":"fake/inaccessible"}
]}
EOF

cat >"$test_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALL_LOG:?}"
if [[ "${1:-} ${2:-}" == "pr list" ]]; then
	exit 0
fi
if [[ "${1:-} ${2:-}" == "pr create" ]]; then
	printf 'mock-pr\n'
	printf 'mock benign PR diagnostic\n' >&2
	exit 0
fi
if [[ "${1:-}" != "api" ]]; then
	exit 0
fi
case "${2:-}" in
repos/fake/admin)
	printf '%s\n' '{"archived":false,"permissions":{"admin":true,"maintain":false}}'
	;;
repos/fake/maintain)
	printf '%s\n' '{"archived":false,"permissions":{"admin":false,"maintain":true}}'
	;;
repos/fake/archived)
	printf '%s\n' '{"archived":true,"permissions":{"admin":true,"maintain":false}}'
	;;
repos/fake/read)
	printf '%s\n' '{"archived":false,"permissions":{"admin":false,"maintain":false}}'
	;;
repos/fake/apply)
	printf '%s\n' '{"archived":false,"permissions":{"admin":true,"maintain":false}}'
	;;
*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$test_root/bin/gh"
: >"$test_root/gh.log"

raw_classification=$(HOME="$test_root" bash "$CHECK_HELPER" \
	--workflow linked-issue-check --json 2>&1)
assert_contains "missing workflows are classified" "$raw_classification" '"classification":"NO-WORKFLOW"'

without_install=$(HOME="$test_root" PATH="$test_root/bin:$PATH" \
	GH_CALL_LOG="$test_root/gh.log" bash "$HELPER" \
	--workflow linked-issue-check --json 2>/dev/null)
assert_not_contains "missing callers remain opt-in by default" "$without_install" 'fake/admin'

install_output=$(HOME="$test_root" PATH="$test_root/bin:$PATH" \
	GH_CALL_LOG="$test_root/gh.log" bash "$HELPER" \
	--workflow linked-issue-check --install-missing --issue 28844 --json 2>&1)
assert_contains "ADMIN repository is planned" "$install_output" '"slug":"fake/admin"'
assert_contains "MAINTAIN repository is planned" "$install_output" '"slug":"fake/maintain"'
assert_contains "workflow and CONTRIBUTING are one rollout" "$install_output" '.github/workflows/linked-issue-check.yml + CONTRIBUTING.md'
assert_contains "contributed upstream is skipped" "$install_output" 'eligibility: external-upstream'
assert_contains "local-only repository is skipped" "$install_output" 'eligibility: local-only'
assert_contains "archived repository is skipped" "$install_output" 'eligibility: archived'
assert_contains "read-only repository is skipped" "$install_output" 'eligibility: insufficient-permission'
assert_contains "inaccessible repository is skipped" "$install_output" 'eligibility: inaccessible'

gh_calls=$(<"$test_root/gh.log")
assert_not_contains "local-only entries avoid GitHub API calls" "$gh_calls" 'repos/local'
assert_not_contains "contributed upstreams avoid GitHub API calls" "$gh_calls" 'repos/fake/upstream'

missing_filter=$(HOME="$test_root" PATH="$test_root/bin:$PATH" \
	GH_CALL_LOG="$test_root/gh.log" bash "$HELPER" --install-missing 2>&1)
missing_filter_rc=$?
assert_exit "install-missing requires workflow filter" 2 "$missing_filter_rc"
assert_contains "install-missing filter error is explicit" "$missing_filter" \
	'--install-missing requires an explicit --workflow filter'

bad_issue=$(HOME="$test_root" PATH="$test_root/bin:$PATH" \
	GH_CALL_LOG="$test_root/gh.log" bash "$HELPER" --issue not-a-number 2>&1)
bad_issue_rc=$?
assert_exit "rollout issue must be numeric" 2 "$bad_issue_rc"
assert_contains "numeric issue error is explicit" "$bad_issue" \
	'--issue requires a numeric issue number'

mkdir -p "$test_root/repos/admin/.github/workflows"
cp "$CALLER_TEMPLATE" "$test_root/repos/admin/.github/workflows/linked-issue-check.yml"
python3 "$BLOCK_HELPER" apply \
	--file "$test_root/repos/admin/CONTRIBUTING.md" \
	--template "$POLICY_TEMPLATE" >/dev/null
current_output=$(HOME="$test_root" PATH="$test_root/bin:$PATH" \
	GH_CALL_LOG="$test_root/gh.log" bash "$HELPER" \
	--repo fake/admin --workflow linked-issue-check --json 2>/dev/null)
assert_not_contains "current caller and policy are idempotent" "$current_output" 'fake/admin'

cat >"$test_root/repos/admin/CONTRIBUTING.md" <<'EOF'
# Contributing

<!-- aidevops:issue-first-pr:start -->
## Stale policy

Stale text.
<!-- aidevops:issue-first-pr:end -->
EOF
policy_drift=$(HOME="$test_root" PATH="$test_root/bin:$PATH" \
	GH_CALL_LOG="$test_root/gh.log" bash "$HELPER" \
	--repo fake/admin --workflow linked-issue-check --json 2>/dev/null)
assert_contains "policy drift is actionable with a current caller" "$policy_drift" '"slug":"fake/admin"'
assert_contains "policy-only drift includes CONTRIBUTING target" "$policy_drift" 'CONTRIBUTING.md'

real_git="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
apply_repo="$test_root/repos/apply"
apply_bare="$test_root/apply.git"
mkdir -p "$apply_repo"
"$real_git" init --bare -q "$apply_bare"
"$real_git" -C "$apply_repo" init -q
"$real_git" -C "$apply_repo" config user.email test@example.com
"$real_git" -C "$apply_repo" config user.name Test
"$real_git" -C "$apply_repo" config commit.gpgsign false
"$real_git" -C "$apply_repo" checkout -q -b main
cat >"$apply_repo/CONTRIBUTING.md" <<'EOF'
# Contributing

Preserve this repository-specific guidance.
EOF
"$real_git" -C "$apply_repo" add CONTRIBUTING.md
"$real_git" -C "$apply_repo" commit -q -m initial
apply_github_url="https://github.com/fake/apply.git"
"$real_git" -C "$apply_repo" config "url.${apply_bare}.insteadOf" "$apply_github_url"
"$real_git" -C "$apply_repo" remote add github "$apply_github_url"
"$real_git" -C "$apply_repo" push -q -u github main
"$real_git" --git-dir="$apply_bare" symbolic-ref HEAD refs/heads/main
"$real_git" -C "$apply_repo" remote set-head github main
cat >"$test_root/.config/aidevops/repos.json" <<EOF
{"initialized_repos":[{"path":"$apply_repo","slug":"fake/apply"}]}
EOF
: >"$test_root/gh.log"
mkdir -p "$test_root/guard-bin"
cat >"$test_root/guard-bin/git" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
real_git="${AIDEVOPS_TEST_GIT_BIN:?}"
canonical_repo="${CANONICAL_GIT_REPO:?}"
guard_log="${CANONICAL_GIT_GUARD_LOG:?}"
args=("$@")
git_cwd="$PWD"
command_index=0
if [[ "${args[0]:-}" == "-C" ]]; then
	git_cwd="${args[1]:-}"
	command_index=2
fi
if [[ "${args[$command_index]:-}" == "fetch" ]]; then
	if [[ "$git_cwd" == "$canonical_repo" ]]; then
		printf 'blocked-canonical-fetch\n' >>"$guard_log"
		exit 97
	fi
	printf 'linked-fetch %s\n' "${args[*]}" >>"$guard_log"
fi
exec "$real_git" "$@"
EOF
chmod +x "$test_root/guard-bin/git"
: >"$test_root/canonical-git-guard.log"
safe_path="$test_root/guard-bin:$test_root/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
apply_output=$(HOME="$test_root" PATH="$safe_path" \
	GH_CALL_LOG="$test_root/gh.log" AIDEVOPS_TEMP_DIR="$test_root/agent-tmp" \
	AIDEVOPS_WORKTREE_BASE_DIR="$test_root/worktrees" \
	AIDEVOPS_TEST_GIT_BIN="$real_git" CANONICAL_GIT_REPO="$apply_repo" \
	CANONICAL_GIT_GUARD_LOG="$test_root/canonical-git-guard.log" bash "$HELPER" \
	--apply --repo fake/apply --workflow linked-issue-check --install-missing \
	--issue 28844 --branch chore/test-issue-first 2>&1)
apply_rc=$?
assert_exit "apply-mode missing install succeeds" 0 "$apply_rc"
assert_contains "apply-mode reports repository PR" "$apply_output" 'PR: mock-pr'
assert_contains "apply-mode retains benign PR diagnostics" "$apply_output" \
	'mock benign PR diagnostic'
assert_not_contains "apply-mode keeps diagnostics out of PR detail" "$apply_output" \
	$'PR: mock-pr\nmock benign PR diagnostic'

applied_workflow=$("$real_git" --git-dir="$apply_bare" show \
	'chore/test-issue-first:.github/workflows/linked-issue-check.yml')
applied_contributing=$("$real_git" --git-dir="$apply_bare" show \
	'chore/test-issue-first:CONTRIBUTING.md')
assert_contains "apply-mode installs linked-issue caller" "$applied_workflow" \
	'linked-issue-check-reusable.yml@main'
assert_contains "apply-mode preserves repository guidance" "$applied_contributing" \
	'Preserve this repository-specific guidance.'
assert_contains "apply-mode installs managed policy block" "$applied_contributing" \
	'<!-- aidevops:issue-first-pr:start -->'

guard_calls=$(<"$test_root/canonical-git-guard.log")
assert_contains "apply refreshes from linked-worktree context" "$guard_calls" 'linked-fetch'
assert_contains "apply resolves renamed GitHub remote" "$guard_calls" ' github '
assert_not_contains "apply avoids canonical fetch" "$guard_calls" 'blocked-canonical-fetch'

apply_gh_calls=$(<"$test_root/gh.log")
assert_contains "PR creation uses body-file discipline" "$apply_gh_calls" '--body-file'
assert_not_contains "PR creation does not use inline body" "$apply_gh_calls" '--body '

second_apply=$(HOME="$test_root" PATH="$safe_path" \
	GH_CALL_LOG="$test_root/gh.log" AIDEVOPS_TEMP_DIR="$test_root/agent-tmp" \
	AIDEVOPS_WORKTREE_BASE_DIR="$test_root/worktrees" \
	AIDEVOPS_TEST_GIT_BIN="$real_git" CANONICAL_GIT_REPO="$apply_repo" \
	CANONICAL_GIT_GUARD_LOG="$test_root/canonical-git-guard.log" bash "$HELPER" \
	--apply --repo fake/apply --workflow linked-issue-check --install-missing \
	--issue 28844 --branch chore/test-issue-first 2>&1)
second_rc=$?
assert_exit "second apply succeeds" 0 "$second_rc"
assert_contains "second apply is an explicit no-op" "$second_apply" \
	'refreshed checkout is CURRENT/CALLER; no changes'
pr_create_count=$(grep -cF 'pr create' "$test_root/gh.log" || true)
if [[ "$pr_create_count" -eq 1 ]]; then
	printf 'PASS idempotent apply opens exactly one PR\n'
	PASS=$((PASS + 1))
else
	printf 'FAIL idempotent apply opened %s PRs\n' "$pr_create_count" >&2
	FAIL=$((FAIL + 1))
fi

if [[ "$FAIL" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$PASS"
	exit 0
fi
printf '%d of %d tests failed\n' "$FAIL" "$((PASS + FAIL))" >&2
exit 1
