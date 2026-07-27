#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge -- merge execution, admin fallback, resource unlocking
# =============================================================================
# Sub-library for full-loop-helper.sh orchestrator. Contains merge repo
# resolution, admin-merge fallback signaling, merge execution, resource
# unlocking (PR/issue), stacked PR retargeting, and the cmd_merge command.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     gh_pr_comment, release_interactive_claim_on_merge)
#   - shared-claim-lifecycle.sh (release_interactive_claim_on_merge)
#   - shared-phase-filing.sh (auto_file_next_phase)
#   - full-loop-helper-commit.sh (cmd_pre_merge_gate)
#   - full-loop-helper-evidence.sh (fresh merged-PR evidence)
#   - Globals: SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Sequential phase auto-filing parity with pulse-merge.sh (t2740/GH#22629).
# shellcheck source=./shared-phase-filing.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/shared-phase-filing.sh"

# Targeted remediation for stale GitHub CLI HTTP cache entries that can make
# `gh pr merge` return a cached 401 even after live gh auth succeeds (GH#24656).
# shellcheck source=./gh-merge-cache-remediation-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/gh-merge-cache-remediation-lib.sh"

if [[ -f "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh" ]]; then
	# shellcheck source=./full-loop-cleanup-receipt.sh
	source "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh"
fi

# shellcheck source=./full-loop-helper-evidence.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-evidence.sh"

# Canonical TODO task/issue mapping parser shared with issue-sync and pre-push.
# shellcheck source=./issue-sync-pr-task-resolver.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/issue-sync-pr-task-resolver.sh"

# --- Repo Resolution ---

# _merge_resolve_repo — resolve repo slug from argument or auto-detect from git remote.
# Echoes the resolved repo slug. Returns 1 when detection fails.
_merge_resolve_repo() {
	local repo_arg="${1:-}"
	if [[ -n "$repo_arg" ]]; then
		printf '%s\n' "$repo_arg"
		return 0
	fi
	local detected=""
	detected=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
	if [[ -z "$detected" ]]; then
		print_error "Cannot detect repo. Pass REPO as second argument."
		return 1
	fi
	printf '%s\n' "$detected"
	return 0
}

# --- Admin Merge Fallback Signaling ---

# _signal_admin_merge_fallback — post PR comment, audit log, and label after --admin fallback merge.
#
# t2247: When `_merge_execute` falls back to `--admin` because branch protection
# blocked a plain merge, this function records three signaling artifacts so the
# fallback is visible at PR level (not just in session logs).
#
# Args: pr_number repo merge_method original_error_output
# Returns: 0 always (signaling failures are non-fatal — the merge already succeeded)
_signal_admin_merge_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local original_error="$4"

	# (a) PR comment with error context, ops markers, and remediation
	local _sig_footer=""
	_sig_footer=$(gh-signature-helper.sh footer --model "${AIDEVOPS_MODEL:-unknown}" 2>/dev/null) || _sig_footer=""

	local _admin_comment="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
## Admin Merge Fallback (t2247)

Branch protection blocked the plain \`gh pr merge\` for PR #${pr_number}. The merge succeeded using \`--admin\` fallback (per GH#18538 — workers share the maintainer's \`gh auth\`).

**Merge method:** \`${merge_method}\`

<details>
<summary>Original branch-protection error</summary>

\`\`\`text
${original_error}
\`\`\`

</details>

**Remediation:** If this bypass was unintended, revert with \`gh pr revert ${pr_number} --repo ${repo}\` and investigate why review bots did not approve.
<!-- ops:end -->
${_sig_footer}"

	if gh_pr_comment "$pr_number" --repo "$repo" --body "$_admin_comment" >/dev/null 2>&1; then
		print_info "Admin-merge fallback comment posted on PR #${pr_number}"
	else
		print_warning "Failed to post admin-merge fallback comment on PR #${pr_number}"
	fi

	# (b) Audit log entry
	if command -v audit-log-helper.sh >/dev/null 2>&1; then
		audit-log-helper.sh log merge-admin-fallback \
			"PR #${pr_number} in ${repo} — ${merge_method} — branch protection blocked plain merge" \
			2>/dev/null || true
	fi

	# (c) admin-merge label for cross-PR filtering
	gh pr edit "$pr_number" --repo "$repo" --add-label "admin-merge" 2>/dev/null || true

	return 0
}

# --- Merge Execution ---

# _merge_output_is_graphql_rate_limit — classify GitHub CLI GraphQL quota failures.
#
# Args: merge_output
# Returns: 0 when the failure is specifically a GraphQL rate-limit/transport
# exhaustion class; 1 for policy, checks, conflict, and generic merge errors.
_merge_output_is_graphql_rate_limit() {
	local merge_output="$1"

	printf '%s' "$merge_output" | grep -qiE 'GraphQL:.*API rate limit|GraphQL.*rate limit|rateLimitExceeded'
	return $?
}

_merge_output_is_review_policy_block() {
	local merge_output="$1"

	printf '%s' "$merge_output" | grep -qiE 'At least [0-9]+ approving review|approving review is required|review required|cannot approve your own pull request|can not approve your own pull request|self-approval'
	return $?
}

_merge_is_headless_session() {
	case "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${Claude_HEADLESS:-}${GITHUB_ACTIONS:-}" in
	*true* | *1*) return 0 ;;
	*) return 1 ;;
	esac
}

_merge_pr_ready_for_interactive_admin_bypass() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="${3:-}"

	if [[ -z "$pr_json" ]]; then
		pr_json=$(gh pr view "$pr_number" --repo "$repo" \
			--json isDraft,reviewDecision,statusCheckRollup 2>/dev/null) || return 1
	fi

	printf '%s' "$pr_json" | jq -e '
		def up(v): (v // "" | ascii_upcase);
		def passish: (up(.conclusion) == "SUCCESS" or up(.conclusion) == "NEUTRAL" or up(.conclusion) == "SKIPPED" or up(.state) == "SUCCESS");
		(.isDraft != true)
		and ((.reviewDecision // "") != "CHANGES_REQUESTED")
		and ([.statusCheckRollup[]? | select(passish | not)] | length) == 0
	' >/dev/null
	return $?
}

_merge_try_interactive_admin_auto_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local merge_output="$4"
	local expected_head_sha="$5"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo" ]] || return 1
	! _merge_is_headless_session || return 1
	_merge_output_is_review_policy_block "$merge_output" || return 1
	_merge_pr_ready_for_interactive_admin_bypass "$pr_number" "$repo" || return 1

	#aidevops:trust-boundary -- interactive admin fallback re-checks exact-head
	# authority immediately before bypassing review-count protection.
	_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" "$expected_head_sha" || return 2
	print_info "Auto-merge is blocked only by review-required branch policy/self-approval; interactive maintainer session is using --admin merge after gates passed."
	if gh pr merge "$pr_number" --repo "$repo" "$merge_method" --admin --match-head-commit "$expected_head_sha" 2>&1; then
		print_success "PR #${pr_number} merged with interactive --admin fallback"
		_signal_admin_merge_fallback "$pr_number" "$repo" "$merge_method" "$merge_output"
		return 0
	fi

	print_error "Merge failed for PR #${pr_number} (even with --admin — maintainer gate or admin rights missing)"
	return 2
}

_merge_linked_issue_numbers() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="${3:-}"
	local issue_numbers=""

	if [[ -z "$pr_json" ]]; then
		pr_json=$(gh pr view "$pr_number" --repo "$repo" \
			--json closingIssuesReferences,body 2>/dev/null) || return 1
	fi

	issue_numbers=$(printf '%s' "$pr_json" | jq -r '.closingIssuesReferences[]?.number // empty') || return 1

	if [[ -z "$issue_numbers" ]]; then
		issue_numbers=$(printf '%s' "$pr_json" | jq -r '.body // ""' |
			grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
			grep -oE '[0-9]+' || true)
	fi

	printf '%s\n' "$issue_numbers" | grep -E '^[0-9]+$' | sort -u || true
	return 0
}

# Return every repository-bound issue that GitHub confirms this merged PR
# closed. A truncated, internally inconsistent, or not-yet-closed connection is
# ambiguous and fails closed so callers perform no partial reconciliation.
_merge_confirmed_closing_issue_numbers() {
	local pr_number="$1"
	local repo="$2"
	local owner="${repo%%/*}"
	local name="${repo#*/}"
	local result=""
	[[ "$repo" == */* && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	# shellcheck disable=SC2016
	result=$(gh api graphql -f query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner,name:$name) {
    nameWithOwner
    pullRequest(number:$number) {
      state merged
      closingIssuesReferences(first:100) {
        totalCount pageInfo { hasNextPage }
        nodes { number state repository { nameWithOwner } }
      }
    }
  }
}' -F owner="$owner" -F name="$name" -F number="$pr_number" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -e --arg repo "$repo" '
      .data.repository as $r
      | $r.pullRequest.closingIssuesReferences as $refs
      | $r.nameWithOwner == $repo
        and $r.pullRequest.state == "MERGED" and $r.pullRequest.merged == true
        and (($refs.totalCount | type) == "number" and $refs.totalCount <= 100)
        and $refs.pageInfo.hasNextPage == false
        and (($refs.nodes | length) == $refs.totalCount)
        and all($refs.nodes[]; .repository.nameWithOwner == $repo and .state == "CLOSED")' >/dev/null 2>&1 || return 1
	printf '%s' "$result" | jq -r '.data.repository.pullRequest.closingIssuesReferences.nodes[]?.number' 2>/dev/null || return 1
	return 0
}

_merge_reconcile_closing_issues() {
	local pr_number="$1"
	local repo="$2"
	local max_attempts="${FULL_LOOP_CLOSING_RECONCILE_ATTEMPTS:-4}"
	local retry_delay="${FULL_LOOP_CLOSING_RECONCILE_DELAY_SECONDS:-2}"
	local attempt=1 closing_issues="" closing_issue=""
	[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=4
	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=2

	while [[ "$attempt" -le "$max_attempts" ]]; do
		if closing_issues=$(_merge_confirmed_closing_issue_numbers "$pr_number" "$repo"); then
			while IFS= read -r closing_issue; do
				[[ "$closing_issue" =~ ^[0-9]+$ ]] || continue
				reconcile_dependants_after_verified_closure "$repo" "$closing_issue" || true
			done <<<"$closing_issues"
			print_info "CLOSING_ISSUE_RECONCILIATION=converged pr=${pr_number} attempts=${attempt} references=$(printf '%s\n' "$closing_issues" | grep -cE '^[0-9]+$' || true)"
			return 0
		fi
		print_warning "CLOSING_ISSUE_RECONCILIATION=pending pr=${pr_number} attempt=${attempt}/${max_attempts}"
		[[ "$attempt" -lt "$max_attempts" && "$retry_delay" -gt 0 ]] && sleep "$retry_delay"
		attempt=$((attempt + 1))
	done
	print_warning "CLOSING_ISSUE_RECONCILIATION=deferred pr=${pr_number} attempts=${max_attempts}; periodic pulse reconciliation will recover stale blocked dependants"
	return 1
}

_merge_issue_requires_maintainer_review() {
	local issue_number="$1"
	local repo="$2"
	local labels_csv=""
	local labels_padded=""

	labels_csv=$(gh issue view "$issue_number" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 2
	printf -v labels_padded ',%s,' "$labels_csv"
	if [[ "$labels_padded" == *",needs-maintainer-review,"* ]]; then
		return 0
	fi
	return 1
}

# Resolve the verifier from the current framework tree first so worktree fixes
# are exercised before deployment. The public key remains in the user's
# root-protected aidevops approval-key directory and is read by the helper.
_merge_approval_helper_path() {
	local approval_helper="${SCRIPT_DIR}/approval-helper.sh"
	if [[ ! -f "$approval_helper" ]]; then
		approval_helper="${HOME}/.aidevops/agents/scripts/approval-helper.sh"
	fi
	[[ -f "$approval_helper" ]] || return 1
	printf '%s\n' "$approval_helper"
	return 0
}

_merge_target_crypto_approved() {
	local target_type="$1"
	local target_number="$2"
	local repo="$3"
	local expected_head_sha="${4:-}"
	local approval_helper=""
	local result=""

	approval_helper=$(_merge_approval_helper_path) || return 1
	if [[ "$target_type" == "pr" ]]; then
		[[ -n "$expected_head_sha" ]] || return 1
		result=$(bash "$approval_helper" verify pr "$target_number" "$repo" \
			--expect-head "$expected_head_sha" 2>/dev/null) || result=""
	else
		result=$(bash "$approval_helper" verify issue "$target_number" "$repo" 2>/dev/null) || result=""
	fi
	[[ "$result" == "VERIFIED" ]]
	return $?
}

# Returns 0 for live admin/maintain/write authority, 1 for a confirmed external
# author, and 2 when GitHub cannot provide a trustworthy verdict.
_merge_author_has_write_authority() {
	local author="$1"
	local repo="$2"
	local permission=""

	# shared-constants.sh loads the App-aware helper in normal full-loop use. It
	# distinguishes a confirmed 404 non-collaborator (permission=none) from API
	# uncertainty; the direct gh fallback keeps this library sourceable in tests.
	if declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
		_gh_collaborator_permission_lookup "$repo" "$author" permission || return 2
	else
		permission=$(gh api "repos/${repo}/collaborators/${author}/permission" \
			--jq '.permission // "none"' 2>/dev/null) || return 2
	fi
	case "$permission" in
	admin | maintain | write) return 0 ;;
	none | read | triage) return 1 ;;
	*) return 2 ;;
	esac
}

# Legacy name retained for sourced callers and tests. This is now the common
# final authority guard for every full-loop merge mode, not only --admin.
_merge_guard_admin_merge_maintainer_review() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="${3:-}"
	local pr_json="" pr_author="" current_head_sha="" labels_csv="" labels_padded="" is_fork="false"
	local issue_numbers=""
	local issue_number=""
	local verify_rc=0 author_rc=0 treat_as_external=0

	if ! pr_json=$(gh pr view "$pr_number" --repo "$repo" \
		--json author,labels,isCrossRepository,headRefOid,closingIssuesReferences,body 2>/dev/null); then
		print_error "Merge blocked: unable to verify PR #${pr_number} authority metadata"
		return 1
	fi
	if ! printf '%s' "$pr_json" | jq -e '
		def is_string: type == "string";
		type == "object"
		and (.author.login | is_string and length > 0)
		and (.headRefOid | is_string and length > 0)
		and (.labels | type == "array")
		and (.isCrossRepository | type == "boolean")
		and (.closingIssuesReferences | type == "array")
		and ((.body == null) or (.body | is_string))
	' >/dev/null 2>&1; then
		print_error "Merge blocked: PR #${pr_number} returned malformed authority metadata"
		return 1
	fi

	pr_author=$(printf '%s' "$pr_json" | jq -r '.author.login') || return 1
	current_head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid') || return 1
	labels_csv=$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")') || return 1
	printf -v labels_padded ',%s,' "$labels_csv"
	is_fork=$(printf '%s' "$pr_json" | jq -r '.isCrossRepository') || return 1
	if [[ -n "$expected_head_sha" && "$current_head_sha" != "$expected_head_sha" ]]; then
		print_error "Merge blocked: PR #${pr_number} head changed before the final authority check"
		return 1
	fi

	#aidevops:trust-boundary GH#17671/GH#28622 -- a live PR NMR label is an
	# explicit hold. Marker text is never merge authority at this boundary.
	if [[ "$labels_padded" == *",needs-maintainer-review,"* ]]; then
		print_error "Merge blocked: PR #${pr_number} still requires maintainer review"
		return 1
	fi

	_merge_author_has_write_authority "$pr_author" "$repo" || author_rc=$?
	if [[ "$author_rc" -eq 2 ]]; then
		print_error "Merge blocked: unable to verify live repository permission for PR author ${pr_author}"
		return 1
	fi
	if [[ "$labels_padded" == *",external-contributor,"* ]] || \
		[[ "$is_fork" == "true" ]] || [[ "$author_rc" -ne 0 ]]; then
		treat_as_external=1
	fi

	issue_numbers=$(_merge_linked_issue_numbers "$pr_number" "$repo" "$pr_json") || {
		print_error "Merge blocked: unable to verify linked issues for PR #${pr_number}"
		return 1
	}

	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		verify_rc=0
		_merge_issue_requires_maintainer_review "$issue_number" "$repo" || verify_rc=$?
		if [[ "$verify_rc" -eq 0 ]]; then
			print_error "Merge blocked: linked issue #${issue_number} still requires maintainer review"
			return 1
		elif [[ "$verify_rc" -ne 1 ]]; then
			print_error "Merge blocked: unable to verify maintainer-review labels on issue #${issue_number}"
			return 1
		fi
		if [[ "$treat_as_external" -eq 1 ]] && \
			! _merge_target_crypto_approved issue "$issue_number" "$repo"; then
			print_error "Merge blocked: external/fork PR linked issue #${issue_number} lacks current cryptographic development authority"
			return 1
		fi
	done <<<"$issue_numbers"

	if [[ "$treat_as_external" -eq 0 ]]; then
		return 0
	fi
	if [[ -z "$issue_numbers" ]]; then
		print_error "Merge blocked: external/fork PR #${pr_number} has no linked issue"
		return 1
	fi
	if ! _merge_target_crypto_approved pr "$pr_number" "$repo" "$current_head_sha"; then
		print_error "Merge blocked: external/fork PR #${pr_number} lacks V2 merge authority for the current head"
		return 1
	fi

	return 0
}

_merge_fetch_head_sha_rest() {
	local pr_number="$1"
	local repo="$2"
	local head_sha=""
	head_sha=$(gh api "repos/${repo}/pulls/${pr_number}" --jq '.head.sha // empty' 2>/dev/null || true)
	if [[ -z "$head_sha" ]]; then
		return 1
	fi
	printf '%s\n' "$head_sha"
	return 0
}

# Return the fresh base ref, base SHA, and head SHA that GitHub currently binds
# to the PR. The three fields form the pinned evidence boundary for a local
# prospective merge-tree check.
_merge_fetch_pr_refs_rest() {
	local pr_number="$1"
	local repo="$2"
	local refs=""
	refs=$(gh api "repos/${repo}/pulls/${pr_number}" \
		--jq '[.base.ref // empty, .base.sha // empty, .head.sha // empty] | @tsv' 2>/dev/null) || return 1
	[[ "$refs" == *$'\t'*$'\t'* ]] || return 1
	printf '%s\n' "$refs"
	return 0
}

_merge_fetch_pinned_commit_objects() {
	local pr_number="$1"
	local base_ref="$2"
	local base_sha="$3"
	local head_sha="$4"

	if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
		git fetch --quiet --no-tags origin "refs/heads/${base_ref}" || return 1
	fi
	if ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
		git fetch --quiet --no-tags origin "refs/pull/${pr_number}/head" || return 1
	fi
	git cat-file -e "${base_sha}^{commit}" 2>/dev/null || return 1
	git cat-file -e "${head_sha}^{commit}" 2>/dev/null || return 1
	return 0
}

# Fail closed unless the exact current PR head can be merged prospectively into
# the fresh base without introducing duplicate TODO task IDs or issue mappings.
_merge_guard_prospective_todo() {
	local pr_number="$1"
	local repo="$2"
	local refs=""
	local base_ref=""
	local base_sha=""
	local head_sha=""
	local merge_tree_output=""
	local merge_tree_sha=""
	local temp_dir=""
	local report=""
	local report_rc="0"

	refs=$(_merge_fetch_pr_refs_rest "$pr_number" "$repo") || {
		print_error "Merge blocked: unable to pin fresh PR base/head evidence for prospective TODO validation"
		return 1
	}
	IFS=$'\t' read -r base_ref base_sha head_sha <<<"$refs"
	if [[ -z "$base_ref" || -z "$base_sha" || -z "$head_sha" ]]; then
		print_error "Merge blocked: incomplete PR base/head evidence for prospective TODO validation"
		return 1
	fi
	if [[ -n "${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-}" && "$head_sha" != "$FULL_LOOP_VERIFIED_PR_HEAD_SHA" ]]; then
		print_error "Merge blocked: PR head changed before prospective TODO validation"
		return 1
	fi
	_merge_fetch_pinned_commit_objects "$pr_number" "$base_ref" "$base_sha" "$head_sha" || {
		print_error "Merge blocked: unable to materialize pinned PR commits for prospective TODO validation"
		return 1
	}

	if ! merge_tree_output=$(git merge-tree --write-tree "$base_sha" "$head_sha" 2>&1); then
		print_error "Merge blocked: prospective merge-tree evidence is indeterminate"
		printf '%s\n' "$merge_tree_output" >&2
		return 1
	fi
	merge_tree_sha=$(printf '%s\n' "$merge_tree_output" | sed -n '1p')
	if ! [[ "$merge_tree_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || \
		! git cat-file -e "${merge_tree_sha}^{tree}" 2>/dev/null; then
		print_error "Merge blocked: prospective merge-tree did not produce a verifiable tree"
		return 1
	fi

	# Repositories without TODO.md have no task mapping surface to validate.
	if ! git cat-file -e "${merge_tree_sha}:TODO.md" 2>/dev/null; then
		return 0
	fi
	temp_dir=$(mktemp -d) || {
		print_error "Merge blocked: unable to create prospective TODO validation workspace"
		return 1
	}
	if ! git show "${merge_tree_sha}:TODO.md" >"${temp_dir}/merged"; then
		rm -rf "$temp_dir"
		print_error "Merge blocked: unable to read prospective TODO evidence"
		return 1
	fi
	if git cat-file -e "${base_sha}:TODO.md" 2>/dev/null; then
		if ! git show "${base_sha}:TODO.md" >"${temp_dir}/base"; then
			rm -rf "$temp_dir"
			print_error "Merge blocked: unable to read base TODO evidence"
			return 1
		fi
	else
		: >"${temp_dir}/base"
	fi
	report=$(todo_duplicate_report "${temp_dir}/merged" "${temp_dir}/base") || report_rc=$?
	rm -rf "$temp_dir"
	if [[ "$report_rc" -eq 0 ]]; then
		return 0
	fi
	if [[ "$report_rc" -eq 1 ]]; then
		print_error "Merge blocked: prospective merge introduces duplicate TODO mappings"
		printf '%s\n' "$report" >&2
		return 1
	fi
	print_error "Merge blocked: prospective TODO duplicate evidence is indeterminate"
	return 1
}

# _merge_rest_fallback — squash/merge/rebase a PR via the REST pull merge endpoint.
#
# This is a transport fallback only. It is called after review-bot-gate has
# passed and only when `gh pr merge` failed because its GraphQL path was rate
# limited. The REST endpoint still enforces branch protection and mergeability;
# failures remain failures.
#
# Args: pr_number repo merge_method expected_head_sha
# Returns: 0 = merged, 1 = REST merge failed
_merge_rest_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local expected_head_sha="$4"
	local rest_method="${merge_method#--}"
	local rest_out="" rest_rc=0

	if [[ -z "$expected_head_sha" ]]; then
		print_error "REST merge fallback unavailable: PR head SHA was not verified before merge"
		return 1
	fi

	case "$rest_method" in
	squash | merge | rebase) ;;
	*)
		print_error "Unsupported merge method for REST fallback: ${merge_method}"
		return 1
		;;
	esac

	print_info "GraphQL rate limit blocked gh pr merge; retrying via REST pull merge endpoint with verified head SHA ${expected_head_sha}..."
	if rest_out=$(gh api -X PUT "repos/${repo}/pulls/${pr_number}/merge" \
		-f "sha=${expected_head_sha}" \
		-f "merge_method=${rest_method}" 2>&1); then
		rest_rc=0
	else
		rest_rc=$?
	fi

	printf '%s\n' "$rest_out"
	if [[ $rest_rc -eq 0 ]]; then
		print_success "PR #${pr_number} merged via REST fallback (${rest_method})"
		return 0
	fi

	print_error "REST merge fallback failed for PR #${pr_number}"
	return 1
}

# _merge_execute — attempt `gh pr merge` with optional --admin fallback on branch-protection errors.
#
# GH#18538: branch protection that requires an approving review rejects plain
# `gh pr merge`. Workers share the owner's gh auth, so --admin works when the
# authed user has admin rights. We only fall back to --admin when the caller
# did not explicitly pass --admin or --auto (explicit intent is never overridden).
#
# GH#18731: --admin / --auto are explicit caller intents; when present, the
# error-retry path is skipped entirely.
#
# Bash 3.2 note: `"${arr[@]}"` raises "unbound variable" under set -u when the
# array is empty. The `${arr[@]+"${arr[@]}"}` form expands to zero words safely.
#
# Args: pr_number repo merge_method has_admin has_auto
# Returns: 0 = merged or queued, 1 = failed
_merge_resolve_match_head() {
	local pr_number="$1"
	local repo="$2"
	local pre_merge_head_sha=""
	pre_merge_head_sha=$(_merge_fetch_head_sha_rest "$pr_number" "$repo" || true)
	if [[ -n "${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-}" ]]; then
		if [[ -z "$pre_merge_head_sha" ]]; then
			print_error "Could not retrieve PR #${pr_number} head SHA for verification; refusing merge"
			return 1
		fi
		if [[ "$pre_merge_head_sha" != "$FULL_LOOP_VERIFIED_PR_HEAD_SHA" ]]; then
			print_error "PR #${pr_number} head changed after remote verification; refusing merge"
			return 1
		fi
	fi
	local match_head_sha="${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-$pre_merge_head_sha}"
	[[ -n "$match_head_sha" ]] || return 1
	printf '%s\n' "$match_head_sha"
	return 0
}

_merge_review_state_still_clear() {
	local pr_number="$1"
	local repo="$2"
	local expected_head="$3"
	local review_json=""

	review_json=$(gh pr view "$pr_number" --repo "$repo" \
		--json state,isDraft,reviewDecision,headRefOid 2>/dev/null) || {
		print_error "Could not refresh PR #${pr_number} review state immediately before merge"
		return 1
	}
	#aidevops:trust-boundary — admin and REST merge paths must not bypass a review added after readiness verification.
	if ! printf '%s\n' "$review_json" | jq -e --arg head "$expected_head" '
		.state == "OPEN"
		and .isDraft != true
		and (.headRefOid // "") == $head
		and ((.reviewDecision // "") | ascii_upcase) != "CHANGES_REQUESTED"
	' >/dev/null 2>&1; then
		print_error "PR #${pr_number} review or head state changed after readiness verification; refusing merge"
		return 1
	fi
	return 0
}

_merge_execute() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local has_admin="$4"
	local has_auto="$5"

	# Reconstruct flags array from boolean sentinels (avoids passing arrays across function calls).
	local merge_flags=()
	[[ "$has_admin" -eq 1 ]] && merge_flags+=("--admin")
	[[ "$has_auto" -eq 1 ]] && merge_flags+=("--auto")

	local merge_desc="$merge_method"
	[[ ${#merge_flags[@]} -gt 0 ]] && merge_desc+=" ${merge_flags[*]}"
	print_info "Merging PR #${pr_number} in ${repo} (${merge_desc})..."

	local match_head_sha=""
	match_head_sha=$(_merge_resolve_match_head "$pr_number" "$repo") || {
		print_error "Cannot bind merge to a remotely verified PR head SHA"
		return 1
	}
	_merge_review_state_still_clear "$pr_number" "$repo" "$match_head_sha" || return 1
	#aidevops:trust-boundary GH#17671/GH#28622 -- every merge mode, including
	# --auto and the non-admin REST transport fallback, must pass the same live
	# external/fork and exact-head cryptographic authority check.
	_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" "$match_head_sha" || return 1
	_merge_guard_prospective_todo "$pr_number" "$repo" || return 1
	merge_flags+=("--match-head-commit" "$match_head_sha")

	# Capture output AND exit code under set -e. A bare assignment `out=$(cmd)`
	# triggers errexit before `rc=$?` is reached; the if-form keeps both available.
	# (GH#18538 follow-up to PR #18748 — the bare-assignment form shipped as a bug.)
	local _merge_out="" _merge_rc=0
	if _merge_out=$(gh pr merge "$pr_number" --repo "$repo" "$merge_method" ${merge_flags[@]+"${merge_flags[@]}"} 2>&1); then
		_merge_rc=0
	else
		_merge_rc=$?
	fi
	if [[ $_merge_rc -ne 0 ]] && gh_merge_remediate_stale_auth_cache "$_merge_out" "full-loop PR #${pr_number} in ${repo}" ""; then
		local _merge_retry_out="" _merge_original_out="$_merge_out"
		print_info "gh pr merge returned 401 while live gh auth succeeds; quarantined stale gh cache entries and retrying once..."
		if _merge_retry_out=$(gh pr merge "$pr_number" --repo "$repo" "$merge_method" ${merge_flags[@]+"${merge_flags[@]}"} 2>&1); then
			_merge_out="$_merge_retry_out"
			_merge_rc=0
		else
			_merge_rc=$?
			_merge_out="${_merge_original_out}

[retry after stale gh cache remediation]
${_merge_retry_out}"
		fi
	fi

	if [[ $_merge_rc -ne 0 ]]; then
		printf '%s\n' "$_merge_out"
		# Only use REST fallback for GraphQL quota transport failures after the
		# caller reached the merge execution stage (cmd_merge runs review-bot-gate
		# first). Do not turn --auto into an immediate REST merge.
		if [[ $has_auto -eq 0 ]] && _merge_output_is_graphql_rate_limit "$_merge_out"; then
			_merge_rest_fallback "$pr_number" "$repo" "$merge_method" "$match_head_sha" && return 0
			return 1
		elif [[ $has_admin -eq 0 && $has_auto -eq 1 ]]; then
			local auto_admin_rc=0
			_merge_try_interactive_admin_auto_fallback "$pr_number" "$repo" "$merge_method" "$_merge_out" "$match_head_sha" || auto_admin_rc=$?
			[[ "$auto_admin_rc" -eq 0 ]] && return 0
			[[ "$auto_admin_rc" -eq 2 ]] && return 1
			print_error "Merge failed for PR #${pr_number}"
			return 1
		# Only fall back to --admin when caller passed neither --admin nor --auto.
		elif [[ $has_admin -eq 0 && $has_auto -eq 0 ]] &&
			printf '%s' "$_merge_out" | grep -qE 'base branch policy prohibits|Required status checks? (is|are) expected|At least [0-9]+ approving review'; then
			_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" "$match_head_sha" || return 1
			print_info "Branch protection blocked plain merge; retrying with --admin (workers share the maintainer's gh auth per GH#18538)..."
			if gh pr merge "$pr_number" --repo "$repo" "$merge_method" --admin --match-head-commit "$match_head_sha" 2>&1; then
				print_success "PR #${pr_number} merged with --admin fallback"
				# t2247: Signal that admin-merge fallback was used — three artifacts:
				# (a) PR comment with error context + remediation
				# (b) Audit log entry
				# (c) admin-merge label for cross-PR filtering
				_signal_admin_merge_fallback "$pr_number" "$repo" "$merge_method" "$_merge_out"
				return 0
			else
				print_error "Merge failed for PR #${pr_number} (even with --admin — maintainer gate or admin rights missing)"
				return 1
			fi
		else
			print_error "Merge failed for PR #${pr_number}"
			return 1
		fi
	fi

	printf '%s\n' "$_merge_out"
	if [[ $has_auto -eq 1 ]]; then
		print_success "PR #${pr_number} queued for auto-merge"
	else
		print_success "PR #${pr_number} merged successfully"
	fi
	return 0
}

_merge_verify_completed_state() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""
	pr_json=$(_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo") || return 1

	FULL_LOOP_MERGE_SHA=$(printf '%s' "$pr_json" | jq -r '.mergeCommit.oid')
	export FULL_LOOP_MERGE_SHA
	return 0
}

# --- Resource Unlocking ---

# _merge_unlock_resources — unlock PR and linked issue after worker self-merge.
#
# t1934: Issues/PRs are locked at dispatch time to prevent prompt injection.
# The worker merge path must unlock them — the pulse deterministic merge path
# has its own unlock, but workers that self-merge bypass it.
#
# Args: pr_number repo
_merge_unlock_resources() {
	local pr_number="$1"
	local repo="$2"

	gh pr unlock "$pr_number" --repo "$repo" >/dev/null 2>&1 || true

	# Find and unlock the issue linked via "Resolves/Closes/Fixes #NNN" in the PR body.
	local _linked_issue=""
	_linked_issue=$(gh pr view "$pr_number" --repo "$repo" --json body \
		--jq '.body' 2>/dev/null |
		grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
		grep -oE '[0-9]+' | head -1) || _linked_issue=""
	if [[ -n "$_linked_issue" && "$_linked_issue" =~ ^[0-9]+$ ]]; then
		gh issue unlock "$_linked_issue" --repo "$repo" >/dev/null 2>&1 || true
	fi

	return 0
}

# --- Stacked PR Retargeting ---

# _retarget_stacked_children_interactive — retarget open PRs stacked on the
# head branch of the PR that is about to be merged. GitHub auto-closes stacked
# children when their base branch disappears after the delete-on-merge step.
# This runs before every interactive merge (cmd_merge). The pulse equivalent
# is _retarget_stacked_children in pulse-merge.sh. (t2412 / GH#20005)
#
# Limitation: only direct children are retargeted; grandchildren are handled
# when their own parent merges and fires this function in turn.
#
# Args: pr_number repo
_retarget_stacked_children_interactive() {
	local pr_number="$1"
	local repo="$2"
	local parent_head_ref
	parent_head_ref=$(gh pr view "$pr_number" --repo "$repo" --json headRefName -q '.headRefName' 2>/dev/null) || parent_head_ref=""
	if [[ -z "$parent_head_ref" ]]; then
		return 0
	fi

	local children
	children=$(gh pr list --repo "$repo" --base "$parent_head_ref" --state open --json number -q '.[].number' 2>/dev/null) || children=""
	if [[ -z "$children" ]]; then
		return 0
	fi

	local default_branch
	default_branch=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
	default_branch="${default_branch:-main}"

	local child
	while IFS= read -r child; do
		[[ -z "$child" ]] && continue
		print_info "Retargeting stacked PR #${child} from '${parent_head_ref}' to '${default_branch}' before merging PR #${pr_number} (t2412)"
		gh pr edit "$child" --repo "$repo" --base "$default_branch" 2>&1 || true
	done <<<"$children"
	return 0
}

# --- Post-Merge Worktree Cleanup ---

_merge_github_slug_from_remote() {
	local worktree_root="$1"
	local remote_name="$2"
	local remote_url=""
	local repo_slug=""
	[[ -n "$worktree_root" && -n "$remote_name" ]] || return 1

	remote_url=$(git -C "$worktree_root" remote get-url "$remote_name" 2>/dev/null || true)
	case "$remote_url" in
	git@github.com:*) repo_slug="${remote_url#git@github.com:}" ;;
	ssh://git@github.com/*) repo_slug="${remote_url#ssh://git@github.com/}" ;;
	https://github.com/*) repo_slug="${remote_url#https://github.com/}" ;;
	http://github.com/*) repo_slug="${remote_url#http://github.com/}" ;;
	git://github.com/*) repo_slug="${remote_url#git://github.com/}" ;;
	*) return 1 ;;
	esac
	repo_slug="${repo_slug%%\?*}"
	repo_slug="${repo_slug%%#*}"
	repo_slug="${repo_slug%/}"
	repo_slug="${repo_slug%.git}"
	[[ -n "$repo_slug" && "$repo_slug" == */* && "${repo_slug#*/}" != */* ]] || return 1
	printf '%s\n' "$repo_slug"
	return 0
}

_merge_current_github_repo_identity() {
	local worktree_root="$1"
	local origin_slug=""
	origin_slug=$(_merge_github_slug_from_remote "$worktree_root" "origin" 2>/dev/null || true)
	if [[ -n "$origin_slug" ]]; then
		printf '%s\n' "$origin_slug"
		return 0
	fi

	# Local-only test mirrors and migrated checkouts may use a non-GitHub origin.
	# Accept a fallback only when every parseable GitHub remote identifies the
	# same repository; multiple identities are ambiguous and fail closed.
	local remote_names=""
	remote_names=$(git -C "$worktree_root" remote 2>/dev/null || true)
	local remote_name=""
	local remote_slug=""
	local candidate_slug=""
	while IFS= read -r remote_name; do
		[[ -n "$remote_name" && "$remote_name" != "origin" ]] || continue
		remote_slug=$(_merge_github_slug_from_remote "$worktree_root" "$remote_name" 2>/dev/null || true)
		[[ -n "$remote_slug" ]] || continue
		if [[ -n "$candidate_slug" && "$candidate_slug" != "$remote_slug" ]]; then
			return 1
		fi
		candidate_slug="$remote_slug"
	done <<<"$remote_names"
	[[ -n "$candidate_slug" ]] || return 1
	printf '%s\n' "$candidate_slug"
	return 0
}

_merge_worktree_record_matches() {
	local porcelain="$1"
	local current_root="$2"
	local current_branch="$3"
	local current_head="$4"
	local record_root=""
	local record_branch=""
	local record_head=""
	local line=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ -z "$line" ]]; then
			if [[ "$record_root" == "$current_root" && "$record_branch" == "refs/heads/${current_branch}" && "$record_head" == "$current_head" ]]; then
				return 0
			fi
			record_root=""
			record_branch=""
			record_head=""
			continue
		fi
		case "$line" in
		worktree\ *) record_root="${line#worktree }" ;;
		HEAD\ *) record_head="${line#HEAD }" ;;
		branch\ *) record_branch="${line#branch }" ;;
		esac
	done <<<"$porcelain"

	if [[ "$record_root" == "$current_root" && "$record_branch" == "refs/heads/${current_branch}" && "$record_head" == "$current_head" ]]; then
		return 0
	fi
	return 1
}

_merge_current_worktree_cleanup_plan() {
	local pr_head_ref="$1"
	local pr_head_oid="$2"
	local pr_head_repo="$3"
	local repo="$4"
	[[ -n "$pr_head_ref" && -n "$pr_head_oid" ]] || return 1

	local current_branch=""
	current_branch=$(git branch --show-current 2>/dev/null || true)
	[[ -n "$current_branch" ]] || return 1

	local current_root=""
	current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	[[ -n "$current_root" ]] || return 1
	local current_head=""
	current_head=$(git rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
	[[ -n "$current_head" && "$current_head" == "$pr_head_oid" ]] || return 1

	local porcelain=""
	porcelain=$(git worktree list --porcelain 2>/dev/null || true)
	[[ -n "$porcelain" ]] || return 1
	_merge_worktree_record_matches "$porcelain" "$current_root" "$current_branch" "$current_head" || return 1

	local canonical_dir=""
	canonical_dir="${porcelain%%$'\n'*}"
	canonical_dir="${canonical_dir#worktree }"
	[[ -n "$canonical_dir" && "$canonical_dir" != "$current_root" ]] || return 1

	local delete_remote_branch="1"
	if [[ "$current_branch" != "$pr_head_ref" ]]; then
		# An alias is accepted only when the linked worktree belongs to the exact
		# PR head repository. The fresh head OID, worktree record, and repository
		# identity jointly prove association without branch-name heuristics.
		[[ -n "$repo" && -n "$pr_head_repo" && "$repo" == "$pr_head_repo" ]] || return 1
		local current_repo=""
		current_repo=$(_merge_current_github_repo_identity "$current_root" 2>/dev/null || true)
		[[ -n "$current_repo" && "$current_repo" == "$repo" ]] || return 1

		# The local repair branch is the cleanup target, but its same-named
		# remote ref is not the PR head and must never be deleted implicitly.
		delete_remote_branch="0"
	fi

	printf '%s\t%s\t%s\t%s\n' "$current_root" "$current_branch" "$canonical_dir" "$delete_remote_branch"
	return 0
}

_merge_fresh_worktree_cleanup_plan() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""
	pr_json=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo" \
		--json headRefName,headRefOid,headRepository,isCrossRepository 2>/dev/null) || return 1
	printf '%s' "$pr_json" | jq -e --arg string_type "string" '
		(.headRefName | type == $string_type and length > 0)
		and (.headRefOid | type == $string_type and length > 0)
		and (.headRepository.nameWithOwner | type == $string_type and length > 0)
		and (.isCrossRepository | type == "boolean")' >/dev/null 2>&1 || return 1

	local pr_head_ref=""
	local pr_head_oid=""
	local pr_head_repo=""
	local is_cross_repository=""
	IFS=$'\t' read -r pr_head_ref pr_head_oid pr_head_repo is_cross_repository < <(
		printf '%s' "$pr_json" | jq -r '[.headRefName, .headRefOid, .headRepository.nameWithOwner, .isCrossRepository] | @tsv'
	)
	: "$is_cross_repository"
	_merge_current_worktree_cleanup_plan "$pr_head_ref" "$pr_head_oid" "$pr_head_repo" "$repo" || return 1
	return 0
}

_merge_default_branch_for_cleanup() {
	local canonical_dir="$1"
	local default_ref=""
	default_ref=$(git -C "$canonical_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
	default_ref="${default_ref#refs/remotes/origin/}"
	if [[ -n "$default_ref" && "$default_ref" != refs/* ]]; then
		printf '%s\n' "$default_ref"
		return 0
	fi
	printf '%s\n' "main"
	return 0
}

_merge_refresh_canonical_for_cleanup() {
	local canonical_dir="$1"
	local default_branch="$2"
	[[ -d "$canonical_dir" && -n "$default_branch" ]] || return 1

	if ! git fetch --quiet origin "$default_branch" >/dev/null 2>&1; then
		print_warning "CANONICAL_SYNC_PENDING=true reason=origin_fetch_failed"
		return 1
	fi
	local current_canonical_branch=""
	current_canonical_branch=$(git -C "$canonical_dir" branch --show-current 2>/dev/null || true)
	local canonical_head=""
	canonical_head=$(git -C "$canonical_dir" rev-parse HEAD 2>/dev/null || true)
	local remote_head=""
	remote_head=$(git rev-parse "origin/${default_branch}" 2>/dev/null || true)
	if [[ "$current_canonical_branch" == "$default_branch" && -n "$remote_head" && "$canonical_head" == "$remote_head" ]]; then
		print_success "LIFECYCLE_STATE=CANONICAL_SYNCED sha=${remote_head}"
		return 0
	fi
	print_warning "CANONICAL_SYNC_PENDING=true canonical=${canonical_dir} branch=${current_canonical_branch:-detached}"
	return 1
}

_merge_report_canonical_sync_state() {
	local cleanup_plan="$1"
	if [[ -z "$cleanup_plan" ]]; then
		print_warning "CANONICAL_SYNC_PENDING=true reason=canonical_path_unavailable"
		return 1
	fi
	local worktree_path branch_name canonical_dir delete_remote_branch
	IFS=$'\t' read -r worktree_path branch_name canonical_dir delete_remote_branch <<<"$cleanup_plan"
	: "$worktree_path" "$branch_name" "$delete_remote_branch"
	local default_branch
	default_branch=$(_merge_default_branch_for_cleanup "$canonical_dir")
	_merge_refresh_canonical_for_cleanup "$canonical_dir" "$default_branch"
	return $?
}

_merge_resolve_worktree_helper() {
	if [[ -x "${SCRIPT_DIR}/worktree-helper.sh" ]]; then
		printf '%s\n' "${SCRIPT_DIR}/worktree-helper.sh"
		return 0
	fi
	if [[ -n "${HOME:-}" && -x "${HOME}/.aidevops/agents/scripts/worktree-helper.sh" ]]; then
		printf '%s\n' "${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
		return 0
	fi
	return 1
}

_merge_remove_worktree_for_cleanup() {
	local branch_name="$1"
	local helper_path=""

	helper_path=$(_merge_resolve_worktree_helper 2>/dev/null || true)
	if [[ -n "$helper_path" ]]; then
		WORKTREE_FORCE_REMOVE=1 "$helper_path" remove "$branch_name" --force >/dev/null 2>&1 && return 0
		print_warning "Post-merge worktree cleanup: guarded helper deferred removal for ${branch_name}"
		return 1
	fi

	print_warning "Post-merge worktree cleanup: guarded worktree helper unavailable for ${branch_name}"
	return 1
}
_merge_cleanup_linked_worktree() {
	local cleanup_plan="$1"
	local repo="$2"
	[[ -n "$cleanup_plan" ]] || return 0

	local worktree_path branch_name canonical_dir delete_remote_branch
	IFS=$'\t' read -r worktree_path branch_name canonical_dir delete_remote_branch <<<"$cleanup_plan"
	[[ -n "$worktree_path" && -n "$branch_name" && -n "$canonical_dir" ]] || return 0
	[[ -d "$canonical_dir" ]] || return 0
	print_info "Post-merge worktree cleanup: removing linked worktree ${worktree_path} for ${branch_name} in ${repo}"
	local default_branch=""
	default_branch=$(_merge_default_branch_for_cleanup "$canonical_dir")
	_merge_refresh_canonical_for_cleanup "$canonical_dir" "$default_branch" || true

	if ! cd "$canonical_dir" 2>/dev/null; then
		print_warning "Post-merge worktree cleanup: could not cd to canonical repo ${canonical_dir}"
		return 0
	fi

	if _merge_remove_worktree_for_cleanup "$branch_name"; then
		if [[ "$delete_remote_branch" == "1" ]]; then
			git push origin --delete "$branch_name" >/dev/null 2>&1 || true
		fi
		git branch -D "$branch_name" >/dev/null 2>&1 || true
		print_success "Post-merge worktree cleanup complete for ${branch_name}"
		return 0
	fi

	print_warning "Post-merge worktree cleanup did not remove ${worktree_path}; safety-net cleanup will retry later"
	return 0
}

_merge_record_deferred_cleanup_owner() {
	local pr_number="$1"
	local repo="$2"
	local cleanup_plan="$3"
	local worktree_path="" branch_name="" canonical_dir="" delete_remote_branch=""
	IFS=$'\t' read -r worktree_path branch_name canonical_dir delete_remote_branch <<<"$cleanup_plan"
	: "$canonical_dir" "$delete_remote_branch"
	[[ -n "$worktree_path" && -n "$branch_name" ]] || return 1
	[[ -d "$worktree_path" ]] || return 1

	local owner_pid=""
	if declare -F _resolve_worktree_owner_pid >/dev/null 2>&1; then
		owner_pid=$(_resolve_worktree_owner_pid "" 2>/dev/null || true)
	fi
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || owner_pid="$PPID"
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1

	local marker_dir="${worktree_path}/.agents"
	local marker_path="${marker_dir}/.full-loop-cleanup-deferred"
	mkdir -p "$marker_dir" || return 1
	# Keep the legacy marker during rollout so an older deployed cleanup
	# supervisor still preserves the live owner. The external receipt below is
	# the durable source of lifecycle truth and survives worktree removal.
	printf '%s\n' "$owner_pid" >"${marker_path}.tmp.$$" || return 1
	mv "${marker_path}.tmp.$$" "$marker_path" || return 1
	local owner_session="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-full-loop-merge}}}"
	if ! declare -F full_loop_write_cleanup_deferred >/dev/null 2>&1; then
		return 1
	fi
	full_loop_write_cleanup_deferred "$repo" "$pr_number" "$worktree_path" "$branch_name" \
		"$owner_pid" "$owner_session" "pending" "FINALIZATION_PENDING" >/dev/null || return 1

	if declare -F claim_worktree_ownership >/dev/null 2>&1; then
		claim_worktree_ownership "$worktree_path" "$branch_name" \
			--owner-pid "$owner_pid" \
			--session "${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-full-loop-merge}}" \
			--task "post-merge-cleanup" >/dev/null 2>&1 || true
	fi
	return 0
}

_merge_capture_session_distill_provenance() {
	local pr_number="$1"
	local repo="$2"
	local cleanup_plan="$3"
	local worktree_path branch_name canonical_dir delete_remote_branch
	IFS=$'\t' read -r worktree_path branch_name canonical_dir delete_remote_branch <<<"$cleanup_plan"
	: "$canonical_dir" "$delete_remote_branch"
	local distill_helper="${SCRIPT_DIR}/session-distill-helper.sh"
	[[ -x "$distill_helper" ]] || return 0
	local session_id="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
	[[ -n "$session_id" ]] || return 0
	AIDEVOPS_SESSION_ID="$session_id" \
		"$distill_helper" provenance --pr "$pr_number" --repo "$repo" \
		--worktree "$worktree_path" --branch "$branch_name" >/dev/null 2>&1 || true
	return 0
}

_merge_finalize_post_merge() {
	local pr_number="$1"
	local repo="$2"
	local has_auto="$3"
	local cleanup_plan="$4"
	_merge_capture_session_distill_provenance "$pr_number" "$repo" "$cleanup_plan"
	local linked_issue=""
	linked_issue=$(gh pr view "$pr_number" --repo "$repo" --json body \
		--jq '.body' 2>/dev/null |
		grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#[0-9]+' |
		grep -oE '[0-9]+' | head -1) || linked_issue=""
	if [[ -n "$linked_issue" ]]; then
		release_interactive_claim_on_merge "$pr_number" "$repo" "$linked_issue" || true
	fi
	_merge_reconcile_closing_issues "$pr_number" "$repo" || true
	if declare -F _full_loop_record_merged_pr >/dev/null 2>&1; then
		_full_loop_record_merged_pr "$pr_number" || return 1
	fi
	if [[ "$has_auto" -eq 0 && -n "$linked_issue" ]]; then
		auto_file_next_phase "$linked_issue" "$repo" || true
	fi

	_merge_unlock_resources "$pr_number" "$repo"
	if [[ "$has_auto" -eq 0 && -n "$cleanup_plan" ]]; then
		if _merge_record_deferred_cleanup_owner "$pr_number" "$repo" "$cleanup_plan"; then
			print_info "LIFECYCLE_STATE=CLEANUP_DEFERRED; guarded cleanup ownership persisted outside the worktree"
		else
			print_warning "Post-merge worktree cleanup deferred, but durable handoff evidence could not be recorded"
		fi
	fi
	return 0
}

# --- Merge Command ---

# Merge wrapper (GH#17541) — enforces review-bot-gate then merges.
# Single command that replaces the multi-step protocol (wait + merge).
# Workers call this instead of bare `gh pr merge`.
#
# Usage: full-loop-helper.sh merge <PR_NUMBER> [REPO] [--squash|--merge|--rebase] [--admin] [--auto]
#   --admin  pass --admin to gh pr merge (GH#18731 — owner-only bypass of
#            branch protection for self-authored PRs on personal-account
#            repos; skips the error-retry path since intent is explicit)
#   --auto   pass --auto to gh pr merge (GH#18731 — queues auto-merge to
#            run when required checks pass, rather than merging now)
# Note: --admin and --auto are mutually exclusive at the gh CLI level
# (GH#19310 / t2141). When both are passed, --admin wins (it already implies
# "merge now", so --auto adds no value); --auto is dropped silently with an
# informational message rather than failing the merge.
# Exit codes: 0 = merged (or queued, with --auto), 1 = gate failed or merge failed
cmd_merge() {
	local pr_number="${1:-}"
	local repo=""
	local merge_method="--squash"
	local has_admin=0
	local has_auto=0

	if [[ -z "$pr_number" ]]; then
		print_error "Usage: full-loop-helper.sh merge <PR_NUMBER> [REPO] [--squash|--merge|--rebase] [--admin] [--auto]"
		return 1
	fi
	shift

	# Parse optional repo, merge method, and gh pass-through flags.
	# --admin / --auto (GH#18731) pass straight through to `gh pr merge`.
	for arg in "$@"; do
		case "$arg" in
		--squash | --merge | --rebase)
			merge_method="$arg"
			;;
		--admin)
			has_admin=1
			;;
		--auto)
			has_auto=1
			;;
		*)
			if [[ -z "$repo" ]]; then
				repo="$arg"
			else
				print_error "Unknown argument: $arg"
				return 1
			fi
			;;
		esac
	done

	# GH#19310 (t2141): `gh pr merge` rejects --admin and --auto together with:
	#   "specify only one of `--auto`, `--disable-auto`, or `--admin`"
	# Resolve in favour of --admin: it already implies "merge now via owner
	# override", so --auto (queue and wait) is functionally redundant when
	# --admin is set. Silent resolution (with info message) is friendlier than
	# erroring on an obvious-feeling combination of flags.
	if [[ "$has_admin" -eq 1 && "$has_auto" -eq 1 ]]; then
		print_info "Both --admin and --auto were specified; gh pr merge rejects this combination."
		print_info "Resolving in favour of --admin (overrides branch protection now); dropping --auto."
		has_auto=0
	fi

	repo=$(_merge_resolve_repo "$repo") || return 1

	# Gate: enforce review-bot-gate before merge.
	cmd_pre_merge_gate "$pr_number" "$repo" || {
		print_error "Merge blocked by review bot gate. Address bot findings or wait for reviews."
		return 1
	}
	local _cleanup_plan=""
	if [[ "$has_auto" -eq 0 ]]; then
		_cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "$pr_number" "$repo" 2>/dev/null || true)
	fi
	# Retarget any open PRs stacked on this branch before the head branch is
	# deleted post-merge. GitHub auto-closes stacked children when their base
	# branch disappears; retargeting to the default branch prevents this.
	# (t2412 / GH#20005)
	_retarget_stacked_children_interactive "$pr_number" "$repo"

	_merge_execute "$pr_number" "$repo" "$merge_method" "$has_admin" "$has_auto" || return 1
	if ! _merge_verify_completed_state "$pr_number" "$repo"; then
		if [[ "$has_auto" -eq 1 ]]; then
			print_info "LIFECYCLE_STATE=REMOTE_VERIFIED"
			print_info "AUTO_MERGE_QUEUED=true"
			return 0
		fi
		print_error "Merge command returned success, but GitHub has not reported PR #${pr_number} as MERGED with a merge SHA"
		return 1
	fi
	print_success "LIFECYCLE_STATE=MERGED merge_sha=${FULL_LOOP_MERGE_SHA}"
	_merge_report_canonical_sync_state "$_cleanup_plan" || true
	if declare -F is_loop_active >/dev/null 2>&1 && is_loop_active; then
		_full_loop_record_phase "postflight" "$pr_number" || return 1
	fi
	_merge_finalize_post_merge "$pr_number" "$repo" "$has_auto" "$_cleanup_plan"

	return 0
}
