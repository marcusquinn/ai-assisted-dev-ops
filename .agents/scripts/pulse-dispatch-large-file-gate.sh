#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-large-file-gate.sh — Large-file simplification gate — blocks dispatch when issue targets files exceeding LARGE_FILE_LINE_THRESHOLD and creates file-size-debt issues.
#
# Extracted from pulse-dispatch-core.sh (GH#18832) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh and worker-lifecycle-common.sh being sourced first.
#
# Functions in this module (in source order):
#   - _large_file_gate_precheck_labels
#   - _large_file_gate_extract_paths
#   - _large_file_gate_evaluate_target
#   - _large_file_gate_create_debt_issue
#   - _large_file_gate_apply
#   - _large_file_gate_clear_stale_label
#   - _large_file_gate_issue_labels
#   - _issue_targets_large_files

[[ -n "${_PULSE_DISPATCH_LARGE_FILE_GATE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_LARGE_FILE_GATE_LOADED=1

# Module-level skip pattern used by the large-file gate — files that are
# large by nature and can't/shouldn't be "simplified" (lockfiles, generated
# data, JSON/YAML configs, binary-adjacent formats). GH#17897: also skips
# data files (.json/.yaml/.yml/.toml/.xml/.csv) which are config, not code.
_LFG_SKIP_PATTERN='(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|Gemfile\.lock|poetry\.lock|simplification-state\.json|\.min\.(js|css)$|\.json$|\.yaml$|\.yml$|\.toml$|\.xml$|\.csv$)'

# t2713: Module-level return variable for _large_file_gate_check_surgical_brief.
# Holds a comma-separated list of exempted file basenames when the surgical-brief
# exemption fires; reset to "" at the start of each call.
_LFG_SURGICAL_EXEMPTED_FILES=""

# Module-level return variables for _large_file_gate_collect_large_files.
# These avoid fragile delimiter parsing for path lists while keeping
# _issue_targets_large_files() as a thin orchestrator.
_LFG_FOUND_LARGE=false
_LFG_LARGE_FILES=""
_LFG_LARGE_FILE_PATHS=""

#######################################
# Label-based early-exit precheck for the large-file gate.
# Handles GH#18042 self-simplification auto-clear, force_recheck bypass,
# already-labeled short-circuit, already-dispatched skips, and origin:worker
# race-window guard.
#
# Arguments: issue_number, repo_slug, issue_labels (comma-joined), force_recheck
# Exit codes:
#   0 - continue to path extraction
#   1 - caller should `return 1` (no gate, don't re-check)
#   2 - caller should `return 0` (gate already applied, short-circuit)
#######################################
_large_file_gate_precheck_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_labels="$3"
	local force_recheck="$4"

	# GH#18042: Never gate simplification tasks behind the large-file gate.
	# Issues tagged "simplification", "file-size-debt", or "function-complexity-debt"
	# exist to reduce the file — blocking them creates a deadlock where the file
	# can never be simplified because the simplification issue is held by the gate.
	# "simplification-debt" kept for backward compat during label migration.
	# If the label was already applied (e.g., before this fix), auto-clear it.
	if [[ ",$issue_labels," == *",simplification,"* ]] ||
		[[ ",$issue_labels," == *",file-size-debt,"* ]] ||
		[[ ",$issue_labels," == *",function-complexity-debt,"* ]] ||
		[[ ",$issue_labels," == *",simplification-debt,"* ]]; then
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "needs-simplification" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Simplification gate auto-cleared for #${issue_number} (${repo_slug}) — issue is itself a simplification task (GH#18042)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] WARN: failed to remove needs-simplification label from #${issue_number} (${repo_slug}); will retry next cycle (GH#18042)" >>"$LOGFILE"
			fi
		fi
		# Always return 1 (don't gate) — the issue IS simplification work
		# regardless of whether the label removal succeeded.
		return 1
	fi

	# t2088: Never gate parent-task / meta issues behind the large-file gate.
	# Parent tasks are never dispatched directly — dispatch is unconditionally
	# blocked by _is_assigned_check_parent_task() in dispatch-dedup-helper.sh
	# (t1986). Applying needs-simplification to them creates confusing label
	# churn: the label is re-added every cycle even after manual removal because
	# the target file is still large, misleading maintainers into thinking
	# simplification is the only remaining gate when in fact the parent-task
	# block is permanent and independent of file size.
	# If the label was already applied (e.g., before this fix), auto-clear it.
	if [[ ",$issue_labels," == *",parent-task,"* ]] ||
		[[ ",$issue_labels," == *",meta,"* ]]; then
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "needs-simplification" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Simplification gate auto-cleared for #${issue_number} (${repo_slug}) — issue is a parent-task/meta, never dispatched directly (t2088)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] WARN: failed to remove needs-simplification label from #${issue_number} (${repo_slug}); will retry next cycle (t2088)" >>"$LOGFILE"
			fi
		fi
		# Always return 1 (don't gate) — parent tasks are never dispatched
		# directly, regardless of whether the label removal succeeded.
		return 1
	fi

	# Skip if already labeled (avoid re-checking every cycle).
	# EXCEPTION (t1998): when called from _reevaluate_simplification_labels,
	# force_recheck is "true" and we bypass this short-circuit. Without the
	# bypass, the re-eval path can never clear a stale label because it
	# always sees an immediate return 0 on labeled issues. This made
	# #18346 and any similar stale issue impossible to unstick even after
	# the target file had been simplified below threshold.
	if [[ "$force_recheck" != "true" ]] &&
		[[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		return 2
	fi
	# Skip if simplification was already done
	if [[ ",$issue_labels," == *",simplified,"* ]]; then
		return 1
	fi

	# GH#17958: Skip if issue is already dispatched (worker actively running).
	# A second pulse cycle can re-evaluate the same issue and post a spurious
	# simplification comment even though the worker is mid-implementation.
	# The gate should only fire for issues that haven't been claimed yet.
	if [[ ",$issue_labels," == *",status:queued,"* ]] ||
		[[ ",$issue_labels," == *",status:in-progress,"* ]]; then
		return 1
	fi
	# Also skip if assigned with origin:worker — worker was dispatched even if
	# status label hasn't been applied yet (race window between assign and label).
	if [[ ",$issue_labels," == *",origin:worker,"* ]]; then
		local assignee_count
		assignee_count=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json assignees --jq '.assignees | length' 2>/dev/null) || assignee_count="0"
		if [[ "$assignee_count" -gt 0 ]]; then
			return 1
		fi
	fi

	return 0
}

#######################################
# Extract candidate file paths from an issue body, preserving any trailing
# ":NNN" or ":START-END" line qualifiers (t2024). Combines two extractors:
#   1. "EDIT:" / "NEW:" / "File:" markers referencing agents/scripts paths.
#   2. Backtick-quoted script paths on lines that ALSO carry an
#      "EDIT:" / "NEW:" / "File:" intent prefix (t2164 — list-item
#      backtick paths without an intent prefix are context references,
#      not edit targets, and must not trigger the gate).
# Prints deduplicated, non-empty paths to stdout (one per line).
#######################################
_large_file_gate_extract_paths() {
	local issue_body="$1"

	# t2024: Preserve any trailing ":NNN" or ":START-END" line qualifier so
	# the gate loop below can distinguish scoped ranges from whole-file targets.
	# Previously this extractor stripped the qualifier via `sed 's/:.*//'`,
	# which threw away the one piece of information needed to tell "targeted
	# edit in a 30-line range" from "rewrite the whole 3000-line file".
	local file_paths
	# shellcheck disable=SC2016  # `\s` is grep-regex escape, not shell expansion.
	file_paths=$(printf '%s' "$issue_body" | grep -oE '(EDIT|NEW|File):?\s+[`"]?\.?agents/scripts/[^`"[:space:],]+' 2>/dev/null |
		sed 's/^[A-Z]*:*[[:space:]]*//' | sed 's/^[`"]//' | sed 's/[`"]*$//' | sort -u) || file_paths=""

	# t2164: Match backtick paths only when the line carries an explicit
	# edit-intent prefix (`EDIT:` / `NEW:` / `File:`). The previous regex
	# (`^\s*[-*]\s|^(EDIT|NEW|File):`) matched ANY backtick path on a
	# `-`-list item, which conflated edit targets with context references.
	# Brief authors routinely cite related files for investigation context
	# (e.g. as `grep -rn` search targets), and those citations were tripping
	# the gate. The `EDIT:`/`NEW:`/`File:` markers are the documented
	# convention for declaring edit intent (see templates/brief-template.md);
	# the gate now trusts them rather than guessing from list-item structure.
	#
	# Forms still matched after t2164:
	#   EDIT: `pulse-triage.sh`
	#   - EDIT: `pulse-triage.sh:255-330`
	#   NEW: `tests/test-foo.sh`
	#   File: `pulse-wrapper.sh`
	#
	# Forms NO LONGER matched (correctly, these are context refs):
	#   - `pulse-triage.sh` — search target for grep
	#   * `path/to/file.sh` (mentioned in passing)
	#
	# t2024: Also preserve line qualifiers here. A list-item reference like
	#   - EDIT: `pulse-ancillary-dispatch.sh:221-253`
	# should be parsed as "file + range", not stripped to bare "file".
	local backtick_paths
	# shellcheck disable=SC2016  # Backtick chars in regex are literals, not command subst.
	backtick_paths=$(printf '%s' "$issue_body" | grep -E '^\s*[-*]\s+(EDIT|NEW|File):|^(EDIT|NEW|File):' 2>/dev/null |
		grep -oE '`[^`]*\.(sh|py|js|ts)[^`]*`' 2>/dev/null |
		tr -d '`' | grep -v '^#' | sort -u) || backtick_paths=""

	printf '%s\n%s' "$file_paths" "$backtick_paths" | sort -u | grep -v '^$' || true
	return 0
}

#######################################
# Evaluate one candidate target against the large-file threshold.
# Parses an optional "file:NNN" or "file:START-END" qualifier (t2024),
# applies the skip-pattern filter, resolves the path relative to the repo
# (checking bare, .agents/, and .-prefixed variants), handles single-line
# and scoped-range citations, then compares `wc -l` to LARGE_FILE_LINE_THRESHOLD.
#
# Arguments: raw_target, repo_path, issue_number
# Stdout: "fpath|line_count" when the file exceeds threshold (exit 0)
# Exit codes:
#   0 - file is large, output emitted on stdout
#   1 - file is under threshold
#   2 - target was skipped (invalid, missing, skip-pattern, single-line, scoped-range)
#######################################
_large_file_gate_evaluate_target() {
	local raw_target="$1"
	local repo_path="$2"
	local issue_number="$3"
	[[ -n "$raw_target" ]] || return 2

	# t2024: Parse optional line qualifier off the end of the target.
	#   "file.sh"            → fpath="file.sh", line_spec=""
	#   "file.sh:1477"       → fpath="file.sh", line_spec="1477"
	#   "file.sh:221-253"    → fpath="file.sh", line_spec="221-253"
	# Only accept a line qualifier when it's numeric (optionally ranged).
	# Anything else (colons inside shell-safe paths, rare but possible)
	# is preserved as part of the path.
	local fpath="$raw_target"
	local line_spec=""
	if [[ "$raw_target" =~ ^(.+):([0-9]+(-[0-9]+)?)$ ]]; then
		fpath="${BASH_REMATCH[1]}"
		line_spec="${BASH_REMATCH[2]}"
	fi

	# Skip non-simplifiable files (lockfiles, generated data, configs)
	local basename_fpath
	basename_fpath=$(basename "$fpath")
	if printf '%s' "$basename_fpath" | grep -qE "$_LFG_SKIP_PATTERN" 2>/dev/null; then
		return 2
	fi

	# Resolve path relative to repo
	local full_path=""
	if [[ -f "${repo_path}/${fpath}" ]]; then
		full_path="${repo_path}/${fpath}"
	elif [[ -f "${repo_path}/.agents/${fpath}" ]]; then
		full_path="${repo_path}/.agents/${fpath}"
	elif [[ -f "${repo_path}/.${fpath}" ]]; then
		full_path="${repo_path}/.${fpath}"
	else
		return 2
	fi

	# t2024: scoped-range and single-line qualifier handling.
	#
	# 1. Single-line references (no range) are context for the human
	#    reader — they help locate the bug but do not describe an edit
	#    target. Skip them for gate evaluation entirely.
	# 2. Ranged references that fit inside SCOPED_RANGE_THRESHOLD bypass
	#    the file-size check — the worker only navigates the cited range.
	# 3. Anything else (no qualifier, or range too large) falls through
	#    to the file-size check as before.
	if [[ "$line_spec" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Large-file gate: #${issue_number} skipping ${fpath}:${line_spec} (single-line citation — context reference, not edit target)" >>"$LOGFILE"
		return 2
	fi
	if [[ "$line_spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
		local _range_start="${BASH_REMATCH[1]}"
		local _range_end="${BASH_REMATCH[2]}"
		local _range_size=$((_range_end - _range_start + 1))
		if [[ "$_range_size" -gt 0 && "$_range_size" -le "$SCOPED_RANGE_THRESHOLD" ]]; then
			echo "[pulse-wrapper] Large-file gate: #${issue_number} scoped-range pass for ${fpath}:${line_spec} (${_range_size} lines, threshold ${SCOPED_RANGE_THRESHOLD})" >>"$LOGFILE"
			return 2
		fi
	fi

	local line_count=0
	line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
	if [[ "$line_count" -ge "$LARGE_FILE_LINE_THRESHOLD" ]]; then
		printf '%s|%s\n' "$fpath" "$line_count"
		return 0
	fi
	return 1
}

#######################################
# t2164 helper — resolve a large-file path against the repo_path, checking
# bare, .agents/-prefixed, and .-prefixed variants (mirrors
# _large_file_gate_evaluate_target). Prints the resolved full path on stdout
# and returns 0 when found; returns 1 and prints nothing otherwise.
#######################################
_large_file_gate_resolve_full_path() {
	local lf_path="$1"
	local repo_path="$2"
	if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
		return 1
	fi
	if [[ -f "${repo_path}/${lf_path}" ]]; then
		printf '%s' "${repo_path}/${lf_path}"
		return 0
	fi
	if [[ -f "${repo_path}/.agents/${lf_path}" ]]; then
		printf '%s' "${repo_path}/.agents/${lf_path}"
		return 0
	fi
	if [[ -f "${repo_path}/.${lf_path}" ]]; then
		printf '%s' "${repo_path}/.${lf_path}"
		return 0
	fi
	return 1
}

#######################################
# Read the cited file's line count from the repository's current default
# branch. This is the authoritative fallback when a runner's local checkout
# may still predate a merged simplification PR.
# Arguments: repo_slug, lf_path
# Stdout: non-negative line count
# Returns: 0 when verified, 1 when remote content is unavailable
#######################################
_large_file_gate_remote_default_line_count() {
	local repo_slug="$1"
	local lf_path="$2"
	local default_branch=""
	local content_json=""
	local line_count=""

	[[ "$repo_slug" == */* && -n "$lf_path" ]] || return 1
	default_branch=$(gh api "repos/${repo_slug}" --jq '.default_branch // empty' 2>/dev/null) || return 1
	[[ -n "$default_branch" ]] || return 1
	content_json=$(gh api --method GET "repos/${repo_slug}/contents/${lf_path}" \
		-f "ref=${default_branch}" 2>/dev/null) || return 1
	line_count=$(printf '%s' "$content_json" | jq -er '
		select(.type == "file" and .encoding == "base64" and (.content | type) == "string")
		| (.content | gsub("\\s"; "") | @base64d) as $text
		| if ($text | length) == 0 then 0
		  else (($text | split("\n") | length) - (if ($text | endswith("\n")) then 1 else 0 end))
		  end
	' 2>/dev/null) || return 1
	[[ "$line_count" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$line_count"
	return 0
}

#######################################
# Verify that a local repository is currently at the remote default-branch
# commit. Large-file measurements are unsafe when this check fails because a
# just-merged split may not exist in the runner's canonical checkout yet.
# Arguments: repo_path
# Returns: 0 when exact, 1 when stale or unverifiable
#######################################
_large_file_gate_repo_matches_remote_default() {
	local repo_path="$1"
	local default_branch=""
	local current_branch=""
	local local_sha=""
	local remote_line=""
	local remote_sha=""

	[[ -n "$repo_path" ]] || return 1
	default_branch=$(git -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
	default_branch="${default_branch#origin/}"
	[[ -n "$default_branch" ]] || return 1
	current_branch=$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
	[[ "$current_branch" == "$default_branch" ]] || return 1
	local_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null) || return 1
	remote_line=$(git -C "$repo_path" ls-remote --heads origin "refs/heads/${default_branch}" 2>/dev/null) || return 1
	[[ -n "$remote_line" && "$remote_line" != *$'\n'* ]] || return 1
	remote_sha="${remote_line%%[[:space:]]*}"
	[[ "$remote_sha" =~ ^[0-9a-fA-F]{40}$ && "$local_sha" == "$remote_sha" ]]
	return $?
}

#######################################
# t2164 — verify whether a closed file-size-debt issue's PR actually
# reduced the file below threshold. Returns:
#   0 — "continuation is valid" (current default branch is under threshold OR
#       authoritative measurement is unavailable; caller should not reopen)
#   1 — current default branch is still over threshold; caller should reopen
#       the canonical debt issue, and this helper logged the decision
#
# t2169: When the issue carries the `simplification-incomplete` label
# (applied by the Simplification Outcome Check workflow when a merged PR
# left the file over threshold), short-circuit immediately with return 1
# without running wc -l. The label is definitive evidence of an incomplete
# simplification — the wc -l would reach the same conclusion but this
# path is faster and avoids a disk read on every gate evaluation.
#
# Arguments: existing_issue_num, lf_path, repo_path, repo_slug (optional)
#######################################
_large_file_gate_verify_prior_reduced_size() {
	local existing_issue="$1"
	local lf_path="$2"
	local repo_path="$3"
	local repo_slug="${4:-}"

	# t2169: short-circuit on simplification-incomplete label — definitive
	# evidence that the prior merged PR did not reduce the file below threshold.
	# Skip wc -l entirely when the label is present.
	if [[ -n "$repo_slug" && -n "$existing_issue" ]]; then
		local _sc_labels=""
		_sc_labels=$(gh_issue_view "$existing_issue" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || _sc_labels=""
		if [[ ",$_sc_labels," == *",simplification-incomplete,"* ]]; then
			echo "[pulse-wrapper] Large-file gate: prior issue #${existing_issue} has simplification-incomplete label; reopening canonical debt issue (outcome-check short-circuit)" >>"$LOGFILE"
			return 1
		fi
	fi

	local _verify_full_path
	_verify_full_path=$(_large_file_gate_resolve_full_path "$lf_path" "$repo_path") || _verify_full_path=""

	if [[ -z "$_verify_full_path" ]]; then
		# Couldn't resolve path — preserve pre-t2164 behaviour: trust the
		# closed-issue signal (safer than creating noisy duplicates when
		# measurement is unavailable, e.g. running outside a checkout).
		return 0
	fi

	local _verify_lines=0
	_verify_lines=$(wc -l <"$_verify_full_path" 2>/dev/null | tr -d ' ') || _verify_lines=0

	if [[ "$_verify_lines" -gt 0 && "$_verify_lines" -lt "$LARGE_FILE_LINE_THRESHOLD" ]]; then
		# Prior PR genuinely reduced the file below threshold.
		return 0
	fi
	if [[ "$_verify_lines" -ge "$LARGE_FILE_LINE_THRESHOLD" ]]; then
		# A local checkout can lag a just-merged simplification PR even after the
		# best-effort canonical refresh. Never reopen a solved debt issue from
		# stale disk state: verify the current remote default-branch blob first.
		local _remote_lines=""
		_remote_lines=$(_large_file_gate_remote_default_line_count "$repo_slug" "$lf_path") || _remote_lines=""
		if [[ -z "$_remote_lines" ]]; then
			echo "[pulse-wrapper] Large-file gate: local ${lf_path} is ${_verify_lines} lines but current remote content could not be verified; deferring canonical debt reopen for #${existing_issue}" >>"$LOGFILE"
			return 0
		fi
		if [[ "$_remote_lines" -lt "$LARGE_FILE_LINE_THRESHOLD" ]]; then
			echo "[pulse-wrapper] Large-file gate: stale local checkout reports ${lf_path} at ${_verify_lines} lines; remote default branch is ${_remote_lines} lines, so solved debt #${existing_issue} stays closed" >>"$LOGFILE"
			return 0
		fi
		# Current remote content is still over threshold — preserve one durable
		# issue per path and reopen only from this authoritative evidence.
		echo "[pulse-wrapper] Large-file gate: prior file-size-debt #${existing_issue} closed but remote ${lf_path} still ${_remote_lines} lines (threshold ${LARGE_FILE_LINE_THRESHOLD}); reopening canonical debt issue" >>"$LOGFILE"
		return 1
	fi
	# wc -l returned 0 (empty file / read error) — treat same as unavailable.
	return 0
}

#######################################
# t2164 / t2995 helper — find an open or recently-closed file-size-debt
# issue carrying the exact generated `cited_file` marker. Prints
# "<state>:<number>" on stdout
# when found (state is "open" or "closed"); prints nothing otherwise.
#
# State is emitted as a stdout prefix instead of via `printf -v` because the
# caller invokes this helper in a command substitution `$(…)`, which runs in
# a subshell — `printf -v` in the subshell cannot reach the caller's scope.
# Encoding both values in stdout sidesteps the subshell boundary entirely.
#
# t2995: distinguish three outcomes via exit code so the caller can defer
# instead of duplicating on a transient lookup failure (the historical bug
# where a 15s gh wall-clock timeout was swallowed by `|| _open=""` and
# treated as "no match", causing the gate to file a duplicate on every
# scanner cycle that timed out — observed 7 duplicates for worktree-helper.sh
# alone over 30 days).
#
# Arguments: repo_slug, lf_path
# Stdout: "open:12345", "closed:18706", or empty
# Exit codes:
#   0 — match found (stdout populated)
#   1 — no match (stdout empty, lookup succeeded)
#   2 — lookup failed (timeout, network error, gh non-zero) — caller should
#       defer. The next pulse cycle will retry.
#######################################
_large_file_gate_find_existing_debt_issue() {
	local repo_slug="$1"
	local lf_path="$2"
	local _marker="generator=large-file-simplification-gate cited_file=${lf_path} "
	local _server_query="\"${lf_path}\" large-file-simplification-gate in:body sort:created-asc"

	# Query both states together so the oldest issue remains canonical even
	# when it is closed and a newer duplicate is open. One retry with 2s
	# backoff covers GitHub search
	# index lag (typically 1-3s after issue creation) — t2995 investigation
	# step 4. We only retry when the call SUCCEEDED but returned empty;
	# retrying a real failure would just hit the same timeout twice.
	local _match _match_json _match_rc=0
	_match_json=$(gh_issue_list --repo "$repo_slug" --state all \
		--label "file-size-debt" --search "$_server_query" \
		--json number,body,state --limit 100) || _match_rc=$?
	if [[ $_match_rc -eq 0 ]]; then
		_match=$(printf '%s' "$_match_json" | jq -r --arg marker "$_marker" \
			'[.[] | select((.body // "") | contains($marker))] | sort_by(.number) | .[0] | if . then "\(.state | ascii_downcase):\(.number)" else empty end') || _match_rc=$?
	fi
	if [[ $_match_rc -eq 0 && -z "$_match" ]]; then
		sleep 2
		_match_json=$(gh_issue_list --repo "$repo_slug" --state all \
			--label "file-size-debt" --search "$_server_query" \
			--json number,body,state --limit 100) || _match_rc=$?
		if [[ $_match_rc -eq 0 ]]; then
			_match=$(printf '%s' "$_match_json" | jq -r --arg marker "$_marker" \
				'[.[] | select((.body // "") | contains($marker))] | sort_by(.number) | .[0] | if . then "\(.state | ascii_downcase):\(.number)" else empty end') || _match_rc=$?
		fi
	fi
	if [[ $_match_rc -ne 0 ]]; then
		echo "[pulse-wrapper] WARN: file-size-debt dedup all-state search failed for ${lf_path} (rc=${_match_rc}); deferring (t2995)" >>"$LOGFILE"
		return 2
	fi
	if [[ -n "$_match" ]]; then
		printf '%s' "$_match"
		return 0
	fi
	return 1
}

#######################################
# Restore the labels required for an active canonical debt issue.
# Arguments: issue_number, repo_slug
#######################################
_large_file_gate_normalize_debt_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	if ! gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "file-size-debt,auto-dispatch" >/dev/null 2>&1; then
		return 1
	fi
	local _labels="" _stale_label
	_labels=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
	for _stale_label in status:done not-planned simplification-incomplete; do
		if [[ ",$_labels," == *",$_stale_label,"* ]]; then
			if ! gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "$_stale_label" >/dev/null 2>&1; then
				return 1
			fi
		fi
	done
	return 0
}

#######################################
# Close all open exact-marker matches except the canonical oldest issue.
# This is retried whenever the canonical issue is encountered, so a transient
# close failure cannot leave a duplicate permanently active.
# Arguments: repo_slug, lf_path, canonical_issue
#######################################
_large_file_gate_close_duplicate_debt_issues() {
	local repo_slug="$1"
	local lf_path="$2"
	local canonical_issue="$3"
	local _marker="generator=large-file-simplification-gate cited_file=${lf_path} "
	local _json="" _duplicate="" _failed=0

	_json=$(gh_issue_list --repo "$repo_slug" --state open --label "file-size-debt" \
		--search "\"${lf_path}\" large-file-simplification-gate in:body sort:created-asc" \
		--json number,body --limit 100 2>/dev/null) || return 1
	while IFS= read -r _duplicate; do
		[[ -n "$_duplicate" && "$_duplicate" != "$canonical_issue" ]] || continue
		if ! gh issue close "$_duplicate" --repo "$repo_slug" --reason "not planned" \
			--comment "Superseded by canonical file-size-debt #${canonical_issue}; closed by duplicate reconciliation." >/dev/null 2>&1; then
			_failed=1
		fi
	done < <(printf '%s' "$_json" | jq -r --arg marker "$_marker" \
		'.[] | select((.body // "") | contains($marker)) | .number' 2>/dev/null)
	[[ "$_failed" -eq 0 ]]
	return $?
}

#######################################
# Reopen the canonical debt issue when its cited file remains oversized.
# Reusing the durable issue identity prevents close/create/auto-dispatch loops.
# Arguments: issue_number, lf_path, repo_slug
#######################################
_large_file_gate_reopen_debt_issue() {
	local issue_number="$1"
	local lf_path="$2"
	local repo_slug="$3"

	if ! gh issue reopen "$issue_number" --repo "$repo_slug" >/dev/null 2>&1; then
		echo "[pulse-wrapper] WARN: failed to reopen canonical file-size-debt #${issue_number} for ${lf_path}; deferring" >>"$LOGFILE"
		return 1
	fi
	if ! _large_file_gate_normalize_debt_issue "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] WARN: reopened file-size-debt #${issue_number} but failed to normalize labels; next pulse will retry" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] Reopened canonical file-size-debt issue #${issue_number} for ${lf_path}" >>"$LOGFILE"
	printf '#%s (reopened)' "$issue_number"
	return 0
}

#######################################
# t2164 helper — create a fresh file-size-debt issue via gh_create_issue.
# Prints "#NNN (new)" on success and empty on failure (gh failure is logged).
# Accepts an optional `prior_attempt_issue` for the body's "Prior attempt"
# footnote (t2164 phantom-continuation audit trail).
#######################################
_large_file_gate_file_new_debt_issue() {
	local lf_path="$1"
	local parent_issue="$2"
	local repo_slug="$3"
	local prior_attempt_issue="${4:-}"

	local _prior_attempt_ref=""
	if [[ -n "$prior_attempt_issue" ]]; then
		_prior_attempt_ref="

**Prior attempt:** #${prior_attempt_issue} closed without reducing file size below the ${LARGE_FILE_LINE_THRESHOLD}-line threshold (current size verified by gate). This issue is the file-size follow-up."
	fi

	# GH#18644: ensure the `file-size-debt` label exists before creation.
	gh label create "file-size-debt" \
		--repo "$repo_slug" \
		--description "Target file exceeds the line-count threshold and needs splitting before implementation can proceed" \
		--color "D93F0B" \
		--force 2>/dev/null || true

	local _new_num _create_body _create_combined
	_create_body="<!-- aidevops:generator=large-file-simplification-gate cited_file=${lf_path} threshold=${LARGE_FILE_LINE_THRESHOLD} -->

## What
Simplify \`${lf_path}\` — currently over ${LARGE_FILE_LINE_THRESHOLD} lines. Break into smaller, focused modules.

## Why
Issue #${parent_issue} is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.${_prior_attempt_ref}

## How
- EDIT: \`${lf_path}\`
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources the extracted modules
- Verify: \`wc -l ${lf_path}\` should be below ${LARGE_FILE_LINE_THRESHOLD}

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for file splits — covers identity-key preservation, CI false-positives, and PR body template).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). For shell scripts, copy the include-guard and SCRIPT_DIR-fallback pattern from the simple precedent.

**Expected CI gate overrides:** This PR will likely trigger a complexity regression from the file-split identity-key change. Apply the \`complexity-bump-ok\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

_Created by large-file simplification gate (pulse-dispatch-core.sh)_"
	# t2115: Use gh_create_issue wrapper for origin label + signature auto-append.
	_create_combined=$(gh_create_issue --repo "$repo_slug" \
		--title "file-size-debt: ${lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
		--label "file-size-debt,auto-dispatch,origin:worker" \
		--body "$_create_body" 2>&1) || true
	_new_num=$(printf '%s' "$_create_combined" |
		grep -oE 'https://github\.com/[^ ]+/issues/[0-9]+' |
		head -1 |
		grep -oE '[0-9]+$' || true)
	if [[ -n "$_new_num" ]]; then
		# Reconcile concurrent search-then-create races after GitHub's search
		# index has had time to expose both issues. The oldest exact-marker
		# match is canonical; any later issue created by this caller is closed.
		sleep 3
		local _canonical_combined _canonical_num="" _reconcile_rc=0
		_canonical_combined=$(_large_file_gate_find_existing_debt_issue "$repo_slug" "$lf_path") || _reconcile_rc=$?
		if [[ "$_reconcile_rc" -eq 0 && "$_canonical_combined" == open:* ]]; then
			_canonical_num="${_canonical_combined#open:}"
		fi
		if [[ -n "$_canonical_num" && "$_canonical_num" != "$_new_num" ]]; then
			if ! _large_file_gate_close_duplicate_debt_issues "$repo_slug" "$lf_path" "$_canonical_num"; then
				echo "[pulse-wrapper] WARN: failed to close one or more duplicate file-size-debt issues for ${lf_path}; next pulse will retry" >>"$LOGFILE"
			fi
			printf '#%s (existing)' "$_canonical_num"
			return 0
		fi
		printf '#%s (new)' "$_new_num"
		echo "[pulse-wrapper] Created file-size-debt issue #${_new_num} for ${lf_path} (blocking #${parent_issue})" >>"$LOGFILE"
	else
		# Log the gh failure so the next cycle's operator can see why
		# the gate "created" nothing. 200-char truncation matches
		# issue-sync-helper.sh style.
		echo "[pulse-wrapper] WARN: failed to create file-size-debt issue for ${lf_path} (blocking #${parent_issue}): ${_create_combined:0:200}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Create a file-size-debt issue for one large-file target. Idempotent:
# if an open file-size-debt issue already mentions the file, emit a
# reference to it instead of creating a new one.
#
# t2021: `gh issue create` does NOT support --json; the issue number is
# parsed from the issue URL on stdout. The `|| true` on the $() guards
# against gh non-zero exits (label application failing server-side while
# the issue still creates — see issue-sync-helper.sh:441-464, GH#15234).
#
# GH#18644: the `file-size-debt` label is created idempotently so
# first-use in a fresh repo doesn't fail.
#
# t2164: `repo_path` parameter added so the recently-closed continuation
# branch (GH#18960) can verify the prior PR actually reduced the file
# below threshold before declaring continuation. Without this check, a
# closed file-size-debt issue whose PR did not shrink the file
# (or even grew it) gets cited as "in flight" continuation, and the
# parent stays held by the gate forever (or until the 30-day window
# expires) with no real work scheduled.
#
# Arguments: lf_path, parent_issue, repo_slug, repo_path
# Stdout: "#NNN (existing)" or "#NNN (new)" or
#         "#NNN (recently-closed — continuation)" on success; empty on failure
# Exit: 0 always (non-fatal; failure is logged)
#######################################
_large_file_gate_create_debt_issue() {
	local lf_path="$1"
	local parent_issue="$2"
	local repo_slug="$3"
	local repo_path="${4:-}"
	# t2164: helper encodes state in stdout as "<state>:<number>" — subshell
	# boundary prevents `printf -v` from crossing the command substitution.
	# t2995: helper now returns 2 when lookup fails (timeout / gh failure),
	# distinct from 1 = no match. On lookup failure we MUST NOT fall through
	# to filing a fresh issue — that's the duplicate-creation bug. Defer to
	# the next pulse cycle.
	local _existing_combined _existing _existing_state _lookup_rc=0
	_existing_combined=$(_large_file_gate_find_existing_debt_issue "$repo_slug" "$lf_path") || _lookup_rc=$?
	if [[ "$_lookup_rc" -eq 2 ]]; then
		echo "[pulse-wrapper] file-size-debt dedup lookup failed for ${lf_path} (parent #${parent_issue}); deferring filing to next cycle (t2995)" >>"$LOGFILE"
		return 0
	fi
	if [[ -n "$_existing_combined" && "$_existing_combined" == *:* ]]; then
		_existing_state="${_existing_combined%%:*}"
		_existing="${_existing_combined#*:}"
	else
		_existing_state=""
		_existing=""
	fi

	if [[ "$_existing_state" == "open" ]]; then
		if ! _large_file_gate_close_duplicate_debt_issues "$repo_slug" "$lf_path" "$_existing"; then
			echo "[pulse-wrapper] WARN: duplicate reconciliation incomplete for canonical file-size-debt #${_existing}; next pulse will retry" >>"$LOGFILE"
		fi
		if ! _large_file_gate_normalize_debt_issue "$_existing" "$repo_slug"; then
			echo "[pulse-wrapper] WARN: failed to normalize canonical file-size-debt #${_existing}; deferring" >>"$LOGFILE"
			return 0
		fi
		printf '#%s (existing)' "$_existing"
		return 0
	fi

	if [[ "$_existing_state" == "closed" ]]; then
		# t2164: verify the prior PR actually reduced file size before
		# declaring continuation. Helper logs the skip when it fires.
		# t2169: pass repo_slug so the helper can short-circuit on the
		# simplification-incomplete label (set by Simplification Outcome
		# Check workflow) without needing a wc -l measurement.
		if _large_file_gate_verify_prior_reduced_size "$_existing" "$lf_path" "$repo_path" "$repo_slug"; then
			printf '#%s (recently-closed — continuation)' "$_existing"
			return 0
		fi
		# The file remains oversized. Reopen the durable per-path issue instead
		# of creating a successor that can feed an unbounded dispatch loop.
		_large_file_gate_reopen_debt_issue "$_existing" "$lf_path" "$repo_slug" || true
		return 0
	fi

	_large_file_gate_file_new_debt_issue "$lf_path" "$parent_issue" "$repo_slug" ""
	return 0
}

#######################################
# Apply the large-file gate: add `needs-simplification` label to the parent
# issue, create one file-size-debt issue per large file (dedup-aware),
# and post the gate comment on the parent issue.
#
# t2164: `repo_path` parameter added so the per-file debt-issue creator can
# verify the prior PR actually reduced the file size before declaring
# "recently-closed continuation".
#
# Arguments:
#   $1 - issue_number (parent, being gated)
#   $2 - repo_slug
#   $3 - large_files_display ("path (N lines), " comma-trailed display string)
#   $4 - large_file_paths (newline-separated paths, may contain \n escapes)
#   $5 - repo_path (filesystem path to repo for wc -l verification, optional)
#######################################
_large_file_gate_apply() {
	local issue_number="$1"
	local repo_slug="$2"
	local large_files_display="$3"
	local large_file_paths="$4"
	local repo_path="${5:-}"

	# Add label to hold dispatch
	gh label create "needs-simplification" \
		--repo "$repo_slug" \
		--description "Issue targets large file(s) needing simplification first" \
		--color "D93F0B" \
		--force 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-simplification" 2>/dev/null || true

	large_files_display="${large_files_display%, }"

	# Create file-size-debt issues for each large file immediately
	# (don't wait for the daily complexity scan). Dedup: skip if an open
	# file-size-debt issue already mentions this file.
	local _created_issues=""
	local _lf_path _debt_ref
	while IFS= read -r _lf_path; do
		[[ -z "$_lf_path" ]] && continue
		_debt_ref=$(_large_file_gate_create_debt_issue "$_lf_path" "$issue_number" "$repo_slug" "$repo_path")
		if [[ -n "$_debt_ref" ]]; then
			_created_issues="${_created_issues}${_debt_ref}, "
		fi
	done < <(printf '%b' "$large_file_paths")

	_created_issues="${_created_issues%, }"
	local simplification_body="## Large File Simplification Gate

This issue references file(s) exceeding ${LARGE_FILE_LINE_THRESHOLD} lines: ${large_files_display}.

Workers dispatched against large files spend most of their context budget reading the file, leaving insufficient capacity for implementation.

**Simplification issues:** ${_created_issues:-none created}

**Status:** Held from dispatch until simplification completes. The \`needs-simplification\` label will be removed automatically when the target file(s) are below threshold.

_Automated by \`_issue_targets_large_files()\` in pulse-wrapper.sh_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"## Large File Simplification Gate" "$simplification_body"

	echo "[pulse-wrapper] Large-file gate: #${issue_number} in ${repo_slug} targets ${large_files_display}" >>"$LOGFILE"
	return 0
}

#######################################
# Clear a stale `needs-simplification` label when no large files remain
# (e.g., all targets now excluded by skip pattern or simplified below
# threshold). Posts a follow-up "CLEARED" comment via the triage helper
# so the original "Held from dispatch" comment doesn't mislead readers (t2042).
#
# Arguments: issue_number, repo_slug
# Returns: 0=label removal confirmed, 1=removal failed or could not be verified
#######################################
_large_file_gate_clear_stale_label() {
	local issue_number="$1"
	local repo_slug="$2"
	local current_labels=""
	if ! gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "needs-simplification" >/dev/null 2>&1; then
		echo "[pulse-wrapper] WARN: failed to clear stale needs-simplification label for #${issue_number} (${repo_slug}); gate remains applied for retry" >>"$LOGFILE"
		return 1
	fi
	if ! current_labels=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null); then
		echo "[pulse-wrapper] WARN: could not verify stale needs-simplification label removal for #${issue_number} (${repo_slug}); gate remains applied for retry" >>"$LOGFILE"
		return 1
	fi
	if [[ ",$current_labels," == *",needs-simplification,"* ]]; then
		echo "[pulse-wrapper] WARN: stale needs-simplification label still present after removal for #${issue_number} (${repo_slug}); gate remains applied for retry" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] Simplification gate cleared for #${issue_number} (${repo_slug}) — no large files after exclusion filter" >>"$LOGFILE"
	# t2042: post follow-up "CLEARED" comment so the original
	# "Held from dispatch" comment doesn't mislead readers. Helper
	# is defined in pulse-triage.sh which is sourced before this
	# file (see pulse-wrapper.sh:169-172).
	if declare -F _post_simplification_gate_cleared_comment >/dev/null 2>&1; then
		_post_simplification_gate_cleared_comment "$issue_number" "$repo_slug"
	fi
	return 0
}

#######################################
# t2713: Surgical-brief exemption precheck for the large-file gate.
# When the issue title encodes a task ID (^tNNN:) and the task's brief
# cites an explicit line range for EVERY path returned by
# _large_file_gate_extract_paths, the edits are surgical and do not
# require whole-file context budget. Returns 0 (exemption applies) when
# all paths are covered; returns 1 otherwise.
#
# Sets module-level global _LFG_SURGICAL_EXEMPTED_FILES to a comma-separated
# list of exempted file basenames when returning 0.
#
# Three accepted line-range forms in the brief (any one form per file counts):
#   a) basename:NNN-NNN            (direct citation, e.g. "auto-update-helper.sh:1320-1345")
#   b) basename ... (line NNN-NNN) (narrative parenthetical)
#   c) basename ... LNNN-LNNN      (GitHub URL / notebook-style)
#
# Conservative fail-open: missing task ID, missing brief, or unmatched
# path all fall through to the normal per-target evaluation loop.
#
# Arguments:
#   $1 - issue_title  (e.g. "t2706: fix deployed-sha drift")
#   $2 - all_paths    (newline-separated, from _large_file_gate_extract_paths)
#   $3 - repo_path    (absolute path to the repo checkout)
# Exit codes:
#   0 - exemption applies (all paths have ≥1 line-range ref in brief)
#   1 - no exemption (no task ID, brief missing, empty paths, ≥1 uncovered)
#######################################
_large_file_gate_check_surgical_brief() {
	local issue_title="$1"
	local all_paths="$2"
	local repo_path="$3"

	_LFG_SURGICAL_EXEMPTED_FILES=""

	# 1. Extract task ID from issue title (must begin with tNNN:).
	local task_id=""
	if [[ "$issue_title" =~ ^(t[0-9]+): ]]; then
		task_id="${BASH_REMATCH[1]}"
	fi
	[[ -n "$task_id" ]] || return 1

	# 2. Locate the task brief — fall through conservatively when missing.
	local brief_path="${repo_path}/todo/tasks/${task_id}-brief.md"
	[[ -f "$brief_path" ]] || return 1

	# 3. For each extracted path, verify ≥1 line-range reference exists in the
	#    brief. ALL paths must be covered for the exemption to fire.
	local covered_all=true
	local covered_files=""
	local raw_target
	while IFS= read -r raw_target; do
		[[ -z "$raw_target" ]] && continue

		# Strip any line qualifier already embedded in the extracted path
		# (mirrors the stripping in _large_file_gate_evaluate_target).
		local fpath="$raw_target"
		if [[ "$raw_target" =~ ^(.+):([0-9]+(-[0-9]+)?)$ ]]; then
			fpath="${BASH_REMATCH[1]}"
		fi
		local bname
		bname=$(basename "$fpath")

		# Pattern a: basename:NNN-NNN (most common — "Relevant Files" sections)
		# Pattern b: basename ... (line NNN-NNN) (narrative parenthetical in prose)
		# Pattern c: basename ... LNNN-LNNN (GitHub URL / notebook reference)
		if grep -qE "${bname}:[0-9]+-[0-9]+" "$brief_path" 2>/dev/null ||
			grep -qE "${bname}.*\(lines?[[:space:]]+[0-9]+-[0-9]+\)" "$brief_path" 2>/dev/null ||
			grep -qE "${bname}.*L[0-9]+-L?[0-9]+" "$brief_path" 2>/dev/null; then
			covered_files="${covered_files}${bname}, "
		else
			covered_all=false
			break
		fi
	done <<<"$all_paths"

	if [[ "$covered_all" == true && -n "$covered_files" ]]; then
		_LFG_SURGICAL_EXEMPTED_FILES="${covered_files%, }"
		return 0
	fi
	return 1
}

#######################################
# Return the issue title from an optional pre-fetched bundle, falling back to gh.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - pre_fetched_json (optional)
# Stdout: issue title, or empty string on failure
#######################################
_large_file_gate_issue_title() {
	local issue_number="$1"
	local repo_slug="$2"
	local pre_fetched_json="$3"

	if [[ -n "$pre_fetched_json" ]] \
		&& printf '%s' "$pre_fetched_json" | jq -e '.title' >/dev/null 2>&1; then
		printf '%s' "$pre_fetched_json" | jq -r '.title // ""' 2>/dev/null || true
		return 0
	fi

	gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json title --jq '.title // ""' 2>/dev/null || true
	return 0
}

#######################################
# Evaluate extracted issue targets and collect any large files.
#
# Sets module-level globals:
#   _LFG_FOUND_LARGE, _LFG_LARGE_FILES, _LFG_LARGE_FILE_PATHS
#
# Arguments:
#   $1 - all_paths (newline-separated, from _large_file_gate_extract_paths)
#   $2 - repo_path
#   $3 - issue_number
#######################################
_large_file_gate_collect_large_files() {
	local all_paths="$1"
	local repo_path="$2"
	local issue_number="$3"

	_LFG_FOUND_LARGE=false
	_LFG_LARGE_FILES=""
	_LFG_LARGE_FILE_PATHS=""

	local raw_target eval_output eval_rc
	while IFS= read -r raw_target; do
		[[ -z "$raw_target" ]] && continue
		eval_rc=0
		eval_output=$(_large_file_gate_evaluate_target "$raw_target" "$repo_path" "$issue_number") || eval_rc=$?
		if [[ "$eval_rc" -eq 0 && -n "$eval_output" ]]; then
			local _f="${eval_output%|*}" _c="${eval_output##*|}"
			_LFG_FOUND_LARGE=true
			_LFG_LARGE_FILES="${_LFG_LARGE_FILES}${_f} (${_c} lines), "
			# shellcheck disable=SC2129  # two appends to _LFG_LARGE_FILE_PATHS is clearer as separate statements
			_LFG_LARGE_FILE_PATHS="${_LFG_LARGE_FILE_PATHS}${_f}\n"
		fi
	done <<<"$all_paths"

	return 0
}

#######################################
# Resolve current issue labels while allowing callers to reuse prefetched
# issue JSON. A prefetched positive gate is volatile, so refresh it before
# dispatch and retain it fail-closed when GitHub cannot provide a snapshot.
#
# Arguments: issue_number, repo_slug, pre_fetched_json
# Outputs: comma-joined issue labels
#######################################
_large_file_gate_issue_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local pre_fetched_json="$3"
	local issue_labels=""
	local fresh_issue_labels=""

	if [[ -n "$pre_fetched_json" ]] \
		&& printf '%s' "$pre_fetched_json" | jq -e '.labels' >/dev/null 2>&1; then
		issue_labels=$(printf '%s' "$pre_fetched_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if fresh_issue_labels=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
				--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null); then
				issue_labels="$fresh_issue_labels"
			else
				echo "[pulse-wrapper] WARN: could not refresh volatile simplification lifecycle for #${issue_number} (${repo_slug}); retaining prefetched gate state" >>"$LOGFILE"
			fi
		fi
	else
		issue_labels=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
	fi

	printf '%s' "$issue_labels"
	return 0
}

#######################################
# Thin orchestrator for the large-file gate. Delegates label precheck,
# path extraction, per-target evaluation, gate application, and stale-label
# cleanup to the `_large_file_gate_*` helpers above. Byte-for-byte
# behaviourally equivalent to the pre-GH#18654 monolithic implementation.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - issue_body
#   $4 - repo_path
#   $5 - force_recheck (optional, default "false"; t1998 re-eval bypass)
#
# Exit codes:
#   0 - gate applied or safely deferred (dispatch blocked)
#   1 - gate not applied (dispatch may proceed)
#######################################
_issue_targets_large_files() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"
	local repo_path="$4"
	# t1998: force_recheck bypasses the skip-if-already-labeled short-circuit.
	# The normal dispatch path leaves this false (perf optimisation — no need
	# to re-run wc -l on an issue we just gated). The re-evaluation path in
	# pulse-triage.sh _reevaluate_simplification_labels() passes "true" so it
	# can detect when a previously-gated file has been simplified below
	# threshold and clear the label.
	local force_recheck="${5:-false}"
	# t2996: optional pre-fetched issue JSON containing `.labels` and `.title`.
	# When `dispatch_with_dedup` invokes this gate, the canonical bundle
	# already carries both fields; threading them through skips two
	# `gh issue view` calls (labels + title) per dispatch candidate.
	# Re-evaluation paths in pulse-triage.sh that may hold stale labels
	# omit this argument and fall back to a fresh fetch.
	local pre_fetched_json="${6:-}"

	[[ -n "$issue_body" ]] || return 1
	[[ -d "$repo_path" ]] || return 1

	local issue_labels=""
	issue_labels=$(_large_file_gate_issue_labels "$issue_number" "$repo_slug" "$pre_fetched_json")

	local _precheck_rc=0
	_large_file_gate_precheck_labels "$issue_number" "$repo_slug" "$issue_labels" "$force_recheck" || _precheck_rc=$?
	case "$_precheck_rc" in
	1) return 1 ;;
	2) return 0 ;;
	esac

	local all_paths
	all_paths=$(_large_file_gate_extract_paths "$issue_body")
	if [[ -z "$all_paths" ]]; then
		# t2170 Fix E (primary): No paths in body — if already labeled, auto-clear
		# (stale label from pre-Fix-A gate application that matched context-ref
		# backtick paths). Closes the gap for issues where Fix A now correctly
		# returns empty but the early-return prevented reaching the auto-clear
		# at lines 682-684. Empirical evidence: GH#19415 received a CLEARED
		# comment but the label persisted; 17 min of zero label events after
		# pulse restart confirmed the extractor fix worked but the stale label
		# required human intervention to clear.
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			_large_file_gate_clear_stale_label "$issue_number" "$repo_slug" || return 0
		fi
		return 1
	fi

	# t2713: Surgical-brief exemption — check before the per-target evaluation
	# loop. If the issue title has a task ID and the linked brief cites line
	# ranges for every extracted path, dispatch proceeds without a split.
	# t2996: title travels in pre_fetched_json when dispatch_with_dedup is
	# the caller; only fall back to a fresh fetch when the bundle is absent
	# (re-evaluation paths from pulse-triage.sh).
	local _surgical_title
	_surgical_title=$(_large_file_gate_issue_title "$issue_number" "$repo_slug" "$pre_fetched_json") || _surgical_title=""
	if _large_file_gate_check_surgical_brief \
		"$_surgical_title" "$all_paths" "$repo_path"; then
		echo "[pulse-wrapper] Large-file gate EXEMPTED for #${issue_number} (${repo_slug}): surgical brief with line ranges for ${_LFG_SURGICAL_EXEMPTED_FILES}" >>"$LOGFILE"
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			_large_file_gate_clear_stale_label "$issue_number" "$repo_slug" || return 0
		fi
		return 1
	fi

	# `_pulse_refresh_repo` is best-effort and canonical recovery may be delayed
	# or unavailable on a contributor runner. When the pulse orchestration is
	# loaded, require exact remote-default freshness before any local wc -l.
	# A stale/unverifiable checkout blocks this candidate for one cycle without
	# mutating issue labels or reopening debt issues.
	if declare -F _pulse_refresh_repo >/dev/null 2>&1 \
		&& ! _large_file_gate_repo_matches_remote_default "$repo_path"; then
		echo "[pulse-wrapper] Large-file gate: deferring #${issue_number} (${repo_slug}); ${repo_path} is not at the verified remote default-branch commit" >>"$LOGFILE"
		return 0
	fi

	_large_file_gate_collect_large_files "$all_paths" "$repo_path" "$issue_number"

	if [[ "$_LFG_FOUND_LARGE" == "true" ]]; then
		# t2164: thread repo_path through so _large_file_gate_create_debt_issue
		# can verify recently-closed continuations actually reduced the file size.
		_large_file_gate_apply "$issue_number" "$repo_slug" "$_LFG_LARGE_FILES" "$_LFG_LARGE_FILE_PATHS" "$repo_path"
		return 0
	fi

	# If was_already_labeled but no large files found (e.g., all files now
	# excluded by skip pattern or simplified below threshold), auto-clear.
	if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		_large_file_gate_clear_stale_label "$issue_number" "$repo_slug" || return 0
	fi

	return 1
}
