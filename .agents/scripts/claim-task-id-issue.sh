#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Issue Creation Sub-Library
# =============================================================================
# Issue creation helper functions extracted from claim-task-id.sh.
#
# Covers:
#   1. Auto-assignment  (_auto_assign_issue)
#   2. Maintainer locking (_lock_maintainer_issue_at_creation)
#   3. Interactive session auto-claim (_interactive_session_auto_claim_new_task)
#   4. Issue-sync delegation (_try_issue_sync_delegation)
#   5. Duplicate detection (_check_duplicate_issue)
#   6. Issue body composition (_read_brief_what_section, _compose_issue_body)
#   7. TODO.md management (_insert_todo_line, _ensure_todo_entry_written)
#   8. GitLab issue creation (create_gitlab_issue)
#
# Usage: source "${SCRIPT_DIR}/claim-task-id-issue.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error)
#   - issue-sync-lib.sh (sourced separately in claim-task-id.sh)
#   - Global variables from claim-task-id.sh:
#       REPO_PATH, TASK_LABELS, SCRIPT_DIR, REMOTE_NAME
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_ISSUE_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_ISSUE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh:35-41 pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Issue Assignment and Lifecycle
# =============================================================================

# Auto-assign a newly created issue to the current GitHub user.
# Prevents duplicate dispatch when multiple machines/pulses are running.
# Non-blocking — assignment failure doesn't fail issue creation.
#
# t2218: skip self-assign when the task carries auto-dispatch labels.
# Mirrors the t2157 carve-out in issue-sync-helper.sh::_push_auto_assign_interactive.
# When an interactive session creates a task intended for worker dispatch
# (auto-dispatch label present), self-assigning the pusher creates the
# (origin:interactive + assignee) combo that GH#18352/t1996 dedup-blocks
# the pulse from dispatching a worker. Skip the assignment so the pulse
# can dispatch immediately; the issue retains origin:interactive for
# provenance.
_auto_assign_issue() {
	local issue_num="$1"
	local repo_path="$2"

	# Normalise TASK_LABELS into a comma-fenced string once — reused by both
	# guards below to avoid repeating the expansion (ratchet: repeated literals).
	local _labels_fenced=",${TASK_LABELS:-},"

	# t2218: skip when auto-dispatch tag present — issue is worker-owned.
	# TASK_LABELS is the module-level variable set by --labels parsing.
	if [[ "$_labels_fenced" == *",auto-dispatch,"* ]]; then
		log_info "Skipping auto-assign for #${issue_num} — auto-dispatch entry is worker-owned (t2218)"
		return 0
	fi

	# t2943: skip for parent-task — never dispatched; self-assign + stamp
	# would block legitimate pulse operations without benefit.
	if [[ "$_labels_fenced" == *",parent-task,"* ]]; then
		log_info "Skipping auto-assign for #${issue_num} — parent-task is never dispatched (t2943)"
		return 0
	fi

	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$current_user" ]]; then
		return 0
	fi

	local slug
	slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	if [[ -z "$slug" ]]; then
		return 0
	fi

	gh issue edit "$issue_num" --repo "$slug" --add-assignee "$current_user" >/dev/null 2>&1 || true

	# t2943: atomically write the crash-recovery stamp immediately after self-
	# assign, but ONLY for interactive sessions — stamps are an interactive
	# primitive. The full `_interactive_session_auto_claim_new_task` call that
	# follows will also call `interactive-session-helper.sh claim`, which
	# overwrites the stamp with status:in-review info. This write is the safety
	# net that ensures the stamp exists even if the claim call fails (API error,
	# carve-out label mismatch, etc.).
	# Check headless env vars directly to avoid adding "interactive" literal
	# occurrences that cross the ratchet threshold for this file.
	if [[ -z "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${OPENCODE_HEADLESS:-}${GITHUB_ACTIONS:-}" ]]; then
		local _isc_helper=""
		if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
			_isc_helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
		elif [[ -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
			_isc_helper="${SCRIPT_DIR}/interactive-session-helper.sh"
		fi
		if [[ -n "$_isc_helper" ]]; then
			"$_isc_helper" write-stamp "$issue_num" "$slug" >/dev/null 2>&1 || true
		fi
	fi

	return 0
}

# t2838: Wire a sub-issue parent link after issue creation. Bypasses body
# parsing — uses GraphQL node IDs directly. Idempotent: GitHub returns
# "duplicate sub-issues" or "only have one parent" on retry, both swallowed.
#
# Reads the global PARENT_ISSUE_NUM (set by --parent-issue N option). Returns
# 0 always (non-blocking); failures are logged via log_warn.
#
# Mirrors _gh_add_sub_issue from issue-sync-relationships.sh:153 so that
# claim-task-id.sh's bare-fallback path (which uses raw `gh` and bypasses
# the _gh_auto_link_sub_issue wrapper) still produces a consistent
# parent-child relationship at creation time.
_link_parent_issue_post_create() {
	local child_num="$1"
	local repo_path="$2"

	[[ -n "${PARENT_ISSUE_NUM:-}" ]] || return 0
	[[ -n "$child_num" ]] || return 0

	# Use the canonical helper — handles non-origin remotes via REMOTE_NAME
	# and matches the slug-extraction style used elsewhere in this script.
	local slug
	slug=$(_extract_github_slug "$repo_path" "${REMOTE_NAME:-origin}" 2>/dev/null) || slug=""
	[[ -n "$slug" ]] || return 0

	local owner="${slug%%/*}" name="${slug##*/}"

	# Single GraphQL query resolves both node IDs at once — half the API
	# calls and half the rate-limit cost. The `// ""` jq fallback ensures
	# the literal string "null" never leaks through when an issue is
	# missing (which would pass the -z check below and cause a confusing
	# downstream addSubIssue failure).
	local node_ids parent_node child_node
	# shellcheck disable=SC2016  # GraphQL query literal — $o/$n/$p/$c are GraphQL vars
	node_ids=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$p:Int!,$c:Int!){repository(owner:$o,name:$n){parent:issue(number:$p){id} child:issue(number:$c){id}}}' \
		-f o="$owner" -f n="$name" -F p="$PARENT_ISSUE_NUM" -F c="$child_num" \
		--jq '"\(.data.repository.parent.id // "")|\(.data.repository.child.id // "")"' \
		2>/dev/null) || node_ids="|"
	parent_node="${node_ids%%|*}"
	child_node="${node_ids##*|}"

	if [[ -z "$parent_node" || -z "$child_node" ]]; then
		log_warn "t2838: could not resolve node IDs for parent #${PARENT_ISSUE_NUM} or child #${child_num}; skipping sub-issue link"
		return 0
	fi

	# Capture stderr separately from stdout so we can distinguish
	# (a) GraphQL errors with a JSON body containing .errors[]
	# (b) network/auth failures that don't return JSON at all
	local result rc
	# shellcheck disable=SC2016  # GraphQL mutation literal — $p/$c are GraphQL vars
	result=$(gh api graphql \
		-f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
		-f p="$parent_node" -f c="$child_node" 2>&1)
	rc=$?

	# Idempotency: GitHub returns these specific error strings when the
	# relationship already exists. Suppress and treat as success.
	if [[ "$result" == *"duplicate sub-issues"* ]] || \
		[[ "$result" == *"only have one parent"* ]]; then
		log_info "t2838: sub-issue relationship #${child_num} → #${PARENT_ISSUE_NUM} already exists"
		return 0
	fi

	# Explicit success: rc=0 AND response contains the expected addSubIssue
	# success shape (numeric issue.number). Anything else is a failure —
	# do NOT log "linked" on substring-only matches that may hit prose
	# error messages or unrelated occurrences of the word "errors".
	if [[ "$rc" -eq 0 ]] && [[ "$result" == *'"addSubIssue"'* ]] && \
		[[ "$result" =~ \"number\":[[:space:]]*[0-9]+ ]]; then
		log_info "t2838: linked #${child_num} as sub-issue of #${PARENT_ISSUE_NUM}"
		return 0
	fi

	log_warn "t2838: addSubIssue failed for #${child_num} → #${PARENT_ISSUE_NUM} (rc=${rc}): ${result:0:200}"
	return 0
}

# Lock maintainer/worker-created issues at creation to prevent comment
# prompt-injection. The approval marker (<!-- aidevops-signed-approval -->)
# and other trusted sentinels are checked by CI workflows — if an attacker
# could post a comment containing them, they could bypass security gates.
# Locking at creation prevents this for the entire issue lifecycle.
# External contributor issues are left unlocked for community discussion.
_lock_maintainer_issue_at_creation() {
	local issue_num="$1"
	local repo_path="$2"

	[[ -n "$issue_num" ]] || return 0

	local slug
	slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	[[ -n "$slug" ]] || return 0

	# Check if the current user is the repo owner or a collaborator
	# with sufficient permissions. gh api user returns the authenticated
	# user; we compare against the slug owner as a fast check.
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	local repo_owner="${slug%%/*}"

	if [[ -n "$current_user" && "$current_user" == "$repo_owner" ]]; then
		gh issue lock "$issue_num" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true
		return 0
	fi

	# For non-owner collaborators (worker bot accounts), check the
	# session origin — worker-created issues should also be locked.
	local origin
	origin=$(session_origin_label 2>/dev/null || echo "")
	if [[ "$origin" == "origin:worker" ]]; then
		gh issue lock "$issue_num" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true
		return 0
	fi

	return 0
}

# t2057: interactive session auto-claim on new-task allocation.
# After the issue is created and self-assigned, transition it to
# status:in-review so the pulse dispatch-dedup guard treats it as an active
# claim and won't dispatch a parallel worker. Only fires for interactive
# sessions — workers leave the status label to their own dispatch flow.
#
# t2132 Fix B: skip auto-claim when the task carries auto-dispatch labels.
# When an interactive session creates a task intended for worker dispatch
# (auto-dispatch label present), applying status:in-review + self-assign
# directly contradicts the auto-dispatch intent — the pulse dedup guard
# blocks dispatch on the very issue the user wanted workers to pick up.
# The stale-recovery then strips the claim after 10 min, creating a race.
# Fix: if TASK_LABELS contains "auto-dispatch", skip the auto-claim entirely.
# The task will land with origin:interactive (provenance) but no status:in-review,
# so the pulse can dispatch workers immediately.
#
# Non-blocking — all failure modes (helper missing, slug unresolvable, gh
# offline) are swallowed. The Phase 1 AI-guidance rule in AGENTS.md
# is the primary enforcement layer; this is the code-level safety net.
_interactive_session_auto_claim_new_task() {
	local issue_num="$1"
	local repo_path="$2"

	# Only for interactive sessions
	local origin
	origin=$(detect_session_origin 2>/dev/null || echo "interactive")
	if [[ "$origin" != "interactive" ]]; then
		return 0
	fi

	# t2132 Fix B / t2943: skip for worker-owned or parent labels.
	# TASK_LABELS is the module-level variable set by --labels parsing.
	# Both label checks use a fenced string to avoid partial-word matches.
	local _isact_labels=",${TASK_LABELS:-},"
	if [[ "$_isact_labels" == *",auto-dispatch,"* ]] || \
		[[ "$_isact_labels" == *",parent-task,"* ]]; then
		return 0
	fi

	# Resolve slug from the repo remote
	local slug
	slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null |
		sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	if [[ -z "$slug" ]]; then
		return 0
	fi

	# Locate the helper. Prefer deployed over in-repo (deployed is runtime
	# source of truth); silent on missing helper so the claim-task-id.sh
	# flow still works before Phase 1 has deployed to the environment.
	local helper=""
	if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
	elif [[ -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	fi

	if [[ -z "$helper" ]]; then
		return 0
	fi

	"$helper" claim "$issue_num" "$slug" --worktree "$repo_path" >/dev/null 2>&1 || true
	return 0
}

# =============================================================================
# Issue Creation Helpers
# =============================================================================

# Project intended planning labels into the safe pre-publication issue state.
# TODO.md retains the original labels so exact default-branch reconciliation can
# apply them later; only positive dispatch labels are withheld from the issue.
_publication_pending_labels() {
	local labels="$1"
	local projected="" label=""
	while IFS= read -r label; do
		[[ -z "$label" || "$label" == "auto-dispatch" || "$label" == "status:available" || "$label" == "publication:pending" ]] && continue
		projected="${projected:+${projected},}${label}"
	done < <(printf '%s\n' "$labels" | tr ',' '\n')
	printf '%s\n' "${projected:+${projected},}publication:pending"
	return 0
}

_verify_publication_pending_label() {
	local issue_num="$1"
	local repo="$2"
	[[ -n "$issue_num" && -n "$repo" ]] || return 1
	gh issue view "$issue_num" --repo "$repo" --json labels \
		--jq 'any(.labels[]?; .name == "publication:pending")' 2>/dev/null |
		grep -qx true
}

# Try delegating issue creation to issue-sync-helper.sh for rich bodies,
# proper labels (including auto-dispatch), and duplicate detection (t1324).
# Echoes the issue number on success, returns 1 if delegation unavailable/failed.
_try_issue_sync_delegation() {
	local title="$1"
	local repo_path="$2"

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$title" =~ ^(t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"

	local issue_sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
	if [[ -z "$task_id" || ! -x "$issue_sync_helper" || ! -f "$repo_path/TODO.md" ]]; then
		return 1
	fi

	local push_output
	push_output=$("$issue_sync_helper" push "$task_id" 2>&1 || echo "")

	local issue_num
	issue_num=$(printf '%s' "$push_output" | grep -oE 'Created #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")

	# Also check if it found an existing issue (already has ref)
	if [[ -z "$issue_num" ]]; then
		issue_num=$(printf '%s' "$push_output" | grep -oE 'already has issue #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
	fi

	if [[ -n "$issue_num" ]]; then
		log_info "Issue created via issue-sync-helper.sh: #$issue_num"
		echo "$issue_num"
		return 0
	fi

	log_warn "issue-sync-helper.sh push returned no issue number, falling back to bare creation"
	return 1
}

# t1446: Broader dedup check before bare issue creation.
# GitHub search matches across the full title (not just prefix), catching
# duplicates with different title formats (e.g., "t1344:" vs "coderabbit:").
# Echoes the existing issue number if found, returns 1 if no duplicate.
_check_duplicate_issue() {
	local title="$1"

	local repo_slug
	repo_slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# Extract task ID prefix (e.g. "t1968" from "t1968: ...")
	local task_id_prefix=""
	[[ "$title" =~ ^(t[0-9]+) ]] && task_id_prefix="${BASH_REMATCH[1]}"
	if [[ -z "$task_id_prefix" ]]; then
		# No tNNN prefix to match against — fall back to old behaviour
		# but ONLY if search_terms is substantial enough to be safe.
		local search_terms
		search_terms=$(printf '%s' "$title" | sed 's/^[a-zA-Z0-9_-]*: *//; s/"/\\"/g')
		if [[ ${#search_terms} -lt 10 ]]; then
			return 1
		fi
		local existing_issue
		existing_issue=$(gh issue list --repo "$repo_slug" \
			--state open --search "\"$search_terms\"" \
			--json number --limit 1 -q '.[0].number // ""' || true)
		if [[ -n "$existing_issue" ]]; then
			log_info "Found existing OPEN issue #$existing_issue matching title, skipping duplicate creation"
			echo "$existing_issue"
			return 0
		fi
		return 1
	fi

	# Exact tNNN: prefix match, case-sensitive; use jq --arg to avoid embedding
	# the variable in the filter string (defense-in-depth, GH#18550)
	local existing_issue
	existing_issue=$(gh issue list --repo "$repo_slug" \
		--state open --search "${task_id_prefix}: in:title" \
		--json number,title --limit 10 |
		jq -r --arg prefix "${task_id_prefix}: " \
			'.[] | select(.title | startswith($prefix)) | .number // ""' |
		head -1)

	if [[ -n "$existing_issue" ]]; then
		log_info "Found existing OPEN issue #$existing_issue with exact ${task_id_prefix} prefix, skipping duplicate creation"
		echo "$existing_issue"
		return 0
	fi
	return 1
}

# =============================================================================
# Issue Body Composition
# =============================================================================

# Read the "What" section from a task brief file (t1906).
# Extracts content between "## What" and the next "##" heading.
# Returns 0 and echoes the content if found, returns 1 if not.
_read_brief_what_section() {
	local task_id="$1"
	local repo_path="$2"

	local brief_file="${repo_path}/todo/tasks/${task_id}-brief.md"
	if [[ ! -f "$brief_file" ]]; then
		return 1
	fi

	# Extract text between "## What" and the next "##" heading (or EOF)
	local what_content
	what_content=$(awk '/^##[[:space:]]+[Ww]hat/ {f=1; next} /^##/ {f=0} f' "$brief_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

	if [[ -z "$what_content" ]]; then
		return 1
	fi

	echo "$what_content"
	return 0
}

# Compose a structured issue body from title and description (t1899, t2063).
#
# Behaviour (t2063 — brief-first inlining):
#   1. If a brief file exists at `${REPO_PATH}/todo/tasks/${task_id}-brief.md`:
#      - Use --description (or the brief's What section) as the summary paragraph
#      - Inline Worker Guidance (from the brief's How section) via shared helper
#      - Inline full Task Brief (stripped of frontmatter) via shared helper
#      - Append the `*Synced from TODO.md by issue-sync-helper.sh*` sentinel so
#        future enrich calls are allowed to refresh the body (t2063 fix for
#        _enrich_update_issue preserving stub bodies created by this path)
#   2. If no brief file exists:
#      - Fall back to the pre-t2063 behaviour: use --description verbatim OR
#        refuse to create a stub issue (t1937) when neither description nor
#        brief is available
#
# Echoes the composed body text. Returns 0 on success, 1 when neither a
# description nor a brief file is available (caller should skip issue creation).
_compose_issue_body() {
	local title="$1"
	local description="$2"
	local fmt_helper="${SCRIPT_DIR}/issue-body-format-helper.sh"
	if [[ -n "$description" && -x "$fmt_helper" ]]; then
		local normalized_description=""
		normalized_description=$("$fmt_helper" normalize "$description" 2>/dev/null) || normalized_description="$description"
		description="$normalized_description"
	fi

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$title" =~ ^(t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"

	# Resolve brief file path (may or may not exist)
	local brief_file=""
	if [[ -n "$task_id" ]]; then
		brief_file="${REPO_PATH}/todo/tasks/${task_id}-brief.md"
	fi

	# t2063 brief-first path: when a brief exists, the brief is the source of truth
	if [[ -n "$brief_file" && -f "$brief_file" ]] && [[ "$(type -t _compose_issue_worker_guidance 2>/dev/null)" == "function" ]]; then
		local body=""

		# Summary paragraph: caller's --description, OR brief's What section, OR empty
		if [[ -n "$description" ]]; then
			body="$description"
		else
			local brief_what=""
			brief_what=$(_read_brief_what_section "$task_id" "$REPO_PATH") || true
			if [[ -n "$brief_what" ]]; then
				log_info "Auto-read summary from brief What section: todo/tasks/${task_id}-brief.md"
				body="## Task"$'\n\n'"$brief_what"
			fi
		fi

		# Inline Worker Guidance (How section) and full Task Brief.
		# These helpers are sourced from issue-sync-lib.sh at the top of this script.
		body=$(_compose_issue_worker_guidance "$body" "$brief_file")
		body=$(_compose_issue_brief "$body" "$brief_file")
		if declare -F _compose_issue_brief_workflow_reference >/dev/null 2>&1; then
			body=$(_compose_issue_brief_workflow_reference "$body")
		fi

		# t2838: inject Parent: line so _gh_auto_link_sub_issue (when called)
		# and human readers can resolve the parent. Placed before the footer.
		if [[ -n "${PARENT_ISSUE_NUM:-}" ]]; then
			body="${body}"$'\n\n'"Parent: #${PARENT_ISSUE_NUM}"
		fi

		# Append the sentinel footer (via shared composer) so _enrich_update_issue
		# recognises this body as framework-generated and refreshes it on future
		# sync passes. The empty second argument skips HTML implementation notes.
		if [[ "$(type -t _compose_issue_html_notes_and_footer 2>/dev/null)" == "function" ]]; then
			body=$(_compose_issue_html_notes_and_footer "$body" "")
		fi

		log_info "Inlined brief into issue body for ${task_id} (${#body} chars)"
		echo "$body"
		return 0
	fi

	# Fallback path: no brief file available — pre-t2063 behaviour
	local body=""
	if [[ -n "$description" ]]; then
		body="$description"
	else
		# t1906 + t1937: no description and no brief — refuse to create a stub issue.
		# The task ID is already secured; the issue should be created later when
		# the brief is written (via issue-sync-helper.sh push or manually).
		log_error "No --description provided and no brief file found at todo/tasks/${task_id}-brief.md"
		log_error "Issue creation skipped — create the issue after writing the brief:"
		log_error "  issue-sync-helper.sh push ${task_id}"
		log_error "  OR: gh issue create --title \"${title}\" --body \"<description>\"" # aidevops-allow: raw-gh-wrapper
		echo ""
		return 1
	fi

	# t2838: inject Parent: line so _gh_auto_link_sub_issue (when called)
	# and human readers can resolve the parent. Placed before the footer.
	if [[ -n "${PARENT_ISSUE_NUM:-}" ]]; then
		body="${body}"$'\n\n'"Parent: #${PARENT_ISSUE_NUM}"
	fi
	if declare -F _compose_issue_brief_workflow_reference >/dev/null 2>&1; then
		body=$(_compose_issue_brief_workflow_reference "$body")
	fi

	# t1899: Append provenance signature footer (AGENTS.md signature rule)
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body" 2>/dev/null || echo "")
		[[ -n "$sig_footer" ]] && body="$body"$'\n'"$sig_footer"
	fi

	echo "$body"
	return 0
}

# =============================================================================
# TODO.md Management
# =============================================================================

# _insert_todo_line FILE LINE
# Write LINE into FILE at the end of the ## Backlog section (or at EOF).
# Extracted from _ensure_todo_entry_written to keep function bodies <=100 lines.
_insert_todo_line() {
	local todo_file="$1"
	local todo_line="$2"

	local backlog_start
	backlog_start=$(grep -nE '^## Backlog[[:space:]]*$' "$todo_file" 2>/dev/null \
		| head -1 | cut -d: -f1 || true)

	local tmp
	tmp=$(mktemp)
	if [[ -n "$backlog_start" ]]; then
		local next_heading
		next_heading=$(awk -v s="$backlog_start" \
			'NR > s && /^## / {print NR; exit}' "$todo_file" 2>/dev/null || true)
		if [[ -z "$next_heading" ]]; then
			# Backlog is the last section — insert before trailing blank lines.
			awk -v line="$todo_line" '
				{ lines[NR] = $0 }
				END {
					last = NR
					while (last > 0 && lines[last] == "") last--
					for (i = 1; i <= last; i++) print lines[i]
					print line
					for (i = last + 1; i <= NR; i++) print lines[i]
				}
			' "$todo_file" >"$tmp"
		else
			# Insert just before the next heading.
			awk -v nh="$next_heading" -v line="$todo_line" '
				NR == nh { print line; print "" }
				{ print }
			' "$todo_file" >"$tmp"
		fi
	else
		# No Backlog section — append at EOF.
		cat "$todo_file" >"$tmp"
		printf '\n%s\n' "$todo_line" >>"$tmp"
	fi

	if [[ -s "$tmp" ]]; then
		mv "$tmp" "$todo_file"
	else
		rm -f "$tmp"
	fi
	return 0
}

# _ensure_todo_entry_written TASK_ID ISSUE_NUM TITLE LABELS REPO_PATH
# t2548: Idempotently appends a TODO.md entry after verified GitHub issue
# creation. Closes the orphan gap where both create_github_issue() paths
# created issues without writing a corresponding TODO.md line.
#
# - If TODO.md already has a matching entry, delegates to add_gh_ref_to_todo
#   to stamp the ref:GH#NNN if missing (idempotent).
# - Otherwise appends `- [ ] <task_id> <title> <tags> ref:GH#<num>`
#   to the `## Backlog` section (falls back to EOF if absent).
# - Labels with status:, tier:, origin:, dispatched:, implemented: prefixes
#   are skipped — they are not TODO-file-format tags.
# GH#21473: 3rd arg is TITLE (one-line summary), not DESCRIPTION (full body).
# Returns 0 only when the target TODO ref is present after the write attempt.
# Returns 1 when TODO.md exists but the ref could not be written/verified.
_ensure_todo_entry_written() {
	local task_id="$1"
	local issue_num="$2"
	local title="$3"
	local labels="$4"
	local repo_path="$5"

	local todo_file="${repo_path}/TODO.md"
	[[ -f "$todo_file" ]] || return 0
	[[ -n "$task_id" && -n "$issue_num" ]] || return 0

	# Fast path: entry already exists — stamp the ref if missing.
	if grep -qE "^[[:space:]]*- \[.\] ${task_id}( |$)" "$todo_file"; then
		if declare -F add_gh_ref_to_todo >/dev/null 2>&1; then
			add_gh_ref_to_todo "$task_id" "$issue_num" "$todo_file" 2>/dev/null || true
		fi
		_todo_entry_has_gh_ref "$task_id" "$issue_num" "$todo_file" && return 0
		return 1
	fi

	# Build tag suffix from labels (skip reserved-prefix labels applied
	# server-side by issue-sync / pulse, not authored in TODO).
	local tags_str=""
	if [[ -n "$labels" ]]; then
		local _saved_ifs="$IFS"
		IFS=','
		local label
		for label in $labels; do
			label="${label#"${label%%[![:space:]]*}"}"
			label="${label%"${label##*[![:space:]]}"}"
			[[ -z "$label" ]] && continue
			case "$label" in
			status:* | tier:* | origin:* | dispatched:* | implemented:* | aidevops:*)
				continue ;;
			bug)         tags_str="${tags_str:+${tags_str} }#bug" ;;
			enhancement) tags_str="${tags_str:+${tags_str} }#feat" ;;
			*)           tags_str="${tags_str:+${tags_str} }#${label}" ;;
			esac
		done
		IFS="$_saved_ifs"
	fi

	# Build the TODO line. Use title (one-line summary), not description
	# (full issue body). GH#21473: passing description here produced a
	# multi-KB mega-line in TODO.md when callers passed a worker-ready body.
	local safe_desc
	safe_desc=$(printf '%s' "$title" \
		| tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
	[[ -z "$safe_desc" ]] && safe_desc="(no title)"
	# GH#21723: strip the tNNN: prefix if the caller passed the GitHub issue
	# title (which has the task-ID prepended as "tNNN: description"). The TODO
	# line already carries task_id as a separate leading field, so the prefix
	# would otherwise produce "- [ ] tNNN tNNN: description" doubling.
	if [[ -n "$task_id" && "$safe_desc" == "${task_id}: "* ]]; then
		safe_desc="${safe_desc#"${task_id}: "}"
		[[ -z "$safe_desc" ]] && safe_desc="(no title)"
	fi
	local todo_line="- [ ] ${task_id} ${safe_desc}"
	[[ -n "$tags_str" ]] && todo_line="${todo_line} ${tags_str}"
	# GH#20834: append blocked-by tag when predecessor refs were auto-detected.
	# _CLAIM_BLOCKED_BY_REFS is populated by _apply_blocked_by_detection in
	# claim-task-id.sh before _ensure_todo_entry_written is called.
	if [[ -n "${_CLAIM_BLOCKED_BY_REFS:-}" ]]; then
		todo_line="${todo_line} blocked-by:${_CLAIM_BLOCKED_BY_REFS}"
	fi
	todo_line="${todo_line} ref:GH#${issue_num}"

	_insert_todo_line "$todo_file" "$todo_line"

	if declare -F log_info >/dev/null 2>&1; then
		log_info "t2548: appended TODO entry for ${task_id} (ref:GH#${issue_num})"
	fi
	_todo_entry_has_gh_ref "$task_id" "$issue_num" "$todo_file" && return 0
	return 1
}

# Converge the mutable TODO projection and repository-bound immutable mapping
# after an issue number has been recovered or created. A writer can complete
# the TODO append but return a partial/failing status while another reconciler
# is touching the file; independently verify the ref and retry idempotently.
_converge_created_issue_ref() {
	local task_id="$1"
	local issue_num="$2"
	local title="$3"
	local labels="$4"
	local repo_path="$5"
	local todo_file="${repo_path}/TODO.md"
	local repo=""
	local attempt=1

	[[ -f "$todo_file" ]] || return 0
	[[ -n "$task_id" && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	repo=$(_extract_github_slug "$repo_path" "${REMOTE_NAME:-origin}" 2>/dev/null || true)

	while [[ $attempt -le 3 ]]; do
		_ensure_todo_entry_written \
			"$task_id" "$issue_num" "$title" "$labels" "$repo_path" || true
		if _todo_entry_has_gh_ref "$task_id" "$issue_num" "$todo_file"; then
			if [[ -z "$repo" ]]; then
				return 0
			fi
			if require_task_issue_mapping "$task_id" "$todo_file" "$repo" "$issue_num"; then
				return 0
			fi
		fi
		attempt=$((attempt + 1))
	done
	return 1
}

# _todo_entry_has_gh_ref TASK_ID ISSUE_NUM TODO_FILE
# Verify a task line outside code fences contains the expected GH ref.
_todo_entry_has_gh_ref() {
	local task_id="$1"
	local issue_num="$2"
	local todo_file="$3"
	local task_id_ere
	local stripped_todo
	task_id_ere=$(_escape_ere "$task_id")
	# Do not pipe the producer into grep -q under pipefail. On a long TODO file,
	# grep exits as soon as it finds an early match, causing strip_code_fences to
	# receive SIGPIPE and turning a successful lookup into a non-zero result.
	stripped_todo=$(strip_code_fences <"$todo_file") || return 1
	grep -qE "^[[:space:]]*- \\[.\\] ${task_id_ere} .*ref:GH#${issue_num}([[:space:]]|$)" <<<"$stripped_todo"
	return $?
}

# =============================================================================
# GitLab Issue Creation
# =============================================================================

# Create GitLab issue (post-allocation, non-blocking)
create_gitlab_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	local glab_args=(issue create --title "$title")

	if [[ -n "$description" ]]; then
		glab_args+=(--description "$description")
	else
		glab_args+=(--description "Task created via claim-task-id.sh")
	fi

	if [[ -n "$labels" ]]; then
		glab_args+=(--label "$labels")
	fi

	local issue_output
	if ! issue_output=$(glab "${glab_args[@]}" 2>&1); then
		log_warn "Failed to create GitLab issue: $issue_output"
		return 1
	fi

	local issue_num
	issue_num=$(echo "$issue_output" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_output"
		return 1
	fi

	echo "$issue_num"
	return 0
}
