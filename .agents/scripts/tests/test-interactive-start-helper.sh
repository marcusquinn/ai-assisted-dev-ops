#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

scripts_dir="$(cd "$(dirname "$0")/.." && pwd)"
helper="${scripts_dir}/interactive-start-helper.sh"
full_loop_helper="${scripts_dir}/full-loop-helper.sh"
command_workflow="${scripts_dir}/commands/full-loop.md"
canonical_workflow="${scripts_dir}/../workflows/full-loop.md"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
stub_dir="${test_root}/bin"
call_log="${test_root}/calls"
canonical_root="${test_root}/canonical"
linked_worktree="${test_root}/linked"
unregistered_path="${test_root}/unregistered"
mkdir -p "$stub_dir" "$unregistered_path"
: >"$call_log"
export CALL_LOG="$call_log"
export CANONICAL_ROOT="$canonical_root"
export LINKED_WORKTREE="$linked_worktree"
export UNREGISTERED_PATH="$unregistered_path"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	exit 1
	return 1
}

assert_log_line() {
	local expected="$1"
	grep -Fxq "$expected" "$call_log" || fail "missing call log line: $expected"
	return 0
}

for workflow_path in "$command_workflow" "$canonical_workflow"; do
	grep -Fq "interactive-start-helper.sh \\" "$workflow_path" ||
		fail "issue-started workflow does not route through interactive-start-helper: $workflow_path"
	grep -Fq "keeps worker-ready issues eligible for \`auto-dispatch\`" "$workflow_path" ||
		fail "issue-started workflow does not preserve automatic continuation: $workflow_path"
	if grep -Fq "preserves \`no-auto-dispatch\`" "$workflow_path"; then
		fail "issue-started workflow still recommends a durable hold: $workflow_path"
	fi
done

git init -q -b main "$canonical_root" || fail "could not initialize canonical fixture"
git -C "$canonical_root" worktree add -q --orphan -b feature/interactive-start-test "$linked_worktree" ||
	fail "could not create linked-worktree fixture"
canonical_root=$(cd "$canonical_root" && pwd -P) || fail "could not resolve canonical fixture"
linked_worktree=$(cd "$linked_worktree" && pwd -P) || fail "could not resolve linked fixture"
unregistered_path=$(cd "$unregistered_path" && pwd -P) || fail "could not resolve unregistered fixture"
export CANONICAL_ROOT="$canonical_root"
export LINKED_WORKTREE="$linked_worktree"
export UNREGISTERED_PATH="$unregistered_path"

headless_out=$(AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION=1 \
	"$full_loop_helper" start "GH#42 local fix" --headless 2>&1)
headless_rc=$?
if [[ $headless_rc -eq 0 ]] || [[ "$headless_out" != *"cannot enter headless/remote worker routing"* ]]; then
	fail "interactive issue marker entered headless routing"
fi

cat >"${stub_dir}/interactive-session-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf 'claim cwd=%s marker=%s args=%s\n' "$(pwd -P)" "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" "$*" >>"$CALL_LOG"
if [[ "${STUB_CLAIM_FAILS:-0}" == "1" && "$1" == "claim" ]]; then
	exit 1
fi
exit 0
STUB

cat >"${stub_dir}/pre-edit-check.sh" <<'STUB'
#!/usr/bin/env bash
printf 'pre-edit cwd=%s args=%s\n' "$(pwd -P)" "$*" >>"$CALL_LOG"
case "${PRE_EDIT_MODE:-valid}" in
valid)
	printf 'LOOP_DECISION=worktree_created\nWORKTREE_PATH=%s\n' "$LINKED_WORKTREE"
	;;
linked-current)
	printf 'OK - already linked\n'
	;;
missing)
	printf 'LOOP_DECISION=worktree_created\n'
	;;
malformed)
	printf 'LOOP_DECISION=worktree_created\nWORKTREE_PATH=relative/path\n'
	;;
unsafe-canonical)
	printf 'LOOP_DECISION=worktree_created\nWORKTREE_PATH=%s\n' "$CANONICAL_ROOT"
	;;
unregistered)
	printf 'LOOP_DECISION=worktree_created\nWORKTREE_PATH=%s\n' "$UNREGISTERED_PATH"
	;;
duplicate)
	printf 'LOOP_DECISION=worktree_created\nWORKTREE_PATH=%s\nWORKTREE_PATH=%s\n' "$LINKED_WORKTREE" "$LINKED_WORKTREE"
	;;
failure)
	printf 'LOOP_DECISION=worktree\n'
	exit 2
	;;
esac
exit 0
STUB

cat >"${stub_dir}/full-loop-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf 'full-loop cwd=%s marker=%s args=%s\n' "$(pwd -P)" "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" "$*" >>"$CALL_LOG"
exit 0
STUB
chmod +x "${stub_dir}/interactive-session-helper.sh" "${stub_dir}/pre-edit-check.sh" "${stub_dir}/full-loop-helper.sh"

assert_help_only() {
	local description="$1"
	shift
	local help_output=""
	local help_rc=0
	local usage_count=0
	: >"$call_log"
	help_output=$(PATH="${stub_dir}:$PATH" "$helper" "$@" 2>&1) || help_rc=$?
	[[ "$help_rc" -eq 0 ]] || fail "${description} returned ${help_rc}"
	usage_count=$(printf '%s\n' "$help_output" | grep -c '^Usage:')
	[[ "$usage_count" -eq 1 ]] || fail "${description} printed usage ${usage_count} times"
	[[ ! -s "$call_log" ]] || fail "${description} invoked a lifecycle helper"
	return 0
}

assert_help_only "long help" --help
assert_help_only "short help" -h
assert_help_only "help after options" --issue 42 --repo owner/repo --help --task "ignored task"

(
	cd "$canonical_root" || exit 1
	PRE_EDIT_MODE=valid PATH="${stub_dir}:$PATH" \
		"$helper" --issue 42 --repo owner/repo --task "local fix" </dev/null
) || fail "canonical-rooted issue start failed"

assert_log_line "claim cwd=${canonical_root} marker=1 args=claim 42 owner/repo --implementing --defer-comment"
assert_log_line "pre-edit cwd=${canonical_root} args=--loop-mode --task local fix"
assert_log_line "claim cwd=${canonical_root} marker=1 args=claim 42 owner/repo --implementing --worktree ${linked_worktree}"
assert_log_line "full-loop cwd=${linked_worktree} marker=1 args=start GH#42 local fix"

: >"$call_log"
(
	cd "$linked_worktree" || exit 1
	PRE_EDIT_MODE=linked-current PATH="${stub_dir}:$PATH" \
		"$helper" --issue 43 --repo owner/repo --task "queued fix" --auto-dispatch --background
) || fail "linked issue start failed"
assert_log_line "claim cwd=${linked_worktree} marker=1 args=claim 43 owner/repo --implementing --defer-comment"
assert_log_line "claim cwd=${linked_worktree} marker=1 args=claim 43 owner/repo --implementing --worktree ${linked_worktree}"
assert_log_line "full-loop cwd=${linked_worktree} marker=1 args=start GH#43 queued fix --background"

: >"$call_log"
if STUB_CLAIM_FAILS=1 PATH="${stub_dir}:$PATH" \
	"$helper" --issue 31317 --repo owner/repo --task "failed claim" </dev/null >/dev/null 2>&1; then
	fail "failed initial claim reached success"
fi
if grep -q '^pre-edit \|^full-loop ' "$call_log"; then
	fail "failed initial claim reached pre-edit or full-loop startup"
fi

for invalid_mode in missing malformed unsafe-canonical unregistered duplicate failure; do
	: >"$call_log"
	if PRE_EDIT_MODE="$invalid_mode" PATH="${stub_dir}:$PATH" \
		"$helper" --issue 44 --repo owner/repo --task "invalid worktree" </dev/null >/dev/null 2>&1; then
		fail "invalid pre-edit mode ${invalid_mode} reached success"
	fi
	if grep -q '^full-loop ' "$call_log"; then
		fail "invalid pre-edit mode ${invalid_mode} reached full-loop"
	fi
done

printf 'PASS interactive issue start enters only the verified linked worktree\n'
exit 0
