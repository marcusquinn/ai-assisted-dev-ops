#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Claim Lifecycle Helpers
# =============================================================================
# Interactive-claim lifecycle helpers shared across merge paths. Extracted from
# pulse-merge.sh (t2429, GH#20067) so that both pulse-merge.sh (deterministic
# merge pass) and full-loop-helper.sh (interactive merge) can release
# interactive claims atomically on PR merge.
#
# Public API:
#   - release_interactive_claim_on_merge <pr_number> <repo_slug> <linked_issue> [pr_labels]
#       Releases the interactive claim stamp, assignee, and status:in-review
#       label for the linked issue if all guards pass. Best-effort; failures
#       are logged but never propagate. pr_labels is retained for compatibility
#       but immutable PR provenance does not determine live claim ownership.
#
# Guards (all must pass for release to fire):
#   1. linked_issue is non-empty after permissive fallback — no issue linked
#      → nothing to release. Callers pass the strict _extract_linked_issue
#      result (closing keywords only); when that is empty, a permissive
#      body scan for Ref/For planning-PR keywords fires before giving up.
#      (t2811)
#   2. A claim stamp exists at the repository-and-issue-scoped path.
#   3. The stamp payload matches that repository and linked issue. A worker PR
#      without a matching live interactive takeover stamp remains untouched.
#
# Release failure is logged but does NOT propagate — release is best-effort
# hygiene and must never block the merge completion path.
#
# Usage: source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"
#
# Dependencies:
#   - shared-constants.sh / shared-gh-wrappers.sh (gh_pr_view, gh_pr_list,
#     gh_issue_view wrappers)
#   - interactive-session-helper.sh (for the actual release)
#   - LOGFILE env var (for logging; falls back to /dev/null)
#   - CLAIM_STAMP_DIR env var (optional; defaults to
#     ~/.aidevops/.agent-workspace/interactive-claims)
#   - AGENTS_DIR env var (optional; defaults to ~/.aidevops/agents)
#
# Cross-references: t2413 (original pulse-merge implementation),
#   t2429/GH#20067 (extraction + full-loop-helper parity),
#   t2811/GH#20757 (permissive Ref/For fallback for planning PRs),
#   AGENTS.md "Interactive issue ownership" → "PR merge auto-release".
# =============================================================================

# Include guard — prevent double-sourcing.
[[ -n "${_SHARED_CLAIM_LIFECYCLE_LOADED:-}" ]] && return 0
_SHARED_CLAIM_LIFECYCLE_LOADED=1

_scl_script_dir="${BASH_SOURCE[0]%/*}"
if ! declare -F aidevops_pulse_worker_log_candidates >/dev/null 2>&1 && [[ -r "${_scl_script_dir}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${_scl_script_dir}/shared-constants.sh"
fi
unset _scl_script_dir

#######################################
# Release the interactive claim for a linked issue after a PR merge.
#
# Called from pulse-merge.sh::_handle_post_merge_actions (deterministic merge)
# and full-loop-helper.sh::cmd_merge (interactive merge) after a successful
# gh pr merge. The function is intentionally best-effort: a failed release is
# logged but never blocks the merge completion path.
#
# Short-circuits (returns 0 silently) when any guard fails:
#   1. linked_issue is empty after permissive fallback — callers pass the
#      strict _extract_linked_issue result (closing keywords only). When that
#      is empty, a permissive body scan for Ref/For planning-PR keywords runs
#      before giving up. This fixes the claim-stamp leak on planning-only PRs
#      that MUST use "Ref #NNN" / "For #NNN" per the planning-PR keyword rule.
#      (t2811/GH#20757; false-positive risk is accepted per issue analysis;
#      Guards 2-3 further constrain scope to a matching claim stamp.)
#   2. No repository-and-issue-scoped claim stamp exists — no active
#      interactive session was tracking it; release is a no-op.
#   3. The stamp payload does not match the repository and linked issue — fail
#      closed instead of releasing another claim.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=pr_labels (optional)
#######################################
release_interactive_claim_on_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_labels="${4:-}"
	local _log="${LOGFILE:-/dev/null}"
	: "$pr_labels"

	# Guard 1: no linked issue from strict caller extraction → try permissive
	# fallback for planning-only PRs that use "Ref #NNN" / "For #NNN".
	# Strict _extract_linked_issue (callers) only matches closing keywords and
	# returns empty for planning PRs. The permissive scan here adds Ref/For so
	# both pulse-merge and full-loop call sites get the fix without duplication.
	# Guards 2-3 still constrain scope to a matching existing stamp.
	# (t2811/GH#20757; precedent: interactive-session-helper.sh:850-858)
	if [[ -z "$linked_issue" ]]; then
		local _pr_body
		_pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json body --jq '.body // empty' 2>/dev/null) || _pr_body=""
		linked_issue=$(printf '%s' "$_pr_body" |
			grep -ioE '\b(close[ds]?|fix(es|ed)?|resolve[ds]?|ref(s|erences?)?|for)\b[[:space:]]+#[0-9]+' |
			head -1 | grep -oE '[0-9]+')
	fi
	[[ -z "$linked_issue" ]] && return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	# Guard 2: immutable PR origin and live ownership are separate. The scoped
	# stamp is the authority for an interactive takeover, including a worker PR.
	local _stamp_base="${CLAIM_STAMP_DIR:-${HOME}/.aidevops/.agent-workspace/interactive-claims}"
	local _stamp_file="${_stamp_base}/${repo_slug//\//-}-${linked_issue}.json"
	[[ -f "$_stamp_file" ]] || return 0

	# Guard 3: the filename is only an index. Verify the durable payload before
	# releasing so malformed or misplaced stamps cannot affect another issue.
	if ! jq -e --arg repo "$repo_slug" --argjson issue "$linked_issue" \
		'.slug == $repo and .issue == $issue' "$_stamp_file" >/dev/null 2>&1; then
		echo "[claim-lifecycle] Claim stamp mismatch for ${repo_slug}#${linked_issue}; skipping release (GH#28690)" >>"$_log"
		return 0
	fi

	echo "[claim-lifecycle] Auto-releasing matching interactive claim on ${repo_slug}#${linked_issue} (PR #${pr_number} merged) — t2413/t2429/GH#28690" >>"$_log"
	local _isc_helper="${AGENTS_DIR:-${HOME}/.aidevops/agents}/scripts/interactive-session-helper.sh"
	if [[ -x "$_isc_helper" ]]; then
		"$_isc_helper" release "$linked_issue" "$repo_slug" --unassign >>"$_log" 2>&1 ||
			echo "[claim-lifecycle] Interactive claim release failed for ${repo_slug}#${linked_issue} — non-fatal (t2413/t2429)" >>"$_log"
	else
		echo "[claim-lifecycle] interactive-session-helper.sh not found/not executable at ${_isc_helper} — skipping release for ${repo_slug}#${linked_issue} (t2413/t2429)" >>"$_log"
	fi
	return 0
}

# Backward-compatible alias: pulse-merge.sh used the underscore-prefixed name.
# Callers may use either form; the underscore-prefixed name is kept so existing
# code (and tests that inline the function) continue to work without changes.
_release_interactive_claim_on_merge() {
	release_interactive_claim_on_merge "$@" || return $?
	return 0
}

#######################################
# Classify the lifecycle state of an exact-head PR or an issue-search fallback.
#
# Determines whether a PR exists for a given head branch and/or linked issue.
# Uses `gh_pr_list --head <branch> --state all` as the PRIMARY signal because
# the GitHub Search index lags real-time PR creation by 5-30 minutes; the
# pulls API (which `--head` queries) hits live state. Falls back to
# `--search <issue_number>` only when branch_name is empty (no head to query)
# OR when the head probe returns zero — search remains useful for cases
# where the worker pushed a different branch than its detected feature branch.
#
# Canonical incident (t3195): a worker opened PR #21885 at 05:47:48Z;
# `_worker_produced_output` ran at 05:52:38Z (5 min later); `gh pr list
# --search 21870` returned 0 because of search-index lag; the worker was
# misclassified as `worker_branch_orphan` and `_attempt_orphan_recovery_pr`
# fired uselessly (PR already existed for the same `--head`). A `--head`
# probe at 05:52:38Z would have returned 1 immediately.
#
# Args:
#   $1 = branch_name   (may be empty)
#   $2 = issue_number  (may be empty)
#   $3 = repo_slug     (e.g. "owner/repo")
#
# Exact-head output states:
#   ready | merged | closed_unmerged | draft_checkpoint |
#   protected_draft | head_mismatch | ready_missing_summary |
#   merged_missing_summary
# Issue-search matches are deliberately `unverified_open_pr`: search can return
# a sibling or stale index hit and therefore proves dedup, never completion.
# Every state is emitted as "state|PR_NUMBER"; absent/unknown have no number.
#######################################
_pr_handoff_state_from_json() {
	local pr_json="$1"
	local expected_head="${2:-}"
	local open_state="OP""EN"
	local merged_state="MER""GED"
	printf '%s' "$pr_json" | jq -r --arg expected_head "$expected_head" \
		--arg open_state "$open_state" --arg merged_state "$merged_state" '
		def label_names: [.labels[]?.name];
		def worker_owned: label_names | any(. == "origin:worker" or . == "origin:worker-takeover");
		def protected: label_names | any(
			. == "origin:interactive" or . == "hold-for-review" or
			. == "no-auto-dispatch" or . == "needs-maintainer-review"
		);
		def rank:
			if .state == $open_state then 0
			elif .state == $merged_state or ((.mergedAt // "") | length) > 0 then 1
			else 2 end;
		sort_by(rank) | .[0]
		| if . == null then ""
		elif ($expected_head | length) > 0 and
			(.state == $open_state or .state == $merged_state or ((.mergedAt // "") | length) > 0) and
			(.headRefOid // "") != $expected_head then "head_mismatch|\(.number)"
		elif .state == $merged_state or ((.mergedAt // "") | length) > 0 then "merged|\(.number)"
		elif .state != $open_state then "closed_unmerged|\(.number)"
		elif (.isDraft // false) and worker_owned and (protected | not) then "draft_checkpoint|\(.number)"
		elif (.isDraft // false) then "protected_draft|\(.number)"
		else "ready|\(.number)" end' 2>/dev/null || true
	return 0
}

_pr_handoff_state_is_completion_candidate() {
	local pr_state="$1"
	[[ "$pr_state" == "ready" || "$pr_state" == "merged" ]]
}

_pr_handoff_has_merge_summary() {
	local repo_slug="$1"
	local pr_number="$2"
	local comments_json=""
	local summary_count=""

	comments_json=$(gh api --paginate --slurp \
		"repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" 2>/dev/null) || return 1
	summary_count=$(printf '%s' "$comments_json" | jq -r \
		'[.[][] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | length' 2>/dev/null) || return 1
	[[ "$summary_count" =~ ^[0-9]+$ && "$summary_count" -gt 0 ]]
}

_pr_handoff_state_for_branch_or_issue() {
	local branch_name="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local match_scope="${4:-branch-or-issue}"
	local expected_head="${5:-}"
	local require_merge_summary="${6:-0}"
	local pr_json=""
	local pr_state=""
	local queried=0
	local probe_failed=0

	if [[ -z "$repo_slug" ]]; then
		printf 'unknown|'
		return 0
	fi

	if [[ -n "$branch_name" ]]; then
		if pr_json=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state all \
			--limit 10 --json number,state,isDraft,mergedAt,headRefOid,labels,statusCheckRollup 2>/dev/null); then
			queried=1
			pr_state=$(_pr_handoff_state_from_json "$pr_json" "$expected_head")
			if [[ -n "$pr_state" ]]; then
				if [[ "$require_merge_summary" -eq 1 ]] && \
					_pr_handoff_state_is_completion_candidate "${pr_state%%|*}"; then
					local pr_number="${pr_state#*|}"
					if ! _pr_handoff_has_merge_summary "$repo_slug" "$pr_number"; then
						printf '%s_missing_summary|%s' "${pr_state%%|*}" "$pr_number"
						return 0
					fi
				fi
				printf '%s' "$pr_state"
				return 0
			fi
		else
			probe_failed=1
		fi
	fi

	if [[ -n "$issue_number" && "$match_scope" != "head-only" ]]; then
		if pr_json=$(gh_pr_list --repo "$repo_slug" --search "#${issue_number} in:body" --state open \
			--limit 10 --json number 2>/dev/null); then
			queried=1
			pr_state=$(printf '%s' "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null || true)
			if [[ -n "$pr_state" ]]; then
				printf 'unverified_open_pr|%s' "$pr_state"
				return 0
			fi
		else
			probe_failed=1
		fi
	fi

	if [[ "$queried" -eq 1 && "$probe_failed" -eq 0 ]]; then
		printf 'absent|'
	else
		printf 'unknown|'
	fi
	return 0
}

#######################################
# Compatibility existence probe for dedup/orphan recovery callers.
# Any lifecycle evidence blocks creation of a competing PR, but only an exact
# ready/merged state may be interpreted as completion by richer callers.
#######################################
_pr_exists_for_branch_or_issue() {
	local branch_name="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local handoff_state=""

	handoff_state=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug")
	case "${handoff_state%%|*}" in
	absent) printf 'absent' ;;
	unknown) printf 'unknown' ;;
	*) printf 'found' ;;
	esac
	return 0
}

#######################################
# _resolve_orphan_recovery_base_branch — PR base for orphan recovery.
#
# Prefers an explicit dispatch PR base, then repository configuration, over
# GitHub's default branch. This covers managed repos whose integration branch
# is `develop` while their default branch remains `main` (GH#80/GH#24800).
#
# Args:
#   $1 = repo_slug (owner/repo)
#   $2 = work_dir   (path to git worktree; optional)
# Outputs: branch name
# Returns: 0 always (falls back to main)
#######################################
_resolve_orphan_recovery_base_branch() {
	local repo_slug="$1"
	local work_dir="${2:-}"
	local base_branch="${WORKER_PR_BASE_BRANCH:-${DISPATCH_REPO_PR_BASE_BRANCH:-${AIDEVOPS_PR_BASE_BRANCH:-}}}"

	if [[ -z "$base_branch" && -n "$work_dir" && -f "${work_dir}/.aidevops.json" ]] && command -v jq >/dev/null 2>&1; then
		base_branch=$(jq -r '.pr_base_branch // .pr_target_branch // .base_branch // .default_branch // empty' "${work_dir}/.aidevops.json" 2>/dev/null || true)
	fi

	local repos_json="${AIDEVOPS_REPOS_JSON:-${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
	if [[ -z "$base_branch" && -n "$repo_slug" && -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		base_branch=$(jq -r --arg slug "$repo_slug" '
			.initialized_repos[]?
			| select(.slug == $slug)
			| .pr_base_branch // .pr_target_branch // .base_branch // .default_branch // empty
		' "$repos_json" 2>/dev/null | sed -n '1p') || base_branch=""
	fi

	if [[ -z "$base_branch" && -n "$repo_slug" ]]; then
		base_branch=$(gh repo view "$repo_slug" \
			--json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
	fi

	printf '%s' "${base_branch:-main}"
	return 0
}

#######################################
# Ensure an orphan-recovery branch is visible on the remote.
#
# Outputs one of: remote, published, pr_found.
# Returns 1 when the branch cannot be safely proven/published.
# Args: $1=work_dir, $2=branch_name, $3=issue_number, $4=repo_slug
#######################################
_ensure_orphan_recovery_branch_remote() {
	local work_dir="$1"
	local branch_name="$2"
	local issue_number="$3"
	local repo_slug="$4"

	if [[ -z "$work_dir" || -z "$branch_name" ]] || ! git -C "$work_dir" rev-parse --git-dir >/dev/null 2>&1; then
		return 1
	fi

	local remote_ref=""
	if ! remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/$branch_name" 2>/dev/null); then
		return 1
	fi
	if [[ -n "$remote_ref" ]]; then
		printf 'remote'
		return 0
	fi

	local local_head_ref="HE""AD"
	local default_branch=""
	if declare -F _hrw_resolve_default_branch >/dev/null 2>&1; then
		default_branch=$(_hrw_resolve_default_branch "$work_dir")
	fi
	[[ -z "$default_branch" ]] && default_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"
	if [[ -z "$issue_number" || "$branch_name" == "$default_branch" || "$branch_name" != *"$issue_number"* ]]; then
		return 1
	fi
	if ! git -C "$work_dir" push origin "${local_head_ref}:refs/heads/${branch_name}" >/dev/null 2>&1; then
		return 1
	fi

	local pr_handoff=""
	pr_handoff=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug")
	if _pr_handoff_state_is_completion_candidate "${pr_handoff%%|*}"; then
		printf 'pr_found'
		return 0
	fi
	if [[ "${pr_handoff%%|*}" != "absent" ]]; then
		return 1
	fi
	printf 'published'
	return 0
}

#######################################
# Build orphan-recovery PR body.
# Args: $1=session_key, $2=branch_name, $3=closing_line, $4=published_local_branch
#######################################
_build_orphan_recovery_pr_body() {
	local session_key="$1"
	local branch_name="$2"
	local closing_line="$3"
	local published_local_branch="${4:-}"

	local pr_summary="Orphan recovery PR — worker pushed this branch but exited before opening a PR."
	local pr_context="Branch \`${branch_name}\` was pushed by headless worker session \`${session_key}\` which released as \`worker_branch_orphan\`. This PR was auto-created by the orphan-recovery path (GH#20819) so the change can land via the normal review and merge pipeline."
	local pr_marker="<!-- aidevops:orphan-recovery worker_branch_orphan session=${session_key} -->"
	if [[ "${published_local_branch:-}" == "1" ]]; then
		pr_summary="Local branch recovery PR — worker committed locally but exited before pushing or opening a PR."
		pr_context="Branch \`${branch_name}\` had local commits from headless worker session \`${session_key}\` and was published by the recovery path before this PR was created (GH#25374)."
		pr_marker="<!-- aidevops:orphan-recovery worker_local_branch_unpushed session=${session_key} -->"
	fi

	printf '%s\n\n%s\n\n%s\n\n%s' \
		"$pr_summary" \
		"$pr_context" \
		"$closing_line" \
		"$pr_marker"
	return 0
}

_create_orphan_recovery_pr() {
	local repo_slug="$1"
	local branch_name="$2"
	local base_branch="$3"
	local pr_title="$4"
	local pr_body="$5"
	local recovery_mode="$6"
	local create_args=(
		--repo "$repo_slug"
		--head "$branch_name"
		--base "$base_branch"
		--title "$pr_title"
		--body "$pr_body"
		--label "origin:worker-takeover"
		--label "status:in-review"
	)
	if [[ "$recovery_mode" == "draft" ]]; then
		create_args+=(--draft)
	fi
	gh pr create "${create_args[@]}" >/dev/null 2>&1 # aidevops-allow: raw-gh-wrapper
	return $?
}

#######################################
# Resolve the authoritative issue number for worker recovery metadata.
#
# The explicit worker contract wins. Session-key fallback is deliberately
# limited to canonical `issue-N` keys because manual/validation session keys
# can end in timestamps that are not GitHub issue numbers.
#
# Args: $1=session key
# Outputs: issue number, or empty when identity is ambiguous
#######################################
_scl_worker_issue_number() {
	local session_key="$1"

	if [[ "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$WORKER_ISSUE_NUMBER"
		return 0
	fi
	if [[ "$session_key" =~ ^issue-([0-9]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 0
}

#######################################
# _attempt_orphan_recovery_pr — auto-recover a worker_branch_orphan (GH#20819)
#
# Called when a worker pushed a branch but exited without opening a PR.
# Attempts to open a non-draft PR against the repo's configured PR base branch
# with origin:worker-takeover + status:in-review labels so the normal
# review/merge pipeline applies immediately.
#
# Short-circuits (returns 1) when:
#   - repo_slug is empty (cannot query or construct PR)
#   - branch_name is empty after the existing-PR probe (cannot construct PR)
#   - linked issue is CLOSED (branch is genuinely orphaned, no PR needed)
#   - a local-only branch cannot be safely pushed for recovery (GH#25374)
#   - gh pr create fails for any reason
#
# Pre-check (t3195/GH#21889): if a PR already exists for the branch or issue
# (`--head`/`--search` probes via _pr_exists_for_branch_or_issue), returns 0
# with no `gh pr create` attempt. This catches search-index-lag and cleaned-
# worktree misclassifications so the recovery helper does not uselessly try to
# create a duplicate PR or release the claim as worker_branch_orphan.
#
# On success: returns 0 (caller records ready recovery as complete, or a draft
# checkpoint as preserved/deferred according to recovery_mode)
# On failure: returns 1 (caller releases as worker_branch_orphan)
#
# Args:
#   $1 = session_key  (e.g. "issue-12345")
#   $2 = work_dir     (path to git worktree; unused after branch_name extracted)
#   $3 = branch_name  (feature branch to set as PR head)
#   $4 = repo_slug    (owner/repo)
#   $5 = recovery_mode (optional; "draft" for dirty-worktree checkpoints)
#
# Non-fatal guard: issues in CLOSED state skip recovery rather than
# creating a PR nobody will review (edge case: worker closed issue as
# "premise falsified" per worker-triage rules — GH#20819 §Context).
#######################################
_attempt_orphan_recovery_pr() {
	local session_key="$1"
	local work_dir="$2"
	local branch_name="$3"
	local repo_slug="$4"
	local recovery_mode="${5:-ready}"

	# Cannot query or build a PR without repo context.
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# Resolve issue identity before branch guards so the existing-PR probe can
	# fall back to issue search when a cleaned worktree leaves branch_name empty.
	# Never interpret arbitrary trailing digits as an issue: manual session keys
	# commonly end in timestamps (GH#28437).
	local issue_number=""
	issue_number=$(_scl_worker_issue_number "$session_key")

	# Pre-check (t3195/GH#21889): if a PR already exists for this branch
	# (or issue), no recovery is needed. Caller releases as worker_complete.
	# Intentionally re-checks rather than trusting the caller's classification:
	# (1) race-condition guard — a PR could be opened in the window between
	#     _worker_produced_output running and this function running; (2) self-
	#     containedness — makes this function correct for any future call path,
	#     not only the current _cmd_run_finish → _handle_worker_branch_orphan
	#     path. Note: after PR #21902 fixed signal-3 to use --head primary, the
	#     original search-index-lag motivation no longer applies; race-condition
	#     defense is now the primary justification for this check.
	local pr_handoff=""
	pr_handoff=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug")
	if _pr_handoff_state_is_completion_candidate "${pr_handoff%%|*}"; then
		return 0
	fi
	if [[ "${pr_handoff%%|*}" != "absent" ]]; then
		return 1
	fi

	# Past this point recovery needs a branch to create a PR. Existing PRs were
	# already handled above, including the empty-branch issue-search fallback.
	if [[ -z "$branch_name" ]]; then
		return 1
	fi

	# Guard: skip recovery for closed issues — worker may have closed it as
	# "premise falsified" (GH#20819 §Context edge case).
	if [[ -n "$issue_number" ]]; then
		local issue_state=""
		issue_state=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json state --jq '.state' 2>/dev/null || true)
		if [[ "$issue_state" == "CLOSED" ]]; then
			return 1
		fi
	fi

	# GH#25374: local-only committed worker branches must be published before
	# `gh pr create --head`; unsafe/failed publish returns 1 for distinct diagnostics.
	local published_local_branch=0
	local recovery_branch_state=""
	recovery_branch_state=$(_ensure_orphan_recovery_branch_remote "$work_dir" "$branch_name" "$issue_number" "$repo_slug") || return 1
	case "$recovery_branch_state" in
		remote) ;;
		published) published_local_branch=1 ;;
		pr_found) return 0 ;;
		*) return 1 ;;
	esac

	local base_branch=""
	base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")

	# Build PR metadata
	local pr_title="auto-recover: orphaned worker branch"
	local closing_line=""
	if [[ -n "$issue_number" ]]; then
		pr_title="auto-recover: orphaned worker branch for #${issue_number}"
		closing_line="Resolves #${issue_number}"
	fi
	if [[ "$recovery_mode" == "draft" ]]; then
		pr_title="checkpoint: recover dirty worker worktree for #${issue_number}"
	fi

	local pr_body
	pr_body=$(_build_orphan_recovery_pr_body "$session_key" "$branch_name" "$closing_line" "$published_local_branch")

	# Attempt PR creation — non-draft so auto-merge and review gates apply.
	# Raw gh pr create (not gh_create_pr wrapper) is intentional: gh_create_pr
	# auto-applies origin:worker which conflicts with origin:worker-takeover
	# (mutually exclusive labels). See GH#20819 for rationale.
	#
	# Args built as an array so the gh-wrapper-guard allowlist marker can stay
	# on the same line as `gh pr create` (its line-by-line scanner requires
	# co-location) without needing a line continuation. Previous form used
	# `gh pr create \ # marker` followed by indented args — but `\<space>#` is
	# NOT a line continuation in bash (`\` escapes the space, `#` starts a
	# comment, the line terminates), so the args were silently dropped and
	# this entire orphan-recovery path never produced a PR. SC2215 caught it.
	_create_orphan_recovery_pr "$repo_slug" "$branch_name" "$base_branch" "$pr_title" "$pr_body" "$recovery_mode"
	return $?
}

#######################################
# _read_worker_log_tail_classified — locate worker log + classify the tail (t2820)
#
# Shared helper extracted from `_post_launch_recovery_claim_released` (Phase 3,
# t2814) so that two consumers can share parsing logic:
#   1. pulse-cleanup.sh — embeds the tail in CLAIM_RELEASED comments.
#   2. worker-lifecycle-common.sh::escalate_issue_tier — uses the classification
#      to reclassify `worker_failed` events as `no_work` when the log shows the
#      worker never produced tool calls (Phase 5 / t2820).
#
# Locates the worker log by enumerating the same per-user candidate paths
# `_post_launch_recovery_claim_released` uses via shared pulse temp helpers.
#
# Reads the last 20 lines (capped at 4KB to match Phase 3's bounds — keeps
# comments readable and limits credential-leak surface). Classifies the tail
# into one of four shapes:
#
#   real_coding          — tail contains tool-use / edit / commit markers
#                          → worker reached implementation; escalate normally
#   no_tool_calls        — tail is non-empty but lacks any tool-use markers
#                          → worker spawned but stalled before implementation
#   canary_post_spawn    — tail contains canary diagnostics or t2814 early-exit
#                          marker → infra failure post-spawn, opus cannot help
#   unknown              — log file missing or empty → no signal available
#
# Side-effects (on success):
#   sets the following variables in the *caller's* scope (no subshell):
#     _WORKER_LOG_TAIL_FILE         path to the log file that was read
#     _WORKER_LOG_TAIL_CONTENT      log tail content (may be empty)
#     _WORKER_LOG_TAIL_CLASS        one of: real_coding|no_tool_calls|
#                                            canary_post_spawn|unknown
#     _WORKER_LOG_TAIL_AGE_SECS     log file age in seconds (now - mtime), or
#                                   empty when no log file exists
#
# Why caller-scope vars: callers need both the raw content (for embedding in
# comments) AND the classification (for branching). Returning a single string
# would force one or the other; setting two named vars is the cheapest way to
# share both without subshell overhead. Tests can `unset` the vars between runs.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo) — used to derive safe_slug for the log path
#
# Returns: 0 always (best-effort; missing log → unknown classification)
#######################################
_read_worker_log_tail_classified() {
	local issue_number="$1"
	local repo_slug="$2"

	# Reset caller-scope vars on every call.
	_WORKER_LOG_TAIL_FILE=""
	_WORKER_LOG_TAIL_CONTENT=""
	_WORKER_LOG_TAIL_CLASS="unknown"
	_WORKER_LOG_TAIL_AGE_SECS=""

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0

	local -a log_candidates=()
	local _candidate=""
	while IFS= read -r _candidate; do
		[[ -n "$_candidate" ]] && log_candidates+=("$_candidate")
	done < <(aidevops_pulse_worker_log_candidates "$repo_slug" "$issue_number" 2>/dev/null || true)

	local log_file=""
	for log_file in "${log_candidates[@]}"; do
		if [[ -f "$log_file" ]] && [[ -s "$log_file" ]]; then
			_WORKER_LOG_TAIL_FILE="$log_file"
			# Bounded read: last 20 lines, capped at 4KB. Same bounds as
			# Phase 3 to keep comments readable + limit credential-leak.
			_WORKER_LOG_TAIL_CONTENT=$(tail -20 "$log_file" 2>/dev/null \
				| head -c 4096 || true)
			# File age = now - mtime. Approximates worker runtime well
			# enough for the reclassification threshold check (the log is
			# created at spawn and written-to throughout execution).
			local now mtime
			now=$(date +%s 2>/dev/null) || now=""
			mtime=$(_file_mtime_epoch "$log_file")
			if [[ -n "$now" && -n "$mtime" && "$mtime" =~ ^[0-9]+$ ]]; then
				_WORKER_LOG_TAIL_AGE_SECS=$((now - mtime))
				# Defensive: clamp negatives to 0 (clock skew / FS race)
				[[ "$_WORKER_LOG_TAIL_AGE_SECS" -lt 0 ]] && _WORKER_LOG_TAIL_AGE_SECS=0
			fi
			break
		fi
	done

	# No log found → unknown (caller should fall through to default behaviour).
	if [[ -z "$_WORKER_LOG_TAIL_FILE" ]]; then
		return 0
	fi

	# Empty content (rare: file existed at -s check but emptied between calls)
	if [[ -z "$_WORKER_LOG_TAIL_CONTENT" ]]; then
		return 0
	fi

	# Classification — order matters: canary signals are most specific, check
	# them first. Tool-call markers next (positive signal of real work). The
	# absence-of-tool-calls case is the catch-all when the log has *something*
	# but no implementation evidence.
	#
	# Markers chosen for stability (not session-format details):
	#   - `[t2814:early_exit]` — explicit marker emitted by Phase 3 Fix 2
	#   - `canary` (case-insensitive) — appears in canary diagnostic output
	#   - `tool_use|tool-use|"tool":` — OpenCode tool-call frames in JSON
	#   - `edit|Edit|Write|Bash` — tool names that imply real implementation
	#   - `git commit|git push` — strongest evidence of implementation
	if printf '%s' "$_WORKER_LOG_TAIL_CONTENT" \
		| grep -qE '\[t2814:early_exit\]|[Cc]anary'; then
		_WORKER_LOG_TAIL_CLASS="canary_post_spawn"
	elif printf '%s' "$_WORKER_LOG_TAIL_CONTENT" \
		| grep -qE 'tool_use|tool-use|"tool":|"name":\s*"(Edit|Write|Bash|Read)"|git\s+(commit|push)'; then
		_WORKER_LOG_TAIL_CLASS="real_coding"
	else
		# Log has content but no implementation markers → worker stalled
		# before reaching tool-call execution.
		_WORKER_LOG_TAIL_CLASS="no_tool_calls"
	fi

	return 0
}
