#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Query & Diagnostic Commands
# =============================================================================
# Read-only/diagnostic commands: cmd_pull, cmd_status, cmd_reconcile, cmd_help.
# These commands read from GitHub and TODO.md but do not create issues.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success)
#   - issue-sync-lib.sh (_escape_ere, strip_code_fences, add_gh_ref_to_todo,
#     fix_gh_ref_in_todo, sed_inplace, _seed_orphan_todo_line)
#   - issue-sync-helper-labels.sh (gh_list_issues, gh_find_issue_by_title)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_COMMANDS_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_COMMANDS_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# cmd_pull
# =============================================================================

_print_pull_summary() {
	local synced="$1" assignee_synced="$2" orphan_seeded="$3" orphan_skipped="$4"
	local orphan_open="$5" orphan_closed="$6" publication_deferred="$7" orphan_list="$8"
	printf "\n=== Pull Summary ===\nRefs synced: %d | Assignees: %d | Orphans seeded: %d | Orphans skipped: %d\n" \
		"$synced" "$assignee_synced" "$orphan_seeded" "$orphan_skipped"
	printf "Orphans open: %d closed: %d | Publication pending deferred: %d\n" \
		"$orphan_open" "$orphan_closed" "$publication_deferred"
	[[ $orphan_open -gt 0 ]] && print_warning "Open orphans: $orphan_list"
	[[ $synced -eq 0 && $assignee_synced -eq 0 && $orphan_open -eq 0 ]] && print_success "TODO.md refs up to date"
	return 0
}

cmd_pull() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	print_info "Pulling issue refs from GitHub ($repo) to TODO.md..."
	local synced=0 orphan_open=0 orphan_closed=0 assignee_synced=0 orphan_list="" orphan_seeded=0 orphan_skipped=0 publication_deferred=0 state=""
	for state in open closed; do
		local json
		json=$(gh_list_issues "$repo" "$state" 200)
		while IFS= read -r issue_line; do
			local num title tid login
			num=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
			title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
			tid=$(task_identity_parse_title_prefix "$title" || true)
			[[ -z "$tid" ]] && continue
			local tid_ere
			tid_ere=$(_escape_ere "$tid")
			# Resolve real task lines; TODO.md may contain examples in HTML comments.
			local task_line_num="" existing_ref=""
			task_line_num=$(_todo_task_line_num "$tid" "$todo_file")
			if [[ -n "$task_line_num" ]]; then
				existing_ref=$(sed -n "${task_line_num}p" "$todo_file" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
			fi
			if [[ "$existing_ref" != "$num" ]]; then
				if [[ -z "$task_line_num" ]]; then
					if [[ "$state" == "open" ]]; then
						local labels_json
						labels_json=$(echo "$issue_line" | jq -r '.labels // []' 2>/dev/null || echo "[]")
						if _issue_labels_include_exact "$labels_json" "publication:pending"; then
							print_info "Publication pending: deferred orphan TODO seeding for #$num ($tid)"
							publication_deferred=$((publication_deferred + 1))
							continue
						fi
						# t2698: seed a TODO.md entry for the open orphan
						if _seed_orphan_todo_line "$num" "$tid" "$title" "$labels_json" "$todo_file" "${DRY_RUN:-}"; then
							orphan_seeded=$((orphan_seeded + 1))
						else
							print_warning "ORPHAN: #$num ($tid: $title) — already in TODO.md"
							orphan_skipped=$((orphan_skipped + 1))
						fi
						orphan_open=$((orphan_open + 1))
						orphan_list="${orphan_list:+$orphan_list, }#$num ($tid)"
					else orphan_closed=$((orphan_closed + 1)); fi
					continue
				fi
				if [[ "$DRY_RUN" == "true" ]]; then
					if [[ -n "$existing_ref" ]]; then
						print_info "[DRY-RUN] Would fix ref:GH#$existing_ref -> ref:GH#$num on $tid"
					else
						print_info "[DRY-RUN] Would add ref:GH#$num to $tid"
					fi
					synced=$((synced + 1))
				else
					if [[ -n "$existing_ref" ]]; then
						fix_gh_ref_in_todo "$tid" "$existing_ref" "$num" "$todo_file"
					else
						add_gh_ref_to_todo "$tid" "$num" "$todo_file"
					fi
					local updated_ref=""
					updated_ref=$(resolve_task_gh_number "$tid" "$todo_file" "$repo" || true)
					if [[ "$updated_ref" == "$num" ]]; then
						print_success "Added ref:GH#$num to $tid"
						synced=$((synced + 1))
					else
						log_verbose "ref:GH#$num already present for $tid — skipped"
					fi
				fi
			fi
			# Assignee sync (open issues only).
			[[ "$state" != "open" ]] && continue
			login=$(echo "$issue_line" | jq -r '.assignees[0].login // empty' 2>/dev/null || echo "")
			[[ -z "$login" ]] && continue
			local tl
			tl=$(_first_todo_task_line_or_empty "$tid" "$todo_file") || return 1
			[[ -z "$tl" ]] && continue
			echo "$tl" | grep -qE 'assignee:[A-Za-z0-9._@-]+' && continue
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would add assignee:$login to $tid"
				assignee_synced=$((assignee_synced + 1))
				continue
			fi
			local ln
			ln=$(awk -v pat="^[[:space:]]*- \\[.\\] ${tid_ere} " '/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
			if [[ -n "$ln" ]]; then
				local cl
				cl=$(sed -n "${ln}p" "$todo_file")
				local nl
				if echo "$cl" | grep -qE 'logged:'; then
					nl=$(echo "$cl" | sed -E "s/( logged:)/ assignee:${login}\1/")
				else nl="${cl} assignee:${login}"; fi
				local nl_escaped
				nl_escaped=$(printf '%s' "$nl" | sed 's/[|&\\]/\\&/g')
				sed_inplace "${ln}s|.*|${nl_escaped}|" "$todo_file"
				assignee_synced=$((assignee_synced + 1))
			fi
		done < <(echo "$json" | jq -c '.[]' 2>/dev/null || true)
	done
	_print_pull_summary "$synced" "$assignee_synced" "$orphan_seeded" "$orphan_skipped" \
		"$orphan_open" "$orphan_closed" "$publication_deferred" "$orphan_list"
	return 0
}

# =============================================================================
# cmd_status
# =============================================================================

cmd_status() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	local unique_lines
	if ! unique_lines=$(_unique_todo_task_snapshot "$todo_file"); then
		print_error "Failed to parse unique TODO task snapshot"
		return 1
	fi
	local total_open=0 total_done=0 with_ref=0 status_line="" status_tid=""
	local incomplete_line_re='^[[:space:]]*-[[:space:]]+\[[[:space:]>]\]'
	while IFS= read -r status_line; do
		status_tid=$(_task_id_from_todo_line "$status_line" || true)
		[[ -n "$status_tid" ]] || continue
		if [[ "$status_line" =~ $incomplete_line_re ]]; then
			total_open=$((total_open + 1))
			[[ "$status_line" =~ ref:GH#[0-9]+ ]] && with_ref=$((with_ref + 1))
		elif [[ "$status_line" =~ ^[[:space:]]*-[[:space:]]+\[x\] ]]; then
			total_done=$((total_done + 1))
		fi
	done <<<"$unique_lines"
	local without_ref=$((total_open - with_ref))

	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local gh_open
	gh_open=$(echo "$open_json" | jq 'length' 2>/dev/null || echo "0")
	local gh_closed
	gh_closed=$(gh_list_issues "$repo" "closed" 500 | jq 'length' 2>/dev/null || echo "0")

	# Forward drift: open GH issue but TODO marked [x]
	local drift=0
	while IFS= read -r il; do
		local tid
		tid=$(task_identity_parse_title_prefix "$(echo "$il" | jq -r '.title' 2>/dev/null)" || true)
		[[ -z "$tid" ]] && continue
		local tid_ere
		tid_ere=$(_escape_ere "$tid")
		grep -qE "^\s*- \[x\] ${tid_ere} " "$todo_file" 2>/dev/null && {
			drift=$((drift + 1))
			print_warning "DRIFT: #$(echo "$il" | jq -r '.number') ($tid) open but completed"
		}
	done < <(echo "$open_json" | jq -c '.[]' 2>/dev/null || true)

	# Reverse drift: open TODO [ ] but GH issue is closed
	# Build set of open issue numbers for fast lookup (avoids per-task API calls)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)
	local reverse_drift=0
	while IFS= read -r line; do
		[[ "$line" =~ $incomplete_line_re ]] || continue
		local rtid
		rtid=$(_task_id_from_todo_line "$line" || true)
		[[ -n "$rtid" ]] || continue
		local ref_num
		ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$ref_num" ]] && continue
		# If the referenced issue number is not in the open set, it's reverse drift
		if ! echo "$open_numbers" | grep -qx "$ref_num"; then
			reverse_drift=$((reverse_drift + 1))
			print_warning "REVERSE-DRIFT: $rtid ref:GH#$ref_num — TODO open but issue closed"
		fi
	done <<<"$unique_lines"

	printf "\n=== Sync Status (%s) ===\nTODO open: %d (%d ref, %d no ref) | done: %d\nGitHub open: %s closed: %s | drift: %d | reverse-drift: %d\n" \
		"$repo" "$total_open" "$with_ref" "$without_ref" "$total_done" "$gh_open" "$gh_closed" "$drift" "$reverse_drift"
	[[ $without_ref -gt 0 ]] && print_warning "$without_ref tasks need push"
	[[ $drift -gt 0 ]] && print_warning "$drift tasks need close"
	[[ $reverse_drift -gt 0 ]] && print_warning "$reverse_drift open TODOs reference closed issues — run 'reconcile' to review"
	if [[ $without_ref -eq 0 && $drift -eq 0 && $reverse_drift -eq 0 ]]; then
		print_success "In sync"
	fi
	return 0
}

# =============================================================================
# cmd_reconcile
# =============================================================================

cmd_reconcile() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	print_info "Reconciling ref:GH# values in $repo..."
	local unique_lines
	if ! unique_lines=$(_unique_todo_task_snapshot "$todo_file"); then
		print_error "Failed to parse unique TODO task snapshot"
		return 1
	fi

	local ref_fixed=0 ref_ok=0 stale=0 orphans=0
	while IFS= read -r line; do
		local tid
		tid=$(_task_id_from_todo_line "$line" || true)
		local gh_ref
		gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$tid" || -z "$gh_ref" ]] && continue
		local it
		it=$(gh issue view "$gh_ref" --repo "$repo" --json title --jq '.title' 2>/dev/null || echo "")
		local itid
		itid=$(task_identity_parse_title_prefix "$it" || true)
		[[ "$itid" == "$tid" ]] && {
			ref_ok=$((ref_ok + 1))
			continue
		}

		print_warning "MISMATCH: $tid ref:GH#$gh_ref -> '$it'"
		local correct
		correct=$(gh_find_issue_by_title "$repo" "${tid}:" "all" 500)
		if [[ -n "$correct" && "$correct" != "$gh_ref" ]]; then
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Fix $tid: #$gh_ref -> #$correct"
			else
				fix_gh_ref_in_todo "$tid" "$gh_ref" "$correct" "$todo_file"
				print_success "Fixed $tid: #$gh_ref -> #$correct"
			fi
			ref_fixed=$((ref_fixed + 1))
		fi
	done <<<"$unique_lines"

	# Forward drift: open GH issue but TODO marked [x]
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 200)
	while IFS= read -r il; do
		local num tid
		num=$(echo "$il" | jq -r '.number' 2>/dev/null || echo "")
		tid=$(task_identity_parse_title_prefix "$(echo "$il" | jq -r '.title' 2>/dev/null)" || true)
		[[ -z "$tid" ]] && continue
		local tid_ere
		tid_ere=$(_escape_ere "$tid")
		grep -qE "^\s*- \[x\] ${tid_ere} " "$todo_file" 2>/dev/null && {
			print_warning "STALE: #$num ($tid) open but done"
			stale=$((stale + 1))
		}
		grep -qE "^\s*- \[.\] ${tid_ere} " "$todo_file" 2>/dev/null || orphans=$((orphans + 1))
	done < <(echo "$open_json" | jq -c '.[]' 2>/dev/null || true)

	# Reverse drift: open TODO [ ] but GH issue is closed
	# Build set of open issue numbers for fast lookup (avoids per-task API calls)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)
	local reverse_drift=0
	local incomplete_line_re='^[[:space:]]*-[[:space:]]+\[[[:space:]>]\]'
	while IFS= read -r line; do
		[[ "$line" =~ $incomplete_line_re ]] || continue
		local rtid
		rtid=$(_task_id_from_todo_line "$line" || true)
		[[ -n "$rtid" ]] || continue
		local ref_num
		ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$ref_num" ]] && continue
		if ! echo "$open_numbers" | grep -qx "$ref_num"; then
			reverse_drift=$((reverse_drift + 1))
			print_warning "REVERSE-DRIFT: $rtid ref:GH#$ref_num — TODO open but issue closed"
		fi
	done <<<"$unique_lines"

	printf "\n=== Reconciliation ===\nRefs OK: %d | fixed: %d | stale: %d | orphans: %d | reverse-drift: %d\n" \
		"$ref_ok" "$ref_fixed" "$stale" "$orphans" "$reverse_drift"
	[[ $stale -gt 0 ]] && print_info "Run 'issue-sync-helper.sh close' for stale issues"
	[[ $reverse_drift -gt 0 ]] && print_warning "$reverse_drift open TODOs reference closed issues — review each: reopen issue or mark TODO [x]"
	[[ $ref_fixed -eq 0 && $stale -eq 0 && $orphans -eq 0 && $reverse_drift -eq 0 ]] && print_success "All refs correct"
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'EOF'
Issue Sync Helper — stateless TODO.md <-> GitHub Issues sync via gh CLI.
Usage: issue-sync-helper.sh [command] [options]
Commands: push [tNNN] | enrich [tNNN] | sync-body tNNN | pull | close [tNNN] | reopen
          reconcile | relationships [tNNN] | backfill-sub-issues [--issue N]
          backfill-cross-phase-blocked-by --issue N
          status | help
Options: --repo SLUG | --project-root PATH | --dry-run | --verbose
         --force (skip evidence on close; bypass enrich body-gate)
         --force-push (allow bulk push outside CI — use with caution, risk of duplicates)
         --allow-closed (only with sync-body; explicit closed-issue correction)

Held body synchronization:
  sync-body tNNN — admin/maintain-authorized body-only update for exactly one
                   mapped issue that retains no-auto-dispatch. Requires
                   an authoritative local brief, rejects non-self active claims
                   and uncertain/concurrent state, preserves title, labels,
                   assignees, relationships, and lifecycle state, then verifies
                   the remote body hash and writes tamper-evident audit receipts.
                   Ordinary enrich, --force, bulk, pulse, and dispatch semantics
                   are unchanged. Closed issues require --allow-closed.

Drift detection:
  status    — reports forward drift (open issue, done TODO) and reverse drift
              (open TODO, closed issue) without making changes.
  reconcile — same detection plus ref mismatches, with actionable guidance.
  reopen    — reopens closed issues whose TODO entry is [ ] or [>] (incomplete).
              Only reopens issues closed as COMPLETED, not NOT_PLANNED.
              Safe for automated use in the pulse.

Relationships (t1889):
  relationships [tNNN] — sync blocked-by/blocks and subtask hierarchy to GitHub
                         issue relationships. Without tNNN, processes all tasks
                         that have ref:GH# plus blocked-by:/blocks: or subtask IDs.
                         Use --dry-run to preview. Idempotent (skips existing).

Sub-issue backfill (t2114):
  backfill-sub-issues [--issue N] — link decomposition children to their
                         parents using GitHub state alone (title + body). No
                         TODO.md or brief file required. Detects parents via:
                         (1) dot-notation title `tNNN.M: ...`, (2) `Parent: ...`
                         line in body, (3) `Blocked by: tNNN` where the blocker
                         carries the `parent-task` label. Idempotent; supports
                         --dry-run.

Cross-phase blocked-by backfill (t2877):
  backfill-cross-phase-blocked-by --issue N
                       — parse prose dependency declarations (e.g.
                         "P1 children blocked by P0a + P0b") from the body
                         of the given parent-task issue and emit the
                         corresponding addBlockedBy GitHub relationships.
                         Per-issue entry point called by the pulse t2877
                         reconcile stage. Idempotent; supports --dry-run.

Note: Bulk push (no task ID) is CI-only by default to prevent duplicate issues.
      Use 'push <task_id>' for single tasks, or --force-push to override.
EOF
}
