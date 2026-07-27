#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dep-graph.sh — Cross-issue dependency graph cache and blocked-status resolution (t1935).
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - build_dependency_graph_cache
#   - refresh_blocked_status_from_graph
#   - is_blocked_by_unresolved
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_DEP_GRAPH_LOADED:-}" ]] && return 0
_PULSE_DEP_GRAPH_LOADED=1
[[ -n "${DEP_FALSE+x}" ]] || DEP_FALSE="false"
[[ -n "${DEP_CACHE_EMPTY_JSON+x}" ]] || DEP_CACHE_EMPTY_JSON='{"use_cache":false,"open_issues":[],"task_to_issue":{}}'
[[ -n "${DEP_AVAILABLE_STATUS+x}" ]] || DEP_AVAILABLE_STATUS="status:available"
[[ -n "${DEP_JQ_NONEMPTY_LINES+x}" ]] || DEP_JQ_NONEMPTY_LINES='split("\n") | map(select(length > 0))'
[[ -n "${_DEP_CACHED_REPO_SLUG+x}" ]] || _DEP_CACHED_REPO_SLUG=""
[[ -n "${_DEP_CACHED_REPO_ID+x}" ]] || _DEP_CACHED_REPO_ID=""

_pulse_dep_graph_dir="${BASH_SOURCE[0]%/*}"
[[ "$_pulse_dep_graph_dir" == "${BASH_SOURCE[0]}" ]] && _pulse_dep_graph_dir="."
# shellcheck source=./task-identity-lib.sh
source "${_pulse_dep_graph_dir}/task-identity-lib.sh"
unset _pulse_dep_graph_dir

#######################################
# Body defer/hold marker detection (t2031)
#
# A `status:blocked` label may have been applied for reasons other than
# the blocked-by chain — most commonly a human-imposed hold phrased in
# the issue body like "Defer until X" or "On hold". The refresh routine
# must not auto-unblock those. This helper runs at cache build time and
# at assertion time in the regression test; keep the regex in sync
# across both copies.
#
# Arguments: $1 - issue body text
# Outputs:   boolean text on stdout
#######################################
_body_has_defer_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qiE 'defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]'; then
		echo "true"
	else
		echo "${DEP_FALSE}"
	fi
}

#######################################
# Parse a single issue for the dep-graph cache (t2031 refactor)
#
# Consumes one issue JSON blob (from `gh issue list --json
# number,title,body,labels`) and the current per-repo accumulator state,
# and emits updated accumulator state. Extracted from
# build_dependency_graph_cache so that function stays under the 100-line
# complexity gate.
#
# Arguments:
#   $1 - issue JSON (single object)
#   $2 - current accumulator JSON (compact object with keys:
#        open_nums, closed_nums, known_nums, task_to_issue, blocked_by_map,
#        defer_flags_map)
#
# Output: a single compact JSON object with the updated accumulator.
# If the input issue JSON is invalid or missing a number, emits the
# input accumulator unchanged.
#######################################
_dep_graph_process_issue_json() {
	local issue_json="$1"
	local acc_json="$2"

	local num="" title="" body="" state=""
	num=$(printf '%s' "$issue_json" | jq -r '.number // empty' 2>/dev/null)
	title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null)
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null)
	state=$(printf '%s' "$issue_json" | jq -r '.state // "OPEN" | ascii_upcase' 2>/dev/null)

	if ! [[ "$num" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$acc_json"
		return 0
	fi

	# Preserve the complete canonical task ID as the graph key.
	local task_id_in_title
	task_id_in_title=$(task_identity_parse_title_prefix "$title" || true)

	# Extract blocked-by task IDs and issue numbers from body and labels. Two-step
	# parse tolerates both the markdown format emitted by
	# brief-template.md (`**Blocked by:** ` + backtick-quoted IDs) and
	# the bare TODO.md format (`blocked-by:tNNN,tMMM`). BSD/GNU portable
	# via POSIX `[^[:cntrl:]]` (see t1983 / t2015 for history).
	# Subtask decimal suffixes (t325.1) are preserved (GH#19165).
	local blocker_lines="" body_blocker_tids="" body_blocker_nums="" label_names="" label_blocker_tids="" label_blocker_nums="" blocker_tids="" blocker_nums=""
	blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
	body_blocker_tids=$(_blocked_by_extract_tids "$blocker_lines")
	body_blocker_nums=$(printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)
	label_names=$(printf '%s' "$issue_json" | jq -r '.labels[]?.name // empty' 2>/dev/null) || label_names=""
	while IFS= read -r label_name; do
		[[ "$label_name" == blocked-by:* ]] || continue
		local label_task_id="${label_name#blocked-by:}"
		if task_identity_validate "$label_task_id"; then
			label_blocker_tids="${label_blocker_tids:+${label_blocker_tids}$'\n'}${label_task_id}"
		elif task_identity_has_malformed_candidate "$label_task_id"; then
			label_blocker_tids="${label_blocker_tids:+${label_blocker_tids}$'\n'}__malformed__"
		fi
	done <<<"$label_names"
	label_blocker_nums=$(printf '%s' "$label_names" | grep -oE '^blocked-by:#[0-9]+$' | grep -oE '[0-9]+' || true)
	blocker_tids=$(printf '%s\n%s\n' "$body_blocker_tids" "$label_blocker_tids" | sed '/^$/d' | sort -u)
	blocker_nums=$(printf '%s\n%s\n' "$body_blocker_nums" "$label_blocker_nums" | sed '/^$/d' | sort -u)
	# A copied roadmap marker can accidentally point back to the issue itself.
	# Self edges are never dependencies and must not create permanent deadlocks.
	[[ -n "$task_id_in_title" ]] && blocker_tids=$(printf '%s\n' "$blocker_tids" | grep -vxF "$task_id_in_title" || true)
	blocker_nums=$(printf '%s\n' "$blocker_nums" | grep -vxF "$num" || true)

	local tid_arr="" num_arr=""
	tid_arr=$(printf '%s' "$blocker_tids" | jq -Rsc "$DEP_JQ_NONEMPTY_LINES" 2>/dev/null) || tid_arr='[]'
	num_arr=$(printf '%s' "$blocker_nums" | jq -Rsc "$DEP_JQ_NONEMPTY_LINES" 2>/dev/null) || num_arr='[]'
	local has_blockers="${DEP_FALSE}"
	[[ -n "$blocker_tids" || -n "$blocker_nums" ]] && has_blockers="true"

	# Body defer/hold marker detection (t2031).
	local has_defer_marker
	has_defer_marker=$(_body_has_defer_marker "$body")

	# Single jq call merges every accumulator update in one pass.
	# Keeps the shell shorter and guarantees compact single-line output.
	printf '%s' "$acc_json" | jq -c \
		--argjson n "$num" \
		--arg tid "$task_id_in_title" \
		--argjson tids "$tid_arr" \
		--argjson nums "$num_arr" \
		--arg has_blockers "$has_blockers" \
		--arg state "$state" \
		--argjson defer "$has_defer_marker" \
		'
		.known_nums = ((.known_nums // []) + [$n])
		| (if $state == "\u0043LOSED" then .closed_nums = ((.closed_nums // []) + [$n]) else .open_nums = (.open_nums + [$n]) end)
		| (if $tid != "" then .task_to_issue[$tid] = $n else . end)
		| (if $has_blockers == "true" and $state != "C\u004cOSED"
			then .blocked_by_map[($n | tostring)] = {"task_ids": $tids, "issue_nums": $nums, "has_defer_marker": $defer}
			else . end)
		| (if $defer == true
			then .defer_flags_map[($n | tostring)] = true
			else . end)
	' 2>/dev/null || printf '%s\n' "$acc_json"
}

#######################################
# Remove deterministic break edges from declared dependency cycles.
#
# Dependency edges point from the blocked issue to its blocker. For every edge
# that participates in a cycle, discard the ascending numeric edge
# (blocked issue number < blocker issue number). Every numeric cycle contains
# at least one ascending edge, so this breaks deadlocks while preserving a
# stable ordering across runners. Task-ID edges are resolved through the
# repo-level task_to_issue map before applying the same rule.
#
# Arguments: $1 - per-repo dependency graph JSON
# Output: the pruned graph JSON
# Returns: 0 on success, 1 for invalid JSON
#######################################
_dep_graph_prune_circular_edges() {
	local repo_data="$1"
	printf '%s' "$repo_data" | jq -c '
		def resolved_blockers($root; $issue):
			(((($root.blocked_by[$issue].issue_nums // []) | map(tostring))
			+ (($root.blocked_by[$issue].task_ids // [])
				| map($root.task_to_issue[.]? // empty | tostring))) | unique);
		def reaches($root; $from; $target; $seen):
			if $from == $target then true
			elif ($seen | index($from)) != null then false
			else any(resolved_blockers($root; $from)[];
				reaches($root; .; $target; ($seen + [$from])))
			end;
		. as $root
		| .blocked_by |= with_entries(
			.key as $blocked
			| .value.issue_nums = ((.value.issue_nums // []) | map(select(
				. as $raw
				| ($raw | tostring) as $blocker
				| (((($blocked | tonumber?) != null)
					and (($blocker | tonumber?) != null)
					and (($blocked | tonumber) < ($blocker | tonumber))
					and reaches($root; $blocker; $blocked; [])) | not))))
			| .value.task_ids = ((.value.task_ids // []) | map(select(
				. as $task
				| ($root.task_to_issue[$task]? // null) as $resolved
				| ((($resolved != null)
					and (($blocked | tonumber?) != null)
					and (($blocked | tonumber) < ($resolved | tonumber))
					and reaches($root; ($resolved | tostring); $blocked; [])) | not))))
		)
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Build per-repo dep graph data (t2031 refactor, GH#18593 perf)
#
# Fetches the bounded issue set for one repo slug and validates each task token
# through the shared codec before pruning deterministic circular edges.
#
# The jq program replicates the logic of _dep_graph_process_issue_json:
#   - task ID extraction from title (^tNNN: prefix)
#   - blocked-by line detection and tID/issueNum extraction
#   - defer/hold marker detection (same patterns as _body_has_defer_marker)
#
# _dep_graph_process_issue_json is retained for unit testing and as a
# reference implementation.
#
# Arguments: $1 - repo slug (owner/repo)
# Output:    one JSON object on stdout
#######################################
_dep_graph_build_repo_data() {
	local slug="$1"
	local issues_json
	if ! issues_json=$(gh_issue_list --repo "$slug" --state all --limit 500 \
		--json number,title,body,labels,state 2>/dev/null); then
		echo "[pulse-wrapper] dep-graph-cache: failed to list open issues for ${slug}; preserving previous repo cache when available" >>"$LOGFILE"
		return 1
	fi

	local acc='{"open_nums":[],"closed_nums":[],"known_nums":[],"task_to_issue":{},"blocked_by_map":{},"defer_flags_map":{}}'
	local issue_json=""
	while IFS= read -r issue_json; do
		[[ -n "$issue_json" ]] || continue
		acc=$(_dep_graph_process_issue_json "$issue_json" "$acc") || return 1
	done < <(printf '%s' "$issues_json" | jq -c '.[]' 2>/dev/null)
	local parsed_repo_data=""
	parsed_repo_data=$(printf '%s' "$acc" | jq -c '{open_issues:.open_nums,closed_issues:.closed_nums,known_issues:.known_nums,task_to_issue:.task_to_issue,blocked_by:.blocked_by_map,defer_flags:.defer_flags_map}') || return 1
	_dep_graph_prune_circular_edges "$parsed_repo_data" || return 1
	return 0
}

#######################################
# Dependency graph cache (t1935)
#
# Builds a JSON cache of all blocked-by relationships across pulse repos.
# The cache is rebuilt once per cycle (or when stale) so that
# is_blocked_by_unresolved() can answer without any live API calls.
#
# Cache format (DEP_GRAPH_CACHE_FILE):
# {
#   "built_at": "<ISO timestamp>",
#   "repos": {
#     "owner/repo": {
#       "open_issues": [<number>, ...],
#       "task_to_issue": { "tNNN": <number>, ... },
#       "blocked_by": {
#         "<issue_number>": {
#           "task_ids": ["NNN", ...],
#           "issue_nums": ["NNN", ...],
#           "has_defer_marker": true|false  # t2031 — body signals human hold
#         }
#       },
#       "defer_flags": { "<issue_number>": true, ... }  # t2031 — body defer
#                                                       # markers for issues
#                                                       # without blocked-by
#     }
#   }
# }
#
# Returns: 0 always (non-fatal — cache miss falls back to live API)
#######################################
build_dependency_graph_cache() {
	local cache_file="$DEP_GRAPH_CACHE_FILE"
	local ttl_secs="$DEP_GRAPH_CACHE_TTL_SECS"

	# Skip rebuild if cache is fresh
	if [[ -f "$cache_file" && "${PULSE_DEP_GRAPH_FORCE_REBUILD:-0}" != "1" ]]; then
		local cache_age
		cache_age=$(($(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0)))
		if [[ "$cache_age" -lt "$ttl_secs" ]]; then
			echo "[pulse-wrapper] dep-graph-cache: cache fresh (${cache_age}s < ${ttl_secs}s TTL), skipping rebuild" >>"$LOGFILE"
			return 0
		fi
	fi
	if [[ "${PULSE_DEP_GRAPH_FORCE_REBUILD:-0}" == "1" ]]; then
		echo "[pulse-wrapper] dep-graph-cache: force rebuild requested after issue-state sync" >>"$LOGFILE"
	fi

	echo "[pulse-wrapper] dep-graph-cache: building dependency graph cache (t1935)" >>"$LOGFILE"
	local build_start
	build_start=$(date +%s)

	local repos_json
	repos_json=$(jq -c '.initialized_repos[] | select(.pulse == true and (.local_only != true))' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || repos_json=""
	if [[ -z "$repos_json" ]]; then
		echo "[pulse-wrapper] dep-graph-cache: no pulse repos found, skipping" >>"$LOGFILE"
		return 0
	fi

	# Build the graph JSON incrementally
	local graph_json="" old_graph_json=""
	graph_json=$(printf '{"built_at":"%s","repos":{}}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
	if [[ -f "$cache_file" ]]; then
		old_graph_json=$(<"$cache_file") || old_graph_json=""
	fi

	while IFS= read -r repo_entry; do
		[[ -n "$repo_entry" ]] || continue
		local slug
		slug=$(printf '%s' "$repo_entry" | jq -r '.slug // empty' 2>/dev/null)
		[[ -n "$slug" ]] || continue

		# Delegate the per-repo fetch + parse to _dep_graph_build_repo_data
		# (t2031 refactor — keeps build_dependency_graph_cache under the
		# 100-line complexity gate).
		local repo_data
		if ! repo_data=$(_dep_graph_build_repo_data "$slug") || [[ -z "$repo_data" ]]; then
			repo_data=$(printf '%s' "$old_graph_json" | jq -c --arg s "$slug" '.repos[$s] // empty' 2>/dev/null) || repo_data=""
			if [[ -z "$repo_data" ]]; then
				echo "[pulse-wrapper] dep-graph-cache: no previous repo cache for ${slug}; omitting failed repo from this cache build" >>"$LOGFILE"
				continue
			fi
			echo "[pulse-wrapper] dep-graph-cache: preserved previous repo cache for ${slug} after fetch/build failure" >>"$LOGFILE"
		fi

		# Merge repo data into graph
		graph_json=$(printf '%s' "$graph_json" |
			jq --arg slug "$slug" --argjson rd "$repo_data" \
				'.repos[$slug] = $rd' 2>/dev/null) || true
	done <<<"$repos_json"

	# Atomically write cache (write to tmp then mv)
	local tmp_file
	tmp_file="${cache_file}.tmp.$$"
	mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
	if printf '%s\n' "$graph_json" >"$tmp_file"; then
		mv "$tmp_file" "$cache_file" || rm -f "$tmp_file"
	else
		rm -f "$tmp_file"
	fi

	local build_end="" build_dur=""
	build_end=$(date +%s)
	build_dur=$((build_end - build_start))
	echo "[pulse-wrapper] dep-graph-cache: built in ${build_dur}s → ${cache_file}" >>"$LOGFILE"
	return 0
}

#######################################
# Non-dep-block comment markers (t2031)
#
# Patterns that indicate `status:blocked` was applied for a reason other
# than the blocked-by chain. When any of these markers appears in recent
# comments, the refresh routine must NOT auto-unblock — removing the
# label would discard worker/watchdog/human evidence and waste cycles on
# a guaranteed re-BLOCKED dispatch.
#
# Sources:
#   - `**BLOCKED**.*cannot proceed` — worker exit BLOCKED with evidence
#   - `Worker Watchdog Kill`        — watchdog thrash kill (zero-commit loops)
#   - `Terminal blocker detected`   — pulse-dispatch-core._apply_terminal_blocker
#   - `ACTION REQUIRED`             — supervisor-posted human-action escalation
#   - `HUMAN_UNBLOCK_REQUIRED`      — explicit machine-readable hold marker
#######################################
_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS='\*\*BLOCKED\*\*.*cannot proceed|Worker Watchdog Kill|Terminal blocker detected|ACTION REQUIRED|HUMAN_UNBLOCK_REQUIRED'

#######################################
# Decide whether to defer auto-unblock for an issue (t2031)
#
# Conservative gate for `refresh_blocked_status_from_graph`. An issue with
# a resolved blocked-by chain should still NOT be auto-unblocked when the
# `status:blocked` label was applied for another reason (worker BLOCKED
# exit, watchdog thrash kill, terminal blocker, manual human hold). Those
# origins leave evidence that auto-unblock would silently discard,
# producing repeat BLOCKED dispatches.
#
# Two signals:
#   (a) Defer/hold marker in the issue body (cached, zero API cost).
#   (b) Non-dep BLOCKED markers in the 10 most recent comments (one API
#       call per unblock candidate — candidates are rare, cost is fine).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number
#   $3 - cached defer flag ("true" or "false" from build time)
#
# Output (stdout):
#   A short machine-readable reason token when the refresh should defer
#   ("body-defer" or "comment-marker"). Empty string when safe to unblock.
#
# Exit codes:
#   0 - defer (do NOT auto-unblock); reason printed to stdout
#   1 - safe to unblock (no signal)
#######################################
_should_defer_auto_unblock() {
	local repo_slug="$1"
	local issue_num="$2"
	local has_defer_flag="$3"

	# (a) Body defer marker — cached at build time, free to consult.
	if [[ "$has_defer_flag" == "true" ]]; then
		printf 'body-defer\n'
		return 0
	fi

	# (b) Non-dep BLOCKED markers in recent comments. Use the paginated REST
	# issue-comments endpoint because only comment bodies are needed; native
	# `gh issue view --json comments` is GraphQL-only and cannot expose
	# response-owned cost. Unblock candidates are rare (typical cycle: 0-5
	# across all repos), so the cost is well-bounded. Silently tolerate fetch
	# failures (fail-open on API error → behave as before, preserving the t1935
	# auto-unblock path when network is flaky).
	local recent_bodies=""
	recent_bodies=$(set -o pipefail; gh api \
		"repos/${repo_slug}/issues/${issue_num}/comments?per_page=100" --paginate --slurp 2>/dev/null |
		jq -r '
			(if (type == "array" and ((.[0]? | type) == "array")) then add else . end)
			| .[-10:] | map(.body // "") | join("\n---\n")
		') || recent_bodies=""

	if [[ -n "$recent_bodies" ]]; then
		if printf '%s' "$recent_bodies" | grep -qE "$_PULSE_DEP_GRAPH_NON_DEP_BLOCK_MARKERS"; then
			printf 'comment-marker\n'
			return 0
		fi
	fi

	return 1
}

#######################################
# Check whether all blocked-by entries of a single cache entry are
# resolved (t2031 refactor helper).
#
# Arguments:
#   $1 - entry_json (blocked_by cache entry for one issue)
#   $2 - task_to_issue_json (repo-level task→issue mapping)
#   $3 - closed_issues_json (repo-level positively closed issue numbers)
#   $4 - known_issues_json (repo-level fetched issue numbers)
#
# Exit codes:
#   0 - all blockers resolved
#   1 - at least one blocker still open
#######################################
_refresh_all_blockers_resolved() {
	local entry_json="$1"
	local task_to_issue_json="$2"
	local closed_issues_json="$3"
	local known_issues_json="$4"

	# Task ID blockers
	local blocker_tids="" tid="" blocker_issue_num="" is_open=""
	blocker_tids=$(printf '%s' "$entry_json" | jq -r '.task_ids[]' 2>/dev/null) || blocker_tids=""
	while IFS= read -r tid; do
		[[ -n "$tid" ]] || continue
		task_identity_validate "$tid" || return 1
		blocker_issue_num=$(printf '%s' "$task_to_issue_json" | jq -r --arg t "$tid" '.[$t] // empty' 2>/dev/null)
		# A missing task mapping is not proof that a blocker resolved. It may be
		# newly created, outside the bounded fetch, or malformed; fail closed.
		[[ -n "$blocker_issue_num" ]] || return 1
		is_open=$(printf '%s' "$closed_issues_json" | jq --argjson n "$blocker_issue_num" 'index($n) == null' 2>/dev/null) || is_open="true"
		[[ "$is_open" == "true" ]] && return 1
	done <<<"$blocker_tids"

	# Issue number blockers
	local blocker_nums="" bnum=""
	blocker_nums=$(printf '%s' "$entry_json" | jq -r '.issue_nums[]?' 2>/dev/null || true)
	while IFS= read -r bnum; do
		[[ "$bnum" =~ ^[0-9]+$ ]] || continue
		is_open=$(printf '%s' "$known_issues_json" | jq --argjson n "$bnum" 'index($n) == null' 2>/dev/null) || is_open="true"
		[[ "$is_open" == "true" ]] && return 1
		is_open=$(printf '%s' "$closed_issues_json" | jq --argjson n "$bnum" 'index($n) == null' 2>/dev/null) || is_open="true"
		[[ "$is_open" == "true" ]] && return 1
	done <<<"$blocker_nums"

	return 0
}

#######################################
# Resolve dependency readiness with native relationships taking precedence.
# Text/TODO cache edges are repair input only when no native relationship is
# present. An unavailable native lookup falls back to those explicit edges and
# remains blocked unless every edge is positively known closed.
#
# Args: $1=slug $2=issue_num $3=entry_json $4=task_map $5=closed $6=known
# Returns: 0 only when dependencies are positively resolved; 1 otherwise.
#######################################
_refresh_dependency_is_resolved() {
	local slug="$1"
	local issue_num="$2"
	local entry_json="$3"
	local task_to_issue_json="$4"
	local closed_issues_json="$5"
	local known_issues_json="$6"
	local native_rc=0

	_blocked_by_check_native_relationships "$slug" "$issue_num" || native_rc=$?
	case "$native_rc" in
		0) return 1 ;;
	esac
	# A positively clear native set may be only a partial repair. Continue through
	# every declared body/TODO-compatible edge before proving readiness.

	local open_issues_json="" cache_state=""
	open_issues_json=$(jq -cn --argjson known "$known_issues_json" --argjson closed "$closed_issues_json" \
		'$known - $closed' 2>/dev/null) || open_issues_json='[]'
	cache_state=$(jq -cn --argjson open "$open_issues_json" --argjson tasks "$task_to_issue_json" \
		'{use_cache:true,open_issues:$open,task_to_issue:$tasks}' 2>/dev/null) || \
		cache_state="$DEP_CACHE_EMPTY_JSON"

	local blocker_tids="" tid="" blocker_nums="" blocker_num=""
	blocker_tids=$(printf '%s' "$entry_json" | jq -r '.task_ids[]?' 2>/dev/null || true)
	while IFS= read -r tid; do
		[[ -n "$tid" ]] || continue
		_blocked_by_check_task_id "$tid" "$slug" "$issue_num" "$cache_state" || continue
		return 1
	done <<<"$blocker_tids"

	blocker_nums=$(printf '%s' "$entry_json" | jq -r '.issue_nums[]?' 2>/dev/null || true)
	while IFS= read -r blocker_num; do
		[[ "$blocker_num" =~ ^[0-9]+$ ]] || continue
		_blocked_by_check_issue_num "$blocker_num" "$slug" "$issue_num" "$cache_state" || continue
		return 1
	done <<<"$blocker_nums"
	return 0
}

_dep_labels_has() {
	local labels_csv="$1"
	local expected_label="$2"
	[[ ",${labels_csv}," == *",${expected_label},"* ]]
	return $?
}

_dep_labels_has_active_status() {
	local labels_csv="$1"
	_dep_labels_has "$labels_csv" "status:queued" ||
		_dep_labels_has "$labels_csv" "status:claimed" ||
		_dep_labels_has "$labels_csv" "status:in-progress" ||
		_dep_labels_has "$labels_csv" "status:in-review" ||
		_dep_labels_has "$labels_csv" "status:done"
	return $?
}

# Resolve a numeric dependency target only after GitHub proves both the
# repository node and issue node identities for the supplied slug/number pair.
_dep_validate_issue_target() {
	local slug="$1"
	local issue_num="$2"
	local repository_id="" resolved_num="" issue_id=""
	[[ "$slug" =~ ^[^/[:space:]]+/[^/[:space:]]+$ && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	if [[ "$_DEP_CACHED_REPO_SLUG" == "$slug" && -n "$_DEP_CACHED_REPO_ID" ]]; then
		repository_id="$_DEP_CACHED_REPO_ID"
	else
		repository_id=$(AIDEVOPS_GH_QUOTA_COST=1 \
			AIDEVOPS_GH_ROUTE_DECISION="pulse-dep-repository-identity-rest" \
			gh api "repos/${slug}" --jq '.node_id // ""' || true)
		if [[ -n "$repository_id" ]]; then
			_DEP_CACHED_REPO_SLUG="$slug"
			_DEP_CACHED_REPO_ID="$repository_id"
		fi
	fi
	[[ -n "$repository_id" ]] || return 1
	IFS=$'\t' read -r resolved_num issue_id < <(
		AIDEVOPS_GH_QUOTA_COST=1 \
			AIDEVOPS_GH_ROUTE_DECISION="pulse-dep-issue-identity-rest" \
			gh api "repos/${slug}/issues/${issue_num}" \
				--jq '[.number // "", .node_id // ""] | @tsv' 2>/dev/null || true
	)
	[[ "$resolved_num" == "$issue_num" && -n "$issue_id" ]]
	return $?
}

#######################################
# Atomically move an issue advertised as available to blocked when dependency
# evidence is unresolved. Re-read labels immediately before the write so a
# concurrent runner cannot have advanced it to queued/claimed in the meantime.
#
# Args: $1=slug $2=issue_num
# Returns: 0 when status changed, 1 when no safe change was needed.
#######################################
_refresh_ensure_unresolved_is_blocked() {
	local slug="$1"
	local issue_num="$2"
	local current_labels=""
	_dep_validate_issue_target "$slug" "$issue_num" || return 1

	current_labels=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
	_dep_labels_has "$current_labels" "$DEP_AVAILABLE_STATUS" || return 1
	if _dep_labels_has_active_status "$current_labels"; then
		return 1
	fi
	if ! gh issue edit "$issue_num" --repo "$slug" \
		--remove-label "$DEP_AVAILABLE_STATUS" --add-label "status:blocked" >/dev/null 2>&1; then
		return 1
	fi
	# Preserve a lifecycle transition that raced the first label read. The direct
	# edit above intentionally leaves active labels intact so this repair can
	# remove only the dependency block instead of clobbering queued/in-progress.
	current_labels=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	if _dep_labels_has "$current_labels" "status:blocked" &&
		_dep_labels_has_active_status "$current_labels"; then
		gh issue edit "$issue_num" --repo "$slug" --remove-label "status:blocked" >/dev/null 2>&1 || true
		return 1
	fi
	echo "[pulse-wrapper] dep-graph-cache: normalized #${issue_num} in ${slug} available -> blocked — unresolved dependency evidence; retryable relationship normalization pending" >>"$LOGFILE"
	return 0
}

#######################################
# Remove stale direct issue-number blocked-by labels after all blockers resolve.
#
# Arguments:
#   $1 - slug
#   $2 - issue_num
#   $3 - entry_json (blocked_by cache entry)
#   $4 - current_labels (comma-separated label names)
#
# Exit codes:
#   0 - at least one stale label was removed
#   1 - no labels removed
#######################################
_refresh_cleanup_resolved_blocker_labels() {
	local slug="$1"
	local issue_num="$2"
	local entry_json="$3"
	local current_labels="$4"
	_dep_validate_issue_target "$slug" "$issue_num" || return 1

	local removed_count=0
	local blocker_nums="" blocker_num="" stale_label=""
	blocker_nums=$(printf '%s' "$entry_json" | jq -r '.issue_nums[]?' 2>/dev/null || true)
	while IFS= read -r blocker_num; do
		[[ "$blocker_num" =~ ^[0-9]+$ ]] || continue
		stale_label="blocked-by:#${blocker_num}"
		[[ ",${current_labels}," == *",${stale_label},"* ]] || continue
		if gh issue edit "$issue_num" --repo "$slug" --remove-label "$stale_label" >/dev/null 2>&1; then
			removed_count=$((removed_count + 1))
			echo "[pulse-wrapper] dep-graph-cache: removed stale ${stale_label} from #${issue_num} in ${slug} — blocker resolved (GH#25922)" >>"$LOGFILE"
		fi
	done <<<"$blocker_nums"

	[[ "$removed_count" -gt 0 ]] && return 0
	return 1
}

#######################################
# Attempt to auto-unblock a single issue (t2031 refactor helper).
#
# Consults the non-dep defer gate and only unblocks when both body and
# comments are clean. Extracted from refresh_blocked_status_from_graph
# so that function stays under the 100-line complexity gate.
#
# Arguments:
#   $1 - slug
#   $2 - issue_num
#   $3 - entry_json (blocked_by cache entry)
#   $4 - defer_flags_json (repo-level defer flags)
#
# Exit codes:
#   0 - issue unblocked (caller should increment counter)
#   1 - skipped (label absent, API error, or non-dep block detected)
#######################################
_refresh_try_unblock_issue() {
	local slug="$1"
	local issue_num="$2"
	local entry_json="$3"
	local defer_flags_json="$4"
	_dep_validate_issue_target "$slug" "$issue_num" || return 1

	local current_labels
	current_labels=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	local has_blocked_status="${DEP_FALSE}"
	[[ ",${current_labels}," == *",status:blocked,"* ]] && has_blocked_status="true"

	# Cached defer flag — either inside the blocked_by entry or in the
	# repo-level defer_flags map. Either "true" triggers defer.
	local entry_defer="" top_defer="" has_defer_flag=""
	entry_defer=$(printf '%s' "$entry_json" | jq -r '.has_defer_marker // false' 2>/dev/null) || entry_defer="${DEP_FALSE}"
	top_defer=$(printf '%s' "$defer_flags_json" | jq -r --arg n "$issue_num" '.[$n] // false' 2>/dev/null) || top_defer="${DEP_FALSE}"
	has_defer_flag="${DEP_FALSE}"
	[[ "$entry_defer" == "true" || "$top_defer" == "true" ]] && has_defer_flag="true"

	local skip_reason=""
	if skip_reason=$(_should_defer_auto_unblock "$slug" "$issue_num" "$has_defer_flag"); then
		echo "[pulse-wrapper] dep-graph-cache: NOT unblocking #${issue_num} in ${slug} — non-dep block detected (${skip_reason}) (t2031)" >>"$LOGFILE"
		return 1
	fi

	local changed="${DEP_FALSE}"
	if _refresh_cleanup_resolved_blocker_labels "$slug" "$issue_num" "$entry_json" "$current_labels"; then
		changed="true"
	fi

	[[ "$has_blocked_status" == "true" ]] || {
		[[ "$changed" == "true" ]] && return 0
		return 1
	}

	# Re-read before mutation because comment/label cleanup above performs API
	# work during which a dispatcher may have advanced the lifecycle.
	current_labels=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
	_dep_labels_has "$current_labels" "status:blocked" || return 1
	_dep_labels_has_active_status "$current_labels" && return 1
	# Preserve any lifecycle transition that races this edit: mutate only the
	# dependency statuses, then remove available if an active status appeared.
	gh issue edit "$issue_num" --repo "$slug" \
		--remove-label "status:blocked" --add-label "$DEP_AVAILABLE_STATUS" >/dev/null 2>&1 || return 1
	current_labels=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	if _dep_labels_has "$current_labels" "$DEP_AVAILABLE_STATUS" &&
		_dep_labels_has_active_status "$current_labels"; then
		gh issue edit "$issue_num" --repo "$slug" --remove-label "$DEP_AVAILABLE_STATUS" >/dev/null 2>&1 || true
		return 1
	fi
	echo "[pulse-wrapper] dep-graph-cache: unblocked #${issue_num} in ${slug} — all blockers resolved, no non-dep markers (t1935/t2031)" >>"$LOGFILE"
	return 0
}

#######################################
# Refresh blocked status from dependency graph (t1935, hardened t2031)
#
# Reads the cached dependency graph and relabels issues from
# status:blocked → status:available when all their blockers are closed.
# Runs once per cycle with zero API calls for the resolution check
# (the graph already contains open issue numbers).
#
# t2031 hardening: before removing the label, consults
# _should_defer_auto_unblock() via _refresh_try_unblock_issue() to skip
# issues whose block origin is clearly non-dep (body defer gate, worker
# BLOCKED exit, watchdog kill, terminal blocker, human hold). The old
# behaviour — blindly unblocking on dep resolution — wasted worker
# budget on guaranteed-re-BLOCKED dispatches (webapp#2273).
#
# Returns: 0 always (non-fatal)
#######################################
refresh_blocked_status_from_graph() {
	local cache_file="$DEP_GRAPH_CACHE_FILE"

	if [[ ! -f "$cache_file" ]]; then
		echo "[pulse-wrapper] dep-graph-cache: no cache file, skipping blocked-status refresh" >>"$LOGFILE"
		return 0
	fi

	local graph_json
	graph_json=$(cat "$cache_file" 2>/dev/null) || return 0
	[[ -n "$graph_json" ]] || return 0

	local unblocked_count=0 blocked_count=0

	# Iterate repos in the graph
	local slugs
	slugs=$(printf '%s' "$graph_json" | jq -r '.repos | keys[]' 2>/dev/null) || slugs=""
	[[ -n "$slugs" ]] || return 0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local repo_data="" closed_issues_json="" known_issues_json="" task_to_issue_json="" blocked_by_json="" defer_flags_json=""
		repo_data=$(printf '%s' "$graph_json" | jq -c --arg s "$slug" '.repos[$s]' 2>/dev/null) || continue
		closed_issues_json=$(printf '%s' "$repo_data" | jq -c '.closed_issues // []' 2>/dev/null) || closed_issues_json='[]'
		known_issues_json=$(printf '%s' "$repo_data" | jq -c '.known_issues // []' 2>/dev/null) || known_issues_json='[]'
		task_to_issue_json=$(printf '%s' "$repo_data" | jq -c '.task_to_issue // {}' 2>/dev/null) || task_to_issue_json='{}'
		blocked_by_json=$(printf '%s' "$repo_data" | jq -c '.blocked_by // {}' 2>/dev/null) || blocked_by_json='{}'
		defer_flags_json=$(printf '%s' "$repo_data" | jq -c '.defer_flags // {}' 2>/dev/null) || defer_flags_json='{}'

		local blocked_issue_nums
		blocked_issue_nums=$(printf '%s' "$blocked_by_json" | jq -r 'keys[]' 2>/dev/null) || blocked_issue_nums=""
		[[ -n "$blocked_issue_nums" ]] || continue

		local issue_num="" entry_json=""
		while IFS= read -r issue_num; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
			entry_json=$(printf '%s' "$blocked_by_json" | jq -c --arg n "$issue_num" '.[$n]' 2>/dev/null) || continue

			if _refresh_dependency_is_resolved "$slug" "$issue_num" "$entry_json" "$task_to_issue_json" "$closed_issues_json" "$known_issues_json"; then
				if _refresh_try_unblock_issue "$slug" "$issue_num" "$entry_json" "$defer_flags_json"; then
					unblocked_count=$((unblocked_count + 1))
				fi
			elif _refresh_ensure_unresolved_is_blocked "$slug" "$issue_num"; then
				blocked_count=$((blocked_count + 1))
			fi
		done <<<"$blocked_issue_nums"
	done <<<"$slugs"

	if [[ "$unblocked_count" -gt 0 || "$blocked_count" -gt 0 ]]; then
		echo "[pulse-wrapper] dep-graph-cache: refresh complete — blocked ${blocked_count}, unblocked ${unblocked_count} issue(s) (t1935/t18100)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Rebuild and normalize dependency readiness for one repository on demand.
#
# Candidate sweeps normally consume the cycle cache built by pulse-wrapper.
# When every remaining roadmap child is status:blocked, however, the shared
# candidate selector has no issue on which to run its dispatch-time dependency
# guard. Daily/worker sweeps can also call that selector without running the
# full pulse preflight. This repository-scoped fallback provides a fresh view
# when a candidate snapshot contains dependency-blocked work, so the next
# dependency-ready child can become available without rebuilding every
# configured repository.
#
# Args: $1=repo slug
# Returns: 0 when normalization ran, 1 when fresh repository data was unavailable.
#######################################
normalize_repo_dependency_readiness() {
	local slug="$1"
	local repo_data=""
	[[ -n "$slug" ]] || return 1

	repo_data=$(_dep_graph_build_repo_data "$slug") || return 1
	local graph_json=""
	graph_json=$(jq -cn --arg slug "$slug" --argjson data "$repo_data" \
		'{repos:{($slug):$data}}' 2>/dev/null) || return 1

	local previous_cache_file="${DEP_GRAPH_CACHE_FILE:-}"
	local scoped_cache_file=""
	scoped_cache_file=$(mktemp 2>/dev/null || true)
	[[ -n "$scoped_cache_file" ]] || return 1
	if ! printf '%s\n' "$graph_json" >"$scoped_cache_file"; then
		rm -f "$scoped_cache_file"
		return 1
	fi
	DEP_GRAPH_CACHE_FILE="$scoped_cache_file"
	refresh_blocked_status_from_graph
	DEP_GRAPH_CACHE_FILE="$previous_cache_file"
	rm -f "$scoped_cache_file"
	return 0
}

normalize_repo_dependency_readiness_if_due() {
	local slug="$1"
	local ttl_secs="${PULSE_DEP_NORMALIZE_TTL_SECS:-60}"
	local marker_dir="${HOME:+$HOME/.aidevops/cache/dependency-normalization}"
	local marker_file=""
	local marker_age=0
	[[ -n "$slug" ]] || return 1
	[[ -n "$marker_dir" ]] || return 1
	[[ "$ttl_secs" =~ ^[0-9]+$ ]] || ttl_secs=60
	marker_file="${marker_dir}/${slug//\//_}"

	if [[ -f "$marker_file" ]]; then
		marker_age=$(($(date +%s) - $(date -r "$marker_file" +%s 2>/dev/null || echo 0)))
		[[ "$marker_age" -lt "$ttl_secs" ]] && return 0
	fi
	mkdir -p "$marker_dir" 2>/dev/null || return 1
	if normalize_repo_dependency_readiness "$slug"; then
		: >"$marker_file"
		return 0
	fi
	return 1
}

#######################################
# Extract blocked-by task IDs and issue numbers from an issue body.
#
# (GH#18693 refactor helper — keeps is_blocked_by_unresolved under 100 lines.)
#
# Patterns matched:
#   - "blocked-by:tNNN" or "blocked-by: tNNN" (TODO.md format)
#   - "Blocked by tNNN" or "blocked by tNNN" (prose)
#   - "blocked-by:#NNN" (GitHub issue reference)
#
# Arguments: $1 - issue body text
# Output:    two newline-separated lists on stdout, separated by a NUL:
#            <task_ids>\0<issue_nums>
#######################################
# GH#18830: Single-return helpers for blocked-by extraction.
#
# History: Before GH#18830, these were combined into a single
# `_blocked_by_extract_refs` helper that returned both lists via
# `printf '%s\0%s'` and a `${refs%%$'\0'*}` split. That pattern was
# fatally broken on bash 3.2:
#
#   1. Bash strings cannot hold NUL bytes — command substitution
#      `refs=$(printf '%s\0%s' "$a" "$b")` truncated at the first NUL,
#      silently losing the second value.
#   2. Even worse, `${refs%%$'\0'*}` triggered a bash 3.2 parser bug:
#      "bad substitution: no closing '}'", aborting the shell. The
#      error went to stderr (never LOGFILE) and propagated up through
#      the dispatch command-substitution subshell, killing every
#      dispatch candidate that reached `is_blocked_by_unresolved`.
#
# On macOS default `/bin/bash` (3.2.57), this silently broke the
# dispatch_max for weeks. Contained only by the subshell
# wrapper added in PR #18826 (GH#18804) which isolated the abort
# without identifying its cause.
#
# Fix: two single-return helpers, each printing one value to stdout.
# No NUL, no parser traps, trivially portable across bash versions.
_blocked_by_extract_tids() {
	local body="$1"
	local blocker_lines
	# Match the dep-graph whole-line parser so compact blocker lists such as
	# `blocked-by:t001,t002,t003` are enforced consistently at dispatch time.
	# Capture full subtask ID including decimal suffix (e.g. t325.1 → 325.1).
	blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
	if task_identity_has_malformed_candidate "$blocker_lines"; then
		printf '%s\n' '__malformed__'
		return 0
	fi
	task_identity_extract_all "$blocker_lines" || true
	return 0
}

_blocked_by_extract_nums() {
	local body="$1"
	local blocker_lines
	blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
	printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true
	return 0
}

#######################################
# Check GitHub's native blocked-by relationship field for unresolved blockers.
#
# GitHub's issue relationship graph is the canonical source once blockers have
# been synced by issue-sync-relationships.sh. Body/TODO `blocked-by:*` tokens are
# retained as fallback intent and repair signals, but dispatch must consult the
# native relationship first so UI-created/backfilled dependencies are enforced
# even when the issue body does not repeat them.
#
# Arguments:
#   $1 - repo slug
#   $2 - issue number
# Exit codes:
#   0 - native relationship is open/unknown (caller should block dispatch)
#   1 - no native relationships were found (caller should check text fallback)
#   2 - native relationships exist and are positively clear
#   3 - native relationship lookup unavailable (caller should check text
#       fallback, then fail closed if no fallback marker can prove intent)
#######################################
_blocked_by_check_native_relationships() {
	local repo_slug="$1"
	local issue_number="$2"

	[[ -n "$repo_slug" && -n "$issue_number" ]] || return 1
	[[ "$repo_slug" == */* ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1

	local owner="" repo_name=""
	owner="${repo_slug%%/*}"
	repo_name="${repo_slug#*/}"
	[[ -n "$owner" && -n "$repo_name" ]] || return 1

	local response="" reported_cost="" rel_states=""
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub, not shell.
	if ! response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-blocked-by-exact-cost" \
		gh api graphql \
		-f query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner, name:$name) {
    issue(number:$number) {
      blockedBy(first: 50) {
        nodes { number state }
		pageInfo { hasNextPage }
      }
    }
  }
	rateLimit { cost }
}' \
		-F owner="$owner" -F name="$repo_name" -F number="$issue_number" \
		2>/dev/null); then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} native blockedBy lookup unavailable — checking body fallback (GH#24576)" >>"$LOGFILE"
		return 3
	fi
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || reported_cost=""
	if [[ ! "$reported_cost" =~ ^[1-9][0-9]*$ ]]; then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} native blockedBy cost unavailable — checking body fallback (GH#27777)" >>"$LOGFILE"
		return 3
	fi
	rel_states=$(printf '%s' "$response" | jq -r '
		.data.repository.issue.blockedBy as $b
		| (if $b.pageInfo.hasNextPage then "__TRUNCATED__:UNKNOWN" else empty end),
		  ($b.nodes[]? | "\(.number):\(.state)")
	' 2>/dev/null) || {
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} native blockedBy response invalid — checking body fallback (GH#24576)" >>"$LOGFILE"
		return 3
	}

	local rel_state="" rel_num="" state="" saw_relationship="${DEP_FALSE}"
	while IFS= read -r rel_state; do
		[[ -n "$rel_state" ]] || continue
		saw_relationship="true"
		rel_num="${rel_state%%:*}"
		state="${rel_state#*:}"
		case "$state" in
			[Oo][Pp][Ee][Nn])
				echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by native relationship #${rel_num} (open) — skipping dispatch (GH#23932)" >>"$LOGFILE"
				return 0
				;;
			[Cc][Ll][Oo][Ss][Ee][Dd])
				# Positively clear, continue checking other native blockers.
				;;
			*)
				echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} native blockedBy #${rel_num} has unknown state '${state}' — skipping dispatch (GH#23932)" >>"$LOGFILE"
				return 0
				;;
		esac
	done <<<"$rel_states"

	if [[ "$saw_relationship" == "true" ]]; then
		return 2
	fi

	return 1
}

#######################################
# Load cached dep-graph state for a repo (GH#18693 refactor helper).
#
# Reads DEP_GRAPH_CACHE_FILE (if present and within 2× TTL) and extracts
# the per-repo open_issues and task_to_issue maps. Emits a single compact
# JSON object on stdout with the fields the resolver needs:
#   {"use_cache": bool, "open_issues": [...], "task_to_issue": {...}}
#
# Cache errors emit use_cache:false so the caller falls through to live API
# resolution; unresolved live lookups fail closed at the blocker check.
#
# Arguments: $1 - repo slug
# Output:    one JSON object on stdout
#######################################
_blocked_by_load_cache() {
	local repo_slug="$1"
	local cache_file="$DEP_GRAPH_CACHE_FILE"

	[[ -f "$cache_file" ]] || {
		printf '%s' "$DEP_CACHE_EMPTY_JSON"
		return 0
	}

	local cache_age
	cache_age=$(($(date +%s) - $(date -r "$cache_file" +%s 2>/dev/null || echo 0)))
	# Accept cache up to 2× TTL to tolerate slow rebuild cycles
	if [[ "$cache_age" -ge $((DEP_GRAPH_CACHE_TTL_SECS * 2)) ]]; then
		printf '%s' "$DEP_CACHE_EMPTY_JSON"
		return 0
	fi

	local graph_json
	graph_json=$(<"$cache_file") || graph_json=""
	if [[ -z "$graph_json" ]]; then
		printf '%s' "$DEP_CACHE_EMPTY_JSON"
		return 0
	fi

	printf '%s' "$graph_json" | jq -c --arg s "$repo_slug" '
		if .repos[$s] == null then
			{"use_cache":false,"open_i\u0073sues":[],"task_to_issue":{}}
		else
			{"use_cache":true,"open_is\u0073ues":(.repos[$s].open_issues // []),"task_to_issue":(.repos[$s].task_to_issue // {})}
		end
	' 2>/dev/null || printf '%s' "$DEP_CACHE_EMPTY_JSON"
	return 0
}

#######################################
# Resolve a single task-ID blocker to blocked/clear/unknown (GH#18693 refactor helper).
#
# Uses the cached dep graph first; falls back to a live `gh issue list`
# search when the task is not found in the cache.
#
# Arguments:
#   $1 - canonical task ID
#   $2 - repo slug
#   $3 - issue_number (for logging)
#   $4 - cache_state JSON (from _blocked_by_load_cache)
#
# Exit codes:
#   0 - blocker is open or unknown (caller should return "blocked")
#   1 - blocker is positively resolved (caller should continue)
#######################################
_blocked_by_check_task_id() {
	local task_id="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local cache_state="$4"
	if ! task_identity_validate "$task_id"; then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} malformed blocked-by task ID — skipping dispatch" >>"$LOGFILE"
		return 0
	fi

	local use_cache
	use_cache=$(printf '%s' "$cache_state" | jq -r '.use_cache' 2>/dev/null || echo "${DEP_FALSE}")

	if [[ "$use_cache" == "true" ]]; then
		local blocker_issue_num
		blocker_issue_num=$(printf '%s' "$cache_state" |
			jq -r --arg t "$task_id" '.task_to_issue[$t] // empty' 2>/dev/null)
		if [[ -n "$blocker_issue_num" ]]; then
			local is_open
			is_open=$(printf '%s' "$cache_state" |
				jq --argjson n "$blocker_issue_num" '.open_issues | index($n) != null' 2>/dev/null) || is_open="${DEP_FALSE}"
			if [[ "$is_open" == "true" ]]; then
				echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by ${task_id}=#${blocker_issue_num} (cache: open) — skipping dispatch (t1935)" >>"$LOGFILE"
				return 0
			fi
			if _blocked_by_todo_marks_incomplete "$task_id" "$repo_slug" "$issue_number"; then
				return 0
			fi
			return 1
		fi
		# Task not in map → fall through to live API (may be a new issue).
	fi

	# Live API fallback: search all issues with this task ID in the title.
	# Empty/error is not proof of resolution because GitHub search can lag
	# immediately after rapid task creation. Treat that as unknown and block.
	local blocker_state=""
	local live_matches=""
	if ! live_matches=$(gh_issue_list --repo "$repo_slug" --state all \
		--search "${task_id} in:title" --json number,title,state 2>/dev/null); then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked-by-unresolved-reference ${task_id} (live lookup failed) — skipping dispatch" >>"$LOGFILE"
		return 0
	fi
	blocker_state=$(printf '%s' "$live_matches" | jq -r \
		--arg current_issue "$issue_number" \
		--arg task_id "$task_id" '
		def canonical_title:
			(.title // "" | ascii_downcase) as $title
			| ($task_id | ascii_downcase) as $needle
			| (($title | startswith($needle + ":")) or ($title | startswith($needle + " ")));
		[.[] | select((.number | tostring) != $current_issue)] as $matches
		| (($matches | map(select(canonical_title)) | .[0]) // $matches[0] // {})
		| .state // ""
		' 2>/dev/null) || blocker_state=""
	case "$blocker_state" in
		[Oo][Pp][Ee][Nn])
			echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by ${task_id} (live: open) — skipping dispatch (t1927)" >>"$LOGFILE"
			return 0
			;;
		[Cc][Ll][Oo][Ss][Ee][Dd])
			if _blocked_by_todo_marks_incomplete "$task_id" "$repo_slug" "$issue_number"; then
				return 0
			fi
			return 1
			;;
	esac
	echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked-by-unresolved-reference ${task_id} (cache miss / live lookup inconclusive) — skipping dispatch" >>"$LOGFILE"
	return 0
}

#######################################
# Check whether local TODO.md still marks a task blocker incomplete.
#
# GitHub closure proves the blocker resolved. When dispatch supplied
# PULSE_DEP_GRAPH_REPO_PATH and TODO.md still has an unchecked canonical tNNN
# entry, log the stale local ledger but do not re-block dispatch; the pulse
# issue-state sync stage reconciles TODO.md before cache rebuilds.
#
# Args: $1=task_id digits, $2=repo_slug, $3=issue_number
# Returns: 1 always so stale TODO never overrides closed GitHub state.
#######################################
_blocked_by_todo_marks_incomplete() {
	local task_id="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local repo_path="${PULSE_DEP_GRAPH_REPO_PATH:-}"

	[[ -n "$repo_path" ]] || return 1
	[[ -f "${repo_path}/TODO.md" ]] || return 1
	local task_id_ere=""
	task_id_ere=$(task_identity_escape_ere "$task_id") || return 1
	if grep -Eq "^- \[ \] ${task_id_ere}([:[:space:]]|$)" "${repo_path}/TODO.md" 2>/dev/null; then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} stale-todo-after-closed-blocker ${task_id} in ${repo_slug} — GitHub blocker is closed; ignoring stale TODO.md and relying on issue-state sync" >>"$LOGFILE"
		return 1
	fi
	return 1
}

#######################################
# Resolve a single GitHub issue-number blocker through live API.
#
# Arguments:
#   $1 - blocker_num
#   $2 - repo slug
#   $3 - issue_number (for logging)
#
# Exit codes:
#   0 - blocker is open or unknown
#   1 - blocker is positively resolved
#######################################
_blocked_by_check_issue_num_live() {
	local blocker_num="$1"
	local repo_slug="$2"
	local issue_number="$3"

	local blocker_state=""
	if ! blocker_state=$(gh issue view "$blocker_num" --repo "$repo_slug" \
		--json state --jq '.state // ""' 2>/dev/null); then
		echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked-by-unresolved-reference #${blocker_num} (live lookup failed) — skipping dispatch" >>"$LOGFILE"
		return 0
	fi
	case "$blocker_state" in
		[Oo][Pp][Ee][Nn])
			echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by #${blocker_num} (live: open) — skipping dispatch (t1927)" >>"$LOGFILE"
			return 0
			;;
		[Cc][Ll][Oo][Ss][Ee][Dd])
			return 1
			;;
	esac
	echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked-by-unresolved-reference #${blocker_num} (live lookup inconclusive) — skipping dispatch" >>"$LOGFILE"
	return 0
}

#######################################
# Resolve a single GitHub issue-number blocker (GH#18693 refactor helper).
#
# Arguments:
#   $1 - blocker_num
#   $2 - repo slug
#   $3 - issue_number (for logging)
#   $4 - cache_state JSON (from _blocked_by_load_cache)
#
# Exit codes:
#   0 - blocker is open or unknown
#   1 - blocker is positively resolved
#######################################
_blocked_by_check_issue_num() {
	local blocker_num="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local cache_state="$4"

	local use_cache
	use_cache=$(printf '%s' "$cache_state" | jq -r '.use_cache' 2>/dev/null || echo "${DEP_FALSE}")

	if [[ "$use_cache" == "true" ]]; then
		local is_open
		is_open=$(printf '%s' "$cache_state" |
			jq --argjson n "$blocker_num" '.open_issues | index($n) != null' 2>/dev/null) || is_open="${DEP_FALSE}"
		if [[ "$is_open" == "true" ]]; then
			echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} blocked by #${blocker_num} (cache: open) — skipping dispatch (t1935)" >>"$LOGFILE"
			return 0
		fi
		# Cache absence is not positive proof for direct issue-number blockers:
		# the issue may have been created after the cache snapshot. Verify live.
	fi

	_blocked_by_check_issue_num_live "$blocker_num" "$repo_slug" "$issue_number"
	return $?
}

#######################################
# Blocked-by enforcement (t1927, enhanced t1935, decomposed GH#18693)
#
# Checks GitHub's native blockedBy relationship field first, then parses the
# issue body for blocked-by dependencies and checks whether the blocking
# task/issue is still open. Uses the cached dependency graph (built once per
# cycle) for zero-API-call body-token resolution. Falls back to live API calls
# only when the cache is absent or the blocker is not found in it.
#
# Decomposed into _blocked_by_extract_tids, _blocked_by_extract_nums,
# _blocked_by_load_cache, _blocked_by_check_task_id, and
# _blocked_by_check_issue_num so this outer orchestrator stays under the
# 100-line complexity gate. GH#18830: split extract into two single-return
# helpers to avoid the broken NUL-delimited two-value return channel.
#
# Args:
#   $1 - issue body text
#   $2 - repo slug (owner/repo)
#   $3 - issue number (for logging)
# Returns:
#   exit 0 = blocker is unresolved (do NOT dispatch)
#   exit 1 = no blocker or blocker is resolved (safe to dispatch)
#######################################
is_blocked_by_unresolved() {
	local issue_body="$1"
	local repo_slug="$2"
	local issue_number="$3"

	[[ -n "$repo_slug" ]] || return 1
	[[ -n "$issue_number" ]] || return 1

	# Native GitHub dependencies are the primary source of truth once present.
	# Body/TODO markers remain as fallback repair intent only when no native
	# relationships exist yet. GH#23952: closed native blockers must not be
	# re-blocked by stale duplicate text markers.
	local native_rc=0
	_blocked_by_check_native_relationships "$repo_slug" "$issue_number" || native_rc=$?
	if [[ "$native_rc" -eq 0 ]]; then
		return 0
	fi
	if [[ "$native_rc" -eq 2 ]]; then
		return 1
	fi

	if [[ -z "$issue_body" ]]; then
		if [[ "$native_rc" -eq 3 ]]; then
			echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} DISPATCH_BLOCK_REASON reason=blocked_by_native_lookup_unavailable signal=native blockedBy lookup unavailable and issue body is empty — skipping dispatch (GH#24576)" >>"$LOGFILE"
			return 0
		fi
		return 1
	fi

	# Extract blocked-by references (tNNN and #NNN) via two single-return
	# helpers. GH#18830: the previous NUL-delimited two-value return was
	# fatally broken on bash 3.2 — see `_blocked_by_extract_refs` header.
	local blocker_task_ids="" blocker_issue_nums=""
	blocker_task_ids=$(_blocked_by_extract_tids "$issue_body")
	blocker_issue_nums=$(_blocked_by_extract_nums "$issue_body")

	# No blocked-by references → not blocked
	if [[ -z "$blocker_task_ids" && -z "$blocker_issue_nums" ]]; then
		if [[ "$native_rc" -eq 3 ]]; then
			echo "[pulse-wrapper] is_blocked_by_unresolved: #${issue_number} DISPATCH_BLOCK_REASON reason=blocked_by_native_lookup_unavailable signal=native blockedBy lookup unavailable and no body blocked-by markers found — skipping dispatch (GH#24576)" >>"$LOGFILE"
			return 0
		fi
		return 1
	fi

	# Load cache state once for this repo (one JSON object the helpers consume).
	local cache_state
	cache_state=$(_blocked_by_load_cache "$repo_slug")

	# Check task ID blockers
	if [[ -n "$blocker_task_ids" ]]; then
		local task_id
		while IFS= read -r task_id; do
			[[ -n "$task_id" ]] || continue
			if _blocked_by_check_task_id "$task_id" "$repo_slug" "$issue_number" "$cache_state"; then
				return 0
			fi
		done <<<"$blocker_task_ids"
	fi

	# Check GitHub issue number blockers
	if [[ -n "$blocker_issue_nums" ]]; then
		local blocker_num
		while IFS= read -r blocker_num; do
			[[ -n "$blocker_num" ]] || continue
			if _blocked_by_check_issue_num "$blocker_num" "$repo_slug" "$issue_number" "$cache_state"; then
				return 0
			fi
		done <<<"$blocker_issue_nums"
	fi

	return 1
}
