#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-simplification-state.sh — Simplification hash-registry state management.
#
# Extracted from pulse-simplification.sh in t2020 (GH#18483) as the surgical
# split to clear the 2,000-line simplification gate that was blocking #18420
# (t1993: schedule post-merge-review-scanner.sh).
#
# This module contains the self-contained sub-cluster of functions that read,
# write, refresh, prune, publish, and backfill .agents/configs/simplification-state.json
# — the shared hash registry the simplification routine uses to detect which
# files have been processed, how many passes they have been through, and whether
# they have converged.
#
# Why a separate module? The parent file (pulse-simplification.sh) had grown to
# 2,058 lines — 58 over the large-file simplification gate threshold — which
# deadlocked any dispatch that named the file as an implementation target. The
# state cluster is the largest self-contained sub-cluster in the parent file:
# its 7 functions only call each other, _complexity_scan_has_existing_issue
# (resolved at call time via Bash name resolution since both modules are sourced
# from pulse-wrapper.sh), and standard shell/gh/jq builtins. No call graph
# rewiring is needed — this is a pure move.
#
# This module is sourced by pulse-wrapper.sh immediately after
# pulse-simplification.sh. It MUST NOT be executed directly — it relies on the
# orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
#   pulse-simplification.sh   (source order: state AFTER parent, since parent
#                              defines _complexity_scan_has_existing_issue which
#                              _simplification_state_backfill_closed calls.
#                              Bash resolves function names at call time, so
#                              the inverse order would also work, but keeping
#                              state after parent reads left-to-right as
#                              "parent, then the state sub-cluster extracted
#                              from it".)
#
# Functions in this module (in source order):
#   - _simplification_state_check
#   - _simplification_state_record
#   - _simplification_state_refresh
#   - _simplification_state_prune
#   - _simplification_state_push
#   - _create_requeue_issue
#   - _simplification_backfill_extract_file_path            (helper, GH#18680)
#   - _simplification_backfill_update_entry_state           (helper, GH#18680)
#   - _simplification_backfill_verify_remaining_smells      (helper, GH#18680)
#   - _simplification_state_backfill_closed
#   - _simplification_close_spurious_requeue_issues          (defensive, GH#18795)
#
# The three _simplification_backfill_* helpers were extracted from
# _simplification_state_backfill_closed in GH#18680 to keep the orchestrator
# under the 100-line function-complexity gate. The public call contract
# (same args, same stdout, same state file mutations, same log lines) is
# unchanged. All other function bodies remain byte-identical to the pre-
# extraction (t2020) form.
#
# _simplification_close_spurious_requeue_issues (GH#18795) is a defensive
# sweep that auto-closes any open re-queue issues whose title says
# "0 smells remaining" AND whose target file currently has zero Qlty smells.
# It catches stragglers from the pre-PR-#18848 grep-c bug and self-heals any
# future regression of the same class.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_SIMPLIFICATION_STATE_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_STATE_LOADED=1

# Check if a file has already been simplified and is unchanged.
# Arguments: $1 - repo_path, $2 - file_path (repo-relative), $3 - state_file path
# Returns: 0 = already simplified (unchanged/converged), 1 = not simplified or changed
# Outputs to stdout: "unchanged" | "converged" | "recheck" | "new"
# "converged" means the file has been through SIMPLIFICATION_MAX_PASSES passes
# and should not be re-flagged until it is genuinely modified by non-simplification work.
_simplification_state_check() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"
	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"

	if [[ ! -f "$state_file" ]]; then
		echo "new"
		return 1
	fi

	local recorded_hash
	recorded_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$state_file" 2>/dev/null) || recorded_hash=""

	if [[ -z "$recorded_hash" ]]; then
		echo "new"
		return 1
	fi

	# Compute current git blob hash
	local current_hash
	local full_path="${repo_path}/${file_path}"
	if [[ ! -f "$full_path" ]]; then
		echo "new"
		return 1
	fi
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""

	if [[ "$current_hash" == "$recorded_hash" ]]; then
		echo "unchanged"
		return 0
	fi

	# Hash differs — check pass count before flagging for recheck (t1754).
	# Files that have been through max_passes simplification rounds are
	# considered converged. They won't be re-flagged until the hash is
	# refreshed by _simplification_state_refresh (which resets passes to 0
	# only when the file is genuinely modified by non-simplification work).
	local passes
	passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || passes=0
	if [[ "$passes" -ge "$max_passes" ]]; then
		echo "converged"
		return 0
	fi

	echo "recheck"
	return 1
}

# Record a file as simplified in the state file.
# Increments the pass counter each time a file is re-simplified (t1754).
# Arguments: $1 - repo_path, $2 - file_path, $3 - state_file, $4 - pr_number
_simplification_state_record() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"
	local pr_number="${4:-0}"

	local current_hash
	local full_path="${repo_path}/${file_path}"
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""
	[[ -z "$current_hash" ]] && return 1

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Ensure state file exists with valid structure
	if [[ ! -f "$state_file" ]]; then
		printf '{"files":{}}\n' >"$state_file"
	fi

	# Read existing pass count and increment (t1754 — convergence tracking)
	local prev_passes
	prev_passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || prev_passes=0
	local new_passes=$((prev_passes + 1))

	# Update the entry using jq — includes pass counter
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" \
		--argjson pr "$pr_number" --argjson passes "$new_passes" \
		'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr, "passes": $passes}' \
		"$state_file" >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
	return 0
}

# Refresh all hashes in the simplification state file against current main (t1754).
# This replaces the fragile timeline-API-based backfill. For every file already
# in state, recompute git hash-object. If the hash matches, do nothing. If it
# differs, update the hash AND increment the pass counter (the file was changed
# by a simplification PR that merged since the last scan).
#
# BRANCH GUARD (GH#18622): This function must only write state when on the main
# branch. Running it on a feature branch would pollute PR diffs with hundreds of
# unrelated hash updates, increasing merge-conflict surface. The function checks
# the current branch and skips the write phase (but not the read/check) when
# not on main. _simplification_state_push has a matching guard; this guard
# prevents even the in-memory tmp_state from being persisted to disk.
#
# Arguments: $1 - repo_path, $2 - state_file path
# Returns: 0 on success. Outputs refreshed count to stdout.
_simplification_state_refresh() {
	local repo_path="$1"
	local state_file="$2"
	local refreshed=0

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	# Branch guard: skip write phase when not on main (GH#18622).
	# State refresh is a main-branch-only maintenance operation. On feature branches,
	# return 0 (no changes) so the caller does not trigger a state push commit.
	local main_branch current_branch
	main_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"
	current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""
	if [[ -n "$current_branch" && "$current_branch" != "$main_branch" && "$current_branch" != "HEAD" ]]; then
		echo "[pulse-wrapper] simplification-state: skipping refresh write — not on $main_branch (on $current_branch); state is read-only on PR branches (GH#18622)" >>"${LOGFILE:-/dev/null}"
		echo "0"
		return 0
	fi

	local file_paths
	file_paths=$(jq -r '.files | keys[]' "$state_file" 2>/dev/null) || file_paths=""
	[[ -z "$file_paths" ]] && {
		echo "0"
		return 0
	}

	local tmp_state
	tmp_state=$(mktemp)
	cp "$state_file" "$tmp_state"

	while IFS= read -r fp; do
		[[ -z "$fp" ]] && continue
		local full_path="${repo_path}/${fp}"
		[[ ! -f "$full_path" ]] && continue

		local current_hash stored_hash
		current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || continue
		# Read hash and passes in a single jq call — spawning jq twice per file
		# inside a loop is inefficient when the state file can have hundreds of entries (GH#18555).
		# GH#19044: replaced process substitution (< <(jq ...)) with command
		# substitution + here-string to avoid FD leaks in bash 3.2. Process
		# substitution creates a /dev/fd entry per iteration that bash 3.2
		# does not reliably close, exhausting the 256 FD soft limit after
		# ~200 files.
		local prev_passes _jq_result
		_jq_result=$(jq -r --arg fp "$fp" \
			'.files[$fp] // {"hash": "", "passes": 0} | [(.hash // ""), (.passes // 0 | tostring)] | join("\t")' \
			"$tmp_state" 2>/dev/null) || _jq_result=""
		IFS=$'\t' read -r stored_hash prev_passes <<<"$_jq_result"
		[[ -n "$stored_hash" ]] || stored_hash=""
		[[ "$prev_passes" =~ ^[0-9]+$ ]] || prev_passes=0

		# Also fix any non-SHA1 hashes (wrong algorithm, t1754)
		local stored_len=${#stored_hash}
		if [[ "$current_hash" != "$stored_hash" || "$stored_len" -ne 40 ]]; then
			local now_iso new_passes
			now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
			new_passes=$((prev_passes + 1))
			local inner_tmp
			inner_tmp=$(mktemp)
			jq --arg fp "$fp" --arg hash "$current_hash" --arg at "$now_iso" \
				--argjson passes "$new_passes" \
				'.files[$fp].hash = $hash | .files[$fp].at = $at | .files[$fp].passes = $passes' \
				"$tmp_state" >"$inner_tmp" 2>/dev/null && mv "$inner_tmp" "$tmp_state" || rm -f "$inner_tmp"
			refreshed=$((refreshed + 1))
		fi
	done <<<"$file_paths"

	if [[ "$refreshed" -gt 0 ]]; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
	fi
	echo "$refreshed"
	return 0
}

# Prune stale entries from simplification state (files that no longer exist).
# This handles file moves/renames/deletions — entries for non-existent files
# are removed so they don't cause false "recheck" status or accumulate.
# Arguments: $1 - repo_path, $2 - state_file path
# Returns: 0 = pruned (or nothing to prune), 1 = error
# Outputs to stdout: number of entries pruned
_simplification_state_prune() {
	local repo_path="$1"
	local state_file="$2"

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	local all_paths
	all_paths=$(jq -r '.files | keys[]' "$state_file" 2>/dev/null) || {
		echo "0"
		return 1
	}

	local pruned=0
	local stale_paths=""
	while IFS= read -r file_path; do
		[[ -z "$file_path" ]] && continue
		local full_path="${repo_path}/${file_path}"
		if [[ ! -f "$full_path" ]]; then
			stale_paths="${stale_paths}${file_path}\n"
			pruned=$((pruned + 1))
		fi
	done <<<"$all_paths"

	if [[ "$pruned" -gt 0 ]]; then
		local tmp_file
		tmp_file=$(mktemp)
		# Build a JSON array of stale paths and remove all in one jq pass using
		# --argjson. Building a jq filter by string concatenation is fragile:
		# paths containing quotes or special characters cause syntax errors and
		# are a potential injection vector (GH#18555).
		local stale_paths_json
		stale_paths_json=$(printf '%b' "$stale_paths" | jq -R . | jq -s .)
		jq --argjson paths "${stale_paths_json:-[]}" \
			'reduce $paths[] as $p (.; del(.files[$p]))' \
			"$state_file" >"$tmp_file" 2>/dev/null || {
			# Fallback: remove entries one at a time using safe --arg (not string concat)
			cp "$state_file" "$tmp_file"
			while IFS= read -r sp; do
				[[ -z "$sp" ]] && continue
				local tmp2
				tmp2=$(mktemp)
				jq --arg fp "$sp" 'del(.files[$fp])' "$tmp_file" >"$tmp2" 2>/dev/null && mv "$tmp2" "$tmp_file" || rm -f "$tmp2"
			done < <(printf '%b' "$stale_paths")
		}
		mv "$tmp_file" "$state_file" || {
			rm -f "$tmp_file"
			echo "0"
			return 1
		}
	fi

	echo "$pruned"
	return 0
}

# Publish simplification state without mutating the source checkout.
# Arguments: $1 - repo_path, $2 - optional isolated state source
_simplification_state_push() {
	local repo_path="$1"
	local state_source="${2:-}"
	local state_rel=".agents/configs/simplification-state.json"
	local module_dir="${BASH_SOURCE[0]%/*}"
	local main_branch="" base_sha="" publication_rc=0

	if ! declare -F planning_publish >/dev/null 2>&1; then
		[[ "$module_dir" != "${BASH_SOURCE[0]}" ]] || module_dir="."
		module_dir=$(cd "$module_dir" && pwd) || return 1
		[[ -f "${module_dir}/planning-publisher.sh" ]] || return 1
		# shellcheck source=./planning-publisher.sh
		source "${module_dir}/planning-publisher.sh"
	fi
	main_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch=""
	main_branch="${main_branch:-main}"
	base_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null) || return 1

	AIDEVOPS_PLANNING_BASE_SHA="$base_sha" \
		AIDEVOPS_PLANNING_PUBLISH_SCOPE="simplification-state" \
		planning_publish "$repo_path" "chore: update simplification state registry" \
			origin "$main_branch" "$state_rel" "$state_source" || publication_rc=$?
	case "$publication_rc" in
	0) echo "[pulse-wrapper] simplification-state: ${PLANNING_PUBLISH_RESULT:-published} on $main_branch" >>"${LOGFILE:-/dev/null}" ;;
	2) echo "[pulse-wrapper] simplification-state: retryable publication conflict on $main_branch" >>"${LOGFILE:-/dev/null}" ;;
	*) echo "[pulse-wrapper] simplification-state: publication failed on $main_branch (rc=$publication_rc)" >>"${LOGFILE:-/dev/null}" ;;
	esac
	return "$publication_rc"
}

# Create a follow-up function-complexity-debt issue when Qlty smells persist after
# a simplification PR merges (t1912). Each re-queue creates a NEW issue (not a
# reopen) for a clean audit trail of each pass.
#
# Arguments:
#   $1 - aidevops_slug (owner/repo)
#   $2 - file_path (repo-relative)
#   $3 - remaining_smells (integer count)
#   $4 - pass_count (current pass number, already incremented)
#   $5 - prev_issue_num (the issue that just closed)
# Returns: 0 on success, 1 on failure. Outputs created issue number to stdout.
_create_requeue_issue() {
	local aidevops_slug="$1"
	local file_path="$2"
	local remaining_smells="$3"
	local pass_count="$4"
	local prev_issue_num="$5"
	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"

	# Determine tier based on pass count — escalate to thinking after max passes
	local tier_label="tier:standard"
	local escalation_note=""
	if [[ "$pass_count" -ge "$max_passes" ]]; then
		tier_label="tier:thinking"
		escalation_note="

### Escalation note

This file has been through ${pass_count} simplification passes but ${remaining_smells} Qlty smells remain. Previous passes achieved partial reduction but the remaining complexity likely requires **architectural decomposition** (extracting modules, splitting concerns) rather than incremental tightening. Consider a different approach than the previous passes took."
	fi

	local issue_title="simplification: re-queue ${file_path} (pass ${pass_count}, ${remaining_smells} smells remaining)"

	# NOTE: Uses IFS read instead of $(cat <<HEREDOC) to avoid Bash 3.2 bug
	# where literal ) inside a heredoc nested in $() is misinterpreted as
	# closing the command substitution. macOS ships Bash 3.2 by default.
	local issue_body
	IFS= read -r -d '' issue_body <<REQUEUE_BODY_EOF || true
<!-- aidevops:generator=function-complexity-gate cited_file=${file_path} threshold=${COMPLEXITY_FUNC_LINE_THRESHOLD:-100} -->

## Post-merge smell verification (automated — t1912)

**File:** \`${file_path}\`
**Qlty smells remaining:** ${remaining_smells}
**Pass:** ${pass_count} of ${max_passes} max
**Previous issue:** #${prev_issue_num}

The previous simplification pass (issue #${prev_issue_num}) merged successfully but Qlty still reports ${remaining_smells} smell(s) on this file. This follow-up issue was created automatically by the post-merge verification step.

### Context from previous pass

Review issue #${prev_issue_num} for what the previous attempt accomplished and what trade-offs were made. Build on that work rather than starting from scratch.

### Proposed action

1. Run \`~/.qlty/bin/qlty smells --all "${file_path}"\` to identify the specific remaining smells
2. Address the flagged complexity — reduce function length, extract helpers, simplify control flow
3. Verify: \`~/.qlty/bin/qlty smells --all 2>&1 | grep '${file_path}' | grep -c . | grep -q '^0$'\` (report \`SKIP\` if Qlty unavailable)${escalation_note}

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for file splits — covers orchestrator pattern, identity-key preservation, and PR body template).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). For shell scripts, copy the include-guard and SCRIPT_DIR-fallback pattern from the simple precedent.

**Expected CI gate overrides:** This PR may trigger a complexity regression from function extraction. Apply the \`complexity-bump-ok\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

### Verification

- Qlty smells resolved or reduced for the target file
- Content preservation: all task IDs, URLs, code blocks present before and after
- ShellCheck clean (for .sh files)
REQUEUE_BODY_EOF

	# Append signature footer
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "Claude Code" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	local created_number=""
	# shellcheck disable=SC2086
	created_number=$(gh_create_issue --repo "$aidevops_slug" \
		--title "$issue_title" \
		--label "function-complexity-debt" --label "$tier_label" --label "auto-dispatch" \
		--body "$issue_body" 2>/dev/null | grep -oE '[0-9]+$') || {
		echo "[pulse-wrapper] _create_requeue_issue: failed to create re-queue issue for ${file_path}" >>"$LOGFILE"
		return 1
	}

	echo "[pulse-wrapper] _create_requeue_issue: created #${created_number} for ${file_path} (pass ${pass_count}, ${remaining_smells} smells, ${tier_label})" >>"$LOGFILE"
	echo "$created_number"
	return 0
}

# Backfill simplification state for recently closed issues (t1855).
#
# The critical bug: _simplification_state_record() was defined but never called.
# Workers complete simplification PRs and issues auto-close via "Closes #NNN",
# but the state file never gets updated. This function runs each scan cycle
# to detect recently closed simplification issues and record their file hashes.
#
# Arguments: $1 - repo_path, $2 - state_file, $3 - aidevops_slug
# Returns: 0. Outputs count of entries added to stdout.
# ---------------------------------------------------------------------------
# Backfill helpers (GH#18680 — decomposition of
# _simplification_state_backfill_closed to keep the orchestrator under the
# 100-line function-complexity gate).
#
# Each helper is self-contained, side-effect-scoped (explicit args only), and
# preserves the behaviour of the original inline block byte-for-byte.
# ---------------------------------------------------------------------------

# Extract a repo-relative file path from a simplification issue title.
# Handles titles in all three forms produced by the complexity scanner:
#   "simplification: tighten agent doc <path> (<N> lines)"                        (no topic label)
#   "simplification: tighten agent doc <topic> (<path>, <N> lines)"               (topic label — path in parens)
#   "simplification: reduce function complexity in <path> (<N> functions ...)"    (function complexity)
# Arguments:
#   $1 - issue title (string)
# Outputs:
#   The first .md or .sh path found in the title, or empty if none.
# Returns: 0 always (empty output on no match is a normal signal).
#
# GH#19370: the topic-label form wraps the path in "(<path>, <N> lines)". The
# original character class excluded space/comma/close-paren but NOT open-paren,
# so it captured "(.agents/…" with a leading "(". The subsequent
# "[[ -f ${repo_path}/${file_path} ]] && continue" check in
# _simplification_state_backfill_closed then silently skipped every
# topic-labeled issue, so state never recorded these files and the scanner
# re-flagged them on every cycle (observed: 8 thrash cycles on
# shell-style-guide.md, 9 on pre-dispatch-validators.md over 2026-04-14…16).
# The fix excludes open-paren too, so all three title forms extract cleanly.
_simplification_backfill_extract_file_path() {
	local title="$1"
	# `|| true` swallows the pipefail that grep -o / head -1 raise when the
	# regex does not match — the caller distinguishes "no path" via empty
	# output, not exit code, so we must not propagate the failure.
	# Character class excludes: space, comma, open-paren, close-paren.
	# Open-paren exclusion is load-bearing — see GH#19370 rationale above.
	printf '%s\n' "$title" | grep -oE '[^ ,()]+\.(md|sh)' | head -1 || true
	return 0
}

# Record (or refresh) a file's entry in the in-progress tmp_state JSON.
# Bumps the pass counter, stamps the current hash, and sets the merged PR/
# issue number and timestamp. The mutation is staged into a second temp file
# and atomically renamed over tmp_state so a mid-jq failure cannot corrupt
# the in-progress state.
# Arguments:
#   $1 - tmp_state path (will be mutated in place on success)
#   $2 - file_path (repo-relative)
#   $3 - current_hash (git hash-object of the file)
#   $4 - issue_num (merged simplification issue number)
#   $5 - now_iso (optional; ISO 8601 timestamp; computed via date if absent)
# Outputs:
#   new_passes (integer, previous passes + 1) on success.
# Returns: 0 on successful mutation, 1 if jq failed (tmp_state untouched).
_simplification_backfill_update_entry_state() {
	local tmp_state="$1"
	local file_path="$2"
	local current_hash="$3"
	local issue_num="$4"

	local now_iso prev_passes new_passes
	now_iso="${5:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
	prev_passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$tmp_state" 2>/dev/null) || prev_passes=0
	new_passes=$((prev_passes + 1))

	local inner_tmp
	inner_tmp=$(mktemp)
	if jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" \
		--argjson pr "$issue_num" --argjson passes "$new_passes" \
		'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr, "passes": $passes}' \
		"$tmp_state" >"$inner_tmp" 2>/dev/null; then
		mv "$inner_tmp" "$tmp_state"
		echo "$new_passes"
		return 0
	fi
	rm -f "$inner_tmp"
	return 1
}

# Post-merge smell verification (t1912): after we record a merged
# simplification PR, probe the file with Qlty and, if smells persist, open a
# re-queue issue so the file gets another pass. Qlty CLI is optional — if
# not installed, this step is skipped silently and the function behaves as
# a no-op.
# Arguments:
#   $1 - repo_path       (absolute worktree path)
#   $2 - file_path       (repo-relative)
#   $3 - aidevops_slug   (owner/repo for issue creation)
#   $4 - new_passes      (pass counter after this merge, from update_entry_state)
#   $5 - issue_num       (merged simplification issue number)
# Side effects:
#   - Writes one line to $LOGFILE describing the outcome (clean / re-queued
#     / skipped duplicate) when Qlty is available.
	#   - May call _create_requeue_issue (defined earlier in this file) to open
	#     a follow-up function-complexity-debt issue.
# Returns: 0 always (this is an advisory step; failures should not abort
#          the surrounding backfill loop).
_simplification_backfill_verify_remaining_smells() {
	local repo_path="$1"
	local file_path="$2"
	local aidevops_slug="$3"
	local new_passes="$4"
	local issue_num="$5"

	local qlty_cmd=""
	if command -v qlty >/dev/null 2>&1; then
		qlty_cmd="qlty"
	elif [[ -x "${HOME}/.qlty/bin/qlty" ]]; then
		qlty_cmd="${HOME}/.qlty/bin/qlty"
	fi
	[[ -z "$qlty_cmd" ]] && return 0

	local full_path="${repo_path}/${file_path}"
	local remaining_smells
	# grep -c always emits a count on stdout; when there are zero matches it
	# ALSO exits non-zero. A naive `|| echo "0"` fallback appends a second
	# "0", giving us a literal "0\n0" in $remaining_smells. That string then
	# fails the `-eq 0` test below and cascades into a spurious re-queue
	# issue with "0\n0 smells remaining" in the title (seen on GH#18809,
	# #18829, #18796, #18797, #18798, #18799 — every file Qlty reported
	# clean generated a false-positive follow-up). Fix: swallow grep's exit
	# code inside a group command WITHOUT emitting any extra output, then
	# defensively normalise to a single integer before comparison.
	remaining_smells=$("$qlty_cmd" smells --all "$full_path" 2>/dev/null | { grep -c '^[^ ]' || true; })
	remaining_smells=$(printf '%s' "$remaining_smells" | tr -d '[:space:]')
	[[ ! "$remaining_smells" =~ ^[0-9]+$ ]] && remaining_smells=0

	if [[ "$remaining_smells" -eq 0 ]]; then
		echo "[pulse-wrapper] backfill: ${file_path} — Qlty clean after #${issue_num} (pass ${new_passes})" >>"$LOGFILE"
		return 0
	fi

	# Smells persist. Check for an existing open re-queue issue before
	# creating a new one to avoid duplicate-issue noise.
	if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
		echo "[pulse-wrapper] backfill: ${file_path} has ${remaining_smells} smells after #${issue_num} but open issue already exists — skipping re-queue" >>"$LOGFILE"
		return 0
	fi

	local requeue_result=""
	requeue_result=$(_create_requeue_issue "$aidevops_slug" "$file_path" "$remaining_smells" "$new_passes" "$issue_num") || true
	if [[ -n "$requeue_result" ]]; then
		echo "[pulse-wrapper] backfill: re-queued ${file_path} → #${requeue_result} (${remaining_smells} smells remain after #${issue_num})" >>"$LOGFILE"
	fi
	return 0
}

# Main backfill orchestrator. Scans recently-closed function-complexity-debt
# issues, records any whose underlying file has drifted from the known
# state, and (via _simplification_backfill_verify_remaining_smells) opens
# follow-up issues when Qlty smells persist post-merge.
#
# Decomposed in GH#18680 from a 107-line inline implementation; the public
# contract (args, stdout, return code, state-file mutations, log lines) is
# unchanged from the pre-decomposition form.
#
# Arguments:
#   $1 - repo_path       (absolute worktree path)
#   $2 - state_file      (absolute path to simplification-state.json)
#   $3 - aidevops_slug   (owner/repo for gh issue queries)
# Outputs:
#   "added" integer (count of files whose state entry was updated) to stdout.
# Returns: 0 always.
_simplification_state_backfill_closed() {
	local repo_path="$1"
	local state_file="$2"
	local aidevops_slug="$3"
	local added=0 now_iso
	# Compute timestamp once here — loop-invariant, passed to the helper to
	# avoid a date(1) subprocess per issue iteration.
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Fetch recently closed function-complexity-debt issues (last 7 days, max 50).
	local closed_issues
	closed_issues=$(gh_issue_list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state closed \
		--limit 50 --json number,title,closedAt 2>/dev/null) || {
		echo "0"
		return 0
	}
	[[ -z "$closed_issues" || "$closed_issues" == "[]" ]] && {
		echo "0"
		return 0
	}

	local tmp_state
	tmp_state=$(mktemp)
	cp "$state_file" "$tmp_state"

	# Process substitution (not a pipe) so $added propagates out of the loop
	# (t1855 subshell variable propagation bug).
	while IFS= read -r issue; do
		[[ -z "$issue" ]] && continue
		local title file_path issue_num

		# Single jq pass for both fields — halves subprocess count per iteration.
		# GH#19044: command substitution + here-string instead of process
		# substitution to avoid FD leaks in bash 3.2.
		local _issue_fields
		_issue_fields=$(printf '%s\n' "$issue" | jq -r '[.title // "", .number // ""] | @tsv' 2>/dev/null) || _issue_fields=""
		IFS=$'\t' read -r title issue_num <<<"$_issue_fields"
		[[ -z "$title" || -z "$issue_num" ]] && continue

		file_path=$(_simplification_backfill_extract_file_path "$title")
		[[ -z "$file_path" ]] && continue

		# Skip if the file no longer exists in the worktree.
		[[ ! -f "${repo_path}/${file_path}" ]] && continue

		# Skip if already recorded at the current hash (nothing to backfill).
		local existing_hash current_hash
		existing_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$tmp_state" 2>/dev/null) || existing_hash=""
		current_hash=$(git -C "$repo_path" hash-object "${repo_path}/${file_path}" 2>/dev/null) || continue
		[[ "$existing_hash" == "$current_hash" ]] && continue

		# Record the file in state — either new entry or updated hash.
		local new_passes
		new_passes=$(_simplification_backfill_update_entry_state \
			"$tmp_state" "$file_path" "$current_hash" "$issue_num" "$now_iso") || continue
		added=$((added + 1))

		# Advisory post-merge smell verification. Failures here never abort
		# the loop; the helper always returns 0.
		_simplification_backfill_verify_remaining_smells \
			"$repo_path" "$file_path" "$aidevops_slug" "$new_passes" "$issue_num"
	done < <(echo "$closed_issues" | jq -c '.[]')

	if [[ "$added" -gt 0 ]]; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
	fi
	echo "$added"
	return 0
}

# Defensive auto-close sweep for spurious "0 smells remaining" re-queue
# issues (GH#18795). The pre-PR-#18848 grep-c bug in
# _simplification_backfill_verify_remaining_smells produced literal "0\n0"
# strings that failed the -eq 0 test and cascaded into re-queue issues for
# files Qlty had already reported clean. PR #18848 fixed the bug, but
# stragglers from before that fix landed lingered in the open backlog and
# burned worker dispatches (#18796, #18797, #18798, #18799, #18809, #18829).
#
# This sweep runs each pulse cycle and closes any open re-queue issue where
# BOTH conditions hold:
#   1. The title contains "(pass N, ... 0 smells remaining)" — the
#      diagnostic signature of the bug. Tolerates the "0\n0" newline-
#      corrupted form by stripping whitespace before matching.
#   2. The target file currently has zero Qlty smells per a fresh probe.
#      The probe is the gate — if Qlty reports any smells the issue is
#      legitimate (rare title coincidence) and is left open.
#
# Both conditions are required so a buggy title alone never auto-closes a
# legitimate finding. The function is a no-op when Qlty is not installed.
#
# Arguments:
#   $1 - repo_path      (absolute worktree path)
#   $2 - aidevops_slug  (owner/repo for issue queries/closures)
# Outputs:
#   Integer count of issues closed to stdout.
# Side effects:
#   - One log line per close attempt (success or failure) to $LOGFILE.
#   - Closes matching issues with reason "not planned" plus a rationale
#     comment that links to PR #18848 (the original fix) and #18795 (the
#     defensive sweep itself).
# Returns: 0 always (advisory step; failures must not abort the surrounding
#          state-refresh stage).
_simplification_close_spurious_requeue_issues() {
	local repo_path="$1"
	local aidevops_slug="$2"
	local closed=0

	# Locate qlty CLI; bail silently if unavailable. The sweep is purely
	# defensive — when Qlty is missing we cannot verify the smell count
	# and must leave issues alone rather than risk closing a legitimate
	# finding.
	local qlty_cmd=""
	if command -v qlty >/dev/null 2>&1; then
		qlty_cmd="qlty"
	elif [[ -x "${HOME}/.qlty/bin/qlty" ]]; then
		qlty_cmd="${HOME}/.qlty/bin/qlty"
	fi
	[[ -z "$qlty_cmd" ]] && {
		echo "0"
		return 0
	}

	# Query open re-queue issues. The bug-corrupted titles contain a
	# literal newline which `gh issue list --search` cannot match across,
	# so we fetch all open function-complexity-debt issues and filter client-
	# side. The list is bounded by SIMPLIFICATION_OPEN_CAP (~50 typical),
	# so the cost is O(N) gh API calls in the worst case but typically 0.
	local issues_json
	issues_json=$(gh_issue_list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state open \
		--limit 100 --json number,title 2>/dev/null) || {
		echo "0"
		return 0
	}
	[[ -z "$issues_json" || "$issues_json" == "[]" ]] && {
		echo "0"
		return 0
	}

	while IFS= read -r row; do
		[[ -z "$row" ]] && continue
		local num title
		num=$(echo "$row" | jq -r '.number') || continue
		title=$(echo "$row" | jq -r '.title') || continue

		# Strip whitespace (incl. embedded \n from the corrupted form)
		# before pattern-matching. The diagnostic signature is the
		# literal phrase "0 smells remaining" inside a "(pass N, ...)"
		# parenthetical.
		local stripped_title
		stripped_title=$(printf '%s' "$title" | tr -d '[:space:]')
		[[ ! "$stripped_title" =~ \(pass[0-9]+,0+smellsremaining\) ]] && continue

		# Extract the file path from the title and verify Qlty currently
		# reports zero smells before closing. Reuse the existing helper
		# so any future title-format change stays consistent.
		local file_path
		file_path=$(_simplification_backfill_extract_file_path "$title")
		[[ -z "$file_path" ]] && continue
		[[ ! -f "${repo_path}/${file_path}" ]] && continue

		# Probe Qlty using the same defensive count pattern as
		# _simplification_backfill_verify_remaining_smells (the post-
		# #18848 form). Anything other than a clean "0" leaves the
		# issue open.
		local current_smells
		current_smells=$("$qlty_cmd" smells "${repo_path}/${file_path}" 2>/dev/null | { grep -c '^[^ ]' || true; })
		current_smells=$(printf '%s' "$current_smells" | tr -d '[:space:]')
		[[ ! "$current_smells" =~ ^[0-9]+$ ]] && current_smells=0
		[[ "$current_smells" -ne 0 ]] && continue

		# Both conditions hold: title says "0 smells remaining" AND the
		# fresh probe confirms zero smells. Close as spurious.
		local close_comment
		close_comment="Auto-closed by simplification-state spurious-sweep (GH#18795).

\`${file_path}\` currently has zero Qlty smells. This re-queue issue was generated by the pre-PR-#18848 \`grep -c\` bug in \`_simplification_backfill_verify_remaining_smells\` (\`pulse-simplification-state.sh\`) which produced a literal \`0\\n0\` string for files Qlty reported clean and then failed the \`-eq 0\` test. The bug is fixed in commit 625c6da5e (PR #18848); this sweep cleans up stragglers and self-heals any future regression of the same class."

		if gh issue close "$num" --repo "$aidevops_slug" \
			--reason "not planned" \
			--comment "$close_comment" >/dev/null 2>&1; then
			echo "[pulse-wrapper] spurious-sweep: closed #${num} (${file_path}, 0 smells)" >>"$LOGFILE"
			closed=$((closed + 1))
		else
			echo "[pulse-wrapper] spurious-sweep: failed to close #${num} (${file_path})" >>"$LOGFILE"
		fi
	done < <(echo "$issues_json" | jq -c '.[]')

	echo "$closed"
	return 0
}
