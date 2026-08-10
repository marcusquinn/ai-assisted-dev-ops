#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# task-id-collision-guard.sh — git commit-msg hook and CI check.
#
# Scans commit subjects (and bodies) for t\d+ references and rejects commits
# where a referenced t-ID appears to be invented — i.e., greater than the
# current .task-counter on the merge base AND not cross-referenced via a
# linked GitHub issue title that confirms the ID was claimed by someone else.
#
# Modes:
#   Default (commit-msg hook):
#     Called with arg1 = path to the commit message file.
#     Exits 0 (allow) or 1 (reject with actionable error).
#
#   check-pr <PR_NUMBER>:
#     Scans every commit in the PR range (merge-base..HEAD) AND the PR title.
#     A worker can open a PR whose title advertises a tNNN not in any commit —
#     the title scan closes that gap (GH#19987).
#     Used by CI to catch commits authored outside the hook.
#     Exits 0 (all clean) or 1 (one or more violations).
#
#   check-push <BEFORE_SHA> <AFTER_SHA>:
#     Scans non-merge commits in a push and supplements squash commit messages
#     with their associated PR title/body before checking linked issue proof.
#     Exits 0 (all clean) or 1 (one or more violations).
#
# Environment:
#   TASK_ID_GUARD_DISABLE=1   — bypass for this invocation (equivalent to --no-verify)
#   TASK_ID_GUARD_DEBUG=1     — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - gh CLI unavailable or unauthenticated
#   - .task-counter not present on merge base
#   - offline state
#   - git command failures

set -u

_task_id_guard_dir="${BASH_SOURCE[0]%/*}"
[[ "$_task_id_guard_dir" == "${BASH_SOURCE[0]}" ]] && _task_id_guard_dir="."
# shellcheck source=../scripts/task-identity-lib.sh
source "${_task_id_guard_dir}/../scripts/task-identity-lib.sh"
unset _task_id_guard_dir

# ---------------------------------------------------------------------------
# Bypass
# ---------------------------------------------------------------------------

if [[ "${TASK_ID_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[task-id-guard][INFO] TASK_ID_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_debug() {
	local msg="$1"
	[[ "${TASK_ID_GUARD_DEBUG:-0}" == "1" ]] && printf '[task-id-guard][DEBUG] %s\n' "$msg" >&2
	return 0
}

_warn() {
	local msg="$1"
	printf '[task-id-guard][WARN] %s\n' "$msg" >&2
	return 0
}

_info() {
	local msg="$1"
	printf '[task-id-guard][INFO] %s\n' "$msg" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Read the .task-counter value at a given git ref.
# Returns the integer or empty string on failure.
# ---------------------------------------------------------------------------
_read_counter_at_ref() {
	local ref="${1:-}"
	if [[ -z "$ref" ]]; then
		return 1
	fi
	local val
	val=$(git show "${ref}:.task-counter" 2>/dev/null | tr -d '[:space:]')
	if [[ "$val" =~ ^[0-9]+$ ]]; then
		printf '%s' "$val"
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Resolve the current task counter by taking the MAX across multiple known-good
# sources. .task-counter is monotonically increasing so max == most current.
#
# This prevents stale-worktree false positives: claims may advance either the
# dedicated task-id-counter CAS branch or the default branch after a worktree
# was created. Reading both remote tips returns the authoritative counter,
# regardless of merge-base age or counter-branch rollout state.
#
# Returns the integer counter string (no newline), or empty string on failure.
# ---------------------------------------------------------------------------
_resolve_current_counter() {
	local best=""
	local val ref
	# Priority sources, highest-freshness first. We take the MAX across all,
	# not the first — .task-counter is monotonic so max == most current.
	for ref in "origin/task-id-counter" "task-id-counter" \
		"origin/main" "origin/master" "main" "master" "HEAD"; do
		if git rev-parse --verify "$ref" >/dev/null 2>&1; then
			val=$(git show "${ref}:.task-counter" 2>/dev/null | tr -d '[:space:]')
			if [[ "$val" =~ ^[0-9]+$ ]]; then
				# Force base-10 (10#) so leading-zero values like "008" don't trip
				# bash's octal parser — same root cause as the line 290 comparison
				# fixed in GH#19620. The ^[0-9]+$ guard above makes 10# safe.
				if [[ -z "$best" ]] || ((10#$val > 10#$best)); then
					best="$val"
				fi
			fi
		fi
	done
	# Also consider working copy (covers detached-HEAD / no-remote edge cases)
	if [[ -f .task-counter ]]; then
		val=$(tr -d '[:space:]' <.task-counter)
		if [[ "$val" =~ ^[0-9]+$ ]]; then
			# Force base-10 (10#) — same octal-trap fix as above.
			if [[ -z "$best" ]] || ((10#$val > 10#$best)); then
				best="$val"
			fi
		fi
	fi
	[[ -n "$best" ]] && printf '%s' "$best"
	return 0
}

# ---------------------------------------------------------------------------
# Determine the merge base between HEAD and the default branch (main/master).
# Falls back to the root commit.
# ---------------------------------------------------------------------------
_find_merge_base() {
	if [[ -n "${_TASK_ID_GUARD_MERGE_BASE_CACHE:-}" ]]; then
		printf '%s' "$_TASK_ID_GUARD_MERGE_BASE_CACHE"
		return 0
	fi

	local base="" ref
	# Try main first, then master
	for branch in main master; do
		ref="origin/${branch}"
		if git rev-parse --verify "$ref" >/dev/null 2>&1; then
			base=$(git merge-base HEAD "$ref" 2>/dev/null) && break
		elif git rev-parse --verify "$branch" >/dev/null 2>&1; then
			base=$(git merge-base HEAD "$branch" 2>/dev/null) && break
		fi
	done
	if [[ -z "$base" ]]; then
		# Fallback: root commit of the current branch
		base=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
	fi
	printf '%s' "$base"
	return 0
}

# ---------------------------------------------------------------------------
# Resolve the best ref for "the upstream default branch tip" for use as the
# left-hand side of `git log A..HEAD`. Prefers origin/main, then origin/master,
# then local main, then local master. Returns empty if none found.
#
# Used by _run_check_pr (t2895) to scope the commit list to the PR's unique
# commits, excluding upstream commits brought in via a merge from main. This
# is critical for performance when a PR has merged main to resolve conflicts —
# the merge-base..HEAD range expands to include all commits between fork-point
# and the new main tip, which can be hundreds of commits on long-lived branches.
# ---------------------------------------------------------------------------
_find_default_branch_ref() {
	local branch ref
	for branch in main master; do
		ref="origin/${branch}"
		if git rev-parse --verify "$ref" >/dev/null 2>&1; then
			printf '%s' "$ref"
			return 0
		fi
	done
	for branch in main master; do
		if git rev-parse --verify "$branch" >/dev/null 2>&1; then
			printf '%s' "$branch"
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# Subject caches (t2895 performance fix).
#
# When invoked in check-pr mode, _check_message is called per commit in the
# PR range. Each call may trigger _branch_has_claim and _repo_has_claim, both
# of which run `git log` against the same data set. Without caching, these
# scans are repeated O(N_commits × M_tids) times — for a PR with 143 commits
# brought in via a merge from main, this caused 21+ minute hangs in CI before
# being cancelled (canonical: PR #20913).
#
# These caches are populated once per check-pr invocation and read by the
# subject-list helpers below. Commit-msg hook mode does NOT populate these,
# so its behavior is unchanged (single-commit scope, caching not worthwhile).
# ---------------------------------------------------------------------------
_TASK_ID_GUARD_BRANCH_SUBJECTS=""
_TASK_ID_GUARD_BRANCH_SUBJECTS_HOT="0"
_TASK_ID_GUARD_REPO_SUBJECTS=""
_TASK_ID_GUARD_REPO_SUBJECTS_HOT="0"
_TASK_ID_GUARD_MERGE_BASE_CACHE=""

# Emit `git log --format='%s' BASE..HEAD` output, using the cache when hot.
# Args:
#   arg1 = base ref (e.g. merge-base SHA)
_branch_subjects() {
	local base="${1:-}"
	if [[ "$_TASK_ID_GUARD_BRANCH_SUBJECTS_HOT" == "1" ]]; then
		[[ -n "$_TASK_ID_GUARD_BRANCH_SUBJECTS" ]] && printf '%s\n' "$_TASK_ID_GUARD_BRANCH_SUBJECTS"
		return 0
	fi
	[[ -n "$base" ]] && git log --format='%s' "${base}..HEAD" 2>/dev/null
	return 0
}

# Emit `git log --all --format='%s'` output, using the cache when hot.
_repo_subjects() {
	if [[ "$_TASK_ID_GUARD_REPO_SUBJECTS_HOT" == "1" ]]; then
		[[ -n "$_TASK_ID_GUARD_REPO_SUBJECTS" ]] && printf '%s\n' "$_TASK_ID_GUARD_REPO_SUBJECTS"
		return 0
	fi
	git log --all --format='%s' 2>/dev/null
	return 0
}

# Pre-populate both subject caches. Call once at entry of _run_check_pr so
# subsequent _branch_has_claim / _repo_has_claim calls hit the cache instead
# of forking git per (commit, t-ID) pair.
# Args:
#   arg1 = base ref for branch subjects (typically the merge-base SHA)
_populate_check_pr_caches() {
	local base="${1:-}"
	if [[ -n "$base" ]]; then
		_TASK_ID_GUARD_BRANCH_SUBJECTS=$(git log --format='%s' "${base}..HEAD" 2>/dev/null)
		_TASK_ID_GUARD_BRANCH_SUBJECTS_HOT="1"
	fi
	_TASK_ID_GUARD_REPO_SUBJECTS=$(git log --all --format='%s' 2>/dev/null)
	_TASK_ID_GUARD_REPO_SUBJECTS_HOT="1"
	_TASK_ID_GUARD_MERGE_BASE_CACHE="$base"
	return 0
}

# ---------------------------------------------------------------------------
# Check whether a given t-ID has a matching claim commit on the current
# branch between merge-base and HEAD. The claim commit subject must match
# `chore: claim tNNN[..tMMM] [nonce]` (single or range form — see
# allocate_counter_cas in claim-task-id.sh lines 684-689).
#
# Returns 0 if a claim commit is found, 1 otherwise.
# ---------------------------------------------------------------------------
_branch_has_claim() {
	local tid="${1:-}"
	local base
	base=$(_find_merge_base)
	if [[ -z "$base" ]]; then
		_debug "merge-base empty — cannot verify branch claim, allowing"
		return 0
	fi
	# Match single claim: "chore: claim t001 [nonce]"
	# Match range claim:  "chore: claim t001..t003 [nonce]"
	# Use git log with %s (subject) and grep for the tid as word.
	local num
	num=$(printf '%s' "$tid" | tr -d 't')
	if ! [[ "$num" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	local branch_subjects
	branch_subjects=$(_branch_subjects "$base")
	# Look for an exact single-ID claim first.
	if grep -qE "^chore: claim t0*${num}( |\$|\\[)" <<<"$branch_subjects"; then
		return 0
	fi
	# Look for a range claim that covers num: chore: claim tA..tB
	local line low high
	while IFS= read -r line; do
		# Extract tA and tB from "chore: claim t00A..t00B [nonce]"
		if [[ "$line" =~ ^chore:\ claim\ t0*([0-9]+)\.\.t0*([0-9]+) ]]; then
			low="${BASH_REMATCH[1]}"
			high="${BASH_REMATCH[2]}"
			if ((10#$num >= 10#$low && 10#$num <= 10#$high)); then
				return 0
			fi
		fi
	done <<<"$branch_subjects"
	return 1
}

# ---------------------------------------------------------------------------
# Check whether a given t-ID has a matching claim commit anywhere in the
# repo history (git log --all). This catches t-IDs that were claimed in
# prior merged PRs and are now being referenced in prose (e.g., "the t2574
# REST fallback covers..."). The claim commit subject must match
# `chore: claim tNNN[..tMMM] [nonce]` (single or range form).
#
# Returns 0 if a claim commit is found, 1 otherwise.
# ---------------------------------------------------------------------------
_repo_has_claim() {
	local tid="${1:-}"
	local num
	num=$(printf '%s' "$tid" | tr -d 't')
	if ! [[ "$num" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	local repo_subjects
	repo_subjects=$(_repo_subjects)
	# Look for an exact single-ID claim first.
	if grep -qE "^chore: claim t0*${num}( |\$|\\[)" <<<"$repo_subjects"; then
		return 0
	fi
	# Look for a range claim that covers num: chore: claim tA..tB
	local line low high
	while IFS= read -r line; do
		# Extract tA and tB from "chore: claim t00A..t00B [nonce]"
		if [[ "$line" =~ ^chore:\ claim\ t0*([0-9]+)\.\.t0*([0-9]+) ]]; then
			low="${BASH_REMATCH[1]}"
			high="${BASH_REMATCH[2]}"
			if ((10#$num >= 10#$low && 10#$num <= 10#$high)); then
				return 0
			fi
		fi
	done <<<"$repo_subjects"
	return 1
}

# ---------------------------------------------------------------------------
# Extract all tNNN references from text.
# Outputs one per line.
# ---------------------------------------------------------------------------
_extract_tids() {
	local text="${1:-}"
	local scan_text=""
	# Allocator range claims are a separate, legacy-only grammar consumed by
	# _branch_has_claim/_repo_has_claim. Remove only that exact generated form
	# before lexical task-ID validation so `t120..t130` is not misclassified as
	# a malformed canonical ID when check-pr scans the claim commit itself.
	scan_text=$(printf '%s' "$text" | sed -E 's/chore: claim t[0-9]+\.\.t[0-9]+//g')
	if task_identity_has_malformed_candidate "$scan_text"; then
		printf '%s\n' '__malformed__'
		return 0
	fi
	task_identity_extract_all "$scan_text" | sort -u
	return 0
}

_legacy_sequence_for_collision_check() {
	local task_id="${1:-}"
	task_identity_parse "$task_id" || return 1
	if [[ "$TASK_IDENTITY_KIND" == "legacy" ]]; then
		printf '%s\n' "$TASK_IDENTITY_SEQUENCE"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Extract issue numbers from Resolves|Closes|Fixes|Ref|For footer lines.
# Accepts both closing keywords (Resolves, Closes, Fixes) and non-closing
# reference keywords (Ref, For) — the downstream title-match verification
# is unchanged, so adding Ref/For doesn't weaken the safety check.
# Outputs one per line.
# ---------------------------------------------------------------------------
_extract_closing_issues() {
	local text="${1:-}"
	printf '%s' "$text" | grep -iE '(Resolves|Closes|Fixes|Ref|For)[[:space:]]+#[0-9]+' |
		grep -oE '#[0-9]+' | tr -d '#' | sort -u
	return 0
}

# ---------------------------------------------------------------------------
# Cross-reference a single t-ID against closing issues via the gh API.
# Args:
#   arg1 = tid (e.g. "t2047")
#   arg2 = newline-separated closing issue numbers
# Returns:
#   0 = confirmed (title of at least one linked issue contains the t-ID)
#   1 = not confirmed (violation)
#   2 = fail-open (gh unavailable or API error with no confirmation)
# ---------------------------------------------------------------------------
_verify_tid_via_issues() {
	local tid="${1:-}"
	local closing_issues="${2:-}"

	if [[ -z "$closing_issues" ]]; then
		_debug "$tid: no linked issues (Resolves/Closes/Fixes/Ref/For) — marking as violation"
		return 1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		_warn "gh not available — fail-open (CI will validate on push)"
		return 2
	fi

	local iss_num
	local gh_had_error=0
	local confirmed=0
	while IFS= read -r iss_num; do
		[[ -z "$iss_num" ]] && continue
		local title
		title=$(gh issue view "$iss_num" --json title --jq '.title' 2>/dev/null)
		local gh_rc=$?
		if [[ "$gh_rc" -ne 0 || -z "$title" ]]; then
			_debug "gh issue view #${iss_num} failed (rc=${gh_rc}) — marking gh_had_error"
			gh_had_error=1
			continue
		fi
		_debug "Issue #${iss_num} title: $title"
		local title_tid=""
		title_tid=$(task_identity_parse_title_prefix "$title" || true)
		if [[ "$title_tid" == "$tid" ]]; then
			_debug "$tid confirmed via linked issue #${iss_num}"
			confirmed=1
			break
		fi
	done <<<"$closing_issues"

	if [[ "$gh_had_error" -eq 1 && "$confirmed" -eq 0 ]]; then
		_warn "gh API error during cross-reference check — fail-open (CI will validate on push)"
		return 2
	fi

	[[ "$confirmed" -eq 1 ]] && return 0
	return 1
}

# ---------------------------------------------------------------------------
# Print the violation block to stderr.
# Args:
#   arg1 = violations string (printf %b-formatted lines)
#   arg2 = commit subject (for display)
# ---------------------------------------------------------------------------
_report_violations() {
	local violations="${1:-}"
	local subject="${2:-<unknown>}"
	printf '\n[task-id-guard][BLOCK] Commit subject references invented or unclaimed task ID(s):\n\n' >&2
	printf '  Subject: %s\n\n' "$subject" >&2
	printf '%b\n' "$violations" >&2
	printf '  To fix:\n' >&2
	printf '    1. Remove the t-ID from the commit subject/body, OR\n' >&2
	printf '    2. Claim the ID first: claim-task-id.sh --title "..." → then use the allocated ID, OR\n' >&2
	printf '    3. If cross-referencing another person'"'"'s task, add "Resolves/Closes/Fixes/Ref/For #NNN" footer\n' >&2
	printf '       where the linked issue title contains the t-ID.\n' >&2
	printf '  Bypass (sets audit trail): TASK_ID_GUARD_DISABLE=1 git commit ...  or git commit --no-verify\n\n' >&2
	return 0
}

# Check one extracted task identity. Sets CHECK_MESSAGE_VIOLATION when the
# identity is invalid. Returns 0 (clean), 1 (violation), or 2 (fail-open).
_check_tid() {
	local tid="$1"
	local counter="$2"
	local closing_issues="$3"
	local num=""
	CHECK_MESSAGE_VIOLATION=""

	if ! num=$(_legacy_sequence_for_collision_check "$tid"); then
		CHECK_MESSAGE_VIOLATION="  ${tid} — malformed task identity\n"
		return 1
	fi
	if [[ -z "$num" ]]; then
		_debug "$tid is origin-namespaced — verifying canonical linked issue binding"
		local namespaced_verify_rc=0
		_verify_tid_via_issues "$tid" "$closing_issues" || namespaced_verify_rc=$?
		if [[ "$namespaced_verify_rc" -eq 2 ]]; then
			return 2
		fi
		if [[ "$namespaced_verify_rc" -ne 0 ]]; then
			CHECK_MESSAGE_VIOLATION="  ${tid} — namespaced ID is not bound to a linked issue title\n"
			return 1
		fi
		return 0
	fi

	# Force base-10 so leading-zero legacy IDs do not enter Bash's octal parser.
	if ((10#$num <= 10#$counter)); then
		if _branch_has_claim "$tid"; then
			_debug "$tid claimed on this branch — allowed"
			return 0
		fi
		if _repo_has_claim "$tid"; then
			_debug "$tid claimed in repo history — allowed (cross-reference)"
			return 0
		fi
		_debug "$tid ≤ counter but no branch/repo claim — verifying via linked issues"
		local verify_rc=0
		_verify_tid_via_issues "$tid" "$closing_issues" || verify_rc=$?
		if [[ "$verify_rc" -eq 2 ]]; then
			return 2
		fi
		if [[ "$verify_rc" -eq 1 ]]; then
			CHECK_MESSAGE_VIOLATION="  ${tid} — ≤ counter ${counter}, but no 'chore: claim ${tid}' commit on this branch, in repo history, or linked issue title\n"
			return 1
		fi
		return 0
	fi

	_debug "$tid ($num) > counter ($counter) — suspicious, checking linked issues"
	local verify_rc=0
	_verify_tid_via_issues "$tid" "$closing_issues" || verify_rc=$?
	if [[ "$verify_rc" -eq 2 ]]; then
		return 2
	fi
	if [[ "$verify_rc" -eq 1 ]]; then
		CHECK_MESSAGE_VIOLATION="  ${tid} — numeric ID ${num} > current counter ${counter}; no matching issue title was found via a commit footer or associated PR body\n"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Core check: given a commit message, check if any t\d+ reference is invented.
# Args:
#   arg1 = full commit message text
#   arg2 = commit subject (for display in errors), optional
# Returns 0 (clean), 1 (violation found), 2 (fail-open — skip).
# ---------------------------------------------------------------------------
_check_message() {
	local msg="${1:-}"
	local subject="${2:-<unknown>}"

	if [[ -z "$msg" ]]; then
		_debug "Empty commit message — allowing"
		return 0
	fi

	if [[ "$subject" == "<unknown>" ]]; then
		subject=$(printf '%s' "$msg" | head -1)
	fi

	local tids
	tids=$(_extract_tids "$msg")
	if [[ -z "$tids" ]]; then
		_debug "No t-IDs in commit — allowing"
		return 0
	fi

	_debug "Found t-IDs: $(printf '%s' "$tids" | tr '\n' ' ')"

	local counter=""
	counter=$(_resolve_current_counter)
	if [[ -z "$counter" ]]; then
		_warn ".task-counter not readable from any source — fail-open"
		return 2
	fi

	_debug "Current counter value: $counter"

	local closing_issues
	closing_issues=$(_extract_closing_issues "$msg")
	_debug "Closing issues: $(printf '%s' "$closing_issues" | tr '\n' ' ')"

	local violations=""
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		local check_rc=0
		_check_tid "$tid" "$counter" "$closing_issues" || check_rc=$?
		if [[ "$check_rc" -eq 2 ]]; then
			return 2
		fi
		if [[ "$check_rc" -eq 1 ]]; then
			violations="${violations}${CHECK_MESSAGE_VIOLATION}"
		fi
	done <<<"$tids"

	if [[ -n "$violations" ]]; then
		_report_violations "$violations" "$subject"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Commit-msg hook mode (default).
# arg1 = path to commit message file
# ---------------------------------------------------------------------------
_run_hook() {
	local msg_file="${1:-}"
	if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
		_warn "commit-msg: no message file provided — fail-open"
		return 0
	fi

	local msg
	msg=$(cat "$msg_file")
	local subject
	subject=$(head -1 "$msg_file")

	# Skip merge commits, fixup commits, and squash commits
	if printf '%s' "$subject" | grep -qE '^(Merge|fixup!|squash!)'; then
		_debug "Merge/fixup/squash commit — skipping"
		return 0
	fi

	local rc
	_check_message "$msg" "$subject"
	rc=$?

	if [[ "$rc" -eq 2 ]]; then
		# Fail-open
		return 0
	fi
	return "$rc"
}

# ---------------------------------------------------------------------------
# Check the PR title (and body, for cross-reference footers) for invented
# t-IDs. Extracted from _run_check_pr (t2895) to keep that function under the
# 100-line function-complexity gate.
#
# Strategy: concatenate PR title + PR body and run _check_message on the
# combined string. The PR body typically contains the Resolves/Closes/Fixes
# footer that supplies the cross-reference context, so title + body together
# give _check_message everything it needs to distinguish a valid tNNN from
# an invented one. Fail-open if gh is unavailable or the fetch fails.
#
# Returns 1 on violation, 0 otherwise (including fail-open paths).
# ---------------------------------------------------------------------------

_pr_commit_oids() {
	local pr_number="$1"
	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi
	gh pr view "$pr_number" --json commits --jq '.commits[].oid' 2>/dev/null
	return $?
}

_associated_pr_context() {
	local commit_hash="$1"
	local repository="${GITHUB_REPOSITORY:-}"
	if [[ -z "$repository" ]] || ! command -v gh >/dev/null 2>&1; then
		return 1
	fi
	gh api -X GET "repos/${repository}/commits/${commit_hash}/pulls" \
		--jq '.[] | (.title + "\n\n" + (.body // ""))' 2>/dev/null
	return $?
}

_check_push_commit() {
	local commit_hash="$1"
	local commit_msg=""
	local subject=""
	local pr_context=""
	commit_msg=$(git log -1 --format='%s%n%n%b' "$commit_hash" 2>/dev/null) || return 0
	subject=$(git log -1 --format='%s' "$commit_hash" 2>/dev/null) || return 0
	pr_context=$(_associated_pr_context "$commit_hash" || true)
	if [[ -n "$pr_context" ]]; then
		_debug "Adding associated PR context for push commit $commit_hash"
		commit_msg="${commit_msg}"$'\n\n'"${pr_context}"
	fi

	local rc=0
	_check_message "$commit_msg" "$subject" || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		printf '[task-id-guard][VIOLATION] commit %s: %s\n' "$commit_hash" "$subject" >&2
		return 1
	fi
	return 0
}

_run_check_push() {
	local before_sha="${1:-}"
	local after_sha="${2:-HEAD}"
	local commits=""
	if [[ -z "$before_sha" || "$before_sha" == "0000000000000000000000000000000000000000" ]]; then
		commits=$(git rev-list --no-walk --no-merges "$after_sha" 2>/dev/null)
	else
		commits=$(git rev-list --no-merges "${before_sha}..${after_sha}" 2>/dev/null)
	fi
	if [[ -z "$commits" ]]; then
		_info "No non-merge commits in push range — nothing to check"
		return 0
	fi

	local total_violations=0
	local commit_hash
	while IFS= read -r commit_hash; do
		[[ -z "$commit_hash" ]] && continue
		if ! _check_push_commit "$commit_hash"; then
			total_violations=$((total_violations + 1))
		fi
	done <<<"$commits"

	if [[ "$total_violations" -gt 0 ]]; then
		printf '\n[task-id-guard][SUMMARY] %d violation(s) found in push\n' "$total_violations" >&2
		return 1
	fi
	_info "Push clean — no invented t-IDs detected"
	return 0
}

_check_pr_title() {
	local pr_number="$1"
	if ! command -v gh >/dev/null 2>&1; then
		_warn "gh not available — skipping PR title check (fail-open)"
		return 0
	fi
	local pr_title pr_body pr_combined title_rc
	pr_title=$(gh pr view "$pr_number" --json title --jq '.title' 2>/dev/null)
	if [[ -z "$pr_title" ]]; then
		_warn "Could not fetch PR #${pr_number} title via gh — skipping title check (fail-open)"
		return 0
	fi
	pr_body=$(gh pr view "$pr_number" --json body --jq '.body' 2>/dev/null)
	pr_combined="${pr_title}"$'\n\n'"${pr_body:-}"
	_debug "Checking PR #${pr_number} title: $pr_title"
	_check_message "$pr_combined" "PR #${pr_number} title: ${pr_title}"
	title_rc=$?
	[[ "$title_rc" -eq 1 ]] && printf '[task-id-guard][VIOLATION] PR #%s title references invented t-ID: %s\n' "$pr_number" "$pr_title" >&2
	return "$title_rc"
}

# ---------------------------------------------------------------------------
# CI mode: check-pr <PR_NUMBER>
# Scans every commit in the PR range (merge-base..HEAD).
# ---------------------------------------------------------------------------
_run_check_pr() {
	local pr_number="${1:-}"
	if [[ -z "$pr_number" ]]; then
		printf '[task-id-guard][ERROR] check-pr requires a PR number\n' >&2
		return 1
	fi

	# Prefer GitHub's PR commit list: it is already bounded to the pull request
	# and avoids shallow/default-branch graph edge cases in Actions checkouts.
	# Fall back to local graph walking when gh is unavailable.
	local commits
	if commits=$(_pr_commit_oids "$pr_number") && [[ -n "$commits" ]]; then
		_debug "Using GitHub PR commit list for PR #${pr_number}"
	else
		local default_ref base
		base=$(_find_merge_base)
		if [[ -n "$base" ]]; then
			_debug "Using merge-base for PR scan range: $base"
		elif default_ref=$(_find_default_branch_ref); then
			base="$default_ref"
			_debug "No merge-base found; falling back to default-branch ref: $base"
		else
			_warn "Could not determine PR scan base — fail-open"
			return 0
		fi
		commits=$(git log --no-merges "${base}..HEAD" --format='%H' 2>/dev/null)
	fi
	if [[ -z "$commits" ]]; then
		_info "No commits in PR range — nothing to check"
		return 0
	fi

	# Pre-populate subject caches once. _branch_has_claim and _repo_has_claim
	# called from _check_message would otherwise fork `git log` per (commit,
	# t-ID) pair, which is the actual cost driver behind the timeout. Compute
	# the merge-base for the branch-subjects cache; this is independent of
	# `base` above (which may be origin/main directly) — we want claims that
	# live on the branch since fork-point, not since the current main tip.
	local merge_base
	merge_base=$(_find_merge_base)
	_populate_check_pr_caches "$merge_base"

	local total_violations=0
	local commit_hash
	while IFS= read -r commit_hash; do
		[[ -z "$commit_hash" ]] && continue
		local commit_msg
		commit_msg=$(git log -1 --format='%s%n%n%b' "$commit_hash" 2>/dev/null)
		local subject
		subject=$(git log -1 --format='%s' "$commit_hash" 2>/dev/null)

		_debug "Checking commit $commit_hash: $subject"

		# Skip merge/fixup/squash commits. GitHub PR commit lists can include
		# merge-from-main commits; local fallback excludes merges with --no-merges.
		if printf '%s' "$subject" | grep -qE '^(Merge|fixup!|squash!)'; then
			_debug "Skipping merge/fixup/squash: $commit_hash"
			continue
		fi

		local rc
		_check_message "$commit_msg" "$subject"
		rc=$?
		if [[ "$rc" -eq 1 ]]; then
			printf '[task-id-guard][VIOLATION] commit %s\n' "$commit_hash" >&2
			total_violations=$((total_violations + 1))
		fi
	done <<<"$commits"

	# Also check the PR title for invented t-IDs (GH#19987). See
	# _check_pr_title for the strategy. Extracted to keep _run_check_pr
	# under the 100-line function-complexity gate (t2895).
	local title_rc
	_check_pr_title "$pr_number"
	title_rc=$?
	total_violations=$((total_violations + (title_rc == 1 ? 1 : 0)))

	if [[ "$total_violations" -gt 0 ]]; then
		printf '\n[task-id-guard][SUMMARY] %d violation(s) found in PR #%s\n' "$total_violations" "$pr_number" >&2
		return 1
	fi

	_info "PR #${pr_number}: all commits clean"
	return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
	local mode="${1:-}"
	case "$mode" in
	check-pr)
		shift
		_run_check_pr "$@"
		return $?
		;;
	check-push)
		shift
		_run_check_push "$@"
		return $?
		;;
	help | --help | -h)
		sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
		return 0
		;;
	*)
		# Default: commit-msg hook mode. First arg is the message file path.
		_run_hook "${1:-}"
		return $?
		;;
	esac
}

main "$@"
