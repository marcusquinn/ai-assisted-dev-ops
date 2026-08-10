#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-no-orphan.sh — t2548 regression guard.
#
# Asserts that `_ensure_todo_entry_written()` in claim-task-id.sh appends a
# TODO.md entry with ref:GH#NNN after a verified issue creation when the
# task ID is not yet present in TODO.md.
#
# Production failure (t2548):
#   `claim-task-id.sh --title X --description Y` created a GitHub issue
#   (via _try_issue_sync_delegation OR the bare `gh issue create` fallback)
#   but NEVER wrote a TODO.md entry when the task ID wasn't already
#   registered in TODO.md. `_push_process_task` in issue-sync-helper.sh
#   silently returns 0 when `target_task` is missing from TODO.md;
#   `add_gh_ref_to_todo` is a modify-existing-line helper and no-ops.
#   Evidence: 4/4 orphans from one ILDS session 2026-04-20 (t135-t138).
#
# Fix (Option A, t2548): idempotent `_ensure_todo_entry_written` helper
# called from `create_github_issue` on both the delegation success path
# and the bare-fallback path.
#
# Tests:
#   1. Missing entry + no Backlog → appended at EOF with ref
#   2. Missing entry + Backlog section present → appended inside Backlog
#   3. Entry already present → ref stamped, no duplicate added
#   4. Empty labels → no tag suffix, still valid line
#   5. Reserved-prefix labels (status:, tier:, origin:) are skipped
#   6. `bug` / `enhancement` labels map to `#bug` / `#feat` tags
#   7. No TODO.md file → silent no-op (non-fatal)
#   8. Empty task_id or issue_num → silent no-op (non-fatal)
#   9. Existing entry with a different GH ref returns failure
#   10. issue-sync no-number + duplicate recovery stamps TODO ref
#   11. bare fallback recovers partial ref persistence without duplicates
#   12. delegated creation reports mapping persistence failure
#   13. long TODO early-match verification is SIGPIPE-safe under pipefail

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="$1"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Source claim-task-id.sh to gain access to internal helper functions.
# The BASH_SOURCE guard in the script prevents main() from running.
# shellcheck disable=SC1090
if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
	printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
	exit 1
fi

if ! declare -F _ensure_todo_entry_written >/dev/null 2>&1; then
	printf '%s[FATAL]%s _ensure_todo_entry_written not defined after sourcing\n' \
		"$RED" "$NC" >&2
	exit 1
fi

# Issue creation now requires a verified publication blocker before local
# planning lands. These persistence tests isolate TODO/ref convergence; the
# blocker failure path is covered by test-issue-sync-publication-pending.sh.
_verify_publication_pending_label() { return 0; }

printf '%sRunning _ensure_todo_entry_written tests (t2548)%s\n' "$BLUE" "$NC"

# ---------------------------------------------------------------------------
# Test 1 — Missing entry + no Backlog section → appended at EOF
# ---------------------------------------------------------------------------
test_missing_no_backlog() {
	local name="1: missing entry + no Backlog → appended at EOF with ref"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	cat >"${tmpdir}/TODO.md" <<'EOF'
# Project TODO

## Ready

- [ ] t001 pre-existing ref:GH#1

## Done

- [x] t000 historical ref:GH#0
EOF

	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "" "$tmpdir"

	if grep -qE "^- \[ \] t2548 fix orphan bug ref:GH#20180$" "${tmpdir}/TODO.md"; then
		pass "$name"
	else
		fail "$name" "line not found: $(grep 't2548' "${tmpdir}/TODO.md" || echo '(none)')"
	fi
	return 0
}
test_missing_no_backlog

# ---------------------------------------------------------------------------
# Test 2 — Missing entry + Backlog section → appended inside Backlog
# ---------------------------------------------------------------------------
test_missing_with_backlog() {
	local name="2: missing entry + Backlog present → appended inside Backlog"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	cat >"${tmpdir}/TODO.md" <<'EOF'
# Project TODO

## Tasks

- [ ] t001 existing task ref:GH#1

## Backlog

- [ ] t002 backlog item ref:GH#2

## Done

- [x] t000 done ref:GH#0
EOF

	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "" "$tmpdir"

	# Line must exist AND appear between ## Backlog and ## Done
	local backlog_line done_line new_line
	backlog_line=$(grep -n '^## Backlog' "${tmpdir}/TODO.md" | cut -d: -f1)
	done_line=$(grep -n '^## Done' "${tmpdir}/TODO.md" | cut -d: -f1)
	new_line=$(grep -n 't2548' "${tmpdir}/TODO.md" | cut -d: -f1)

	if [[ -n "$new_line" && -n "$backlog_line" && -n "$done_line" ]] \
		&& [[ "$new_line" -gt "$backlog_line" ]] \
		&& [[ "$new_line" -lt "$done_line" ]]; then
		pass "$name"
	else
		fail "$name" "backlog=${backlog_line} done=${done_line} new=${new_line:-absent}"
	fi
	return 0
}
test_missing_with_backlog

# ---------------------------------------------------------------------------
# Test 3 — Entry already present → no duplicate line added
# ---------------------------------------------------------------------------
test_entry_already_present() {
	local name="3: entry already present → no duplicate line added"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	cat >"${tmpdir}/TODO.md" <<'EOF'
# Tasks

- [ ] t2548 fix orphan bug ref:GH#20180
EOF

	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "" "$tmpdir"

	local count
	count=$(grep -c 't2548' "${tmpdir}/TODO.md" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	if [[ "$count" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected 1 occurrence, got ${count}"
	fi
	return 0
}
test_entry_already_present

# ---------------------------------------------------------------------------
# Test 4 — Empty labels → no tag suffix, valid line
# ---------------------------------------------------------------------------
test_empty_labels() {
	local name="4: empty labels → no tag suffix in appended line"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	printf '# Tasks\n\n' >"${tmpdir}/TODO.md"

	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "" "$tmpdir"

	if grep -qE "^- \[ \] t2548 fix orphan bug ref:GH#20180$" "${tmpdir}/TODO.md"; then
		pass "$name"
	else
		fail "$name" "$(grep 't2548' "${tmpdir}/TODO.md" || echo '(none)')"
	fi
	return 0
}
test_empty_labels

# ---------------------------------------------------------------------------
# Test 5 — Reserved-prefix labels skipped; plain labels become tags
# ---------------------------------------------------------------------------
test_reserved_label_filtering() {
	local name="5: reserved-prefix labels filtered; plain labels become tags"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	printf '# Tasks\n\n' >"${tmpdir}/TODO.md"

	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" \
		"status:queued,tier:standard,origin:worker,auto-dispatch" "$tmpdir"

	if grep -qE "^- \[ \] t2548 fix orphan bug #auto-dispatch ref:GH#20180$" \
		"${tmpdir}/TODO.md"; then
		pass "$name"
	else
		fail "$name" "$(grep 't2548' "${tmpdir}/TODO.md" || echo '(none)')"
	fi
	return 0
}
test_reserved_label_filtering

# ---------------------------------------------------------------------------
# Test 6 — `bug` / `enhancement` labels map to `#bug` / `#feat`
# ---------------------------------------------------------------------------
test_label_mapping() {
	local name="6: bug/enhancement labels map to #bug/#feat"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	printf '# Tasks\n\n' >"${tmpdir}/TODO.md"

	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" \
		"bug,enhancement" "$tmpdir"

	if grep -qE "^- \[ \] t2548 fix orphan bug #bug #feat ref:GH#20180$" \
		"${tmpdir}/TODO.md"; then
		pass "$name"
	else
		fail "$name" "$(grep 't2548' "${tmpdir}/TODO.md" || echo '(none)')"
	fi
	return 0
}
test_label_mapping

# ---------------------------------------------------------------------------
# Test 7 — No TODO.md file → silent no-op
# ---------------------------------------------------------------------------
test_no_todo_file() {
	local name="7: no TODO.md → silent no-op (non-fatal)"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local rc=0
	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "" "$tmpdir" || rc=$?
	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "returned non-zero: $rc"
	fi
	return 0
}
test_no_todo_file

# ---------------------------------------------------------------------------
# Test 8 — Empty task_id or issue_num → silent no-op
# ---------------------------------------------------------------------------
test_empty_task_id() {
	local name="8: empty task_id → silent no-op"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	printf '# Tasks\n\n' >"${tmpdir}/TODO.md"

	local rc=0
	_ensure_todo_entry_written "" "20180" "fix orphan bug" "" "$tmpdir" || rc=$?
	local lc
	lc=$(wc -l <"${tmpdir}/TODO.md")
	if [[ $rc -eq 0 && "$lc" -le 3 ]]; then
		pass "$name"
	else
		fail "$name" "rc=${rc} lines=${lc}"
	fi
	return 0
}
test_empty_task_id

# ---------------------------------------------------------------------------
# Test 9 — Existing entry with a different GH ref must fail verification
# ---------------------------------------------------------------------------
test_existing_wrong_ref_fails() {
	local name="9: existing entry with different GH ref → returns failure"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	cat >"${tmpdir}/TODO.md" <<'EOF'
# Tasks

- [ ] t2548 fix orphan bug ref:GH#99999
EOF

	local rc=0
	_ensure_todo_entry_written "t2548" "20180" "fix orphan bug" "" "$tmpdir" || rc=$?
	if [[ $rc -ne 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero when ref:GH#20180 could not be verified"
	fi
	return 0
}
test_existing_wrong_ref_fails

# ---------------------------------------------------------------------------
# Test 10 — issue-sync creates but emits no number; duplicate recovery still
# stamps TODO.md with the recovered issue number before create_github_issue
# reports success (GH#22381).
# ---------------------------------------------------------------------------
test_issue_sync_no_number_duplicate_recovery_stamps_ref() {
	local name="10: issue-sync no-number duplicate recovery stamps TODO ref"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	cat >"${tmpdir}/TODO.md" <<'EOF'
# Project TODO

## Backlog

- [ ] t3481 Preserve TODO refs after fallback issue creation #bug #auto-dispatch
EOF

	_try_issue_sync_delegation() {
		return 1
	}
	_check_duplicate_issue() {
		printf '22370'
		return 0
	}

	local issue_num rc=0
	issue_num=$(create_github_issue \
		"t3481: Preserve TODO refs after fallback issue creation" \
		"description not used on duplicate recovery" \
		"bug,auto-dispatch" \
		"$tmpdir") || rc=$?

	if [[ $rc -eq 0 && "$issue_num" == "22370" ]] && \
		grep -qE '^- \[ \] t3481 .*ref:GH#22370$' "${tmpdir}/TODO.md"; then
		pass "$name"
	else
		fail "$name" "rc=${rc} issue=${issue_num:-<empty>} line=$(grep 't3481' "${tmpdir}/TODO.md" || echo '(none)')"
	fi
	return 0
}
test_issue_sync_no_number_duplicate_recovery_stamps_ref

# ---------------------------------------------------------------------------
# Test 11 — issue-sync emits no number, bare fallback creates one issue, and a
# partial first TODO persistence result converges on retry. A second invocation
# recovers the same issue rather than creating a duplicate.
# ---------------------------------------------------------------------------
test_bare_fallback_partial_persistence_recovery() {
	local name="11: bare fallback converges partial persistence without duplicate"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN
	printf '# Project TODO\n\n## Backlog\n\n' >"${tmpdir}/TODO.md"

	_try_issue_sync_delegation() { return 1; }
	_extract_github_slug() { printf 'owner/repo\n'; return 0; }
	_auto_assign_issue() { return 0; }
	_interactive_session_auto_claim_new_task() { return 0; }
	_lock_maintainer_issue_at_creation() { return 0; }
	_link_parent_issue_post_create() { return 0; }
	_check_duplicate_issue() {
		if [[ -f "${tmpdir}/created" ]]; then
			printf '9290\n'
			return 0
		fi
		return 1
	}
	gh_create_issue() {
		printf 'created\n' >>"${tmpdir}/created"
		printf 'https://github.com/owner/repo/issues/9290\n'
		return 0
	}
	_ensure_todo_entry_written() {
		local task_id="$1" issue_num="$2" title="$3" labels="$4" repo_path="$5"
		if ! _todo_entry_has_gh_ref "$task_id" "$issue_num" "${repo_path}/TODO.md"; then
			_insert_todo_line "${repo_path}/TODO.md" \
				"- [ ] ${task_id} ${title#"${task_id}: "} #${labels%%,*} ref:GH#${issue_num}"
			return 1
		fi
		return 0
	}
	require_task_issue_mapping() {
		local task_id="$1" todo_file="$2" repo="$3" issue_num="$4"
		_todo_entry_has_gh_ref "$task_id" "$issue_num" "$todo_file" || return 1
		printf '%s|%s|%s\n' "$task_id" "$repo" "$issue_num" >"${tmpdir}/mapping"
		return 0
	}

	local first second rc=0
	first=$(create_github_issue "t9290: fallback recovery" "worker-ready body" \
		"bug,auto-dispatch" "$tmpdir") || rc=$?
	second=$(create_github_issue "t9290: fallback recovery" "worker-ready body" \
		"bug,auto-dispatch" "$tmpdir") || rc=$?
	local issue_count todo_count
	issue_count=$(wc -l <"${tmpdir}/created")
	todo_count=$(grep -c '^[[:space:]]*- \[ \] t9290 ' "${tmpdir}/TODO.md" || true)

	if [[ $rc -eq 0 && "$first" == "9290" && "$second" == "9290" && \
		"$issue_count" -eq 1 && "$todo_count" -eq 1 ]] && \
		grep -q '^t9290|owner/repo|9290$' "${tmpdir}/mapping"; then
		pass "$name"
	else
		fail "$name" "rc=${rc} first=${first:-none} second=${second:-none} issues=${issue_count} todos=${todo_count}"
	fi
	return 0
}
test_bare_fallback_partial_persistence_recovery

# ---------------------------------------------------------------------------
# Test 12 — delegated creation must not report success after the issue exists
# when durable task mapping convergence fails.
# ---------------------------------------------------------------------------
test_delegated_creation_mapping_failure() {
	local name="12: delegated creation reports mapping persistence failure"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN
	printf '# Project TODO\n' >"${tmpdir}/TODO.md"

	_try_issue_sync_delegation() { printf '9390\n'; return 0; }
	_auto_assign_issue() { return 0; }
	_interactive_session_auto_claim_new_task() { return 0; }
	_lock_maintainer_issue_at_creation() { return 0; }
	_link_parent_issue_post_create() { return 0; }
	_converge_created_issue_ref() { return 1; }

	local output="" rc=0
	output=$(create_github_issue "t9390: delegated recovery" "worker-ready body" \
		"bug,auto-dispatch" "$tmpdir") || rc=$?
	if [[ $rc -ne 0 && -z "$output" ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero with no reported issue number; rc=${rc} output=${output:-<empty>}"
	fi
	return 0
}
test_delegated_creation_mapping_failure

# ---------------------------------------------------------------------------
# Test 13 — grep -q used to close its input after an early match, causing the
# strip_code_fences producer to receive SIGPIPE on long TODO files. Under
# pipefail that made a present ref look absent.
# ---------------------------------------------------------------------------
test_long_todo_early_match_is_pipefail_safe() {
	local name="13: long TODO early-match verification is pipefail-safe"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	printf '%s\n' '- [ ] t9490 durable mapping ref:GH#9490' >"${tmpdir}/TODO.md"
	local i
	for ((i = 0; i < 50000; i++)); do
		printf -- '- [ ] t%05d unrelated task without a GitHub ref\n' "$i"
	done >>"${tmpdir}/TODO.md"

	local rc=0
	(
		set -o pipefail
		_todo_entry_has_gh_ref "t9490" "9490" "${tmpdir}/TODO.md"
	) || rc=$?
	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "present early ref returned ${rc} under pipefail"
	fi
	return 0
}
test_long_todo_early_match_is_pipefail_safe

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n'
printf '%sResults: %d passed, %d failed%s\n' "$BLUE" "$PASS" "$FAIL" "$NC"
if [[ $FAIL -gt 0 ]]; then
	printf '%sFailed tests:%s%s\n' "$RED" "$NC" "$ERRORS"
	exit 1
fi
exit 0
