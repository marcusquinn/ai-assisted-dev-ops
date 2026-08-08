#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# quality-feedback-issues-lib.sh - Issue creation for quality-feedback-helper.sh
#
# Contains functions for creating and managing GitHub quality-debt issues
# from PR review findings, including tagging actioned PRs and backfilling
# priority labels.
#
# Usage: source "${SCRIPT_DIR}/quality-feedback-issues-lib.sh"
#
# Dependencies: shared-constants.sh (gh_create_issue), bash 3.2+, gh, jq
# Do not execute directly — this file is sourced by quality-feedback-helper.sh.

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_QF_ISSUES_LIB_LOADED:-}" ]] && return 0
readonly _QF_ISSUES_LIB_LOADED=1

if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
	_QF_ISSUES_LIB_DIR="${BASH_SOURCE[0]%/*}"
	if [[ -f "${_QF_ISSUES_LIB_DIR}/github-app-auth-helper.sh" ]]; then
		# shellcheck source=./github-app-auth-helper.sh
		source "${_QF_ISSUES_LIB_DIR}/github-app-auth-helper.sh"
	fi
	if [[ -f "${_QF_ISSUES_LIB_DIR}/shared-gh-wrappers-rest-fallback.sh" ]]; then
		# shellcheck source=./shared-gh-wrappers-rest-fallback.sh
		source "${_QF_ISSUES_LIB_DIR}/shared-gh-wrappers-rest-fallback.sh"
	fi
	if [[ -f "${_QF_ISSUES_LIB_DIR}/shared-gh-collaborator-permission.sh" ]]; then
		# shellcheck source=./shared-gh-collaborator-permission.sh
		source "${_QF_ISSUES_LIB_DIR}/shared-gh-collaborator-permission.sh"
	fi
	unset _QF_ISSUES_LIB_DIR
fi

#######################################
# Tag scanned PRs where all review feedback has been actioned (t1413)
#
# For each scanned PR, checks if any quality-debt issues reference it.
# If all such issues are closed (or none were created because the PR
# had no actionable findings), labels the PR as "code-reviews-actioned".
#
# This provides a clear signal of which PRs have been fully reviewed
# and resolved, vs which still have outstanding feedback.
#
# Arguments:
#   $1 - repo slug
#   $2 - state file path
# Returns: 0 on success
#######################################
_tag_actioned_prs() {
	local repo_slug="$1"
	local state_file="$2"

	echo "Tagging actioned PRs for ${repo_slug}..." >&2

	# Ensure label exists
	gh label create "code-reviews-actioned" --repo "$repo_slug" --color "0E8A16" \
		--description "All review feedback has been actioned" --force || true

	# Get all scanned PR numbers
	local scanned_prs
	scanned_prs=$(jq -r '.scanned_prs[]' "$state_file") || return 0

	# Get all OPEN quality-debt issues with their titles (to extract PR numbers)
	local open_debt_titles
	open_debt_titles=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 500 \
		--json title --jq '.[].title' || echo "")

	# Get PRs that already have the label (avoid redundant API calls)
	local already_tagged
	already_tagged=$(gh pr list --repo "$repo_slug" --state merged \
		--label "code-reviews-actioned" --limit 500 \
		--json number --jq '.[].number' || echo "")

	local tagged_count=0
	local batch_count=0

	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue

		# Skip if already tagged
		if printf '%s' "$already_tagged" | grep -qx "$pr_num"; then
			continue
		fi

		# Check if this PR has any OPEN quality-debt issues
		# Quality-debt issue titles contain "PR #NNN" — check for open ones
		local has_open_debt=false
		if [[ -n "$open_debt_titles" ]]; then
			if printf '%s' "$open_debt_titles" | grep -qF "PR #${pr_num}"; then
				has_open_debt=true
			fi
		fi

		if [[ "$has_open_debt" == false ]]; then
			# No open debt for this PR — tag it as actioned
			gh pr edit "$pr_num" --repo "$repo_slug" \
				--add-label "code-reviews-actioned" || true
			tagged_count=$((tagged_count + 1))
		fi

		# Rate limiting: sleep every 50 labels to avoid API abuse
		batch_count=$((batch_count + 1))
		if [[ $((batch_count % 50)) -eq 0 ]]; then
			echo "  Tagged ${tagged_count} PRs so far (${batch_count} checked), sleeping 3s..." >&2
			sleep 3
		fi
	done <<<"$scanned_prs"

	echo "  Tagged ${tagged_count} PRs as code-reviews-actioned" >&2

	# Backfill priority labels on existing open quality-debt issues (t1413)
	# Issues created before the priority label feature won't have them.
	# Parse severity from the title "(critical)", "(high)", "(medium)" and add
	# the corresponding priority:* label if missing.
	_backfill_priority_labels "$repo_slug"

	return 0
}

#######################################
# Backfill priority labels on open quality-debt issues (t1413)
#
# Parses severity from issue titles and adds priority:critical,
# priority:high, or priority:medium labels to issues that don't
# have them yet. Enables the supervisor to sort quality-debt
# issues by severity when deciding dispatch order.
#
# Arguments:
#   $1 - repo slug
# Returns: 0 on success
#######################################
_backfill_priority_labels() {
	local repo_slug="$1"

	# Ensure priority labels exist on the repo
	gh label create "priority:critical" --repo "$repo_slug" --color "B60205" \
		--description "Critical severity — security or data loss risk" --force || true
	gh label create "priority:high" --repo "$repo_slug" --color "D93F0B" \
		--description "High severity — significant quality issue" --force || true
	gh label create "priority:medium" --repo "$repo_slug" --color "FBCA04" \
		--description "Medium severity — moderate quality issue" --force || true

	# Get open quality-debt issues — extract number, title, and whether
	# a priority label already exists, in a single jq pass
	local issues_to_label
	issues_to_label=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 500 \
		--json number,title,labels \
		--jq '.[] | select([.labels[].name // ""] | any(startswith("priority:")) | not) | "\(.number)|\(.title)"' ||
		echo "")

	[[ -z "$issues_to_label" ]] && return 0

	local labelled_count=0

	while IFS='|' read -r issue_num title; do
		[[ -z "$issue_num" ]] && continue

		# Extract severity from title: "(critical)", "(high)", "(medium)"
		local severity=""
		case "$title" in
		*"(critical)"*) severity="critical" ;;
		*"(high)"*) severity="high" ;;
		*"(medium)"*) severity="medium" ;;
		esac

		if [[ -n "$severity" ]]; then
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--add-label "priority:${severity}" || true
			labelled_count=$((labelled_count + 1))
		fi
	done <<<"$issues_to_label"

	[[ "$labelled_count" -gt 0 ]] && echo "  Added priority labels to ${labelled_count} quality-debt issues" >&2
	return 0
}

# _verify_findings_against_main: filter a JSON findings array to only those
# that still exist on the default branch. Annotates each with verification_status.
# Arguments: $1=repo_slug $2=findings_json
# Outputs filtered JSON array to stdout.
_verify_findings_against_main() {
	local repo_slug="$1"
	local findings="$2"
	local verified_findings_stream=""

	while IFS= read -r finding; do
		[[ -z "$finding" ]] && continue

		local file_path=""
		local line_num=""
		local body_full=""
		local verification_json=""
		local verification_result=""
		local verification_status=""
		local finding_fields=""
		local finding_with_status=""

		# Single jq call to extract all three fields (body_full base64-encoded to preserve newlines)
		finding_fields=$(printf '%s' "$finding" | jq -r '"\(.file // "")\t\(.line // "?")\t\(.body_full // .body // "" | @base64)"')
		IFS=$'\t' read -r file_path line_num body_full <<<"$finding_fields"
		body_full=$(printf '%s' "$body_full" | base64 -d)

		verification_json=$(_finding_still_exists_on_main "$repo_slug" "$file_path" "$line_num" "$body_full" || true)

		# Parse fixed-format JSON without jq — format is {"result":bool,"status":"str"}
		verification_result="false"
		verification_status="verified"
		if [[ "$verification_json" == *'"result":true'* ]]; then
			verification_result="true"
		fi
		if [[ "$verification_json" == *'"status":"unverifiable"'* ]]; then
			verification_status="unverifiable"
		elif [[ "$verification_json" == *'"status":"resolved"'* ]]; then
			verification_status="resolved"
		fi

		if [[ "$verification_result" == "true" ]]; then
			finding_with_status=$(printf '%s' "$finding" | jq --arg status "$verification_status" '. + {verification_status: $status}')
			verified_findings_stream+="${finding_with_status}"$'\n'
		fi
	done < <(printf '%s' "$findings" | jq -c '.[]')

	if [[ -n "$verified_findings_stream" ]]; then
		printf '%s' "$verified_findings_stream" | jq -s '.'
	else
		echo "[]"
	fi
	return 0
}

# _ensure_quality_debt_labels: create quality-debt labels on the repo if missing.
# Arguments: $1=repo_slug
_ensure_quality_debt_labels() {
	local repo_slug="$1"
	gh label create "quality-debt" --repo "$repo_slug" --color "D93F0B" \
		--description "Unactioned review feedback from merged PRs" --force || true
	gh label create "source:review-feedback" --repo "$repo_slug" --color "C2E0C6" \
		--description "Auto-created by quality-feedback-helper.sh" --force || true
	gh label create "priority:critical" --repo "$repo_slug" --color "B60205" \
		--description "Critical severity — security or data loss risk" --force || true
	gh label create "priority:high" --repo "$repo_slug" --color "D93F0B" \
		--description "High severity — significant quality issue" --force || true
	gh label create "priority:medium" --repo "$repo_slug" --color "FBCA04" \
		--description "Medium severity — moderate quality issue" --force || true
	gh label create "security" --repo "$repo_slug" --color "D73A4A" \
		--description "Security-sensitive issue or change" --force || true
	return 0
}

# _quality_debt_security_related: classify security-sensitive quality-debt text.
# Arguments: $1=text to classify
# Returns: 0 when security-related, 1 otherwise
_quality_debt_security_related() {
	local text="$1"

	if printf '%s' "$text" | LC_ALL=C grep -Eiq \
		'\b(auth|authentication|authorization|authorisation|credential|credentials|secret|secrets|token|api[ -]?key|private[ -]?key|ssh[ -]?key|webhook|prompt[ -]?injection|supply[ -]?chain|untrusted external content|auto[ -]?approval|approval gate|merge gate|permission|permissions|privilege|privileged|cryptographic|signature|signing|security)\b'; then
		return 0
	fi

	return 1
}

# _build_quality_debt_issue_body: compose the body text for a new quality-debt issue.
# Includes provenance header, finding details, optional approval gate text, and sig footer.
# Arguments: $1=pr_num $2=file $3=reviewers $4=file_finding_count
#            $5=max_severity $6=finding_details $7=is_maintainer_pr
# Outputs composed issue body to stdout.
_build_quality_debt_issue_body() {
	local pr_num="$1"
	local file="$2"
	local reviewers="$3"
	local file_finding_count="$4"
	local max_severity="$5"
	local finding_details="$6"
	local is_maintainer_pr="${7:-false}"

	local issue_body
	issue_body="## Unactioned Review Feedback

<!-- provenance:start — workers: skip to implementation below -->
**Source PR**: #${pr_num}
**File**: \`${file}\`
**Reviewers**: ${reviewers}
**Findings**: ${file_finding_count}
**Max severity**: ${max_severity}
<!-- provenance:end -->

---

${finding_details}

---
<!-- provenance:start -->
_Auto-generated by \`quality-feedback-helper.sh scan-merged\`. Review each finding and either fix the code or dismiss with a reason._
<!-- provenance:end -->"

	# GH#17916: Maintainer-authored PRs skip the approval gate — the maintainer
	# implicitly approves quality-debt by merging their own PR. External PRs
	# keep the approval block so the maintainer can review before dispatch.
	if [[ "$is_maintainer_pr" != "true" ]]; then
		issue_body="${issue_body}

---
**To approve or decline**, use one of:
- \`sudo aidevops approve issue <number> ${repo_slug}\` -- cryptographically signs approval for automated dispatch
- Comment \`declined: <reason>\` -- closes this issue (include your reason after the colon)"
	fi

	# Append signature footer with model/session context from env vars
	# (AIDEVOPS_SIG_MODEL, AIDEVOPS_SIG_CLI, etc. set by calling LLM session).
	# Pass --session-type routine since scan-merged is a bash routine (GH#17523).
	local qf_sig=""
	local sig_args=(footer --body "$issue_body" --session-type routine)
	# Pass model from env if available (set by the LLM session calling us)
	if [[ -n "${AIDEVOPS_SIG_MODEL:-}" ]]; then
		sig_args+=(--model "$AIDEVOPS_SIG_MODEL")
	fi
	qf_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" "${sig_args[@]}" 2>/dev/null || true)

	printf '%s' "${issue_body}${qf_sig}"
	return 0
}

# _build_quality_debt_labels: compute the label args string for a new quality-debt issue.
# Arguments: $1=max_severity $2=is_maintainer_pr $3=finding_details
# Outputs comma-separated label string to stdout.
_build_quality_debt_labels() {
	local max_severity="$1"
	local is_maintainer_pr="${2:-false}"
	local finding_details="${3:-}"

	# Map severity to priority label for dispatch ordering (t1413)
	local priority_label=""
	case "$max_severity" in
	critical) priority_label="priority:critical" ;;
	high) priority_label="priority:high" ;;
	medium) priority_label="priority:medium" ;;
	*) priority_label="" ;;
	esac
	if _quality_debt_security_related "$finding_details"; then
		if [[ "$priority_label" != "priority:critical" ]]; then
			priority_label="priority:high"
		fi
	fi

	# Create the issue with severity-based priority label and source provenance.
	# Keep the issue unassigned and explicitly dispatchable. The worker claim
	# adds the real assignee at launch time; pre-assigning the repo owner here
	# collapses backlog ownership and execution claim into the same field,
	# which makes the pulse skip fresh quality-debt work.
	local label_args="quality-debt,source:review-feedback,auto-dispatch,status:available,origin:worker,tier:standard"
	[[ -n "$priority_label" ]] && label_args="${label_args},${priority_label}"
	if _quality_debt_security_related "$finding_details"; then
		label_args="${label_args},security"
	fi

	# GH#17916: External PRs get needs-maintainer-review so the dispatch gate
	# actually blocks until the maintainer approves. Preserve the external-origin
	# provenance because the generated issue itself is authored by trusted
	# automation. Maintainer PRs skip this gate.
	if [[ "$is_maintainer_pr" != "true" ]]; then
		label_args="${label_args},external-contributor,needs-maintainer-review"
	fi

	printf '%s' "$label_args"
	return 0
}

# _post_approval_instructions_comment: post approval instructions as an audit-trail
# comment on a newly created quality-debt issue (GH#17523).
# Arguments: $1=repo_slug $2=issue_num $3=pr_num
# Returns: 0 always (failure is tolerated — comment is audit trail only)
_post_approval_instructions_comment() {
	local repo_slug="$1"
	local issue_num="$2"
	local pr_num="$3"

	gh_issue_comment "$issue_num" --repo "$repo_slug" \
		--body "<!-- provenance:start — workers: skip this comment, it is for the maintainer not the implementer -->
This quality-debt issue was auto-generated by \`quality-feedback-helper.sh scan-merged\` from review feedback on PR #${pr_num}.

**To approve for automated dispatch:**
\`\`\`
sudo aidevops approve issue ${issue_num} ${repo_slug}
\`\`\`

**To decline:** comment \`declined: <reason>\` to close this issue.

Approval requires cryptographic signing via the maintainer's root-protected key. Without approval, this issue will not enter the dispatch pipeline.

<details>
<summary>First-time setup</summary>

If you haven't set up approval signing yet, run the one-time key generation first:
\`\`\`
sudo aidevops approve setup
\`\`\`
This creates a root-protected ED25519 signing key. Check status anytime with \`aidevops approve status\`.
</details>
<!-- provenance:end -->" >/dev/null 2>&1 || true
	return 0
}

# _create_new_quality_debt_issue: create a new GitHub issue for a file's findings.
# Arguments: $1=repo_slug $2=pr_num $3=file $4=issue_title $5=max_severity
#            $6=reviewers $7=file_finding_count $8=finding_details
#            $9=is_maintainer_pr ("true" = skip approval gate, dispatches immediately)
# Outputs "1" if created, "0" otherwise.
_create_new_quality_debt_issue() {
	local repo_slug="$1"
	local pr_num="$2"
	local file="$3"
	local issue_title="$4"
	local max_severity="$5"
	local reviewers="$6"
	local file_finding_count="$7"
	local finding_details="$8"
	local is_maintainer_pr="${9:-false}"

	local issue_body
	issue_body=$(_build_quality_debt_issue_body \
		"$pr_num" "$file" "$reviewers" "$file_finding_count" \
		"$max_severity" "$finding_details" "$is_maintainer_pr")

	local label_args
	label_args=$(_build_quality_debt_labels "$max_severity" "$is_maintainer_pr" "$finding_details")

	local new_issue
	new_issue=$(gh_create_issue --repo "$repo_slug" \
		--title "$issue_title" \
		--body "$issue_body" \
		--label "$label_args" | grep -oE '[0-9]+$' || echo "")

	if [[ -n "$new_issue" ]]; then
		# GH#17916: Only post approval instructions for external PRs.
		# Maintainer PRs are immediately dispatchable — no approval needed.
		if [[ "$is_maintainer_pr" != "true" ]]; then
			_post_approval_instructions_comment "$repo_slug" "$new_issue" "$pr_num"
		fi
		echo "  Created issue #${new_issue}: ${issue_title}" >&2
		echo "1"
		return 0
	fi
	echo "0"
	return 0
}

# _append_findings_to_issue: append findings as a comment on an existing issue.
# Arguments: $1=repo_slug $2=issue_num $3=pr_num $4=file $5=reviewers
#            $6=file_finding_count $7=max_severity $8=finding_details
_append_findings_to_issue() {
	local repo_slug="$1"
	local issue_num="$2"
	local pr_num="$3"
	local file="$4"
	local reviewers="$5"
	local file_finding_count="$6"
	local max_severity="$7"
	local finding_details="$8"

	local comment_body="## Additional Review Feedback (PR #${pr_num})

<!-- provenance:start — workers: skip to implementation below -->
**Reviewers**: ${reviewers}
**Findings**: ${file_finding_count}
**Max severity**: ${max_severity}
<!-- provenance:end -->

---

${finding_details}

---
<!-- provenance:start -->
_Appended by \`quality-feedback-helper.sh scan-merged\` (cross-PR file dedup, t1411)._
<!-- provenance:end -->"

	# Append signature footer with session-type and model context (GH#17523)
	local append_sig=""
	local append_sig_args=(footer --body "$comment_body" --session-type routine)
	if [[ -n "${AIDEVOPS_SIG_MODEL:-}" ]]; then
		append_sig_args+=(--model "$AIDEVOPS_SIG_MODEL")
	fi
	append_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" "${append_sig_args[@]}" 2>/dev/null || true)
	comment_body="${comment_body}${append_sig}"

	gh_issue_comment "$issue_num" --repo "$repo_slug" \
		--body "$comment_body" >/dev/null || true
	if _quality_debt_security_related "$finding_details"; then
		gh issue edit "$issue_num" --repo "$repo_slug" \
			--add-label "security" --add-label "priority:high" >/dev/null 2>&1 || true
	fi
	echo "  Appended to existing #${issue_num} for ${file} (PR #${pr_num})" >&2
	return 0
}

# _create_or_append_file_issue: for a single file's findings, either create a
# new quality-debt issue or append to an existing one (cross-PR dedup, t1411).
# Arguments: $1=repo_slug $2=pr_num $3=file $4=file_findings_json
#            $5=existing_issues_json $6=existing_open_issues_json
#            $7=is_maintainer_pr ("true" = maintainer authored the source PR)
# Outputs "1" if a new issue was created, "0" otherwise.
_create_or_append_file_issue() {
	local repo_slug="$1"
	local pr_num="$2"
	local file="$3"
	local file_findings="$4"
	local existing_issues_json="$5"
	local existing_open_issues_json="$6"
	local is_maintainer_pr="${7:-false}"

	local file_finding_count
	file_finding_count=$(echo "$file_findings" | jq 'length')
	[[ "$file_finding_count" -eq 0 ]] && echo "0" && return 0

	# Get highest severity for this file
	local max_severity
	max_severity=$(echo "$file_findings" | jq -r '
		[.[].severity] |
		if any(. == "critical") then "critical"
		elif any(. == "high") then "high"
		elif any(. == "medium") then "medium"
		else "low"
		end
	')

	# Build issue title
	local issue_title
	if [[ "$file" == "general" ]]; then
		issue_title="quality-debt: PR #${pr_num} review feedback (${max_severity})"
	else
		issue_title="quality-debt: ${file} — PR #${pr_num} review feedback (${max_severity})"
	fi

	# Build finding details (shared between new issue and comment append)
	local reviewers
	reviewers=$(echo "$file_findings" | jq -r '[.[].reviewer] | unique | join(", ")')

	local finding_details
	finding_details=$(echo "$file_findings" | jq -r '.[] |
		"### \(.severity | ascii_upcase): \(.reviewer) (\(.reviewer_login))\n" +
		(if .file != null and .line != null then "**File**: `\(.file):\(.line)`\n" else "" end) +
		(if .verification_status == "unverifiable" then "**Verification**: kept as unverifiable (no stable snippet extracted)\n" else "" end) +
		"\(.body_full)\n\n" +
		(if .url != null then "<!-- provenance:start -->\n[View comment](\(.url))\n<!-- provenance:end -->\n" else "" end) +
		"---\n"
	')

	# Skip if exact duplicate (same PR + file combination), including closed history.
	# This prevents re-creating previously resolved issues when backfill/scan state resets.
	local exact_title_match
	local exact_title_state
	exact_title_match=$(echo "$existing_issues_json" | jq -r --arg t "$issue_title" \
		'[.[] | select(.title == $t)][0].number // empty' 2>/dev/null || echo "")
	exact_title_state=$(echo "$existing_issues_json" | jq -r --arg t "$issue_title" \
		'[.[] | select(.title == $t)][0].state // empty' 2>/dev/null || echo "")
	if [[ -n "$exact_title_match" ]]; then
		if [[ "$exact_title_state" == "CLOSED" ]]; then
			echo "  Skipping previously closed quality-debt issue #${exact_title_match}: ${issue_title}" >&2
		else
			echo "  Skipping duplicate: ${issue_title}" >&2
		fi
		echo "0"
		return 0
	fi

	# Cross-PR file dedup (t1411): check if there's an existing open
	# quality-debt issue for the same FILE from a different PR. If so,
	# append findings as a comment instead of creating a new issue.
	local existing_file_issue_json=""
	local existing_file_issue=""
	local existing_file_issue_pr=""
	if [[ "$file" != "general" ]]; then
		existing_file_issue_json=$(echo "$existing_open_issues_json" | jq -c --arg f "$file" \
			'[.[] | select((.title // "") | startswith("quality-debt: \($f) —"))] | .[0] // {}' ||
			echo '{}')
		existing_file_issue=$(echo "$existing_file_issue_json" | jq -r '.number // empty')
		existing_file_issue_pr=$(echo "$existing_file_issue_json" | jq -r \
			'(.title // "") | try capture("— PR #(?<number>[0-9]+) review feedback").number catch ""')
	fi

	if [[ -n "$existing_file_issue" ]]; then
		# PR numbers are monotonically increasing within a repository. Never append
		# older review feedback to debt opened from a newer PR: the newer change may
		# already supersede the older finding (GH#27703).
		if [[ "$pr_num" =~ ^[0-9]+$ && "$existing_file_issue_pr" =~ ^[0-9]+$ &&
			"$pr_num" -lt "$existing_file_issue_pr" ]]; then
			echo "  Skipping superseded PR #${pr_num} feedback; #${existing_file_issue} already tracks newer PR #${existing_file_issue_pr} for ${file}" >&2
			echo "0"
			return 0
		fi
		_append_findings_to_issue "$repo_slug" "$existing_file_issue" "$pr_num" "$file" \
			"$reviewers" "$file_finding_count" "$max_severity" "$finding_details"
		echo "0"
		return 0
	fi

	# No existing issue for this file — delegate to creation helper
	_create_new_quality_debt_issue \
		"$repo_slug" "$pr_num" "$file" "$issue_title" "$max_severity" \
		"$reviewers" "$file_finding_count" "$finding_details" "$is_maintainer_pr"
	return $?
}

# _quality_findings_are_trusted_automation: GH#29795
#
# Quality-debt issues are maintainer-controlled scanner output. Findings from
# explicitly trusted code-quality apps are therefore authorized for worker
# triage regardless of who authored the merged source PR. This keeps source
# provenance separate from task authority: an external or dependency-bot PR
# does not turn a trusted audit finding into an external contribution.
#
# Every reviewer identity must match the exact allowlist. Missing configuration,
# malformed findings, mixed human/bot findings, and lookalike bot names fail
# closed so the existing source-author trust check remains the fallback.
#
# Args:
#   $1 - findings JSON array
#
# Returns:
#   0 if every finding came from trusted quality automation
#   1 otherwise
_quality_findings_are_trusted_automation() {
	local findings="$1"
	local trust_file="${AIDEVOPS_TRUSTED_CODE_QUALITY_BOTS_FILE:-${BASH_SOURCE[0]%/*}/../configs/trusted-code-quality-bots.txt}"
	local reviewer_logins=""
	local reviewer_login=""

	[[ -f "$trust_file" ]] || return 1
	reviewer_logins=$(printf '%s' "$findings" | jq -r \
		'[.[].reviewer_login // ""] | unique | .[]' 2>/dev/null) || return 1
	[[ -n "$reviewer_logins" ]] || return 1

	while IFS= read -r reviewer_login; do
		[[ -n "$reviewer_login" ]] || return 1
		grep -Fqx -- "$reviewer_login" "$trust_file" || return 1
	done <<<"$reviewer_logins"

	return 0
}

# _is_maintainer_equivalent_author: GH#17916 (t2686)
#
# Determines whether a PR author should be treated as maintainer-equivalent
# for the purpose of skipping the NMR approval gate on quality-debt issues.
# Extracted from _create_quality_debt_issues for unit-testability (t2686).
#
# Trust bar matches pulse-merge.sh auto-merge (t2411 criterion 2,
# t2449 criterion 2): repo maintainer OR a collaborator with admin/maintain
# permission. The maintainer implicitly approves merged content; co-admins
# have the same institutional trust and merging it is itself an approval act.
# External/contributor PRs do NOT qualify and keep the gate.
#
# Two-stage check:
#   1. Fast path: repos.json .maintainer string match or slug-owner fallback.
#      Avoids a gh api call on solo-maintainer repos (the common case).
#   2. Collaborator-permission probe:
#      gh api repos/{slug}/collaborators/{user}/permission.
#      Accepts permission ∈ {admin, maintain, write}. Fail-closed on API errors
#      (404, 403, network failure) — an unreachable API is not a trust
#      signal; default to NOT maintainer-equivalent so NMR still applies.
#
# Args:
#   $1 - pr_author : GitHub login of the PR author (may be empty)
#   $2 - repo_slug : owner/repo (e.g. exampleorg/examplerepo)
#
# Returns:
#   0 if author is maintainer-equivalent (skip NMR gate)
#   1 otherwise (apply NMR gate)
#
# Environment:
#   REPOS_JSON — path to repos.json (defaults to ~/.config/aidevops/repos.json)
_is_maintainer_equivalent_author() {
	local pr_author="$1"
	local repo_slug="$2"

	if [[ -z "$pr_author" || -z "$repo_slug" ]]; then
		return 1
	fi

	# Stage 1: maintainer fast-path.
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local maintainer=""
	if [[ -f "$repos_json" ]]; then
		maintainer=$(jq -r --arg slug "$repo_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
			"$repos_json" 2>/dev/null || echo "")
	fi
	# Fallback: slug owner (first part before /)
	[[ -z "$maintainer" ]] && maintainer="${repo_slug%%/*}"
	if [[ "$pr_author" == "$maintainer" ]]; then
		return 0
	fi

	# Stage 2: collaborator permission probe. NMR is an external-authority gate,
	# so every authenticated write-level collaborator is trusted here.
	# #aidevops:trust-boundary — maintainer-equivalent classification requires
	# confirmed admin/maintain; lookup failures fail closed separately from none.
	local collab_permission=""
	_gh_collaborator_permission_lookup "$repo_slug" "$pr_author" collab_permission || {
		echo "[quality-feedback] permission check failed for author ${pr_author} on ${repo_slug} (HTTP ${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-unknown}) — not treating as maintainer-equivalent" >&2
		return 1
	}
	if [[ "$collab_permission" == "admin" || "$collab_permission" == "maintain" || "$collab_permission" == "write" ]]; then
		echo "[quality-feedback] author ${pr_author} has ${collab_permission} permission on ${repo_slug} — treating as maintainer-equivalent (t2686)" >&2
		return 0
	fi

	return 1
}

# _quality_feedback_dispatch_authorized: resolve generated-task authority.
# Arguments: $1=findings JSON $2=repo slug $3=source PR number
# Returns: 0 when trusted audit identity or source-author authority is verified.
_quality_feedback_dispatch_authorized() {
	local findings="$1"
	local repo_slug="$2"
	local pr_num="$3"
	local pr_author=""

	if _quality_findings_are_trusted_automation "$findings"; then
		echo "[quality-feedback] trusted quality-app findings on PR #${pr_num} — authorizing worker triage" >&2
		return 0
	fi

	pr_author=$(gh pr view "$pr_num" --repo "$repo_slug" --json author --jq '.author.login' 2>/dev/null || echo "")
	_is_maintainer_equivalent_author "$pr_author" "$repo_slug"
	return $?
}

_create_quality_debt_issues() {
	local repo_slug="$1"
	local pr_num="$2"
	local findings="$3"

	# Verify findings still exist on main branch
	findings=$(_verify_findings_against_main "$repo_slug" "$findings")

	local finding_count
	finding_count=$(printf '%s' "$findings" | jq 'length' || echo "0")

	if [[ "$finding_count" -eq 0 ]]; then
		echo "0"
		return 0
	fi

	# GH#29795: The scanner's trusted quality-app identity authorizes worker
	# triage independently of the merged source PR author. For findings from
	# humans or unknown automation, retain the source-author trust fallback and
	# fail closed to the external approval gate.
	local is_maintainer_pr="false"
	if _quality_feedback_dispatch_authorized "$findings" "$repo_slug" "$pr_num"; then
		is_maintainer_pr="true"
	fi

	# Ensure labels exist (quality-debt + source + priority labels for dispatch ordering, t1413)
	_ensure_quality_debt_labels "$repo_slug"

	# Check existing quality-debt issues to avoid duplicates.
	# Fetch title/number/state so we can dedupe against both open and closed history.
	local existing_issues_json
	existing_issues_json=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state all --limit 1000 \
		--json title,number,state || echo "[]")

	local existing_open_issues_json
	existing_open_issues_json=$(echo "$existing_issues_json" | jq '[.[] | select(.state == "OPEN")]' 2>/dev/null || echo "[]")

	# Group findings by file (null files grouped as "general")
	local files
	files=$(echo "$findings" | jq -r '[.[].file // "general"] | unique | .[]')

	local created=0

	while IFS= read -r file; do
		[[ -z "$file" ]] && continue

		# Get findings for this file
		local file_findings
		if [[ "$file" == "general" ]]; then
			file_findings=$(echo "$findings" | jq '[.[] | select(.file == null)]')
		else
			file_findings=$(echo "$findings" | jq --arg f "$file" '[.[] | select(.file == $f)]')
		fi

		local issue_created
		issue_created=$(_create_or_append_file_issue \
			"$repo_slug" "$pr_num" "$file" "$file_findings" \
			"$existing_issues_json" "$existing_open_issues_json" "$is_maintainer_pr")
		created=$((created + issue_created))
	done <<<"$files"

	echo "$created"
	return 0
}
